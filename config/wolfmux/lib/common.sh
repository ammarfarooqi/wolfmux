#!/bin/bash
# common.sh — output helpers, validation, tool lookup, model table, project resolution.
# Compatible with macOS /bin/bash 3.2 (no associative arrays, no mapfile, no ${var,,}).

WOLFMUX_VERSION="1.11.0"
WOLFMUX_HOME="${WOLFMUX_HOME:-$HOME/.config/wolfmux}"
WOLFMUX_DATA="${WOLFMUX_DATA:-$HOME/.wolfmux}"
# This project was first called "ai-team". A team started under that name keeps
# running on a tmux server with the old socket name until its last session ends;
# teamctl follows it there (tm_adopt_legacy_server) unless a socket was chosen explicitly.
if [ -z "${WOLFMUX_TMUX_SOCKET:-}" ]; then
  WOLFMUX_TMUX_SOCKET="wolfmux"
  WOLFMUX_ADOPT_LEGACY="${WOLFMUX_ADOPT_LEGACY:-1}"
fi
WOLFMUX_LEGACY_SOCKET="${WOLFMUX_LEGACY_SOCKET:-ai-team}"
WOLFMUX_OWN_SOCKET="$WOLFMUX_TMUX_SOCKET" # what we go back to once the old-name server has ended
WOLFMUX_BIN_DIR="${WOLFMUX_BIN_DIR:-$HOME/bin}"
WOLFMUX_WINDOW="team"
WOLFMUX_LEAD_ROLE="lead"

# --- output ------------------------------------------------------------------
if [ -t 2 ]; then
  _C_RED=$'\033[31m' _C_YEL=$'\033[33m' _C_GRN=$'\033[32m' _C_DIM=$'\033[2m' _C_BLD=$'\033[1m' _C_OFF=$'\033[0m'
else
  _C_RED="" _C_YEL="" _C_GRN="" _C_DIM="" _C_BLD="" _C_OFF=""
fi

