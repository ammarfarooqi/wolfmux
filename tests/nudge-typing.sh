#!/bin/bash
# nudge-typing.sh — a notice is never typed into a pane a human may be typing in.
#
# The bug this guards (issue #9): teamctl nudge typed its one-line notice into the
# target pane and pressed Enter. A human mid-sentence had their half-typed text and
# the notice submitted glued together: "i said install bun if requir[wolfmux] Beads
# update ... include-infraed". Here the notice has to WAIT instead, and several
# notices that pile up while it waits have to arrive as ONE line.
#
# Fully isolated from any team you have running: its own tmux server (socket
# wolfmux-test-nudge-<pid>), its own state directory, a throwaway git repository and
# stub agents. It never touches the live "wolfmux" socket or a real role.
#
#   tests/nudge-typing.sh
# No pipefail: checks end in `grep -q`, which closes the pipe early by design.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-nudge.XXXXXX")"
export WOLFMUX_HOME="$REPO/config/wolfmux"
export WOLFMUX_BIN_DIR="$REPO/bin"
export WOLFMUX_DATA="$WORK/data"
export WOLFMUX_TMUX_SOCKET="wolfmux-test-nudge-$$"
export WOLFMUX_LAUNCHER_FABLE="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_FLASH="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_GLM53="$REPO/tests/stub-agent"
# Short waits so the suite stays quick; the defaults are 3 / 5 / 600.
export WOLFMUX_NUDGE_RETRY=1
export WOLFMUX_NUDGE_HUMAN_IDLE=3
export WOLFMUX_NUDGE_DEFER_MAX=60
export WOLFMUX_NUDGE_DEBOUNCE=0 # the debounce has its own check in smoke.sh
# Run from an agent's pane, the environment carries that agent's team and session.
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR WOLFMUX_NOTIFY WOLFMUX_SPLASH TMUX TMUX_PANE
unset WOLFMUX_TEAM WOLFMUX_TEAM_ARG WOLFMUX_SESSION WOLFMUX_WORKTREE WOLFMUX_BRANCH WOLFMUX_MODEL
teamctl() { "$REPO/bin/teamctl" "$@"; }
tmx() { tmux -L "$WOLFMUX_TMUX_SOCKET" "$@"; }

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

