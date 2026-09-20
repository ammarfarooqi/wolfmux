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
export WOLFMUX_LAUNCHER_OPUS="$REPO/tests/stub-agent" WOLFMUX_LAUNCHER_SONNET="$REPO/tests/stub-agent" WOLFMUX_LAUNCHER_HAIKU="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_CLAUDE="$REPO/tests/stub-agent" WOLFMUX_LAUNCHER_CODEX="$REPO/tests/stub-agent" # for claude:<id> / codex:<id>
export WOLFMUX_LAUNCHER_KIMI="$REPO/tests/stub-agent" WOLFMUX_LAUNCHER_MOONSHOT="$REPO/tests/stub-agent" WOLFMUX_LAUNCHER_DEEPSEEK="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_MINIMAX="$REPO/tests/stub-agent" WOLFMUX_LAUNCHER_QWEN="$REPO/tests/stub-agent" # also for <provider>:<id>
export WOLFMUX_CLAUDE_PROJECTS="$WORK/claude-projects" # where a purge looks for the agents' transcripts
export ECC_DISABLED_HOOKS="post:example" # a hook the user already disables; teamctl must keep it
# Run from an agent's pane (a teammate testing its change), the environment carries that agent's
# team, worktree and session: all of it is dropped, or every command would act as that agent.
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR WOLFMUX_NOTIFY WOLFMUX_SPLASH WOLFMUX_METERED TMUX TMUX_PANE
unset WOLFMUX_TEAM WOLFMUX_TEAM_ARG WOLFMUX_SESSION WOLFMUX_WORKTREE WOLFMUX_BRANCH WOLFMUX_MODEL WOLFMUX_EXTRA_SETTINGS
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

# Codex looks for its helper binaries next to the path it was started as. Started through a
# symlink in ~/bin it could not find its command runner and the Astra lead could run nothing.
/bin/mkdir -p "$WORK/app/Resources" "$WORK/linkbin"
printf '#!/bin/bash\nexit 0\n' >"$WORK/app/Resources/codex"
/bin/chmod 755 "$WORK/app/Resources/codex"
/bin/ln -s "$WORK/app/Resources/codex" "$WORK/linkbin/codex"
REAL_CODEX="$(cd "$WORK/app/Resources" && pwd -P)/codex"
check "codex-astra: starts Codex by its real path, never through a symlink" 'WOLFMUX_DRY_RUN=1 WOLFMUX_CODEX_BIN="$WORK/linkbin/codex" "$REPO/bin/codex-astra" | grep -qF "would exec:      $REAL_CODEX "'
for name in opus sonnet haiku; do /bin/ln -s "$REPO/bin/claude-fable" "$WORK/linkbin/claude-$name"; done
check "claude-opus / -sonnet / -haiku: the same subscription launcher, each pinned to its model" 'WOLFMUX_DRY_RUN=1 "$WORK/linkbin/claude-sonnet" | grep -q -- "--model claude-sonnet-5" && WOLFMUX_DRY_RUN=1 "$WORK/linkbin/claude-opus" | grep -q -- "--model claude-opus-5" && WOLFMUX_DRY_RUN=1 "$WORK/linkbin/claude-haiku" | grep -q -- "--model claude-haiku-4-5" && WOLFMUX_DRY_RUN=1 WOLFMUX_SONNET_MODEL=claude-sonnet-9 "$WORK/linkbin/claude-sonnet" | grep -q -- "--model claude-sonnet-9" && WOLFMUX_DRY_RUN=1 "$REPO/bin/claude-fable" | grep -q -- "--model claude-fable-5-1"'

