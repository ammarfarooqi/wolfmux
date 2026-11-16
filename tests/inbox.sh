#!/bin/bash
# inbox.sh — nothing is ever typed into the human's conversation, and the agent still
# learns about the bead.
#
# The bug this guards (issue #11): every `[wolfmux] Beads update for <role> …` line was
# typed into the LEAD's pane, which is the pane the human talks to the lead in, so a
# notice landed in the middle of whatever he was saying. v1.14.0 stopped notices landing
# in a half-typed LINE; this is the complaint underneath that one — a notice typed in
# perfectly is still an interruption.
#
# What has to hold, and each of these is a check below:
#   · v1.20.0, the default (policy human-pane-typing off): a client is attached -> the
#     lead pane is NEVER typed into, quiet or not; it is filed for the agent's own hooks.
#     A worker pane the human is looking at is not typed into either; other workers are.
#     A notice parked for a pane waits while the human watches it. tmux errors -> not typed
#   · under human-pane-typing idle, the v1.16.1 rule, asserted as it always was:
#   · a client is attached and a human is WORKING in the lead pane -> nothing is typed
#     into it; the notice waits in the marker and arrives once that pane is quiet
#   · a client is attached and the lead pane is QUIET -> it IS typed (issue #12: a
#     filed notice reaches an agent through its Stop hook, and an agent that is already
#     idle has no turn boundary left, so filing alone never reached it)
#   · no client attached -> it IS typed, exactly as v1.14.0 did it, under either policy
#   · the Stop hook blocks once and only once, and cannot loop
#   · the badge is empty at zero, and never fails however broken its input is
#   · `teamctl inbox` clears new-ness but not delivered-ness; the agent's hook clears
#     delivered-ness but not new-ness. The two are independent, in both directions
#   · a notice survives a waiter that died: the typed path lost it, the file did not
#   · the stall notification is raised once per burst and carries the count
#
# Fully isolated from any team you have running: its own tmux server (socket
# wolfmux-test-inbox-<pid>), its own state directory, a throwaway git repository and stub
# agents. It never touches the live "wolfmux" socket or a real role. The attached client
# is a pty of its own (script(1)), and the window size is pinned so that client cannot
# reflow the panes. The desktop notification is caught in a file through the
# WOLFMUX_NOTIFY_TTY seam, so nothing reaches your screen.
#
#   tests/inbox.sh
# No pipefail: checks end in `grep -q`, which closes the pipe early by design.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-inbox.XXXXXX")"
export WOLFMUX_HOME="$REPO/config/wolfmux"
# v1.24.0: a new project gets the native store (lib/store.sh). This suite models a Beads project
# (bd is a fake on PATH), which is what it was written for, so it says so.
export WOLFMUX_STORE=beads
export WOLFMUX_BIN_DIR="$REPO/bin"
export WOLFMUX_DATA="$WORK/data"
export WOLFMUX_TMUX_SOCKET="wolfmux-test-inbox-$$"
export WOLFMUX_LAUNCHER_FABLE="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_FLASH="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_GLM53="$REPO/tests/stub-agent"
export WOLFMUX_NUDGE_RETRY=1
export WOLFMUX_NUDGE_HUMAN_IDLE=3
export WOLFMUX_NUDGE_LEAD_IDLE=3 # 300 in real use; the lead's pane asks for more quiet
export WOLFMUX_NUDGE_DEFER_MAX=60
export WOLFMUX_NUDGE_DEBOUNCE=0
# The desktop notification goes into a file instead of onto a screen, and the two
# fallbacks behind it are pointed at nothing so they cannot fire either.
export WOLFMUX_NOTIFY_TTY="$WORK/notifications"
export WOLFMUX_NOTIFIER_APP="$WORK/no-such.app"
export WOLFMUX_OSASCRIPT="$WORK/no-such-osascript"
: >"$WOLFMUX_NOTIFY_TTY"
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR WOLFMUX_NOTIFY WOLFMUX_SPLASH TMUX TMUX_PANE
unset WOLFMUX_TEAM WOLFMUX_TEAM_ARG WOLFMUX_SESSION WOLFMUX_WORKTREE WOLFMUX_BRANCH WOLFMUX_MODEL
unset WOLFMUX_NUDGE_TYPE WOLFMUX_INBOX_CLIENTS WOLFMUX_INBOX_STALL_NOTIFY WOLFMUX_HUMAN_PANE_TYPING WOLFMUX_INBOX_WATCHED
unset WOLFMUX_INBOX_APPROVAL_TYPE WOLFMUX_INBOX_STOP_COOLDOWN WOLFMUX_INBOX_MARK
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
RENDER_PID=""
cleanup() {
  [ -z "$ATTACH_PID" ] || kill "$ATTACH_PID" 2>/dev/null
  [ -z "$RENDER_PID" ] || kill "$RENDER_PID" 2>/dev/null
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
git -c user.name=inbox -c user.email=inbox@example.invalid commit -qm "initial commit"

teamctl start fable --no-attach --skip-beads >/dev/null 2>&1
teamctl spawn qa flash --no-kickoff >/dev/null 2>&1
sleep 2
SESSION="$(teamctl status --json | jq -r .session)"
LEAD_PANE="$(teamctl status --json | jq -r '.agents[] | select(.role == "lead") | .pane')"
PANE="$(teamctl status --json | jq -r '.agents[] | select(.role == "qa") | .pane')"
[ -n "$LEAD_PANE" ] && [ "$LEAD_PANE" != "null" ] && [ -n "$PANE" ] || {
  echo "setup failed: no panes"
  exit 1
}
WINDOW="$(tmx display-message -p -t "$LEAD_PANE" '#{window_id}')"
tmx set-option -t "$SESSION" window-size manual >/dev/null 2>&1
tmx resize-window -t "$WINDOW" -x 200 -y 50 >/dev/null 2>&1
STATE_DIR="$(ls -d "$WOLFMUX_DATA"/state/*/ 2>/dev/null | head -1)"
STATE_DIR="${STATE_DIR%/}"
INBOX="$STATE_DIR/inbox"

inbox_file() { printf '%s\n' "$INBOX/$1"; }
pending_dir() { printf '%s\n' "$STATE_DIR/nudge/$1.pending"; }
notices() { teamctl capture "$1" --all 2>/dev/null | grep -c "$2"; }
clients() { tmx list-clients -t "$SESSION" -F x 2>/dev/null | wc -l | tr -d ' '; }
badge() { teamctl _inbox-badge "$SESSION" 2>&1; }
# Since v1.20.0 the badge counts the HUMAN's unread Beads messages, not these notices
# (the human-messages section below). The checks about a notice's new-ness count it the
# way the badge used to: every role's new notices, through teamctl inbox's own reader.
notices_new() { teamctl inbox --all --json --keep 2>/dev/null | jq '[.[] | select(.new)] | length'; }
# notify_deliver writes OSC 9 with no newline, so several banners land on one line:
# count the OCCURRENCES, not the lines. "1 notice waiting" is singular on purpose.
banners() { grep -o 'notices\{0,1\} waiting' "$WOLFMUX_NOTIFY_TTY" 2>/dev/null | wc -l | tr -d ' '; }
# state_of <role> <line-number> — the two-letter state column of one line
state_of() { awk -F'\t' -v n="$2" 'NR == n { print $3 }' "$(inbox_file "$1")" 2>/dev/null; }
# inbox_count_new_of <role> — notices this ONE role has that the human has not expanded
# (the badge itself counts the whole team, which is what the human wants to see)
inbox_count_new_of() { awk -F'\t' 'NF >= 4 && substr($3, 1, 1) == "n" { n++ } END { print n + 0 }' "$(inbox_file "$1")" 2>/dev/null; }
# A hook runs with the agent's own environment, in the agent's own directory, IN the agent's
# own pane: tmux put TMUX and TMUX_PANE into the pane's processes, Claude Code hands its
# environment to hooks, and the pane's process is one of the hook's ancestors. That last part
# is the pane proof (lib/common.sh identity_in_own_pane). Here the stub agent is not the hook's
# parent, so tests/fake-ps grafts this test shell under the pane's process.
pane_of_role() { tmx list-panes -s -t "$SESSION" -F '#{@ai_role} #{pane_id}' 2>/dev/null | awk -v r="$1" '$1 == r { print $2; exit }'; }
hook() { # <role> <_inbox-stop|_inbox-prompt>
  hook_in "$(pane_of_role "$1")" "$1" "$2"
}
# hook_in <pane> <role> <hook> — the hook as the agent IN that pane runs it. The fixture itself
# asks the real tmux, so a check that breaks tmux on PATH breaks only the hook's own reads.
REAL_TMUX="$(command -v tmux)"
hook_in() {
  local pid socket
  pid="$("$REAL_TMUX" -L "$WOLFMUX_TMUX_SOCKET" display-message -p -t "$1" '#{pane_pid}' 2>/dev/null)"
  socket="$("$REAL_TMUX" -L "$WOLFMUX_TMUX_SOCKET" display-message -p -t "$1" '#{socket_path}' 2>/dev/null)"
  (cd "$PROJECT" && TMUX="$socket,0,0" TMUX_PANE="$1" \
    WOLFMUX_PS_BIN="$REPO/tests/fake-ps" WOLFMUX_FAKE_PS_GRAFT="$$:$pid" \
    TEAM_ROLE="$2" WOLFMUX_TEAM=default teamctl "$3" </dev/null 2>/dev/null)
}
# hook_bare <role> <hook> — the same hook with the agent's environment and no pane at all: a
# background chat of Claude's daemon that inherited it (2026-10-19). It must be given nothing.
hook_bare() {
  (cd "$PROJECT" && TEAM_ROLE="$1" WOLFMUX_TEAM=default BEADS_ACTOR="$1" teamctl "$2" </dev/null 2>/dev/null)
}
# delivered_of <role> <text> <true|false> — has the agent been given the notice naming text?
delivered_of() {
  teamctl inbox "$1" --keep --json | jq -e --arg t "$2" --argjson want "$3" '[.[] | select(.text | contains($t)) | .delivered] == [$want]' >/dev/null
}
# stop_continues <answer> — the Stop hook's answer that keeps the turn going (v1.22.1): the
# notices in hookSpecificOutput.additionalContext, which Claude Code shows as "Stop hook
# feedback", and no decision or reason key, which it would show as "Stop hook error"
stop_continues() {
  printf '%s' "$1" | jq -e '.hookSpecificOutput.hookEventName == "Stop" and (.hookSpecificOutput.additionalContext | type) == "string" and (has("decision") | not) and (has("reason") | not)' >/dev/null
}
# stop_body — what the agent is given, read from that answer on stdin
stop_body() { jq -r '.hookSpecificOutput.additionalContext'; }
attach_client() {
  script -q /dev/null tmux -L "$WOLFMUX_TMUX_SOCKET" attach -t "$SESSION" >/dev/null 2>&1 &
  ATTACH_PID=$!
  disown "$ATTACH_PID" 2>/dev/null || true
  sleep 1
}
detach_client() {
  [ -z "$ATTACH_PID" ] || kill "$ATTACH_PID" 2>/dev/null
  ATTACH_PID=""
  sleep 1
}

echo "== the agent's settings file carries both hooks, and keeps the notification one"
SETTINGS="$STATE_DIR/settings/lead.json"
check "settings: the lead's Stop array has FOUR entries, the notification hook, the inbox hook, the turn hook (v1.24.0) and the wake waiter" '[ "$(jq ".hooks.Stop | length" "$SETTINGS")" = "4" ] && jq -e ".hooks.Stop[].hooks[].command | select(test(\"_notify$\"))" "$SETTINGS" && jq -e ".hooks.Stop[].hooks[].command | select(test(\"_inbox-stop\"))" "$SETTINGS"'
# v1.23.0: the wake waiter, the lead's only, on Stop and SessionStart: asyncRewake, the 7-day
# timeout, its own summary line, and the command EXECs teamctl so no shell sits in between
WAKE_HOOK_JQ='[.hooks.Stop[].hooks[], .hooks.SessionStart[].hooks[]] | map(select(.command | test("_inbox-wake$"))) | length == 2 and all(.asyncRewake == true and .timeout == 604800 and .rewakeSummary == "wolfmux: team notice" and (.command | startswith("exec \"")))'
check "settings: the lead's wake waiter is on Stop and SessionStart, asyncRewake, timeout 604800, its summary, exec'd" 'jq -e "$WAKE_HOOK_JQ" "$SETTINGS"'
check "settings: a worker's file has no wake waiter, and its Stop array keeps three entries (v1.24.0: the turn hook)" '! grep -q "_inbox-wake" "$STATE_DIR/settings/qa.json" && [ "$(jq ".hooks.Stop | length" "$STATE_DIR/settings/qa.json")" = "3" ] && [ "$(jq ".hooks.SessionStart // [] | length" "$STATE_DIR/settings/qa.json")" = "1" ]'
check "settings: UserPromptSubmit runs the inbox hook" 'jq -e ".hooks.UserPromptSubmit[0].hooks[0].command | test(\"_inbox-prompt\")" "$SETTINGS"'
check "settings: nothing of this went into your own ~/.claude/settings.json" '[ ! -e "$WORK/.claude" ]'

echo "== the badge is empty at zero, and never fails whatever it is handed"
check "badge: no notices at all -> prints nothing, exits 0" '[ -z "$(badge)" ] && teamctl _inbox-badge "$SESSION" >/dev/null 2>&1'
check "badge: no session name -> prints nothing, exits 0" '[ -z "$(teamctl _inbox-badge 2>&1)" ] && teamctl _inbox-badge >/dev/null 2>&1'
check "badge: a session that does not exist -> prints nothing, exits 0" '[ -z "$(teamctl _inbox-badge "no-such-session-$$" 2>&1)" ] && teamctl _inbox-badge "no-such-session-$$" >/dev/null 2>&1'
check "badge: a root that is not a directory -> prints nothing, exits 0" '[ -z "$(teamctl _inbox-badge "$SESSION" /no/such/root default 2>&1)" ]'
check "badge: an invalid team name -> prints nothing, exits 0" '[ -z "$(teamctl _inbox-badge "$SESSION" "$PROJECT" "../escape" 2>&1)" ]'
/bin/mkdir -p "$INBOX"
printf 'junk with no tabs at all\n\n\t\t\n' >"$(inbox_file lead)"
check "badge: a damaged inbox file -> prints nothing, exits 0" '[ -z "$(badge)" ] && teamctl _inbox-badge "$SESSION" >/dev/null 2>&1'
/bin/rm -f "$(inbox_file lead)"

echo "== v1.20.0: the number is the human's unread Beads messages, and it opens them"
# Never the live Beads store. The hook is run the way bd runs it (the bead id and the event
# as arguments, the bead's JSON on stdin, in the caller's directory), with JSON shaped as bd
# 1.3.0 sends it (measured on a scratch store, 2026-10-15), and bd itself is a fake on PATH
# that records every call: "<BEADS_ACTOR>|<arguments>".
US="$(printf '\037')"
HUMAN_INDEX="$STATE_DIR/human-inbox" # the default team: its state IS the project's
FAKE_BIN="$WORK/fake-bin"
BD_LOG="$WORK/bd-calls"
BD_LIST="$WORK/bd-list.json"
/bin/mkdir -p "$FAKE_BIN"
printf '%s\n' '#!/bin/bash' 'printf "%s|%s\n" "${BEADS_ACTOR:-}" "$*" >>"$FAKE_BD_LOG"' \
  'case "$1" in list) /bin/cat "$FAKE_BD_LIST" ;; show) echo "SHOW $2" ;; esac' >"$FAKE_BIN/bd"
chmod +x "$FAKE_BIN/bd"
fake_bd() { (cd "$PROJECT" && PATH="$FAKE_BIN:$PATH" FAKE_BD_LOG="$BD_LOG" FAKE_BD_LIST="$BD_LIST" "$@"); }
bd_calls() { awk 'END { print NR + 0 }' "$BD_LOG" 2>/dev/null; }
# bead_json <id> <assignee> <status> <title> [<created_at>]
bead_json() {
  jq -cn --arg id "$1" --arg a "$2" --arg s "$3" --arg t "$4" --arg c "${5:-2026-10-14T04:22:25.93691Z}" \
    '{id: $id, title: $t, description: "body", status: $s, priority: 2, issue_type: "message",
      assignee: $a, owner: "x@example.invalid", created_at: $c,
      created_by: "communication-management.lead", updated_at: $c, ephemeral: true}'
}
# bd_hook <event> <json> [<actor>]. The actor is picked so that the hook's OTHER job, the
# nudge, has nobody to tell (the assignee itself, or `human`, who has no pane): a pane
# notice filed here would be counted by the notice checks further down.
bd_hook() {
  (cd "$PROJECT" && printf '%s' "$2" | WOLFMUX_BIN_DIR="$REPO/bin" BEADS_ACTOR="${3:-communication-management.lead}" \
    "$WOLFMUX_HOME/hooks/beads-nudge" "$(printf '%s' "$2" | jq -r .id)" "$1" >/dev/null 2>&1)
}
index_rows() { awk -F"$US" 'NF >= 4' "$HUMAN_INDEX" 2>/dev/null | awk 'END { print NR + 0 }'; }
index_ids() { awk -F"$US" 'NF >= 4 { printf "%s ", $1 }' "$HUMAN_INDEX" 2>/dev/null; }
# The hook writes in the background, so a check waits (5 s at most) for the FILE — never bd.
wait_rows() {
  local n=0
  while [ "$(index_rows)" != "$1" ] && [ "$n" -lt 50 ]; do
    sleep 0.1
    n=$((n + 1))
  done
}

bd_hook create "$(bead_json m-1 human open 'First, with a	tab' 2026-10-14T01:00:00Z)"
wait_rows 1
check "hook: an open message for the human adds a row on create" '[ "$(index_ids)" = "m-1 " ]'
check "hook: the row is id, sender, subject, created (epoch), and a tab in the subject is a space" 'grep -q "^m-1${US}communication-management.lead${US}First, with a tab${US}[0-9][0-9]*\$" "$HUMAN_INDEX"'
bd_hook create "$(bead_json m-x lead open 'For the lead')" lead
bd_hook create "$(bead_json m-2 human open 'Second' 2026-10-14T02:00:00Z)"
bd_hook create "$(bead_json m-3 human open 'Third' 2026-10-14T03:00:00Z)"
wait_rows 3
sleep 1
check "hook: a message for somebody else is not the human's" '[ "$(index_ids)" = "m-3 m-2 m-1 " ]'
check "hook: newest first" '[ "$(head -1 "$HUMAN_INDEX" | cut -d "$US" -f1)" = "m-3" ]'
check "hook: no temp file or lock left behind" '[ -z "$(ls -A "$STATE_DIR" | grep "human-inbox\.")" ]'
: >"$BD_LOG"
check "badge: three unread messages read 📨 3" '[ "$(fake_bd teamctl _inbox-badge "$SESSION")" = "📨 3" ]'
check "badge: and it ran bd zero times to say so" '[ "$(bd_calls)" = "0" ]'
bd_hook close "$(bead_json m-1 human closed 'First')"
wait_rows 2
check "hook: a message marked read is dropped on close" '[ "$(index_ids)" = "m-3 m-2 " ]'
bd_hook update "$(bead_json m-2 qa open 'Second')" qa
wait_rows 1
check "hook: a message handed to somebody else is dropped on reassign" '[ "$(index_ids)" = "m-3 " ]'
check "badge: one left reads 📨 1" '[ "$(badge)" = "📨 1" ]'

