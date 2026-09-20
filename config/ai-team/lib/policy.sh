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
# Precedence: `teamctl start` flags / `teamctl policy` (stored in this project's
# meta.json) > environment > ~/.config/ai-team/config > the defaults below.

POLICY_KEYS="lead-permissions worker-permissions worker-spawn"

policy_default() {
  case "$1" in
    lead-permissions) printf '%s\n' "${AI_TEAM_LEAD_PERMISSIONS:-skip}" ;;
    worker-permissions) printf '%s\n' "${AI_TEAM_WORKER_PERMISSIONS:-skip}" ;;
    worker-spawn) printf '%s\n' "${AI_TEAM_WORKER_SPAWN:-off}" ;;
    *) return 1 ;;
  esac
}

policy_valid() { # <key> <value>
  case "$1:$2" in
    lead-permissions:skip | lead-permissions:ask) return 0 ;;
    worker-permissions:skip | worker-permissions:lead | worker-permissions:ask) return 0 ;;
    worker-spawn:on | worker-spawn:off) return 0 ;;
    *) return 1 ;;
  esac
}

policy_choices() {
  case "$1" in
    lead-permissions) printf 'skip|ask\n' ;;
    worker-permissions) printf 'skip|lead|ask\n' ;;
    worker-spawn) printf 'on|off\n' ;;
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

is_manager() {
  local role
  role="$(caller_role)"
  [ -z "$role" ] || [ "$role" = "$AI_TEAM_LEAD_ROLE" ]
}

require_manager() { # <command name>
  is_manager && return 0
  die "'teamctl $1' is reserved for the lead. You are '$(caller_role)'. Ask the lead: bd create \"<what you need>\" -t message -a lead -d \"<why>\"" 77
}

policy_summary() {
  printf 'lead: %s · workers: %s · worker spawning: %s\n' \
    "$(policy_get lead-permissions)" "$(policy_get worker-permissions)" "$(policy_get worker-spawn)"
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
  if tm_session_exists "$SESSION" && [ "$(caller_role)" != "$AI_TEAM_LEAD_ROLE" ]; then
    notify_lead policy "$key" "$value" || true
  fi
}
