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
# MEM_TEST=1 lets drain and backup pruning run on the pinned MEM_NOW clock the checks use.
export MEM_TEST=1
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
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" >/dev/null 2>&1 && wait "$MOCK_PID" 2>/dev/null
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT
[ -n "${MEM_TEST_KEEP:-}" ] && trap - EXIT

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

# tree_sum <dir>: one digest over every path, its bytes and its mtime: equal means untouched.
tree_sum() {
  python3 -I - "$1" <<'EOF'
import hashlib, os, sys
h = hashlib.sha256()
for folder, dirs, names in os.walk(sys.argv[1]):
    dirs.sort()
    for name in sorted(names):
        path = os.path.join(folder, name)
        h.update(path.encode() + b"\0" + str(os.lstat(path).st_mtime_ns).encode() + b"\0")
        if os.path.isfile(path) and not os.path.islink(path):
            h.update(open(path, "rb").read())
print(h.hexdigest())
EOF
}
# quote_of <ledger file> <anchor>: the quote of that decision block, byte for byte, on stdout.
quote_of() {
  python3 -I - "$1" "$2" <<'EOF'
import re, sys
data = open(sys.argv[1], "rb").read()
start = data.index(b"\n## " + sys.argv[2].encode() + b"\n") + 1
size = int(re.compile(rb"\nbytes: (\d+)\n").search(data, start).group(1))
fence_start = data.index(b"\n", data.index(b"\nbytes: ", start) + 1) + 1
body_start = data.index(b"\n", fence_start) + 1
sys.stdout.buffer.write(data[body_start:body_start + size])
EOF
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
/bin/mkdir -p "$WORK/foreign/notes"; printf 'mine\n' >"$WORK/foreign/todo.txt"; chmod 755 "$WORK/foreign" "$WORK/foreign/notes"
OUT="$("$T/bin/mem" --root "$WORK/foreign" init 2>&1)"; RC=$?
check "init refuses a non-empty folder with neither .meta/ nor bin/mem, says why, changes nothing" \
  '[ "$RC" -eq 1 ] && printf "%s" "$OUT" | grep -q "neither .meta/ nor bin/mem" && [ ! -e "$WORK/foreign/.meta" ] && [ ! -e "$WORK/foreign/core" ] && [ "$(mode_of "$WORK/foreign")" = 755 ] && [ "$(mode_of "$WORK/foreign/notes")" = 755 ]'
check "init makes a tree of an empty folder and of a folder that does not exist yet" \
  '/bin/mkdir -p "$WORK/empty-root" && "$T/bin/mem" --root "$WORK/empty-root" init >/dev/null && [ -d "$WORK/empty-root/.meta" ] && "$T/bin/mem" --root "$WORK/new-root/t" init >/dev/null && [ -f "$WORK/new-root/t/MEMORY.md" ]'
# A link to bin/mem in a bin folder on PATH: the tree is the folder above the REAL script.
/bin/mkdir -p "$HOME/.local/bin"; chmod 755 "$HOME/.local" "$HOME/.local/bin"
ln -s "$T/bin/mem" "$HOME/.local/bin/mem"
OUT="$("$HOME/.local/bin/mem" init 2>&1)"; RC=$?
check "through a symlinked \$0, init and boot work on the real tree, never on the link's folder" \
  '[ "$RC" -eq 0 ] && printf "%s" "$OUT" | grep -q "^mem init: $T is ready" && "$HOME/.local/bin/mem" boot | grep -q "^# Card" && [ ! -e "$HOME/.local/.meta" ] && [ ! -e "$HOME/.local/MEMORY.md" ] && [ "$(mode_of "$HOME/.local")" = 755 ] && [ "$(mode_of "$HOME/.local/bin")" = 755 ]'
/bin/rm -rf "$HOME/.local"
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
# 200 topics (importance 1..5 in turn, dates spread) and 30 rules: far past 80 lines unless cut.
python3 -I - "$T" <<'EOF'
import os, sys
t = sys.argv[1]
for i in range(1, 201):
    imp, day = (i % 5) + 1, (i % 28) + 1
    with open(os.path.join(t, "topics", "filler-%d.md" % i), "w") as out:
        out.write("---\nname: filler-%d\nregion: topics\nkeywords: kw%d, other%d\nsummary: a filler topic number %d with a summary long enough to take room in the index\n"
                  "links:\nimportance: %d\nlast_confirmed: 2026-10-%02d\nstatus: live\n---\nbody %d\n" % (i, i, i, i, imp, day, i))
    os.chmod(os.path.join(t, "topics", "filler-%d.md" % i), 0o600)
for i in range(1, 31):
    with open(os.path.join(t, "rules", "rule-%d.md" % i), "w") as out:
        out.write("---\nname: rule-%d\nregion: rules\nkeywords: rk%d, rother%d\nsummary: rule number %d\nlinks:\nimportance: 3\nauthority: shared:RULES.md\n"
                  "last_confirmed: 2026-10-%02d\nstatus: live\n---\nrule %d\n" % (i, i, i, i, (i % 28) + 1, i))
    os.chmod(os.path.join(t, "rules", "rule-%d.md" % i), 0o600)
EOF
OUT="$("$T/bin/mem" check)"; RC=$?
check "200 topics and 30 rules: check exits 0, MEMORY.md stays within 80 lines and 5,000 bytes" \
  '[ "$RC" -eq 0 ] && [ "$(wc -l <"$T/MEMORY.md")" -le 80 ] && [ "$(wc -c <"$T/MEMORY.md")" -le 5000 ] && ! printf "%s" "$OUT" | grep -q PROBLEM'
check "the overflow is a WARN per cut region, naming how many are listed" \
  'printf "%s" "$OUT" | grep -q "^WARN .*MEMORY.md lists [0-9]* of 200 live topics (the index caps); mem recall finds the rest" && printf "%s" "$OUT" | grep -q "^WARN .*MEMORY.md lists [0-9]* of 30 live rules"'
check "a cut region ends with ONE line: N more <region>: mem recall <words>" \
  '[ "$(grep -c "^- [0-9]* more topics: mem recall <words>$" "$T/MEMORY.md")" -eq 1 ] && [ "$(grep -c "^- 11 more rules: mem recall <words>$" "$T/MEMORY.md")" -eq 1 ] && n="$(grep -c "(topics/filler-" "$T/MEMORY.md")" && grep -q "^- $((200 - n)) more topics:" "$T/MEMORY.md"'
check "listed topics are the most important first, then the most recently confirmed" \
  'python3 -I - "$T" <<'"'"'EOF'"'"'
import re, sys
t = sys.argv[1]
shown = re.findall(r"\(topics/(filler-\d+)\.md\)", open(t + "/MEMORY.md").read())
def key(name):
    text = open("%s/topics/%s.md" % (t, name)).read()
    return (int(re.search(r"^importance: (\d)", text, re.M).group(1)), re.search(r"^last_confirmed: (\S+)", text, re.M).group(1))
keys = [key(n) for n in shown]
best = sorted((key("filler-%d" % i) for i in range(1, 201)), reverse=True)[:len(keys)]
sys.exit(not (keys and keys == sorted(keys, reverse=True) and keys == best and all(k[0] == 5 for k in keys)))
EOF'
check "the caps are written in schema.md" 'grep -q "rules 20, people 8, teams 6, topics 12" "$SKEL/.meta/schema.md"'
/bin/rm -f "$T"/topics/filler-*.md "$T"/rules/rule-*.md
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
check "that warning names the ask id and the days only, never who asked or who is waited on" \
  '[ "$(printf "%s\n" "$OUT" | grep "open ask stale-ask")" = "WARN    open ask stale-ask untouched for 52 days" ]'
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
printf -- '---\nname: suite-tmpdir\ndescription: leave TMPDIR alone for suite runs\nmetadata:\n  type: reference\n---\nShort TMPDIR.\n' >"$T/suite-tmpdir.md"
"$T/bin/mem" check >/dev/null
check "the newer auto-memory shape (type: nested under metadata:) is filed too" \
  '[ ! -e "$T/suite-tmpdir.md" ] && [ -f "$T/topics/suite-tmpdir.md" ] && grep -q "^summary: leave TMPDIR alone for suite runs" "$T/topics/suite-tmpdir.md"'
check "a feedback filed into rules has no authority yet, so check fails until the owner gives one" \
  '[ "$RC" -eq 1 ] && printf "%s" "$OUT" | grep -q "PROBLEM .*rules/tone-of-replies.md: no authority"'


echo "== recall"
T="$WORK/recall"
fresh "$T"
topic "$T" fly-dev "fly, deploy, dev" 3 2026-10-20
topic "$T" fly-prod "fly, deploy, prod" 5 2026-10-20
topic "$T" slack-tone "slack, tone" 3 2026-10-20
topic "$T" old-notes "notes, fly" 2 2026-01-01
topic "$T" new-notes "notes, fly" 2 2026-10-22
OUT="$(MEM_NOW=2026-10-23T09:00Z "$T/bin/mem" recall fly deploy)"
check "recall ranks equal hits by importance: fly-prod (5) before fly-dev (3)" \
  '[ "$(printf "%s\n" "$OUT" | sed -n 1p)" = "topics/fly-prod.md: about fly-prod" ] && [ "$(printf "%s\n" "$OUT" | sed -n 2p)" = "topics/fly-dev.md: about fly-dev" ]'
check "recall leaves out files with no hit" '! printf "%s" "$OUT" | grep -q slack-tone'
OUT="$(MEM_NOW=2026-10-23T09:00Z "$T/bin/mem" recall fly dev)"
check "recall ranks more hits first: fly-dev (fly + dev) before fly-prod (fly)" \
  'printf "%s\n" "$OUT" | sed -n 1p | grep -q "^topics/fly-dev.md"'
OUT="$(MEM_NOW=2026-10-23T09:00Z "$T/bin/mem" recall notes)"
check "recall ranks equal hits and importance by last_confirmed: the newer first" \
  'printf "%s\n" "$OUT" | sed -n 1p | grep -q "^topics/new-notes.md" && printf "%s\n" "$OUT" | sed -n 2p | grep -q "^topics/old-notes.md"'
i=1
while [ $i -le 8 ]; do topic "$T" "many-$i" "many, things$i" 3 2026-10-20; i=$((i + 1)); done
OUT="$("$T/bin/mem" recall many)"
check "recall prints at most 5 lines, about 500 characters" \
  '[ "$(printf "%s\n" "$OUT" | wc -l | tr -d " ")" -eq 5 ] && [ "$(printf "%s" "$OUT" | wc -c | tr -d " ")" -le 520 ]'
check "recall with no hit says so and exits 1" '! "$T/bin/mem" recall zebra-nothing && "$T/bin/mem" recall zebra-nothing | grep -q "no match"'
SH="$WORK/shared-recall"
/bin/mkdir -p "$SH/rules"
printf -- '- [Deploy windows](rules/deploy-windows.md) when the shared deploys run\n' >"$SH/MEMORY.md"
printf -- '---\nname: deploy-windows\nkeywords: deploy, window\nsummary: shared deploy windows\n---\nbody\n' >"$SH/rules/deploy-windows.md"
"$T/bin/mem" set shared-folder "$SH" >/dev/null
SUM_BEFORE="$(tree_sum "$SH")"
OUT="$("$T/bin/mem" recall deploy window --shared)"
check "recall --shared finds the shared folder's files and labels them SHARED" \
  'printf "%s" "$OUT" | grep -q "^SHARED $SH/rules/deploy-windows.md: shared deploy windows"'
check "recall --shared never writes the shared folder" '[ "$SUM_BEFORE" = "$(tree_sum "$SH")" ]'
check "recall without --shared shows no SHARED line" '! "$T/bin/mem" recall deploy window | grep -q SHARED'
/bin/mkdir -p "$T/archive/2026-08/topics"
printf -- '---\nname: gone-topic\nregion: topics\nkeywords: zeppelin\nsummary: an archived zeppelin note\nlinks:\nimportance: 2\nlast_confirmed: 2026-06-01\nstatus: live\n---\nold\n' >"$T/archive/2026-08/topics/gone-topic.md"
check "recall --archive finds archived files and labels them ARCHIVE; plain recall does not" \
  '"$T/bin/mem" recall zeppelin --archive | grep -q "^ARCHIVE archive/2026-08/topics/gone-topic.md" && ! "$T/bin/mem" recall zeppelin'

echo "== add"
T="$WORK/add"
fresh "$T"
OUT="$(printf 'Line one.\nThe deploy goes at noon.\nLine three.\n' | MEM_NOW=2026-10-01T09:00Z "$T/bin/mem" add --region topics --name deploys --keywords "deploy, fly, noon" --summary "when deploys go out")"
check "add of a new name says ADD and writes header + body" \
  '[ "$OUT" = "ADD topics/deploys.md" ] && grep -q "^last_confirmed: 2026-10-01" "$T/topics/deploys.md" && grep -qx "The deploy goes at noon." "$T/topics/deploys.md"'
check "add writes the file mode 600 and lists it in MEMORY.md" \
  '[ "$(mode_of "$T/topics/deploys.md")" = 600 ] && grep -q "^- \[deploys\](topics/deploys.md) when deploys go out" "$T/MEMORY.md"'
OUT="$(printf 'The deploy goes at 14:00 UTC.\n' | MEM_NOW=2026-10-05T09:00Z "$T/bin/mem" add --region topics --name deploys --keywords "deploy, fly, noon" --summary "when deploys go out" --replace "The deploy goes at noon.")"
check "add with the same name says UPDATE and sets last_confirmed to today" \
  'printf "%s" "$OUT" | grep -q "^UPDATE topics/deploys.md (same name" && grep -q "^last_confirmed: 2026-10-05" "$T/topics/deploys.md"'
check "a correction replaces the old sentence in place; nothing is appended" \
  'python3 -I -c "import sys; d=open(sys.argv[1]).read(); b=d.split(\"---\n\",2)[2]; sys.exit(b != \"Line one.\nThe deploy goes at 14:00 UTC.\nLine three.\n\")" "$T/topics/deploys.md"'
OUT="$(MEM_NOW=2026-10-05T10:00Z "$T/bin/mem" add --region topics --name deploys --keywords "deploy, fly, noon" --summary "when deploys go out" </dev/null)"
check "add with nothing new on the same day says NOOP and changes nothing" '[ "$OUT" = "NOOP topics/deploys.md (nothing new; confirmed today already)" ]'
SUM_BEFORE="$(tree_sum "$T")"
OUT="$(printf 'A whole new body.\n' | MEM_NOW=2026-10-06T10:00Z "$T/bin/mem" add --region topics --name deploy-times --keywords "deploy, fly, noon, times" --summary "deploy times" 2>&1)"; RC=$?
check "add of a new name with >= 70% keyword overlap names the candidate, writes nothing, and exits 1" \
  '[ "$RC" -eq 1 ] && printf "%s" "$OUT" | grep -q "^CANDIDATE topics/deploys.md (keywords overlap 75% with --name deploy-times)" && printf "%s" "$OUT" | grep -q "use --name deploys to update it, or --supersedes deploys" && [ ! -e "$T/topics/deploy-times.md" ] && [ "$SUM_BEFORE" = "$(tree_sum "$T")" ]'
OUT="$(printf 'Line one.\nDeploys go at 14:00 UTC, on weekdays.\n' | MEM_NOW=2026-10-06T10:00Z "$T/bin/mem" add --region topics --name deploys --keywords "deploy, fly, noon, times" --summary "deploy times")"
check "the same add under the matched name is an UPDATE that carries its body" \
  '[ "$OUT" = "UPDATE topics/deploys.md (same name)" ] && python3 -I -c "import sys; d=open(sys.argv[1]).read(); sys.exit(d.split(\"---\n\",2)[2] != \"Line one.\nDeploys go at 14:00 UTC, on weekdays.\n\" or \"\nsummary: deploy times\n\" not in d)" "$T/topics/deploys.md"'
SUM_BEFORE="$(tree_sum "$T")"
OUT="$(echo body | "$T/bin/mem" add --region topics --name brand-new --keywords "zinc, copper" --summary "metals" --dry-run)"
check "add --dry-run shows the decision and writes nothing" '[ "$OUT" = "would ADD topics/brand-new.md" ] && [ "$SUM_BEFORE" = "$(tree_sum "$T")" ]'
OUT="$(echo "Deploys now go through the release train." | MEM_NOW=2026-10-07T09:00Z "$T/bin/mem" add --region topics --name release-train --keywords "train, release" --summary "deploys ride the release train" --supersedes deploys)"
check "add --supersedes says SUPERSEDE, writes the new file and marks the old one" \
  '[ "$OUT" = "SUPERSEDE topics/release-train.md replaces topics/deploys.md" ] && grep -q "^status: superseded:release-train" "$T/topics/deploys.md" && grep -q "^superseded_on: 2026-10-07" "$T/topics/deploys.md" && [ -f "$T/topics/release-train.md" ]'
check "MEMORY.md lists the new file and leaves the superseded one out" \
  'grep -q "(topics/release-train.md)" "$T/MEMORY.md" && ! grep -q "(topics/deploys.md)" "$T/MEMORY.md"'
H="$WORK/header"
fresh "$H"
# kept_header <last_confirmed> <status lines> <body>: a header with a comment line and a folded block.
kept_header() {
  printf -- '---\nname: kept\n# the owner asked for this note\nregion: topics\nkeywords: kept, header, comment\nsummary: a header with a comment\nlinks:\nimportance: 3\nlast_confirmed: %s\n%bcontext: >-\n  a folded block\n  over two lines\n---\n%b' "$1" "$2" "$3"
}
kept_header 2026-10-01 'status: live\n' 'Old body.\n' >"$H/topics/kept.md"
printf 'New body.\n' | MEM_NOW=2026-10-06T10:00Z "$H/bin/mem" add --region topics --name kept --keywords "kept, header, comment" --summary "a header with a comment" >/dev/null
kept_header 2026-10-06 'status: live\n' 'New body.\n' >"$WORK/kept-update.md"
check "an UPDATE rewrites only the changed header line; a comment line and a folded block stay byte for byte" \
  'cmp -s "$WORK/kept-update.md" "$H/topics/kept.md"'
echo "Kept, but newer." | MEM_NOW=2026-10-07T09:00Z "$H/bin/mem" add --region topics --name kept-two --keywords "newer, kept" --summary "the newer one" --supersedes kept >/dev/null
kept_header 2026-10-06 'status: superseded:kept-two\nsuperseded_on: 2026-10-07\n' 'New body.\n' >"$WORK/kept-superseded.md"
check "a supersede edits status in place and puts superseded_on after it; the comment and the block stay" \
  'cmp -s "$WORK/kept-superseded.md" "$H/topics/kept.md"'
OUT="$(echo "Never send at night." | "$T/bin/mem" add --region rules --name quiet-hours --keywords "night, send" --summary "no sends at night" 2>&1)"; RC=$?
check "add --region rules without --authority is refused and writes nothing" \
  '[ "$RC" -eq 1 ] && printf "%s" "$OUT" | grep -q "rules need --authority" && [ ! -e "$T/rules/quiet-hours.md" ]'
REF="$(printf 'No sends at night.' | MEM_NOW=2026-10-08T09:00Z "$T/bin/mem" decide --time 2026-10-08T09:00Z --source chat)"
OUT="$(echo "Never send at night." | MEM_NOW=2026-10-08T09:01Z "$T/bin/mem" add --region rules --name quiet-hours --keywords "night, send" --summary "no sends at night" --authority "$REF")"
check "add --region rules with the authority mem decide printed is accepted and check passes" \
  '[ "$OUT" = "ADD rules/quiet-hours.md" ] && grep -q "^authority: decisions-2026-10#2026-10-08T09:00Z" "$T/rules/quiet-hours.md" && "$T/bin/mem" check'
check "add refuses a name another region already has" \
  '! echo x | "$T/bin/mem" add --region people --name quiet-hours --keywords "q, r" --summary "clash" && [ ! -e "$T/people/quiet-hours.md" ]'
check "add refuses a name that is not a slug (no path tricks)" \
  '! echo x | "$T/bin/mem" add --region topics --name "../escape" --keywords "q" --summary "s" && [ ! -e "$WORK/escape.md" ]'
LONG80="$(printf 'a%.0s' $(seq 1 69))-long-names"   # 80 characters
check "add takes an 80-character name; MEMORY.md keeps the whole path, cuts the link text, stays within 120 characters" \
  'echo x | "$T/bin/mem" add --region topics --name "$LONG80" --keywords "longname" --summary "a summary long enough to be cut down in the index line" >/dev/null && LINE="$(grep -F "(topics/$LONG80.md)" "$T/MEMORY.md")" && python3 -I -c "import sys; sys.exit(len(sys.argv[1]) > 120)" "$LINE" && printf "%s" "$LINE" | grep -q "^- \[a*…\](topics/$LONG80.md) a summary" && "$T/bin/mem" check'
check "add refuses an 81-character name" \
  '! echo x | "$T/bin/mem" add --region topics --name "${LONG80}x" --keywords "q" --summary "s" 2>/dev/null && [ ! -e "$T/topics/${LONG80}x.md" ]'

echo "== set"
T="$WORK/set"
fresh "$T"
"$T/bin/mem" set cursors.slack_dm 1761000000 >/dev/null
"$T/bin/mem" set cursors.beads_fe.last "bd-42" >/dev/null
MEM_NOW=2026-10-23T09:00Z "$T/bin/mem" set machine.start.free_pct 50 >/dev/null
check "set writes a dotted path into the state file, as JSON" \
  'python3 -I -c "import json,sys; c=json.load(open(sys.argv[1])); m=json.load(open(sys.argv[2])); sys.exit(not (c[\"slack_dm\"] == 1761000000 and c[\"beads_fe\"][\"last\"] == \"bd-42\" and m[\"start\"] == {\"free_pct\": 50, \"set_at\": \"2026-10-23T09:00Z\"}))" "$T/state/cursors.json" "$T/state/machine.json"'
"$T/bin/mem" set cursors.slack_dm 1761000099 >/dev/null
check "set keeps the other keys when it changes one" \
  'python3 -I -c "import json,sys; c=json.load(open(sys.argv[1])); sys.exit(not (c[\"slack_dm\"] == 1761000099 and c[\"beads_fe\"][\"last\"] == \"bd-42\"))" "$T/state/cursors.json"'
"$T/bin/mem" ask open --id a1 --who sam --what "a question" --waiting-on owner >/dev/null
"$T/bin/mem" set open-asks.a1.next_check 2026-10-30T09:00Z >/dev/null
"$T/bin/mem" set crons.sweep.schedule "*/20 * * * *" >/dev/null
"$T/bin/mem" set crons.sweep.enabled false >/dev/null
check "set edits open-asks and crons entries by id" \
  'python3 -I -c "import json,sys; a=json.load(open(sys.argv[1])); c=json.load(open(sys.argv[2])); sys.exit(not (a[0][\"next_check\"] == \"2026-10-30T09:00Z\" and c == [{\"name\": \"sweep\", \"schedule\": \"*/20 * * * *\", \"enabled\": False}]))" "$T/state/open-asks.json" "$T/state/crons.json"'
"$T/bin/mem" set cursors.gmail 42 --string >/dev/null
check "set --string keeps a number-looking value a string" 'grep -q "\"gmail\": \"42\"" "$T/state/cursors.json"'
check "set refuses an unknown state file, an ask that does not exist, and a bare file name" \
  '! "$T/bin/mem" set nothing.key 1 && ! "$T/bin/mem" set open-asks.nope.what x && ! "$T/bin/mem" set cursors 1'

echo "== decide, sent, ask, sweep-log"
T="$WORK/ledger"
fresh "$T"
printf 'First: keep it short.\n' >"$WORK/q1"
REF1="$(MEM_NOW=2026-10-09T13:55Z "$T/bin/mem" decide --time 2026-10-09T13:50Z --source chat <"$WORK/q1")"
check "decide prints the authority ref" '[ "$REF1" = "decisions-2026-10#2026-10-09T13:50Z" ]'
check "decide writes the quote verbatim (bytes compared)" 'quote_of "$T/ledger/decisions-2026-10.md" 2026-10-09T13:50Z | cmp -s - "$WORK/q1"'
printf 'Use ```code``` and ````more````,  trailing spaces  \r\nüñí, no newline at the end' >"$WORK/q2"
BEFORE="$(cat "$T/ledger/decisions-2026-10.md")"
REF2="$(MEM_NOW=2026-10-09T13:56Z "$T/bin/mem" decide --time 2026-10-09T13:50Z --source slack:1760017800.123 <"$WORK/q2")"
check "a second decision in the same minute gets -2" '[ "$REF2" = "decisions-2026-10#2026-10-09T13:50Z-2" ]'
check "backticks, CRLF, unicode and a missing final newline survive byte for byte" \
  'quote_of "$T/ledger/decisions-2026-10.md" 2026-10-09T13:50Z-2 | cmp -s - "$WORK/q2"'
check "the ledger is append-only: the earlier text is an exact prefix" \
  'python3 -I -c "import sys; d=open(sys.argv[1],\"rb\").read(); b=open(sys.argv[2],\"rb\").read(); sys.exit(not d.startswith(b.rstrip(b\"\n\")))" "$T/ledger/decisions-2026-10.md" <(printf "%s" "$BEFORE")'
check "the block records the source and the byte count" \
  'grep -q "^source: slack:1760017800.123" "$T/ledger/decisions-2026-10.md" && grep -q "^bytes: $(wc -c <"$WORK/q2" | tr -d " ")$" "$T/ledger/decisions-2026-10.md"'
check "decide refuses a bad source and an empty quote" \
  '! printf x | "$T/bin/mem" decide --time 2026-10-09T13:50Z --source email && ! "$T/bin/mem" decide --time 2026-10-09T13:50Z --source chat </dev/null'
SH="$WORK/shared-decide"
/bin/mkdir -p "$SH"
printf '# Shared rules\n- one\n' >"$SH/RULES.md"
"$T/bin/mem" set shared-folder "$SH" >/dev/null
printf -- '---\nname: shared-rules\nregion: rules\nkeywords: shared, rules\nsummary: the shared rules file\nlinks:\nimportance: 4\nauthority: shared:RULES.md\nlast_confirmed: 2026-10-01\nstatus: live\npointer: %s\n---\nSee the shared file.\n' "$SH/RULES.md" >"$T/rules/shared-rules.md"
chmod 600 "$T/rules/shared-rules.md"
SUM_BEFORE="$(tree_sum "$SH")"
OUT="$(printf 'Add rule two.' | MEM_NOW=2026-10-10T08:00Z "$T/bin/mem" decide --time 2026-10-10T08:00Z --source bead:x-1 --shared RULES.md)"
check "decide --shared prints the exact edit for the shared file, with the ref" \
  'printf "%s" "$OUT" | grep -q "^shared file (mem never writes there; edit it yourself): $SH/RULES.md" && printf "%s" "$OUT" | grep -q "suggested line, under its rule: .*decisions-2026-10#2026-10-10T08:00Z.*Add rule two."'
check "decide --shared never writes into the shared folder" '[ "$SUM_BEFORE" = "$(tree_sum "$SH")" ]'
check "decide --shared refreshes the matching pointer file's last_confirmed" 'grep -q "^last_confirmed: 2026-10-10" "$T/rules/shared-rules.md"'
OUT="$(MEM_NOW=2026-10-11T08:00Z "$T/bin/mem" sent --to sam --channel slack-dm --ref https://example.slack.com/p1 --subject "the deploy plan")"
check "sent appends one line: time, to, channel, ref, subject" \
  'grep -qxF -e "- 2026-10-11T08:00Z | to: sam | channel: slack-dm | ref: https://example.slack.com/p1 | the deploy plan" "$T/ledger/sends-2026-10.md"'
check "sent refuses a subject of two lines" '! "$T/bin/mem" sent --to sam --channel c --ref r --subject "$(printf "a\nb")"'
MEM_NOW=2026-10-12T08:00Z "$T/bin/mem" ask open --id q-1 --who sam --what "send the logo" --waiting-on dana --next-check 2026-10-13T08:00Z >/dev/null
check "ask open adds the ask to state/open-asks.json and the ledger" \
  'python3 -I -c "import json,sys; a=json.load(open(sys.argv[1]))[0]; sys.exit(not (a[\"id\"]==\"q-1\" and a[\"who\"]==\"sam\" and a[\"waiting_on\"]==\"dana\" and a[\"status\"]==\"open\" and a[\"opened\"]==\"2026-10-12T08:00Z\" and a[\"next_check\"]==\"2026-10-13T08:00Z\"))" "$T/state/open-asks.json" && grep -q "^- 2026-10-12T08:00Z | open | q-1 | who: sam | waiting on: dana | send the logo" "$T/ledger/asks-2026-10.md"'
check "ask open refuses an id that exists" '! "$T/bin/mem" ask open --id q-1 --who x --what y --waiting-on z'
MEM_NOW=2026-10-12T09:00Z "$T/bin/mem" ask close --id q-1 --note "logo arrived" >/dev/null
check "ask close marks it closed and logs it" \
  'grep -q "\"status\": \"closed\"" "$T/state/open-asks.json" && grep -q "^- 2026-10-12T09:00Z | close | q-1 | logo arrived" "$T/ledger/asks-2026-10.md"'
check "ask close refuses an ask that is not open" '! "$T/bin/mem" ask close --id q-1 && ! "$T/bin/mem" ask close --id nope'
python3 -I -c "import json,sys; p=sys.argv[1]; a=json.load(open(p)); a.append({'id': 'AFD-1234_v2', 'who': 'sam', 'what': 'migrated', 'opened': '2026-10-01T09:00Z', 'waiting_on': 'owner', 'next_check': None, 'status': 'open', 'updated': '2026-10-01T09:00Z'}); open(p, 'w').write(json.dumps(a, indent=2) + '\n')" "$T/state/open-asks.json"
check "ask close takes a migrated id that is not a slug; ask open still wants a slug; a | in an id is refused" \
  'MEM_NOW=2026-10-12T09:30Z "$T/bin/mem" ask close --id AFD-1234_v2 >/dev/null && grep -q "^- 2026-10-12T09:30Z | close | AFD-1234_v2 |" "$T/ledger/asks-2026-10.md" && ! "$T/bin/mem" ask open --id AFD-9 --who x --what y --waiting-on z 2>/dev/null && ! "$T/bin/mem" ask close --id "a|b" 2>/dev/null'
printf 'The owner pasted an old note:\n## 2026-10-05T10:00Z\nslug: not-a-block\n' | "$T/bin/mem" decide --time 2026-10-04T09:00Z --source chat >/dev/null
REF="$(printf 'A real decision.' | "$T/bin/mem" decide --time 2026-10-05T10:00Z --source chat)"
check "a ## <time> line inside a decision's fence is quote only: the real decision at that time keeps the plain anchor" \
  '[ "$REF" = "decisions-2026-10#2026-10-05T10:00Z" ]'
check "--root counts only before the command; after it, it is the command's own argument" \
  'OUT="$("$T/bin/mem" recall -- --root=nothing-here 2>&1)"; printf "%s" "$OUT" | grep -q "no match" && OUT="$("$T/bin/mem" --root "$WORK/no-such-tree" recall x 2>&1)"; [ $? -eq 1 ] && printf "%s" "$OUT" | grep -q "not a memory tree"'
MEM_NOW=2026-10-12T10:00Z "$T/bin/mem" sweep-log --inboxes 3 --asks-touched 1 --free-pct 41 --swap-gb 2.5 --load 3.2 >/dev/null
check "sweep-log writes one JSON line with the numbers" \
  'python3 -I -c "import json,sys; l=open(sys.argv[1]).read().splitlines(); r=json.loads(l[-1]); sys.exit(not (len(l)==1 and r[\"time\"]==\"2026-10-12T10:00Z\" and r[\"inboxes\"]==3 and r[\"free_pct\"]==41 and r[\"swap_gb\"]==2.5 and r[\"load\"]==3.2))" "$T/ledger/sweeps-2026-10.jsonl"'
check "the ledger files are mode 600" '[ "$(mode_of "$T/ledger/sends-2026-10.md")" = 600 ] && [ "$(mode_of "$T/ledger/sweeps-2026-10.jsonl")" = 600 ]'


echo "== the Jev mock"
# A local stand-in for POST /v1/systemone. It saves every request (headers + raw body) under
# $WORK/jev-got/, and answers by the slug it was sent: "keep" in it -> keep, "border" in it ->
# archive at p=0.65 (under the 0.7 bar), anything else -> archive at p=0.9. $WORK/jev-mode
# holding 429 or 500 makes it fail every request with that status instead.
/bin/mkdir -p "$WORK/jev-got"
echo normal >"$WORK/jev-mode"
cat >"$WORK/jev_mock.py" <<'EOF'
import http.server, json, os, sys
work = sys.argv[1]
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        got = os.path.join(work, "jev-got")
        n = len(os.listdir(got)) + 1
        with open(os.path.join(got, "%03d.json" % n), "w") as out:
            json.dump({"path": self.path, "auth": self.headers.get("Authorization"), "raw": raw.decode("utf-8")}, out)
        mode = open(os.path.join(work, "jev-mode")).read().strip()
        if mode in ("429", "500"):
            self.send_response(int(mode)); self.end_headers(); self.wfile.write(b'{"detail":"busy"}'); return
        odd = {"listbody": b'[1, 2]', "badshape": b'{"answers": {"drain": {"choice": "archive", "probabilities": [0.9]}}}',
               "nan": b'{"answers": {"drain": {"choice": "archive", "probabilities": {"archive": NaN}}}}',
               "badchoice": b'{"answers": {"drain": {"choice": ["archive"], "probabilities": {"archive": 0.9}}}}'}
        if mode in odd:
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(odd[mode]); return
        slug = json.loads(raw)["state"]["slug"]
        choice, p = ("keep", 0.1) if "keep" in slug else (("archive", 0.65) if "border" in slug else ("archive", 0.9))
        rest = (1.0 - p) / 2
        probs = {"keep": rest, "archive": p, "ask-owner": rest} if choice == "archive" else {"keep": 0.8, "archive": p, "ask-owner": 0.1}
        body = json.dumps({"model": "jev-latest", "answers": {"drain": {"type": "choice", "choice": choice,
                           "confidence": 0.8, "probabilities": probs}}}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body)
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
open(os.path.join(work, "jev-port.tmp"), "w").write(str(server.server_address[1]))
os.rename(os.path.join(work, "jev-port.tmp"), os.path.join(work, "jev-port"))
server.serve_forever()
EOF
python3 -I "$WORK/jev_mock.py" "$WORK" >/dev/null 2>&1 &
MOCK_PID=$!
i=0
while [ ! -f "$WORK/jev-port" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
export MEM_JEV_URL="http://127.0.0.1:$(cat "$WORK/jev-port" 2>/dev/null)/v1/systemone"
check "the Jev mock is listening" '[ -f "$WORK/jev-port" ] && kill -0 "$MOCK_PID"'

echo "== drain"
export MEM_NOW=2026-10-23T09:00Z
T="$WORK/drain"
fresh "$T"
printf -- '---\nname: dana-smith\nregion: people\nkeywords: dana, smith\nsummary: Dana Smith runs design\nlinks:\nimportance: 3\nlast_confirmed: 2026-01-01\nstatus: live\n---\nDana.\n' >"$T/people/dana-smith.md"
printf -- '---\nname: old-rule\nregion: rules\nkeywords: old, rule\nsummary: an old rule\nlinks:\nimportance: 1\nauthority: shared:RULES.md\nlast_confirmed: 2026-01-01\nstatus: live\n---\nRule.\n' >"$T/rules/old-rule.md"
for f in stale-a stale-keep stale-border stale-named; do topic "$T" "$f" "$f, things" 3 2026-09-01; done
topic "$T" dana-onboarding "dana, smith, onboarding" 3 2026-09-01
printf 'SECRETBODY dana smith private words\n' >>"$T/topics/dana-onboarding.md"
topic "$T" stale-important "important, things" 4 2026-09-01
topic "$T" fresh-topic "fresh, things" 3 2026-10-20
printf -- '---\nname: old-team\nregion: teams\nkeywords: old, team\nsummary: an old team\nlinks:\nimportance: 2\nlast_confirmed: 2026-08-01\nstatus: live\n---\nTeam.\n' >"$T/teams/old-team.md"
printf -- '---\nname: gone-sup\nregion: topics\nkeywords: gone, sup\nsummary: superseded long ago\nlinks:\nimportance: 3\nlast_confirmed: 2026-10-01\nstatus: superseded:fresh-topic\nsuperseded_on: 2026-10-10\n---\nOld.\n' >"$T/topics/gone-sup.md"
printf -- '---\nname: new-sup\nregion: topics\nkeywords: new, sup\nsummary: superseded lately\nlinks:\nimportance: 3\nlast_confirmed: 2026-10-01\nstatus: superseded:fresh-topic\nsuperseded_on: 2026-10-20\n---\nNew.\n' >"$T/topics/new-sup.md"
chmod 600 "$T"/*/*.md
printf 'We still need stale-named next week.' | "$T/bin/mem" decide --time 2026-10-20T08:00Z --source chat >/dev/null
MEM_NOW=2026-10-09T09:00Z "$T/bin/mem" ask open --id old-ask --who sam --what "old" --waiting-on dana >/dev/null
MEM_NOW=2026-10-10T09:00Z "$T/bin/mem" ask close --id old-ask >/dev/null
MEM_NOW=2026-10-19T09:00Z "$T/bin/mem" ask open --id new-ask --who sam --what "new" --waiting-on dana >/dev/null
MEM_NOW=2026-10-20T09:00Z "$T/bin/mem" ask close --id new-ask >/dev/null
MEM_NOW=2026-08-05T09:00Z "$T/bin/mem" sent --to sam --channel c --ref r --subject "august send" >/dev/null
MEM_NOW=2026-09-05T09:00Z "$T/bin/mem" sent --to sam --channel c --ref r --subject "september send" >/dev/null
for d in 01T08 01T20 02T08 20T08; do
  MEM_NOW="2026-10-${d}:00Z" "$T/bin/mem" sweep-log --inboxes 2 --asks-touched 1 --free-pct 40 --swap-gb 1 --load 2 >/dev/null
done
"$T/bin/mem" set crons.sweep.schedule "*/20 * * * *" >/dev/null
"$T/bin/mem" set machine.start.free_pct 50 >/dev/null
SUM_BEFORE="$(tree_sum "$T")"
GOT_BEFORE="$(ls "$WORK/jev-got" | wc -l | tr -d ' ')"
DRY="$("$T/bin/mem" drain --dry-run)"; RC=$?
check "drain --dry-run exits 0 and moves nothing (tree unchanged, no backup)" '[ "$RC" -eq 0 ] && [ "$SUM_BEFORE" = "$(tree_sum "$T")" ]'
check "the dry run does not call Jev" '[ "$GOT_BEFORE" = "$(ls "$WORK/jev-got" | wc -l | tr -d " ")" ]'
check "the dry run names the rule-4 candidates: stale topics and teams, importance <= 3, not named lately" \
  'for f in topics/stale-a topics/stale-keep topics/stale-border topics/dana-onboarding teams/old-team; do printf "%s" "$DRY" | grep -q "^candidate $f.md (rule 4" || exit 1; done'
check "it never names a file named in the last 30 days of ledger, importance 4, fresh, rules or people" \
  'for f in stale-named stale-important fresh-topic old-rule dana-smith; do ! printf "%s" "$DRY" | grep -q "^candidate .*/$f.md" || exit 1; done && ! printf "%s" "$DRY" | grep -q -e "rules/" -e "people/"'
check "the dry run names rules 1, 2, 3 and 5 too" \
  'printf "%s" "$DRY" | grep -q "^would clear ask old-ask" && ! printf "%s" "$DRY" | grep -q "clear ask new-ask" && printf "%s" "$DRY" | grep -q "^would archive ledger/sends-2026-08.md -> archive/2026-08/ledger/sends-2026-08.md" && ! printf "%s" "$DRY" | grep -q "sends-2026-09" && printf "%s" "$DRY" | grep -q "^would archive 3 sweep lines of ledger/sweeps-2026-10.jsonl" && printf "%s" "$DRY" | grep -q "^would archive topics/gone-sup.md" && ! printf "%s" "$DRY" | grep -q "new-sup"'
OUT="$("$T/bin/mem" drain)"; RC=$?
check "drain takes a backup first" '[ "$RC" -eq 0 ] && printf "%s\n" "$OUT" | sed -n 1p | grep -q "^backup .meta/backups/20261023T090000Z.tar" && [ -f "$T/.meta/backups/20261023T090000Z.tar" ]'
check "rule 4: Jev archive p >= 0.7 moves the file to the archive" \
  '[ ! -e "$T/topics/stale-a.md" ] && [ -f "$T/archive/2026-10/topics/stale-a.md" ] && [ -f "$T/archive/2026-10/topics/dana-onboarding.md" ] && [ -f "$T/archive/2026-10/teams/old-team.md" ]'
check "rule 4: Jev keep, or archive under 0.7, leaves the file and lists it for the digest" \
  '[ -f "$T/topics/stale-keep.md" ] && [ -f "$T/topics/stale-border.md" ] && grep -q "topics/stale-keep.md: rule 4 candidate; Jev keep" "$T/.meta/digest-pending.md" && grep -q "topics/stale-border.md: rule 4 candidate; Jev archive, p(archive)=0.65" "$T/.meta/digest-pending.md"'
check "every move is in archive/index.md and .meta/drain.log" \
  'grep -q "^- 2026-10-23 archive/2026-10/topics/stale-a.md from topics/stale-a.md: rule 4" "$T/archive/index.md" && grep -q "archive topics/stale-a.md -> archive/2026-10/topics/stale-a.md: rule 4: confirmed 52 days ago; Jev archive p=0.90" "$T/.meta/drain.log" && grep -q "rule 4: topics/stale-border.md stays" "$T/.meta/drain.log"'
check "rule 1: the ask closed > 7 days ago leaves state; the newer one stays; the ledger keeps both" \
  '! grep -q old-ask "$T/state/open-asks.json" && grep -q new-ask "$T/state/open-asks.json" && grep -q "close | old-ask" "$T/ledger/asks-2026-10.md"'
check "rule 2: a ledger month older than last month is archived; last month stays" \
  '[ -f "$T/archive/2026-08/ledger/sends-2026-08.md" ] && [ ! -e "$T/ledger/sends-2026-08.md" ] && [ -f "$T/ledger/sends-2026-09.md" ]'
check "rule 3: sweep lines > 14 days old go to the archive; one summary line per day stays" \
  'python3 -I -c "import json,sys; live=[json.loads(l) for l in open(sys.argv[1])]; arch=open(sys.argv[2]).read().splitlines(); s=[r[\"day\"] for r in live if r.get(\"summary\")]; sys.exit(not (s==[\"2026-10-01\",\"2026-10-02\"] and len(arch)==3 and [r[\"time\"] for r in live if not r.get(\"summary\")]==[\"2026-10-20T08:00Z\"] and live[0][\"sweeps\"]==2))" "$T/ledger/sweeps-2026-10.jsonl" "$T/archive/2026-10/ledger/sweeps-2026-10.jsonl"'
check "rule 5: superseded more than 7 days ago is archived; superseded lately stays" \
  '[ -f "$T/archive/2026-10/topics/gone-sup.md" ] && [ -f "$T/topics/new-sup.md" ]'
check "rule 6: rules, people, importance 4+, crons, machine and core are never moved" \
  '[ -f "$T/rules/old-rule.md" ] && [ -f "$T/people/dana-smith.md" ] && [ -f "$T/topics/stale-important.md" ] && [ -f "$T/topics/stale-named.md" ] && grep -q sweep "$T/state/crons.json" && grep -q free_pct "$T/state/machine.json" && [ -f "$T/core/boot.md" ]'
check "Jev was called with the bearer key, model jev-latest and the Choice options keep | archive | ask-owner" \
  'python3 -I -c "import json,sys,glob; g=[json.load(open(f)) for f in sorted(glob.glob(sys.argv[1]+\"/*.json\"))]; b=[json.loads(x[\"raw\"]) for x in g]; sys.exit(not (len(g)==5 and all(x[\"auth\"]==\"Bearer test-key-not-real\" for x in g) and all(y[\"model\"]==\"jev-latest\" and sorted(y[\"questions\"][\"drain\"][\"criteria\"])==[\"archive\",\"ask-owner\",\"keep\"] and y[\"questions\"][\"drain\"][\"type\"]==\"choice\" for y in b)))" "$WORK/jev-got"'
check "Jev gets no person name: dana and smith are masked to person, in the slug and the keywords" \
  '! cat "$WORK"/jev-got/*.json | grep -qi -e dana -e smith && cat "$WORK"/jev-got/*.json | grep -q "person-onboarding"'
check "Jev gets only slug, region, keywords, importance, the two ages and the size: no body, no summary" \
  '! cat "$WORK"/jev-got/*.json | grep -q -e SECRETBODY -e "about stale" && python3 -I -c "import json,sys,glob; s=[sorted(json.loads(json.load(open(f))[\"raw\"])[\"state\"]) for f in glob.glob(sys.argv[1]+\"/*.json\")]; sys.exit(not all(x==[\"days_since_last_confirmed\",\"days_since_last_reference\",\"file_size_bytes\",\"importance\",\"keywords\",\"region\",\"slug\"] for x in s))" "$WORK/jev-got"'
check "every Jev call is kept under .meta/jev/ with what was sent and what came back" \
  '[ "$(ls "$T"/.meta/jev/*.json | wc -l | tr -d " ")" -eq 5 ] && python3 -I -c "import json,sys,glob; a=[json.load(open(f)) for f in glob.glob(sys.argv[1]+\"/*.json\")]; sys.exit(not all(x[\"sent\"][\"model\"]==\"jev-latest\" and x[\"response\"][\"answers\"][\"drain\"][\"choice\"] and x[\"status\"]==200 for x in a))" "$T/.meta/jev"'
check "the key is never written into the tree" '! grep -rq test-key-not-real "$T"'
check "after drain, check passes and MEMORY.md no longer lists the archived files" \
  '"$T/bin/mem" check && ! grep -q "(topics/stale-a.md)" "$T/MEMORY.md"'
check "a second drain finds nothing new to move" '"$T/bin/mem" drain | grep -q -e "nothing to drain" -e "^digest "'
# Jev down: 429 on every try, then 500, then --no-jev, then no key at all. Nothing moves.
T="$WORK/drain-down"
fresh "$T"
topic "$T" stale-x "stale, x" 3 2026-09-01
topic "$T" stale-y "stale, y, why" 3 2026-09-01
chmod 600 "$T"/topics/*.md
echo 429 >"$WORK/jev-mode"
GOT_BEFORE="$(ls "$WORK/jev-got" | wc -l | tr -d ' ')"
OUT="$("$T/bin/mem" drain)"
check "Jev 429: 3 retries (4 tries), then the candidates wait for the digest and nothing moves" \
  '[ "$(( $(ls "$WORK/jev-got" | wc -l) - GOT_BEFORE ))" -eq 4 ] && [ -f "$T/topics/stale-x.md" ] && [ -f "$T/topics/stale-y.md" ] && grep -q "stale-x.md: rule 4 candidate; Jev failed: HTTP 429" "$T/.meta/digest-pending.md" && grep -q "stale-y.md: rule 4 candidate; Jev failed" "$T/.meta/digest-pending.md"'
check "Jev 429: the failure is logged" 'grep -q "rule 4: Jev failed (HTTP 429)" "$T/.meta/drain.log"'
echo 500 >"$WORK/jev-mode"
check "Jev 500: nothing moves" '"$T/bin/mem" drain >/dev/null && [ -f "$T/topics/stale-x.md" ] && [ -f "$T/topics/stale-y.md" ]'
echo normal >"$WORK/jev-mode"
GOT_BEFORE="$(ls "$WORK/jev-got" | wc -l | tr -d ' ')"
check "drain --no-jev never calls Jev and moves no rule-4 file" \
  '"$T/bin/mem" drain --no-jev | grep -q "^digest topics/stale-x.md (rule 4; --no-jev)" && [ "$GOT_BEFORE" = "$(ls "$WORK/jev-got" | wc -l | tr -d " ")" ] && [ -f "$T/topics/stale-x.md" ]'
check "with no key (no MEM_JEV_KEY, no Keychain item) nothing is sent and nothing moves" \
  '(unset MEM_JEV_KEY MEM_JEV_URL; PATH="$WORK/nosec:$PATH"; /bin/mkdir -p "$WORK/nosec"; printf "#!/bin/sh\nexit 44\n" >"$WORK/nosec/security"; chmod +x "$WORK/nosec/security"; "$T/bin/mem" drain | grep -q "no Jev key") && [ "$GOT_BEFORE" = "$(ls "$WORK/jev-got" | wc -l | tr -d " ")" ] && [ -f "$T/topics/stale-x.md" ]'
# A Keychain stand-in that hands out a key and leaves a mark when asked.
/bin/mkdir -p "$WORK/fakesec"
printf '#!/bin/sh\ntouch "%s/fakesec/asked"\necho KEYCHAINSECRET42\n' "$WORK" >"$WORK/fakesec/security"; chmod +x "$WORK/fakesec/security"
OUT="$(unset MEM_JEV_KEY; PATH="$WORK/fakesec:$PATH" "$T/bin/mem" drain 2>&1)"
check "a custom MEM_JEV_URL without MEM_JEV_KEY never gets the Keychain key: the Keychain is not asked, nothing is sent" \
  'printf "%s" "$OUT" | grep -q "^digest topics/stale-x.md (rule 4; MEM_JEV_URL is not https://api.typesafe.ai/v1/systemone and MEM_JEV_KEY is not set" && [ ! -e "$WORK/fakesec/asked" ] && [ "$GOT_BEFORE" = "$(ls "$WORK/jev-got" | wc -l | tr -d " ")" ] && ! grep -rq KEYCHAINSECRET42 "$T" "$WORK/jev-got"'
# A leftover MEM_NOW outside the tests (no MEM_TEST): drain refuses, backup keeps every tar.
T="$WORK/pinned"
fresh "$T"
topic "$T" stale-p "stale, p" 3 2026-01-01
MEM_NOW=2026-10-01T09:00Z "$T/bin/mem" backup >/dev/null
SUM_BEFORE="$(tree_sum "$T")"
OUT="$(env -u MEM_TEST MEM_NOW=2027-06-01T09:00Z "$T/bin/mem" drain 2>&1)"; RC=$?
check "drain with MEM_NOW set and no MEM_TEST=1 refuses and changes nothing" \
  '[ "$RC" -eq 1 ] && printf "%s" "$OUT" | grep -q "^mem: MEM_NOW is set: drain refuses a pinned clock" && [ "$SUM_BEFORE" = "$(tree_sum "$T")" ]'
OUT="$(env -u MEM_TEST MEM_NOW=2027-06-01T09:00Z "$T/bin/mem" backup 2>&1)"; RC=$?
check "backup with MEM_NOW set and no MEM_TEST=1 warns, takes the backup but prunes nothing" \
  '[ "$RC" -eq 0 ] && printf "%s" "$OUT" | grep -q "^mem: warning: MEM_NOW=2027-06-01T09:00Z pins the clock" && printf "%s" "$OUT" | grep -q "^prune skipped: MEM_NOW is set" && [ -f "$T/.meta/backups/20261001T090000Z.tar" ] && [ -f "$T/.meta/backups/20270601T090000Z.tar" ]'
check "with MEM_TEST=1 the same backup prunes the old routine tar" \
  'MEM_NOW=2027-06-02T09:00Z "$T/bin/mem" backup >/dev/null && [ ! -e "$T/.meta/backups/20261001T090000Z.tar" ]'
# A key that cannot go in a header is "no key"; an error is logged by its type name only.
T="$WORK/drain-key"
fresh "$T"
topic "$T" stale-k "stale, k" 3 2026-09-01
BADKEY="$(printf 'bad\nLEAKEDKEY99')"
NL=$'\n'
OUT="$(MEM_JEV_KEY="$BADKEY" "$T/bin/mem" drain 2>&1)"
check "a key with a newline is never sent: the candidate goes to the digest, jev key rejected (format)" \
  'printf "%s" "$OUT" | grep -q "^digest topics/stale-k.md (rule 4; jev key rejected (format))" && grep -q "jev key rejected (format)" "$T/.meta/drain.log" && [ "$GOT_BEFORE" = "$(ls "$WORK/jev-got" | wc -l | tr -d " ")" ] && [ -f "$T/topics/stale-k.md" ]'
check "the bad key reaches no output, log, digest or audit file" \
  '! printf "%s" "$OUT" | grep -q LEAKEDKEY99 && ! grep -rq LEAKEDKEY99 "$T"'
check "a key with a space or a trailing newline is rejected the same way" \
  'MEM_JEV_KEY="bad LEAKEDKEY98" "$T/bin/mem" drain | grep -q "jev key rejected (format)" && MEM_JEV_KEY="LEAKEDKEY97$NL" "$T/bin/mem" drain | grep -q "jev key rejected (format)" && [ "$GOT_BEFORE" = "$(ls "$WORK/jev-got" | wc -l | tr -d " ")" ] && ! grep -rq LEAKEDKEY9 "$T"'
# A 200 with an odd shape: never a move, the candidate waits for the digest, the drain ends cleanly.
for mode in listbody badshape nan badchoice; do
  T="$WORK/drain-odd-$mode"
  fresh "$T"
  topic "$T" stale-o "stale, o" 3 2026-09-01
  printf -- '---\nname: gone-o\nregion: topics\nkeywords: gone, o\nsummary: superseded long ago\nlinks:\nimportance: 3\nlast_confirmed: 2026-10-01\nstatus: superseded:stale-o\nsuperseded_on: 2026-10-10\n---\nOld.\n' >"$T/topics/gone-o.md"
  chmod 600 "$T/topics/gone-o.md"
  "$T/bin/mem" check >/dev/null
  echo "$mode" >"$WORK/jev-mode"
  OUT="$("$T/bin/mem" drain 2>&1)"; RC=$?
  check "Jev 200 with an odd shape ($mode): drain exits 0, nothing moves on rule 4, the candidate goes to the digest" \
    '[ "$RC" -eq 0 ] && [ -f "$T/topics/stale-o.md" ] && printf "%s" "$OUT" | grep -q "^digest topics/stale-o.md (rule 4; Jev failed: malformed answer" && grep -q "stale-o.md: rule 4 candidate; Jev failed: malformed answer" "$T/.meta/digest-pending.md" && ! printf "%s" "$OUT" | grep -q Traceback'
  check "after the odd answer ($mode) the moves made before it are in the index (drain ended with check)" \
    '[ -f "$T/archive/2026-10/topics/gone-o.md" ] && ! grep -q "(topics/gone-o.md)" "$T/MEMORY.md" && grep -q "(topics/stale-o.md)" "$T/MEMORY.md"'
done
echo normal >"$WORK/jev-mode"
T="$WORK/drain-unreachable"
fresh "$T"
topic "$T" stale-u "stale, u" 3 2026-09-01
OUT="$(MEM_JEV_URL="http://127.0.0.1:9/v1/systemone" "$T/bin/mem" drain 2>&1)"
check "Jev unreachable: only the exception's type name is logged, never its text" \
  'printf "%s" "$OUT" | grep -q "^digest topics/stale-u.md (rule 4; Jev failed: URLError; nothing moves)" && grep -q "rule 4: Jev failed (URLError)" "$T/.meta/drain.log" && grep -q "Jev failed: URLError$" "$T/.meta/digest-pending.md" && ! grep -rqi "refused" "$T/.meta/drain.log" "$T/.meta/digest-pending.md" "$T/.meta/jev" && [ -f "$T/topics/stale-u.md" ]'
# Names hidden inside a longer token, and names with accents, are masked too.
T="$WORK/drain-mask"
fresh "$T"
printf -- '---\nname: dana-smith\nregion: people\nkeywords: dana, smith\nsummary: Dana Smith runs design\nlinks:\nimportance: 3\nlast_confirmed: 2026-10-01\nstatus: live\n---\nDana.\n' >"$T/people/dana-smith.md"
printf -- '---\nname: renee-dupont\nregion: people\nkeywords: renee\nsummary: Renée Dupont runs sales\nlinks:\nimportance: 3\nlast_confirmed: 2026-10-01\nstatus: live\n---\nRenée.\n' >"$T/people/renee-dupont.md"
printf -- '---\nname: danasmith-notes\nregion: topics\nkeywords: Renée, DUPONT, danasmith, plans\nsummary: notes\nlinks:\nimportance: 3\nlast_confirmed: 2026-09-01\nstatus: live\n---\nNotes.\n' >"$T/topics/danasmith-notes.md"
chmod 600 "$T"/*/*.md
GOT_BEFORE="$(ls "$WORK/jev-got" | wc -l | tr -d ' ')"
MEM_NOW=2026-10-23T09:00Z "$T/bin/mem" drain >/dev/null 2>&1
check "Jev never sees a name inside a longer token (danasmith) or with accents (Renée): both become person" \
  'python3 -I - "$WORK/jev-got" "$GOT_BEFORE" <<'"'"'EOF'"'"'
import glob, json, sys
got = sorted(glob.glob(sys.argv[1] + "/*.json"))[int(sys.argv[2]):]
state = json.loads(json.load(open(got[0]))["raw"])["state"]
text = json.dumps(state).lower()
sys.exit(not (len(got) == 1 and state["slug"] == "person-notes" and state["keywords"] == ["person", "person", "person", "plans"]
              and not any(w in text for w in ("dana", "smith", "renee", "ren\\u00e9e", "dupont"))))
EOF'

echo "== backup and unarchive"
T="$WORK/backup"
fresh "$T"
MEM_NOW=2026-10-01T09:00Z "$T/bin/mem" backup >/dev/null
MEM_NOW=2026-10-01T09:30Z "$T/bin/mem" backup --note "migration rollback; delete 7 days after the restart test on the owner's word" >/dev/null
MEM_NOW=2026-10-05T09:00Z "$T/bin/mem" backup >/dev/null
check "backup writes a mode 600 tar named by the UTC time and logs its sha256 and basis" \
  '[ "$(mode_of "$T/.meta/backups/20261001T090000Z.tar")" = 600 ] && s="$(python3 -I -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],\"rb\").read()).hexdigest())" "$T/.meta/backups/20261005T090000Z.tar")" && grep -q "backup .meta/backups/20261005T090000Z.tar sha256=$s basis=kept 7 days" "$T/.meta/drain.log"'
check "the tar holds the tree but not the other backups" \
  'tar -tf "$T/.meta/backups/20261005T090000Z.tar" | grep -qx "MEMORY.md" && tar -tf "$T/.meta/backups/20261005T090000Z.tar" | grep -q "^state/cursors.json$" && ! tar -tf "$T/.meta/backups/20261005T090000Z.tar" | grep -q "^.meta/backups/"'
OUT="$(MEM_NOW=2026-10-10T09:00Z "$T/bin/mem" backup)"
check "backup prunes routine tars older than 7 days and logs each prune" \
  '[ ! -e "$T/.meta/backups/20261001T090000Z.tar" ] && [ -f "$T/.meta/backups/20261005T090000Z.tar" ] && grep -q "prune .meta/backups/20261001T090000Z.tar (older than 7 days" "$T/.meta/drain.log"'
check "a tar kept on the owner's word is never pruned automatically" '[ -f "$T/.meta/backups/20261001T093000Z.tar" ]'
T="$WORK/drain"
OUT="$("$T/bin/mem" unarchive stale-a)"
check "unarchive moves a file back, refreshes last_confirmed and removes its index line" \
  '[ -f "$T/topics/stale-a.md" ] && [ ! -e "$T/archive/2026-10/topics/stale-a.md" ] && grep -q "^last_confirmed: 2026-10-23" "$T/topics/stale-a.md" && ! grep -q "topics/stale-a.md from" "$T/archive/index.md" && grep -q "unarchive archive/2026-10/topics/stale-a.md -> topics/stale-a.md" "$T/.meta/drain.log"'
check "unarchive lists the file in MEMORY.md again" 'grep -q "(topics/stale-a.md)" "$T/MEMORY.md"'
check "unarchive refuses a name that is not archived, and a path" '! "$T/bin/mem" unarchive no-such-file && ! "$T/bin/mem" unarchive ../etc'
unset MEM_NOW


echo "== erase and purge"
export MEM_NOW=2026-10-23T09:00Z
T="$WORK/erase"
fresh "$T"
printf -- '---\nname: dana\nregion: people\nkeywords: design\nsummary: Dana Smith runs design\nlinks:\nimportance: 3\nlast_confirmed: 2026-10-01\nstatus: live\n---\nDana.\n' >"$T/people/dana.md"
topic "$T" onboarding "onboarding, design" 3 2026-10-01
printf 'Ask DANA SMITH first.\n' >>"$T/topics/onboarding.md"
topic "$T" unrelated "zinc, copper" 3 2026-10-01
chmod 600 "$T"/*/*.md
/bin/mkdir -p "$T/archive/2026-08/topics"
printf -- '---\nname: dana-old\nregion: topics\nkeywords: old\nsummary: Dana Smith in August\nlinks:\nimportance: 2\nlast_confirmed: 2026-08-01\nstatus: live\n---\nOld.\n' >"$T/archive/2026-08/topics/dana-old.md"
printf -- '- 2026-08-30 archive/2026-08/topics/dana-old.md from topics/dana-old.md: test\n' >>"$T/archive/index.md"
printf 'Dana Smith decides the colours.' | "$T/bin/mem" decide --time 2026-10-02T09:00Z --source chat --slug colours >/dev/null
"$T/bin/mem" sent --to "Dana Smith" --channel dm --ref r1 --subject "colours" >/dev/null
"$T/bin/mem" sent --to "sam" --channel dm --ref r2 --subject "zinc" >/dev/null
"$T/bin/mem" ask open --id colours --who "Dana Smith" --what "the colours" --waiting-on owner >/dev/null
"$T/bin/mem" ask open --id zinc --who sam --what "zinc price" --waiting-on owner >/dev/null
"$T/bin/mem" backup >/dev/null
MEM_NOW=2026-10-22T09:00Z "$T/bin/mem" backup --note "kept on Dana Smith's word" >/dev/null
/bin/mkdir -p "$HOME/.wolfmux/backups"
( cd "$T" && tar -cf "$HOME/.wolfmux/backups/memory-pre-migration-20261001T000000Z.tar" people/dana.md )
HOME_TAR_SUM="$(tree_sum "$HOME/.wolfmux/backups")"
SUM_BEFORE="$(tree_sum "$T")"
LIST="$("$T/bin/mem" erase "dana smith")"; RC=$?
check "erase without --confirm lists every live file, archive file, ledger line, state entry and tar member" \
  '[ "$RC" -eq 0 ] && printf "%s" "$LIST" | grep -q "^file   people/dana.md" && printf "%s" "$LIST" | grep -q "^file   topics/onboarding.md" && printf "%s" "$LIST" | grep -q "^file   archive/2026-08/topics/dana-old.md" && printf "%s" "$LIST" | grep -q "^line   ledger/decisions-2026-10.md:" && printf "%s" "$LIST" | grep -q "^line   ledger/sends-2026-10.md:" && printf "%s" "$LIST" | grep -q "^state  state/open-asks.json#colours" && printf "%s" "$LIST" | grep -q "^tar    .meta/backups/20261023T090000Z.tar: drop people/dana.md"'
check "it names the pre-migration tar outside the tree, which it never changes" \
  'printf "%s" "$LIST" | grep -q "^outside the tree, not changed (erase it by hand): $HOME/.wolfmux/backups/memory-pre-migration-20261001T000000Z.tar"'
check "erase without --confirm changes nothing" '[ "$SUM_BEFORE" = "$(tree_sum "$T")" ]'
N="$(printf '%s\n' "$LIST" | sed -n 's/^\([0-9][0-9]*\) items; run again with --confirm \1 to erase them.*/\1/p')"
check "the listing ends with its item count, and --confirm with another count is refused and changes nothing" \
  '[ "$N" = "$(printf "%s\n" "$LIST" | grep -c "^\(file\|line\|state\|tar\) ")" ] && OUT="$("$T/bin/mem" erase "dana smith" --confirm $((N + 1)) 2>&1)"; [ $? -eq 1 ] && printf "%s" "$OUT" | grep -q "the listing has $N items" && [ "$SUM_BEFORE" = "$(tree_sum "$T")" ]'
OUT="$("$T/bin/mem" erase "dana smith" --confirm "$N")"; RC=$?
check "erase --confirm removes the live and archived files that name the subject" \
  '[ "$RC" -eq 0 ] && [ ! -e "$T/people/dana.md" ] && [ ! -e "$T/topics/onboarding.md" ] && [ ! -e "$T/archive/2026-08/topics/dana-old.md" ] && [ -f "$T/topics/unrelated.md" ]'
check "the ledger lines become a one-line marker; the other lines stay" \
  'grep -qxF "[erased 2026-10-23 on owner'"'"'s word]" "$T/ledger/sends-2026-10.md" && grep -q "| to: sam |" "$T/ledger/sends-2026-10.md" && grep -qF "[erased 2026-10-23 on owner'"'"'s word]" "$T/ledger/decisions-2026-10.md"'
check "the state entry naming the subject is removed; the others stay" \
  '! grep -q colours "$T/state/open-asks.json" && grep -q zinc "$T/state/open-asks.json"'
check "the backup tar is rebuilt without the subject and keeps the rest" \
  'python3 -I -c "import sys,tarfile; t=tarfile.open(sys.argv[1]); n=t.getnames(); bad=[m.name for m in t.getmembers() if m.isfile() and b\"dana smith\" in t.extractfile(m).read().lower()]; sys.exit(bool(bad) or \"people/dana.md\" in n or \"topics/unrelated.md\" not in n)" "$T/.meta/backups/20261023T090000Z.tar"'
check "nothing in the tree names the subject any more, drain.log included" '! grep -rqi "dana smith" "$T"'
ERASE_ID="$(printf '%s\n' "$OUT" | sed -n 's/.*(erase id \([0-9a-f]\{8\}\) in .meta\/drain.log)$/\1/p')"
SUBJECT_HASH="$(printf 'dana smith' | python3 -I -c "import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])")"
check "drain.log says what erase did under a random 8-hex erase id (the one erase printed), never the subject or its hash" \
  '[ -n "$ERASE_ID" ] && grep -q "erase on the owner'"'"'s word: erase id $ERASE_ID; 3 files removed" "$T/.meta/drain.log" && ! grep -q "$SUBJECT_HASH" "$T/.meta/drain.log"'