# The popup: the index is drawn at once, then ONE targeted bd call puts it right. Beads
# says m-3 and m-7 are open (m-7 arrived while no hook ran, m-3 is still there).
jq -n "[$(bead_json m-7 human open 'Arrived unseen' 2026-10-14T05:00:00Z), $(bead_json m-3 human open 'Third' 2026-10-14T03:00:00Z)]" >"$BD_LIST"
: >"$BD_LOG"
fake_bd teamctl _human-inbox --print >"$WORK/popup-print" 2>&1
check "popup: opening it makes exactly ONE bd call" '[ "$(bd_calls)" = "1" ]'
check "popup: and it is the targeted one, never the whole store" 'grep -q "|list --assignee human --type message --status open --limit 0 --json$" "$BD_LOG"'
check "popup: the index now says what Beads says, newest first" '[ "$(index_ids)" = "m-7 m-3 " ]'
check "popup: rows carry the number, the sender, the subject and the age" 'grep -qE "^ +1  m-7  communication-management.lead  Arrived unseen  [0-9]+[mhd]$" "$WORK/popup-print"'
: >"$BD_LOG"
printf 'q' | fake_bd teamctl _human-inbox >/dev/null 2>&1
check "popup, interactive: opened and closed with q, still exactly one bd call" '[ "$(bd_calls)" = "1" ] && grep -q "|list --assignee human " "$BD_LOG"'
: >"$BD_LOG"
printf 'jrq' | fake_bd teamctl _human-inbox >/dev/null 2>&1
check "popup: r marks the selected message read, AS the human" 'grep -qx "human|close m-3 -r read" "$BD_LOG"'
check "popup: and drops it from the index at once" '[ "$(index_ids)" = "m-7 " ]'
: >"$BD_LOG"
printf 'anq' | fake_bd teamctl _human-inbox >/dev/null 2>&1
check "popup: a then n marks nothing" '! grep -q "|close" "$BD_LOG"'
jq -n "[$(bead_json m-7 human open 'Arrived unseen' 2026-10-14T05:00:00Z), $(bead_json m-8 human open 'Eighth' 2026-10-14T06:00:00Z)]" >"$BD_LIST"
: >"$BD_LOG"
printf 'ayq' | fake_bd teamctl _human-inbox >/dev/null 2>&1
check "popup: a then y marks them all read in ONE bd call, as the human" '[ "$(grep -c "|close" "$BD_LOG")" = "1" ] && grep -qx "human|close m-8 m-7 -r read" "$BD_LOG"'
check "badge: hidden at 0" '[ -z "$(badge)" ] && [ "$(index_rows)" = "0" ]'
printf 'keep-1%scomms%sKept%s1760000000\n' "$US" "$US" "$US" >"$HUMAN_INDEX"
printf 'bd: database is locked\n' >"$BD_LIST"
fake_bd teamctl _human-inbox --print >"$WORK/popup-print" 2>&1
check "popup: a bd answer that is not a list leaves the index as it was, and says so" '[ "$(index_ids)" = "keep-1 " ] && grep -q "could not refresh" "$WORK/popup-print"'
printf '[]\n' >"$BD_LIST"
: >"$BD_LOG"
WOLFMUX_HUMAN=ammar fake_bd teamctl _human-inbox --print >/dev/null 2>&1
check "WOLFMUX_HUMAN: the popup asks Beads for that name" 'grep -q "|list --assignee ammar " "$BD_LOG" && [ "$(index_rows)" = "0" ]'
(cd "$PROJECT" && bead_json m-9 ammar open 'For ammar' | WOLFMUX_HUMAN=ammar WOLFMUX_BIN_DIR="$REPO/bin" "$WOLFMUX_HOME/hooks/beads-nudge" m-9 create >/dev/null 2>&1)
wait_rows 1
check "WOLFMUX_HUMAN: and the hook keeps that name's messages" '[ "$(index_ids)" = "m-9 " ]'
/bin/rm -f "$HUMAN_INDEX"

echo "== v1.20.0: a pane a human is watching is never typed into (policy human-pane-typing off)"
# Ammar, 2026-10-15: "i still see beads messages in my terminal". v1.16.1 typed into an
# attached lead's pane once it had been quiet for WOLFMUX_NUDGE_LEAD_IDLE, and at once
# while he was looking at another pane. The default now is never, for the lead's pane of
# an attached team and for whatever pane an attached client is showing; such a notice is
# filed and the agent's own hooks hand it over. A second worker, aux, is the "other
# workers still are" half: the human looks at qa, and aux must still be typed into.
teamctl spawn aux flash --no-kickoff >/dev/null 2>&1
sleep 2
AUX_PANE="$(teamctl status --json | jq -r '.agents[] | select(.role == "aux") | .pane')"
attach_client
tmx select-window -t "$WINDOW" >/dev/null 2>&1
tmx select-pane -t "$PANE" >/dev/null 2>&1 # the human is looking at the qa pane
sleep 4                                    # longer than any idle window this suite uses
check "setup: one client attached, showing qa, a second worker aux, and the policy at its default off" '[ "$(clients)" = "1" ] && [ "$(tmx list-clients -F "#{pane_id}")" = "$PANE" ] && [ -n "$AUX_PANE" ] && [ "$AUX_PANE" != "null" ] && teamctl policy | grep -qE "^  human-pane-typing +off "'
HBEFORE="$(notices lead "Beads update for lead")"
teamctl nudge lead --id human-lead-1 >"$WORK/human-lead-1.log" 2>&1
HUMAN_LEAD_STATUS=$?
sleep 2
# v1.23.0 (issue #34): the client shows qa, so nobody is USING the lead's pane. A Claude-family
# lead is still never typed into while a client is attached; the sender is told it is held.
check "attached + the lead pane: filed, not typed (exit 4), and the sender is told it is held" '[ "$HUMAN_LEAD_STATUS" -eq 4 ] && grep -q "^filed: held for lead" "$WORK/human-lead-1.log" && grep -q "no wake waiter runs for it" "$WORK/human-lead-1.log"'
check "attached + the lead pane: nothing reached it, though it is quiet and not on screen" '[ "$(notices lead "Beads update for lead")" = "$HBEFORE" ] && ! teamctl capture lead --all | grep -q "human-lead-1"'
check "attached + the lead pane: no waiter was parked either, so nothing types it in later" '[ ! -d "$(pending_dir lead)" ]'
check "attached + the lead pane: the event log names the rule and what the sender was told" 'grep -q "human-pane-typing=off: a client is attached.*held for lead" "$STATE_DIR/events.jsonl"'
# v1.23.0: nobody is using the lead's pane (the client shows qa), but a client IS attached:
# its Stop hook stays silent, because Claude Code would print the notice in full in the pane
# ("Stop hook feedback"). The wake waiter hands it over instead, and a wake prints one line.
# The waiter's exit status is that of the bin/teamctl process itself: Claude Code wakes the
# agent on the PROCESS exit code 2, so set +e and main's own error handling must keep it.
check "attached + the lead pane not in use: its Stop hook still prints nothing, the notice waits" '[ -z "$(hook lead _inbox-stop)" ] && delivered_of lead human-lead-1 false'
WOLFMUX_WAKE_POLL=1 hook_in "$LEAD_PANE" lead _inbox-wake >"$WORK/human-lead-wake.out"
HUMAN_LEAD_WAKE_RC=$?
check "attached + the lead pane not in use: the wake waiter PROCESS exits 2 with the notice, and it is delivered" '[ "$HUMAN_LEAD_WAKE_RC" -eq 2 ] && grep -q "human-lead-1" "$WORK/human-lead-wake.out" && delivered_of lead human-lead-1 true'
check "attached + the lead pane not in use: the next prompt then has nothing left to hand over" '[ -z "$(hook lead _inbox-prompt)" ]'
/bin/rm -f "$INBOX/.stop.lead" "$INBOX/.wake.lead"
QBEFORE="$(notices qa "Beads update for qa")"
teamctl nudge qa --id human-qa-1 >"$WORK/human-qa-1.log" 2>&1
HUMAN_QA_STATUS=$?
sleep 2
check "attached + the human viewing the qa pane: qa is not typed into (exit 4)" '[ "$HUMAN_QA_STATUS" -eq 4 ] && grep -q "an attached client shows this pane" "$WORK/human-qa-1.log" && [ "$(notices qa "Beads update for qa")" = "$QBEFORE" ]'
check "attached + the human viewing qa: it is filed, qa's Stop hook keeps quiet, its next prompt hands it over" 'grep -q "human-qa-1" "$(inbox_file qa)" && [ -z "$(hook qa _inbox-stop)" ] && delivered_of qa human-qa-1 false && hook qa _inbox-prompt | grep -q "human-qa-1" && delivered_of qa human-qa-1 true'
teamctl nudge aux --id human-aux-1 >"$WORK/human-aux-1.log" 2>&1
HUMAN_AUX_STATUS=$?
sleep 2
check "attached + the human viewing qa: ANOTHER worker, aux, is typed into exactly as before" '[ "$HUMAN_AUX_STATUS" -eq 0 ] && teamctl capture aux --all | grep -q "Beads update for aux (human-aux-1)"'
LPBEFORE="$(notices lead "Policy changed")"
teamctl policy lead-teams on >/dev/null 2>&1
sleep 2
check "attached + a policy notice for the lead (notify_lead): filed, never typed" '[ "$(notices lead "Policy changed")" = "$LPBEFORE" ] && grep -q "Policy changed: lead-teams = on" "$(inbox_file lead)"'
# A notice already PARKED for a pane must not be typed once the human starts watching it:
# the waiter asks the same question before every line. aux gets a half-typed line, so the
# notice parks; then the human looks at aux and the line goes. It waits while he watches,
# and arrives by itself once he looks away.
tmx send-keys -t "$AUX_PANE" -l "aux has a half typed line" >/dev/null 2>&1
sleep 0.5
teamctl nudge aux --id parked-aux-1 >"$WORK/parked-aux-1.log" 2>&1
PARKED_AUX_STATUS=$?
check "parked then watched: the notice parks behind aux's half-typed line (exit 3)" '[ "$PARKED_AUX_STATUS" -eq 3 ] && [ -d "$(pending_dir aux)" ]'
tmx select-pane -t "$AUX_PANE" >/dev/null 2>&1
tmx send-keys -t "$AUX_PANE" Enter >/dev/null 2>&1
sleep 5
check "parked then watched: while the human watches aux, the waiter types nothing" '! teamctl capture aux --all | grep -q "(parked-aux-1)" && [ -d "$(pending_dir aux)" ]'
tmx select-pane -t "$PANE" >/dev/null 2>&1
sleep 5
check "parked then watched: once the human looks away, it arrives by itself" 'teamctl capture aux --all | grep -q "Beads update for aux (parked-aux-1)" && [ ! -d "$(pending_dir aux)" ]'

echo "== v1.20.0: the Stop hook says nothing in a pane a human is watching; the next prompt carries it"
# Ammar, 2026-10-15, a screenshot of the pane he watches: "Stop hook error: [wolfmux] You
# have team notices: …" — "i am still seeing such messages". Claude Code prints a Stop
# hook's reason in the pane; a UserPromptSubmit hook's output reaches the model alone.
# Still attached here, showing qa. WOLFMUX_NUDGE_TYPE=off files each notice without
# typing it, so the Stop hook is the only thing that could hand it over.
FAKE_TMUX_DIR="$WORK/fake-tmux"
/bin/mkdir -p "$FAKE_TMUX_DIR"
# a tmux that fails ONE subcommand, FAKE_TMUX_FAIL, and hands every other to the real one
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "$FAKE_TMUX_FAIL" ] && exit 1; done\nexec "%s" "$@"\n' "$(command -v tmux)" >"$FAKE_TMUX_DIR/tmux"
chmod +x "$FAKE_TMUX_DIR/tmux"
/bin/rm -f "$INBOX/.stop.lead" "$INBOX/.stop.qa" "$INBOX/.stop.aux"
stop_silent_events() { grep -c '"type":"inbox-stop-silent"' "$STATE_DIR/events.jsonl" 2>/dev/null || true; }
SILENT_BEFORE="$(stop_silent_events)"
# v1.23.0: "watched" is a pane a client SHOWS and a human uses (its terminal has focus: a pty
# client that sends no focus reports reads focused from the start). So the client shows the
# lead's pane for these checks, and goes back to qa after them.
tmx select-pane -t "$LEAD_PANE" >/dev/null 2>&1
WOLFMUX_NUDGE_TYPE=off teamctl nudge lead --id silent-lead-1 >/dev/null 2>&1
hook lead _inbox-stop >"$WORK/silent-lead.out"
SILENT_LEAD_STATUS=$?
check "watched lead pane: the Stop hook exits 0 and prints NOTHING" '[ "$SILENT_LEAD_STATUS" -eq 0 ] && [ ! -s "$WORK/silent-lead.out" ]'
check "watched lead pane: the notice is still undelivered, waiting for the next prompt" 'delivered_of lead silent-lead-1 false'
check "watched lead pane: one event line says why, and the cooldown stamp is left alone" '[ "$(stop_silent_events)" -gt "$SILENT_BEFORE" ] && grep "\"type\":\"inbox-stop-silent\"" "$STATE_DIR/events.jsonl" | tail -1 | grep -q "next prompt (human-pane-typing=off: an attached client shows this pane and its terminal has focus" && [ ! -e "$INBOX/.stop.lead" ]'
check "watched lead pane (TMUX_PANE named directly): silent as well" '[ -z "$(hook_in "$LEAD_PANE" lead _inbox-stop)" ] && delivered_of lead silent-lead-1 false'
PROMPT_SILENT="$(hook lead _inbox-prompt)"
check "watched lead pane: the next prompt hands it over and marks it delivered" 'printf "%s" "$PROMPT_SILENT" | grep -q "silent-lead-1" && printf "%s" "$PROMPT_SILENT" | grep -q "bd list --assignee lead" && delivered_of lead silent-lead-1 true'
check "watched lead pane: after that the Stop hook has nothing left to say" '[ -z "$(hook lead _inbox-stop)" ]'
tmx select-pane -t "$PANE" >/dev/null 2>&1 # the client shows qa again
WOLFMUX_NUDGE_TYPE=off teamctl nudge lead --id bg-lead-1 >/dev/null 2>&1
check "the same lead pane once the client shows qa (a background pane): the Stop hook stays silent (the waiter's job)" '[ -z "$(hook lead _inbox-stop)" ] && delivered_of lead bg-lead-1 false'
check "a background lead pane: the wake waiter process exits 2 and hands bg-lead-1 over" 'WOLFMUX_WAKE_POLL=1 hook_in "$LEAD_PANE" lead _inbox-wake | grep -q "bg-lead-1"; [ "${PIPESTATUS[0]}" -eq 2 ] && delivered_of lead bg-lead-1 true'
/bin/rm -f "$INBOX/.stop.lead" "$INBOX/.wake.lead"
WOLFMUX_NUDGE_TYPE=off teamctl nudge qa --id silent-qa-1 >/dev/null 2>&1
check "watched worker pane (the client shows qa): silent, both ways the fixture runs it" '[ -z "$(hook_in "$PANE" qa _inbox-stop)" ] && [ -z "$(hook qa _inbox-stop)" ] && delivered_of qa silent-qa-1 false && grep "\"type\":\"inbox-stop-silent\"" "$STATE_DIR/events.jsonl" | tail -1 | grep -q "an attached client shows this pane"'
check "watched worker pane: qa's next prompt hands it over" 'hook_in "$PANE" qa _inbox-prompt | grep -q "silent-qa-1" && delivered_of qa silent-qa-1 true'
WOLFMUX_NUDGE_TYPE=off teamctl nudge aux --id silent-aux-1 >/dev/null 2>&1
AUX_STOP="$(hook_in "$AUX_PANE" aux _inbox-stop)"
check "UNwatched worker pane (aux, same team, same time): the hook still continues the turn, as feedback" 'stop_continues "$AUX_STOP" && printf "%s" "$AUX_STOP" | stop_body | grep -q "silent-aux-1" && delivered_of aux silent-aux-1 true && [ -s "$INBOX/.stop.aux" ]'
/bin/rm -f "$INBOX/.stop.aux"
WOLFMUX_NUDGE_TYPE=off teamctl nudge aux --id tmuxerr-1 >/dev/null 2>&1
TMUXERR_OUT="$(
  export PATH="$FAKE_TMUX_DIR:$PATH" FAKE_TMUX_FAIL=list-clients
  hook_in "$AUX_PANE" aux _inbox-stop
)"
check "a tmux error on who is watching: read as watched, so silent, and the notice waits" '[ -z "$TMUXERR_OUT" ] && delivered_of aux tmuxerr-1 false && [ ! -e "$INBOX/.stop.aux" ]'
check "a tmux error: and the same hook with tmux answering continues the turn as before" 'hook_in "$AUX_PANE" aux _inbox-stop | stop_body | grep -q "tmuxerr-1" && delivered_of aux tmuxerr-1 true'
/bin/rm -f "$INBOX/.stop.aux"
WOLFMUX_NUDGE_TYPE=off teamctl nudge aux --id lookup-1 >/dev/null 2>&1
# The pane proof reads the pane once (display-message). When that read fails, the hook cannot
# tell whose pane it is: it is given nothing and nothing is taken. It never falls back to
# looking the pane up by role (list-panes): that is how an inherited environment found the
# real agent's pane.
LOOKUP_OUT="$(
  export PATH="$FAKE_TMUX_DIR:$PATH" FAKE_TMUX_FAIL=display-message
  hook_in "$AUX_PANE" aux _inbox-stop
)"
check "the pane read fails (tmux fails display-message): no proof, silent, nothing taken" '[ -z "$LOOKUP_OUT" ] && delivered_of aux lookup-1 false'
LOOKUP_OUT="$(
  export PATH="$FAKE_TMUX_DIR:$PATH" FAKE_TMUX_FAIL=list-panes
  hook_in "$AUX_PANE" aux _inbox-stop
)"
check "tmux fails list-panes: the hook never needs a lookup by role, and continues the turn" 'printf "%s" "$LOOKUP_OUT" | stop_body | grep -q "lookup-1" && delivered_of aux lookup-1 true'
# v1.22.1: policy idle too. Under idle the Stop hook still answered here, and Claude Code
# printed it as "Stop hook error" after almost every turn of the communication lead, in the
# pane Ammar is attached to (2026-10-26). idle decides typing; the Stop hook keeps out.
tmx select-pane -t "$LEAD_PANE" >/dev/null 2>&1 # in use: shown, and focused
WOLFMUX_NUDGE_TYPE=off teamctl nudge lead --id idle-stop-1 >/dev/null 2>&1
SILENT_BEFORE="$(stop_silent_events)"
WOLFMUX_HUMAN_PANE_TYPING=idle hook lead _inbox-stop >"$WORK/idle-stop.out"
IDLE_STOP_STATUS=$?
check "policy idle, a client attached: the lead's Stop hook exits 0 and prints NOTHING" '[ "$IDLE_STOP_STATUS" -eq 0 ] && [ ! -s "$WORK/idle-stop.out" ]'
check "policy idle, a client attached: the notice is still undelivered" 'delivered_of lead idle-stop-1 false'
check "policy idle, a client attached: the newest silent event names idle, and the cooldown stamp is left alone" '[ "$(stop_silent_events)" -gt "$SILENT_BEFORE" ] && grep "\"type\":\"inbox-stop-silent\"" "$STATE_DIR/events.jsonl" | tail -1 | grep -q "human-pane-typing=idle: an attached client shows this pane" && [ ! -e "$INBOX/.stop.lead" ]'
check "policy idle, a client attached: the next prompt hands it over and marks it delivered" 'WOLFMUX_HUMAN_PANE_TYPING=idle hook lead _inbox-prompt | grep -q "idle-stop-1" && delivered_of lead idle-stop-1 true'
tmx select-pane -t "$PANE" >/dev/null 2>&1
detach_client
/bin/rm -f "$INBOX/.stop.lead"
WOLFMUX_NUDGE_TYPE=off teamctl nudge lead --id unwatched-1 >/dev/null 2>&1
check "detached (nobody watching), policy off: the lead's Stop hook continues the turn as before" 'hook lead _inbox-stop | stop_body | grep -q "unwatched-1" && delivered_of lead unwatched-1 true'
WOLFMUX_NUDGE_TYPE=off teamctl nudge lead --id unwatched-2 >/dev/null 2>&1
check "detached, policy off: the cooldown still holds the next block back" '[ -z "$(hook lead _inbox-stop)" ] && delivered_of lead unwatched-2 false'
/bin/rm -f "$INBOX/.stop.lead"
check "detached, policy off: and once it has passed, the next turn end continues with it" 'hook lead _inbox-stop | stop_body | grep -q "unwatched-2"'

# The blocks below count the lead's inbox lines from the first one and the banners from
# zero, so this section hands everything back empty.
teamctl inbox --all >/dev/null 2>&1
: >"$(inbox_file lead)"
: >"$WOLFMUX_NOTIFY_TTY"
/bin/rm -f "$WOLFMUX_DATA/.stall.lead" "$INBOX/.stall.lead" "$INBOX/.stop.lead" "$INBOX/.stop.qa" "$INBOX/.stop.aux"

# From here to the detach further down, the v1.16.1 rule is asserted exactly as it was:
# it is still there, as policy human-pane-typing idle, for whoever chooses it.
export WOLFMUX_HUMAN_PANE_TYPING=idle

echo "== under policy idle: a client attached and a QUIET lead pane: the notice is typed after all (issue #12)"
# Measured in production on 2026-10-12: a lead idle from 13:58Z never received P1
# notices sent at 16:13Z or 16:53Z, because v1.15.0 filed them and filing reaches the
# agent through its Stop hook, which needs a turn boundary an idle agent does not have.
# No suite had an IDLE agent in it, which is why 933 passing checks did not catch it.
attach_client
tmx select-window -t "$WINDOW" >/dev/null 2>&1
tmx select-pane -t "$PANE" >/dev/null 2>&1 # the human is looking at the WORKER pane
sleep 4                                    # longer than WOLFMUX_NUDGE_LEAD_IDLE
check "setup: a client is attached" '[ "$(clients)" = "1" ]'
AWAKE_BEFORE="$(notices lead "Beads update for lead")"
teamctl nudge lead --id awake-1 >"$WORK/awake-1.log" 2>&1
AWAKE_STATUS=$?
sleep 2
check "attached + a quiet lead pane: typed at once (exit 0), with no human keystroke" '[ "$AWAKE_STATUS" -eq 0 ] && grep -q "notified: lead" "$WORK/awake-1.log" && teamctl capture lead --all | grep -q "Beads update for lead (awake-1)"'
check "attached + a quiet lead pane: typing marked it delivered, so no hook hands it over twice" '[ "$(state_of lead 1)" = "nd" ]'
# Both directions, because a notice delivered TWICE looks like the agent being nagged
# with nothing in the inbox to explain it, and that is worse than one delivered late.
# v1.22.1: the Stop hook is silent in this pane whatever it holds, so the prompt hook is the
# one that proves "not twice" here.
check "attached + a quiet lead pane: and neither hook therefore has anything to say about it" '[ -z "$(hook lead _inbox-stop)" ] && [ -z "$(hook lead _inbox-prompt)" ]'
check "attached + a quiet lead pane: the notice is still filed, unread, and NOT on the badge" '[ "$(notices_new)" = "1" ] && [ -z "$(badge)" ]'
check "attached + a quiet lead pane: no banner — the notice reached the agent" '[ "$(banners)" = "0" ]'
# The blocks below count the lead's inbox lines from the first one, so this episode
# hands the file back empty rather than shifting every line number after it.
teamctl inbox --all >/dev/null 2>&1
: >"$(inbox_file lead)"
: >"$WOLFMUX_NOTIFY_TTY"
/bin/rm -f "$INBOX/.stall.lead"

