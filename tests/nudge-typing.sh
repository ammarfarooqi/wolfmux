#!/bin/bash
# nudge-typing.sh — a notice is never typed into a pane a human may be typing in.
#
# The bug this guards (issue #9): teamctl nudge typed its one-line notice into the
# target pane and pressed Enter. A human mid-sentence had their half-typed text and
# the notice submitted together, as one line: "i said install bun if requir[wolfmux]
# Beads update ... include-infraed".
#
# The second thing it guards, which review round 1 found: a TUI's own placeholder text
# in its input box must not read as a half-typed line, or an idle agent silently stops
# being told about its work. DIM is what tells them apart, not the client list — a
# placeholder is dim, typed text carries no escape sequences at all.
#
# The third, which review round 2 found: the input-line check must run whether or not a
# client is attached. Gating it on a client reopened issue #9, because a line can be
# left half-typed in a pane and the session then detached.
#
# From v1.15.0 a notice is FILED before any of this is decided (lib/inbox.sh). v1.15.0
# also stopped typing into an attached LEAD's pane altogether, and v1.16.1 narrowed that
# to what the complaint actually asked for (issue #12): with a client attached the lead's
# pane is typed into only while it is QUIET — no keystroke for WOLFMUX_NUDGE_LEAD_IDLE
# seconds, nothing on the input line, no copy mode. This suite still drives a lead pane
# for the queued-notice and mid-delivery properties — it detaches the client around those
# blocks rather than giving them up — and has one block of its own for the new rule, with
# the negative twin next to it. The inbox itself is tests/inbox.sh.
#
# Fully isolated from any team you have running: its own tmux server (socket
# wolfmux-test-nudge-<pid>), its own state directory, a throwaway git repository and
# stub agents. It never touches the live "wolfmux" socket or a real role. The attached
# client is a pty of its own (script(1)), and the window size is pinned so that client
# cannot reflow the panes.
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
# Short waits so the suite stays quick; the defaults are 3 / 5 / 600 / 60.
export WOLFMUX_NUDGE_RETRY=1
export WOLFMUX_NUDGE_HUMAN_IDLE=3
export WOLFMUX_NUDGE_LEAD_IDLE=3 # 300 in real use; the lead's pane asks for more quiet
export WOLFMUX_NUDGE_DEFER_MAX=60
export WOLFMUX_NUDGE_DEBOUNCE=0 # the debounce has its own check in smoke.sh
# Run from an agent's pane, the environment carries that agent's team and session.
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR WOLFMUX_NOTIFY WOLFMUX_SPLASH TMUX TMUX_PANE
unset WOLFMUX_TEAM WOLFMUX_TEAM_ARG WOLFMUX_SESSION WOLFMUX_WORKTREE WOLFMUX_BRANCH WOLFMUX_MODEL
unset WOLFMUX_HUMAN_PANE_TYPING WOLFMUX_INBOX_WATCHED WOLFMUX_INBOX_CLIENTS WOLFMUX_NUDGE_TYPE
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
SESSION="$(teamctl status --json | jq -r .session)"
PANE="$(teamctl status --json | jq -r '.agents[] | select(.role == "qa") | .pane')"
LEAD_PANE="$(teamctl status --json | jq -r '.agents[] | select(.role == "lead") | .pane')"
[ -n "$PANE" ] && [ "$PANE" != "null" ] && [ -n "$LEAD_PANE" ] || {
  echo "setup failed: no panes"
  exit 1
}
WINDOW="$(tmx display-message -p -t "$PANE" '#{window_id}')"
# Pin the size: an attached client must not reflow the panes under the checks.
tmx set-option -t "$SESSION" window-size manual >/dev/null 2>&1
tmx resize-window -t "$WINDOW" -x 200 -y 50 >/dev/null 2>&1
STATE_DIR="$(ls -d "$WOLFMUX_DATA"/state/*/ 2>/dev/null | head -1)"
STATE_DIR="${STATE_DIR%/}" # the default team keeps its state right there

