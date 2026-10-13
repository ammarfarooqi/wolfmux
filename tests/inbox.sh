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
#   · a client is attached and a human is WORKING in the lead pane -> nothing is typed
#     into it; the notice waits in the marker and arrives once that pane is quiet
#   · a client is attached and the lead pane is QUIET -> it IS typed (issue #12: a
#     filed notice reaches an agent through its Stop hook, and an agent that is already
#     idle has no turn boundary left, so filing alone never reached it)
#   · no client attached -> it IS typed, exactly as v1.14.0 did it
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
unset WOLFMUX_NUDGE_TYPE WOLFMUX_INBOX_CLIENTS WOLFMUX_INBOX_STALL_NOTIFY
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
# notify_deliver writes OSC 9 with no newline, so several banners land on one line:
# count the OCCURRENCES, not the lines. "1 notice waiting" is singular on purpose.
banners() { grep -o 'notices\{0,1\} waiting' "$WOLFMUX_NOTIFY_TTY" 2>/dev/null | wc -l | tr -d ' '; }
# state_of <role> <line-number> — the two-letter state column of one line
state_of() { awk -F'\t' -v n="$2" 'NR == n { print $3 }' "$(inbox_file "$1")" 2>/dev/null; }
# inbox_count_new_of <role> — notices this ONE role has that the human has not expanded
# (the badge itself counts the whole team, which is what the human wants to see)
inbox_count_new_of() { awk -F'\t' 'NF >= 4 && substr($3, 1, 1) == "n" { n++ } END { print n + 0 }' "$(inbox_file "$1")" 2>/dev/null; }
# A hook runs with the agent's own environment, in the agent's own directory.
hook() { # <role> <_inbox-stop|_inbox-prompt>
  (cd "$PROJECT" && TEAM_ROLE="$1" WOLFMUX_TEAM=default teamctl "$2" </dev/null 2>/dev/null)
}
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
check "settings: the Stop array has TWO entries, the notification hook and the inbox hook" '[ "$(jq ".hooks.Stop | length" "$SETTINGS")" = "2" ] && jq -e ".hooks.Stop[].hooks[].command | select(test(\"_notify$\"))" "$SETTINGS" && jq -e ".hooks.Stop[].hooks[].command | select(test(\"_inbox-stop\"))" "$SETTINGS"'
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

echo "== a client attached and a QUIET lead pane: the notice is typed after all (issue #12)"
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
check "attached + a quiet lead pane: and the Stop hook therefore has nothing to say about it" '[ -z "$(hook lead _inbox-stop)" ]'
check "attached + a quiet lead pane: the human still has it in the badge, unread" 'badge | grep -q "📨 1"'
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
check "attached + a human in the lead pane: the badge now shows the envelope and a count of 1" 'badge | grep -q "📨 1"'
check "attached + a human in the lead pane: the event log says deferred, not nudged" 'grep -q "nudge-deferred" "$STATE_DIR/events.jsonl"'

echo "== and the human is told once, by a banner that carries the count"
check "stall: exactly one desktop notification was raised" '[ "$(banners)" = "1" ]'
check "stall: it names the team and role and carries the count, not the bead id" 'grep -q "default/lead: 1 notice waiting" "$WOLFMUX_NOTIFY_TTY" && ! grep -q "quiet-1" "$WOLFMUX_NOTIFY_TTY"'
for n in 2 3 4 5 6 7 8 9 10 11; do teamctl nudge lead --id "burst-$n" >/dev/null 2>&1; done
sleep 1
check "stall: ten more beads inside the 120 s window raise NO second banner" '[ "$(banners)" = "1" ]'
check "stall: but every one of them is in the file, and the badge counts them all" 'badge | grep -q "📨 11" && [ "$(grep -c "burst-" "$(inbox_file lead)")" = "10" ]'
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

