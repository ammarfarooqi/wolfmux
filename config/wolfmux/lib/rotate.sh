#!/bin/bash
# rotate.sh - a fresh conversation for a nearly full worker, with a hand-over wolfmux writes
# itself (ADR-0039). Three ways in: `teamctl rotate <role>` (the lead, or a worker for itself),
# the Stop hook under policy worker-rotation auto (rotate_at_stop, run from recall_hook), and
# the thrash event of lib/recall.sh. The agent is never asked to write anything.
#
# Files, all under run/<role>/:
#   memory/handover.md         the hand-over, at most WOLFMUX_HANDOVER_CHARS characters
#   memory/handover.pending    exists = the next SessionStart(startup) shows it, once
#   memory/rotated             the conversation ids that were rotated away (one per line), and
#                              the ids of conversations a rotation started ("new <id>")
#   memory/below-seen          exists = the watch saw this conversation under its rotate threshold
#                              at least once (a conversation a rotation started may rotate again)
#   memory/rotate-declined     exists = the lead was told this conversation was not rotated (no task)
#   memory/rotate-due          exists = told at a crossing to end its turn for a rotation: every Stop hook
#                              of wolfmux stays quiet at that turn end (they run in parallel, so a file
#                              written before the Stop is the one thing they all can see)
#   rotate.lock                a directory: one rotation at a time per role; its "by" file holds
#                              "<who> <epoch> <token>"; older than WOLFMUX_ROTATE_LOCK_STALE seconds, it is
#                              taken over. The token (pid and a random number of the taker) is handed to the
#                              detached process, which proves with it that a rotation took the lock for it

WOLFMUX_HANDOVER_CHARS="${WOLFMUX_HANDOVER_CHARS:-12000}"
WOLFMUX_ROTATE_WAIT="${WOLFMUX_ROTATE_WAIT:-120}"
WOLFMUX_ROTATE_LOCK_STALE="${WOLFMUX_ROTATE_LOCK_STALE:-600}"
# One cap per part, so no part can push another out. Their sum stays under the whole cap.
_ROTATE_CAP_TASK=2500
_ROTATE_CAP_CHECKPOINT=1200
_ROTATE_CAP_GIT=1800
_ROTATE_CAP_DIFF=3000
_ROTATE_CAP_ANSWER=1500
_ROTATE_CAP_ANSWERS=2400
_ROTATE_CAP_TAIL=700

_rotate_num() { case "${1:-}" in "" | *[!0-9]*) return 1 ;; esac; }

# _rotate_part <cap> - stdin to stdout: cleaned, cut at <cap>, marked when cut
_rotate_part() {
  local text
  text="$(LC_ALL=C /usr/bin/tr -d '\000-\010\013-\037\177' | /usr/bin/sed 's/^\[wolfmux/> [wolfmux/')"
  if [ "${#text}" -gt "$1" ]; then
    printf '%s\n[cut at %s characters]\n' "${text:0:$(($1 - 40))}" "$1"
  else
    printf '%s\n' "$text"
  fi
}

# _rotate_task_text <task-json> - part a
_rotate_task_text() {
  [ -n "$1" ] || { printf 'no task in_progress\n'; return 0; }
  printf '%s' "$1" | "$JQ_BIN" -r '"id: \(.id)\ntitle: \(.title)\n\nbody:\n\(.description // "")\n\nnotes:\n\(.notes // "" | if . == "" then "(none)" else . end)"' 2>/dev/null
}

# _rotate_own_checkpoint <file> - part b: the agent's own text, before the automatic sections
_rotate_own_checkpoint() {
  local first
  [ -r "$1" ] || return 0
  first="$(/usr/bin/grep -n "^$_MEMORY_PRECOMPACT_MARKER" "$1" 2>/dev/null | /usr/bin/head -1 | /usr/bin/cut -d: -f1)"
  if [ -n "$first" ]; then /usr/bin/head -n "$((first - 1))" "$1"; else /bin/cat "$1"; fi
}

# _rotate_git <workdir> <base-commit> - part c
_rotate_git() {
  local log
  if [ -n "$2" ]; then log="$("$GIT_BIN" -C "$1" log --oneline "$2..HEAD" 2>/dev/null | /usr/bin/head -n 30)"; else log="$("$GIT_BIN" -C "$1" log --oneline -10 2>/dev/null)"; fi
  printf 'branch: %s\n' "$("$GIT_BIN" -C "$1" branch --show-current 2>/dev/null)"
  printf 'commits since the base (%s):\n%s\n' "${2:0:12}" "${log:-(none)}"
  printf 'git status --short:\n%s\n' "$("$GIT_BIN" -C "$1" status --short 2>/dev/null | /usr/bin/head -n 40)"
  printf 'git diff --stat (unstaged):\n%s\n' "$("$GIT_BIN" -C "$1" diff --stat 2>/dev/null | /usr/bin/tail -n 15)"
  printf 'git diff --cached --stat (staged):\n%s\n' "$("$GIT_BIN" -C "$1" diff --cached --stat 2>/dev/null | /usr/bin/tail -n 15)"
}

