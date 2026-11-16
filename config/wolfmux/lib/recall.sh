#!/bin/bash
# recall.sh — team memory, context watch, checkpoints. The contract is the header of lib/hooks.sh.
#
# Three things an agent is otherwise never told: what earlier agents of this project learned
# (team memory, lib/store.sh), how full its own conversation is, and where it (or its
# predecessor) left off. Every read of team memory or a task here goes through the store_*
# interface; _bd_bounded (lib/store.sh) bounds the Beads half of it to 5s, since this runs
# inside a hook, which may never hang on a slow write queue. The native backend is fast
# enough that nothing here bounds it.

# Numbers that are not WOLFMUX_CONTEXT_WARN / WOLFMUX_CONTEXT_ROTATE (already on the config
# allow list in lib/provider-env.sh). These stay environment-only, for a test to override;
# ~/.config/wolfmux/config does not touch them.
WOLFMUX_MEMORY_CHARS="${WOLFMUX_MEMORY_CHARS:-4000}"
WOLFMUX_MEMORY_NOTE_MAX="${WOLFMUX_MEMORY_NOTE_MAX:-1500}" # one teamctl remember note, refused above this
WOLFMUX_CHECKPOINT_CHARS="${WOLFMUX_CHECKPOINT_CHARS:-8000}"
WOLFMUX_CHECKPOINT_MAX_AGE_H="${WOLFMUX_CHECKPOINT_MAX_AGE_H:-72}"

# _memory_clean <max-chars> — stdin to stdout: control characters and escape sequences gone
# (tab and newline kept, since a checkpoint is meant to read like a note), cut to the whole
# text's length, not per line (_hook_cap, lib/hooks.sh). A bead's or a transcript's text is
# data an agent did not write for a terminal; this is read back into one.
_memory_clean() {
  LC_ALL=C tr -d '\000-\010\013-\037\177' | _hook_cap "$1"
}

# _memory_quote_notes — stdin to stdout: the shared notes cleaned as mail bodies are
# (lib/mail.sh _mail_sanitize_body): control characters and escape sequences gone, tab and
# newline kept, and a line that starts "[wolfmux" quoted with "> " so a note can never pass
# for a wolfmux notice in an agent's context. No length cap here: the block already has one.
_memory_quote_notes() {
  LC_ALL=C /usr/bin/tr -d '\000-\010\013-\037\177' | /usr/bin/sed 's/^\[wolfmux/> [wolfmux/'
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

# memory_store_* — every place this module reads or writes the store, one function per
# operation, through lib/store.sh's store_* interface. On the Beads backend, a read is
# bounded to 5s (_bd_bounded, lib/store.sh): this runs inside a hook, which may never hang
# on a slow write queue. The native backend is fast enough that nothing here bounds it.

# memory_store_memories_text — the team-memory block's text, or nothing (exit 1) when there
# are no memories, or the store is unreachable or (Beads) slower than 5s.
memory_store_memories_text() {
  local body
  case "$(store_kind)" in
    native) body="$(store_memory_text "$WOLFMUX_MEMORY_CHARS")" ;;
    beads) body="$(_bd_bounded 5 store_memory_text "$WOLFMUX_MEMORY_CHARS")" ;;
  esac
  [ -n "$body" ] || return 1
  printf '%s\n' "$body"
}

# memory_store_inprogress_task <identity> — that identity's one in_progress task, as a single
# JSON object (empty when none, or the store is unreachable or (Beads) slower than 5s).
memory_store_inprogress_task() {
  local raw
  case "$(store_kind)" in
    native) raw="$(store_tasks_json "$1" in_progress)" || return 1 ;;
    beads) raw="$(_bd_bounded 5 store_tasks_json "$1" in_progress)" || return 1 ;;
  esac
  printf '%s' "${raw:-[]}" | "$JQ_BIN" -c '.[0] // empty' 2>/dev/null
}

# memory_store_task_note <id> <author> <text> — appends a note to a task.
memory_store_task_note() { store_task_note "$1" "$2" "$3"; }

# memory_store_lead_message <lead-identity> <sender-identity> <subject> <body> — a message to
# the lead, announced (a no-op in Beads mode: its own hook already delivers).
memory_store_lead_message() {
  local lead="$1" sender="$2" subject="$3" body="$4" id
  id="$(store_msg_create "$sender" "$lead" "$subject" "$body")" || return 1
  mail_announce create "$(store_item_json "$id")" "$sender"
}

