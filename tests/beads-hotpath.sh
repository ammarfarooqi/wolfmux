#!/bin/bash
# beads-hotpath.sh — what runs on every notice and every status-bar redraw never calls bd.
#
# Why (P0, 2026-10-15): every bd call opens the whole Beads store before it reads one row,
# and bd calls run one at a time. A 2 GB store made each call 2.7 s, and with several agents
# reacting to one notice the k-th call waited k x 2.7 s. The notices themselves must not add
# to that: a hook or a badge that asked bd would be paid for on every bead change, by every
# agent, and every few seconds by tmux. So:
#   · hooks/beads-nudge, with a task and a message on stdin (create, update, close). It
#     starts `teamctl nudge` in the background, both the typed way and the filed way, and
#     from v1.20.0 also `teamctl _human-inbox-hook` for a message
#   · the agent's own hooks: teamctl _inbox-stop and _inbox-prompt
#   · the status bar: teamctl _inbox-badge, _overview-badge and _model-badge
# all run with a stand-in bd FIRST on the PATH that writes down every call it gets, and that
# list must stay empty. Two control checks show the stand-in would have seen a call: bd run
# directly, and a teamctl command that does ask bd (`_refresh-hooks` asks `bd where`).
# Each path is also checked for having done its work, so an early exit cannot pass for "no bd".
#
# Fully isolated from any team you have running: its own tmux server (socket
# wolfmux-test-hotpath-<pid>), its own state directory, a throwaway git repository and stub
# agents. No real Beads store is opened.
#
#   tests/beads-hotpath.sh
# No pipefail: checks end in `grep -q`, which closes the pipe early by design.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-hotpath.XXXXXX")"
export WOLFMUX_HOME="$REPO/config/wolfmux"
export WOLFMUX_BIN_DIR="$REPO/bin"
export WOLFMUX_DATA="$WORK/data"
export WOLFMUX_TMUX_SOCKET="wolfmux-test-hotpath-$$"
export WOLFMUX_LAUNCHER_FABLE="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_FLASH="$REPO/tests/stub-agent"
export WOLFMUX_NUDGE_RETRY=1
export WOLFMUX_NUDGE_HUMAN_IDLE=1
export WOLFMUX_NUDGE_LEAD_IDLE=1 # 300 in real use
export WOLFMUX_NUDGE_DEFER_MAX=20
export WOLFMUX_NUDGE_DEBOUNCE=0
export WOLFMUX_HUMAN=human
export WOLFMUX_NOTIFY_TTY="$WORK/notifications"
export WOLFMUX_NOTIFIER_APP="$WORK/no-such.app"
export WOLFMUX_OSASCRIPT="$WORK/no-such-osascript"
: >"$WOLFMUX_NOTIFY_TTY"
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR WOLFMUX_NOTIFY WOLFMUX_SPLASH TMUX TMUX_PANE
unset WOLFMUX_TEAM WOLFMUX_TEAM_ARG WOLFMUX_SESSION WOLFMUX_WORKTREE WOLFMUX_BRANCH WOLFMUX_MODEL
unset WOLFMUX_NUDGE_TYPE WOLFMUX_INBOX_CLIENTS WOLFMUX_INBOX_STALL_NOTIFY
unset WOLFMUX_INBOX_APPROVAL_TYPE WOLFMUX_INBOX_STOP_COOLDOWN WOLFMUX_INBOX_MARK
unset BEADS_DIR

# The stand-in bd, first on the PATH for everything below, the team's tmux server included.
# It answers nothing useful on purpose: a hot path that needed its answer would show up here
# as a call either way. Each line: the arguments, then the command that ran it.
FAKE_BD="$WORK/fake-bd"
BD_LOG="$WORK/bd-calls"
/bin/mkdir -p "$FAKE_BD"
cat >"$FAKE_BD/bd" <<EOF
#!/bin/bash
printf '%s\037%s\n' "\$*" "\$(/bin/ps -o command= -p "\$PPID" 2>/dev/null)" >>"$BD_LOG"
exit 0
EOF
/bin/chmod 755 "$FAKE_BD/bd"
export PATH="$FAKE_BD:$PATH"
: >"$BD_LOG"