# _rotate_diff <workdir> - part c, second half: the uncommitted change itself, unstaged then staged
_rotate_diff() {
  local unstaged staged
  unstaged="$("$GIT_BIN" -C "$1" diff 2>/dev/null)"
  staged="$("$GIT_BIN" -C "$1" diff --cached 2>/dev/null)"
  [ -n "$unstaged$staged" ] || { printf '(none)\n'; return 0; }
  [ -z "$unstaged" ] || printf '%s\n' "$unstaged"
  [ -z "$staged" ] || printf 'staged:\n%s\n' "$staged"
}

# _rotate_answers <transcript> - part d: the last five answers (text blocks of the main
# conversation; no tool call, no thinking), each cut, newest last
_rotate_answers() {
  [ -r "${1:-}" ] || { printf '(no transcript)\n'; return 0; }
  /usr/bin/tail -n 3000 "$1" 2>/dev/null | "$JQ_BIN" -R -r --argjson cap "$_ROTATE_CAP_ANSWER" '
    fromjson? | objects | select(.type == "assistant" and .isSidechain != true and .isApiErrorMessage != true)
    | [(.message.content // []) | if type == "array" then .[] else empty end | select(.type == "text") | .text] | join("\n")
    | select(length > 0) | (if length > $cap then .[0:$cap] + " [cut]" else . end) | @json' 2>/dev/null |
    /usr/bin/tail -n 5 | "$JQ_BIN" -r '"---\n" + .' 2>/dev/null
}

# rotate_handover_write <file> <task-json> <checkpoint> <workdir> <base> <transcript> <out-dir> <reason> <by>
rotate_handover_write() {
  local file="$1" body
  body="$({
    printf '# hand-over %s\n\n## a. your task\n' "$(now_iso)"
    _rotate_task_text "$2" | _rotate_part "$_ROTATE_CAP_TASK"
    printf '\n## b. your own checkpoint text\n'
    _rotate_own_checkpoint "$3" | _rotate_part "$_ROTATE_CAP_CHECKPOINT"
    printf '\n## c. the tree\n'
    _rotate_git "$4" "$5" | _rotate_part "$_ROTATE_CAP_GIT"
    printf '\n### the uncommitted diff (git diff, then git diff --cached)\n'
    _rotate_diff "$4" | _rotate_part "$_ROTATE_CAP_DIFF"
    printf '\n## d. your last answers, newest last\n'
    _rotate_answers "$6" | _hook_tail_cap "$_ROTATE_CAP_ANSWERS"
    # f before e: long paths are cut, the reason and who asked are not
    printf '\n\n## f. why\n'
    { printf 'reason: %s\nasked by: %s\n' "$8" "$9"
      printf '\n## e. paths\nold transcript: %s\noutput logs (to read, not to write): %s\nthis hand-over: %s\n' "${6:-unknown}" "$7" "$file"; } | _rotate_part "$_ROTATE_CAP_TAIL"
  })"
  printf '%s\n' "$body" | _hook_cap "$WOLFMUX_HANDOVER_CHARS" | _reg_write_atomic "$file"
}

# rotate_session_handover - SessionStart(startup): the hand-over, once, before anything else
rotate_session_handover() {
  local pending="$HOOK_RUN/memory/handover.pending" file="$HOOK_RUN/memory/handover.md"
  [ "$HOOK_SOURCE" = "startup" ] && [ -e "$pending" ] && [ -r "$file" ] || return 0
  /bin/rm -f "$pending" 2>/dev/null || true
  # The new conversation names itself: the loop guard does not depend on the rotating process
  # outliving the restart (it should; see _rotate_detach).
  local sid
  sid="$(hook_input .session_id)"
  _rotate_note_new "$HOOK_RUN" "$sid"
  hook_context "[wolfmux] This is a fresh conversation for the same task: wolfmux replaced the full one and wrote this hand-over ($file). Your task is already claimed and in progress: do not claim it again. The tree state below (commits, status, the uncommitted diff) is current as of the rotation and the work in it, committed or not, is yours: continue from it, do not start over and do not re-check what it already says.

$(/bin/cat "$file" 2>/dev/null)"
}