# A closed pipe (`teamctl spawn ... | head -1`) must not turn finished work into
# an error exit under `set -e`.
say() { printf '%s\n' "$*" 2>/dev/null || true; }
info() { printf '%s\n' "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$_C_YEL" "$_C_OFF" "$*" >&2; }
die() {
  printf '%steamctl:%s %s\n' "$_C_RED" "$_C_OFF" "$1" >&2
  exit "${2:-1}"
}
# teamctl_on_exit — the EXIT trap. Releases the project lock, and never lets a crash pass in
# silence: set -e ends teamctl on the first failing command, and when that command was killed
# by a signal (SIGPIPE: exit 141) nothing had printed a word (issue #6). Ctrl-C (130) is you,
# a hangup (129) is a closed terminal: `destroy` run inside the team it ends closes its own pane.
teamctl_on_exit() {
  local rc=$?
  lock_release 2>/dev/null || true
  if [ "$rc" -gt 128 ] && [ "$rc" -ne 130 ] && [ "$rc" -ne 129 ]; then
    printf '%steamctl:%s stopped unexpectedly (exit %s: signal %s) in: teamctl %s\nIt ended before it finished: check what it had done (teamctl status), then report this line.\n' \
      "$_C_RED" "$_C_OFF" "$rc" "$((rc - 128))" "${TEAMCTL_ARGS:-}" >&2 2>/dev/null || true
  fi
}
# die_usage "<message>" — wrong invocation (exit 64, EX_USAGE)
die_usage() {
  printf '%steamctl:%s %s\n' "$_C_RED" "$_C_OFF" "$1" >&2
  exit 64
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_stamp() { date +%Y%m%d-%H%M%S; }
now_epoch() { date +%s; }

# --- tools -------------------------------------------------------------------
# find_tool <name> [fallback path...] — PATH first, then known install locations,
# because a pane or an agent's shell may carry a shorter PATH than your terminal.
find_tool() {
  local name="$1" found candidate
  shift
  found="$(command -v "$name" 2>/dev/null || true)"
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    return 0
  fi
  for candidate in "$@"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

TMUX_BIN="$(find_tool tmux /opt/homebrew/bin/tmux /usr/local/bin/tmux || true)"
GIT_BIN="$(find_tool git /usr/bin/git /opt/homebrew/bin/git || true)"
JQ_BIN="$(find_tool jq /usr/bin/jq /opt/homebrew/bin/jq || true)"
BD_BIN="$(find_tool bd "$HOME/.local/bin/bd" /opt/homebrew/bin/bd /usr/local/bin/bd || true)"

require_tools() {
  local missing=""
  [ -n "$TMUX_BIN" ] || missing="$missing tmux"
  [ -n "$GIT_BIN" ] || missing="$missing git"
  [ -n "$JQ_BIN" ] || missing="$missing jq"
  [ -z "$missing" ] || die "required tool(s) not found:$missing  (run: teamctl doctor)"
}

# --- validation --------------------------------------------------------------
# Role names end up in branch names, file names and tmux targets.
# Alphabets are spelled out: a range such as [a-z] follows the locale's collation, and
# under en_AU.UTF-8 it matches capitals (a lead once spawned "Riley-pr-reviewer").
_WM_LOWER="abcdefghijklmnopqrstuvwxyz"
_WM_UPPER="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
_WM_DIGITS="0123456789"

# valid_role — a NEW role: lowercase letters, digits, hyphens, at most 32
valid_role() {
  case "$1" in
    "" | *[!${_WM_LOWER}${_WM_DIGITS}-]* | -* | *-) return 1 ;;
  esac
  [ "${#1}" -le 32 ]
}

# known_role_name — may name an agent that already exists. Capitals are tolerated here
# (older versions let them through); anything that could leave the registry directory
# or disturb a line typed into a pane is not.
known_role_name() {
  case "$1" in
    "" | *[!${_WM_LOWER}${_WM_UPPER}${_WM_DIGITS}-]* | -* | *-) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

require_role_arg() {
  [ -n "${1:-}" ] || die_usage "missing <role>"
  known_role_name "$1" || die_usage "invalid role '$1' (letters, digits and '-')"
}

require_new_role_arg() {
  [ -n "${1:-}" ] || die_usage "missing <role>"
  valid_role "$1" || die_usage "invalid role '$1' (use lowercase letters, digits and '-', max 32 chars)"
}

# A ticket key ends up in a branch name (teamctl spawn --ticket AFD-1844), so it is kept
# to an alphabet git and every hook we know of accept. Capitals are the norm for Jira keys.
valid_ticket() {
  case "$1" in
    "" | *[!${_WM_LOWER}${_WM_UPPER}${_WM_DIGITS}_-]* | -* | *-) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

# Bead ids are echoed into a pane, so keep them to a harmless alphabet.
valid_bead_id() {
  case "$1" in
    "" | *[!${_WM_LOWER}${_WM_UPPER}${_WM_DIGITS}._-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

# --- model table (the only place that knows which CLI serves which model) -----
# model_info <key> — sets MODEL_KEY MODEL_ID MODEL_LAUNCHER MODEL_LABEL MODEL_FAMILY MODEL_BILLING
# A model is a key from this table, or "claude:<model id>" / "codex:<model id>" for any
# other model of those two subscriptions. (GLM: the Coding Plan covers only the two ids
# behind glm53 and flash, so there is no "glm:<id>".) Every other provider of the provider
# table (lib/providers.sh) is a key of its own, and "<key>:<model id>" where the provider
# lets you name the model. MODEL_BILLING: subscription (Claude, ChatGPT), plan (a coding plan
# with a quota) or metered (every token is billed: off unless WOLFMUX_METERED=on).
valid_model_id() {
  case "$1" in
    "" | *[!${_WM_LOWER}${_WM_UPPER}${_WM_DIGITS}._\[\]-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

# _model_info_provider <key>: "<provider>" or "<provider>:<model id>" for a provider of the
# table other than glm. Returns 1 for anything else, so a typo is refused before anything is created.
_model_info_provider() {
  local provider="${1%%:*}" model_id=""
  [ -n "$provider" ] && [ "$provider" != "glm" ] || return 1
  case " $WOLFMUX_PROVIDERS " in *" $provider "*) ;; *) return 1 ;; esac
  wolfmux_provider_info "$provider" || return 1
  if [ "$1" != "$provider" ]; then
    [ "$PROVIDER_PINNABLE" = "1" ] || return 1
    model_id="${1#*:}"
    valid_model_id "$model_id" || return 1
  fi
  MODEL_ID="$model_id" MODEL_LAUNCHER="claude-$provider" MODEL_FAMILY="claude" MODEL_BILLING="$PROVIDER_BILLING"
  MODEL_LABEL="${model_id:-$PROVIDER_LABEL}"
}

model_info() {
  MODEL_KEY="$1" MODEL_ID="" MODEL_BILLING="subscription"
  case "$1" in
    fable)
      MODEL_LAUNCHER="claude-fable" MODEL_LABEL="Fable 5.1" MODEL_FAMILY="claude"
      ;;
    opus)
      MODEL_LAUNCHER="claude-opus" MODEL_LABEL="Opus 5" MODEL_FAMILY="claude"
      ;;
    sonnet)
      MODEL_LAUNCHER="claude-sonnet" MODEL_LABEL="Sonnet 5" MODEL_FAMILY="claude"
      ;;
    haiku)
      MODEL_LAUNCHER="claude-haiku" MODEL_LABEL="Haiku 4.5" MODEL_FAMILY="claude"
      ;;
    claude:*)
      valid_model_id "${1#claude:}" || return 1
      MODEL_ID="${1#claude:}" MODEL_LAUNCHER="claude-fable" MODEL_LABEL="${1#claude:}" MODEL_FAMILY="claude"
      ;;
    codex:*)
      valid_model_id "${1#codex:}" || return 1
      MODEL_ID="${1#codex:}" MODEL_LAUNCHER="codex-astra" MODEL_LABEL="${1#codex:}" MODEL_FAMILY="codex"
      ;;
    astra)
      MODEL_LAUNCHER="codex-astra" MODEL_LABEL="GPT-6 Astra" MODEL_FAMILY="codex"
      ;;
    glm53)
      MODEL_LAUNCHER="claude-glm" MODEL_LABEL="GLM-5.3" MODEL_FAMILY="claude" MODEL_BILLING="plan"
      ;;
    flash)
      MODEL_LAUNCHER="claude-glm-flash" MODEL_LABEL="GLM-5.3 Flash" MODEL_FAMILY="claude" MODEL_BILLING="plan"
      ;;
    *) _model_info_provider "$1" ;;
  esac
}

