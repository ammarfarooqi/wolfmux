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
#   orphan-steward      <team> | off        DEFAULT off. The one team of this project whose LEAD may
#                                           bring back a team YOU founded while that team's lead is
#                                           not running: restart its lead, stop its agents, nothing
#                                           else (the orphan steward, below). One value for the whole
#                                           project, so it is kept in a file of the project's own
#                                           (project_policy_file), not in one team's meta.json. Only
#                                           you may set it, never an agent (require_operator).
#   lead-model          <model> | default   DEFAULT opus (WOLFMUX_LEAD_MODEL). The model a NEW lead gets from
#                                           `teamctl start` when no model is named. Fable only when asked for:
#                                           `teamctl start fable`, or `teamctl model lead fable` for a running
#                                           team. A team that has a lead keeps that lead's own recorded model.
#                                           For the whole project, kept beside orphan-steward; yours alone.
#   team-memory         <team> | off        DEFAULT off. The one team of this project whose LEAD keeps a
#                                           private memory folder, ~/.wolfmux/memory/<project>/<team>/
#                                           (lib/memory.sh). For the whole project, kept beside
#                                           orphan-steward. Only you may turn it on (require_operator);
#                                           off may also come from that team's own lead. Never read from
#                                           the environment or the config file: no default but off.
#   restore-on-limit    report | <model>    DEFAULT report. What `teamctl restore` does with a lead
#                                           that comes back to a used-up model limit ("You've
#                                           reached your Fable limit"): report = name it at the end
#                                           and change nothing; a model (opus, sonnet, claude:<id>…) =
#                                           restart that lead on it, through `teamctl restart --model`
#                                           (lib/restore.sh)
# Precedence: `teamctl start` flags / `teamctl policy` (stored in this project's
# meta.json) > environment > ~/.config/wolfmux/config > the defaults below.

POLICY_KEYS="lead-permissions worker-permissions browser-writes worker-spawn worker-isolation lead-teams disk-guard disk-min-gb link-node-modules auto-prune auto-reclaim branch-template human-pane-typing orphan-steward lead-model team-memory restore-on-limit"

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
    orphan-steward) printf '%s\n' "${WOLFMUX_ORPHAN_STEWARD:-off}" ;;
    lead-model) printf '%s\n' "${WOLFMUX_LEAD_MODEL:-opus}" ;;
    team-memory) printf 'off\n' ;; # no setting: only `teamctl memory enable` turns it on
    restore-on-limit) printf '%s\n' "${WOLFMUX_RESTORE_ON_LIMIT:-report}" ;;
    *) return 1 ;;
  esac
}

# restore_on_limit_valid <value> — report, or a model `teamctl start` would take: a fixed key
# (opus, sonnet…) or <prefix>:<model-id> where the key list allows one (claude:<model-id>…)
restore_on_limit_valid() {
  local key
  [ "$1" = "report" ] && return 0
  for key in $WOLFMUX_MODEL_KEYS; do
    case "$key" in
      *":<model-id>")
        case "$1" in "${key%%:*}":?*) valid_model_id "${1#*:}" && return 0 ;; esac
        ;;
      *) [ "$1" = "$key" ] && return 0 ;;
    esac
  done
  return 1
}

policy_valid() { # <key> <value>
  # The keys that are not a choice out of a fixed set.
  if [ "$1" = "branch-template" ]; then
    branch_template_valid "$2"
    return
  fi
  # A team's name, or off. Whether that team exists is asked where it is set (cmd_policy).
  if [ "$1" = "orphan-steward" ] || [ "$1" = "team-memory" ]; then
    [ "$2" = "off" ] || valid_team_name "$2"
    return
  fi
  # Any model a lead can be started on (teamctl start <model>), as the resolver reads it. In a subshell: model_info
  # sets the MODEL_* of whoever calls it, and asking whether a value is valid must change nothing.
  if [ "$1" = "lead-model" ]; then
    [ -n "$2" ] && (model_info "$2") >/dev/null 2>&1
    return
  fi
  if [ "$1" = "restore-on-limit" ]; then
    restore_on_limit_valid "$2"
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
    orphan-steward | team-memory) printf 'a team of this project, or off\n' ;;
    lead-model) printf 'a model (opus, fable, sonnet, haiku, astra, …), or default\n' ;;
    restore-on-limit) printf 'report, or a model (opus, sonnet, claude:<model-id>, ...)\n' ;;
  esac
}