echo "== a client attached and a human WORKING in the lead pane: nothing is typed (issue #11)"
# The complaint itself: "i dont want to keep seeing these updates in the mid of my
# convos". A half-typed line is the deterministic form of "a human is working here", and
# it holds for the whole region below — every lead notice from here to the detach waits
# in the marker, undelivered, which is what the Stop-hook and badge checks need.
BEFORE="$(notices lead "Beads update for lead")"
tmx send-keys -t "$LEAD_PANE" -l "the human is mid-sentence" >/dev/null 2>&1
sleep 0.5
teamctl nudge lead --id quiet-1 >"$WORK/quiet-1.log" 2>&1
QUIET_STATUS=$?
sleep 2
check "attached + a human in the lead pane: exit 3, and the message says the notice was deferred" '[ "$QUIET_STATUS" -eq 3 ] && grep -q "^deferred:" "$WORK/quiet-1.log"'
check "attached + a human in the lead pane: NOTHING was typed into the lead pane" '[ "$(notices lead "Beads update for lead")" = "$BEFORE" ] && ! teamctl capture lead --all | grep -q "quiet-1"'
check "attached + a human in the lead pane: a waiter IS parked, to deliver once that pane is quiet" '[ -d "$(pending_dir lead)" ]'
check "attached + a human in the lead pane: the notice IS in the file, new and undelivered" '[ "$(state_of lead 1)" = "nu" ] && grep -q "quiet-1" "$(inbox_file lead)"'
check "attached + a human in the lead pane: one notice is filed for the human, unread" '[ "$(notices_new)" = "1" ]'
check "attached + a human in the lead pane: the event log says deferred, not nudged" 'grep -q "nudge-deferred" "$STATE_DIR/events.jsonl"'

echo "== and the human is told once, by a banner that carries the count"
check "stall: exactly one desktop notification was raised" '[ "$(banners)" = "1" ]'
check "stall: it names the team and role and carries the count, not the bead id" 'grep -q "default/lead: 1 notice waiting" "$WOLFMUX_NOTIFY_TTY" && ! grep -q "quiet-1" "$WOLFMUX_NOTIFY_TTY"'
for n in 2 3 4 5 6 7 8 9 10 11; do teamctl nudge lead --id "burst-$n" >/dev/null 2>&1; done
sleep 1
check "stall: ten more beads inside the 120 s window raise NO second banner" '[ "$(banners)" = "1" ]'
check "stall: but every one of them is in the file, and all of them count as unread" '[ "$(notices_new)" = "11" ] && [ "$(grep -c "burst-" "$(inbox_file lead)")" = "10" ]'
check "stall: still nothing typed into the lead pane after eleven notices" '[ "$(notices lead "Beads update for lead")" = "$BEFORE" ]'
: >"$WOLFMUX_NOTIFY_TTY"
/bin/rm -f "$INBOX/.stall.lead"
WOLFMUX_NOTIFY=off teamctl nudge lead --id off-1 >/dev/null 2>&1
sleep 1
check "stall: WOLFMUX_NOTIFY=off raises no banner at all, and still types nothing" '[ "$(banners)" = "0" ] && [ "$(notices lead "Beads update for lead")" = "$BEFORE" ]'
/bin/rm -f "$INBOX/.stall.lead"
WOLFMUX_INBOX_STALL_NOTIFY=off teamctl nudge lead --id off-2 >/dev/null 2>&1
sleep 1
check "stall: WOLFMUX_INBOX_STALL_NOTIFY=off raises none either" '[ "$(banners)" = "0" ]'
QBEFORE="$(banners)"
teamctl nudge qa --id worker-1 >/dev/null 2>&1
sleep 2
check "stall: a WORKER raises no banner — it gets the typed fallback instead" '[ "$(banners)" = "$QBEFORE" ] && teamctl capture qa --all | grep -q "Beads update for qa (worker-1)"'

echo "== the Stop hook under idle: silent in the watched lead pane, and told once, no loop, elsewhere"
# v1.22.1: this block expected the block answer in the lead's pane. That pane is in front of
# the human (a client is attached), so under idle too the Stop hook says nothing there and
# the next prompt hands the notices over. The two loop guards are asserted on aux instead,
# a worker pane nobody is showing, where the hook still has to speak.
SILENT_BEFORE="$(stop_silent_events)"
tmx select-pane -t "$LEAD_PANE" >/dev/null 2>&1 # v1.23.0: watched = shown and in use
hook lead _inbox-stop >"$WORK/idle-lead-stop.out"
IDLE_LEAD_STATUS=$?
check "Stop hook, watched lead pane under idle: it exits 0 and prints NOTHING, with notices waiting" '[ "$IDLE_LEAD_STATUS" -eq 0 ] && [ ! -s "$WORK/idle-lead-stop.out" ]'
check "Stop hook, watched lead pane under idle: nothing was taken, and no cooldown stamp was written" '[ "$(state_of lead 1)" = "nu" ] && delivered_of lead quiet-1 false && [ ! -e "$INBOX/.stop.lead" ]'
check "Stop hook, watched lead pane under idle: the newest silent event names idle and the reason" '[ "$(stop_silent_events)" -gt "$SILENT_BEFORE" ] && grep "\"type\":\"inbox-stop-silent\"" "$STATE_DIR/events.jsonl" | tail -1 | grep -q "human-pane-typing=idle: an attached client shows this pane"'
LEAD_PROMPT="$(hook lead _inbox-prompt)"
check "watched lead pane under idle: the next prompt hands them over, with the Beads command" 'printf "%s" "$LEAD_PROMPT" | grep -q "quiet-1" && printf "%s" "$LEAD_PROMPT" | grep -q "bd list --assignee lead" && [ "$(state_of lead 1)" = "nd" ]'
check "watched lead pane under idle: and the human's column is untouched, so they still count as unread" '[ "$(notices_new)" -gt 0 ]'
check "watched lead pane under idle: after that the Stop hook has nothing left to say" '[ -z "$(hook lead _inbox-stop)" ]'
tmx select-pane -t "$PANE" >/dev/null 2>&1
/bin/rm -f "$INBOX/.stop.aux"
WOLFMUX_NUDGE_TYPE=off teamctl nudge aux --id loop-aux-1 >/dev/null 2>&1
STOP_OUT="$(hook_in "$AUX_PANE" aux _inbox-stop)"
check "Stop hook, unwatched aux pane under idle: it continues the turn, and the feedback carries the notice and the Beads command" 'stop_continues "$STOP_OUT" && printf "%s" "$STOP_OUT" | stop_body | grep -q "loop-aux-1" && printf "%s" "$STOP_OUT" | stop_body | grep -q "bd list --assignee aux"'
check "Stop hook, aux: the line was marked delivered BEFORE it answered, the stamp written, the event says continued" 'delivered_of aux loop-aux-1 true && [ -s "$INBOX/.stop.aux" ] && grep "\"type\":\"inbox-stop\"" "$STATE_DIR/events.jsonl" | tail -1 | grep -q "continued once with 1 notice(s)"'
WOLFMUX_NUDGE_TYPE=off teamctl nudge aux --id loop-aux-2 >/dev/null 2>&1
check "Stop hook, aux: a second turn ending at once says nothing (cooldown), and takes nothing" '[ -z "$(hook_in "$AUX_PANE" aux _inbox-stop)" ] && delivered_of aux loop-aux-2 false'
/bin/rm -f "$INBOX/.stop.aux"
check "Stop hook, aux: with the cooldown gone, the NEW notice continues the turn, so nothing is starved by the two guards" 'hook_in "$AUX_PANE" aux _inbox-stop | stop_body | grep -q "loop-aux-2" && delivered_of aux loop-aux-2 true'
/bin/rm -f "$INBOX/.stop.aux"
check "Stop hook, aux: it continued exactly once for that notice, not twice" '[ -z "$(hook_in "$AUX_PANE" aux _inbox-stop)" ]'
check "Stop hook: an agent with no notices at all says nothing" '[ -z "$(hook no-such-role _inbox-stop)" ]'

echo "== the UserPromptSubmit hook: the same notices, on stdout, when the human types"
teamctl nudge lead --id prompt-1 >/dev/null 2>&1
PROMPT_OUT="$(hook lead _inbox-prompt)"
check "UserPromptSubmit: the notices are printed for the model's context" 'printf "%s" "$PROMPT_OUT" | grep -q "prompt-1" && printf "%s" "$PROMPT_OUT" | grep -q "bd list --assignee lead"'
check "UserPromptSubmit: it has no cooldown, but delivered notices are not repeated" '[ -z "$(hook lead _inbox-prompt)" ]'

echo "== the two states are independent, in both directions"
check "independence: everything is delivered to the agent, and all still new for the human" '[ "$(teamctl inbox lead --keep --json | jq "[.[] | select(.delivered == false)] | length")" = "0" ] && [ "$(teamctl inbox lead --keep --json | jq "[.[] | select(.new == false)] | length")" = "0" ]'
check "inbox --keep: printed them and left every one marked new" '[ "$(notices_new)" -gt 0 ]'
# The badge counts the WHOLE team, so clearing it needs --all: the worker has notices of
# its own from the blocks above.
teamctl inbox --all >"$WORK/inbox-1.log" 2>&1
check "teamctl inbox: it printed the notices, oldest first" 'grep -q "quiet-1" "$WORK/inbox-1.log" && [ "$(grep -n "quiet-1" "$WORK/inbox-1.log" | cut -d: -f1)" -lt "$(grep -n "prompt-1" "$WORK/inbox-1.log" | cut -d: -f1)" ]'
check "teamctl inbox: it points at Beads for the work itself" 'grep -q "bd list --assignee" "$WORK/inbox-1.log"'
check "teamctl inbox --all: reading every role left no notice unread" '[ "$(notices_new)" = "0" ]'
check "teamctl inbox: it cleared new-ness WITHOUT touching delivered-ness" '[ "$(state_of lead 1)" = "sd" ] && [ "$(teamctl inbox lead --keep --json | jq "[.[] | select(.delivered == false)] | length")" = "0" ]'
teamctl nudge lead --id both-1 >/dev/null 2>&1
check "independence the other way: a new notice is new for the human AND undelivered" '[ "$(teamctl inbox lead --keep --json | jq "[.[] | select(.new and (.delivered | not))] | length")" = "1" ]'
hook lead _inbox-prompt >/dev/null 2>&1 # v1.22.1: the Stop hook is silent in this watched pane
check "independence the other way: the agent having it does NOT mark it read for the human" 'delivered_of lead both-1 true && [ "$(notices_new)" = "1" ] && [ "$(inbox_count_new_of lead)" = "1" ]'
check "teamctl notices: the alias is the same command" 'teamctl notices lead --keep | grep -q "both-1"'
check "teamctl inbox --all: every role of the team, the worker included" 'teamctl inbox --all --keep | grep -q "^qa" && teamctl inbox --all --keep | grep -q "^lead"'
check "teamctl inbox: it is no longer the pointer-to-Beads message it used to print" '! teamctl inbox lead --keep 2>&1 | grep -q "is not a teamctl command"'
# v1.24.0 (D6): send is a real command now; broadcast and message-history keep the old answer
check "moved_to_beads still covers every other word it covered" '! teamctl send 2>&1 | grep -q "is not a teamctl command" && teamctl broadcast 2>&1 | grep -q "is not a teamctl command" && teamctl message-history 2>&1 | grep -q "is not a teamctl command"'

echo "== an approval: the louder mark, and typed after the grace period if still unread"
teamctl inbox --all >/dev/null 2>&1
printf '%s\tapproval\tnu\t[wolfmux] Permission request A1 from qa. Run: teamctl approvals\n' "$(date +%s)" >>"$(inbox_file lead)"
# v1.20.0: the bell is a request still PENDING in the approvals store, not an unread notice
# (prefix N no longer opens the notices, so a bell that waited for them to be read would
# never go). A request file of its own, an id no real request reaches, removed after.
APPROVAL_FILE="$STATE_DIR/approvals/A900.json"
/bin/mkdir -p "$STATE_DIR/approvals"
printf '{\n  "id": "A900",\n  "role": "qa",\n  "status": "pending"\n}\n' >"$APPROVAL_FILE"
check "approval: a pending request puts the bell on the badge, alone while no message is unread" '[ "$(badge)" = "🔔" ]'
teamctl inbox lead >/dev/null 2>&1
check "approval: reading the notices does not take the bell away while it is pending" '[ "$(badge)" = "🔔" ]'
printf '{\n  "id": "A900",\n  "role": "qa",\n  "status": "approved"\n}\n' >"$APPROVAL_FILE"
check "approval: once decided, the bell is gone" '[ -z "$(badge)" ]'
/bin/rm -f "$APPROVAL_FILE"
LBEFORE="$(notices lead "Permission request")"
WOLFMUX_INBOX_APPROVAL_GRACE=2 teamctl policy worker-permissions lead >/dev/null 2>&1
sleep 1
teamctl spawn probe flash --no-kickoff >/dev/null 2>&1
sleep 2
# The real approval path needs a worker actually asking, so this reaches below it and drives
# the CLI: `teamctl nudge lead` (cmd_nudge -> _nudge_one). That is also the point the check
# below makes — a BEADS notice is not an approval, so the grace override has to leave it
# waiting for the pane however the approval knobs are set: the grace period belongs to the
# approval that blocks a worker, and nothing else may borrow it.
(
  cd "$PROJECT" || exit 1
  WOLFMUX_INBOX_APPROVAL_GRACE=2 WOLFMUX_INBOX_APPROVAL_TYPE=grace \
    teamctl nudge lead --id grace-probe >/dev/null 2>&1
)
check "approval: a bead notice does not borrow the approval grace, so nothing is typed" '[ "$(notices lead "Permission request")" = "$LBEFORE" ] && ! teamctl capture lead --all | grep -q "grace-probe"'
teamctl policy worker-permissions skip >/dev/null 2>&1
sleep 1
teamctl inbox --all >/dev/null 2>&1

echo "== no client attached: the lead IS typed into, exactly as v1.14.0 did it, under the default policy"
# The region above left a half-typed line in the lead pane and a waiter behind it. Both
# have to go, or the next notice joins that marker instead of being typed into the pane.
tmx send-keys -t "$LEAD_PANE" Enter >/dev/null 2>&1
/bin/rm -rf "$(pending_dir lead)"
sleep 1
detach_client
sleep 1
unset WOLFMUX_HUMAN_PANE_TYPING # the v1.16.1 region ends: the default policy, off, again
check "setup: no client is attached now" '[ "$(clients)" = "0" ]'
: >"$WOLFMUX_NOTIFY_TTY"
/bin/rm -f "$INBOX/.stall.lead"
BEFORE="$(notices lead "Beads update for lead")"
teamctl nudge lead --id typed-1 >"$WORK/typed-1.log" 2>&1
TYPED_STATUS=$?
sleep 2
check "detached lead: delivered at once (exit 0), and the message says notified" '[ "$TYPED_STATUS" -eq 0 ] && grep -q "notified: lead" "$WORK/typed-1.log"'
check "detached lead: the notice really is in the pane, naming its bead" 'teamctl capture lead --all | grep -q "Beads update for lead (typed-1)"'
check "detached lead: and it is in the file as well, so nothing depends on the typing" 'grep -q "typed-1" "$(inbox_file lead)"'
check "detached lead: no banner for a notice that reached the agent" '[ "$(banners)" = "0" ]'
# Typing IS delivery. Without marking it, the Stop hook would hand the same notice over a
# second time at the end of the next turn, and "nothing is delivered twice" is a property
# this project asserts for every other path.
check "detached lead: the typed notice is marked delivered, so no hook repeats it" 'teamctl inbox lead --keep --json | jq -e "[.[] | select(.text | test(\"typed-1\")) | .delivered] == [true]"'
check "detached lead: and the Stop hook therefore has nothing to say about it" '! hook lead _inbox-stop | grep -q "typed-1"'
check "detached lead: the human's count still rose, because typing is not reading" 'teamctl inbox lead --keep --json | jq -e "[.[] | select(.text | test(\"typed-1\")) | .new] == [true]"'
echo "== one logical Beads change fires several hooks: the count must not treble"
teamctl inbox --all >/dev/null 2>&1
WOLFMUX_NUDGE_DEBOUNCE=30 WOLFMUX_NUDGE_TYPE=off teamctl nudge lead --id dedupe-1 >/dev/null 2>&1
WOLFMUX_NUDGE_DEBOUNCE=30 WOLFMUX_NUDGE_TYPE=off teamctl nudge lead --id dedupe-1 >/dev/null 2>&1
WOLFMUX_NUDGE_DEBOUNCE=30 WOLFMUX_NUDGE_TYPE=off teamctl nudge lead --id dedupe-1 >/dev/null 2>&1
check "dedupe: three events for the SAME bead file one line, so the count reads 1" '[ "$(grep -c "dedupe-1" "$(inbox_file lead)")" = "1" ] && [ "$(notices_new)" = "1" ]'
WOLFMUX_NUDGE_DEBOUNCE=30 WOLFMUX_NUDGE_TYPE=off teamctl nudge lead --id dedupe-2 >/dev/null 2>&1
check "dedupe: a DIFFERENT bead is never collapsed away" '[ "$(notices_new)" = "2" ] && grep -q "dedupe-2" "$(inbox_file lead)"'
teamctl inbox --all >/dev/null 2>&1

echo "== a notice survives a waiter that died: the typed path lost it, the file did not"
tmx send-keys -t "$PANE" -l "half typed line"
sleep 0.5
teamctl nudge qa --id survive-1 >"$WORK/survive-1.log" 2>&1
SURVIVE_STATUS=$?
check "killed waiter: the notice was parked, because the pane holds a half-typed line" '[ "$SURVIVE_STATUS" -eq 3 ] && [ -d "$(pending_dir qa)" ]'
/bin/rm -rf "$(pending_dir qa)" # exactly what a waiter that was killed leaves behind
check "killed waiter: the parked notice is gone from the typed path" '[ ! -d "$(pending_dir qa)" ]'
check "killed waiter: the file still has it, new and undelivered" 'teamctl inbox qa --keep | grep -q "survive-1"'
check "killed waiter: and the agent is still given it by its own Stop hook" 'hook qa _inbox-stop | stop_body | grep -q "survive-1"'
tmx send-keys -t "$PANE" Enter
sleep 0.5

echo "== the file itself: one line per notice, capped, and safe to append to"
LONG="$(printf 'x%.0s' $(seq 1 900))"
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  inbox_add cap "beads" "$LONG"
  inbox_add cap "beads" "$(printf 'a\tb\nc')"
  [ "$(wc -l <"$STATE_DIR/inbox/cap" | tr -d ' ')" = "2" ] || exit 1
  # the long text was cut, and the tab and newline never reached the record
  awk -F'\t' 'NF != 4 { exit 1 }' "$STATE_DIR/inbox/cap" || exit 1
  # 400 characters plus the ellipsis, which this awk counts as its three UTF-8 bytes
  [ "$(awk -F'\t' 'NR == 1 { print length($4) }' "$STATE_DIR/inbox/cap")" -le 403 ] || exit 1
  [ "$(awk -F'\t' 'NR == 1 { print length($4) }' "$STATE_DIR/inbox/cap")" -ge 400 ] || exit 1
  i=0
  while [ "$i" -lt 300 ]; do
    inbox_add cap "beads" "line $i"
    i=$((i + 1))
  done
  [ "$(wc -l <"$STATE_DIR/inbox/cap" | tr -d ' ')" -le 250 ] || exit 1
  exit 0
) >/dev/null 2>&1
FILE_STATUS=$?
check "the file: one line per notice, tabs and newlines stripped, long text cut, capped" '[ "$FILE_STATUS" -eq 0 ]'

