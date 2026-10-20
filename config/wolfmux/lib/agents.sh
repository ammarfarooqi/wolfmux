#!/bin/bash
# agents.sh — agent lifecycle: start, spawn, run, stop, restart, destroy, nudge.
#
# Model-neutral on purpose: a lead is "whatever launcher the model table names",
# and workers neither know nor care whether the lead is Fable or Astra.

WOLFMUX_NUDGE_DEBOUNCE="${WOLFMUX_NUDGE_DEBOUNCE:-3}"
# Nothing is ever typed into a pane a human may be typing in: the notice waits.
WOLFMUX_NUDGE_COLLISION_CHECK="${WOLFMUX_NUDGE_COLLISION_CHECK:-1}" # 0 brings back the old blind typing
WOLFMUX_NUDGE_HUMAN_IDLE="${WOLFMUX_NUDGE_HUMAN_IDLE:-5}"           # seconds since the last keystroke that still count as "at the keyboard"
# The LEAD's pane, with somebody attached, is the human's own conversation. A notice may
# go in there once it is quiet, but five seconds of quiet is a pause for thought, not an
# empty chair: 300 keeps "not in the middle of my conversation" while still delivering to
# a lead that has gone idle. Only check (a) — "a human is at this pane" — uses it; a
# half-typed line and copy mode are busy at any width.
WOLFMUX_NUDGE_LEAD_IDLE="${WOLFMUX_NUDGE_LEAD_IDLE:-300}"           # seconds of no keystroke before the human's own pane may be typed into
WOLFMUX_NUDGE_RETRY="${WOLFMUX_NUDGE_RETRY:-3}"                     # how often a waiting notice looks again
WOLFMUX_NUDGE_DEFER_MAX="${WOLFMUX_NUDGE_DEFER_MAX:-600}"           # how long it waits before giving up
# An approval notice is worthless once the worker has stopped waiting for the decision
# (WOLFMUX_APPROVAL_TIMEOUT, also 600), so it gets its own, shorter cap.
WOLFMUX_NUDGE_APPROVAL_DEFER_MAX="${WOLFMUX_NUDGE_APPROVAL_DEFER_MAX:-60}"
# ":-" substitutes for unset and empty, so an explicit 0 survives it. sleep 0 with
# waited=$((waited + 0)) is a waiter that spins on tmux for ever and never expires.
case "$WOLFMUX_NUDGE_RETRY" in "" | *[!0-9]*) WOLFMUX_NUDGE_RETRY=3 ;; esac
[ "$WOLFMUX_NUDGE_RETRY" -ge 1 ] || WOLFMUX_NUDGE_RETRY=1
# Nonsense here would make `[ "$idle" -lt "$window" ]` exit 2, which reads as NOT busy:
# a typo in this knob would type into the human's conversation. tm_pane_human_busy
# floors it a second time, for callers that pass their own number.
case "$WOLFMUX_NUDGE_LEAD_IDLE" in "" | *[!0-9]*) WOLFMUX_NUDGE_LEAD_IDLE=300 ;; esac

session_name_for_project() {
  local stored candidate
  stored="$(meta_get session || true)"
  if [ -n "$stored" ]; then
    printf '%s\n' "$stored"
    return 0
  fi
  candidate="team-$(sanitize_name "$(basename "$ROOT")")"
  # Same directory name, different repository: fall back to the unique project key.
  if tm_session_exists "$candidate" && [ "$(tm_session_root "$candidate")" != "$ROOT" ]; then
    candidate="team-$PROJECT_KEY"
  fi
  if [ "${TEAM:-$WOLFMUX_DEFAULT_TEAM}" != "$WOLFMUX_DEFAULT_TEAM" ]; then candidate="$candidate-$TEAM"; fi
  printf '%s\n' "$candidate"
}

# agent_command <role> [--continue] — fills AGENT_CMD: what a pane of this team runs
agent_command() {
  AGENT_CMD=("$TEAMCTL_SELF")
  if [ "$TEAM" != "$WOLFMUX_DEFAULT_TEAM" ]; then AGENT_CMD+=(--team "$TEAM"); fi
  AGENT_CMD+=(_run-agent "$ROOT" "$1")
  if [ "${2:-}" = "--continue" ]; then AGENT_CMD+=(--continue); fi
}

# --- conversation ids ------------------------------------------------------------
# Every lead of a project works in the same folder, so `claude --continue` (the newest
# transcript there) cannot tell two leads apart: with several teams they all land in one
# conversation. Each agent therefore gets its own id at birth and resumes exactly that.

# valid_session_id <id> — the shape a CLI conversation id has: uuid, 8-4-4-4-12 hex
valid_session_id() {
  [ "${#1}" -eq 36 ] || return 1
  case "$1" in *[!0-9a-fA-F-]*) return 1 ;; esac
  [ "${1:8:1}" = "-" ] && [ "${1:13:1}" = "-" ] && [ "${1:18:1}" = "-" ] && [ "${1:23:1}" = "-" ]
}

# new_session_id [<workdir>] — a conversation id for a fresh agent. The CLI refuses an id it
# has already used, so when a transcript of that name is already in the folder we try once
# more; a second collision is not a thing uuids do.
new_session_id() {
  local id dir="" try
  if [ -n "${1:-}" ]; then dir="$(transcripts_dir "$1" 2>/dev/null || true)"; fi
  for try in 1 2; do
    id="$(uuidgen 2>/dev/null | LC_ALL=C tr 'A-Z' 'a-z')"
    [ -n "$id" ] || return 1
    [ -n "$dir" ] && [ -e "$dir/$id.jsonl" ] || break
  done
  printf '%s\n' "$id"
}

# transcripts_base: the folder in which Claude Code keeps one folder of conversations per directory
transcripts_base() { printf '%s\n' "${WOLFMUX_CLAUDE_PROJECTS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}"; }