echo "== doctor and the inbox command (nothing is started)"
# bash 3.2 under a UTF-8 locale reads the first byte of a dash as part of a variable name: a
# variable written right before one became an unbound variable, and doctor died on the one
# case it exists to report. Doctor looks at your login, shell profiles and Keychain, so here
# it gets a throwaway HOME and stand-ins for both CLIs: nothing of yours is read. That holds
# for the Keychain too: `security find-generic-password` without a keychain argument searches
# the user's search list, which macOS resolves from HOME (~/Library/Preferences,
# ~/Library/Keychains). Under the throwaway HOME that list is empty; a check below says so.
DOCTOR_HOME="$WORK/doctor-home"
/bin/mkdir -p "$DOCTOR_HOME/.claude" "$WORK/stubbin"
printf '{"env":{"ANTHROPIC_BASE_URL":"https://example.invalid"}}\n' >"$DOCTOR_HOME/.claude/settings.json"
printf '#!/bin/bash\necho "{}"\n' >"$WORK/stubbin/claude"
/bin/chmod 755 "$WORK/stubbin/claude"
doctor_utf8() { env -u CLAUDE_CONFIG_DIR -u CODEX_HOME HOME="$DOCTOR_HOME" LC_ALL=en_US.UTF-8 WOLFMUX_CLAUDE_BIN="$WORK/stubbin/claude" WOLFMUX_CODEX_BIN="$WORK/app/Resources/codex" "$REPO/bin/teamctl" doctor 2>&1 </dev/null; }
check "doctor: reports a provider override in settings.json under a UTF-8 locale instead of dying" 'doctor_utf8 | grep -q "sets env: ANTHROPIC_BASE_URL" && ! doctor_utf8 | grep -q "unbound variable"'
check "doctor: in the throwaway HOME no keychain of yours is on the search list, and doctor finds no Z.ai item there" '[ -z "$(HOME="$DOCTOR_HOME" /usr/bin/security list-keychains -d user 2>/dev/null)" ] && doctor_utf8 | grep -q "no Keychain item"'
# The metered gate is the owner's switch: it reads the config file of WOLFMUX_HOME and never the
# environment. Throwaway program folders (links to the real one) with a config of their own:
home_with() { # <name> <config content>
  local dir="$WORK/home-$1" entry
  /bin/mkdir -p "$dir"
  for entry in "$REPO"/config/wolfmux/*; do [ "$(basename "$entry")" = "config" ] || /bin/ln -sf "$entry" "$dir/"; done
  printf '%s\n' "$2" >"$dir/config"
}
home_with metered "WOLFMUX_METERED=on"
home_with last-off "WOLFMUX_METERED=on
WOLFMUX_METERED=off"
home_with commented "# WOLFMUX_METERED=on"
metered() { WOLFMUX_HOME="$WORK/home-metered" "$REPO/bin/teamctl" "$@"; } # teamctl with the gate open
# every provider of the table gets its own section; only the Z.ai key is a warning when missing
DOCTOR_HOME2="$WORK/doctor-home2"
/bin/mkdir -p "$DOCTOR_HOME2/.claude"
printf '{"note":"routes to api.deepseek.com"}\n' >"$DOCTOR_HOME2/.claude/settings.local.json"
doctor_other() { env -u CLAUDE_CONFIG_DIR -u CODEX_HOME HOME="$DOCTOR_HOME2" WOLFMUX_CLAUDE_BIN="$WORK/stubbin/claude" WOLFMUX_CODEX_BIN="$WORK/app/Resources/codex" "$REPO/bin/teamctl" doctor 2>&1 </dev/null; }
check "doctor: every provider has a section with its own Keychain service; a missing key of an optional one is a note, only Z.ai's is a warning" 'for p in kimi moonshot deepseek minimax qwen; do doctor_utf8 | grep -q "no Keychain item .wolfmux-$p." || exit 1; done && [ "$(doctor_utf8 | grep -c "optional, not set up: no Keychain item")" = 5 ] && doctor_utf8 | grep -q "WARNING.*no Keychain item .zai-coding-plan." && ! doctor_utf8 | grep "WARNING" | grep -q "wolfmux-"'
check "doctor: a metered provider says so, and that teamctl refuses it until the config file says WOLFMUX_METERED=on (the environment does not count)" 'doctor_utf8 | grep -q "billing: METERED (.*prepaid balance.*); teamctl refuses" && WOLFMUX_METERED=on doctor_utf8 | grep -q "teamctl refuses" && WOLFMUX_HOME="$WORK/home-metered" doctor_utf8 | grep -q "WOLFMUX_METERED=on in .*: teamctl starts metered agents" && doctor_utf8 | grep -q "billing: plan (Kimi for Coding"'
check "doctor: a settings file that names the host of any provider (not only Z.ai) is reported" 'doctor_other | grep -q "settings.local.json mentions api.deepseek.com" && ! doctor_utf8 | grep -q "mentions api.deepseek.com"'
check "doctor: no variable in any script is followed directly by a non-ASCII character" '! LC_ALL=C grep -nE "\\\$[A-Za-z_][A-Za-z0-9_]*[^ -~]" "$REPO"/bin/* "$REPO"/config/wolfmux/lib/*.sh "$REPO"/config/wolfmux/hooks/* "$REPO"/*.sh "$REPO"/tests/*.sh "$REPO"/tests/stub-agent'
# `bd update --claim` sets in_progress: an inbox that lists only `open` hides the task a
# restarted worker is in the middle of, and it would answer "ready" and wait for ever.
check "inbox: every inbox command we print or teach lists claimed and blocked work too" '! grep -rn -- "--status open --include-infra" "$REPO/bin" "$REPO/config/wolfmux" "$REPO/codex" "$REPO/docs" "$REPO/README.md"'
# In a named team the inbox belongs to <team>.<role>, which is $BEADS_ACTOR and not $TEAM_ROLE.
# (TEAM_PROTOCOL.md says $TEAM_ROLE in the file and is rewritten when it is handed to an agent.)
check "inbox: help and manuals address the inbox by Beads identity, never by plain role" '! grep -rnE -- "--assignee .?.TEAM_ROLE" "$REPO/bin" "$REPO/docs" "$REPO/config/wolfmux/README.md" "$REPO/config/wolfmux/lib" "$REPO/README.md" | grep -v "sed\|-e .s/"'

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
check "spawn: the kickoff lists claimed work and says to continue it, not start over" 'teamctl capture backend -n 12 | grep -q "STUB kickoff_in_progress=yes"'
check "spawn: the lead is the first pane" '[ "$(tmux -L "$WOLFMUX_TMUX_SOCKET" list-panes -a -F "#{pane_index}:#{@ai_role}" | head -1)" = "0:lead" ]'
check "spawn: pane titles are roles" 'tmux -L "$WOLFMUX_TMUX_SOCKET" list-panes -a -F "#{pane_title}" | grep -q "^backend · GLM-5.3$"'
check "validation: duplicate role refused" '! teamctl spawn backend glm53'
check "validation: reserved and malformed roles refused" '! teamctl spawn lead glm53 && ! teamctl spawn "Bad Role" glm53'
check "validation: a capital letter is refused whatever the locale says about [a-z]" 'for l in C en_AU.UTF-8 en_US.UTF-8; do LC_ALL=$l LANG=$l teamctl spawn Riley-reviewer glm53; [ $? -eq 64 ] || exit 1; done; [ -z "$(git branch --list "ai/Riley*")" ]'
LEGACY_RECORD="$(ls -d "$WOLFMUX_DATA"/state/*/agents | head -1)/Old-Reviewer.json"
jq '.role = "Old-Reviewer" | .pane_id = "" | .state = "stopped"' "$(dirname "$LEGACY_RECORD")/backend.json" >"$LEGACY_RECORD"
check "validation: a role an older version let through (capitals) can still be listed and stopped" 'teamctl status | grep -q "🐶 Old-Reviewer  *GLM-5.3" && teamctl stop Old-Reviewer && teamctl status --json | jq -e ".agents[] | select(.role == \"Old-Reviewer\") | .state == \"stopped\""'
check "validation: a role name can never leave the registry directory" 'teamctl stop "../backend"; [ $? -eq 64 ] && teamctl capture "a/b"; [ $? -eq 64 ]'
/bin/rm -f "$LEGACY_RECORD"
check "validation: flag without value reports usage (exit 64)" 'teamctl spawn x glm53 --base; [ $? -eq 64 ]'