echo "== who is typed into: every combination of the knob, the role and the family"
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  SESSION="irrelevant"
  FAMILY="claude"
  reg_field() { [ "$2" = "family" ] && printf '%s\n' "$FAMILY"; }
  # WOLFMUX_INBOX_CLIENTS is the test seam for "is anybody watching this team"
  want() { # <expect 0|1> <role> <nudge-type> <clients> <family>
    WOLFMUX_NUDGE_TYPE="$3" WOLFMUX_INBOX_CLIENTS="$4" FAMILY="$5"
    if inbox_type_allowed "$2"; then [ "$1" = "0" ]; else [ "$1" = "1" ]; fi
  }
  # off: nobody, ever, not even Codex
  want 1 lead off 0 claude || exit 1
  want 1 qa off 0 claude || exit 1
  want 1 lead off 1 codex || exit 1
  # all: everybody, watched or not — the pre-1.15.0 behaviour
  want 0 lead all 1 claude || exit 1
  want 0 qa all 1 claude || exit 1
  # workers: never the lead, whoever is watching
  want 0 qa workers 0 claude || exit 1
  want 1 lead workers 0 claude || exit 1
  want 1 lead workers 1 claude || exit 1
  # detached-lead, the default: the lead only while nobody is attached
  want 0 qa detached-lead 1 claude || exit 1
  want 0 lead detached-lead 0 claude || exit 1
  want 1 lead detached-lead 1 claude || exit 1
  # Codex has no hooks, so typing is the only channel that reaches it at all
  want 0 lead detached-lead 1 codex || exit 1
  want 0 lead workers 1 codex || exit 1
  # inbox_type_when_idle: which NO means "wait for the pane", and which means "never".
  # Only the attached lead under the default rule waits; off and workers mean never, or
  # a knob called off would still put a line in the human's conversation.
  when() { # <expect 0|1> <role> <nudge-type>
    WOLFMUX_NUDGE_TYPE="$3"
    if inbox_type_when_idle "$2"; then [ "$1" = "0" ]; else [ "$1" = "1" ]; fi
  }
  when 0 lead detached-lead || exit 1
  when 1 qa detached-lead || exit 1
  when 1 lead off || exit 1
  when 1 lead workers || exit 1
  when 1 lead all || exit 1
  # nonsense in the knob falls back to the default, it does not turn the gate off
  WOLFMUX_NUDGE_TYPE=junk
  . "$WOLFMUX_HOME/lib/inbox.sh"
  [ "$WOLFMUX_NUDGE_TYPE" = "detached-lead" ] || exit 1
  exit 0
) >/dev/null 2>&1
MATRIX_STATUS=$?
check "who is typed into: off/workers/detached-lead/all x lead/worker x claude/codex" '[ "$MATRIX_STATUS" -eq 0 ]'
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  # A tmux read that fails tells us nothing, and "nobody is watching" is the answer
  # that puts a line in the human's conversation. So it fails CLOSED: attached.
  unset WOLFMUX_INBOX_CLIENTS
  inbox_clients_attached "no-such-session-$$" || exit 1
  TMUX_BIN=""
  inbox_clients_attached "$SESSION" || exit 1
  exit 0
) >/dev/null 2>&1
CLOSED_STATUS=$?
check "is anybody watching: a tmux read we cannot make sense of counts as attached" '[ "$CLOSED_STATUS" -eq 0 ]'
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/policy.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  SESSION="irrelevant"
  unset WOLFMUX_INBOX_WATCHED
  # v1.20.0, fail CLOSED: a tmux that errors says "a human is watching", so nothing is typed
  tmx() { return 1; }
  tm_pane_watched "%7" || exit 1
  tm_pane_watched "" || exit 1
  WOLFMUX_INBOX_CLIENTS=0
  inbox_human_pane qa "%7" || exit 1
  TMUX_BIN=""
  inbox_human_pane qa "%7" || exit 1
  # a tmux that answers: only the panes on a client's screen are watched
  TMUX_BIN=/usr/bin/true
  tmx() { printf '%%3\n%%9\n'; }
  tm_pane_watched "%3" || exit 1
  tm_pane_watched "%31" && exit 1
  inbox_human_pane qa "%5" && exit 1
  # a shown pane whose client record carries no readable keystroke time: in use (fail closed)
  inbox_human_pane qa "%3" || exit 1
  # v1.23.0 (issue #34): the lead's pane of an attached team is NOT watched by that alone
  WOLFMUX_INBOX_CLIENTS=1
  inbox_human_pane lead "%5" && exit 1
  inbox_human_pane qa "%5" && exit 1
  # the seam, and its error word
  WOLFMUX_INBOX_WATCHED="%2 %4"
  inbox_human_pane qa "%4" || exit 1
  inbox_human_pane qa "%5" && exit 1
  WOLFMUX_INBOX_WATCHED=error
  inbox_human_pane qa "%5" || exit 1
  # the policy: off (also unset, or nonsense) keeps off the pane; idle lets the old rule decide
  policy_get() { printf '%s\n' "${FAKE_POLICY:-}"; }
  FAKE_POLICY=off inbox_keep_off_human_pane qa "%5" || exit 1
  FAKE_POLICY="" inbox_keep_off_human_pane qa "%5" || exit 1
  FAKE_POLICY=idle inbox_keep_off_human_pane qa "%5" && exit 1
  unset -f policy_get
  . "$WOLFMUX_HOME/lib/policy.sh" # the real one back, for the last question
  [ "$(WOLFMUX_HUMAN_PANE_TYPING=junk policy_get human-pane-typing)" = "off" ] || exit 1
  exit 0
) >/dev/null 2>&1
HUMAN_CLOSED_STATUS=$?
check "a human's pane: a tmux error, no tmux, or the error seam all read as watched; only shown panes count; nonsense policy is off" '[ "$HUMAN_CLOSED_STATUS" -eq 0 ]'
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/policy.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  unset WOLFMUX_INBOX_WATCHED WOLFMUX_INBOX_CLIENTS WOLFMUX_INBOX_CLIENT_LIST WOLFMUX_WATCH_QUIET
  NOW="$(date +%s)" OLD=$(($(date +%s) - 600)) RECENT=$(($(date +%s) - 40))
  # 1. the seam: shown + focused, shown + a recent key, shown + neither, not shown, error
  WOLFMUX_INBOX_CLIENT_LIST="%7|attached,focused,UTF-8|$OLD"
  tm_pane_in_use %7 || exit 1
  case "$TM_IN_USE_WHY" in *"has focus"*) ;; *) exit 1 ;; esac
  WOLFMUX_INBOX_CLIENT_LIST="%7|attached,UTF-8|$RECENT"
  tm_pane_in_use %7 || exit 1
  case "$TM_IN_USE_WHY" in *"keystroke 4"*"s ago"*) ;; *) exit 1 ;; esac
  WOLFMUX_INBOX_CLIENT_LIST="%7|attached,UTF-8|$OLD"
  tm_pane_in_use %7 && exit 1
  WOLFMUX_INBOX_CLIENT_LIST="%3|attached,focused,UTF-8|$NOW %9|attached|$NOW"
  tm_pane_in_use %7 && exit 1
  WOLFMUX_INBOX_CLIENT_LIST="error"
  tm_pane_in_use %7 || exit 1
  # "focused" is a whole flag, not a substring of another one
  WOLFMUX_INBOX_CLIENT_LIST="%7|attached,unfocused-ish|$OLD"
  tm_pane_in_use %7 && exit 1
  # two clients on one pane: either one in use is enough
  WOLFMUX_INBOX_CLIENT_LIST="%7|attached|$OLD %7|attached,focused|$OLD"
  tm_pane_in_use %7 || exit 1
  # 2. fail closed: no pane id, a keystroke time that is not a number
  WOLFMUX_INBOX_CLIENT_LIST="%7|attached|$OLD"
  tm_pane_in_use "" || exit 1
  WOLFMUX_INBOX_CLIENT_LIST="%7|attached|"
  tm_pane_in_use %7 || exit 1
  # 3. WOLFMUX_WATCH_QUIET is the keystroke window; nonsense falls back to 120
  WOLFMUX_INBOX_CLIENT_LIST="%7|attached|$RECENT"
  WOLFMUX_WATCH_QUIET=30 tm_pane_in_use %7 && exit 1
  WOLFMUX_WATCH_QUIET=junk tm_pane_in_use %7 || exit 1
  #    WOLFMUX_WATCH_FOCUS_MAX: 0 (the default) = focus counts with no limit; above 0, focus
  #    counts only with a key that recent (a tab attached in the background reads focused)
  WOLFMUX_INBOX_CLIENT_LIST="%7|attached,focused|$OLD"
  WOLFMUX_WATCH_FOCUS_MAX=0 tm_pane_in_use %7 || exit 1
  WOLFMUX_WATCH_FOCUS_MAX=300 tm_pane_in_use %7 && exit 1
  WOLFMUX_WATCH_FOCUS_MAX=junk tm_pane_in_use %7 || exit 1
  WOLFMUX_INBOX_CLIENT_LIST="%7|attached,focused|$((NOW - 200))"
  WOLFMUX_WATCH_FOCUS_MAX=300 tm_pane_in_use %7 || exit 1
  case "$TM_IN_USE_WHY" in *"has focus and a key was pressed"*) ;; *) exit 1 ;; esac
  WOLFMUX_INBOX_CLIENT_LIST="%7|attached|$((NOW - 200))"
  WOLFMUX_WATCH_FOCUS_MAX=300 tm_pane_in_use %7 && exit 1
  # 4. the real read: ONE list-clients with the three fields, for every client of the server;
  #    a read that fails is in use
  unset WOLFMUX_INBOX_CLIENT_LIST
  CALLS="$WORK/in-use.calls"
  : >"$CALLS"
  tmx() { printf '%s\n' "$*" >>"$CALLS"; printf '%%7|attached,UTF-8|%s\n%%8|attached,focused|%s\n' "$OLD" "$OLD"; }
  tm_pane_in_use %7 && exit 1
  tm_pane_in_use %8 || exit 1
  [ "$(wc -l <"$CALLS" | tr -d ' ')" = "2" ] || exit 1
  grep -qx 'list-clients -F #{pane_id}|#{client_flags}|#{client_activity}' "$CALLS" || exit 1
  tmx() { return 1; }
  tm_pane_in_use %7 || exit 1
  # 5. inbox_human_pane is that question now, for the lead too, attached or not
  TMUX_BIN=/usr/bin/true WOLFMUX_INBOX_CLIENTS=1 SESSION=irrelevant
  WOLFMUX_INBOX_CLIENT_LIST="%5|attached,UTF-8|$OLD"
  inbox_human_pane lead %5 && exit 1
  WOLFMUX_INBOX_CLIENT_LIST="%5|attached,focused|$OLD"
  inbox_human_pane lead %5 || exit 1
  case "$INBOX_HUMAN_REASON" in *"has focus"*) ;; *) exit 1 ;; esac
  # 6. what is TYPED (policy off): a pane in use never; a Claude-family LEAD's pane never while
  #    a client is attached, in use or not; a Codex lead's and a worker's only while not in use
  FAMILY=claude
  reg_field() { [ "$2" = "family" ] && printf '%s\n' "$FAMILY"; }
  policy_get() { printf '%s\n' "${FAKE_POLICY:-off}"; }
  WOLFMUX_INBOX_CLIENT_LIST="%5|attached,UTF-8|$OLD"
  inbox_keep_off_human_pane lead %5 || exit 1
  case "$INBOX_HUMAN_REASON" in *"own hooks deliver"*) ;; *) exit 1 ;; esac
  WOLFMUX_INBOX_CLIENTS=0
  inbox_keep_off_human_pane lead %5 && exit 1 # nobody attached: today's detached rule
  WOLFMUX_INBOX_CLIENTS=1
  FAMILY=codex
  inbox_keep_off_human_pane lead %5 && exit 1
  WOLFMUX_INBOX_CLIENT_LIST="%5|attached,focused|$OLD"
  inbox_keep_off_human_pane lead %5 || exit 1
  FAMILY=claude
  inbox_keep_off_human_pane qa %5 || exit 1
  WOLFMUX_INBOX_CLIENT_LIST="%5|attached,UTF-8|$OLD"
  inbox_keep_off_human_pane qa %5 && exit 1
  # under idle the v1.16.1 rule decides, as before: nothing is kept off here
  FAKE_POLICY=idle inbox_keep_off_human_pane lead %5 && exit 1
  exit 0
) >/dev/null 2>&1
IN_USE_STATUS=$?
check "in use (v1.23.0): shown AND (focused or a key within WOLFMUX_WATCH_QUIET); one read; fails closed; the lead's pane by the same rule; a Claude lead is still never typed into while attached" '[ "$IN_USE_STATUS" -eq 0 ]'
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/policy.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  unset WOLFMUX_INBOX_WATCHED WOLFMUX_INBOX_CLIENTS
  CALLS="$WORK/stop-pane.calls"
  : >"$CALLS"
  TMUX_BIN=/usr/bin/true
  tmx() {
    printf '%s\n' "$*" >>"$CALLS"
    case "$1" in
      display-message) printf '%s\n' "$FAKE_READ" ;;
      list-clients) printf '%s\n' "$FAKE_SHOWN" ;;
      *) return 1 ;;
    esac
  }
  policy_get() { printf '%s\n' "$FAKE_POLICY"; }
  INBOX_ROLE=qa FAKE_POLICY=off FAKE_SHOWN="" SESSION=team-x
  # The pane proof, one tmux read: "<pane pid>|<@ai_role>|<@wolfmux_team>|<session>". tests/fake-ps
  # makes pid 4242 this shell's parent ($$ is the suite's shell here too).
  export WOLFMUX_PS_BIN="$REPO/tests/fake-ps" WOLFMUX_FAKE_PS_GRAFT="$$:4242"
  # 1. TMUX_PANE, a pane of the team's server, this role, this session, its process among our parents
  TMUX="/tmp/tmux-1/$WOLFMUX_TMUX_SOCKET,1,0" TMUX_PANE=%7 FAKE_READ="4242|qa|default|team-x"
  identity_in_own_pane qa team-x || exit 1
  [ "$IDENTITY_PANE_ROLE" = "qa" ] && [ "$IDENTITY_SESSION" = "team-x" ] && [ "$IDENTITY_TEAM" = "default" ] || exit 1
  [ "$(grep -c display-message "$CALLS")" = "1" ] || exit 1 # ONE read
  # 2. another role's pane, no agent's pane, another session, another pane's process: no
  FAKE_READ="4242|lead|default|team-x"
  identity_in_own_pane qa team-x && exit 1
  case "$IDENTITY_WHY" in *"lead's, not qa's"*) ;; *) exit 1 ;; esac
  FAKE_READ="4242||default|team-x"
  identity_in_own_pane qa team-x && exit 1
  case "$IDENTITY_WHY" in *"no agent's pane"*) ;; *) exit 1 ;; esac
  FAKE_READ="4242|qa|default|team-y"
  identity_in_own_pane qa team-x && exit 1
  case "$IDENTITY_WHY" in *"session team-y"*) ;; *) exit 1 ;; esac
  FAKE_READ="4243|qa|default|team-x"
  identity_in_own_pane qa team-x && exit 1
  case "$IDENTITY_WHY" in *"not among its parents"*) ;; *) exit 1 ;; esac
  # 3. a pane of ANOTHER tmux server is not even read, and neither is a missing TMUX_PANE
  : >"$CALLS"
  TMUX="/tmp/tmux-1/default,1,0" FAKE_READ="4242|qa|default|team-x"
  identity_in_own_pane qa team-x && exit 1
  TMUX="/tmp/tmux-1/$WOLFMUX_TMUX_SOCKET,1,0"
  unset TMUX_PANE
  identity_in_own_pane qa team-x && exit 1
  [ "$IDENTITY_WHY" = "no TMUX_PANE" ] && ! grep -q display-message "$CALLS" || exit 1
  # 4. the proven pane on nobody's screen: not watched, so the hook answers as it always did;
  #    on a client's screen: watched
  INBOX_PANE=%7
  FAKE_SHOWN="%3"
  _inbox_stop_watched && exit 1
  FAKE_SHOWN="%7"
  _inbox_stop_watched || exit 1
  # v1.23.0: on a client's screen but in a background tab (no focus, no key for 10 min): a
  #    worker's Stop hook speaks. A Claude lead's stays silent while a client is attached
  #    (its waiter hands them over: a Stop hook prints them in full), in use or not, under
  #    either policy. A Codex lead's speaks, and with nobody attached the lead's does too.
  FAKE_SHOWN="%7|attached,UTF-8|$(($(date +%s) - 600))"
  _inbox_stop_watched && exit 1
  INBOX_ROLE=lead WOLFMUX_INBOX_CLIENTS=1
  _inbox_stop_watched || exit 1
  case "$INBOX_HUMAN_REASON" in *"wake waiter hands"*) ;; *) exit 1 ;; esac
  FAKE_POLICY=idle _inbox_stop_watched || exit 1
  WOLFMUX_INBOX_CLIENTS=0
  _inbox_stop_watched && exit 1
  WOLFMUX_INBOX_CLIENTS=1
  reg_field() { [ "$2" = "family" ] && printf 'codex\n'; }
  _inbox_stop_watched && exit 1
  unset -f reg_field
  . "$WOLFMUX_HOME/lib/registry.sh"
  FAKE_SHOWN="%7|attached,focused,UTF-8|$(($(date +%s) - 600))"
  _inbox_stop_watched || exit 1
  INBOX_ROLE=qa
  unset WOLFMUX_INBOX_CLIENTS
  # 5. no pane: that reads as WATCHED (fail closed), for a worker and for the lead alike
  INBOX_PANE="" FAKE_SHOWN="%3"
  _inbox_stop_watched || exit 1
  INBOX_ROLE=lead
  _inbox_stop_watched || exit 1
  # 6. policy idle (v1.22.1): the same answers as off. tmux IS asked, a pane on a client's
  #    screen is watched, and one on nobody's screen is not
  : >"$CALLS"
  FAKE_POLICY=idle FAKE_SHOWN="%7" INBOX_ROLE=qa INBOX_PANE=%7
  _inbox_stop_watched || exit 1
  grep -q list-clients "$CALLS" || exit 1
  FAKE_SHOWN="%3"
  _inbox_stop_watched && exit 1
  exit 0
) >/dev/null 2>&1
STOP_PANE_STATUS=$?
check "the pane proof: this role's pane of this session on this server, its process among our parents, one read; no pane reads as watched; idle watches the same panes" '[ "$STOP_PANE_STATUS" -eq 0 ]'
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/policy.sh"
  . "$WOLFMUX_HOME/lib/approvals.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  . "$WOLFMUX_HOME/lib/brand.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  . "$WOLFMUX_HOME/lib/agents.sh"
  STATE_DIR="$WORK/human-approval"
  /bin/mkdir -p "$STATE_DIR/inbox"
  SESSION="irrelevant" WOLFMUX_INBOX_CLIENTS=1 WOLFMUX_INBOX_STALL_NOTIFY=off
  tm_pane_for_role() { printf '%%1\n'; }
  tm_pane_state() { printf 'running\n'; }
  _notify_type_or_park() { printf '%s\n' "$3" >>"$WORK/human-approval.typed"; }
  : >"$WORK/human-approval.typed"
  # an approval with APPROVAL_TYPE=always, the loudest setting there is: under the default
  # policy the attached lead's pane still gets nothing typed, and it is filed
  rc=0
  WOLFMUX_INBOX_APPROVAL_TYPE=always notify_lead approval A1 qa || rc=$?
  [ "$rc" -eq 4 ] && [ ! -s "$WORK/human-approval.typed" ] || exit 1
  grep -q "Permission request A1 from qa" "$STATE_DIR/inbox/lead" || exit 1
  # and under idle, the v1.16.1 override is back: typed at once
  WOLFMUX_HUMAN_PANE_TYPING=idle WOLFMUX_INBOX_APPROVAL_TYPE=always notify_lead approval A2 qa || true
  grep -q "A2" "$WORK/human-approval.typed" || exit 1
  exit 0
) >/dev/null 2>&1
HUMAN_APPROVAL_STATUS=$?
check "a human's pane: even an approval with APPROVAL_TYPE=always is filed, not typed; under idle it is typed" '[ "$HUMAN_APPROVAL_STATUS" -eq 0 ]'

echo "== WOLFMUX_NUDGE_TYPE=all brings the pre-1.15.0 behaviour back, under policy idle only"
attach_client
tmx select-pane -t "$PANE" >/dev/null 2>&1
sleep 4
BEFORE="$(notices lead "Beads update for lead")"
WOLFMUX_NUDGE_TYPE=all teamctl nudge lead --id all-off-1 >/dev/null 2>&1
ALL_OFF_STATUS=$?
sleep 2
check "WOLFMUX_NUDGE_TYPE=all under the default policy: the attached lead is still not typed into" '[ "$ALL_OFF_STATUS" -eq 4 ] && [ "$(notices lead "Beads update for lead")" = "$BEFORE" ] && ! teamctl capture lead --all | grep -q "all-off-1"'
WOLFMUX_HUMAN_PANE_TYPING=idle WOLFMUX_NUDGE_TYPE=all teamctl nudge lead --id all-1 >/dev/null 2>&1
ALL_STATUS=$?
sleep 2
check "WOLFMUX_NUDGE_TYPE=all + human-pane-typing idle: typed into an attached lead pane again" '[ "$ALL_STATUS" -eq 0 ] && teamctl capture lead --all | grep -q "Beads update for lead (all-1)"'
BEFORE="$(notices lead "Beads update for lead")"
WOLFMUX_NUDGE_TYPE=off teamctl nudge qa --id none-1 >/dev/null 2>&1
sleep 2
check "WOLFMUX_NUDGE_TYPE=off: not even a worker is typed into, and it is still filed" '! teamctl capture qa --all | grep -q "none-1" && grep -q "none-1" "$(inbox_file qa)"'
detach_client

