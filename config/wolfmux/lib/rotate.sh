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
#   rotate.lock                a directory: one rotation at a time per role

WOLFMUX_HANDOVER_CHARS="${WOLFMUX_HANDOVER_CHARS:-12000}"
WOLFMUX_ROTATE_WAIT="${WOLFMUX_ROTATE_WAIT:-120}"
# One cap per part, so no part can push another out. Their sum stays under the whole cap.
_ROTATE_CAP_TASK=3200
_ROTATE_CAP_CHECKPOINT=1500
_ROTATE_CAP_GIT=2800
_ROTATE_CAP_ANSWER=1500
_ROTATE_CAP_ANSWERS=3200
_ROTATE_CAP_TAIL=900

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
    printf '\n## d. your last answers, newest last\n'
    _rotate_answers "$6" | _hook_tail_cap "$_ROTATE_CAP_ANSWERS"
    printf '\n\n## e. paths\n'
    { printf 'old transcript: %s\noutput logs: %s\nthis hand-over: %s\n' "${6:-unknown}" "$7" "$file"
      printf '\n## f. why\nreason: %s\nasked by: %s\n' "$8" "$9"; } | _rotate_part "$_ROTATE_CAP_TAIL"
  })"
  printf '%s\n' "$body" | _hook_cap "$WOLFMUX_HANDOVER_CHARS" | _reg_write_atomic "$file"
}

# rotate_session_handover - SessionStart(startup): the hand-over, once, before anything else
rotate_session_handover() {
  local pending="$HOOK_RUN/memory/handover.pending" file="$HOOK_RUN/memory/handover.md"
  [ "$HOOK_SOURCE" = "startup" ] && [ -e "$pending" ] && [ -r "$file" ] || return 0
  /bin/rm -f "$pending" 2>/dev/null || true
  hook_context "[wolfmux] This is a fresh conversation for the same task: wolfmux replaced the full one and wrote this hand-over ($file). The work in your tree, committed or not, is yours to continue. Read it, then go on from where it stops; do not start over.

$(/bin/cat "$file" 2>/dev/null)"
}

# _rotate_session_rotated <session-id> - 0 when that conversation was rotated away or was started by a rotation
_rotate_session_rotated() {
  [ -n "$1" ] && /usr/bin/grep -q -e "^$1\$" -e "^new $1\$" "$HOOK_RUN/memory/rotated" 2>/dev/null
}

# rotate_at_stop - Stop, from recall_hook: a worker at or past its rotate threshold, or one
# that thrashes, is rotated at this turn end, detached. Cheap checks only here; the policy, the
# task and the family are asked by the detached process (teamctl _rotate-auto).
rotate_at_stop() {
  local percent="" rotate reason="" session lock
  [ -z "$(hook_input .agent_id)" ] || return 0
  [ "$HOOK_ROLE" != "${WOLFMUX_LEAD_ROLE:-lead}" ] || return 0
  [ "${WOLFMUX_WORKER_ROTATION:-}" != "off" ] || return 0
  if [ -r "$HOOK_RUN/memory/ctx" ]; then percent="$("$JQ_BIN" -r '.percent // empty' "$HOOK_RUN/memory/ctx" 2>/dev/null)"; fi
  rotate="$(_memory_threshold "${WOLFMUX_CONTEXT_ROTATE:-}" 80)"
  if [ -e "$HOOK_RUN/memory/thrash-told" ]; then
    reason="compacted twice within ${WOLFMUX_THRASH_CALLS:-10} tool calls"
  elif _rotate_num "$percent" && [ "$rotate" -gt 0 ] && [ "$percent" -ge "$rotate" ]; then
    reason="context at $percent% of its limit (rotate threshold $rotate%)"
  fi
  [ -n "$reason" ] || return 0
  [ ! -e "$HOOK_RUN/memory/rotate-fired" ] || return 0
  : >"$HOOK_RUN/memory/rotate-fired" 2>/dev/null || true
  session="$(hook_input .session_id)"
  if _rotate_session_rotated "$session"; then
    # A conversation a rotation started, already past the threshold: no second rotation.
    _memory_tell_lead "${percent:-?}" "$(_memory_ctx_line "$HOOK_RUN" | /usr/bin/sed 's/^context: //')"
    return 0
  fi
  lock="$HOOK_RUN/rotate.lock"
  /bin/mkdir "$lock" 2>/dev/null || return 0
  printf 'stop %s\n' "$(now_epoch)" >"$lock/by" 2>/dev/null || true
  ("$TEAMCTL_SELF" _rotate-auto "$HOOK_ROLE" "$reason" "$session" </dev/null >>"$HOOK_RUN/rotate.log" 2>&1 &) >/dev/null 2>&1
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
  /bin/mkdir "$dir/rotate.lock" 2>/dev/null || die "a rotation of '$role' is already under way ($dir/rotate.lock)"
  # In a subshell: whatever ends it (a die, another module's EXIT trap), the lock goes after it.
  (ROTATE_HAVE_LOCK=1 rotate_run "$role" "${reason:-asked by $by}" "$by" "$now" "") || rc=$?
  /bin/rm -rf "$dir/rotate.lock" 2>/dev/null || true
  return "$rc"
}

