#!/bin/bash
# finish.sh — a finished team takes itself off the books, and a team that is not finished says
# what it holds.
#
# lib/reclaim.sh takes a finished LANE. What it leaves is the team around the lanes: the lead's
# record, the state directory, a session, and the lanes that were kept on purpose. On
# 2026-10-14 eleven of twenty-one teams on this machine were orphaned like that and nothing said
# so. This file does two things about it, and the second is the larger:
#
#   1  `teamctl finish` — the lead's way to say "we are done". It is the ONLY thing that may
#      take a team. It parks every lane, asks every lane the eight gates of lib/reclaim.sh, and
#      when no lane is left and no task of the team is open, the team goes: records, state
#      directory, session. When something still holds it, the session ends all the same and
#      the team stays, with the reason; the next `teamctl reclaim --all-teams` finishes it once
#      what held it is gone.
#
#   2  a team that cannot go says WHY, in `teamctl teams`, in one line of the dashboard and in
#      the status bar. Unreclaimable is acceptable; invisible is not.
#
# The rule that decides it (the lead's decision, 2026-10-14, recorded on the stage-4 bead):
# a lead that is not running is not evidence that its team finished. A crashed lead and a
# finished one look the same from outside, and a crashed lead with a tidy bead list is
# exactly the team that must survive. `teamctl stop` promises in writing to keep the record
# ("bring it back with: teamctl restart"), and a lead that closes every bead and parks for the
# night is the tidiest lead there is. So `stop` and a plain `destroy` leave a record of HOW the
# lead's session ended (lead-end.json) — and that record is evidence for the reason text only.
# It authorises nothing. Only `finish` does, and no record means not finished.
#
# What finish never does: delete a lane any gate keeps, delete a transcript (the lead's
# conversation id goes into the ledger, so `claude --resume <id>` still works), or take a team
# whose Beads cannot be asked.

_FINISH_US="$(printf '\037')"

# team_end_file — where the lead's last end is written down
team_end_file() { printf '%s/lead-end.json\n' "$STATE_DIR"; }

# finish_log_file — what finish said, for when the pane it said it in is gone (machine-wide:
# the team's own state directory may be gone too)
finish_log_file() { printf '%s/state/finish.log\n' "$WOLFMUX_DATA"; }

# finish_by — who is acting, as Beads names them: <team>.lead, a founder's identity, or operator
finish_by() {
  local by
  by="$(caller_identity 2>/dev/null || true)"
  printf '%s\n' "${by:-operator}"
}

# team_end_note <how> — write down how the lead's session is being ended: finish, stop or
# destroy. Called BEFORE the command touches a pane: a lead that ends its own session takes
# the hangup with it, and whatever comes after kill-pane may never run (common.sh: exit 129).
# Never fails the command it is in.
team_end_note() {
  local sid
  [ -d "$STATE_DIR" ] || return 0
  sid="$(reg_field "$WOLFMUX_LEAD_ROLE" session_id 2>/dev/null || true)"
  { "$JQ_BIN" -n --arg ts "$(now_iso)" --arg how "$1" --arg by "$(finish_by)" --arg session "$sid" \
    '{ts: $ts, how: $how, by: $by, session: (if $session == "" then null else $session end)}' |
    _reg_write_atomic "$(team_end_file)"; } 2>/dev/null || true
}

# team_end_clear — a new session of the lead: the last one's end no longer describes the team
team_end_clear() { /bin/rm -f "$(team_end_file)" 2>/dev/null || true; }

# team_end_how — finish | stop | destroy | nothing: what the record says
team_end_how() {
  [ -f "$(team_end_file)" ] || return 0
  "$JQ_BIN" -r '.how // empty' "$(team_end_file)" 2>/dev/null || true
}

# _finish_when <iso ts> — "11:40Z" today, "2026-10-13 10:34Z" on another day (UTC both)
_finish_when() {
  local ts="$1" day time
  day="${ts%%T*}"
  time="${ts#*T}"
  time="${time%:*}Z"
  case "$time" in [0-9][0-9]:[0-9][0-9]Z) ;; *) printf '%s\n' "$ts"; return 0 ;; esac
  if [ "$day" = "$(date -u +%Y-%m-%d)" ]; then printf '%s\n' "$time"; else printf '%s %s\n' "$day" "$time"; fi
}

