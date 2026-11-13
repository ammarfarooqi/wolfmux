#!/bin/bash
# tasks.sh — hand out work, report it, never stop with work forgotten.
# The contract is the header of lib/hooks.sh. Beads (bd) stays the record; these three
# commands are the short, safe spelling of what the protocol already asks for in a few
# `bd` calls, plus the Stop reminder (tasks_hook) that catches work left open under an
# agent's name when its turn ends.
#
# Every `bd` invocation of this module lives in one of the tasks_store_* functions below:
# plain arguments in, JSON or plain text on stdout, exit status says whether it worked.
# Nothing else in this file calls bd, or knows a bead's JSON shape beyond id, title,
# status and (through length) how many a list holds — so the store can be swapped for a
# faster one later (a local sqlite3 index is planned) without touching a command above it.

# tasks_store_create <title> <priority> <assignee> [<description>] — prints the new id.
tasks_store_create() {
  local title="$1" priority="$2" assignee="$3" desc="${4:-}"
  if [ -n "$desc" ]; then
    "$BD_BIN" create "$title" -t task -p "$priority" -a "$assignee" -d "$desc" --silent
  else
    "$BD_BIN" create "$title" -t task -p "$priority" -a "$assignee" --silent
  fi
}

# tasks_store_add_dependency <id> <blocker-id> — <id> cannot start before <blocker-id> is closed.
tasks_store_add_dependency() { "$BD_BIN" dep add "$1" "$2" >/dev/null; }

# tasks_store_title <id> — empty when there is no such bead.
tasks_store_title() { "$BD_BIN" show "$1" --json 2>/dev/null | "$JQ_BIN" -r '.[0].title // empty'; }

# tasks_store_close <id> <reason>
tasks_store_close() { "$BD_BIN" close "$1" -r "$2" >/dev/null; }

# tasks_store_block <id> <note> — status blocked, note appended
tasks_store_block() { "$BD_BIN" update "$1" --status blocked --append-notes "$2" >/dev/null; }

# tasks_store_reply <to-identity> <subject> <body> <reply-to-id> — a message bead that
# replies to a task; `bd dep add` accepts a free-form dependency type (confirmed against a
# throwaway repo), so this needs no fallback that names the task id in the body instead.
tasks_store_reply() {
  local to="$1" subject="$2" body="$3" reply_to="$4"
  "$BD_BIN" create "$subject" -t message -a "$to" -d "$body" --deps "replies-to:$reply_to" --silent >/dev/null
}

# tasks_store_list <identity> <status-csv> [<timeout-seconds>] — that identity's beads in
# those statuses, as JSON. `bd list` without --include-infra already hides messages (an
# infra bead type), so a task lookup never has to filter them out by hand. With a timeout,
# the call is bounded by wall clock instead of running straight (a hook may never hang the
# agent on a slow write queue; no `timeout` binary is a dependency here, macOS ships none).
tasks_store_list() {
  local me="$1" statuses="$2" secs="${3:-0}"
  if [ "$secs" -gt 0 ]; then
    _tasks_bd_timeout "$secs" list --assignee "$me" --status "$statuses" --json
  else
    "$BD_BIN" list --assignee "$me" --status "$statuses" --json 2>/dev/null
  fi
}

# _tasks_bd_timeout <seconds> <bd argument>... — the wall-clock bound behind tasks_store_list.
_tasks_bd_timeout() {
  local secs="$1" out pid waited=0 rc=0
  shift
  out="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/wolfmux-bd.XXXXXX")" || return 1
  ("$BD_BIN" "$@" >"$out" 2>/dev/null) &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      # Both can legitimately fail here (the process may have just exited on its own,
      # between the check above and this line): a hook may never die on that race.
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
      /bin/rm -f "$out"
      return 1
    fi
    sleep 1 2>/dev/null || true
    waited=$((waited + 1))
  done
  # `wait`'s own exit status is bd's; captured through an if, not a bare statement,
  # so a nonzero one (bd failed) does not trip this script's `set -e`.
  if wait "$pid"; then rc=0; else rc=$?; fi
  /bin/cat "$out" 2>/dev/null
  /bin/rm -f "$out"
  return "$rc"
}