check "a backup kept on the owner's word keeps its drain.log line: only the basis text is erased, so it stays non-routine" \
  'grep -q "backup .meta/backups/20261022T090000Z.tar sha256=[0-9a-f]* basis=\[erased 2026-10-23 on owner.s word\]$" "$T/.meta/drain.log" && grep -q "backup .meta/backups/20261022T090000Z.tar sha256=[0-9a-f]* basis=\[erased 2026-10-23 on owner.s word\] (rebuilt by erase)$" "$T/.meta/drain.log"'
check "8 days on, backup pruning drops the routine tar and keeps the one kept on the owner's word" \
  'MEM_NOW=2026-10-31T09:00Z "$T/bin/mem" backup >/dev/null && [ -f "$T/.meta/backups/20261022T090000Z.tar" ] && [ ! -e "$T/.meta/backups/20261023T090000Z.tar" ]'
check "the pre-migration tar outside the tree is untouched" '[ "$HOME_TAR_SUM" = "$(tree_sum "$HOME/.wolfmux/backups")" ]'
check "erase refuses a subject shorter than 3 characters" '! "$T/bin/mem" erase da --confirm 1'
T="$WORK/erase-words"
fresh "$T"
topic "$T" custom-domains "domains, dns" 3 2026-10-01
printf 'Custom domains go live soon.\n' >>"$T/topics/custom-domains.md"
topic "$T" later "later, plan" 3 2026-10-01
printf 'We do it tomorrow.\n' >>"$T/topics/later.md"
topic "$T" meeting "meeting, weekly" 3 2026-10-01
printf 'Tom runs the meeting.\n' >>"$T/topics/meeting.md"
printf 'We decided.' | "$T/bin/mem" decide --time 2026-10-02T09:00Z --source chat --slug decided >/dev/null
"$T/bin/mem" sweep-log --inboxes 3 --asks-touched 1 --free-pct 40 --swap-gb 1 --load 2 >/dev/null
SUM_BEFORE="$(tree_sum "$T")"
LIST="$("$T/bin/mem" erase tom)"
check "erase matches whole words: tom finds the file that says Tom, not custom-domains or tomorrow" \
  '[ "$(printf "%s\n" "$LIST" | grep -c "^file ")" -eq 1 ] && printf "%s" "$LIST" | grep -q "^file   topics/meeting.md" && printf "%s" "$LIST" | grep -q "^1 items; run again with --confirm 1"'
