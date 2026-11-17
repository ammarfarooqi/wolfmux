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
#   worker-context      full | trim | lean  what of YOUR Claude Code setup a worker's conversation starts
#                                           with. full = all of it (plugins, their skills, agents and
#                                           hooks, your rules). trim = your rules and settings, no
#                                           plugins. lean = the project's own instructions and
#                                           wolfmux's, nothing from ~/.claude. See worker_context_*
#                                           below for what that costs and saves.
#   lead-context        full | trim         DEFAULT full: the lead starts with everything of yours, as before
#                                           v1.25.0. trim = the reductions a trimmed worker gets (the tools a
#                                           pane agent cannot use, the claude.ai connectors, context-exclude),
#                                           except that it keeps AskUserQuestion and your plugins.
#   context-exclude     <glob>...           instruction files (CLAUDE.md, rules) that a trimmed agent does
#                                           not load: workers under trim and lean, the lead under
#                                           lead-context trim. Empty by default: nothing of yours is left
#                                           out unless you name it. Free text, handled apart below.
#   output-offload      on | off            DEFAULT on. A Bash call's long output goes to a log and
#                                           the agent sees a shortened form with the path
#                                           (lib/offload.sh, ADR-0036), lead and workers alike. Off:
#                                           not one hook entry of it is registered.
#   worker-rotation     off | ask | auto    DEFAULT auto. A worker with a task in_progress that ends a
#                                           turn at or past its rotate threshold, or thrashes, gets a
#                                           fresh conversation with a hand-over (lib/rotate.sh,
#                                           ADR-0039). ask: the lead is sent the command. off: told only.
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
#                                           Typing only: under both values the Stop hook says
#                                           nothing in a watched pane (v1.22.1).
#                                           Only you may change it, never an agent: it is about
#                                           your own screen (require_operator).
#   lead-wake           unwatched | off     DEFAULT unwatched (v1.23.0, issue #34). May an IDLE
#                                           Claude-family lead wake ITSELF when a notice arrives
#                                           and nobody is using its pane (not focused, no key for
#                                           WOLFMUX_WATCH_QUIET seconds)? unwatched = yes: a waiter
#                                           hook (teamctl _inbox-wake, lib/inbox.sh) hands the
#                                           notices over and the lead takes a turn; nothing is
#                                           typed. off = the v1.22.1 answer: it gets them at its
#                                           next turn end or prompt. Only you may change it, never
#                                           an agent (require_operator).
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

POLICY_KEYS="lead-permissions worker-permissions browser-writes worker-spawn worker-isolation worker-context lead-context context-exclude lead-teams disk-guard disk-min-gb link-node-modules auto-prune auto-reclaim branch-template human-pane-typing lead-wake orphan-steward lead-model team-memory restore-on-limit output-offload worker-rotation"

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
    worker-context) printf '%s\n' "${WOLFMUX_WORKER_CONTEXT:-trim}" ;;
    worker-rotation) printf '%s\n' "${WOLFMUX_WORKER_ROTATION:-auto}" ;;
    lead-context) printf '%s\n' "${WOLFMUX_LEAD_CONTEXT:-full}" ;;
    context-exclude) printf '%s\n' "${WOLFMUX_CONTEXT_EXCLUDE:-}" ;;
    branch-template) printf '%s\n' "${WOLFMUX_BRANCH_TEMPLATE:-}" ;;
    human-pane-typing) printf '%s\n' "${WOLFMUX_HUMAN_PANE_TYPING:-off}" ;;
    lead-wake) printf '%s\n' "${WOLFMUX_LEAD_WAKE:-unwatched}" ;;
    orphan-steward) printf '%s\n' "${WOLFMUX_ORPHAN_STEWARD:-off}" ;;
    lead-model) printf '%s\n' "${WOLFMUX_LEAD_MODEL:-opus}" ;;
    team-memory) printf 'off\n' ;; # no setting: only `teamctl memory enable` turns it on
    restore-on-limit) printf '%s\n' "${WOLFMUX_RESTORE_ON_LIMIT:-report}" ;;
    output-offload) printf '%s\n' "${WOLFMUX_OUTPUT_OFFLOAD:-on}" ;;
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
  if [ "$1" = "context-exclude" ]; then
    context_exclude_valid "$2"
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
    output-offload:on | output-offload:off) return 0 ;;
    human-pane-typing:off | human-pane-typing:idle) return 0 ;;
    lead-wake:unwatched | lead-wake:off) return 0 ;;
    # A number, not a word: whole gigabytes, 0 switches the limit off, and the ceiling is
    # only there so that a slip of the hand cannot refuse every spawn for ever.
    # A leading zero is refused on purpose. `test -le` reads base ten but shell arithmetic
    # reads 08 as octal and aborts, so "disk-min-gb 08" used to break every spawn in the
    # team with a raw bash error, and "010" quietly enforced 8 GB while printing 010.
    disk-min-gb:*)
      case "$2" in "" | *[!${_WM_DIGITS}]* | 0?*) return 1 ;; esac
      [ "$2" -le 10000 ]
      ;;
    worker-context:full | worker-context:trim | worker-context:lean) return 0 ;;
    worker-rotation:off | worker-rotation:ask | worker-rotation:auto) return 0 ;;
    lead-context:full | lead-context:trim) return 0 ;;
    *) return 1 ;;
  esac
}

