#!/bin/bash
# ledger.sh: a lead that stays small (ADR-0040): `teamctl done` keeps the whole report as a file
# and the lead's mail is a short notice; `teamctl show <id> --report`; `teamctl decide`;
# `teamctl ledger`, and the lead's SessionStart after a compaction or a resume. No model is called.
#
# Runs once per store, native and Beads, each fully isolated: its own tmux socket, state
# directory, throwaway git repository, stub agents. Without bd the Beads half reports and is
# skipped; the native half always runs.
#
#   tests/ledger.sh              both stores
#   tests/ledger.sh native       one of them (unit: the parts that need no store)
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
TOP="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-ledger.XXXXXX")"
export WOLFMUX_HOME="$REPO/config/wolfmux"
export WOLFMUX_BIN_DIR="$REPO/bin"
export WOLFMUX_LAUNCHER_FABLE="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_GLM53="$REPO/tests/stub-agent"
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR WOLFMUX_IDENTITY WOLFMUX_NOTIFY WOLFMUX_SPLASH WOLFMUX_METERED TMUX TMUX_PANE
unset WOLFMUX_TEAM WOLFMUX_TEAM_ARG WOLFMUX_SESSION WOLFMUX_WORKTREE WOLFMUX_BRANCH WOLFMUX_MODEL WOLFMUX_EXTRA_SETTINGS
unset WOLFMUX_RUN_DIR WOLFMUX_MAIL_BODY_MAX WOLFMUX_INBOX_CLIENTS WOLFMUX_STORE BEADS_DIR
JQ="$(command -v jq)"
teamctl() { "$REPO/bin/teamctl" "$@"; }
# as an agent, from inside its own pane (tests/in-pane): <role> <teamctl args...>
as() {
  local role="$1"
  shift
  BEADS_ACTOR="$role" TEAM_ROLE="$role" "$REPO/tests/in-pane" "$@"
}

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