# _rotate_note_new <run-dir> <session-id> - "new <id>" in memory/rotated, once: the new conversation's
# SessionStart and the rotating process both write it, whichever comes first.
_rotate_note_new() {
  [ -n "$2" ] || return 0
  /usr/bin/grep -qx "new $2" "$1/memory/rotated" 2>/dev/null || printf 'new %s\n' "$2" >>"$1/memory/rotated" 2>/dev/null || true
}

# _rotate_guarded <run-dir> <session-id> - 0 when the loop guard holds this conversation back: it was
# rotated away once and has been resumed by hand, or it was started by a rotation and the watch never
# saw it under the rotate threshold (it STARTED past it). A conversation a rotation started that was
# under the threshold once and filled up with work is rotated again.
_rotate_guarded() {
  [ -n "$2" ] && [ -r "$1/memory/rotated" ] || return 1
  /usr/bin/grep -q -e "^$2\$" "$1/memory/rotated" 2>/dev/null && return 0
  [ ! -e "$1/memory/below-seen" ] || return 1
  /usr/bin/grep -q -e "^new $2\$" "$1/memory/rotated" 2>/dev/null
}

# rotate_will_follow - in a hook, at a crossing only (the rotate threshold, the thrash event): 0 when a
# rotation will follow this conversation's next turn end, as far as a hook can tell without the store:
# not the lead, policy worker-rotation auto (the team's meta.json, else the default), a Claude agent,
# not held back by the loop guard. Whether a task is in progress is asked later, by _rotate-auto.
# One jq for the policy and the family; no bd.
rotate_will_follow() {
  local state files=() answer policy family
  [ "$HOOK_ROLE" != "${WOLFMUX_LEAD_ROLE:-lead}" ] || return 1
  state="${HOOK_RUN%/run/*}"
  [ ! -r "$state/meta.json" ] || files+=("$state/meta.json")
  [ ! -r "$state/agents/$HOOK_ROLE.json" ] || files+=("$state/agents/$HOOK_ROLE.json")
  answer=" "
  if [ "${#files[@]}" -gt 0 ]; then
    answer="$("$JQ_BIN" -rn 'reduce inputs as $o ({}; if (input_filename | endswith("/meta.json")) then .p = ($o.policy_worker_rotation // "") else .f = ($o.family // "") end) | "\(.p // "") \(.f // "")"' "${files[@]}" 2>/dev/null)" || answer=" "
  fi
  policy="${answer%% *}" family="${answer#* }"
  [ -n "$policy" ] || policy="${WOLFMUX_WORKER_ROTATION:-auto}"
  [ "$policy" = "auto" ] && [ "$family" != "codex" ] || return 1
  ! _rotate_guarded "$HOOK_RUN" "$(hook_input .session_id)"
}

# The agent's line at a crossing when a rotation will follow: end the turn, wolfmux does the rest.
ROTATE_END_TURN="If you have a task in progress: commit what works, do not start its next step, then END YOUR TURN now with one line
that says where you stand. wolfmux then replaces this conversation with a fresh one that gets a hand-over (your task, the
commits, the uncommitted diff, your last answers) and continues the task. Do not close the task, do not hand it back; no
message to the lead is needed."

# _rotate_lock_age <lock-dir> - its age in seconds: the epoch in its "by" file, else the directory's
# mtime. 1 when it is not there or its age is unknown.
_rotate_lock_age() {
  local who="" at="" rest
  [ -d "$1" ] || return 1
  if [ -r "$1/by" ]; then read -r who at rest <"$1/by" || true; fi
  _rotate_num "$at" || at="$(/usr/bin/stat -f %m "$1" 2>/dev/null)" || at=""
  _rotate_num "$at" || return 1
  printf '%s\n' "$(($(now_epoch) - at))"
}

# rotate_lock_stale <lock-dir> - 0 when it is there and older than WOLFMUX_ROTATE_LOCK_STALE seconds: the
# process that held it is gone (killed, the machine slept) and it no longer stands for a rotation.
rotate_lock_stale() {
  local age
  age="$(_rotate_lock_age "$1")" || return 1
  [ "$age" -gt "$WOLFMUX_ROTATE_LOCK_STALE" ]
}

# _rotate_lock_take <lock-dir> <who> - 0 with the lock taken; a lock older than
# WOLFMUX_ROTATE_LOCK_STALE seconds (its "by" file, else the directory's mtime) is taken over. 1 when
# it is held; ROTATE_LOCK_AGE is then its age in seconds ("" when unknown). Taken, ROTATE_LOCK_TOKEN
# is the token written into its "by" file.
_rotate_lock_take() {
  ROTATE_LOCK_AGE="" ROTATE_LOCK_TOKEN="$$.$RANDOM$RANDOM"
  if ! /bin/mkdir "$1" 2>/dev/null; then
    ROTATE_LOCK_AGE="$(_rotate_lock_age "$1")" || return 1
    [ "$ROTATE_LOCK_AGE" -gt "$WOLFMUX_ROTATE_LOCK_STALE" ] || return 1
    /bin/rm -rf "$1" 2>/dev/null || true
    /bin/mkdir "$1" 2>/dev/null || return 1
  fi
  printf '%s %s %s\n' "$2" "$(now_epoch)" "$ROTATE_LOCK_TOKEN" >"$1/by" 2>/dev/null || true
  return 0
}

# _rotate_lock_token <lock-dir> - the token its "by" file holds, or nothing
_rotate_lock_token() {
  local who="" at="" token=""
  if [ -r "$1/by" ]; then read -r who at token <"$1/by" || true; fi
  printf '%s' "$token"
}

# _rotate_lock_release <lock-dir> <token> - remove the lock only while it is still this rotation's: one
# that outlived WOLFMUX_ROTATE_LOCK_STALE may have been taken over by a second rotation since.
_rotate_lock_release() {
  [ -n "${2:-}" ] && [ "$(_rotate_lock_token "$1")" = "$2" ] || return 0
  /bin/rm -rf "$1" 2>/dev/null || true
}

# _rotate_internal_gate <role> <token> - the entry of _rotate-run and _rotate-auto, before anything is
# written. They are started detached by a rotation of <role> that took run/<role>/rotate.lock (a Stop
# hook of that agent, or its own teamctl rotate), and inherit its TEAM_ROLE and TMUX_PANE: the caller
# must be <role> itself, never the lead, and the lock must hold the token that rotation handed over.
# Anyone else typing them (a worker for the lead or another worker, the lead for a worker: the lead
# uses teamctl rotate) is refused with 77. The detached process has left the pane, so the pane proof
# cannot be asked of it; the role it names and the token are.
_rotate_internal_gate() {
  local why=""
  caller_resolve
  if [ "$1" = "$WOLFMUX_LEAD_ROLE" ]; then
    why="the lead is not rotated"
  elif [ -z "$CALLER_ROLE" ] || [ "$CALLER_ROLE" != "$1" ]; then
    why="it runs only as '$1' itself, started by a rotation of '$1' (you are ${CALLER_ROLE:-the operator})"
  elif [ ! -d "$(run_dir "$1")/rotate.lock" ]; then
    why="no rotation of '$1' holds its rotate.lock"
  elif [ -z "${2:-}" ] || [ "$(_rotate_lock_token "$(run_dir "$1")/rotate.lock")" != "$2" ]; then
    why="the rotate.lock of '$1' was not taken for this process"
  fi
  [ -n "$why" ] || return 0
  die "teamctl ${TEAMCTL_ARGS:-_rotate} is internal and was not run: $why. To rotate a worker: teamctl rotate <role> (the lead, or a worker for itself)." 77
}

# _rotate_detach <log> <command...> - start <command> so that it outlives the pane it was started
# from: the restart it does ends that pane (tmux respawn-pane -k), and with it the pane's process
# group and session (SIGHUP). macOS has no setsid binary; /usr/bin/perl ships with it and its POSIX
# module has setsid(): it forks (so the child is no group leader), the child ignores SIGHUP (an
# ignored signal stays ignored across exec) and calls setsid() (a new session and process group, no
# controlling terminal), then execs. Without perl: SIGHUP ignored only, as nohup does.
_rotate_detach() {
  local log="$1"
  shift
  if [ -x /usr/bin/perl ]; then
    (/usr/bin/perl -MPOSIX -e '$SIG{HUP} = "IGNORE"; my $p = fork; exit 0 if $p; exit 1 unless defined $p; POSIX::setsid(); exec @ARGV or exit 127' "$@" </dev/null >>"$log" 2>&1 &) >/dev/null 2>&1
  else
    (trap '' HUP; exec "$@" </dev/null >>"$log" 2>&1 &) >/dev/null 2>&1
  fi
}

# rotate_at_stop - Stop, from recall_hook: a worker at or past its rotate threshold, or one
# that thrashes, is rotated at this turn end, detached. Cheap checks only here; the policy, the
# task and the family are asked by the detached process (teamctl _rotate-auto).
rotate_at_stop() {
  local percent="" rotate reason="" session lock
  [ -z "$(hook_input .agent_id)" ] || return 0
  [ "$HOOK_ROLE" != "${WOLFMUX_LEAD_ROLE:-lead}" ] || return 0
  [ "${WOLFMUX_WORKER_ROTATION:-}" != "off" ] || return 0
  if [ -e "$HOOK_RUN/memory/rotate-due" ] && [ -d "$HOOK_RUN/rotate.lock" ]; then
    if ! rotate_lock_stale "$HOOK_RUN/rotate.lock"; then
      # A rotation is under way and waits for this turn end (a worker's own teamctl rotate, or an
      # earlier Stop): nothing more to start, and no other module may continue the turn.
      ROTATE_STARTED=1
      return 0
    fi
    # A stale lock: the rotation that took it is gone. Kept, it and rotate-due would keep every Stop
    # hook of this conversation quiet for ever; both go, and this Stop goes on as usual.
    /bin/rm -rf "$HOOK_RUN/rotate.lock" 2>/dev/null || true
    /bin/rm -f "$HOOK_RUN/memory/rotate-due" 2>/dev/null || true
  fi
  if [ -r "$HOOK_RUN/memory/ctx" ]; then percent="$("$JQ_BIN" -r '.percent // empty' "$HOOK_RUN/memory/ctx" 2>/dev/null)"; fi
  rotate="$(_memory_threshold "${WOLFMUX_CONTEXT_ROTATE:-}" 80)"
  if [ -e "$HOOK_RUN/memory/thrash-told" ]; then
    reason="compacted twice within ${WOLFMUX_THRASH_CALLS:-10} tool calls"
  elif _rotate_num "$percent" && [ "$rotate" -gt 0 ] && [ "$percent" -ge "$rotate" ]; then
    reason="context at $percent% of its limit (rotate threshold $rotate%)"
  fi
  if [ -z "$reason" ]; then
    # Back under the threshold (a compaction came first): no rotation, and the Stop hooks may speak again.
    [ ! -e "$HOOK_RUN/memory/rotate-due" ] || [ -d "$HOOK_RUN/rotate.lock" ] || /bin/rm -f "$HOOK_RUN/memory/rotate-due" 2>/dev/null || true
    return 0
  fi
  [ ! -e "$HOOK_RUN/memory/rotate-fired" ] || return 0
  : >"$HOOK_RUN/memory/rotate-fired" 2>/dev/null || true
  session="$(hook_input .session_id)"
  if _rotate_guarded "$HOOK_RUN" "$session"; then
    # A conversation a rotation started that was never under the threshold: no second rotation.
    /bin/rm -f "$HOOK_RUN/memory/rotate-due" 2>/dev/null || true
    _memory_tell_lead "${percent:-?}" "$(_memory_ctx_line "$HOOK_RUN" | /usr/bin/sed 's/^context: //')"
    return 0
  fi
  lock="$HOOK_RUN/rotate.lock"
  _rotate_lock_take "$lock" stop || return 0
  _rotate_detach "$HOOK_RUN/rotate.log" "$TEAMCTL_SELF" _rotate-auto "$HOOK_ROLE" "$reason" "$session" "$ROTATE_LOCK_TOKEN"
  # cmd_hook runs no other module after this one at this Stop: no task reminder, no mail handed over,
  # nothing that would continue the turn the rotation waits for.
  ROTATE_STARTED=1
  return 0
}

# _rotate_wait_idle <run-dir> <seconds> - 0 once the agent's turn has ended (its Stop hook wrote
# "idle" to run/<role>/state), 1 when <seconds> pass first.
_rotate_wait_idle() {
  local waited=0 state=""
  while :; do
    state=""
    if [ -r "$1/state" ]; then IFS= read -r state <"$1/state" || true; fi
    [ "$state" != "idle" ] || return 0
    [ "$waited" -lt "$(($2 * 2))" ] || return 1
    sleep 0.5
    waited=$((waited + 1))
  done
}

# _rotate_figure <run-dir> - "142k/167k 85%" of that agent's last reading, or "not measured"
_rotate_figure() {
  local line
  line="$(_memory_ctx_line "$1")"
  printf '%s\n' "${line#context: }" | /usr/bin/sed 's/^$/not measured/'
}

# cmd_rotate <role> [--reason <text>] [--now]
cmd_rotate() {
  local role="" reason="" now=0 by
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --now) now=1 ;;
      --reason)
        [ "$#" -ge 2 ] || die_usage "--reason needs a text"
        reason="$2"
        shift
        ;;
      -*) die_usage "unknown option for rotate: $1" ;;
      *) role="$1" ;;
    esac
    shift
  done
  require_role_arg "$role"
  require_tools
  load_project
  [ "$role" != "$WOLFMUX_LEAD_ROLE" ] || die_usage "teamctl rotate is for workers in this release; the lead is not rotated (restart it: teamctl restart lead)"
  reg_exists "$role" || die "no such agent: $role  (see: teamctl status)"
  caller_resolve
  if [ -n "$CALLER_ROLE" ] && [ "$CALLER_ROLE" != "$WOLFMUX_LEAD_ROLE" ]; then
    caller_require_proven
    [ "$CALLER_ROLE" = "$role" ] ||
      die "a worker may rotate only itself. You are '$(team_identity "$TEAM" "$CALLER_ROLE")'; ask your lead to rotate '$role'." 77
  else
    require_manager rotate "$role"
  fi
  by="$(if [ -n "$CALLER_ROLE" ]; then team_identity "$TEAM" "$CALLER_ROLE"; else printf 'operator'; fi)"
  local dir rc=0
  dir="$(run_dir_ensure "$role")"
  if [ "${CALLER_ROLE:-}" = "$role" ] && _rotate_guarded "$dir" "$(reg_field "$role" session_id)"; then
    # The loop guard of the automatic path, for a worker rotating itself: without it, a confused worker
    # could rotate every turn. The lead is not held back by it.
    die "not rotated: this conversation was started by a rotation and has not been under its rotate threshold since, so a fresh one would start just as full and a rotation would not help. Commit, end your turn with where you stand, and tell your lead: the lead can still rotate it (teamctl rotate $role)."
  fi
  _rotate_lock_take "$dir/rotate.lock" rotate ||
    die "a rotation of '$role' is already under way ($dir/rotate.lock, ${ROTATE_LOCK_AGE:-?} s old; taken over after ${WOLFMUX_ROTATE_LOCK_STALE} s)"
  if [ -n "$CALLER_ROLE" ] && [ "$CALLER_ROLE" = "$role" ]; then
    # A worker rotating itself runs this inside its own tool call: the restart would end the process
    # that runs it, and its turn cannot end while it waits. A detached process does it; it waits for
    # the turn end as the default does (or not, with --now).
    : >"$dir/memory/rotate-due" 2>/dev/null || true
    _rotate_detach "$dir/rotate.log" "$TEAMCTL_SELF" _rotate-run "$role" "${reason:-asked by $by}" "$by" "$now" "$ROTATE_LOCK_TOKEN"
    say "rotation started: end your turn (wolfmux replaces this conversation once it has ended; log: $(short_path "$dir/rotate.log"))"
    return 0
  fi
  # In a subshell: whatever ends it (a die, another module's EXIT trap), the lock goes after it.
  (ROTATE_HAVE_LOCK=1 rotate_run "$role" "${reason:-asked by $by}" "$by" "$now" "") || rc=$?
  _rotate_lock_release "$dir/rotate.lock" "$ROTATE_LOCK_TOKEN"
  return "$rc"
}

