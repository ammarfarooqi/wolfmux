#!/bin/bash
# install.sh — put wolfmux in place for the current user. Idempotent and reversible.
#
# It copies files, creates two symlinks, and makes three small, backed-up edits:
#   ~/.zshrc                      one marked block that appends ~/bin to PATH
#   ~/.claude/settings.json       narrow allow/ask permission rules (merged, never replaced)
#   ~/.codex/rules/wolfmux.rules  a separate rule file (default.rules is not touched)
# It never reads, writes or asks for a credential. Undo everything with ./uninstall.sh.
#
#   ./install.sh [--no-path] [--no-claude-permissions] [--no-codex-rules]
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd -P)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BIN_DIR="$HOME/bin"
CONF_DIR="$HOME/.config/wolfmux"
DO_PATH=1
DO_CLAUDE=1
DO_CODEX=1

for arg in "$@"; do
  case "$arg" in
    --no-path) DO_PATH=0 ;;
    --no-claude-permissions) DO_CLAUDE=0 ;;
    --no-codex-rules) DO_CODEX=0 ;;
    -h | --help)
      sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "install.sh: unknown option: $arg" >&2
      exit 64
      ;;
  esac
done

say() { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }

backup() { # <file> — timestamped copy next to the original
  /bin/cp -p "$1" "$1.backup-$STAMP"
  note "backup: $1.backup-$STAMP"
}

# install_file <src> <dst> <mode> — replace only when the content differs. The
# previous version of one of OUR files goes to ~/.wolfmux/backups/<stamp>/, never
# next to the original: an executable copy in ~/bin would sit on your PATH.
install_file() {
  local src="$1" dst="$2" mode="$3" keep
  if [ -f "$dst" ] && /usr/bin/cmp -s "$src" "$dst"; then
    return 0
  fi
  if [ -e "$dst" ]; then
    keep="$HOME/.wolfmux/backups/$STAMP/${dst#"$HOME"/}"
    /bin/mkdir -p "$(dirname "$keep")"
    /bin/cp -p "$dst" "$keep"
    /bin/chmod 600 "$keep"
    note "previous version kept: $keep"
  fi
  /usr/bin/install -m "$mode" "$src" "$dst"
  note "installed: $dst"
}

# install_once <src> <dst> <mode> — user-editable files are never overwritten
install_once() {
  if [ -e "$2" ]; then
    note "kept your existing: $2"
  else
    /usr/bin/install -m "$3" "$1" "$2"
    note "installed: $2"
  fi
}

say "== prerequisites"
missing=""
for tool in tmux git jq; do
  if command -v "$tool" >/dev/null 2>&1; then note "ok       $tool"; else
    note "MISSING  $tool"
    missing="$missing $tool"
  fi
done
[ -z "$missing" ] || {
  echo "install.sh: install these first (e.g. with Homebrew):$missing" >&2
  exit 1
}
for tool in claude bd; do
  if command -v "$tool" >/dev/null 2>&1; then note "ok       $tool"; else note "not found (needed before the first team starts): $tool"; fi
done

say "== files"
/bin/mkdir -p "$BIN_DIR" "$CONF_DIR/lib" "$CONF_DIR/hooks"
/bin/chmod 700 "$CONF_DIR"
for name in teamctl claude-fable codex-astra claude-glm; do
  install_file "$REPO/bin/$name" "$BIN_DIR/$name" 755
