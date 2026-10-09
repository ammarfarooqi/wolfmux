#!/bin/bash
# agents.sh — agent lifecycle: start, spawn, run, stop, restart, destroy, nudge.
#
# Model-neutral on purpose: a lead is "whatever launcher the model table names",
# and workers neither know nor care whether the lead is Fable or Astra.

WOLFMUX_NUDGE_DEBOUNCE="${WOLFMUX_NUDGE_DEBOUNCE:-3}"
# Nothing is ever typed into a pane a human may be typing in: the notice waits.
WOLFMUX_NUDGE_COLLISION_CHECK="${WOLFMUX_NUDGE_COLLISION_CHECK:-1}" # 0 brings back the old blind typing
WOLFMUX_NUDGE_HUMAN_IDLE="${WOLFMUX_NUDGE_HUMAN_IDLE:-5}"           # seconds since the last keystroke that still count as "at the keyboard"
WOLFMUX_NUDGE_RETRY="${WOLFMUX_NUDGE_RETRY:-3}"                     # how often a waiting notice looks again
WOLFMUX_NUDGE_DEFER_MAX="${WOLFMUX_NUDGE_DEFER_MAX:-600}"           # how long it waits before giving up
# An approval notice is worthless once the worker has stopped waiting for the decision
# (WOLFMUX_APPROVAL_TIMEOUT, also 600), so it gets its own, shorter cap.
WOLFMUX_NUDGE_APPROVAL_DEFER_MAX="${WOLFMUX_NUDGE_APPROVAL_DEFER_MAX:-60}"
# ":-" substitutes for unset and empty, so an explicit 0 survives it. sleep 0 with
# waited=$((waited + 0)) is a waiter that spins on tmux for ever and never expires.
case "$WOLFMUX_NUDGE_RETRY" in "" | *[!0-9]*) WOLFMUX_NUDGE_RETRY=3 ;; esac
[ "$WOLFMUX_NUDGE_RETRY" -ge 1 ] || WOLFMUX_NUDGE_RETRY=1

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
  "$JQ_BIN" -n --arg role "$1" --arg kind "$2" --arg model "$3" --arg label "$MODEL_LABEL" \
    --arg family "$MODEL_FAMILY" --arg launcher "$launcher" --arg workdir "$4" --arg branch "$5" \
    --arg base_ref "$6" --arg base_commit "$7" --arg kickoff "$8" --arg now "$(now_iso)" \
    --arg spawned_by "${9:-operator}" --arg permissions "$permissions" --arg model_id "$MODEL_ID" --arg billing "$MODEL_BILLING" \
    --arg repo "${10:-}" --arg branch_created "${11:-0}" --arg session_id "$session_id" \
    '{role: $role, kind: $kind, model: $model, model_id: $model_id, label: $label, family: $family, billing: $billing, launcher: $launcher,
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
      if ! founder_may_act; then
        warn "team '$TEAM' already exists and has its own lead ($(team_identity "$TEAM" "$WOLFMUX_LEAD_ROLE")). Message it; you do not manage it$(is_founder && printf ' (%s)' "$FOUNDER_HINT" || true)."
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
  [ -n "$model" ] && model_info "$model" ||
    die_usage "usage: teamctl start <fable|astra|…> [--no-attach] [--continue] [--resume <session-id>] [--lead-permissions skip|ask] [--worker-permissions skip|lead|ask] [--worker-spawn on|off]   (models: $WOLFMUX_MODEL_KEYS)"
  require_metered_ok
  require_tools
  # start never guesses between teams: the one you name, else the first one.
  WOLFMUX_TEAM_ARG="${WOLFMUX_TEAM_ARG:-$WOLFMUX_DEFAULT_TEAM}"
  load_project
  require_pin "$pin" "$MODEL_FAMILY" "$WOLFMUX_LEAD_ROLE"
  founder="$(start_permitted)" || exit 77
  # An agent acting on a team it did not found today is a founder bringing one back: it is announced and logged as that.
  if [ "$founder" != "operator" ]; then EVENT_BY="$founder"; fi
  if [ "$founder" != "operator" ] && founder_may_act; then FOUNDER_ACTING="$founder"; fi
  wt_require_commit "$ROOT"
  ensure_state_dirs
  beads_ensure "$beads"
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
  if [ -n "${FOUNDER_ACTING:-}" ]; then
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
  local from_tree="" old_record="" old_branch="" old_pane dirty
  local want_branch="" ticket="" repo_arg="" repo="" spawn_repo trees repo_note=""
  local pin=""
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
      -*) die_usage "unknown option for spawn: $1" ;;
      *) if [ -z "$role" ]; then role="$1"; elif [ -z "$model" ]; then model="$1"; else die_usage "unexpected argument: $1"; fi ;;
    esac
    shift
  done
  [ -n "$role" ] && [ -n "$model" ] || die_usage "usage: teamctl spawn <role> <model> [--base <ref>] [--branch <name>] [--ticket <KEY>] [--repo <path> | --from-worktree <role>] [--no-kickoff] [--resume <session-id>]   (models: $WOLFMUX_MODEL_KEYS)"
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
    if ! "$GIT_BIN" -C "$path" switch -q -c "$branch" "$base_commit" >/dev/null 2>&1; then
      die "could not create branch $branch in $(short_path "$path") (is that directory still a git worktree of $(short_path "$spawn_repo")?)"
    fi
    reg_delete "$from_tree"
    /bin/rm -f "$STATE_DIR/settings/$from_tree.json"
  else
    path="$(wt_create "$spawn_repo" "$trees/$role-$stamp" "$branch" "$base_commit")"
  fi
  new_record "$role" worker "$model" "$path" "$branch" "$base_ref" "$base_commit" "$kickoff" "${spawner:-operator}" "$repo" 1
  if [ -n "$pin" ]; then reg_set "$role" session_id "$pin"; fi

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
  say "pane:      $pane"
  if [ -n "$repo" ]; then say "repo:      $(short_path "$repo")   (another repository; the guard holds this teammate to the worktree below)"; fi
  say "branch:    $branch  (base: $base_ref @ $(printf '%s' "$base_commit" | cut -c1-12))"
  say "worktree:  $(short_path "$path")"
  if [ -n "$from_tree" ]; then
    say "handed over: the worktree of $from_tree (its branch $old_branch and its commits are kept)"
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
write_agent_settings() {
  local role="$1" path="$STATE_DIR/settings/$1.json" kind notify_command="" guard_command=""
  /bin/mkdir -p "$STATE_DIR/settings"
  kind="$(reg_field "$role" kind)"
  if notify_wanted "$kind"; then notify_command="\"$TEAMCTL_SELF\" _notify"; fi
  if [ "$kind" = "worker" ] && [ "$(policy_get worker-isolation)" = "on" ]; then guard_command="\"$TEAMCTL_SELF\" _guard"; fi
  # Workers only: agent teams off, so a worker can never become a second manager.
  # Workers, unless the policy says otherwise: the worktree guard (lib/guard.sh).
  # Everyone: notifications are teamctl's job inside a team (lib/notify.sh).
  # Lead mode only: permission requests go to the lead.
  "$JQ_BIN" -n --arg kind "$kind" --arg mode "$(reg_field "$role" permissions)" \
    --arg permission_command "\"$TEAMCTL_SELF\" _permission-hook" --argjson timeout "$(($(approval_timeout) + 30))" \
    --arg notify_command "$notify_command" --arg silence "$(notify_silence_value)" --arg guard_command "$guard_command" '
    (if $kind == "worker" then {env: {CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "0"}, teammateMode: "in-process"} else {} end)
    * {env: {ECC_DISABLED_HOOKS: $silence}}
    * (if $notify_command != ""
       then {hooks: {Stop: [{hooks: [{type: "command", command: $notify_command, timeout: 10}]}]}} else {} end)
    * (if $guard_command != ""
       then {hooks: {PreToolUse: [{matcher: "Edit|Write|MultiEdit|NotebookEdit|Read|Grep|Glob|LS|Bash|mcp__.*",
                                   hooks: [{type: "command", command: $guard_command, timeout: 10}]}]}} else {} end)
    * (if $kind == "worker" and $mode == "lead"
       then {hooks: {PermissionRequest: [{hooks: [{type: "command", command: $permission_command, timeout: $timeout}]}]}}
       else {} end)' >"$path"
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
  listing="$("$GIT_BIN" -C "$1" status --short 2>/dev/null || true)" # whole, in a variable: no pipe to close
  printf '%s\n' "$listing" | sed -n "1,$4p" | sed "s/^/$2/"
  if [ "$3" -gt "$4" ]; then printf '%s… and %s more files\n' "$2" "$(($3 - $4))"; fi
}