pending_dir() { printf '%s\n' "$STATE_DIR/nudge/$1.pending"; }
cursor_row() { tmx capture-pane -p -J -t "$1" -S "$(tmx display-message -p -t "$1" '#{cursor_y}')" -E "$(tmx display-message -p -t "$1" '#{cursor_y}')"; }
notices() { teamctl capture "$1" --all 2>/dev/null | grep -c "$2"; }
clients() { tmx list-clients -t "$SESSION" -F x 2>/dev/null | wc -l | tr -d ' '; }
attach_client() {
  script -q /dev/null tmux -L "$WOLFMUX_TMUX_SOCKET" attach -t "$SESSION" >/dev/null 2>&1 &
  ATTACH_PID=$!
  disown "$ATTACH_PID" 2>/dev/null || true # killing it later must not print a job notice
  sleep 1
}
detach_client() {
  [ -z "$ATTACH_PID" ] || kill "$ATTACH_PID" 2>/dev/null
  ATTACH_PID=""
  sleep 1
}
HALF="i said install bun if requir"
# A second string for the episodes with a client attached. HALF is typed and submitted
# in the no-client episode above, so the attached episodes' "nothing was glued" checks
# need a string that only they ever typed.
HALF2="the lead reviews this next"
type_text() { tmx send-keys -t "$1" -l "$2"; }
type_half() { type_text "$1" "$HALF"; }
submit() { tmx send-keys -t "$1" Enter; } # the line the human was writing goes off on its own

echo "== nobody attached: a dim placeholder is furniture, typed text is not (review rounds 1 and 2)"
check "setup: no client is attached to the test session" '[ "$(clients)" = "0" ]'
# A TUI's placeholder, drawn the way a TUI draws it: straight onto the pane's terminal,
# dim, so it lands on the cursor row without going through the stub's stdin.
PANE_TTY="$(tmx display-message -p -t "$PANE" '#{pane_tty}')"
printf '\033[2mTry "fix typecheck errors"\033[0m' >"$PANE_TTY" 2>/dev/null
sleep 0.5
check "setup: the dim placeholder really is on the pane's cursor row" 'cursor_row "$PANE" | grep -qF "fix typecheck errors"'
teamctl nudge qa --id hint-1 >"$WORK/hint-1.log" 2>&1
HINT_STATUS=$?
sleep 1
# Round 2's regression: gating the row check on a client was meant to fix THIS, and the
# dim strip fixes it without the gate. An idle agent must never stop being told.
check "no client, dim placeholder: delivered at once, not read as a half-typed line" '[ "$HINT_STATUS" -eq 0 ] && teamctl capture qa --all | grep -q "Beads update for qa (hint-1)"'
check "no client, dim placeholder: nothing was parked" '[ ! -d "$(pending_dir qa)" ]'
submit "$PANE"
sleep 0.5
# Round 2's new blocker: this is issue #9 verbatim, on a DETACHED session.
type_half "$PANE"
sleep 0.5
BEFORE="$(notices qa "Beads update for qa")"
teamctl nudge qa --id gate-1 >"$WORK/gate-1.log" 2>&1
GATE_STATUS=$?
sleep 1
check "no client, a half-typed line: deferred (exit 3), and the reason names the input line" '[ "$GATE_STATUS" -eq 3 ] && grep -q "deferred" "$WORK/gate-1.log" && grep -q "input line is not empty" "$WORK/gate-1.log"'
check "no client, a half-typed line: nothing was typed into the pane" '[ "$(notices qa "Beads update for qa")" = "$BEFORE" ]'
check "no client, a half-typed line: the text is still on the input line, unsubmitted" 'cursor_row "$PANE" | grep -qF "$HALF"'
check "no client, a half-typed line: the notice is parked, waiting for the pane" '[ -d "$(pending_dir qa)" ]'
submit "$PANE"
sleep 4
check "no client: the human's own line went off whole, with no notice glued to it" 'teamctl capture qa --all | grep -qF "$HALF" && ! teamctl capture qa --all | grep -q "${HALF}.wolfmux"'
check "no client: the parked notice follows once the line is gone, and the marker clears" 'teamctl capture qa --all | grep -q "Beads update for qa (gate-1)" && [ ! -d "$(pending_dir qa)" ]'

