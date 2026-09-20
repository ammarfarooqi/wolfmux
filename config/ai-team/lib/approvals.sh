#!/bin/bash
# approvals.sh — in worker-permissions=lead mode the manager decides a worker's
# permission requests.
#
# Claude Code fires a PermissionRequest hook the moment a worker would show a
# permission prompt. The hook (`teamctl _permission-hook`) files the request under
# $STATE_DIR/approvals/, tells the lead's pane, and waits. The lead answers with
# `teamctl approve <id>` or `teamctl deny <id> "<reason>"`, and the hook hands that
# decision back to the worker's CLI. No answer in time: the hook returns nothing
# and the normal prompt appears in the worker's pane, so a human can still decide.

APPROVAL_TIMEOUT="${AI_TEAM_APPROVAL_TIMEOUT:-600}"
case "$APPROVAL_TIMEOUT" in "" | *[!0-9]*) APPROVAL_TIMEOUT=600 ;; esac

approvals_dir() { printf '%s/approvals\n' "$STATE_DIR"; }

valid_approval_id() {
  case "$1" in A[0-9]*) ;; *) return 1 ;; esac
  case "${1#A}" in *[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 12 ]
}

# approval_create <role> <tool> <summary> <cwd> — prints the new id.
# The hard link is the atomic "create only if absent" step.
approval_create() {
  local dir tmp number id
  dir="$(approvals_dir)"
  /bin/mkdir -p "$dir"
  tmp="$dir/.new.$$"
  number="$(/bin/ls "$dir" 2>/dev/null | sed -n 's/^A\([0-9][0-9]*\)\.json$/\1/p' | sort -n | tail -1)"
  number=$((${number:-0} + 1))
  while :; do
    id="A$number"
    "$JQ_BIN" -n --arg id "$id" --arg role "$1" --arg tool "$2" --arg summary "$3" --arg cwd "$4" \
      --arg now "$(now_iso)" --arg epoch "$(now_epoch)" \
      '{id: $id, role: $role, tool: $tool, summary: $summary, cwd: $cwd, status: "pending",
        created_at: $now, created_epoch: ($epoch | tonumber), decided_by: "", reason: ""}' >"$tmp"
    if /bin/ln "$tmp" "$dir/$id.json" 2>/dev/null; then
      /bin/rm -f "$tmp"
      printf '%s\n' "$id"
      return 0
    fi
    number=$((number + 1))
  done
}

approval_field() { "$JQ_BIN" -r --arg f "$2" '.[$f] // empty' "$(approvals_dir)/$1.json" 2>/dev/null; }

# approval_decide <id> <approved|denied|expired> <by> <reason>
approval_decide() {
  local path tmp
  path="$(approvals_dir)/$1.json"
  tmp="$path.tmp.$$"
  "$JQ_BIN" --arg status "$2" --arg by "$3" --arg reason "$4" --arg now "$(now_iso)" \
    '.status = $status | .decided_by = $by | .reason = $reason | .decided_at = $now' "$path" >"$tmp" &&
    /bin/mv -f "$tmp" "$path"
}

approvals_pending_count() {
  local file count=0
  for file in "$(approvals_dir)"/A*.json; do
    [ -f "$file" ] || continue
    if [ "$("$JQ_BIN" -r '.status' "$file" 2>/dev/null)" = "pending" ]; then count=$((count + 1)); fi
  done
  printf '%s\n' "$count"
}

# teamctl approvals [--all]
cmd_approvals() {
  local show_all=0 file shown=0 now
  if [ "${1:-}" = "--all" ]; then show_all=1; fi
  require_tools
  load_project
  now="$(now_epoch)"
  printf '%-6s %-14s %-12s %-9s %-6s %s\n' ID ROLE TOOL STATUS AGE REQUEST
  for file in $(/bin/ls "$(approvals_dir)" 2>/dev/null | sed -n 's/^\(A[0-9][0-9]*\)\.json$/\1/p' | sort -t A -k 2 -n); do
    if [ "$show_all" -eq 0 ] && [ "$(approval_field "$file" status)" != "pending" ]; then continue; fi
    shown=$((shown + 1))
    "$JQ_BIN" -r --argjson now "$now" \
      '[.id, .role, .tool, .status, "\($now - .created_epoch)s", (.summary | gsub("[\\n\\r\\t]"; " ") | .[0:160])] | join("|")' \
      "$(approvals_dir)/$file.json" |
      while IFS='|' read -r id role tool status age summary; do
        printf '%-6s %-14s %-12s %-9s %-6s %s\n' "$id" "$role" "$tool" "$status" "$age" "$summary"
      done
  done
  if [ "$shown" -eq 0 ]; then say "(no $([ "$show_all" -eq 1 ] && printf 'requests' || printf 'pending requests'))"; fi
  say ""
  say "decide:  teamctl approve <id>|--all      teamctl deny <id> \"<reason the worker will read>\""
}

