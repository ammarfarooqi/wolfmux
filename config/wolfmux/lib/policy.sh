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
#   worker-context      full | trim | lean  what of YOUR Claude Code setup a worker's conversation starts
#                                           with. full = all of it (plugins, their skills, agents and
#                                           hooks, your rules). trim = your rules and settings, no
#                                           plugins. lean = the project's own instructions and
#                                           wolfmux's, nothing from ~/.claude. See worker_context_*
#                                           below for what that costs and saves.
#   branch-template     <template>          how this team names its workers' branches, with the
#                                           placeholders {team} {role} {ts} {ticket}. Empty = the
#                                           built-in shape (lib/worktree.sh). The only key whose
#                                           value is free text, so it is handled apart below.
# Precedence: `teamctl start` flags / `teamctl policy` (stored in this project's
# meta.json) > environment > ~/.config/wolfmux/config > the defaults below.

POLICY_KEYS="lead-permissions worker-permissions worker-spawn worker-isolation worker-context lead-teams branch-template"

policy_default() {
  case "$1" in
    lead-permissions) printf '%s\n' "${WOLFMUX_LEAD_PERMISSIONS:-skip}" ;;
    worker-permissions) printf '%s\n' "${WOLFMUX_WORKER_PERMISSIONS:-skip}" ;;
    worker-spawn) printf '%s\n' "${WOLFMUX_WORKER_SPAWN:-off}" ;;
    worker-isolation) printf '%s\n' "${WOLFMUX_WORKER_ISOLATION:-on}" ;;
    lead-teams) printf '%s\n' "${WOLFMUX_LEAD_TEAMS:-on}" ;;
    worker-context) printf '%s\n' "${WOLFMUX_WORKER_CONTEXT:-trim}" ;;
    branch-template) printf '%s\n' "${WOLFMUX_BRANCH_TEMPLATE:-}" ;;
    *) return 1 ;;
  esac
}

policy_valid() { # <key> <value>
  # The one key that is not a choice out of a fixed set.
  if [ "$1" = "branch-template" ]; then
    branch_template_valid "$2"
    return
  fi
  case "$1:$2" in
    lead-permissions:skip | lead-permissions:ask) return 0 ;;
    worker-permissions:skip | worker-permissions:lead | worker-permissions:ask) return 0 ;;
    worker-spawn:on | worker-spawn:off) return 0 ;;
    worker-isolation:on | worker-isolation:off) return 0 ;;
    lead-teams:on | lead-teams:off) return 0 ;;
    worker-context:full | worker-context:trim | worker-context:lean) return 0 ;;
    *) return 1 ;;
  esac
}

policy_choices() {
  case "$1" in
    lead-permissions) printf 'skip|ask\n' ;;
    worker-permissions) printf 'skip|lead|ask\n' ;;
    worker-spawn | worker-isolation | lead-teams) printf 'on|off\n' ;;
    worker-context) printf 'full|trim|lean\n' ;;
    branch-template) printf "'<template>' with {team} {role} {ts} {ticket}, or the word default\n" ;;
  esac
}