# recall_hook <Event> — see lib/hooks.sh for the contract.
recall_hook() {
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
  if body="$(memory_store_memories_text)" && body="$(printf '%s\n' "$body" | _memory_quote_notes)" && [ -n "$body" ]; then
    hook_context "[wolfmux memory] What this project's teams have learned (teamctl memories <word> to search, teamctl remember \"<fact>\" to add):

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

$(/bin/cat "$file" 2>/dev/null | _hook_tail_cap "$WOLFMUX_CHECKPOINT_CHARS")"
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
# conversation (recall_hook SessionStart resets memory/warned).
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

# _memory_tell_lead <percent> <tokens> <window> — a message to this team's lead, detached: a
# store write is slow enough (Beads) that a hook may never wait on it.
_memory_tell_lead() {
  local lead sender body
  lead="$(team_identity "${WOLFMUX_TEAM:-$WOLFMUX_DEFAULT_TEAM}" lead)"
  sender="${BEADS_ACTOR:-$HOOK_ROLE}"
  body="tokens: $2 of $3 ($1%)
checkpoint: $HOOK_RUN/memory/checkpoint.md
teamctl restart $HOOK_ROLE : a new conversation in the same worktree and branch; it starts from the checkpoint"
  (
    memory_store_lead_message "$lead" "$sender" "$HOOK_ROLE: context at $1%" "$body" &
  ) >/dev/null 2>&1
}

_MEMORY_PRECOMPACT_MARKER="## state at compaction "

# _memory_precompact — the agent cannot be asked anything here: add what can be read from the
# filesystem alone, and never take long doing it. Appending without bound would let the file
# grow forever across many compactions, so this keeps the agent's own text (everything before
# the first automatic section) plus only the newest of the EXISTING automatic sections, which
# together with the one just added makes two.
_memory_precompact() {
  local file="$HOOK_RUN/memory/checkpoint.md" branch head status_lines log_lines
  local marker_lines first_marker last_marker own_text="" keep=""
  branch="$("$GIT_BIN" branch --show-current 2>/dev/null)" || branch=""
  head="$("$GIT_BIN" rev-parse --short HEAD 2>/dev/null)" || head=""
  status_lines="$("$GIT_BIN" status --short 2>/dev/null | /usr/bin/head -n 20)" || status_lines=""
  log_lines="$("$GIT_BIN" log --oneline -5 2>/dev/null)" || log_lines=""
  if [ -r "$file" ]; then
    marker_lines="$(/usr/bin/grep -n "^$_MEMORY_PRECOMPACT_MARKER" "$file" 2>/dev/null | /usr/bin/cut -d: -f1)"
    if [ -n "$marker_lines" ]; then
      first_marker="$(printf '%s\n' "$marker_lines" | /usr/bin/head -1)"
      last_marker="$(printf '%s\n' "$marker_lines" | /usr/bin/tail -1)"
      own_text="$(/usr/bin/head -n "$((first_marker - 1))" "$file")"
      keep="$(/usr/bin/tail -n "+$last_marker" "$file")"
    else
      own_text="$(/bin/cat "$file")"
    fi
  fi
  {
    [ -z "$own_text" ] || printf '%s\n' "$own_text"
    [ -z "$keep" ] || printf '%s\n' "$keep"
    printf '%s%s\n' "$_MEMORY_PRECOMPACT_MARKER" "$(now_iso)"
    [ -z "$branch" ] || printf 'branch: %s\n' "$branch"
    [ -z "$head" ] || printf 'head: %s\n' "$head"
    printf 'git status --short (first 20 lines):\n%s\n' "$status_lines"
    printf 'git log --oneline -5:\n%s\n' "$log_lines"
  } | _reg_write_atomic "$file" 2>/dev/null || true
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
  load_project
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
  if [ -n "$task_id" ]; then
    (
      memory_store_task_note "$task_id" "${BEADS_ACTOR:-$role}" "checkpoint $stamp: $clean_text" &
    ) >/dev/null 2>&1
  fi
}

# _memory_slug <text> — the first few words, lowercased and hyphenated: a default --key.
_memory_slug() {
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -c "${_WM_LOWER}${_WM_DIGITS}" '-' \
    | cut -c1-48 | sed -E 's/-+/-/g; s/^-//; s/-$//'
}

# teamctl remember "<fact>" [--key <slug>] — team memory, any agent. Key default: a slug
# from the first words.
cmd_remember() {
  local text="" key="" positional=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --key)
        [ "$#" -ge 2 ] || die_usage "--key needs a slug"
        key="$2"
        shift
        ;;
      -*) die_usage "unknown option for remember: $1" ;;
      *) positional+=("$1") ;;
    esac
    shift
  done
  text="${positional[0]:-}"
  [ -n "$text" ] || die_usage 'usage: teamctl remember "<fact>" [--key <slug>]'
  [ "${#text}" -le "$WOLFMUX_MEMORY_NOTE_MAX" ] ||
    die_usage "a note is at most $WOLFMUX_MEMORY_NOTE_MAX characters (this one has ${#text}); keep it to one fact, and put the detail in a doc or a task note"
  [ -n "$key" ] || key="$(_memory_slug "$text")"
  require_tools
  load_project
  store_memory_set "$key" "$text" "${BEADS_ACTOR:-$(caller_role)}" ||
    die_usage "invalid --key '$key' (lowercase letters, digits and '-', max 64) or the store is unreachable"
  say "remembered: $key"
}

# teamctl memories [<query>] [--json]
cmd_memories() {
  local query="" asjson=0 rows count
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) asjson=1 ;;
      -*) die_usage "unknown option for memories: $1" ;;
      *) query="$1" ;;
    esac
    shift
  done
  require_tools
  load_project
  rows="$(store_memory_list_json "$query")" || die "could not read memory"
  if [ "$asjson" -eq 1 ]; then
    printf '%s\n' "${rows:-[]}"
    return 0
  fi
  count="$(printf '%s' "${rows:-[]}" | "$JQ_BIN" -r 'length' 2>/dev/null)"
  case "$count" in '' | *[!0-9]*) count=0 ;; esac
  if [ "$count" -eq 0 ]; then
    say "no memories"
    return 0
  fi
  printf '%s' "$rows" | "$JQ_BIN" -r '.[] | "### " + .key + "\n" + .text + "\n"'
}

# teamctl forget <key>
cmd_forget() {
  local key="${1:-}"
  [ -n "$key" ] || die_usage "usage: teamctl forget <key>"
  require_tools
  load_project
  store_memory_forget "$key" || die "no such memory: $key"
  say "forgotten: $key"
}
