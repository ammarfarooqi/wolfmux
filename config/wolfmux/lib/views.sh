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

# --- Claude's agent view in an agent's pane --------------------------------------------------
# /bg sends a Claude conversation to the background: Claude Code turns the pane's own process
# into its agent view (`claude agents`), and the conversation goes on as a background chat of
# Claude's daemon, outside the pane. That is how the comms lead's identity leaked on 2026-10-19
# (lib/common.sh identity_in_own_pane). The pane looks alive to tmux, but no agent works in it.

# agent_view_roles <session> — the roles, one per line, whose pane's own process is Claude's
# agent view: a word whose last path part is `claude`, then the word `agents`. One tmux read
# for every pane of the session and ONE ps call for all of their processes.
agent_view_roles() {
  local panes pids
  panes="$(tmx list-panes -s -t "=$1" -F '#{@ai_role} #{pane_pid}' 2>/dev/null | awk 'NF == 2 && $2 ~ /^[0-9]+$/')" || panes=""
  [ -n "$panes" ] || return 0
  pids="$(printf '%s\n' "$panes" | awk '{ printf "%s%s", sep, $2; sep = "," }')"
  { printf '%s\n--\n' "$panes"; "$WOLFMUX_PS_BIN" -o pid=,command= -p "$pids" 2>/dev/null || true; } | awk '
    !listed && $0 == "--" { listed = 1; next }
    !listed { role[$2] = $1; next }
    ($1 in role) {
      for (i = 2; i < NF; i++) {
        n = split($i, part, "/")
        if (part[n] == "claude" && $(i + 1) == "agents") { print role[$1]; break }
      }
    }'
}

# agent_view_continued_in <session id> <workdir> — the id of the background chat the agent's
# conversation went on in: the LAST "continued-in" line of its transcript (field
# continuedInSessionId). Only the tail is read: a transcript can be hundreds of MB.
agent_view_continued_in() {
  local file id
  file="$(session_transcript "${1:-}" "${2:-}" 2>/dev/null || true)"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  # The id is matched, not parsed: the first line of the tail is usually cut, and a line that
  # does not parse must not hide the id it carries.
  id="$(tail -c 65536 "$file" 2>/dev/null | grep -E '"type": ?"continued-in"' | tail -1 |
    grep -oE '"continuedInSessionId": ?"[0-9A-Fa-f-]+"' | tail -1 | grep -oE '[0-9A-Fa-f-]{36}' || true)"
  if valid_session_id "$id"; then printf '%s\n' "$id"; fi
}

# agent_view_hint <continued-in id or empty> — the line under a backgrounded agent's row
agent_view_hint() {
  if [ -n "${1:-}" ]; then
    printf "this pane runs Claude's agent view; its conversation continued in %s as a background chat\n" "$1"
  else
    printf "this pane runs Claude's agent view; its conversation continued as a background chat (its transcript names none)\n"
  fi
}

