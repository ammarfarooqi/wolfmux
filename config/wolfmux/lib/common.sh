#!/bin/bash
# common.sh — output helpers, validation, tool lookup, model table, project resolution.
# Compatible with macOS /bin/bash 3.2 (no associative arrays, no mapfile, no ${var,,}).

WOLFMUX_VERSION="1.2.0"
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
valid_role() {
  case "$1" in
    "" | *[!a-z0-9-]* | -* | *-) return 1 ;;
  esac
  [ "${#1}" -le 32 ]
}

require_role_arg() {
  [ -n "${1:-}" ] || die_usage "missing <role>"
  valid_role "$1" || die_usage "invalid role '$1' (use lowercase letters, digits and '-', max 32 chars)"
}

# Bead ids are echoed into a pane, so keep them to a harmless alphabet.
valid_bead_id() {
  case "$1" in
    "" | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

# --- model table (the only place that knows which CLI serves which model) -----
# model_info <key> — sets MODEL_KEY MODEL_LAUNCHER MODEL_LABEL MODEL_FAMILY
model_info() {
  MODEL_KEY="$1"
  case "$1" in
    fable)
      MODEL_LAUNCHER="claude-fable" MODEL_LABEL="Fable 5.1" MODEL_FAMILY="claude"
      ;;
    astra)
      MODEL_LAUNCHER="codex-astra" MODEL_LABEL="GPT-6 Astra" MODEL_FAMILY="codex"
      ;;
    glm53)
      MODEL_LAUNCHER="claude-glm" MODEL_LABEL="GLM-5.3" MODEL_FAMILY="claude"
      ;;
    flash)
      MODEL_LAUNCHER="claude-glm-flash" MODEL_LABEL="GLM-5.3 Flash" MODEL_FAMILY="claude"
      ;;
    *) return 1 ;;
  esac
}

WOLFMUX_MODEL_KEYS="fable astra glm53 flash"

# launcher_path <key> — WOLFMUX_LAUNCHER_<KEY> overrides the default (used by tests).
launcher_path() {
  local key="$1" upper override
  model_info "$key" || return 1
  upper="$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
  eval "override=\"\${WOLFMUX_LAUNCHER_${upper}:-}\""
  if [ -n "$override" ]; then
    printf '%s\n' "$override"
  else
    printf '%s\n' "$WOLFMUX_BIN_DIR/$MODEL_LAUNCHER"
  fi
}

# --- project + state resolution -------------------------------------------------
# resolve_root — main checkout of the current repository, also when called from a
# linked worktree that lives outside it (every worker does).
resolve_root() {
  local common top
  if [ -n "${WOLFMUX_ROOT:-}" ] && [ -d "$WOLFMUX_ROOT" ]; then
    printf '%s\n' "$WOLFMUX_ROOT"
    return 0
  fi
  [ -n "$GIT_BIN" ] || return 1
  common="$("$GIT_BIN" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  case "$common" in
    */.git)
      printf '%s\n' "${common%/.git}"
      ;;
    *)
      top="$("$GIT_BIN" rev-parse --show-toplevel 2>/dev/null)" || return 1
      printf '%s\n' "$top"
      ;;
  esac
}

sanitize_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '-' | sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'
}

project_key() {
  local root="$1" base hash
  base="$(sanitize_name "$(basename "$root")")"
  hash="$(printf '%s' "$root" | shasum -a 256 | cut -c1-6)"
  printf '%s-%s\n' "${base:-project}" "$hash"
}

# load_project — sets ROOT PROJECT_KEY STATE_DIR WORKTREES_DIR, or dies.
load_project() {
  ROOT="$(resolve_root)" || die "not inside a git repository (teams need git worktrees). cd into your project first."
  PROJECT_KEY="$(project_key "$ROOT")"
  STATE_DIR="$WOLFMUX_DATA/state/$PROJECT_KEY"
  WORKTREES_DIR="$WOLFMUX_DATA/worktrees/$PROJECT_KEY"
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