echo "== copy mode defers whether or not anybody is attached"
tmx copy-mode -t "$PANE"
sleep 0.5
teamctl nudge qa --id copy-1 >"$WORK/copy-1.log" 2>&1
COPY_STATUS=$?
check "copy mode, no client: deferred, never typed, and the reason names copy mode" '[ "$COPY_STATUS" -eq 3 ] && grep -q "copy mode" "$WORK/copy-1.log" && ! teamctl capture qa --all | grep -q "copy-1"'
tmx send-keys -t "$PANE" -X cancel
sleep 3
check "copy mode: leaving it lets the waiting notice through, naming its bead" 'teamctl capture qa --all | grep -q "Beads update for qa (copy-1)"'
submit "$PANE"
sleep 0.5

echo "== a marker whose waiter died is reaped, not left to swallow nudges (BLOCKER 1)"
/bin/mkdir -p "$(pending_dir qa)"
echo $(($(date +%s) - 900)) >"$(pending_dir qa)/ts"
echo $(($(date +%s) - 900)) >"$(pending_dir qa)/beat"
echo "ghost-bead" >"$(pending_dir qa)/bead"
check "stale marker: it is there, with no waiter behind it" '[ -d "$(pending_dir qa)" ] && [ -f "$(pending_dir qa)/bead" ]'
teamctl nudge qa --id reap-1 >"$WORK/reap-1.log" 2>&1
REAP_STATUS=$?
sleep 1
check "stale marker: the next nudge reaps it and is delivered, instead of being swallowed" '[ "$REAP_STATUS" -eq 0 ] && teamctl capture qa --all | grep -q "Beads update for qa (reap-1)"'
check "stale marker: the dead waiter's marker is gone, and its bead was never typed" '[ ! -d "$(pending_dir qa)" ] && ! teamctl capture qa --all | grep -q "ghost-bead"'
check "stale marker: the event log says it was reaped" 'grep -q "nudge-defer-reaped" "$STATE_DIR/events.jsonl"'
submit "$PANE"
sleep 0.5

echo "== a human attached: one delivered notice, measured, as the baseline for counting"
attach_client
tmx select-window -t "$WINDOW" >/dev/null 2>&1
tmx select-pane -t "$LEAD_PANE" >/dev/null 2>&1 # the human is looking at the LEAD pane
sleep 4                                         # longer than WOLFMUX_NUDGE_HUMAN_IDLE: no keystroke is recent
check "setup: a client is attached now" '[ "$(clients)" = "1" ]'
BEFORE="$(notices qa "Beads update for qa")"
teamctl nudge qa --id base-1 >"$WORK/base-1.log" 2>&1
BASE_STATUS=$?
sleep 1
AFTER="$(notices qa "Beads update for qa")"
PER_LINE=$((AFTER - BEFORE))
# A `cat` pane shows one delivered line twice: the tty echoes what was typed and the
# stub prints it back. Measure that here, then count every later case against it.
check "baseline: an idle pane with a human attached elsewhere is notified at once" '[ "$BASE_STATUS" -eq 0 ] && [ "$PER_LINE" -ge 1 ] && grep -q "notified: qa" "$WORK/base-1.log"'

echo "== the input line already holds something, with a human attached"
type_text "$PANE" "$HALF2"
sleep 0.5
BEFORE="$(notices qa "Beads update for qa")"
teamctl nudge qa --id half-1 >"$WORK/defer-1.log" 2>&1
DEFER_STATUS=$?
check "busy input line: deferred (exit 3), and the reason names the input line" '[ "$DEFER_STATUS" -eq 3 ] && grep -q "deferred" "$WORK/defer-1.log" && grep -q "input line is not empty" "$WORK/defer-1.log"'
check "busy input line: nothing new was typed into the pane" '[ "$(notices qa "Beads update for qa")" = "$BEFORE" ]'
check "busy input line: the half-typed text is still on the input line, unsubmitted" 'cursor_row "$PANE" | grep -qF "$HALF2"'
check "busy input line: a notice is parked, waiting for the pane" '[ -d "$(pending_dir qa)" ]'

