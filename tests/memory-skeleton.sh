#!/bin/bash
# memory-skeleton.sh — the memory skeleton (config/wolfmux/memory-skeleton/) and its tool,
# bin/mem: every subcommand's main path and its refusals.
#
# Fully isolated: every tree is a copy of the skeleton under one mktemp -d folder, HOME points
# into it (migrate writes ~/.wolfmux/backups), and Jev is a local python http.server mock that
# records what it was sent. No network, no Keychain, nothing outside $WORK. Needs python3.
#
#   tests/memory-skeleton.sh
# No pipefail: checks end in `grep -q`, which closes the pipe early by design.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
SKEL="$REPO/config/wolfmux/memory-skeleton"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-mem.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
export HOME="$WORK/home"
/bin/mkdir -p "$HOME"
# Run from an agent's pane, the environment may carry a real tree or a real clock: all dropped.
unset MEM_ROOT MEM_NOW MEM_PYTHON MEM_LOCK_WAIT MEM_LOCK_HELD MEM_SHARED_FOLDER MEM_JEV_URL MEM_JEV_KEY MEM_JEV_BACKOFF
# Jev is never the real one here: the key is a dummy and the URL is the mock (set once it runs).
export MEM_JEV_KEY="test-key-not-real"
export MEM_JEV_URL="http://127.0.0.1:9/never-started"
export MEM_JEV_BACKOFF=0

passed=0
failed=0
# The body runs in a SUBSHELL, as in tests/disk.sh: a failing check must be able to fail
# without taking the suite with it.
check() { # <description> <command string>
  if ( eval "$2" ) >/dev/null 2>&1; then
    passed=$((passed + 1))
    printf '  pass  %s\n' "$1"
  else
    failed=$((failed + 1))
    printf '  FAIL  %s\n' "$1"
  fi
}