"$T/bin/mem" erase tom --confirm 1 >/dev/null
check "erase tom --confirm 1 removes only that file" \
  '[ ! -e "$T/topics/meeting.md" ] && [ -f "$T/topics/custom-domains.md" ] && [ -f "$T/topics/later.md" ]'
SUM_BEFORE="$(tree_sum "$T")"
check "erase dec matches nothing: a path counts by its file stem only, never decisions-YYYY-MM" \
  '"$T/bin/mem" erase dec | grep -qx "nothing in the tree names that subject" && "$T/bin/mem" erase ledger 2>/dev/null; [ -f "$T/ledger/decisions-2026-10.md" ]'
check "erase matches state and .jsonl values, never field names: free finds no sweep line" \
  '"$T/bin/mem" erase free | grep -qx "nothing in the tree names that subject"'
check "erase refuses .md, a header field, a folder name and a bare number, and changes nothing" \
  '! "$T/bin/mem" erase .md && ! "$T/bin/mem" erase summary && ! "$T/bin/mem" erase topics && ! "$T/bin/mem" erase 2026 && [ "$SUM_BEFORE" = "$(tree_sum "$T")" ]'
printf 'Ask the person on call.\n' >>"$T/topics/later.md"
"$T/bin/mem" backup >/dev/null
N="$("$T/bin/mem" erase person | sed -n 's/^\([0-9][0-9]*\) items; run again.*/\1/p')"
"$T/bin/mem" erase person --confirm "$N" >/dev/null
check "erase never edits bin/mem or .meta/schema.md, live or inside a backup tar (both say person)" \
  '[ ! -e "$T/topics/later.md" ] && grep -q person "$T/bin/mem" && grep -q person "$T/.meta/schema.md" && python3 -I -c "import sys,tarfile; t=tarfile.open(sys.argv[1]); sys.exit(not (t.extractfile(\"bin/mem\").read() == open(sys.argv[2], \"rb\").read() and t.extractfile(\".meta/schema.md\").read() == open(sys.argv[3], \"rb\").read() and \"topics/later.md\" not in t.getnames()))" "$(ls "$T"/.meta/backups/*.tar | head -1)" "$T/bin/mem" "$T/.meta/schema.md"'