# The keys that belong to the project, not to a team: orphan-steward and team-memory name a team of the project, and
# lead-model is what a team that does not exist yet starts on, so no team's meta.json can hold it. In a team's
# meta.json it would be read by that team only, and the default team's goes with `teamctl destroy --purge`.
project_policy_file() { printf '%s/policy.json\n' "$PROJECT_STATE"; }

project_policy_get() { # <field>
  [ -n "${PROJECT_STATE:-}" ] && [ -f "$(project_policy_file)" ] || return 1
  "$JQ_BIN" -r --arg f "$1" '.[$f] // empty' "$(project_policy_file)"
}

project_policy_put() { # <field> <value>
  local record="{}"
  /bin/mkdir -p "$PROJECT_STATE"
  [ -f "$(project_policy_file)" ] && record="$(/bin/cat "$(project_policy_file)")"
  printf '%s' "$record" | "$JQ_BIN" --arg f "$1" --arg v "$2" '.[$f] = $v' | _reg_write_atomic "$(project_policy_file)"
}

# policy_get <key> — never fails; an invalid stored or configured value falls back
# to the safe side (ask / off) instead of silently widening what agents may do.
policy_get() {
  local key="$1" value
  if [ "$key" = "orphan-steward" ] || [ "$key" = "lead-model" ] || [ "$key" = "team-memory" ]; then
    value="$(project_policy_get "policy_${key//-/_}" 2>/dev/null || true)"
  else
    value="$(meta_get "policy_${key//-/_}" 2>/dev/null || true)"
  fi
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
  elif [ "$key" = "orphan-steward" ] || [ "$key" = "team-memory" ]; then
    # Unreadable means nobody but you and a team's founder may act on a team: no steward.
    # And no lead gets a private memory that nobody can say was turned on.
    printf 'off\n'
  elif [ "$key" = "lead-model" ]; then
    # A model nobody can start a lead on (a typo in the config file) is the built-in default, not a refused start.
    printf 'opus\n'
  elif [ "$key" = "restore-on-limit" ]; then
    # Unreadable means restore changes no lead's model: it reports, as by default.
    printf 'report\n'
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
  # lead-model default: back to the config file's value, or opus. Stored as nothing at all, as branch-template is.
  if [ "$1" = "lead-model" ] && [ "$2" = "default" ]; then
    project_policy_put policy_lead_model ""
    return 0
  fi
  policy_valid "$1" "$2" || die_usage "$1 must be one of: $(policy_choices "$1")"
  if [ "$1" = "orphan-steward" ] || [ "$1" = "lead-model" ] || [ "$1" = "team-memory" ]; then
    project_policy_put "policy_${1//-/_}" "$2"
    return 0
  fi
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
#
# The role is what the environment CLAIMS, and caller_resolve checks the claim with the pane
# proof (identity_in_own_pane, lib/common.sh). A claim that fails it is still the role printed
# here, never empty: empty is you, who may do everything, and a background chat that inherited
# the comms lead's environment (2026-10-19) must not become you by failing the proof. Every
# check of who may act (is_operator, is_manager, is_founder, is_steward, and through them
# require_manager and require_operator) refuses such a caller with exit 77 instead
# (caller_require_proven). What only reads (status, teams, dashboard, inbox, diff, capture,
# doctor) asks none of them and keeps working for it.
caller_role() {
  caller_resolve
  printf '%s\n' "$CALLER_ROLE"
}

# caller_resolve — works out, once per process, who the caller claims to be and whether the claim
# holds. CALLER_ROLE: the claimed role, empty for you. CALLER_TEAM: the claimed team.
# CALLER_NOT_HERE: why the claim does not hold, empty when it does (or when there is no claim).
# Call it in THIS shell before a $(caller_role): a substitution's subshell cannot keep the answer.
caller_resolve() {
  local proven=0 session=""
  [ -z "${CALLER_RESOLVED:-}" ] || return 0
  CALLER_RESOLVED=1 CALLER_ROLE="" CALLER_TEAM="" CALLER_NOT_HERE=""
  # One tmux read and one ps for the pane this process says it runs in, whatever role that is.
  if identity_in_own_pane ""; then proven=1; fi
  CALLER_ROLE="$IDENTITY_PANE_ROLE"
  [ -n "$CALLER_ROLE" ] || CALLER_ROLE="${TEAM_ROLE:-}"
  CALLER_TEAM="$IDENTITY_TEAM"
  [ -n "$CALLER_TEAM" ] || CALLER_TEAM="${WOLFMUX_TEAM:-$WOLFMUX_DEFAULT_TEAM}"
  [ -n "$CALLER_ROLE" ] || return 0 # nobody claims anything: you
  if [ "$proven" -eq 0 ]; then
    CALLER_NOT_HERE="$IDENTITY_WHY"
    return 0
  fi
  # The pane is that agent's, and this process runs in it. It must also be its team's session in
  # this project, as the records name it (not checked before a project is loaded: restore_who).
  if [ -n "${PROJECT_STATE:-}" ]; then
    session="$(team_paths "$CALLER_TEAM" && session_name_for_project 2>/dev/null)" || session=""
    if [ -n "$session" ] && [ "$session" != "$IDENTITY_SESSION" ]; then
      CALLER_NOT_HERE="pane $TMUX_PANE is in session $IDENTITY_SESSION, not the team's session $session"
    fi
  fi
  return 0
}

# caller_require_proven — the refusal: exit 77 when this process claims an agent's identity and
# does not run in that agent's pane (a background or inherited chat). Says nothing otherwise.
# One identity-refused line goes to the event log, at most once a minute per role.
caller_require_proven() {
  caller_resolve
  [ -n "$CALLER_NOT_HERE" ] || return 0
  identity_refused_log "$CALLER_ROLE" "teamctl ${TEAMCTL_ARGS:-}: $CALLER_NOT_HERE"
  die "this process claims $(team_identity "$CALLER_TEAM" "$CALLER_ROLE") but does not run in its pane (a background or inherited chat). Run teamctl from the agent's own pane, or from a plain Terminal as yourself. ('teamctl ${TEAMCTL_ARGS:-}' was not run: $CALLER_NOT_HERE)" 77
}

# is_operator — you, at your own terminal, and nobody else: caller_role is empty.
#
# is_manager below says 0 for an empty caller role AND for the lead of the loaded team, which
# is what "may manage this team" means and is right for every command that has one. It cannot
# express "every team on this machine at once", because a lead has no standing outside its own
# team: `teamctl prune --all-teams` would sweep lanes of teams that lead does not manage, and
# is_manager says 0 to it for the team it happens to be standing in. So the operator-only
# commands ask this instead. Same cooperative check as caller_role, not a security boundary.
#
# Like every check of who may act, it refuses a caller that fails the pane proof (exit 77). A
# view that only wants to word a line for you or for an agent asks caller_is_you instead.
is_operator() {
  caller_require_proven
  [ -z "$CALLER_ROLE" ]
}

# caller_is_you — 0 when nobody claims an agent's identity: for wording, never for permission
caller_is_you() {
  caller_resolve
  [ -z "$CALLER_ROLE" ]
}

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
  caller_require_proven
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
FOUNDER_COMMANDS="restart stop remove destroy finish model"

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
  caller_require_proven
  [ "$(caller_role)" = "$WOLFMUX_LEAD_ROLE" ] || return 1
  founder="$(team_founder)"
  [ "$founder" != "operator" ] && [ "$founder" = "$(caller_identity)" ]
}

# founder_may_act: is_founder, and the loaded team has no running lead to conflict with
founder_may_act() {
  is_founder && ! team_lead_running
}

FOUNDER_HINT="you founded it: once its lead has stopped you may restart or destroy it"

# --- the orphan steward ------------------------------------------------------------------
# A team YOU start has no founding lead (team_founder says "operator"), so once its lead is gone no agent may
# bring it back. Policy orphan-steward names one team of the project whose LEAD may do that much for you, on a
# team you founded whose lead is not running: `teamctl restart lead` (also --continue and --resume <id>) and
# `teamctl stop <role>`. Nothing else: not remove, destroy, start, policy, approve, deny or spawn, and nothing
# on a team another lead founded (that is its founder's) or on one whose lead runs (that is its lead's).
# Each act is written to the project's steward.jsonl BEFORE it happens, and not done when that line cannot be
# written; you are told, and the event log names the steward.
STEWARD_HINT="you are the orphan steward: once its lead has stopped you may restart its lead or stop its agents"

# orphan_steward: the team policy orphan-steward names, empty when it is off
orphan_steward() {
  local team
  team="$(policy_get orphan-steward)"
  [ "$team" = "off" ] || printf '%s\n' "$team"
}

# is_steward: the caller is the lead of the steward team, and the loaded team is another one, founded by you
is_steward() {
  local steward own
  caller_require_proven
  [ "$(caller_role)" = "$WOLFMUX_LEAD_ROLE" ] || return 1
  steward="$(orphan_steward)"
  [ -n "$steward" ] || return 1
  own="$(caller_team)"
  [ "${own:-$WOLFMUX_DEFAULT_TEAM}" = "$steward" ] && [ "${TEAM:-$WOLFMUX_DEFAULT_TEAM}" != "$steward" ] || return 1
  [ "$(team_founder)" = "operator" ]
}

# steward_command <command> <role>: one of the steward's two: restart of the lead, stop of any agent. `teamctl model`
# goes with restart: it chooses what that restart starts the lead on, and its --now IS a restart.
steward_command() {
  case "$1" in
    restart | model) [ "${2:-}" = "$WOLFMUX_LEAD_ROLE" ] ;;
    stop) [ -n "${2:-}" ] ;;
    *) return 1 ;;
  esac
}

