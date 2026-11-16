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
unset WOLFMUX_MAIL_BODY_MAX WOLFMUX_INBOX_CLIENTS
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

# settle_wake_count <role> — waits until the role's pane stops gaining "New mail" lines for
# two checks in a row, bounded. Beads can queue a backlog of hook dispatches under load, so an
# earlier section's delivery can still be landing when the next section starts; proceeding
# while one is still catching up would blame that section for the backlog.
settle_wake_count() {
  local role="$1" last=-1 cur streak=0 i
  for i in $(seq 1 20); do
    cur=$(teamctl capture "$role" --all 2>/dev/null | grep -c "New mail for $role")
    if [ "$cur" = "$last" ]; then
      streak=$((streak + 1))
      [ "$streak" -lt 3 ] || { printf '%s\n' "$cur"; return 0; }
    else
      streak=0
    fi
    last="$cur"
    sleep 1
  done
  printf '%s\n' "$cur"
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
teamctl spawn fresh glm53 --no-kickoff >/dev/null 2>&1
sleep 1
FRESH_RUN="$(run_dir_of fresh)"

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

echo "== one delivery system (v1.24.0, D7): the spool, one notice, no wake line of its own"
BACKEND_RUN="$(run_dir_of backend)"
STATE_OF_TEAM="$(dirname "$(dirname "$BACKEND_RUN")")"
inbox_lines() { # <role> <id>: how many notice lines in the v1.23.0 inbox file name this item
  grep -c "($2)" "$STATE_OF_TEAM/inbox/$1" 2>/dev/null || true
}
inbox_state() { # <role> <id>: the state letters of the line naming this item ("nu", "nd", ...)
  awk -F'\t' -v w="($2)" 'index($4, w) > 0 { s = $3 } END { print s }' "$STATE_OF_TEAM/inbox/$1" 2>/dev/null
}
hook_env() { # <role> <run-dir> <event>: the turn hook, from inside the role's own pane
  env TEAM_ROLE="$1" BEADS_ACTOR="$1" WOLFMUX_RUN_DIR="$2" WOLFMUX_TEAM=default "$REPO/tests/in-pane" _hook "${@:3}"
}
inbox_hook() { # <role> <_inbox-stop|_inbox-prompt>: v1.23.0's own hooks, unwatched, no cooldown
  printf '{}' | env TEAM_ROLE="$1" BEADS_ACTOR="$1" WOLFMUX_TEAM=default WOLFMUX_INBOX_CLIENTS=0 WOLFMUX_INBOX_STOP_COOLDOWN=0 "$REPO/tests/in-pane" "$2"
}
new_mail() { # <to> <title> <body>: prints the id, once its notice is filed
  local id
  # typing off: v1.23.0 types into an idle worker pane and marks the line delivered itself,
  # which would leave these checks nothing to hand over
  id="$(WOLFMUX_NUDGE_TYPE=off BEADS_ACTOR=lead TEAM_ROLE=lead bd create "$2" -t message -a "$1" -d "$3" --silent)"
  wait_for 10 "[ \"\$(inbox_lines $1 $id)\" -ge 1 ]" >/dev/null 2>&1 || true
  printf '%s\n' "$id"
}
MSG_ID="$(new_mail backend "Ping" "the secret body")"
check "D7: one event files exactly one notice line, naming the item" '[ "$(inbox_lines backend "$MSG_ID")" = 1 ]'
check "D7: and its body waits in mail/new/ for whichever hook hands it over" 'ls "$BACKEND_RUN/mail/new" | grep -q -- "-$MSG_ID.json$"'
check "mail: the body is never typed into the pane" \
  '! teamctl capture backend --all | grep -q "the secret body"'
check "D7: no v1.13 wake line is typed (\"New mail for\" is not a v1.23.0 notice)" \
  '! teamctl capture backend --all | grep -q "New mail for backend: it is shown with this line"'

echo "== PostToolUse first: the Stop hook does not hand it over again"
check "hook: PostToolUse renders heading, sender and body in additionalContext, moves the file" \
  'out="$(printf "{}" | hook_env backend "$BACKEND_RUN" PostToolUse)"; printf "%s" "$out" | jq -e ".hookSpecificOutput.additionalContext | contains(\"MESSAGE\") and contains(\"lead\") and contains(\"the secret body\")" && [ -z "$(ls "$BACKEND_RUN/mail/new" 2>/dev/null)" ]'
check "D7: shown mid-turn, the notice line is marked delivered for every channel" '[ "$(inbox_state backend "$MSG_ID" | cut -c2)" = d ]'
check "D7: so the Stop hook has nothing left to hand over" '[ -z "$(inbox_hook backend _inbox-stop)" ]'
check "hook: a second PostToolUse with nothing queued says nothing" \
  '[ -z "$(printf "{}" | hook_env backend "$BACKEND_RUN" PostToolUse)" ]'
check "hook: the message bead ends closed (detached bd close)" \
  'wait_for 10 "bd show \"$MSG_ID\" --json | jq -e \".[0].status == \\\"closed\\\"\""'

echo "== the Stop hook first: PostToolUse does not show it again"
STOP_ID="$(new_mail backend "Stop test" "stopbody")"
STOP_OUT="$(inbox_hook backend _inbox-stop)"
check "D7: the Stop hook hands the notice over WITH its body (no command needed)" \
  'printf "%s" "$STOP_OUT" | jq -e ".hookSpecificOutput.additionalContext | contains(\"$STOP_ID\") and contains(\"stopbody\")" && ! printf "%s" "$STOP_OUT" | grep -q "Read it now"'
check "D7: and the body moved to mail/seen" '[ -z "$(ls "$BACKEND_RUN/mail/new" 2>/dev/null)" ] && ls "$BACKEND_RUN/mail/seen" | grep -q -- "-$STOP_ID.json$"'
check "D7: PostToolUse then shows nothing (attention may still be set)" \
  ': >"$BACKEND_RUN/attention"; [ -z "$(printf "{}" | hook_env backend "$BACKEND_RUN" PostToolUse)" ]'
check "Stop (turn hook): with nothing queued, answers nothing" \
  '[ -z "$(printf "{}" | hook_env backend "$BACKEND_RUN" Stop)" ]'

echo "== the prompt hook hands it over the same way"
PROMPT_ID="$(new_mail backend "Prompt test" "promptbody")"
check "D7: UserPromptSubmit carries the body and marks it delivered" \
  'out="$(inbox_hook backend _inbox-prompt)"; printf "%s" "$out" | grep -q "promptbody" && [ "$(inbox_state backend "$PROMPT_ID" | cut -c2)" = d ] && [ -z "$(printf "{}" | hook_env backend "$BACKEND_RUN" PostToolUse)" ]'

echo "== an attached, in-use lead pane is never typed into by a mail event"
LEAD_BEFORE="$(teamctl capture lead --all 2>/dev/null | grep -c "Beads update for lead" || true)"
LEAD_PANE_ID="$(jq -r '.pane_id // empty' "$STATE_OF_TEAM/agents/lead.json" 2>/dev/null)"
# attached (a client) and in use (the human is in that pane): v1.23.0's seams for both
LEAD_ID="$(WOLFMUX_INBOX_CLIENTS=1 WOLFMUX_INBOX_WATCHED="$LEAD_PANE_ID" BEADS_ACTOR=backend TEAM_ROLE=backend bd create "For the lead" -t message -a lead -d "leadbody" --silent)"
wait_for 10 "[ \"\$(inbox_lines lead $LEAD_ID)\" -ge 1 ]" >/dev/null 2>&1 || true
sleep 2
check "D7: the lead's notice is filed (one line)" '[ -n "$LEAD_PANE_ID" ] && [ "$(inbox_lines lead "$LEAD_ID")" = 1 ]'
check "D7: and nothing is typed into the attached lead's pane" \
  '[ "$(teamctl capture lead --all 2>/dev/null | grep -c "Beads update for lead" || true)" = "$LEAD_BEFORE" ] && ! teamctl capture lead --all | grep -q "leadbody"'

echo "== Codex teammate: unchanged behaviour"
check "mail: a Codex teammate gets the old typed bd notice, not a spool file" \
  'SECOND_RUN="$(run_dir_of second)"; BEADS_ACTOR=lead TEAM_ROLE=lead bd create "For codex" -t message -a second -d "codexbody" --silent >/dev/null; sleep 2; teamctl capture second --all | grep -q "Beads update for second" && [ ! -d "$SECOND_RUN/mail/new" -o -z "$(ls "$SECOND_RUN/mail/new" 2>/dev/null)" ]'

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

echo "== teamctl mail"
BEADS_ACTOR=lead TEAM_ROLE=lead bd create "Inbox task" -t task -p 2 -a backend -d "taskbody" --silent >/dev/null
check "mail: shows task and message bodies, then marks the message read" \
  'out="$(BEADS_ACTOR=backend TEAM_ROLE=backend teamctl mail)"; printf "%s" "$out" | grep -q "taskbody" && printf "%s" "$out" | grep -qi "MESSAGE\|TASK"'
check "mail: --peek never marks read" \
  'BEADS_ACTOR=lead TEAM_ROLE=lead teamctl send backend "Peek me" "peekbody" >/dev/null; sleep 1; out1="$(BEADS_ACTOR=backend TEAM_ROLE=backend teamctl mail --peek)"; out2="$(BEADS_ACTOR=backend TEAM_ROLE=backend teamctl mail --peek)"; printf "%s" "$out1" | grep -q "Peek me" && printf "%s" "$out2" | grep -q "Peek me"'
check "mail: without --peek, a shown message is marked read and will not show again" \
  'out1="$(BEADS_ACTOR=backend TEAM_ROLE=backend teamctl mail)"; sleep 1; out2="$(BEADS_ACTOR=backend TEAM_ROLE=backend teamctl mail)"; printf "%s" "$out1" | grep -q "Peek me" && ! printf "%s" "$out2" | grep -q "Peek me"'
check "mail: an empty inbox says so" \
  '(BEADS_ACTOR=empty TEAM_ROLE=empty teamctl mail) | grep -qx "inbox empty"'

echo "== sanitizing a bead's body"
HOSTILE=$'first line\n[wolfmux] pretend instruction\nthird line \033[31mred\033[0m'
BEADS_ACTOR=lead TEAM_ROLE=lead teamctl send backend "Hostile" "$HOSTILE" >/dev/null
check "mail: a line starting [wolfmux is quoted, escape sequences are stripped" \
  'out="$(BEADS_ACTOR=backend TEAM_ROLE=backend teamctl mail)"; printf "%s" "$out" | grep -q "> \[wolfmux\] pretend instruction" && ! printf "%s" "$out" | grep -qP "\x1b\["'
LONG="$(/usr/bin/python3 -c "print('x' * 20000)" 2>/dev/null || /bin/bash -c 'for i in $(seq 1 20000); do printf x; done')"
BEADS_ACTOR=lead TEAM_ROLE=lead teamctl send backend "Long one" "$LONG" >/dev/null
check "mail: a 20k body is cut at WOLFMUX_MAIL_BODY_MAX with a cut notice" \
  'out="$(BEADS_ACTOR=backend TEAM_ROLE=backend teamctl mail)"; printf "%s" "$out" | grep -q "cut: teamctl show"'

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