# --- teamctl stop / restart ------------------------------------------------------------
cmd_stop() {
  local role="${1:-}" pane
  require_role_arg "$role"
  require_tools
  load_project
  reg_exists "$role" || die "no such agent: $role  (see: teamctl status)"
  require_manager stop
  lock_acquire
  SESSION="$(session_name_for_project)"
  pane="$(tm_pane_for_role "$SESSION" "$role" 2>/dev/null || true)"
  if [ -n "$pane" ]; then
    tmx kill-pane -t "$pane" 2>/dev/null || true
    layout_apply
  fi
  reg_set "$role" pane_id "" state stopped
  event_log stop "$role"
  lock_release
  say "stopped: $role   (worktree, branch and commits are untouched; bring it back with: teamctl restart $role)"
  if [ "$role" = "$WOLFMUX_LEAD_ROLE" ]; then founder_announce "stopped the lead of"; else founder_announce "stopped $role of"; fi
}

# restart_without_session <role> <resume 0|1> — the tmux session is gone (it was ended, or the
# machine restarted) and the records remain. Restarting the lead is starting the team again, as
# the model that led it; a worker needs that session first, and is told the exact commands.
restart_without_session() {
  local role="$1" resume="$2" pin="${3:-}" model team_flag="" continue_flag="" start_args
  model="$(reg_field "$WOLFMUX_LEAD_ROLE" model 2>/dev/null || true)"
  if [ "$TEAM" != "$WOLFMUX_DEFAULT_TEAM" ]; then team_flag=" --team $TEAM"; fi
  if [ "$resume" -eq 1 ]; then continue_flag=" --continue"; fi
  if [ -n "$pin" ]; then continue_flag=" --resume $pin"; fi
  if [ "$role" != "$WOLFMUX_LEAD_ROLE" ]; then
    die "team '$TEAM' has no session (it was ended, or the machine restarted). Bring the lead back in its last conversation: teamctl start ${model:-<fable|astra>}$team_flag --continue   then: teamctl restart $role$team_flag$continue_flag"
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
  cmd_start "${start_args[@]}"
}

