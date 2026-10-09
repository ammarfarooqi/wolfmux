#!/bin/bash
# policy.sh — one manager, and what everybody else may do.
#
# The lead is the only manager of a team. Workers implement; they never manage,
# approve, stop or (unless you switch it on) spawn other agents.
#
# Team policy, per project:
#   lead-permissions    skip | ask          how the lead's CLI treats permission prompts
#   worker-permissions  skip | lead | ask   skip = none asked · lead = the lead decides
#                                           them (teamctl approvals) · ask = in the pane
#   worker-spawn        off | on            may a worker run `teamctl spawn`?
#   lead-teams          on | off            may this team's lead found further teams (teamctl start
#                                           <model> --team <new>) and hand work over to them?
#   worker-isolation    on | off            refuse a worker's tool calls that reach outside its
#                                           own worktree and branch (lib/guard.sh)
#   disk-guard          refuse | warn | off what `teamctl spawn` does when free disk is under
#                                           disk-min-gb (lib/disk.sh)
#   disk-min-gb         <whole number>      the free space a spawn asks for, in GB (0 = no limit)
#   link-node-modules   off | on            link a new lane's node_modules to the project root's
#                                           copy instead of letting it install its own
# Precedence: `teamctl start` flags / `teamctl policy` (stored in this project's
# meta.json) > environment > ~/.config/wolfmux/config > the defaults below.

POLICY_KEYS="lead-permissions worker-permissions worker-spawn worker-isolation lead-teams disk-guard disk-min-gb link-node-modules"

policy_default() {
  case "$1" in
    lead-permissions) printf '%s\n' "${WOLFMUX_LEAD_PERMISSIONS:-skip}" ;;
    worker-permissions) printf '%s\n' "${WOLFMUX_WORKER_PERMISSIONS:-skip}" ;;
    worker-spawn) printf '%s\n' "${WOLFMUX_WORKER_SPAWN:-off}" ;;
    worker-isolation) printf '%s\n' "${WOLFMUX_WORKER_ISOLATION:-on}" ;;
    lead-teams) printf '%s\n' "${WOLFMUX_LEAD_TEAMS:-on}" ;;
    disk-guard) printf '%s\n' "${WOLFMUX_DISK_GUARD:-refuse}" ;;
    disk-min-gb) printf '%s\n' "${WOLFMUX_DISK_MIN_GB:-$WOLFMUX_DISK_MIN_GB_DEFAULT}" ;;
    link-node-modules) printf '%s\n' "${WOLFMUX_LINK_NODE_MODULES:-off}" ;;
    *) return 1 ;;
  esac
}

policy_valid() { # <key> <value>
  case "$1:$2" in
    lead-permissions:skip | lead-permissions:ask) return 0 ;;
    worker-permissions:skip | worker-permissions:lead | worker-permissions:ask) return 0 ;;
    worker-spawn:on | worker-spawn:off) return 0 ;;
    worker-isolation:on | worker-isolation:off) return 0 ;;
    lead-teams:on | lead-teams:off) return 0 ;;
    disk-guard:refuse | disk-guard:warn | disk-guard:off) return 0 ;;
    link-node-modules:on | link-node-modules:off) return 0 ;;
    # A number, not a word: whole gigabytes, 0 switches the limit off, and the ceiling is
    # only there so that a slip of the hand cannot refuse every spawn for ever.
    # A leading zero is refused on purpose. `test -le` reads base ten but shell arithmetic
    # reads 08 as octal and aborts, so "disk-min-gb 08" used to break every spawn in the
    # team with a raw bash error, and "010" quietly enforced 8 GB while printing 010.
    disk-min-gb:*)
      case "$2" in "" | *[!${_WM_DIGITS}]* | 0?*) return 1 ;; esac
      [ "$2" -le 10000 ]
      ;;
    *) return 1 ;;
  esac
}

policy_choices() {
  case "$1" in
    lead-permissions) printf 'skip|ask\n' ;;
    worker-permissions) printf 'skip|lead|ask\n' ;;
    worker-spawn | worker-isolation | lead-teams | link-node-modules) printf 'on|off\n' ;;
    disk-guard) printf 'refuse|warn|off\n' ;;
    disk-min-gb) printf 'a whole number of GB, no leading zero (0 = no limit)\n' ;;
  esac
}