# model_context_window <model-key> — the context window, in tokens, that status shows a share of.
# A provider of the table declares its own (PROVIDER_CONTEXT); a model id that ends in [1m]
# means 1M; everything else is counted as 200k. Never fails: the fallback is 200000.
model_context_window() {
  local key="$1" provider="${1%%:*}"
  case " $WOLFMUX_PROVIDERS " in
    *" $provider "*)
      # The row's declared window holds for every id of that provider, pinned or not
      # (glm has no pinned ids; its keys are glm53 and flash, handled below).
      if [ "$key" = "$provider" ] || _model_info_provider "$key" 2>/dev/null; then
        if wolfmux_provider_info "$provider" 2>/dev/null; then
          printf '%s\n' "$PROVIDER_CONTEXT"
          return 0
        fi
      fi
      ;;
  esac
  if model_info "$key" 2>/dev/null; then
    case "${MODEL_ID:-}" in
      *\[1m\]) printf '1048576\n' ;;
      *) printf '200000\n' ;;
    esac
  else
    printf '200000\n'
  fi
}

# What usage lines and "unknown model" errors list: the fixed keys, then whatever the provider
# table holds (so a new provider is named everywhere without editing a string).
WOLFMUX_MODEL_KEYS="glm53 flash fable opus sonnet haiku astra"
for _wm_provider in $WOLFMUX_PROVIDERS; do
  [ "$_wm_provider" = "glm" ] || WOLFMUX_MODEL_KEYS="$WOLFMUX_MODEL_KEYS $_wm_provider"
done
WOLFMUX_MODEL_KEYS="$WOLFMUX_MODEL_KEYS claude:<model-id> codex:<model-id>"
for _wm_provider in $WOLFMUX_PROVIDERS; do
  [ "$_wm_provider" = "glm" ] && continue
  if wolfmux_provider_info "$_wm_provider" && [ "$PROVIDER_PINNABLE" = "1" ]; then
    WOLFMUX_MODEL_KEYS="$WOLFMUX_MODEL_KEYS $_wm_provider:<model-id>"
  fi
done
unset _wm_provider

# require_metered_ok, after model_info: a metered model (every token is billed to a prepaid
# balance) is refused unless the owner's config file says WOLFMUX_METERED=on (wolfmux_metered_on).
# The environment never counts: an agent could put a variable in front of one command, and the
# pane a spawned agent runs in gets its environment from the tmux server, not from that command.
require_metered_ok() {
  [ "$MODEL_BILLING" = "metered" ] || return 0
  wolfmux_metered_on && return 0
  # An agent gets no recipe. The worktree guard refuses a worker's Edit and Write on the
  # owner's config, but not a shell command it runs, and printing the exact line to put
  # there is the nudge that turns a guard into a suggestion.
  [ -z "${TEAM_ROLE:-}" ] || die "'$MODEL_KEY' is metered: every token is billed to a prepaid balance, not to a plan or a subscription, so it is off. Only the machine's owner switches it on, in the owner's own config file; an agent does not decide that. Ask the owner." 77
  die "'$MODEL_KEY' is metered: every token is billed to a prepaid balance, not to a plan or a subscription, so it is off. Only the owner switches it on (an agent does not decide that): put WOLFMUX_METERED=on in $(wolfmux_owner_config_label). An environment variable does not count." 77
}

