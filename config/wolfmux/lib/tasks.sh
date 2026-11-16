#!/bin/bash
# tasks.sh — hand out work, report it, never stop with work forgotten.
# The contract is the header of lib/hooks.sh. Every task read and write here goes through
# lib/store.sh's store_* interface, plus the Stop reminder (tasks_hook) that catches work
# left open under an agent's name when its turn ends.
#
# A write that should tell someone calls mail_announce after it (a no-op in Beads mode: its
# own hook already delivers). The functions below name what each one means for a task;
# nothing else in this file knows a bead's JSON shape beyond id, title and status.

# tasks_store_create <creator> <assignee> <priority> <title> [<description>] — prints the new id.
tasks_store_create() { store_task_create "$1" "$2" "$3" "$4" "${5:-}"; }

# tasks_store_add_dependency <id> <blocker-id> — <id> cannot start before <blocker-id> is closed.
tasks_store_add_dependency() { store_task_dep_add "$1" "$2"; }

# tasks_store_title <id> — empty when there is no such task.
tasks_store_title() { store_item_json "$1" 2>/dev/null | "$JQ_BIN" -r '.title // empty' 2>/dev/null; }

# _tasks_close <id> <reason> <actor-identity> [failed] [force] — closes the task and announces
# it. The actor travels to the store, so Beads' own assignee guard applies to a worker's
# close; "force" is for the lead only, who closes any task of its team.
_tasks_close() {
  local id="$1" reason="$2" actor="$3" failed="${4:-}" force="${5:-}"
  store_task_close "$id" "$reason" "$failed" "$actor" "$force" || return 1
  mail_announce close "$(store_item_json "$id")" "$actor"
}

# _tasks_block <id> <actor-identity> <note> — status blocked, note appended, announced.
_tasks_block() {
  local id="$1" actor="$2" note="$3"
  store_task_status "$id" blocked || return 1
  store_task_note "$id" "$actor" "$note" || true
  mail_announce update "$(store_item_json "$id")" "$actor"
}

# _tasks_reply <sender-identity> <to-identity> <subject> <body> <reply-to-id> — a message
# that replies to a task, announced.
_tasks_reply() {
  local sender="$1" to="$2" subject="$3" body="$4" reply_to="$5" id
  id="$(store_msg_create "$sender" "$to" "$subject" "$body" "$reply_to")" || return 1
  mail_announce create "$(store_item_json "$id")" "$sender"
}

# tasks_store_list <identity> <status-csv> — that identity's tasks in those statuses, as
# JSON, straight (no bound: for an interactive command, not a hook).
tasks_store_list() { store_tasks_json "$1" "$2"; }

# _tasks_hook_list <identity> <status-csv> — the same, but bounded to 5s on the Beads
# backend (tasks_hook runs inside a hook, which may never hang on a slow write queue; the
# native backend is fast enough to call straight). Empty, not an error, past the bound.
_tasks_hook_list() {
  case "$(store_kind)" in
    native) store_tasks_json "$1" "$2" ;;
    beads) _bd_bounded 5 store_tasks_json "$1" "$2" ;;
  esac
}

# _tasks_own_item <id> <identity> <role> <verb> — the task's ITEM JSON, or dies: no such
# task, a message rather than a task, already closed, or (for anyone but the lead) a task
# assigned to someone else. done and blocked are the assignee's; teamctl close is the lead's.
_tasks_own_item() {
  local id="$1" me="$2" role="$3" verb="$4" item kind status assignee
  item="$(store_item_json "$id" 2>/dev/null)" || item=""
  [ -n "$item" ] || die "no such task: $id"
  kind="$(printf '%s' "$item" | "$JQ_BIN" -r '.issue_type // empty')"
  [ "$kind" = "task" ] || die "$id is a ${kind:-item}, not a task; teamctl $verb takes a task id"
  status="$(printf '%s' "$item" | "$JQ_BIN" -r '.status // empty')"
  [ "$status" != "closed" ] || die "$id is already closed; nothing to report. The lead reopens it if more is needed: teamctl reopen $id \"<why>\""
  assignee="$(printf '%s' "$item" | "$JQ_BIN" -r '.assignee // empty')"
  if [ "$role" != "$WOLFMUX_LEAD_ROLE" ] && [ "$assignee" != "$me" ]; then
    die "$id is assigned to ${assignee:-nobody}, not to you ($me); only its assignee runs teamctl $verb on it. Check the id: teamctl tasks $role"
  fi
  printf '%s\n' "$item"
}

