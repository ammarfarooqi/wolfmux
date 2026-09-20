#!/bin/bash
# install.sh — put wolfmux in place for the current user. Idempotent and reversible.
#
# It copies files, links the launcher names, builds Wolfmux.app (the owner of the team's
# notifications), writes ~/bin/codex when no codex is installed, and makes three small,
# backed-up edits:
#   ~/.zshrc                      one marked block that appends ~/bin to PATH
#   ~/.claude/settings.json       narrow allow/ask permission rules (merged, never replaced)
#   ~/.codex/rules/wolfmux.rules  a separate rule file (default.rules is not touched)
# It never reads, writes or asks for a credential. Undo everything with ./uninstall.sh.
#
#   ./install.sh [--no-path] [--no-claude-permissions] [--no-codex-rules] [--no-notifier-app]
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd -P)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BIN_DIR="$HOME/bin"
CONF_DIR="$HOME/.config/wolfmux"
DO_PATH=1
DO_CLAUDE=1
DO_CODEX=1
DO_APP=1

for arg in "$@"; do
  case "$arg" in
    --no-path) DO_PATH=0 ;;
    --no-claude-permissions) DO_CLAUDE=0 ;;
    --no-codex-rules) DO_CODEX=0 ;;
    --no-notifier-app) DO_APP=0 ;;
    -h | --help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
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

# v1.1 and earlier were called "ai-team". Installing next to it would strand its state and worktrees.
if [ -z "${WOLFMUX_MIGRATING:-}" ] && { [ -e "$HOME/.ai-team" ] || [ -e "$HOME/.config/ai-team" ]; }; then
  echo "install.sh: an installation under this tool's old name (ai-team) is present." >&2
  echo "Run ./migrate-from-ai-team.sh instead: it carries state and worktrees over, then calls install.sh." >&2
  exit 1
fi

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
# A config without a single active line is only an old copy of the template: refresh it,
# so new settings show up as comments. One edit of yours and it is never touched again.
if [ -f "$CONF_DIR/config" ] && ! grep -qvE '^[[:space:]]*(#|$)' "$CONF_DIR/config"; then
  install_file "$REPO/config/wolfmux/config" "$CONF_DIR/config" 644
else
  install_once "$REPO/config/wolfmux/config" "$CONF_DIR/config" 644
fi
if ! /usr/bin/cmp -s "$REPO/config/wolfmux/config" "$CONF_DIR/config"; then
  note "new settings may exist: compare with $REPO/config/wolfmux/config"
fi
install_once "$REPO/config/wolfmux/glm-worker-settings.json" "$CONF_DIR/glm-worker-settings.json" 644

# Wolfmux.app owns the notifications of a team that is on no screen, so that clicking one
# opens the team and not Script Editor (lib/notify.sh). Built here because an application
# bundle is not something to keep in git; rebuilt only when its source changes, because
# macOS ties the "may control iTerm" permission to the exact build.
if [ "$DO_APP" -eq 1 ]; then
  say "== Wolfmux.app (click a notification -> the team opens)"
  notifier="$REPO/config/wolfmux/notifier"
  app="$CONF_DIR/Wolfmux.app"
  if ! command -v osacompile >/dev/null 2>&1; then
    note "osacompile not found: skipped (notifications of a detached team will open Script Editor)"
  else
    want="$(/bin/cat "$notifier/Wolfmux.applescript" "$notifier/Wolfmux.icns" | shasum -a 256 | cut -d' ' -f1)"
    have="$(/bin/cat "$app/Contents/Resources/wolfmux-build" 2>/dev/null || true)"
    if [ "$want" = "$have" ]; then
      note "already current"
    else
      # osacompile decides by the name: only "*.app" becomes an application
      build="$CONF_DIR/.notifier-build"
      fresh="$build/Wolfmux.app"
      /bin/rm -rf "$build"
      /bin/mkdir -p "$build"
      if osacompile -o "$fresh" "$notifier/Wolfmux.applescript" >/dev/null 2>&1 && [ -d "$fresh/Contents/Resources" ]; then
        plist="$fresh/Contents/Info.plist"
        /bin/cp "$notifier/Wolfmux.icns" "$fresh/Contents/Resources/applet.icns"
        /bin/rm -f "$fresh/Contents/Resources/Assets.car" # it carries the stock script icon and would win
        /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$plist" >/dev/null 2>&1 || true
        for entry in 'CFBundleIdentifier string local.wolfmux.notifier' 'CFBundleName string Wolfmux' 'LSUIElement bool true'; do
          /usr/libexec/PlistBuddy -c "Delete :${entry%% *}" "$plist" >/dev/null 2>&1 || true
          /usr/libexec/PlistBuddy -c "Add :$entry" "$plist" >/dev/null
        done
        printf '%s\n' "$want" >"$fresh/Contents/Resources/wolfmux-build"
        /usr/bin/codesign --force -s - "$fresh" >/dev/null 2>&1 || note "could not sign the application (it still runs)"
        /bin/rm -rf "$app"
        /bin/mv "$fresh" "$app"
        /bin/rm -rf "$build"
        note "built: $app"
        note "the first time, macOS asks once to allow Wolfmux notifications, and once to let it control your terminal: allow both"
      else
        /bin/rm -rf "$build"
        note "could not build it: skipped (notifications of a detached team will open Script Editor)"
      fi
    fi
  fi
fi

say "== symlinks"
if [ ! -e "$BIN_DIR/claude-glm-flash" ]; then
  /bin/ln -s claude-glm "$BIN_DIR/claude-glm-flash"
  note "linked: $BIN_DIR/claude-glm-flash -> claude-glm"