# _tasks_default_id <identity> — the caller's only in_progress task, when no bead id was
# given on the command line.
_tasks_default_id() {
  local me="$1" json count
  json="$(tasks_store_list "$me" in_progress)" || die "bd list failed"
  count="$(printf '%s' "$json" | "$JQ_BIN" -r 'length' 2>/dev/null)"
  case "$count" in
    1) printf '%s' "$json" | "$JQ_BIN" -r '.[0].id' ;;
    0) die "no bead id given, and '$me' has no in_progress task. Name one: teamctl done <bead-id> \"...\"" 64 ;;
    *) die "no bead id given, and '$me' has more than one in_progress task: $(printf '%s' "$json" | "$JQ_BIN" -r '[.[].id] | join(" ")'). Name one of them." 64 ;;
  esac
}

# _tasks_commit_report <worktree> <base-commit> — up to 30 "git log --oneline" lines of
# base..HEAD, and how many commits there are in total (the model is report_commits, lib/agents.sh).
_tasks_commit_report() {
  local path="$1" base="$2" total
  total="$("$GIT_BIN" -C "$path" rev-list --count "$base..HEAD" 2>/dev/null)"
  printf 'commits (%s):\n' "${total:-0}"
  "$GIT_BIN" -C "$path" log --oneline -n 30 "$base..HEAD" 2>/dev/null
}

# teamctl task <role> "<title>" [-d "<text>" | --body-file <file> | -] [-p <0-4>] [--after <bead-id>]... [--spawn <model>]
cmd_task() {
  local role="" title="" desc="" body_file="" priority="2" spawn_model="" after=() positional=0 id me blocker
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -d)
        [ "$#" -ge 2 ] || die_usage "-d needs text"
        desc="$2"
        shift
        ;;
      --body-file)
        [ "$#" -ge 2 ] || die_usage "--body-file needs a path"
        body_file="$2"
        shift
        ;;
      -) body_file="-" ;;
      -p)
        [ "$#" -ge 2 ] || die_usage "-p needs 0-4"
        priority="$2"
        shift
        ;;
      --after)
        [ "$#" -ge 2 ] || die_usage "--after needs a bead id"
        valid_bead_id "$2" || die_usage "invalid bead id '$2'"
        after+=("$2")
        shift
        ;;
      --spawn)
        [ "$#" -ge 2 ] || die_usage "--spawn needs a model"
        spawn_model="$2"
        shift
        ;;
      -*) die_usage "unknown option for task: $1" ;;
      *)
        case "$positional" in
          0) role="$1" ;;
          1) title="$1" ;;
          *) die_usage "unexpected argument: $1" ;;
        esac
        positional=$((positional + 1))
        ;;
    esac
    shift
  done
  [ -n "$role" ] && [ -n "$title" ] ||
    die_usage 'usage: teamctl task <role> "<title>" [-d "<text>" | --body-file <file> | -] [-p <0-4>] [--after <bead-id>]... [--spawn <model>]'
  require_role_arg "$role"
  case "$priority" in [0-4]) ;; *) die_usage "-p must be 0-4" ;; esac
  [ -n "$BD_BIN" ] || die "Beads (bd) is not installed; the team uses it for tasks and messages. See: teamctl doctor"
  require_tools
  load_project
  require_manager task
  me="$(team_identity "$TEAM" "$role")"
  if [ "$body_file" = "-" ]; then
    desc="$(/bin/cat)"
  elif [ -n "$body_file" ]; then
    desc="$(/bin/cat "$body_file" 2>/dev/null)" || die "cannot read --body-file: $body_file"
  fi
  id="$(tasks_store_create "$title" "$priority" "$me" "$desc")" || die "bd create failed"
  id="$(printf '%s' "$id" | tr -d '[:space:]')"
  [ -n "$id" ] || die "bd create produced no id"
  for blocker in "${after[@]:-}"; do
    [ -n "$blocker" ] || continue
    tasks_store_add_dependency "$id" "$blocker" || die "bd dep add $id $blocker failed"
  done
  if [ -n "$spawn_model" ]; then
    if reg_exists "$role"; then
      say "--spawn ignored: '$role' is already running; the Beads hook delivers the task."
    else
      cmd_spawn "$role" "$spawn_model"
    fi
  elif ! reg_exists "$role"; then
    say "no agent named '$role' is on record; the task waits. Staff it: teamctl spawn $role <model>"
  fi
  say "task $id -> $me"
}