policy_choices() {
  case "$1" in
    lead-permissions) printf 'skip|ask\n' ;;
    worker-permissions) printf 'skip|lead|ask\n' ;;
    browser-writes) printf 'ask|allow\n' ;;
    worker-spawn | worker-isolation | lead-teams | link-node-modules | auto-prune | auto-reclaim | output-offload) printf 'on|off\n' ;;
    worker-context) printf 'full|trim|lean\n' ;;
    worker-rotation) printf 'off|ask|auto\n' ;;
    lead-context) printf 'full|trim\n' ;;
    context-exclude) printf "one or more globs of instruction files ('**/rules/pack/zh/**'), or the word none\n" ;;
    disk-guard) printf 'refuse|warn|off\n' ;;
    human-pane-typing) printf 'off|idle\n' ;;
    lead-wake) printf 'unwatched|off\n' ;;
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
  if [ "$key" = "context-exclude" ]; then
    # Empty, or anything that is not a list of globs, means nothing is left out: an unreadable
    # value must never take an instruction file of yours away from an agent.
    if [ -n "$value" ] && context_exclude_valid "$value"; then printf '%s\n' "$value"; fi
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
  elif [ "$key" = "lead-wake" ]; then
    # Unreadable means the default. The wake types nothing into any pane, and off would leave
    # an idle lead deaf to its team again (issue #34): a typo must not bring that back.
    printf 'unwatched\n'
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
  elif [ "$key" = "worker-context" ] || [ "$key" = "lead-context" ]; then
    printf 'full\n' # an unreadable value never takes something of yours away from an agent
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
  # context-exclude none: back to leaving nothing out. Stored as no list at all, as branch-template is.
  if [ "$1" = "context-exclude" ]; then
    if [ "$2" = "none" ]; then
      meta_put policy_context_exclude ""
      return 0
    fi
    context_exclude_valid "$2" || die_usage "context-exclude must be $(policy_choices context-exclude)