# wait_for <seconds> <command string>: polls a bounded condition (a Beads hook delivers detached)
wait_for() {
  local t="$1" i=0
  while [ "$i" -lt "$((t * 4))" ]; do
    eval "$2" >/dev/null 2>&1 && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

SOCKETS=""
cleanup() {
  local s
  for s in $SOCKETS; do
    tmux -L "$s" kill-server >/dev/null 2>&1
    /bin/rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$s"
  done
  /bin/rm -rf "$TOP"
}
trap cleanup EXIT

last_task_id() { tail -1 | sed -E 's/^task ([^ ]+) ->.*/\1/'; }

# hook <role> <event> <json>: the CLI's call of that agent's hook, from its own pane
hook() {
  printf '%s' "$3" | BEADS_ACTOR="$1" TEAM_ROLE="$1" WOLFMUX_RUN_DIR="$STATE/run/$1" "$REPO/tests/in-pane" _hook "$2"
}
context_of() { "$JQ" -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }

# commit_in <dir> <file>: one commit in a worker's worktree
commit_in() {
  (cd "$1" && echo "$RANDOM" >>"$2" && git add -A && git -c user.name=w -c user.email=w@example.invalid commit -qm "work on $2")
}

# body_of_size <n> <file>: n characters of report text: many lines, quotes, $(...), a tab
body_of_size() {
  python3 -c '
import sys
n = int(sys.argv[1])
line = "detail line with \"quotes\", it'"'"'s $(echo not-run) `tick`\tand a tab; "
out = ""
i = 0
while len(out) < n:
    out += "%05d %s\n" % (i, line)
    i += 1
sys.stdout.write(out[:n])
' "$1" >"$2"
}

# unit_lib <command string>: runs it with the wolfmux modules sourced (no tmux, no store), in a
# subshell under set -euo pipefail as teamctl runs: an expansion error is a non-zero exit there
unit_lib() {
  (
    set -euo pipefail
    for module in provider-env common registry tmuxctl worktree beads policy agents hooks store mail ledger; do
      . "$WOLFMUX_HOME/lib/$module.sh"
    done
    JQ_BIN="$JQ"
    eval "$1"
  )
}

# long <n> <char>: n times that character
long() { python3 -c 'import sys; sys.stdout.write(sys.argv[2] * int(sys.argv[1]))' "$1" "$2"; }

# chars <text>: its length in characters, whatever the locale
chars() { python3 -c 'import sys; print(len(sys.argv[1]))' "$1"; }

run_unit() {
  echo "== the Done notice: at most 600 characters, whatever the fields are"
  local P300 T400 B120 MB n out rc
  P300="/$(long 288 p)/reports/x.md"
  T400="tests: $(long 394 t)"
  B120="ai/$(long 117 b)"
  MB="$(long 200 'é')"
  for case in "state path 300" "tests line 400" "branch 120" "all three, multi-byte summary" "all three, short summary"; do
    case "$case" in
      "state path 300") args=(wolfmux-abc memory-management.backend "Build it" "a summary" "t: 1 passed" ai/x abc1234 " 2 files changed, 3 insertions(+)" "$P300") ;;
      "tests line 400") args=(wolfmux-abc backend "Build it" "a summary" "$T400" ai/x abc1234 " 1 file changed" /s/reports/x.md) ;;
      "branch 120") args=(wolfmux-abc backend "Build it" "a summary" "t" "$B120" abc1234 " 1 file changed" /s/reports/x.md) ;;
      "all three, multi-byte summary") args=(wolfmux-abc.12 memory-management.backend "$(long 80 T)" "$MB" "$T400" "$B120" abc1234 " $(long 100 s)" "$P300") ;;
      "all three, short summary") args=(wolfmux-abc memory-management.backend "$(long 80 T)" "ok" "$T400" "$B120" abc1234 " 9 files changed" "$P300") ;;
    esac
    out="$(LANG=en_US.UTF-8 unit_lib_args "${args[@]}" 2>&1)"
    rc=$?
    n="$(chars "[wolfmux mail] $out")"
    check "notice, $case: built without an error (exit 0)" '[ "$rc" -eq 0 ]'
    check "notice, $case: at most 600 characters with the mail prefix ($n)" '[ "$n" -le 600 ]'
    check "notice, $case: it still names the command to the full report" 'printf "%s" "$out" | grep -qF "read it: teamctl show ${args[0]} --report"'
    case "$case" in
      *multi-byte*) check "notice, $case: keeps at least 120 characters of the summary, whole characters" \
        '[ "$(printf "%s" "$out" | sed -n 2p | python3 -c "import sys; s=sys.stdin.buffer.read().decode(\"utf-8\"); print(s.count(\"é\"))")" -ge 120 ]' ;;
      *short*) check "notice, $case: a short summary is whole" 'printf "%s" "$out" | sed -n 2p | grep -qx "ok"' ;;
    esac
  done
  check "notice, multi-byte under the C locale: still at most 600 characters, valid UTF-8" \
    'out="$(LC_ALL=C LANG=C unit_lib_args wolfmux-abc backend "Build it" "$MB$MB$MB" "t" ai/x abc1234 " 1 file changed" "$P300")" && [ "$(chars "[wolfmux mail] $out")" -le 600 ] && printf "%s" "$out" | python3 -c "import sys; sys.stdin.buffer.read().decode(\"utf-8\")"'

  echo "== the ledger: done rows and decisions do not depend on the length of the state path"
  local now rows i d
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  rows="$(python3 -c '
import json, sys
now = sys.argv[1]
r = [{"id": "wolfmux-o%d" % i, "status": "open", "assignee": "backend", "title": "Open task number %d with a title long enough to be cut after sixty" % i, "blocked_by": []} for i in range(200)]
r.append({"id": "wolfmux-done1", "status": "closed", "assignee": "backend", "title": "done", "updated_at": now})
r.append({"id": "wolfmux-old1", "status": "closed", "assignee": "backend", "title": "old", "updated_at": "2020-01-01T00:00:00Z"})
print(json.dumps(r))' "$now")"
  for d in short long; do
    if [ "$d" = short ]; then L="$TOP/u"; else L="$TOP/$(long 240 l)"; fi
    /bin/mkdir -p "$L/reports" "$L/run/lead"
    : >"$L/reports/wolfmux-done1.md"
    : >"$L/decisions"
    for i in $(seq 1 30); do printf '%s\t%s decision number %s\n' "$now" "$(long 270 d)" "$i" >>"$L/decisions"; done
    out="$(L="$L" ROWS="$rows" unit_lib 'PROJECT_STATE="$L"; STATE_DIR="$L"; TEAM=default; ledger_text "$ROWS"')"
    check "ledger, $d state path (${#L}): at most 4000 characters" '[ "$(chars "$out")" -le 4000 ]'
    check "ledger, $d state path: keeps the done task with its report path" 'printf "%s" "$out" | grep -qF "wolfmux-done1 backend report: $L/reports/wolfmux-done1.md"'
    check "ledger, $d state path: keeps the newest decision" 'printf "%s" "$out" | grep -q "decision number 30$"'
    check "ledger, $d state path: open tasks say how many more" 'printf "%s" "$out" | grep -Eq "^\([0-9]+ more: teamctl tasks\)$"'
  done

  echo "== the ledger: done tasks of the last 24 hours, or since the conversation began if earlier"
  L="$TOP/u24"
  /bin/mkdir -p "$L/run/lead"
  rows="$(python3 -c '