fi
# The other Claude-subscription models: the same launcher under another name.
for name in claude-opus claude-sonnet claude-haiku; do
  if [ ! -e "$BIN_DIR/$name" ] && [ ! -L "$BIN_DIR/$name" ]; then
    /bin/ln -s claude-fable "$BIN_DIR/$name"
    note "linked: $BIN_DIR/$name -> claude-fable"
  fi
done
# The other providers of the table (lib/providers.sh): claude-glm again, under the provider's name.
# The name it is called by decides which endpoint and key it uses. A file of yours under one of
# those names is kept, and then teamctl would start yours: the note says so.
PROVIDERS="$( . "$REPO/config/wolfmux/lib/provider-env.sh"; printf '%s' "$WOLFMUX_PROVIDERS")"
for provider in $PROVIDERS; do
  [ "$provider" = "glm" ] && continue
  name="claude-$provider"
  if [ ! -e "$BIN_DIR/$name" ] && [ ! -L "$BIN_DIR/$name" ]; then
    /bin/ln -s claude-glm "$BIN_DIR/$name"
    note "linked: $BIN_DIR/$name -> claude-glm"
  elif [ "$(readlink "$BIN_DIR/$name" 2>/dev/null || true)" != "claude-glm" ]; then
    note "kept your existing $BIN_DIR/$name (it is not our link: teamctl will start that one for '$provider')"
  fi
done
BUNDLED_CODEX="/Applications/ChatGPT.app/Contents/Resources/codex"
# A wrapper, not a symlink: Codex looks for its helper programs (its command runner among
# them) next to the path it was started as, and through a symlink that would be ~/bin.
write_codex_wrapper() {
  /bin/rm -f "$BIN_DIR/codex"
  {
    printf '#!/bin/sh\n# wolfmux-codex-wrapper: the Codex CLI inside ChatGPT.app, started by its real path\n'
    printf '# (as a symlink, Codex would look for its helper programs in this directory).\n'
    printf 'exec "%s" "$@"\n' "$BUNDLED_CODEX"
  } >"$BIN_DIR/codex"
  /bin/chmod 755 "$BIN_DIR/codex"
}
if [ -L "$BIN_DIR/codex" ] && [ "$(readlink "$BIN_DIR/codex")" = "$BUNDLED_CODEX" ]; then
  write_codex_wrapper
  note "replaced the symlink $BIN_DIR/codex with a wrapper (Codex could not find its command runner through a symlink)"
elif command -v codex >/dev/null 2>&1; then
  note "codex already on PATH: $(command -v codex)"
elif [ -e "$BIN_DIR/codex" ]; then
  note "codex already present: $BIN_DIR/codex"
elif [ -x "$BUNDLED_CODEX" ]; then
  write_codex_wrapper
  note "wrote: $BIN_DIR/codex (starts ChatGPT.app's bundled Codex CLI)"
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
  # "retired": rules an earlier version added that are wider than they read. A rule is a prefix
  # match, so `git log *` also allowed `git log --output=<any file>`, and the tmux ones allowed
  # `... \; run-shell <anything>` -- in every Claude Code session on this machine. They are
  # never added again and are taken out here; `teamctl diff|panes|capture` cover the same needs.
  retired="$(jq -r --slurpfile p "$REPO/claude/permissions.json" '
    ($p[0].retired // []) as $gone | [(.permissions.allow // [])[] | select(. as $rule | $gone | index($rule))] | join(", ")' "$settings")"
  merged="$(jq --slurpfile p "$REPO/claude/permissions.json" '
    .permissions = (.permissions // {})
    | .permissions.allow = (reduce $p[0].allow[] as $rule ((.permissions.allow // []) - ($p[0].retired // []); if index($rule) then . else . + [$rule] end))
    | .permissions.ask   = (reduce $p[0].ask[]   as $rule (.permissions.ask   // []; if index($rule) then . else . + [$rule] end))
  ' "$settings")"
  if [ "$(jq -S . "$settings")" = "$(printf '%s' "$merged" | jq -S .)" ]; then
    note "rules already present"
  else
    backup "$settings"
    printf '%s\n' "$merged" >"$settings.tmp.$$"
    /bin/mv -f "$settings.tmp.$$" "$settings"
    /bin/chmod 600 "$settings"
    if [ -n "$retired" ]; then
      note "merged allow/ask rules; retired (they allowed more than they read, see claude/permissions.json): $retired"
    else
      note "merged allow/ask rules (nothing removed)"
    fi
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

Other providers are optional; add a key only for one you will use, the same way (Keychain service
in brackets), then: teamctl spawn <role> <provider>
EOF
metered=""
for provider in $PROVIDERS; do
  [ "$provider" = "glm" ] && continue
  ( . "$REPO/config/wolfmux/lib/provider-env.sh"; wolfmux_provider_info "$provider" && printf '     %-9s (%s)\n' "$provider" "$PROVIDER_KEYCHAIN" )
  if [ "$( . "$REPO/config/wolfmux/lib/provider-env.sh"; wolfmux_provider_info "$provider" && printf '%s' "$PROVIDER_BILLING")" = "metered" ]; then metered="$metered $provider"; fi
done
/bin/cat <<'EOF'
     security add-generic-password -U -s <service> -a "$USER" -l "<name> API key" -w
   teamctl doctor prints the exact command per provider.
EOF
if [ -n "$metered" ]; then
  printf '   Metered (every token is billed):%s. teamctl refuses them until you set WOLFMUX_METERED=on in %s/config.\n' "$metered" "~/.config/wolfmux"
fi
