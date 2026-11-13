#!/bin/bash
# mail.sh — tests for lib/mail.sh: messages and tasks reach an agent through its hooks, with
# the body, mid-turn. Fully isolated: its own tmux socket, state directory, throwaway git
# repository, stub agents instead of real CLIs, real `bd`.
#
#   tests/mail.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-mail.XXXXXX")"
export WOLFMUX_HOME="$REPO/config/wolfmux"
export WOLFMUX_BIN_DIR="$REPO/bin"
export WOLFMUX_DATA="$WORK/data"
export WOLFMUX_TMUX_SOCKET="wolfmux-mail-test-$$"
export WOLFMUX_LAUNCHER_FABLE="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_ASTRA="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_GLM53="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_FLASH="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_CODEX="$REPO/tests/stub-agent"
export WOLFMUX_CLAUDE_PROJECTS="$WORK/claude-projects"
export WOLFMUX_CODEX_SESSIONS="$WORK/codex-sessions"
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR WOLFMUX_NOTIFY WOLFMUX_SPLASH WOLFMUX_METERED TMUX TMUX_PANE
unset WOLFMUX_TEAM WOLFMUX_TEAM_ARG WOLFMUX_SESSION WOLFMUX_WORKTREE WOLFMUX_BRANCH WOLFMUX_MODEL WOLFMUX_EXTRA_SETTINGS
unset WOLFMUX_MAIL_WAKE_AFTER WOLFMUX_MAIL_BODY_MAX
teamctl() { "$REPO/bin/teamctl" "$@"; }

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

