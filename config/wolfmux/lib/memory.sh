#!/bin/bash
# memory.sh — team memory, context watch, checkpoints. The contract is the header of lib/hooks.sh.
#
# Three things an agent is otherwise never told: what earlier agents of this project learned
# (Beads memories), how full its own conversation is, and where it (or its predecessor) left off.

# Numbers that are not WOLFMUX_CONTEXT_WARN / WOLFMUX_CONTEXT_ROTATE (already on the config
# allow list in lib/provider-env.sh). These stay environment-only, for a test to override;
# ~/.config/wolfmux/config does not touch them.
WOLFMUX_MEMORY_CHARS="${WOLFMUX_MEMORY_CHARS:-4000}"
WOLFMUX_CHECKPOINT_CHARS="${WOLFMUX_CHECKPOINT_CHARS:-8000}"
WOLFMUX_CHECKPOINT_MAX_AGE_H="${WOLFMUX_CHECKPOINT_MAX_AGE_H:-72}"

# _bd_bounded <seconds> <bd args...> — bd's own stdout, or nothing (exit 1) when bd is not
# installed, exits non-zero, or does not answer within <seconds>. macOS ships no timeout(1).
# Polls for the process to end rather than blocking on `wait "$pid"` racing a background
# killer: under this script's `set -e`, that blocking form was measured to hang past its own
# bound (bash never returns from the wait once a second background job exists to track), so
# a poll is the only shape here that reliably comes back on time.
_bd_bounded() {
  local secs="$1" tmp rc=1 waited=0 pid
  shift
  [ -n "$BD_BIN" ] || return 1
  tmp="$(mktemp 2>/dev/null)" || return 1
  "$BD_BIN" "$@" >"$tmp" 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$((secs * 10))" ]; then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      /bin/rm -f "$tmp" 2>/dev/null
      return 1
    fi
    /bin/sleep 0.1 2>/dev/null || true
    waited=$((waited + 1))
  done
  if wait "$pid" 2>/dev/null; then rc=0; fi
  [ "$rc" -eq 0 ] && /bin/cat "$tmp"
  /bin/rm -f "$tmp" 2>/dev/null
  return "$rc"
}

# _memory_clean <max-chars> — stdin to stdout: control characters and escape sequences gone
# (tab and newline kept, since a checkpoint is meant to read like a note), cut to length. A
# bead's or a transcript's text is data an agent did not write for a terminal; this is read
# back into one.
_memory_clean() {
  LC_ALL=C tr -d '\000-\010\013-\037\177' | /usr/bin/cut -c1-"$1"
}

# _memory_threshold <raw> <default> — an integer 1..99, else <default>; "0" or "off" is 0
# (disabled). Anything else (negative, over 99, not a number) is nonsense: falls back.
_memory_threshold() {
  local raw="$1" default="$2"
  case "$raw" in
    "") printf '%s\n' "$default"; return 0 ;;
    0 | off) printf '0\n'; return 0 ;;
    *[!0-9]*) printf '%s\n' "$default"; return 0 ;;
  esac
  if [ "$raw" -ge 1 ] && [ "$raw" -le 99 ]; then printf '%s\n' "$raw"; else printf '%s\n' "$default"; fi
}

# memory_store_* — every place this module calls bd (Beads), one function per operation, so a
# second, faster store can sit behind the same verbs later without anything else changing.
# Inputs are plain arguments, output is JSON or plain text on stdout, exit status says whether
# it worked. Nothing outside these functions calls bd or knows a bead's JSON shape beyond
# id, title, description, issue_type, status, priority, assignee, created_by.

# memory_store_memories_text — bd's own stdout for the team-memory block, or nothing (exit 1)
# when bd is missing, failing, or slower than 5s.
memory_store_memories_text() {
  _bd_bounded 5 prime --memories-only --max-memory-chars "$WOLFMUX_MEMORY_CHARS"
}

# memory_store_inprogress_task <identity> — that identity's one in_progress task bead, as a
# single JSON object (empty when none, or bd is missing, failing, or slower than 5s).
memory_store_inprogress_task() {
  local raw
  raw="$(_bd_bounded 5 list --assignee "$1" --status in_progress --type task --json -n 1)" || return 1
  printf '%s' "$raw" | "$JQ_BIN" -c '.[0] // empty' 2>/dev/null
}