# _tasks_default_id <identity> — the caller's only in_progress task, when no bead id was
# given on the command line.
_tasks_default_id() {
  local me="$1" json count
  json="$(tasks_store_list "$me" in_progress)" || die "could not read the store"
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
  local role="" title="" desc="" body_file="" priority="2" spawn_model="" after=() positional=0 id me creator blocker
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
  require_tools
  load_project
  store_backend_ready
  require_manager task
  me="$(team_identity "$TEAM" "$role")"
  creator="${BEADS_ACTOR:-${TEAM_ROLE:-}}"
  if [ "$body_file" = "-" ]; then
    desc="$(/bin/cat)"
  elif [ -n "$body_file" ]; then
    desc="$(/bin/cat "$body_file" 2>/dev/null)" || die "cannot read --body-file: $body_file"
  fi
  id="$(tasks_store_create "$creator" "$me" "$priority" "$title" "$desc")" || die "could not create the task"
  id="$(printf '%s' "$id" | tr -d '[:space:]')"
  [ -n "$id" ] || die "task creation produced no id"
  for blocker in "${after[@]:-}"; do
    [ -n "$blocker" ] || continue
    tasks_store_add_dependency "$id" "$blocker" || die "could not add dependency $id -> $blocker"
  done
  mail_announce create "$(store_item_json "$id")" "$creator"
  if [ -n "$spawn_model" ]; then
    if reg_exists "$role"; then
      say "--spawn ignored: '$role' is already running; it is already told."
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
  local role me path branch base_commit title tests_line commits_block stat_line short_sha report extra lead_id item blocked_by force=""
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
  require_tools
  load_project
  store_backend_ready
  role="$(caller_role)"
  [ -n "$role" ] || die_usage "run 'teamctl done' from inside your own agent pane (TEAM_ROLE is unset)"
  reg_exists "$role" || die "no registry record for role '$role' in $(short_path "$ROOT")"
  me="$(team_identity "$TEAM" "$role")"
  if [ -n "$id" ]; then
    valid_bead_id "$id" || die_usage "invalid bead id '$id'"
  else
    id="$(_tasks_default_id "$me")" || exit $?
  fi
  item="$(_tasks_own_item "$id" "$me" "$role" done)" || exit $?
  blocked_by="$(printf '%s' "$item" | "$JQ_BIN" -r '[.blocked_by[]?] | join(", ")' 2>/dev/null)"
  [ -z "$blocked_by" ] || die "$id is waiting on unclosed blockers: $blocked_by; it cannot be done before they are closed"
  path="$(reg_field "$role" workdir)"
  [ -d "$path" ] || die "working directory is gone: $path"
  if [ "$allow_dirty" -eq 0 ] && [ -n "$("$GIT_BIN" -C "$path" status --porcelain 2>/dev/null)" ]; then
    die "uncommitted changes in $(short_path "$path"); commit first, or pass --allow-dirty."
  fi
  branch="$(reg_field "$role" branch)"
  base_commit="$(reg_field "$role" base_commit)"
  title="$(printf '%s' "$item" | "$JQ_BIN" -r '.title // empty')"

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

  # Close first, report after: a close that fails must not leave the lead holding a "Done"
  # report for a task that is still open.
  [ "$role" = "$WOLFMUX_LEAD_ROLE" ] && force="force"
  # The worker's Done: report below already tells the lead; the close is not announced to it
  # a second time (D7, one notice per event; lib/mail.sh reads WOLFMUX_MAIL_CLOSE_REPORTED).
  WOLFMUX_MAIL_CLOSE_REPORTED="$([ "$role" != "$WOLFMUX_LEAD_ROLE" ] && printf 1)" \
    _tasks_close "$id" "commit $short_sha; $(printf '%s' "$summary" | head -1)" "$me" "" "$force" || die "could not close $id"
  lead_id="$(team_identity "$TEAM" "$WOLFMUX_LEAD_ROLE")"
  if [ "$role" != "$WOLFMUX_LEAD_ROLE" ]; then
    _tasks_reply "$me" "$lead_id" "Done: $title" "$report" "$id" ||
      die "closed $id, but could not send the report message to $lead_id; tell the lead: teamctl send $WOLFMUX_LEAD_ROLE \"Done: $title\" --body-file <file>"
    say "sent: Done: $title -> $lead_id"
  fi
  say "closed: $id"
}