echo "== any model for any teammate"
teamctl spawn fe-review astra --no-kickoff >/dev/null 2>&1
teamctl spawn summary sonnet --no-kickoff >/dev/null 2>&1
teamctl spawn triage claude:claude-haiku-4-5-20251001 --no-kickoff >/dev/null 2>&1
teamctl spawn second codex:gpt-6-astra-mini --no-kickoff >/dev/null 2>&1
sleep 2
agent() { teamctl status --json | jq -c --arg role "$1" '.agents[] | select(.role == $role) | {label, family, state}'; }
check "models: a Codex teammate in a team that is led by another model" '[ "$(agent fe-review)" = "{\"label\":\"GPT-6 Astra\",\"family\":\"codex\",\"state\":\"running\"}" ] && teamctl capture fe-review --all | grep -q "STUB role=fe-review"'
check "models: a Claude-subscription teammate (sonnet) beside GLM workers" '[ "$(agent summary)" = "{\"label\":\"Sonnet 5\",\"family\":\"claude\",\"state\":\"running\"}" ] && teamctl capture summary --all | grep -q "STUB guard=true"'
check "models: any model id of a family — claude:<id> and codex:<id> reach the CLI" 'teamctl capture triage --all | grep -q "STUB modelarg=claude-haiku-4-5-20251001" && teamctl capture second --all | grep -q "STUB astra_model=gpt-6-astra-mini"'
check "models: a Codex teammate reports finished turns too (notify program set)" 'teamctl capture fe-review --all | grep -q "STUB codexnotify=true"'
check "models: nonsense is refused before anything is created (exit 64)" 'for m in gpt claude: "claude:bad;id" "glm:glm-9" "codex:a b" glm kimi: "kimi:bad;id" "qwen:a b" "deepseek:a:b" "kimi:x/y"; do teamctl spawn bogus "$m"; [ $? -eq 64 ] || exit 1; done; [ -z "$(git branch --list "ai/bogus-*")" ]'
for role in fe-review summary triage second; do teamctl stop "$role" >/dev/null 2>&1; teamctl remove "$role" --yes >/dev/null 2>&1; done

