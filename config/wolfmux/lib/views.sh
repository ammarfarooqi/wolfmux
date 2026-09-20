#!/bin/bash
# views.sh — read-only views of the team, and moving your terminal to it.
#
# Process state comes from tmux, worktree state from git, and the role/model
# mapping from the registry. Terminal output is never parsed for state.

_status_rows() { # emits one JSON object per agent
  local role kind pane state branch ahead dirty workdir
  for role in $(reg_list); do
    reg_exists "$role" || continue
    kind="$(reg_field "$role" kind)"
    workdir="$(reg_field "$role" workdir)"
    pane=""
    state="stopped"
    if [ -n "$SESSION_LIVE" ]; then
      pane="$(tm_pane_for_role "$SESSION" "$role")"
      state="$(agent_state "$role")"
    fi
    if [ "$kind" = "lead" ]; then
      branch="$(gitr symbolic-ref --short -q HEAD || printf 'detached')"
      ahead="-"
    else
      branch="$(reg_field "$role" branch)"
      ahead="$(wt_ahead "$(reg_field "$role" base_commit)" "$branch")"
    fi
    dirty="$(wt_dirty_count "$workdir")"
    "$JQ_BIN" -cn --arg role "$role" --arg kind "$kind" --arg model "$(reg_field "$role" model)" \
      --arg label "$(reg_field "$role" label)" --arg state "$state" --arg pane "$pane" \
      --arg branch "$branch" --arg ahead "$ahead" --arg dirty "$dirty" --arg workdir "$workdir" \
      --arg permissions "$(reg_field "$role" permissions)" --arg spawned_by "$(reg_field "$role" spawned_by)" \
      '{role: $role, kind: $kind, model: $model, label: $label, state: $state, pane: $pane,
        permissions: (if $permissions == "" then "ask" else $permissions end),
        spawned_by: (if $spawned_by == "" then "operator" else $spawned_by end),
        branch: $branch, commits_ahead: $ahead, uncommitted: $dirty, workdir: $workdir}'
  done
}

# teamctl status [--json]   (alias: workers)
cmd_status() {
  local json=0 rows
  if [ "${1:-}" = "--json" ]; then json=1; fi
  require_tools
  load_project
  SESSION="$(session_name_for_project)"
  SESSION_LIVE=""
  if tm_session_exists "$SESSION"; then SESSION_LIVE=1; fi
  rows="$(_status_rows)"
  if [ "$json" -eq 1 ]; then
    printf '%s\n' "$rows" | "$JQ_BIN" -s --arg root "$ROOT" --arg session "$SESSION" \
      --arg running "${SESSION_LIVE:-0}" --arg lp "$(policy_get lead-permissions)" \
      --arg wp "$(policy_get worker-permissions)" --arg ws "$(policy_get worker-spawn)" \
      --arg pending "$(approvals_pending_count)" \
      '{root: $root, session: $session, session_running: ($running == "1"), manager: "lead",
        policy: {lead_permissions: $lp, worker_permissions: $wp, worker_spawn: $ws},
        approvals_pending: ($pending | tonumber), agents: .}'
    return 0
  fi
  say "project   $(short_path "$ROOT")"
  if [ -z "$SESSION_LIVE" ]; then
    say "session   $SESSION  (not running)"
  elif [ "$(tm_alive_count "$SESSION")" -eq 0 ]; then
    say "session   $SESSION  (ended: every agent has exited — 'teamctl start <fable|astra>' opens a new one)"
  else
    say "session   $SESSION  (running)"
  fi
  say "policy    manager: $WOLFMUX_LEAD_MARK lead · $(policy_summary) · approvals pending: $(approvals_pending_count)"
  say ""
  if [ -z "$rows" ]; then
    say "no agents registered. Start a team: teamctl start <fable|astra>"
    return 0
  fi
  printf '%-14s %-14s %-11s %-5s %-5s %-10s %-30s %-6s %-6s %s\n' ROLE MODEL STATE PANE PERM "SPAWNED BY" BRANCH AHEAD DIRTY WORKDIR
  # "|" keeps empty columns in place; a whitespace IFS would collapse them.
  printf '%s\n' "$rows" | "$JQ_BIN" -r '[.role, .label, .state, (if .pane == "" then "-" else .pane end), .permissions, .spawned_by, .branch, .commits_ahead, .uncommitted, .workdir] | join("|")' |
    while IFS='|' read -r role label state pane permissions spawned_by branch ahead dirty workdir; do
      printf '%-14s %-14s %-11s %-5s %-5s %-10s %-30s %-6s %-6s %s\n' "$role" "$label" "$state" "$pane" "$permissions" "$spawned_by" "$branch" "$ahead" "$dirty" "$(short_path "$workdir")"
    done
  say ""
  say "tasks and messages live in Beads:  bd ready · bd list --status in_progress · bd list --assignee <role> --status open --include-infra"
}