# cmd_rotate_auto <role> <reason> <session> - internal (`teamctl _rotate-auto`), detached from a
# Stop hook that already holds run/<role>/rotate.lock. Policy, task and family are asked here.
cmd_rotate_auto() {
  local role="$1" reason="$2" dir policy task lead
  require_tools
  load_project
  dir="$(run_dir "$role")"
  # In a subshell: whatever ends it (a die, another module's EXIT trap), the lock goes after it.
  (_rotate_auto_body "$role" "$reason")
  /bin/rm -rf "$dir/rotate.lock" 2>/dev/null || true
}

_rotate_auto_body() {
  local role="$1" reason="$2" dir policy task lead
  dir="$(run_dir "$role")"
  reg_exists "$role" || return 0
  [ "$(reg_field "$role" family)" != "codex" ] || return 0
  task="$(memory_store_inprogress_task "$(team_identity "$TEAM" "$role")")" || task=""
  [ -n "$task" ] || return 0
  policy="$(policy_get worker-rotation)"
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
  rotate_run "$role" "$reason" "wolfmux (policy worker-rotation auto)" 0 "$task"
}

# rotate_run <role> <reason> <by> <now 0|1> [<task-json>]
rotate_run() {
  local role="$1" reason="$2" by="$3" now="$4" task="${5:-}" dir workdir old_session transcript file old_fig new_fig lead
  dir="$(run_dir_ensure "$role")"
  [ "$(reg_field "$role" family)" != "codex" ] || die "teamctl rotate is for Claude Code agents in this release; '$role' runs Codex (restart it: teamctl restart $role)"
  if [ "$now" -eq 0 ] && ! _rotate_wait_idle "$dir" "$WOLFMUX_ROTATE_WAIT"; then
    die "'$role' did not end its turn within ${WOLFMUX_ROTATE_WAIT}s (WOLFMUX_ROTATE_WAIT): not rotated. To rotate it in the middle of its turn: teamctl rotate $role --now"
  fi
  [ -n "$task" ] || task="$(memory_store_inprogress_task "$(team_identity "$TEAM" "$role")")" || task=""
  workdir="$(reg_field "$role" workdir)"
  old_session="$(reg_field "$role" session_id)"
  transcript="$(session_transcript "$old_session" "$workdir")"
  file="$dir/memory/handover.md"
  old_fig="$(_rotate_figure "$dir")"
  rotate_handover_write "$file" "$task" "$dir/memory/checkpoint.md" "$workdir" "$(reg_field "$role" base_commit)" \
    "$transcript" "$dir/out/" "$reason" "$by"
  : >"$dir/memory/handover.pending"
  [ -z "$old_session" ] || printf '%s\n' "$old_session" >>"$dir/memory/rotated"
  ROTATE_ACTING=1 cmd_restart "$role" >/dev/null
  printf 'new %s\n' "$(reg_field "$role" session_id)" >>"$dir/memory/rotated"
  reg_set "$role" rotated_from "$old_session"
  /bin/rm -f "$dir/memory/rotate-fired" 2>/dev/null || true
  event_log rotate "$role" "from ${old_session:-?}: $reason"
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