# teamctl done [<bead-id>] "<summary>" [--tests "<command: result>"] [--body-file <file>] [--allow-dirty]
cmd_done() {
  local id="" summary="" tests="" body_file="" allow_dirty=0 args=()
  local role me path branch base_commit title tests_line commits_block stat_line short_sha report extra lead_id
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tests)
        [ "$#" -ge 2 ] || die_usage '--tests needs "<command: result>"'
        tests="$2"
        shift
        ;;
      --body-file)
        [ "$#" -ge 2 ] || die_usage "--body-file needs a path"
        body_file="$2"
        shift
        ;;
      --allow-dirty) allow_dirty=1 ;;
      -*) die_usage "unknown option for done: $1" ;;
      *) args+=("$1") ;;
    esac
    shift
  done
  case "${#args[@]}" in
    1) summary="${args[0]}" ;;
    2) id="${args[0]}" summary="${args[1]}" ;;
    *) die_usage 'usage: teamctl done [<bead-id>] "<summary>" [--tests "<command: result>"] [--body-file <file>] [--allow-dirty]' ;;
  esac
  [ -n "$summary" ] || die_usage 'usage: teamctl done [<bead-id>] "<summary>" [--tests "<command: result>"] [--body-file <file>] [--allow-dirty]'
  [ -n "$BD_BIN" ] || die "Beads (bd) is not installed; the team uses it for tasks and messages. See: teamctl doctor"
  require_tools
  load_project
  role="$(caller_role)"
  [ -n "$role" ] || die_usage "run 'teamctl done' from inside your own agent pane (TEAM_ROLE is unset)"
  reg_exists "$role" || die "no registry record for role '$role' in $(short_path "$ROOT")"
  me="$(team_identity "$TEAM" "$role")"
  if [ -n "$id" ]; then
    valid_bead_id "$id" || die_usage "invalid bead id '$id'"
  else
    id="$(_tasks_default_id "$me")" || exit $?
  fi
  path="$(reg_field "$role" workdir)"
  [ -d "$path" ] || die "working directory is gone: $path"
  if [ "$allow_dirty" -eq 0 ] && [ -n "$("$GIT_BIN" -C "$path" status --porcelain 2>/dev/null)" ]; then
    die "uncommitted changes in $(short_path "$path"); commit first, or pass --allow-dirty."
  fi
  branch="$(reg_field "$role" branch)"
  base_commit="$(reg_field "$role" base_commit)"
  title="$(tasks_store_title "$id")"
  [ -n "$title" ] || die "no such task: $id"

  if [ -n "$tests" ]; then tests_line="tests: $tests"; else tests_line="tests: not stated"; fi
  commits_block="$(_tasks_commit_report "$path" "$base_commit")"
  stat_line="$("$GIT_BIN" -C "$path" diff --stat "$base_commit..HEAD" 2>/dev/null | tail -1)"
  short_sha="$("$GIT_BIN" -C "$path" rev-parse --short HEAD 2>/dev/null)"
  report="$summary
$tests_line
branch: $branch
$commits_block
$stat_line"
  if [ -n "$body_file" ]; then
    extra="$(/bin/cat "$body_file" 2>/dev/null)" || die "cannot read --body-file: $body_file"
    report="$report

$extra"
  fi

  lead_id="$(team_identity "$TEAM" "$WOLFMUX_LEAD_ROLE")"
  if [ "$role" != "$WOLFMUX_LEAD_ROLE" ]; then
    tasks_store_reply "$lead_id" "Done: $title" "$report" "$id" || die "bd create (report message to $lead_id) failed"
    say "sent: Done: $title -> $lead_id"
  fi
  tasks_store_close "$id" "commit $short_sha; $(printf '%s' "$summary" | head -1)" || die "bd close $id failed"
  say "closed: $id"
}

