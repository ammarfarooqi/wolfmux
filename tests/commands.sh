#!/bin/bash
# commands.sh — what install.sh does to ~/.claude/commands/ (the Claude Code slash commands
# for teamctl), rehearsed in a throwaway WOLFMUX_INSTALL_HOME. Nothing of yours is read or
# written; no team is started.
#
# install.sh copies config/wolfmux/commands/*.md there by content hash: a file that already
# matches is left alone, a stale copy of OUR OWN file is updated, and a file under the same
# name that install.sh did not put there (yours, or ours once you have edited it) is kept,
# with a note saying why.
#
# Every install.sh call below sets WOLFMUX_INSTALL_HOME for that one command, never $HOME:
# reassigning $HOME does not survive between separate shell invocations, which is exactly how
# a stray real install happened once. WOLFMUX_INSTALL_HOME exists so the real script can be
# rehearsed without that risk.
#
#   tests/commands.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-commands.XXXXXX")"
trap '/bin/rm -rf "$WORK"' EXIT
DEST="$WORK/home"
COMMANDS_DIR="$DEST/.claude/commands"
MANIFEST="$DEST/.config/wolfmux/commands.manifest"
SRC="$REPO/config/wolfmux/commands"
SOCKETS="WOLFMUX_TMUX_SOCKET=wolfmux-test-commands-$$ WOLFMUX_LEGACY_SOCKET=wolfmux-test-commands-old-$$"
run_install() { env WOLFMUX_INSTALL_HOME="$DEST" $SOCKETS "$REPO/install.sh" --no-path --no-codex-rules --no-notifier-app "$@"; }

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
count() { /bin/ls "$1" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' '; }
NAMES="$( (cd "$SRC" 2>/dev/null && /bin/ls) | /usr/bin/sed 's/\.md$//')"
N="$(printf '%s\n' "$NAMES" | /usr/bin/grep -c .)"

echo "== a fresh install"
run_install >"$WORK/install-1.log" 2>&1
check "every command file in config/wolfmux/commands/ lands in ~/.claude/commands/" "[ \"\$(count "$COMMANDS_DIR")\" = \"$N\" ]"
check "the manifest records one hash per installed file" "[ \"\$(/usr/bin/wc -l <"$MANIFEST" | /usr/bin/tr -d ' ')\" = \"$N\" ]"
out=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  /usr/bin/cmp -s "$SRC/$name.md" "$COMMANDS_DIR/$name.md" || out="$out $name"
done <<EOF
$NAMES
EOF
check "every installed file matches its source byte for byte" "[ -z \"$out\" ]"
check "the generic /teamctl command passes its arguments straight through" "/usr/bin/grep -q 'teamctl \$ARGUMENTS' '$COMMANDS_DIR/teamctl.md'"
check "/team-destroy shows the teams first and asks before the real command" "/usr/bin/grep -qi 'ask the user' '$COMMANDS_DIR/team-destroy.md' && /usr/bin/grep -q 'teamctl teams' '$COMMANDS_DIR/team-destroy.md'"
check "/team-prune asks before anything but --dry-run" "/usr/bin/grep -qi 'ask the user' '$COMMANDS_DIR/team-prune.md' && /usr/bin/grep -q -- '--dry-run' '$COMMANDS_DIR/team-prune.md'"

echo "== a second run is idempotent"
run_install >"$WORK/install-2.log" 2>&1
check "nothing in ~/.claude/commands/ is touched again" '! (/usr/bin/grep -A200 "Claude Code slash commands" "$WORK/install-2.log" | /usr/bin/grep -q "installed:\|updated:")'

echo "== a file you wrote yourself, under the same name, is never ours to overwrite"
printf 'my own command, not wolfmuxs own\n' >"$COMMANDS_DIR/team-approvals.md"
run_install >"$WORK/install-3.log" 2>&1
check "install.sh says it kept your file, and why" '/usr/bin/grep -q "kept your existing.*team-approvals.md" "$WORK/install-3.log"'
check "your content is untouched" '[ "$(/bin/cat "$COMMANDS_DIR/team-approvals.md")" = "my own command, not wolfmuxs own" ]'

echo "== a stale copy of OUR OWN file (you never touched it) is updated"
/bin/cp "$SRC/teamctl.md" "$WORK/teamctl-repo-orig.md"
printf '%s\n' '---' 'description: changed for the test' '---' 'teamctl $ARGUMENTS' >"$SRC/teamctl.md"
run_install >"$WORK/install-4.log" 2>&1
check "install.sh says it updated the stale file" '/usr/bin/grep -q "updated:.*teamctl.md" "$WORK/install-4.log"'
check "the installed file now carries the new content" '/usr/bin/grep -q "changed for the test" "$COMMANDS_DIR/teamctl.md"'
/bin/cp "$WORK/teamctl-repo-orig.md" "$SRC/teamctl.md"

echo "== --no-claude-commands skips the step entirely"
NOCMD="$WORK/home2"
env WOLFMUX_INSTALL_HOME="$NOCMD" $SOCKETS "$REPO/install.sh" --no-path --no-codex-rules --no-notifier-app --no-claude-commands >"$WORK/install-5.log" 2>&1
check "no ~/.claude/commands/ directory is created" '[ ! -d "$NOCMD/.claude/commands" ]'

echo
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