# teamctl blocked [<bead-id>] "<why>"
cmd_blocked() {
  local id="" why="" args=() role me title lead_id item
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
  require_tools
  load_project
  store_backend_ready
  role="$(caller_role)"
  [ -n "$role" ] || die_usage "run 'teamctl blocked' from inside your own agent pane (TEAM_ROLE is unset)"
  me="$(team_identity "$TEAM" "$role")"
  if [ -n "$id" ]; then
    valid_bead_id "$id" || die_usage "invalid bead id '$id'"
  else
    id="$(_tasks_default_id "$me")" || exit $?
  fi
  item="$(_tasks_own_item "$id" "$me" "$role" blocked)" || exit $?
  title="$(printf '%s' "$item" | "$JQ_BIN" -r '.title // empty')"
  _tasks_block "$id" "$me" "$why" || die "could not mark $id blocked"
  lead_id="$(team_identity "$TEAM" "$WOLFMUX_LEAD_ROLE")"
  if [ "$role" != "$WOLFMUX_LEAD_ROLE" ]; then
    _tasks_reply "$me" "$lead_id" "Blocked: $title" "$why" "$id" || die "could not send the blocked message to $lead_id"
    say "sent: Blocked: $title -> $lead_id"
  fi
  say "blocked: $id"
}

# _tasks_default_open_id <identity> — that identity's only open task, when no bead id was
# given on the command line (teamctl claim).
_tasks_default_open_id() {
  local me="$1" json count
  json="$(tasks_store_list "$me" open)" || die "could not read the store"
  count="$(printf '%s' "$json" | "$JQ_BIN" -r 'length' 2>/dev/null)"
  case "$count" in
    1) printf '%s' "$json" | "$JQ_BIN" -r '.[0].id' ;;
    0) die "no bead id given, and '$me' has no open task. Name one: teamctl claim <id>" 64 ;;
    *) die "no bead id given, and '$me' has more than one open task: $(printf '%s' "$json" | "$JQ_BIN" -r '[.[].id] | join(" ")'). Name one of them." 64 ;;
  esac
}

# teamctl claim [<id>] — default: the caller's only open task. Refuses one with unclosed
# blockers, naming them; prints the task's title and body so the agent has it this turn.
cmd_claim() {
  local id="${1:-}" role me item blocked_by title desc
  require_tools
  load_project
  store_backend_ready
  role="$(caller_role)"
  [ -n "$role" ] || die_usage "run 'teamctl claim' from inside your own agent pane (TEAM_ROLE is unset)"
  me="${BEADS_ACTOR:-$(team_identity "$TEAM" "$role")}"
  if [ -n "$id" ]; then
    valid_bead_id "$id" || die_usage "invalid bead id '$id'"
  else
    id="$(_tasks_default_open_id "$me")" || exit $?
  fi
  item="$(store_item_json "$id")" || die "no such task: $id"
  blocked_by="$(printf '%s' "$item" | "$JQ_BIN" -r '[.blocked_by[]?] | join(", ")' 2>/dev/null)"
  [ -z "$blocked_by" ] || die "$id is waiting on unclosed blockers: $blocked_by"
  store_task_claim "$id" "$me" || die "could not claim $id (already claimed by someone else, or not open)"
  mail_announce update "$(store_item_json "$id")" "$me"
  title="$(printf '%s' "$item" | "$JQ_BIN" -r '.title // empty')"
  desc="$(printf '%s' "$item" | "$JQ_BIN" -r '.description // empty')"
  say "claimed: $id $title"
  [ -z "$desc" ] || say "$desc"
}