echo "== other providers (Kimi, Moonshot, DeepSeek, MiniMax, Qwen) through the same launcher"
teamctl spawn kimi-w kimi --no-kickoff >/dev/null 2>&1
teamctl spawn mm-w minimax --no-kickoff >/dev/null 2>&1
teamctl spawn qw-w qwen:qwen3.7-max --no-kickoff >/dev/null 2>&1
sleep 2
check "providers: a plain provider key starts an agent, labelled from the table, through its own launcher name" '[ "$(agent kimi-w)" = "{\"label\":\"Kimi Code\",\"family\":\"claude\",\"state\":\"running\"}" ] && teamctl capture kimi-w --all | grep -q "STUB role=kimi-w actor=kimi-w model=kimi " && [ "$(jq -r .launcher "$(ls -d "$WOLFMUX_DATA"/state/*/agents | head -1)/kimi-w.json" | xargs basename)" = "stub-agent" ] && [ "$(agent mm-w)" = "{\"label\":\"MiniMax M3\",\"family\":\"claude\",\"state\":\"running\"}" ]'
check "providers: <provider>:<model-id> pins a model of that provider, as claude:<id> does" 'teamctl capture qw-w --all | grep -q "STUB modelarg=qwen3.7-max" && [ "$(agent qw-w)" = "{\"label\":\"qwen3.7-max\",\"family\":\"claude\",\"state\":\"running\"}" ]'
check "providers: a provider agent is a Claude Code agent (bypass flag, worker settings, guard) and never sees a credential in its pane" 'teamctl capture kimi-w --all | grep -q "STUB flags=--dangerously-skip-permissions" && teamctl capture kimi-w --all | grep -q "STUB guard=true" && teamctl capture kimi-w --all | grep -Eq "^STUB leaked= *$"'
check "providers: status --json says how each one is billed (a plan for Kimi Code, none for a subscription model)" 'teamctl status --json | jq -e "([.agents[] | select(.role == \"kimi-w\")][0].billing == \"plan\") and ([.agents[] | select(.role == \"backend\")][0].billing == \"plan\") and ([.agents[] | select(.role == \"lead\")][0].billing == \"subscription\")"'
check "providers: the status table marks nothing while nothing is metered" '! teamctl status | grep -q "metered"'
# the metered gate: a provider that bills per token is off until the owner says otherwise
check "metered: spawn refuses a metered provider by default (exit 77), says how the owner switches it on, and creates nothing" 'out="$(teamctl spawn m1 moonshot --no-kickoff 2>&1)"; [ $? -eq 77 ] && printf "%s" "$out" | grep -q "WOLFMUX_METERED=on" && printf "%s" "$out" | grep -qi "owner" && [ -z "$(git branch --list "ai/m1-*")" ] && ! teamctl status --json | jq -e ".agents[] | select(.role == \"m1\")"'
check "metered: the environment alone never opens the gate (WOLFMUX_METERED=on on the command line), for a plain key, a pinned model id and a lead" 'WOLFMUX_METERED=on teamctl spawn m1 moonshot --no-kickoff; [ $? -eq 77 ] && WOLFMUX_METERED=on teamctl spawn m1 deepseek:deepseek-v4-flash --no-kickoff; [ $? -eq 77 ] && WOLFMUX_METERED=on teamctl start deepseek --team gated --no-attach --skip-beads; [ $? -eq 77 ] && ! teamctl teams | grep -q "^gated " && [ -z "$(git branch --list "ai/m1-*")" ]'
check "metered: a config file whose last active line says off, or that only comments the switch, keeps it closed" 'WOLFMUX_HOME="$WORK/home-last-off" teamctl spawn m1 moonshot --no-kickoff; [ $? -eq 77 ] && WOLFMUX_HOME="$WORK/home-commented" teamctl spawn m1 moonshot --no-kickoff; [ $? -eq 77 ] && [ -z "$(git branch --list "ai/m1-*")" ]'
check "metered: an agent cannot open the gate by asking for a lead that costs money (worker spawning is off, and the gate is checked first)" 'TEAM_ROLE=backend teamctl spawn m1 moonshot --no-kickoff; [ $? -eq 77 ] && [ -z "$(git branch --list "ai/m1-*")" ]'
metered spawn m1 moonshot --no-kickoff >/dev/null 2>&1
metered spawn m2 deepseek:deepseek-v4-flash --no-kickoff >/dev/null 2>&1
sleep 2
check "metered: WOLFMUX_METERED=on in the config file lets it through, and the record and status --json say metered" 'teamctl status --json | jq -e "([.agents[] | select(.role == \"m1\")][0] | .billing == \"metered\" and .state == \"running\" and .label == \"Kimi K3 API\") and ([.agents[] | select(.role == \"m2\")][0].billing == \"metered\")" && jq -e ".billing == \"metered\"" "$(ls -d "$WOLFMUX_DATA"/state/*/agents | head -1)/m1.json"'
check "metered: the status table puts a \$ after the label of a metered agent, and only of those, with a legend line" 'out="$(teamctl status)"; printf "%s\n" "$out" | grep -q "🐶 m1 .*Kimi K3 API\\$ " && printf "%s\n" "$out" | grep -q "🐶 kimi-w .*Kimi Code  " && ! printf "%s\n" "$out" | grep -q "Kimi Code\\$" && printf "%s\n" "$out" | grep -q "^  \\$ = metered"'
check "metered: a metered lead is allowed with the gate open, and shows its \$ in its own team" 'metered start deepseek --team paid --no-attach --skip-beads && sleep 1 && teamctl status --team paid | grep -q "🐺 lead .*DeepSeek V4\\$ " && teamctl destroy --team paid --purge --yes'
check "providers: teamctl help, the usage line and the unknown-model error list every provider key" 'for k in kimi moonshot deepseek minimax qwen kimi:\<model-id\> moonshot:\<model-id\> deepseek:\<model-id\> minimax:\<model-id\> qwen:\<model-id\>; do teamctl help | grep -qF -- "$k" || exit 1; teamctl spawn 2>&1 | grep -qF -- "$k" || exit 1; teamctl spawn x nosuchmodel 2>&1 | grep -qF -- "$k" || exit 1; teamctl start 2>&1 | grep -qF -- "$k" || exit 1; done'
for role in kimi-w mm-w qw-w m1 m2; do teamctl stop "$role" >/dev/null 2>&1; teamctl remove "$role" --yes >/dev/null 2>&1; done

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
check "notify: nobody attached -> the message is handed to Wolfmux.app, not to osascript" 'printf "%s" "{\"last_assistant_message\":\"merged the cart API\"}" | TEAM_ROLE=lead detached _notify && grep -q "Wolfmux.app$" "$WORK/open.args" && [ ! -e "$WORK/osa.args" ] && [ "$(sed -n 1p "$WOLFMUX_DATA/notify/last")" = "$PROJECT_REAL" ]'
check "notify: the app fetches its message exactly once (so its next start is a click)" '[ "$(detached _notify-pending | head -1)" = "🐺 lead: merged the cart API" ] && [ -z "$(detached _notify-pending)" ]'
check "notify: a message the app never fetched is not posted late" 'printf "%s" "{}" | TEAM_ROLE=qa detached _notify && touch -t 202001010000 "$WOLFMUX_DATA/notify/pending" && [ -z "$(detached _notify-pending)" ]'
/bin/rm -f "$WORK/osa.args" "$WORK/open.args"
check "notify: a click opens a terminal on the team (script with the project and teamctl attach)" 'detached _open-team && grep -q "open-team.command" "$WORK/osa.args" && grep -q "create window with default profile command" "$WORK/osa.args" && grep -qF "$(printf "%q" "$PROJECT_REAL")" "$WOLFMUX_DATA/notify/open-team.command" && grep -q "teamctl --team default attach" "$WOLFMUX_DATA/notify/open-team.command"'

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
check "guard: words are not commands — prose in quotes and heredocs never triggers it" 'all allow Bash "$(sh "git commit -m \"note: do not use tmux directly; git checkout main is how you go back\"")" "$(sh "bd create \"Use tmux?\" -t message -a lead -d \"should I git switch main, or rm the file in $ROOT_REAL/docs?\"")" "$(sh "git commit -m \"cleanup: rm stale fixtures, docs live in $ROOT_REAL/docs now\"")" "$(sh "cat $ROOT_REAL/.env; rm tmpfile")" "$(jq -cn "{command: \"git commit -F - <<EOF\\nfix: tmux pane handling\\n\\ngit checkout main is documented, rm -rf too\\nEOF\"}")"'
check "guard: a quoted PATH is still a path" 'all deny Bash "$(sh "cd \"$ROOT_REAL\" && ls")" "$(sh "cat \"$QA_TREE/notes.md\"")" "$(sh "rm -rf \"$ROOT_REAL/src\"")" && all deny Read "$(file "$OWN_TREE/nope/../../$(basename "$QA_TREE")/x")"'
mcp() { jq -cn --arg p "$1" '{path: $p, content: "text that mentions tmux and git checkout main"}'; }
check "guard: MCP tools are held to the same lanes" '[ "$(guard mcp__filesystem__write_file "$(mcp "$ROOT_REAL/README.md")")" = deny ] && [ "$(guard mcp__filesystem__read_file "$(mcp "$QA_TREE/README.md")")" = deny ] && [ "$(guard mcp__filesystem__write_file "$(mcp "$OWN_TREE/README.md")")" = allow ] && [ "$(guard mcp__filesystem__read_file "$(mcp "$ROOT_REAL/README.md")")" = allow ] && [ "$(guard mcp__github__create_issue "$(jq -cn "{title: \"x\", body: \"see /etc/hosts and tmux\"}")")" = allow ]'
check "guard: the lead is not guarded, and an agent it cannot place is allowed (fails open)" '[ -z "$(file "$QA_TREE/x" | as_write | TEAM_ROLE=lead WOLFMUX_WORKTREE="$OWN_TREE" "$REPO/bin/teamctl" _guard)" ] && [ -z "$(file "$QA_TREE/x" | as_write | TEAM_ROLE=backend "$REPO/bin/teamctl" _guard)" ]'
teamctl policy worker-isolation off >/dev/null 2>&1
teamctl restart qa >/dev/null 2>&1
sleep 2
check "guard: teamctl policy worker-isolation off takes it away at the next start" 'teamctl capture qa --all | grep "STUB guard=" | tail -1 | grep -q "STUB guard=false"'
teamctl policy worker-isolation on >/dev/null 2>&1
teamctl restart qa >/dev/null 2>&1
sleep 2

