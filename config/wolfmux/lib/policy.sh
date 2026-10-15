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
#   browser-writes      ask | allow         DEFAULT ask. allow writes an explicit
#                                           permissions.allow rule for mcp__claude-in-chrome__*
#                                           into every agent's settings (lead and workers), so
#                                           a Chrome write resolves before Claude Code's
#                                           auto-mode classifier ever sees it (lib/agents.sh)
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
#   auto-prune          on | off            DEFAULT on. Sweep a lane's build output the moment the
#                                           lane is parked, instead of waiting for someone to
#                                           remember `teamctl prune` (lib/disk.sh). A single lane is
#                                           protected with `teamctl keep <role>`
#   auto-reclaim        on | off            DEFAULT on. Take a parked lane off the books by itself
#                                           (worktree, branch, record) once its task is closed, its
#                                           content is in main, nothing is uncommitted and no PR is
#                                           open (lib/reclaim.sh). Off: nothing is removed unless
#                                           somebody runs `teamctl reclaim`. `teamctl keep <role>`
#                                           protects a single lane from this too
#   branch-template     <template>          how this team names its workers' branches, with the
#                                           placeholders {team} {role} {ts} {ticket}. Empty = the
#                                           built-in shape (lib/worktree.sh). The only key whose
#                                           value is free text, so it is handled apart below.
#   human-pane-typing   off | idle          DEFAULT off. May a notice be TYPED into a pane a human
#                                           is watching: the lead's pane while a client is attached
#                                           to the team, and whatever pane an attached client is
#                                           showing? off = never; the notice is filed and the agent
#                                           gets it from its own hooks (lib/inbox.sh). idle = the
#                                           v1.16.1 rule: typed once that pane has been quiet.
#                                           Only you may change it, never an agent: it is about
#                                           your own screen (require_operator).
# Precedence: `teamctl start` flags / `teamctl policy` (stored in this project's
# meta.json) > environment > ~/.config/wolfmux/config > the defaults below.

POLICY_KEYS="lead-permissions worker-permissions browser-writes worker-spawn worker-isolation lead-teams disk-guard disk-min-gb link-node-modules auto-prune auto-reclaim branch-template human-pane-typing"

policy_default() {
  case "$1" in
    lead-permissions) printf '%s\n' "${WOLFMUX_LEAD_PERMISSIONS:-skip}" ;;
    worker-permissions) printf '%s\n' "${WOLFMUX_WORKER_PERMISSIONS:-skip}" ;;
    browser-writes) printf '%s\n' "${WOLFMUX_BROWSER_WRITES:-ask}" ;;
    worker-spawn) printf '%s\n' "${WOLFMUX_WORKER_SPAWN:-off}" ;;
    worker-isolation) printf '%s\n' "${WOLFMUX_WORKER_ISOLATION:-on}" ;;
    lead-teams) printf '%s\n' "${WOLFMUX_LEAD_TEAMS:-on}" ;;
    disk-guard) printf '%s\n' "${WOLFMUX_DISK_GUARD:-refuse}" ;;
    disk-min-gb) printf '%s\n' "${WOLFMUX_DISK_MIN_GB:-$WOLFMUX_DISK_MIN_GB_DEFAULT}" ;;
    link-node-modules) printf '%s\n' "${WOLFMUX_LINK_NODE_MODULES:-off}" ;;
    auto-prune) printf '%s\n' "${WOLFMUX_AUTO_PRUNE:-on}" ;;
    auto-reclaim) printf '%s\n' "${WOLFMUX_AUTO_RECLAIM:-on}" ;;
    branch-template) printf '%s\n' "${WOLFMUX_BRANCH_TEMPLATE:-}" ;;
    human-pane-typing) printf '%s\n' "${WOLFMUX_HUMAN_PANE_TYPING:-off}" ;;
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
    browser-writes:ask | browser-writes:allow) return 0 ;;
    worker-spawn:on | worker-spawn:off) return 0 ;;
    worker-isolation:on | worker-isolation:off) return 0 ;;
    lead-teams:on | lead-teams:off) return 0 ;;
    disk-guard:refuse | disk-guard:warn | disk-guard:off) return 0 ;;
    link-node-modules:on | link-node-modules:off) return 0 ;;
    auto-prune:on | auto-prune:off) return 0 ;;
    auto-reclaim:on | auto-reclaim:off) return 0 ;;
    human-pane-typing:off | human-pane-typing:idle) return 0 ;;
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
    browser-writes) printf 'ask|allow\n' ;;
    worker-spawn | worker-isolation | lead-teams | link-node-modules | auto-prune | auto-reclaim) printf 'on|off\n' ;;
    disk-guard) printf 'refuse|warn|off\n' ;;
    human-pane-typing) printf 'off|idle\n' ;;
    disk-min-gb) printf 'a whole number of GB, no leading zero (0 = no limit)\n' ;;
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
  elif [ "$key" = "disk-guard" ]; then
    printf 'refuse\n'
  elif [ "$key" = "disk-min-gb" ]; then
    printf '%s\n' "$WOLFMUX_DISK_MIN_GB_DEFAULT"
  elif [ "$key" = "link-node-modules" ]; then
    printf 'off\n'
  elif [ "$key" = "auto-prune" ]; then
    # The default is on, but a value nobody can read is not permission to delete: the
    # cautious answer for a cleanup is "do not", exactly as it is "ask" for a permission.
    printf 'off\n'
  elif [ "$key" = "auto-reclaim" ]; then
    # The same direction as auto-prune above, and here it is not a matter of taste. The
    # default is on because a finished lane that nobody takes away is the hoarding this knob
    # exists to end. But what it switches on deletes a worktree and a branch — source, not
    # something a build makes again — so a value nobody can read (a typo in the config file,
    # a hand-edited meta.json) must never be read as "yes". Unreadable means off: nothing is
    # removed, every lane says what it is holding, and `teamctl reclaim` still works by hand.
    printf 'off\n'
  elif [ "$key" = "human-pane-typing" ]; then
    # Unreadable means the human's screen stays quiet: a typo must not bring the lines back.
    printf 'off\n'
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