echo "== the Stop hook: the agent is told, once, and cannot loop"
STOP_OUT="$(hook lead _inbox-stop)"
check "Stop hook: it blocks, and the reason carries the notices and the Beads command" 'printf "%s" "$STOP_OUT" | jq -e ".decision == \"block\"" && printf "%s" "$STOP_OUT" | jq -r .reason | grep -q "quiet-1" && printf "%s" "$STOP_OUT" | jq -r .reason | grep -q "bd list --assignee lead"'
check "Stop hook: the lines were marked delivered BEFORE it answered" '[ "$(state_of lead 1)" = "nd" ]'
check "Stop hook: and the human's column is untouched, so the badge still counts them" 'badge | grep -q "📨"'
check "Stop hook: a second turn ending at once says nothing (cooldown)" '[ -z "$(hook lead _inbox-stop)" ]'
/bin/rm -f "$INBOX/.stop.lead"
check "Stop hook: and with the cooldown gone it STILL says nothing, because they are delivered" '[ -z "$(hook lead _inbox-stop)" ]'
check "Stop hook: an agent with no notices at all says nothing" '[ -z "$(hook no-such-role _inbox-stop)" ]'
teamctl nudge lead --id loop-1 >/dev/null 2>&1
check "Stop hook: a NEW notice blocks again, so nothing is starved by the two guards" 'hook lead _inbox-stop | jq -e ".decision == \"block\""'
check "Stop hook: it blocked exactly once for that notice, not twice" '[ -z "$(hook lead _inbox-stop)" ]'

echo "== the UserPromptSubmit hook: the same notices, on stdout, when the human types"
teamctl nudge lead --id prompt-1 >/dev/null 2>&1
PROMPT_OUT="$(hook lead _inbox-prompt)"
check "UserPromptSubmit: the notices are printed for the model's context" 'printf "%s" "$PROMPT_OUT" | grep -q "prompt-1" && printf "%s" "$PROMPT_OUT" | grep -q "bd list --assignee lead"'
check "UserPromptSubmit: it has no cooldown, but delivered notices are not repeated" '[ -z "$(hook lead _inbox-prompt)" ]'

echo "== the two states are independent, in both directions"
check "independence: everything is delivered to the agent, and all still new for the human" '[ "$(teamctl inbox lead --keep --json | jq "[.[] | select(.delivered == false)] | length")" = "0" ] && [ "$(teamctl inbox lead --keep --json | jq "[.[] | select(.new == false)] | length")" = "0" ]'
check "inbox --keep: printed them and left every one marked new" 'badge | grep -q "📨"'
# The badge counts the WHOLE team, so clearing it needs --all: the worker has notices of
# its own from the blocks above.
teamctl inbox --all >"$WORK/inbox-1.log" 2>&1
check "teamctl inbox: it printed the notices, oldest first" 'grep -q "quiet-1" "$WORK/inbox-1.log" && [ "$(grep -n "quiet-1" "$WORK/inbox-1.log" | cut -d: -f1)" -lt "$(grep -n "prompt-1" "$WORK/inbox-1.log" | cut -d: -f1)" ]'
check "teamctl inbox: it points at Beads for the work itself" 'grep -q "bd list --assignee" "$WORK/inbox-1.log"'
check "teamctl inbox --all: reading every role cleared the badge entirely" '[ -z "$(badge)" ]'
check "teamctl inbox: it cleared new-ness WITHOUT touching delivered-ness" '[ "$(state_of lead 1)" = "sd" ] && [ "$(teamctl inbox lead --keep --json | jq "[.[] | select(.delivered == false)] | length")" = "0" ]'
teamctl nudge lead --id both-1 >/dev/null 2>&1
check "independence the other way: a new notice is new for the human AND undelivered" '[ "$(teamctl inbox lead --keep --json | jq "[.[] | select(.new and (.delivered | not))] | length")" = "1" ]'
hook lead _inbox-stop >/dev/null 2>&1
check "independence the other way: the agent having it does NOT clear the human's badge" 'badge | grep -q "📨 1" && [ "$(inbox_count_new_of lead)" = "1" ]'
check "teamctl notices: the alias is the same command" 'teamctl notices lead --keep | grep -q "both-1"'
check "teamctl inbox --all: every role of the team, the worker included" 'teamctl inbox --all --keep | grep -q "^qa" && teamctl inbox --all --keep | grep -q "^lead"'
check "teamctl inbox: it is no longer the pointer-to-Beads message it used to print" '! teamctl inbox lead --keep 2>&1 | grep -q "is not a teamctl command"'
check "moved_to_beads still covers every other word it covered" 'teamctl send 2>&1 | grep -q "is not a teamctl command" && teamctl broadcast 2>&1 | grep -q "is not a teamctl command"'