# policy_get <key> — never fails; an invalid stored or configured value falls back
# to the safe side (ask / off) instead of silently widening what agents may do.
policy_get() {
  local key="$1" value
  value="$(meta_get "policy_${key//-/_}" 2>/dev/null || true)"
  [ -n "$value" ] || value="$(policy_default "$key")"
  if policy_valid "$key" "$value"; then
    printf '%s\n' "$value"
  elif [ "$key" = "worker-spawn" ]; then
    printf 'off\n'
  elif [ "$key" = "worker-isolation" ]; then
    printf 'on\n'
  elif [ "$key" = "lead-teams" ]; then
    printf 'off\n'
  elif [ "$key" = "disk-guard" ]; then
    printf 'refuse\n'
  elif [ "$key" = "disk-min-gb" ]; then
    printf '%s\n' "$WOLFMUX_DISK_MIN_GB_DEFAULT"
  elif [ "$key" = "link-node-modules" ]; then
    printf 'off\n'
  else
    printf 'ask\n'
  fi
}

policy_set() { # <key> <value>
  policy_valid "$1" "$2" || die_usage "$1 must be one of: $(policy_choices "$1")"
  meta_put "policy_${1//-/_}" "$2"
}

# effective_permissions <kind> <family> — the mode an agent is launched with.
# Codex has no permission-request hook, so "lead" degrades to its own prompts.
effective_permissions() {
  local mode
  if [ "$1" = "lead" ]; then
    policy_get lead-permissions
    return 0
  fi
  mode="$(policy_get worker-permissions)"
  if [ "$mode" = "lead" ] && [ "$2" = "codex" ]; then mode="ask"; fi
  printf '%s\n' "$mode"
}

# caller_role — which agent is running this command. The pane it runs in decides;
# TEAM_ROLE is the fallback outside tmux. Empty = you, at your own terminal.
# A cooperative check, not a security boundary: every agent is your macOS user.
caller_role() {
  local role=""
  if [ -n "${TMUX_PANE:-}" ] && [ -n "$TMUX_BIN" ] && tm_inside_team_server; then
    role="$(tmx display-message -p -t "$TMUX_PANE" '#{@ai_role}' 2>/dev/null || true)"
  fi
  [ -n "$role" ] || role="${TEAM_ROLE:-}"
  printf '%s\n' "$role"
}

# You manage every team. A lead manages its own team and no other.
is_manager() {
  local role team
  role="$(caller_role)"
  [ -n "$role" ] || return 0
  [ "$role" = "$WOLFMUX_LEAD_ROLE" ] || return 1
  team="$(caller_team)"
  [ "${team:-$WOLFMUX_DEFAULT_TEAM}" = "${TEAM:-$WOLFMUX_DEFAULT_TEAM}" ]
}

require_manager() { # <command name>
  is_manager && return 0
  die "'teamctl $1' is reserved for the lead of team '${TEAM:-$WOLFMUX_DEFAULT_TEAM}'. You are '$(team_identity "$(caller_team | sed "s/^\$/$WOLFMUX_DEFAULT_TEAM/")" "$(caller_role)")'. Ask that lead: bd create \"<what you need>\" -t message -a $(team_identity "${TEAM:-$WOLFMUX_DEFAULT_TEAM}" "$WOLFMUX_LEAD_ROLE") -d \"<why>\"" 77
}

policy_summary() {
  printf 'lead: %s · workers: %s · worker spawning: %s · worker isolation: %s\n' \
    "$(policy_get lead-permissions)" "$(policy_get worker-permissions)" "$(policy_get worker-spawn)" "$(policy_get worker-isolation)"
}

# teamctl policy [<key> <value>]
cmd_policy() {
  local key="${1:-}" value="${2:-}"
  require_tools
  load_project
  if [ -z "$key" ]; then
    say "policy for $(short_path "$ROOT")"
    say "  lead-permissions    $(policy_get lead-permissions)    (skip|ask)"
    say "  worker-permissions  $(policy_get worker-permissions)    (skip|lead|ask)   lead = you decide them: teamctl approvals"
    say "  worker-spawn        $(policy_get worker-spawn)     (on|off)          may workers run 'teamctl spawn'?"
    say "  worker-isolation    $(policy_get worker-isolation)      (on|off)          refuse a worker's tool calls outside its own worktree and branch"
    say "  lead-teams          $(policy_get lead-teams)      (on|off)          may the lead found further teams and hand work over?"
    say "  disk-guard          $(policy_get disk-guard)  (refuse|warn|off) what 'teamctl spawn' does under disk-min-gb free disk"
    say "  disk-min-gb         $(policy_get disk-min-gb)       (number, GB)      free space a spawn asks for; 0 = no limit"
    say "  link-node-modules   $(policy_get link-node-modules)     (on|off)          link a new lane's node_modules to the project root's copy"
    say ""
    say "change:  teamctl policy <key> <value>     permission changes apply at the next start/restart of an agent"
    return 0
  fi
  case " $POLICY_KEYS " in *" $key "*) ;; *) die_usage "unknown policy '$key' (known: $POLICY_KEYS)" ;; esac
  [ -n "$value" ] || die_usage "usage: teamctl policy $key <$(policy_choices "$key")>"
  require_manager policy
  ensure_state_dirs
  policy_set "$key" "$value"
  event_log policy "" "$key=$value"
  say "policy: $key = $value"
  case "$key" in
    worker-spawn) ;;
    *) say "applies to agents started or restarted from now on (teamctl restart <role>)" ;;
  esac
  SESSION="$(session_name_for_project)"
  if tm_session_exists "$SESSION" && [ "$(caller_role)" != "$WOLFMUX_LEAD_ROLE" ]; then
    notify_lead policy "$key" "$value" || true
  fi
}