echo "== one manager, permissions, spawning"
check "policy: defaults are skip / skip / worker spawning off / worker isolation on" 'teamctl status --json | jq -e ".manager == \"lead\" and .policy == {lead_permissions: \"skip\", worker_permissions: \"skip\", worker_spawn: \"off\", worker_isolation: \"on\", lead_teams: \"on\"}"'
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
# The same setting from ~/.config/wolfmux/config (a copy of the program folder with its own config file).
/bin/mkdir -p "$WORK/home-with-config"
for entry in "$REPO"/config/wolfmux/*; do [ "$(basename "$entry")" = "config" ] || /bin/ln -s "$entry" "$WORK/home-with-config/"; done
printf 'WOLFMUX_APPROVAL_TIMEOUT=2\n' >"$WORK/home-with-config/config"
printf '%s' "$HOOK_IN" >"$WORK/hook-in.json"
WOLFMUX_HOME="$WORK/home-with-config" TEAM_ROLE=qa "$REPO/bin/teamctl" _permission-hook <"$WORK/hook-in.json" >/dev/null 2>&1 &
CONFIG_HOOK_PID=$!
sleep 6
check "lead mode: the waiting time is also read from the config file" 'grep -l "no decision within 2s" "$WOLFMUX_DATA"/state/*/approvals/A4.json'
kill "$CONFIG_HOOK_PID" >/dev/null 2>&1
teamctl policy worker-permissions ask >/dev/null 2>&1
teamctl restart qa >/dev/null 2>&1
sleep 2
check "ask mode: no bypass flag and no hook" 'teamctl capture qa -n 8 | grep -q "flags=none" && teamctl capture qa -n 8 | grep -q "\"hook\":false"'
teamctl policy worker-permissions skip >/dev/null 2>&1