echo "== the popup key, and the session option the two tmux format strings need"
check "tmux: prefix N is bound, and to a popup (via run-shell and teamctl _popup, v1.20.1) that runs the inbox" 'tmx list-keys -T prefix 2>/dev/null | grep -E "^bind-key +-T prefix +N " | grep -q "run-shell -b .* _popup "'
check "tmux: prefix I was left alone, so a sourced ~/.tmux.conf keeps it" '! tmx list-keys -T prefix 2>/dev/null | grep -qE "^bind-key +-T prefix +I .*inbox"'
check "tmux: prefix T still re-tiles, so the key that was there already is untouched" 'tmx list-keys -T prefix 2>/dev/null | grep -qE "^bind-key +-T prefix +T +select-layout"'
check "tmux: the session knows where teamctl is, so the badge and the popup can run it" '[ -x "$(tmx show-options -t "=$SESSION:" -qv @wolfmux_teamctl)" ]'
check "tmux: status-interval is 5, so the count is never more than 5 s stale" '[ "$(tmx show-options -gqv status-interval)" = "5" ]'
check "tmux: status-left calls the badge" 'tmx show-options -gqv status-left | grep -q "_inbox-badge"'
check "tmux: prefix N opens the human's messages, not the pane notices" 'tmx list-keys -T prefix 2>/dev/null | grep -E "^bind-key +-T prefix +N " | grep -q "_human-inbox\"$"'
check "tmux: the badge is wrapped in the inbox range, and the rest of status-left is the left range again" 'tmx show-options -gqv status-left | grep -qF "#[range=user|inbox]#(" && tmx show-options -gqv status-left | grep -qF "#[norange range=left]"'
MOUSE_BINDING="$(tmx list-keys -T root 2>/dev/null | grep -E "^bind-key +-T root +MouseDown1Status ")"
check "tmux: a click opens the messages popup only on the inbox range" 'printf "%s" "$MOUSE_BINDING" | grep -qF "if-shell -F \"#{==:#{mouse_status_range},inbox}\" { run-shell -b" && printf "%s" "$MOUSE_BINDING" | grep -qF " _popup " && printf "%s" "$MOUSE_BINDING" | grep -qF "_human-inbox"'
check "tmux: every other status click still does tmux's default, switch-client -t =" 'printf "%s" "$MOUSE_BINDING" | grep -qE "\} \{ switch-client -t = \}$"'
echo "== the badge END TO END: the shipped status-left really runs it, and its output draws"
# Three things are needed together and all three were learned the hard way: a REAL pty
# client (with none, tmux never runs the #() job at all), time plus a forced refresh (one
# interval is not enough), and a LITERAL MARKER grepped out of the typescript. Do NOT try
# to read the result back through #{E:...} or #{T:...}: both come back empty even in a run
# that demonstrably rendered, so they are a dead end as verification.
# v1.20.0: what it draws is the human's unread messages (one row in the index the Beads
# hook keeps) and the bell of a pending request (a request file of its own).
printf 'render-1\037comms.lead\037Render check\037%s\n' "$(date +%s)" >"$STATE_DIR/human-inbox"
/bin/mkdir -p "$STATE_DIR/approvals"
printf '{\n  "id": "A909",\n  "status": "pending"\n}\n' >"$STATE_DIR/approvals/A909.json"
RENDER_TTY="$WORK/render-typescript"
tmx set-option -t "$SESSION" status-interval 1 >/dev/null 2>&1
# The same spelling the shipped file uses, with a marker around it so the segment can be
# told apart from anything else tmux draws.
tmx set-option -g status-left 'WOLFBADGE[#("#{?@wolfmux_teamctl,#{@wolfmux_teamctl},teamctl}" _inbox-badge "#{session_name}" "#{@wolfmux_root}" "#{@wolfmux_team}")]' >/dev/null 2>&1
tmx set-option -g status-left-length 120 >/dev/null 2>&1
script -q "$RENDER_TTY" tmux -L "$WOLFMUX_TMUX_SOCKET" attach -t "$SESSION" >/dev/null 2>&1 &
RENDER_PID=$!
disown "$RENDER_PID" 2>/dev/null || true
sleep 5
tmx refresh-client >/dev/null 2>&1
sleep 3
kill "$RENDER_PID" 2>/dev/null
sleep 1
check "badge end to end: the segment ran and its output is in the drawn status line" 'grep -ao "WOLFBADGE\[[^]]*\]" "$RENDER_TTY" 2>/dev/null | grep -q "📨"'
check "badge end to end: the count and the approval bell are what was drawn" 'grep -ao "WOLFBADGE\[[^]]*\]" "$RENDER_TTY" 2>/dev/null | grep -q "📨 1 🔔"'
# The honest other half of the same measurement, and a documented limit: tmux draws the
# status line BEFORE the job has produced anything, so the first draw is empty.
check "badge end to end: the first draw is blank, which is why ROADMAP carries that limit" 'grep -aq "WOLFBADGE\[\]" "$RENDER_TTY"'
# F9 -- and now the case the quoting is FOR: a teamctl whose own path contains a space.
# $TEAMCTL_SELF is an absolute path built from `dirname $0`, so an install under
# `~/My bin/` used to split into two words. The badge swallows every error by design, so
# the symptom was a blank badge for ever and a popup saying `My: command not found` --
# silently absent and undebuggable. Same pty-client harness, because nothing else proves
# a #() job ran.
SPACED_DIR="$WORK/My bin"
/bin/mkdir -p "$SPACED_DIR"
printf '#!/bin/sh\nexec "%s/bin/teamctl" "$@"\n' "$REPO" >"$SPACED_DIR/teamctl"
chmod +x "$SPACED_DIR/teamctl"
tmx set-option -t "=$SESSION:" @wolfmux_teamctl "$SPACED_DIR/teamctl" >/dev/null 2>&1
printf 'spaced-1\037comms.lead\037Spaced check\037%s\n' "$(date +%s)" >>"$STATE_DIR/human-inbox"
RENDER_TTY2="$WORK/render-typescript-spaced"
tmx set-option -t "$SESSION" status-interval 1 >/dev/null 2>&1
tmx set-option -g status-left 'WOLFSPACED[#("#{?@wolfmux_teamctl,#{@wolfmux_teamctl},teamctl}" _inbox-badge "#{session_name}" "#{@wolfmux_root}" "#{@wolfmux_team}")]' >/dev/null 2>&1
tmx set-option -g status-left-length 120 >/dev/null 2>&1
script -q "$RENDER_TTY2" tmux -L "$WOLFMUX_TMUX_SOCKET" attach -t "$SESSION" >/dev/null 2>&1 &
RENDER_PID2=$!
disown "$RENDER_PID2" 2>/dev/null || true
sleep 5
tmx refresh-client >/dev/null 2>&1
sleep 3
kill "$RENDER_PID2" 2>/dev/null
sleep 1
check "F9: a teamctl path with a space still runs the badge (quoted program field)" 'grep -ao "WOLFSPACED\[[^]]*\]" "$RENDER_TTY2" 2>/dev/null | grep -q "📨"'
tmx set-option -t "=$SESSION:" @wolfmux_teamctl "$REPO/bin/teamctl" >/dev/null 2>&1
tmx set-option -gu status-left >/dev/null 2>&1
tmx set-option -t "$SESSION" status-interval 5 >/dev/null 2>&1
teamctl inbox --all >/dev/null 2>&1
/bin/rm -f "$STATE_DIR/human-inbox" "$STATE_DIR/approvals/A909.json"

echo "== the eight findings of the v1.15.0 review, each asserted against its own mechanism"

# F2 -- off MEANS off. The matrix above tests inbox_type_allowed directly, and the
# approval override never passes through it, so the matrix was exhaustive and blind at
# the same time. This drives `teamctl nudge lead` (cmd_nudge -> _nudge_one) with a client
# attached, so the knob and the override are read on the live path instead of in isolation.
attach_client
sleep 1
: >"$WOLFMUX_NOTIFY_TTY"
teamctl inbox --all >/dev/null 2>&1
/bin/rm -f "$WOLFMUX_DATA/.stall.lead" "$INBOX/.stall.lead"
OFF_BEFORE="$(notices lead "Beads update for lead")"
OFF_FILED="$(inbox_count_new_of lead)"
(
  cd "$PROJECT" || exit 1
  WOLFMUX_NUDGE_TYPE=off WOLFMUX_INBOX_APPROVAL_TYPE=always \
    teamctl nudge lead --id off-approval >"$WORK/off.log" 2>&1
)
sleep 2
check "F2: nudge-type=off types NOTHING into an attached lead, approval or not" '[ "$(notices lead "Beads update for lead")" = "$OFF_BEFORE" ]'
check "F2: off still FILES the notice, so being silent loses nothing" '[ "$(inbox_count_new_of lead)" -gt "$OFF_FILED" ]'
check "F2: and it says so: exit 4, filed, not typed" 'grep -q "filed" "$WORK/off.log"'

# F3 -- the badge counted its own temp files as roles, because every one of them was a
# non-dot sibling of the record holding a COPY of it. One notice read as 3.
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  STATE_DIR="$WORK/f3"
  /bin/mkdir -p "$STATE_DIR/inbox"
  printf '%s\tbeads\tnu\tone real notice\n' "$(now_epoch)" >"$STATE_DIR/inbox/lead"
  # the temp files as they are written now
  cp "$STATE_DIR/inbox/lead" "$(inbox_tmp lead taken)"
  cp "$STATE_DIR/inbox/lead" "$(inbox_tmp lead texts)"
  # and as they used to be written, to prove the glob filter catches them too
  cp "$STATE_DIR/inbox/lead" "$STATE_DIR/inbox/lead.taken.4242"
  reg_list() { printf 'lead\n'; }
  total=0
  for r in $(inbox_roles); do total=$((total + $(inbox_count_new "$r"))); done
  [ "$total" = "1" ] || exit 1
  inbox_roles | grep -q '\.taken\.' && exit 1
  exit 0
) >/dev/null 2>&1
F3_STATUS=$?
check "F3: temp files are dotfiles AND non-role names are filtered, so ONE notice counts 1" '[ "$F3_STATUS" -eq 0 ]'

# F1 -- a read-modify-write whose awk cannot write must change nothing. Measured by the
# reviewer at 40,000 records in and 11,773 out when awk died part-way.
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  STATE_DIR="$WORK/f1"
  /bin/mkdir -p "$STATE_DIR/inbox"
  i=1
  while [ $i -le 200 ]; do
    printf '%s\tbeads\tnu\tnotice %s\n' "$(now_epoch)" "$i" >>"$STATE_DIR/inbox/lead"
    i=$((i + 1))
  done
  # every temp path now points somewhere unwritable, which is what ENOSPC looks like here
  inbox_tmp() { printf '%s\n' "$STATE_DIR/inbox/no-such-dir/.tmp.$1.$2.$$"; }
  out="$(inbox_take_undelivered lead)"
  [ -z "$out" ] || exit 1                                    # nothing handed over
  [ "$(wc -l <"$STATE_DIR/inbox/lead" | tr -d ' ')" = "200" ] || exit 1   # record intact
  [ "$(LC_ALL=C /usr/bin/awk -F'\t' 'substr($3,2,1)=="u"' "$STATE_DIR/inbox/lead" | wc -l | tr -d ' ')" = "200" ] || exit 1
  exit 0
) >/dev/null 2>&1
F1_STATUS=$?
check "F1: an awk that cannot write destroys nothing and hands nothing over" '[ "$F1_STATUS" -eq 0 ]'

# F6 -- the create+update collapse has to survive another notice landing between the two.
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  STATE_DIR="$WORK/f6"
  # the suite exports WOLFMUX_NUDGE_DEBOUNCE=0 so that its own nudges are never
  # collapsed; the dedupe needs a real window to be testable at all
  WOLFMUX_NUDGE_DEBOUNCE=30
  /bin/mkdir -p "$STATE_DIR/inbox"
  inbox_add lead beads "task A assigned"
  inbox_add lead beads "task B assigned"
  inbox_add lead beads "task A assigned"     # A-update, no longer adjacent to A-create
  [ "$(wc -l <"$STATE_DIR/inbox/lead" | tr -d ' ')" = "2" ] || exit 1
  [ "$(inbox_count_new lead)" = "2" ] || exit 1
  # and two genuinely different notices are never collapsed into one
  inbox_add lead approval "Permission request A7"
  [ "$(wc -l <"$STATE_DIR/inbox/lead" | tr -d ' ')" = "3" ] || exit 1
  exit 0
) >/dev/null 2>&1
F6_STATUS=$?
check "F6: an interleaved create/update pair still files ONE line, two beads read 2" '[ "$F6_STATUS" -eq 0 ]'

# F7 -- the hooks mark delivered BEFORE they answer, which is what makes the no-loop
# property true. So a failing answer has to put the letters back.
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  STATE_DIR="$WORK/f7"
  /bin/mkdir -p "$STATE_DIR/inbox"
  printf '%s\tbeads\tnu\tnotice one\n%s\tbeads\tnu\tnotice two\n' "$(now_epoch)" "$(now_epoch)" >"$STATE_DIR/inbox/lead"
  INBOX_ROLE=lead INBOX_IDENTITY=lead
  JQ_BIN="$WORK/jq-that-fails"
  printf '#!/bin/sh\nexit 1\n' >"$JQ_BIN"
  chmod +x "$JQ_BIN"
  _inbox_hook_ready() { return 0; }
  # nobody is watching: the answer is attempted (v1.20.0 keeps quiet in a watched pane,
  # and quiet would leave both lines undelivered too, passing this for the wrong reason)
  _inbox_stop_watched() { return 1; }
  cmd_inbox_stop </dev/null >/dev/null 2>&1
  # the answer really was attempted: only that path writes the cooldown stamp
  [ -s "$STATE_DIR/inbox/.stop.lead" ] || exit 1
  # both lines must be undelivered again, or they are lost for good
  [ "$(inbox_count_undelivered lead)" = "2" ] || exit 1
  # and the human's count is untouched by any of it
  [ "$(inbox_count_new lead)" = "2" ] || exit 1
  # v1.20.0: a watched pane takes nothing, prints nothing and writes no stamp
  /bin/rm -f "$STATE_DIR/inbox/.stop.lead"
  JQ_BIN="$(command -v jq)"
  _inbox_stop_watched() { INBOX_HUMAN_REASON="test"; return 0; }
  [ -z "$(cmd_inbox_stop </dev/null 2>/dev/null)" ] || exit 1
  [ ! -e "$STATE_DIR/inbox/.stop.lead" ] || exit 1
  [ "$(inbox_count_undelivered lead)" = "2" ] || exit 1
  exit 0
) >/dev/null 2>&1
F7_STATUS=$?
check "F7: a Stop hook whose answer fails re-queues the notices instead of eating them; a watched pane takes none" '[ "$F7_STATUS" -eq 0 ]'

# F5 -- the grace waiter must watch THIS request. prefix N prints --all and marks every
# role seen, so asking "has this role a new approval" let a glance at a worker's line
# cancel an approval the human had never read.
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  STATE_DIR="$WORK/f5"
  /bin/mkdir -p "$STATE_DIR/inbox"
  inbox_add lead approval "Permission request A7 from backend"
  inbox_is_new lead "Permission request A7 from backend" || exit 1
  inbox_is_new lead "a notice that was never filed" && exit 1
  # the human reads: this request is no longer new
  cmd_inbox lead >/dev/null 2>&1
  ! inbox_is_new lead "Permission request A7 from backend" || exit 1
  # and the test is on the RECORD, not the role: a SECOND request arriving after that
  # read is new while the first stays read, which role-level matching cannot express
  inbox_add lead approval "Permission request B2 from frontend"
  inbox_is_new lead "Permission request B2 from frontend" || exit 1
  ! inbox_is_new lead "Permission request A7 from backend" || exit 1
  exit 0
) >/dev/null 2>&1
F5_STATUS=$?
check "F5: unread-ness is per RECORD, so one request read does not speak for another" '[ "$F5_STATUS" -eq 0 ]'

# F8 -- the stall window is shared by every team on the machine. Per team meant 25 teams
# could ring 25 times in one window, which is this release's own complaint with a sound.
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  # brand.sh too: the banner text carries WOLFMUX_LEAD_MARK, exactly as notify.sh's own
  # body does, and teamctl loads brand before notify and inbox
  . "$WOLFMUX_HOME/lib/brand.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  WOLFMUX_DATA="$WORK/f8data"
  /bin/mkdir -p "$WOLFMUX_DATA"
  notify_deliver() { printf 'ring\n' >>"$WORK/f8.rings"; }
  notify_wanted() { return 0; }
  : >"$WORK/f8.rings"
  # two DIFFERENT teams, each with its own STATE_DIR, inside one window
  for t in alpha beta gamma; do
    STATE_DIR="$WORK/f8-$t"
    /bin/mkdir -p "$STATE_DIR/inbox"
    printf '%s\tbeads\tnu\tnotice for %s\n' "$(now_epoch)" "$t" >"$STATE_DIR/inbox/lead"
    TEAM="$t" inbox_stall_notify lead beads
  done
  [ "$(wc -l <"$WORK/f8.rings" | tr -d ' ')" = "1" ] || exit 1
  exit 0
) >/dev/null 2>&1
F8_STATUS=$?
check "F8: three teams inside one window ring ONCE, not once each" '[ "$F8_STATUS" -eq 0 ]'

# F5 / option A -- the grace timer is cancelled by the request no longer being PENDING,
# not by the human having looked. A glance at the popup unblocks no worker.
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/approvals.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  . "$WOLFMUX_HOME/lib/brand.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  . "$WOLFMUX_HOME/lib/agents.sh"
  STATE_DIR="$WORK/f5a"
  /bin/mkdir -p "$STATE_DIR/inbox"
  WOLFMUX_INBOX_APPROVAL_GRACE=3
  # the pane is always "running", and typing is recorded instead of done
  tm_pane_state() { printf 'running\n'; }
  _notify_type_or_park() { printf '%s\n' "$3" >>"$WORK/f5a.typed"; }

  : >"$WORK/f5a.typed"
  # 1. a request that is DECIDED during the grace is never typed, even though the
  #    notice itself is still unread
  id1="$(approval_create backend Bash "rm -rf /tmp/x" "$PWD")"
  inbox_add lead approval "[wolfmux] Permission request $id1 from backend. Run: teamctl approvals"
  _inbox_approval_grace_wait lead "%9" "[wolfmux] Permission request $id1 from backend. Run: teamctl approvals" 60 "$id1" &
  waiter=$!
  sleep 1
  approval_decide "$id1" approved operator ""
  wait "$waiter" 2>/dev/null
  [ ! -s "$WORK/f5a.typed" ] || exit 1
  inbox_is_new lead "[wolfmux] Permission request $id1 from backend. Run: teamctl approvals" || exit 1

  # 2. a request still PENDING after the grace IS typed, however much has been read
  : >"$WORK/f5a.typed"
  id2="$(approval_create backend Bash "curl example.com" "$PWD")"
  inbox_add lead approval "[wolfmux] Permission request $id2 from backend. Run: teamctl approvals"
  cmd_inbox --all >/dev/null 2>&1          # the human glances at everything: prefix N
  _inbox_approval_grace_wait lead "%9" "[wolfmux] Permission request $id2 from backend. Run: teamctl approvals" 60 "$id2"
  grep -q "$id2" "$WORK/f5a.typed" || exit 1

  # 3. expired counts as settled: nothing is blocked, so nothing is typed
  : >"$WORK/f5a.typed"
  id3="$(approval_create backend Bash "git push --force" "$PWD")"
  approval_decide "$id3" expired "" "no decision within 600s"
  _inbox_approval_grace_wait lead "%9" "[wolfmux] Permission request $id3 from backend. Run: teamctl approvals" 60 "$id3"
  [ ! -s "$WORK/f5a.typed" ] || exit 1

  # 4. a store that cannot be read fails TOWARDS typing: a stalled worker is the harm
  : >"$WORK/f5a.typed"
  approval_field() { return 1; }
  _inbox_approval_grace_wait lead "%9" "[wolfmux] Permission request A99 from backend. Run: teamctl approvals" 60 A99
  [ -s "$WORK/f5a.typed" ] || exit 1
  exit 0
) >/dev/null 2>&1
F5A_STATUS=$?
check "F5: a DECIDED request is never typed; one still pending after the grace is" '[ "$F5A_STATUS" -eq 0 ]'