# memory_store_task_note <id> <text> — appends a note to a task bead.
memory_store_task_note() {
  [ -n "$BD_BIN" ] || return 1
  "$BD_BIN" note "$1" "$2" >/dev/null 2>&1
}

# memory_store_lead_message <lead-identity> <subject> <body> — a message bead to the lead.
memory_store_lead_message() {
  [ -n "$BD_BIN" ] || return 1
  "$BD_BIN" create "$2" -t message -a "$1" -d "$3" >/dev/null 2>&1
}

# _memory_prime_body — the team-memory block's body (bd's own banner lines gone), or nothing
# (exit 1) when there are no memories, or bd is missing, failing, or slower than 5s.
_memory_prime_body() {
  local raw
  raw="$(memory_store_memories_text)" || return 1
  [ -n "$raw" ] || return 1
  case "$raw" in *"No memories stored"*) return 1 ;; esac
  printf '%s\n' "$raw" | sed -e '/^\[bd prime\] If this output is truncated/d' -e '/^Stored via `bd remember`/d' -e '/./,$!d'
}

# memory_hook <Event> — see lib/hooks.sh for the contract.
memory_hook() {
  case "$1" in
    SessionStart) _memory_session_start ;;
    PostToolUse) _memory_context_watch ;;
    PreCompact) _memory_precompact ;;
  esac
  return 0
}

_memory_session_start() {
  case "$HOOK_SOURCE" in
    startup | clear | compact) /bin/rm -f "$HOOK_RUN/memory/warned" 2>/dev/null || true ;;
  esac
  local body
  if body="$(_memory_prime_body)" && [ -n "$body" ]; then
    hook_context "[wolfmux memory] What this project's teams have learned (bd memories <word> to search, bd remember \"<fact>\" --key <slug> to add):

$body"
  fi
  case "$HOOK_SOURCE" in
    startup | compact | resume) _memory_session_checkpoint ;;
  esac
}

# _memory_session_checkpoint — SessionStart's "where you left off", read from this role's own
# checkpoint file. Never on `clear`: that is the user asking for a blank slate.
_memory_session_checkpoint() {
  local file="$HOOK_RUN/memory/checkpoint.md" mtime age_h
  [ -r "$file" ] || return 0
  mtime="$(/usr/bin/stat -f %m "$file" 2>/dev/null || printf 0)"
  [ "$mtime" -gt 0 ] || return 0
  age_h=$((($(now_epoch) - mtime) / 3600))
  if [ "$WOLFMUX_CHECKPOINT_MAX_AGE_H" -gt 0 ] && [ "$age_h" -ge "$WOLFMUX_CHECKPOINT_MAX_AGE_H" ]; then
    hook_context "[wolfmux memory] An old checkpoint exists (written ${age_h}h ago, past this role's ${WOLFMUX_CHECKPOINT_MAX_AGE_H}h limit): teamctl checkpoint --show $HOOK_ROLE to read it."
    return 0
  fi
  hook_context "[wolfmux memory] Where you left off (checkpoint of $(/bin/date -u -r "$mtime" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null), written by this role's previous or current conversation):

$(/bin/cat "$file" 2>/dev/null)"
}

# _memory_context_watch — PostToolUse: how full is this conversation, and has it crossed a
# threshold it has not already announced.
_memory_context_watch() {
  _ctx_of_transcript "$HOOK_TRANSCRIPT"
  [ -n "$CTX_TOKENS" ] || return 0
  local window percent
  window="$(model_context_window "${WOLFMUX_MODEL:-}")"
  [ -n "$window" ] && [ "$window" -gt 0 ] 2>/dev/null || window=200000
  percent=$((CTX_TOKENS * 100 / window))
  _memory_write_ctx "$CTX_TOKENS" "$window" "$percent"
  _memory_check_thresholds "$percent" "$CTX_TOKENS" "$window"
}