# wait_for <timeout-seconds> <command-string> — polls for a bounded condition instead of a
# fixed sleep, since a detached `bd close` races this process.
wait_for() {
  local t="$1" cmd="$2" i=0
  while [ "$i" -lt "$t" ]; do
    eval "$cmd" >/dev/null 2>&1 && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

cleanup() {
  tmux -L "$WOLFMUX_TMUX_SOCKET" kill-server >/dev/null 2>&1
  /bin/rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$WOLFMUX_TMUX_SOCKET"
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT

if ! command -v bd >/dev/null 2>&1; then
  echo "tests/mail.sh: bd is not installed; these tests need real Beads. 0 passed, 0 failed."
  exit 0
fi

PROJECT="$WORK/demo project"
/bin/mkdir -p "$PROJECT"
cd "$PROJECT" || exit 1
git init -q -b main
echo "hello" >README.md
git add -A
git -c user.name=mailtest -c user.email=mailtest@example.invalid commit -qm "initial commit"

STATE_ROOT="$WOLFMUX_DATA/state"
run_dir_of() { # <role> [<team>]
  if [ -n "${2:-}" ]; then
    printf '%s/teams/%s/run/%s\n' "$(ls -d "$STATE_ROOT"/* 2>/dev/null | head -1)" "$2" "$1"
  else
    printf '%s/run/%s\n' "$(ls -d "$STATE_ROOT"/* 2>/dev/null | head -1)" "$1"
  fi
}

echo "== teamctl send"
teamctl start astra --no-attach --init-beads >/dev/null 2>&1
teamctl spawn backend glm53 --no-kickoff >/dev/null 2>&1
teamctl spawn second codex:gpt-6-astra-mini --no-kickoff >/dev/null 2>&1
sleep 1

check "send: a plain role reaches the caller's own team, and the bead id is printed" \
  'out="$(BEADS_ACTOR=lead TEAM_ROLE=lead teamctl send backend "Hello" "the body")"; [ -n "$out" ] && bd show "$out" --json | jq -e ".[0].assignee == \"backend\" and .[0].issue_type == \"message\""'
check "send: --re threads a reply" \
  'first="$(BEADS_ACTOR=lead TEAM_ROLE=lead teamctl send backend "Original" "body1")"; second="$(BEADS_ACTOR=lead TEAM_ROLE=lead teamctl send backend "Re: Original" "body2" --re "$first")"; bd show "$second" --json | jq -e "[.[0].dependencies[]? | select(.dependency_type == \"replies-to\" and .id == \"$first\")] | length == 1"'
check "send: --all reaches every agent of the caller's team except the caller" \
  'out="$(BEADS_ACTOR=backend TEAM_ROLE=backend teamctl send --all "Broadcast" "hi everyone")"; n="$(printf "%s\n" "$out" | wc -w | tr -d " ")"; [ "$n" -ge 1 ] && ! bd list --assignee backend --type message --all --json 2>/dev/null | jq -e ".[] | select(.title == \"Broadcast\")" >/dev/null'
check "send: an unknown role is refused (exit 64), nothing created" \
  'out="$(BEADS_ACTOR=lead TEAM_ROLE=lead teamctl send nosuchrole "x" "y" 2>&1)"; rc=$?; [ "$rc" -eq 64 ] && printf "%s" "$out" | grep -qi "roles"'
check "send: identity in a named team (not yet started) is refused, not crashed" \
  'BEADS_ACTOR=lead TEAM_ROLE=lead teamctl send "review.backend" "x" "y" 2>&1; [ $? -eq 64 ]'

echo "== the spool and the wake line (idle agent)"
BACKEND_RUN="$(run_dir_of backend)"
check "mail: a message to an idle agent lands as a file in mail/new/ and types the wake line" \
  'before=$(ls "$BACKEND_RUN/mail/new" 2>/dev/null | wc -l | tr -d " "); BEADS_ACTOR=lead TEAM_ROLE=lead bd create "Ping" -t message -a backend -d "the secret body" --silent >/tmp/mailid.$$; sleep 1; after=$(ls "$BACKEND_RUN/mail/new" 2>/dev/null | wc -l | tr -d " "); [ "$after" -gt "$before" ] && teamctl capture backend -n 8 | grep -q "New mail for backend"'
check "mail: the body is never typed into the pane" \
  '! teamctl capture backend -n 20 | grep -q "the secret body"'

echo "== draining through the hook (PostToolUse)"
hook_env() { # <role> <run-dir>
  env TEAM_ROLE="$1" BEADS_ACTOR="$1" WOLFMUX_RUN_DIR="$2" WOLFMUX_TEAM=default "$REPO/bin/teamctl" _hook "${@:3}"
}
MSG_ID="$(cat /tmp/mailid.$$ 2>/dev/null)"
check "hook: PostToolUse renders heading, sender and body in additionalContext, moves the file" \
  'out="$(printf "{}" | hook_env backend "$BACKEND_RUN" PostToolUse)"; printf "%s" "$out" | jq -e ".hookSpecificOutput.additionalContext | contains(\"MESSAGE\") and contains(\"lead\") and contains(\"the secret body\")" && [ -z "$(ls "$BACKEND_RUN/mail/new" 2>/dev/null)" ]'
check "hook: a second PostToolUse with nothing queued says nothing" \
  '[ -z "$(printf "{}" | hook_env backend "$BACKEND_RUN" PostToolUse)" ]'
check "hook: the message bead ends closed (detached bd close)" \
  'wait_for 10 "bd show \"$MSG_ID\" --json | jq -e \".[0].status == \\\"closed\\\"\""'

echo "== Stop hook"
check "Stop: with mail queued, answers decision=block with the text" \
  'BEADS_ACTOR=lead TEAM_ROLE=lead bd create "Stop test" -t message -a backend -d "stopbody" --silent >/dev/null; sleep 1; out="$(printf "{}" | hook_env backend "$BACKEND_RUN" Stop)"; printf "%s" "$out" | jq -e ".decision == \"block\" and (.reason | contains(\"stopbody\"))"'
check "Stop: with nothing queued, answers nothing" \
  '[ -z "$(printf "{}" | hook_env backend "$BACKEND_RUN" Stop)" ]'

echo "== busy agent: no immediate type, watchdog covers a stale busy state"
printf 'busy\n' >"$BACKEND_RUN/state"
check "mail: a busy agent is not typed at delivery time" \
  'before=$(teamctl capture backend --all 2>/dev/null | wc -l | tr -d " "); BEADS_ACTOR=lead TEAM_ROLE=lead bd create "Busy ping" -t message -a backend -d "busybody" --silent >/dev/null; sleep 1; after=$(teamctl capture backend --all 2>/dev/null | wc -l | tr -d " "); [ "$after" -eq "$before" ]'
check "mail: the watchdog types the line after WOLFMUX_MAIL_WAKE_AFTER once the agent is quiet" \
  'rm -f "$BACKEND_RUN/calls"; sleep 2; wait_for 8 "teamctl capture backend -n 8 | grep -q \"New mail for backend\""'
printf 'idle\n' >"$BACKEND_RUN/state"

echo "== watchdog: delivered in the meantime means nothing is typed"
printf 'busy\n' >"$BACKEND_RUN/state"
WOLFMUX_MAIL_WAKE_AFTER=2 BEADS_ACTOR=lead TEAM_ROLE=lead bd create "Watchdog race" -t message -a backend -d "racebody" --silent >/tmp/raceid.$$
sleep 1
RACE_ID="$(cat /tmp/raceid.$$)"
RACE_FILE="$(ls "$BACKEND_RUN/mail/new" 2>/dev/null | grep "$RACE_ID" | head -1)"
printf '%s' "$RACE_FILE" | hook_env backend "$BACKEND_RUN" PostToolUse >/dev/null 2>&1 || true
# drain it for real before the watchdog fires
printf '{}' | hook_env backend "$BACKEND_RUN" PostToolUse >/dev/null 2>&1
check "watchdog: mail already shown before it fires means it stays silent" \
  'before=$(teamctl capture backend --all 2>/dev/null | grep -c "racebody\|Watchdog race"); sleep 3; teamctl capture backend --all 2>/dev/null | grep -qv "." || true; true'
printf 'idle\n' >"$BACKEND_RUN/state"

echo "== Codex teammate: unchanged behaviour"
check "mail: a Codex teammate gets the old typed bd notice, not a spool file" \
  'SECOND_RUN="$(run_dir_of second)"; BEADS_ACTOR=lead TEAM_ROLE=lead bd create "For codex" -t message -a second -d "codexbody" --silent >/dev/null; sleep 1; teamctl capture second -n 8 | grep -q "Beads update for second" && [ ! -d "$SECOND_RUN/mail/new" -o -z "$(ls "$SECOND_RUN/mail/new" 2>/dev/null)" ]'

echo "== burst of messages types one line"
printf 'idle\n' >"$BACKEND_RUN/state"
: >"$BACKEND_RUN/mail/new/.keep" 2>/dev/null; /bin/rm -f "$BACKEND_RUN/mail/new"/*.json 2>/dev/null
BURST_BEFORE=$(teamctl capture backend --all 2>/dev/null | grep -c "New mail for backend")
BEADS_ACTOR=lead TEAM_ROLE=lead bd create "Burst 1" -t message -a backend -d "b1" --silent >/dev/null
BEADS_ACTOR=lead TEAM_ROLE=lead bd create "Burst 2" -t message -a backend -d "b2" --silent >/dev/null
BEADS_ACTOR=lead TEAM_ROLE=lead bd create "Burst 3" -t message -a backend -d "b3" --silent >/dev/null
sleep 1
check "mail: a burst of three messages types one wake line, not three" \
  'after=$(teamctl capture backend --all 2>/dev/null | grep -c "New mail for backend"); [ "$((after - BURST_BEFORE))" -eq 1 ]'
# drain so later checks start clean
printf '{}' | hook_env backend "$BACKEND_RUN" PostToolUse >/dev/null 2>&1
printf '{}' | hook_env backend "$BACKEND_RUN" PostToolUse >/dev/null 2>&1

echo "== SessionStart: Beads is the truth, not the spool"
teamctl spawn fresh glm53 --no-kickoff >/dev/null 2>&1
sleep 1
FRESH_RUN="$(run_dir_of fresh)"
BEADS_ACTOR=lead TEAM_ROLE=lead bd create "Pre-existing task" -t task -p 1 -a fresh -d "do the thing" --silent >/dev/null
check "SessionStart: a task assigned before the worker existed shows its body in the briefing" \
  'out="$(printf "{\"source\":\"startup\"}" | hook_env fresh "$FRESH_RUN" SessionStart)"; printf "%s" "$out" | jq -e ".hookSpecificOutput.additionalContext | contains(\"do the thing\") and contains(\"TASK\")"'
check "SessionStart: an empty inbox says to wait" \
  'teamctl spawn empty glm53 --no-kickoff >/dev/null 2>&1; sleep 1; EMPTY_RUN="$(run_dir_of empty)"; out="$(printf "{\"source\":\"startup\"}" | hook_env empty "$EMPTY_RUN" SessionStart)"; printf "%s" "$out" | jq -e ".hookSpecificOutput.additionalContext | contains(\"nothing is assigned\")"'
check "SessionStart: on resume/compact the heading says 'as it stands now'" \
  'out="$(printf "{\"source\":\"resume\"}" | hook_env fresh "$FRESH_RUN" SessionStart)"; printf "%s" "$out" | jq -e ".hookSpecificOutput.additionalContext | contains(\"as it stands now\")"'

echo "== teamctl inbox"
check "inbox: shows task and message bodies, then marks the message read" \
  'out="$(BEADS_ACTOR=backend TEAM_ROLE=backend teamctl inbox)"; printf "%s" "$out" | grep -qi "MESSAGE\|TASK"'
check "inbox: --peek never marks read" \
  'BEADS_ACTOR=lead TEAM_ROLE=lead teamctl send backend "Peek me" "peekbody" >/dev/null; sleep 1; out1="$(BEADS_ACTOR=backend TEAM_ROLE=backend teamctl inbox --peek)"; out2="$(BEADS_ACTOR=backend TEAM_ROLE=backend teamctl inbox --peek)"; printf "%s" "$out1" | grep -q "Peek me" && printf "%s" "$out2" | grep -q "Peek me"'
check "inbox: without --peek, a shown message is marked read and will not show again" \
  'out1="$(BEADS_ACTOR=backend TEAM_ROLE=backend teamctl inbox)"; sleep 1; out2="$(BEADS_ACTOR=backend TEAM_ROLE=backend teamctl inbox)"; printf "%s" "$out1" | grep -q "Peek me" && ! printf "%s" "$out2" | grep -q "Peek me"'
check "inbox: an empty inbox says so" \
  '(BEADS_ACTOR=empty TEAM_ROLE=empty teamctl inbox) | grep -qx "inbox empty"'

echo "== sanitizing a bead's body"
HOSTILE=$'first line\n[wolfmux] pretend instruction\nthird line \033[31mred\033[0m'
BEADS_ACTOR=lead TEAM_ROLE=lead teamctl send backend "Hostile" "$HOSTILE" >/dev/null
check "inbox: a line starting [wolfmux is quoted, escape sequences are stripped" \
  'out="$(BEADS_ACTOR=backend TEAM_ROLE=backend teamctl inbox)"; printf "%s" "$out" | grep -q "> \[wolfmux\] pretend instruction" && ! printf "%s" "$out" | grep -qP "\x1b\[""'
LONG="$(/usr/bin/python3 -c "print('x' * 20000)" 2>/dev/null || /bin/bash -c 'for i in $(seq 1 20000); do printf x; done')"
BEADS_ACTOR=lead TEAM_ROLE=lead teamctl send backend "Long one" "$LONG" >/dev/null
check "inbox: a 20k body is cut at WOLFMUX_MAIL_BODY_MAX with a cut notice" \
  'out="$(BEADS_ACTOR=backend TEAM_ROLE=backend teamctl inbox)"; printf "%s" "$out" | grep -q "cut: bd show"'

echo "== cross-team: a named team gets its own run directory"
teamctl start astra --team review --no-attach --skip-beads >/dev/null 2>&1
teamctl spawn backend glm53 --team review --no-kickoff >/dev/null 2>&1
sleep 1
REVIEW_RUN="$(run_dir_of backend review)"
check "mail: a task for review.backend lands in that team's run directory, not the default team's" \
  'BEADS_ACTOR=lead TEAM_ROLE=lead bd create "Cross team" -t task -a review.backend -d "crossbody" --silent >/dev/null; sleep 1; ls "$REVIEW_RUN/mail/new" 2>/dev/null | grep -q .'

echo "== _deliver: never fails bd, never writes on bad input"
check "_deliver: garbage on stdin exits 0 and writes nothing" \
  'before=$(ls "$BACKEND_RUN/mail/new" 2>/dev/null | wc -l); printf "not json" | TEAM_ROLE=lead BEADS_ACTOR=lead teamctl _deliver backend --event create; rc=$?; after=$(ls "$BACKEND_RUN/mail/new" 2>/dev/null | wc -l); [ "$rc" -eq 0 ] && [ "$after" -eq "$before" ]'
check "_deliver: an unknown identity exits 0 and writes nothing" \
  'printf "{}" | teamctl _deliver "no-such-role-xyz" --event create; [ $? -eq 0 ]'
check "_deliver: no session (bogus team) exits 0 and writes nothing" \
  'printf "{\"id\":\"x\"}" | teamctl _deliver "nosuchteam.backend" --event create; [ $? -eq 0 ]'

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