# is_operator — you, at your own terminal, and nobody else: caller_role is empty.
#
# is_manager below says 0 for an empty caller role AND for the lead of the loaded team, which
# is what "may manage this team" means and is right for every command that has one. It cannot
# express "every team on this machine at once", because a lead has no standing outside its own
# team: `teamctl prune --all-teams` would sweep lanes of teams that lead does not manage, and
# is_manager says 0 to it for the team it happens to be standing in. So the operator-only
# commands ask this instead. Same cooperative check as caller_role, not a security boundary.
is_operator() { [ -z "$(caller_role)" ]; }

# require_operator <what was typed> <what it would reach> <what to run instead> — the same
# shape of refusal as require_manager, exit 77, naming the command that IS the caller's.
#
# No Beads suggestion here, unlike require_manager: a command that reaches every team is not
# something any lead can grant, so pointing a refused agent at its lead would send it to ask
# the one person who cannot say yes. The owner runs it, from a terminal of their own.
require_operator() {
  is_operator && return 0
  die "'teamctl $1' reaches $2, so it is the machine owner's alone to run, from their own terminal. You are '$(team_identity "$(caller_team | sed "s/^\$/$WOLFMUX_DEFAULT_TEAM/")" "$(caller_role)")', and a lead has no standing outside its own team — no lead can grant this one, so there is nobody to ask for it. What is yours: $3" 77
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
  printf 'lead: %s · workers: %s · worker spawning: %s · worker isolation: %s\n' \
    "$(policy_get lead-permissions)" "$(policy_get worker-permissions)" "$(policy_get worker-spawn)" "$(policy_get worker-isolation)"
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
    say "  browser-writes      $(policy_get browser-writes)      (ask|allow)       allow writes a Chrome-write ALLOW rule into every agent's settings"
    say "  worker-spawn        $(policy_get worker-spawn)     (on|off)          may workers run 'teamctl spawn'?"
    say "  worker-isolation    $(policy_get worker-isolation)      (on|off)          refuse a worker's tool calls outside its own worktree and branch"
    say "  lead-teams          $(policy_get lead-teams)      (on|off)          may the lead found further teams and hand work over?"
    say "  disk-guard          $(policy_get disk-guard)  (refuse|warn|off) what 'teamctl spawn' does under disk-min-gb free disk"
    say "  disk-min-gb         $(policy_get disk-min-gb)       (number, GB)      free space a spawn asks for; 0 = no limit"
    say "  link-node-modules   $(policy_get link-node-modules)     (on|off)          link a new lane's node_modules to its repository's copy"
    say "  auto-prune          $(policy_get auto-prune)      (on|off)          sweep a lane's build output as soon as it is parked (protect one: teamctl keep <role>)"
    say "  auto-reclaim        $(policy_get auto-reclaim)      (on|off)          take a parked lane off the books once its task is closed and its work is all in main (protect one: teamctl keep <role>)"
    template="$(policy_get branch-template)"
    if [ -n "$template" ]; then
      say "  branch-template     $template     how this team names its workers' branches"
    else
      say "  branch-template     $(wt_default_template)   (the built-in shape)   how this team names its workers' branches"
    fi
    say "                      placeholders {team} {role} {ts} {ticket}; {ts} is required. A template with {ticket}"
    say "                      needs teamctl spawn --ticket <KEY>, or a team default: teamctl start <model> --ticket <KEY>"
    say "                      back to the built-in shape: teamctl policy branch-template default"
    say "  human-pane-typing   $(policy_get human-pane-typing)       (off|idle)        type a notice into a pane you are watching (the lead's while you are attached,"
    say "                      and any pane on your screen)? off = never, it is filed for the agent's own hooks · idle = once that pane is quiet."
    say "                      Yours alone to change, from your own terminal. Who is typed into at all: WOLFMUX_NUDGE_TYPE=$WOLFMUX_NUDGE_TYPE"
    say ""
    say "change:  teamctl policy <key> <value>     permission changes apply at the next start/restart of an agent"
    return 0
  fi
  case " $POLICY_KEYS " in *" $key "*) ;; *) die_usage "unknown policy '$key' (known: $POLICY_KEYS)" ;; esac
  [ -n "$value" ] || die_usage "usage: teamctl policy $key <$(policy_choices "$key")>"
  # Whether notices may be typed in front of the human is the human's call. A lead that is
  # not being woken has every reason to want it back on, and its pane IS the human's.
  if [ "$key" = "human-pane-typing" ]; then
    require_operator "policy human-pane-typing" "the human's own screen (may a notice be typed into a pane they are watching)" \
      "nothing to change: your notices reach you through your own Stop and UserPromptSubmit hooks. If that is not enough, tell the human"
  fi
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