# cmd_rotate_detached <role> <reason> <by> <now> <token> - internal (`teamctl _rotate-run`), detached by
# a worker's own `teamctl rotate`, which already holds run/<role>/rotate.lock.
cmd_rotate_detached() {
  local role="${1:-}" dir rc=0
  require_role_arg "$role"
  require_tools
  load_project
  _rotate_internal_gate "$role" "${5:-}"
  dir="$(run_dir "$role")"
  (ROTATE_HAVE_LOCK=1 rotate_run "$role" "$2" "$3" "$4" "") || rc=$?
  [ "$rc" -eq 0 ] || _rotate_failed "$role" "$dir" "$2"
  _rotate_lock_release "$dir/rotate.lock" "${5:-}"
  return "$rc"
}

# _rotate_failed <role> <run-dir> <reason> - a rotation nobody watches (the automatic one, a worker's own)
# ended without one: its output, the die included, is in rotate.log. rotate-fired and rotate-due go, so
# the next crossing may try again and the Stop hooks speak, and the lead gets one message to act on.
_rotate_failed() {
  local last
  /bin/rm -f "$2/memory/rotate-fired" "$2/memory/rotate-due" 2>/dev/null || true
  last="$(/usr/bin/tail -n 1 "$2/rotate.log" 2>/dev/null)"
  memory_store_lead_message "$(team_identity "$TEAM" "$WOLFMUX_LEAD_ROLE")" "$(team_identity "$TEAM" "$1")" "$1: rotation failed" \
    "rotation failed ($3), the old conversation goes on: ${last:-nothing in the log}
context: $(_rotate_figure "$2")
log: $2/rotate.log
teamctl rotate $1 : to retry" >/dev/null 2>&1 || true
}