MOCK_PID=""
cleanup() {
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" >/dev/null 2>&1
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT

# fresh <dir>: a copy of the skeleton, initialised, as `teamctl memory enable` makes it.
fresh() {
  /bin/rm -rf "$1"
  /bin/cp -R "$SKEL" "$1"
  "$1/bin/mem" init >/dev/null
}
# mode_of <path>: the permission bits, octal (BSD stat on macOS, GNU stat elsewhere).
mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
# topic <tree> <name> <keywords> [importance] [last_confirmed]: a topics file with a full header.
topic() {
  printf -- '---\nname: %s\nregion: topics\nkeywords: %s\nsummary: about %s\nlinks:\nimportance: %s\nlast_confirmed: %s\nstatus: live\n---\nbody of %s\n' \
    "$2" "$3" "$2" "${4:-3}" "${5:-2026-10-01}" "$2" >"$1/topics/$2.md"
  chmod 600 "$1/topics/$2.md"
}

echo "== the skeleton and init"
check "the skeleton has MEMORY.md, core/boot.md, .meta/schema.md and bin/mem" \
  '[ -f "$SKEL/MEMORY.md" ] && [ -f "$SKEL/core/boot.md" ] && [ -f "$SKEL/.meta/schema.md" ] && [ -x "$SKEL/bin/mem" ]'
check "every empty region and state folder carries a .keep" \
  'for d in state rules people teams topics ledger archive; do [ -f "$SKEL/$d/.keep" ] || exit 1; done'
T="$WORK/init"
/bin/rm -rf "$T"; /bin/cp -R "$SKEL" "$T"
INIT1="$("$T/bin/mem" init 2>&1)"; RC1=$?
check "init on a fresh copy exits 0 and creates the state files" \
  '[ "$RC1" -eq 0 ] && for s in open-asks watches cursors crons machine; do [ -f "$T/state/$s.json" ] || exit 1; done'
check "init writes the first card" '[ -f "$T/core/card.md" ] && grep -q "^next: read core/boot.md" "$T/core/card.md"'
check "init sets the root and folders to 700 and files to 600" \
  '[ "$(mode_of "$T")" = 700 ] && [ "$(mode_of "$T/rules")" = 700 ] && [ "$(mode_of "$T/state/cursors.json")" = 600 ] && [ "$(mode_of "$T/MEMORY.md")" = 600 ] && [ "$(mode_of "$T/bin/mem")" = 700 ]'
echo '{"slack_dm": 5}' >"$T/state/cursors.json"
INIT2="$("$T/bin/mem" init 2>&1)"; RC2=$?
check "init is idempotent: a second run exits 0, creates nothing, keeps state" \
  '[ "$RC2" -eq 0 ] && printf "%s" "$INIT2" | grep -q "nothing was missing" && grep -q "\"slack_dm\": 5" "$T/state/cursors.json"'
check "init refuses a home folder as the root" \
  '! "$T/bin/mem" --root "$HOME" init && [ ! -d "$HOME/.meta" ]'
check "mem runs from any cwd with only PATH and HOME set" \
  '(cd / && env -i PATH="$PATH" HOME="$HOME" "$T/bin/mem" boot) | grep -q "^# Card"'
check "MEM_ROOT points mem at another tree" \
  'fresh "$WORK/other" && MEM_ROOT="$WORK/other" "$T/bin/mem" boot >/dev/null && [ -f "$WORK/other/core/card.md" ]'

echo "== boot"
T="$WORK/boot"
fresh "$T"
i=1
while [ $i -le 7 ]; do
  MEM_NOW="2026-10-0${i}T09:00Z" "$T/bin/mem" ask open --id "ask-$i" --who "person$i" --what "a question number $i" --waiting-on "owner$i" >/dev/null
  i=$((i + 1))
done
long="$(python3 -I -c 'print("x" * 400)')"
i=1
while [ $i -le 12 ]; do
  "$T/bin/mem" set "crons.cron-$i.schedule" "*/20 * * * *" >/dev/null
  "$T/bin/mem" set "crons.cron-$i.prompt_file" "prompts/$long-$i.md" >/dev/null
  i=$((i + 1))
done
"$T/bin/mem" set machine.start.free_pct 50 >/dev/null
CARD="$(MEM_NOW=2026-10-23T10:00Z "$T/bin/mem" boot)"
check "boot prints the card and writes core/card.md with the same text" \
  '[ "$CARD" = "$(cat "$T/core/card.md")" ]'
check "the card stays <= 2,000 bytes with 7 asks and 12 long crons" \
  '[ "$(wc -c <"$T/core/card.md")" -le 2000 ]'
check "the card shows the 5 oldest open asks with who waits on whom, not the 2 newest" \
  'for i in 1 2 3 4 5; do printf "%s" "$CARD" | grep -q "ask-$i since 2026-10-0$i: person$i waits on owner$i" || exit 1; done && ! printf "%s" "$CARD" | grep -q "ask-6" && ! printf "%s" "$CARD" | grep -q "ask-7"'
check "the card lists the crons to re-create and the machine lines" \
  'printf "%s" "$CARD" | grep -q "^crons to re-create (state/crons.json): 12" && printf "%s" "$CARD" | grep -q "^- start: free_pct=50"'
printf 'chat quote\n' | MEM_NOW=2026-10-20T08:00Z "$T/bin/mem" decide --time 2026-10-20T08:00Z --source chat --slug first-call >/dev/null
"$T/bin/mem" set shared-folder "$WORK/shared" >/dev/null
CARD="$(MEM_NOW=2026-10-23T10:00Z "$T/bin/mem" boot)"
check "the card shows the newest decision (slug + time), the ledger count and the shared folder" \
  'printf "%s" "$CARD" | grep -q "^- 2026-10-20T08:00Z first-call" && printf "%s" "$CARD" | grep -q "^ledger files this month: [1-9]" && printf "%s" "$CARD" | grep -q "^shared folder: $WORK/shared"'
check "the card ends with: read core/boot.md next" 'printf "%s\n" "$CARD" | tail -1 | grep -q "^next: read core/boot.md"'

echo "== check"
T="$WORK/check"
fresh "$T"
check "check passes on the clean skeleton" '"$T/bin/mem" check'
check "the regenerated MEMORY.md has the legend, the boot steps, the regions and the ledger pointers" \
  'for h in "## Legend" "## Boot (every start)" "## Rules" "## People" "## Teams" "## Topics" "## Ledger pointers"; do grep -qxF "$h" "$T/MEMORY.md" || exit 1; done && head -1 "$T/MEMORY.md" | grep -q "^# Memory (checked .* by mem check, [0-9]* bytes)"'
printf '%s\n' "$(cat "$T/MEMORY.md")" '- [a](topics/a.md) and [b](topics/b.md) in one line' >"$T/MEMORY.md"
OUT="$("$T/bin/mem" check)"; RC=$?
check "check fails on a hub-of-hubs line in MEMORY.md" \
  '[ "$RC" -eq 1 ] && printf "%s" "$OUT" | grep -q "PROBLEM .*hub-of-hubs"'
check "and the regenerated MEMORY.md has no such line, so the next check passes" '"$T/bin/mem" check'
python3 -I -c 'import sys; open(sys.argv[1], "w").write("# Memory\n" + ("- filler line that is long enough\n" * 180))' "$T/MEMORY.md"
OUT="$("$T/bin/mem" check)"; RC=$?
check "check fails on a 6,000-byte MEMORY.md" '[ "$RC" -eq 1 ] && printf "%s" "$OUT" | grep -q "PROBLEM .*bytes (cap 5000)"'
"$T/bin/mem" check >/dev/null
i=1
while [ $i -le 85 ]; do topic "$T" "filler-$i" "kw$i, other$i"; i=$((i + 1)); done
OUT="$("$T/bin/mem" check)"; RC=$?
check "check fails when the generated index would pass 80 lines" \
  '[ "$RC" -eq 1 ] && printf "%s" "$OUT" | grep -q "PROBLEM .*MEMORY.md (generated) has [0-9]* lines (cap 80)"'
/bin/rm -f "$T"/topics/filler-*.md
printf -- '---\nname: no-summary\nregion: topics\nkeywords: a, b\nlinks:\nimportance: 3\nlast_confirmed: 2026-10-01\nstatus: live\n---\nbody\n' >"$T/topics/no-summary.md"
chmod 600 "$T/topics/no-summary.md"
OUT="$("$T/bin/mem" check)"; RC=$?
check "check fails on a missing header field and names it" \
  '[ "$RC" -eq 1 ] && printf "%s" "$OUT" | grep -q "PROBLEM .*topics/no-summary.md: .*summary"'
/bin/rm -f "$T/topics/no-summary.md"
printf -- '---\nname: bare-rule\nregion: rules\nkeywords: a, b\nsummary: a rule nobody set\nlinks:\nimportance: 3\nlast_confirmed: 2026-10-01\nstatus: live\n---\nbody\n' >"$T/rules/bare-rule.md"
chmod 600 "$T/rules/bare-rule.md"
OUT="$("$T/bin/mem" check)"; RC=$?
check "check fails on a rules file without authority" \
  '[ "$RC" -eq 1 ] && printf "%s" "$OUT" | grep -q "PROBLEM .*rules/bare-rule.md: .*authority"'
/bin/rm -f "$T/rules/bare-rule.md"
check "with those removed, check passes again" '"$T/bin/mem" check'
chmod 644 "$T/state/cursors.json"
OUT="$("$T/bin/mem" check)"; RC=$?
check "check fails on a file with mode 644" '[ "$RC" -eq 1 ] && printf "%s" "$OUT" | grep -q "PROBLEM .*state/cursors.json has mode 644, want 600"'
chmod 600 "$T/state/cursors.json"
topic "$T" "dup-one" "fly, deploy, dev, server"
topic "$T" "dup-two" "fly, deploy, dev, server, plan"
OUT="$("$T/bin/mem" check)"
check "check warns on two files sharing >= 70% of their keywords and names both" \
  'printf "%s" "$OUT" | grep -q "WARN .*topics/dup-one.md and topics/dup-two.md share"'
/bin/rm -f "$T"/topics/dup-*.md
MEM_NOW=2026-09-01T09:00Z "$T/bin/mem" ask open --id stale-ask --who sam --what "an old question" --waiting-on owner >/dev/null
OUT="$(MEM_NOW=2026-10-23T09:00Z "$T/bin/mem" check)"
check "check warns on an open ask untouched for 14 days" 'printf "%s" "$OUT" | grep -q "WARN .*open ask stale-ask untouched for 52 days"'
printf -- '---\nname: sam\nregion: people\nkeywords: sam, design\nsummary: Sam leads design\nlinks:\nimportance: 3\nlast_confirmed: 2026-10-01\nstatus: live\n---\nSam.\n' >"$T/people/sam.md"
chmod 600 "$T/people/sam.md"
printf -- '---\nname: Tone of replies\ndescription: keep replies short\ntype: feedback\n---\nShort replies.\n' >"$T/feedback_tone.md"
printf -- '---\nname: Sam prefers threads\ndescription: answer Sam in the thread\ntype: feedback\n---\nThreads.\n' >"$T/feedback_sam.md"
printf -- '---\nname: Release train\ndescription: the release train schedule\ntype: project\n---\nTrains leave on Monday.\n' >"$T/project_train.md"
OUT="$("$T/bin/mem" check)"; RC=$?
check "check files Claude Code auto-memory: feedback -> rules, feedback naming a person -> people, project -> topics" \
  '[ ! -e "$T/feedback_tone.md" ] && [ ! -e "$T/feedback_sam.md" ] && [ ! -e "$T/project_train.md" ] && [ -f "$T/rules/tone-of-replies.md" ] && [ -f "$T/people/sam-prefers-threads.md" ] && [ -f "$T/topics/release-train.md" ]'
check "a filed auto-memory file gets the missing header fields and keeps its body" \
  'f="$T/topics/release-train.md" && grep -q "^region: topics" "$f" && grep -q "^keywords: " "$f" && grep -q "^summary: the release train schedule" "$f" && grep -q "^last_confirmed: " "$f" && tail -1 "$f" | grep -qx "Trains leave on Monday."'
check "a feedback filed into rules has no authority yet, so check fails until the owner gives one" \
  '[ "$RC" -eq 1 ] && printf "%s" "$OUT" | grep -q "PROBLEM .*rules/tone-of-replies.md: no authority"'

echo
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