echo "== several nudges while the pane is busy collapse into one notice"
teamctl nudge qa --id half-2 >/dev/null 2>&1
teamctl nudge qa --id half-3 >/dev/null 2>&1
check "collapse: still exactly one waiter for the role" '[ "$(/bin/ls -d "$(pending_dir qa)" 2>/dev/null | wc -l | tr -d " ")" = "1" ]'
check "collapse: still nothing typed while the pane is busy" '[ "$(notices qa "Beads update for qa")" = "$BEFORE" ]'
submit "$PANE"
sleep 4
check "collapse: the human's own line was submitted whole, with no notice glued to it" 'teamctl capture qa --all | grep -qF "$HALF2" && ! teamctl capture qa --all | grep -q "${HALF2}.wolfmux"'
AFTER="$(notices qa "Beads update for qa")"
check "collapse: exactly ONE notice arrived for three nudges, not one per nudge" '[ $((AFTER - BEFORE)) -eq "$PER_LINE" ]'
check "collapse: three bead ids became the generic line, which names the whole inbox" '! teamctl capture qa --all | grep -qE "half-(1|2|3)" && teamctl capture qa --all | grep -q "Beads update for qa\. Run: bd list"'
check "collapse: the marker is gone once the notice has been delivered" '[ ! -d "$(pending_dir qa)" ]'

echo "== the human looking at a worker's pane: under the default policy it is never typed into (v1.20.0)"
detach_client
attach_client # a fresh client: tmux counts the attach as input from it
tmx select-window -t "$WINDOW" >/dev/null 2>&1
tmx select-pane -t "$PANE" >/dev/null 2>&1 # now the human is looking at qa
BEFORE="$(notices qa "Beads update for qa")"
teamctl nudge qa --id watched-qa-1 >"$WORK/watched-qa-1.log" 2>&1
WATCHED_QA_STATUS=$?
sleep 6 # longer than WOLFMUX_NUDGE_HUMAN_IDLE: quiet makes no difference to this rule
check "human-pane-typing off: the pane on the human's screen is filed for, not typed into (exit 4)" '[ "$WATCHED_QA_STATUS" -eq 4 ] && grep -q "^filed: a human is watching qa" "$WORK/watched-qa-1.log" && [ "$(notices qa "Beads update for qa")" = "$BEFORE" ] && [ ! -d "$(pending_dir qa)" ]'

# From here to the "giving up" block the v1.16.1 rule is asserted as it was: it is still
# there, as policy human-pane-typing idle.
export WOLFMUX_HUMAN_PANE_TYPING=idle
echo "== under policy idle: a human at the keyboard, with an empty input line"
detach_client
attach_client # a fresh client: tmux counts the attach as input from it
tmx select-window -t "$WINDOW" >/dev/null 2>&1
tmx select-pane -t "$PANE" >/dev/null 2>&1 # now the human is looking at qa
BEFORE="$(notices qa "Beads update for qa")"
teamctl nudge qa --id human-1 >"$WORK/human-1.log" 2>&1
HUMAN_STATUS=$?
check "human at the keyboard: an empty input line is still not typed into (exit 3)" '[ "$HUMAN_STATUS" -eq 3 ] && grep -q "keystroke" "$WORK/human-1.log" && ! teamctl capture qa --all | grep -q "human-1"'
sleep 6 # no keystroke for longer than WOLFMUX_NUDGE_HUMAN_IDLE
check "human at the keyboard: once they stop touching the keyboard, the notice arrives" 'teamctl capture qa --all | grep -q "Beads update for qa (human-1)"'
check "human at the keyboard: one notice, not one per look" '[ $(($(notices qa "Beads update for qa") - BEFORE)) -eq "$PER_LINE" ]'
tmx select-pane -t "$LEAD_PANE" >/dev/null 2>&1
sleep 4