/bin/rm -rf "$HOME/.wolfmux"
T="$WORK/purge"
fresh "$T"
/bin/mkdir -p "$T/archive/2026-07/topics" "$T/archive/2026-08/topics"
for m in 07 08; do
  printf -- '---\nname: old-%s\nregion: topics\nkeywords: old\nsummary: old\nlinks:\nimportance: 2\nlast_confirmed: 2026-%s-01\nstatus: live\n---\nOld.\n' "$m" "$m" >"$T/archive/2026-$m/topics/old-$m.md"
  printf -- '- 2026-%s-30 archive/2026-%s/topics/old-%s.md from topics/old-%s.md: test\n' "$m" "$m" "$m" "$m" >>"$T/archive/index.md"
done
topic "$T" old-07 "live, copy" 3 2026-10-01
SUM_BEFORE="$(tree_sum "$T")"
OUT="$("$T/bin/mem" purge old-08)"
check "purge without --confirm lists and deletes nothing" \
  'printf "%s" "$OUT" | grep -q "^would purge archive/2026-08/topics/old-08.md" && [ "$SUM_BEFORE" = "$(tree_sum "$T")" ]'
"$T/bin/mem" purge --confirm old-08 >/dev/null
check "purge --confirm deletes from archive/, drops its index line and logs it" \
  '[ ! -e "$T/archive/2026-08" ] && ! grep -q "old-08" "$T/archive/index.md" && grep -q "purge on the owner'"'"'s word: deleted 1 archived files: archive/2026-08/topics/old-08.md" "$T/.meta/drain.log"'
