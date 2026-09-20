#!/bin/bash
# smoke.sh — end-to-end lifecycle test of THIS checkout. No model is called.
#
# Fully isolated from any team you have running: its own tmux server (socket
# ai-team-test-<pid>), its own state directory, a throwaway git repository, and
# stub agents instead of real CLIs. Needs tmux, git, jq; Beads checks run when
# `bd` is installed.
#
#   tests/smoke.sh
# No pipefail: checks end in `grep -q`, which closes the pipe early by design.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ai-team-smoke.XXXXXX")"
export AI_TEAM_HOME="$REPO/config/ai-team"
export AI_TEAM_BIN_DIR="$REPO/bin"
export AI_TEAM_DATA="$WORK/data"
export AI_TEAM_TMUX_SOCKET="ai-team-test-$$"
export AI_TEAM_LAUNCHER_FABLE="$REPO/tests/stub-agent"
export AI_TEAM_LAUNCHER_ASTRA="$REPO/tests/stub-agent"
export AI_TEAM_LAUNCHER_GLM53="$REPO/tests/stub-agent"
export AI_TEAM_LAUNCHER_FLASH="$REPO/tests/stub-agent"
unset AI_TEAM_ROOT TEAM_ROLE BEADS_ACTOR
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

cleanup() {
  tmux -L "$AI_TEAM_TMUX_SOCKET" kill-server >/dev/null 2>&1
  /bin/rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$AI_TEAM_TMUX_SOCKET" # tmux leaves the socket file behind
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT

PROJECT="$WORK/demo project" # the space is deliberate
/bin/mkdir -p "$PROJECT"
cd "$PROJECT" || exit 1
git init -q -b main
echo "hello" >README.md
git add -A
git -c user.name=smoke -c user.email=smoke@example.invalid commit -qm "initial commit"
git branch release

HAVE_BD=0
START_FLAGS="--skip-beads"
if command -v bd >/dev/null 2>&1; then
  HAVE_BD=1
  START_FLAGS="--init-beads"
fi

echo "== lifecycle"
teamctl start astra --no-attach $START_FLAGS >/dev/null 2>&1
check "start: session running, lead registered" 'teamctl status --json | jq -e ".session_running and (.agents[0].role == \"lead\")"'
check "start: repository left clean (no commit, no tracked file)" '[ -z "$(git status --porcelain)" ] && [ "$(git rev-list --count HEAD)" = 1 ]'
teamctl spawn backend glm53 --base release >/dev/null 2>&1
teamctl spawn qa flash --no-kickoff >/dev/null 2>&1
sleep 2
check "spawn: two workers running" '[ "$(teamctl status --json | jq "[.agents[] | select(.kind == \"worker\" and .state == \"running\")] | length")" = 2 ]'
check "spawn: own branch per worker" '[ "$(git branch --list "ai/*" | wc -l | tr -d " ")" = 2 ]'
check "spawn: worktrees live outside the repository" 'teamctl status --json | jq -e --arg root "$PROJECT" "[.agents[] | select(.kind == \"worker\") | .workdir | startswith(\$root) | not] | all"'
check "spawn: --base recorded" 'teamctl diff backend | grep -q "base:    release"'
check "spawn: role environment set inside the pane" 'teamctl capture backend -n 8 | grep -q "STUB role=backend actor=backend model=glm53"'
check "spawn: no provider or agent-session variable leaks into a pane" 'teamctl capture backend -n 8 | grep -Eq "^STUB leaked= *$"'
check "spawn: kickoff prompt passed by default, omitted with --no-kickoff" 'teamctl capture backend -n 8 | grep -q "argc=6" && teamctl capture qa -n 8 | grep -q "argc=5"'
check "spawn: tiled 2x2-style layout, lead first" '[ "$(tmux -L "$AI_TEAM_TMUX_SOCKET" list-panes -a -F "#{pane_index}:#{@ai_role}" | head -1)" = "0:lead" ]'
check "spawn: pane titles are roles" 'tmux -L "$AI_TEAM_TMUX_SOCKET" list-panes -a -F "#{pane_title}" | grep -q "^backend · GLM-5.3$"'
check "validation: duplicate role refused" '! teamctl spawn backend glm53'
check "validation: reserved and malformed roles refused" '! teamctl spawn lead glm53 && ! teamctl spawn "Bad Role" glm53'
check "validation: flag without value reports usage (exit 64)" 'teamctl spawn x glm53 --base; [ $? -eq 64 ]'

echo "== one manager, permissions, spawning"
check "policy: defaults are skip / skip / worker spawning off" 'teamctl status --json | jq -e ".manager == \"lead\" and .policy == {lead_permissions: \"skip\", worker_permissions: \"skip\", worker_spawn: \"off\"}"'
check "permissions: lead and workers start in their CLI's bypass mode" 'teamctl capture lead -n 8 | grep -q "flags=--dangerously-bypass-approvals-and-sandbox" && teamctl capture backend -n 8 | grep -q "flags=--dangerously-skip-permissions"'
check "hierarchy: the CLI's own agent-teams feature is switched off inside workers" 'teamctl capture backend -n 8 | grep -q "settings={\"teams\":\"0\",\"mode\":\"in-process\",\"hook\":false}"'
check "hierarchy: the lead's own settings are left alone" 'teamctl capture lead -n 8 | grep -q "settings=none"'
check "spawning: refused for a worker while the toggle is off (exit 77)" 'TEAM_ROLE=backend teamctl spawn helper flash; [ $? -eq 77 ] && [ -z "$(git branch --list "ai/helper-*")" ]'
check "manager only: a worker cannot stop, restart, destroy, approve or change policy" 'for c in "stop qa" "restart qa" "destroy --yes" "policy worker-spawn on" "approve A1" "deny A1 no"; do TEAM_ROLE=backend teamctl $c; [ $? -eq 77 ] || exit 1; done'
teamctl policy worker-spawn on >/dev/null 2>&1
sleep 1
check "spawning: allowed for a worker once the toggle is on" 'TEAM_ROLE=backend teamctl spawn helper flash --no-kickoff'
check "spawning: the record and status say who spawned whom" 'teamctl status --json | jq -e ".agents[] | select(.role == \"helper\") | .spawned_by == \"backend\""'
check "spawning: the lead is told" 'sleep 1; teamctl capture lead -n 12 | grep -q "Team change: backend spawned teammate helper (GLM-5.3 Flash)"'
teamctl stop helper >/dev/null 2>&1
teamctl policy worker-spawn off >/dev/null 2>&1

echo "== the lead decides workers' permission requests (worker-permissions=lead)"
teamctl policy worker-permissions lead >/dev/null 2>&1
teamctl restart qa >/dev/null 2>&1
sleep 2
check "lead mode: worker starts without bypass, with the permission-request hook" 'teamctl capture qa -n 8 | grep -q "flags=none" && teamctl capture qa -n 8 | grep -q "\"hook\":true"'
HOOK_IN='{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm install left-pad"}}'
(printf '%s' "$HOOK_IN" | TEAM_ROLE=qa teamctl _permission-hook >"$WORK/hook1.out" 2>/dev/null) &
sleep 3
check "lead mode: the request is filed and the lead is told" 'teamctl approvals | grep -q "A1 .*qa .*Bash .*pending .*npm install left-pad" && teamctl capture lead -n 12 | grep -q "Permission request A1 from qa"'
check "lead mode: status shows the pending request" 'teamctl status --json | jq -e ".approvals_pending == 1"'
check "lead mode: a worker cannot approve its own request" 'TEAM_ROLE=qa teamctl approve A1; [ $? -eq 77 ]'
teamctl approve A1 >/dev/null 2>&1
sleep 2
check "lead mode: approve -> the worker's CLI receives allow" 'jq -e ".hookSpecificOutput.hookEventName == \"PermissionRequest\" and .hookSpecificOutput.decision.behavior == \"allow\"" "$WORK/hook1.out"'
(printf '%s' "$HOOK_IN" | TEAM_ROLE=qa teamctl _permission-hook >"$WORK/hook2.out" 2>/dev/null) &
sleep 3
teamctl deny A2 "use npm ci instead" >/dev/null 2>&1
sleep 2
check "lead mode: deny -> the worker's CLI receives deny with the reason" 'jq -e ".hookSpecificOutput.decision.behavior == \"deny\" and (.hookSpecificOutput.decision.message | contains(\"use npm ci instead\"))" "$WORK/hook2.out"'
check "lead mode: no answer -> no decision, so the worker's own prompt appears" 'out="$(printf "%s" "$HOOK_IN" | AI_TEAM_APPROVAL_TIMEOUT=2 TEAM_ROLE=qa teamctl _permission-hook)"; [ -z "$out" ] && teamctl approvals --all | grep -q "A3 .*expired"'
teamctl policy worker-permissions ask >/dev/null 2>&1
teamctl restart qa >/dev/null 2>&1
sleep 2
check "ask mode: no bypass flag and no hook" 'teamctl capture qa -n 8 | grep -q "flags=none" && teamctl capture qa -n 8 | grep -q "\"hook\":false"'
teamctl policy worker-permissions skip >/dev/null 2>&1

echo "== notifications"
check "nudge: fixed line typed into the pane" 'teamctl nudge qa --id abc-123 && sleep 1 && teamctl capture qa -n 8 | grep -q "Beads update for qa (abc-123)"'
check "nudge: debounced inside the window" 'teamctl nudge qa | grep -q skipped'
sleep 4
check "nudge: hostile bead id is dropped, never typed" 'teamctl nudge qa --id "x;rm -rf ~" && sleep 1 && ! teamctl capture qa -n 12 | grep -q "rm -rf"'
if [ "$HAVE_BD" -eq 1 ]; then
  sleep 4
  BEADS_ACTOR=lead TEAM_ROLE=lead bd create "Quote test" -t message -a backend -d 'body with "quotes" $HOME `ticks`' --silent >/dev/null 2>&1
  sleep 3
  check "beads: message to a role notifies its pane" 'teamctl capture backend -n 12 | grep -q "Beads update for backend"'
  check "beads: body is stored intact and never typed into the pane" 'bd list --assignee backend --status open --include-infra --json | jq -e ".[0].description | contains(\"\$HOME\")" && ! teamctl capture backend -n 20 | grep -q ticks'
  check "beads: a worker reaches the shared database from its worktree" '(cd "$(teamctl status --json | jq -r ".agents[] | select(.role == \"backend\") | .workdir")" && bd list --assignee backend --status open --include-infra --json | jq -e "length == 1")'
else
  echo "  skip  Beads checks (bd not installed)"
fi

echo "== git"
BACKEND_DIR="$(teamctl status --json | jq -r '.agents[] | select(.role == "backend") | .workdir')"
echo "work" >"$BACKEND_DIR/work.txt"
(cd "$BACKEND_DIR" && git add -A && git -c user.name=backend -c user.email=b@example.invalid commit -qm "feat: work")
echo "scratch" >"$BACKEND_DIR/untracked.tmp"
check "diff: commits, stat and patch" 'teamctl diff backend --commits | grep -q "feat: work" && teamctl diff backend --stat | grep -q work.txt && teamctl diff backend | grep -q "^+work"'
check "diff: uncommitted leftovers visible" 'teamctl diff backend --working | grep -q untracked.tmp'
check "isolation: main checkout untouched by worker commits" '[ ! -e "$PROJECT/work.txt" ] && [ -z "$(git -C "$PROJECT" status --porcelain)" ]'
check "worktrees: lists lead + workers" '[ "$(teamctl worktrees | grep -cE "^(lead|backend|qa) ")" = 3 ]'

echo "== stop / restart / destroy"
check "stop: pane closed, record kept" 'teamctl stop qa && teamctl status --json | jq -e ".agents[] | select(.role == \"qa\") | .state == \"stopped\""'
check "restart: same worktree and branch" 'before="$(git branch --list "ai/qa-*")" && teamctl restart qa && [ "$(git branch --list "ai/qa-*")" = "$before" ] && teamctl status --json | jq -e ".agents[] | select(.role == \"qa\") | .state == \"running\""'
check "destroy: refuses without confirmation when not interactive" '! teamctl destroy --worktrees </dev/null'
check "destroy: runs with --yes" 'teamctl destroy --worktrees --yes'
check "destroy: dirty worktree with an unmerged commit is kept" '[ -d "$BACKEND_DIR" ] && git rev-parse -q --verify "refs/heads/$(git -C "$BACKEND_DIR" branch --show-current)"'
check "destroy: clean worktree removed, merged branch deleted" '[ -z "$(git branch --list "ai/qa-*")" ]'
check "destroy: tmux session gone" '! tmux -L "$AI_TEAM_TMUX_SOCKET" has-session 2>/dev/null'

echo
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