# _tasks_table <rows-json> — id, status (a task waiting on unclosed blockers shows as
# "waiting" instead of its own status, so it is never mistaken for ready work),
# priority, assignee, blocked-by, title.
_tasks_table() {
  local rows="${1:-[]}" count
  count="$(printf '%s' "$rows" | "$JQ_BIN" -r 'length' 2>/dev/null)"
  case "$count" in '' | *[!0-9]*) count=0 ;; esac
  if [ "$count" -eq 0 ]; then
    say "no tasks"
    return 0
  fi
  printf '%s' "$rows" | "$JQ_BIN" -r '
    .[] | [.id, (if ((.blocked_by // []) | length) > 0 then "waiting" else .status end),
           ("P" + (.priority | tostring)), .assignee, ((.blocked_by // []) | join(",")), .title] | @tsv' \
    | while IFS=$'\t' read -r tid status prio assignee blockers title; do
      printf '%-10s %-11s %-3s %-18s %-14s %s\n' "$tid" "$status" "$prio" "$assignee" "${blockers:--}" "$title"
    done
}

# teamctl tasks [<role>|--all] [--status <list>] [--json] — default: the caller's own team,
# not closed. <role>: just that role (bare = this team, team.role = another). --all: every
# team this project's store knows about.
cmd_tasks() {
  local target="" all=0 statuses="" asjson=0 identity="" rows
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --all) all=1 ;;
      --status)
        [ "$#" -ge 2 ] || die_usage "--status needs a list"
        statuses="$2"
        shift
        ;;
      --json) asjson=1 ;;
      -*) die_usage "unknown option for tasks: $1" ;;
      *) target="$1" ;;
    esac
    shift
  done
  [ -z "$target" ] || [ "$all" -eq 0 ] || die_usage "usage: teamctl tasks [<role>|--all] [--status <list>] [--json]"
  require_tools
  load_project
  [ -n "$statuses" ] || statuses="open,in_progress,blocked"
  if [ -n "$target" ]; then
    case "$target" in
      *.*)
        identity_split "$target"
        valid_team_name "$ID_TEAM" || die_usage "$(team_name_error "$ID_TEAM")"
        known_role_name "$ID_ROLE" || die_usage "invalid role '$target'"
        identity="$(team_identity "$ID_TEAM" "$ID_ROLE")"
        ;;
      *)
        known_role_name "$target" || die_usage "invalid role '$target'"
        identity="$(team_identity "$TEAM" "$target")"
        ;;
    esac
    rows="$(store_tasks_json "$identity" "$statuses")" || die "could not read the store"
  else
    rows="$(store_tasks_json "" "$statuses")" || die "could not read the store"
    if [ "$all" -eq 0 ]; then
      rows="$(printf '%s' "$rows" | "$JQ_BIN" -c --arg t "$TEAM" --arg d "$WOLFMUX_DEFAULT_TEAM" '
        [.[] | select(
          (($t == $d) and ((.assignee | test("\\.")) | not)) or
          (($t != $d) and (.assignee | startswith($t + ".")))
        )]')"
    fi
  fi
  if [ "$asjson" -eq 1 ]; then
    printf '%s\n' "${rows:-[]}"
    return 0
  fi
  _tasks_table "$rows"
}