# _finish_who <by> <the lead's own identity> — "itself", "you", or the identity
_finish_who() {
  if [ "$1" = "operator" ] || [ -z "$1" ]; then printf 'you\n'
  elif [ "$1" = "$2" ] || [ "$1" = "$WOLFMUX_LEAD_ROLE" ]; then printf 'itself\n'
  else printf '%s\n' "$1"; fi
}

# team_end_words — how the lead's last session ended, in the words a reason line uses.
# Sets TEAM_END_HOW, TEAM_END_BY and TEAM_END_TS (empty when nothing says).
#
# lead-end.json first. A team older than it has its own event log: a `stop` of the lead, or a
# `destroy`, written there by teamctl at the time, is a record too. Nothing else is: when
# neither says anything, the line says that there is no record, and never guesses which of a
# crash, a kill-server or a reboot it was.
team_end_words() {
  local file line type lead who
  TEAM_END_HOW="" TEAM_END_BY="" TEAM_END_TS=""
  lead="$(team_identity "${TEAM:-$WOLFMUX_DEFAULT_TEAM}" "$WOLFMUX_LEAD_ROLE")"
  file="$(team_end_file)"
  if [ -f "$file" ]; then
    # The unit separator, not a tab: an empty field would vanish in `read` (see dash_team_records)
    line="$("$JQ_BIN" -r '[.how // "", .by // "", .ts // ""] | join("\u001f")' "$file" 2>/dev/null || true)"
    TEAM_END_HOW="${line%%"$_FINISH_US"*}"
    line="${line#*"$_FINISH_US"}"
    TEAM_END_BY="${line%%"$_FINISH_US"*}"
    TEAM_END_TS="${line#*"$_FINISH_US"}"
  fi
  if [ -z "$TEAM_END_HOW" ] && [ -f "$STATE_DIR/events.jsonl" ]; then
    # The last thing that happened to the lead. A start or a restart after a stop means the
    # stop no longer describes it.
    line="$(grep -E '"type":"(stop|start|restart)","role":"lead"|"type":"destroy"' "$STATE_DIR/events.jsonl" 2>/dev/null | tail -n 1 || true)"
    if [ -n "$line" ]; then
      type="$(printf '%s' "$line" | "$JQ_BIN" -r '.type // empty' 2>/dev/null || true)"
      case "$type" in
        stop | destroy)
          TEAM_END_HOW="$type"
          TEAM_END_BY="$(printf '%s' "$line" | "$JQ_BIN" -r '.by // empty' 2>/dev/null || true)"
          TEAM_END_TS="$(printf '%s' "$line" | "$JQ_BIN" -r '.ts // empty' 2>/dev/null || true)"
          ;;
      esac
    fi
  fi
  who="$(_finish_who "$TEAM_END_BY" "$lead")"
  case "$TEAM_END_HOW" in
    stop)
      case "$who" in
        itself) printf 'lead stopped itself %s\n' "$(_finish_when "$TEAM_END_TS")" ;;
        *) printf 'lead stopped by %s %s\n' "$who" "$(_finish_when "$TEAM_END_TS")" ;;
      esac
      ;;
    destroy | finish)
      case "$who" in
        itself) printf 'lead ran teamctl %s %s\n' "$TEAM_END_HOW" "$(_finish_when "$TEAM_END_TS")" ;;
        *) printf '%s ran teamctl %s %s\n' "$who" "$TEAM_END_HOW" "$(_finish_when "$TEAM_END_TS")" ;;
      esac
      ;;
    *) printf 'no record of how the lead ended (crash, kill or reboot)\n' ;;
  esac
}

