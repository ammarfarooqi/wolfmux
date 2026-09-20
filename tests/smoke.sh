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

echo "== launchers (dry run: nothing is started, no key is read)"
glm_dry() { env -u WOLFMUX_GLM_CONTEXT WOLFMUX_DRY_RUN=1 "$@" "$REPO/bin/claude-glm" 2>&1; }
check "claude-glm: declares a 200k context window, so Claude Code prints no model-catalog notice" 'glm_dry | grep -q "^context window: *200000 tokens"'
check "claude-glm: 1m uses the [1m] suffix instead; a number of yours is declared; nonsense falls back with a warning" 'glm_dry WOLFMUX_GLM_CONTEXT=1m | grep -q "^context window: *1M" && glm_dry WOLFMUX_GLM_CONTEXT=128000 | grep -q "^context window: *128000 tokens" && glm_dry WOLFMUX_GLM_CONTEXT=huge | grep -q "must be .1m. or a number"'
check "claude-glm: a context value from outside never reaches the worker (it is scrubbed, then set)" 'glm_dry CLAUDE_CODE_MAX_CONTEXT_TOKENS=5 | grep -q "^context window: *200000 tokens"'

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
check "spawn: the lead is the first pane" '[ "$(tmux -L "$WOLFMUX_TMUX_SOCKET" list-panes -a -F "#{pane_index}:#{@ai_role}" | head -1)" = "0:lead" ]'
check "spawn: pane titles are roles" 'tmux -L "$WOLFMUX_TMUX_SOCKET" list-panes -a -F "#{pane_title}" | grep -q "^backend · GLM-5.3$"'
check "validation: duplicate role refused" '! teamctl spawn backend glm53'
check "validation: reserved and malformed roles refused" '! teamctl spawn lead glm53 && ! teamctl spawn "Bad Role" glm53'
check "validation: a capital letter is refused whatever the locale says about [a-z]" 'for l in C en_AU.UTF-8 en_US.UTF-8; do LC_ALL=$l LANG=$l teamctl spawn Riley-reviewer glm53; [ $? -eq 64 ] || exit 1; done; [ -z "$(git branch --list "ai/Riley*")" ]'
LEGACY_RECORD="$(ls -d "$WOLFMUX_DATA"/state/*/agents | head -1)/Old-Reviewer.json"
jq '.role = "Old-Reviewer" | .pane_id = "" | .state = "stopped"' "$(dirname "$LEGACY_RECORD")/backend.json" >"$LEGACY_RECORD"
check "validation: a role an older version let through (capitals) can still be listed and stopped" 'teamctl status | grep -q "^Old-Reviewer  *GLM-5.3" && teamctl stop Old-Reviewer && teamctl status --json | jq -e ".agents[] | select(.role == \"Old-Reviewer\") | .state == \"stopped\""'
check "validation: a role name can never leave the registry directory" 'teamctl stop "../backend"; [ $? -eq 64 ] && teamctl capture "a/b"; [ $? -eq 64 ]'
/bin/rm -f "$LEGACY_RECORD"
check "validation: flag without value reports usage (exit 64)" 'teamctl spawn x glm53 --base; [ $? -eq 64 ]'