# _rotate_declined <role> <run-dir> <reason> - the auto path found no task: the conversation may
# rotate later (rotate-fired goes), and the lead gets the context message the crossing held back,
# once per conversation (rotate-declined; both go at startup and clear).
_rotate_declined() {
  local lead percent=""
  /bin/rm -f "$2/memory/rotate-fired" "$2/memory/rotate-due" 2>/dev/null || true
  [ ! -e "$2/memory/rotate-declined" ] || return 0
  : >"$2/memory/rotate-declined" 2>/dev/null || true
  if [ -r "$2/memory/ctx" ]; then percent="$("$JQ_BIN" -r '.percent // empty' "$2/memory/ctx" 2>/dev/null)"; fi
  lead="$(team_identity "$TEAM" "$WOLFMUX_LEAD_ROLE")"
  memory_store_lead_message "$lead" "$(team_identity "$TEAM" "$1")" "$1: context at ${percent:-?}%" \
    "$3; not rotated: no task in progress. context: $(_rotate_figure "$2").
teamctl rotate $1 : a fresh conversation in the same worktree and branch, with a hand-over wolfmux writes" >/dev/null 2>&1 || true
}

# cmd_rotate_auto <role> <reason> <session> <token> - internal (`teamctl _rotate-auto`), detached from a
# Stop hook that already holds run/<role>/rotate.lock. Policy, task and family are asked here.
cmd_rotate_auto() {
  local role="${1:-}" reason="${2:-}" dir
  require_role_arg "$role"
  require_tools
  load_project
  _rotate_internal_gate "$role" "${4:-}"
  dir="$(run_dir "$role")"
  # In a subshell: whatever ends it (a die, another module's EXIT trap), the lock goes after it.
  (_rotate_auto_body "$role" "$reason") || _rotate_failed "$role" "$dir" "$reason"
  _rotate_lock_release "$dir/rotate.lock" "${4:-}"
}