# From v1.15.0 the LEAD's pane is typed into only while no client is attached to the
# team (WOLFMUX_NUDGE_TYPE=detached-lead; see tests/inbox.sh for that rule itself). The
# two blocks below drive a lead pane on purpose — queued fixed notices arriving in order
# and exactly once, and a human typing part-way through a five-notice delivery — and
# those properties are exactly as important as they were. So they run with the client
# detached, which is still a typed path, rather than being deleted or thinned.
detach_client
sleep 1
check "setup: no client attached, so the lead pane is a typed path again (v1.15.0)" '[ "$(clients)" = "0" ]'

echo "== queued fixed notices: in order, exactly once, re-checking before every line (BLOCKER 3)"
LBEFORE="$(notices lead "Policy changed")"
teamctl policy worker-spawn on >/dev/null 2>&1
sleep 2
LAFTER="$(notices lead "Policy changed")"
PER_LEAD=$((LAFTER - LBEFORE))
check "queued notices: one policy notice on an idle lead pane is the per-line baseline" '[ "$PER_LEAD" -ge 1 ] && teamctl capture lead --all | grep -q "Policy changed: worker-spawn = on"'
type_text "$LEAD_PANE" "$HALF2"
sleep 0.5
LBEFORE="$(notices lead "Policy changed")"
teamctl policy worker-isolation off >/dev/null 2>&1
teamctl policy lead-teams off >/dev/null 2>&1
teamctl policy worker-permissions ask >/dev/null 2>&1
check "queued notices: nothing was typed into the busy lead pane" '[ "$(notices lead "Policy changed")" = "$LBEFORE" ]'
check "queued notices: all three are queued behind one waiter" '[ -d "$(pending_dir lead)" ] && [ "$(wc -l <"$(pending_dir lead)/lines" | tr -d " ")" = "3" ]'
check "queued notices: the lead's half-typed line is untouched" 'cursor_row "$LEAD_PANE" | grep -qF "$HALF2"'
submit "$LEAD_PANE"
sleep 6
check "queued notices: all three arrived" 'teamctl capture lead --all | grep -q "worker-isolation = off" && teamctl capture lead --all | grep -q "lead-teams = off" && teamctl capture lead --all | grep -q "worker-permissions = ask"'
check "queued notices: in the order they happened" '[ "$(teamctl capture lead --all | grep -o "Policy changed: [a-z-]* = [a-z]*" | awk "!seen[\$0]++" | grep -c .)" -ge 4 ] && [ "$(teamctl capture lead --all | grep -o "Policy changed: [a-z-]* = [a-z]*" | awk "!seen[\$0]++" | tail -3 | tr "\n" "|")" = "Policy changed: worker-isolation = off|Policy changed: lead-teams = off|Policy changed: worker-permissions = ask|" ]'
check "queued notices: each arrived exactly once (three lines, no re-sends)" '[ $(($(notices lead "Policy changed") - LBEFORE)) -eq $((PER_LEAD * 3)) ]'
check "queued notices: nothing is glued onto any of them" '! teamctl capture lead --all | grep -q "teamctl policy${HALF2:0:4}" && ! teamctl capture lead --all | grep -q "${HALF2}.wolfmux"'
check "queued notices: the marker and its lines file are gone" '[ ! -d "$(pending_dir lead)" ]'

echo "== a human who starts typing part-way through a queued delivery (BLOCKER 3)"
# The pane is asked again before every line, and each line leaves the marker as it is
# typed. So a delivery that stops part-way keeps the rest for later and can never
# re-send what already went out. In practice this case also exercises the partial stop
# (nudge-defer-partial); what is asserted here is the part that holds whatever the
# timing does: nothing is ever delivered twice, and nothing is lost.
type_text "$LEAD_PANE" "$HALF2"
sleep 0.5
LBEFORE="$(notices lead "Policy changed")"
for pair in "worker-isolation on" "lead-teams on" "worker-permissions skip" "lead-permissions skip" "worker-spawn off"; do
  # shellcheck disable=SC2086
  teamctl policy $pair >/dev/null 2>&1