# policy_get <key> — never fails; an invalid stored or configured value falls back
# to the safe side (ask / off) instead of silently widening what agents may do.
policy_get() {
  local key="$1" value
  value="$(meta_get "policy_${key//-/_}" 2>/dev/null || true)"
  [ -n "$value" ] || value="$(policy_default "$key")"
  if [ "$key" = "branch-template" ]; then
    # Empty, or anything unusable, means the built-in shape: a stored template that can no
    # longer be expanded must never stop a spawn.
    if [ -n "$value" ] && branch_template_valid "$value"; then printf '%s\n' "$value"; fi
    return 0
  fi
  if policy_valid "$key" "$value"; then
    printf '%s\n' "$value"
  elif [ "$key" = "worker-spawn" ]; then
    printf 'off\n'
  elif [ "$key" = "worker-isolation" ]; then
    printf 'on\n'
  elif [ "$key" = "lead-teams" ]; then
    printf 'off\n'
  elif [ "$key" = "worker-context" ]; then
    printf 'full\n' # an unreadable value never takes something of yours away from a worker
  else
    printf 'ask\n'
  fi
}

policy_set() { # <key> <value>
  local why
  if [ "$1" = "branch-template" ]; then
    # "default" is how you go back to the built-in shape; it is stored as no template at all.
    if [ "$2" = "default" ]; then
      meta_put policy_branch_template ""
      return 0
    fi
    why="$(branch_template_error "$2")"
    [ -z "$why" ] || die_usage "branch-template '$2': $why"
    meta_put policy_branch_template "$2"
    return 0
  fi
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

# --- the founder of a team ---------------------------------------------------------------
# A lead that founds a team (teamctl start <model> --team <new>) does not manage it while its own
# lead runs. When that lead is not running (its pane exited or is gone, or there is no session at
# all) nobody would be left to restart, stop or delete the team, so its founder may: restart, stop,
# remove and destroy, and start --continue. Never policy, approve or deny. The founder is the Beads
# identity in the lead's spawned_by ("lead", "review.lead"), written when the team was started.
FOUNDER_COMMANDS="restart stop remove destroy"

# caller_identity: what the calling agent is called in Beads ("lead", "review.backend"); empty for you
caller_identity() {
  local role team
  role="$(caller_role)"
  [ -n "$role" ] || return 1
  team="$(caller_team)"
  team_identity "${team:-$WOLFMUX_DEFAULT_TEAM}" "$role"
}

# team_founder: who started the loaded team: the Beads identity of the lead that founded it, else
# "operator" (you). The lead's record says; meta.json keeps it for when that record is gone
# (a plain `teamctl destroy` deletes the lead's record and keeps the workers').
team_founder() {
  local founder
  founder="$(reg_field "$WOLFMUX_LEAD_ROLE" spawned_by 2>/dev/null || true)"
  [ -n "$founder" ] || founder="$(meta_get founder 2>/dev/null || true)"
  printf '%s\n' "${founder:-operator}"
}

# team_lead_running: is the lead of the loaded team running right now? Asks tmux.
team_lead_running() {
  local session pane
  session="$(session_name_for_project)"
  tm_session_exists "$session" || return 1
  pane="$(tm_pane_for_role "$session" "$WOLFMUX_LEAD_ROLE" 2>/dev/null || true)"
  [ "$(tm_pane_state "$pane")" = "running" ]
}

# team_orphaned: the loaded team exists (records or a session) and has no running lead
team_orphaned() {
  [ -n "$(reg_list 2>/dev/null)" ] || tm_session_exists "$(session_name_for_project)" || return 1
  ! team_lead_running
}

# is_founder: the caller is a lead, and the lead that founded the loaded team
is_founder() {
  local founder
  [ "$(caller_role)" = "$WOLFMUX_LEAD_ROLE" ] || return 1
  founder="$(team_founder)"
  [ "$founder" != "operator" ] && [ "$founder" = "$(caller_identity)" ]
}

# founder_may_act: is_founder, and the loaded team has no running lead to conflict with
founder_may_act() {
  is_founder && ! team_lead_running
}

FOUNDER_HINT="you founded it: once its lead has stopped you may restart or destroy it"

# founder_announce <what it did>: set by require_manager / cmd_start when a founder acts: you are told, the way
# founding a team is told, and the event log says who acted (event_log: by is the founder's identity)
founder_announce() {
  [ -n "${FOUNDER_ACTING:-}" ] || return 0
  (WOLFMUX_TEAM="$TEAM" notify_deliver "$WOLFMUX_LEAD_MARK $FOUNDER_ACTING $1 team '$TEAM', which it founded (its lead was not running)." >/dev/null 2>&1) || true
}

require_manager() { # <command name>
  local hint=""
  is_manager && return 0
  case " $FOUNDER_COMMANDS " in
    *" $1 "*)
      if is_founder; then
        if ! team_lead_running; then
          FOUNDER_ACTING="$(caller_identity)"
          EVENT_BY="$FOUNDER_ACTING"
          return 0
        fi
        hint="; $FOUNDER_HINT"
      fi
      ;;
  esac
  die "'teamctl $1' is reserved for the lead of team '${TEAM:-$WOLFMUX_DEFAULT_TEAM}'. You are '$(team_identity "$(caller_team | sed "s/^\$/$WOLFMUX_DEFAULT_TEAM/")" "$(caller_role)")'$hint. Ask that lead: bd create \"<what you need>\" -t message -a $(team_identity "${TEAM:-$WOLFMUX_DEFAULT_TEAM}" "$WOLFMUX_LEAD_ROLE") -d \"<why>\"" 77
}

# team_orphaned_note: who may act on the loaded team while its lead is not running
team_orphaned_note() {
  local founder note="you"
  founder="$(team_founder)"
  if [ "$founder" != "operator" ]; then note="you, $founder (its founder)"; fi
  printf 'orphaned: its lead is not running. May act on it: %s.' "$note"
}

policy_summary() {
  printf 'lead: %s · workers: %s · worker spawning: %s · worker isolation: %s · worker context: %s\n' \
    "$(policy_get lead-permissions)" "$(policy_get worker-permissions)" "$(policy_get worker-spawn)" "$(policy_get worker-isolation)" "$(policy_get worker-context)"
}

# --- worker-context: what a worker's conversation starts with ----------------------------
# Measured on the owner's machine (Claude Code 2.1.323, 2026-11-13): a worker's FIRST request was
# 111,000 tokens before it had read its task, more than half of a 200k window, and every later
# request carries it. About 60,000 of that were the listings and session hooks of nine plugins,
# about 30,000 the rules in ~/.claude; the worker used almost none of it. A `claude -p` probe:
# full 85,700 tokens, plugins off 56,500, nothing from ~/.claude 19,000.
#   full  everything, as before v1.13
#   trim  (default) your rules and settings stay; every plugin is off for the worker
#   lean  only the project's own instructions (its CLAUDE.md, .claude/) and wolfmux's
# The lead is never trimmed: it is the conversation you talk to.

# worker_context_plugins_off — a settings fragment that turns off every plugin you have enabled or
# installed, for one agent ({} when there is none or the files cannot be read)
worker_context_plugins_off() {
  local base="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" files=() f
  for f in "$base/settings.json" "$base/plugins/installed_plugins.json"; do
    if [ -r "$f" ]; then files+=("$f"); fi
  done
  if [ "${#files[@]}" -eq 0 ]; then
    printf '{}\n'
    return 0
  fi
  "$JQ_BIN" -cs '[.[] | objects | ((.enabledPlugins // {}), (.plugins // {})) | objects | keys[]]
    | unique | map(select(type == "string" and test("^[A-Za-z0-9._@-]+$"))) | map({key: ., value: false})
    | if length == 0 then {} else {enabledPlugins: from_entries} end' "${files[@]}" 2>/dev/null || printf '{}\n'
}

# worker_context_settings <kind> <mode> — the fragment write_agent_settings merges in
worker_context_settings() {
  if [ "$1" != "worker" ] || [ "$2" = "full" ]; then
    printf '{}\n'
    return 0
  fi
  worker_context_plugins_off
}

# teamctl policy [<key> <value>]
cmd_policy() {
  local key="${1:-}" value="${2:-}" template
  require_tools
  load_project
  if [ -z "$key" ]; then
    say "policy for $(short_path "$ROOT")"
    say "  lead-permissions    $(policy_get lead-permissions)    (skip|ask)"
    say "  worker-permissions  $(policy_get worker-permissions)    (skip|lead|ask)   lead = you decide them: teamctl approvals"
    say "  worker-spawn        $(policy_get worker-spawn)     (on|off)          may workers run 'teamctl spawn'?"
    say "  worker-isolation    $(policy_get worker-isolation)      (on|off)          refuse a worker's tool calls outside its own worktree and branch"
    say "  worker-context      $(policy_get worker-context)    (full|trim|lean)  what of your ~/.claude a worker starts with: full = all,"
    say "                      trim = your rules, no plugins · lean = only the project's own instructions and wolfmux's"
    say "  lead-teams          $(policy_get lead-teams)      (on|off)          may the lead found further teams and hand work over?"
    template="$(policy_get branch-template)"
    if [ -n "$template" ]; then
      say "  branch-template     $template     how this team names its workers' branches"
    else
      say "  branch-template     $(wt_default_template)   (the built-in shape)   how this team names its workers' branches"
    fi
    say "                      placeholders {team} {role} {ts} {ticket}; {ts} is required. A template with {ticket}"
    say "                      needs teamctl spawn --ticket <KEY>, or a team default: teamctl start <model> --ticket <KEY>"
    say "                      back to the built-in shape: teamctl policy branch-template default"
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
  if [ "$key" = "branch-template" ] && [ "$value" = "default" ]; then
    say "policy: branch-template = $(wt_default_template)   (the built-in shape)"
  else
    say "policy: $key = $value"
  fi
  case "$key" in
    worker-spawn) ;;
    *) say "applies to agents started or restarted from now on (teamctl restart <role>)" ;;
  esac
  SESSION="$(session_name_for_project)"
  if tm_session_exists "$SESSION" && [ "$(caller_role)" != "$WOLFMUX_LEAD_ROLE" ]; then
    notify_lead policy "$key" "$value" || true
  fi
}