import json, sys, datetime
n = datetime.datetime.now(datetime.timezone.utc)
f = lambda h: (n - datetime.timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ")
print(json.dumps([{"id": "wolfmux-h1", "status": "closed", "assignee": "a", "updated_at": f(1)},
                  {"id": "wolfmux-h30", "status": "closed", "assignee": "a", "updated_at": f(30)},
                  {"id": "wolfmux-h60", "status": "closed", "assignee": "a", "updated_at": f(60)}]))')"
  check "ledger: with no conversation start, 1 hour ago is listed, 30 hours ago is not" \
    'out="$(L="$L" ROWS="$rows" unit_lib "PROJECT_STATE=\$L; STATE_DIR=\$L; TEAM=default; ledger_text \"\$ROWS\"")"; printf "%s" "$out" | grep -q "^wolfmux-h1 " && ! printf "%s" "$out" | grep -q "^wolfmux-h30 "'
  check "ledger: a conversation that began 48 hours ago lists 30 hours ago, not 60" \
    'echo $(( $(date +%s) - 48 * 3600 )) >"$L/run/lead/ledger-began"; out="$(L="$L" ROWS="$rows" unit_lib "PROJECT_STATE=\$L; STATE_DIR=\$L; TEAM=default; ledger_text \"\$ROWS\"")"; printf "%s" "$out" | grep -q "^wolfmux-h30 " && ! printf "%s" "$out" | grep -q "^wolfmux-h60 "'
  check "ledger: a conversation that began 1 hour ago still lists the last 24 hours" \
    'echo $(( $(date +%s) - 3600 )) >"$L/run/lead/ledger-began"; out="$(L="$L" ROWS="$rows" unit_lib "PROJECT_STATE=\$L; STATE_DIR=\$L; TEAM=default; ledger_text \"\$ROWS\"")"; printf "%s" "$out" | grep -q "^wolfmux-h1 " && ! printf "%s" "$out" | grep -q "^wolfmux-h30 "'
  check "ledger: multi-byte titles and decisions stay at most 4000 characters" \
    'L2="$TOP/umb"; /bin/mkdir -p "$L2/run/lead"; : >"$L2/decisions"; for i in $(seq 1 30); do printf "%s\t%s\n" "$now" "$(long 290 "é")" >>"$L2/decisions"; done; R2="$(python3 -c "import json; print(json.dumps([{\"id\": \"wolfmux-m%d\" % i, \"status\": \"open\", \"assignee\": \"b\", \"title\": \"é\" * 80} for i in range(100)]))")"; out="$(L="$L2" ROWS="$R2" unit_lib "PROJECT_STATE=\$L; STATE_DIR=\$L; TEAM=default; ledger_text \"\$ROWS\"")"; [ "$(chars "$out")" -le 4000 ]'
}

# unit_lib_args <ledger_report_notice args...>
unit_lib_args() {
  (
    set -euo pipefail
    for module in provider-env common registry tmuxctl worktree beads policy agents hooks store mail ledger; do
      . "$WOLFMUX_HOME/lib/$module.sh"
    done
    JQ_BIN="$JQ"
    ledger_report_notice "$@"
  )
}