# steward_may_act <command> <role>: is_steward, the command is the steward's, and the loaded team's lead is not running
steward_may_act() {
  steward_command "$1" "${2:-}" && is_steward && ! team_lead_running
}

steward_log_file() { printf '%s/steward.jsonl\n' "$PROJECT_STATE"; }

# steward_begin <command> <role>: the steward is about to act. Who it is goes into STEWARD_ACTING and EVENT_BY,
# and one line into steward.jsonl, once per command (a restart that runs start, or start that runs restart, is
# one act). A line that cannot be written stops the act, as the removal ledger does (lib/reclaim.sh).
steward_begin() {
  local file
  STEWARD_ACTING="$(caller_identity)"
  EVENT_BY="$STEWARD_ACTING"
  [ -z "${STEWARD_RECORDED:-}" ] || return 0
  file="$(steward_log_file)"
  /bin/mkdir -p "$PROJECT_STATE" 2>/dev/null || true
  # The braces are for the redirection: a file that cannot be opened is reported here, in the die below.
  if ! {
    "$JQ_BIN" -cn --arg ts "$(now_iso)" --arg steward "$STEWARD_ACTING" --arg team "${TEAM:-$WOLFMUX_DEFAULT_TEAM}" \
      --arg command "$1" --arg role "${2:-}" '{ts: $ts, steward: $steward, team: $team, command: $command, role: $role}' >>"$file"
  } 2>/dev/null; then
    die "'teamctl $1 ${2:-}' was not done: the steward's record cannot be written ($(short_path "$file")), and an act of the orphan steward that nobody can look up is not made."
  fi
  STEWARD_RECORDED=1
}