"$T/bin/mem" purge --confirm 2026-07 >/dev/null
check "purge --confirm YYYY-MM deletes that month and never a live file of the same name" \
  '[ ! -e "$T/archive/2026-07/topics/old-07.md" ] && [ -f "$T/topics/old-07.md" ]'
check "purge of something not archived exits 1; a path is refused" '! "$T/bin/mem" purge --confirm nothing-here && ! "$T/bin/mem" purge --confirm ../topics'

echo "== migrate"
SRC="$WORK/shared-src"
RULES_SRC="$WORK/rules-src"
/bin/mkdir -p "$SRC/old" "$RULES_SRC"
printf '# Shared memory\n\n- [Fly](project_fly.md) fly notes\n- [Tone](feedback_tone.md) tone\n' >"$SRC/MEMORY.md"
printf -- '---\nname: Tone\ndescription: keep it short\ntype: feedback\n---\nKeep replies short.\nNo jargon.\n' >"$SRC/feedback_tone.md"
printf 'AFD-2129 notes: the fly deploy, step 1.\r\nstep 2, with ```code```\n' >"$SRC/project_fly.md"
printf 'Shared links live here.\n' >"$SRC/reference_links.md"
printf 'The vendor list lives here.\n' >"$SRC/project_vendors.md"
printf 'The board lives here.\n' >"$SRC/reference_board.md"
printf -- '---\nA rule line, then prose.\n\nMore prose.\n---\nAfter the rule.\n' >"$SRC/false_front.md"
printf -- '---\nname: Only\ndescription: >-\n  all of it is\n  in here\ntype: project\n---\n' >"$SRC/only_front.md"
printf 'Same text.\n' >"$SRC/dup_a.md"
printf 'Same text.\n' >"$SRC/dup_b.md"
printf -- '- 2026-10-05T09:00Z | to: sam | channel: c | ref: r | first send\n' >"$SRC/send_a.md"
printf -- '- 2026-10-06T09:00Z | to: sam | channel: c | ref: r | second send\n' >"$SRC/send_b.md"
: >"$SRC/empty.md"
CM="$HOME/claude-mem-export-2026-10-22"   # the default --claude-mem-from
/bin/mkdir -p "$CM/observations"
printf -- '---\ntitle: Fly cutover\ntype: observation\n---\nThe cutover ran at 09:00 UTC.\n' >"$CM/observations/obs-1.md"
printf 'Archived note from July.\n' >"$SRC/old/archived.md"
printf 'private, never copied\n' >"$SRC/secret.md"
printf 'held for later\n' >"$SRC/held.md"
printf 'Slack rule: plain names.\n' >"$RULES_SRC/slack-names.md"
printf 'A rule without a ledger line.\n' >"$RULES_SRC/orphan.md"
printf '{"cursors": {"slack_dm": "1761000000.1"}, "asks": [{"id": "a1", "who": "sam", "what": "logo", "status": "open", "opened": "2026-10-01T09:00Z", "waiting_on": "dana"}], "decisions": [{"time": "2026-10-09T13:50Z", "quote": "keep it short"}], "notes": {"tone": "Plain words, short lines."}, "contacts": {"dana": {"tz": "UTC+1", "role": "design"}}}\n' >"$WORK/comms-state.json"
python3 -I - "$WORK/map.csv" "$WORK/migrate" <<'EOF'
import csv, sys
rows = [
    ("feedback_tone.md", "file", "rules/tone.md", "rules", "copy", "no", "tone", "tone, replies", "keep replies short, no jargon", "4", "decisions-2026-10#2026-10-09T13:50Z", "", "", "feedback"),
    ("project_fly.md", "file", "topics/afd-2129.md", "topics", "copy", "no", "afd-2129", "fly, deploy, afd-2129", "the fly deploy steps", "3", "", "", "fe:src/features/fly/agent-log/0007.md AFD-2129", ""),
    ("reference_links.md", "file", "rules/shared-links.md", "rules", "pointer", "no", "shared-links", "links", "where the shared links live", "3", "", "", "", ""),
    ("archive:old/archived.md", "archive-file", "archive/state/archived.md", "", "copy", "no", "", "", "", "", "", "", "", ""),
    ("hub:MEMORY.md#3", "hub-line", "archive/hub/memory-line-3.md", "", "copy", "no", "", "", "", "", "", "", "", "one hub line"),
    ("rules:slack-names.md", "rules-file", "rules/slack-names.md", "rules", "copy", "no", "slack-names", "slack, names", "plain names in slack", "4", "decisions-2026-10#2026-10-09T13:50Z", "[[tone]]", "", ""),
    ("rules:orphan.md", "rules-file", "rules/orphan.md", "rules", "copy", "no", "orphan", "orphan", "a rule with no authority", "3", "", "", "", ""),
    ("state:cursors.slack_dm", "state-key", "state/cursors.json#slack_dm", "", "copy", "no", "", "", "", "", "", "", "", ""),
    ("state:asks.a1", "state-key", "state/open-asks.json#a1", "", "copy", "no", "", "", "", "", "", "", "", ""),
    ("state:decisions.0", "state-key", "ledger/decisions-2026-10.md", "", "copy", "no", "", "", "", "", "", "", "", ""),
    ("held.md", "file", "topics/held.md", "topics", "hold", "yes", "held", "held", "held", "3", "", "", "", "waiting for the owner"),
    ("secret.md", "file", "", "", "skip", "no", "", "", "", "", "", "", "", "private"),
    # line 14 on: a state key whose value becomes a region file's body (a string; an object)
    ("state:notes.tone", "state-key", "topics/state-tone.md", "topics", "copy", "no", "state-tone", "tone, state", "the tone note from the comms state", "3", "", "", "", ""),
    ("state:contacts.dana", "state-key", "people/dana.md", "people", "copy", "no", "dana", "dana, design", "dana works on design", "3", "", "", "", ""),
    ("state:notes.tone", "state-key", "rules/state-tone-pointer.md", "rules", "pointer", "no", "state-tone-pointer", "tone", "a pointer to a state key", "3", "", "", "", ""),
    # line 17 on: pointers with region 'pointer' (the dest's folder), a pointer in topics/, and a copy row that says pointer
    ("project_vendors.md", "file", "rules/vendors.md", "pointer", "pointer", "no", "vendors", "vendors", "where the vendor list lives", "3", "", "", "", ""),
    ("reference_board.md", "file", "topics/board.md", "topics", "pointer", "no", "board", "board", "where the board lives", "3", "", "", "", ""),
    ("reference_board.md", "file", "topics/board-copy.md", "pointer", "copy", "no", "board-copy", "board", "a copy that says pointer", "3", "", "", "", ""),
    # line 20: a claude-mem export file, frontmatter stripped like a file row's
    ("claude-mem:observations/obs-1.md", "claude-mem", "topics/fly-cutover.md", "topics", "copy", "no", "fly-cutover", "fly, cutover", "when the fly cutover ran", "3", "", "", "", ""),
    # line 21: a second row into line 3's dest
    ("reference_links.md", "file", "topics/afd-2129.md", "topics", "copy", "no", "afd-2129", "links", "a second row into one dest", "3", "", "", "", ""),
    # line 22: refused for the same cause as line 8 (the summary groups them)
    ("rules:orphan.md", "rules-file", "rules/orphan-two.md", "rules", "copy", "no", "orphan-two", "orphan", "a second rule with no authority", "3", "", "", "", ""),
    # line 23 on: a false frontmatter (all body), a frontmatter-only source (empty body), two sources with one body
    ("false_front.md", "file", "topics/false-front.md", "topics", "copy", "no", "false-front", "rule, prose", "starts with a rule line", "3", "", "", "", ""),
    ("only_front.md", "file", "topics/only-front.md", "topics", "copy", "no", "only-front", "only", "all in the frontmatter", "3", "", "", "", ""),
    ("dup_a.md", "file", "topics/dup-a.md", "topics", "copy", "no", "dup-a", "dup, first", "one body", "3", "", "", "", ""),
    ("dup_b.md", "file", "topics/dup-b.md", "topics", "copy", "no", "dup-b", "dup, second", "the same body", "3", "", "", "", ""),
    # line 27 on: two rows into one ledger month
    ("send_a.md", "file", "ledger/sends-2026-10.md", "", "copy", "no", "", "", "", "", "", "", "", ""),
    ("send_b.md", "file", "ledger/sends-2026-10.md", "", "copy", "no", "", "", "", "", "", "", "", ""),
    # line 29: an empty source into the ledger has nothing to append
    ("empty.md", "file", "ledger/sends-2026-10.md", "", "copy", "no", "", "", "", "", "", "", "", ""),
    # line 30 on: dests that are not plain paths in the tree (.., an absolute path, a . segment)
    ("dup_a.md", "file", "topics/../rules/sneak.md", "topics", "copy", "no", "sneak", "sneak", "climbs into rules", "3", "", "", "", ""),
    ("dup_a.md", "file", sys.argv[2] + "/topics/abs.md", "topics", "copy", "no", "abs", "abs", "an absolute dest", "3", "", "", "", ""),
    ("dup_a.md", "file", "topics/./dot.md", "topics", "copy", "no", "dot", "dot", "a dot segment", "3", "", "", "", ""),
]
with open(sys.argv[1], "w", newline="") as out:
    w = csv.writer(out)
    w.writerow(["source", "source_type", "dest", "region", "action", "hold", "name", "keywords", "summary", "importance", "authority", "links", "repo_ref", "notes"])
    w.writerows(rows)