_rotate_auto_body() {
  local role="$1" reason="$2" dir policy task lead
  dir="$(run_dir "$role")"
  reg_exists "$role" || return 0
  [ "$(reg_field "$role" family)" != "codex" ] || return 0
  task="$(memory_store_inprogress_task "$(team_identity "$TEAM" "$role")")" || task=""
  policy="$(policy_get worker-rotation)"
  [ "$policy" != "off" ] || return 0
  if [ -z "$task" ]; then
    # Under ask the lead was told at the crossing already; one message per conversation is right there.
    [ "$policy" != "auto" ] || _rotate_declined "$role" "$dir" "$reason"
    return 0
  fi
  lead="$(team_identity "$TEAM" "$WOLFMUX_LEAD_ROLE")"
  case "$policy" in
    off) return 0 ;;
    ask)
      memory_store_lead_message "$lead" "$(team_identity "$TEAM" "$role")" "$role: rotate it ($reason)" \
        "$reason. context: $(_rotate_figure "$dir").
teamctl rotate $role : wolfmux writes the hand-over, the task gets a fresh conversation in the same worktree and branch." >/dev/null 2>&1 || true
      return 0
      ;;
  esac
  # The task is asked again after the wait: it may have been finished in the meantime.
  rotate_run "$role" "$reason" "wolfmux (policy worker-rotation auto)" 0 "" 1
}