# session_transcript <id> [<workdir>]: the transcript of that conversation, or nothing. The agent's own
# folder first; then any folder, because the CLI reopens a conversation by id from wherever it was held
# (measured with Claude Code 2.1: --resume <id> finds one whose transcript sits under another directory).
session_transcript() {
  local base dir f
  [ -n "${1:-}" ] || return 0
  if [ -n "${2:-}" ]; then
    dir="$(transcripts_dir "$2" 2>/dev/null || true)"
    if [ -n "$dir" ] && [ -f "$dir/$1.jsonl" ]; then
      printf '%s\n' "$dir/$1.jsonl"
      return 0
    fi
  fi
  base="$(transcripts_base)"
  for f in "$base"/*/"$1".jsonl; do
    if [ -f "$f" ]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 0
}

# session_holder <id> [<own-role>]: the Beads name of another agent of this project whose record holds that
# conversation id, in any team (every lead works in the same folder), or nothing. <own-role> is the agent of
# the loaded team that may keep it: the one being restarted.
session_holder() {
  local file team role own="${2:-}"
  for file in "$PROJECT_STATE"/agents/*.json "$PROJECT_STATE"/teams/*/agents/*.json; do
    [ -f "$file" ] || continue
    [ "$("$JQ_BIN" -r '.session_id // empty' "$file" 2>/dev/null || true)" = "$1" ] || continue
    role="$(basename "$file" .json)"
    case "$file" in
      "$PROJECT_STATE"/agents/*) team="$WOLFMUX_DEFAULT_TEAM" ;;
      *) team="$(basename "$(dirname "$(dirname "$file")")")" ;;
    esac
    if [ -n "$own" ] && [ "$team" = "$TEAM" ] && [ "$role" = "$own" ]; then continue; fi
    team_identity "$team" "$role"
    return 0
  done
  return 0
}

# require_pin <id> <family> [<own-role>]: a conversation named with --resume has to be one the CLI can reopen,
# and nobody else's. A pane that is started on an id nobody ever used dies at once ("No conversation found
# with session ID"); a Codex agent takes no id at all; and two agents in one conversation is the fault this
# exists to end. All three are refused here, before anything is stopped or rewritten. Needs the project loaded.
require_pin() {
  local holder
  [ -n "$1" ] || return 0
  if [ "$2" = "codex" ]; then
    die_usage "--resume names a Claude Code conversation; a Codex agent resumes its own last one. Use --continue."
  fi
  [ -n "$(session_transcript "$1")" ] ||
    die "--resume: no conversation $1 under $(short_path "$(transcripts_base)") (its transcript would be <folder>/$1.jsonl). teamctl status --json shows each agent's stored id."
  holder="$(session_holder "$1" "${3:-}")"
  [ -z "$holder" ] ||
    die "--resume: conversation $1 is the one '$holder' has on record. Two agents in one conversation write over each other; name another one (teamctl status --json shows each agent's)."
}

require_session() {
  SESSION="$(session_name_for_project)"
  tm_session_exists "$SESSION" || die "team '$TEAM' has no session running. Start it: teamctl start <fable|astra>$([ "$TEAM" = "$WOLFMUX_DEFAULT_TEAM" ] || printf ' --team %s' "$TEAM")"
}

# agent_state <role> — running | exited(N) | stopped
agent_state() {
  local pane state
  pane="$(tm_pane_for_role "$SESSION" "$1" 2>/dev/null || true)"
  state="$(tm_pane_state "$pane")"
  case "$state" in
    running) printf 'running\n' ;;
    exited:*) printf 'exited(%s)\n' "${state#exited:}" ;;
    *) printf 'stopped\n' ;;
  esac
}

# new_record <role> <kind> <model-key> <workdir> <branch> <base-ref> <base-commit> <kickoff>
#            <spawned-by> [<repo>] [<branch-created 0|1>]
# repo: the repository this agent's worktree and branch live in, empty for this project.
# branch_created: 1 when teamctl made that branch, and only then is it ever deleted again.
new_record() {
  local launcher permissions session_id=""
  # model_info must run in THIS shell: launcher_path runs in a substitution
  # subshell, so the MODEL_* variables it sets there never reach us.
  model_info "$3" || die "unknown model '$3' (known: $WOLFMUX_MODEL_KEYS)"
  launcher="$(launcher_path "$3")"
  [ -x "$launcher" ] || die "launcher missing or not executable: $launcher  (run: teamctl doctor)"
  permissions="$(effective_permissions "$2" "$MODEL_FAMILY")"
  # Codex takes no conversation id; it resumes its own last one (resume --last).
  if [ "$MODEL_FAMILY" != "codex" ]; then session_id="$(new_session_id "$4" || true)"; fi
  # model_id is the id this agent is started with (run_agent passes it as --model), for an alias
  # as for claude:<id>: what an agent runs is on record, and model_source says where it came from.
  # model_at is when that id was recorded: an answer written before it says nothing about this
  # start (a continued conversation still ends with the old model's answer; models_running).
  "$JQ_BIN" -n --arg role "$1" --arg kind "$2" --arg model "$3" --arg label "$MODEL_LABEL" \
    --arg family "$MODEL_FAMILY" --arg launcher "$launcher" --arg workdir "$4" --arg branch "$5" \
    --arg base_ref "$6" --arg base_commit "$7" --arg kickoff "$8" --arg now "$(now_iso)" \
    --arg spawned_by "${9:-operator}" --arg permissions "$permissions" --arg model_id "$MODEL_ID" --arg billing "$MODEL_BILLING" \
    --arg repo "${10:-}" --arg branch_created "${11:-0}" --arg session_id "$session_id" --arg model_source "$MODEL_SOURCE" \
    --arg model_context "$MODEL_CONTEXT" \
    '{role: $role, kind: $kind, model: $model, model_id: $model_id, model_source: $model_source, model_context: $model_context,
      model_at: (if $model_id == "" then "" else $now end), label: $label, family: $family, billing: $billing, launcher: $launcher,
      workdir: $workdir, repo: $repo, branch: $branch, branch_created: $branch_created, base_ref: $base_ref, base_commit: $base_commit,
      kickoff: $kickoff, spawned_by: $spawned_by, permissions: $permissions, session_id: $session_id,
      pane_id: "", state: "starting", created_at: $now, updated_at: $now}' |
    reg_put "$1"
}

# start_permitted — who is starting this team? You: always ("operator"). An agent: only a
# lead, and only its own team or a team that does not exist yet (policy lead-teams of ITS
# team, default on). Never a worker, never somebody else's existing team. Prints the
# founder's Beads name; exit status 1 means refused.
start_permitted() {
  local role own exists allowed keep_team="$TEAM"
  role="$(caller_role)"
  if [ -z "$role" ]; then
    printf 'operator\n'
    return 0
  fi
  own="$(caller_team)"
  own="${own:-$WOLFMUX_DEFAULT_TEAM}"
  if [ "$role" != "$WOLFMUX_LEAD_ROLE" ]; then
    warn "'teamctl start' is for you and for leads. You are '$(team_identity "$own" "$role")': ask your lead."
    return 1
  fi
  if [ "$TEAM" != "$own" ]; then
    exists=""
    if [ -n "$(reg_list 2>/dev/null)" ] || tm_session_exists "$(session_name_for_project)" 2>/dev/null; then exists=1; fi
    team_paths "$own"
    allowed="$(policy_get lead-teams)"
    team_paths "$keep_team"
    if [ -n "$exists" ]; then
      # A team that has a lead is that lead's. Once that lead is not running, whoever founded the team may bring
      # it back: that is recovery, not founding, so the lead-teams policy (which is about founding) does not apply.
      # So may the orphan steward, for a team you founded, but only as `teamctl restart lead` (LEAD_RESTART,
      # set by restart_without_session): a plain start takes options that change the team's policy.
      if ! founder_may_act && ! { [ -n "${LEAD_RESTART:-}" ] && steward_may_act restart "$WOLFMUX_LEAD_ROLE"; }; then
        warn "team '$TEAM' already exists and has its own lead ($(team_identity "$TEAM" "$WOLFMUX_LEAD_ROLE")). Message it; you do not manage it$(is_founder && printf ' (%s)' "$FOUNDER_HINT" || true)$(is_steward && printf ' (%s: teamctl restart lead --team %s)' "$STEWARD_HINT" "$TEAM" || true)."
        return 1
      fi
    elif [ "$allowed" != "on" ]; then
      warn "founding teams is switched off for your team (teamctl policy lead-teams). Ask the human."
      return 1
    fi
  fi
  team_identity "$own" "$role"
}

# lead_session_remember <role>: the team keeps the conversation of its Claude lead outside the lead's record,
# which a plain `teamctl destroy` deletes. A Codex lead has none and leaves what is kept alone: when a Claude
# lead leads again with --continue, it is the last Claude lead's own conversation that comes back, not the
# newest one in the folder. A lead started on the newest-transcript guess (no id) leaves it alone as well.
lead_session_remember() {
  local id
  [ "$1" = "$WOLFMUX_LEAD_ROLE" ] || return 0
  id="$(reg_field "$1" session_id 2>/dev/null || true)"
  [ -z "$id" ] || meta_put lead_session "$id"
}

# lead_restore <created_at> <handover> <spawned_by>: a lead record that is written again for a team that
# already had one (the session is gone, or another model is asked for) keeps what says since when the team
# exists, which handover it was founded with and who founded it. Empty = there was none: nothing is set.
lead_restore() {
  local fields=()
  [ -z "$1" ] || fields+=(created_at "$1")
  [ -z "$2" ] || fields+=(handover "$2")
  [ -z "$3" ] || fields+=(spawned_by "$3")
  if [ "${#fields[@]}" -gt 0 ]; then reg_set "$WOLFMUX_LEAD_ROLE" "${fields[@]}"; fi
}

# lead_default_model — what `teamctl start` with no model starts the lead on: the loaded team's lead's recorded model
# (its record, after a /model typed into its pane has been adopted; else the one meta.json kept when a plain
# `teamctl destroy` took the record), and for a team that never had a lead, policy lead-model (default opus).
lead_default_model() {
  local model=""
  if reg_exists "$WOLFMUX_LEAD_ROLE" 2>/dev/null; then
    agent_model "$WOLFMUX_LEAD_ROLE"
    agent_adopt_live "$WOLFMUX_LEAD_ROLE" "${MT_MODEL_AT:-}"
    model="$(reg_field "$WOLFMUX_LEAD_ROLE" model 2>/dev/null || true)"
  fi
  [ -n "$model" ] || model="$(meta_get lead_model 2>/dev/null || true)"
  [ -n "$model" ] || model="$(policy_get lead-model)"
  printf '%s\n' "$model"
}

# --- which model an agent is started with ------------------------------------------------
# An agent's record holds two things about its model. `model` (and launcher, family, billing, which follow from it)
# is the key its NEXT start uses: teamctl start, restart, and the restore lane's restore. model_id, label, model_at,
# model_source and model_context describe the start that is RUNNING; a restart writes them anew from `model`. They
# differ only between a `teamctl model` and the restart that carries it out, and that is the point: status goes on
# naming the model the pane really runs until it runs another one.

# agent_set_model <role> <model-key> [running|all] — record <model-key> as what <role> starts on next. "running"
# (the default) leaves the running start's description alone; "all" writes it too, for an agent with no pane.
# model_info must have been run for <model-key>, in THIS shell, just before: its MODEL_* are what is written.
agent_set_model() {
  local launcher
  launcher="$(launcher_path "$2")" || die "unknown model '$2' (known: $WOLFMUX_MODEL_KEYS)"
  [ -x "$launcher" ] || die "launcher missing or not executable: $launcher  (run: teamctl doctor)"
  reg_set "$1" model "$2" launcher "$launcher" family "$MODEL_FAMILY" billing "$MODEL_BILLING"
  if [ "${3:-running}" = "all" ]; then
    reg_set "$1" model_id "$MODEL_ID" model_source "$MODEL_SOURCE" model_context "$MODEL_CONTEXT" \
      model_at "$(if [ -n "$MODEL_ID" ]; then now_iso; fi)" label "$MODEL_LABEL"
  fi
  if [ "$1" = "$WOLFMUX_LEAD_ROLE" ]; then meta_put lead_model "$2"; fi
}

# agent_adopt_live <role> <seen-at> — the record follows a /model typed into the agent's pane. Nothing tells teamctl
# about one: the agent's transcript does, and the one resolver (models_running) reads it. Call this right after
# agent_model or agent_context has set MR_* for <role>; <seen-at> is the time of the answer it read (MT_MODEL_AT,
# CTX_MODEL_AT). When its last answer names a
# model of another of the four families (fable, opus, sonnet, haiku) than the record, written after the record's
# start, the record takes that family as its key and that id as what runs. So the next restart, start or restore
# brings the agent back on the model it was moved to, not on the one it was started with. Logged as a "model"
# event. Only a family change, never a version: Claude Code can serve an earlier version of the family it was
# asked for, and the key already names that family. Lazily, from the reads that have the answer at hand
# (status, teams, restart, start), never on a timer; and never under somebody else's project lock: the next read
# does it then. Sets MR_HOW to record (and MR_MARK to nothing) when it adopted, as the record now says that.
agent_adopt_live() {
  local role="$1" key id seen at recorded_at family took=0
  [ "${MR_HOW:-}" = "transcript" ] || return 0
  seen="$MR_ID" at="${2:-}"
  key="$(reg_field "$role" model 2>/dev/null || true)"
  models_is_alias "$key" || return 0
  models_parse "$seen" || return 0
  family="$MP_FAMILY"
  models_is_alias "$family" || return 0
  id="$(reg_field "$role" model_id 2>/dev/null || true)"
  recorded_at="$(reg_field "$role" model_at 2>/dev/null || true)"
  # The resolver can display an answer whose age is unknown. Persisting a change needs
  # proof that it followed this start. Missing ids or times, and answers in the same
  # second as the start, cannot prove that; keep them as transcript evidence only.
  [ -n "$id" ] && _models_before "$recorded_at" "$at" || return 0
  if [ "$family" = "$key" ]; then
    # The key is right already (a `teamctl model` the agent has not been restarted for, then /model to that very
    # family). What runs is on record only when the recorded id is of another family.
    [ -n "$id" ] && models_parse "$id" && [ "$MP_FAMILY" != "$family" ] || return 0
  fi
  if [ -z "${LOCK_HELD:-}" ]; then
    /bin/mkdir "$STATE_DIR/.lock" 2>/dev/null || return 0
    printf '%s\n' "$$" >"$STATE_DIR/.lock/pid"
    LOCK_HELD="$STATE_DIR/.lock"
    trap 'teamctl_on_exit' EXIT
    took=1
  fi
  # Under the lock the record is read again: a restart may have rewritten it since MR_* were worked out.
  if [ "$(reg_field "$role" model 2>/dev/null || true)" = "$key" ] && [ "$(reg_field "$role" model_id 2>/dev/null || true)" = "$id" ] &&
    [ "$(reg_field "$role" model_at 2>/dev/null || true)" = "$recorded_at" ] &&
    model_info "$family"; then
    agent_set_model "$role" "$family"
    models_label_of "$seen"
    models_window_of "$seen"
    reg_set "$role" model_id "$seen" model_source "its transcript: /model typed in its pane (adopted $(now_iso))" \
      model_context "$MW_CONTEXT" model_at "${at:-$(now_iso)}" label "$MODELS_LABEL"
    event_log model "$role" "adopted $family from its transcript: its last answer ($seen, ${at:-no time}) is not the $key on record (${id:-no id})"
    MR_HOW="record" MR_MARK=""
  fi
  if [ "$took" -eq 1 ]; then lock_release; fi
  return 0
}

# --- teamctl start <fable|astra> ------------------------------------------------
cmd_start() {
  local model="" attach=1 beads="ask" pane branch opt_lead="" opt_worker="" opt_spawn="" resume=0 role stopped="" previous previous_model="" previous_session="" previous_kept="" handover="" founder="operator" ticket="" pin=""
  local prior_created="" prior_handover="" prior_by=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-attach | -d) attach=0 ;;
      --continue) resume=1 ;;
      --resume)
        [ "$#" -ge 2 ] || die_usage "--resume needs the conversation id to reopen (teamctl status --json shows the stored one)"
        valid_session_id "$2" || die_usage "--resume: '$2' is not a conversation id (a uuid, 8-4-4-4-12 hex)"
        pin="$2"
        resume=1
        shift
        ;;
      --handover)
        [ "$#" -ge 2 ] || die_usage "--handover needs the id of the bead that holds the handover"
        valid_bead_id "$2" || die_usage "--handover: '$2' is not a bead id"
        handover="$2"
        shift
        ;;
      --ticket)
        [ "$#" -ge 2 ] || die_usage "--ticket needs a ticket key, e.g. --ticket AFD-1844"
        valid_ticket "$2" || die_usage "invalid ticket key '$2' (letters, digits, '-' and '_', not at either end, max 64)"
        ticket="$2"
        shift
        ;;
      --init-beads) beads="yes" ;;
      --skip-beads) beads="skip" ;;
      --lead-permissions | --worker-permissions | --worker-spawn)
        [ "$#" -ge 2 ] || die_usage "$1 needs a value: $(policy_choices "${1#--}")"
        policy_valid "${1#--}" "$2" || die_usage "$1 must be one of: $(policy_choices "${1#--}")"
        case "$1" in
          --lead-permissions) opt_lead="$2" ;;
          --worker-permissions) opt_worker="$2" ;;
          --worker-spawn) opt_spawn="$2" ;;
        esac
        shift
        ;;
      -*) die_usage "unknown option for start: $1" ;;
      *) model="$1" ;;
    esac
    shift
  done
  [ -z "$model" ] || model_info "$model" ||
    die_usage "usage: teamctl start [<opus|fable|astra|…>] [--no-attach] [--continue] [--resume <session-id>] [--lead-permissions skip|ask] [--worker-permissions skip|lead|ask] [--worker-spawn on|off]   (models: $WOLFMUX_MODEL_KEYS)"
  require_tools
  # start never guesses between teams: the one you name, else the first one.
  WOLFMUX_TEAM_ARG="${WOLFMUX_TEAM_ARG:-$WOLFMUX_DEFAULT_TEAM}"
  load_project
  # No model named: a team that has a lead comes back on that lead's recorded model, a new one on policy lead-model.
  if [ -z "$model" ]; then
    model="$(lead_default_model)"
    model_info "$model" || die "the lead's model '$model' is not one teamctl knows (known: $WOLFMUX_MODEL_KEYS). Name one: teamctl start <model>"
  fi
  require_metered_ok
  require_pin "$pin" "$MODEL_FAMILY" "$WOLFMUX_LEAD_ROLE"
  founder="$(start_permitted)" || exit 77
  # An agent acting on a team it did not found today is a founder bringing one back: it is announced and logged as that.
  if [ "$founder" != "operator" ]; then EVENT_BY="$founder"; fi
  if [ "$founder" != "operator" ] && founder_may_act; then FOUNDER_ACTING="$founder"; fi
  # The orphan steward bringing back a team you founded is not its founder: the record goes on saying you are.
  if [ -n "${LEAD_RESTART:-}" ] && [ -z "${FOUNDER_ACTING:-}" ] && steward_may_act restart "$WOLFMUX_LEAD_ROLE"; then
    founder="operator"
    steward_begin restart "$WOLFMUX_LEAD_ROLE"
  fi
  wt_require_commit "$ROOT"
  ensure_state_dirs
  beads_ensure "$beads"
  models_refresh "$model" # as in spawn: at most one probe a day, outside the lock
  lock_acquire
  # What the lead record says about the team's beginnings, before anything below rewrites it.
  if reg_exists "$WOLFMUX_LEAD_ROLE"; then
    prior_created="$(reg_field "$WOLFMUX_LEAD_ROLE" created_at || true)"
    prior_handover="$(reg_field "$WOLFMUX_LEAD_ROLE" handover || true)"
  fi
  prior_by="$(reg_field "$WOLFMUX_LEAD_ROLE" spawned_by 2>/dev/null || true)"
  [ -n "$prior_by" ] || prior_by="$(meta_get founder 2>/dev/null || true)"
  if [ -n "$opt_lead" ]; then policy_set lead-permissions "$opt_lead"; fi
  if [ -n "$opt_worker" ]; then policy_set worker-permissions "$opt_worker"; fi
  if [ -n "$opt_spawn" ]; then policy_set worker-spawn "$opt_spawn"; fi
  # The team's default ticket key: every spawn whose branch template asks for one uses it.
  if [ -n "$ticket" ]; then meta_put ticket "$ticket"; fi

  SESSION="$(session_name_for_project)"
  if tm_session_exists "$SESSION"; then
    if [ "$(tm_pane_state "$(tm_pane_for_role "$SESSION" "$WOLFMUX_LEAD_ROLE")")" = "running" ]; then
      lock_release
      # Asking for another model is asking for another team, not for this one.
      if [ "$(reg_field "$WOLFMUX_LEAD_ROLE" model 2>/dev/null || true)" != "$model" ]; then
        info "team '$TEAM' is already running here, led by $(reg_field "$WOLFMUX_LEAD_ROLE" label 2>/dev/null || printf 'another model')."
        info "  open it:              teamctl attach$([ "$TEAM" = "$WOLFMUX_DEFAULT_TEAM" ] || printf ' --team %s' "$TEAM")"
        info "  a second team:        teamctl start $model --team <name>        e.g. --team $(printf '%s' "$model" | tr -c "${_WM_LOWER}${_WM_DIGITS}\n" '-' | cut -c1-24)"
        info "  all teams:            teamctl status"
        exit 1
      fi
      info "team '$TEAM' ($SESSION) is already running (lead: $(reg_field "$WOLFMUX_LEAD_ROLE" label 2>/dev/null || printf unknown))."
      if [ "$attach" -eq 1 ]; then cmd_attach; fi
      return 0
    fi
    if [ "$(tm_alive_count "$SESSION")" -gt 0 ]; then
      # Something is still running in that session (workers, or a shell of yours); only the
      # manager is gone. Bring it back where it was and leave the rest alone.
      info "the lead of '$SESSION' had exited; other panes are still running. Bringing the lead back."
      # The record is only rewritten when another model was asked for, and it is put back
      # if the restart fails: status must never describe a lead that does not exist.
      previous=""
      if [ "$(reg_field "$WOLFMUX_LEAD_ROLE" model 2>/dev/null || true)" != "$model" ]; then
        previous="$(reg_get "$WOLFMUX_LEAD_ROLE" 2>/dev/null || true)"
        previous_model="$(meta_get lead_model 2>/dev/null || true)"
        previous_session="$(reg_field "$WOLFMUX_LEAD_ROLE" session_id 2>/dev/null || true)"
        previous_kept="$(meta_get lead_session 2>/dev/null || true)"
        branch="$(gitr symbolic-ref --short -q HEAD || printf 'detached')"
        new_record "$WOLFMUX_LEAD_ROLE" lead "$model" "$ROOT" "$branch" "$branch" "$(gitr rev-parse HEAD)" 0 operator "" 0
        lead_restore "$prior_created" "$prior_handover" "$prior_by"
        meta_put lead_model "$model"
        # Another model, the same conversation: --continue asked for that one, not a new one (and when the
        # record held no id, for the newest one in the folder, as before conversation ids).
        if [ "$resume" -eq 1 ] && [ "$MODEL_FAMILY" != "codex" ]; then reg_set "$WOLFMUX_LEAD_ROLE" session_id "${previous_session:-$previous_kept}"; fi
      fi
      lock_release
      # In a subshell: a `die` in there ends only the attempt, not this command.
      if ! (if [ -n "$pin" ]; then
        cmd_restart "$WOLFMUX_LEAD_ROLE" --resume "$pin"
      elif [ "$resume" -eq 1 ]; then cmd_restart "$WOLFMUX_LEAD_ROLE" --continue; else cmd_restart "$WOLFMUX_LEAD_ROLE"; fi); then
        if [ -n "$previous" ]; then
          printf '%s\n' "$previous" | reg_put "$WOLFMUX_LEAD_ROLE"
          meta_put lead_model "$previous_model" lead_session "$previous_kept"
        fi
        die "the lead could not be restarted; its record is as it was. Try: teamctl restart $WOLFMUX_LEAD_ROLE"
      fi
      tm_set_splash "$SESSION"
      if [ "$attach" -eq 1 ] && [ -t 0 ] && [ -t 1 ]; then cmd_attach; fi
      return 0
    fi
    # Every process has exited (tmux keeps the panes so their last output stays readable).
    # That is a finished session, not a team: clear it away and start a new one.
    info "the previous session '$SESSION' had ended (every agent had exited); starting a new one."
    tmx kill-session -t "=$SESSION" 2>/dev/null || true
    for role in $(reg_list); do
      if [ "$(reg_field "$role" kind)" = "worker" ]; then
        reg_set "$role" pane_id "" state stopped
        stopped="$stopped $role"
      fi
    done
    event_log cleanup "$WOLFMUX_LEAD_ROLE" "ended session replaced"
    tm_adopt_legacy_server # that may have been the last session of a server from before the rename
  fi

  branch="$(gitr symbolic-ref --short -q HEAD || printf 'detached')"
  # A new record is written even where one was there (the last session had ended). With
  # --continue the conversation of that lead is what was asked for: keep its id.
  previous_session=""
  if [ "$resume" -eq 1 ]; then
    previous_session="$(reg_field "$WOLFMUX_LEAD_ROLE" session_id 2>/dev/null || true)"
    # A plain `teamctl destroy` deletes the lead's record: which conversation it had is kept with the team.
    [ -n "$previous_session" ] || previous_session="$(meta_get lead_session 2>/dev/null || true)"
  fi
  new_record "$WOLFMUX_LEAD_ROLE" lead "$model" "$ROOT" "$branch" "$branch" "$(gitr rev-parse HEAD)" 0 "$founder" "" 0
  lead_restore "$prior_created" "$prior_handover" "$prior_by"
  if [ -n "$handover" ]; then reg_set "$WOLFMUX_LEAD_ROLE" handover "$handover"; fi
  # Which conversation: the one you name; with --continue the one this lead had. With --continue and none on
  # record (a first start, a team from before conversation ids, a team that was purged) NO id is stored: the
  # CLI refuses to resume an id it never used, so --continue is then what it always was, the newest
  # conversation in this folder, and the pane says so. Codex takes no id.
  if [ "$MODEL_FAMILY" != "codex" ]; then
    if [ -n "$pin" ]; then
      reg_set "$WOLFMUX_LEAD_ROLE" session_id "$pin"
    elif [ "$resume" -eq 1 ]; then
      reg_set "$WOLFMUX_LEAD_ROLE" session_id "$previous_session"
    fi
  fi
  if [ "$resume" -eq 1 ]; then agent_command "$WOLFMUX_LEAD_ROLE" --continue; else agent_command "$WOLFMUX_LEAD_ROLE"; fi
  pane="$(tm_new_session "$SESSION" "$ROOT" "${AGENT_CMD[@]}")" || {
    reg_delete "$WOLFMUX_LEAD_ROLE"
    die "could not create tmux session '$SESSION'"
  }
  # A half-configured session would be invisible to every later command: roll back.
  # @wolfmux_teamctl: the status-bar badge and the prefix-N popup are tmux format
  # strings, and tmux runs what they name through /bin/sh with whatever PATH the server
  # was started with. Storing the absolute path here means neither has to find teamctl.
  # tmux.conf sets the same option globally to the bare word, so a session started by an
  # older teamctl falls back to PATH instead of running nothing.
  inbox_tag_session "$SESSION" || true
  if ! { tm_set_session_root "$SESSION" "$ROOT" && tm_set_session_team "$SESSION" "$TEAM" && tm_tag "$pane" "$WOLFMUX_LEAD_ROLE" "$MODEL_LABEL"; }; then
    tmx kill-session -t "=$SESSION" 2>/dev/null || true
    reg_delete "$WOLFMUX_LEAD_ROLE"
    die "could not configure tmux session '$SESSION'; it was rolled back"
  fi
  reg_set "$WOLFMUX_LEAD_ROLE" pane_id "$pane" state running
  # founder: kept beside the records, because a plain `teamctl destroy` deletes the lead's (team_founder)
  meta_put root "$ROOT" session "$SESSION" lead_model "$model" team "$TEAM" founder "$(reg_field "$WOLFMUX_LEAD_ROLE" spawned_by)"
  lead_session_remember "$WOLFMUX_LEAD_ROLE"
  event_log start "$WOLFMUX_LEAD_ROLE" "$model"
  lock_release
  tm_set_splash "$SESSION"
  layout_apply
  # A team that an agent founded, or brought back, is news for you.
  if [ -n "${FOUNDER_ACTING:-}${STEWARD_ACTING:-}" ]; then
    founder_announce restarted
  elif [ "$founder" != "operator" ]; then
    (WOLFMUX_TEAM="$TEAM" notify_deliver "$WOLFMUX_LEAD_MARK $founder started team '$TEAM' ($MODEL_LABEL). Open it: teamctl attach --team $TEAM" >/dev/null 2>&1) || true
  fi

  brand_banner
  say "team:          $TEAM   (session $SESSION, tmux socket $WOLFMUX_TMUX_SOCKET)"
  say "lead:          $MODEL_LABEL via $MODEL_LAUNCHER in $(short_path "$ROOT")"
  say "policy:        $(policy_summary)   (teamctl policy)"
  if [ -n "$stopped" ]; then
    say "stopped:      $stopped   (worktrees and branches kept; bring one back with: teamctl restart <role> [--continue])"
  fi
  say "next:          teamctl spawn backend glm53 · teamctl status · teamctl attach"
  if [ "$attach" -eq 1 ] && [ -t 0 ] && [ -t 1 ]; then
    cmd_attach
  fi
}

# --- teamctl spawn <role> <model> -----------------------------------------------
# The branch: the team's template, or exactly what --branch says. The repository: this
# project, or the one --repo names. Everything is resolved and refused before a worktree,
# a branch, a record or a pane exists, so a spawn that is turned down leaves nothing behind.
cmd_spawn() {
  local role="" model="" base="HEAD" kickoff=1 stamp path branch base_commit base_ref target pane spawner
  local from_tree="" old_record="" old_branch="" old_keep="" old_pane dirty
  local want_branch="" ticket="" repo_arg="" repo="" spawn_repo trees repo_note=""
  local pin="" link=0 linked=0
  if [ "${WOLFMUX_NO_KICKOFF:-}" = "1" ]; then kickoff=0; fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base)
        [ "$#" -ge 2 ] || die_usage "--base needs a git ref"
        base="$2"
        shift
        ;;
      --from-worktree)
        [ "$#" -ge 2 ] || die_usage "--from-worktree needs the role whose worktree is handed over"
        from_tree="$2"
        shift
        ;;
      --branch)
        [ "$#" -ge 2 ] || die_usage "--branch needs a branch name"
        want_branch="$2"
        shift
        ;;
      --ticket)
        [ "$#" -ge 2 ] || die_usage "--ticket needs a ticket key, e.g. --ticket AFD-1844"
        valid_ticket "$2" || die_usage "invalid ticket key '$2' (letters, digits, '-' and '_', not at either end, max 64)"
        ticket="$2"
        shift
        ;;
      --repo)
        [ "$#" -ge 2 ] || die_usage "--repo needs the path of a git repository"
        repo_arg="$2"
        shift
        ;;
      --resume)
        [ "$#" -ge 2 ] || die_usage "--resume needs the conversation id to reopen"
        valid_session_id "$2" || die_usage "--resume: '$2' is not a conversation id (a uuid, 8-4-4-4-12 hex)"
        pin="$2"
        kickoff=0 # that conversation has its own history; a kickoff prompt would talk past it
        shift
        ;;
      --no-kickoff) kickoff=0 ;;
      --link-node-modules) link=1 ;;
      -*) die_usage "unknown option for spawn: $1" ;;
      *) if [ -z "$role" ]; then role="$1"; elif [ -z "$model" ]; then model="$1"; else die_usage "unexpected argument: $1"; fi ;;
    esac
    shift
  done
  [ -n "$role" ] && [ -n "$model" ] || die_usage "usage: teamctl spawn <role> <model> [--base <ref>] [--branch <name>] [--ticket <KEY>] [--repo <path> | --from-worktree <role>] [--no-kickoff] [--resume <session-id>] [--link-node-modules]   (models: $WOLFMUX_MODEL_KEYS)"
  if [ -n "$from_tree" ] && [ -n "$repo_arg" ]; then die_usage "--repo and --from-worktree do not go together: a handed-over worktree stays in the repository it belongs to"; fi
  require_new_role_arg "$role"
  [ "$role" != "$WOLFMUX_LEAD_ROLE" ] || die_usage "'lead' is reserved; the lead is created by: teamctl start"
  model_info "$model" || die_usage "unknown model '$model' (known: $WOLFMUX_MODEL_KEYS)"
  require_metered_ok
  require_tools
  load_project
  require_pin "$pin" "$MODEL_FAMILY"
  ensure_state_dirs
  require_session
  spawner="$(caller_role)"
  if ! is_manager && [ "$(policy_get worker-spawn)" != "on" ]; then
    die "worker spawning is off, and you are '$spawner'. Only the lead spawns teammates. Ask it: bd create \"Need a helper: <for what>\" -t message -a lead -d \"<why, which model>\"" 77
  fi
  # Handing a worktree over deletes another agent's record: that is the lead's call (or yours),
  # never a worker's, even with worker-spawn on (review of issues #4/#5).
  if [ -n "$from_tree" ]; then require_manager "spawn --from-worktree"; fi
  # A new lane costs another node_modules and another build. Checked before the worktree is
  # made, so a refusal leaves nothing behind. A handover reuses a worktree that is already
  # there and installs nothing, so it is not asked to clear the bar (lib/disk.sh).
  if [ -z "$from_tree" ]; then disk_guard_spawn; fi
  # fable/opus/sonnet/haiku: today's answer of Claude Code, probed here at most once a day and
  # outside the lock (a probe takes seconds). new_record reads it back without a network call.
  models_refresh "$model"
  lock_acquire

  if reg_exists "$role"; then
    die "role '$role' already exists ($(agent_state "$role")). Use: teamctl restart $role — or choose another role name."
  fi
  # A worktree handed over is checked completely before anything is changed.
  if [ -n "$from_tree" ]; then
    known_role_name "$from_tree" || die_usage "invalid role '$from_tree'"
    reg_exists "$from_tree" || die "no such agent: $from_tree  (see: teamctl status)"
    [ "$(reg_field "$from_tree" kind)" = "worker" ] || die "'$from_tree' is the lead; only a worker's worktree can be handed over"
    old_pane="$(tm_pane_for_role "$SESSION" "$from_tree" 2>/dev/null || true)"
    [ "$(tm_pane_state "$old_pane")" != "running" ] || die "'$from_tree' is still running; stop it first: teamctl stop $from_tree"
    path="$(reg_field "$from_tree" workdir)"
    [ -d "$path" ] || die "cannot hand over '$from_tree': its working directory is gone ($path)"
    dirty="$(wt_dirty_count "$path")"
    if [ "$dirty" != "0" ]; then
      say "'$from_tree' has uncommitted work in $(short_path "$path"); nothing was changed:"
      report_files "$path" '  ' "$dirty" 10
      exit 1
    fi
  fi
  # A handed-over worktree stays where it is, in its own repository.
  if [ -n "$from_tree" ]; then repo="$(reg_field "$from_tree" repo 2>/dev/null || true)"; fi

  # Which repository this teammate works in. Without --repo it is the project, which is
  # also what --repo pointing back at the project means.
  if [ -n "$repo_arg" ]; then
    [ -d "$repo_arg" ] || die_usage "--repo: no such directory: $repo_arg"
    repo="$(repo_root_of "$repo_arg")" || die_usage "--repo: $repo_arg is not inside a git repository"
    [ "$repo" != "$ROOT" ] || repo=""
  fi
  if [ -n "$repo" ]; then
    git_in "$repo" rev-parse --verify -q 'HEAD^{commit}' >/dev/null ||
      die_usage "--repo: $(short_path "$repo") has no commits yet; a worktree needs one"
    spawn_repo="$repo"
    trees="$WOLFMUX_DATA/worktrees/$(project_key "$repo")/teams/$TEAM"
    repo_note=" in $(short_path "$repo")"
  else
    wt_require_commit "$ROOT"
    spawn_repo="$ROOT"
    trees="$WORKTREES_DIR"
  fi
  /bin/mkdir -p "$trees"

  base_commit="$(git_in "$spawn_repo" rev-parse --verify -q "$base^{commit}")" || die "cannot resolve base ref '$base' in $(short_path "$spawn_repo")"
  base_ref="$base"
  if [ "$base" = "HEAD" ]; then
    base_ref="$(git_in "$spawn_repo" symbolic-ref --short -q HEAD || printf '%s' "$base_commit" | cut -c1-12)"
  fi

  stamp="$(now_stamp)"
  if [ -n "$want_branch" ]; then
    branch="$want_branch"
  else
    # A ticket on the command line wins over the team's default (teamctl start --ticket).
    [ -n "$ticket" ] || ticket="$(meta_get ticket 2>/dev/null || true)"
    branch="$(wt_branch_name "$role" "$stamp" "$ticket")"
  fi
  wt_require_branch_name "$spawn_repo" "$branch"
  if wt_branch_exists_in "$spawn_repo" "$branch"; then
    die "branch '$branch' already exists in $(short_path "$spawn_repo"). teamctl never adopts a branch it did not create (teamctl remove deletes a teammate's branch), so pick another name."
  fi
  if [ -n "$from_tree" ]; then
    # A fresh conversation in the worktree that already exists: the same directory, so
    # everything git ignores (node_modules, build output) survives and no install or
    # build is repeated. The old branch and its commits stay; the record moves to the
    # new role. If the pane cannot be made, the old worker is put back exactly as it was.
    old_record="$(reg_get "$from_tree")"
    old_branch="$(reg_field "$from_tree" branch)"
    # The keep flag belongs to the WORKTREE, not to the role name: a handover reuses the
    # same expensive checkout, so a lane that was worth protecting from the automatic sweep
    # is still worth protecting under its new role. Read before the old record is deleted.
    old_keep="$(reg_field "$from_tree" keep_build 2>/dev/null || true)"
    if ! "$GIT_BIN" -C "$path" switch -q -c "$branch" "$base_commit" >/dev/null 2>&1; then
      die "could not create branch $branch in $(short_path "$path") (is that directory still a git worktree of $(short_path "$spawn_repo")?)"
    fi
    reg_delete "$from_tree"
    /bin/rm -f "$STATE_DIR/settings/$from_tree.json"
  else
    path="$(wt_create "$spawn_repo" "$trees/$role-$stamp" "$branch" "$base_commit")"
    # Only a brand-new worktree: a handed-over one already has the dependencies it installed.
    if disk_link_wanted "$link" && disk_link_node_modules "$spawn_repo" "$path"; then linked=1; fi
  fi
  new_record "$role" worker "$model" "$path" "$branch" "$base_ref" "$base_commit" "$kickoff" "${spawner:-operator}" "$repo" 1
  if [ -n "$pin" ]; then reg_set "$role" session_id "$pin"; fi
  if [ "$old_keep" = "on" ]; then reg_set "$role" keep_build on; fi

  target="$(tm_split_target "$SESSION")" || target=""
  pane=""
  if [ -n "$target" ]; then
    if [ -n "$pin" ]; then agent_command "$role" --continue; else agent_command "$role"; fi
    pane="$(tm_split "$target" "$path" "${AGENT_CMD[@]}" || true)"
  fi
  if [ -z "$pane" ]; then
    if [ -n "$from_tree" ]; then
      # Only a worktree that is back on its old branch lets go of the new one; otherwise the
      # new branch stays (it is what is checked out there) and you are told.
      if "$GIT_BIN" -C "$path" switch -q "$old_branch" >/dev/null 2>&1; then
        git_in "$spawn_repo" branch -D "$branch" >/dev/null 2>&1 || true
      else
        warn "could not switch $(short_path "$path") back to $old_branch; it is still on $branch. Switch it yourself: git -C \"$path\" switch $old_branch"
      fi
      printf '%s\n' "$old_record" | reg_put "$from_tree"
    else
      wt_discard_new "$spawn_repo" "$path" "$branch"
    fi
    reg_delete "$role"
    die "could not create a tmux pane for '$role' (window too small? attach and enlarge the terminal, then retry)."
  fi
  tm_tag "$pane" "$role" "$MODEL_LABEL"
  reg_set "$role" pane_id "$pane" state running
  layout_apply
  if [ -n "$from_tree" ]; then
    event_log from-worktree "$role" "$from_tree handed its worktree over; branch $old_branch kept"
  fi
  event_log spawn "$role" "$model $branch by ${spawner:-operator}${repo_note}"
  lock_release
  # The manager always knows who is on the team, whoever did the spawning.
  if [ -n "$spawner" ] && [ "$spawner" != "$WOLFMUX_LEAD_ROLE" ]; then
    notify_lead spawn "$spawner" "$role" "$MODEL_LABEL" || true
  fi

  say "spawned:   $role  ($MODEL_LABEL via $MODEL_LAUNCHER)  permissions: $(reg_field "$role" permissions)"
  if [ -n "$MODEL_SOURCE" ]; then say "model:     $MODEL_ID  ($MODEL_SOURCE)"; fi
  say "pane:      $pane"
  if [ -n "$repo" ]; then say "repo:      $(short_path "$repo")   (another repository; the guard holds this teammate to the worktree below)"; fi
  say "branch:    $branch  (base: $base_ref @ $(printf '%s' "$base_commit" | cut -c1-12))"
  say "worktree:  $(short_path "$path")"
  if [ -n "$from_tree" ]; then
    say "handed over: the worktree of $from_tree (its branch $old_branch and its commits are kept)"
    # The point of a handover is that the install is not repeated, and from v1.17.0 parking
    # the old lane sweeps its build output — so say which of the two happened here instead of
    # leaving the new agent to discover it when a build fails.
    if [ "$old_keep" = "on" ]; then
      say "kept:      teamctl keep came with the worktree, so its build output is still protected from the automatic sweep"
    elif [ ! -e "$path/node_modules" ]; then
      say "note:      this worktree has no node_modules: it was swept when $from_tree was parked. To carry an install through a handover, run teamctl keep <role> BEFORE stopping that lane (or teamctl policy auto-prune off for the team)"
    fi
  fi
  if [ "$linked" -eq 1 ]; then
    say "deps:      node_modules linked to $(short_path "$spawn_repo")/node_modules — ONE directory for every lane, so an install in any lane changes them all"
  fi
}

# --- internal: the process that a pane runs -----------------------------------------
path_prepend() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) if [ -d "$1" ]; then PATH="$1:$PATH"; fi ;;
  esac
}

build_role_prompt() {
  local role="$1" kind workdir me lead repo
  kind="$(reg_field "$role" kind)"
  workdir="$(reg_field "$role" workdir)"
  repo="$(reg_field "$role" repo)"
  me="$(team_identity "$TEAM" "$role")"
  lead="$(team_identity "$TEAM" "$WOLFMUX_LEAD_ROLE")"
  printf '# Wolfmux session context\n\n'
  printf 'You are an agent in a Wolfmux tmux session. These facts are yours:\n\n'
  printf -- '- TEAM_ROLE: %s   (kind: %s, model: %s)\n' "$role" "$(printf '%s' "$kind" | tr '[:lower:]' '[:upper:]')" "$(reg_field "$role" label)"
  printf -- '- Project root (the lead works here): %s\n' "$ROOT"
  if [ "$kind" = "worker" ]; then
    printf -- '- Your private worktree (work ONLY here): %s\n' "$workdir"
    printf -- '- Your branch: %s   (base: %s @ %s)\n' "$(reg_field "$role" branch)" "$(reg_field "$role" base_ref)" "$(reg_field "$role" base_commit | cut -c1-12)"
    if [ -n "$repo" ]; then
      printf -- '- Your worktree is a worktree of ANOTHER repository: %s. Your branch lives there, and your work belongs there. The project root above is your lead'"'"'s repository: you may read it, you may not change it. Your team, your Beads inbox and your lead are unchanged.\n' "$repo"
    fi
  fi
  printf -- '- Your team: %s\n' "$TEAM"
  printf -- '- Your Beads identity: BEADS_ACTOR=%s (already exported). Your inbox: bd list --assignee %s --status open,in_progress,blocked --include-infra\n' "$me" "$me"
  printf -- '- "Your inbox" always means that Beads command: the work itself lives there and nowhere else. `teamctl inbox` is a different thing — the short pane notices filed for a role, which the human reads with prefix N; you are given yours automatically and never need to run it.\n'
  printf -- '- The manager of this team is the agent with TEAM_ROLE=lead; in Beads it is called "%s". Nobody else manages, approves or assigns.\n' "$lead"
  if [ "$TEAM" != "$WOLFMUX_DEFAULT_TEAM" ]; then
    printf -- '- This project has more than one team and they share one Beads database. Everyone in YOUR team is called "%s.<role>" there: assign and message with -a %s.<role> (your lead: -a %s). A plain "lead" is the lead of ANOTHER team, and the tasks of other teams are not yours.\n' "$TEAM" "$TEAM" "$lead"
  fi
  if [ "$kind" = "worker" ]; then
    printf -- '- You were spawned by: %s. You report to the lead regardless.\n' "$(reg_field "$role" spawned_by)"
    if [ "$(policy_get worker-isolation)" = "on" ]; then
      printf -- '- Worktree isolation is ON: a tool call that changes files outside your worktree, reads another teammate'"'"'s worktree, switches or deletes branches, or writes into the lead'"'"'s checkout is refused. That is by design; when something outside has to change, message the lead.\n'
    fi
    if [ "$(policy_get worker-spawn)" = "on" ]; then
      printf -- '- Worker spawning is ON: you may run `teamctl spawn <role> <glm53|flash>` when the work needs it; the lead is told automatically.\n'
    else
      printf -- '- Worker spawning is OFF: you cannot add teammates. If you need one, message the lead.\n'
    fi
  else
    printf -- '- Team policy: %s. Change it with `teamctl policy`.\n' "$(policy_summary)"
  fi
  printf -- '- Other teams of this project share this Beads database (list them: `teamctl teams`). Reach another team through its lead: -a <team>.lead (the first team'"'"'s lead is plain "lead"). Their tasks are theirs; hand work across with a message.\n'
  if [ "$kind" = "lead" ] && [ "$(policy_get lead-teams)" = "on" ]; then
    printf -- '- You may found a further team and hand work over to it: write the handover as a Beads message or task first, then `teamctl start <model> --team <new-name> --no-attach --handover <bead-id>`. The human is told. You do not manage that team afterwards; its lead does. If that lead is not running (teamctl teams says orphaned) you may restart it (teamctl restart lead --team <new-name> --continue), stop, remove or destroy the team (teamctl destroy --team <new-name> --purge); the human is told each time.\n'
  fi
  printf -- '- Your permission mode: %s\n\n' "$(reg_field "$role" permissions)"
  printf 'The %s section of the protocol below is binding for you.\n\n---\n\n' "$(printf '%s' "$kind" | tr '[:lower:]' '[:upper:]')"
  if [ -r "$WOLFMUX_HOME/TEAM_PROTOCOL.md" ] && [ "$TEAM" = "$WOLFMUX_DEFAULT_TEAM" ]; then
    /bin/cat "$WOLFMUX_HOME/TEAM_PROTOCOL.md"
  elif [ -r "$WOLFMUX_HOME/TEAM_PROTOCOL.md" ]; then
    # The protocol's examples address "lead" and plain roles; in a named team those are
    # <team>.lead and <team>.<role>. Rewrite the examples rather than hope it is remembered.
    sed -E -e "s/(-a|--assignee) (lead|backend|frontend|qa)([^${_WM_LOWER}${_WM_DIGITS}.-]|\$)/\\1 $TEAM.\\2\\3/g" \
      -e 's/--assignee \$TEAM_ROLE/--assignee $BEADS_ACTOR/g' "$WOLFMUX_HOME/TEAM_PROTOCOL.md"
  else
    printf 'Team protocol file is missing: %s/TEAM_PROTOCOL.md\n' "$WOLFMUX_HOME"
  fi
}

# kickoff_text <role> <beads-identity> [<provider>] — the inbox is addressed by identity (<team>.<role>
# in a named team, the plain role in the first one); teamctl takes the plain role and knows the team.
# A worker on a provider of the table (not a subscription model) also learns what a 401 means and who
# checks it (issue #1): the key in its Keychain slot is rejected by that endpoint, and doctor --probe
# says so. Only a request that got through can carry this, so it is for a key that fails later.
kickoff_text() {
  local hint=""
  if [ -n "${3:-}" ] && wolfmux_provider_info "$3"; then
    hint=" If your requests fail with 401 or an authentication error, tell the lead: the key in '$PROVIDER_KEYCHAIN' is rejected by $PROVIDER_BASE_URL; the lead or the human runs \`teamctl doctor --probe\` to check the key."
  fi
  printf 'You are the %s worker of a Wolfmux session. Check your Beads inbox now: run `bd list --assignee %s --status open,in_progress,blocked --include-infra`, read every item with `bd show <id>`, then act as the team protocol in your system prompt says. If a task of yours is already in_progress, you were restarted in the middle of it: run `git status` and `teamctl diff %s --commits` to see what you already did, then continue it; do not start over. If nothing is assigned to you yet, answer with one line saying you are ready, and wait.%s' "$1" "${2:-$1}" "$1" "$hint"
}

# handover_text — what the lead of a team founded by another lead is started with
handover_text() {
  local me bead founder
  me="$(team_identity "$TEAM" "$WOLFMUX_LEAD_ROLE")"
  bead="$(reg_field "$WOLFMUX_LEAD_ROLE" handover)"
  founder="$(reg_field "$WOLFMUX_LEAD_ROLE" spawned_by)"
  printf 'You are the lead of the new team "%s". %s founded this team to hand work over to you. Read the handover first: run `bd show %s`. Then check your inbox: `bd list --assignee %s --status open,in_progress,blocked --include-infra`. Staff your team with `teamctl spawn <role> <model>` as the work needs, and report back to %s through Beads (-a %s) when the handover asks for it.' \
    "$TEAM" "$founder" "$bead" "$me" "$founder" "$founder"
}

# cmd_prompt <role> — internal (`teamctl _prompt`): the session context an agent is started with
cmd_prompt() {
  require_role_arg "${1:-}"
  require_tools
  load_project
  reg_exists "$1" || die "no such agent: $1"
  build_role_prompt "$1"
}

# write_agent_settings <role> — Claude Code settings for one Claude-based agent; prints
# the file path. Workers never run Claude Code's own agent-teams feature: with it on,
# any subagent a session names becomes a teammate whose "team lead" — and permission
# approver — is that worker. The lead's file holds the notification hook and nothing
# about teams or permissions: those stay exactly as you have them.
#
# Two of the hooks are how an agent learns about a bead without a keystroke anywhere
# (lib/inbox.sh): `_inbox-stop` is a SECOND entry in the Stop array, next to the
# notification hook rather than instead of it, and `_inbox-prompt` runs on
# UserPromptSubmit. Nothing is added to ~/.claude/settings.json — this file is per
# agent, written at run time, and goes when the team goes.
write_agent_settings() {
  local role="$1" path="$STATE_DIR/settings/$1.json" kind notify_command="" guard_command=""
  /bin/mkdir -p "$STATE_DIR/settings"
  kind="$(reg_field "$role" kind)"
  if notify_wanted "$kind"; then notify_command="\"$TEAMCTL_SELF\" _notify"; fi
  if [ "$kind" = "worker" ] && [ "$(policy_get worker-isolation)" = "on" ]; then guard_command="\"$TEAMCTL_SELF\" _guard"; fi
  # Workers only: agent teams off, so a worker can never become a second manager.
  # Workers, unless the policy says otherwise: the worktree guard (lib/guard.sh).
  # Everyone: notifications are teamctl's job inside a team (lib/notify.sh), and the
  #   notice inbox reaches the agent on Stop and on UserPromptSubmit (lib/inbox.sh).
  # Lead mode only: permission requests go to the lead.
  # Everyone, when the team's browser-writes policy says so (lib/policy.sh): an explicit
  # ALLOW rule for Chrome writes, so the permission check resolves before Claude Code's
  # auto-mode classifier ever runs on it (bypass mode does not switch that off).
  "$JQ_BIN" -n --arg kind "$kind" --arg mode "$(reg_field "$role" permissions)" \
    --arg permission_command "\"$TEAMCTL_SELF\" _permission-hook" --argjson timeout "$(($(approval_timeout) + 30))" \
    --arg notify_command "$notify_command" --arg silence "$(notify_silence_value)" --arg guard_command "$guard_command" \
    --arg inbox_stop "\"$TEAMCTL_SELF\" _inbox-stop" --arg inbox_prompt "\"$TEAMCTL_SELF\" _inbox-prompt" \
    --arg browser_allow "$(policy_get browser-writes)" '
    (if $kind == "worker" then {env: {CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "0"}, teammateMode: "in-process"} else {} end)
    * {env: {ECC_DISABLED_HOOKS: $silence}}
    * {hooks: {
         Stop: (
           (if $notify_command != "" then [{hooks: [{type: "command", command: $notify_command, timeout: 10}]}] else [] end)
           + [{hooks: [{type: "command", command: $inbox_stop, timeout: 10}]}]),
         UserPromptSubmit: [{hooks: [{type: "command", command: $inbox_prompt, timeout: 10}]}]}}
    * (if $guard_command != ""
       then {hooks: {PreToolUse: [{matcher: "Edit|Write|MultiEdit|NotebookEdit|Read|Grep|Glob|LS|Bash|mcp__.*",
                                   hooks: [{type: "command", command: $guard_command, timeout: 10}]}]}} else {} end)
    * (if $kind == "worker" and $mode == "lead"
       then {hooks: {PermissionRequest: [{hooks: [{type: "command", command: $permission_command, timeout: $timeout}]}]}}
       else {} end)
    # $browser_allow is the TEAM-level browser-write grant (policy browser-writes, lib/policy.sh).
    # It is NOT the role-level PermissionRequest hook above — different gate, different purpose,
    # kept as its own arm on purpose so a later edit cannot merge or drop one for the other.
    * (if $browser_allow == "allow"
       then {permissions: {allow: ["mcp__claude-in-chrome__*"]}} else {} end)' >"$path"
  printf '%s\n' "$path"
}

cmd_run_agent() {
  local root="${1:-}" role="${2:-}" resume=0 launcher family workdir prompt args permissions name model_id provider beads_workspace session_id
  [ -n "$root" ] && [ -n "$role" ] || die_usage "internal use: _run-agent <root> <role> [--continue]"
  if [ "${3:-}" = "--continue" ]; then resume=1; fi
  export WOLFMUX_ROOT="$root"
  require_tools
  load_project
  reg_exists "$role" || die "no registry record for role '$role' in $(short_path "$ROOT")"
  # A new session of the lead: how the last one ended no longer describes the team.
  if [ "$role" = "$WOLFMUX_LEAD_ROLE" ]; then team_end_clear; fi
  launcher="$(reg_field "$role" launcher)"
  family="$(reg_field "$role" family)"
  workdir="$(reg_field "$role" workdir)"
  [ -x "$launcher" ] || die "launcher missing or not executable: $launcher"
  [ -d "$workdir" ] || die "working directory is gone: $workdir"

  WOLFMUX_TEAM="$TEAM"
  BEADS_ACTOR="$(team_identity "$TEAM" "$role")" # all teams of a project share its Beads
  export TEAM_ROLE="$role" BEADS_ACTOR WOLFMUX_TEAM
  if [ "$(reg_field "$role" kind)" = "worker" ]; then
    WOLFMUX_WORKTREE="$workdir" # what the worktree guard (lib/guard.sh) holds this agent to
    WOLFMUX_BRANCH="$(reg_field "$role" branch)"
    WOLFMUX_REPO="$(reg_field "$role" repo)" # set only with --repo: that repository's own checkout is read-only too
    export WOLFMUX_WORKTREE WOLFMUX_BRANCH WOLFMUX_REPO
    # A teammate spawned with --repo sits in another repository, and bd resolves its workspace
    # through git: without this it would look for Beads in THAT repository and find none or the
    # wrong one. The team's tasks and messages live in the project's workspace, so name it.
    if [ -n "$(reg_field "$role" repo)" ] && [ -z "${BEADS_DIR:-}" ]; then
      beads_workspace="$(beads_dir 2>/dev/null || true)"
      if [ -n "$beads_workspace" ]; then export BEADS_DIR="$beads_workspace"; fi
    fi
  fi
  WOLFMUX_SESSION="$(meta_get session || true)"
  WOLFMUX_MODEL="$(reg_field "$role" model)"
  export WOLFMUX_SESSION WOLFMUX_MODEL
  path_prepend "$HOME/.local/bin"
  path_prepend "$WOLFMUX_BIN_DIR"
  export PATH
  cd "$workdir" || die "cannot enter $workdir"

  permissions="$(reg_field "$role" permissions)"
  model_id="$(reg_field "$role" model_id)" # only for claude:<id> / codex:<id>
  if [ "$family" != "codex" ]; then
    WOLFMUX_EXTRA_SETTINGS="$(write_agent_settings "$role")"
    export WOLFMUX_EXTRA_SETTINGS
  fi

  prompt="$(build_role_prompt "$role")"
  if [ "$role" = "$WOLFMUX_LEAD_ROLE" ]; then brand_wolf 2; fi # the manager's pane opens with the wolf
  printf '[wolfmux] role=%s  model=%s  launcher=%s  permissions=%s\n[wolfmux] cwd=%s\n' \
    "$role" "$(reg_field "$role" label)" "$(basename "$launcher")" "${permissions:-ask}" "$workdir"
  # A provider agent's first failure is usually its key. The line stays above the CLI's own screen.
  provider="$(wolfmux_provider_of_model "$WOLFMUX_MODEL" || true)"
  if [ -n "$provider" ] && wolfmux_provider_info "$provider"; then
    printf "[wolfmux] key: '%s' -> %s   (a 401 in this pane means the key is rejected: teamctl doctor --probe)\n" "$PROVIDER_KEYCHAIN" "$PROVIDER_BASE_URL"
  fi

  case "$family" in
    codex)
      # TOML multi-line literal string; it cannot contain three single quotes.
      case "$prompt" in *"'''"*) prompt="You are TEAM_ROLE=$role in a Wolfmux session. Read and follow $WOLFMUX_HOME/TEAM_PROTOCOL.md before anything else." ;; esac
      args=(-c "developer_instructions='''
$prompt
'''")
      if [ -n "$model_id" ]; then export WOLFMUX_ASTRA_MODEL="$model_id"; fi
      # Codex has no Stop hook; its `notify` program is the same thing under another name.
      if notify_wanted "$(reg_field "$role" kind)"; then
        args+=(-c "notify=[\"$TEAMCTL_SELF\",\"_notify\",\"--codex\"]")
      fi
      if [ "$permissions" = "skip" ]; then args+=(--dangerously-bypass-approvals-and-sandbox); fi
      if [ "$resume" -eq 1 ]; then
        args+=(resume --last)
      elif [ "$(reg_field "$role" kickoff)" = "1" ]; then
        args+=("$(kickoff_text "$role" "$BEADS_ACTOR")")
      fi
      ;;
    *)
      # The same marks as on the pane border, inside Claude Code's own frame: wolf = manager, dog = teammate.
      if [ "$role" = "$WOLFMUX_LEAD_ROLE" ]; then name="$WOLFMUX_LEAD_MARK team/$role"; else name="$WOLFMUX_WORKER_MARK team/$role"; fi
      args=(--append-system-prompt "$prompt" --name "$name")
      if [ -n "$model_id" ]; then args+=(--model "$model_id"); fi
      if [ "$permissions" = "skip" ]; then args+=(--dangerously-skip-permissions); fi
      session_id="$(reg_field "$role" session_id)"
      if [ "$resume" -eq 1 ]; then
        if [ -z "$session_id" ]; then
          # A record from before conversation ids were stored.
          warn "no stored conversation id for '$role': resuming the newest transcript in $workdir. With another agent working in the same folder that may be its conversation, not this one. Pin one: teamctl restart $role --resume <session-id>"
          args+=(--continue)
        elif [ -n "$(session_transcript "$session_id" "$workdir")" ]; then
          # This agent's own conversation, whoever else works in the same folder.
          args+=(--resume "$session_id")
        else
          # It never said a word, so the CLI wrote no transcript and would refuse to resume one
          # ("No conversation found with session ID"): the same id, started as what it is, new.
          info "[wolfmux] nothing to continue yet: conversation $session_id of '$role' has no transcript. Starting it fresh under the same id."
          args+=(--session-id "$session_id")
          if [ "$(reg_field "$role" kickoff)" = "1" ]; then args+=("$(kickoff_text "$role" "$BEADS_ACTOR" "$provider")"); fi
        fi
      else
        # The CLI refuses an id that already has a transcript ("already in use"). teamctl mints a
        # new one at every fresh start, so that only happens when this pane is run again by hand.
        if [ -n "$session_id" ] && [ -n "$(session_transcript "$session_id" "$workdir")" ]; then
          lock_acquire
          session_id="$(new_session_id "$workdir" || true)"
          reg_set "$role" session_id "$session_id"
          lead_session_remember "$role"
          lock_release
        fi
        if [ -n "$session_id" ]; then args+=(--session-id "$session_id"); fi
        if [ "$(reg_field "$role" kickoff)" = "1" ]; then
          args+=("$(kickoff_text "$role" "$BEADS_ACTOR" "$provider")")
        fi
      fi
      ;;
  esac
  # The lead of a team that another lead founded starts with its handover (both CLIs take
  # the first prompt as the last argument). Not on --continue: that conversation has it.
  if [ "$role" = "$WOLFMUX_LEAD_ROLE" ] && [ "$resume" -eq 0 ] && [ -n "$(reg_field "$role" handover)" ]; then
    args+=("$(handover_text)")
  fi
  # The model pins and policy this pane inherited were frozen into the tmux server's environment
  # when the team started (the environment outranks the config file). The record already says which
  # model this agent runs; the launcher reads the config file afresh for whatever else it needs.
  unset WOLFMUX_FABLE_MODEL WOLFMUX_OPUS_MODEL WOLFMUX_SONNET_MODEL WOLFMUX_HAIKU_MODEL WOLFMUX_MODEL_POLICY
  exec "$launcher" "${args[@]}"
}

# A report shows the first lines of a list and says how many it left out. It never lets `head`
# close a pipe under git: git flushes into a pipe line by line, the next write gets SIGPIPE,
# and with pipefail and set -e the command died silently with exit 141 (issue #6).
# report_commits <role> <branch> <indent> <count> — the newest ten commits that the HEAD of
# THAT WORKER'S repository does not have (its own, when it was spawned with --repo)
report_commits() {
  git_for_role "$1" log -n 10 --format="$3%h %s" "HEAD..$2" || true
  if [ "$4" -gt 10 ]; then printf '%s… and %s more commits\n' "$3" "$(($4 - 10))"; fi
}
# report_files <worktree> <indent> <count> <shown> — the first <shown> changed files of a worktree
report_files() {
  local listing
  # A caller that counted with something other than wt_dirty_count passes its own listing,
  # so the number it printed and the lines below it cannot disagree (teamctl remove counts
  # with disk_work_dirty_count: build output is not work).
  if [ "$#" -ge 5 ]; then
    listing="$5"
  else
    listing="$("$GIT_BIN" -C "$1" status --short 2>/dev/null || true)" # whole, in a variable: no pipe to close
  fi
  printf '%s\n' "$listing" | sed -n "1,$4p" | sed "s/^/$2/"
  if [ "$3" -gt "$4" ]; then printf '%s… and %s more files\n' "$2" "$(($3 - $4))"; fi
}

# --- teamctl stop / restart ------------------------------------------------------------
cmd_stop() {
  local role="${1:-}" pane freed=""
  require_role_arg "$role"
  require_tools
  load_project
  reg_exists "$role" || die "no such agent: $role  (see: teamctl status)"
  require_manager stop "$role"
  lock_acquire
  SESSION="$(session_name_for_project)"
  # How the lead's session ended, written before its pane is touched: a lead that stops itself
  # takes the hangup with it. Evidence for `teamctl teams` only (lib/finish.sh): a stopped
  # lead is a parked lead, and only `teamctl finish` ever ends a team.
  if [ "$role" = "$WOLFMUX_LEAD_ROLE" ]; then team_end_note stop; fi
  pane="$(tm_pane_for_role "$SESSION" "$role" 2>/dev/null || true)"
  if [ -n "$pane" ]; then
    tmx kill-pane -t "$pane" 2>/dev/null || true
    layout_apply
  fi
  reg_set "$role" pane_id "" state stopped
  # A stopped lane keeps its worktree for as long as the role is on the books, which is where
  # the disk went (issue #11). Until v1.17.0 only the build CACHES went here and node_modules
  # stayed, so that `teamctl restart` would be the cheap thing it looks like — and the result
  # was 50.9 GB of node_modules in parked lanes nobody restarted (measured 2026-10-13). So the
  # whole allowlist goes now, and the trade is stated in the line the sweep prints: a restarted
  # lane installs again. `teamctl policy auto-prune off` brings the old behaviour back exactly,
  # and `teamctl keep <role>` protects one expensive checkout (lib/disk.sh).
  if disk_park_sweep_say "$role" stop; then freed="$(human_size "$DISK_FREED_KB")"; fi
  event_log stop "$role" "${freed:+freed=$freed}"
  lock_release
  # The lane is parked now, and a parked lane whose work is finished is a whole checkout held
  # for nothing (lib/reclaim.sh). So this is where it is asked — and every other parked lane of
  # the team with it, because a merge is a plain git command teamctl never sees: the lane that
  # was parked before its merge goes here, the next time any lane is parked. After the lock is
  # released, on purpose: the check asks Beads and GitHub, and a team's lock is not held
  # across a network call. Stopping the lead parks no lane and asks nothing.
  #
  # The lane is parked, and this command says so whatever the check does: reclaim_after_park
  # runs it in a subshell with `|| true`, so that neither a failure nor an `exit` in there
  # (lock_acquire dies when the team's lock stays held for 30 seconds) ends this command.
  # A subshell hands no variable back, and that is the better way round, not the clumsier
  # one: whether the lane is "off the books" is read from the books (reg_exists), not from a
  # flag the check set before its last step. Do not pass a flag back out of it.
  # Not when the orphan steward stopped it: a reclaim takes lanes off the books, which is `remove`, and the
  # steward may never do that. The lane is asked the next time its own lead or you park one.
  if [ "$(reg_field "$role" kind)" = "worker" ] && [ -z "${STEWARD_ACTING:-}" ]; then reclaim_after_park "$role" stop 0 ""; fi
  if ! reg_exists "$role"; then
    say "stopped: $role   (its task is closed and its work is all in main, so the lane is off the books: worktree, branch and record. To keep a lane you mean to restart: teamctl keep $role before you stop it · for the team: teamctl policy auto-reclaim off)"
  else
    say "stopped: $role   (worktree, branch and commits are untouched; bring it back with: teamctl restart $role)"
  fi
  if [ "$role" = "$WOLFMUX_LEAD_ROLE" ]; then founder_announce "stopped the lead of"; else founder_announce "stopped $role of"; fi
}

# restart_without_session <role> <resume 0|1> — the tmux session is gone (it was ended, or the
# machine restarted) and the records remain. Restarting the lead is starting the team again, as
# the model that led it; a worker needs that session first, and is told the exact commands.
restart_without_session() {
  local role="$1" resume="$2" pin="${3:-}" model team_flag="" continue_flag="" model_flag="" start_args
  # The lead comes back on the model you name (restart --model), else on its recorded one (lead_default_model).
  model="${4:-$(lead_default_model)}"
  if [ "$TEAM" != "$WOLFMUX_DEFAULT_TEAM" ]; then team_flag=" --team $TEAM"; fi
  if [ "$resume" -eq 1 ]; then continue_flag=" --continue"; fi
  if [ -n "$pin" ]; then continue_flag=" --resume $pin"; fi
  if [ -n "${4:-}" ]; then model_flag=" --model $4"; fi
  if [ "$role" != "$WOLFMUX_LEAD_ROLE" ]; then
    die "team '$TEAM' has no session (it was ended, or the machine restarted). Bring the lead back in its last conversation: teamctl start $(lead_default_model)$team_flag --continue   then: teamctl restart $role$team_flag$model_flag$continue_flag"
  fi
  info "team '$TEAM' has no session (it was ended, or the machine restarted); starting it again."
  start_args=("$model")
  if [ -n "$pin" ]; then
    start_args+=(--resume "$pin")
  elif [ "$resume" -eq 1 ]; then start_args+=(--continue); fi
  # A team that ran without Beads is not asked about Beads again: a project with no Beads workspace is started with
  # --skip-beads. A bd that is not installed is not that: start dies about it, as a manual start does.
  if [ -n "$BD_BIN" ] && ! beads_dir >/dev/null 2>&1; then start_args+=(--skip-beads); fi
  WOLFMUX_TEAM_ARG="$TEAM" # the team this restart resolved, also when it was not named
  LEAD_RESTART=1           # this start is `teamctl restart lead`, which the orphan steward may run (start_permitted)
  cmd_start "${start_args[@]}"
}

# restart_undone <role> <its id before> <the team's kept id before> <message>: no pane came of a restart, so
# the conversation it had is the one on record again (for the lead, in the team's meta too), and it ends.
restart_undone() {
  # A restart --model had already recorded the new model: the record it had is put back whole.
  if [ -n "${RESTART_PREV_RECORD:-}" ]; then
    printf '%s\n' "$RESTART_PREV_RECORD" | reg_put "$1"
    if [ "$1" = "$WOLFMUX_LEAD_ROLE" ]; then meta_put lead_model "$RESTART_PREV_LEAD_MODEL"; fi
  fi
  reg_set "$1" session_id "$2"
  if [ "$1" = "$WOLFMUX_LEAD_ROLE" ]; then meta_put lead_session "$3"; fi
  die "$4"
}

cmd_restart() {
  local role="" resume=0 pin="" pane workdir target conversation was_session was_kept model new_model="" family on=""
  RESTART_PREV_RECORD="" RESTART_PREV_LEAD_MODEL=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --continue) resume=1 ;;
      --resume)
        [ "$#" -ge 2 ] || die_usage "--resume needs the conversation id to reopen (teamctl status --json shows the stored one)"
        valid_session_id "$2" || die_usage "--resume: '$2' is not a conversation id (a uuid, 8-4-4-4-12 hex)"
        pin="$2"
        resume=1
        shift
        ;;
      --model)
        [ "$#" -ge 2 ] || die_usage "--model needs the model to restart on (models: $WOLFMUX_MODEL_KEYS)"
        model_info "$2" || die_usage "--model: unknown model '$2' (known: $WOLFMUX_MODEL_KEYS)"
        new_model="$2"
        shift
        ;;
      -*) die_usage "unknown option for restart: $1" ;;
      *) role="$1" ;;
    esac
    shift
  done
  require_role_arg "$role"
  if [ -n "$new_model" ]; then
    model_info "$new_model"
    require_metered_ok
  fi
  require_tools
  load_project
  reg_exists "$role" || die "no such agent: $role  (see: teamctl status)"
  family="$(reg_field "$role" family)"
  if [ -n "$new_model" ]; then
    model_info "$new_model"
    # A conversation belongs to the CLI that held it: Claude Code cannot reopen a Codex one, nor Codex a Claude one.
    if [ "$resume" -eq 1 ] && [ "$MODEL_FAMILY" != "$family" ]; then
      die_usage "--model $new_model: a $family conversation cannot be continued on a $MODEL_FAMILY model. Restart it fresh (no --continue or --resume), with a handover in Beads"
    fi
    family="$MODEL_FAMILY"
  else
    # No model named: the recorded one, after a /model typed into its pane has been adopted (agent_adopt_live).
    agent_model "$role"
    agent_adopt_live "$role" "${MT_MODEL_AT:-}"
  fi
  require_pin "$pin" "$family" "$role"
  workdir="$(reg_field "$role" workdir)"
  [ -d "$workdir" ] || die "cannot restart '$role': its working directory is gone ($workdir)"
  SESSION="$(session_name_for_project)"
  if ! tm_session_exists "$SESSION"; then
    restart_without_session "$role" "$resume" "$pin" "$new_model"
    return
  fi
  require_manager restart "$role"
  model="${new_model:-$(reg_field "$role" model)}"
  models_refresh "$model" # fable/opus/sonnet/haiku: a restart is how an agent moves to a newer model
  lock_acquire
  # restart --model: that model is recorded first, as what this agent starts on from now on (the restore lane's
  # restore-on-limit uses it). It is put back if no pane comes of the restart (restart_undone).
  if [ -n "$new_model" ] && [ "$new_model" != "$(reg_field "$role" model)" ]; then
    RESTART_PREV_RECORD="$(reg_get "$role")"
    RESTART_PREV_LEAD_MODEL="$(meta_get lead_model 2>/dev/null || true)"
    model_info "$new_model"
    agent_set_model "$role" "$new_model"
    on=" on $new_model"
  fi
  # A restart picks up the current policy.
  reg_set "$role" permissions "$(effective_permissions "$(reg_field "$role" kind)" "$(reg_field "$role" family)")"
  # ... and what its model means today, which is what this pane is started with (run_agent passes
  # model_id as --model). A record from before ids were recorded gets one here. Every key, not only the four
  # aliases: after a `teamctl model` the running start's id is another key's, and must not be passed on.
  if model_info "$model"; then
    reg_set "$role" model_id "$MODEL_ID" model_source "$MODEL_SOURCE" model_context "$MODEL_CONTEXT" \
      model_at "$(if [ -n "$MODEL_ID" ]; then now_iso; fi)" label "$MODEL_LABEL"
  fi
  # Which conversation this pane comes back in: the one you named, the one it had, or a new
  # one. Codex has no id to store; it resumes its own last conversation. The pane reads the id as it
  # starts, so it is stored first, and put back if no pane comes of it.
  was_session="$(reg_field "$role" session_id)"
  was_kept="$(meta_get lead_session 2>/dev/null || true)"
  if [ "$(reg_field "$role" family)" != "codex" ]; then
    if [ -n "$pin" ]; then
      reg_set "$role" session_id "$pin"
    elif [ "$resume" -eq 0 ]; then
      reg_set "$role" session_id "$(new_session_id "$workdir" || true)"
    fi
  fi
  lead_session_remember "$role"

  if [ "$resume" -eq 1 ]; then agent_command "$role" --continue; else agent_command "$role"; fi
  pane="$(tm_pane_for_role "$SESSION" "$role")"
  if [ -n "$pane" ]; then
    tm_respawn "$pane" "$workdir" "${AGENT_CMD[@]}" || restart_undone "$role" "$was_session" "$was_kept" "respawn failed for pane $pane"
  else
    target="$(tm_split_target "$SESSION")" || restart_undone "$role" "$was_session" "$was_kept" "no pane to split in session $SESSION"
    pane="$(tm_split "$target" "$workdir" "${AGENT_CMD[@]}")" || restart_undone "$role" "$was_session" "$was_kept" "could not create a tmux pane for '$role'"
  fi
  tm_tag "$pane" "$role" "$(reg_field "$role" label)"
  reg_set "$role" pane_id "$pane" state running
  layout_apply
  if [ "$resume" -eq 1 ]; then
    conversation="$(reg_field "$role" session_id)"
    event_log restart "$role" "continue ${conversation:-newest}$on"
    say "restarted: $role in pane $pane$on (continuing ${conversation:-its previous conversation})"
  else
    event_log restart "$role" "fresh$on"
    say "restarted: $role in pane $pane$on"
  fi
  lock_release
  if [ "$role" = "$WOLFMUX_LEAD_ROLE" ]; then founder_announce restarted; else founder_announce "restarted $role of"; fi
}

# --- teamctl model <role> <model> [--now] ---------------------------------------------------------------------
# Changes what <role> starts on: its next start, restart or restore (agent_set_model). With --now the running agent
# is switched as well, but only when that is safe, and then by a resume-restart (`teamctl restart <role> --resume
# <its id>` on the new model): the conversation goes on, and nothing outside this agent changes. Typing /model into
# its pane would switch it too and is not offered: Claude Code then writes that model into ~/.claude/settings.json,
# the default of EVERY new Claude Code session on this Mac, not of this agent alone (seen on 2026-10-16).
# Safe means all of: the agent runs; on the same CLI (a Claude conversation cannot go on in Codex); with its own
# conversation id on record; between turns (models_turn_idle: a restart ends a turn that is running); and no human
# at its pane (_notice_pane_busy: the v1.20.0 rule for a pane a human is watching, then a keystroke, a half-typed
# line, copy mode). Anything else: the model is recorded only, the reason is said, and it switches at the next
# restart. Who may run it: whoever may restart that agent (require_manager).
cmd_model() {
  local role="" model="" now=0 old old_family state="stopped" pane="" running_id session_id transcript why="" scope="" running_label
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --now) now=1 ;;
      --type) die_usage "--type is not offered: /model typed into a pane writes that model into ~/.claude/settings.json, the default of every new Claude Code session on this Mac. --now switches by a resume-restart instead, which changes this agent only" ;;
      -*) die_usage "unknown option for model: $1" ;;
      *)
        if [ -z "$role" ]; then
          role="$1"
        elif [ -z "$model" ]; then
          model="$1"
        else
          die_usage "usage: teamctl model <role> <model> [--now]"
        fi
        ;;
    esac
    shift
  done
  [ -n "$role" ] && [ -n "$model" ] || die_usage "usage: teamctl model <role> <model> [--now]   (models: $WOLFMUX_MODEL_KEYS)"
  require_role_arg "$role"
  model_info "$model" || die_usage "unknown model '$model' (known: $WOLFMUX_MODEL_KEYS)"
  require_metered_ok
  require_tools
  load_project
  reg_exists "$role" || die "no such agent: $role  (see: teamctl status)"
  require_manager model "$role"
  if [ "$TEAM" != "$WOLFMUX_DEFAULT_TEAM" ]; then scope=" --team $TEAM"; fi
  SESSION="$(session_name_for_project)"
  if tm_session_exists "$SESSION"; then
    pane="$(tm_pane_for_role "$SESSION" "$role" 2>/dev/null || true)"
    if [ "$(tm_pane_state "$pane")" = "running" ]; then state="running"; fi
  fi
  # What it runs now, by the one resolver; a /model typed into its pane is on record first (agent_adopt_live).
  agent_model "$role"
  agent_adopt_live "$role" "${MT_MODEL_AT:-}"
  running_label="${MR_LABEL:-$(agent_label "$role")}"
  old="$(reg_field "$role" model)"
  old_family="$(reg_field "$role" family)"
  running_id="$(reg_field "$role" model_id)"
  models_refresh "$model" # what an alias means today, as spawn and restart ask: at most one probe a day
  model_info "$model"
  # Nothing to do: that key on record, and the pane (if any) already on that model.
  if [ "$old" = "$model" ]; then
    if [ "$state" != "running" ] ||
      { models_is_alias "$model" && models_parse "$running_id" && [ "$MP_FAMILY" = "$model" ]; } ||
      { ! models_is_alias "$model" && [ "$running_id" = "$MODEL_ID" ]; }; then
      say "$role: already on $model ($running_label). Nothing to change."
      return 0
    fi
  fi
  lock_acquire
  if [ "$state" = "running" ]; then agent_set_model "$role" "$model"; else agent_set_model "$role" "$model" all; fi
  event_log model "$role" "recorded $model (was $old)"
  lock_release
  if [ "$state" != "running" ]; then
    say "recorded: $role starts on $MODEL_LABEL ($model) from its next start: teamctl restart $role$scope --continue"
    return 0
  fi
  if [ "$now" -eq 0 ]; then
    say "recorded: $role runs $running_label until its next restart, then $MODEL_LABEL ($model)."
    say "  switch it now (keeps its conversation; only when it is between turns and nobody is at its pane): teamctl model $role $model$scope --now"
    return 0
  fi
  session_id="$(reg_field "$role" session_id)"
  if [ "$old_family" != "$MODEL_FAMILY" ]; then
    why="a $old_family conversation cannot go on in a $MODEL_FAMILY model"
  elif [ "$MODEL_FAMILY" != "claude" ]; then
    why="whether a Codex agent is between turns cannot be read"
  elif [ -z "$session_id" ]; then
    why="it has no conversation id on record to reopen"
  else
    transcript="$(session_transcript "$session_id" "$(reg_field "$role" workdir)" 2>/dev/null || true)"
    if ! models_turn_idle "$transcript"; then
      why="it is not between turns ($MT_TURN)"
    elif _notice_pane_busy "$role" "$pane"; then
      why="$TM_BUSY_REASON"
    fi
  fi
  if [ -n "$why" ]; then
    event_log model "$role" "not switched now: $why"
    say "recorded, not switched now: $why."
    say "  $role runs $running_label until then; it switches at its next restart: teamctl restart $role$scope --continue"
    return 0
  fi
  info "switching $role now by a resume-restart on $model: conversation $session_id goes on, and ~/.claude/settings.json is not touched."
  cmd_restart "$role" --resume "$session_id"
}

# --- teamctl destroy [--worktrees] [--yes] --------------------------------------------------
# _inside_worktrees <path> <worktrees dir> — really inside that worktree directory (symlinks
# resolved). The directory is the team's own, or, for a teammate spawned with --repo, the one
# that belongs to its repository: worker_trees_dir <role> says which.
_inside_worktrees() {
  local real base
  real="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  base="$(cd "$2" 2>/dev/null && pwd -P)" || return 1
  case "$real/" in "$base"/?*/) return 0 ;; esac
  return 1
}

