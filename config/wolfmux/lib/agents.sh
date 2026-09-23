#!/bin/bash
# agents.sh — agent lifecycle: start, spawn, run, stop, restart, destroy, nudge.
#
# Model-neutral on purpose: a lead is "whatever launcher the model table names",
# and workers neither know nor care whether the lead is Fable or Astra.

WOLFMUX_NUDGE_DEBOUNCE="${WOLFMUX_NUDGE_DEBOUNCE:-3}"

session_name_for_project() {
  local stored candidate
  stored="$(meta_get session || true)"
  if [ -n "$stored" ]; then
    printf '%s\n' "$stored"
    return 0
  fi
  candidate="team-$(sanitize_name "$(basename "$ROOT")")"
  # Same directory name, different repository: fall back to the unique project key.
  if tm_session_exists "$candidate" && [ "$(tm_session_root "$candidate")" != "$ROOT" ]; then
    candidate="team-$PROJECT_KEY"
  fi
  if [ "${TEAM:-$WOLFMUX_DEFAULT_TEAM}" != "$WOLFMUX_DEFAULT_TEAM" ]; then candidate="$candidate-$TEAM"; fi
  printf '%s\n' "$candidate"
}

# agent_command <role> [--continue] — fills AGENT_CMD: what a pane of this team runs
agent_command() {
  AGENT_CMD=("$TEAMCTL_SELF")
  if [ "$TEAM" != "$WOLFMUX_DEFAULT_TEAM" ]; then AGENT_CMD+=(--team "$TEAM"); fi
  AGENT_CMD+=(_run-agent "$ROOT" "$1")
  if [ "${2:-}" = "--continue" ]; then AGENT_CMD+=(--continue); fi
}

require_session() {
  SESSION="$(session_name_for_project)"
  tm_session_exists "$SESSION" || die "team '$TEAM' has no session running. Start it: teamctl start <fable|astra>$([ "$TEAM" = "$WOLFMUX_DEFAULT_TEAM" ] || printf ' --team %s' "$TEAM")"
}

# agent_state <role> — running | exited(N) | stopped
agent_state() {
  local pane state
  pane="$(tm_pane_for_role "$SESSION" "$1" 2>/dev/null || true)"
  state="$(tm_pane_state "$pane")"
  case "$state" in
    running) printf 'running\n' ;;
    exited:*) printf 'exited(%s)\n' "${state#exited:}" ;;
    *) printf 'stopped\n' ;;
  esac
}

# new_record <role> <kind> <model-key> <workdir> <branch> <base-ref> <base-commit> <kickoff> <spawned-by>
new_record() {
  local launcher permissions
  # model_info must run in THIS shell: launcher_path runs in a substitution
  # subshell, so the MODEL_* variables it sets there never reach us.
  model_info "$3" || die "unknown model '$3' (known: $WOLFMUX_MODEL_KEYS)"
  launcher="$(launcher_path "$3")"
  [ -x "$launcher" ] || die "launcher missing or not executable: $launcher  (run: teamctl doctor)"
  permissions="$(effective_permissions "$2" "$MODEL_FAMILY")"
  "$JQ_BIN" -n --arg role "$1" --arg kind "$2" --arg model "$3" --arg label "$MODEL_LABEL" \
    --arg family "$MODEL_FAMILY" --arg launcher "$launcher" --arg workdir "$4" --arg branch "$5" \
    --arg base_ref "$6" --arg base_commit "$7" --arg kickoff "$8" --arg now "$(now_iso)" \
    --arg spawned_by "${9:-operator}" --arg permissions "$permissions" --arg model_id "$MODEL_ID" --arg billing "$MODEL_BILLING" \
    '{role: $role, kind: $kind, model: $model, model_id: $model_id, label: $label, family: $family, billing: $billing, launcher: $launcher,
      workdir: $workdir, branch: $branch, base_ref: $base_ref, base_commit: $base_commit,
      kickoff: $kickoff, spawned_by: $spawned_by, permissions: $permissions,
      pane_id: "", state: "starting", created_at: $now, updated_at: $now}' |
    reg_put "$1"
}

# start_permitted — who is starting this team? You: always ("operator"). An agent: only a
# lead, and only its own team or a team that does not exist yet (policy lead-teams of ITS
# team, default on). Never a worker, never somebody else's existing team. Prints the
# founder's Beads name; exit status 1 means refused.
start_permitted() {
  local role own exists allowed keep_team="$TEAM"
  role="$(caller_role)"
  if [ -z "$role" ]; then
    printf 'operator\n'
    return 0
  fi
  own="$(caller_team)"
  own="${own:-$WOLFMUX_DEFAULT_TEAM}"
  if [ "$role" != "$WOLFMUX_LEAD_ROLE" ]; then
    warn "'teamctl start' is for you and for leads. You are '$(team_identity "$own" "$role")': ask your lead."
    return 1
  fi
  if [ "$TEAM" != "$own" ]; then
    exists=""
    if [ -n "$(reg_list 2>/dev/null)" ] || tm_session_exists "$(session_name_for_project)" 2>/dev/null; then exists=1; fi
    team_paths "$own"
    allowed="$(policy_get lead-teams)"
    team_paths "$keep_team"
    if [ -n "$exists" ]; then
      warn "team '$TEAM' already exists and has its own lead ($(team_identity "$TEAM" "$WOLFMUX_LEAD_ROLE")). Message it; you do not manage it."
      return 1
    fi
    if [ "$allowed" != "on" ]; then
      warn "founding teams is switched off for your team (teamctl policy lead-teams). Ask the human."
      return 1
    fi
  fi
  team_identity "$own" "$role"
}