# _rotate_unrotated <rotated-file> <session-id> - drop the last line that is exactly <session-id>
_rotate_unrotated() {
  local tmp
  [ -n "$2" ] && [ -r "$1" ] || return 0
  tmp="$1.tmp.$$"
  /usr/bin/awk -v id="$2" '{ line[NR] = $0; if ($0 == id) last = NR } END { for (i = 1; i <= NR; i++) if (i != last) print line[i] }' "$1" >"$tmp" 2>/dev/null &&
    /bin/mv -f "$tmp" "$1" 2>/dev/null || /bin/rm -f "$tmp" 2>/dev/null || true
}

# _rotate_switch <role> <run-dir> <file> <task> <workdir> <old-session> <transcript> <reason> <by> - the
# hand-over, the marks the new conversation and the loop guard read, then the restart. Run in a subshell.
_rotate_switch() {
  rotate_handover_write "$3" "$4" "$2/memory/checkpoint.md" "$5" "$(reg_field "$1" base_commit)" \
    "$7" "$2/out/" "$8" "$9"
  # What must outlive the restart is written before it: the restart may end the pane this runs from.
  [ -z "$6" ] || printf '%s\n' "$6" >>"$2/memory/rotated"
  reg_set "$1" rotated_from "$6"
  event_log rotate "$1" "from ${6:-?}: $8"
  : >"$2/memory/handover.pending"
  # The permission to restart goes to cmd_restart in this process only: a plain shell variable of this
  # subshell, never exported (main() drops any ROTATE_ACTING that comes in from the environment).
  ROTATE_ACTING=1
  cmd_restart "$1" >/dev/null
}