echo "== the wolf (cosmetic: it may never break a command)"
SESSION_NAME="$(teamctl status --json | jq -r .session)"
pane_of() { teamctl status --json | jq -r --arg role "$1" '.agents[] | select(.role == $role) | .pane'; }
border_of() { tmux -L "$WOLFMUX_TMUX_SOCKET" display-message -p -t "$(pane_of "$1")" '#{E:pane-border-format} #{E:pane-border-style}'; }
check "wolf: opening the session shows the splash (popup on client-attached)" 'tmux -L "$WOLFMUX_TMUX_SOCKET" show-hooks -t "=$SESSION_NAME:" | grep -q "client-attached.*display-popup.*_splash"'
check "wolf: the splash draws the wolf, the wordmark and the team line" 'out="$(teamctl _splash </dev/null)" && [ "$(printf "%s\n" "$out" | grep -c "█")" -ge 12 ] && printf "%s\n" "$out" | grep -q "W O L F M U X" && printf "%s\n" "$out" | grep -q "lead GPT-6 Astra · 2 workers"'
check "wolf: no colour codes outside a terminal" '! teamctl _splash </dev/null | grep -q "$(printf "\033")"'
check "wolf: the splash still works outside any project" '(cd / && teamctl _splash </dev/null | grep -q "W O L F M U X")'
check "wolf: the manager pane carries the wolf and the amber border; a teammate is a dog with a grey one" 'border_of lead | grep -q "🐺.*fg=colour214" && ! border_of lead | grep -q "🐶" && border_of backend | grep -q "🐶.*fg=colour244" && ! border_of backend | grep -q "🐺"'
check "wolf: the manager pane opens with the wolf" '[ "$(teamctl capture lead --all | grep -c "█")" -ge 12 ] && [ "$(teamctl capture backend --all | grep -c "█")" = 0 ]'
check "wolf: status line and terminal title carry it" 'tmux -L "$WOLFMUX_TMUX_SOCKET" show-options -gv status-left | grep -q "🐺" && tmux -L "$WOLFMUX_TMUX_SOCKET" show-options -gv set-titles-string | grep -q "🐺"'
check "wolf: WOLFMUX_SPLASH=off removes the popup, the default brings it back" 'WOLFMUX_SPLASH=off teamctl attach; ! tmux -L "$WOLFMUX_TMUX_SOCKET" show-hooks -t "=$SESSION_NAME:" | grep -q display-popup && { teamctl attach; tmux -L "$WOLFMUX_TMUX_SOCKET" show-hooks -t "=$SESSION_NAME:" | grep -q display-popup; }'

echo "== pane arrangement"
# role left top width height window_width window_height, one line per pane
geometry() { tmux -L "$WOLFMUX_TMUX_SOCKET" list-panes -a -F '#{@ai_role} #{pane_left} #{pane_top} #{pane_width} #{pane_height} #{window_width} #{window_height}'; }
lead_left() { geometry | awk '$1 == "lead" { lead = ($2 == 0 && $5 >= $7 - 2 && $4 * 2 > $6); edge = $4 } $1 != "lead" { columns[$2] = 1; if ($2 == 0) wrong = 1 } END { n = 0; for (c in columns) n++; exit !(lead && !wrong && n == 1) }'; }
lead_top() { geometry | awk '$1 == "lead" { lead = ($2 == 0 && $3 <= 1 && $4 == $6 && $5 * 2 > $7) } $1 != "lead" { rows[$3] = 1; if ($3 <= 1) wrong = 1 } END { n = 0; for (r in rows) n++; exit !(lead && !wrong && n == 1) }'; }
check "layout: by default the lead is the large pane on the left, workers stacked on the right" 'lead_left'
check "layout: lead-top puts the lead across the top, workers side by side below" 'teamctl layout lead-top && lead_top'
check "layout: tiled is available; the choice is remembered; nonsense is refused (exit 64)" 'teamctl layout tiled && teamctl layout | grep -q "^layout: tiled" && { teamctl layout diagonal; [ $? -eq 64 ]; }'
teamctl layout lead-left >/dev/null 2>&1