# cmd_remove <role>... [--force] [--yes] — take a stopped worker off the books: worktree,
# branch and record. Work is never discarded silently: without --force a worker with
# uncommitted files or commits that are not in your current branch is refused, and the
# refusal lists them. With --force the same list is shown and one question is asked.
cmd_remove() {
  local force=0 assume_yes=0 roles="" role path branch dirty unmerged pane holding="" kb=0 swept=0 freed=0 repo_of repo_note
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) force=1 ;;
      --yes | -y) assume_yes=1 ;;
      -*) die_usage "unknown option for remove: $1" ;;
      *)
        require_role_arg "$1"
        roles="$roles $1"
        ;;
    esac
    shift
  done
  [ -n "$roles" ] || die_usage "usage: teamctl remove <role>... [--force] [--yes]"
  require_tools
  load_project
  require_manager remove
  SESSION="$(session_name_for_project)"
  for role in $roles; do
    reg_exists "$role" || die "no such agent: $role  (see: teamctl status)"
    [ "$(reg_field "$role" kind)" = "worker" ] || die "'$role' is the lead; end the team with: teamctl destroy"
    pane="$(tm_pane_for_role "$SESSION" "$role" 2>/dev/null || true)"
    [ "$(tm_pane_state "$pane")" != "running" ] || die "'$role' is running; stop it first: teamctl stop $role"
  done

  lock_acquire
  # What counts as "still holds work" here is disk_work_dirty_count, not wt_dirty_count: an
  # untracked entry that is only build output is not work. Two of those are this tool's own
  # doing — the node_modules symlink --link-node-modules puts in a lane, and the trash an
  # interrupted cleanup leaves — and counting them made remove demand --force for a lane
  # wolfmux had made that way. Nothing is swept before this question is answered: a command
  # that then refuses must leave the lane exactly as it found it, and "nothing was removed"
  # has to be true. The sweep happens further down, per lane, once that lane is going.
  # All or nothing: nobody is removed when one of them cannot be.
  if [ "$force" -ne 1 ]; then
    for role in $roles; do
      path="$(reg_field "$role" workdir)"
      branch="$(reg_field "$role" branch)"
      unmerged=0
      if wt_branch_exists "$role" "$branch"; then unmerged="$(git_for_role "$role" rev-list --count "HEAD..$branch" 2>/dev/null || printf 0)"; fi
      if [ "$(disk_work_dirty_count "$path")" != "0" ] || [ "$unmerged" != "0" ]; then holding="$holding $role"; fi
    done
  fi
  for role in $roles; do
    path="$(reg_field "$role" workdir)"
    branch="$(reg_field "$role" branch)"
    # Read while the record still exists: the line that reports the removal is printed
    # after reg_delete, so asking the registry there answered "no repository" for every
    # teammate, including the ones spawned with --repo.
    repo_of="$(reg_field "$role" repo 2>/dev/null || true)"
    repo_note=""
    [ -z "$repo_of" ] || repo_note=" in $(short_path "$repo_of")"
    dirty="$(disk_work_dirty_count "$path")"
    unmerged=0
    if wt_branch_exists "$role" "$branch"; then unmerged="$(git_for_role "$role" rev-list --count "HEAD..$branch" 2>/dev/null || printf 0)"; fi
    if [ -n "$holding" ] && [ "$dirty" = "0" ] && [ "$unmerged" = "0" ]; then continue; fi # reported below, removed never
    if [ "$dirty" != "0" ] || [ "$unmerged" != "0" ]; then
      say "$role still holds work that is nowhere else:"
      if [ "$unmerged" != "0" ]; then
        say "  $unmerged commit$([ "$unmerged" = "1" ] || printf s) on $branch that the current branch of $(short_path "$(worker_repo "$role")") does not have:"
        report_commits "$role" "$branch" '    ' "$unmerged"
      fi
      if [ "$dirty" != "0" ]; then
        say "  $dirty uncommitted file$([ "$dirty" = "1" ] || printf s) in $(short_path "$path"):"
        # The same list the count came from, so the number and the lines agree: build
        # output is left out of both.
        report_files "$path" '    ' "$dirty" 10 "$(disk_work_dirty_list "$path")"
      fi
      if [ "$force" -ne 1 ]; then
        say "  keep it:    commit in that worktree, then: git merge $branch"
        say "  discard it: teamctl remove $role --force"
        continue
      fi
      if [ "$assume_yes" -ne 1 ]; then
        confirm "Discard all of that and remove '$role'?" || { lock_release; die "aborted; nothing was removed (pass --yes to skip this question)"; }
      fi
    fi
    # This lane is going now: every refusal and every question above is behind us. Take its
    # build output first, so the symlink of a --link-node-modules lane and any leftover
    # cleanup trash are gone before git is asked to remove the worktree (that is what used
    # to make `git worktree remove` need --force here).
    swept=0
    if disk_clean_role "$role" all 1 && [ -n "$DISK_CLEANED" ]; then
      swept="$DISK_FREED_KB"
      say "$role: took $(human_size "$swept") of build output first ($DISK_CLEANED)"
      disk_cache_adjust "$swept"
    fi
    # Where the branch is, on the screen and in the machine-wide ledger, BEFORE it is deleted:
    # with --force this is the command that discards work on purpose, and the sha is what
    # turns a second thought into `git branch <name> <sha>` instead of `git fsck`.
    lane_tip_say "" "$role"
    lane_removal_log "$role" remove "$((swept + $(disk_kb "$path")))" "$branch" "$LANE_TIP" \
      "teamctl remove (force=$force): $dirty uncommitted, $unmerged unmerged" ||
      warn "$role: the removal could not be written to $(short_path "$(disk_reclaim_log_file)"); the sha above is the only record of it"
    # A record is a file anyone can edit. Whatever it says, only a directory inside the
    # worktree directory of this teammate's own repository is ever deleted, and only a
    # branch teamctl created that is not checked out in that repository itself.
    kb=0
    if [ -d "$path" ]; then
      if _inside_worktrees "$path" "$(worker_trees_dir "$role")"; then
        # The whole worktree goes, node_modules and every other build directory with it,
        # so what it took is what this frees. Measured before, reported after (issue #11).
        kb="$(disk_kb "$path")"
        git_for_role "$role" worktree remove --force "$path" >/dev/null 2>&1 || /bin/rm -rf "$path"
        if [ -d "$path" ]; then kb=0; fi
        freed=$((freed + kb))
      else
        warn "$role: its record points outside $(short_path "$(worker_trees_dir "$role")") ($(short_path "$path")); that directory was left alone"
      fi
    fi
    git_for_role "$role" worktree prune 2>/dev/null || true
    # -D only here: the refusal above, or your yes, is what makes discarding it deliberate.
    if branch_is_ours "$role"; then
      if wt_branch_exists "$role" "$branch" && [ "$branch" != "$(git_for_role "$role" symbolic-ref --short -q HEAD || true)" ]; then
        git_for_role "$role" branch -D "$branch" >/dev/null 2>&1 || warn "could not delete branch $branch"
      fi
    else
      [ -z "$branch" ] || warn "$role: teamctl did not create branch '$branch'; it was left alone"
    fi
    pane="$(tm_pane_for_role "$SESSION" "$role" 2>/dev/null || true)"
    if [ -n "$pane" ]; then tmx kill-pane -t "$pane" 2>/dev/null || true; fi
    /bin/rm -f "$STATE_DIR/settings/$role.json"
    reg_delete "$role"
    event_log remove "$role" "force=$force dirty=$dirty unmerged=$unmerged freed_kb=$((kb + swept)) branch=$branch tip=$LANE_TIP"
    say "removed: $role  (worktree, branch $branch and record)$repo_note — freed $(human_size "$((kb + swept))")"
  done
  layout_apply
  disk_cache_adjust "$freed"
  lock_release
  [ -z "$holding" ] || die "nothing was removed:$holding still hold$([ "$(printf '%s' "$holding" | wc -w | tr -d ' ')" = "1" ] && printf s) work."
  founder_announce "removed $(printf '%s' "$roles" | sed 's/^ //; s/ /, /g') from"
}