# rotate_run <role> <reason> <by> <now 0|1> [<task-json>] [<require-task 0|1>]
rotate_run() {
  local role="$1" reason="$2" by="$3" now="$4" task="${5:-}" require="${6:-0}" dir workdir old_session transcript file old_fig new_fig lead was_from err
  # Whoever calls it: the lead is never rotated (its restart is the lead's own, or the founder's, call).
  [ "$role" != "$WOLFMUX_LEAD_ROLE" ] || die "the lead is not rotated (restart it: teamctl restart lead)" 77
  dir="$(run_dir_ensure "$role")"
  [ "$(reg_field "$role" family)" != "codex" ] || die "teamctl rotate is for Claude Code agents in this release; '$role' runs Codex (restart it: teamctl restart $role)"
  if [ "$now" -eq 0 ] && ! _rotate_wait_idle "$dir" "$WOLFMUX_ROTATE_WAIT"; then
    # No rotation after all: the Stop hooks of this conversation may speak again.
    /bin/rm -f "$dir/memory/rotate-due" 2>/dev/null || true
    die "'$role' did not end its turn within ${WOLFMUX_ROTATE_WAIT}s (WOLFMUX_ROTATE_WAIT): not rotated. To rotate it in the middle of its turn: teamctl rotate $role --now"
  fi
  [ -n "$task" ] || task="$(memory_store_inprogress_task "$(team_identity "$TEAM" "$role")")" || task=""
  if [ -z "$task" ] && [ "$require" = 1 ]; then
    # The automatic path, and the task was closed or handed back while it waited: nothing to continue.
    /bin/rm -f "$dir/memory/rotate-fired" "$dir/memory/rotate-due" 2>/dev/null || true
    say "not rotated: '$role' has no task in progress any more ($(now_iso)); rotate-fired cleared"
    return 0
  fi
  /bin/rm -f "$dir/memory/rotate-due" 2>/dev/null || true
  workdir="$(reg_field "$role" workdir)"
  old_session="$(reg_field "$role" session_id)"
  transcript="$(session_transcript "$old_session" "$workdir")"
  file="$dir/memory/handover.md"
  old_fig="$(_rotate_figure "$dir")"
  was_from="$(reg_field "$role" rotated_from 2>/dev/null)" || was_from=""
  # In a subshell: a die anywhere in it (the restart above all) is caught here, and what it wrote for
  # the new conversation is taken back, so the old one, which goes on, is neither guarded nor handed over.
  # Its error output is kept to name the cause in the one line that says it failed (rotate.log's last).
  if ! err="$( (_rotate_switch "$role" "$dir" "$file" "$task" "$workdir" "$old_session" "$transcript" "$reason" "$by") 2>&1)"; then
    /bin/rm -f "$dir/memory/handover.pending" "$dir/memory/rotate-due" 2>/dev/null || true
    _rotate_unrotated "$dir/memory/rotated" "$old_session"
    reg_set "$role" rotated_from "$was_from" 2>/dev/null || true
    err="$(printf '%s\n' "$err" | /usr/bin/sed -e 's/^teamctl: //' -e '/^[[:space:]]*$/d' | /usr/bin/tail -n 1)"
    die "the restart of '$role' failed (${err:-no message}): not rotated, the old conversation goes on (handover.pending and its rotated line taken back)"
  fi
  [ -z "$err" ] || printf '%s\n' "$err" >&2
  _rotate_note_new "$dir" "$(reg_field "$role" session_id)"
  /bin/rm -f "$dir/memory/rotate-fired" 2>/dev/null || true
  context_measured "$STATE_DIR" worker
  new_fig="about ${CM_FIRST:-?} at its first request (measured for this team), limit $(reg_field "$role" compact_window 2>/dev/null)"
  say "rotated: $role   (hand-over: $(short_path "$file"); the old conversation: teamctl restart $role --resume ${old_session:-?})"
  if [ "$by" != "$(team_identity "$TEAM" "$WOLFMUX_LEAD_ROLE")" ]; then
    lead="$(team_identity "$TEAM" "$WOLFMUX_LEAD_ROLE")"
    memory_store_lead_message "$lead" "$(team_identity "$TEAM" "$role")" "$role: rotated ($reason)" \
      "reason: $reason (asked by $by)
old conversation: $old_fig ($old_session; teamctl restart $role --resume $old_session reopens it)
new conversation: $new_fig
hand-over: $file" >/dev/null 2>&1 || true
  fi
}
