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
#   · a client is attached and the lead is idle -> NOTHING is typed into the lead pane
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

echo "== a client attached and an idle lead: NOTHING is typed (this is issue #11)"
attach_client
tmx select-window -t "$WINDOW" >/dev/null 2>&1
tmx select-pane -t "$PANE" >/dev/null 2>&1 # the human is looking at the WORKER pane
sleep 4                                    # longer than WOLFMUX_NUDGE_HUMAN_IDLE
check "setup: a client is attached" '[ "$(clients)" = "1" ]'
BEFORE="$(notices lead "Beads update for lead")"
teamctl nudge lead --id quiet-1 >"$WORK/quiet-1.log" 2>&1
QUIET_STATUS=$?
sleep 2
check "attached + idle lead: exit 4, and the message says the notice was filed" '[ "$QUIET_STATUS" -eq 4 ] && grep -q "^filed:" "$WORK/quiet-1.log"'
check "attached + idle lead: NOTHING was typed into the lead pane" '[ "$(notices lead "Beads update for lead")" = "$BEFORE" ] && ! teamctl capture lead --all | grep -q "quiet-1"'
check "attached + idle lead: no waiter was parked either, so nothing can arrive later" '[ ! -d "$(pending_dir lead)" ]'
check "attached + idle lead: the notice IS in the file, new and undelivered" '[ "$(state_of lead 1)" = "nu" ] && grep -q "quiet-1" "$(inbox_file lead)"'
check "attached + idle lead: the badge now shows the envelope and a count of 1" 'badge | grep -q "📨 1"'
check "attached + idle lead: the event log says filed, not nudged" 'grep -q "inbox-filed" "$STATE_DIR/events.jsonl"'

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
# The real approval path needs a worker asking; drive notify_lead directly instead, which
# is the function every one of those callers uses.
(
  cd "$PROJECT" || exit 1
  WOLFMUX_INBOX_APPROVAL_GRACE=2 WOLFMUX_INBOX_APPROVAL_TYPE=grace \
    teamctl nudge lead --id grace-probe >/dev/null 2>&1
)
check "approval: a bead notice is still only filed, grace or no grace" '[ "$(notices lead "Permission request")" = "$LBEFORE" ]'
teamctl policy worker-permissions skip >/dev/null 2>&1
sleep 1
teamctl inbox --all >/dev/null 2>&1

echo "== no client attached: the lead IS typed into, exactly as v1.14.0 did it"
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
tmx set-option -g status-left 'WOLFBADGE[#(#{?@wolfmux_teamctl,#{@wolfmux_teamctl},teamctl} _inbox-badge "#{session_name}" "#{@wolfmux_root}" "#{@wolfmux_team}")]' >/dev/null 2>&1
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
tmx set-option -gu status-left >/dev/null 2>&1
tmx set-option -t "$SESSION" status-interval 5 >/dev/null 2>&1
teamctl inbox --all >/dev/null 2>&1

teamctl destroy --worktrees --yes >/dev/null 2>&1

echo
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