_approval_pending_or_die() {
  valid_approval_id "$1" || die_usage "not an approval id: $1  (see: teamctl approvals)"
  [ -f "$(approvals_dir)/$1.json" ] || die "no such request: $1"
  [ "$(approval_field "$1" status)" = "pending" ] || die "$1 is already $(approval_field "$1" status)"
}

# teamctl approve <id>...|--all
cmd_approve() {
  local id by
  [ "$#" -gt 0 ] || die_usage "usage: teamctl approve <id>...|--all"
  require_tools
  load_project
  require_manager approve
  by="$(caller_role)"
  if [ "$1" = "--all" ]; then
    set --
    for id in $(/bin/ls "$(approvals_dir)" 2>/dev/null | sed -n 's/^\(A[0-9][0-9]*\)\.json$/\1/p'); do
      if [ "$(approval_field "$id" status)" = "pending" ]; then set -- "$@" "$id"; fi
    done
    [ "$#" -gt 0 ] || { say "nothing pending"; return 0; }
  fi
  for id in "$@"; do
    _approval_pending_or_die "$id"
    approval_decide "$id" approved "${by:-operator}" ""
    event_log approve "$(approval_field "$id" role)" "$id"
    say "approved: $id  ($(approval_field "$id" role): $(approval_field "$id" tool))"
  done
}

# teamctl deny <id> [reason...]
cmd_deny() {
  local id="${1:-}" by reason
  [ -n "$id" ] || die_usage "usage: teamctl deny <id> \"<reason>\""
  shift
  reason="${*:-denied by the lead}"
  require_tools
  load_project
  require_manager deny
  by="$(caller_role)"
  _approval_pending_or_die "$id"
  approval_decide "$id" denied "${by:-operator}" "$reason"
  event_log deny "$(approval_field "$id" role)" "$id"
  say "denied: $id  ($(approval_field "$id" role): $(approval_field "$id" tool))"
}

# internal: the PermissionRequest hook of a worker. Must never break the worker:
# every failure path prints nothing and exits 0, which means "show the usual prompt".
cmd_permission_hook() {
  local input role tool summary id deadline status
  set +e
  input="$(/bin/cat)"
  role="${TEAM_ROLE:-}"
  [ -n "$role" ] && [ "$role" != "$AI_TEAM_LEAD_ROLE" ] || exit 0
  [ -n "$TMUX_BIN" ] && [ -n "$JQ_BIN" ] && [ -n "$GIT_BIN" ] || exit 0
  ROOT="$(resolve_root 2>/dev/null)" || exit 0
  PROJECT_KEY="$(project_key "$ROOT")"
  STATE_DIR="$AI_TEAM_DATA/state/$PROJECT_KEY"
  WORKTREES_DIR="$AI_TEAM_DATA/worktrees/$PROJECT_KEY"
  [ -d "$STATE_DIR" ] || exit 0
  SESSION="$(session_name_for_project)"
  # Nobody to ask: do not make the worker wait for a lead that is not there.
  [ "$(tm_pane_state "$(tm_pane_for_role "$SESSION" "$AI_TEAM_LEAD_ROLE")")" = "running" ] || exit 0

  tool="$(printf '%s' "$input" | "$JQ_BIN" -r '.tool_name // "tool"' 2>/dev/null)"
  summary="$(printf '%s' "$input" | "$JQ_BIN" -r '(.tool_input.command // .tool_input.file_path // .tool_input.url // .tool_input.query // (.tool_input | tojson)) | tostring | .[0:400]' 2>/dev/null)"
  id="$(approval_create "$role" "${tool:-tool}" "${summary:-}" "$PWD")" || exit 0
  event_log approval-request "$role" "$id"
  notify_lead approval "$id" "$role"

  deadline=$(($(now_epoch) + APPROVAL_TIMEOUT))
  while [ "$(now_epoch)" -lt "$deadline" ]; do
    status="$(approval_field "$id" status)"
    case "$status" in
      approved)
        printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}\n'
        exit 0
        ;;
      denied)
        "$JQ_BIN" -cn --arg message "Denied by the team lead: $(approval_field "$id" reason)" \
          '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "deny", message: $message}}}'
        exit 0
        ;;
    esac
    sleep 1
  done
  approval_decide "$id" expired "" "no decision within ${APPROVAL_TIMEOUT}s"
  exit 0
}