# teamctl blocked [<bead-id>] "<why>"
cmd_blocked() {
  local id="" why="" args=() role me title lead_id
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -*) die_usage "unknown option for blocked: $1" ;;
      *) args+=("$1") ;;
    esac
    shift
  done
  case "${#args[@]}" in
    1) why="${args[0]}" ;;
    2) id="${args[0]}" why="${args[1]}" ;;
    *) die_usage 'usage: teamctl blocked [<bead-id>] "<why>"' ;;
  esac
  [ -n "$why" ] || die_usage 'usage: teamctl blocked [<bead-id>] "<why>"'
  [ -n "$BD_BIN" ] || die "Beads (bd) is not installed; the team uses it for tasks and messages. See: teamctl doctor"
  require_tools
  load_project
  role="$(caller_role)"
  [ -n "$role" ] || die_usage "run 'teamctl blocked' from inside your own agent pane (TEAM_ROLE is unset)"
  me="$(team_identity "$TEAM" "$role")"
  if [ -n "$id" ]; then
    valid_bead_id "$id" || die_usage "invalid bead id '$id'"
  else
    id="$(_tasks_default_id "$me")" || exit $?
  fi
  title="$(tasks_store_title "$id")"
  [ -n "$title" ] || die "no such task: $id"
  tasks_store_block "$id" "$why" || die "bd update $id failed"
  lead_id="$(team_identity "$TEAM" "$WOLFMUX_LEAD_ROLE")"
  if [ "$role" != "$WOLFMUX_LEAD_ROLE" ]; then
    tasks_store_reply "$lead_id" "Blocked: $title" "$why" "$id" || die "bd create (blocked message to $lead_id) failed"
    say "sent: Blocked: $title -> $lead_id"
  fi
  say "blocked: $id"
}

# --- the Stop hook: nobody stops with work forgotten ------------------------------------

# _tasks_forget_closed <dir> <json> — a marker whose task is no longer in the open/in_progress
# list (closed, or moved off this agent) is deleted, so the same id reminds again if reopened.
_tasks_forget_closed() {
  local dir="$1" json="$2" f id
  for f in "$dir"/reminded-*; do
    [ -e "$f" ] || continue
    id="${f##*/reminded-}"
    if ! printf '%s' "$json" | "$JQ_BIN" -e --arg id "$id" 'any(.[]; .id == $id)' >/dev/null 2>&1; then
      /bin/rm -f "$f"
    fi
  done
}

# tasks_hook <Event> — Stop only: an in_progress task under this agent's name is reminded
# once (teamctl done / teamctl blocked); failing that, an open, unclaimed one is pointed out
# once. The lead's turn ends all the time, so it is never reminded of anything here.
tasks_hook() {
  [ "$1" = "Stop" ] || return 0
  [ "$HOOK_ROLE" != "$WOLFMUX_LEAD_ROLE" ] || return 0
  [ "$(hook_input .stop_hook_active)" != "true" ] || return 0
  [ -n "$BD_BIN" ] || return 0
  local me="${BEADS_ACTOR:-$HOOK_ROLE}" json dir id title marker
  json="$(tasks_store_list "$me" open,in_progress 5)" || return 0
  printf '%s' "$json" | "$JQ_BIN" -e 'type == "array"' >/dev/null 2>&1 || return 0
  dir="$HOOK_RUN/tasks"
  /bin/mkdir -p "$dir" 2>/dev/null || return 0
  _tasks_forget_closed "$dir" "$json"

  id="$(printf '%s' "$json" | "$JQ_BIN" -r '[.[] | select(.status == "in_progress")][0].id // empty')"
  if [ -n "$id" ] && valid_bead_id "$id"; then
    marker="$dir/reminded-$id"
    if [ ! -e "$marker" ]; then
      title="$(printf '%s' "$json" | "$JQ_BIN" -r --arg id "$id" '[.[] | select(.id == $id)][0].title')"
      : >"$marker" 2>/dev/null || true
      hook_context "[wolfmux] You are stopping while $id \"$title\" is in progress under your name. Finished: teamctl done \"<summary>\" --tests \"<command: result>\". Waiting or stuck: teamctl blocked \"<why>\". Already reported or deliberately waiting for an answer: ignore this and stop."
    fi
    return 0
  fi

  id="$(printf '%s' "$json" | "$JQ_BIN" -r '[.[] | select(.status == "open")][0].id // empty')"
  [ -n "$id" ] && valid_bead_id "$id" || return 0
  marker="$dir/reminded-$id"
  [ -e "$marker" ] && return 0
  title="$(printf '%s' "$json" | "$JQ_BIN" -r --arg id "$id" '[.[] | select(.id == $id)][0].title')"
  : >"$marker" 2>/dev/null || true
  hook_context "[wolfmux] $id \"$title\" is assigned to you and not started. Claim it and start: bd update $id --claim   (the body is in its inbox: teamctl inbox)"
}