# founder_announce <what it did>: set by require_manager / cmd_start when a founder or the orphan steward acts: you
# are told, the way founding a team is told, and the event log says who acted (event_log: by is its identity)
founder_announce() {
  if [ -n "${STEWARD_ACTING:-}" ]; then
    (WOLFMUX_TEAM="$TEAM" notify_deliver "$WOLFMUX_LEAD_MARK $STEWARD_ACTING $1 team '$TEAM', which you founded; its lead was not running." >/dev/null 2>&1) || true
    return 0
  fi
  [ -n "${FOUNDER_ACTING:-}" ] || return 0
  (WOLFMUX_TEAM="$TEAM" notify_deliver "$WOLFMUX_LEAD_MARK $FOUNDER_ACTING $1 team '$TEAM', which it founded (its lead was not running)." >/dev/null 2>&1) || true
}

require_manager() { # <command name> [<role>]
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
  if steward_command "$1" "${2:-}" && is_steward; then
    if ! team_lead_running; then
      steward_begin "$1" "${2:-}"
      return 0
    fi
    hint="; $STEWARD_HINT"
  fi
  die "'teamctl $1' is reserved for the lead of team '${TEAM:-$WOLFMUX_DEFAULT_TEAM}'. You are '$(team_identity "$(caller_team | sed "s/^\$/$WOLFMUX_DEFAULT_TEAM/")" "$(caller_role)")'$hint. Ask that lead: bd create \"<what you need>\" -t message -a $(team_identity "${TEAM:-$WOLFMUX_DEFAULT_TEAM}" "$WOLFMUX_LEAD_ROLE") -d \"<why>\"" 77
}