# --- teamctl start <fable|astra> ------------------------------------------------
cmd_start() {
  local model="" attach=1 beads="ask" pane branch opt_lead="" opt_worker="" opt_spawn="" resume=0 role stopped="" previous previous_model="" handover="" founder="operator"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-attach | -d) attach=0 ;;
      --continue) resume=1 ;;
      --handover)
        [ "$#" -ge 2 ] || die_usage "--handover needs the id of the bead that holds the handover"
        valid_bead_id "$2" || die_usage "--handover: '$2' is not a bead id"
        handover="$2"
        shift
        ;;
      --init-beads) beads="yes" ;;
      --skip-beads) beads="skip" ;;
      --lead-permissions | --worker-permissions | --worker-spawn)
        [ "$#" -ge 2 ] || die_usage "$1 needs a value: $(policy_choices "${1#--}")"
        policy_valid "${1#--}" "$2" || die_usage "$1 must be one of: $(policy_choices "${1#--}")"
        case "$1" in
          --lead-permissions) opt_lead="$2" ;;
          --worker-permissions) opt_worker="$2" ;;
          --worker-spawn) opt_spawn="$2" ;;
        esac
        shift
        ;;
      -*) die_usage "unknown option for start: $1" ;;
      *) model="$1" ;;
    esac
    shift
  done
  [ -n "$model" ] && model_info "$model" ||
    die_usage "usage: teamctl start <fable|astra|…> [--no-attach] [--continue] [--lead-permissions skip|ask] [--worker-permissions skip|lead|ask] [--worker-spawn on|off]   (models: $WOLFMUX_MODEL_KEYS)"
  require_metered_ok
  require_tools
  # start never guesses between teams: the one you name, else the first one.
  WOLFMUX_TEAM_ARG="${WOLFMUX_TEAM_ARG:-$WOLFMUX_DEFAULT_TEAM}"
  load_project
  founder="$(start_permitted)" || exit 77
  wt_require_commit
  ensure_state_dirs
  beads_ensure "$beads"
  lock_acquire
  if [ -n "$opt_lead" ]; then policy_set lead-permissions "$opt_lead"; fi
  if [ -n "$opt_worker" ]; then policy_set worker-permissions "$opt_worker"; fi
  if [ -n "$opt_spawn" ]; then policy_set worker-spawn "$opt_spawn"; fi

  SESSION="$(session_name_for_project)"
  if tm_session_exists "$SESSION"; then
    if [ "$(tm_pane_state "$(tm_pane_for_role "$SESSION" "$WOLFMUX_LEAD_ROLE")")" = "running" ]; then
      lock_release
      # Asking for another model is asking for another team, not for this one.
      if [ "$(reg_field "$WOLFMUX_LEAD_ROLE" model 2>/dev/null || true)" != "$model" ]; then
        info "team '$TEAM' is already running here, led by $(reg_field "$WOLFMUX_LEAD_ROLE" label 2>/dev/null || printf 'another model')."
        info "  open it:              teamctl attach$([ "$TEAM" = "$WOLFMUX_DEFAULT_TEAM" ] || printf ' --team %s' "$TEAM")"
        info "  a second team:        teamctl start $model --team <name>        e.g. --team $(printf '%s' "$model" | tr -c "${_WM_LOWER}${_WM_DIGITS}\n" '-' | cut -c1-24)"
        info "  all teams:            teamctl status"
        exit 1
      fi
      info "team '$TEAM' ($SESSION) is already running (lead: $(reg_field "$WOLFMUX_LEAD_ROLE" label 2>/dev/null || printf unknown))."
      if [ "$attach" -eq 1 ]; then cmd_attach; fi
      return 0
    fi
    if [ "$(tm_alive_count "$SESSION")" -gt 0 ]; then
      # Something is still running in that session (workers, or a shell of yours); only the
      # manager is gone. Bring it back where it was and leave the rest alone.
      info "the lead of '$SESSION' had exited; other panes are still running. Bringing the lead back."
      # The record is only rewritten when another model was asked for, and it is put back
      # if the restart fails: status must never describe a lead that does not exist.
      previous=""
      if [ "$(reg_field "$WOLFMUX_LEAD_ROLE" model 2>/dev/null || true)" != "$model" ]; then
        previous="$(reg_get "$WOLFMUX_LEAD_ROLE" 2>/dev/null || true)"
        previous_model="$(meta_get lead_model 2>/dev/null || true)"
        branch="$(gitr symbolic-ref --short -q HEAD || printf 'detached')"
        new_record "$WOLFMUX_LEAD_ROLE" lead "$model" "$ROOT" "$branch" "$branch" "$(gitr rev-parse HEAD)" 0 operator
        meta_put lead_model "$model"
      fi
      lock_release
      # In a subshell: a `die` in there ends only the attempt, not this command.
      if ! (if [ "$resume" -eq 1 ]; then cmd_restart "$WOLFMUX_LEAD_ROLE" --continue; else cmd_restart "$WOLFMUX_LEAD_ROLE"; fi); then
        if [ -n "$previous" ]; then
          printf '%s\n' "$previous" | reg_put "$WOLFMUX_LEAD_ROLE"
          meta_put lead_model "$previous_model"
        fi
        die "the lead could not be restarted; its record is as it was. Try: teamctl restart $WOLFMUX_LEAD_ROLE"
      fi
      tm_set_splash "$SESSION"
      if [ "$attach" -eq 1 ] && [ -t 0 ] && [ -t 1 ]; then cmd_attach; fi
      return 0
    fi
    # Every process has exited (tmux keeps the panes so their last output stays readable).
    # That is a finished session, not a team: clear it away and start a new one.
    info "the previous session '$SESSION' had ended (every agent had exited); starting a new one."
    tmx kill-session -t "=$SESSION" 2>/dev/null || true
    for role in $(reg_list); do
      if [ "$(reg_field "$role" kind)" = "worker" ]; then
        reg_set "$role" pane_id "" state stopped
        stopped="$stopped $role"
      fi
    done
    event_log cleanup "$WOLFMUX_LEAD_ROLE" "ended session replaced"
    tm_adopt_legacy_server # that may have been the last session of a server from before the rename
  fi

  branch="$(gitr symbolic-ref --short -q HEAD || printf 'detached')"
  new_record "$WOLFMUX_LEAD_ROLE" lead "$model" "$ROOT" "$branch" "$branch" "$(gitr rev-parse HEAD)" 0 "$founder"
  if [ -n "$handover" ]; then reg_set "$WOLFMUX_LEAD_ROLE" handover "$handover"; fi
  if [ "$resume" -eq 1 ]; then agent_command "$WOLFMUX_LEAD_ROLE" --continue; else agent_command "$WOLFMUX_LEAD_ROLE"; fi
  pane="$(tm_new_session "$SESSION" "$ROOT" "${AGENT_CMD[@]}")" || {
    reg_delete "$WOLFMUX_LEAD_ROLE"
    die "could not create tmux session '$SESSION'"
  }
  # A half-configured session would be invisible to every later command: roll back.
  if ! { tm_set_session_root "$SESSION" "$ROOT" && tm_set_session_team "$SESSION" "$TEAM" && tm_tag "$pane" "$WOLFMUX_LEAD_ROLE" "$MODEL_LABEL"; }; then
    tmx kill-session -t "=$SESSION" 2>/dev/null || true
    reg_delete "$WOLFMUX_LEAD_ROLE"
    die "could not configure tmux session '$SESSION'; it was rolled back"
  fi
  reg_set "$WOLFMUX_LEAD_ROLE" pane_id "$pane" state running
  meta_put root "$ROOT" session "$SESSION" lead_model "$model" team "$TEAM"
  event_log start "$WOLFMUX_LEAD_ROLE" "$model"
  lock_release
  tm_set_splash "$SESSION"
  layout_apply
  # A team that an agent founded is news for you.
  if [ "$founder" != "operator" ]; then
    (WOLFMUX_TEAM="$TEAM" notify_deliver "$WOLFMUX_LEAD_MARK $founder started team '$TEAM' ($MODEL_LABEL). Open it: teamctl attach --team $TEAM" >/dev/null 2>&1) || true
  fi

  brand_banner
  say "team:          $TEAM   (session $SESSION, tmux socket $WOLFMUX_TMUX_SOCKET)"
  say "lead:          $MODEL_LABEL via $MODEL_LAUNCHER in $(short_path "$ROOT")"
  say "policy:        $(policy_summary)   (teamctl policy)"
  if [ -n "$stopped" ]; then
    say "stopped:      $stopped   (worktrees and branches kept; bring one back with: teamctl restart <role> [--continue])"
  fi
  say "next:          teamctl spawn backend glm53 · teamctl status · teamctl attach"
  if [ "$attach" -eq 1 ] && [ -t 0 ] && [ -t 1 ]; then
    cmd_attach
  fi
}