EOF
T="$WORK/migrate"
fresh "$T"
# A file already in the tree with an empty body: line 24's empty body must not count it.
printf -- '---\nname: empty-here\nregion: topics\nkeywords: empty\nsummary: a header and no body\nlinks:\nimportance: 3\nlast_confirmed: 2026-10-01\nstatus: live\n---\n' >"$T/topics/empty-here.md"
chmod 600 "$T/topics/empty-here.md"
SRC_SUM="$(tree_sum "$SRC")"; RULES_SUM="$(tree_sum "$RULES_SRC")"; T_SUM="$(tree_sum "$T")"
DRY="$("$T/bin/mem" migrate --from "$SRC" --map "$WORK/map.csv" --rules-from "$RULES_SRC" --state "$WORK/comms-state.json" --dry-run)"; RC=$?
check "migrate --dry-run exits 0 and says nothing was written" '[ "$RC" -eq 0 ] && printf "%s\n" "$DRY" | sed -n 1p | grep -q "(dry run: nothing was written)"'
check "the dry run reports a sha256 match for every copied body" \
  '[ "$(printf "%s" "$DRY" | grep -c "sha256 match (in memory)")" -eq 12 ] && printf "%s" "$DRY" | grep -q "^verification: every payload keeps its sha256 in memory"'