echo "== notifications"
check "nudge: fixed line typed into the pane" 'teamctl nudge qa --id abc-123 && sleep 1 && teamctl capture qa -n 8 | grep -q "Beads update for qa (abc-123).*--status open,in_progress,blocked"'
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
jq -n '{role: "idle-one", kind: "worker", model: "glm53", label: "GLM-5.3", family: "claude", launcher: "/bin/true", workdir: "/nonexistent/wolfmux", branch: "ai/idle-one-1", base_ref: "main", base_commit: "", kickoff: "0", spawned_by: "operator", permissions: "skip", pane_id: "", state: "stopped"}' >"$(ls -d "$WOLFMUX_DATA"/state/*/agents | head -1)/idle-one.json"
check "status: a record from before the billing field is shown as it always was (plan, no \$), never as metered" 'teamctl status --json | jq -e "[.agents[] | select(.role == \"idle-one\")][0].billing == \"plan\"" && ! teamctl status | grep "idle-one" | grep -q "GLM-5.3\$"'
check "remove: all or nothing — one worker that holds work stops the whole command" 'teamctl remove idle-one backend; [ $? -eq 1 ] && teamctl status --json | jq -e "[.agents[].role] | (index(\"idle-one\") != null) and (index(\"backend\") != null)" && teamctl remove idle-one && ! teamctl status --json | jq -e ".agents[] | select(.role == \"idle-one\")"'
BACKEND_BRANCH="$(git -C "$BACKEND_DIR" branch --show-current)"
check "remove --force --yes: worktree, branch and record are gone; the main checkout is untouched" 'teamctl remove backend --force --yes && [ ! -d "$BACKEND_DIR" ] && ! git rev-parse -q --verify "refs/heads/$BACKEND_BRANCH" && ! teamctl status --json | jq -e ".agents[] | select(.role == \"backend\")" && [ -z "$(git -C "$PROJECT" status --porcelain)" ] && ! git worktree list | grep -q backend'
PRECIOUS="$WORK/precious"
/bin/mkdir -p "$PRECIOUS" && echo keep >"$PRECIOUS/file.txt"
AGENTS_DIR="$(ls -d "$WOLFMUX_DATA"/state/*/agents | head -1)"
jq -n --arg dir "$PRECIOUS" '{role: "rogue", kind: "worker", model: "glm53", label: "GLM-5.3", family: "claude", launcher: "/bin/true", workdir: $dir, branch: "main", base_ref: "main", base_commit: "", kickoff: "0", spawned_by: "operator", permissions: "skip", pane_id: "", state: "stopped"}' >"$AGENTS_DIR/rogue.json"
check "remove: a damaged record can never delete a directory outside the worktrees, nor a branch that is not ai/*" 'teamctl remove rogue --force --yes; [ -f "$PRECIOUS/file.txt" ] && git rev-parse -q --verify refs/heads/main >/dev/null && ! teamctl status --json | jq -e ".agents[] | select(.role == \"rogue\")"'
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

echo "== several teams in one project"
sessions() { tmux -L "$WOLFMUX_TMUX_SOCKET" list-sessions -F '#{session_name}' 2>/dev/null | sort | tr '\n' ' '; }
teamctl start astra --no-attach --skip-beads >/dev/null 2>&1
FIRST_SESSION="$(teamctl status --json | jq -r .session)"
check "teams: asking for another lead model while a team runs never hijacks that team; it says how to start a second one" 'out="$(teamctl start fable --no-attach --skip-beads 2>&1)"; [ $? -eq 1 ] && printf "%s" "$out" | grep -q -- "teamctl start fable --team" && teamctl status --json | jq -e ".agents[0].label == \"GPT-6 Astra\""'
check "teams: a second, named team gets its own tmux session and its own lead" 'teamctl start fable --team review --no-attach --skip-beads && [ "$(sessions)" = "$FIRST_SESSION $FIRST_SESSION-review " ]'
check "teams: with several teams a command has to say which one (exit 64, and it lists them)" 'out="$(teamctl spawn backend glm53 --no-kickoff 2>&1)"; [ $? -eq 64 ] && printf "%s" "$out" | grep -q "default" && printf "%s" "$out" | grep -q "review"'
check "teams: the same role name can exist in two teams; --team works before or after the command" 'teamctl spawn backend glm53 --team review --no-kickoff && teamctl --team default spawn backend flash --no-kickoff && sleep 2 && [ "$(git branch --list "ai/review/backend-*" | wc -l | tr -d " ")" = 1 ] && [ "$(git branch --list "ai/backend-*" | wc -l | tr -d " ")" = 1 ] && teamctl status --json --team review | jq -e "[.agents[] | select(.role == \"backend\")][0] | (.branch | startswith(\"ai/review/backend-\")) and .commits_ahead == \"0\""'
check "teams: status shows every team as a hierarchy: team, wolf, dogs" 'out="$(teamctl status)"; printf "%s\n" "$out" | grep -q "^TEAM default" && printf "%s\n" "$out" | grep -q "^TEAM review" && [ "$(printf "%s\n" "$out" | grep -c "🐺 lead")" = 2 ] && [ "$(printf "%s\n" "$out" | grep -c "🐶 backend")" = 2 ]'
check "teams: status --json lists the teams; with --team it keeps the single-team shape" 'teamctl status --json | jq -e "(.teams | map(.team) | sort) == [\"default\", \"review\"] and ([.teams[] | select(.team == \"review\")][0].agents | map(.role)) == [\"lead\", \"backend\"]" && teamctl status --json --team review | jq -e ".team == \"review\" and .session_running and (.agents | length == 2)"'
check "teams: teamctl teams is the short list" 'teamctl teams | grep -q "review .*running .*Fable 5.1" && teamctl teams | grep -q "default .*running .*GPT-6 Astra"'
check "teams: a named team has its own Beads identities (<team>.<role>); the first team keeps plain roles" 'teamctl capture backend --team review --all | grep -q "STUB role=backend actor=review.backend" && teamctl capture backend --team default --all | grep -q "STUB role=backend actor=backend "'
check "teams: the kickoff of a teammate in a named team names its own inbox (<team>.<role>)" 'teamctl spawn scribe flash --team review && sleep 2 && teamctl capture scribe --team review --all | grep -q "STUB kickoff_assignee=review.scribe"'
teamctl stop scribe --team review >/dev/null 2>&1
teamctl remove scribe --team review --force --yes >/dev/null 2>&1
check "teams: an agent is told who its lead is, in its own team's terms" 'teamctl _prompt backend --team review | grep -q "review.lead" && teamctl _prompt backend --team review | grep -q -- "-a review.lead" && ! teamctl _prompt backend --team default | grep -q "review\.lead"'
check "teams: a notification finds the right team by identity" 'teamctl nudge review.backend --id abc-9 && sleep 1 && teamctl capture backend --team review -n 12 | grep -q "Beads update for review.backend (abc-9)" && ! teamctl capture backend --team default -n 12 | grep -q "abc-9"'
check "teams: a lead manages its own team only (exit 77 for another team)" 'TEAM_ROLE=lead WOLFMUX_TEAM=review teamctl stop backend --team default; [ $? -eq 77 ] && TEAM_ROLE=lead WOLFMUX_TEAM=review teamctl stop backend && teamctl status --json --team review | jq -e "[.agents[] | select(.role == \"backend\")][0].state == \"stopped\"" && teamctl status --json --team default | jq -e "[.agents[] | select(.role == \"backend\")][0].state == \"running\""'
(TEAM_ROLE=backend WOLFMUX_TEAM=review "$REPO/bin/teamctl" _permission-hook <"$WORK/hook-in.json" >"$WORK/hook-review.out" 2>/dev/null) &
sleep 3
check "teams: a permission request in a named team is filed with, and announced to, its own lead" 'teamctl approvals --team review | grep -q "A1 .*backend .*pending" && teamctl capture lead --team review -n 12 | grep -q "Permission request A1 from backend" && ! teamctl approvals --team default | grep -q "^A[0-9].* pending "'
check "teams: another team's lead cannot decide it (exit 77); its own lead can, and the worker's CLI receives allow" 'TEAM_ROLE=lead WOLFMUX_TEAM=default teamctl approve A1 --team review; [ $? -eq 77 ] && TEAM_ROLE=lead WOLFMUX_TEAM=review teamctl approve A1 && sleep 2 && jq -e ".hookSpecificOutput.decision.behavior == \"allow\"" "$WORK/hook-review.out"'
check "teams: desktop notifications name the team" 'printf "%s" "{\"last_assistant_message\":\"review done\"}" | TEAM_ROLE=lead WOLFMUX_TEAM=review WOLFMUX_NOTIFY_TTY="$WORK/tty-team" notify && grep -q "🐺 review/lead: review done" "$WORK/tty-team" && [ "$(sed -n 2p "$WOLFMUX_DATA/notify/last")" = review ]'
check "teams: a bad team name is refused (exit 64)" 'for name in "Bad Name" "a/b" "../x" "x."; do teamctl start fable --team "$name" --no-attach --skip-beads; [ $? -eq 64 ] || exit 1; done'
if [ "$HAVE_BD" -eq 1 ]; then
  teamctl restart backend --team review >/dev/null 2>&1
  sleep 5
  BEADS_ACTOR=review.backend TEAM_ROLE=backend WOLFMUX_TEAM=review bd create "Review ready" -t message -a review.lead -d "see branch" --silent >/dev/null 2>&1
  sleep 3
  check "teams: Beads messages reach the lead of the right team" 'teamctl capture lead --team review -n 12 | grep -q "Beads update for review.lead" && ! teamctl capture lead --team default -n 12 | grep -q "review.lead"'
  sleep 4
  BEADS_ACTOR=lead TEAM_ROLE=lead WOLFMUX_TEAM=default bd create "Need a second opinion" -t message -a review.lead -d "from the first team" --silent >/dev/null 2>&1
  sleep 4
  BEADS_ACTOR=review.lead TEAM_ROLE=lead WOLFMUX_TEAM=review bd create "Opinion attached" -t message -a lead -d "from team review" --silent >/dev/null 2>&1
  sleep 3
  check "teams: teams talk to each other through Beads, in both directions" '[ "$(teamctl capture lead --team review --all | grep -c "Beads update for review.lead")" -ge 2 ] && teamctl capture lead --team default --all | grep -q "Beads update for lead "'