echo "== desktop notifications that lead back to the team"
FAKE_OSA="$WORK/fake-osascript"
printf '#!/bin/bash\nprintf "%%s\\n" "$@" >"%s"\n' "$WORK/osa.args" >"$FAKE_OSA"
/bin/chmod 755 "$FAKE_OSA"
notify() { WOLFMUX_OSASCRIPT="$FAKE_OSA" "$REPO/bin/teamctl" _notify; }
check "notify: every Claude agent gets the Stop hook; the plugin notifier is silenced, the user's own entry kept" 'teamctl capture backend --all | grep -q "STUB notify={\"stop\":true,\"silenced\":\"post:example,stop:desktop-notify\"}"'
check "notify: goes to the attached terminal as OSC 9 — first line, markdown dropped" 'printf "%s" "{\"last_assistant_message\":\"\\n**Done:** built \`x\`\\nsecond line\"}" | TEAM_ROLE=backend WOLFMUX_NOTIFY_TTY="$WORK/tty1" notify && [ "$(/bin/cat "$WORK/tty1")" = "$(printf "\033]9;🐶 backend: Done: built x\007")" ]'
check "notify: the manager is marked with the wolf" 'printf "%s" "{\"last_assistant_message\":\"merged\"}" | TEAM_ROLE=lead WOLFMUX_NOTIFY_TTY="$WORK/tty2" notify && grep -q "🐺 lead: merged" "$WORK/tty2"'
check "notify: escape sequences in a message never reach the terminal" 'jq -cn "{last_assistant_message: \"ok \u001b]52;c;aGk=\u0007 \u001b[2J done\"}" | TEAM_ROLE=qa WOLFMUX_NOTIFY_TTY="$WORK/tty3" notify && [ "$(LC_ALL=C tr -cd "\033\007" <"$WORK/tty3" | wc -c | tr -d " ")" = 2 ]'
check "notify: long messages are shortened" 'jq -cn "{last_assistant_message: (\"x\" * 400)}" | TEAM_ROLE=qa WOLFMUX_NOTIFY_TTY="$WORK/tty4" notify && [ "$(wc -m <"$WORK/tty4" | tr -d " ")" -lt 120 ]'
check "notify: with no terminal attached it falls back, text passed as an argument, and never fails" 'printf "not json" | TEAM_ROLE=qa notify && grep -q "^🐶 qa: finished$" "$WORK/osa.args" && grep -q "teamctl attach" "$WORK/osa.args"'
# a team on no screen: Wolfmux.app owns the notification, and a click opens the team
FAKE_APP="$WORK/Wolfmux.app"
FAKE_OPEN="$WORK/fake-open"
/bin/mkdir -p "$FAKE_APP"
printf '#!/bin/bash\nprintf "%%s\\n" "$@" >>"%s"\n' "$WORK/open.args" >"$FAKE_OPEN"
/bin/chmod 755 "$FAKE_OPEN"
PROJECT_REAL="$(cd "$PROJECT" && pwd -P)" # git reports the physical path (/private/var/… on macOS)
detached() { WOLFMUX_NOTIFIER_APP="$FAKE_APP" WOLFMUX_OPEN_BIN="$FAKE_OPEN" WOLFMUX_OSASCRIPT="$FAKE_OSA" WOLFMUX_TERMINAL=iterm "$REPO/bin/teamctl" "$@"; }
/bin/rm -f "$WORK/osa.args" "$WORK/open.args"
check "notify: nobody attached -> the message is handed to Wolfmux.app, not to osascript" 'printf "%s" "{\"last_assistant_message\":\"merged the cart API\"}" | TEAM_ROLE=lead detached _notify && grep -q "Wolfmux.app$" "$WORK/open.args" && [ ! -e "$WORK/osa.args" ] && [ "$(/bin/cat "$WOLFMUX_DATA/notify/last")" = "$PROJECT_REAL" ]'
check "notify: the app fetches its message exactly once (so its next start is a click)" '[ "$(detached _notify-pending | head -1)" = "🐺 lead: merged the cart API" ] && [ -z "$(detached _notify-pending)" ]'
check "notify: a message the app never fetched is not posted late" 'printf "%s" "{}" | TEAM_ROLE=qa detached _notify && touch -t 202001010000 "$WOLFMUX_DATA/notify/pending" && [ -z "$(detached _notify-pending)" ]'
/bin/rm -f "$WORK/osa.args" "$WORK/open.args"
check "notify: a click opens a terminal on the team (script with the project and teamctl attach)" 'detached _open-team && grep -q "open-team.command" "$WORK/osa.args" && grep -q "create window with default profile command" "$WORK/osa.args" && grep -qF "$(printf "%q" "$PROJECT_REAL")" "$WOLFMUX_DATA/notify/open-team.command" && grep -q "teamctl. attach\|teamctl attach" "$WOLFMUX_DATA/notify/open-team.command"'

tmux -L "$WOLFMUX_TMUX_SOCKET" set-environment -g WOLFMUX_NOTIFY lead
teamctl restart qa >/dev/null 2>&1
sleep 2
check "notify: WOLFMUX_NOTIFY=lead keeps workers quiet (no hook, plugin notifier still silenced)" 'teamctl capture qa --all | grep "STUB notify=" | tail -1 | grep -q "{\"stop\":false,\"silenced\":\"post:example,stop:desktop-notify\"}"'
tmux -L "$WOLFMUX_TMUX_SOCKET" set-environment -gu WOLFMUX_NOTIFY
teamctl restart qa >/dev/null 2>&1
sleep 2