a glob may hold letters, digits and . _ / * ? ~ @ + - only, at most $CONTEXT_EXCLUDE_MAX of them"
    meta_put policy_context_exclude "$2"
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
  local lead ask
  lead="$(team_identity "${TEAM:-$WOLFMUX_DEFAULT_TEAM}" "$WOLFMUX_LEAD_ROLE")"
  if [ "$(store_kind 2>/dev/null || printf beads)" = "native" ]; then
    ask="teamctl send $lead \"<what you need>\" \"<why>\""
  else
    ask="bd create \"<what you need>\" -t message -a $lead -d \"<why>\""
  fi
  die "'teamctl $1' is reserved for the lead of team '${TEAM:-$WOLFMUX_DEFAULT_TEAM}'. You are '$(team_identity "$(caller_team | sed "s/^\$/$WOLFMUX_DEFAULT_TEAM/")" "$(caller_role)")'$hint. Ask that lead: $ask" 77
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
  printf 'lead: %s · workers: %s · worker spawning: %s · worker isolation: %s · worker context: %s\n' \
    "$(policy_get lead-permissions)" "$(policy_get worker-permissions)" "$(policy_get worker-spawn)" "$(policy_get worker-isolation)" "$(policy_get worker-context)"
}

# --- worker-context: what a worker's conversation starts with ----------------------------
# Measured on the owner's machine (Claude Code 2.1.323, 2026-11-13): a worker's FIRST request was
# 111,000 tokens before it had read its task, more than half of a 200k window, and every later
# request carries it. About 60,000 of that were the listings and session hooks of nine plugins,
# about 30,000 the rules in ~/.claude; the worker used almost none of it. A `claude -p` probe:
# full 85,700 tokens, plugins off 56,500, nothing from ~/.claude 19,000.
#   full  everything, as before v1.24.0
#   trim  (default) your rules and settings stay; every plugin is off for the worker
#   lean  only the project's own instructions (its CLAUDE.md, .claude/) and wolfmux's
# The lead is not trimmed unless you say so (lead-context trim): it is the conversation you talk to.
#
# v1.25.0, measured on Claude Code 2.1.325 (2026-11-16, docs/adr/0037): a trimmed worker still began
# at 81,024 tokens. Three more things it never uses went with every request:
#   - the schemas of tools a pane agent cannot use (WOLFMUX_PANE_UNUSED_TOOLS; Artifact alone is
#     37,000 characters). A bare tool name in permissions.deny takes the tool out of the request.
#   - the claude.ai connectors of your account: they connect after the first request and then add
#     their tool names and instructions (36,879 characters in a two-line task).
#   - instruction files you name with context-exclude (a second-language copy of your rules).
# With all three: 54,289. full keeps every one of them.

# The tools of Claude Code that an agent in a pane has no use for: they publish a page, ask a
# dialog nobody is watching, send feedback, schedule a wake-up or start a second agent system.
# AskUserQuestion is the lead's way to ask you, so a trimmed lead keeps it.
WOLFMUX_PANE_UNUSED_TOOLS="Artifact AskUserQuestion SendFeedback ScheduleWakeup Workflow ReportFindings ListAgents"
CONTEXT_EXCLUDE_MAX=16 # globs in one context-exclude list

