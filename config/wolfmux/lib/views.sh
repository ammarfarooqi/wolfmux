#!/bin/bash
# views.sh — read-only views of the team, and moving your terminal to it.
#
# Process state comes from tmux, worktree state from git, and the role/model
# mapping from the registry. Terminal output is never parsed for state.

# _billing_of <role>: how the agent is paid for: plan | metered | subscription. A record from
# before the field existed has none: it is worked out from its model key, and an agent whose
# model is not in the table any more is simply not metered ("").
_billing_of() {
  local billing
  billing="$(reg_field "$1" billing)"
  if [ -z "$billing" ] && model_info "$(reg_field "$1" model)" 2>/dev/null; then billing="$MODEL_BILLING"; fi
  printf '%s\n' "$billing"
}

_status_rows() { # emits one JSON object per agent
  local role kind pane state branch ahead dirty workdir
  for role in $(reg_list | awk -v lead="$WOLFMUX_LEAD_ROLE" '$0 == lead { print; next } { rest = rest $0 "\n" } END { printf "%s", rest }'); do
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
      --arg label "$(reg_field "$role" label)" --arg family "$(reg_field "$role" family)" --arg billing "$(_billing_of "$role")" --arg state "$state" --arg pane "$pane" \
      --arg branch "$branch" --arg ahead "$ahead" --arg dirty "$dirty" --arg workdir "$workdir" \
      --arg permissions "$(reg_field "$role" permissions)" --arg spawned_by "$(reg_field "$role" spawned_by)" \
      '{role: $role, kind: $kind, model: $model, label: $label, family: $family, billing: $billing, state: $state, pane: $pane,
        permissions: (if $permissions == "" then "ask" else $permissions end),
        spawned_by: (if $spawned_by == "" then "operator" else $spawned_by end),
        branch: $branch, commits_ahead: $ahead, uncommitted: $dirty, workdir: $workdir}'
  done
}

# teamctl status [--json]   (alias: workers)
# role_column_width — 14, or as wide as the longest role
role_column_width() {
  local role width=14
  for role in $(reg_list); do
    if [ "${#role}" -gt "$width" ]; then width="${#role}"; fi
  done
  printf '%s\n' "$width"
}

# _status_team_json — one team as an object (needs team_paths to have run)
_status_team_json() {
  SESSION="$(session_name_for_project)"
  SESSION_LIVE=""
  if tm_session_exists "$SESSION"; then SESSION_LIVE=1; fi
  _status_rows | "$JQ_BIN" -s --arg team "$TEAM" --arg root "$ROOT" --arg session "$SESSION" \
    --arg running "${SESSION_LIVE:-0}" --arg lp "$(policy_get lead-permissions)" \
    --arg wp "$(policy_get worker-permissions)" --arg ws "$(policy_get worker-spawn)" --arg wi "$(policy_get worker-isolation)" --arg lt "$(policy_get lead-teams)" \
    --arg pending "$(approvals_pending_count)" \
    --arg dg "$(policy_get disk-guard)" --arg dmin "$(policy_get disk-min-gb)" --arg lnm "$(policy_get link-node-modules)" \
    --arg free "$(disk_free_kb)" --arg trees "$(disk_team_kb_cached)" \
    '{team: $team, root: $root, session: $session, session_running: ($running == "1"), manager: "lead",
      policy: {lead_permissions: $lp, worker_permissions: $wp, worker_spawn: $ws, worker_isolation: $wi, lead_teams: $lt,
               disk_guard: $dg, disk_min_gb: ($dmin | tonumber), link_node_modules: $lnm},
      disk: {free_kb: (if $free == "" then null else ($free | tonumber) end),
             worktrees_kb: (if $trees == "" then null else ($trees | tonumber) end)},
      approvals_pending: ($pending | tonumber), agents: .}'
}

# _status_team_text — one team as a small tree: the team, its wolf, its dogs
_status_team_text() {
  local rows width state hint=""
  SESSION="$(session_name_for_project)"
  SESSION_LIVE=""
  if tm_session_exists "$SESSION"; then SESSION_LIVE=1; fi
  if [ "$TEAM" != "$WOLFMUX_DEFAULT_TEAM" ]; then hint=" --team $TEAM"; fi
  if [ -z "$SESSION_LIVE" ]; then
    state="not running"
  elif [ "$(tm_alive_count "$SESSION")" -eq 0 ]; then
    state="ended: every agent has exited — 'teamctl start <fable|astra>$hint' opens a new one"
  else
    state="running"
  fi
  say "TEAM $TEAM · $SESSION · $state"
  say "  policy  $(policy_summary) · approvals pending: $(approvals_pending_count)"
  # Free disk is a df call; the lane total is whatever the last command that changed the
  # lanes left behind, because measuring it here is a du over every worktree (lib/disk.sh).
  say "  disk    $(disk_free_label) free · this team's lanes: $(disk_team_label) · spawn guard: $(policy_get disk-guard) under $(policy_get disk-min-gb) GB"
  rows="$(_status_rows)"
  if [ -z "$rows" ]; then
    say "  no agents on record. Start it: teamctl start <fable|astra>$hint"
    return 0
  fi
  width="$(role_column_width)"
  printf '     %-*s %-14s %-11s %-5s %-5s %-10s %-30s %-6s %-6s %s\n' "$((width + 2))" ROLE MODEL STATE PANE PERM "SPAWNED BY" BRANCH AHEAD DIRTY WORKDIR
  # "|" keeps empty columns in place; a whitespace IFS would collapse them.
  # A metered agent is marked with a $ after its label (every token it uses is billed).
  printf '%s\n' "$rows" | "$JQ_BIN" -r '[.kind, .role, (.label + (if .billing == "metered" then "$" else "" end)), .state, (if .pane == "" then "-" else .pane end), .permissions, .spawned_by, .branch, .commits_ahead, .uncommitted, .workdir] | join("|")' |
    while IFS='|' read -r kind role label state pane permissions spawned_by branch ahead dirty workdir; do
      if [ "$kind" = "lead" ]; then
        printf '  %s %-*s' "$WOLFMUX_LEAD_MARK" "$((width + 2))" "$role"
      else
        printf '    %s %-*s' "$WOLFMUX_WORKER_MARK" "$width" "$role"
      fi
      printf ' %-14s %-11s %-5s %-5s %-10s %-30s %-6s %-6s %s\n' "$label" "$state" "$pane" "$permissions" "$spawned_by" "$branch" "$ahead" "$dirty" "$(short_path "$workdir")"
    done
  if [ -n "$(printf '%s\n' "$rows" | "$JQ_BIN" -r 'select(.billing == "metered") | .role' | head -1)" ]; then
    say '  $ = metered: every token is billed to a prepaid balance, not to a plan or subscription (WOLFMUX_METERED=on, the owner'"'"'s decision)'
  fi
}