_destroy_worker_artifacts() {
  local role="$1" path branch result tip
  path="$(reg_field "$role" workdir)"
  branch="$(reg_field "$role" branch)"
  tip="$(lane_tip "$role")"
  # Build output first. A project whose .gitignore does not list node_modules reports it
  # as untracked, wt_remove_if_clean then calls the worktree dirty, and the gigabytes stay
  # for ever (issue #11). Taking the allowlist first leaves a tree that is clean or really
  # dirty, and the answer below is about work again.
  if disk_clean_role "$role" all 1 && [ -n "$DISK_CLEANED" ]; then
    say "  $role: freed $(human_size "$DISK_FREED_KB") of build output ($DISK_CLEANED)"
    disk_cache_adjust "$DISK_FREED_KB"
  fi
  result=0
  wt_remove_if_clean "$role" "$path" || result=$?
  case "$result" in
    0) say "  $role: removed clean worktree $(short_path "$path")" ;;
    1)
      say "  $role: KEPT worktree (uncommitted work or in use): $(short_path "$path")"
      say "      keep its work: commit there, then merge $branch · discard it: teamctl remove $role --force"
      return 0
      ;;
    *) : ;;
  esac
  if ! wt_branch_exists "$role" "$branch"; then
    reg_delete "$role"
  elif wt_delete_branch_if_merged "$role" "$branch"; then
    # git's own -d did this, so every commit of it is still reachable from the branch it was
    # merged into. The sha is said all the same: one rule for every branch teamctl deletes.
    say "  $role: branch $branch was at $tip"
    say "  $role: deleted fully merged branch $branch"
    LANE_HEAD=""
    lane_removal_log "$role" destroy-worktrees 0 "$branch" "$tip" "teamctl destroy --worktrees: fully merged (git branch -d)" || true
    reg_delete "$role"
  elif ! branch_is_ours "$role"; then
    say "  $role: KEPT branch $branch (teamctl did not create it)"
  else
    say "  $role: KEPT branch $branch (has unmerged commits; review with: teamctl diff $role)"
    say "      keep its work: git merge $branch · discard it: teamctl remove $role --force"
  fi
  git_for_role "$role" worktree prune 2>/dev/null || true
}