_status_rows() { # emits one JSON object per agent
  local role kind pane state branch ahead dirty workdir model cctx repo session_id recorded_id label view_roles=" " continued shown_id shown_continued held_n held_oldest wake
  # Which panes run Claude's agent view: asked once for the whole team, not once per agent.
  if [ -n "$SESSION_LIVE" ]; then view_roles=" $(agent_view_roles "$SESSION" | tr '\n' ' ')"; fi
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
    # A live pane whose process is Claude's agent view: backgrounded, and where the chat went.
    continued=""
    if [ "$state" = "running" ]; then
      case "$view_roles" in
        *" $role "*)
          state="backgrounded"
          continued="$(agent_view_continued_in "$session_id" "$workdir")"
          ;;
      esac
    fi
    # The memory lead's conversation ids, as printed: "hidden" for anybody but you and that lead (memory_id_hidden).
    # The real ones still read its transcript, just above and below.
    shown_id="$session_id" shown_continued="$continued"
    if memory_id_hidden "$role"; then
      shown_id="${session_id:+hidden}" shown_continued="${continued:+hidden}"
    fi
    recorded_id="$(reg_field "$role" model_id)"
    # Notices its agent has not been given yet (lib/inbox.sh), and for a lead whether its wake
    # waiter runs (v1.23.0): two file reads, no tmux.
    held_n="$(inbox_count_undelivered "$role")" held_oldest="$(inbox_oldest_undelivered "$role")" wake="" WAKE_SINCE=""
    if [ "$kind" = "lead" ]; then
      inbox_wake_state "$role"
      wake="$WAKE_STATE"
    fi
    agent_context "$workdir" "$model" "$(reg_field "$role" family)" "$session_id" "$(reg_field "$role" model_context)" "$recorded_id" "$(reg_field "$role" model_at)" "$(reg_field "$role" compact_window)"
    # A /model typed into its pane: the record follows, so its next restart keeps that model (agent_adopt_live).
    if [ "$MR_HOW" = "transcript" ]; then
      agent_adopt_live "$role" "$CTX_MODEL_AT"
      model="$(reg_field "$role" model)"
      recorded_id="$(reg_field "$role" model_id)"
    fi
    if [ -n "$CTX_TOKENS" ]; then
      cctx="$(ctx_display "$CTX_TOKENS" "$CTX_LIMIT")"
    else
      cctx="-"
    fi
    # Which model it runs is the one resolver's answer (models_running, lib/models.sh), the same
    # one teamctl models prints: status does not work it out a second time. An agent that is not
    # on fable, opus, sonnet or haiku has no such answer: its record's label and id stand.
    #   model_id     the id it runs (null: neither its record nor its transcript says, "Opus ?")
    #   recorded_id  the id its record says it was started with (null: a record from before v1.18.0)
    #   known_from   record | transcript | unknown (null: not on an alias)
    #   label_mark   "*" when known_from is transcript: the table puts it after the label
    label="$MR_LABEL"
    [ -n "$label" ] || label="$(agent_label "$role")"
    "$JQ_BIN" -cn --arg role "$role" --arg kind "$kind" --arg model "$model" \
      --arg label "$label" --arg family "$(reg_field "$role" family)" --arg billing "$(_billing_of "$role")" --arg state "$state" --arg pane "$pane" \
      --arg branch "$branch" --arg ahead "$ahead" --arg dirty "$dirty" --arg workdir "$workdir" --arg repo "$repo" \
      --arg permissions "$(reg_field "$role" permissions)" --arg spawned_by "$(reg_field "$role" spawned_by)" \
      --arg ct "$CTX_TOKENS" --arg cw "$CTX_WINDOW" --arg cl "$CTX_LIMIT" --arg cr "$CTX_REQUESTS" --arg cctx "$cctx" \
      --arg session_id "$shown_id" --arg keep "$(reg_field "$role" keep_build)" \
      --arg model_id "$MR_ID" --arg recorded_id "$recorded_id" --arg known_from "$MR_HOW" --arg mark "$MR_MARK" \
      --arg model_source "$(reg_field "$role" model_source)" \
      --arg hw "$(reg_field "$role" hold_why)" --arg hk "$(reg_field "$role" hold_kb)" --arg ha "$(reg_field "$role" hold_at)" \
      --arg held_n "$held_n" --arg held_oldest "$held_oldest" --arg wake "$wake" --arg wake_since "$WAKE_SINCE" \
      --arg continued "$shown_continued" --arg hint "$(if [ "$state" = "backgrounded" ]; then agent_view_hint "$shown_continued"; fi)" \
      '{role: $role, kind: $kind, model: $model, label: $label, label_mark: $mark, family: $family, billing: $billing, state: $state, pane: $pane,
        keep_build: (if $keep == "on" then "on" else "off" end),
        holding: (if $kind == "worker" and $state != "running" and $state != "backgrounded" and $hw != "" then
                    {kb: (($hk | tonumber?) // null), reason: $hw,
                     checked_at: ((($ha | tonumber?) // null) | if . == null then null else todate end),
                     checked_epoch: (($ha | tonumber?) // null)}
                  else null end),
        model_id: (if $model_id == "" then null else $model_id end), recorded_id: (if $recorded_id == "" then null else $recorded_id end),
        known_from: (if $known_from == "" then null else $known_from end), model_source: (if $model_source == "" then null else $model_source end),
        permissions: (if $permissions == "" then "ask" else $permissions end),
        spawned_by: (if $spawned_by == "" then "operator" else $spawned_by end),
        session_id: $session_id,
        branch: $branch, commits_ahead: $ahead, uncommitted: $dirty, workdir: $workdir, repo: $repo,
        context_tokens: (if $ct == "" then null else ($ct | tonumber) end),
        context_window: ($cw | tonumber? // 0), context_limit: ($cl | tonumber? // null), requests: ($cr | tonumber? // 0), context: $cctx,
        held: {count: ($held_n | tonumber? // 0), oldest_epoch: ($held_oldest | tonumber? // null),
               wake: (if $wake == "" then null else $wake end), wake_since: ($wake_since | tonumber? // null)}}
        + (if $state == "backgrounded" then {hint: $hint, continued_in: (if $continued == "" then null else $continued end)} else {} end)'
  done
}

# The `holding` of a row is what the last reclaim check wrote into that lane's record
# (lib/reclaim.sh: hold_why, hold_kb, hold_at). Status only reads it. Asking again here would
# be a du, a Beads query and a GitHub query per parked lane, on a command that runs every few
# minutes — so the line can be older than the lane's state, and _hold_age says how old.
#
# _hold_age <epoch> — nothing while the check is fresh (under ten minutes), else its age
_hold_age() {
  local age
  case "${1:-x}" in "" | *[!0-9]* | 0?*) return 0 ;; esac
  age=$(($(now_epoch) - $1))
  if [ "$age" -lt 600 ]; then
    return 0
  elif [ "$age" -lt 7200 ]; then
    printf ' · checked %s min ago' "$((age / 60))"
  elif [ "$age" -lt 172800 ]; then
    printf ' · checked %s h ago' "$((age / 3600))"
  else
    printf ' · checked %s d ago' "$((age / 86400))"
  fi
}

# ctx_display <used> <limit> - "142k/167k 85%": what the CONTEXT column shows, in status, in
# the dashboard, in the watch's notices and in a checkpoint: what the conversation holds, the
# limit its CLI compacts at (context_limit_for, lib/policy.sh), and the share of THAT. When the
# limit is unknown (empty or 0: nobody declared the window) there is no limit and no share:
# the tokens still mean something on their own, a share of a guess does not.
ctx_display() {
  awk -v t="$1" -v w="$2" 'function k(n) {
    if (n >= 1000000) return sprintf("%.1fM", n / 1000000);
    if (n >= 10000) return sprintf("%.0fk", n / 1000);
    return sprintf("%.1fk", n / 1000)
  }
  BEGIN {
    if (w + 0 > 0) printf "%s/%s %d%%\n", k(t), k(w), int(t * 100 / w);
    else printf "%s\n", k(t)
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
    --arg lc "$(policy_get lead-context)" --arg cx "$(policy_get context-exclude)" \
    --arg pending "$(approvals_pending_count)" \
    --arg dg "$(policy_get disk-guard)" --arg dmin "$(policy_get disk-min-gb)" --arg lnm "$(policy_get link-node-modules)" \
    --arg ap "$(policy_get auto-prune)" --arg ar "$(policy_get auto-reclaim)" \
    --arg free "$(disk_free_kb)" --arg trees "$(disk_team_kb_cached)" --arg parked "$(disk_parked_kb "$STATE_DIR")" \
    '{team: $team, root: $root, session: $session, session_running: ($running == "1"), manager: "lead",
      founder: $founder, orphaned: ($orphaned == "1"),
      policy: {lead_permissions: $lp, worker_permissions: $wp, worker_spawn: $ws, worker_isolation: $wi, worker_context: $wc, lead_teams: $lt,
               lead_context: $lc, context_exclude: ($cx | split(" ") | map(select(length > 0))),
               disk_guard: $dg, disk_min_gb: ($dmin | tonumber), link_node_modules: $lnm, auto_prune: $ap, auto_reclaim: $ar},
      disk: {free_kb: (if $free == "" then null else ($free | tonumber) end),
             worktrees_kb: (if $trees == "" then null else ($trees | tonumber) end),
             parked_kb: (if $parked == "" then null else ($parked | tonumber) end)},
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
  # Free disk is a df call; the lane total is whatever the last command that changed the
  # lanes left behind, because measuring it here is a du over every worktree (lib/disk.sh).
  say "  disk    $(disk_free_label) free · this team's lanes: $(disk_team_label) · spawn guard: $(policy_get disk-guard) under $(policy_get disk-min-gb) GB · auto-prune on park: $(policy_get auto-prune) · auto-reclaim: $(policy_get auto-reclaim)"
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
    printf '     %-*s %-14s %-12s %-5s %-5s %-10s %-16s %-30s %-6s %-6s %-14s %s\n' "$((width + 2))" ROLE MODEL STATE PANE PERM "SPAWNED BY" REPO BRANCH AHEAD DIRTY CONTEXT WORKDIR
  else
    printf '     %-*s %-14s %-12s %-5s %-5s %-10s %-30s %-6s %-6s %-14s %s\n' "$((width + 2))" ROLE MODEL STATE PANE PERM "SPAWNED BY" BRANCH AHEAD DIRTY CONTEXT WORKDIR
  fi
  # "|" keeps empty columns in place; a whitespace IFS would collapse them.
  # A metered agent is marked with a $ after its label (every token it uses is billed), and a
  # model its record does not vouch for with a * (label_mark; the legend is below the table).
  # CONTEXT is what the agent's transcript says the conversation holds, the limit its CLI
  # compacts at, and the share of that limit (tokens alone when the limit is unknown: see
  # ctx_display). A stopped worker's line is the reuse-or-respawn signal.
  # The three hold fields come last, and the reason last of all: it is the one free text in
  # the row, and `read` gives whatever is left to its final variable.
  printf '%s\n' "$rows" | "$JQ_BIN" -r '[.kind, .role, (.label + .label_mark + (if .billing == "metered" then "$" else "" end)), .state, (if .pane == "" then "-" else .pane end), .permissions, .spawned_by, .branch, .commits_ahead, .uncommitted, .context, .workdir, (.repo // ""), (.continued_in // ""),
      (.held.count | tostring), ((.held.oldest_epoch // "") | tostring), (.held.wake // ""), ((.held.wake_since // "") | tostring),
      ((.holding.kb // "") | tostring), ((.holding.checked_epoch // "") | tostring), (.holding.reason // "")] | join("|")' |
    while IFS='|' read -r kind role label state pane permissions spawned_by branch ahead dirty cctx workdir repo continued held_n held_oldest wake wake_since hold_kb hold_epoch hold_why; do
      if [ "$kind" = "lead" ]; then
        printf '  %s %-*s' "$WOLFMUX_LEAD_MARK" "$((width + 2))" "$role"
      else
        printf '    %s %-*s' "$WOLFMUX_WORKER_MARK" "$width" "$role"
      fi
      if [ -n "$repo_col" ]; then
        printf ' %-14s %-12s %-5s %-5s %-10s %-16s %-30s %-6s %-6s %-14s %s\n' "$label" "$state" "$pane" "$permissions" "$spawned_by" "$([ -n "$repo" ] && basename "$repo" || printf -- '-')" "$branch" "$ahead" "$dirty" "$cctx" "$(short_path "$workdir")"
      else
        printf ' %-14s %-12s %-5s %-5s %-10s %-30s %-6s %-6s %-14s %s\n' "$label" "$state" "$pane" "$permissions" "$spawned_by" "$branch" "$ahead" "$dirty" "$cctx" "$(short_path "$workdir")"
      fi
      # A parked lane that could not be taken off the books says what it holds and why, right
      # under its own row: space nobody can see is the complaint this line answers. A parked
      # lane nobody has asked yet says that instead of saying nothing.
      # A backgrounded agent (Claude's agent view in its pane) says where its conversation went.
      # A lead whose agent has notices it has not been given (v1.23.0, issue #34): how many, how
      # old, and whether it wakes itself for them.
      if [ "$kind" = "lead" ] && [ "${held_n:-0}" != "0" ]; then
        printf '        %s\n' "$(inbox_held_line "$role" "$held_n" "$held_oldest" "$wake" "$wake_since")"
      fi
      if [ "$state" = "backgrounded" ]; then
        printf '        %s\n' "$(agent_view_hint "$continued")"
      elif [ "$kind" = "worker" ] && [ "$state" != "running" ] && [ -d "$workdir" ]; then
        if [ -n "$hold_why" ]; then
          printf '        holding %s: %s%s\n' "$(human_size "${hold_kb:-0}")" "$hold_why" "$(_hold_age "$hold_epoch")"
        else
          printf '        holding its worktree: not checked yet (what is in the way: teamctl reclaim --dry-run)\n'
        fi
      fi
    done
  if [ -n "$repo_col" ]; then
    say "  REPO: the repository a teammate's worktree and branch live in ('-' = this project). teamctl spawn <role> <model> --repo <path>"
  fi
  if [ -n "$(printf '%s\n' "$rows" | "$JQ_BIN" -r 'select(.label_mark == "*") | .role' | head -1)" ]; then
    say "  $MODELS_MARK_LEGEND"
  fi
  if [ -n "$(printf '%s\n' "$rows" | "$JQ_BIN" -r 'select(.billing == "metered") | .role' | head -1)" ]; then
    say '  $ = metered: every token is billed to a prepaid balance, not to a plan or subscription (WOLFMUX_METERED=on, the owner'"'"'s decision)'
  fi
}

# teamctl status [--json] — every team of the project, or the one named with --team
cmd_status() {
  local json=0 teams team first=1 stalled role asked
  if [ "${1:-}" = "--json" ]; then json=1; fi
  require_tools
  load_project any
  if [ -n "$TEAM" ]; then teams="$TEAM"; else teams="$(team_list)"; fi
  # One of the three lookers of lib/stall.sh: an agent whose last turn ended on an error, idle
  # with a task in progress, is told to its lead once. Before the table, so the badge counts it.
  # team_paths sets TEAM: what was asked for is kept and put back, or a team list reads as --team
  stalled="" asked="$TEAM"
  for team in $teams; do
    team_paths "$team"
    stalled="$stalled$(TEAM="$team" stall_scan | sed "s|^|$team/|")
"
  done
  TEAM="$asked"
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
  for role in $stalled; do
    say "stalled   $role: its last turn ended on an error, its task is in progress; the lead has been told (teamctl restart ${role#*/} --continue)"
  done
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
    say "tasks and messages live in the native store:  teamctl tasks · teamctl mail · teamctl show <id> · teamctl store"
  else
    say "tasks and messages live in Beads:  bd ready · bd list --status in_progress · bd list --assignee <role> --status open,in_progress,blocked --include-infra"
  fi
}

# _teams_facts: for the loaded team: TEAMS_STATE, TEAMS_FOUNDER, TEAMS_LEAD, TEAMS_COUNT, TEAMS_KB
_teams_facts() {
  SESSION="$(session_name_for_project)"
  TEAMS_STATE="running"
  if team_orphaned; then TEAMS_STATE="orphaned"; fi
  TEAMS_FOUNDER="$(team_founder)"
  TEAMS_LEAD="" TEAMS_LEAD_MARK="" TEAMS_LEAD_ID="" TEAMS_LEAD_FROM=""
  if reg_exists "$WOLFMUX_LEAD_ROLE" 2>/dev/null; then
    # The lead's model, by the resolver status and teamctl models use (lib/models.sh)
    agent_model "$WOLFMUX_LEAD_ROLE"
    agent_adopt_live "$WOLFMUX_LEAD_ROLE" "${MT_MODEL_AT:-}" # a /model typed into its pane goes on record
    TEAMS_LEAD="$MR_LABEL" TEAMS_LEAD_MARK="$MR_MARK" TEAMS_LEAD_ID="$MR_ID" TEAMS_LEAD_FROM="$MR_HOW"
  fi
  TEAMS_COUNT="$(reg_list | wc -l | tr -d ' ')"
  # Worktrees of this team's workers (the lead works in your own checkout and adds nothing).
  # This is the command that MEASURES: a du over every lane, seconds on a busy machine, and
  # the number it leaves behind in state/<project>/disk-kb is what `teamctl status` shows
  # without measuring anything itself (lib/disk.sh).
  TEAMS_KB="$(disk_team_kb_measure)"
  # An orphaned team says why it is still here (lib/finish.sh): how its lead ended, its open
  # tasks (one Beads question for the whole project, the first time it is needed), and its
  # lanes with what the last check of each wrote down. GitHub is not asked here.
  TEAMS_WHY="" TEAMS_LANES_HELD=0
  TEAM_END_HOW="" TEAM_END_BY="" TEAM_END_TS="" TEAM_TASKS_OPEN=""
  if [ "$TEAMS_STATE" = "orphaned" ]; then
    team_lanes_on_record
    team_reason "$TEAM_LANES" "$TEAM_LANE_LIST"
    TEAMS_WHY="$TEAM_WHY"
    TEAMS_LANES_HELD="$TEAM_LANES"
    team_end_words >/dev/null # the reason ran it in a subshell; the JSON wants its parts
  fi
}

# teamctl teams [--json]: the short list. STATE: running, or orphaned when the team's lead is not running
# (its pane exited or is gone, or there is no session): nobody manages it then, and the note under the table
# says who may act on it.
cmd_teams() {
  local json=0 team orphans="" hint marked=""
  if [ "${1:-}" = "--json" ]; then json=1; fi
  require_tools
  load_project any
  if [ "$json" -eq 1 ]; then
    # In braces with the loop: the left side of a pipe is a subshell, and the Beads answer an
    # orphaned team's reason fetched lives there. Dropped after the pipe, it would be a file
    # nobody can name any more.
    {
      for team in $(team_list); do
        team_paths "$team"
        _teams_facts
        # lead: its label. lead_model_id and lead_known_from: the id it runs and where that is known
        # from (record | transcript | unknown; null for a lead that is not on an alias), as in status.
        # orphan: null for a team whose lead runs; otherwise why it is still here (lib/finish.sh).
        "$JQ_BIN" -cn --arg team "$team" --arg state "$TEAMS_STATE" --arg lead "$TEAMS_LEAD" --arg agents "$TEAMS_COUNT" --arg kb "$TEAMS_KB" \
          --arg founder "$TEAMS_FOUNDER" --arg session "$SESSION" --arg lead_id "$TEAMS_LEAD_ID" --arg lead_from "$TEAMS_LEAD_FROM" \
          --arg why "$TEAMS_WHY" --arg end_how "$TEAM_END_HOW" --arg end_by "$TEAM_END_BY" --arg end_ts "$TEAM_END_TS" \
          --arg tasks "${TEAM_TASKS_OPEN:-}" --arg held "$TEAMS_LANES_HELD" \
          '{team: $team, state: $state, orphaned: ($state == "orphaned"), founder: $founder, lead: $lead,
            lead_model_id: (if $lead_id == "" then null else $lead_id end), lead_known_from: (if $lead_from == "" then null else $lead_from end),
            agents: ($agents | tonumber), disk_kb: ($kb | tonumber), session: $session,
            orphan: (if $state != "orphaned" then null else
              {why: $why, kb: ($kb | tonumber), lanes_held: ($held | tonumber),
               tasks_open: ($tasks | tonumber? // null),
               lead_end: (if $end_how == "" then null else {how: $end_how, by: $end_by, ts: $end_ts} end)} end)}'
      done
      team_beads_forget || true # the scratch file of what Beads said
    } | "$JQ_BIN" -s .
    return 0
  fi
  printf '%-16s %-12s %-16s %-7s %-8s %-16s %s\n' TEAM STATE LEAD AGENTS DISK FOUNDER SESSION
  for team in $(team_list); do
    team_paths "$team"
    _teams_facts
    printf '%-16s %-12s %-16s %-7s %-8s %-16s %s\n' "$team" "$TEAMS_STATE" "${TEAMS_LEAD:--}$TEAMS_LEAD_MARK" "$TEAMS_COUNT" "$(human_size "$TEAMS_KB")" \
      "$([ "$TEAMS_FOUNDER" = "operator" ] && printf you || printf '%s' "$TEAMS_FOUNDER")" "$SESSION"
    if [ -n "$TEAMS_LEAD_MARK" ]; then marked=1; fi
    if [ "$TEAMS_STATE" = "orphaned" ]; then
      hint=""
      if [ "$team" != "$WOLFMUX_DEFAULT_TEAM" ]; then hint=" --team $team"; fi
      orphans="$orphans$team is $(team_orphaned_note) Bring it back: teamctl restart lead$hint --continue · finish it: teamctl finish$hint · delete it: teamctl destroy$hint --purge
  holding $(human_size "$TEAMS_KB"): $TEAMS_WHY
"
    fi
  done
  team_beads_forget || true # the scratch file of what Beads said
  if [ -n "$orphans" ]; then
    say ""
    printf '%s' "$orphans"
  fi
  say ""
  if [ -n "$marked" ]; then say "$MODELS_MARK_LEGEND"; fi
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
  # The memory team's lead reads its private memory in that pane (mem boot prints the card): its screen is
  # yours to look at, nobody else's (lib/memory.sh). The pane proof decides, as for every owner-only command.
  # Also a lead that was started with the memory and still holds it after the policy moved (memory_lead_started_with).
  if { memory_lead_dir "$role" >/dev/null || memory_lead_started_with "$role"; } && ! is_operator; then
    die "the pane of '$role' of team '${TEAM:-$WOLFMUX_DEFAULT_TEAM}' shows that lead's private team memory, so only the human captures it, from their own terminal. Nothing to do for you: ask that lead by Beads for what you need." 77
  fi
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