# _show_render_task <item-json> — plain-text view: heading, waiting-on, body, notes.
_show_render_task() {
  local item="$1" id title status prio assignee desc notes blocked
  id="$(printf '%s' "$item" | "$JQ_BIN" -r '.id')"
  title="$(printf '%s' "$item" | "$JQ_BIN" -r '.title')"
  status="$(printf '%s' "$item" | "$JQ_BIN" -r '.status')"
  prio="$(printf '%s' "$item" | "$JQ_BIN" -r '.priority')"
  assignee="$(printf '%s' "$item" | "$JQ_BIN" -r '.assignee')"
  desc="$(printf '%s' "$item" | "$JQ_BIN" -r '.description // ""')"
  notes="$(printf '%s' "$item" | "$JQ_BIN" -r '.notes // ""')"
  blocked="$(printf '%s' "$item" | "$JQ_BIN" -r '[.blocked_by[]?] | join(", ")')"
  say "$id  P$prio  $status  $assignee  $title"
  [ -z "$blocked" ] || say "waiting on: $blocked"
  [ -z "$desc" ] || {
    say ""
    say "$desc"
  }
  [ -z "$notes" ] || {
    say ""
    say "notes:"
    say "$notes"
  }
}

# teamctl show <id> [--json] — one task (body, notes, blockers), or one message with its thread.
cmd_show() {
  local id="" asjson=0 item type thread
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) asjson=1 ;;
      -*) die_usage "unknown option for show: $1" ;;
      *) id="$1" ;;
    esac
    shift
  done
  [ -n "$id" ] && valid_bead_id "$id" || die_usage "usage: teamctl show <id> [--json]"
  require_tools
  load_project
  item="$(store_item_json "$id")" || die "no such id: $id"
  type="$(printf '%s' "$item" | "$JQ_BIN" -r '.issue_type // "task"')"
  if [ "$type" = "message" ]; then
    thread="$(store_thread_json "$id" 2>/dev/null)"
    [ -n "$thread" ] || thread="$(printf '%s' "$item" | "$JQ_BIN" -c '[.]')"
    if [ "$asjson" -eq 1 ]; then
      printf '%s\n' "$thread"
      return 0
    fi
    printf '%s' "$thread" | "$JQ_BIN" -c '.[]' | while IFS= read -r m; do
      [ -n "$m" ] || continue
      say "$(_mail_render_bead "$m")"
      say ""
    done
    _show_mark_shown "$item" "$id"
    return 0
  fi
  if [ "$asjson" -eq 1 ]; then
    printf '%s\n' "$item"
    return 0
  fi
  _show_render_task "$item"
  _show_mark_shown "$item" "$id"
}

# _show_mark_shown <item-json> <id> — D7: whatever shows an item to its addressee marks it
# delivered (lib/mail.sh mail_item_shown; a no-op before that function exists).
_show_mark_shown() {
  [ -n "${BEADS_ACTOR:-}" ] || return 0
  [ "$(printf '%s' "$1" | "$JQ_BIN" -r '.assignee // ""')" = "$BEADS_ACTOR" ] || return 0
  declare -F mail_item_shown >/dev/null 2>&1 || return 0
  mail_item_shown "$(caller_role)" "$BEADS_ACTOR" "$2" || true
}

# teamctl note <id> "<text>" — a durable note on a task. Notifies nobody.
cmd_note() {
  local id="" text="" args=() me title
  for a in "$@"; do args+=("$a"); done
  case "${#args[@]}" in
    2) id="${args[0]}" text="${args[1]}" ;;
    *) die_usage 'usage: teamctl note <id> "<text>"' ;;
  esac
  valid_bead_id "$id" || die_usage "invalid bead id '$id'"
  [ -n "$text" ] || die_usage 'usage: teamctl note <id> "<text>"'
  require_tools
  load_project
  me="${BEADS_ACTOR:-$(caller_role)}"
  title="$(tasks_store_title "$id")"
  [ -n "$title" ] || die "no such task: $id"
  store_task_note "$id" "$me" "$text" || die "could not add the note"
  say "noted: $id"
}

