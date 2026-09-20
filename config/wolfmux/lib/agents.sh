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
  printf '%s\n' "$candidate"
}

require_session() {
  SESSION="$(session_name_for_project)"
  tm_session_exists "$SESSION" || die "no team session for this project. Start one: teamctl start <fable|astra>"
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
    --arg spawned_by "${9:-operator}" --arg permissions "$permissions" \
    '{role: $role, kind: $kind, model: $model, label: $label, family: $family, launcher: $launcher,
      workdir: $workdir, branch: $branch, base_ref: $base_ref, base_commit: $base_commit,
      kickoff: $kickoff, spawned_by: $spawned_by, permissions: $permissions,
      pane_id: "", state: "starting", created_at: $now, updated_at: $now}' |
    reg_put "$1"
}

# --- teamctl start <fable|astra> ------------------------------------------------
cmd_start() {
  local model="" attach=1 beads="ask" pane branch opt_lead="" opt_worker="" opt_spawn="" resume=0 role run stopped="" previous previous_model=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-attach | -d) attach=0 ;;
      --continue) resume=1 ;;
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
  case "$model" in
    fable | astra) ;;
    *) die_usage "usage: teamctl start <fable|astra> [--no-attach] [--continue] [--lead-permissions skip|ask] [--worker-permissions skip|lead|ask] [--worker-spawn on|off]" ;;
  esac
  require_tools
  load_project
  require_manager start
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
      info "team session '$SESSION' is already running (lead: $(reg_field "$WOLFMUX_LEAD_ROLE" label 2>/dev/null || printf unknown))."
      lock_release
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
  new_record "$WOLFMUX_LEAD_ROLE" lead "$model" "$ROOT" "$branch" "$branch" "$(gitr rev-parse HEAD)" 0 operator
  run=("$TEAMCTL_SELF" _run-agent "$ROOT" "$WOLFMUX_LEAD_ROLE")
  if [ "$resume" -eq 1 ]; then run+=(--continue); fi
  pane="$(tm_new_session "$SESSION" "$ROOT" "${run[@]}")" || {
    reg_delete "$WOLFMUX_LEAD_ROLE"
    die "could not create tmux session '$SESSION'"
  }
  # A half-configured session would be invisible to every later command: roll back.
  if ! { tm_set_session_root "$SESSION" "$ROOT" && tm_tag "$pane" "$WOLFMUX_LEAD_ROLE" "$MODEL_LABEL"; }; then
    tmx kill-session -t "=$SESSION" 2>/dev/null || true
    reg_delete "$WOLFMUX_LEAD_ROLE"
    die "could not configure tmux session '$SESSION'; it was rolled back"
  fi
  reg_set "$WOLFMUX_LEAD_ROLE" pane_id "$pane" state running
  meta_put root "$ROOT" session "$SESSION" lead_model "$model"
  event_log start "$WOLFMUX_LEAD_ROLE" "$model"
  lock_release
  tm_set_splash "$SESSION"
  layout_apply

  brand_banner
  say "team session:  $SESSION   (tmux socket: $WOLFMUX_TMUX_SOCKET)"
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
  [ -n "$role" ] && [ -n "$model" ] || die_usage "usage: teamctl spawn <role> <glm53|flash|fable|astra> [--base <ref>] [--no-kickoff]"
  require_role_arg "$role"
  [ "$role" != "$WOLFMUX_LEAD_ROLE" ] || die_usage "'lead' is reserved; the lead is created by: teamctl start"
  model_info "$model" || die_usage "unknown model '$model' (known: $WOLFMUX_MODEL_KEYS)"
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
  branch="ai/$role-$stamp"
  path="$(wt_create "$role" "$stamp" "$base_commit")"
  new_record "$role" worker "$model" "$path" "$branch" "$base_ref" "$base_commit" "$kickoff" "${spawner:-operator}"

  target="$(tm_split_target "$SESSION")" || target=""
  pane=""
  if [ -n "$target" ]; then
    pane="$(tm_split "$target" "$path" "$TEAMCTL_SELF" _run-agent "$ROOT" "$role" || true)"
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
  local role="$1" kind workdir
  kind="$(reg_field "$role" kind)"
  workdir="$(reg_field "$role" workdir)"
  printf '# Wolfmux session context\n\n'
  printf 'You are an agent in a Wolfmux tmux session. These facts are yours:\n\n'
  printf -- '- TEAM_ROLE: %s   (kind: %s, model: %s)\n' "$role" "$(printf '%s' "$kind" | tr '[:lower:]' '[:upper:]')" "$(reg_field "$role" label)"
  printf -- '- Project root (the lead works here): %s\n' "$ROOT"
  if [ "$kind" = "worker" ]; then
    printf -- '- Your private worktree (work ONLY here): %s\n' "$workdir"
    printf -- '- Your branch: %s   (base: %s @ %s)\n' "$(reg_field "$role" branch)" "$(reg_field "$role" base_ref)" "$(reg_field "$role" base_commit | cut -c1-12)"
  fi
  printf -- '- Your Beads identity: BEADS_ACTOR=%s (already exported)\n' "$role"
  printf -- '- The manager of this team is the agent with TEAM_ROLE=lead. Nobody else manages, approves or assigns.\n'
  if [ "$kind" = "worker" ]; then
    printf -- '- You were spawned by: %s. You report to the lead regardless.\n' "$(reg_field "$role" spawned_by)"
    if [ "$(policy_get worker-spawn)" = "on" ]; then
      printf -- '- Worker spawning is ON: you may run `teamctl spawn <role> <glm53|flash>` when the work needs it; the lead is told automatically.\n'
    else
      printf -- '- Worker spawning is OFF: you cannot add teammates. If you need one, message the lead.\n'
    fi
  else
    printf -- '- Team policy: %s. Change it with `teamctl policy`.\n' "$(policy_summary)"
  fi
  printf -- '- Your permission mode: %s\n\n' "$(reg_field "$role" permissions)"
  printf 'The %s section of the protocol below is binding for you.\n\n---\n\n' "$(printf '%s' "$kind" | tr '[:lower:]' '[:upper:]')"
  if [ -r "$WOLFMUX_HOME/TEAM_PROTOCOL.md" ]; then
    /bin/cat "$WOLFMUX_HOME/TEAM_PROTOCOL.md"
  else
    printf 'Team protocol file is missing: %s/TEAM_PROTOCOL.md\n' "$WOLFMUX_HOME"
  fi
}

