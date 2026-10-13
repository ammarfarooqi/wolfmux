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
# N itself must be at least 1 before any "every file matches" check means anything —
# "every one of zero files agrees" is true by vacuous logic, not by anything install.sh
# did. This guard is what ea6509f's empty config/wolfmux/commands/ exposed: every
# per-file check below passed there for having nothing to disagree about.
check "config/wolfmux/commands/ actually has command files to install (N >= 1)" "[ \"$N\" -ge 1 ]"
run_install >"$WORK/install-1.log" 2>&1
check "every command file in config/wolfmux/commands/ lands in ~/.claude/commands/" "[ \"$N\" -ge 1 ] && [ \"\$(count "$COMMANDS_DIR")\" = \"$N\" ]"
check "the manifest records one hash per installed file" "[ \"\$(/usr/bin/wc -l <"$MANIFEST" | /usr/bin/tr -d ' ')\" = \"$N\" ]"
out=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  /usr/bin/cmp -s "$SRC/$name.md" "$COMMANDS_DIR/$name.md" || out="$out $name"
done <<EOF
$NAMES
EOF
check "every installed file matches its source byte for byte" "[ \"$N\" -ge 1 ] && [ -z \"$out\" ]"
check "the generic /teamctl command passes its arguments straight through" "/usr/bin/grep -q 'teamctl \$ARGUMENTS' '$COMMANDS_DIR/teamctl.md'"
check "/team-destroy shows the teams first and asks before the real command" "/usr/bin/grep -qi 'ask the user' '$COMMANDS_DIR/team-destroy.md' && /usr/bin/grep -q 'teamctl teams' '$COMMANDS_DIR/team-destroy.md'"
check "/team-prune asks before anything but --dry-run" "/usr/bin/grep -qi 'ask the user' '$COMMANDS_DIR/team-prune.md' && /usr/bin/grep -q -- '--dry-run' '$COMMANDS_DIR/team-prune.md'"

echo "== a second run is idempotent"
# Snapshot every installed file's mtime and hash before the second run. Checking only
# the log output passes vacuously wherever nothing was ever installed (e.g. the old
# install.sh on a tree with no ~/.claude/commands/ at all) — asserting against the
# files themselves can only pass where a first install actually happened.
snapshot="$WORK/snapshot-1"
: >"$snapshot"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  f="$COMMANDS_DIR/$name.md"
  [ -f "$f" ] && printf '%s %s %s\n' "$name" "$(stat -f '%m' "$f")" "$(shasum -a 256 "$f" | cut -d' ' -f1)" >>"$snapshot"
done <<EOF
$NAMES
EOF
check "every command file exists before the second run (so the next check cannot pass vacuously)" "[ \"$N\" -ge 1 ] && [ \"\$(/usr/bin/wc -l <\"$snapshot\" | /usr/bin/tr -d ' ')\" = \"$N\" ]"
run_install >"$WORK/install-2.log" 2>&1
unchanged=1
while IFS=' ' read -r name mtime hash; do
  [ -n "$name" ] || continue
  f="$COMMANDS_DIR/$name.md"
  if [ ! -f "$f" ]; then
    unchanged=0
    break
  fi
  now_mtime="$(stat -f '%m' "$f")"
  now_hash="$(shasum -a 256 "$f" | cut -d' ' -f1)"
  if [ "$now_mtime" != "$mtime" ] || [ "$now_hash" != "$hash" ]; then
    unchanged=0
    break
  fi
done <"$snapshot"
check "a second run leaves every installed file's mtime and hash exactly as the first run left it" "[ \"$N\" -ge 1 ] && [ $unchanged -eq 1 ]"

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
# On the old install.sh, --no-claude-commands is an unknown option: it refuses with
# exit 64 before the step it is meant to skip ever existed. Asserting only the absent
# directory passes there too, for the wrong reason — assert the flag was ACCEPTED as
# well, so this can only pass where the step existed and was actually skipped.
NOCMD="$WORK/home2"
env WOLFMUX_INSTALL_HOME="$NOCMD" $SOCKETS "$REPO/install.sh" --no-path --no-codex-rules --no-notifier-app --no-claude-commands >"$WORK/install-5.log" 2>&1
rc=$?
check "install.sh accepts --no-claude-commands and exits clean" "[ $rc -eq 0 ]"
check "install.sh does not refuse or warn about the flag" '! /usr/bin/grep -qi "unknown option" "$WORK/install-5.log"'
check "no ~/.claude/commands/ directory is created" '[ ! -d "$NOCMD/.claude/commands" ]'

echo
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
