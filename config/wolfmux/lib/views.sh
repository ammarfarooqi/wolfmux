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
  local role kind pane state branch ahead dirty workdir model cctx repo session_id
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
      ahead="$(wt_ahead "$role" "$(reg_field "$role" base_commit)" "$branch")"
    fi
    repo="$(reg_field "$role" repo)" # empty: this project. A teammate spawned with --repo: that repository.
    dirty="$(wt_dirty_count "$workdir")"
    model="$(reg_field "$role" model)"
    session_id="$(reg_field "$role" session_id)" # its own conversation: what --continue reopens, and what CONTEXT reads
    agent_context "$workdir" "$model" "$(reg_field "$role" family)" "$session_id"
    if [ -n "$CTX_TOKENS" ]; then
      cctx="$(ctx_display "$CTX_TOKENS" "$CTX_WINDOW")"
    else
      cctx="-"
    fi
    "$JQ_BIN" -cn --arg role "$role" --arg kind "$kind" --arg model "$model" \
      --arg label "$(reg_field "$role" label)" --arg family "$(reg_field "$role" family)" --arg billing "$(_billing_of "$role")" --arg state "$state" --arg pane "$pane" \
      --arg branch "$branch" --arg ahead "$ahead" --arg dirty "$dirty" --arg workdir "$workdir" --arg repo "$repo" \
      --arg permissions "$(reg_field "$role" permissions)" --arg spawned_by "$(reg_field "$role" spawned_by)" \
      --arg ct "$CTX_TOKENS" --arg cw "$CTX_WINDOW" --arg cr "$CTX_REQUESTS" --arg cctx "$cctx" \
      --arg session_id "$session_id" \
      '{role: $role, kind: $kind, model: $model, label: $label, family: $family, billing: $billing, state: $state, pane: $pane,
        permissions: (if $permissions == "" then "ask" else $permissions end),
        spawned_by: (if $spawned_by == "" then "operator" else $spawned_by end),
        session_id: $session_id,
        branch: $branch, commits_ahead: $ahead, uncommitted: $dirty, workdir: $workdir, repo: $repo,
        context_tokens: (if $ct == "" then null else ($ct | tonumber) end),
        context_window: ($cw | tonumber? // 0), requests: ($cr | tonumber? // 0), context: $cctx}'
  done
}

# ctx_display <tokens> <window> — "142k 71%": what the CONTEXT column shows. When the
# window is unknown the share is 0% and the tokens still mean something on their own.
ctx_display() {
  awk -v t="$1" -v w="$2" 'BEGIN {
    if (t >= 1000000) s = sprintf("%.1fM", t / 1000000);
    else if (t >= 10000) s = sprintf("%.0fk", t / 1000);
    else s = sprintf("%.1fk", t / 1000);
    printf "%s %d%%\n", s, (w + 0 > 0 ? int(t * 100 / w) : 0)
  }'
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
  local orphaned=0
  SESSION="$(session_name_for_project)"
  SESSION_LIVE=""
  if tm_session_exists "$SESSION"; then SESSION_LIVE=1; fi
  if team_orphaned; then orphaned=1; fi
  _status_rows | "$JQ_BIN" -s --arg team "$TEAM" --arg root "$ROOT" --arg session "$SESSION" \
    --arg running "${SESSION_LIVE:-0}" --arg founder "$(team_founder)" --arg orphaned "$orphaned" --arg lp "$(policy_get lead-permissions)" \
    --arg wp "$(policy_get worker-permissions)" --arg ws "$(policy_get worker-spawn)" --arg wi "$(policy_get worker-isolation)" --arg wc "$(policy_get worker-context)" --arg lt "$(policy_get lead-teams)" \
    --arg pending "$(approvals_pending_count)" \
    '{team: $team, root: $root, session: $session, session_running: ($running == "1"), manager: "lead",
      founder: $founder, orphaned: ($orphaned == "1"),
      policy: {lead_permissions: $lp, worker_permissions: $wp, worker_spawn: $ws, worker_isolation: $wi, worker_context: $wc, lead_teams: $lt},
      approvals_pending: ($pending | tonumber), agents: .}'
}