done
for path in "$REPO"/config/wolfmux/lib/*.sh; do
  install_file "$path" "$CONF_DIR/lib/$(basename "$path")" 644
done
install_file "$REPO/config/wolfmux/hooks/beads-nudge" "$CONF_DIR/hooks/beads-nudge" 755
for name in tmux.conf TEAM_PROTOCOL.md README.md; do
  install_file "$REPO/config/wolfmux/$name" "$CONF_DIR/$name" 644
done
install_once "$REPO/config/wolfmux/config" "$CONF_DIR/config" 644
if ! /usr/bin/cmp -s "$REPO/config/wolfmux/config" "$CONF_DIR/config"; then
  note "new settings may exist: compare with $REPO/config/wolfmux/config"
fi
install_once "$REPO/config/wolfmux/glm-worker-settings.json" "$CONF_DIR/glm-worker-settings.json" 644

say "== symlinks"
if [ ! -e "$BIN_DIR/claude-glm-flash" ]; then
  /bin/ln -s claude-glm "$BIN_DIR/claude-glm-flash"
  note "linked: $BIN_DIR/claude-glm-flash -> claude-glm"
fi
BUNDLED_CODEX="/Applications/ChatGPT.app/Contents/Resources/codex"
if command -v codex >/dev/null 2>&1; then
  note "codex already on PATH: $(command -v codex)"
elif [ -x "$BUNDLED_CODEX" ] && [ ! -e "$BIN_DIR/codex" ]; then
  /bin/ln -s "$BUNDLED_CODEX" "$BIN_DIR/codex"
  note "linked: $BIN_DIR/codex -> ChatGPT.app's bundled Codex CLI"
else
  note "no Codex CLI found; the Astra lead needs one (https://chatgpt.com/codex)"
fi

if [ "$DO_PATH" -eq 1 ]; then
  say "== PATH (~/.zshrc)"
  if [ -f "$HOME/.zshrc" ] && grep -q '>>> wolfmux >>>' "$HOME/.zshrc"; then
    note "block already present"
  else
    if [ -f "$HOME/.zshrc" ]; then backup "$HOME/.zshrc"; fi
    {
      printf '\n# >>> wolfmux >>> (added %s; delete this block to uninstall)\n' "$(date +%Y-%m-%d)"
      printf '# teamctl + model launchers live in ~/bin. Appended, not prepended, so nothing\n'
      printf '# in ~/bin can shadow an existing tool.\n'
      printf '[[ -d "$HOME/bin" ]] && path+=("$HOME/bin")\n'
      printf '# <<< wolfmux <<<\n'
    } >>"$HOME/.zshrc"
    note "appended the wolfmux block to ~/.zshrc (open a new terminal to pick it up)"
  fi
fi

if [ "$DO_CLAUDE" -eq 1 ]; then
  say "== Claude Code permissions (~/.claude/settings.json)"
  settings="$HOME/.claude/settings.json"
  /bin/mkdir -p "$HOME/.claude"
  [ -f "$settings" ] || printf '{}\n' >"$settings"
  merged="$(jq --slurpfile p "$REPO/claude/permissions.json" '
    .permissions = (.permissions // {})
    | .permissions.allow = (reduce $p[0].allow[] as $rule (.permissions.allow // []; if index($rule) then . else . + [$rule] end))
    | .permissions.ask   = (reduce $p[0].ask[]   as $rule (.permissions.ask   // []; if index($rule) then . else . + [$rule] end))
  ' "$settings")"
  if [ "$(jq -S . "$settings")" = "$(printf '%s' "$merged" | jq -S .)" ]; then
    note "rules already present"
  else
    backup "$settings"
    printf '%s\n' "$merged" >"$settings.tmp.$$"
    /bin/mv -f "$settings.tmp.$$" "$settings"
    /bin/chmod 600 "$settings"
    note "merged allow/ask rules (nothing removed)"
  fi
fi

if [ "$DO_CODEX" -eq 1 ]; then
  say "== Codex rules (~/.codex/rules/wolfmux.rules)"
  if [ -d "$HOME/.codex" ]; then
    /bin/mkdir -p "$HOME/.codex/rules"
    sed "s|__HOME__|$HOME|g" "$REPO/codex/wolfmux.rules.template" >"$HOME/.codex/rules/wolfmux.rules.tmp.$$"
    if [ -f "$HOME/.codex/rules/wolfmux.rules" ] && /usr/bin/cmp -s "$HOME/.codex/rules/wolfmux.rules.tmp.$$" "$HOME/.codex/rules/wolfmux.rules"; then
      /bin/rm -f "$HOME/.codex/rules/wolfmux.rules.tmp.$$"
      note "rule file already current"
    else
      if [ -f "$HOME/.codex/rules/wolfmux.rules" ]; then backup "$HOME/.codex/rules/wolfmux.rules"; fi
      /bin/mv -f "$HOME/.codex/rules/wolfmux.rules.tmp.$$" "$HOME/.codex/rules/wolfmux.rules"
      note "installed: ~/.codex/rules/wolfmux.rules"
    fi
  else
    note "no ~/.codex directory: skipped (run Codex once, then re-run this script)"
  fi
fi

/bin/cat <<'EOF'

== next
1. Store your Z.ai Coding Plan key in the macOS Keychain (you are prompted; nothing is echoed):
     security add-generic-password -U -s zai-coding-plan -a "$USER" -l "Z.ai Coding Plan API key" -w
2. Open a new terminal, then:   teamctl doctor
3. In a project:                teamctl start fable      (or: teamctl start astra)
EOF