# The text sweep the F6 ruling asked for: a notice text is arbitrary (it comes from a bead
# title) and must survive every comparison in the file. awk processes escapes in a -v
# assignment, so a title holding a literal backslash-n used to arrive as a real newline
# and every match silently failed -- filing the same notice twice, or leaving a typed one
# undelivered to be handed over again.
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  STATE_DIR="$WORK/ftext"
  WOLFMUX_NUDGE_DEBOUNCE=30
  /bin/mkdir -p "$STATE_DIR/inbox"
  # a literal backslash-n, a backslash-t, and a lone backslash: all legal in a bead title
  odd='task C:\new\table and a trailing \'
  inbox_add lead beads "$odd"
  inbox_add lead beads "$odd"                   # the dedupe must still catch it
  [ "$(wc -l <"$STATE_DIR/inbox/lead" | tr -d ' ')" = "1" ] || exit 1
  # the stored line is the text VERBATIM, not an interpreted version of it
  [ "$(cut -f4 "$STATE_DIR/inbox/lead")" = "$odd" ] || exit 1
  # and it can be found, marked delivered and re-queued by its own text
  inbox_is_new lead "$odd" || exit 1
  inbox_mark_typed lead "$odd"
  [ "$(inbox_count_undelivered lead)" = "0" ] || exit 1
  inbox_requeue lead "$odd"
  [ "$(inbox_count_undelivered lead)" = "1" ] || exit 1
  exit 0
) >/dev/null 2>&1
FTEXT_STATUS=$?
check "a bead title holding backslash escapes still dedupes, matches and re-queues" '[ "$FTEXT_STATUS" -eq 0 ]'

# F11 -- one hook may not inject ~80 KB. The oldest batch goes, the rest STAY
# undelivered for the next turn, and the body says how many are still waiting. A cap that
# marked them delivered without showing them would be the lost-notice bug in a new place.
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  STATE_DIR="$WORK/f11"
  /bin/mkdir -p "$STATE_DIR/inbox"
  WOLFMUX_INBOX_HANDOVER_MAX=5
  i=1
  while [ $i -le 12 ]; do
    printf '%s\tbeads\tnu\tnotice %s\n' "$(now_epoch)" "$i" >>"$STATE_DIR/inbox/lead"
    i=$((i + 1))
  done
  first="$(inbox_take_undelivered lead)"
  [ "$(printf '%s\n' "$first" | grep -c .)" = "5" ] || exit 1          # capped
  [ "$(inbox_count_undelivered lead)" = "7" ] || exit 1                 # rest kept
  printf '%s\n' "$first" | grep -q "notice 1" || exit 1                 # oldest first
  printf '%s\n' "$first" | grep -q "notice 6" && exit 1
  # the body says how many are still waiting
  inbox_hook_body lead "$first" "$(inbox_count_undelivered lead)" | grep -q "7 more waiting" || exit 1
  # the next turn takes the next batch, and nothing was lost across the two
  second="$(inbox_take_undelivered lead)"
  [ "$(printf '%s\n' "$second" | grep -c .)" = "5" ] || exit 1
  printf '%s\n' "$second" | grep -q "notice 6" || exit 1
  third="$(inbox_take_undelivered lead)"
  [ "$(printf '%s\n' "$third" | grep -c .)" = "2" ] || exit 1
  [ "$(inbox_count_undelivered lead)" = "0" ] || exit 1
  # and an uncapped body carries no such line
  inbox_hook_body lead "$third" 0 | grep -q "more waiting" && exit 1
  exit 0
) >/dev/null 2>&1
F11_STATUS=$?
check "F11: one hand-over is capped, the rest stay undelivered, and the body says so" '[ "$F11_STATUS" -eq 0 ]'

# N1 -- the F7 recovery path used to report success whether it had requeued anything or
# not. The want list went to awk as a FILE whose path was passed with -v, and a getline
# that cannot read its file is not an awk error: want[] came out empty, nothing matched,
# every line was printed unchanged, awk exited 0, the && chain installed a record in which
# the notices were still 'd', and the caller logged "N notice(s) re-queued". So the one
# path built to stop notices being lost could lose them and record that it saved them.
# This is the FAILURE path of a read-modify-write, which is the shape F1 has and this
# function did not: the same unwritable-temp-path trick, asserting the return value.
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  STATE_DIR="$WORK/n1"
  /bin/mkdir -p "$STATE_DIR/inbox"
  i=1
  while [ $i -le 3 ]; do
    printf '%s\tbeads\tnd\tnotice %s\n' "$(now_epoch)" "$i" >>"$STATE_DIR/inbox/lead"
    i=$((i + 1))
  done
  want="$(printf 'notice 1\nnotice 2\nnotice 3\n')"
  # 1. it still requeues, and it says so
  inbox_requeue lead "$want" || exit 1
  [ "$(inbox_count_undelivered lead)" = "3" ] || exit 1
  # 2. the multi-line list arrives VERBATIM: a bead title holding backslash escapes is
  #    split on real newlines and matched as stored, not as awk would have expanded it
  : >"$STATE_DIR/inbox/lead"
  odd1='task C:\new\table'
  odd2='and a trailing \'
  printf '%s\tbeads\tnd\t%s\n' "$(now_epoch)" "$odd1" >>"$STATE_DIR/inbox/lead"
  printf '%s\tbeads\tnd\t%s\n' "$(now_epoch)" "$odd2" >>"$STATE_DIR/inbox/lead"
  inbox_requeue lead "$(printf '%s\n%s\n' "$odd1" "$odd2")" || exit 1
  [ "$(inbox_count_undelivered lead)" = "2" ] || exit 1
  # 3. THE POINT: a requeue that cannot write its replacement record must FAIL, not
  #    report success. Every temp path now points somewhere unwritable.
  : >"$STATE_DIR/inbox/lead"
  i=1
  while [ $i -le 3 ]; do
    printf '%s\tbeads\tnd\tnotice %s\n' "$(now_epoch)" "$i" >>"$STATE_DIR/inbox/lead"
    i=$((i + 1))
  done
  inbox_tmp() { printf '%s\n' "$STATE_DIR/inbox/no-such-dir/.tmp.$1.$2.$$"; }
  inbox_requeue lead "$want" && exit 1                                  # returned non-zero
  [ "$(inbox_count_undelivered lead)" = "0" ] || exit 1                 # record intact
  [ "$(wc -l <"$STATE_DIR/inbox/lead" | tr -d ' ')" = "3" ] || exit 1
  exit 0
) >/dev/null 2>&1
N1_STATUS=$?
check "N1: a re-queue that cannot write its record FAILS instead of reporting success" '[ "$N1_STATUS" -eq 0 ]'

# N1, second half -- the caller must not assert a re-queue that did not happen. The Stop
# hook's jq fails AND the re-queue fails: the event has to say the notices were lost.
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  STATE_DIR="$WORK/n1log"
  /bin/mkdir -p "$STATE_DIR/inbox"
  printf '%s\tbeads\tnd\tnotice 1\n' "$(now_epoch)" >"$STATE_DIR/inbox/lead"
  inbox_tmp() { printf '%s\n' "$STATE_DIR/inbox/no-such-dir/.tmp.$1.$2.$$"; }
  INBOX_ROLE=lead
  if inbox_requeue "$INBOX_ROLE" "notice 1"; then
    event_log inbox-stop-failed "$INBOX_ROLE" "jq failed; 1 notice(s) re-queued" 2>/dev/null || true
  else
    event_log inbox-stop-failed "$INBOX_ROLE" "jq failed AND the re-queue failed; 1 notice(s) LOST" 2>/dev/null || true
  fi
  grep -q 'LOST' "$STATE_DIR/events.jsonl" || exit 1
  grep -q 're-queued' "$STATE_DIR/events.jsonl" && exit 1
  exit 0
) >/dev/null 2>&1
N1LOG_STATUS=$?
check "N1: the event says the notices were LOST, never that a failed re-queue saved them" '[ "$N1LOG_STATUS" -eq 0 ]'

# N2 -- inbox_take_undelivered's output path went through -v as well. F1's chain already
# contains the damage (nothing moved, nothing printed, every letter still 'u'), so this
# one fails SAFE. What it did not do was SAY so: awk's stderr is /dev/null, so both hooks
# could stop delivering for the life of an install while the badge, which passes no paths,
# kept counting up. The path is off -v now; this asserts the silence is gone.
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  STATE_DIR="$WORK/n2"
  /bin/mkdir -p "$STATE_DIR/inbox"
  printf '%s\tbeads\tnu\tnotice 1\n' "$(now_epoch)" >"$STATE_DIR/inbox/lead"
  # a working take logs no failure, and the texts still come back
  [ "$(inbox_take_undelivered lead)" = "notice 1" ] || exit 1
  [ ! -f "$STATE_DIR/events.jsonl" ] || ! grep -q 'inbox-take-failed' "$STATE_DIR/events.jsonl" || exit 1
  # now it cannot write: nothing handed over, record intact -- and an event says so
  printf '%s\tbeads\tnu\tnotice 2\n' "$(now_epoch)" >>"$STATE_DIR/inbox/lead"
  inbox_tmp() { printf '%s\n' "$STATE_DIR/inbox/no-such-dir/.tmp.$1.$2.$$"; }
  [ -z "$(inbox_take_undelivered lead)" ] || exit 1
  [ "$(inbox_count_undelivered lead)" = "1" ] || exit 1
  grep -q 'inbox-take-failed' "$STATE_DIR/events.jsonl" || exit 1
  exit 0
) >/dev/null 2>&1
N2_STATUS=$?
check "N2: a hand-over that cannot rewrite the record is recorded, not silent" '[ "$N2_STATUS" -eq 0 ]'

# The reviewer's trap 1: inbox_mark_typed was called with the RAW text while inbox_add
# stored a normalised one, so the first notice over the length cap would stop being marked
# delivered and be handed over twice.
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  STATE_DIR="$WORK/ftrap1"
  /bin/mkdir -p "$STATE_DIR/inbox"
  long="$(printf '[wolfmux] Beads update for lead ('; i=0; while [ $i -lt 500 ]; do printf 'x'; i=$((i+1)); done; printf ')')"
  inbox_add lead beads "$long"
  [ "$(inbox_count_undelivered lead)" = "1" ] || exit 1
  inbox_mark_typed lead "$long"          # the RAW, over-length string, as the callers pass it
  [ "$(inbox_count_undelivered lead)" = "0" ] || exit 1
  exit 0
) >/dev/null 2>&1
FTRAP1_STATUS=$?
check "a notice longer than the text cap is still marked delivered when it is typed" '[ "$FTRAP1_STATUS" -eq 0 ]'

# F4 -- the numeric knobs are validated like the word above them. The cooldown is the
# dangerous one: a non-numeric value made the Stop hook return without delivering on
# every turn, for the life of the team, silently.
(
  cd "$PROJECT" || exit 1
  for bad in off 10s " " -5 1e3; do
    (
      # shellcheck disable=SC1090
      WOLFMUX_INBOX_STOP_COOLDOWN="$bad" WOLFMUX_INBOX_APPROVAL_GRACE="$bad" \
        WOLFMUX_INBOX_STALL_NOTIFY_DEBOUNCE="$bad" WOLFMUX_INBOX_MAX="$bad"
      . "$WOLFMUX_HOME/lib/provider-env.sh"
      . "$WOLFMUX_HOME/lib/common.sh"
      . "$WOLFMUX_HOME/lib/registry.sh"
      . "$WOLFMUX_HOME/lib/tmuxctl.sh"
      . "$WOLFMUX_HOME/lib/notify.sh"
      . "$WOLFMUX_HOME/lib/inbox.sh"
      [ "$WOLFMUX_INBOX_STOP_COOLDOWN" = "10" ] || exit 1
      [ "$WOLFMUX_INBOX_APPROVAL_GRACE" = "20" ] || exit 1
      [ "$WOLFMUX_INBOX_STALL_NOTIFY_DEBOUNCE" = "120" ] || exit 1
      [ "$WOLFMUX_INBOX_MAX" = "200" ] || exit 1
    ) || exit 1
  done
  # a real number is still honoured
  (
    WOLFMUX_INBOX_STOP_COOLDOWN=45
    . "$WOLFMUX_HOME/lib/provider-env.sh"
    . "$WOLFMUX_HOME/lib/common.sh"
    . "$WOLFMUX_HOME/lib/registry.sh"
    . "$WOLFMUX_HOME/lib/tmuxctl.sh"
    . "$WOLFMUX_HOME/lib/notify.sh"
    . "$WOLFMUX_HOME/lib/inbox.sh"
    [ "$WOLFMUX_INBOX_STOP_COOLDOWN" = "45" ] || exit 1
  ) || exit 1
  exit 0
) >/dev/null 2>&1
F4_STATUS=$?
check "F4: a non-numeric knob falls back to its default instead of disabling a hook" '[ "$F4_STATUS" -eq 0 ]'

echo "== v1.14.3's browser-writes arm and this release's inbox hooks, in ONE document"
# The division of labour, so this does not re-do work that belongs with the other branch:
# tests/smoke.sh's four browser-writes rows (v1.14.3) pin the TEAM-level permissions arm
# against the role-level PermissionRequest hook, which is the pair a careless merge of the
# two branches would flatten. Those four are ASSUMED here and never re-asserted. What that
# matrix cannot reach is the case this release creates: ONE document carrying both inbox
# hooks AND that arm at the same time — the product neither branch could test alone,
# because neither had both halves.
#
# $TEAMCTL_SELF is an absolute path that differs per run and per checkout, so it is
# normalised to a token before any comparison; everything else is compared verbatim, on
# `jq -S .` so key order can never make a true document look false. There is deliberately
# no golden fixture FILE: it would go stale on every legitimate change to that jq chain,
# and a fixture nobody trusts gets deleted rather than read.
settings_of() { printf '%s\n' "$STATE_DIR/settings/$1.json"; }
norm_self() { sed "s#$REPO/bin/teamctl#<TEAMCTL>#g"; }
settings_doc() { jq -S . "$(settings_of "$1")" | norm_self; }
settings_doc_noperm() { jq -S 'del(.permissions)' "$(settings_of "$1")" | norm_self; }
settings_keys() { jq -Sc 'keys' "$(settings_of "$1")"; }
# Every hook command in the document, by event: a quiet change of hook SHAPE fails this
# even when both documents change together, which is what the delta below cannot see.
settings_hooks() { jq -Sc '.hooks | with_entries(.value |= [.[].hooks[].command])' "$(settings_of "$1")" | norm_self; }
# all three at once in one document — env, the hooks (the notification hook KEPT and both
# inbox hooks present), and permissions.allow as an EXACT array. Never a contains, never a
# substring, never "the matcher is present": an allow list that grows unnoticed is how a
# narrow exemption becomes a machine-wide one, so a second matcher must FAIL this.
allow_doc_ok() { # <role>
  jq -e '
    (.env | type) == "object"
    and ([.hooks.Stop[].hooks[].command] | map(select(test("_notify$"))) | length) == 1
    and ([.hooks.Stop[].hooks[].command] | map(select(test("_inbox-stop$"))) | length) == 1
    and (.hooks.UserPromptSubmit[0].hooks[0].command | test("_inbox-prompt$"))
    and .permissions == {allow: ["mcp__claude-in-chrome__*"]}
  ' "$(settings_of "$1")" >/dev/null 2>&1
}
worker_guard_ok() { # <role> — the worktree guard is still there beside the rest
  jq -e '([.hooks.PreToolUse[].hooks[].command] | map(select(test("_guard$"))) | length) == 1' \
    "$(settings_of "$1")" >/dev/null 2>&1
}
# The document is rewritten by the respawned pane's own process, asynchronously from
# `teamctl restart` returning, so poll for the condition that actually changed rather than
# trusting a fixed sleep: a busy machine must not be able to make this flake.
settings_wait() { # <role> <jq boolean filter>
  local f i
  f="$(settings_of "$1")"
  for i in 1 2 3 4 5 6 7 8; do
    jq -e "$2" "$f" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}
# The default-policy documents FIRST: this team has never seen the allow policy.
DEFAULT_LEAD_DOC="$(settings_doc lead)"
DEFAULT_QA_DOC="$(settings_doc qa)"
DEFAULT_LEAD_KEYS="$(settings_keys lead)"
DEFAULT_QA_KEYS="$(settings_keys qa)"
DEFAULT_LEAD_HOOKS="$(settings_hooks lead)"
DEFAULT_QA_HOOKS="$(settings_hooks qa)"
DEFAULT_LEAD_PERMKEY="$(jq -c 'has("permissions")' "$(settings_of lead)" 2>/dev/null)"
DEFAULT_QA_PERMKEY="$(jq -c 'has("permissions")' "$(settings_of qa)" 2>/dev/null)"
# v1.23.0: the lead's wake waiter on SessionStart and as the third Stop entry (exec'd)
# v1.24.0 (D7): and `teamctl _hook <Event>` exactly once for each of the five turn events (lib/hooks.sh)
EXPECT_LEAD_HOOKS='{"PostToolUse":["\"<TEAMCTL>\" _hook PostToolUse"],"PreCompact":["\"<TEAMCTL>\" _hook PreCompact"],"SessionStart":["\"<TEAMCTL>\" _hook SessionStart","exec \"<TEAMCTL>\" _inbox-wake"],"Stop":["\"<TEAMCTL>\" _notify","\"<TEAMCTL>\" _inbox-stop","\"<TEAMCTL>\" _hook Stop","exec \"<TEAMCTL>\" _inbox-wake"],"UserPromptSubmit":["\"<TEAMCTL>\" _inbox-prompt","\"<TEAMCTL>\" _hook UserPromptSubmit"]}'
EXPECT_QA_HOOKS='{"PostToolUse":["\"<TEAMCTL>\" _hook PostToolUse"],"PreCompact":["\"<TEAMCTL>\" _hook PreCompact"],"PreToolUse":["\"<TEAMCTL>\" _guard"],"SessionStart":["\"<TEAMCTL>\" _hook SessionStart"],"Stop":["\"<TEAMCTL>\" _notify","\"<TEAMCTL>\" _inbox-stop","\"<TEAMCTL>\" _hook Stop"],"UserPromptSubmit":["\"<TEAMCTL>\" _inbox-prompt","\"<TEAMCTL>\" _hook UserPromptSubmit"]}'
teamctl policy browser-writes allow >/dev/null 2>&1
teamctl restart lead >/dev/null 2>&1
teamctl restart qa >/dev/null 2>&1
settings_wait lead 'has("permissions")'
LEAD_ALLOW_WAIT=$?
settings_wait qa 'has("permissions")'
QA_ALLOW_WAIT=$?
check "settings at allow: both documents really were rewritten after the policy change (polled, not slept)" '[ "$LEAD_ALLOW_WAIT" -eq 0 ] && [ "$QA_ALLOW_WAIT" -eq 0 ]'
check "settings at allow (lead): env, the notification hook, BOTH inbox hooks and permissions.allow as an exact array — all in one document" 'allow_doc_ok lead'
check "settings at allow (worker): the same, with the worktree guard still beside them" 'allow_doc_ok qa && worker_guard_ok qa'
# The DELTA, from both directions: their arm adds exactly the permissions key and nothing
# else. A one-directional "has no permissions key" would miss a second thing it also added.
check "settings delta (lead): at the default there is no permissions key at all, and that document equals the allow document with .permissions deleted" '[ "$DEFAULT_LEAD_PERMKEY" = "false" ] && [ "$DEFAULT_LEAD_DOC" = "$(settings_doc_noperm lead)" ]'
check "settings delta (worker): the same both ways round" '[ "$DEFAULT_QA_PERMKEY" = "false" ] && [ "$DEFAULT_QA_DOC" = "$(settings_doc_noperm qa)" ]'
# The DRIFT, which the delta cannot see: if something else in that jq chain quietly changes
# shape, BOTH documents change together and the delta still passes.
check "settings drift (lead): the key set is exactly disableAgentView, env and hooks, and the hooks are exactly the notification hook, the inbox Stop hook, the wake waiter (Stop and SessionStart), the inbox UserPromptSubmit hook and the turn hooks" '[ "$DEFAULT_LEAD_KEYS" = "[\"disableAgentView\",\"env\",\"hooks\"]" ] && [ "$DEFAULT_LEAD_HOOKS" = "$EXPECT_LEAD_HOOKS" ]'
# v1.24.0: plus enabledPlugins, and only that, which the worker-context policy (default trim)
# writes when the machine has plugins to switch off (lib/policy.sh worker_context_settings).
# v1.25.0: plus permissions, the deny list of the tools a pane agent cannot use (the same policy).
check "settings drift (worker): exactly disableAgentView, env, hooks and teammateMode (and enabledPlugins and permissions under worker-context trim), and exactly the guard, the notification hook, the two inbox hooks and the turn hooks" '[ "$(printf "%s" "$DEFAULT_QA_KEYS" | jq -c "map(select(. != \"enabledPlugins\" and . != \"permissions\"))")" = "[\"disableAgentView\",\"env\",\"hooks\",\"teammateMode\"]" ] && [ "$DEFAULT_QA_HOOKS" = "$EXPECT_QA_HOOKS" ]'
# rgi60 F5: Claude Code's agent view is off for every agent, by the setting AND by its
# environment switch. With it on, /bg turned the comms lead's pane into the agent view, which
# started Claude's daemon from inside the pane (2026-10-19).
check "agent view off (lead and worker): disableAgentView is true and env.CLAUDE_CODE_DISABLE_AGENT_VIEW is \"1\"" '(for r in lead qa; do jq -e ".disableAgentView == true and .env.CLAUDE_CODE_DISABLE_AGENT_VIEW == \"1\"" "$(settings_of "$r")" || exit 1; done)'