# --- every open task of the project: finish's own question to Beads -------------------
# NOT reclaim_beads_load. That one asks about a team's CURRENT worker lanes and nothing else,
# which is right for a lane and wrong for a team: the lead's own tasks, and the tasks of a
# lane that was removed and given new work, are not in its answer. Read from it, a team whose
# lead still has a task open would say "0 tasks open" and be finished with work left.
#
# So finish asks its own question, once per project per run: every bead that is not closed
# and not a message. It is bounded, as reclaim's is: 241 beads, 0.9 MB and about a second on
# 2026-10-15 for the busiest project here (the whole store was 1,465). An answer that reaches
# the limit is "cannot tell", and the team stays.
TEAM_BEADS_LIMIT=2000
TEAM_BEADS_FILE=""
TEAM_BEADS_AT=""
TEAM_BEADS_DOWN=""
TEAM_BEADS_DOWN_AT=""

# team_beads_forget — drop the answer. Called when a run that asked ends.
team_beads_forget() {
  [ -z "$TEAM_BEADS_FILE" ] || /bin/rm -f "$TEAM_BEADS_FILE"
  TEAM_BEADS_FILE=""
  TEAM_BEADS_AT=""
}

# _team_beads_down <why> — Beads cannot be asked about this project, for the rest of the run.
_team_beads_down() {
  TEAM_BEADS_DOWN="$1"
  TEAM_BEADS_DOWN_AT="$ROOT"
  RECLAIM_WHY="cannot ask Beads ($1)"
  return 1
}

# team_beads_load — every bead of the project that is not closed and not a message, asked
# once per project per run. Sets TEAM_BEADS_FILE (a JSON array), or returns 1 with RECLAIM_WHY
# set: when bd is missing, fails, does not answer in time, says something that cannot be
# read, or stops at the limit. Every one of those keeps the team. A project where reclaim
# already found Beads down is not asked again: the same bd would make it wait the same limit.
team_beads_load() {
  local out rc=0 count
  if [ "$TEAM_BEADS_AT" = "$ROOT" ] && [ -n "$TEAM_BEADS_FILE" ] && [ -f "$TEAM_BEADS_FILE" ]; then return 0; fi
  if [ -n "$TEAM_BEADS_DOWN" ] && [ "$TEAM_BEADS_DOWN_AT" = "$ROOT" ]; then
    RECLAIM_WHY="cannot ask Beads ($TEAM_BEADS_DOWN)"
    return 1
  fi
  if [ -n "${RECLAIM_BEADS_DOWN:-}" ] && [ "${RECLAIM_BEADS_DOWN_AT:-}" = "$ROOT" ]; then
    RECLAIM_WHY="cannot ask Beads ($RECLAIM_BEADS_DOWN)"
    return 1
  fi
  team_beads_forget
  [ -n "$BD_BIN" ] || { _team_beads_down "bd is not installed" || return 1; }
  if [ ! -e "$ROOT/.beads" ] && [ -z "${BEADS_DIR:-}" ]; then
    _team_beads_down "no Beads workspace in $(short_path "$ROOT")" || return 1
  fi
  out="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/wolfmux-finish.XXXXXX" 2>/dev/null || true)"
  [ -n "$out" ] || { _team_beads_down "no scratch file could be made in ${TMPDIR:-/tmp}" || return 1; }
  info "finish: asking Beads which tasks of the project are open (it gets $RECLAIM_ASK_SECONDS s to answer)"
  reclaim_ask "$RECLAIM_ASK_SECONDS" "$out" "$ROOT" "$BD_BIN" query "status!=closed AND type!=message" --all --limit "$TEAM_BEADS_LIMIT" --json || rc=$?
  if [ "$rc" -eq 124 ]; then
    reclaim_scratch_done "$out"
    _team_beads_down "bd did not answer in $RECLAIM_ASK_SECONDS s" || return 1
  fi
  if [ "$rc" -ne 0 ]; then
    rc="bd failed, exit $rc$(reclaim_said "$out")"
    reclaim_scratch_done "$out"
    _team_beads_down "$rc" || return 1
  fi
  # Read the way reclaim_beads_load reads its answer: a bare array, or a wrapped one.
  if ! "$JQ_BIN" -c 'if type == "array" then . elif type == "object" and (.issues | type) == "array" then .issues else error("neither a list nor a wrapped list") end
        | if all(.[]; type == "object") then . else error("a list of something else") end' "$out" >"$out.beads" 2>/dev/null; then
    reclaim_scratch_done "$out"
    /bin/rm -f "$out.beads"
    _team_beads_down "its answer could not be read" || return 1
  fi
  reclaim_scratch_done "$out"
  count="$("$JQ_BIN" -r 'length' "$out.beads" 2>/dev/null || true)"
  case "${count:-x}" in "" | *[!0-9]*)
    /bin/rm -f "$out.beads"
    _team_beads_down "its answer could not be read" || return 1
    ;;
  esac
  if [ "$count" -ge "$TEAM_BEADS_LIMIT" ]; then
    /bin/rm -f "$out.beads"
    _team_beads_down "its answer stopped at $TEAM_BEADS_LIMIT open beads, and a task of this team could be past that" || return 1
  fi
  TEAM_BEADS_FILE="$out.beads"
  TEAM_BEADS_AT="$ROOT"
  return 0
}