# context_exclude_valid <list>: one to CONTEXT_EXCLUDE_MAX globs, separated by spaces, each made
# of the characters a path and a glob need and nothing a shell or JSON would read otherwise.
context_exclude_valid() {
  local glob count=0
  [ -n "$1" ] || return 1
  set -f # the globs are words here, never patterns to expand against this directory
  for glob in $1; do
    count=$((count + 1))
    case "$glob" in
      *[!A-Za-z0-9._/*?~@+-]*) set +f; return 1 ;;
    esac
    if [ "${#glob}" -gt 200 ]; then set +f; return 1; fi
  done
  set +f
  [ "$count" -ge 1 ] && [ "$count" -le "$CONTEXT_EXCLUDE_MAX" ]
}

# context_reductions <kind>: the settings fragment of the three reductions above, for a trimmed
# worker or a trimmed lead ({} when jq fails: a reduction that cannot be written is not made)
context_reductions() {
  local tools="$WOLFMUX_PANE_UNUSED_TOOLS" exclude
  if [ "$1" = "lead" ]; then tools="${tools/AskUserQuestion /}"; fi
  exclude="$(policy_get context-exclude)"
  "$JQ_BIN" -cn --arg tools "$tools" --arg exclude "$exclude" '
    {permissions: {deny: ($tools | split(" ") | map(select(length > 0)))},
     env: {ENABLE_CLAUDEAI_MCP_SERVERS: "false"}}
    + (($exclude | split(" ") | map(select(length > 0))) as $globs
       | if ($globs | length) > 0 then {claudeMdExcludes: $globs} else {} end)' 2>/dev/null || printf '{}\n'
}

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

# --- one context number, and a window that cannot thrash (ADR-0038) ---------------------------
# The reserve: Claude Code compacts a conversation at about its window MINUS this many tokens.
# Observed on two windows of Claude Code 2.1.325 (165-171k of 200k, 66-89k of 100k), in line with
# the vendor's "about 967k of 1M", and stated by the vendor nowhere. Environment only, for a test.
WOLFMUX_COMPACT_RESERVE="${WOLFMUX_COMPACT_RESERVE:-33000}"
# What a worker's window is made of: its first request F (the part re-sent with every request),
# what a compaction keeps K, the reserve, and room to work in. F and K are measured by the watch
# (lib/recall.sh) and kept per team in $STATE_DIR/context/worker; until then these stand in. Both
# err high: a window too large costs one later compaction, a window too small thrashes.
WOLFMUX_CONTEXT_FIRST="${WOLFMUX_CONTEXT_FIRST:-90000}" # F with nothing measured (measured: 54k trimmed, 81k full)
WOLFMUX_CONTEXT_KEPT="${WOLFMUX_CONTEXT_KEPT:-45000}"   # K, and its floor: one agent's compactions kept 19k to 47k
WOLFMUX_CONTEXT_ROOM="${WOLFMUX_CONTEXT_ROOM:-150000}"  # room to work in between two compactions (config file)
# Under this much room after a compaction the CLI compacts again within a few requests (measured:
# 4-5k of room, 10 compactions in 5 minutes, then the CLI stops). One file read is up to 25k.
WOLFMUX_CONTEXT_MIN_ROOM="${WOLFMUX_CONTEXT_MIN_ROOM:-30000}"

# _ctx_number <value> <default> - <value> when it is a plain number of at most 9 digits, else <default>
_ctx_number() {
  case "$1" in "" | *[!0-9]*) printf '%s\n' "$2"; return 0 ;; esac
  if [ "${#1}" -le 9 ]; then printf '%s\n' "$((10#$1))"; else printf '%s\n' "$2"; fi
}

# context_limit <window> - where a CLI with that window compacts: the window minus the reserve.
# Nothing for a window that is not a number above the reserve.
context_limit() {
  case "${1:-}" in "" | *[!0-9]*) return 0 ;; esac
  [ "${#1}" -le 9 ] && [ "$1" -gt "$WOLFMUX_COMPACT_RESERVE" ] || return 0
  printf '%s\n' "$(($1 - WOLFMUX_COMPACT_RESERVE))"
}

# context_limit_for <family> <model-window> <compact-window> - sets CTX_LIMIT, the ONE number every
# view and the watch divide by ("" = unknown, and then nothing is divided). Claude Code: the
# smaller of the window its CLI was told to compact at and its model's window, minus the reserve.
# Codex states its own window in its rollout and nothing here measured where it compacts: its
# limit is that window, unreduced. No fork: status calls this once per agent.
context_limit_for() {
  local window="${2:-}" compact="${3:-}"
  CTX_LIMIT=""
  case "$window" in "" | 0 | *[!0-9]*) window="" ;; esac
  case "$compact" in "" | 0 | *[!0-9]*) compact="" ;; esac
  [ "${#window}" -le 9 ] || window=""
  [ "${#compact}" -le 9 ] || compact=""
  if [ "$1" = "codex" ]; then
    CTX_LIMIT="$window"
    return 0
  fi
  # A model whose window nobody declared has no limit, whatever its CLI was told: the CLI caps the
  # compact window at the model's own, so the number on record is only an upper bound.
  [ -n "$window" ] || return 0
  if [ -n "$compact" ] && [ "$compact" -lt "$window" ]; then window="$compact"; fi
  [ "$window" -gt "$WOLFMUX_COMPACT_RESERVE" ] || return 0
  CTX_LIMIT="$((window - WOLFMUX_COMPACT_RESERVE))"
}

# context_measured <state-dir> <kind> - sets CM_FIRST and CM_KEPT ("" = never measured) from what
# the watch last recorded for an agent of that kind in this team: one line "first kept epoch role".
# It outlives the agent that measured it, so a NEW worker starts from a measured F.
context_measured() {
  local first="" kept="" rest=""
  CM_FIRST="" CM_KEPT=""
  [ -r "$1/context/$2" ] || return 0
  IFS=' ' read -r first kept rest <"$1/context/$2" || true
  case "$first" in "" | 0 | *[!0-9]*) ;; *) [ "${#first}" -gt 9 ] || CM_FIRST="$first" ;; esac
  case "$kept" in "" | 0 | *[!0-9]*) ;; *) [ "${#kept}" -gt 9 ] || CM_KEPT="$kept" ;; esac
  return 0
}

# worker_compact_plan <model-key> <override> - sets WCP_WINDOW: the token count a worker's CLI is
# told to compact its conversation at (CLAUDE_CODE_AUTO_COMPACT_WINDOW; "" = left to the CLI), and
# WCP_NOTE: one sentence when the window is not the one asked for ("" otherwise).
#   <override>  off: left to the CLI. A number from 100000 to 1000000 (what the CLI accepts): that
#               window. Anything else: none.
#   no override F + K + reserve + WOLFMUX_CONTEXT_ROOM, from what was measured (context_measured).
# Either way the window is at least F + K + reserve + WOLFMUX_CONTEXT_MIN_ROOM, so that a
# compaction leaves room to work in, and at most the model's own window (the CLI caps it there
# anyway). A model whose window nobody declared gets a window only when one was asked for.
# Needs STATE_DIR. The CLI reads the window when it starts: it is computed at spawn and restart.
worker_compact_plan() {
  local model="$1" want="${2:-}" cap first kept floor window="" asked=""
  WCP_WINDOW="" WCP_NOTE="" WCP_FIRST="" WCP_KEPT=""
  [ "$want" != "off" ] || return 0
  cap="$(model_context_window "$model" 2>/dev/null || true)"
  cap="$(_ctx_number "$cap" "")"
  if [ -n "$cap" ] && [ "$cap" -gt 1000000 ]; then cap=1000000; fi
  if [ -n "$cap" ] && [ "$cap" -lt 100000 ]; then return 0; fi
  case "$want" in
    "") ;;
    *[!0-9]*) WCP_NOTE="WOLFMUX_WORKER_COMPACT_WINDOW=$want is neither off nor a number: ignored." ;;
    *)
      if [ "${#want}" -le 7 ] && [ "$want" -ge 100000 ] && [ "$want" -le 1000000 ]; then
        asked="$want"
      else
        WCP_NOTE="WOLFMUX_WORKER_COMPACT_WINDOW=$want is outside 100000 to 1000000, what the CLI accepts: ignored."
      fi
      ;;
  esac
  [ -n "$cap" ] || [ -n "$asked" ] || return 0
  context_measured "${STATE_DIR:-}" worker
  first="$(_ctx_number "${CM_FIRST:-}" "$(_ctx_number "$WOLFMUX_CONTEXT_FIRST" 90000)")"
  kept="$(_ctx_number "$WOLFMUX_CONTEXT_KEPT" 45000)"
  if [ -n "$CM_KEPT" ] && [ "$CM_KEPT" -gt "$kept" ]; then kept="$CM_KEPT"; fi
  WCP_FIRST="$first" WCP_KEPT="$kept"
  floor=$((first + kept + WOLFMUX_COMPACT_RESERVE + $(_ctx_number "$WOLFMUX_CONTEXT_MIN_ROOM" 30000)))
  window="${asked:-$((first + kept + WOLFMUX_COMPACT_RESERVE + $(_ctx_number "$WOLFMUX_CONTEXT_ROOM" 150000)))}"
  if [ "$window" -lt "$floor" ]; then
    WCP_NOTE="compact window $floor, not ${asked:-$window}: a limit of $((${asked:-$window} - WOLFMUX_COMPACT_RESERVE)) tokens leaves under $(_ctx_number "$WOLFMUX_CONTEXT_MIN_ROOM" 30000) after a compaction (first request $first + kept $kept), and the CLI would compact over and over."
    window="$floor"
  fi
  window=$((((window + 999) / 1000) * 1000))
  [ "$window" -ge 100000 ] || window=100000
  [ "$window" -le 1000000 ] || window=1000000
  if [ -n "$cap" ] && [ "$window" -gt "$cap" ]; then
    window="$cap"
    if [ "$cap" -lt "$floor" ]; then
      WCP_NOTE="compact window $cap, the model's own: after a compaction only about $((cap - WOLFMUX_COMPACT_RESERVE - first - kept)) tokens are left to work in (first request $first + kept $kept). Expect compactions close together; a smaller start helps (teamctl policy worker-context, context-exclude)."
    fi
  fi
  WCP_WINDOW="$window"
}

# worker_compact_window <model-key> [<override>] - prints worker_compact_plan's window, or nothing.
# The override defaults to WOLFMUX_WORKER_COMPACT_WINDOW of this process.
worker_compact_window() {
  worker_compact_plan "$1" "${2-${WOLFMUX_WORKER_COMPACT_WINDOW:-}}"
  [ -z "$WCP_WINDOW" ] || printf '%s\n' "$WCP_WINDOW"
}

# worker_context_carried — what a lean worker loses together with your user settings and then
# stops on: your own, already recorded, acceptance of bypass-permissions mode. Without it a
# lean worker in skip mode sits at the CLI's "Yes, I accept" dialog and never reads its task
# (seen against Claude Code 2.1.325). Carried only when your settings say so, never invented:
# someone who has not accepted that mode is still asked.
worker_context_carried() {
  local f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
  if [ -r "$f" ] && "$JQ_BIN" -e '.skipDangerousModePermissionPrompt == true' "$f" >/dev/null 2>&1; then
    printf '{"skipDangerousModePermissionPrompt":true}\n'
  else
    printf '{}\n'
  fi
}

# worker_context_settings <kind> <mode>: the fragment write_agent_settings merges in for a
# worker. full: nothing. trim: your plugins off and the reductions. lean: that, and what a
# worker without your user settings needs carried over.
worker_context_settings() {
  if [ "$1" != "worker" ] || [ "$2" = "full" ]; then
    printf '{}\n'
    return 0
  fi
  {
    worker_context_plugins_off
    context_reductions worker
    if [ "$2" = "lean" ]; then worker_context_carried; fi
  } | "$JQ_BIN" -cs 'reduce .[] as $part ({}; . * $part)' 2>/dev/null || printf '{}\n'
}

# agent_context_settings <kind>: what write_agent_settings merges in for any agent: a worker by
# worker-context, the lead by lead-context (full: nothing; trim: the reductions, plugins untouched).
agent_context_settings() {
  if [ "$1" = "worker" ]; then
    worker_context_settings worker "$(policy_get worker-context)"
  elif [ "$1" = "lead" ] && [ "$(policy_get lead-context)" = "trim" ]; then
    context_reductions lead
  else
    printf '{}\n'
  fi
}

# teamctl policy [<key> <value>]
cmd_policy() {
  local key="${1:-}" value="${2:-}" template teams exclude
  # context-exclude takes a list: every further word is one more glob
  if [ "$key" = "context-exclude" ] && [ "$#" -gt 2 ]; then
    shift
    value="$*"
  fi
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
    say "  worker-context      $(policy_get worker-context)    (full|trim|lean)  what of your ~/.claude a worker starts with: full = all,"
    say "                      trim = your rules, no plugins, no tools a pane cannot use, no claude.ai connectors ·"
    say "                      lean = only the project's own instructions and wolfmux's"
    say "  lead-context        $(policy_get lead-context)    (full|trim)       what the lead starts with: full = everything of yours ·"
    say "                      trim = without the tools a pane cannot use (it keeps AskUserQuestion), the claude.ai"
    say "                      connectors and the files of context-exclude. Your plugins stay."
    exclude="$(policy_get context-exclude)"
    say "  context-exclude     ${exclude:-none}    (<glob>...|none)  instruction files (CLAUDE.md, rules) a trimmed agent does not load:"
    say "                      workers under trim and lean, the lead under lead-context trim. teamctl doctor names a"
    say "                      rules folder that repeats another one in a second language, with the line to use."
    say "  lead-teams          $(policy_get lead-teams)      (on|off)          may the lead found further teams and hand work over?"
    say "  disk-guard          $(policy_get disk-guard)  (refuse|warn|off) what 'teamctl spawn' does under disk-min-gb free disk"
    say "  disk-min-gb         $(policy_get disk-min-gb)       (number, GB)      free space a spawn asks for; 0 = no limit"
    say "  link-node-modules   $(policy_get link-node-modules)     (on|off)          link a new lane's node_modules to its repository's copy"
    say "  auto-prune          $(policy_get auto-prune)      (on|off)          sweep a lane's build output as soon as it is parked (protect one: teamctl keep <role>)"
    say "  auto-reclaim        $(policy_get auto-reclaim)      (on|off)          take a parked lane off the books once its task is closed and its work is all in main (protect one: teamctl keep <role>)"
    say "  output-offload      $(policy_get output-offload)      (on|off)          a long Bash output goes to a log; the agent sees head, tail, failure lines and the path"
    say "  worker-rotation     $(policy_get worker-rotation)    (off|ask|auto)    a worker near its limit gets a fresh conversation with a hand-over at its turn end (ask: you get the command)"
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
    say "  lead-wake           $(policy_get lead-wake) (unwatched|off)  may an idle lead wake itself for a notice while nobody is using its pane"
    say "                      (no focus, no key for ${WOLFMUX_WATCH_QUIET:-120}s)? Nothing is typed. off = it waits for its next turn end or prompt. Yours alone."
    say "  orphan-steward      $(policy_get orphan-steward)       (<team>|off)      for the whole project: the team whose lead may restart the lead of a team"
    say "                      you founded, or stop its agents, while that lead is not running. Nothing else. Yours alone to change."
    say "  lead-model          $(policy_get lead-model)      (<model>|default) for the whole project: what a NEW lead starts on when"
    say "                      teamctl start names no model. Fable only when asked: teamctl start fable · teamctl model lead fable."
    say "                      A running team's lead keeps its own recorded model (teamctl model). Yours alone to change."
    say "  team-memory         $(policy_get team-memory)       (<team>|off)      for the whole project: the one team whose lead keeps a private memory"
    say "                      folder (teamctl memory status). Yours alone to turn on; that lead may turn it off. Nothing is ever deleted by it."
    say "  restore-on-limit    $(policy_get restore-on-limit)    (report|<model>)  teamctl restore and a lead that comes back to a used-up model limit:"
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
  # Whether an idle lead takes a turn by itself is the human's call too: each wake is a model
  # request, and the lead it wakes may be the one asking.
  if [ "$key" = "lead-wake" ]; then
    require_operator "policy lead-wake" "this team's lead (may it take a turn by itself for a notice while it is idle)" \
      "nothing to change: your notices reach you through your own hooks. If that is not enough, tell the human"
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
  elif [ "$key" = "context-exclude" ]; then
    exclude="$(policy_get context-exclude)"
    say "policy: context-exclude = ${exclude:-none}   (workers under trim and lean; the lead under lead-context trim)"
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