# launcher_path <key> — WOLFMUX_LAUNCHER_<KEY> overrides the default (used by tests).
launcher_path() {
  local key="$1" upper override
  model_info "$key" || return 1
  case "$key" in
    claude:* | codex:*) upper="$(printf '%s' "$MODEL_FAMILY" | tr '[:lower:]' '[:upper:]')" ;; # claude:<id> / codex:<id>
    *:*) upper="$(printf '%s' "${key%%:*}" | tr '[:lower:]' '[:upper:]')" ;;                    # <provider>:<id>
    *) upper="$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')" ;;
  esac
  eval "override=\"\${WOLFMUX_LAUNCHER_${upper}:-}\""
  if [ -n "$override" ]; then
    printf '%s\n' "$override"
  else
    printf '%s\n' "$WOLFMUX_BIN_DIR/$MODEL_LAUNCHER"
  fi
}

# --- project + state resolution -------------------------------------------------
# repo_root_of <directory> — main checkout of the repository that holds it, also when
# the directory is a linked worktree that lives outside that checkout (every worker's is).
repo_root_of() {
  local dir="$1" common top
  [ -n "$GIT_BIN" ] && [ -d "$dir" ] || return 1
  common="$("$GIT_BIN" -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  case "$common" in
    */.git)
      printf '%s\n' "${common%/.git}"
      ;;
    *)
      top="$("$GIT_BIN" -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
      printf '%s\n' "$top"
      ;;
  esac
}

# resolve_root — main checkout of the current repository.
resolve_root() {
  if [ -n "${WOLFMUX_ROOT:-}" ] && [ -d "$WOLFMUX_ROOT" ]; then
    printf '%s\n' "$WOLFMUX_ROOT"
    return 0
  fi
  repo_root_of "$PWD"
}

sanitize_name() {
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9_-' '-' | sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'
}

project_key() {
  local root="$1" base hash
  base="$(sanitize_name "$(basename "$root")")"
  hash="$(printf '%s' "$root" | shasum -a 256 | cut -c1-6)"
  printf '%s-%s\n' "${base:-project}" "$hash"
}

# load_project — sets ROOT PROJECT_KEY STATE_DIR WORKTREES_DIR, or dies.
# --- teams ---------------------------------------------------------------------
# A project can have several teams, each with its own tmux session, lead, workers, policy
# and arrangement. The first one is called "default" and lives where the only team used to
# live, so nothing moves for a project that has one team. A named team lives under teams/.
#
#   state       ~/.wolfmux/state/<project>/                     default
#               ~/.wolfmux/state/<project>/teams/<team>/        named
#   worktrees   ~/.wolfmux/worktrees/<project>/<role>-<stamp>   default
#               ~/.wolfmux/worktrees/<project>/teams/<team>/<role>-<stamp>
#   branches    ai/<role>-<stamp>  ·  ai/<team>/<role>-<stamp>   (the default branch template;
#               a team can name its workers' branches differently: teamctl policy branch-template)
#   Beads name  <role>             ·  <team>.<role>       (all teams share the project's Beads)
#
# A worker can also be given a worktree in ANOTHER repository (teamctl spawn --repo <path>):
# its worktree, branch and base live there, under ~/.wolfmux/worktrees/<that repo>/teams/<team>/,
# and its record says which repository that is. Everything else about the team is unchanged.
WOLFMUX_DEFAULT_TEAM="default"

# A team's name is part of its tmux session, its branches and its Beads names, so it is kept
# to a harmless alphabet; the length is only there so that a slip of the hand is not a name.
WOLFMUX_TEAM_NAME_MAX=50

valid_team_name() {
  case "$1" in
    "" | *[!${_WM_LOWER}${_WM_DIGITS}-]* | -* | *-) return 1 ;;
  esac
  [ "${#1}" -le "$WOLFMUX_TEAM_NAME_MAX" ]
}

# team_name_error <name>: why valid_team_name refused it, for every command alike
team_name_error() {
  if [ "${#1}" -gt "$WOLFMUX_TEAM_NAME_MAX" ]; then
    printf "invalid team name '%s': it is %s characters, max %s\n" "$1" "${#1}" "$WOLFMUX_TEAM_NAME_MAX"
  else
    printf "invalid team name '%s' (lowercase letters, digits and '-', not at either end, max %s)\n" "$1" "$WOLFMUX_TEAM_NAME_MAX"
  fi
}