# teamctl panes — what tmux itself reports for every pane of the team session
cmd_panes() {
  require_tools
  load_project
  require_session
  printf '%-14s %-6s %-16s %-8s %-7s %s\n' ROLE PANE COMMAND PID STATE CWD
  tmx list-panes -s -t "=$SESSION" \
    -F '#{?#{@ai_role},#{@ai_role},(untagged)}|#{pane_id}|#{pane_current_command}|#{pane_pid}|#{?pane_dead,exited(#{pane_dead_status}),running}|#{pane_current_path}' |
    while IFS='|' read -r role pane command pid state cwd; do
      printf '%-14s %-6s %-16s %-8s %-7s %s\n' "$role" "$pane" "$command" "$pid" "$state" "$(short_path "$cwd")"
    done
}

_pane_or_die() { # <role> — prints the pane id
  local pane
  reg_exists "$1" || die "no such agent: $1  (see: teamctl status)"
  pane="$(tm_pane_for_role "$SESSION" "$1")"
  [ -n "$pane" ] || die "'$1' has no pane (stopped). Bring it back with: teamctl restart $1"
  printf '%s\n' "$pane"
}

# teamctl capture <role> [-n <lines>|--all]      teamctl log <role> == capture --all
cmd_capture() {
  local role="" lines=80 pane
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -n | --lines)
        [ "$#" -ge 2 ] || die_usage "-n needs a number of lines"
        lines="$2"
        shift
        ;;
      --all) lines="all" ;;
      -*) die_usage "usage: teamctl capture <role> [-n <lines>|--all]" ;;
      *) role="$1" ;;
    esac
    shift
  done
  require_role_arg "$role"
  case "$lines" in all) ;; "" | *[!0-9]*) die_usage "-n expects a number" ;; esac
  require_tools
  load_project
  require_session
  pane="$(_pane_or_die "$role")"
  tm_capture "$pane" "$lines"
}

cmd_focus() {
  local role="${1:-}" pane
  require_role_arg "$role"
  require_tools
  load_project
  require_session
  pane="$(_pane_or_die "$role")"
  tmx select-window -t "$pane"
  tmx select-pane -t "$pane"
  say "focused: $role ($pane)"
}

# teamctl attach   (alias: open)
cmd_attach() {
  require_tools
  load_project
  require_session
  if tm_inside_team_server; then
    tmx switch-client -t "=$SESSION"
    return 0
  fi
  if [ -n "${TMUX:-}" ]; then
    die "you are inside another tmux server. Open a new terminal tab and run: teamctl attach"
  fi
  tm_set_splash "$SESSION"
  [ -t 0 ] && [ -t 1 ] || die "not a terminal. In your own terminal run: teamctl attach   (or: tmux -L $WOLFMUX_TMUX_SOCKET attach -t $SESSION)"
  exec "$TMUX_BIN" -L "$WOLFMUX_TMUX_SOCKET" attach-session -t "=$SESSION"
}