echo "== an approval: the louder mark, and typed after the grace period if still unread"
teamctl inbox --all >/dev/null 2>&1
printf '%s\tapproval\tnu\t[wolfmux] Permission request A1 from qa. Run: teamctl approvals\n' "$(date +%s)" >>"$(inbox_file lead)"
check "approval: the badge adds the bell next to the envelope" 'badge | grep -q "📨 1 🔔"'
teamctl inbox lead >/dev/null 2>&1
check "approval: once read, the bell and the count are both gone" '[ -z "$(badge)" ]'
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

echo "== no client attached: the lead IS typed into, exactly as v1.14.0 did it"
# The region above left a half-typed line in the lead pane and a waiter behind it. Both
# have to go, or the next notice joins that marker instead of being typed into the pane.
tmx send-keys -t "$LEAD_PANE" Enter >/dev/null 2>&1
/bin/rm -rf "$(pending_dir lead)"
sleep 1
detach_client
sleep 1
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
check "dedupe: three events for the SAME bead file one line, so the badge reads 1" '[ "$(grep -c "dedupe-1" "$(inbox_file lead)")" = "1" ] && badge | grep -q "📨 1"'
WOLFMUX_NUDGE_DEBOUNCE=30 WOLFMUX_NUDGE_TYPE=off teamctl nudge lead --id dedupe-2 >/dev/null 2>&1
check "dedupe: a DIFFERENT bead is never collapsed away" 'badge | grep -q "📨 2" && grep -q "dedupe-2" "$(inbox_file lead)"'
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
check "killed waiter: and the agent is still given it by its own Stop hook" 'hook qa _inbox-stop | jq -r .reason | grep -q "survive-1"'
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

echo "== WOLFMUX_NUDGE_TYPE=all brings the pre-1.15.0 behaviour back"
attach_client
tmx select-pane -t "$PANE" >/dev/null 2>&1
sleep 4
BEFORE="$(notices lead "Beads update for lead")"
WOLFMUX_NUDGE_TYPE=all teamctl nudge lead --id all-1 >/dev/null 2>&1
ALL_STATUS=$?
sleep 2
check "WOLFMUX_NUDGE_TYPE=all: typed into an attached lead pane again, for whoever wants it" '[ "$ALL_STATUS" -eq 0 ] && teamctl capture lead --all | grep -q "Beads update for lead (all-1)"'
BEFORE="$(notices lead "Beads update for lead")"
WOLFMUX_NUDGE_TYPE=off teamctl nudge qa --id none-1 >/dev/null 2>&1
sleep 2
check "WOLFMUX_NUDGE_TYPE=off: not even a worker is typed into, and it is still filed" '! teamctl capture qa --all | grep -q "none-1" && grep -q "none-1" "$(inbox_file qa)"'
detach_client