# team_identity <team> <role> — what an agent is called in Beads
team_identity() {
  if [ "$1" = "$WOLFMUX_DEFAULT_TEAM" ]; then printf '%s\n' "$2"; else printf '%s.%s\n' "$1" "$2"; fi
}

# identity_split <identity> — sets ID_TEAM and ID_ROLE ("review.backend" -> review, backend)
identity_split() {
  case "$1" in
    *.*) ID_TEAM="${1%%.*}" ID_ROLE="${1#*.}" ;;
    *) ID_TEAM="$WOLFMUX_DEFAULT_TEAM" ID_ROLE="$1" ;;
  esac
}

# team_paths <team> — point STATE_DIR and WORKTREES_DIR at one team of the loaded project
team_paths() {
  TEAM="$1"
  if [ "$TEAM" = "$WOLFMUX_DEFAULT_TEAM" ]; then
    STATE_DIR="$PROJECT_STATE"
    WORKTREES_DIR="$PROJECT_TREES"
  else
    STATE_DIR="$PROJECT_STATE/teams/$TEAM"
    WORKTREES_DIR="$PROJECT_TREES/teams/$TEAM"
  fi
}

# team_list — teams of the loaded project that have agents on record or a session running
team_list() {
  local dir name keep_team="${TEAM:-}" keep_state="${STATE_DIR:-}" keep_trees="${WORKTREES_DIR:-}"
  for name in "$WOLFMUX_DEFAULT_TEAM" $(for dir in "$PROJECT_STATE"/teams/*/; do [ -d "$dir" ] && basename "$dir"; done 2>/dev/null); do
    valid_team_name "$name" || continue
    team_paths "$name"
    if [ -n "$(reg_list 2>/dev/null)" ] || tm_session_exists "$(session_name_for_project)" 2>/dev/null; then printf '%s\n' "$name"; fi
  done
  TEAM="$keep_team" STATE_DIR="$keep_state" WORKTREES_DIR="$keep_trees"
}

# caller_team — the team of the agent running this command: the pane it runs in decides,
# WOLFMUX_TEAM (exported into every agent) otherwise. Empty = you, at your own terminal.
caller_team() {
  local team=""
  if [ -n "${TMUX_PANE:-}" ] && [ -n "$TMUX_BIN" ] && tm_inside_team_server; then
    team="$(tmx display-message -p -t "$TMUX_PANE" '#{@wolfmux_team}' 2>/dev/null || true)"
  fi
  [ -n "$team" ] || team="${WOLFMUX_TEAM:-}"
  printf '%s\n' "$team"
}

# load_project [any] — the repository, then the team. Which team: --team, else the caller's
# own, else the only one there is. With several and none named, a command has to be told;
# "any" is for the commands that can show all of them (TEAM stays empty).
load_project() {
  local wanted teams count
  ROOT="$(resolve_root)" || die "not inside a git repository (teams need git worktrees). cd into your project first."
  PROJECT_KEY="$(project_key "$ROOT")"
  PROJECT_STATE="$WOLFMUX_DATA/state/$PROJECT_KEY"
  PROJECT_TREES="$WOLFMUX_DATA/worktrees/$PROJECT_KEY"
  wanted="${WOLFMUX_TEAM_ARG:-}"
  [ -n "$wanted" ] || wanted="$(caller_team)"
  if [ -n "$wanted" ]; then
    valid_team_name "$wanted" || die_usage "$(team_name_error "$wanted")"
    team_paths "$wanted"
    return 0
  fi
  teams="$(team_list | tr '\n' ' ')"
  count="$(printf '%s' "$teams" | wc -w | tr -d ' ')"
  case "$count" in
    0) team_paths "$WOLFMUX_DEFAULT_TEAM" ;;
    1) team_paths "${teams% }" ;;
    *)
      if [ "${1:-}" = "any" ]; then
        team_paths "$WOLFMUX_DEFAULT_TEAM"
        TEAM=""
      else
        die_usage "this project has several teams (${teams% }); say which one: teamctl --team <name> …"
      fi
      ;;
  esac
}

ensure_state_dirs() {
  /bin/mkdir -p "$STATE_DIR/agents" "$STATE_DIR/nudge" "$WORKTREES_DIR"
  /bin/chmod 700 "$WOLFMUX_DATA" 2>/dev/null || true
}

# short_path <abs> — $HOME-relative for display
short_path() {
  case "$1" in
    "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

confirm() {
  local prompt="$1" answer
  [ -t 0 ] || return 1
  printf '%s [y/N] ' "$prompt" >&2
  read -r answer || return 1
  case "$answer" in y | Y | yes | YES) return 0 ;; *) return 1 ;; esac
}