check "the dry run writes nothing: not the tree, not the source, not ~/.wolfmux" \
  '[ "$T_SUM" = "$(tree_sum "$T")" ] && [ "$SRC_SUM" = "$(tree_sum "$SRC")" ] && [ ! -e "$HOME/.wolfmux" ]'
check "the dry run lists the held and skipped rows with their reasons" \
  'printf "%s" "$DRY" | grep -q "^- line 8 refused rules:orphan.md: a rules dest needs an authority" && printf "%s" "$DRY" | grep -q "^- line 12 hold held.md: waiting for the owner" && printf "%s" "$DRY" | grep -q "^- line 13 skip secret.md: private"'
OUT="$("$T/bin/mem" migrate --from "$SRC" --map "$WORK/map.csv" --rules-from "$RULES_SRC" --state "$WORK/comms-state.json" 2>"$WORK/migrate-err.txt")"; RC=$?
printf '%s\n' "$OUT" >"$WORK/migrate-report.txt"
check "the real migrate finds every source body and state value exactly once" \
  'grep -q "^verification: every source body and state value found exactly once in the new tree" "$WORK/migrate-report.txt" && grep -q "^modes: all 700/600" "$WORK/migrate-report.txt"'
check "a real run that refused rows writes its report, places the rest, then exits 1 naming --allow-refused" \
  '[ "$RC" -eq 1 ] && grep -q "^mem: 9 rows refused (the report says why); the other rows are placed. Fix the map and run again, or pass --allow-refused" "$WORK/migrate-err.txt" && ls "$T"/.meta/migrate-*.md >/dev/null 2>&1 && [ -f "$T/rules/tone.md" ]'
check "every copied body is byte for byte the source (sha256 compared here, not by mem)" \
  'python3 -I - "$T" "$SRC" "$RULES_SRC" <<'"'"'EOF'"'"'
import hashlib, sys
t, s, r = sys.argv[1:4]
def body(path):
    d = open(path, "rb").read()
    return d.split(b"\n---\n", 1)[1] if d.startswith(b"---\n") else d
sha = lambda b: hashlib.sha256(b).hexdigest()
pairs = [(body(t + "/rules/tone.md"), body(s + "/feedback_tone.md")),
         (body(t + "/topics/afd-2129.md"), open(s + "/project_fly.md", "rb").read()),
         (open(t + "/archive/state/archived.md", "rb").read(), open(s + "/old/archived.md", "rb").read()),
         (open(t + "/archive/hub/memory-line-3.md", "rb").read(), open(s + "/MEMORY.md", "rb").read().split(b"\n")[2] + b"\n"),
         (body(t + "/rules/slack-names.md"), open(r + "/slack-names.md", "rb").read())]
sys.exit(not all(sha(a) == sha(b) for a, b in pairs))
EOF'
check "a state key into a region: a string value is the body as is, an object is pretty-printed (indent 2, sorted keys)" \
  'python3 -I - "$T" "$WORK/comms-state.json" <<'"'"'EOF'"'"'
import json, sys
t, s = sys.argv[1:3]
state = json.load(open(s))
body = lambda p: open(p, "rb").read().split(b"\n---\n", 1)[1]
want = json.dumps(state["contacts"]["dana"], indent=2, sort_keys=True, ensure_ascii=False).encode()
sys.exit(not (body(t + "/topics/state-tone.md") == b"Plain words, short lines." and body(t + "/people/dana.md") == want
              and b"\nregion: people\n" in open(t + "/people/dana.md", "rb").read()))
EOF'
check "the report finds both state-key bodies once; a state key as a pointer is refused" \
  'grep -q "^line 14 copy    state:notes.tone -> topics/state-tone.md sha256 [0-9a-f]*: found once" "$WORK/migrate-report.txt" && grep -q "^line 15 copy    state:contacts.dana -> people/dana.md sha256 [0-9a-f]*: found once" "$WORK/migrate-report.txt" && grep -q "^- line 16 refused state:notes.tone: a state key is copied into rules/, never a pointer" "$WORK/migrate-report.txt" && [ ! -e "$T/rules/state-tone-pointer.md" ]'
check "a pointer row with region 'pointer' lands in the dest's folder and says so in its header" \
  'grep -q "^region: rules$" "$T/rules/vendors.md" && grep -q "^pointer: $SRC/project_vendors.md$" "$T/rules/vendors.md" && grep -q "^line 17 pointer project_vendors.md -> rules/vendors.md.*: pointer ok" "$WORK/migrate-report.txt"'
check "a pointer row may land in topics/ (authority shared:<path>, no body copied)" \
  'grep -q "^region: topics$" "$T/topics/board.md" && grep -q "^authority: shared:$SRC/reference_board.md$" "$T/topics/board.md" && ! grep -q "The board lives here" "$T/topics/board.md" && grep -q "^line 18 pointer reference_board.md -> topics/board.md.*: pointer ok" "$WORK/migrate-report.txt"'
check "region 'pointer' on a copy row is refused and names the fix" \
  'grep -q "^- line 19 refused reference_board.md: region .pointer. on a copy row: set region topics, or action pointer" "$WORK/migrate-report.txt" && [ ! -e "$T/topics/board-copy.md" ]'
check "a claude-mem: row reads the default ~/claude-mem-export-2026-10-22 and copies the body without its frontmatter" \
  'python3 -I -c "import sys; sys.exit(open(sys.argv[1], \"rb\").read().split(b\"\n---\n\", 1)[1] != b\"The cutover ran at 09:00 UTC.\n\")" "$T/topics/fly-cutover.md" && grep -q "^line 20 copy    claude-mem:observations/obs-1.md -> topics/fly-cutover.md sha256 [0-9a-f]* raw [0-9a-f]* (source frontmatter of 45 bytes replaced by the header): found once" "$WORK/migrate-report.txt"'
check "migrate refuses a --claude-mem-from that is not a folder; a claude-mem: row without the folder is held with the fix" \
  '! "$T/bin/mem" migrate --from "$SRC" --map "$WORK/map.csv" --claude-mem-from "$WORK/no-such-export" --dry-run 2>/dev/null && OUT="$(HOME="$WORK/empty-home" "$T/bin/mem" migrate --from "$SRC" --map "$WORK/map.csv" --rules-from "$RULES_SRC" --state "$WORK/comms-state.json" --dry-run)" && printf "%s" "$OUT" | grep -q "^- line 20 refused claude-mem:observations/obs-1.md: a claude-mem: row needs --claude-mem-from <dir>"'
check "a second row into one dest is refused, and the message says what to do; the first row's file is kept" \
  'grep -q "^- line 21 refused reference_links.md: dest topics/afd-2129.md is already the dest of line 3: keep one row, set the others to action skip (or give each its own dest)" "$WORK/migrate-report.txt" && grep -q "^repo_ref: fe:" "$T/topics/afd-2129.md"'
check "a --- block with a prose line in it is not frontmatter: the whole source is the body" \
  'python3 -I -c "import sys; d=open(sys.argv[1],\"rb\").read(); sys.exit(d.split(b\"\n---\n\",1)[1] != open(sys.argv[2],\"rb\").read())" "$T/topics/false-front.md" "$SRC/false_front.md" && ! grep -q "^line 23 .*source frontmatter" "$WORK/migrate-report.txt" && grep -q "^line 23 copy .*: found once" "$WORK/migrate-report.txt"'
check "a frontmatter-only source leaves an empty body; its description (a folded block) is kept as source_description" \
  'python3 -I -c "import sys; d=open(sys.argv[1],\"rb\").read(); sys.exit(not d.endswith(b\"\n---\n\") or b\"\nsource_description: all of it is in here\n\" not in d)" "$T/topics/only-front.md" && grep -q "^line 24 copy .*(source frontmatter of 74 bytes replaced by the header; its description kept as source_description): found at the dest (an empty body)" "$WORK/migrate-report.txt" && grep -q "^source_description: keep it short$" "$T/rules/tone.md"'
check "two sources with the same body are each found once at their own dest" \
  'grep -q "^line 25 copy .*: found once at its dest (2 rows place this body)" "$WORK/migrate-report.txt" && grep -q "^line 26 copy .*: found once at its dest (2 rows place this body)" "$WORK/migrate-report.txt"'
sed -n '/^## Summary$/,$p' "$WORK/migrate-report.txt" >"$WORK/migrate-summary.txt"
check "the report ends with a summary: counts by status, then refusal reasons grouped with counts and line numbers" \
  '[ "$(tail -n "$(wc -l <"$WORK/migrate-summary.txt")" "$WORK/migrate-report.txt")" = "$(cat "$WORK/migrate-summary.txt")" ] && grep -qx "copy 17, pointer 3, hold 1, skip 1, refused 9 (31 rows)" "$WORK/migrate-summary.txt" && grep -qx "refused, by reason:" "$WORK/migrate-summary.txt" && grep -qx -- "- 2 x a rules dest needs an authority (lines 8, 22)" "$WORK/migrate-summary.txt" && grep -qx -- "- 1 x dest <path> is already the dest of line <n>: keep one row, set the others to action skip (or give each its own dest) (line 21)" "$WORK/migrate-summary.txt" && grep -qx -- "- 1 x the source is empty: nothing to append to <path>; set action skip (line 29)" "$WORK/migrate-summary.txt" && [ "$(grep -c "^- " "$WORK/migrate-summary.txt")" -eq 6 ]'
check "a dest with .., a leading slash or a . segment is refused as written, and nothing lands" \
  'for n in 30 31 32; do grep -q "^- line $n refused dup_a.md: dest .* is not a plain path in the tree (no leading slash, no . or .. segments)" "$WORK/migrate-report.txt" || exit 1; done && grep -qx -- "- 3 x dest <path> is not a plain path in the tree (no leading slash, no . or .. segments) (lines 30, 31, 32)" "$WORK/migrate-summary.txt" && [ ! -e "$T/rules/sneak.md" ] && [ ! -e "$T/topics/abs.md" ] && [ ! -e "$T/topics/dot.md" ]'
