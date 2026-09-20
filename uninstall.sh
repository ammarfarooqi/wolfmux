#!/bin/bash
# uninstall.sh — remove wolfmux. Claude Code, Codex, Beads, your repositories,
# commits and branches are not touched. Edited files are backed up first.
#
#   ./uninstall.sh            remove the tool, keep ~/.wolfmux (worktrees + state)
#   ./uninstall.sh --purge    also remove ~/.wolfmux, but only when it holds no worktree
#
# Not done for you, on purpose:
#   security delete-generic-password -s zai-coding-plan     (your Keychain item)
#   per project: teamctl destroy --worktrees, and `rm -r .beads` if you want Beads gone
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd -P)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BIN_DIR="$HOME/bin"
CONF_DIR="$HOME/.config/wolfmux"
PURGE=0
case "${1:-}" in
  "") ;;
  --purge) PURGE=1 ;;
  -h | --help)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "uninstall.sh: unknown option: $1" >&2
    exit 64
    ;;
esac

note() { printf '  %s\n' "$*"; }
backup() {
  /bin/cp -p "$1" "$1.backup-$STAMP"
  note "backup: $1.backup-$STAMP"
}

SOCKET="${WOLFMUX_TMUX_SOCKET:-wolfmux}"

echo "== team tmux server"
for socket in "$SOCKET" "${WOLFMUX_LEGACY_SOCKET:-ai-team}"; do # the second: a team started before the rename
  if command -v tmux >/dev/null 2>&1 && tmux -L "$socket" ls >/dev/null 2>&1; then
    echo "uninstall.sh: a team is still running (tmux -L $socket ls). Run 'teamctl destroy' in its project first." >&2
    exit 1
  fi
done
note "no team running"

echo "== launchers and CLI"
for name in teamctl claude-fable codex-astra claude-glm; do
  if [ -f "$BIN_DIR/$name" ]; then
    /bin/rm -f "$BIN_DIR/$name"
    note "removed: $BIN_DIR/$name"
  fi
done
for name in claude-glm-flash claude-opus claude-sonnet claude-haiku; do
  if [ -L "$BIN_DIR/$name" ]; then
    /bin/rm -f "$BIN_DIR/$name"
    note "removed: $BIN_DIR/$name"
  fi
done
# The provider launchers are links to claude-glm (claude-kimi, claude-qwen, ...). Any link of that
# kind goes, whichever version of the table put it there; a file of yours under such a name stays.
for link in "$BIN_DIR"/claude-*; do
  if [ -L "$link" ] && [ "$(readlink "$link")" = "claude-glm" ]; then
    /bin/rm -f "$link"
    note "removed: $link"
  fi
done
# Only our own symlink to the app-bundled CLI; a real codex install is left alone.
if [ -L "$BIN_DIR/codex" ] && [ "$(readlink "$BIN_DIR/codex")" = "/Applications/ChatGPT.app/Contents/Resources/codex" ]; then
  /bin/rm -f "$BIN_DIR/codex"
  note "removed: $BIN_DIR/codex (symlink)"
elif [ -f "$BIN_DIR/codex" ] && grep -q 'wolfmux-codex-wrapper' "$BIN_DIR/codex" 2>/dev/null; then
  /bin/rm -f "$BIN_DIR/codex"
  note "removed: $BIN_DIR/codex (wrapper)"
fi
/bin/rmdir "$BIN_DIR" 2>/dev/null && note "removed empty $BIN_DIR" || true

echo "== ~/.config/wolfmux"
if [ -d "$CONF_DIR" ]; then
  /bin/rm -rf "$CONF_DIR"
  note "removed: $CONF_DIR"
fi

echo "== ~/.zshrc"
if [ -f "$HOME/.zshrc" ] && grep -q '>>> wolfmux >>>' "$HOME/.zshrc"; then
  backup "$HOME/.zshrc"
  # Drops the block and the one blank separator line install.sh put in front of it,
  # so the file ends up byte-identical to what it was before.
  awk '
    /^# >>> wolfmux >>>/ { skipping = 1; holding = 0; next }
    skipping && /^# <<< wolfmux <<</ { skipping = 0; next }
    skipping { next }
    { if (holding) print held; if ($0 == "") { held = $0; holding = 1 } else { holding = 0; print } }
    END { if (holding) print held }
  ' "$HOME/.zshrc" >"$HOME/.zshrc.tmp.$$"
  /bin/mv -f "$HOME/.zshrc.tmp.$$" "$HOME/.zshrc"
  note "removed the wolfmux block"
else
  note "no wolfmux block"
fi

echo "== Claude Code permissions"
settings="$HOME/.claude/settings.json"
if [ -f "$settings" ] && command -v jq >/dev/null 2>&1; then
  cleaned="$(jq --slurpfile p "$REPO/claude/permissions.json" '
    if .permissions then
      .permissions.allow = ((.permissions.allow // []) - $p[0].allow - ($p[0].retired // []))
      | .permissions.ask = ((.permissions.ask // []) - $p[0].ask)
      | if (.permissions.ask | length) == 0 then del(.permissions.ask) else . end
    else . end' "$settings")"
  if [ "$(jq -S . "$settings")" = "$(printf '%s' "$cleaned" | jq -S .)" ]; then
    note "no wolfmux rules present"
  else
    backup "$settings"
    printf '%s\n' "$cleaned" >"$settings.tmp.$$"
    /bin/mv -f "$settings.tmp.$$" "$settings"
    /bin/chmod 600 "$settings"
    note "removed the wolfmux allow/ask rules"
  fi
fi

echo "== Codex rules"
if [ -f "$HOME/.codex/rules/wolfmux.rules" ]; then
  /bin/rm -f "$HOME/.codex/rules/wolfmux.rules"
  note "removed: ~/.codex/rules/wolfmux.rules"
fi

echo "== ~/.wolfmux (worktrees + state)"
if [ "$PURGE" -eq 1 ] && [ -d "$HOME/.wolfmux" ]; then
  # A worktree is <project>/<role>-<stamp>, or <project>/teams/<team>/<role>-<stamp> in a named
  # team. The teams/ folder itself stays behind when a named team is deleted: it is not one.
  # No pipe into head, and `|| true`: as a plain assignment the status would reach `set -e`,
  # and find fails when there is no worktrees/ folder at all.
  held="$(find "$HOME/.wolfmux/worktrees" -mindepth 2 -maxdepth 2 -type d ! -name teams -print -quit 2>/dev/null || true)"
  [ -n "$held" ] || held="$(find "$HOME/.wolfmux/worktrees" -mindepth 4 -maxdepth 4 -type d -path '*/teams/*' -print -quit 2>/dev/null || true)"
  if [ -n "$held" ]; then
    note "KEPT: worktrees still exist under ~/.wolfmux/worktrees (they may hold uncommitted work)"
  else
    /bin/rm -rf "$HOME/.wolfmux"
    note "removed: ~/.wolfmux"
  fi
else
  note "kept (use --purge to remove it when it holds no worktree)"
fi

echo
echo "Left in place: Claude Code, Codex, Beads (~/.local/bin/bd), your Keychain item, every repository."