done
check "mid-delivery: all five are queued, nothing typed yet" '[ "$(wc -l <"$(pending_dir lead)/lines" | tr -d " ")" = "5" ] && [ "$(notices lead "Policy changed")" = "$LBEFORE" ]'
# a watcher that keeps typing from the moment the first notice lands, like a person
# reacting to it. send-keys does not move client_activity, so only check (b) can fire.
(
  while :; do
    if tmx capture-pane -p -J -t "$LEAD_PANE" -S -40 2>/dev/null | grep -q "worker-isolation = on"; then
      for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        tmx send-keys -t "$LEAD_PANE" -l 'TYPING'
        perl -e 'select(undef,undef,undef,0.2)'
      done
      exit 0
    fi
    perl -e 'select(undef,undef,undef,0.02)'
  done
) >/dev/null 2>&1 &
WATCHER=$!
disown "$WATCHER" 2>/dev/null || true
submit "$LEAD_PANE" # the pane goes idle and delivery starts
sleep 6
kill "$WATCHER" 2>/dev/null
submit "$LEAD_PANE" # clear whatever the watcher left on the input line
sleep 10            # the waiter finds it idle again and finishes the queue
check "mid-delivery: no notice was ever delivered twice" 'for k in "worker-isolation = on" "lead-teams = on" "worker-permissions = skip" "lead-permissions = skip" "worker-spawn = off"; do [ "$(notices lead "$k")" -le "$PER_LEAD" ] || exit 1; done'
check "mid-delivery: every queued notice still arrived, none was lost on the way" 'for k in "worker-isolation = on" "lead-teams = on" "worker-permissions = skip" "lead-permissions = skip" "worker-spawn = off"; do [ "$(notices lead "$k")" -eq "$PER_LEAD" ] || exit 1; done'
check "mid-delivery: the marker is empty at the end" '[ ! -d "$(pending_dir lead)" ]'

echo "== the new rule itself: the lead pane is typed into only while it is QUIET"
# Issue #12, and the three episodes below are the whole rule. v1.15.0 answered "a client
# is attached" with filing only, and a filed notice reaches the agent through its Stop
# hook, which fires on a TURN BOUNDARY. An agent that is already IDLE has no further
# boundary, so the notice was never handed over at all. So: a client attached and the
# lead's pane quiet delivers; a half-typed line in it does not; a human sitting in it
# who has just pressed a key does not either.
attach_client
tmx select-window -t "$WINDOW" >/dev/null 2>&1
tmx select-pane -t "$LEAD_PANE" >/dev/null 2>&1 # the human is looking at the LEAD pane
sleep 4                                         # longer than WOLFMUX_NUDGE_LEAD_IDLE
LBEFORE="$(notices lead "Beads update for lead")"
teamctl nudge lead --id idle-1 >"$WORK/idle-1.log" 2>&1
IDLE_LEAD_STATUS=$?
sleep 2
check "a client attached + an IDLE lead pane + a bead: it IS typed, with no human keystroke" '[ "$IDLE_LEAD_STATUS" -eq 0 ] && grep -q "notified: lead" "$WORK/idle-1.log" && teamctl capture lead --all | grep -q "Beads update for lead (idle-1)"'
check "a client attached + an idle lead pane: the event log says the pane was quiet, not that it was filed" 'grep -q "a client is attached; the pane was quiet" "$STATE_DIR/events.jsonl"'

# The negative twin, so the fix cannot be "type always": a half-typed line in the
# human's own pane. Nothing is glued onto it, however idle the agent is, and the notice
# still arrives once that line is gone.
type_text "$LEAD_PANE" "$HALF2"
sleep 0.5
LPARKED="$(notices lead "Beads update for lead")"
teamctl nudge lead --id parked-1 >"$WORK/parked-1.log" 2>&1
PARKED_STATUS=$?
sleep 2
check "a client attached + a half-typed line in the lead pane: nothing typed, the notice is parked" '[ "$PARKED_STATUS" -eq 3 ] && grep -q "^deferred:" "$WORK/parked-1.log" && [ -d "$(pending_dir lead)" ] && [ "$(notices lead "Beads update for lead")" = "$LPARKED" ]'
check "a client attached + a half-typed line: the human's own text is untouched" 'cursor_row "$LEAD_PANE" | grep -qF "$HALF2"'
submit "$LEAD_PANE" # the line goes, the pane is quiet again
sleep 6
check "a client attached + the pane then goes quiet: the parked notice arrives by itself" 'teamctl capture lead --all | grep -q "Beads update for lead (parked-1)" && [ ! -d "$(pending_dir lead)" ]'