# team_tasks_open — every task of the LOADED team that is not closed, from finish's own answer
# (team_beads_load). Sets TEAM_TASKS_OPEN (a count) and TEAM_TASKS_IDS (the first three ids),
# or returns 1 with RECLAIM_WHY set.
#
# A task of the team is one assigned to any of its members, as Beads names them: every
# <team>.<role> of a named team, whether that role is still on record or not (a lane that was
# reclaimed can still be given new work), the lead included. The first team's members carry
# bare names, so there it is every role on record, every role its event log has seen, and the
# lead. A message is not a task.
team_tasks_open() {
  local names out
  TEAM_TASKS_OPEN="" TEAM_TASKS_IDS=""
  team_beads_load || return 1
  if [ "${TEAM:-$WOLFMUX_DEFAULT_TEAM}" = "$WOLFMUX_DEFAULT_TEAM" ]; then
    names="$({
      printf '%s\n' "$WOLFMUX_LEAD_ROLE"
      reg_list 2>/dev/null || true
      "$JQ_BIN" -r '.role // empty' "$STATE_DIR/events.jsonl" 2>/dev/null || true
    } | awk 'NF && !seen[$0]++' | "$JQ_BIN" -R . | "$JQ_BIN" -sc . 2>/dev/null || true)"
    [ -n "$names" ] || names='["lead"]'
    out="$("$JQ_BIN" -r --argjson names "$names" '[.[] | select((.assignee // "") as $a | $names | index($a))
      | select((.issue_type // "task") != "message" and (.status // "open") != "closed") | .id]
      | "\(length) \(.[0:3] | join(", "))"' "$TEAM_BEADS_FILE" 2>/dev/null || true)"
  else
    out="$("$JQ_BIN" -r --arg p "$TEAM." '[.[] | select((.assignee // "") | startswith($p))
      | select((.issue_type // "task") != "message" and (.status // "open") != "closed") | .id]
      | "\(length) \(.[0:3] | join(", "))"' "$TEAM_BEADS_FILE" 2>/dev/null || true)"
  fi
  case "${out%% *}" in
    "" | *[!0-9]*)
      RECLAIM_WHY="cannot ask Beads (its answer could not be read)"
      return 1
      ;;
  esac
  TEAM_TASKS_OPEN="${out%% *}"
  TEAM_TASKS_IDS="${out#* }"
  if [ "$TEAM_TASKS_OPEN" -gt 3 ]; then TEAM_TASKS_IDS="$TEAM_TASKS_IDS and $((TEAM_TASKS_OPEN - 3)) more"; fi
  return 0
}

# team_reason <lanes held> <what holds them> — the reason line: how the lead ended, the tasks,
# the lanes. Asks Beads (once per project per run). Sets TEAM_WHY, and TEAM_CLEAR=1 when
# nothing holds the team: no task open, Beads answered, no lane left.
team_reason() {
  local held="$1" list="$2" tasks
  TEAM_CLEAR=0
  if team_tasks_open; then
    tasks="$(reclaim_count "$TEAM_TASKS_OPEN" "task open" "tasks open")"
    if [ "$TEAM_TASKS_OPEN" -gt 0 ]; then tasks="$tasks: $TEAM_TASKS_IDS"; fi
  else
    tasks="tasks unknown ($RECLAIM_WHY)"
  fi
  TEAM_WHY="$(team_end_words), $tasks, $(reclaim_count "$held" "lane held" "lanes held")${list:+: $list}"
  if [ "${TEAM_TASKS_OPEN:-x}" = "0" ] && [ "$held" -eq 0 ]; then TEAM_CLEAR=1; fi
  return 0
}

# team_lanes_on_record — the lanes the LOADED team still has, as `teamctl teams` sees them:
# what the last check of each one wrote into its record, never a new question (no git, no gh).
# Sets TEAM_LANES (a count) and TEAM_LANE_LIST ("role (why); role (why)").
team_lanes_on_record() {
  local role why
  TEAM_LANES=0 TEAM_LANE_LIST=""
  [ -n "${SESSION:-}" ] || SESSION="$(session_name_for_project)"
  for role in $(reg_list); do
    [ "$(reg_field "$role" kind 2>/dev/null || true)" = "worker" ] || continue
    TEAM_LANES=$((TEAM_LANES + 1))
    if disk_lane_running "$role"; then
      why="running"
    else
      why="$(reg_field "$role" hold_why 2>/dev/null || true)"
      [ -n "$why" ] || why="not checked yet: teamctl reclaim --dry-run"
    fi
    TEAM_LANE_LIST="$TEAM_LANE_LIST${TEAM_LANE_LIST:+; }$role ($why)"
  done
}

# finish_log <line> — one line in the finish log, stamped, never failing
finish_log() {
  local file
  file="$(finish_log_file)"
  /bin/mkdir -p "$(dirname "$file")" 2>/dev/null || true
  { printf '%s %s/%s: %s\n' "$(now_iso)" "${PROJECT_KEY:-?}" "${TEAM:-?}" "$1" >>"$file"; } 2>/dev/null || true
}

# finish_say <line> — said, and written to the finish log: the pane it is said in may be the
# one this command is about to close
finish_say() {
  say "$1"
  finish_log "$1"
}

# team_removal_log <trigger> <reason> — the team's line in the machine-wide ledger
# (reclaimed.jsonl, beside the lanes'), written BEFORE anything of it is deleted. A team's own
# event log goes with the team; this line is what is left. Returns 1 when it cannot be written.
team_removal_log() {
  local file
  file="$(disk_reclaim_log_file)"
  /bin/mkdir -p "$(dirname "$file")" 2>/dev/null || true
  [ -n "$JQ_BIN" ] || return 1
  team_end_words >/dev/null
  {
    "$JQ_BIN" -cn --arg ts "$(now_iso)" --arg project "${PROJECT_KEY:-}" --arg team "${TEAM:-}" --arg root "${ROOT:-}" \
      --arg trigger "$1" --arg reason "$2" --arg by "$(finish_by)" --arg session "${SESSION:-}" \
      --arg lead_session "$(reg_field "$WOLFMUX_LEAD_ROLE" session_id 2>/dev/null || true)" \
      --arg end_how "$TEAM_END_HOW" --arg end_by "$TEAM_END_BY" --arg end_ts "$TEAM_END_TS" \
      '{ts: $ts, event: "team-destroyed", project: $project, team: $team, root: $root, trigger: $trigger, by: $by,
        took: "records state-directory session", reason: $reason, session: $session,
        lead_session: (if $lead_session == "" then null else $lead_session end),
        lead_end: (if $end_how == "" then null else {how: $end_how, by: $end_by, ts: $end_ts} end)}' \
      >>"$file"
  } 2>/dev/null
}

# team_finish_remove <trigger> <indent> — take the LOADED team off the books: its records, its
# state directory, its session. The caller has judged it (team_reason, TEAM_CLEAR=1) and does
# NOT hold the team's lock. Returns 1, with TEAM_WHY set and nothing touched, when a lane came
# back on record meanwhile or the ledger cannot be written.
#
# The session is NOT ended here; finish_end_session does that, as the caller's very last act.
team_finish_remove() {
  local trigger="$1" indent="$2" role
  lock_acquire
  for role in $(reg_list); do
    if [ "$(reg_field "$role" kind 2>/dev/null || true)" = "worker" ]; then
      lock_release
      TEAM_WHY="lane $role is on record again"
      return 1
    fi
  done
  if ! team_removal_log "$trigger" "$TEAM_WHY"; then
    lock_release
    TEAM_WHY="the ledger cannot be written ($(short_path "$(disk_reclaim_log_file)"))"
    return 1
  fi
  for role in $(reg_list); do reg_delete "$role"; done
  # As _purge_team, plus what it leaves: the notices (inbox/) and the lead's end. The first
  # team's directory is also the parent of the named teams: its files go, never teams/.
  /bin/rm -rf "$STATE_DIR/agents" "$STATE_DIR/approvals" "$STATE_DIR/settings" "$STATE_DIR/nudge" "$STATE_DIR/inbox"
  /bin/rm -f "$STATE_DIR/events.jsonl" "$STATE_DIR/meta.json" "$STATE_DIR/disk-kb" "$STATE_DIR/disk-parked-kb" "$(team_end_file)"
  lock_release
  if [ "$TEAM" != "$WOLFMUX_DEFAULT_TEAM" ]; then /bin/rmdir "$STATE_DIR" 2>/dev/null || true; fi # only when empty
  /bin/rmdir "$WORKTREES_DIR" 2>/dev/null || true
  if [ -n "${FOUNDER_ACTING:-}" ]; then
    (team_paths "$(caller_team | sed "s/^\$/$WOLFMUX_DEFAULT_TEAM/")" && event_log finish "" "finished team $TEAM, which it founded") || true
  fi
  return 0
}

# finish_end_session — end the LOADED team's session, as the very last act of the command.
# finish may be run by the lead from a pane of that very session; killing it hangs up on the
# lead, its shell and the pipe this command writes to. Everything that matters has happened by
# now, and what is left is made to survive the hangup: HUP and PIPE are ignored, and the
# output goes to the finish log instead of a terminal that is about to close.
finish_end_session() {
  tm_session_exists "$SESSION" || return 0
  finish_log "ending session $SESSION"
  trap '' HUP PIPE
  exec >>"$(finish_log_file)" 2>&1
  tmx kill-session -t "=$SESSION" 2>/dev/null || true
  finish_log "session $SESSION ended"
}

# finish_park_all — park every lane of the LOADED team, as `teamctl stop` would one by one:
# its pane closed, its record stopped, its build output swept. Under the team's lock.
finish_park_all() {
  local role pane
  for role in $(reg_list); do
    [ "$(reg_field "$role" kind 2>/dev/null || true)" = "worker" ] || continue
    pane="$(tm_pane_for_role "$SESSION" "$role" 2>/dev/null || true)"
    [ -n "$pane" ] || continue
    tmx kill-pane -t "$pane" 2>/dev/null || true
    reg_set "$role" pane_id "" state stopped
    if disk_park_sweep "$role" finish; then
      say "  $role: parked, freed $(human_size "$DISK_FREED_KB") of build output ($DISK_CLEANED)"
    else
      say "  $role: parked"
    fi
    event_log stop "$role" "by teamctl finish"
  done
}

# --- teamctl finish [--dry-run] --------------------------------------------------------
FINISH_TAKES="every lane that passes the eight gates of teamctl reclaim; then the team itself (records, state directory, session) once no lane is left and no task of it is open. Never a transcript"

cmd_finish() {
  local dry=0 apply=1 hint="" doubt=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      *) die_usage "usage: teamctl finish [--team <name>] [--dry-run]" ;;
    esac
    shift
  done
  if [ "$dry" -eq 1 ]; then apply=0; fi
  require_tools
  load_project
  [ "$dry" -eq 1 ] || require_manager finish
  SESSION="$(session_name_for_project)"
  if [ -z "$(reg_list)" ] && ! tm_session_exists "$SESSION"; then
    die "there is no team '$TEAM' in $(short_path "$ROOT") (see: teamctl teams)"
  fi
  if [ "$TEAM" != "$WOLFMUX_DEFAULT_TEAM" ]; then hint=" --team $TEAM"; fi
  if [ "$dry" -eq 1 ]; then
    say "finish team '$TEAM' of $(short_path "$ROOT")   ·   DRY RUN: nothing is deleted"
  else
    say "finish team '$TEAM' of $(short_path "$ROOT")"
  fi
  say "  takes: $FINISH_TAKES"
  say ""
  doubt="$(prune_team_doubt)"
  if [ -n "$doubt" ]; then
    die "$doubt. Nothing was touched. Look: teamctl status$hint · teamctl panes. Then run finish again."
  fi
  if [ "$apply" -eq 1 ]; then
    ensure_state_dirs
    lock_acquire
    # First, before any pane: the record that this team was finished, and by whom. It is
    # what lets the next `teamctl reclaim --all-teams` finish the team if something still
    # holds it now.
    team_end_note finish
    finish_park_all
    event_log finish "" "by $(finish_by)"
    lock_release
    finish_log "finish run by $(finish_by)"
  fi
  # Every lane is asked, and with apply every lane that passes goes, whatever policy
  # auto-reclaim says: this was asked for, as `teamctl reclaim` is. `teamctl keep` still holds.
  reclaim_team "$apply" "  "
  team_reason "$RECLAIM_HOLD_N" "$RECLAIM_HOLD_LIST"
  reclaim_beads_forget || true
  team_beads_forget || true
  say ""
  if [ "$dry" -eq 1 ]; then
    if [ "$TEAM_CLEAR" -eq 1 ]; then
      say "would finish: team '$TEAM' — $TEAM_WHY"
      say "  take it: teamctl finish$hint"
    else
      say "would keep: team '$TEAM', holding $(human_size "$RECLAIM_HOLD_KB"): $TEAM_WHY"
      say "  teamctl finish$hint would still end its session; the next teamctl reclaim --all-teams would finish it once nothing holds it"
    fi
    return 0
  fi
  if [ "$TEAM_CLEAR" -eq 1 ] && team_finish_remove finish "  "; then
    finish_say "finished: team '$TEAM' is gone — $TEAM_WHY"
    say "  every lane removal and the team's own line: $(short_path "$(disk_reclaim_log_file)") · what finish said: $(short_path "$(finish_log_file)")"
    founder_announce finished
  else
    finish_say "kept: team '$TEAM' is holding $(human_size "$RECLAIM_HOLD_KB"): $TEAM_WHY"
    say "  Its session ends now; the team stays, listed in teamctl teams with this reason. Once nothing holds it, the next teamctl reclaim --all-teams finishes it (or run teamctl finish$hint again)."
    founder_announce "finished (kept: something still holds it)"
  fi
  finish_end_session
}