# restart_undone <role> <its id before> <the team's kept id before> <message>: no pane came of a restart, so
# the conversation it had is the one on record again (for the lead, in the team's meta too), and it ends.
restart_undone() {
  reg_set "$1" session_id "$2"
  if [ "$1" = "$WOLFMUX_LEAD_ROLE" ]; then meta_put lead_session "$3"; fi
  die "$4"
}

cmd_restart() {
  local role="" resume=0 pin="" pane workdir target conversation was_session was_kept
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
      -*) die_usage "unknown option for restart: $1" ;;
      *) role="$1" ;;
    esac
    shift
  done
  require_role_arg "$role"
  require_tools
  load_project
  reg_exists "$role" || die "no such agent: $role  (see: teamctl status)"
  require_pin "$pin" "$(reg_field "$role" family)" "$role"
  workdir="$(reg_field "$role" workdir)"
  [ -d "$workdir" ] || die "cannot restart '$role': its working directory is gone ($workdir)"
  SESSION="$(session_name_for_project)"
  if ! tm_session_exists "$SESSION"; then
    restart_without_session "$role" "$resume" "$pin"
    return
  fi
  require_manager restart
  lock_acquire
  # A restart picks up the current policy.
  reg_set "$role" permissions "$(effective_permissions "$(reg_field "$role" kind)" "$(reg_field "$role" family)")"
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
    event_log restart "$role" "continue ${conversation:-newest}"
    say "restarted: $role in pane $pane (continuing ${conversation:-its previous conversation})"
  else
    event_log restart "$role" fresh
    say "restarted: $role in pane $pane"
  fi
  lock_release
  if [ "$role" = "$WOLFMUX_LEAD_ROLE" ]; then founder_announce restarted; else founder_announce "restarted $role of"; fi
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
  local force=0 assume_yes=0 roles="" role path branch dirty unmerged pane holding=""
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
  # All or nothing: nobody is removed when one of them cannot be.
  if [ "$force" -ne 1 ]; then
    for role in $roles; do
      path="$(reg_field "$role" workdir)"
      branch="$(reg_field "$role" branch)"
      unmerged=0
      if wt_branch_exists "$role" "$branch"; then unmerged="$(git_for_role "$role" rev-list --count "HEAD..$branch" 2>/dev/null || printf 0)"; fi
      if [ "$(wt_dirty_count "$path")" != "0" ] || [ "$unmerged" != "0" ]; then holding="$holding $role"; fi
    done
  fi
  for role in $roles; do
    path="$(reg_field "$role" workdir)"
    branch="$(reg_field "$role" branch)"
    dirty="$(wt_dirty_count "$path")"
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
        report_files "$path" '    ' "$dirty" 10
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
    # A record is a file anyone can edit. Whatever it says, only a directory inside the
    # worktree directory of this teammate's own repository is ever deleted, and only a
    # branch teamctl created that is not checked out in that repository itself.
    if [ -d "$path" ]; then
      if _inside_worktrees "$path" "$(worker_trees_dir "$role")"; then
        git_for_role "$role" worktree remove --force "$path" >/dev/null 2>&1 || /bin/rm -rf "$path"
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
    event_log remove "$role" "force=$force dirty=$dirty unmerged=$unmerged"
    say "removed: $role  (worktree, branch $branch and record)$(repo="$(reg_field "$role" repo)"; [ -z "$repo" ] || printf ' in %s' "$(short_path "$repo")")"
  done
  layout_apply
  lock_release
  [ -z "$holding" ] || die "nothing was removed:$holding still hold$([ "$(printf '%s' "$holding" | wc -w | tr -d ' ')" = "1" ] && printf s) work."
  founder_announce "removed $(printf '%s' "$roles" | sed 's/^ //; s/ /, /g') from"
}