kickoff_text() {
  printf 'You are the %s worker of a Wolfmux session. Check your Beads inbox now: run `bd list --assignee %s --status open --include-infra`, read every item with `bd show <id>`, then act as the team protocol in your system prompt says. If nothing is assigned to you yet, answer with one line saying you are ready, and wait.' "$1" "$1"
}

# write_agent_settings <role> — Claude Code settings for one Claude-based agent; prints
# the file path. Workers never run Claude Code's own agent-teams feature: with it on,
# any subagent a session names becomes a teammate whose "team lead" — and permission
# approver — is that worker. The lead's file holds the notification hook and nothing
# about teams or permissions: those stay exactly as you have them.
write_agent_settings() {
  local role="$1" path="$STATE_DIR/settings/$1.json" kind notify_command=""
  /bin/mkdir -p "$STATE_DIR/settings"
  kind="$(reg_field "$role" kind)"
  if notify_wanted "$kind"; then notify_command="\"$TEAMCTL_SELF\" _notify"; fi
  # Workers only: agent teams off, so a worker can never become a second manager.
  # Everyone: notifications are teamctl's job inside a team (lib/notify.sh).
  # Lead mode only: permission requests go to the lead.
  "$JQ_BIN" -n --arg kind "$kind" --arg mode "$(reg_field "$role" permissions)" \
    --arg permission_command "\"$TEAMCTL_SELF\" _permission-hook" --argjson timeout "$((APPROVAL_TIMEOUT + 30))" \
    --arg notify_command "$notify_command" --arg silence "$(notify_silence_value)" '
    (if $kind == "worker" then {env: {CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "0"}, teammateMode: "in-process"} else {} end)
    * {env: {ECC_DISABLED_HOOKS: $silence}}
    * (if $notify_command != ""
       then {hooks: {Stop: [{hooks: [{type: "command", command: $notify_command, timeout: 10}]}]}} else {} end)
    * (if $kind == "worker" and $mode == "lead"
       then {hooks: {PermissionRequest: [{hooks: [{type: "command", command: $permission_command, timeout: $timeout}]}]}}
       else {} end)' >"$path"
  printf '%s\n' "$path"
}

