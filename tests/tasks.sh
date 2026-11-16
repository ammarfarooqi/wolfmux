#!/bin/bash
# tasks.sh — standalone test of `teamctl task` / `done` / `blocked`, the Stop reminder
# (tasks_hook), and the new kickoff text. No model is called.
#
# Fully isolated from any team you have running: its own tmux socket (wolfmux-tasks-<pid>),
# its own state directory, a throwaway git repository, and stub agents instead of real
# CLIs. Needs tmux, git, jq, and a real `bd` (these commands shell out to it); without one
# installed this file reports and exits 0 rather than failing a check it cannot run.
#
#   tests/tasks.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-tasks.XXXXXX")"
export WOLFMUX_HOME="$REPO/config/wolfmux"
export WOLFMUX_BIN_DIR="$REPO/bin"
export WOLFMUX_DATA="$WORK/data"
export WOLFMUX_TMUX_SOCKET="wolfmux-tasks-$$"
export WOLFMUX_LAUNCHER_ASTRA="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_GLM53="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_FLASH="$REPO/tests/stub-agent"
export WOLFMUX_CLAUDE_PROJECTS="$WORK/claude-projects"
export WOLFMUX_CODEX_SESSIONS="$WORK/codex-sessions"
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR WOLFMUX_NOTIFY WOLFMUX_SPLASH WOLFMUX_METERED TMUX TMUX_PANE
unset WOLFMUX_TEAM WOLFMUX_TEAM_ARG WOLFMUX_SESSION WOLFMUX_WORKTREE WOLFMUX_BRANCH WOLFMUX_MODEL WOLFMUX_EXTRA_SETTINGS
teamctl() { "$REPO/bin/teamctl" "$@"; }

# last_task_id — pulls <id> out of cmd_task's required last line: "task <id> -> <identity>"
last_task_id() { tail -1 | sed -E 's/^task ([^ ]+) ->.*/\1/'; }