echo "== rgi60: an inherited identity is not an identity (the pane proof)"
# 2026-10-19: the comms lead was sent to the background (/bg). Its pane became Claude's agent
# view, the agent view started Claude's daemon from inside the pane, and every background chat
# of that daemon had the lead's whole environment (TEAM_ROLE, WOLFMUX_TEAM, BEADS_ACTOR, TMUX,
# TMUX_PANE). Three chats acted as the comms lead for two days. Their process tree was chat ->
# `claude bg-pty-host` -> `claude daemon run` -> pid 1: the pane's process was not among their
# parents. That tree is built here with tests/fake-ps: invented daemon processes, and this
# suite's shell grafted under them, so every process it starts runs "in the daemon".
LEAD_PANE="$(pane_of_role lead)"
QA_PANE="$(pane_of_role qa)"
DAEMON_TABLE="$WORK/daemon-ps"
{
  printf '%s\t%s\t%s\t%s\n' 71001 1 "/Users/x/.local/bin/claude daemon run" "TEAM_ROLE=lead WOLFMUX_TEAM=default"
  printf '%s\t%s\t%s\n' 71002 71001 "/Users/x/.local/bin/claude bg-pty-host"
} >"$DAEMON_TABLE"
REAL_SOCKET="$("$REAL_TMUX" -L "$WOLFMUX_TMUX_SOCKET" display-message -p -t "$LEAD_PANE" '#{socket_path}')"
# hook_daemon <role> <hook> — the hook in a background chat of that daemon: the agent's whole
# environment, its TMUX_PANE too, and a process tree that never reaches the pane
hook_daemon() {
  (cd "$PROJECT" && TMUX="$REAL_SOCKET,0,0" TMUX_PANE="$(pane_of_role "$1")" TEAM_ROLE="$1" WOLFMUX_TEAM=default BEADS_ACTOR="$1" \
    WOLFMUX_PS_BIN="$REPO/tests/fake-ps" WOLFMUX_FAKE_PS_TABLE="$DAEMON_TABLE" WOLFMUX_FAKE_PS_GRAFT="$$:71002" \
    teamctl "$2" </dev/null 2>/dev/null)
}
# as_daemon_chat <command…> — teamctl itself, run from such a chat (stdout and stderr together)
as_daemon_chat() {
  (cd "$PROJECT" && TMUX="$REAL_SOCKET,0,0" TMUX_PANE="$LEAD_PANE" TEAM_ROLE=lead WOLFMUX_TEAM=default BEADS_ACTOR=lead \
    WOLFMUX_PS_BIN="$REPO/tests/fake-ps" WOLFMUX_FAKE_PS_TABLE="$DAEMON_TABLE" WOLFMUX_FAKE_PS_GRAFT="$$:71002" \
    teamctl "$@" </dev/null 2>&1)
}
# as_lead_in_pane <command…> — the same command from the lead's own pane
as_lead_in_pane() {
  (cd "$PROJECT" && TMUX="$REAL_SOCKET,0,0" TMUX_PANE="$LEAD_PANE" TEAM_ROLE=lead WOLFMUX_TEAM=default BEADS_ACTOR=lead \
    WOLFMUX_PS_BIN="$REPO/tests/fake-ps" WOLFMUX_FAKE_PS_GRAFT="$$:$("$REAL_TMUX" -L "$WOLFMUX_TMUX_SOCKET" display-message -p -t "$LEAD_PANE" '#{pane_pid}')" \
    teamctl "$@" </dev/null 2>&1)
}
NOT_YOU="[wolfmux] This chat is not running in default's lead pane, so it is NOT lead. Do not send Beads or run teamctl as that role, and ignore wolfmux notices. BEADS_ACTOR in this chat's environment is inherited, not yours."
CLAIMS="this process claims lead but does not run in its pane (a background or inherited chat). Run teamctl from the agent's own pane, or from a plain Terminal as yourself."
refused_events() { grep -c '"type":"identity-refused"' "$STATE_DIR/events.jsonl" 2>/dev/null || true; }
teamctl inbox --all >/dev/null 2>&1
/bin/rm -f "$STATE_DIR"/.identity-refused.* "$INBOX/.stop.lead" "$INBOX/.stop.qa"
REFUSED_BEFORE="$(refused_events)"
WOLFMUX_NUDGE_TYPE=off teamctl nudge lead --id idn-lead-1 >/dev/null 2>&1
# case 2: the daemon's chat, then a chat with no pane at all
DAEMON_PROMPT="$(hook_daemon lead _inbox-prompt)"
DAEMON_STOP="$(hook_daemon lead _inbox-stop)"
BARE_PROMPT="$(hook_bare lead _inbox-prompt)"
BARE_STOP="$(hook_bare lead _inbox-stop)"
check "daemon chat: _inbox-prompt hands over NOTHING and says, in the brief's words, that the chat is not the lead" '[ "$DAEMON_PROMPT" = "$NOT_YOU" ]'
check "daemon chat: _inbox-stop prints nothing and blocks nothing" '[ -z "$DAEMON_STOP" ] && [ ! -e "$INBOX/.stop.lead" ]'
check "no pane at all: the same line, on EVERY prompt (it may have forgotten after a compaction), and a silent Stop hook" '[ "$BARE_PROMPT" = "$NOT_YOU" ] && [ -z "$BARE_STOP" ]'
check "nothing was taken from the inbox: the notice is still undelivered" 'delivered_of lead idn-lead-1 false'
check "identity-refused: four refusals inside a minute log ONE line, naming the role and why" '[ "$(refused_events)" -eq $((REFUSED_BEFORE + 1)) ] && grep "\"type\":\"identity-refused\"" "$STATE_DIR/events.jsonl" | tail -1 | jq -e ".role == \"lead\" and .by == \"not-in-its-pane\" and (.detail | test(\"not among its parents\"))"'
# case 3: another role's pane (qa's), really an ancestor, but the claim is lead
OTHER_PROMPT="$(cd "$PROJECT" && TMUX="$REAL_SOCKET,0,0" TMUX_PANE="$QA_PANE" TEAM_ROLE=lead WOLFMUX_TEAM=default \
  WOLFMUX_PS_BIN="$REPO/tests/fake-ps" WOLFMUX_FAKE_PS_GRAFT="$$:$("$REAL_TMUX" -L "$WOLFMUX_TMUX_SOCKET" display-message -p -t "$QA_PANE" '#{pane_pid}')" \
  teamctl _inbox-prompt </dev/null 2>/dev/null)"
check "TMUX_PANE of another role's pane: refused, the not-you line, nothing taken" '[ "$OTHER_PROMPT" = "$NOT_YOU" ] && delivered_of lead idn-lead-1 false'
# the notification hook: no "lead: finished" on your screen from a chat that is not the lead
NOTIFY_BEFORE="$(wc -c <"$WOLFMUX_NOTIFY_TTY" | tr -d ' ')"
printf '%s' '{"last_assistant_message":"idn daemon chat finished"}' | (cd "$PROJECT" && TMUX="$REAL_SOCKET,0,0" TMUX_PANE="$LEAD_PANE" TEAM_ROLE=lead WOLFMUX_TEAM=default \
  WOLFMUX_PS_BIN="$REPO/tests/fake-ps" WOLFMUX_FAKE_PS_TABLE="$DAEMON_TABLE" WOLFMUX_FAKE_PS_GRAFT="$$:71002" teamctl _notify >/dev/null 2>&1)
check "daemon chat: the notification hook posts nothing" '[ "$(wc -c <"$WOLFMUX_NOTIFY_TTY" | tr -d " ")" = "$NOTIFY_BEFORE" ] && ! grep -rq "idn daemon chat" "$WOLFMUX_DATA/notify" 2>/dev/null'
# case 1: the lead in its own pane gets it, as before
IN_PANE_PROMPT="$(hook lead _inbox-prompt)"
check "the lead in its own pane: the notice is handed over and marked delivered, and no not-you line" 'printf "%s" "$IN_PANE_PROMPT" | grep -q "idn-lead-1" && ! printf "%s" "$IN_PANE_PROMPT" | grep -q "is NOT" && delivered_of lead idn-lead-1 true'
# case 4: what the daemon chat may and may not run
IDN_POLICY_BEFORE="$(teamctl status --json | jq -c .policy)"
for c in "stop qa" "spawn idn flash --no-kickoff" "policy worker-spawn on" "restart qa" "approve A1" "remove qa" "model qa flash" "finish" "start fable --no-attach --skip-beads"; do
  # shellcheck disable=SC2086
  out="$(as_daemon_chat $c)"
  rc=$?
  printf '%s\n' "$rc|$out" >"$WORK/idn-$(printf '%s' "$c" | tr -c 'a-z' '_').out"
done
check "daemon chat: stop, spawn, policy, restart, approve, remove, model, finish and start all refuse with exit 77 and the brief's sentence" '(for f in "$WORK"/idn-*.out; do grep -q "^77|" "$f" && grep -qF "$CLAIMS" "$f" || exit 1; done)'
check "daemon chat: and nothing happened (qa still runs, no new role, the policy unchanged)" '[ "$(teamctl status --json | jq -r ".agents[] | select(.role == \"qa\") | .state")" = "running" ] && ! teamctl status --json | jq -e ".agents[] | select(.role == \"idn\")" && [ "$(teamctl status --json | jq -c .policy)" = "$IDN_POLICY_BEFORE" ]'
check "daemon chat: status, teams, inbox, version and approvals still work (they only read)" 'as_daemon_chat status >/dev/null && as_daemon_chat teams >/dev/null && as_daemon_chat inbox lead --keep >/dev/null && as_daemon_chat version >/dev/null && as_daemon_chat approvals >/dev/null'
check "daemon chat: status --json is still JSON" 'as_daemon_chat status --json | jq -e .agents'
IN_PANE_APPROVE="$(as_lead_in_pane approve NOPE)"
check "the lead in its own pane: past the identity gate (approve of an unknown id fails for THAT reason, not 77)" '! printf "%s" "$IN_PANE_APPROVE" | grep -qF "does not run in its pane" && printf "%s" "$IN_PANE_APPROVE" | grep -qi "NOPE"'
# case 5: you, at your own terminal: unchanged
OP_APPROVE="$(cd "$PROJECT" && teamctl approve NOPE 2>&1)"
check "operator (no TEAM_ROLE, no TMUX_PANE): no claim, no refusal, and the hooks say nothing" '! printf "%s" "$OP_APPROVE" | grep -qF "does not run in its pane" && [ -z "$(cd "$PROJECT" && teamctl _inbox-prompt </dev/null 2>&1)" ]'
# A pane you split for yourself in the team's window: on the team's server, but no agent's.
OWN_PANE="$(tmx split-window -d -t "$LEAD_PANE" -P -F '#{pane_id}' 'sleep 600' 2>/dev/null)"
OWN_APPROVE="$(cd "$PROJECT" && TMUX="$REAL_SOCKET,0,0" TMUX_PANE="$OWN_PANE" teamctl approve NOPE 2>&1)"
check "operator in a pane of the team's window that is no agent's: still you" '[ -n "$OWN_PANE" ] && ! printf "%s" "$OWN_APPROVE" | grep -qF "does not run in its pane"'
tmx kill-pane -t "$OWN_PANE" >/dev/null 2>&1
# caller_role: a failed claim keeps its role. Empty would be YOU, who may do everything.
CLAIMED_ROLE="$(cd "$PROJECT" && TEAM_ROLE=lead WOLFMUX_TEAM=default bash -c '
  set -euo pipefail
  for m in provider-env common registry tmuxctl policy; do . "$WOLFMUX_HOME/lib/$m.sh"; done
  caller_role' 2>/dev/null)"
check "caller_role: a claim that fails the proof is still that role, never empty (empty is you)" '[ "$CLAIMED_ROLE" = "lead" ]'
# case 6: Claude's agent view in qa's pane. Its record's conversation went on in a background chat.
QA_PID="$("$REAL_TMUX" -L "$WOLFMUX_TMUX_SOCKET" display-message -p -t "$QA_PANE" '#{pane_pid}')"
QA_SID="$(teamctl status --json | jq -r '.agents[] | select(.role == "qa") | .session_id')"
QA_WORKDIR="$(teamctl status --json | jq -r '.agents[] | select(.role == "qa") | .workdir')"
VIEW_TABLE="$WORK/view-ps"
printf '%s\t1\t/Users/x/.local/bin/claude agents\n' "$QA_PID" >"$VIEW_TABLE"
VIEW_PROJECTS="$WORK/view-projects"
VIEW_TDIR="$VIEW_PROJECTS/$(printf '%s' "$(cd "$QA_WORKDIR" && pwd -P)" | LC_ALL=C sed 's|[^A-Za-z0-9]|-|g')"
/bin/mkdir -p "$VIEW_TDIR"
CONT_ID="0f0e0d0c-1111-4222-8333-444455556666"
{
  printf '%s\n' '{"type":"user","message":{"content":"hello"}}'
  printf '%s\n' '{"type":"continued-in","continuedInSessionId":"00000000-0000-4000-8000-000000000001"}'
  # one 70 kB line: the earlier continued-in line is outside the 64 KiB tail teamctl reads
  printf '{"type":"filler","text":"%s"}\n' "$(head -c 70000 /dev/zero | tr '\0' 'x')"
  printf '%s\n' '{"type":"continued-in","continuedInSessionId":"'"$CONT_ID"'"}'
} >"$VIEW_TDIR/$QA_SID.jsonl"
view_status() { (cd "$PROJECT" && WOLFMUX_CLAUDE_PROJECTS="$VIEW_PROJECTS" WOLFMUX_PS_BIN="$REPO/tests/fake-ps" WOLFMUX_FAKE_PS_TABLE="$VIEW_TABLE" teamctl status "$@" 2>/dev/null); }
VIEW_JSON="$(view_status --json)"
VIEW_TEXT="$(view_status)"
check "status --json: qa, whose pane runs Claude's agent view, is backgrounded, with the LAST continued-in id of its transcript" 'printf "%s" "$VIEW_JSON" | jq -e --arg id "$CONT_ID" ".agents[] | select(.role == \"qa\") | .state == \"backgrounded\" and .continued_in == \$id and (.hint | test(\"agent view\")) and .holding == null"'
check "status --json: the lead's row is running and keeps its old shape (no hint, no continued_in)" 'printf "%s" "$VIEW_JSON" | jq -e ".agents[] | select(.role == \"lead\") | .state == \"running\" and (has(\"hint\") | not) and (has(\"continued_in\") | not)"'
check "status (text): the backgrounded row and the hint line under it" 'printf "%s" "$VIEW_TEXT" | grep -q "qa .*backgrounded" && printf "%s" "$VIEW_TEXT" | grep -qF "this pane runs Claude'"'"'s agent view; its conversation continued in $CONT_ID as a background chat"'
check "status (text): \"backgrounded\" fits the STATE column: the pane id starts where it does on the lead's row" 'q="$(printf "%s\n" "$VIEW_TEXT" | grep "🐶 qa " | awk "{ print index(\$0, \"%\") }")"; l="$(printf "%s\n" "$VIEW_TEXT" | grep "🐺 lead " | awk "{ print index(\$0, \"%\") }")"; [ -n "$q" ] && [ "$q" -gt 0 ] && [ "$q" = "$l" ]'
check "status without the fake table: qa is running again (nothing is remembered)" '[ "$(teamctl status --json | jq -r ".agents[] | select(.role == \"qa\") | .state")" = "running" ]'
# case 7: doctor, on a fake daemon whose environment holds an identity AND secrets. Only the
# section's own function: the whole doctor runs a real claude for `auth status`.
DOCTOR_TABLE="$WORK/doctor-ps"
{
  printf '%s\t%s\t%s\t%s\n' 72001 1 '/Users/x/.local/bin/claude daemon run --spawned-by {"pid":4321,"kind":"agents"}' \
    "HOME=/x/home SECRET_TOKEN=idn-secret-1 TEAM_ROLE=lead WOLFMUX_TEAM=communication-management BEADS_ACTOR=communication-management.lead ANTHROPIC_API_KEY=idn-secret-2 PATH=/bin"
  printf '%s\t%s\t%s\t%s\n' 72002 1 "claude daemon run" "HOME=/y CLAUDE_CODE_OAUTH_TOKEN=idn-secret-3"
  printf '%s\t%s\t%s\t%s\n' 72003 1 "/usr/bin/vim notes-about-claude-daemon-run.txt" "EDITOR=vim"
} >"$DOCTOR_TABLE"
doctor_daemons() { # <table>
  (cd "$PROJECT" && WOLFMUX_PS_BIN="$REPO/tests/fake-ps" WOLFMUX_FAKE_PS_TABLE="$1" bash -c '
    set -euo pipefail
    for m in provider-env common registry tmuxctl worktree disk beads policy approvals agents views models doctor; do . "$WOLFMUX_HOME/lib/$m.sh"; done
    DOC_WARN=0 DOC_FAIL=0
    _doc_daemons
    echo "warnings=$DOC_WARN"' 2>&1)
}
DOCTOR_OUT="$(doctor_daemons "$DOCTOR_TABLE")"
check "doctor: the daemon with an identity is ONE warning naming it, its spawner pid and the fix" 'printf "%s" "$DOCTOR_OUT" | grep "pid 72001" | grep -F "TEAM_ROLE=lead" | grep -F "WOLFMUX_TEAM=communication-management" | grep -F "BEADS_ACTOR=communication-management.lead" | grep -F "started by pid 4321" | grep -F "claude stop <id>" | grep -qF "teamctl restart" && printf "%s" "$DOCTOR_OUT" | grep -q "^warnings=1$"'
check "doctor: the daemon without one is ok, and a process that only MENTIONS the words is no daemon" 'printf "%s" "$DOCTOR_OUT" | grep -q "ok .*pid 72002 carries no wolfmux identity" && ! printf "%s" "$DOCTOR_OUT" | grep -q 72003'
check "doctor: no other environment variable is ever printed (no token, no HOME, no PATH)" '! printf "%s" "$DOCTOR_OUT" | grep -qE "idn-secret|SECRET_TOKEN|ANTHROPIC_API_KEY|OAUTH|HOME=|PATH=|EDITOR"'
: >"$WORK/empty-ps"
check "doctor: no daemon at all is one ok line" 'doctor_daemons "$WORK/empty-ps" | grep -q "ok .*no Claude daemon running"'

teamctl inbox --all >/dev/null 2>&1

echo "== v1.23.0 (issue #34): what the sender is told, the lead-wake policy, and teamctl status"
# What _nudge_one decides for a lead, with tmux and typing stubbed: nothing here starts a
# process or reads the suite's tmux. The client list is the WOLFMUX_INBOX_CLIENT_LIST seam.
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/policy.sh"
  . "$WOLFMUX_HOME/lib/approvals.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  . "$WOLFMUX_HOME/lib/brand.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  . "$WOLFMUX_HOME/lib/agents.sh"
  STATE_DIR="$WORK/held-words"
  /bin/mkdir -p "$STATE_DIR/inbox"
  TEAM=default SESSION=irrelevant WOLFMUX_INBOX_STALL_NOTIFY=off WOLFMUX_NUDGE_TYPE=detached-lead WOLFMUX_WAKE_POLL=15
  unset WOLFMUX_INBOX_WATCHED
  OLD=$(($(date +%s) - 600))
  TYPED="$WORK/held-words.typed"
  : >"$TYPED"
  # the policy's own reader first (no meta.json here): the default, and an unreadable value
  [ "$(policy_get lead-wake)" = "unwatched" ] || exit 1
  [ "$(WOLFMUX_LEAD_WAKE=off policy_get lead-wake)" = "off" ] || exit 1
  [ "$(WOLFMUX_LEAD_WAKE=junk policy_get lead-wake)" = "unwatched" ] || exit 1
  FAMILY=claude
  reg_field() { [ "$2" = "family" ] && printf '%s\n' "$FAMILY"; }
  policy_get() { case "$1" in human-pane-typing) printf 'off\n' ;; *) printf 'unwatched\n' ;; esac; }
  tm_pane_for_role() { printf '%%5\n'; }
  tm_pane_state() { printf 'running\n'; }
  tm_pane_human_busy() { return 1; }
  tm_type_line() { printf '%s\n' "$2" >>"$TYPED"; }
  event_log() { :; }
  held() { # <bead> <expected exit> <expected words: a case pattern>
    local rc=0
    _nudge_one lead "$1" || rc=$?
    [ "$rc" -eq "$2" ] || return 1
    case "$NUDGE_FILED_WHY" in $3) return 0 ;; esac
    return 1
  }
  # 1. a Claude lead, a client attached, its pane not in use: filed, NOT typed (the typing
  #    rule is v1.20.0's); no waiter on record, so the sender is not promised a wake
  WOLFMUX_INBOX_CLIENTS=1 WOLFMUX_INBOX_CLIENT_LIST="%5|attached,UTF-8|$OLD"
  held w-1 4 "held for lead: no wake waiter runs for it*" || exit 1
  [ ! -s "$TYPED" ] || exit 1
  # 2. a live waiter on record: idle since when it armed, wakes itself within ~poll
  inbox_wake_write lead tok-1 "$OLD" "$$" || exit 1
  held w-2 4 "held for lead (idle since $(inbox_hhmmz "$OLD")): it wakes itself within ~15s" || exit 1
  # 3. a waiter whose process has gone is no waiter
  sleep 0 &
  gone=$!
  wait "$gone"
  inbox_wake_write lead tok-2 "$OLD" "$gone" || exit 1
  held w-3 4 "held for lead: no wake waiter runs*" || exit 1
  # 4. a prompt started a turn; 5. lead-wake off
  inbox_wake_write lead busy "$OLD" - || exit 1
  held w-4 4 "held for lead (in a turn since $(inbox_hhmmz "$OLD")): its Stop hook hands this over when that turn ends" || exit 1
  inbox_wake_write lead off "$OLD" - || exit 1
  held w-5 4 "held for lead: policy lead-wake is off*" || exit 1
  # 6. its pane in use (shown and focused): in front of a human
  WOLFMUX_INBOX_CLIENT_LIST="%5|attached,focused|$OLD"
  held w-6 4 "held for lead: its pane is in front of a human; it reads this at the next prompt" || exit 1
  [ ! -s "$TYPED" ] || exit 1
  # 7. a CODEX lead, a client attached, its pane not in use: typed (its only channel), and
  #    marked delivered; in use: filed
  FAMILY=codex WOLFMUX_INBOX_CLIENT_LIST="%5|attached,UTF-8|$OLD"
  rc=0
  _nudge_one lead w-7 || rc=$?
  [ "$rc" -eq 0 ] && grep -q "Beads update for lead (w-7)" "$TYPED" || exit 1
  grep "w-7" "$STATE_DIR/inbox/lead" | awk -F'\t' '{ exit !(substr($3, 2, 1) == "d") }' || exit 1
  WOLFMUX_INBOX_CLIENT_LIST="%5|attached,focused|$OLD"
  rc=0
  _nudge_one lead w-8 || rc=$?
  [ "$rc" -eq 4 ] && ! grep -q "w-8" "$TYPED" || exit 1
  # 8. a Claude lead with NOBODY attached: typed, exactly as v1.14.0 did it
  FAMILY=claude WOLFMUX_INBOX_CLIENTS=0 WOLFMUX_INBOX_CLIENT_LIST=""
  rc=0
  _nudge_one lead w-9 || rc=$?
  [ "$rc" -eq 0 ] && grep -q "Beads update for lead (w-9)" "$TYPED" || exit 1
  # 9. a worker the human is using keeps its v1.20.0 words; one shown but not in use is typed
  WOLFMUX_INBOX_CLIENTS=1 WOLFMUX_INBOX_CLIENT_LIST="%5|attached,focused|$OLD"
  rc=0
  _nudge_one qa w-11 || rc=$?
  [ "$rc" -eq 4 ] && case "$NUDGE_FILED_WHY" in "a human is watching qa's pane (an attached client shows this pane and its terminal has focus)"*) true ;; *) false ;; esac || exit 1
  WOLFMUX_INBOX_CLIENT_LIST="%5|attached,UTF-8|$OLD"
  rc=0
  _nudge_one qa w-12 || rc=$?
  [ "$rc" -eq 0 ] && grep -q "Beads update for qa (w-12)" "$TYPED" || exit 1
  exit 0
) >/dev/null 2>&1
HELD_WORDS_STATUS=$?
check "lead-wake reads unwatched by default and for nonsense; held for a lead: a Claude lead attached is filed with words that say whether it wakes itself (waiter, gone, turn, off, in use); a Codex lead is typed when not in use; a worker keeps its words" '[ "$HELD_WORDS_STATUS" -eq 0 ]'
check "lead-wake: unwatched by default, and teamctl policy shows it" 'teamctl policy | grep -qE "^  lead-wake +unwatched "'
check "lead-wake: an agent may not set it (exit 77), not the lead and not a worker, and it stays unwatched" '{ TEAM_ROLE=lead WOLFMUX_TEAM=default "$REPO/tests/in-pane" policy lead-wake off >/dev/null 2>&1; [ $? -eq 77 ]; } && { TEAM_ROLE=qa WOLFMUX_TEAM=default "$REPO/tests/in-pane" policy lead-wake off >/dev/null 2>&1; [ $? -eq 77 ]; } && teamctl policy | grep -qE "^  lead-wake +unwatched "'
check "lead-wake: you may set it, off and back, and nonsense is refused (exit 64)" 'teamctl policy lead-wake off | grep -q "lead-wake = off" && teamctl policy | grep -qE "^  lead-wake +off " && { teamctl policy lead-wake sometimes >/dev/null 2>&1; [ $? -eq 64 ]; } && teamctl policy lead-wake unwatched >/dev/null 2>&1 && teamctl policy | grep -qE "^  lead-wake +unwatched "'
# teamctl status: the lead's held notices, oldest first, and whether its waiter runs. The suite
# shell's own pid stands in for a live waiter.
/bin/cp "$(inbox_file lead)" "$WORK/lead-inbox.saved" 2>/dev/null || : >"$WORK/lead-inbox.saved"
printf '%s\tbeads\tnu\t[wolfmux] status-1\n%s\tbeads\tnu\t[wolfmux] status-2\n%s\tbeads\tnd\t[wolfmux] status-3\n' \
  "$(($(date +%s) - 900))" "$(($(date +%s) - 60))" "$(($(date +%s) - 3000))" >"$(inbox_file lead)"