cmd_run_agent() {
  local root="${1:-}" role="${2:-}" resume=0 launcher family workdir prompt args permissions name
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

  export TEAM_ROLE="$role" BEADS_ACTOR="$role"
  WOLFMUX_SESSION="$(meta_get session || true)"
  WOLFMUX_MODEL="$(reg_field "$role" model)"
  export WOLFMUX_SESSION WOLFMUX_MODEL
  path_prepend "$HOME/.local/bin"
  path_prepend "$WOLFMUX_BIN_DIR"
  export PATH
  cd "$workdir" || die "cannot enter $workdir"

  permissions="$(reg_field "$role" permissions)"
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
      if [ "$permissions" = "skip" ]; then args+=(--dangerously-bypass-approvals-and-sandbox); fi
      if [ "$resume" -eq 1 ]; then
        args+=(resume --last)
      elif [ "$(reg_field "$role" kickoff)" = "1" ]; then
        args+=("$(kickoff_text "$role")")
      fi
      ;;
    *)
      # The same marks as on the pane border, inside Claude Code's own frame: wolf = manager, dog = teammate.
      if [ "$role" = "$WOLFMUX_LEAD_ROLE" ]; then name="$WOLFMUX_LEAD_MARK team/$role"; else name="$WOLFMUX_WORKER_MARK team/$role"; fi
      args=(--append-system-prompt "$prompt" --name "$name")
      if [ "$permissions" = "skip" ]; then args+=(--dangerously-skip-permissions); fi
      if [ "$resume" -eq 1 ]; then
        args+=(--continue)
      elif [ "$(reg_field "$role" kickoff)" = "1" ]; then
        args+=("$(kickoff_text "$role")")
      fi
      ;;
  esac
  exec "$launcher" "${args[@]}"
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

cmd_restart() {
  local role="" resume=0 pane workdir target cmd
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
  tm_session_exists "$SESSION" || die "no team session. Start one first: teamctl start $(reg_field "$WOLFMUX_LEAD_ROLE" model 2>/dev/null || printf '<fable|astra>')"
  require_manager restart
  lock_acquire
  # A restart picks up the current policy.
  reg_set "$role" permissions "$(effective_permissions "$(reg_field "$role" kind)" "$(reg_field "$role" family)")"

  cmd=("$TEAMCTL_SELF" _run-agent "$ROOT" "$role")
  if [ "$resume" -eq 1 ]; then cmd+=(--continue); fi
  pane="$(tm_pane_for_role "$SESSION" "$role")"
  if [ -n "$pane" ]; then
    tm_respawn "$pane" "$workdir" "${cmd[@]}" || die "respawn failed for pane $pane"
  else
    target="$(tm_split_target "$SESSION")" || die "no pane to split in session $SESSION"
    pane="$(tm_split "$target" "$workdir" "${cmd[@]}")" || die "could not create a tmux pane for '$role'"
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
  fi
}

cmd_destroy() {
  local remove_worktrees=0 assume_yes=0 role
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --worktrees) remove_worktrees=1 ;;
      --yes | -y) assume_yes=1 ;;
      *) die_usage "usage: teamctl destroy [--worktrees] [--yes]" ;;
    esac
    shift
  done
  require_tools
  load_project
  require_manager destroy
  SESSION="$(session_name_for_project)"
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
    say "worktrees kept. Remove the clean ones later with: teamctl destroy --worktrees"
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
      valid_role "$2" && valid_role "$3" || return 1
      text="[wolfmux] Team change: $2 spawned teammate $3 ($4). Run: teamctl status"
      ;;
    approval)
      valid_approval_id "$2" && valid_role "$3" || return 1
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
  local role="$1" bead="$2" pane text
  [ "$role" != "${TEAM_ROLE:-}" ] || return 0
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
    text="[wolfmux] Beads update for $role ($bead). Run: bd show $bead -- then: bd list --assignee $role --status open --include-infra"
  else
    text="[wolfmux] Beads update for $role. Run: bd list --assignee $role --status open --include-infra"
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
  # Called from Beads hooks for every assignee, including humans and roles that
  # are not running: in quiet mode "nothing to notify" is success, not an error.
  if [ "$quiet" -eq 1 ]; then
    [ -n "$TMUX_BIN" ] && [ -n "$JQ_BIN" ] && [ -n "$GIT_BIN" ] || return 0
    ROOT="$(resolve_root 2>/dev/null)" || return 0
    PROJECT_KEY="$(project_key "$ROOT")"
    STATE_DIR="$WOLFMUX_DATA/state/$PROJECT_KEY"
    WORKTREES_DIR="$WOLFMUX_DATA/worktrees/$PROJECT_KEY"
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
    valid_role "$role" || return 0
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