# teamctl status [--json] — every team of the project, or the one named with --team
cmd_status() {
  local json=0 teams team first=1
  if [ "${1:-}" = "--json" ]; then json=1; fi
  require_tools
  load_project any
  if [ -n "$TEAM" ]; then teams="$TEAM"; else teams="$(team_list)"; fi
  if [ "$json" -eq 1 ]; then
    if [ -n "$TEAM" ]; then
      _status_team_json
    else
      for team in $teams; do
        team_paths "$team"
        _status_team_json
      done | "$JQ_BIN" -s --arg root "$ROOT" '{root: $root, teams: .}'
    fi
    return 0
  fi
  say "project   $(short_path "$ROOT")"
  for team in $teams; do
    say ""
    team_paths "$team"
    _status_team_text
  done
  say ""
  if [ "$(printf '%s\n' "$teams" | wc -w | tr -d ' ')" -gt 1 ]; then
    say "several teams: add --team <name> to a command · each team has its own session: teamctl attach --team <name>"
    say "they share this project's Beads; a named team's agents are <team>.<role> there (bd list --assignee review.lead …)"
  fi
  say "tasks and messages live in Beads:  bd ready · bd list --status in_progress · bd list --assignee <role> --status open,in_progress,blocked --include-infra"
}

# teamctl teams — the short list
cmd_teams() {
  local team lead state count kb
  require_tools
  load_project any
  printf '%-16s %-12s %-16s %-7s %-8s %s\n' TEAM STATE LEAD AGENTS DISK SESSION
  for team in $(team_list); do
    team_paths "$team"
    SESSION="$(session_name_for_project)"
    if ! tm_session_exists "$SESSION"; then
      state="not running"
    elif [ "$(tm_alive_count "$SESSION")" -eq 0 ]; then
      state="ended"
    else
      state="running"
    fi
    lead="$(reg_field "$WOLFMUX_LEAD_ROLE" label 2>/dev/null || true)"
    count="$(reg_list | wc -l | tr -d ' ')"
    # Worktrees of this team's workers (the lead works in your own checkout and adds
    # nothing). This is the command that MEASURES: a du over every lane, seconds on a
    # busy machine, and the number it leaves behind is what `teamctl status` shows.
    kb="$(disk_team_kb_measure)"
    printf '%-16s %-12s %-16s %-7s %-8s %s\n' "$team" "$state" "${lead:--}" "$count" "$(human_size "$kb")" "$SESSION"
  done
  say ""
  say "disk: $(disk_free_label) free · take the build output of parked lanes: teamctl prune --dry-run"
}

cmd_panes() {
  require_tools
  load_project
  require_session
  width="$(role_column_width)"
  printf '%-*s %-6s %-16s %-8s %-7s %s\n' "$width" ROLE PANE COMMAND PID STATE CWD
  tmx list-panes -s -t "=$SESSION" \
    -F '#{?#{@ai_role},#{@ai_role},(untagged)}|#{pane_id}|#{pane_current_command}|#{pane_pid}|#{?pane_dead,exited(#{pane_dead_status}),running}|#{pane_current_path}' |
    while IFS='|' read -r role pane command pid state cwd; do
      printf '%-*s %-6s %-16s %-8s %-7s %s\n' "$width" "$role" "$pane" "$command" "$pid" "$state" "$(short_path "$cwd")"
    done
}

_pane_or_die() { # <role> — prints the pane id
  local pane width
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
  if [ -n "${TERM_PROGRAM:-}" ] && [ -d "$STATE_DIR" ]; then meta_put last_terminal "$TERM_PROGRAM" 2>/dev/null || true; fi
  [ -t 0 ] && [ -t 1 ] || die "not a terminal. In your own terminal run: teamctl attach   (or: tmux -L $WOLFMUX_TMUX_SOCKET attach -t $SESSION)"
  exec "$TMUX_BIN" -L "$WOLFMUX_TMUX_SOCKET" attach-session -t "=$SESSION"
}
