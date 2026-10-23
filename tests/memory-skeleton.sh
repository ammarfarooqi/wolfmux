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
OUT="$(MEM_NOW=2026-10-06T10:00Z "$T/bin/mem" add --region topics --name deploy-times --keywords "deploy, fly, noon, times" --summary "deploy times" </dev/null)"
check "add of a new name with >= 70% keyword overlap updates the existing file instead" \
  'printf "%s" "$OUT" | grep -q "^UPDATE topics/deploys.md (keywords overlap 75% with --name deploy-times" && [ ! -e "$T/topics/deploy-times.md" ]'
SUM_BEFORE="$(tree_sum "$T")"
OUT="$(echo body | "$T/bin/mem" add --region topics --name brand-new --keywords "zinc, copper" --summary "metals" --dry-run)"
check "add --dry-run shows the decision and writes nothing" '[ "$OUT" = "would ADD topics/brand-new.md" ] && [ "$SUM_BEFORE" = "$(tree_sum "$T")" ]'
OUT="$(echo "Deploys now go through the release train." | MEM_NOW=2026-10-07T09:00Z "$T/bin/mem" add --region topics --name release-train --keywords "train, release" --summary "deploys ride the release train" --supersedes deploys)"
check "add --supersedes says SUPERSEDE, writes the new file and marks the old one" \
  '[ "$OUT" = "SUPERSEDE topics/release-train.md replaces topics/deploys.md" ] && grep -q "^status: superseded:release-train" "$T/topics/deploys.md" && grep -q "^superseded_on: 2026-10-07" "$T/topics/deploys.md" && [ -f "$T/topics/release-train.md" ]'
check "MEMORY.md lists the new file and leaves the superseded one out" \
  'grep -q "(topics/release-train.md)" "$T/MEMORY.md" && ! grep -q "(topics/deploys.md)" "$T/MEMORY.md"'
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
MEM_NOW=2026-10-12T10:00Z "$T/bin/mem" sweep-log --inboxes 3 --asks-touched 1 --free-pct 41 --swap-gb 2.5 --load 3.2 >/dev/null
check "sweep-log writes one JSON line with the numbers" \
  'python3 -I -c "import json,sys; l=open(sys.argv[1]).read().splitlines(); r=json.loads(l[-1]); sys.exit(not (len(l)==1 and r[\"time\"]==\"2026-10-12T10:00Z\" and r[\"inboxes\"]==3 and r[\"free_pct\"]==41 and r[\"swap_gb\"]==2.5 and r[\"load\"]==3.2))" "$T/ledger/sweeps-2026-10.jsonl"'
check "the ledger files are mode 600" '[ "$(mode_of "$T/ledger/sends-2026-10.md")" = 600 ] && [ "$(mode_of "$T/ledger/sweeps-2026-10.jsonl")" = 600 ]'

echo
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