# An agent's command runs from its own pane (tests/in-pane: the pane proof); without TEAM_ROLE the shim changes nothing.
teamctl() { "$REPO/tests/in-pane" "$@"; }
tmx() { tmux -L "$WOLFMUX_TMUX_SOCKET" "$@"; }

passed=0
failed=0
skipped=0
check() { # <description> <command string>
  if eval "$2" >/dev/null 2>&1; then
    passed=$((passed + 1))
    printf '  pass  %s\n' "$1"
  else
    failed=$((failed + 1))
    printf '  FAIL  %s\n' "$1"
  fi
}
skip() { # <description> <why>
  skipped=$((skipped + 1))
  printf '  SKIP  %s\n        (%s)\n' "$1" "$2"
}

cleanup() {
  tmx kill-server >/dev/null 2>&1
  /bin/rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$WOLFMUX_TMUX_SOCKET"
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT

PROJECT="$WORK/demo project" # the space is deliberate
/bin/mkdir -p "$PROJECT"
cd "$PROJECT" || exit 1
git init -q -b main
echo hello >README.md
git add -A
git -c user.name=hotpath -c user.email=hotpath@example.invalid commit -qm "initial commit"

teamctl start fable --no-attach --skip-beads >/dev/null 2>&1
teamctl spawn qa flash --no-kickoff >/dev/null 2>&1
sleep 2
SESSION="$(teamctl status --json | jq -r .session)"
QA_PANE="$(teamctl status --json | jq -r '.agents[] | select(.role == "qa") | .pane')"
[ -n "$SESSION" ] && [ "$SESSION" != "null" ] && [ -n "$QA_PANE" ] && [ "$QA_PANE" != "null" ] || {
  echo "setup failed: no team"
  exit 1
}
SOCKET_PATH="$(tmx display-message -p -t "$QA_PANE" '#{socket_path}')"
STATE_DIR="$(ls -d "$WOLFMUX_DATA"/state/*/ 2>/dev/null | head -1)"
STATE_DIR="${STATE_DIR%/}"
INBOX="$STATE_DIR/inbox"

# calls — what the stand-in was asked, arguments only
calls() { awk -F'\037' '{ print $1 }' "$BD_LOG" 2>/dev/null; }
# bead <id> <assignee> <type> <status> — the JSON bd hands its hooks on stdin
bead() { printf '{"id":"%s","title":"t","assignee":"%s","issue_type":"%s","status":"%s","created_by":"x"}\n' "$1" "$2" "$3" "$4"; }
# fire <actor> <event> <id> <assignee> <type> <status> — what bd does after a write: run the
# hook in the project, with the writer's identity, the bead on stdin
fire() {
  bead "$3" "$4" "$5" "$6" | (cd "$PROJECT" && BEADS_ACTOR="$1" TEAM_ROLE="$1" "$WOLFMUX_HOME/hooks/beads-nudge" "$3" "$2")
}
# settle — wait for the hook's background work (nudges and their waiters) to end
settle() {
  local i=0
  while [ "$i" -lt 90 ]; do
    pgrep -f "teamctl (nudge .*--id hp-$$-|_human-inbox-hook)" >/dev/null 2>&1 || return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}
# hook <role> <_inbox-stop|_inbox-prompt> — the agent's own hook, in its own environment
hook() { (cd "$PROJECT" && TEAM_ROLE="$1" BEADS_ACTOR="$1" WOLFMUX_TEAM=default teamctl "$2" </dev/null 2>/dev/null); }

echo "== control: the stand-in sees a call when there is one"
check "control: bd run directly is written down" 'bd show hp-control >/dev/null && calls | grep -qx "show hp-control"'
check "control: teamctl finds the stand-in too (_refresh-hooks asks bd where)" '(cd "$PROJECT" && teamctl _refresh-hooks >/dev/null 2>&1); calls | grep -qx "where"'
: >"$BD_LOG"

T1="hp-$$-t1" T2="hp-$$-t2" M1="hp-$$-m1" M2="hp-$$-m2" H1="hp-$$-h1"

echo "== hooks/beads-nudge: the typed way (no client attached, panes quiet)"
fire lead create "$T1" qa task open
fire qa update "$T1" qa task blocked
fire qa create "$M1" lead message open
fire lead create "$H1" human message open
fire qa close "$T1" qa task closed
fire lead close "$M1" lead message closed
check "the hook's nudges ended within 90 s" 'settle'
check "it did its work: qa's notice was typed into qa's pane" 'teamctl capture qa --all | grep -qF "Beads update for qa ($T1)"'
check "and the lead's notices reached the lead (blocked, message, closed task)" 'grep -qF "$M1" "$INBOX/lead" && [ "$(grep -cF "$T1" "$INBOX/lead")" -ge 1 ]'

echo "== hooks/beads-nudge: the filed way (WOLFMUX_NUDGE_TYPE=off: nothing typed)"
export WOLFMUX_NUDGE_TYPE=off
fire lead create "$T2" qa task open
fire qa create "$M2" lead message open
unset WOLFMUX_NUDGE_TYPE
check "the filed nudges ended within 90 s" 'settle'
check "it did its work: both notices are in the inbox files, not yet given to the agents" 'grep -F "$T2" "$INBOX/qa" | awk -F"\t" "{ print \$3 }" | grep -q "u$" && grep -F "$M2" "$INBOX/lead" | awk -F"\t" "{ print \$3 }" | grep -q "u$"'

if grep -q '_human-inbox-hook)' "$REPO/bin/teamctl"; then
  check "_human-inbox-hook (v1.20.0): it did its work, the human's message is in the index" 'grep -qF "$H1" "$STATE_DIR/human-inbox"'
else
  skip "_human-inbox-hook (v1.20.0): the human's message is in the index" "skipped: not on this branch (no teamctl _human-inbox-hook)"
fi

echo "== the agent's hooks"
STOP_OUT="$(hook qa _inbox-stop)"
PROMPT_OUT="$(hook lead _inbox-prompt)"
check "_inbox-stop did its work: it continued the turn once (Stop hook feedback, no decision key), with qa's filed notice" 'printf "%s" "$STOP_OUT" | jq -e ".hookSpecificOutput.hookEventName == \"Stop\" and (has(\"decision\") | not)" && printf "%s" "$STOP_OUT" | jq -r .hookSpecificOutput.additionalContext | grep -qF "$T2" && printf "%s" "$STOP_OUT" | jq -r .hookSpecificOutput.additionalContext | grep -q "bd list --assignee qa"'
check "_inbox-prompt did its work: it handed the lead its filed notice" 'printf "%s" "$PROMPT_OUT" | grep -qF "$M2"'

echo "== the status bar"
# Called the way tmux.conf calls them, with the session's own @wolfmux_root and @wolfmux_team.
BAR_ROOT="$(tmx show-options -t "=$SESSION:" -qv @wolfmux_root 2>/dev/null)"
BAR_TEAM="$(tmx show-options -t "=$SESSION:" -qv @wolfmux_team 2>/dev/null)"
INBOX_BADGE="$(teamctl _inbox-badge "$SESSION" "$BAR_ROOT" "$BAR_TEAM" 2>&1)"
OVERVIEW_BADGE="$(teamctl _overview-badge "$SOCKET_PATH" 2>&1)"
teamctl _model-badge "$BAR_ROOT" "$BAR_TEAM" >/dev/null 2>&1
MODEL_RC=$?
check "_inbox-badge did its work: it counts the notices" '[ -n "$INBOX_BADGE" ]'
check "_overview-badge did its work: it prints the overview line" '[ -n "$OVERVIEW_BADGE" ]'
check "_model-badge ran and exited 0" '[ "$MODEL_RC" -eq 0 ]'

echo "== the point of it all"
check "not one bd call from any of the above" '[ ! -s "$BD_LOG" ]'
if [ -s "$BD_LOG" ]; then
  echo "        bd was called (arguments | from):"
  tr '\037' '|' <"$BD_LOG" | sed 's/^/          /' | head -20
fi

echo
echo "result: $passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