# --- teamctl spawn <role> <model> -----------------------------------------------
cmd_spawn() {
  local role="" model="" base="HEAD" kickoff=1 stamp path branch base_commit base_ref target pane spawner
  if [ "${WOLFMUX_NO_KICKOFF:-}" = "1" ]; then kickoff=0; fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base)
        [ "$#" -ge 2 ] || die_usage "--base needs a git ref"
        base="$2"
        shift
        ;;
      --no-kickoff) kickoff=0 ;;
      -*) die_usage "unknown option for spawn: $1" ;;
      *) if [ -z "$role" ]; then role="$1"; elif [ -z "$model" ]; then model="$1"; else die_usage "unexpected argument: $1"; fi ;;
    esac
    shift
  done
  [ -n "$role" ] && [ -n "$model" ] || die_usage "usage: teamctl spawn <role> <model> [--base <ref>] [--no-kickoff]   (models: $WOLFMUX_MODEL_KEYS)"
  require_new_role_arg "$role"
  [ "$role" != "$WOLFMUX_LEAD_ROLE" ] || die_usage "'lead' is reserved; the lead is created by: teamctl start"
  model_info "$model" || die_usage "unknown model '$model' (known: $WOLFMUX_MODEL_KEYS)"
  require_metered_ok
  require_tools
  load_project
  ensure_state_dirs
  require_session
  spawner="$(caller_role)"
  if ! is_manager && [ "$(policy_get worker-spawn)" != "on" ]; then
    die "worker spawning is off, and you are '$spawner'. Only the lead spawns teammates. Ask it: bd create \"Need a helper: <for what>\" -t message -a lead -d \"<why, which model>\"" 77
  fi
  lock_acquire

  if reg_exists "$role"; then
    die "role '$role' already exists ($(agent_state "$role")). Use: teamctl restart $role — or choose another role name."
  fi
  wt_require_commit
  base_commit="$(gitr rev-parse --verify -q "$base^{commit}")" || die "cannot resolve base ref: $base"
  base_ref="$base"
  if [ "$base" = "HEAD" ]; then
    base_ref="$(gitr symbolic-ref --short -q HEAD || printf '%s' "$base_commit" | cut -c1-12)"
  fi

  stamp="$(now_stamp)"
  branch="$(wt_branch_name "$role" "$stamp")"
  path="$(wt_create "$role" "$stamp" "$base_commit")"
  new_record "$role" worker "$model" "$path" "$branch" "$base_ref" "$base_commit" "$kickoff" "${spawner:-operator}"

  target="$(tm_split_target "$SESSION")" || target=""
  pane=""
  if [ -n "$target" ]; then
    agent_command "$role"
    pane="$(tm_split "$target" "$path" "${AGENT_CMD[@]}" || true)"
  fi
  if [ -z "$pane" ]; then
    wt_discard_new "$path" "$branch"
    reg_delete "$role"
    die "could not create a tmux pane for '$role' (window too small? attach and enlarge the terminal, then retry)."
  fi
  tm_tag "$pane" "$role" "$MODEL_LABEL"
  reg_set "$role" pane_id "$pane" state running
  layout_apply
  event_log spawn "$role" "$model $branch by ${spawner:-operator}"
  lock_release
  # The manager always knows who is on the team, whoever did the spawning.
  if [ -n "$spawner" ] && [ "$spawner" != "$WOLFMUX_LEAD_ROLE" ]; then
    notify_lead spawn "$spawner" "$role" "$MODEL_LABEL" || true
  fi

  say "spawned:   $role  ($MODEL_LABEL via $MODEL_LAUNCHER)  permissions: $(reg_field "$role" permissions)"
  say "pane:      $pane"
  say "branch:    $branch  (base: $base_ref @ $(printf '%s' "$base_commit" | cut -c1-12))"
  say "worktree:  $(short_path "$path")"
}

# --- internal: the process that a pane runs -----------------------------------------
path_prepend() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) if [ -d "$1" ]; then PATH="$1:$PATH"; fi ;;
  esac
}

build_role_prompt() {
  local role="$1" kind workdir me lead
  kind="$(reg_field "$role" kind)"
  workdir="$(reg_field "$role" workdir)"
  me="$(team_identity "$TEAM" "$role")"
  lead="$(team_identity "$TEAM" "$WOLFMUX_LEAD_ROLE")"
  printf '# Wolfmux session context\n\n'
  printf 'You are an agent in a Wolfmux tmux session. These facts are yours:\n\n'
  printf -- '- TEAM_ROLE: %s   (kind: %s, model: %s)\n' "$role" "$(printf '%s' "$kind" | tr '[:lower:]' '[:upper:]')" "$(reg_field "$role" label)"
  printf -- '- Project root (the lead works here): %s\n' "$ROOT"
  if [ "$kind" = "worker" ]; then
    printf -- '- Your private worktree (work ONLY here): %s\n' "$workdir"
    printf -- '- Your branch: %s   (base: %s @ %s)\n' "$(reg_field "$role" branch)" "$(reg_field "$role" base_ref)" "$(reg_field "$role" base_commit | cut -c1-12)"
  fi
  printf -- '- Your team: %s\n' "$TEAM"
  printf -- '- Your Beads identity: BEADS_ACTOR=%s (already exported). Your inbox: bd list --assignee %s --status open,in_progress,blocked --include-infra\n' "$me" "$me"
  printf -- '- The manager of this team is the agent with TEAM_ROLE=lead; in Beads it is called "%s". Nobody else manages, approves or assigns.\n' "$lead"
  if [ "$TEAM" != "$WOLFMUX_DEFAULT_TEAM" ]; then
    printf -- '- This project has more than one team and they share one Beads database. Everyone in YOUR team is called "%s.<role>" there: assign and message with -a %s.<role> (your lead: -a %s). A plain "lead" is the lead of ANOTHER team, and the tasks of other teams are not yours.\n' "$TEAM" "$TEAM" "$lead"
  fi
  if [ "$kind" = "worker" ]; then
    printf -- '- You were spawned by: %s. You report to the lead regardless.\n' "$(reg_field "$role" spawned_by)"
    if [ "$(policy_get worker-isolation)" = "on" ]; then
      printf -- '- Worktree isolation is ON: a tool call that changes files outside your worktree, reads another teammate'"'"'s worktree, switches or deletes branches, or writes into the lead'"'"'s checkout is refused. That is by design; when something outside has to change, message the lead.\n'
    fi
    if [ "$(policy_get worker-spawn)" = "on" ]; then
      printf -- '- Worker spawning is ON: you may run `teamctl spawn <role> <glm53|flash>` when the work needs it; the lead is told automatically.\n'
    else
      printf -- '- Worker spawning is OFF: you cannot add teammates. If you need one, message the lead.\n'
    fi
  else
    printf -- '- Team policy: %s. Change it with `teamctl policy`.\n' "$(policy_summary)"
  fi
  printf -- '- Other teams of this project share this Beads database (list them: `teamctl teams`). Reach another team through its lead: -a <team>.lead (the first team'"'"'s lead is plain "lead"). Their tasks are theirs; hand work across with a message.\n'
  if [ "$kind" = "lead" ] && [ "$(policy_get lead-teams)" = "on" ]; then
    printf -- '- You may found a further team and hand work over to it: write the handover as a Beads message or task first, then `teamctl start <model> --team <new-name> --no-attach --handover <bead-id>`. The human is told. You do not manage that team afterwards; its lead does.\n'
  fi
  printf -- '- Your permission mode: %s\n\n' "$(reg_field "$role" permissions)"
  printf 'The %s section of the protocol below is binding for you.\n\n---\n\n' "$(printf '%s' "$kind" | tr '[:lower:]' '[:upper:]')"
  if [ -r "$WOLFMUX_HOME/TEAM_PROTOCOL.md" ] && [ "$TEAM" = "$WOLFMUX_DEFAULT_TEAM" ]; then
    /bin/cat "$WOLFMUX_HOME/TEAM_PROTOCOL.md"
  elif [ -r "$WOLFMUX_HOME/TEAM_PROTOCOL.md" ]; then
    # The protocol's examples address "lead" and plain roles; in a named team those are
    # <team>.lead and <team>.<role>. Rewrite the examples rather than hope it is remembered.
    sed -E -e "s/(-a|--assignee) (lead|backend|frontend|qa)([^${_WM_LOWER}${_WM_DIGITS}.-]|\$)/\\1 $TEAM.\\2\\3/g" \
      -e 's/--assignee \$TEAM_ROLE/--assignee $BEADS_ACTOR/g' "$WOLFMUX_HOME/TEAM_PROTOCOL.md"
  else
    printf 'Team protocol file is missing: %s/TEAM_PROTOCOL.md\n' "$WOLFMUX_HOME"
  fi
}