echo "== the popup key, and the session option the two tmux format strings need"
check "tmux: prefix N is bound, and to a popup that runs the inbox" 'tmx list-keys -T prefix 2>/dev/null | grep -E "^bind-key +-T prefix +N " | grep -q "display-popup"'
check "tmux: prefix I was left alone, so a sourced ~/.tmux.conf keeps it" '! tmx list-keys -T prefix 2>/dev/null | grep -qE "^bind-key +-T prefix +I .*inbox"'
check "tmux: prefix T still re-tiles, so the key that was there already is untouched" 'tmx list-keys -T prefix 2>/dev/null | grep -qE "^bind-key +-T prefix +T +select-layout"'
check "tmux: the session knows where teamctl is, so the badge and the popup can run it" '[ -x "$(tmx show-options -t "=$SESSION:" -qv @wolfmux_teamctl)" ]'
check "tmux: status-interval is 5, so the count is never more than 5 s stale" '[ "$(tmx show-options -gqv status-interval)" = "5" ]'
check "tmux: status-left calls the badge" 'tmx show-options -gqv status-left | grep -q "_inbox-badge"'

echo "== the badge END TO END: the shipped status-left really runs it, and its output draws"
# Three things are needed together and all three were learned the hard way: a REAL pty
# client (with none, tmux never runs the #() job at all), time plus a forced refresh (one
# interval is not enough), and a LITERAL MARKER grepped out of the typescript. Do NOT try
# to read the result back through #{E:...} or #{T:...}: both come back empty even in a run
# that demonstrably rendered, so they are a dead end as verification.
printf '%s\tbeads\tnu\t[wolfmux] Beads update for lead (render-1)\n' "$(date +%s)" >>"$(inbox_file lead)"
printf '%s\tapproval\tnu\t[wolfmux] Permission request A9 from qa\n' "$(date +%s)" >>"$(inbox_file lead)"
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
check "badge end to end: the count and the approval bell are what was drawn" 'grep -ao "WOLFBADGE\[[^]]*\]" "$RENDER_TTY" 2>/dev/null | grep -q "🔔"'
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
printf '%s\tbeads\tnu\t[wolfmux] Beads update for lead (spaced-1)\n' "$(date +%s)" >>"$(inbox_file lead)"
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
  cmd_inbox_stop </dev/null >/dev/null 2>&1
  # both lines must be undelivered again, or they are lost for good
  [ "$(inbox_count_undelivered lead)" = "2" ] || exit 1
  # and the human's count is untouched by any of it
  [ "$(inbox_count_new lead)" = "2" ] || exit 1
  exit 0
) >/dev/null 2>&1
F7_STATUS=$?
check "F7: a Stop hook whose answer fails re-queues the notices instead of eating them" '[ "$F7_STATUS" -eq 0 ]'

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
EXPECT_LEAD_HOOKS='{"Stop":["\"<TEAMCTL>\" _notify","\"<TEAMCTL>\" _inbox-stop"],"UserPromptSubmit":["\"<TEAMCTL>\" _inbox-prompt"]}'
EXPECT_QA_HOOKS='{"PreToolUse":["\"<TEAMCTL>\" _guard"],"Stop":["\"<TEAMCTL>\" _notify","\"<TEAMCTL>\" _inbox-stop"],"UserPromptSubmit":["\"<TEAMCTL>\" _inbox-prompt"]}'
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
check "settings drift (lead): the key set is exactly env and hooks, and the hooks are exactly the notification hook, the inbox Stop hook and the inbox UserPromptSubmit hook" '[ "$DEFAULT_LEAD_KEYS" = "[\"env\",\"hooks\"]" ] && [ "$DEFAULT_LEAD_HOOKS" = "$EXPECT_LEAD_HOOKS" ]'
check "settings drift (worker): exactly env, hooks and teammateMode, and exactly the guard, the notification hook and the two inbox hooks" '[ "$DEFAULT_QA_KEYS" = "[\"env\",\"hooks\",\"teammateMode\"]" ] && [ "$DEFAULT_QA_HOOKS" = "$EXPECT_QA_HOOKS" ]'

teamctl inbox --all >/dev/null 2>&1

teamctl destroy --worktrees --yes >/dev/null 2>&1

echo
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