# human_size <kilobytes>
human_size() {
  awk -v kb="${1:-0}" 'BEGIN { if (kb >= 1048576) printf "%.1f GB\n", kb / 1048576; else if (kb >= 1024) printf "%.0f MB\n", kb / 1024; else printf "%d KB\n", kb }'
}

# disk_kb <path>... — kilobytes on disk, 0 for what is not there
disk_kb() {
  local total=0 path size
  for path in "$@"; do
    [ -e "$path" ] || continue
    size="$(du -sk "$path" 2>/dev/null | awk '{ print $1 }')"
    total=$((total + ${size:-0}))
  done
  printf '%s\n' "$total"
}

# transcripts_dir <worktree> — where Claude Code keeps the conversations of an agent that ran
# there: a folder named after the path, every other character turned into "-"
transcripts_dir() {
  local base real
  base="$(transcripts_base)"
  real="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$base" "$(printf '%s' "$real" | LC_ALL=C sed 's|[^A-Za-z0-9]|-|g')"
}

# --- context use (status shows it; a lead reads it to decide reuse against respawn) ---
# Read from what the CLI wrote next to the worktree, never from a live process, and only
# the tail of a transcript: status must stay fast, and a half-written line must never
# break it. Every failure means "unknown", not an error.

# _ctx_of_claude <workdir> [<session-id>] — sets CTX_TOKENS ("" when nothing is readable) and CTX_REQUESTS
# from the transcript of the agent's own conversation (a record from before conversation ids: the
# newest *.jsonl of its folder): what the last assistant turn saw (its input
# plus what the prompt cache holds), and how many assistant turns with usage the tail holds.
# Also CTX_MODEL and CTX_MODEL_AT: the model of the last answer in its own conversation, and when.
_ctx_of_claude() {
  local tdir f m newest="" newest_m=0
  CTX_TOKENS="" CTX_REQUESTS="" CTX_FILE="" CTX_MODEL="" CTX_MODEL_AT=""
  if [ -n "${2:-}" ]; then
    # Its own conversation, by id. Never the newest file of the folder: every lead of a project works
    # in the same folder, and so do your own sessions, so the newest one is usually somebody else's.
    newest="$(session_transcript "$2" "$1")"
  else
    tdir="$(transcripts_dir "$1" 2>/dev/null)" || return 0
    [ -d "$tdir" ] || return 0
    for f in "$tdir"/*.jsonl; do
      [ -f "$f" ] || continue
      m="$(stat -f %m "$f" 2>/dev/null || printf 0)"
      if [ "$m" -gt "$newest_m" ]; then newest_m="$m" newest="$f"; fi
    done
  fi
  [ -n "$newest" ] || return 0
  # The file this reader opened, for a caller that wants its timestamp rather than its
  # contents (teamctl dashboard shows when the transcript was last written). Set here, so
  # there is never a second piece of code working out where an agent's transcript lives.
  CTX_FILE="$newest"
  # One pass over its tail, shared with every other reader of a transcript (lib/models.sh).
  models_transcript_tail "$newest"
  # The model is taken only from the agent's OWN conversation: the newest file of a folder may
  # be somebody else's, and teamctl models reads by conversation id too.
  if [ -n "${2:-}" ]; then CTX_MODEL="$MT_MODEL" CTX_MODEL_AT="$MT_MODEL_AT"; fi
  [ -n "$MT_TOKENS" ] || return 0
  CTX_TOKENS="$MT_TOKENS"
  CTX_REQUESTS="$MT_REQUESTS"
  return 0
}

# _ctx_of_codex <workdir> — sets CTX_TOKENS, CTX_REQUESTS and CTX_WINDOW from the newest
# rollout under the codex sessions directory (WOLFMUX_CODEX_SESSIONS, else Codex's own
# location) whose session was started with cwd = this worktree: the last token_count event
# in it, which also states the window Codex actually serves. The 25 newest rollouts are
# looked at; none of them matches, or the event shape is unknown, and nothing is reported.
_ctx_of_codex() {
  local base="${WOLFMUX_CODEX_SESSIONS:-${CODEX_HOME:-$HOME/.codex}/sessions}" f real cands stats last="" reqs=0 line meta
  CTX_TOKENS="" CTX_REQUESTS="" CTX_WINDOW="" CTX_FILE=""
  [ -d "$base" ] || return 0
  real="$(cd "$1" 2>/dev/null && pwd -P)" || return 0
  cands="$(find "$base" -type f -name 'rollout-*.jsonl' -exec stat -f '%m%t%N' {} + 2>/dev/null | sort -rn | cut -f2- | sed -n '1,25p')" || cands=""
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    meta="$(head -n 1 "$f" 2>/dev/null | "$JQ_BIN" -Rr 'fromjson? | select(.type == "session_meta") | .payload.cwd // empty' 2>/dev/null)" || meta=""
    if [ "$meta" != "$1" ] && [ "$meta" != "$real" ]; then continue; fi
    stats="$(tail -n 400 "$f" 2>/dev/null | "$JQ_BIN" -Rr '
      fromjson? | select(.type == "event_msg" and .payload.type == "token_count" and (.payload.info != null)) |
      [(.payload.info.last_token_usage.total_tokens // .payload.info.total_token_usage.total_tokens // 0),
       (.payload.info.model_context_window // 0)] | @tsv' 2>/dev/null)" || stats=""
    while IFS="$(printf '\t')" read -r line; do
      [ -n "$line" ] || continue
      reqs=$((reqs + 1))
      last="$line"
    done <<EOF
$stats
EOF
    CTX_FILE="$f" # the rollout this reader opened: its timestamp is what dashboard shows
    break         # the newest rollout of this worktree is the one
  done <<EOF
$cands
EOF
  [ -n "$last" ] || return 0
  CTX_TOKENS="$(printf '%s' "$last" | cut -f1)"
  CTX_WINDOW="$(printf '%s' "$last" | cut -f2)"
  CTX_REQUESTS="$reqs"
  return 0
}

# agent_context <workdir> <model-key> <family> [<session-id>] [<recorded-window>] [<recorded-id>] [<recorded-at>]
# Everything a view shows about one agent's context AND its model, from one read of its
# transcript. Sets CTX_TOKENS ("" = unknown), CTX_REQUESTS and CTX_WINDOW ("" = unknown). The
# window is declared by the model's provider row, by the model table (model_context_window), or
# by a model id ending in [1m] (1M); for codex the token_count event's own window wins, since
# that is the one Codex actually serves. A model whose window none of those know stays "" — not
# a 200k guess — so the caller shows tokens with no share of the wrong number.
# fable/opus/sonnet/haiku mean another model after each release, so for them the window is the
# one of the model the agent actually runs, and which model that is comes from the one resolver
# every view shares (models_running, lib/models.sh): it leaves MR_ID, MR_HOW, MR_LABEL, MR_MARK
# and MR_WINDOW behind for the caller. A model nobody can name has no window either: tokens
# alone, never a share of what the key happens to mean today.
agent_context() {
  local computed
  CTX_TOKENS="" CTX_WINDOW="" CTX_REQUESTS="0" CTX_FILE="" CTX_MODEL="" CTX_MODEL_AT=""
  # MR_*: which model it runs, by the one resolver (lib/models.sh). Args 6 and 7 are the id and
  # the time of it on its record. An agent that is not on an alias keeps its recorded id.
  MR_ID="${6:-}" MR_HOW="" MR_LABEL="" MR_MARK="" MR_WINDOW=""
  if [ "$3" = "codex" ]; then
    _ctx_of_codex "$1"
  else
    _ctx_of_claude "$1" "${4:-}"
  fi
  if models_is_alias "$2"; then
    models_running "$2" "${6:-}" "${5:-}" "${7:-}" "$CTX_MODEL" "$CTX_MODEL_AT"
    computed="$MR_WINDOW"
  else
    computed="$(model_context_window "$2" 2>/dev/null)" || computed=""
  fi
  [ -n "$CTX_WINDOW" ] || CTX_WINDOW="$computed"
  return 0
}

# _purge_report — what deleting this team means, worker by worker. Sets PURGE_AT_RISK (roles
# that hold work which exists nowhere else) and PURGE_KB.
_purge_report() {
  local role path branch dirty unmerged kb notes tdir alive repo
  PURGE_AT_RISK=""
  PURGE_KB=0
  alive=0
  if tm_session_exists "$SESSION"; then alive="$(tm_alive_count "$SESSION")"; fi
  say "team '$TEAM' of $(short_path "$ROOT")   ·   session $SESSION ($alive running)"
  say ""
  for role in $(reg_list); do
    [ "$(reg_field "$role" kind)" = "worker" ] || continue
    path="$(reg_field "$role" workdir)"
    branch="$(reg_field "$role" branch)"
    repo="$(reg_field "$role" repo)"
    dirty="$(wt_dirty_count "$path")"
    unmerged=0
    if wt_branch_exists "$role" "$branch"; then unmerged="$(git_for_role "$role" rev-list --count "HEAD..$branch" 2>/dev/null || printf 0)"; fi
    kb="$(disk_kb "$path")"
    tdir="$(transcripts_dir "$path" 2>/dev/null || true)"
    if [ "$PURGE_TRANSCRIPTS" -eq 1 ] && [ -n "$tdir" ]; then kb=$((kb + $(disk_kb "$tdir"))); fi
    PURGE_KB=$((PURGE_KB + kb))
    notes="nothing to lose"
    if [ "$dirty" != "0" ] || [ "$unmerged" != "0" ]; then
      PURGE_AT_RISK="$PURGE_AT_RISK $role"
      notes="HOLDS WORK THAT EXISTS NOWHERE ELSE"
    fi
    printf '  %s %-18s %9s   %s\n' "$WOLFMUX_WORKER_MARK" "$role" "$(human_size "$kb")" "$notes"
    printf '        %s   (branch %s%s)\n' "$(short_path "$path")" "$branch" "$([ -z "$repo" ] || printf ' in %s' "$(short_path "$repo")")"
    if [ "$unmerged" != "0" ]; then
      printf '        %s commit%s that the current branch of %s does not have:\n' "$unmerged" "$([ "$unmerged" = "1" ] || printf s)" "$(short_path "$(worker_repo "$role")")"
      report_commits "$role" "$branch" '          ' "$unmerged"
    fi
    if [ "$dirty" != "0" ]; then
      printf '        %s uncommitted file%s:\n' "$dirty" "$([ "$dirty" = "1" ] || printf s)"
      report_files "$path" '          ' "$dirty" 15
    fi
  done
  kb="$(disk_kb "$STATE_DIR/agents" "$STATE_DIR/approvals" "$STATE_DIR/settings" "$STATE_DIR/nudge" "$STATE_DIR/events.jsonl" "$STATE_DIR/meta.json" "$STATE_DIR/disk-kb")"
  PURGE_KB=$((PURGE_KB + kb))
  printf '  %-21s %9s   records, approvals, event log\n' "teamctl's state" "$(human_size "$kb")"
  say ""
  printf '  %-21s %9s   is what this frees%s\n' "total" "$(human_size "$PURGE_KB")" "$([ "$PURGE_TRANSCRIPTS" -eq 1 ] && printf ' (worktrees, and the agents'"'"' Claude Code transcripts)' || printf ' (transcripts are kept)')"
  say "  Not touched: your checkout and its branch, every branch teamctl did not create, Beads, other teams."
}

# _purge_team — the deleting itself. Every path comes from a record, so every path is checked.
_purge_team() {
  local role path branch tdir
  if tm_session_exists "$SESSION"; then
    tmx kill-session -t "=$SESSION" 2>/dev/null || true
    say "tmux session $SESSION terminated."
  fi
  for role in $(reg_list); do
    if [ "$(reg_field "$role" kind)" = "worker" ]; then
      path="$(reg_field "$role" workdir)"
      branch="$(reg_field "$role" branch)"
      # This is the path that lost work on 2026-10-13: a team was purged while a branch tip
      # was on no remote, and its three commits lived on only as dangling objects that had to
      # be found with git fsck. So before a lane goes, where its branch was is said on the
      # screen and written to the machine-wide ledger — the team's own event log is deleted a
      # few lines below, so the ledger is the only record that outlives the purge.
      lane_tip_say "  " "$role"
      lane_removal_log "$role" purge "$(disk_kb "$path")" "$branch" "$LANE_TIP" "teamctl destroy --purge" ||
        warn "$role: the removal could not be written to $(short_path "$(disk_reclaim_log_file)"); the sha above is the only record of it"
      if [ -d "$path" ]; then
        if _inside_worktrees "$path" "$(worker_trees_dir "$role")"; then
          tdir="$(transcripts_dir "$path" 2>/dev/null || true)"
          git_for_role "$role" worktree remove --force "$path" >/dev/null 2>&1 || /bin/rm -rf "$path"
          if [ "$PURGE_TRANSCRIPTS" -eq 1 ] && [ -n "$tdir" ] && [ -d "$tdir" ]; then /bin/rm -rf "$tdir"; fi
        else
          warn "$role: its record points outside $(short_path "$(worker_trees_dir "$role")") ($(short_path "$path")); that directory was left alone"
        fi
      fi
      if branch_is_ours "$role"; then
        if wt_branch_exists "$role" "$branch" && [ "$branch" != "$(git_for_role "$role" symbolic-ref --short -q HEAD || true)" ]; then
          git_for_role "$role" branch -D "$branch" >/dev/null 2>&1 || warn "could not delete branch $branch"
        fi
      fi
      git_for_role "$role" worktree prune 2>/dev/null || true
      # A teammate in another repository leaves an empty teams/<team> directory behind there.
      /bin/rmdir "$(worker_trees_dir "$role")" 2>/dev/null || true
    fi
    reg_delete "$role"
  done
  gitr worktree prune
  # The first team's directory is also the parent of the named teams: take its files, never teams/.
  /bin/rm -rf "$STATE_DIR/agents" "$STATE_DIR/approvals" "$STATE_DIR/settings" "$STATE_DIR/nudge"
  # disk-kb is the remembered size of lanes that no longer exist; leaving it behind also
  # left the team's state directory non-empty, so the rmdir of a named team did nothing.
  # disk-parked-kb is its v1.17.0 twin and arrived here the same way: it was written by
  # `teamctl teams`, not named here, and the purge stopped deleting the directory. Every
  # per-team file the disk module writes belongs on this line — tests/disk.sh checks that.
  /bin/rm -f "$STATE_DIR/events.jsonl" "$STATE_DIR/meta.json" "$STATE_DIR/disk-kb" \
    "$STATE_DIR/disk-parked-kb" "$STATE_DIR/lead-end.json"
  /bin/rmdir "$WORKTREES_DIR" 2>/dev/null || true
}

cmd_destroy() {
  local remove_worktrees=0 assume_yes=0 purge=0 force=0 role
  PURGE_TRANSCRIPTS=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --worktrees) remove_worktrees=1 ;;
      --purge) purge=1 ;;
      --force) force=1 ;;
      --keep-transcripts) PURGE_TRANSCRIPTS=0 ;;
      --yes | -y) assume_yes=1 ;;
      *) die_usage "usage: teamctl destroy [--worktrees | --purge [--force] [--keep-transcripts]] [--yes]" ;;
    esac
    shift
  done
  [ "$force" -eq 0 ] || [ "$purge" -eq 1 ] || die_usage "--force belongs to --purge (destroy alone never discards work)"
  require_tools
  load_project
  require_manager destroy
  SESSION="$(session_name_for_project)"
  if [ "$purge" -eq 1 ]; then
    # Look first, ask, and only then touch anything: a refusal leaves the team running.
    say "DELETE a whole team: its session, every worker's worktree and its branch, its records."
    _purge_report
    if [ -n "$PURGE_AT_RISK" ] && [ "$force" -ne 1 ]; then
      say ""
      say "Keep that work first: commit in the worktree, then git merge <branch>.  Or delete it anyway: add --force"
      confirm "Delete team '$TEAM' INCLUDING the uncommitted and unmerged work of:$PURGE_AT_RISK ?" ||
        die "nothing was deleted; team '$TEAM' is untouched."
    elif [ "$force" -ne 1 ] && [ "$assume_yes" -ne 1 ]; then
      confirm "Delete team '$TEAM'?" || die "nothing was deleted (pass --yes to skip this question)"
    fi
    ensure_state_dirs
    lock_acquire
    _purge_team
    lock_release
    if [ "$TEAM" != "$WOLFMUX_DEFAULT_TEAM" ]; then /bin/rmdir "$STATE_DIR" 2>/dev/null || true; fi # only when empty
    say "team '$TEAM' is gone. Freed about $(human_size "$PURGE_KB")."
    say "(commits of the deleted branches leave .git when git next collects garbage; now: git gc --prune=now)"
    founder_record_purge
    founder_announce destroyed
    return 0
  fi
  say "About to stop every agent of this project's team ($SESSION)."
  say "Kept in all cases: your source files, every branch whose work is not all in main and every commit on it, credentials, Beads data."
  if [ "$remove_worktrees" -ne 1 ] && [ "$(policy_get auto-reclaim)" = "on" ]; then
    say "A lane whose task is closed and whose work is all in main is taken off the books (policy auto-reclaim); where its branch was is printed first."
  fi
  if [ "$remove_worktrees" -eq 1 ]; then
    say "--worktrees: clean worker worktrees are removed; fully merged branches teamctl created are deleted."
  fi
  if [ "$assume_yes" -ne 1 ]; then
    confirm "Continue?" || die "aborted (pass --yes to skip this question)"
  fi
  ensure_state_dirs
  lock_acquire
  # Before the session goes: run inside the team it ends, this command takes the hangup at
  # kill-session, and nothing after that line may run (common.sh). Evidence only, as in
  # cmd_stop: a plain destroy keeps every lane that holds work, and never finishes a team.
  team_end_note destroy
  if tm_session_exists "$SESSION"; then
    tmx kill-session -t "=$SESSION"
    say "tmux session $SESSION terminated."
  else
    say "no running tmux session for this project."
  fi
  for role in $(reg_list); do
    reg_set "$role" pane_id "" state stopped
  done
  if [ "$remove_worktrees" -eq 1 ]; then
    for role in $(reg_list); do
      if [ "$(reg_field "$role" kind)" = "worker" ]; then _destroy_worker_artifacts "$role"; fi
    done
    gitr worktree prune
  else
    # The second path that parks lanes, and the one that parks them in bulk: this form ends
    # the session and keeps every worktree, so without the sweep each lane sat on its whole
    # node_modules until somebody ran prune. (--worktrees above sweeps in
    # _destroy_worker_artifacts, before it decides what to remove.)
    for role in $(reg_list); do
      [ "$(reg_field "$role" kind)" = "worker" ] || continue
      if disk_park_sweep "$role" destroy; then
        say "  $role: freed $(human_size "$DISK_FREED_KB") of build output ($DISK_CLEANED)"
      else
        say "  $role: kept its build output ($PARK_SWEEP_WHY)"
      fi
    done
  fi
  reg_delete "$WOLFMUX_LEAD_ROLE"
  event_log destroy "" "worktrees=$remove_worktrees"
  lock_release
  if [ "$remove_worktrees" -ne 1 ]; then
    # Every lane is parked now, so every lane is asked whether it is finished (lib/reclaim.sh),
    # each one aloud: a team that has ended has nobody left to park a lane, so this is the
    # last automatic chance a finished lane of it gets, and a lane that stays has to say what
    # it is holding before the team's session is gone. After the lock, as in cmd_stop, and
    # through reclaim_after_park as there: the team has ended, and this command says so
    # whether the check failed or exited.
    reclaim_after_park "" destroy 1 "  "
    say "worktrees kept, except a lane reclaimed above: its task was closed and its work is all in main. What every other lane holds, and why: teamctl reclaim --dry-run · clean ones go with: teamctl destroy --worktrees · one that still holds work: teamctl remove <role> --force"
  fi
  founder_announce ended
}

# founder_record_purge: the log of a team that was purged went with it. An agent that deleted a team it
# founded leaves that in the log of its own team.
founder_record_purge() {
  local victim="$TEAM" own
  [ -n "${FOUNDER_ACTING:-}" ] || return 0
  own="$(caller_team)"
  (team_paths "${own:-$WOLFMUX_DEFAULT_TEAM}" && event_log destroy "" "purged team $victim, which it founded") || true
}

# notify_lead <spawn|approval|policy> <args...> — a fixed one-line notice FOR the lead.
# Every interpolated value is a validated role, a model label from the model table, an
# approval id or a policy word; nothing free-form is ever typed.
#
# Since v1.15.0 the notice is FILED first (lib/inbox.sh) and typed only where typing is
# still the right channel. The lead's pane is the human's conversation, so with somebody
# attached nothing goes into it: the status-bar badge carries the notice, the agent is
# given it by its Stop or UserPromptSubmit hook, and the human can open it with prefix N.
# An approval is the one exception, because a WORKER is blocked on the answer — see
# WOLFMUX_INBOX_APPROVAL_TYPE.
#
# This is the one notice path v1.16.1 did NOT change. A BEADS notice for an attached lead
# now waits for that pane to go quiet rather than stopping at the file (_nudge_one, and
# ADR-0029 says why), because a bead for an idle agent has no other way in. These three
# are addressed to the HUMAN first — a teammate appeared, a policy moved, somebody wants
# permission — and the badge, the banner and prefix N all reach a human who is sitting
# right there. Giving them the same treatment is a separate decision on a separate path.
#
#   0  typed    3  parked for a busy pane    4  filed only    1  no pane to notify
notify_lead() {
  local kind="$1" pane text cap
  pane="$(tm_pane_for_role "$SESSION" "$WOLFMUX_LEAD_ROLE")"
  [ -n "$pane" ] && [ "$(tm_pane_state "$pane")" = "running" ] || return 1
  case "$kind" in
    spawn)
      known_role_name "$2" && known_role_name "$3" || return 1
      text="[wolfmux] Team change: $2 spawned teammate $3 ($4). Run: teamctl status"
      ;;
    approval)
      valid_approval_id "$2" && known_role_name "$3" || return 1
      text="[wolfmux] Permission request $2 from $3. Run: teamctl approvals"
      ;;
    policy)
      # branch-template's value is free text, so only its name is ever typed.
      if [ "$2" = "branch-template" ]; then
        text="[wolfmux] Policy changed: branch-template. Run: teamctl policy"
      else
        policy_valid "$2" "$3" || return 1
        text="[wolfmux] Policy changed: $2 = $3. Run: teamctl policy"
      fi
      ;;
    *) return 1 ;;
  esac
  cap="$WOLFMUX_NUDGE_DEFER_MAX"
  if [ "$kind" = "approval" ]; then cap="$WOLFMUX_NUDGE_APPROVAL_DEFER_MAX"; fi
  # The record, before anything is decided about typing: from here on nothing can lose
  # the notice. The bead or the approval stays where it is too.
  inbox_add "$WOLFMUX_LEAD_ROLE" "$kind" "$text"
  # v1.20.0, and ahead of everything below, the approval overrides included: with a human
  # attached the lead's pane is his, and under the default policy nothing is typed into it.
  # An approval still gets the bell on the status bar and the banner, and the lead's agent
  # gets the notice from its own hooks. WOLFMUX_INBOX_APPROVAL_TYPE (grace, always) applies
  # again only under human-pane-typing idle.
  if inbox_keep_off_human_pane "$WOLFMUX_LEAD_ROLE" "$pane"; then
    event_log inbox-filed "$WOLFMUX_LEAD_ROLE" "$kind (human-pane-typing=off: $INBOX_HUMAN_REASON)"
    inbox_stall_notify "$WOLFMUX_LEAD_ROLE" "$kind"
    return 4
  fi
  if ! inbox_type_allowed "$WOLFMUX_LEAD_ROLE"; then
    # An approval blocks a worker until the lead decides, so it may not get slower than
    # it was in v1.14.0. grace: file it, and type it after all if it is still unread
    # WOLFMUX_INBOX_APPROVAL_GRACE seconds later. always: type it now. never: the badge.
    #
    # BUT off means off. This override used to sit outside the WOLFMUX_NUDGE_TYPE
    # decision, so `off` plus an attached client plus a worker asking permission still
    # put a line in the human's conversation 20 s later — while USAGE.md, the manual and
    # this library's own header all promised `off` types into nobody, ever. A knob called
    # off that still types is worse than no knob, so the code follows the documents.
    if [ "$WOLFMUX_NUDGE_TYPE" = "off" ]; then
      event_log inbox-filed "$WOLFMUX_LEAD_ROLE" "$kind (nudge-type=off, nothing is ever typed)"
      inbox_stall_notify "$WOLFMUX_LEAD_ROLE" "$kind"
      return 4
    fi
    if [ "$kind" = "approval" ] && [ "$WOLFMUX_INBOX_APPROVAL_TYPE" = "always" ]; then
      : # fall through to the typed path below
    else
      if [ "$kind" = "approval" ] && [ "$WOLFMUX_INBOX_APPROVAL_TYPE" = "grace" ]; then
        _inbox_approval_grace_start "$WOLFMUX_LEAD_ROLE" "$pane" "$text" "$cap" "$2"
        event_log inbox-filed "$WOLFMUX_LEAD_ROLE" "$kind (unread after ${WOLFMUX_INBOX_APPROVAL_GRACE}s is typed after all)"
      else
        event_log inbox-filed "$WOLFMUX_LEAD_ROLE" "$kind (nudge-type=$WOLFMUX_NUDGE_TYPE, a client is attached)"
      fi
      inbox_stall_notify "$WOLFMUX_LEAD_ROLE" "$kind"
      return 4
    fi
  fi
  _notify_type_or_park "$WOLFMUX_LEAD_ROLE" "$pane" "$text" "$cap" "$kind"
}

# _notice_pane_busy <role> <pane> [<idle-seconds>] — 0 when a notice may NOT be typed into
# this pane right now. tm_pane_human_busy (a keystroke, a half-typed line, copy mode), plus
# the v1.20.0 rule: under policy human-pane-typing off, a pane a human is watching is busy
# for as long as he watches it (inbox_human_pane). Every typed path asks THIS, right before
# each line, so a human who attaches, or switches to the pane, while a notice is parked is
# never typed in front of. TM_BUSY_REASON says why, as tm_pane_human_busy does.
_notice_pane_busy() {
  if inbox_keep_off_human_pane "$1" "$2"; then
    TM_BUSY_REASON="a human is watching this pane: $INBOX_HUMAN_REASON"
    return 0
  fi
  tm_pane_human_busy "$2" "${3:-}"
}

# _notify_type_or_park <role> <pane> <text> <cap> <kind> — type one fixed notice into a
# pane, or park it for the one waiter if a human may be typing in there. Unchanged
# v1.14.0 machinery, lifted out of notify_lead so the approval-grace path below uses
# exactly the same code rather than a second copy of it.
#   0 typed    3 parked (or dropped for want of a marker)
_notify_type_or_park() {
  local role="$1" pane="$2" text="$3" cap="$4" kind="$5" tries=0 locked=0 fresh=0
  # Serialize with other notices for this role so two lines never interleave.
  while [ "$tries" -lt 30 ]; do
    if nudge_begin "$role"; then
      locked=1
      break
    fi
    tries=$((tries + 1))
    sleep 0.2
  done
  # A marker whose waiter died must not swallow this notice (see nudge_pending_reap).
  if [ "$locked" -eq 1 ]; then nudge_pending_reap "$role" || true; fi
  # The lead is a pane a human sits in front of: never type over a half-typed line.
  # Each of these notices names its own event, so they queue instead of collapsing.
  # Without the lock we never type either: another notifier may be mid-line right now.
  if [ "$locked" -eq 0 ] || _notice_pane_busy "$role" "$pane"; then
    if ! nudge_pending_exists "$role"; then
      if nudge_pending_open "$role"; then fresh=1; fi
    fi
    if nudge_pending_exists "$role"; then
      nudge_pending_put_line "$role" "$text" || true
      nudge_pending_put_cap "$role" "$cap" || true
      if [ "$locked" -eq 1 ]; then nudge_end "$role"; fi
      if [ "$fresh" -eq 1 ]; then _nudge_defer_start "$role" "$pane"; fi
      event_log notify-deferred "$role" "$kind (${TM_BUSY_REASON:-no lock}, cap ${cap}s)"
      return 3
    fi
    # No marker and none could be made: say so rather than type over the human.
    if [ "$locked" -eq 1 ]; then nudge_end "$role"; fi
    event_log notify-dropped "$role" "$kind (pane busy, no marker)"
    return 3
  fi
  tm_type_line "$pane" "$text"
  inbox_mark_typed "$role" "$text" # the agent has it: no hook may hand it over again
  nudge_mark "$role"
  nudge_end "$role"
  return 0
}

# _inbox_approval_grace_start <role> <pane> <text> <cap> <approval-id> — an approval is
# the ONE notice that can still put a line in the human's conversation, and a blocked
# worker is the reason: the request holds that worker until the lead answers, and the
# lead's own WOLFMUX_NUDGE_APPROVAL_DEFER_MAX is 60 s. So the badge gets its louder mark
# at once, and if the request is still PENDING WOLFMUX_INBOX_APPROVAL_GRACE seconds later
# it is typed after all. Fully detached, like the nudge waiter, and for the same reasons:
# macOS ships no setsid, so it ignores HUP, INT and TERM instead.
_inbox_approval_grace_start() {
  (
    set +e
    trap '' HUP INT TERM
    _inbox_approval_grace_wait "$1" "$2" "$3" "$4" "$5" >/dev/null 2>&1 &
  )
  return 0
}

# _inbox_approval_grace_wait <role> <pane> <text> <cap> <approval-id>
#
# What cancels the typing is the request no longer being PENDING — not the human having
# looked at it. The timer exists because a worker is blocked, so the only thing that
# should stop it is the thing that unblocks the worker: approved, denied or expired. A
# glance at the popup unblocks nobody, and `prefix N` prints --all and marks every role's
# notices seen, so "has the human looked?" let a glance at a WORKER's line cancel the
# typing of an approval the human had never read (reviewer F5). Asking the approvals
# store whether it is still pending replaces that proxy with the state itself.
#
# If the store cannot be read, this FAILS TOWARDS TYPING: a stalled worker is the harm,
# one line in a pane is the cost.
_inbox_approval_grace_wait() {
  local role="$1" pane="$2" text="$3" cap="$4" id="$5" waited=0 status
  while [ "$waited" -lt "$WOLFMUX_INBOX_APPROVAL_GRACE" ]; do
    sleep 1
    waited=$((waited + 1))
    if [ -n "$id" ]; then
      status="$(approval_field "$id" status 2>/dev/null || true)"
      case "$status" in
        approved | denied | expired)
          event_log inbox-approval-settled "$role" "$id is $status after ${waited}s; nothing was typed"
          return 0
          ;;
      esac
      # anything else — pending, or a store we could not read — keeps the timer running
    fi
    [ "$(tm_pane_state "$pane")" = "running" ] || {
      event_log inbox-approval-pane-gone "$role" "pane not running after ${waited}s; nothing was typed"
      return 0
    }
  done
  # Still pending. Type it, through the same busy-and-park machinery as ever.
  _notify_type_or_park "$role" "$pane" "$text" "$cap" approval || true
  event_log inbox-approval-grace "$role" "$id still pending after ${WOLFMUX_INBOX_APPROVAL_GRACE}s: typed"
  return 0
}

# --- teamctl nudge <role>|--all [--id <bead>] [--quiet] ------------------------------------------
# The ONLY thing ever typed into an agent's prompt: one short, fixed line. Task and
# message bodies stay in Beads, so there is nothing to quote, escape or truncate.
_nudge_text() { # <identity> [bead]
  if [ -n "${2:-}" ]; then
    printf '[wolfmux] Beads update for %s (%s). Run: bd show %s -- then: bd list --assignee %s --status open,in_progress,blocked --include-infra\n' "$1" "$2" "$2" "$1"
  else
    printf '[wolfmux] Beads update for %s. Run: bd list --assignee %s --status open,in_progress,blocked --include-infra\n' "$1" "$1"
  fi
}

_nudge_one() {
  local role="$1" bead="$2" pane text who idle_window watched=0
  # never yourself: the same role in the same team
  if [ "$role" = "${TEAM_ROLE:-}" ] && [ "$TEAM" = "${WOLFMUX_TEAM:-$WOLFMUX_DEFAULT_TEAM}" ]; then return 0; fi
  who="$(team_identity "$TEAM" "$role")"
  pane="$(tm_pane_for_role "$SESSION" "$role")"
  [ -n "$pane" ] && [ "$(tm_pane_state "$pane")" = "running" ] || return 1
  # The record first, so nothing below can lose the notice (lib/inbox.sh). The bead
  # itself is in Beads either way; this is what the badge counts and what the agent's
  # own Stop and UserPromptSubmit hooks hand over.
  inbox_add "$role" beads "$(_nudge_text "$who" "$bead")"
  # Who may be typed into at all, and under which rule. Typing that is off by the knob
  # (off, workers) stops here: the badge, the hooks and prefix N carry the notice.
  #
  # The attached LEAD is NOT that case. Its pane is the human's conversation, so the
  # notice waits for that conversation to be quiet — but it does WAIT, in the marker,
  # rather than stopping here. v1.15.0 returned at this point and that is issue #12: an
  # idle agent has no turn boundary left, so its Stop hook never fires and a filed
  # notice was never handed over at all. The only thing that changes for the lead is the
  # width of the quiet it needs (WOLFMUX_NUDGE_LEAD_IDLE); everything below — the
  # debounce, the one waiter, the collapse, inbox_mark_typed — is the same machinery
  # v1.14.0 used, in the order v1.14.0 used it.
  idle_window="$WOLFMUX_NUDGE_HUMAN_IDLE"
  NUDGE_FILED_WHY="nothing is ever typed into ${role}'s pane (WOLFMUX_NUDGE_TYPE=$WOLFMUX_NUDGE_TYPE)"
  if ! inbox_type_allowed "$role"; then
    if ! inbox_type_when_idle "$role"; then
      event_log inbox-filed "$role" "${bead:-no bead} (nudge-type=$WOLFMUX_NUDGE_TYPE, nothing is typed into this pane)"
      inbox_stall_notify "$role" beads
      return 4
    fi
    watched=1
    idle_window="$WOLFMUX_NUDGE_LEAD_IDLE"
  fi
  # v1.20.0: a pane a human is watching is not typed into at all, quiet or not, unless he
  # has asked for the v1.16.1 rule (policy human-pane-typing idle). Filed only: the agent
  # gets it from its own Stop and UserPromptSubmit hooks. See inbox_human_pane.
  if inbox_keep_off_human_pane "$role" "$pane"; then
    NUDGE_FILED_WHY="a human is watching ${role}'s pane ($INBOX_HUMAN_REASON) and policy human-pane-typing is off"
    event_log inbox-filed "$role" "${bead:-no bead} (human-pane-typing=off: $INBOX_HUMAN_REASON)"
    inbox_stall_notify "$role" beads
    return 4
  fi
  nudge_begin "$role" || return 2
  # A marker whose waiter died must not swallow this role's nudges for ever: reap it
  # before looking, while the per-role lock is held (see nudge_pending_reap).
  if nudge_pending_reap "$role"; then event_log nudge-defer-reaped "$role" "waiter gone"; fi
  # A notice is already waiting for this pane to go idle: add this bead to it and
  # let the one waiter deliver. Several queued nudges collapse into ONE line.
  if nudge_pending_exists "$role"; then
    nudge_pending_put_bead "$role" "$bead" || true
    nudge_pending_put_idle "$role" "$idle_window" || true
    nudge_end "$role"
    # The human hears about a watched notice that could not reach the agent now, once
    # per WOLFMUX_INBOX_STALL_NOTIFY_DEBOUNCE — the same banner v1.15.0 raised when it
    # filed. A burst collapses into one, because the debounce is what suppresses the
    # rest, not this branch being quiet.
    [ "$watched" -eq 0 ] || inbox_stall_notify "$role" beads
    return 3
  fi
  # Notified moments ago: one notice covers a burst of bead events, because the
  # notice always ends with the full inbox command.
  if [ $(($(now_epoch) - $(nudge_last "$role"))) -lt "$WOLFMUX_NUDGE_DEBOUNCE" ]; then
    nudge_end "$role"
    return 2
  fi
  # A human may be typing in there. Park the notice and wait instead of gluing it
  # onto their half-typed line. The lock is NOT held across the wait.
  if _notice_pane_busy "$role" "$pane" "$idle_window"; then
    if nudge_pending_open "$role"; then
      nudge_pending_put_bead "$role" "$bead" || true
      nudge_pending_put_idle "$role" "$idle_window" || true
      nudge_end "$role"
      _nudge_defer_start "$role" "$pane"
      event_log nudge-deferred "$role" "$bead (${TM_BUSY_REASON:-busy})"
    elif nudge_pending_exists "$role"; then
      # A waiter appeared between the two checks: let it carry this bead too.
      nudge_pending_put_bead "$role" "$bead" || true
      nudge_pending_put_idle "$role" "$idle_window" || true
      nudge_end "$role"
    else
      nudge_end "$role"
      event_log nudge-dropped "$role" "$bead (pane busy, no marker)"
    fi
    [ "$watched" -eq 0 ] || inbox_stall_notify "$role" beads
    return 3
  fi
  text="$(_nudge_text "$who" "$bead")"
  nudge_mark "$role"
  # The 300 ms between the text and the Enter inside tm_type_line is a window: a human
  # who had been quiet for $idle_window seconds could start typing inside it and have
  # their first keystrokes land after the notice. It stays open, because closing it
  # needs tmux to tell us a key arrived while we were mid-line, and there is no such
  # channel. The queued path below does NOT accept it: it re-checks per line.
  tm_type_line "$pane" "$text"
  inbox_mark_typed "$role" "$text" # the agent has it: no hook may hand it over again
  if [ "$watched" -eq 0 ]; then
    event_log nudge "$role" "$bead"
  else
    # Worth its own event: this is the line that used to be filed and never handed over.
    event_log nudge "$role" "$bead (a client is attached; the pane was quiet for ${idle_window}s)"
  fi
  nudge_end "$role"
}

# _nudge_defer_start <role> <pane> — the one waiter for a role, fully detached: the
# caller (a Beads hook, already backgrounded) must never wait on it and nothing it
# does may reach the caller's terminal.
_nudge_defer_start() {
  # errexit off inside the waiter: one tmux read that fails in passing must not
  # abandon a notice somebody is waiting for.
  #
  # macOS ships no setsid(1), so the waiter is kept alive the way that does work here:
  # it ignores HUP, INT and TERM, so closing the terminal that ran teamctl, or a Ctrl-C
  # in it, cannot kill it. A killed waiter leaves its marker behind, and before the reap
  # (nudge_pending_reap) that marker swallowed every later notice for the role.
  (
    set +e
    trap '' HUP INT TERM
    _nudge_defer_wait "$1" "$2" >/dev/null 2>&1 &
  )
  return 0
}

# _nudge_defer_wait <role> <pane> — look again every WOLFMUX_NUDGE_RETRY seconds for at
# most the marker's cap (WOLFMUX_NUDGE_DEFER_MAX, or less for an approval notice). It
# looks BEFORE the first sleep, so a pane that is already idle is notified at once.
# First look that comes back idle: deliver what the marker holds, exactly once, and
# remove it. On expiry: remove it and log that. Nothing is lost either way, because
# every notice ends with the agent's own inbox command.
_nudge_defer_wait() {
  local role="$1" pane="$2" who waited=0 tries bead line delivered busy_again cap idlew
  who="$(team_identity "$TEAM" "$role")"
  while :; do
    nudge_pending_exists "$role" || return 0 # someone else cleaned up
    nudge_pending_beat "$role"
    cap="$(nudge_pending_cap "$role" "$WOLFMUX_NUDGE_DEFER_MAX")"
    case "$cap" in "" | *[!0-9]*) cap="$WOLFMUX_NUDGE_DEFER_MAX" ;; esac
    # Read with the cap and for the same reason: the marker, not this process, says how
    # quiet the pane must be. A notice parked for the lead's own pane keeps its wider
    # window even if the waiter was started by a worker-rule notice (nudge_pending_idle).
    idlew="$(nudge_pending_idle "$role" "$WOLFMUX_NUDGE_HUMAN_IDLE")"
    case "$idlew" in "" | *[!0-9]*) idlew="$WOLFMUX_NUDGE_HUMAN_IDLE" ;; esac
    if [ "$waited" -ge "$cap" ]; then break; fi
    if [ "$(tm_pane_state "$pane")" != "running" ]; then
      nudge_pending_clear "$role"
      event_log nudge-defer-dropped "$role" "pane ended after ${waited}s"
      return 0
    fi
    if _notice_pane_busy "$role" "$pane" "$idlew"; then
      sleep "$WOLFMUX_NUDGE_RETRY"
      waited=$((waited + WOLFMUX_NUDGE_RETRY))
      continue
    fi
    tries=0
    until nudge_begin "$role"; do
      tries=$((tries + 1))
      [ "$tries" -lt 30 ] || break
      sleep 0.2
    done
    delivered=0 busy_again=0
    # Fixed notices first, in the order they happened; each names its own event. The
    # pane is asked again before EVERY line, because the moment a notice appears is
    # exactly when a human starts typing, and each line carries its own 300 ms window.
    # Each line leaves the marker as it is typed, so stopping here, or being killed
    # mid-delivery, can never re-send what already went out.
    while nudge_pending_has_lines "$role"; do
      if _notice_pane_busy "$role" "$pane" "$idlew"; then
        busy_again=1
        break
      fi
      line="$(nudge_pending_shift_line "$role")" || break
      [ -n "$line" ] || continue
      tm_type_line "$pane" "$line"
      inbox_mark_typed "$role" "$line" # only this line: the rest may still need a hook
      delivered=$((delivered + 1))
    done
    if [ "$busy_again" -eq 0 ] && nudge_pending_has_bead "$role"; then
      if _notice_pane_busy "$role" "$pane" "$idlew"; then
        busy_again=1
      else
        bead="$(nudge_pending_bead "$role")"
        line="$(_nudge_text "$who" "$bead")"
        tm_type_line "$pane" "$line"
        inbox_mark_typed "$role" "$line"
        delivered=$((delivered + 1))
        event_log nudge "$role" "${bead:-collapsed} (waited ${waited}s)"
      fi
    fi
    if [ "$delivered" -gt 0 ]; then nudge_mark "$role"; fi
    # Busy part-way through: leave the rest in the marker and keep waiting for it.
    if [ "$busy_again" -eq 1 ]; then
      nudge_end "$role"
      event_log nudge-defer-partial "$role" "typed ${delivered}, rest still waiting (${TM_BUSY_REASON:-busy})"
      sleep "$WOLFMUX_NUDGE_RETRY"
      waited=$((waited + WOLFMUX_NUDGE_RETRY))
      continue
    fi
    nudge_pending_clear "$role"
    nudge_end "$role"
    [ "$delivered" -gt 0 ] || event_log nudge-defer-empty "$role" "marker held nothing"
    return 0
  done
  nudge_pending_clear "$role"
  event_log nudge-defer-expired "$role" "gave up after ${waited}s; the bead is still in the inbox"
  return 0
}

cmd_nudge() {
  local role="" bead="" quiet=0 all=0 target failed=0 shown_cap
  NUDGE_FILED_WHY="nothing is ever typed into that pane (WOLFMUX_NUDGE_TYPE=$WOLFMUX_NUDGE_TYPE)" # _nudge_one says which rule
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --quiet | -q) quiet=1 ;;
      --all) all=1 ;;
      --id)
        [ "$#" -ge 2 ] || die_usage "--id needs a bead id"
        bead="$2"
        shift
        ;;
      -*) die_usage "unknown option for nudge: $1" ;;
      *) role="$1" ;;
    esac
    shift
  done
  # A Beads name says which team: "review.backend" is backend of team review.
  case "$role" in
    *.*)
      identity_split "$role"
      if ! valid_team_name "$ID_TEAM"; then
        if [ "$quiet" -eq 1 ]; then return 0; fi
        die_usage "invalid team in '$role'"
      fi
      WOLFMUX_TEAM_ARG="$ID_TEAM"
      role="$ID_ROLE"
      ;;
  esac
  # Called from Beads hooks for every assignee, including humans and roles that
  # are not running: in quiet mode "nothing to notify" is success, not an error.
  if [ "$quiet" -eq 1 ]; then
    [ -n "$TMUX_BIN" ] && [ -n "$JQ_BIN" ] && [ -n "$GIT_BIN" ] || return 0
    ROOT="$(resolve_root 2>/dev/null)" || return 0
    PROJECT_KEY="$(project_key "$ROOT")"
    PROJECT_STATE="$WOLFMUX_DATA/state/$PROJECT_KEY"
    PROJECT_TREES="$WOLFMUX_DATA/worktrees/$PROJECT_KEY"
    # The assignee's name decides the team; a plain name belongs to the first team.
    team_paths "${WOLFMUX_TEAM_ARG:-$WOLFMUX_DEFAULT_TEAM}"
    [ -d "$STATE_DIR" ] || return 0
    SESSION="$(session_name_for_project)"
    tm_session_exists "$SESSION" || return 0
  else
    require_tools
    load_project
    require_session
  fi
  [ -z "$bead" ] || valid_bead_id "$bead" || bead=""
  if [ "$all" -eq 1 ]; then
    for target in $(reg_list); do _nudge_one "$target" "$bead" || true; done
    return 0
  fi
  if [ "$quiet" -eq 1 ]; then
    known_role_name "$role" || return 0
    reg_exists "$role" || return 0
  else
    require_role_arg "$role"
    reg_exists "$role" || die "no such agent: $role"
  fi
  _nudge_one "$role" "$bead" || failed=$?
  if [ "$quiet" -eq 1 ]; then return 0; fi
  case "$failed" in
    0) say "notified: $role" ;;
    2) say "skipped: $role was notified moments ago (debounce ${WOLFMUX_NUDGE_DEBOUNCE}s)" ;;
    3)
      # The marker's own cap, not the global: an approval parked in this marker lowers it
      # to WOLFMUX_NUDGE_APPROVAL_DEFER_MAX, and that is when this notice really expires.
      shown_cap="$(nudge_pending_cap "$role" "$WOLFMUX_NUDGE_DEFER_MAX")"
      case "$shown_cap" in "" | *[!0-9]*) shown_cap="$WOLFMUX_NUDGE_DEFER_MAX" ;; esac
      say "deferred: ${role}'s pane is busy (${TM_BUSY_REASON:-a notice is already waiting}). The notice follows by itself as soon as that pane is idle (it gives up after ${shown_cap}s; the bead stays in the inbox either way)."
      return 3
      ;;
    4)
      say "filed: $NUDGE_FILED_WHY. The notice is in its inbox: the status bar counts it, the agent is given it by its own Stop hook when its turn ends or when somebody prompts it, and you can read it now with: teamctl inbox $role"
      return 4
      ;;
    *) die "'$role' has no running pane (its beads are waiting in Beads; start it with: teamctl restart $role)" ;;
  esac
}