printf 'tok-status %s %s\n' "$(($(date +%s) - 1200))" "$$" >"$INBOX/.wake.lead"
STATUS_TEXT="$(teamctl status 2>&1)"
STATUS_JSON="$(teamctl status --json 2>/dev/null)"
check "status: under the lead, one line with the held count, the oldest age and the waiter" 'printf "%s\n" "$STATUS_TEXT" | grep -q "held: 2 notices not yet given to the agent, oldest 15 min · it wakes itself when nobody is using its pane (idle since "'
check "status --json: held {count, oldest_epoch, wake} on the lead's row, and a worker with none has count 0" 'printf "%s" "$STATUS_JSON" | jq -e "(.agents[] | select(.role == \"lead\") | .held | .count == 2 and .wake == \"waiting\" and (.oldest_epoch | type) == \"number\") and (.agents[] | select(.role == \"aux\") | .held.count == 0)"'
/bin/rm -f "$INBOX/.wake.lead"
/bin/cp "$WORK/lead-inbox.saved" "$(inbox_file lead)"
check "status: no held line when the lead has nothing undelivered" ': >"$(inbox_file lead)" && ! teamctl status 2>&1 | grep -q "held: " && /bin/cp "$WORK/lead-inbox.saved" "$(inbox_file lead)"'

echo "== v1.23.0 (issue #34): the wake waiter, teamctl _inbox-wake"
# Its loop with the pane proof, tmux, time and the agent's process stubbed: sleep moves a fake
# clock, so each run takes no time and starts no process. on_tick runs after every sleep and is
# where a check makes something happen mid-wait. One end-to-end run on the suite's team follows.
(
  cd "$PROJECT" || exit 1
  # shellcheck disable=SC1090
  . "$WOLFMUX_HOME/lib/provider-env.sh"
  . "$WOLFMUX_HOME/lib/common.sh"
  . "$WOLFMUX_HOME/lib/registry.sh"
  . "$WOLFMUX_HOME/lib/tmuxctl.sh"
  . "$WOLFMUX_HOME/lib/policy.sh"
  . "$WOLFMUX_HOME/lib/approvals.sh"
  . "$WOLFMUX_HOME/lib/notify.sh"
  . "$WOLFMUX_HOME/lib/brand.sh"
  . "$WOLFMUX_HOME/lib/inbox.sh"
  . "$WOLFMUX_HOME/lib/agents.sh"
  STATE_DIR="$WORK/wake-unit"
  /bin/mkdir -p "$STATE_DIR/inbox"
  TEAM=default SESSION=irrelevant WOLFMUX_WAKE_POLL=15 WOLFMUX_WAKE_TIMEOUT=600
  unset WOLFMUX_INBOX_WATCHED WOLFMUX_INBOX_CLIENTS
  EVENTS="$WORK/wake-unit.events"
  OUT="$WORK/wake-unit.out"
  event_log() { printf '%s|%s|%s\n' "$1" "$2" "$3" >>"$EVENTS"; }
  FAKE_NOW=1000000000
  now_epoch() { printf '%s\n' "$FAKE_NOW"; }
  on_tick() { :; }
  sleep() { FAKE_NOW=$((FAKE_NOW + ${1%.*})); TICKS=$((TICKS + 1)); on_tick; [ "$TICKS" -lt 1000 ] || exit 9; }
  ROLE=lead
  _inbox_hook_ready() { INBOX_ROLE="$ROLE" INBOX_IDENTITY="$ROLE" INBOX_PANE=%5; return 0; }
  PANE_STATE=running POLICY=unwatched
  tm_pane_state() { printf '%s\n' "$PANE_STATE"; }
  policy_get() { case "$1" in lead-wake) printf '%s\n' "$POLICY" ;; human-pane-typing) printf 'off\n' ;; *) printf '\n' ;; esac; }
  FREE="%5|attached,UTF-8|0" BUSY="%5|attached,focused|0" # no key since 1970: only focus counts
  export WOLFMUX_INBOX_CLIENT_LIST="$FREE" WOLFMUX_WAKE_ALIVE="$PPID" WOLFMUX_WAKE_PPID=4242
  add() { inbox_add lead beads "[wolfmux] Beads update for lead ($1). Run: bd show $1"; }
  state() { awk -F'\t' -v t="$1" 'index($4, "(" t ")") { print substr($3, 2, 1) }' "$STATE_DIR/inbox/lead"; }
  last_event() { tail -1 "$EVENTS" | cut -d'|' -f1; }
  run() { TICKS=0 RC=0; : >"$EVENTS"; cmd_inbox_wake </dev/null >"$OUT" 2>/dev/null || RC=$?; }
  # 1. a notice waiting and nobody using the pane: exit 2 at the first look, the body on stdout,
  #    the notice taken, the record says a turn runs; the prompt hook then has nothing to give
  add n-1
  run
  [ "$RC" -eq 2 ] && [ "$TICKS" -eq 1 ] && grep -q "(n-1)" "$OUT" && grep -q "Read it now: bd list --assignee lead" "$OUT" || exit 1
  [ "$(state n-1)" = "d" ] && [ "$(last_event)" = "inbox-wake" ] || exit 1
  inbox_wake_read lead && [ "$WAKE_TOKEN" = "busy" ] || exit 1
  [ -z "$(cmd_inbox_prompt </dev/null)" ] || exit 1
  # 2. NO notices: never exit 2 with nothing to hand over (the measured wake loop); it waits
  #    out its lifetime (600 s timeout: 300 s, 20 looks) and then re-arms with one short line
  run
  [ "$RC" -eq 2 ] && [ "$TICKS" -eq 20 ] && [ "$(last_event)" = "inbox-wake-rearm" ] || exit 1
  grep -qx "\[wolfmux\] Your notice waiter re-arms after 300s. No new notices; nothing to do. End your turn." "$OUT" || exit 1
  ! grep -q "team notices" "$OUT" || exit 1
  # and the real timeout's words: 7 days, 300 s before Claude Code's 604800
  [ "$(WOLFMUX_WAKE_TIMEOUT=604800 _inbox_wake_life)" = "604500" ] || exit 1
  WOLFMUX_WAKE_TIMEOUT=604800 _inbox_wake_rearm tok 0 | grep -q "re-arms after 7 days. No new notices; nothing to do. End your turn." || exit 1
  # the lifetime is up under lead-wake off: it just ends
  on_tick() { [ "$TICKS" -ne 19 ] || POLICY=off; }
  run
  [ "$RC" -eq 0 ] && [ ! -s "$OUT" ] && [ "$(last_event)" = "inbox-wake-off" ] || exit 1
  POLICY=unwatched
  on_tick() { :; }
  # 3. a human using the pane: it keeps waiting, and wakes at the first look after he leaves
  add n-3
  WOLFMUX_INBOX_CLIENT_LIST="$BUSY"
  on_tick() { [ "$TICKS" -ne 5 ] || WOLFMUX_INBOX_CLIENT_LIST="$FREE"; }
  run
  [ "$RC" -eq 2 ] && [ "$TICKS" -eq 5 ] && grep -q "(n-3)" "$OUT" && [ "$(state n-3)" = "d" ] || exit 1
  # 4. two waiters one after the other: the first sees the second's token and ends, without waking
  on_tick() { [ "$TICKS" -ne 1 ] || { inbox_wake_write lead tok-second "$FAKE_NOW" 4243; add n-4; }; }
  run
  [ "$RC" -eq 0 ] && [ ! -s "$OUT" ] && [ "$(state n-4)" = "u" ] && [ "$(last_event)" = "inbox-wake-superseded" ] || exit 1
  # 5. a prompt (cmd_inbox_prompt) supersedes it as well; that prompt hands the notice over.
  #    The human is at the pane (in use), or the waiter would rightly wake at its first look.
  WOLFMUX_INBOX_CLIENT_LIST="$BUSY"
  on_tick() { [ "$TICKS" -ne 2 ] || cmd_inbox_prompt </dev/null >"$WORK/wake-unit.prompt"; }
  run
  [ "$RC" -eq 0 ] && [ "$TICKS" -eq 2 ] && [ ! -s "$OUT" ] && grep -q "(n-4)" "$WORK/wake-unit.prompt" && [ "$(last_event)" = "inbox-wake-superseded" ] || exit 1
  WOLFMUX_INBOX_CLIENT_LIST="$FREE"
  on_tick() { :; }
  #    and a prompt stamped LATER than the waiter started (the Stop/prompt race): it never arms
  inbox_wake_write lead busy $((FAKE_NOW + 1)) -
  add n-5
  run
  [ "$RC" -eq 0 ] && [ "$TICKS" -eq 0 ] && [ "$(state n-5)" = "u" ] && [ "$(last_event)" = "inbox-wake-superseded" ] || exit 1
  # 6. lead-wake off: not armed at all; turned off while waiting: ends, notices left alone
  POLICY=off
  run
  [ "$RC" -eq 0 ] && [ "$TICKS" -eq 0 ] && [ "$(last_event)" = "inbox-wake-off" ] || exit 1
  inbox_wake_read lead && [ "$WAKE_TOKEN" = "off" ] || exit 1
  POLICY=unwatched
  WOLFMUX_INBOX_CLIENT_LIST="$BUSY"
  on_tick() { [ "$TICKS" -ne 3 ] || POLICY=off; }
  run
  [ "$RC" -eq 0 ] && [ "$(state n-5)" = "u" ] && [ "$(last_event)" = "inbox-wake-off" ] || exit 1
  POLICY=unwatched
  # 7. it ends itself: the pane is gone; its agent is gone; it was re-parented to PID 1
  on_tick() { [ "$TICKS" -ne 2 ] || PANE_STATE=gone; }
  run
  [ "$RC" -eq 0 ] && [ "$TICKS" -eq 2 ] && [ "$(last_event)" = "inbox-wake-gone" ] || exit 1
  PANE_STATE=running
  on_tick() { :; }
  WOLFMUX_WAKE_ALIVE=""
  run
  [ "$RC" -eq 0 ] && [ "$TICKS" -eq 1 ] && [ "$(last_event)" = "inbox-wake-gone" ] || exit 1
  WOLFMUX_WAKE_ALIVE="$PPID" WOLFMUX_WAKE_PPID=1
  run
  [ "$RC" -eq 0 ] && [ "$TICKS" -eq 1 ] && [ "$(last_event)" = "inbox-wake-gone" ] || exit 1
  WOLFMUX_WAKE_PPID=4242
  _inbox_wake_owner_gone "$PPID" && exit 1
  _inbox_wake_owner_gone "" || exit 1
  _inbox_wake_owner_gone 1 || exit 1
  # 8. a worker never has one; and stdout that cannot be written puts the notices back
  ROLE=qa
  run
  [ "$RC" -eq 0 ] && [ "$TICKS" -eq 0 ] && [ ! -s "$EVENTS" ] || exit 1
  ROLE=lead WOLFMUX_INBOX_CLIENT_LIST="$FREE"
  eval "orig_$(declare -f inbox_hook_body)"
  inbox_hook_body() { return 1; } # the write to Claude fails
  run
  [ "$RC" -eq 0 ] && [ "$(state n-5)" = "u" ] && [ "$(last_event)" = "inbox-wake-failed" ] || exit 1
  grep -q "re-queued" "$EVENTS" || exit 1
  eval "$(declare -f orig_inbox_hook_body | sed '1s/^orig_//')"
  # 9. human-pane-typing idle: the typed waiter does not type a line a hook already handed over
  #    (and still types one that is waiting)
  TYPED="$WORK/wake-unit.typed"
  : >"$TYPED"
  tm_type_line() { printf '%s\n' "$2" >>"$TYPED"; }
  _notice_pane_busy() { return 1; }
  APPROVAL="[wolfmux] Permission request A9 from qa. Run: teamctl approvals"
  inbox_add lead approval "$APPROVAL"
  inbox_take_undelivered lead >/dev/null # the wake waiter took them all
  nudge_pending_open lead && nudge_pending_put_line lead "$APPROVAL" && nudge_pending_put_bead lead n-9 || exit 1
  : >"$EVENTS"
  _nudge_defer_wait lead %5
  [ ! -s "$TYPED" ] && ! nudge_pending_exists lead && [ "$(grep -c nudge-skip-delivered "$EVENTS")" = "2" ] || exit 1
  OTHER="[wolfmux] Team change: lead spawned teammate qa2 (flash). Run: teamctl status"
  inbox_add lead spawn "$OTHER"
  nudge_pending_open lead && nudge_pending_put_line lead "$OTHER" || exit 1
  _nudge_defer_wait lead %5
  grep -qxF "$OTHER" "$TYPED" || exit 1
  exit 0
) >/dev/null 2>&1
WAKE_UNIT_STATUS=$?
check "wake waiter: exit 2 only with notices (or the 7-day re-arm); waits while in use; one waiter (token), a prompt supersedes it; off, pane gone, agent gone, PID 1 end it; a failed print re-queues; the typed waiter skips what it took" '[ "$WAKE_UNIT_STATUS" -eq 0 ]'
# End to end, on the suite's own team: the dispatch, the pane proof and the real reads. Two
# waiters one after the other (the second is a later Stop), then a notice: the first ends
# without waking, the second wakes the lead with it. WOLFMUX_INBOX_CLIENT_LIST="" = nobody
# attached, so nobody is using the pane.
/bin/rm -f "$INBOX/.wake.lead" "$WORK"/wake-e2e.*
teamctl inbox lead >/dev/null 2>&1
hook lead _inbox-prompt >/dev/null 2>&1 # nothing undelivered before the waiters arm
( WOLFMUX_WAKE_POLL=1 WOLFMUX_INBOX_CLIENT_LIST="" hook_in "$LEAD_PANE" lead _inbox-wake >"$WORK/wake-e2e.1.out"; echo $? >"$WORK/wake-e2e.1.rc" ) &
sleep 2
( WOLFMUX_WAKE_POLL=1 WOLFMUX_INBOX_CLIENT_LIST="" hook_in "$LEAD_PANE" lead _inbox-wake >"$WORK/wake-e2e.2.out"; echo $? >"$WORK/wake-e2e.2.rc" ) &
sleep 3
WOLFMUX_NUDGE_TYPE=off teamctl nudge lead --id wake-e2e-1 >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  [ -s "$WORK/wake-e2e.1.rc" ] && [ -s "$WORK/wake-e2e.2.rc" ] && break
  sleep 1
done
check "wake end to end: the first waiter ends (exit 0) without waking once a second one arms" '[ "$(cat "$WORK/wake-e2e.1.rc" 2>/dev/null)" = "0" ] && [ ! -s "$WORK/wake-e2e.1.out" ]'
check "wake end to end: the second wakes the lead (exit 2) with the notice, marked delivered, and the event says so" '[ "$(cat "$WORK/wake-e2e.2.rc" 2>/dev/null)" = "2" ] && grep -q "wake-e2e-1" "$WORK/wake-e2e.2.out" && delivered_of lead wake-e2e-1 true && grep "\"type\":\"inbox-wake\"" "$STATE_DIR/events.jsonl" | tail -1 | grep -q "woke the agent with"'
check "wake end to end: the record now says a turn runs, so a sender is told so" 'read -r t _ <"$INBOX/.wake.lead" && [ "$t" = "busy" ]'
/bin/rm -f "$INBOX/.wake.lead"

teamctl destroy --worktrees --yes >/dev/null 2>&1

echo
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