# And the requirement that is in tension with the first episode: "i dont want to keep
# seeing these updates in the mid of my convos". A human AT the lead pane who pressed a
# key inside WOLFMUX_NUDGE_LEAD_IDLE holds the notice back, so a pause for thought
# mid-conversation is never typed over. The window is measured against this client's
# real #{client_activity} rather than a faked keystroke: send-keys does not move it, so
# a test cannot type as the human — it widens the window past the client's real idle
# time instead, which is the same comparison the code makes.
CLIENT_ACT="$(tmx list-clients -t "$SESSION" -F '#{client_activity}' 2>/dev/null | head -1)"
WIDE=$(($(date +%s) - CLIENT_ACT + 120))
tmx select-pane -t "$LEAD_PANE" >/dev/null 2>&1
LWATCHED="$(notices lead "Beads update for lead")"
WOLFMUX_NUDGE_LEAD_IDLE="$WIDE" teamctl nudge lead --id watched-1 >"$WORK/watched-1.log" 2>&1
WATCHED_STATUS=$?
sleep 2
check "a client attached + the human AT the lead pane inside WOLFMUX_NUDGE_LEAD_IDLE: nothing is typed" '[ "$WATCHED_STATUS" -eq 3 ] && grep -q "keystroke" "$WORK/watched-1.log" && [ "$(notices lead "Beads update for lead")" = "$LWATCHED" ] && ! teamctl capture lead --all | grep -q "watched-1"'
check "a client attached + the human at the lead pane: it waits in the marker, which carries the wide window" '[ -d "$(pending_dir lead)" ] && [ "$(cat "$(pending_dir lead)/idle" 2>/dev/null)" = "$WIDE" ]'
# That waiter would sit out its cap against a window no later check wants: take the
# marker away, and it stops at its next look (nudge_pending_exists).
/bin/rm -rf "$(pending_dir lead)"
detach_client
sleep 1
teamctl nudge lead --id unwatched-1 >"$WORK/unwatched-1.log" 2>&1
UNWATCHED_STATUS=$?
sleep 2
check "no client attached + the same idle lead + a bead: it IS typed, exactly as before" '[ "$UNWATCHED_STATUS" -eq 0 ] && grep -q "notified: lead" "$WORK/unwatched-1.log" && teamctl capture lead --all | grep -q "Beads update for lead (unwatched-1)"'
unset WOLFMUX_HUMAN_PANE_TYPING # the v1.16.1 region ends; nothing below has a client watching

echo "== giving up: a pane that never goes idle"
type_text "$PANE" "$HALF2"
sleep 0.5
BEFORE="$(notices qa "Beads update for qa")"
WOLFMUX_NUDGE_DEFER_MAX=2 teamctl nudge qa --id expire-1 >"$WORK/expire-1.log" 2>&1
EXPIRE_STATUS=$?
check "expiry: deferred first, and the message says it gives up after 2s" '[ "$EXPIRE_STATUS" -eq 3 ] && grep -q "2s" "$WORK/expire-1.log"'
sleep 6
check "expiry: the marker is cleaned up" '[ ! -d "$(pending_dir qa)" ]'
check "expiry: nothing was ever typed into the busy pane" '[ "$(notices qa "Beads update for qa")" = "$BEFORE" ] && ! teamctl capture qa --all | grep -q "expire-1"'
check "expiry: the half-typed text is untouched, and the event log says why it gave up" 'cursor_row "$PANE" | grep -qF "$HALF2" && grep -q "nudge-defer-expired" "$STATE_DIR/events.jsonl"'