# _memory_write_ctx <tokens> <window> <percent> — one JSON line, atomically
_memory_write_ctx() {
  "$JQ_BIN" -cn --argjson tokens "$1" --argjson window "$2" --argjson percent "$3" --argjson at "$(now_epoch)" \
    '{tokens: $tokens, window: $window, percent: $percent, at: $at}' 2>/dev/null | _reg_write_atomic "$HOOK_RUN/memory/ctx"
}

_memory_warned() { grep -qx "$1" "$HOOK_RUN/memory/warned" 2>/dev/null; }
_memory_mark_warned() { printf '%s\n' "$1" >>"$HOOK_RUN/memory/warned" 2>/dev/null || true; }

# _memory_check_thresholds <percent> <tokens> <window> — warn and rotate each fire once per
# conversation (lib/hooks.sh.memory_hook SessionStart resets memory/warned).
_memory_check_thresholds() {
  local percent="$1" tokens="$2" window="$3" warn rotate
  warn="$(_memory_threshold "${WOLFMUX_CONTEXT_WARN:-}" 60)"
  rotate="$(_memory_threshold "${WOLFMUX_CONTEXT_ROTATE:-}" 80)"
  if [ "$warn" -gt 0 ] && [ "$rotate" -gt 0 ] && [ "$warn" -ge "$rotate" ]; then warn=60 rotate=80; fi
  if [ "$rotate" -gt 0 ] && [ "$percent" -ge "$rotate" ] && ! _memory_warned rotate; then
    _memory_mark_warned rotate
    hook_context "[wolfmux] Your conversation holds ${percent}% of its window. Do not start anything new: commit, run
teamctl checkpoint \"<done so far / what is next / what to watch out for>\", and finish or hand back the current step. The lead has been told and may
give this task a fresh conversation."
    [ "$HOOK_ROLE" = "lead" ] || _memory_tell_lead "$percent" "$tokens" "$window"
  fi
  if [ "$warn" -gt 0 ] && [ "$percent" -ge "$warn" ] && ! _memory_warned warn; then
    _memory_mark_warned warn
    hook_context "[wolfmux] Your conversation holds ${percent}% of its window. Commit what works now. Then record where you
stand, so nothing is lost if this conversation is compacted or replaced:
teamctl checkpoint \"<done so far / what is next / what to watch out for>\""
  fi
}

# _memory_tell_lead <percent> <tokens> <window> — a message bead to this team's lead, detached:
# a bd write is slow enough that a hook may never wait on it.
_memory_tell_lead() {
  [ -n "$BD_BIN" ] || return 0
  local lead body
  lead="$(team_identity "${WOLFMUX_TEAM:-$WOLFMUX_DEFAULT_TEAM}" lead)"
  body="tokens: $2 of $3 ($1%)
checkpoint: $HOOK_RUN/memory/checkpoint.md
teamctl restart $HOOK_ROLE : a new conversation in the same worktree and branch; it starts from the checkpoint"
  (
    memory_store_lead_message "$lead" "$HOOK_ROLE: context at $1%" "$body" &
  ) >/dev/null 2>&1
}

# _memory_precompact — the agent cannot be asked anything here: append what can be read from
# the filesystem alone, and never take long doing it.
_memory_precompact() {
  local file="$HOOK_RUN/memory/checkpoint.md" branch head status_lines log_lines
  branch="$("$GIT_BIN" branch --show-current 2>/dev/null)" || branch=""
  head="$("$GIT_BIN" rev-parse --short HEAD 2>/dev/null)" || head=""
  status_lines="$("$GIT_BIN" status --short 2>/dev/null | /usr/bin/head -n 20)" || status_lines=""
  log_lines="$("$GIT_BIN" log --oneline -5 2>/dev/null)" || log_lines=""
  {
    printf '\n## state at compaction %s\n' "$(now_iso)"
    [ -z "$branch" ] || printf 'branch: %s\n' "$branch"
    [ -z "$head" ] || printf 'head: %s\n' "$head"
    printf 'git status --short (first 20 lines):\n%s\n' "$status_lines"
    printf 'git log --oneline -5:\n%s\n' "$log_lines"
  } >>"$file" 2>/dev/null || true
}