fi
check "teams: every agent is told that other teams exist and how to reach them" 'teamctl _prompt lead --team default | grep -q "teamctl teams" && teamctl _prompt lead --team default | grep -q -- "-a <team>.lead"'
as_lead() { TEAM_ROLE=lead WOLFMUX_TEAM=default WOLFMUX_NOTIFY_TTY="$WORK/tty-newteam" WOLFMUX_OSASCRIPT="$FAKE_OSA" "$REPO/bin/teamctl" "$@"; }
check "teams: a lead can found a fresh team and hand work over to it" 'as_lead start fable --team fresh --no-attach --skip-beads --handover abc-77 && sleep 2 && teamctl status --json --team fresh | jq -e ".session_running and .agents[0].spawned_by == \"lead\"" && teamctl capture lead --team fresh --all | grep -q "STUB lastarg=.*abc-77"'
check "teams: you are told when an agent founds a team" 'grep -q "started team .fresh." "$WORK/tty-newteam"'
check "teams: a lead cannot take over a team that already has a lead, and a worker cannot found one (exit 77)" 'as_lead start fable --team review --no-attach --skip-beads; [ $? -eq 77 ] && { TEAM_ROLE=backend WOLFMUX_TEAM=default "$REPO/bin/teamctl" start fable --team sneaky --no-attach --skip-beads; [ $? -eq 77 ]; } && ! teamctl teams | grep -q "^sneaky "'
teamctl policy lead-teams off --team default >/dev/null 2>&1
check "teams: teamctl policy lead-teams off keeps founding teams to you" 'as_lead start fable --team another --no-attach --skip-beads; [ $? -eq 77 ] && ! teamctl teams | grep -q "^another "'
teamctl policy lead-teams on --team default >/dev/null 2>&1
teamctl destroy --team fresh --purge --yes >/dev/null 2>&1
echo "== deleting a whole team (destroy --purge)"
teamctl start fable --team scrap --no-attach --skip-beads >/dev/null 2>&1
teamctl spawn tidy flash --team scrap --no-kickoff >/dev/null 2>&1
teamctl spawn busy glm53 --team scrap --no-kickoff >/dev/null 2>&1
sleep 2
BUSY_TREE="$(teamctl status --json --team scrap | jq -r '.agents[] | select(.role == "busy") | .workdir')"
TIDY_TREE="$(teamctl status --json --team scrap | jq -r '.agents[] | select(.role == "tidy") | .workdir')"
echo "half done" >"$BUSY_TREE/draft.txt"
echo "committed" >"$BUSY_TREE/kept.txt"
(cd "$BUSY_TREE" && git add kept.txt && git -c user.name=busy -c user.email=b@example.invalid commit -qm "feat: only on this branch")
transcripts_of() { printf '%s/%s\n' "$WOLFMUX_CLAUDE_PROJECTS" "$(cd "$1" && pwd -P | sed 's|[^A-Za-z0-9]|-|g')"; }
/bin/mkdir -p "$(transcripts_of "$BUSY_TREE")" "$(transcripts_of "$TIDY_TREE")" "$WOLFMUX_CLAUDE_PROJECTS/-somebody-elses-project"
echo '{"turn":1}' >"$(transcripts_of "$BUSY_TREE")/session.jsonl"
SCRAP_STATE="$(ls -d "$WOLFMUX_DATA"/state/*/teams/scrap)"
BUSY_TRANSCRIPTS="$(transcripts_of "$BUSY_TREE")"
check "purge: a worker may not delete a team (exit 77)" 'TEAM_ROLE=busy WOLFMUX_TEAM=scrap teamctl destroy --purge --force; [ $? -eq 77 ] && [ -d "$BUSY_TREE" ]'
check "purge: work that exists nowhere else is listed, and without an answer nothing at all is touched" 'out="$(teamctl destroy --team scrap --purge 2>&1 </dev/null)"; [ $? -eq 1 ] && printf "%s" "$out" | grep -q "draft.txt" && printf "%s" "$out" | grep -q "feat: only on this branch" && printf "%s" "$out" | grep -q -- "--force" && [ -d "$BUSY_TREE" ] && tmux -L "$WOLFMUX_TMUX_SOCKET" has-session -t "=$FIRST_SESSION-scrap" && teamctl status --json --team scrap | jq -e "[.agents[] | select(.state == \"running\")] | length == 3"'
check "purge: it says how much space the team takes" 'teamctl destroy --team scrap --purge 2>&1 </dev/null | grep -Eq "total +[0-9.]+ ?(KB|MB|GB)"'
check "purge --force: session, worktrees, ai/ branches, records and transcripts of that team are gone" 'teamctl destroy --team scrap --purge --force && ! tmux -L "$WOLFMUX_TMUX_SOCKET" has-session -t "=$FIRST_SESSION-scrap" 2>/dev/null && [ ! -e "$BUSY_TREE" ] && [ ! -e "$TIDY_TREE" ] && [ -z "$(git branch --list "ai/scrap/*")" ] && [ ! -e "$SCRAP_STATE" ] && [ ! -e "$BUSY_TRANSCRIPTS" ] && [ -d "$WOLFMUX_CLAUDE_PROJECTS" ] && ! git worktree list | grep -q "/scrap/"'
check "purge: nothing else is touched — other teams, their branches, your checkout, other transcripts" 'teamctl status --json --team review | jq -e ".session_running" && teamctl status --json --team default | jq -e ".session_running" && [ -n "$(git branch --list "ai/review/*")" ] && [ -z "$(git -C "$PROJECT" status --porcelain)" ] && [ -d "$WOLFMUX_CLAUDE_PROJECTS/-somebody-elses-project" ] && ! teamctl teams | grep -q "^scrap "'
check "purge: with nothing at risk it still wants a yes when nobody can be asked" 'teamctl start fable --team scrap2 --no-attach --skip-beads && ! teamctl destroy --team scrap2 --purge </dev/null && teamctl destroy --team scrap2 --purge --yes && ! teamctl teams | grep -q "^scrap2 "'
check "teams: the short list shows what each team takes on disk" 'teamctl teams | head -1 | grep -q "DISK" && teamctl teams | grep -Eq "^review .*[0-9] ?(KB|MB|GB)"'
check "teams: destroy ends one team and leaves the other alone" 'teamctl destroy --team review --worktrees --yes && [ "$(sessions)" = "$FIRST_SESSION " ] && teamctl status --json | jq -e ".team == \"default\" and .session_running"'
check "purge: deleting the first team leaves the named teams' state alone" 'teamctl start fable --team keeper --no-attach --skip-beads && teamctl destroy --team default --purge --force && [ -d "$(ls -d "$WOLFMUX_DATA"/state/*/teams/keeper)" ] && teamctl status --json --team keeper | jq -e ".session_running" && teamctl destroy --team keeper --purge --yes'
/bin/mkdir -p "$PROJECT/.beads/hooks"
printf '#!/bin/bash\n# ai-team-hook v1 — written before the rename\nexit 0\n' >"$PROJECT/.beads/hooks/on_create"
printf '#!/bin/bash\n# somebody else wrote this\nexit 0\n' >"$PROJECT/.beads/hooks/on_close"
teamctl _refresh-hooks >/dev/null 2>&1
check "rename: a Beads hook written under the old name is replaced" 'grep -q "wolfmux-hook v1" "$PROJECT/.beads/hooks/on_create" && grep -q "/.config/wolfmux}/hooks/beads-nudge" "$PROJECT/.beads/hooks/on_create"'
check "rename: a hook that is not ours is still left alone" 'grep -q "somebody else wrote this" "$PROJECT/.beads/hooks/on_close"'

echo
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