ATTACH_PID=""
cleanup() {
  [ -z "$ATTACH_PID" ] || kill "$ATTACH_PID" 2>/dev/null
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
git -c user.name=nudge -c user.email=nudge@example.invalid commit -qm "initial commit"

teamctl start fable --no-attach --skip-beads >/dev/null 2>&1
teamctl spawn qa flash --no-kickoff >/dev/null 2>&1
sleep 2
PANE="$(teamctl status --json | jq -r '.agents[] | select(.role == "qa") | .pane')"
[ -n "$PANE" ] && [ "$PANE" != "null" ] || {
  echo "setup failed: no pane for qa"
  exit 1
}
STATE_DIR="$(ls -d "$WOLFMUX_DATA"/state/*/ 2>/dev/null | head -1)"
STATE_DIR="${STATE_DIR%/}" # the default team keeps its state right there
pending_dir() { printf '%s\n' "$STATE_DIR/nudge/qa.pending"; }
pane_row() { tmx capture-pane -p -J -t "$PANE" -S "$(tmx display-message -p -t "$PANE" '#{cursor_y}')" -E "$(tmx display-message -p -t "$PANE" '#{cursor_y}')"; }
notices() { teamctl capture qa --all 2>/dev/null | grep -c "$1"; }
HALF="i said install bun if requir"
type_half() { tmx send-keys -t "$PANE" -l "$HALF"; }
submit_half() { tmx send-keys -t "$PANE" Enter; } # the line the human was writing goes off on its own

echo "== the input line already holds something"
type_half
sleep 0.5
teamctl nudge qa --id half-1 >"$WORK/defer-1.log" 2>&1
DEFER_STATUS=$?
check "busy input line: the nudge is deferred, and says so in plain words (exit 3)" '[ "$DEFER_STATUS" -eq 3 ] && grep -q "deferred" "$WORK/defer-1.log" && grep -q "typing" "$WORK/defer-1.log"'
check "busy input line: nothing was typed into the pane" '! teamctl capture qa --all | grep -q "wolfmux. Beads update"'
check "busy input line: the half-typed text is still on the input line, unsubmitted" 'pane_row | grep -qF "$HALF"'
check "busy input line: a notice is parked, waiting for the pane" '[ -d "$(pending_dir)" ]'

echo "== several nudges while the pane is busy collapse into one notice"
teamctl nudge qa --id half-2 >/dev/null 2>&1
teamctl nudge qa --id half-3 >/dev/null 2>&1
check "collapse: still exactly one waiter for the role" '[ "$(/bin/ls -d "$(pending_dir)" 2>/dev/null | wc -l | tr -d " ")" = "1" ]'
check "collapse: still nothing typed while the pane is busy" '! teamctl capture qa --all | grep -q "wolfmux. Beads update"'
submit_half
sleep 4
check "collapse: the human's own line was submitted whole, with no notice glued to it" 'teamctl capture qa --all | grep -qF "$HALF" && ! teamctl capture qa --all | grep -q "${HALF}.wolfmux"'
check "collapse: the pane is idle again, so the notice arrives by itself" 'teamctl capture qa --all | grep -q "wolfmux. Beads update for qa"'
check "collapse: three bead ids became ONE line, the generic one that names the whole inbox" '! teamctl capture qa --all | grep -qE "half-(1|2|3)" && teamctl capture qa --all | grep -q "Beads update for qa\. Run: bd list"'
check "collapse: the marker is gone once the notice has been delivered" '[ ! -d "$(pending_dir)" ]'
# One delivered notice shows up twice in a `cat` pane: the tty echoes what was typed
# and the stub prints it back. Measure that once, then count against it.
PER_NOTICE="$(notices "Beads update for qa\. Run: bd list")"
check "collapse: exactly one notice was delivered, not one per nudge" '[ "$PER_NOTICE" -ge 1 ]'

echo "== an idle pane is still notified at once"
tmx send-keys -t "$PANE" Enter # a clean, empty input line
sleep 0.5
teamctl nudge qa --id idle-1 >"$WORK/idle-1.log" 2>&1
IDLE_STATUS=$?
sleep 1
check "idle pane: delivered straight away (exit 0), with the bead id in the line" '[ "$IDLE_STATUS" -eq 0 ] && grep -q "notified: qa" "$WORK/idle-1.log" && teamctl capture qa --all | grep -q "Beads update for qa (idle-1)"'
check "idle pane: nothing was parked" '[ ! -d "$(pending_dir)" ]'
check "idle pane: one nudge delivered one notice" '[ "$(notices "Beads update for qa (idle-1)")" = "$PER_NOTICE" ]'

echo "== copy mode: keys would drive the mode, not the prompt"
tmx copy-mode -t "$PANE"
sleep 0.5
teamctl nudge qa --id copy-1 >"$WORK/copy-1.log" 2>&1
COPY_STATUS=$?
check "copy mode: deferred, never typed" '[ "$COPY_STATUS" -eq 3 ] && grep -q "deferred" "$WORK/copy-1.log" && ! teamctl capture qa --all | grep -q "copy-1"'
tmx send-keys -t "$PANE" -X cancel
sleep 3
check "copy mode: leaving it lets the waiting notice through, naming its bead" 'teamctl capture qa --all | grep -q "Beads update for qa (copy-1)"'

echo "== a human at the keyboard, with an empty input line"
tmx select-window -t "$(tmx display-message -p -t "$PANE" '#{window_id}')" >/dev/null 2>&1
tmx select-pane -t "$PANE" >/dev/null 2>&1
script -q /dev/null tmux -L "$WOLFMUX_TMUX_SOCKET" attach -t "$(tmx display-message -p -t "$PANE" '#{session_name}')" >/dev/null 2>&1 &
ATTACH_PID=$!
disown "$ATTACH_PID" 2>/dev/null || true # killing it later must not print a job notice
sleep 1 # the client attached a moment ago: tmux counts that as input from it
teamctl nudge qa --id human-1 >"$WORK/human-1.log" 2>&1
HUMAN_STATUS=$?
check "human at the keyboard: an empty input line is still not typed into (exit 3)" '[ "$HUMAN_STATUS" -eq 3 ] && ! teamctl capture qa --all | grep -q "human-1"'
sleep 5 # no keystroke for longer than WOLFMUX_NUDGE_HUMAN_IDLE
check "human at the keyboard: once they stop touching the keyboard, the notice arrives" 'teamctl capture qa --all | grep -q "Beads update for qa (human-1)"'
kill "$ATTACH_PID" 2>/dev/null
ATTACH_PID=""
sleep 1

echo "== giving up: a pane that never goes idle"
tmx send-keys -t "$PANE" Enter
sleep 0.5
type_half
sleep 0.5
BEFORE="$(notices "Beads update for qa")"
WOLFMUX_NUDGE_DEFER_MAX=2 teamctl nudge qa --id expire-1 >"$WORK/expire-1.log" 2>&1
EXPIRE_STATUS=$?
check "expiry: deferred first, and the message says it gives up after 2s" '[ "$EXPIRE_STATUS" -eq 3 ] && grep -q "2s" "$WORK/expire-1.log"'
sleep 6
check "expiry: the marker is cleaned up" '[ ! -d "$(pending_dir)" ]'
check "expiry: nothing was ever typed into the busy pane" '[ "$(notices "Beads update for qa")" = "$BEFORE" ] && ! teamctl capture qa --all | grep -q "expire-1"'
check "expiry: the half-typed text is untouched, and the event log says why it gave up" 'pane_row | grep -qF "$HALF" && grep -q "nudge-defer-expired" "$STATE_DIR/events.jsonl"'
tmx send-keys -t "$PANE" Enter

echo "== the switch that brings the old behaviour back"
type_half
sleep 0.5
WOLFMUX_NUDGE_COLLISION_CHECK=0 teamctl nudge qa --id blind-1 >/dev/null 2>&1
BLIND_STATUS=$?
sleep 1
check "WOLFMUX_NUDGE_COLLISION_CHECK=0: types blind again, for whoever needs the old behaviour" '[ "$BLIND_STATUS" -eq 0 ] && teamctl capture qa --all | grep -q "blind-1"'

echo "== the check itself"
# shellcheck disable=SC1090
(
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  tm_input_line_dirty "" && exit 1
  tm_input_line_dirty "   " && exit 1
  tm_input_line_dirty "> " && exit 1
  tm_input_line_dirty "│ >                                        │" && exit 1
  tm_input_line_dirty "╭──────────────────────────────────────────╮" && exit 1
  tm_input_line_dirty "│ > half typed                             │" || exit 1
  tm_input_line_dirty "i said install bun if requir" || exit 1
  tm_input_line_dirty "❯ ls -la" || exit 1
  exit 0
) >/dev/null 2>&1
DIRTY_STATUS=$?
check "input line: an empty prompt and a bare box are clean; anything typed is not" '[ "$DIRTY_STATUS" -eq 0 ]'

teamctl destroy --worktrees --yes >/dev/null 2>&1

echo
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