echo "== a teammate stays in its own worktree and on its own branch"
OWN_TREE="$(teamctl status --json | jq -r '.agents[] | select(.role == "backend") | .workdir')"
OWN_BRANCH="$(teamctl status --json | jq -r '.agents[] | select(.role == "backend") | .branch')"
QA_TREE="$(teamctl status --json | jq -r '.agents[] | select(.role == "qa") | .workdir')"
ROOT_REAL="$(cd "$PROJECT" && pwd -P)"
# guard <tool> <json tool_input> — the hook's answer for the backend worker: "deny" or "allow"
guard() {
  local answer
  answer="$(jq -cn --arg tool "$1" --argjson input "$2" --arg cwd "$OWN_TREE" '{hook_event_name: "PreToolUse", tool_name: $tool, tool_input: $input, cwd: $cwd}' |
    TEAM_ROLE=backend WOLFMUX_ROOT="$ROOT_REAL" WOLFMUX_WORKTREE="$OWN_TREE" WOLFMUX_BRANCH="$OWN_BRANCH" "$REPO/bin/teamctl" _guard)"
  if printf '%s' "$answer" | jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | length > 20)' >/dev/null 2>&1; then echo deny; else echo "allow${answer:+ (unexpected output)}"; fi
}
file() { jq -cn --arg p "$1" '{file_path: $p}'; }
search() { jq -cn --arg p "$1" '{pattern: "x", path: $p}'; }
as_write() { jq -c '{tool_name: "Write", tool_input: .}'; } # helpers instead of nested \"quotes\": bash 3.2 misreads those inside $( )
sh() { jq -cn --arg c "$1" '{command: $c}'; }
all() { local want="$1" tool="$2" input; shift 2; for input in "$@"; do [ "$(guard "$tool" "$input")" = "$want" ] || { echo "expected $want: $tool $input" >&2; return 1; }; done; }
check "guard: every worker has it, the lead does not" 'teamctl capture backend --all | grep -q "STUB guard=true" && teamctl capture qa --all | grep -q "STUB guard=true"'
check "guard: a worker may change files in its own worktree (absolute, relative, new) and in temporary directories" 'all allow Write "$(file "$OWN_TREE/src/new/file.ts")" "$(file "src/app.ts")" "$(file "/tmp/scratch.txt")" && all allow Edit "$(file "$OWN_TREE/README.md")"'
check "guard: it may not change the lead's checkout, a teammate's worktree, or climb out with .." 'all deny Write "$(file "$ROOT_REAL/README.md")" "$(file "$QA_TREE/README.md")" "$(file "../$(basename "$QA_TREE")/x.ts")" "$(file "$HOME/.zshrc")" && all deny Edit "$(file "$ROOT_REAL/src/x.ts")"'
check "guard: it may read the lead's checkout, never a teammate's work in progress or teamctl's state" 'all allow Read "$(file "$ROOT_REAL/README.md")" "$(file "$OWN_TREE/README.md")" && all deny Read "$(file "$QA_TREE/README.md")" "$(file "$WOLFMUX_DATA/state")" && all deny Grep "$(search "$QA_TREE")"'
check "guard: ordinary shell work passes" 'all allow Bash "$(sh "npm test")" "$(sh "git status && git add -A && git commit -m wip")" "$(sh "git checkout -- src/app.ts")" "$(sh "git push -u origin HEAD")" "$(sh "cat $ROOT_REAL/.env.example")" "$(sh "cp $ROOT_REAL/.env .")" "$(sh "teamctl status")" "$(sh "bd list --assignee backend --status open --include-infra")" "$(sh "git rebase main")"'
check "guard: shell commands that reach into other worktrees or write into the lead's checkout are refused" 'all deny Bash "$(sh "cat $QA_TREE/secret.txt")" "$(sh "cat $(cd "$QA_TREE" && pwd -P)/secret.txt")" "$(sh "cd $ROOT_REAL && git commit -am x")" "$(sh "git -C $ROOT_REAL reset --hard")" "$(sh "rm -rf $ROOT_REAL/src")" "$(sh "cp fix.ts $ROOT_REAL/src/")" "$(sh "echo x > $ROOT_REAL/notes.txt")"'
check "guard: branches, worktrees, tmux and pushes to main are the lead's" 'all deny Bash "$(sh "git switch main")" "$(sh "git checkout main")" "$(sh "git checkout -b feature")" "$(sh "git branch -D ai/qa-1")" "$(sh "git worktree add ../x")" "$(sh "tmux capture-pane -p -t %0")" "$(sh "git push origin main")" "$(sh "git push --force origin +HEAD:main")"'
check "guard: the lead is not guarded, and an agent it cannot place is allowed (fails open)" '[ -z "$(file "$QA_TREE/x" | as_write | TEAM_ROLE=lead WOLFMUX_WORKTREE="$OWN_TREE" "$REPO/bin/teamctl" _guard)" ] && [ -z "$(file "$QA_TREE/x" | as_write | TEAM_ROLE=backend "$REPO/bin/teamctl" _guard)" ]'
teamctl policy worker-isolation off >/dev/null 2>&1
teamctl restart qa >/dev/null 2>&1
sleep 2
check "guard: teamctl policy worker-isolation off takes it away at the next start" 'teamctl capture qa --all | grep "STUB guard=" | tail -1 | grep -q "STUB guard=false"'
teamctl policy worker-isolation on >/dev/null 2>&1
teamctl restart qa >/dev/null 2>&1
sleep 2