# teamctl reopen <id> "<why>" — the lead sends a closed task back: open, the reason noted,
# the assignee told (mail_announce treats this as an update).
cmd_reopen() {
  local id="" why="" args=() me title
  for a in "$@"; do args+=("$a"); done
  case "${#args[@]}" in
    2) id="${args[0]}" why="${args[1]}" ;;
    *) die_usage 'usage: teamctl reopen <id> "<why>"' ;;
  esac
  valid_bead_id "$id" || die_usage "invalid bead id '$id'"
  [ -n "$why" ] || die_usage 'usage: teamctl reopen <id> "<why>"'
  require_tools
  load_project
  require_manager reopen
  me="${BEADS_ACTOR:-$(caller_role)}"
  title="$(tasks_store_title "$id")"
  [ -n "$title" ] || die "no such task: $id"
  store_task_status "$id" open || die "could not reopen $id"
  store_task_note "$id" "$me" "reopened: $why" || true
  mail_announce update "$(store_item_json "$id")" "$me"
  say "reopened: $id"
}

# teamctl close <id> -r "<reason>" [--failed] — the lead closes or rejects any task of its team.
cmd_close() {
  local id="" reason="" failed="" positional=() me title
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -r)
        [ "$#" -ge 2 ] || die_usage '-r needs a reason'
        reason="$2"
        shift
        ;;
      --failed) failed="failed" ;;
      -*) die_usage "unknown option for close: $1" ;;
      *) positional+=("$1") ;;
    esac
    shift
  done
  id="${positional[0]:-}"
  valid_bead_id "$id" || die_usage 'usage: teamctl close <id> -r "<reason>" [--failed]'
  [ -n "$reason" ] || die_usage 'usage: teamctl close <id> -r "<reason>" [--failed]'
  require_tools
  load_project
  require_manager close
  me="${BEADS_ACTOR:-$(caller_role)}"
  title="$(tasks_store_title "$id")"
  [ -n "$title" ] || die "no such task: $id"
  _tasks_close "$id" "$reason" "$me" "$failed" force || die "could not close $id"
  say "closed: $id"
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
  local me="${BEADS_ACTOR:-$HOOK_ROLE}" json dir id title marker
  json="$(_tasks_hook_list "$me" open,in_progress)" || return 0
  printf '%s' "$json" | "$JQ_BIN" -e 'type == "array"' >/dev/null 2>&1 || return 0
  dir="$HOOK_RUN/tasks"
  /bin/mkdir -p "$dir" 2>/dev/null || return 0
  _tasks_forget_closed "$dir" "$json"

  id="$(printf '%s' "$json" | "$JQ_BIN" -r '[.[] | select(.status == "in_progress")][0].id // empty')"
  if [ -n "$id" ] && valid_bead_id "$id"; then
    marker="$dir/reminded-$id"
    if [ ! -e "$marker" ]; then
      title="$(_hook_title "$(printf '%s' "$json" | "$JQ_BIN" -r --arg id "$id" '[.[] | select(.id == $id)][0].title')")"
      : >"$marker" 2>/dev/null || true
      hook_context "[wolfmux] You are stopping while $id \"$title\" is in progress under your name. Finished: teamctl done \"<summary>\" --tests \"<command: result>\". Waiting or stuck: teamctl blocked \"<why>\". Already reported or deliberately waiting for an answer: ignore this and stop."
    fi
    return 0
  fi

  id="$(printf '%s' "$json" | "$JQ_BIN" -r '[.[] | select(.status == "open")][0].id // empty')"
  [ -n "$id" ] && valid_bead_id "$id" || return 0
  marker="$dir/reminded-$id"
  [ -e "$marker" ] && return 0
  title="$(_hook_title "$(printf '%s' "$json" | "$JQ_BIN" -r --arg id "$id" '[.[] | select(.id == $id)][0].title')")"
  : >"$marker" 2>/dev/null || true
  hook_context "[wolfmux] $id \"$title\" is assigned to you and not started. Claim it and start: teamctl claim $id   (the body is in its inbox: teamctl mail)"
}