# _checkpoint_header <role> <stamp> <task-id> <task-title>
_checkpoint_header() {
  local role="$1" stamp="$2" task_id="$3" task_title="$4" branch head dirty
  branch="$("$GIT_BIN" branch --show-current 2>/dev/null)" || branch=""
  head="$("$GIT_BIN" rev-parse --short HEAD 2>/dev/null)" || head=""
  dirty="$("$GIT_BIN" status --porcelain 2>/dev/null | /usr/bin/wc -l | tr -d '[:space:]')" || dirty="?"
  printf '# checkpoint %s\n' "$stamp"
  printf 'role: %s\n' "$role"
  [ -z "$branch" ] || printf 'branch: %s\n' "$branch"
  [ -z "$head" ] || printf 'head: %s\n' "$head"
  printf 'uncommitted files: %s\n' "$dirty"
  [ -z "$task_id" ] || printf 'task: %s %s\n' "$task_id" "$task_title"
  printf '\n'
}

# _memory_role_dir <role> — that role's run directory. $WOLFMUX_RUN_DIR directly when it
# already names this same role (an agent, about itself: no tmux lookup needed, and it must
# be the exact directory a hook of its own reads back); load_project + run_dir otherwise, for
# naming another role, or running outside an agent's own environment.
_memory_role_dir() {
  if [ -n "${WOLFMUX_RUN_DIR:-}" ] && [ "$1" = "${TEAM_ROLE:-}" ]; then
    printf '%s\n' "$WOLFMUX_RUN_DIR"
    return 0
  fi
  require_tools
  load_project
  run_dir "$1"
}

# cmd_checkpoint "<text>" | --body-file <file> | - | --show [<role>]
cmd_checkpoint() {
  local mode="write" text="" file="" show_role="" role dir cur prev stamp task_id="" task_title="" task_json clean_text
  case "${1:-}" in
    --show)
      mode="show"
      shift
      show_role="${1:-}"
      ;;
    --body-file)
      shift
      file="${1:-}"
      [ -n "$file" ] || die_usage "--body-file needs a path"
      [ -r "$file" ] || die_usage "cannot read $file"
      text="$(/bin/cat "$file" 2>/dev/null)"
      ;;
    -) text="$(/bin/cat)" ;;
    *) text="${1:-}" ;;
  esac
  require_tools
  if [ "$mode" = "show" ]; then
    role="${show_role:-${TEAM_ROLE:-}}"
    require_role_arg "$role"
    dir="$(_memory_role_dir "$role")"
    [ -r "$dir/memory/checkpoint.md" ] || die "no checkpoint stored for '$role'"
    /bin/cat "$dir/memory/checkpoint.md"
    return 0
  fi
  [ -n "$text" ] || die_usage 'usage: teamctl checkpoint "<text>" | --body-file <file> | - | --show [<role>]'
  role="${TEAM_ROLE:-}"
  require_role_arg "$role"
  dir="$(_memory_role_dir "$role")"
  /bin/mkdir -p "$dir/memory" 2>/dev/null || true
  cur="$dir/memory/checkpoint.md"
  prev="$dir/memory/checkpoint.prev.md"
  stamp="$(now_iso)"
  if [ -n "${BEADS_ACTOR:-}" ]; then
    task_json="$(memory_store_inprogress_task "$BEADS_ACTOR")" || task_json=""
    task_id="$(printf '%s' "$task_json" | "$JQ_BIN" -r '.id // empty' 2>/dev/null)"
    task_title="$(printf '%s' "$task_json" | "$JQ_BIN" -r '.title // empty' 2>/dev/null)"
  fi
  clean_text="$(printf '%s' "$text" | _memory_clean "$WOLFMUX_CHECKPOINT_CHARS")"
  [ ! -r "$cur" ] || /bin/cp "$cur" "$prev" 2>/dev/null || true
  {
    _checkpoint_header "$role" "$stamp" "$task_id" "$task_title"
    printf '%s\n' "$clean_text"
  } | _reg_write_atomic "$cur"
  say "checkpoint saved: $(short_path "$cur")"
  if [ -n "$task_id" ] && [ -n "$BD_BIN" ]; then
    (
      memory_store_task_note "$task_id" "checkpoint $stamp: $clean_text" &
    ) >/dev/null 2>&1
  fi
}