# run_store <native|beads>
run_store() {
  local kind="$1" start_flag
  WORK="$TOP/$kind"
  /bin/mkdir -p "$WORK"
  # a state path of about 300 characters: the Done notice and the ledger must not depend on it
  export WOLFMUX_DATA="$WORK/$(long 220 d)/data"
  export WOLFMUX_TMUX_SOCKET="wolfmux-ledger-$kind-$$"
  export WOLFMUX_CLAUDE_PROJECTS="$WORK/claude-projects"
  export WOLFMUX_CODEX_SESSIONS="$WORK/codex-sessions"
  SOCKETS="$SOCKETS $WOLFMUX_TMUX_SOCKET"
  if [ "$kind" = beads ]; then
    export WOLFMUX_STORE=beads
    start_flag="--init-beads"
  else
    export WOLFMUX_STORE=native
    start_flag="--skip-beads"
  fi
  PROJECT="$WORK/project"
  /bin/mkdir -p "$PROJECT"
  cd "$PROJECT" || return 1
  git init -q -b main
  echo hello >README.md
  git add -A
  git -c user.name=t -c user.email=t@example.invalid commit -qm "initial commit"
  teamctl start fable --no-attach "$start_flag" >/dev/null 2>&1
  teamctl spawn backend glm53 --no-kickoff >/dev/null 2>&1
  sleep 1
  STATE="$(ls -d "$WOLFMUX_DATA"/state/* | head -1)"
  BACKEND_DIR="$(teamctl status --json | "$JQ" -r '[.agents[] | select(.role == "backend")][0].workdir')"
  check "$kind: the store is $kind" '[ "$(teamctl store 2>&1 | grep -c "$kind")" -ge 1 ]'
  # the lead's conversation begins: its SessionStart records when (the ledger counts done from it)
  hook lead SessionStart '{"source":"startup"}' >/dev/null

  echo "== $kind: a report is a file, the lead's mail is short"
  T1="$(teamctl task backend "Build the widget" -d "the body" | last_task_id)"
  as backend claim "$T1" >/dev/null 2>&1
  commit_in "$BACKEND_DIR" widget.txt
  body_of_size 20000 "$WORK/body20k.txt"
  # drain whatever the lead has queued so far: only the Done notice counts below
  /bin/rm -f "$STATE/run/lead/mail/new/"* 2>/dev/null
  SUMMARY="$(printf 'first line of the summary\nsecond: he said "yes", it'"'"'s $(touch %s/pwned) and `touch %s/pwned2`' "$WORK" "$WORK")"
  DONE_OUT="$(as backend done "$T1" "$SUMMARY" --tests "tests/widget.sh: 12 passed" --body-file "$WORK/body20k.txt" 2>&1)"
  REPORT="$STATE/reports/$T1.md"
  check "$kind: done names the report file and closes the task" \
    'printf "%s" "$DONE_OUT" | grep -qF "report: $REPORT" && printf "%s" "$DONE_OUT" | grep -q "^closed: $T1$"'
  check "$kind: the report file is beside the store, <state>/reports/<task-id>.md" '[ -s "$REPORT" ]'
  check "$kind: the report file holds every character of the 20,000-character --body-file" \
    'python3 -c "import sys; b=open(sys.argv[1]).read(); r=open(sys.argv[2]).read(); sys.exit(0 if len(b)==20000 and b in r else 1)" "$WORK/body20k.txt" "$REPORT"'
  check "$kind: the report file holds the summary as written, and the tests line, branch and commits" \
    'python3 -c "import sys; r=open(sys.argv[1]).read(); sys.exit(0 if sys.argv[2] in r else 1)" "$REPORT" "$SUMMARY" && grep -q "^tests: tests/widget.sh: 12 passed$" "$REPORT" && grep -q "^branch: " "$REPORT" && grep -Eq "^commits \([0-9]+\):" "$REPORT"'
  check "$kind: nothing in the summary was run" '[ ! -e "$WORK/pwned" ] && [ ! -e "$WORK/pwned2" ]'
  wait_for 10 'ls "$STATE/run/lead/mail/new/"*.json'
  sleep 1
  NOTICE="$(hook lead PostToolUse '{}' | context_of)"
  printf '      (%s: %s characters reach the lead for one done with a 20,000-character report)\n' "$kind" "${#NOTICE}"
  check "$kind: what reaches the lead through its hooks is at most 600 characters" '[ -n "$NOTICE" ] && [ "${#NOTICE}" -le 600 ]'
  check "$kind: the notice names the task, the tests line, branch, short sha, diff stat, report path (dropped when long) and the command" \
    'printf "%s" "$NOTICE" | grep -q "DONE $T1 by backend: Build the widget" && printf "%s" "$NOTICE" | grep -qF "tests/widget.sh: 12 passed" && printf "%s" "$NOTICE" | grep -q "^branch: .* at $(cd "$BACKEND_DIR" && git rev-parse --short HEAD)$" && printf "%s" "$NOTICE" | grep -q "file.* changed" && { printf "%s" "$NOTICE" | grep -qF "full report: $REPORT" || { [ "${#REPORT}" -gt 150 ] && ! printf "%s" "$NOTICE" | grep -q "full report:"; }; } && printf "%s" "$NOTICE" | grep -qF "read it: teamctl show $T1 --report"'
  check "$kind: the notice says it is already marked read and needs no reply" \
    'printf "%s" "$NOTICE" | grep -q "already marked read and needs no reply" && ! printf "%s" "$NOTICE" | grep -q "Reply: teamctl send"'
  check "$kind: the summary's newlines, quotes and \$(...) arrive literally" \
    'printf "%s" "$NOTICE" | grep -q "^first line of the summary$" && printf "%s" "$NOTICE" | grep -qF "second: he said \"yes\", it'"'"'s \$(touch $WORK/pwned)"'
  check "$kind: the 20,000-character body is not in the notice" '! printf "%s" "$NOTICE" | grep -q "detail line with"'
  check "$kind: the report message is marked read in the store (the lead's inbox has no unread Done)" \
    'wait_for 5 "[ \"\$(teamctl mail lead --peek --json | \"$JQ\" -r \"[.[] | select(.title == \\\"Done: Build the widget\\\")] | length\")\" = 0 ]"'
  check "$kind: no second notice to the lead for the close of the task it has the report of" \
    'sleep 2; ls "$STATE/run/lead/mail/seen/"*.json >/dev/null 2>&1 && ! "$JQ" -e --arg id "$T1" "select(.id == \$id and .event == \"close\")" "$STATE/run/lead/mail/new/"*.json "$STATE/run/lead/mail/seen/"*.json 2>/dev/null | grep -q .'
  check "$kind: the lead's inbox file has one line for this done, not two" \
    '[ "$(grep -c "" "$STATE/inbox/lead" 2>/dev/null)" -le 1 ]'

  echo "== $kind: done with long fields: a state path of ${#STATE}, a tests line of 400, a multi-byte summary"
  TL="$(teamctl task backend "Long fields" -d x | last_task_id)"
  as backend claim "$TL" >/dev/null 2>&1
  commit_in "$BACKEND_DIR" long.txt
  /bin/rm -f "$STATE/run/lead/mail/new/"* 2>/dev/null
  as backend done "$TL" "$(long 300 "é")" --tests "tests: $(long 394 t)" >/dev/null 2>&1
  DONE_RC=$?
  check "$kind: long fields: done exits 0 and closes the task" \
    '[ "$DONE_RC" -eq 0 ] && [ "$(teamctl show "$TL" --json | "$JQ" -r .status)" = closed ]'
  wait_for 10 'ls "$STATE/run/lead/mail/new/"*.json'
  sleep 1
  NL="$(hook lead PostToolUse '{}' | context_of)"
  check "$kind: long fields: the lead has one notice, at most 600 characters ($(chars "$NL"))" \
    '[ "$(printf "%s" "$NL" | grep -c "^\[wolfmux mail\] DONE $TL ")" = 1 ] && [ "$(chars "$NL")" -le 600 ]'

  echo "== $kind: teamctl show <id> --report, and show on a done task"
  check "$kind: show --report prints the stored report, every character" \
    'teamctl show "$T1" --report >"$WORK/shown.txt" && cmp -s "$WORK/shown.txt" "$REPORT"'
  check "$kind: show on a done task names the report path" 'teamctl show "$T1" | grep -qF "report: $REPORT"'
  check "$kind: show --report on a task with no report says so (exit 1)" \
    'T0="$(teamctl task backend "No report yet" -d x | last_task_id)"; out="$(teamctl show "$T0" --report 2>&1)"; [ $? -eq 1 ] && printf "%s" "$out" | grep -q "no report for $T0"'
  check "$kind: show --report and --json together are a usage error (64)" 'teamctl show "$T1" --report --json; [ $? -eq 64 ]'
  check "$kind: the notice's message, shown by id, carries the command to the full report (a lead without hooks)" \
    'mid="$("$JQ" -r "select(.title == \"Done: Build the widget\") | .id" "$STATE/run/lead/mail/seen/"*.json | head -1)"; [ -n "$mid" ] && teamctl show "$mid" | grep -qF "teamctl show $T1 --report"'

  echo "== $kind: a second done after a reopen keeps the first report"
  teamctl reopen "$T1" "one more thing" >/dev/null 2>&1
  as backend claim "$T1" >/dev/null 2>&1
  commit_in "$BACKEND_DIR" widget2.txt
  as backend done "$T1" "the second round" --tests "tests/widget.sh: 13 passed" >/dev/null 2>&1
  check "$kind: the first report is kept as <id>.1.md, whole" \
    'python3 -c "import sys; b=open(sys.argv[1]).read(); r=open(sys.argv[2]).read(); sys.exit(0 if b in r else 1)" "$WORK/body20k.txt" "$STATE/reports/$T1.1.md"'
  check "$kind: <id>.md is the second report" 'grep -q "^the second round$" "$REPORT" && ! grep -q "detail line" "$REPORT"'
  check "$kind: show names the earlier report" 'teamctl show "$T1" | grep -qF "earlier reports: $STATE/reports/$T1.1.md"'

  echo "== $kind: teamctl decide"
  check "$kind: a worker cannot decide (exit 77), nothing recorded" \
    'as backend decide "workers do not decide"; [ $? -eq 77 ] && [ ! -s "$STATE/decisions" ]'
  check "$kind: an empty decision is refused (64)" 'teamctl decide "   "; [ $? -eq 64 ]'
  check "$kind: a decision over 300 characters is refused (64)" \
    'teamctl decide "$(printf "x%.0s" $(seq 1 301))"; [ $? -eq 64 ] && [ ! -s "$STATE/decisions" ]'
  check "$kind: a decision of exactly 300 characters is kept" \
    'teamctl decide "$(printf "y%.0s" $(seq 1 300))" && teamctl decide --list | grep -q "^1\. [0-9-]* yyyy"'
  teamctl decide --drop 1 >/dev/null 2>&1
  check "$kind: the lead decides; --list shows it dated, numbered" \
    'teamctl decide "ship v1.26 with the ledger" | grep -q "decision 1 recorded" && teamctl decide --list | grep -q "^1\. $(date -u +%Y-%m-%d) ship v1.26 with the ledger$"'
  check "$kind: a decision with quotes and \$(...) is kept literally, on one line" \
    'teamctl decide "use \"native\" by default; \$(not run)" && teamctl decide --list | grep -qF "2. $(date -u +%Y-%m-%d) use \"native\" by default; \$(not run)"'
  check "$kind: --drop <n> removes that one" 'teamctl decide --drop 1 && ! teamctl decide --list | grep -q "ship v1.26" && teamctl decide --list | grep -q "^1\. .*native"'
  check "$kind: --drop of a number that is not there is refused" 'teamctl decide --drop 9; [ $? -ne 0 ]'
  check "$kind: a worker cannot drop one (77)" 'as backend decide --drop 1; [ $? -eq 77 ]'
  for i in $(seq 1 31); do teamctl decide "decision number $i" >/dev/null 2>&1; done
  check "$kind: at most 30 kept; the oldest leave first" \
    '[ "$(teamctl decide --list | grep -c "")" = 30 ] && ! teamctl decide --list | grep -q "native" && ! teamctl decide --list | grep -q "decision number 1$" && teamctl decide --list | grep -q "^30\. .* decision number 31$"'

  echo "== $kind: teamctl ledger"
  T2="$(teamctl task backend "An open task with a title that is much longer than sixty characters in all" -d x | last_task_id)"
  LEDGER="$(teamctl ledger)"
  check "$kind: one line per open task: id, state, assignee, title cut at 60" \
    'printf "%s" "$LEDGER" | grep -q "^$T2 open backend An open task with a title that is much longer than sixty cha\.\.\.$"'
  check "$kind: one line per task done since the conversation began: id, assignee, report path" \
    'printf "%s" "$LEDGER" | grep -qF "$T1 backend report: $REPORT"'
  check "$kind: the decisions, newest last" 'printf "%s" "$LEDGER" | tail -1 | grep -q "decision number 31$"'
  check "$kind: the ledger is at most 4000 characters" '[ "${#LEDGER}" -le 4000 ]'

  echo "== $kind: the lead's SessionStart"
  check "$kind: compact attaches the ledger to the lead" \
    'hook lead SessionStart "{\"source\":\"compact\"}" | context_of | grep -q "^\[wolfmux ledger\] team default"'
  check "$kind: resume attaches the ledger to the lead" \
    'hook lead SessionStart "{\"source\":\"resume\"}" | context_of | grep -qF "$T1 backend report: $REPORT"'
  check "$kind: a fresh start attaches no ledger" \
    '! hook lead SessionStart "{\"source\":\"startup\"}" | context_of | grep -q "wolfmux ledger"'
  check "$kind: a worker never gets it, on compact or resume" \
    '! hook backend SessionStart "{\"source\":\"compact\"}" | context_of | grep -q "wolfmux ledger" && ! hook backend SessionStart "{\"source\":\"resume\"}" | context_of | grep -q "wolfmux ledger"'
  check "$kind: hook input with agent_id (a subagent) attaches nothing" \
    'o="$(hook lead SessionStart "{\"source\":\"compact\",\"agent_id\":\"a1\",\"agent_type\":\"Explore\"}" 2>&1)"; printf "%s" "$o" >"${LEDGER_DEBUG:-/dev/null}"; [ -z "$o" ]'

  echo "== $kind: the ledger cap with 200 tasks"
  (
    for module in provider-env common registry tmuxctl worktree beads policy agents store; do
      . "$WOLFMUX_HOME/lib/$module.sh"
    done
    load_project >/dev/null 2>&1
    for i in $(seq 1 200); do
      store_task_create lead backend 2 "Bulk task number $i with a title long enough to be cut somewhere after sixty" "x" >/dev/null
    done
  ) 2>/dev/null
  BIG="$(teamctl ledger)"
  printf '      (%s: the ledger with 200+ tasks and 30 decisions is %s characters)\n' "$kind" "${#BIG}"
  check "$kind: with 200 tasks the ledger stays at most 4000 characters" '[ "${#BIG}" -le 4000 ]'
  check "$kind: and says how many more there are and where to see them" 'printf "%s" "$BIG" | grep -Eq "^\([0-9]+ more: teamctl tasks\)$"'
  check "$kind: and still has the done tasks and the newest decision" \
    'printf "%s" "$BIG" | grep -qF "$T1 backend report:" && printf "%s" "$BIG" | grep -q "decision number 31$"'
  check "$kind: SessionStart after a compaction attaches the capped ledger" \
    'out="$(hook lead SessionStart "{\"source\":\"compact\"}" | context_of)"; printf "%s" "$out" | grep -q "^\[wolfmux ledger\]" && [ "$(printf "%s" "$out" | sed -n "/^\[wolfmux ledger\]/,\$p" | wc -c)" -le 4100 ]'

  tmux -L "$WOLFMUX_TMUX_SOCKET" kill-server >/dev/null 2>&1
  cd "$TOP" || true
}

stores="${1:-unit native beads}"
for kind in $stores; do
  if [ "$kind" = unit ]; then
    run_unit
    continue
  fi
  if [ "$kind" = beads ] && ! command -v bd >/dev/null 2>&1; then
    echo "== beads: bd is not installed; the Beads half is skipped"
    continue
  fi
  run_store "$kind"
done

echo
echo "ledger: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