# team_orphaned_note: who may act on the loaded team while its lead is not running. "you" is said to you only:
# in an agent's pane it reads as that agent, so an agent is told "the human".
team_orphaned_note() {
  local founder steward note="you"
  caller_is_you || note="the human" # wording only: teamctl status and teams must not refuse anybody
  founder="$(team_founder)"
  if [ "$founder" != "operator" ]; then
    note="$note, $founder (its founder)"
  else
    steward="$(orphan_steward)"
    if [ -n "$steward" ] && [ "$steward" != "${TEAM:-$WOLFMUX_DEFAULT_TEAM}" ]; then note="$note, $(team_identity "$steward" "$WOLFMUX_LEAD_ROLE") (steward)"; fi
  fi
  printf 'orphaned: its lead is not running. May act on it: %s.' "$note"
}

policy_summary() {
  printf 'lead: %s · workers: %s · worker spawning: %s · worker isolation: %s\n' \
    "$(policy_get lead-permissions)" "$(policy_get worker-permissions)" "$(policy_get worker-spawn)" "$(policy_get worker-isolation)"
}

# teamctl policy [<key> <value>]
cmd_policy() {
  local key="${1:-}" value="${2:-}" template teams
  require_tools
  # orphan-steward and lead-model are the project's, not a team's: they are set without naming a team.
  if [ "$key" = "orphan-steward" ] || [ "$key" = "lead-model" ] || [ "$key" = "team-memory" ]; then load_project any; else load_project; fi
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
    say "  orphan-steward      $(policy_get orphan-steward)       (<team>|off)      for the whole project: the team whose lead may restart the lead of a team"
    say "                      you founded, or stop its agents, while that lead is not running. Nothing else. Yours alone to change."
    say "  lead-model          $(policy_get lead-model)      (<model>|default) for the whole project: what a NEW lead starts on when"
    say "                      teamctl start names no model. Fable only when asked: teamctl start fable · teamctl model lead fable."
    say "                      A running team's lead keeps its own recorded model (teamctl model). Yours alone to change."
    say "  team-memory         $(policy_get team-memory)       (<team>|off)      for the whole project: the one team whose lead keeps a private memory"
    say "                      folder (teamctl memory status). Yours alone to turn on; that lead may turn it off. Nothing is ever deleted by it."
    say "  restore-on-limit   $(policy_get restore-on-limit)    (report|<model>)  teamctl restore and a lead that comes back to a used-up model limit:"
    say "                      report = name it at the end, change nothing · a model (opus…) = restart that lead on it"
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
  # Who may bring back the teams the human founded is the human's call, and the steward's own lead is the
  # last one who should decide that it is the steward.
  if [ "$key" = "orphan-steward" ]; then
    require_operator "policy orphan-steward" "every team the human founded in this project (which team's lead may restart or stop them)" \
      "nothing to set: if a team the human founded needs bringing back, tell the human"
    policy_valid "$key" "$value" || die_usage "orphan-steward must be $(policy_choices "$key")"
    if [ "$value" != "off" ]; then
      teams="$(team_list | tr '\n' ' ')" # in a variable: no pipe for a grep -q to close under pipefail
      case " $teams " in
        *" $value "*) ;;
        *) die_usage "orphan-steward: '$value' is not a team of this project (teams: ${teams% })" ;;
      esac
    fi
    policy_set "$key" "$value"
    event_log policy "" "$key=$value"
    say "policy: $key = $value   (for the whole project)"
    return 0
  fi
  # Which lead keeps notes no team can see is the human's call; turning it off only narrows, so the memory team's own
  # lead may do that too. The same path as teamctl memory enable / disable (lib/memory.sh), folder and log included.
  if [ "$key" = "team-memory" ]; then
    policy_valid "$key" "$value" || die_usage "team-memory must be $(policy_choices "$key")"
    memory_policy_set "$value"
    return 0
  fi
  # What every new lead of the project runs on is the human's call, as orphan-steward is: one team's lead would be
  # choosing the model of leads that are not its own.
  if [ "$key" = "lead-model" ]; then
    require_operator "policy lead-model" "every team of this project (the model each new lead starts on)" \
      "teamctl model lead <model> changes your own team's lead, at its next restart (or --now)"
    if [ "$value" != "default" ]; then
      policy_valid "$key" "$value" || die_usage "lead-model must be $(policy_choices "$key") (known: $WOLFMUX_MODEL_KEYS)"
    fi
    policy_set "$key" "$value"
    event_log policy "" "$key=$value"
    say "policy: lead-model = $(policy_get lead-model)   (for the whole project: what a new lead starts on; a running lead keeps its own: teamctl model lead <model>)"
    return 0
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