# _status_team_text — one team as a small tree: the team, its wolf, its dogs
_status_team_text() {
  local rows width state hint="" repo_col="" role
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
  if team_orphaned; then
    say "  $(team_orphaned_note) Bring it back: teamctl restart lead$hint --continue · delete it: teamctl destroy$hint --purge"
  fi
  say "  policy  $(policy_summary) · approvals pending: $(approvals_pending_count)"
  rows="$(_status_rows)"
  if [ -z "$rows" ]; then
    say "  no agents on record. Start it: teamctl start <fable|astra>$hint"
    return 0
  fi
  width="$(role_column_width)"
  # The REPO column costs a whole column on every team, and almost every team has none:
  # it appears only when a teammate really works in another repository (teamctl spawn --repo).
  for role in $(reg_list); do
    if [ -n "$(reg_field "$role" repo 2>/dev/null || true)" ]; then
      repo_col=1
      break
    fi
  done
  if [ -n "$repo_col" ]; then
    printf '     %-*s %-14s %-11s %-5s %-5s %-10s %-16s %-30s %-6s %-6s %-9s %s\n' "$((width + 2))" ROLE MODEL STATE PANE PERM "SPAWNED BY" REPO BRANCH AHEAD DIRTY CONTEXT WORKDIR
  else
    printf '     %-*s %-14s %-11s %-5s %-5s %-10s %-30s %-6s %-6s %-9s %s\n' "$((width + 2))" ROLE MODEL STATE PANE PERM "SPAWNED BY" BRANCH AHEAD DIRTY CONTEXT WORKDIR
  fi
  # "|" keeps empty columns in place; a whitespace IFS would collapse them.
  # A metered agent is marked with a $ after its label (every token it uses is billed).
  # CONTEXT is what the agent's transcript says the conversation holds: tokens, and the
  # share of the window. A stopped worker's line is the reuse-or-respawn signal.
  printf '%s\n' "$rows" | "$JQ_BIN" -r '[.kind, .role, (.label + (if .billing == "metered" then "$" else "" end)), .state, (if .pane == "" then "-" else .pane end), .permissions, .spawned_by, .branch, .commits_ahead, .uncommitted, .context, .workdir, (.repo // "")] | join("|")' |
    while IFS='|' read -r kind role label state pane permissions spawned_by branch ahead dirty cctx workdir repo; do
      if [ "$kind" = "lead" ]; then
        printf '  %s %-*s' "$WOLFMUX_LEAD_MARK" "$((width + 2))" "$role"
      else
        printf '    %s %-*s' "$WOLFMUX_WORKER_MARK" "$width" "$role"
      fi
      if [ -n "$repo_col" ]; then
        printf ' %-14s %-11s %-5s %-5s %-10s %-16s %-30s %-6s %-6s %-9s %s\n' "$label" "$state" "$pane" "$permissions" "$spawned_by" "$([ -n "$repo" ] && basename "$repo" || printf -- '-')" "$branch" "$ahead" "$dirty" "$cctx" "$(short_path "$workdir")"
      else
        printf ' %-14s %-11s %-5s %-5s %-10s %-30s %-6s %-6s %-9s %s\n' "$label" "$state" "$pane" "$permissions" "$spawned_by" "$branch" "$ahead" "$dirty" "$cctx" "$(short_path "$workdir")"
      fi
    done
  if [ -n "$repo_col" ]; then
    say "  REPO: the repository a teammate's worktree and branch live in ('-' = this project). teamctl spawn <role> <model> --repo <path>"
  fi
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
    if [ "$(store_kind)" = "native" ]; then
      say "they share this project's store; a named team's agents are <team>.<role> there (teamctl tasks review.lead …)"
    else
      say "they share this project's Beads; a named team's agents are <team>.<role> there (bd list --assignee review.lead …)"
    fi
  fi
  # The footer names the store this project actually uses: pointing a native project at bd
  # sends its reader to a database that is not there.
  if [ "$(store_kind)" = "native" ]; then
    say "tasks and messages live in the native store:  teamctl tasks · teamctl inbox <role> · teamctl show <id> · teamctl store"
  else
    say "tasks and messages live in Beads:  bd ready · bd list --status in_progress · bd list --assignee <role> --status open,in_progress,blocked --include-infra"
  fi
}

# _teams_facts: for the loaded team: TEAMS_STATE, TEAMS_FOUNDER, TEAMS_LEAD, TEAMS_COUNT, TEAMS_KB
_teams_facts() {
  local role
  SESSION="$(session_name_for_project)"
  TEAMS_STATE="running"
  if team_orphaned; then TEAMS_STATE="orphaned"; fi
  TEAMS_FOUNDER="$(team_founder)"
  TEAMS_LEAD="$(reg_field "$WOLFMUX_LEAD_ROLE" label 2>/dev/null || true)"
  TEAMS_COUNT="$(reg_list | wc -l | tr -d ' ')"
  # worktrees of this team's workers (the lead works in your own checkout and adds nothing)
  TEAMS_KB=0
  for role in $(reg_list); do
    if [ "$(reg_field "$role" kind)" = "worker" ]; then TEAMS_KB=$((TEAMS_KB + $(disk_kb "$(reg_field "$role" workdir)"))); fi
  done
}

# teamctl teams [--json]: the short list. STATE: running, or orphaned when the team's lead is not running
# (its pane exited or is gone, or there is no session): nobody manages it then, and the note under the table
# says who may act on it.
cmd_teams() {
  local json=0 team orphans="" hint
  if [ "${1:-}" = "--json" ]; then json=1; fi
  require_tools
  load_project any
  if [ "$json" -eq 1 ]; then
    for team in $(team_list); do
      team_paths "$team"
      _teams_facts
      "$JQ_BIN" -cn --arg team "$team" --arg state "$TEAMS_STATE" --arg lead "$TEAMS_LEAD" --arg agents "$TEAMS_COUNT" --arg kb "$TEAMS_KB" \
        --arg founder "$TEAMS_FOUNDER" --arg session "$SESSION" \
        '{team: $team, state: $state, orphaned: ($state == "orphaned"), founder: $founder, lead: $lead, agents: ($agents | tonumber),
          disk_kb: ($kb | tonumber), session: $session}'
    done | "$JQ_BIN" -s .
    return 0
  fi
  printf '%-16s %-12s %-16s %-7s %-8s %-16s %s\n' TEAM STATE LEAD AGENTS DISK FOUNDER SESSION
  for team in $(team_list); do
    team_paths "$team"
    _teams_facts
    printf '%-16s %-12s %-16s %-7s %-8s %-16s %s\n' "$team" "$TEAMS_STATE" "${TEAMS_LEAD:--}" "$TEAMS_COUNT" "$(human_size "$TEAMS_KB")" \
      "$([ "$TEAMS_FOUNDER" = "operator" ] && printf you || printf '%s' "$TEAMS_FOUNDER")" "$SESSION"
    if [ "$TEAMS_STATE" = "orphaned" ]; then
      hint=""
      if [ "$team" != "$WOLFMUX_DEFAULT_TEAM" ]; then hint=" --team $team"; fi
      orphans="$orphans$team is $(team_orphaned_note) Bring it back: teamctl restart lead$hint --continue · delete it: teamctl destroy$hint --purge
"
    fi
  done
  if [ -n "$orphans" ]; then
    say ""
    printf '%s' "$orphans"
  fi
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