# --- the sweep: teamctl reclaim --all-teams -------------------------------------------
# finish_sweep_team <apply 0|1> <indent> — after reclaim_team has asked the LOADED team's
# lanes: a team whose lead is not running gets one line saying what it is. It is finished and
# taken only when its last end on record is `teamctl finish` and nothing holds it any more.
# Sets FINISH_SWEPT=1 when it took the team.
finish_sweep_team() {
  local apply="$1" indent="$2"
  FINISH_SWEPT=0
  team_orphaned || return 0
  team_reason "$RECLAIM_HOLD_N" "$RECLAIM_HOLD_LIST"
  if [ "$TEAM_CLEAR" -eq 1 ] && [ "$(team_end_how)" = "finish" ]; then
    if [ "$apply" -ne 1 ]; then
      printf '%steam %s: would be finished and gone — %s\n' "$indent" "$TEAM" "$TEAM_WHY"
      return 0
    fi
    if team_finish_remove reclaim "$indent"; then
      FINISH_SWEPT=1
      finish_log "finished and gone (teamctl reclaim --all-teams): $TEAM_WHY"
      printf '%steam %s: finished and gone — %s\n' "$indent" "$TEAM" "$TEAM_WHY"
      if tm_session_exists "$SESSION"; then tmx kill-session -t "=$SESSION" 2>/dev/null || true; fi
      return 0
    fi
  fi
  printf '%steam %s: orphaned, holding %s: %s\n' "$indent" "$TEAM" "$(human_size "$RECLAIM_HOLD_KB")" "$TEAM_WHY"
  return 0
}