echo "== one manager, permissions, spawning"
check "policy: defaults are skip / skip / worker spawning off / worker isolation on" 'teamctl status --json | jq -e ".manager == \"lead\" and .policy == {lead_permissions: \"skip\", worker_permissions: \"skip\", worker_spawn: \"off\", worker_isolation: \"on\"}"'
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
check "layout: the arrangement survives a spawn and a stop" 'lead_left'

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
check "remove: a running agent is never removed" 'teamctl remove qa --force --yes; [ $? -eq 1 ] && teamctl status --json | jq -e ".agents[] | select(.role == \"qa\") | .state == \"running\""'
check "destroy: refuses without confirmation when not interactive" '! teamctl destroy --worktrees </dev/null'
check "destroy: runs with --yes" 'teamctl destroy --worktrees --yes'
check "destroy: dirty worktree with an unmerged commit is kept" '[ -d "$BACKEND_DIR" ] && git rev-parse -q --verify "refs/heads/$(git -C "$BACKEND_DIR" branch --show-current)"'
check "destroy: clean worktree removed, merged branch deleted" '[ -z "$(git branch --list "ai/qa-*")" ]'
check "destroy: says which workers it kept, why, and how to keep or discard their work" 'teamctl destroy --worktrees --yes | grep -q "backend: KEPT" && teamctl destroy --worktrees --yes | grep -q "teamctl remove backend --force"'
check "remove: without --force, work is never discarded, and the refusal says what would be lost" 'out="$(teamctl remove backend 2>&1)"; [ $? -eq 1 ] && printf "%s" "$out" | grep -q "1 commit" && printf "%s" "$out" | grep -q "feat: work" && printf "%s" "$out" | grep -q "uncommitted" && [ -d "$BACKEND_DIR" ]'
check "remove: a worker cannot remove anyone (exit 77)" 'TEAM_ROLE=qa teamctl remove backend --force --yes; [ $? -eq 77 ] && [ -d "$BACKEND_DIR" ]'
check "remove: --force needs a yes when nobody can be asked" '! teamctl remove backend --force </dev/null && [ -d "$BACKEND_DIR" ]'
BACKEND_BRANCH="$(git -C "$BACKEND_DIR" branch --show-current)"
check "remove --force --yes: worktree, branch and record are gone; the main checkout is untouched" 'teamctl remove backend --force --yes && [ ! -d "$BACKEND_DIR" ] && ! git rev-parse -q --verify "refs/heads/$BACKEND_BRANCH" && ! teamctl status --json | jq -e ".agents[] | select(.role == \"backend\")" && [ -z "$(git -C "$PROJECT" status --porcelain)" ] && ! git worktree list | grep -q backend'
check "remove: an unknown role is an error, not a silent success" 'teamctl remove nobody --force --yes; [ $? -eq 1 ]'
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
for pane in $(tmux -L "$OLD_NAME_SOCKET" list-panes -a -F '#{pane_id}'); do tmux -L "$OLD_NAME_SOCKET" send-keys -t "$pane" C-d; done
sleep 1
check "rename: a pre-rename team whose agents have all exited is replaced by a fresh one on the new socket" 'follow start astra --no-attach --skip-beads && tmux -L "$WOLFMUX_TMUX_SOCKET" has-session && ! tmux -L "$OLD_NAME_SOCKET" has-session 2>/dev/null && follow status --json | jq -e "[.agents[] | select(.role == \"docs\")][0].state == \"stopped\""'
check "rename: destroy ends it" 'follow destroy --worktrees --yes && ! tmux -L "$OLD_NAME_SOCKET" has-session 2>/dev/null'
check "rename: the next team starts on the new socket" 'follow start fable --no-attach --skip-beads && tmux -L "$WOLFMUX_TMUX_SOCKET" has-session && ! tmux -L "$OLD_NAME_SOCKET" has-session 2>/dev/null'
check "wolf: inside their own CLI a Claude lead is named with the wolf, a teammate with the dog" 'follow spawn docs flash --no-kickoff && sleep 2 && teamctl capture lead --all | grep -q "STUB name=🐺 team/lead" && teamctl capture docs --all | grep -q "STUB name=🐶 team/docs"'