check "the source folder and the rules folder are never written" '[ "$SRC_SUM" = "$(tree_sum "$SRC")" ] && [ "$RULES_SUM" = "$(tree_sum "$RULES_SRC")" ]'
check "headers come from the map: region, keywords, authority, repo_ref, last_confirmed from the source mtime" \
  'grep -q "^authority: decisions-2026-10#2026-10-09T13:50Z" "$T/rules/tone.md" && grep -q "^repo_ref: fe:src/features/fly/agent-log/0007.md AFD-2129" "$T/topics/afd-2129.md" && grep -q "^last_confirmed: $(date -u -r "$SRC/project_fly.md" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)" "$T/topics/afd-2129.md" && grep -q "^links: \[\[tone\]\]" "$T/rules/slack-names.md"'
check "a pointer row writes a pointer file with shared:<path> authority, not the body" \
  'grep -q "^pointer: $SRC/reference_links.md" "$T/rules/shared-links.md" && grep -q "^authority: shared:$SRC/reference_links.md" "$T/rules/shared-links.md" && ! grep -q "Shared links live here" "$T/rules/shared-links.md"'
check "state keys land in state/*.json and the ledger" \
  'grep -q "\"slack_dm\": \"1761000000.1\"" "$T/state/cursors.json" && grep -q "\"id\": \"a1\"" "$T/state/open-asks.json" && grep -q "migrated state:decisions.0" "$T/ledger/decisions-2026-10.md"'
check "held and skipped rows write nothing" '[ ! -e "$T/rules/orphan.md" ] && [ ! -e "$T/topics/held.md" ] && ! grep -rq "never copied" "$T"'
check "archive rows are listed in archive/index.md" 'grep -q "archive/state/archived.md from shared:archive:old/archived.md" "$T/archive/index.md"'
check "a rollback backup is taken first, kept on the owner's word" \
  'grep -q "basis=migration rollback; delete 7 days after the restart test on the owner'"'"'s word" "$T/.meta/drain.log" && [ "$(ls "$T"/.meta/backups/*.tar | wc -l | tr -d " ")" -ge 1 ]'
PRE="$(ls "$HOME"/.wolfmux/backups/memory-pre-migration-*.tar 2>/dev/null | head -1)"
check "the source and rules folders are tarred to ~/.wolfmux/backups, mode 600, with a sha256 list, minus skip rows" \
  '[ -n "$PRE" ] && [ "$(mode_of "$PRE")" = 600 ] && [ -f "${PRE%.tar}.sha256" ] && tar -tf "$PRE" | grep -qx "source/feedback_tone.md" && tar -tf "$PRE" | grep -qx "rules/slack-names.md" && tar -tf "$PRE" | grep -qx "state/comms-state.json" && tar -tf "$PRE" | grep -qx "claude-mem/observations/obs-1.md" && ! tar -tf "$PRE" | grep -q secret.md'
check "the report is kept in .meta/migrate-<UTC>.md" 'ls "$T"/.meta/migrate-*.md >/dev/null 2>&1 && grep -q "^verification: every source body" "$T"/.meta/migrate-*.md'
check "after migrate, check passes" '"$T/bin/mem" check'
check "two rows append to one ledger month: each payload found once" \
  'grep -q "^line 27 copy    send_a.md -> ledger/sends-2026-10.md.*: found once" "$WORK/migrate-report.txt" && grep -q "^line 28 copy    send_b.md -> ledger/sends-2026-10.md.*: found once" "$WORK/migrate-report.txt" && [ "$(grep -c "send$" "$T/ledger/sends-2026-10.md")" -eq 2 ]'
LEDGERS_BEFORE="$(cat "$T"/ledger/*)"
OUT2="$(MEM_NOW=2026-10-23T10:00Z "$T/bin/mem" migrate --from "$SRC" --map "$WORK/map.csv" --rules-from "$RULES_SRC" --state "$WORK/comms-state.json" --allow-refused 2>&1)"; RC2=$?
check "--allow-refused: the same refused rows, exit 0" '[ "$RC2" -eq 0 ] && printf "%s" "$OUT2" | grep -q "refused 9, exists [0-9]* (31 rows)" && ! printf "%s" "$OUT2" | grep -q "^mem: "'
check "a re-run is idempotent: placed rows are exists, the ledger rows too, nothing is appended twice" \
  'printf "%s" "$OUT2" | grep -q "^line 11 exists  state:decisions.0 -> ledger/decisions-2026-10.md.*: found once: already in the ledger" && printf "%s" "$OUT2" | grep -q "^line 27 exists .*: found once: already in the ledger" && printf "%s" "$OUT2" | grep -q "^line 28 exists " && printf "%s" "$OUT2" | grep -q "^line 3 exists " && [ "$LEDGERS_BEFORE" = "$(cat "$T"/ledger/*)" ] && [ "$(grep -c "migrated state:decisions.0" "$T/ledger/decisions-2026-10.md")" -eq 1 ] && printf "%s" "$OUT2" | grep -q "^verification: every source body and state value found exactly once"'
OUT3="$(MEM_NOW=2026-10-23T10:00Z "$T/bin/mem" migrate --from "$SRC" --map "$WORK/map.csv" --rules-from "$RULES_SRC" --state "$WORK/comms-state.json" 2>&1)"
check "a re-run in the same second writes its report as migrate-<UTC>-2.md and keeps the first" \
  '[ -f "$T/.meta/migrate-20261023T100000Z.md" ] && [ -f "$T/.meta/migrate-20261023T100000Z-2.md" ] && grep -q "^line 11 exists" "$T/.meta/migrate-20261023T100000Z.md" && grep -q "^line 11 exists" "$T/.meta/migrate-20261023T100000Z-2.md" && printf "%s" "$OUT3" | grep -q "^verification: every source body"'
check "a second run in the same second keeps the first pre-migration tar" '[ "$(ls "$HOME"/.wolfmux/backups/memory-pre-migration-*.tar | wc -l | tr -d " ")" -eq 3 ] && [ -f "$PRE" ] && [ -f "$HOME/.wolfmux/backups/memory-pre-migration-20261023T100000Z-2.tar" ]'
check "migrate refuses a memory root inside --from" 'fresh "$SRC/inner" 2>/dev/null; ! "$SRC/inner/bin/mem" migrate --from "$SRC" --map "$WORK/map.csv" --dry-run; /bin/rm -rf "$SRC/inner"'
SUM_BEFORE="$(tree_sum "$T")"
check "migrate refuses --from, --rules-from and --claude-mem-from inside the root or holding it, and writes nothing" \
  'for flags in "--from $T/topics" "--from $SRC --rules-from $T/rules" "--from $SRC --rules-from $WORK" "--from $SRC --claude-mem-from $T" "--from $SRC --claude-mem-from $WORK"; do OUT="$("$T/bin/mem" migrate $flags --map "$WORK/map.csv" --dry-run 2>&1)" && exit 1; printf "%s" "$OUT" | grep -q "and the memory root $T overlap (one holds the other)" || exit 1; done && [ "$SUM_BEFORE" = "$(tree_sum "$T")" ]'
printf 'source,source_type\nx,file\n' >"$WORK/bad.csv"
check "migrate refuses a map without the contract columns" '! "$T/bin/mem" migrate --from "$SRC" --map "$WORK/bad.csv" --dry-run'
/bin/rm -rf "$HOME/.wolfmux"
unset MEM_NOW

echo "== scale: add skips the full lint; one token pass over the ledger"
T="$WORK/scale"
fresh "$T"
topic "$T" pair-one "alpha, beta, gamma"
topic "$T" pair-two "alpha, beta, gamma"
chmod 644 "$T/topics/pair-one.md"
OUT="$(echo "Zinc and copper." | "$T/bin/mem" add --region topics --name lone --keywords "zinc, copper" --summary "metals" 2>&1)"
check "add regenerates MEMORY.md but runs no full lint: a problem elsewhere is left to mem check" \
  '[ "$OUT" = "ADD topics/lone.md" ] && grep -q "(topics/lone.md)" "$T/MEMORY.md"'
OUT="$("$T/bin/mem" check)"
check "mem check still finds that problem and the pair that shares its keywords" \
  'printf "%s" "$OUT" | grep -q "^PROBLEM topics/pair-one.md has mode 644, want 600" && printf "%s" "$OUT" | grep -q "^WARN    topics/pair-one.md and topics/pair-two.md share 100% of their keywords"'
T="$WORK/refs"
fresh "$T"
for f in ref-plain ref-longer ref.dot ref_under; do topic "$T" "$f" "$f, refs" 3 2026-09-01; done
printf 'Keep REF-PLAIN, and ref-longer-still; see ref.dot.' | MEM_NOW=2026-10-20T08:00Z "$T/bin/mem" decide --time 2026-10-20T08:00Z --source chat >/dev/null
DRY="$(MEM_NOW=2026-10-23T09:00Z "$T/bin/mem" drain --dry-run)"
check "ledger references: any case and whole names only; a name with . or _ still matches" \
  'printf "%s" "$DRY" | grep -q "^candidate topics/ref-longer.md (rule 4" && printf "%s" "$DRY" | grep -q "^candidate topics/ref_under.md (rule 4" && ! printf "%s" "$DRY" | grep -q -e "topics/ref-plain.md" -e "topics/ref.dot.md"'

echo "== the lock, paths outside the root, status"
T="$WORK/lock"
fresh "$T"
( sleep 4 | "$T/bin/mem" decide --time 2026-10-09T13:50Z --source chat >/dev/null 2>&1 ) &
HOLDER=$!
sleep 1.5
OUT="$(MEM_LOCK_WAIT=0 "$T/bin/mem" set cursors.slack_dm 7 2>&1)"; RC=$?
check "a second writer is refused (exit 75) while another writer holds the lock" \
  '[ "$RC" -eq 75 ] && printf "%s" "$OUT" | grep -q "another writer holds" && ! grep -q slack_dm "$T/state/cursors.json"'
check "readers take no lock: recall and status work while it is held" '"$T/bin/mem" status >/dev/null && "$T/bin/mem" recall zebra | grep -q "no match"'
CARD_SUM="$(tree_sum "$T/core/card.md")"
OUT="$("$T/bin/mem" boot 2>"$WORK/boot-busy.err")"; RC=$?
check "boot while another writer holds the lock still reads: it prints a fresh card at once, unsaved, and says so" \
  '[ "$RC" -eq 0 ] && printf "%s" "$OUT" | grep -q "^# Card" && grep -q "the card below is current but not saved" "$WORK/boot-busy.err" && [ "$CARD_SUM" = "$(tree_sum "$T/core/card.md")" ]'
wait "$HOLDER"
check "once the lock is free the same writer goes through" '"$T/bin/mem" set cursors.slack_dm 7 >/dev/null && grep -q "\"slack_dm\": 7" "$T/state/cursors.json"'
printf -- '---\nname: evil\nregion: topics\nkeywords: evil\nsummary: outside\nlinks:\nimportance: 3\nlast_confirmed: 2026-10-01\nstatus: live\n---\nOutside.\n' >"$WORK/outside.md"
OUTSIDE_SUM="$(tree_sum "$WORK/outside.md")"
ln -s "$WORK/outside.md" "$T/topics/evil.md"
check "a symlink out of the root is refused, and the file it points at is untouched" \
  'OUT="$(echo new | "$T/bin/mem" add --region topics --name evil --keywords evil --summary s 2>&1)"; [ $? -eq 1 ] && printf "%s" "$OUT" | grep -q "outside the memory root" && [ "$OUTSIDE_SUM" = "$(tree_sum "$WORK/outside.md")" ]'
/bin/rm -f "$T/topics/evil.md"
printf -- '- 2026-10-01 ../outside-dest.md from topics/zzz.md: crafted\n' >>"$T/archive/index.md"
check "an archive index line that leads outside the root is refused" \
  'OUT="$("$T/bin/mem" unarchive outside-dest 2>&1)"; [ $? -eq 1 ] && printf "%s" "$OUT" | grep -q "outside the memory root"'
check "a tree that was never initialised is refused" '/bin/mkdir -p "$WORK/plain" && ! "$T/bin/mem" --root "$WORK/plain" boot && [ ! -e "$WORK/plain/core" ]'
check "an unknown command and a missing option exit 64" \
  '"$T/bin/mem" frobnicate >/dev/null 2>&1; [ $? -eq 64 ] && "$T/bin/mem" sent --to x >/dev/null 2>&1; [ $? -eq 64 ]'
OUT="$("$T/bin/mem" status)"
check "status shows sizes, counts per region, index vs cap, candidates, last backup and last check" \
  'printf "%s" "$OUT" | grep -q "^size: [0-9]* bytes in [0-9]* files" && printf "%s" "$OUT" | grep -q "^live: rules 0, people 0, teams 0, topics 0" && printf "%s" "$OUT" | grep -q "^index: [0-9]* / 5000 bytes, [0-9]* / 80 lines; card: [0-9]* / 2000 bytes" && printf "%s" "$OUT" | grep -q "^drain candidates: rule 4 0" && printf "%s" "$OUT" | grep -q "^last backup: none" && printf "%s" "$OUT" | grep -q "^last check: 20"'

echo
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