_destroy_worker_artifacts() {
  local role="$1" path branch result
  path="$(reg_field "$role" workdir)"
  branch="$(reg_field "$role" branch)"
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
    say "  $role: deleted fully merged branch $branch"
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
_ctx_of_claude() {
  local tdir file f m newest="" newest_m=0 stats last="" reqs=0 line
  CTX_TOKENS="" CTX_REQUESTS=""
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
  # -R first: jq's own parser must never see a raw line, a half-written one included;
  # fromjson? then decodes what parses and yields nothing for what does not.
  stats="$(tail -n 400 "$newest" 2>/dev/null | "$JQ_BIN" -Rr '
    fromjson? | select(.type == "assistant" and (.message.usage != null)) |
    [(.message.usage.input_tokens // 0),
     (.message.usage.cache_read_input_tokens // 0),
     (.message.usage.cache_creation_input_tokens // 0)] | @tsv' 2>/dev/null)" || stats=""
  while IFS="$(printf '\t')" read -r line; do
    [ -n "$line" ] || continue
    reqs=$((reqs + 1))
    last="$line"
  done <<EOF
$stats
EOF
  [ -n "$last" ] || return 0
  CTX_TOKENS="$(printf '%s' "$last" | awk -F'\t' '{ print $1 + $2 + $3 }')"
  CTX_REQUESTS="$reqs"
  return 0
}

# _ctx_of_codex <workdir> — sets CTX_TOKENS, CTX_REQUESTS and CTX_WINDOW from the newest
# rollout under the codex sessions directory (WOLFMUX_CODEX_SESSIONS, else Codex's own
# location) whose session was started with cwd = this worktree: the last token_count event
# in it, which also states the window Codex actually serves. The 25 newest rollouts are
# looked at; none of them matches, or the event shape is unknown, and nothing is reported.
_ctx_of_codex() {
  local base="${WOLFMUX_CODEX_SESSIONS:-${CODEX_HOME:-$HOME/.codex}/sessions}" f real cands stats last="" reqs=0 line meta
  CTX_TOKENS="" CTX_REQUESTS="" CTX_WINDOW=""
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
    break # the newest rollout of this worktree is the one
  done <<EOF
$cands
EOF
  [ -n "$last" ] || return 0
  CTX_TOKENS="$(printf '%s' "$last" | cut -f1)"
  CTX_WINDOW="$(printf '%s' "$last" | cut -f2)"
  CTX_REQUESTS="$reqs"
  return 0
}

# agent_context <workdir> <model-key> <family> [<session-id>] — sets CTX_TOKENS ("" = unknown),
# CTX_REQUESTS and CTX_WINDOW for one agent. The window is declared by the model's
# provider, is 1M for a model id that ends in [1m], else 200k; for codex the token_count
# event's own window wins, since that is the one Codex actually serves.
agent_context() {
  local computed
  CTX_TOKENS="" CTX_WINDOW="" CTX_REQUESTS="0"
  if [ "$3" = "codex" ]; then
    _ctx_of_codex "$1"
  else
    _ctx_of_claude "$1" "${4:-}"
  fi
  computed="$(model_context_window "$2" 2>/dev/null)" || computed=""
  [ -n "$CTX_WINDOW" ] || CTX_WINDOW="${computed:-200000}"
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
  kb="$(disk_kb "$STATE_DIR/agents" "$STATE_DIR/approvals" "$STATE_DIR/settings" "$STATE_DIR/nudge" "$STATE_DIR/events.jsonl" "$STATE_DIR/meta.json")"
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
  /bin/rm -f "$STATE_DIR/events.jsonl" "$STATE_DIR/meta.json"
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
  say "Kept in all cases: your source files, every commit, unmerged branches, credentials, Beads data."
  if [ "$remove_worktrees" -eq 1 ]; then
    say "--worktrees: clean worker worktrees are removed; fully merged branches teamctl created are deleted."
  fi
  if [ "$assume_yes" -ne 1 ]; then
    confirm "Continue?" || die "aborted (pass --yes to skip this question)"
  fi
  ensure_state_dirs
  lock_acquire
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
    say "worktrees kept. Clean ones go with: teamctl destroy --worktrees · one that still holds work: teamctl remove <role> --force"
  fi
  reg_delete "$WOLFMUX_LEAD_ROLE"
  event_log destroy "" "worktrees=$remove_worktrees"
  lock_release
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

# notify_lead <spawn|approval|policy> <args...> — a fixed one-line notice in the lead's
# pane. Every interpolated value is a validated role, a model label from the model
# table, an approval id or a policy word; nothing free-form is ever typed.
notify_lead() {
  local kind="$1" pane text tries=0 fresh=0 locked=0 cap
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
  # Serialize with other notices for the lead so two lines never interleave.
  while [ "$tries" -lt 30 ]; do
    if nudge_begin "$WOLFMUX_LEAD_ROLE"; then
      locked=1
      break
    fi
    tries=$((tries + 1))
    sleep 0.2
  done
  # A marker whose waiter died must not swallow this notice (see nudge_pending_reap).
  if [ "$locked" -eq 1 ]; then nudge_pending_reap "$WOLFMUX_LEAD_ROLE" || true; fi
  # The lead is a pane a human sits in front of: never type over a half-typed line.
  # Each of these notices names its own event, so they queue instead of collapsing.
  # Without the lock we never type either: another notifier may be mid-line right now.
  if [ "$locked" -eq 0 ] || tm_pane_human_busy "$pane"; then
    if ! nudge_pending_exists "$WOLFMUX_LEAD_ROLE"; then
      if nudge_pending_open "$WOLFMUX_LEAD_ROLE"; then fresh=1; fi
    fi
    if nudge_pending_exists "$WOLFMUX_LEAD_ROLE"; then
      nudge_pending_put_line "$WOLFMUX_LEAD_ROLE" "$text" || true
      nudge_pending_put_cap "$WOLFMUX_LEAD_ROLE" "$cap" || true
      if [ "$locked" -eq 1 ]; then nudge_end "$WOLFMUX_LEAD_ROLE"; fi
      if [ "$fresh" -eq 1 ]; then _nudge_defer_start "$WOLFMUX_LEAD_ROLE" "$pane"; fi
      event_log notify-deferred "$WOLFMUX_LEAD_ROLE" "$kind (${TM_BUSY_REASON:-no lock}, cap ${cap}s)"
      return 3
    fi
    # No marker and none could be made: say so rather than type over the human.
    if [ "$locked" -eq 1 ]; then nudge_end "$WOLFMUX_LEAD_ROLE"; fi
    event_log notify-dropped "$WOLFMUX_LEAD_ROLE" "$kind (pane busy, no marker)"
    return 3
  fi
  tm_type_line "$pane" "$text"
  nudge_mark "$WOLFMUX_LEAD_ROLE"
  nudge_end "$WOLFMUX_LEAD_ROLE"
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
  local role="$1" bead="$2" pane text who
  # never yourself: the same role in the same team
  if [ "$role" = "${TEAM_ROLE:-}" ] && [ "$TEAM" = "${WOLFMUX_TEAM:-$WOLFMUX_DEFAULT_TEAM}" ]; then return 0; fi
  who="$(team_identity "$TEAM" "$role")"
  pane="$(tm_pane_for_role "$SESSION" "$role")"
  [ -n "$pane" ] && [ "$(tm_pane_state "$pane")" = "running" ] || return 1
  nudge_begin "$role" || return 2
  # A marker whose waiter died must not swallow this role's nudges for ever: reap it
  # before looking, while the per-role lock is held (see nudge_pending_reap).
  if nudge_pending_reap "$role"; then event_log nudge-defer-reaped "$role" "waiter gone"; fi
  # A notice is already waiting for this pane to go idle: add this bead to it and
  # let the one waiter deliver. Several queued nudges collapse into ONE line.
  if nudge_pending_exists "$role"; then
    nudge_pending_put_bead "$role" "$bead" || true
    nudge_end "$role"
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
  if tm_pane_human_busy "$pane"; then
    if nudge_pending_open "$role"; then
      nudge_pending_put_bead "$role" "$bead" || true
      nudge_end "$role"
      _nudge_defer_start "$role" "$pane"
      event_log nudge-deferred "$role" "$bead (${TM_BUSY_REASON:-busy})"
    elif nudge_pending_exists "$role"; then
      # A waiter appeared between the two checks: let it carry this bead too.
      nudge_pending_put_bead "$role" "$bead" || true
      nudge_end "$role"
    else
      nudge_end "$role"
      event_log nudge-dropped "$role" "$bead (pane busy, no marker)"
    fi
    return 3
  fi
  text="$(_nudge_text "$who" "$bead")"
  nudge_mark "$role"
  # The 300 ms between the text and the Enter inside tm_type_line is a window: a human
  # who had been idle for WOLFMUX_NUDGE_HUMAN_IDLE seconds could start typing inside it
  # and have their first keystrokes land after the notice. It stays open, because
  # closing it needs tmux to tell us a key arrived while we were mid-line, and there is
  # no such channel. The queued path below does NOT accept it: it re-checks per line.
  tm_type_line "$pane" "$text"
  event_log nudge "$role" "$bead"
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
  local role="$1" pane="$2" who waited=0 tries bead line delivered busy_again cap
  who="$(team_identity "$TEAM" "$role")"
  while :; do
    nudge_pending_exists "$role" || return 0 # someone else cleaned up
    nudge_pending_beat "$role"
    cap="$(nudge_pending_cap "$role" "$WOLFMUX_NUDGE_DEFER_MAX")"
    case "$cap" in "" | *[!0-9]*) cap="$WOLFMUX_NUDGE_DEFER_MAX" ;; esac
    if [ "$waited" -ge "$cap" ]; then break; fi
    if [ "$(tm_pane_state "$pane")" != "running" ]; then
      nudge_pending_clear "$role"
      event_log nudge-defer-dropped "$role" "pane ended after ${waited}s"
      return 0
    fi
    if tm_pane_human_busy "$pane"; then
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
      if tm_pane_human_busy "$pane"; then
        busy_again=1
        break
      fi
      line="$(nudge_pending_shift_line "$role")" || break
      [ -n "$line" ] || continue
      tm_type_line "$pane" "$line"
      delivered=$((delivered + 1))
    done
    if [ "$busy_again" -eq 0 ] && nudge_pending_has_bead "$role"; then
      if tm_pane_human_busy "$pane"; then
        busy_again=1
      else
        bead="$(nudge_pending_bead "$role")"
        tm_type_line "$pane" "$(_nudge_text "$who" "$bead")"
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
    *) die "'$role' has no running pane (its beads are waiting in Beads; start it with: teamctl restart $role)" ;;
  esac
}
