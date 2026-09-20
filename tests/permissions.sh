#!/bin/bash
# permissions.sh — what install.sh and uninstall.sh do to ~/.claude/settings.json,
# rehearsed in a throwaway HOME. Nothing of yours is read or written; no team is started.
#
# The rules go into the GLOBAL settings file, so they apply to every Claude Code session on
# the machine. A rule is a prefix match: `Bash(git log *)` also allows
# `git log --output=<any file>` (writes it), and `Bash(tmux -L wolfmux list-panes *)` also
# allows `... list-panes ';' run-shell <anything>`. Such rules are retired: never added
# again, and taken out of a settings file that an earlier version put them into.
#
#   tests/permissions.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-permissions.XXXXXX")"
trap '/bin/rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
export WOLFMUX_TMUX_SOCKET="wolfmux-test-permissions-$$" WOLFMUX_LEGACY_SOCKET="wolfmux-test-permissions-old-$$" # uninstall refuses while a team runs on the real sockets
unset WOLFMUX_MIGRATING CLAUDE_CONFIG_DIR
/bin/mkdir -p "$HOME/.claude"
SETTINGS="$HOME/.claude/settings.json"
FLAGS="--no-path --no-codex-rules --no-notifier-app"

passed=0
failed=0
check() { # <description> <command string>
  if eval "$2" >/dev/null 2>&1; then
    passed=$((passed + 1))
    printf '  pass  %s\n' "$1"
  else
    failed=$((failed + 1))
    printf '  FAIL  %s\n' "$1"
  fi
}
allowed() { jq -e --arg rule "$1" '(.permissions.allow // []) | index($rule) != null' "$SETTINGS"; }
UNSAFE='Bash(git diff *)|Bash(git log *)|Bash(git show *)|Bash(tmux -L wolfmux list-panes *)|Bash(tmux -L wolfmux capture-pane *)'
none_unsafe() { jq -e --arg unsafe "$UNSAFE" '($unsafe | split("|")) as $u | [(.permissions.allow // [])[] | select(. as $r | $u | index($r))] | length == 0' "$SETTINGS"; }

echo "== a fresh install"
# shellcheck disable=SC2086
"$REPO/install.sh" $FLAGS >"$WORK/install-1.log" 2>&1
check "install: teamctl and bd are allowed, destroy always asks" 'allowed "Bash(teamctl *)" && allowed "Bash(bd *)" && jq -e ".permissions.ask | index(\"Bash(teamctl destroy *)\") != null" "$SETTINGS"'
check "install: no rule that can write a file or run a command through its arguments" 'none_unsafe'
check "install: the rules file names what it retired, and adds none of it" 'jq -e "(.retired | length) >= 5 and ((.allow - .retired) == .allow)" "$REPO/claude/permissions.json"'

echo "== over a settings file that an earlier version wrote"
jq -n --arg unsafe "$UNSAFE" '{model: "keep-me", permissions: {allow: (["Bash(npm test *)", "Bash(teamctl *)"] + ($unsafe | split("|"))), deny: ["Bash(rm -rf *)"]}}' >"$SETTINGS"
# shellcheck disable=SC2086
"$REPO/install.sh" $FLAGS >"$WORK/install-2.log" 2>&1
check "upgrade: the retired rules are taken out" 'none_unsafe'
check "upgrade: it says which rules it took out, and keeps a backup holding them" 'grep -q "retired.*git log" "$WORK/install-2.log" && /bin/ls "$SETTINGS".backup-* && grep -q "git log" "$SETTINGS".backup-*'
check "upgrade: your own rules and every other setting are untouched" 'allowed "Bash(npm test *)" && jq -e ".model == \"keep-me\" and .permissions.deny == [\"Bash(rm -rf *)\"]" "$SETTINGS"'
# shellcheck disable=SC2086
"$REPO/install.sh" $FLAGS >"$WORK/install-3.log" 2>&1
check "upgrade: a second run changes nothing" 'grep -q "rules already present" "$WORK/install-3.log"'

echo "== uninstall"
jq --arg unsafe "$UNSAFE" '.permissions.allow += ($unsafe | split("|"))' "$SETTINGS" >"$SETTINGS.tmp" && /bin/mv -f "$SETTINGS.tmp" "$SETTINGS"
"$REPO/uninstall.sh" >"$WORK/uninstall.log" 2>&1
check "uninstall: current and retired rules are both removed" 'none_unsafe && ! allowed "Bash(teamctl *)" && ! allowed "Bash(bd *)"'
check "uninstall: your own rules stay" 'allowed "Bash(npm test *)" && jq -e ".permissions.deny == [\"Bash(rm -rf *)\"]" "$SETTINGS"'

echo
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