# kickoff_text <role> <beads-identity> — the inbox is addressed by identity (<team>.<role> in a
# named team, the plain role in the first one); teamctl takes the plain role and knows the team.
kickoff_text() {
  printf 'You are the %s worker of a Wolfmux session. Check your Beads inbox now: run `bd list --assignee %s --status open,in_progress,blocked --include-infra`, read every item with `bd show <id>`, then act as the team protocol in your system prompt says. If a task of yours is already in_progress, you were restarted in the middle of it: run `git status` and `teamctl diff %s --commits` to see what you already did, then continue it; do not start over. If nothing is assigned to you yet, answer with one line saying you are ready, and wait.' "$1" "${2:-$1}" "$1"
}

# handover_text — what the lead of a team founded by another lead is started with
handover_text() {
  local me bead founder
  me="$(team_identity "$TEAM" "$WOLFMUX_LEAD_ROLE")"
  bead="$(reg_field "$WOLFMUX_LEAD_ROLE" handover)"
  founder="$(reg_field "$WOLFMUX_LEAD_ROLE" spawned_by)"
  printf 'You are the lead of the new team "%s". %s founded this team to hand work over to you. Read the handover first: run `bd show %s`. Then check your inbox: `bd list --assignee %s --status open,in_progress,blocked --include-infra`. Staff your team with `teamctl spawn <role> <model>` as the work needs, and report back to %s through Beads (-a %s) when the handover asks for it.' \
    "$TEAM" "$founder" "$bead" "$me" "$founder" "$founder"
}

# cmd_prompt <role> — internal (`teamctl _prompt`): the session context an agent is started with
cmd_prompt() {
  require_role_arg "${1:-}"
  require_tools
  load_project
  reg_exists "$1" || die "no such agent: $1"
  build_role_prompt "$1"
}

# write_agent_settings <role> — Claude Code settings for one Claude-based agent; prints
# the file path. Workers never run Claude Code's own agent-teams feature: with it on,
# any subagent a session names becomes a teammate whose "team lead" — and permission
# approver — is that worker. The lead's file holds the notification hook and nothing
# about teams or permissions: those stay exactly as you have them.
write_agent_settings() {
  local role="$1" path="$STATE_DIR/settings/$1.json" kind notify_command="" guard_command=""
  /bin/mkdir -p "$STATE_DIR/settings"
  kind="$(reg_field "$role" kind)"
  if notify_wanted "$kind"; then notify_command="\"$TEAMCTL_SELF\" _notify"; fi
  if [ "$kind" = "worker" ] && [ "$(policy_get worker-isolation)" = "on" ]; then guard_command="\"$TEAMCTL_SELF\" _guard"; fi
  # Workers only: agent teams off, so a worker can never become a second manager.
  # Workers, unless the policy says otherwise: the worktree guard (lib/guard.sh).
  # Everyone: notifications are teamctl's job inside a team (lib/notify.sh).
  # Lead mode only: permission requests go to the lead.
  "$JQ_BIN" -n --arg kind "$kind" --arg mode "$(reg_field "$role" permissions)" \
    --arg permission_command "\"$TEAMCTL_SELF\" _permission-hook" --argjson timeout "$(($(approval_timeout) + 30))" \
    --arg notify_command "$notify_command" --arg silence "$(notify_silence_value)" --arg guard_command "$guard_command" '
    (if $kind == "worker" then {env: {CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "0"}, teammateMode: "in-process"} else {} end)
    * {env: {ECC_DISABLED_HOOKS: $silence}}
    * (if $notify_command != ""
       then {hooks: {Stop: [{hooks: [{type: "command", command: $notify_command, timeout: 10}]}]}} else {} end)
    * (if $guard_command != ""
       then {hooks: {PreToolUse: [{matcher: "Edit|Write|MultiEdit|NotebookEdit|Read|Grep|Glob|LS|Bash|mcp__.*",
                                   hooks: [{type: "command", command: $guard_command, timeout: 10}]}]}} else {} end)
    * (if $kind == "worker" and $mode == "lead"
       then {hooks: {PermissionRequest: [{hooks: [{type: "command", command: $permission_command, timeout: $timeout}]}]}}
       else {} end)' >"$path"
  printf '%s\n' "$path"
}