echo "== the switch that brings the old behaviour back"
WOLFMUX_NUDGE_COLLISION_CHECK=0 teamctl nudge qa --id blind-1 >/dev/null 2>&1
BLIND_STATUS=$?
sleep 1
check "WOLFMUX_NUDGE_COLLISION_CHECK=0: types blind again, for whoever needs the old behaviour" '[ "$BLIND_STATUS" -eq 0 ] && teamctl capture qa --all | grep -q "blind-1"'
detach_client
submit "$PANE"

echo "== the checks themselves"
# shellcheck disable=SC1090
(
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  # plain rows, no escape data: the fallback path
  tm_input_line_dirty "" && exit 1
  tm_input_line_dirty "   " && exit 1
  tm_input_line_dirty "> " && exit 1
  tm_input_line_dirty "│ >                                        │" && exit 1
  tm_input_line_dirty "╭──────────────────────────────────────────╮" && exit 1
  tm_input_line_dirty "│ > half typed                             │" || exit 1
  tm_input_line_dirty "i said install bun if requir" || exit 1
  tm_input_line_dirty "❯ ls -la" || exit 1
  # rows as capture-pane -e really hands them over. These three are verbatim from the
  # live wolfmux socket, 2026-10-09: the dim text is a TUI placeholder, not typing, and
  # Claude Code writes a NON-BREAKING space after its ❯.
  tm_input_line_dirty "$(printf '\033[38;5;246m\342\235\257\302\240\033[39m     ')" && exit 1
  tm_input_line_dirty "$(printf '\342\235\257\302\240\033[2mclose sprint 7, sprint 8 oct 9 to 15\033[0m  ')" && exit 1
  tm_input_line_dirty "$(printf '\342\235\257\302\240        ')" && exit 1
  tm_input_line_dirty "$(printf '\342\235\257 \033[2mSilence - the lead reviews next, not the user.\033[0m')" && exit 1
  tm_input_line_dirty "$(printf '\342\235\257 \033[2mTry "edit a file"\033[22m')" && exit 1
  # a human's own typing is NOT dim, even next to a dim hint
  tm_input_line_dirty "$(printf '\342\235\257\302\240\033[2mhint\033[0m real typing')" || exit 1
  tm_input_line_dirty "$(printf '\342\235\257\302\240i said install bun if requir')" || exit 1
  exit 0
) >/dev/null 2>&1
DIRTY_STATUS=$?
check "input line: an empty prompt, a bare box and a dim placeholder are clean; typing is not" '[ "$DIRTY_STATUS" -eq 0 ]'
(
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  # "nobody is attached" and "the read failed" are different answers: the first only
  # rules out the keystroke check, the second has to be read as busy.
  tm_client_idle "$SESSION" >/dev/null
  [ "$?" -eq 1 ] || exit 1
  tm_client_idle "no-such-session-$$" >/dev/null
  [ "$?" -eq 2 ] || exit 1
  exit 0
) >/dev/null 2>&1
IDLE_STATUS=$?
check "client list: no client returns 1, a failed read returns 2, so a broken read reads busy" '[ "$IDLE_STATUS" -eq 0 ]'
(
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  [ "$WOLFMUX_NUDGE_RETRY" = "1" ] || exit 1
  WOLFMUX_NUDGE_RETRY=0
  . "$WOLFMUX_HOME/lib/agents.sh"
  [ "$WOLFMUX_NUDGE_RETRY" -ge 1 ] || exit 1
  WOLFMUX_NUDGE_RETRY=junk
  . "$WOLFMUX_HOME/lib/agents.sh"
  [ "$WOLFMUX_NUDGE_RETRY" = "3" ] || exit 1
  exit 0
) >/dev/null 2>&1
RETRY_STATUS=$?
check "WOLFMUX_NUDGE_RETRY: 0 and nonsense are floored, so a waiter can never spin for ever" '[ "$RETRY_STATUS" -eq 0 ]'

teamctl destroy --worktrees --yes >/dev/null 2>&1

echo
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