# kickoff_of <role> <identity> <provider> <family> — kickoff_text's exact output, without
# going through a spawned pane (whose stub only echoes the first 200 characters of it).
kickoff_of() {
  (
    for module in provider-env common registry tmuxctl worktree beads policy approvals agents views doctor brand notify layout guard completion hooks mail memory tasks; do
      . "$WOLFMUX_HOME/lib/$module.sh"
    done
    kickoff_text "$1" "$2" "$3" "$4"
  ) 2>/dev/null
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

cleanup() {
  tmux -L "$WOLFMUX_TMUX_SOCKET" kill-server >/dev/null 2>&1
  /bin/rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$WOLFMUX_TMUX_SOCKET"
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT

if ! command -v bd >/dev/null 2>&1; then
  echo "tests/tasks.sh needs bd (Beads) installed; nothing to test here without it."
  exit 0
fi

PROJECT="$WORK/project"
/bin/mkdir -p "$PROJECT"
cd "$PROJECT" || exit 1
git init -q -b main
echo hello >README.md
git add -A
git -c user.name=t -c user.email=t@example.invalid commit -qm "initial commit"

teamctl start astra --no-attach --init-beads >/dev/null 2>&1
teamctl spawn backend glm53 >/dev/null 2>&1
sleep 1
BACKEND_DIR="$(teamctl status --json | "$(command -v jq)" -r '[.agents[] | select(.role == "backend")][0].workdir')"

echo "== teamctl task"
T1="$(teamctl task backend "First task" -d "body text" -p 1 | last_task_id)"
check "task: creates a bead, assignee is the role's identity, priority stored" \
  'bd show "$T1" --json | jq -e ".[0].assignee == \"backend\" and .[0].priority == 1 and .[0].issue_type == \"task\""'
T2="$(teamctl task backend "Second task" -d "after first" --after "$T1" | last_task_id)"
check "task: --after wires a dependency (T2 depends on T1)" 'bd dep list "$T2" | grep -q "$T1"'
check "task: a worker cannot create one (exit 77)" 'TEAM_ROLE=backend teamctl task backend "nope" -d x; [ $? -eq 77 ]'
check "task: an invalid --after bead id is a usage error (64)" 'teamctl task backend "x" -d x --after "bad!id"; [ $? -eq 64 ]'
check "task: a priority outside 0-4 is a usage error (64)" 'teamctl task backend "x" -d x -p 9; [ $? -eq 64 ]'

echo "== teamctl task --spawn"
SPAWN_OUT="$(teamctl task newrole "Spawn me" -d x --spawn glm53 2>&1)"
check "task --spawn: a new role gets spawned" 'printf "%s" "$SPAWN_OUT" | grep -q "^spawned:   newrole"'
check "task --spawn: the role now exists" 'teamctl status --json | jq -e "[.agents[] | select(.role == \"newrole\")] | length == 1"'
AGAIN_OUT="$(teamctl task backend "Already running" -d x --spawn glm53 2>&1)"
check "task --spawn: a no-op line when the role is already running" 'printf "%s" "$AGAIN_OUT" | grep -q "spawn ignored"'

echo "== teamctl done"
DONE_ID="$(teamctl task backend "Do the thing" -d body | last_task_id)"
BEADS_ACTOR=backend TEAM_ROLE=backend bd update "$DONE_ID" --claim >/dev/null 2>&1
echo wip >"$BACKEND_DIR/wip.txt"
check "done: refuses a dirty worktree" 'TEAM_ROLE=backend teamctl done "Summary"; [ $? -ne 0 ] && [ -z "$(bd show "$DONE_ID" --json | jq -r ".[0].status")" -o "$(bd show "$DONE_ID" --json | jq -r ".[0].status")" = "in_progress" ]'
(cd "$BACKEND_DIR" && git add -A && git -c user.name=w -c user.email=w@example.invalid commit -qm "did the thing")
DONE_OUT="$(BEADS_ACTOR=backend TEAM_ROLE=backend teamctl done "Summary line" --tests "tests/foo.sh: 3 passed" 2>&1)"
check "done: reports what it sent and closed" 'printf "%s" "$DONE_OUT" | grep -q "^sent: Done: Do the thing -> lead$" && printf "%s" "$DONE_OUT" | grep -q "^closed: $DONE_ID$"'
check "done: the task is closed" 'bd show "$DONE_ID" --json | jq -e ".[0].status == \"closed\""'
MSG_ID="$(bd list --assignee lead --status open --include-infra --json | jq -r '[.[] | select(.title == "Done: Do the thing")][0].id')"
MSG_DESC="$(bd show "$MSG_ID" --json | jq -r '.[0].description')"
check "done: the report has the summary, the tests line, the branch, and a commit count" \
  'printf "%s" "$MSG_DESC" | grep -q "^Summary line$" && printf "%s" "$MSG_DESC" | grep -q "tests/foo.sh: 3 passed" && printf "%s" "$MSG_DESC" | grep -q "^branch: " && printf "%s" "$MSG_DESC" | grep -Eq "^commits \([0-9]+\):"'
check "done: the report replies to the task" 'bd dep list "$MSG_ID" | grep -q "$DONE_ID"'
check "done: the task is closed with the short commit sha in the reason (bd show, plain text)" \
  'cd "$BACKEND_DIR" && bd show "$DONE_ID" 2>&1 | grep -q "$(git rev-parse --short HEAD)"'

DONE_ID2="$(teamctl task backend "Second open task" -d x | last_task_id)"
BEADS_ACTOR=backend TEAM_ROLE=backend bd update "$DONE_ID2" --claim >/dev/null 2>&1
DONE_ID3="$(teamctl task backend "Third open task" -d x | last_task_id)"
BEADS_ACTOR=backend TEAM_ROLE=backend bd update "$DONE_ID3" --claim >/dev/null 2>&1
check "done: two in_progress tasks and no id given exits 64 and lists both" \
  'out="$(TEAM_ROLE=backend teamctl done "Which one" 2>&1)"; rc=$?; [ $rc -eq 64 ] && printf "%s" "$out" | grep -q "$DONE_ID2" && printf "%s" "$out" | grep -q "$DONE_ID3"'
echo wip2 >"$BACKEND_DIR/wip2.txt"
check "done: --allow-dirty closes despite an uncommitted file" \
  'BEADS_ACTOR=backend TEAM_ROLE=backend teamctl done "$DONE_ID2" "closing with dirt" --allow-dirty && bd show "$DONE_ID2" --json | jq -e ".[0].status == \"closed\""'
(cd "$BACKEND_DIR" && git add -A && git -c user.name=w -c user.email=w@example.invalid commit -qm "the dirt, committed")

echo "== teamctl blocked"
BLOCK_OUT="$(TEAM_ROLE=backend teamctl blocked "$DONE_ID3" "waiting on the lead" 2>&1)"
check "blocked: sets status, appends the reason as a note, and tells the lead" \
  'bd show "$DONE_ID3" --json | jq -e ".[0].status == \"blocked\"" && bd show "$DONE_ID3" --json | jq -r ".[0].notes // empty" | grep -q "waiting on the lead" && printf "%s" "$BLOCK_OUT" | grep -q "^sent: Blocked: Third open task -> lead$" && printf "%s" "$BLOCK_OUT" | grep -q "^blocked: $DONE_ID3$"'
BMSG_ID="$(bd list --assignee lead --status open --include-infra --json | jq -r '[.[] | select(.title == "Blocked: Third open task")][0].id')"
check "blocked: the message replies to the task" 'bd dep list "$BMSG_ID" | grep -q "$DONE_ID3"'

echo "== Stop hook: nobody stops with work forgotten"
teamctl spawn hooker glm53 --no-kickoff >/dev/null 2>&1
sleep 1
HOOK_ID="$(teamctl task hooker "Hook task" -d x | last_task_id)"
BEADS_ACTOR=hooker TEAM_ROLE=hooker bd update "$HOOK_ID" --claim >/dev/null 2>&1
HOOK_DIR="$WORK/run-hooker"
/bin/mkdir -p "$HOOK_DIR/mail" "$HOOK_DIR/memory"
OUT1="$(printf '{}' | TEAM_ROLE=hooker WOLFMUX_RUN_DIR="$HOOK_DIR" teamctl _hook Stop)"
check "stop hook: reminds once about the in_progress task" \
  'printf "%s" "$OUT1" | grep -q "$HOOK_ID" && printf "%s" "$OUT1" | grep -q "teamctl done"'
OUT2="$(printf '{}' | TEAM_ROLE=hooker WOLFMUX_RUN_DIR="$HOOK_DIR" teamctl _hook Stop)"
check "stop hook: silent the second time (marker already written)" '[ -z "$OUT2" ]'

teamctl spawn hooker2 glm53 --no-kickoff >/dev/null 2>&1
sleep 1
HOOK_ID2="$(teamctl task hooker2 "Unclaimed task" -d x | last_task_id)"
HOOK2_DIR="$WORK/run-hooker2"
/bin/mkdir -p "$HOOK2_DIR/mail" "$HOOK2_DIR/memory"
OUT3="$(printf '{}' | TEAM_ROLE=hooker2 WOLFMUX_RUN_DIR="$HOOK2_DIR" teamctl _hook Stop)"
check "stop hook: an open, unclaimed task is pointed out once" \
  'printf "%s" "$OUT3" | grep -q "$HOOK_ID2" && printf "%s" "$OUT3" | grep -q "Claim it and start"'
OUT4="$(printf '{}' | TEAM_ROLE=hooker2 WOLFMUX_RUN_DIR="$HOOK2_DIR" teamctl _hook Stop)"
check "stop hook: silent the second time for the open task too" '[ -z "$OUT4" ]'

HOOK3_DIR="$WORK/run-hooker3"
/bin/mkdir -p "$HOOK3_DIR/mail" "$HOOK3_DIR/memory"
OUT5="$(printf '{"stop_hook_active": true}' | TEAM_ROLE=hooker WOLFMUX_RUN_DIR="$HOOK3_DIR" teamctl _hook Stop)"
check "stop hook: stop_hook_active silences it" '[ -z "$OUT5" ]'

LEAD_DIR="$WORK/run-lead"
/bin/mkdir -p "$LEAD_DIR/mail" "$LEAD_DIR/memory"
OUT6="$(printf '{}' | TEAM_ROLE=lead WOLFMUX_RUN_DIR="$LEAD_DIR" teamctl _hook Stop)"
check "stop hook: the lead is never reminded" '[ -z "$OUT6" ]'

NOBD_HOME="$WORK/no-bd-home"
/bin/mkdir -p "$NOBD_HOME"
NOBD_PATH="$(dirname "$(command -v tmux)"):$(dirname "$(command -v git)"):$(dirname "$(command -v jq)"):/usr/bin:/bin"
NOBD_DIR="$WORK/run-nobd"
/bin/mkdir -p "$NOBD_DIR/mail" "$NOBD_DIR/memory"
check "stop hook: bd unavailable (PATH and HOME without it) is silent and exits 0" \
  'out="$(printf "{}" | HOME="$NOBD_HOME" PATH="$NOBD_PATH" TEAM_ROLE=hooker WOLFMUX_RUN_DIR="$NOBD_DIR" teamctl _hook Stop)"; rc=$?; [ -z "$out" ] && [ "$rc" -eq 0 ]'

echo "== kickoff text"
KICKOFF_CLAUDE="$(kickoff_of backend review.backend "" claude)"
check "kickoff (Claude family): no longer tells the worker to run bd list" '! printf "%s" "$KICKOFF_CLAUDE" | grep -q "bd list --assignee"'
check "kickoff (Claude family): says to claim first, and not to start over if restarted mid-task" \
  'printf "%s" "$KICKOFF_CLAUDE" | grep -q "teamctl claim <id>" && printf "%s" "$KICKOFF_CLAUDE" | grep -q "do not start over" && printf "%s" "$KICKOFF_CLAUDE" | grep -q "teamctl diff backend --commits"'
check "kickoff (Claude family): falls back to teamctl inbox when nothing was shown above" 'printf "%s" "$KICKOFF_CLAUDE" | grep -q "teamctl inbox"'

KICKOFF_CODEX="$(kickoff_of backend review.backend "" codex)"
check "kickoff (Codex): names teamctl inbox instead of bd list + bd show" \
  'printf "%s" "$KICKOFF_CODEX" | grep -q "run \`teamctl inbox\`" && ! printf "%s" "$KICKOFF_CODEX" | grep -q "bd list --assignee" && ! printf "%s" "$KICKOFF_CODEX" | grep -q "bd show"'
check "kickoff (Codex): still says not to start over if restarted mid-task" 'printf "%s" "$KICKOFF_CODEX" | grep -q "do not start over"'

echo "== named team"
# A second team: once it exists, every teamctl call below needs --team (ambiguous
# otherwise), so this stays last.
teamctl start astra --team review --no-attach --skip-beads >/dev/null 2>&1
teamctl spawn backend glm53 --team review >/dev/null 2>&1
sleep 1
T3="$(teamctl task backend "Team task" -d x --team review | last_task_id)"
check "task: in a named team the assignee is <team>.role" 'bd show "$T3" --json | jq -e ".[0].assignee == \"review.backend\""'

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