cmd_run_agent() {
  local root="${1:-}" role="${2:-}" resume=0 launcher family workdir prompt args permissions name model_id
  [ -n "$root" ] && [ -n "$role" ] || die_usage "internal use: _run-agent <root> <role> [--continue]"
  if [ "${3:-}" = "--continue" ]; then resume=1; fi
  export WOLFMUX_ROOT="$root"
  require_tools
  load_project
  reg_exists "$role" || die "no registry record for role '$role' in $(short_path "$ROOT")"
  launcher="$(reg_field "$role" launcher)"
  family="$(reg_field "$role" family)"
  workdir="$(reg_field "$role" workdir)"
  [ -x "$launcher" ] || die "launcher missing or not executable: $launcher"
  [ -d "$workdir" ] || die "working directory is gone: $workdir"

  WOLFMUX_TEAM="$TEAM"
  BEADS_ACTOR="$(team_identity "$TEAM" "$role")" # all teams of a project share its Beads
  export TEAM_ROLE="$role" BEADS_ACTOR WOLFMUX_TEAM
  if [ "$(reg_field "$role" kind)" = "worker" ]; then
    WOLFMUX_WORKTREE="$workdir" # what the worktree guard (lib/guard.sh) holds this agent to
    WOLFMUX_BRANCH="$(reg_field "$role" branch)"
    export WOLFMUX_WORKTREE WOLFMUX_BRANCH
  fi
  WOLFMUX_SESSION="$(meta_get session || true)"
  WOLFMUX_MODEL="$(reg_field "$role" model)"
  export WOLFMUX_SESSION WOLFMUX_MODEL
  path_prepend "$HOME/.local/bin"
  path_prepend "$WOLFMUX_BIN_DIR"
  export PATH
  cd "$workdir" || die "cannot enter $workdir"

  permissions="$(reg_field "$role" permissions)"
  model_id="$(reg_field "$role" model_id)" # only for claude:<id> / codex:<id>
  if [ "$family" != "codex" ]; then
    WOLFMUX_EXTRA_SETTINGS="$(write_agent_settings "$role")"
    export WOLFMUX_EXTRA_SETTINGS
  fi

  prompt="$(build_role_prompt "$role")"
  if [ "$role" = "$WOLFMUX_LEAD_ROLE" ]; then brand_wolf 2; fi # the manager's pane opens with the wolf
  printf '[wolfmux] role=%s  model=%s  launcher=%s  permissions=%s\n[wolfmux] cwd=%s\n' \
    "$role" "$(reg_field "$role" label)" "$(basename "$launcher")" "${permissions:-ask}" "$workdir"

  case "$family" in
    codex)
      # TOML multi-line literal string; it cannot contain three single quotes.
      case "$prompt" in *"'''"*) prompt="You are TEAM_ROLE=$role in a Wolfmux session. Read and follow $WOLFMUX_HOME/TEAM_PROTOCOL.md before anything else." ;; esac
      args=(-c "developer_instructions='''
$prompt
'''")
      if [ -n "$model_id" ]; then export WOLFMUX_ASTRA_MODEL="$model_id"; fi
      # Codex has no Stop hook; its `notify` program is the same thing under another name.
      if notify_wanted "$(reg_field "$role" kind)"; then
        args+=(-c "notify=[\"$TEAMCTL_SELF\",\"_notify\",\"--codex\"]")
      fi
      if [ "$permissions" = "skip" ]; then args+=(--dangerously-bypass-approvals-and-sandbox); fi
      if [ "$resume" -eq 1 ]; then
        args+=(resume --last)
      elif [ "$(reg_field "$role" kickoff)" = "1" ]; then
        args+=("$(kickoff_text "$role" "$BEADS_ACTOR")")
      fi
      ;;
    *)
      # The same marks as on the pane border, inside Claude Code's own frame: wolf = manager, dog = teammate.
      if [ "$role" = "$WOLFMUX_LEAD_ROLE" ]; then name="$WOLFMUX_LEAD_MARK team/$role"; else name="$WOLFMUX_WORKER_MARK team/$role"; fi
      args=(--append-system-prompt "$prompt" --name "$name")
      if [ -n "$model_id" ]; then args+=(--model "$model_id"); fi
      if [ "$permissions" = "skip" ]; then args+=(--dangerously-skip-permissions); fi
      if [ "$resume" -eq 1 ]; then
        args+=(--continue)
      elif [ "$(reg_field "$role" kickoff)" = "1" ]; then
        args+=("$(kickoff_text "$role" "$BEADS_ACTOR")")
      fi
      ;;
  esac
  # The lead of a team that another lead founded starts with its handover (both CLIs take
  # the first prompt as the last argument). Not on --continue: that conversation has it.
  if [ "$role" = "$WOLFMUX_LEAD_ROLE" ] && [ "$resume" -eq 0 ] && [ -n "$(reg_field "$role" handover)" ]; then
    args+=("$(handover_text)")
  fi
  exec "$launcher" "${args[@]}"
}

# A report shows the first lines of a list and says how many it left out. It never lets `head`
# close a pipe under git: git flushes into a pipe line by line, the next write gets SIGPIPE,
# and with pipefail and set -e the command died silently with exit 141 (issue #6).
# report_commits <branch> <indent> <count> — the newest ten commits HEAD does not have
report_commits() {
  gitr log -n 10 --format="$2%h %s" "HEAD..$1" || true
  if [ "$3" -gt 10 ]; then printf '%s… and %s more commits\n' "$2" "$(($3 - 10))"; fi
}
# report_files <worktree> <indent> <count> <shown> — the first <shown> changed files of a worktree
report_files() {
  local listing
  listing="$("$GIT_BIN" -C "$1" status --short 2>/dev/null || true)" # whole, in a variable: no pipe to close
  printf '%s\n' "$listing" | sed -n "1,$4p" | sed "s/^/$2/"
  if [ "$3" -gt "$4" ]; then printf '%s… and %s more files\n' "$2" "$(($3 - $4))"; fi
}

# --- teamctl stop / restart ------------------------------------------------------------
cmd_stop() {
  local role="${1:-}" pane
  require_role_arg "$role"
  require_tools
  load_project
  reg_exists "$role" || die "no such agent: $role  (see: teamctl status)"
  require_manager stop
  lock_acquire
  SESSION="$(session_name_for_project)"
  pane="$(tm_pane_for_role "$SESSION" "$role" 2>/dev/null || true)"
  if [ -n "$pane" ]; then
    tmx kill-pane -t "$pane" 2>/dev/null || true
    layout_apply
  fi
  reg_set "$role" pane_id "" state stopped
  event_log stop "$role"
  lock_release
  say "stopped: $role   (worktree, branch and commits are untouched; bring it back with: teamctl restart $role)"
}

# restart_without_session <role> <resume 0|1> — the tmux session is gone (it was ended, or the
# machine restarted) and the records remain. Restarting the lead is starting the team again, as
# the model that led it; a worker needs that session first, and is told the exact commands.
restart_without_session() {
  local role="$1" resume="$2" model team_flag="" continue_flag="" start_args
  model="$(reg_field "$WOLFMUX_LEAD_ROLE" model 2>/dev/null || true)"
  if [ "$TEAM" != "$WOLFMUX_DEFAULT_TEAM" ]; then team_flag=" --team $TEAM"; fi
  if [ "$resume" -eq 1 ]; then continue_flag=" --continue"; fi
  if [ "$role" != "$WOLFMUX_LEAD_ROLE" ]; then
    die "team '$TEAM' has no session (it was ended, or the machine restarted). Bring the lead back in its last conversation: teamctl start ${model:-<fable|astra>}$team_flag --continue   then: teamctl restart $role$team_flag$continue_flag"
  fi
  info "team '$TEAM' has no session (it was ended, or the machine restarted); starting it again."
  start_args=("$model")
  if [ "$resume" -eq 1 ]; then start_args+=(--continue); fi
  # A team that ran without Beads is not asked about Beads again.
  if ! beads_dir >/dev/null 2>&1; then start_args+=(--skip-beads); fi
  WOLFMUX_TEAM_ARG="$TEAM" # the team this restart resolved, also when it was not named
  cmd_start "${start_args[@]}"
}

cmd_restart() {
  local role="" resume=0 pane workdir target
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --continue) resume=1 ;;
      -*) die_usage "unknown option for restart: $1" ;;
      *) role="$1" ;;
    esac
    shift
  done
  require_role_arg "$role"
  require_tools
  load_project
  reg_exists "$role" || die "no such agent: $role  (see: teamctl status)"
  workdir="$(reg_field "$role" workdir)"
  [ -d "$workdir" ] || die "cannot restart '$role': its working directory is gone ($workdir)"
  SESSION="$(session_name_for_project)"
  if ! tm_session_exists "$SESSION"; then
    restart_without_session "$role" "$resume"
    return
  fi
  require_manager restart
  lock_acquire
  # A restart picks up the current policy.
  reg_set "$role" permissions "$(effective_permissions "$(reg_field "$role" kind)" "$(reg_field "$role" family)")"

  if [ "$resume" -eq 1 ]; then agent_command "$role" --continue; else agent_command "$role"; fi
  pane="$(tm_pane_for_role "$SESSION" "$role")"
  if [ -n "$pane" ]; then
    tm_respawn "$pane" "$workdir" "${AGENT_CMD[@]}" || die "respawn failed for pane $pane"
  else
    target="$(tm_split_target "$SESSION")" || die "no pane to split in session $SESSION"
    pane="$(tm_split "$target" "$workdir" "${AGENT_CMD[@]}")" || die "could not create a tmux pane for '$role'"
  fi
  tm_tag "$pane" "$role" "$(reg_field "$role" label)"
  reg_set "$role" pane_id "$pane" state running
  layout_apply
  if [ "$resume" -eq 1 ]; then
    event_log restart "$role" continue
    say "restarted: $role in pane $pane (continuing its previous conversation)"
  else
    event_log restart "$role" fresh
    say "restarted: $role in pane $pane"
  fi
  lock_release
}

# --- teamctl destroy [--worktrees] [--yes] --------------------------------------------------
# _inside_worktrees <path> — really inside this project's worktree directory (symlinks resolved)
_inside_worktrees() {
  local real base
  real="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  base="$(cd "$WORKTREES_DIR" 2>/dev/null && pwd -P)" || return 1
  case "$real/" in "$base"/?*/) return 0 ;; esac
  return 1
}

# cmd_remove <role>... [--force] [--yes] — take a stopped worker off the books: worktree,
# branch and record. Work is never discarded silently: without --force a worker with
# uncommitted files or commits that are not in your current branch is refused, and the
# refusal lists them. With --force the same list is shown and one question is asked.
cmd_remove() {
  local force=0 assume_yes=0 roles="" role path branch dirty unmerged pane holding=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) force=1 ;;
      --yes | -y) assume_yes=1 ;;
      -*) die_usage "unknown option for remove: $1" ;;
      *)
        require_role_arg "$1"
        roles="$roles $1"
        ;;
    esac
    shift
  done
  [ -n "$roles" ] || die_usage "usage: teamctl remove <role>... [--force] [--yes]"
  require_tools
  load_project
  require_manager remove
  SESSION="$(session_name_for_project)"
  for role in $roles; do
    reg_exists "$role" || die "no such agent: $role  (see: teamctl status)"
    [ "$(reg_field "$role" kind)" = "worker" ] || die "'$role' is the lead; end the team with: teamctl destroy"
    pane="$(tm_pane_for_role "$SESSION" "$role" 2>/dev/null || true)"
    [ "$(tm_pane_state "$pane")" != "running" ] || die "'$role' is running; stop it first: teamctl stop $role"
  done

  lock_acquire
  # All or nothing: nobody is removed when one of them cannot be.
  if [ "$force" -ne 1 ]; then
    for role in $roles; do
      path="$(reg_field "$role" workdir)"
      branch="$(reg_field "$role" branch)"
      unmerged=0
      if wt_branch_exists "$branch"; then unmerged="$(gitr rev-list --count "HEAD..$branch" 2>/dev/null || printf 0)"; fi
      if [ "$(wt_dirty_count "$path")" != "0" ] || [ "$unmerged" != "0" ]; then holding="$holding $role"; fi
    done
  fi
  for role in $roles; do
    path="$(reg_field "$role" workdir)"
    branch="$(reg_field "$role" branch)"
    dirty="$(wt_dirty_count "$path")"
    unmerged=0
    if wt_branch_exists "$branch"; then unmerged="$(gitr rev-list --count "HEAD..$branch" 2>/dev/null || printf 0)"; fi
    if [ -n "$holding" ] && [ "$dirty" = "0" ] && [ "$unmerged" = "0" ]; then continue; fi # reported below, removed never
    if [ "$dirty" != "0" ] || [ "$unmerged" != "0" ]; then
      say "$role still holds work that is nowhere else:"
      if [ "$unmerged" != "0" ]; then
        say "  $unmerged commit$([ "$unmerged" = "1" ] || printf s) on $branch that your current branch does not have:"
        report_commits "$branch" '    ' "$unmerged"
      fi
      if [ "$dirty" != "0" ]; then
        say "  $dirty uncommitted file$([ "$dirty" = "1" ] || printf s) in $(short_path "$path"):"
        report_files "$path" '    ' "$dirty" 10
      fi
      if [ "$force" -ne 1 ]; then
        say "  keep it:    commit in that worktree, then: git merge $branch"
        say "  discard it: teamctl remove $role --force"
        continue
      fi
      if [ "$assume_yes" -ne 1 ]; then
        confirm "Discard all of that and remove '$role'?" || { lock_release; die "aborted; nothing was removed (pass --yes to skip this question)"; }
      fi
    fi
    # A record is a file anyone can edit. Whatever it says, only a directory inside this
    # project's worktrees is ever deleted, and only an ai/* branch that is not checked out
    # in your own checkout.
    if [ -d "$path" ]; then
      if _inside_worktrees "$path"; then
        gitr worktree remove --force "$path" >/dev/null 2>&1 || /bin/rm -rf "$path"
      else
        warn "$role: its record points outside $(short_path "$WORKTREES_DIR") ($(short_path "$path")); that directory was left alone"
      fi
    fi
    gitr worktree prune
    # -D only here: the refusal above, or your yes, is what makes discarding it deliberate.
    case "$branch" in
      ai/*)
        if wt_branch_exists "$branch" && [ "$branch" != "$(gitr symbolic-ref --short -q HEAD || true)" ]; then
          gitr branch -D "$branch" >/dev/null 2>&1 || warn "could not delete branch $branch"
        fi
        ;;
      *) [ -z "$branch" ] || warn "$role: branch '$branch' is not an ai/* branch; left alone" ;;
    esac
    pane="$(tm_pane_for_role "$SESSION" "$role" 2>/dev/null || true)"
    if [ -n "$pane" ]; then tmx kill-pane -t "$pane" 2>/dev/null || true; fi
    /bin/rm -f "$STATE_DIR/settings/$role.json"
    reg_delete "$role"
    event_log remove "$role" "force=$force dirty=$dirty unmerged=$unmerged"
    say "removed: $role  (worktree, branch $branch and record)"
  done
  layout_apply
  lock_release
  [ -z "$holding" ] || die "nothing was removed:$holding still hold$([ "$(printf '%s' "$holding" | wc -w | tr -d ' ')" = "1" ] && printf s) work."
}

_destroy_worker_artifacts() {
  local role="$1" path branch result
  path="$(reg_field "$role" workdir)"
  branch="$(reg_field "$role" branch)"
  result=0
  wt_remove_if_clean "$path" || result=$?
  case "$result" in
    0) say "  $role: removed clean worktree $(short_path "$path")" ;;
    1)
      say "  $role: KEPT worktree (uncommitted work or in use): $(short_path "$path")"
      say "      keep its work: commit there, then merge $branch · discard it: teamctl remove $role --force"
      return 0
      ;;
    *) : ;;
  esac
  if ! wt_branch_exists "$branch"; then
    reg_delete "$role"
  elif wt_delete_branch_if_merged "$branch"; then
    say "  $role: deleted fully merged branch $branch"
    reg_delete "$role"
  else
    say "  $role: KEPT branch $branch (has unmerged commits; review with: teamctl diff $role)"
    say "      keep its work: git merge $branch · discard it: teamctl remove $role --force"
  fi
}

# human_size <kilobytes>
human_size() {
  awk -v kb="${1:-0}" 'BEGIN { if (kb >= 1048576) printf "%.1f GB\n", kb / 1048576; else if (kb >= 1024) printf "%.0f MB\n", kb / 1024; else printf "%d KB\n", kb }'
}

# disk_kb <path>... — kilobytes on disk, 0 for what is not there
disk_kb() {
  local total=0 path size
  for path in "$@"; do
    [ -e "$path" ] || continue
    size="$(du -sk "$path" 2>/dev/null | awk '{ print $1 }')"
    total=$((total + ${size:-0}))
  done
  printf '%s\n' "$total"
}

# transcripts_dir <worktree> — where Claude Code keeps the conversations of an agent that ran
# there: a folder named after the path, every other character turned into "-"
transcripts_dir() {
  local base="${WOLFMUX_CLAUDE_PROJECTS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}" real
  real="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$base" "$(printf '%s' "$real" | LC_ALL=C sed 's|[^A-Za-z0-9]|-|g')"
}

# _purge_report — what deleting this team means, worker by worker. Sets PURGE_AT_RISK (roles
# that hold work which exists nowhere else) and PURGE_KB.
_purge_report() {
  local role path branch dirty unmerged kb notes tdir alive
  PURGE_AT_RISK=""
  PURGE_KB=0
  alive=0
  if tm_session_exists "$SESSION"; then alive="$(tm_alive_count "$SESSION")"; fi
  say "team '$TEAM' of $(short_path "$ROOT")   ·   session $SESSION ($alive running)"
  say ""
  for role in $(reg_list); do
    [ "$(reg_field "$role" kind)" = "worker" ] || continue
    path="$(reg_field "$role" workdir)"
    branch="$(reg_field "$role" branch)"
    dirty="$(wt_dirty_count "$path")"
    unmerged=0
    if wt_branch_exists "$branch"; then unmerged="$(gitr rev-list --count "HEAD..$branch" 2>/dev/null || printf 0)"; fi
    kb="$(disk_kb "$path")"
    tdir="$(transcripts_dir "$path" 2>/dev/null || true)"
    if [ "$PURGE_TRANSCRIPTS" -eq 1 ] && [ -n "$tdir" ]; then kb=$((kb + $(disk_kb "$tdir"))); fi
    PURGE_KB=$((PURGE_KB + kb))
    notes="nothing to lose"
    if [ "$dirty" != "0" ] || [ "$unmerged" != "0" ]; then
      PURGE_AT_RISK="$PURGE_AT_RISK $role"
      notes="HOLDS WORK THAT EXISTS NOWHERE ELSE"
    fi
    printf '  %s %-18s %9s   %s\n' "$WOLFMUX_WORKER_MARK" "$role" "$(human_size "$kb")" "$notes"
    printf '        %s   (branch %s)\n' "$(short_path "$path")" "$branch"
    if [ "$unmerged" != "0" ]; then
      printf '        %s commit%s that your current branch does not have:\n' "$unmerged" "$([ "$unmerged" = "1" ] || printf s)"
      report_commits "$branch" '          ' "$unmerged"
    fi
    if [ "$dirty" != "0" ]; then
      printf '        %s uncommitted file%s:\n' "$dirty" "$([ "$dirty" = "1" ] || printf s)"
      report_files "$path" '          ' "$dirty" 15
    fi
  done
  kb="$(disk_kb "$STATE_DIR/agents" "$STATE_DIR/approvals" "$STATE_DIR/settings" "$STATE_DIR/nudge" "$STATE_DIR/events.jsonl" "$STATE_DIR/meta.json")"
  PURGE_KB=$((PURGE_KB + kb))
  printf '  %-21s %9s   records, approvals, event log\n' "teamctl's state" "$(human_size "$kb")"
  say ""
  printf '  %-21s %9s   is what this frees%s\n' "total" "$(human_size "$PURGE_KB")" "$([ "$PURGE_TRANSCRIPTS" -eq 1 ] && printf ' (worktrees, and the agents'"'"' Claude Code transcripts)' || printf ' (transcripts are kept)')"
  say "  Not touched: your checkout and its branch, every branch that is not ai/…, Beads, other teams."
}

# _purge_team — the deleting itself. Every path comes from a record, so every path is checked.
_purge_team() {
  local role path branch tdir
  if tm_session_exists "$SESSION"; then
    tmx kill-session -t "=$SESSION" 2>/dev/null || true
    say "tmux session $SESSION terminated."
  fi
  for role in $(reg_list); do
    if [ "$(reg_field "$role" kind)" = "worker" ]; then
      path="$(reg_field "$role" workdir)"
      branch="$(reg_field "$role" branch)"
      if [ -d "$path" ]; then
        if _inside_worktrees "$path"; then
          tdir="$(transcripts_dir "$path" 2>/dev/null || true)"
          gitr worktree remove --force "$path" >/dev/null 2>&1 || /bin/rm -rf "$path"
          if [ "$PURGE_TRANSCRIPTS" -eq 1 ] && [ -n "$tdir" ] && [ -d "$tdir" ]; then /bin/rm -rf "$tdir"; fi
        else
          warn "$role: its record points outside $(short_path "$WORKTREES_DIR") ($(short_path "$path")); that directory was left alone"
        fi
      fi
      case "$branch" in
        ai/*)
          if wt_branch_exists "$branch" && [ "$branch" != "$(gitr symbolic-ref --short -q HEAD || true)" ]; then
            gitr branch -D "$branch" >/dev/null 2>&1 || warn "could not delete branch $branch"
          fi
          ;;
      esac
    fi
    reg_delete "$role"
  done
  gitr worktree prune
  # The first team's directory is also the parent of the named teams: take its files, never teams/.
  /bin/rm -rf "$STATE_DIR/agents" "$STATE_DIR/approvals" "$STATE_DIR/settings" "$STATE_DIR/nudge"
  /bin/rm -f "$STATE_DIR/events.jsonl" "$STATE_DIR/meta.json"
  /bin/rmdir "$WORKTREES_DIR" 2>/dev/null || true
}

cmd_destroy() {
  local remove_worktrees=0 assume_yes=0 purge=0 force=0 role
  PURGE_TRANSCRIPTS=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --worktrees) remove_worktrees=1 ;;
      --purge) purge=1 ;;
      --force) force=1 ;;
      --keep-transcripts) PURGE_TRANSCRIPTS=0 ;;
      --yes | -y) assume_yes=1 ;;
      *) die_usage "usage: teamctl destroy [--worktrees | --purge [--force] [--keep-transcripts]] [--yes]" ;;
    esac
    shift
  done
  [ "$force" -eq 0 ] || [ "$purge" -eq 1 ] || die_usage "--force belongs to --purge (destroy alone never discards work)"
  require_tools
  load_project
  require_manager destroy
  SESSION="$(session_name_for_project)"
  if [ "$purge" -eq 1 ]; then
    # Look first, ask, and only then touch anything: a refusal leaves the team running.
    say "DELETE a whole team: its session, every worker's worktree and ai/ branch, its records."
    _purge_report
    if [ -n "$PURGE_AT_RISK" ] && [ "$force" -ne 1 ]; then
      say ""
      say "Keep that work first: commit in the worktree, then git merge <branch>.  Or delete it anyway: add --force"
      confirm "Delete team '$TEAM' INCLUDING the uncommitted and unmerged work of:$PURGE_AT_RISK ?" ||
        die "nothing was deleted; team '$TEAM' is untouched."
    elif [ "$force" -ne 1 ] && [ "$assume_yes" -ne 1 ]; then
      confirm "Delete team '$TEAM'?" || die "nothing was deleted (pass --yes to skip this question)"
    fi
    ensure_state_dirs
    lock_acquire
    _purge_team
    lock_release
    if [ "$TEAM" != "$WOLFMUX_DEFAULT_TEAM" ]; then /bin/rmdir "$STATE_DIR" 2>/dev/null || true; fi # only when empty
    say "team '$TEAM' is gone. Freed about $(human_size "$PURGE_KB")."
    say "(commits of the deleted ai/ branches leave .git when git next collects garbage; now: git gc --prune=now)"
    return 0
  fi
  say "About to stop every agent of this project's team ($SESSION)."
  say "Kept in all cases: your source files, every commit, unmerged branches, credentials, Beads data."
  if [ "$remove_worktrees" -eq 1 ]; then
    say "--worktrees: clean worker worktrees are removed; fully merged ai/* branches are deleted."
  fi
  if [ "$assume_yes" -ne 1 ]; then
    confirm "Continue?" || die "aborted (pass --yes to skip this question)"
  fi
  ensure_state_dirs
  lock_acquire
  if tm_session_exists "$SESSION"; then
    tmx kill-session -t "=$SESSION"
    say "tmux session $SESSION terminated."
  else
    say "no running tmux session for this project."
  fi
  for role in $(reg_list); do
    reg_set "$role" pane_id "" state stopped
  done
  if [ "$remove_worktrees" -eq 1 ]; then
    for role in $(reg_list); do
      if [ "$(reg_field "$role" kind)" = "worker" ]; then _destroy_worker_artifacts "$role"; fi
    done
    gitr worktree prune
  else
    say "worktrees kept. Clean ones go with: teamctl destroy --worktrees · one that still holds work: teamctl remove <role> --force"
  fi
  reg_delete "$WOLFMUX_LEAD_ROLE"
  event_log destroy "" "worktrees=$remove_worktrees"
  lock_release
}

# notify_lead <spawn|approval|policy> <args...> — a fixed one-line notice in the lead's
# pane. Every interpolated value is a validated role, a model label from the model
# table, an approval id or a policy word; nothing free-form is ever typed.
notify_lead() {
  local kind="$1" pane text tries=0
  pane="$(tm_pane_for_role "$SESSION" "$WOLFMUX_LEAD_ROLE")"
  [ -n "$pane" ] && [ "$(tm_pane_state "$pane")" = "running" ] || return 1
  case "$kind" in
    spawn)
      known_role_name "$2" && known_role_name "$3" || return 1
      text="[wolfmux] Team change: $2 spawned teammate $3 ($4). Run: teamctl status"
      ;;
    approval)
      valid_approval_id "$2" && known_role_name "$3" || return 1
      text="[wolfmux] Permission request $2 from $3. Run: teamctl approvals"
      ;;
    policy)
      policy_valid "$2" "$3" || return 1
      text="[wolfmux] Policy changed: $2 = $3. Run: teamctl policy"
      ;;
    *) return 1 ;;
  esac
  # Serialize with other notices for the lead so two lines never interleave.
  until nudge_begin "$WOLFMUX_LEAD_ROLE"; do
    tries=$((tries + 1))
    [ "$tries" -lt 30 ] || break
    sleep 0.2
  done
  tm_type_line "$pane" "$text"
  nudge_mark "$WOLFMUX_LEAD_ROLE"
  nudge_end "$WOLFMUX_LEAD_ROLE"
}

# --- teamctl nudge <role>|--all [--id <bead>] [--quiet] ------------------------------------------
# The ONLY thing ever typed into an agent's prompt: one short, fixed line. Task and
# message bodies stay in Beads, so there is nothing to quote, escape or truncate.
_nudge_one() {
  local role="$1" bead="$2" pane text who
  # never yourself: the same role in the same team
  if [ "$role" = "${TEAM_ROLE:-}" ] && [ "$TEAM" = "${WOLFMUX_TEAM:-$WOLFMUX_DEFAULT_TEAM}" ]; then return 0; fi
  who="$(team_identity "$TEAM" "$role")"
  pane="$(tm_pane_for_role "$SESSION" "$role")"
  [ -n "$pane" ] && [ "$(tm_pane_state "$pane")" = "running" ] || return 1
  nudge_begin "$role" || return 2
  # Notified moments ago: one notice covers a burst of bead events, because the
  # notice always ends with the full inbox command.
  if [ $(($(now_epoch) - $(nudge_last "$role"))) -lt "$WOLFMUX_NUDGE_DEBOUNCE" ]; then
    nudge_end "$role"
    return 2
  fi
  if [ -n "$bead" ]; then
    text="[wolfmux] Beads update for $who ($bead). Run: bd show $bead -- then: bd list --assignee $who --status open,in_progress,blocked --include-infra"
  else
    text="[wolfmux] Beads update for $who. Run: bd list --assignee $who --status open,in_progress,blocked --include-infra"
  fi
  nudge_mark "$role"
  tm_type_line "$pane" "$text"
  event_log nudge "$role" "$bead"
  nudge_end "$role"
}

cmd_nudge() {
  local role="" bead="" quiet=0 all=0 target failed=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --quiet | -q) quiet=1 ;;
      --all) all=1 ;;
      --id)
        [ "$#" -ge 2 ] || die_usage "--id needs a bead id"
        bead="$2"
        shift
        ;;
      -*) die_usage "unknown option for nudge: $1" ;;
      *) role="$1" ;;
    esac
    shift
  done
  # A Beads name says which team: "review.backend" is backend of team review.
  case "$role" in
    *.*)
      identity_split "$role"
      if ! valid_team_name "$ID_TEAM"; then
        if [ "$quiet" -eq 1 ]; then return 0; fi
        die_usage "invalid team in '$role'"
      fi
      WOLFMUX_TEAM_ARG="$ID_TEAM"
      role="$ID_ROLE"
      ;;
  esac
  # Called from Beads hooks for every assignee, including humans and roles that
  # are not running: in quiet mode "nothing to notify" is success, not an error.
  if [ "$quiet" -eq 1 ]; then
    [ -n "$TMUX_BIN" ] && [ -n "$JQ_BIN" ] && [ -n "$GIT_BIN" ] || return 0
    ROOT="$(resolve_root 2>/dev/null)" || return 0
    PROJECT_KEY="$(project_key "$ROOT")"
    PROJECT_STATE="$WOLFMUX_DATA/state/$PROJECT_KEY"
    PROJECT_TREES="$WOLFMUX_DATA/worktrees/$PROJECT_KEY"
    # The assignee's name decides the team; a plain name belongs to the first team.
    team_paths "${WOLFMUX_TEAM_ARG:-$WOLFMUX_DEFAULT_TEAM}"
    [ -d "$STATE_DIR" ] || return 0
    SESSION="$(session_name_for_project)"
    tm_session_exists "$SESSION" || return 0
  else
    require_tools
    load_project
    require_session
  fi
  [ -z "$bead" ] || valid_bead_id "$bead" || bead=""
  if [ "$all" -eq 1 ]; then
    for target in $(reg_list); do _nudge_one "$target" "$bead" || true; done
    return 0
  fi
  if [ "$quiet" -eq 1 ]; then
    known_role_name "$role" || return 0
    reg_exists "$role" || return 0
  else
    require_role_arg "$role"
    reg_exists "$role" || die "no such agent: $role"
  fi
  _nudge_one "$role" "$bead" || failed=$?
  if [ "$quiet" -eq 1 ]; then return 0; fi
  case "$failed" in
    0) say "notified: $role" ;;
    2) say "skipped: $role was notified moments ago (debounce ${WOLFMUX_NUDGE_DEBOUNCE}s)" ;;
    *) die "'$role' has no running pane (its beads are waiting in Beads; start it with: teamctl restart $role)" ;;
  esac
}