echo "== closing agents and starting again"
role_pane() { follow status --json | jq -r --arg role "$1" '.agents[] | select(.role == $role) | .pane'; }
end_agent() { tmux -L "$WOLFMUX_TMUX_SOCKET" send-keys -t "$1" C-d; } # the stub is `cat`: end of input ends it, the pane stays (remain-on-exit)
DOCS_PANE="$(role_pane docs)"
end_agent "$(role_pane lead)"
sleep 1
check "start again: a lead that exited comes back in place, workers are not touched" 'follow status --json | jq -e "[.agents[] | select(.role == \"lead\")][0].state | startswith(\"exited\")" && follow start fable --no-attach --skip-beads && sleep 1 && follow status --json | jq -e --arg pane "$DOCS_PANE" "([.agents[] | select(.role == \"lead\")][0].state == \"running\") and ([.agents[] | select(.role == \"docs\")][0] | .state == \"running\" and .pane == \$pane)" && lead_left'
end_agent "$(role_pane lead)"
sleep 1
check "start again: asking for the other lead model brings the lead back as that model" 'follow start astra --no-attach --skip-beads && sleep 1 && follow status --json | jq -e "[.agents[] | select(.role == \"lead\")][0] | .state == \"running\" and .model == \"astra\"" && follow status --json | jq -e ".agents | map(select(.role == \"docs\"))[0].state == \"running\""'
for pane in $(tmux -L "$WOLFMUX_TMUX_SOCKET" list-panes -a -F '#{pane_id}'); do end_agent "$pane"; done
sleep 1
check "start again: status says the session has ended when every agent has exited" 'follow status | grep -q "ended: every agent has exited"'
check "start again: when every agent has exited, start opens a fresh session, not the dead one" 'follow start fable --no-attach --skip-beads --continue && sleep 1 && [ "$(tmux -L "$WOLFMUX_TMUX_SOCKET" list-panes -a | wc -l | tr -d " ")" = 1 ] && follow status --json | jq -e "([.agents[] | select(.role == \"lead\")][0].state == \"running\") and ([.agents[] | select(.role == \"docs\")][0].state == \"stopped\")"'
check "start again: --continue resumes the lead's last conversation" 'teamctl capture lead --all | grep -q "STUB flags=.*--continue"'
check "start again: a stopped worker kept its worktree and returns with restart" 'follow restart docs && sleep 1 && follow status --json | jq -e "[.agents[] | select(.role == \"docs\")][0].state == \"running\"" && lead_left'
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
