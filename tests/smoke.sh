#!/bin/bash
# smoke.sh — end-to-end lifecycle test of THIS checkout. No model is called.
#
# Fully isolated from any team you have running: its own tmux servers (sockets
# wolfmux-test-<pid> and wolfmux-test-old-<pid>), its own state directory, a throwaway git repository, and
# stub agents instead of real CLIs. Needs tmux, git, jq; Beads checks run when
# `bd` is installed.
#
#   tests/smoke.sh
# No pipefail: checks end in `grep -q`, which closes the pipe early by design.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-smoke.XXXXXX")"
export WOLFMUX_HOME="$REPO/config/wolfmux"
export WOLFMUX_BIN_DIR="$REPO/bin"
export WOLFMUX_DATA="$WORK/data"
export WOLFMUX_TMUX_SOCKET="wolfmux-test-$$"
export WOLFMUX_LAUNCHER_FABLE="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_ASTRA="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_GLM53="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_FLASH="$REPO/tests/stub-agent"
export ECC_DISABLED_HOOKS="post:example" # a hook the user already disables; teamctl must keep it
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR WOLFMUX_NOTIFY WOLFMUX_SPLASH TMUX TMUX_PANE
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

OLD_NAME_SOCKET="wolfmux-test-old-$$" # stands in for the socket of a team started before the rename
cleanup() {
  local socket
  for socket in "$WOLFMUX_TMUX_SOCKET" "$OLD_NAME_SOCKET"; do
    tmux -L "$socket" kill-server >/dev/null 2>&1
    /bin/rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$socket" # tmux leaves the socket file behind
  done
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
check "spawn: tiled 2x2-style layout, lead first" '[ "$(tmux -L "$WOLFMUX_TMUX_SOCKET" list-panes -a -F "#{pane_index}:#{@ai_role}" | head -1)" = "0:lead" ]'
check "spawn: pane titles are roles" 'tmux -L "$WOLFMUX_TMUX_SOCKET" list-panes -a -F "#{pane_title}" | grep -q "^backend · GLM-5.3$"'
check "validation: duplicate role refused" '! teamctl spawn backend glm53'
check "validation: reserved and malformed roles refused" '! teamctl spawn lead glm53 && ! teamctl spawn "Bad Role" glm53'
check "validation: flag without value reports usage (exit 64)" 'teamctl spawn x glm53 --base; [ $? -eq 64 ]'

echo "== the wolf (cosmetic: it may never break a command)"
SESSION_NAME="$(teamctl status --json | jq -r .session)"
pane_of() { teamctl status --json | jq -r --arg role "$1" '.agents[] | select(.role == $role) | .pane'; }
border_of() { tmux -L "$WOLFMUX_TMUX_SOCKET" display-message -p -t "$(pane_of "$1")" '#{E:pane-border-format} #{E:pane-border-style}'; }
check "wolf: opening the session shows the splash (popup on client-attached)" 'tmux -L "$WOLFMUX_TMUX_SOCKET" show-hooks -t "=$SESSION_NAME:" | grep -q "client-attached.*display-popup.*_splash"'
check "wolf: the splash draws the wolf, the wordmark and the team line" 'out="$(teamctl _splash </dev/null)" && [ "$(printf "%s\n" "$out" | grep -c "█")" -ge 12 ] && printf "%s\n" "$out" | grep -q "W O L F M U X" && printf "%s\n" "$out" | grep -q "lead GPT-6 Astra · 2 workers"'
check "wolf: no colour codes outside a terminal" '! teamctl _splash </dev/null | grep -q "$(printf "\033")"'
check "wolf: the splash still works outside any project" '(cd / && teamctl _splash </dev/null | grep -q "W O L F M U X")'
check "wolf: only the manager pane carries the mark and the amber border" 'border_of lead | grep -q "🐺.*fg=colour214" && ! border_of backend | grep -q "🐺" && border_of backend | grep -q "fg=colour244"'
check "wolf: the manager pane opens with the wolf" '[ "$(teamctl capture lead --all | grep -c "█")" -ge 12 ] && [ "$(teamctl capture backend --all | grep -c "█")" = 0 ]'
check "wolf: status line and terminal title carry it" 'tmux -L "$WOLFMUX_TMUX_SOCKET" show-options -gv status-left | grep -q "🐺" && tmux -L "$WOLFMUX_TMUX_SOCKET" show-options -gv set-titles-string | grep -q "🐺"'
check "wolf: WOLFMUX_SPLASH=off removes the popup, the default brings it back" 'WOLFMUX_SPLASH=off teamctl attach; ! tmux -L "$WOLFMUX_TMUX_SOCKET" show-hooks -t "=$SESSION_NAME:" | grep -q display-popup && { teamctl attach; tmux -L "$WOLFMUX_TMUX_SOCKET" show-hooks -t "=$SESSION_NAME:" | grep -q display-popup; }'

echo "== desktop notifications that lead back to the team"
FAKE_OSA="$WORK/fake-osascript"
printf '#!/bin/bash\nprintf "%%s\\n" "$@" >"%s"\n' "$WORK/osa.args" >"$FAKE_OSA"
/bin/chmod 755 "$FAKE_OSA"
notify() { WOLFMUX_OSASCRIPT="$FAKE_OSA" "$REPO/bin/teamctl" _notify; }
check "notify: every Claude agent gets the Stop hook; the plugin notifier is silenced, the user's own entry kept" 'teamctl capture backend --all | grep -q "STUB notify={\"stop\":true,\"silenced\":\"post:example,stop:desktop-notify\"}"'
check "notify: goes to the attached terminal as OSC 9 — first line, markdown dropped" 'printf "%s" "{\"last_assistant_message\":\"\\n**Done:** built \`x\`\\nsecond line\"}" | TEAM_ROLE=backend WOLFMUX_NOTIFY_TTY="$WORK/tty1" notify && [ "$(/bin/cat "$WORK/tty1")" = "$(printf "\033]9;backend: Done: built x\007")" ]'
check "notify: the manager is marked with the wolf" 'printf "%s" "{\"last_assistant_message\":\"merged\"}" | TEAM_ROLE=lead WOLFMUX_NOTIFY_TTY="$WORK/tty2" notify && grep -q "🐺 lead: merged" "$WORK/tty2"'
check "notify: escape sequences in a message never reach the terminal" 'jq -cn "{last_assistant_message: \"ok \u001b]52;c;aGk=\u0007 \u001b[2J done\"}" | TEAM_ROLE=qa WOLFMUX_NOTIFY_TTY="$WORK/tty3" notify && [ "$(LC_ALL=C tr -cd "\033\007" <"$WORK/tty3" | wc -c | tr -d " ")" = 2 ]'
check "notify: long messages are shortened" 'jq -cn "{last_assistant_message: (\"x\" * 400)}" | TEAM_ROLE=qa WOLFMUX_NOTIFY_TTY="$WORK/tty4" notify && [ "$(wc -m <"$WORK/tty4" | tr -d " ")" -lt 120 ]'
check "notify: with no terminal attached it falls back, text passed as an argument, and never fails" 'printf "not json" | TEAM_ROLE=qa notify && grep -q "^qa: finished$" "$WORK/osa.args" && grep -q "teamctl attach" "$WORK/osa.args"'
tmux -L "$WOLFMUX_TMUX_SOCKET" set-environment -g WOLFMUX_NOTIFY lead
teamctl restart qa >/dev/null 2>&1
sleep 2
check "notify: WOLFMUX_NOTIFY=lead keeps workers quiet (no hook, plugin notifier still silenced)" 'teamctl capture qa --all | grep "STUB notify=" | tail -1 | grep -q "{\"stop\":false,\"silenced\":\"post:example,stop:desktop-notify\"}"'
tmux -L "$WOLFMUX_TMUX_SOCKET" set-environment -gu WOLFMUX_NOTIFY
teamctl restart qa >/dev/null 2>&1
sleep 2

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
check "lead mode: no answer -> no decision, so the worker's own prompt appears" 'out="$(printf "%s" "$HOOK_IN" | WOLFMUX_APPROVAL_TIMEOUT=2 TEAM_ROLE=qa teamctl _permission-hook)"; [ -z "$out" ] && teamctl approvals --all | grep -q "A3 .*expired"'
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
check "destroy: tmux session gone" '! tmux -L "$WOLFMUX_TMUX_SOCKET" has-session 2>/dev/null'

echo "== a team started before the rename to Wolfmux"
# teamctl with the default socket follows a server that still runs under the old
# socket name. Here both names are test sockets, so the switch is set by hand.
follow() { WOLFMUX_ADOPT_LEGACY=1 WOLFMUX_LEGACY_SOCKET="$OLD_NAME_SOCKET" "$REPO/bin/teamctl" "$@"; }
WOLFMUX_TMUX_SOCKET="$OLD_NAME_SOCKET" teamctl start astra --no-attach --skip-beads >/dev/null 2>&1
sleep 1
check "rename: an explicitly chosen socket is never redirected" 'teamctl status --json | jq -e ".session_running | not"'
check "rename: teamctl follows the team on the old socket" 'follow status --json | jq -e ".session_running and (.agents[0].state == \"running\")"'
check "rename: new panes join that team" 'follow spawn docs flash --no-kickoff && sleep 1 && tmux -L "$OLD_NAME_SOCKET" list-panes -a -F "#{@ai_role}" | grep -qx docs'
check "rename: destroy ends it" 'follow destroy --worktrees --yes && ! tmux -L "$OLD_NAME_SOCKET" has-session 2>/dev/null'
check "rename: the next team starts on the new socket" 'follow start fable --no-attach --skip-beads && tmux -L "$WOLFMUX_TMUX_SOCKET" has-session && ! tmux -L "$OLD_NAME_SOCKET" has-session 2>/dev/null'
check "wolf: a Claude lead is named with the mark inside its own CLI, workers are not" 'follow spawn docs flash --no-kickoff && sleep 2 && teamctl capture lead --all | grep -q "STUB name=🐺 team/lead" && teamctl capture docs --all | grep -q "STUB name=team/docs"'
teamctl destroy --worktrees --yes >/dev/null 2>&1
/bin/mkdir -p "$PROJECT/.beads/hooks"
printf '#!/bin/bash\n# ai-team-hook v1 — written before the rename\nexit 0\n' >"$PROJECT/.beads/hooks/on_create"
printf '#!/bin/bash\n# somebody else wrote this\nexit 0\n' >"$PROJECT/.beads/hooks/on_close"
teamctl _refresh-hooks >/dev/null 2>&1
check "rename: a Beads hook written under the old name is replaced" 'grep -q "wolfmux-hook v1" "$PROJECT/.beads/hooks/on_create" && grep -q "/.config/wolfmux}/hooks/beads-nudge" "$PROJECT/.beads/hooks/on_create"'
check "rename: a hook that is not ours is still left alone" 'grep -q "somebody else wrote this" "$PROJECT/.beads/hooks/on_close"'

echo
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
