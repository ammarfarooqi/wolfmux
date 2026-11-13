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
export WOLFMUX_CODEX_SESSIONS="$WORK/codex-sessions"   # where status looks for a codex agent's rollout
export ECC_DISABLED_HOOKS="post:example" # a hook the user already disables; teamctl must keep it
# Run from an agent's pane (a teammate testing its change), the environment carries that agent's
# team, worktree and session: all of it is dropped, or every command would act as that agent.
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR WOLFMUX_NOTIFY WOLFMUX_SPLASH WOLFMUX_METERED TMUX TMUX_PANE
unset WOLFMUX_TEAM WOLFMUX_TEAM_ARG WOLFMUX_SESSION WOLFMUX_WORKTREE WOLFMUX_BRANCH WOLFMUX_MODEL WOLFMUX_EXTRA_SETTINGS
teamctl() { "$REPO/bin/teamctl" "$@"; }
# transcripts_of <dir> — where the CLIs put the transcripts of an agent that ran there
transcripts_of() { printf '%s/%s\n' "$WOLFMUX_CLAUDE_PROJECTS" "$(cd "$1" && pwd -P | sed 's|[^A-Za-z0-9]|-|g')"; }
# The real CLI writes a conversation's transcript once something was said in it; it refuses to resume an id
# that has none, and to start a new conversation under an id that has one. tests/stub-agent refuses the same.
# fake_conversation <id> [<workdir>] — a transcript for that id: in that directory's folder, else in another one
fake_conversation() {
  local dir="$WOLFMUX_CLAUDE_PROJECTS/-somewhere-else"
  if [ -n "${2:-}" ]; then dir="$(transcripts_of "$2")"; fi
  /bin/mkdir -p "$dir" && printf '{"type":"user","message":{"content":"hi"}}\n' >"$dir/$1.jsonl"
}
# spoke <role> [<team>] — that agent has said something: its own conversation now has a transcript
spoke() {
  local row
  row="$("$REPO/bin/teamctl" status --json ${2:+--team "$2"} | jq -c --arg r "$1" '[.agents[] | select(.role == $r)][0]')"
  [ -n "$(printf '%s' "$row" | jq -r '.session_id // empty')" ] || return 1
  fake_conversation "$(printf '%s' "$row" | jq -r .session_id)" "$(printf '%s' "$row" | jq -r .workdir)"
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
# The metered gate is the owner's switch: it reads the owner's real config file (found through the
# password database, not through $HOME or $WOLFMUX_HOME) and never the environment. So no test can
# open it, by design: these tests hold it CLOSED, and show what an open gate would show with agent
# records made by hand. If your own config says WOLFMUX_METERED=on, the closed-side checks cannot
# hold: that is detected once and they are skipped, with the reason. Nothing here writes to your config.
OWNER_GATE_OPEN=0
if (. "$REPO/config/wolfmux/lib/provider-env.sh" && wolfmux_metered_on) >/dev/null 2>&1; then OWNER_GATE_OPEN=1; fi
# a program folder (links to the real one) whose config says on: pointing WOLFMUX_HOME at it must not open the gate
REDIRECTED_HOME="$WORK/home-redirected"
/bin/mkdir -p "$REDIRECTED_HOME"
for entry in "$REPO"/config/wolfmux/*; do [ "$(basename "$entry")" = "config" ] || /bin/ln -sf "$entry" "$REDIRECTED_HOME/"; done
printf 'WOLFMUX_METERED=on\n' >"$REDIRECTED_HOME/config"
closed_check() { # <description> <command string>: needs the gate closed
  if [ "$OWNER_GATE_OPEN" -eq 1 ]; then
    printf '  skip  %s (your own config has WOLFMUX_METERED=on: this check needs the gate closed)\n' "$1"
  else
    check "$1" "$2"
  fi
}
# every provider of the table gets its own section; only the Z.ai key is a warning when missing
DOCTOR_HOME2="$WORK/doctor-home2"
/bin/mkdir -p "$DOCTOR_HOME2/.claude"
printf '{"note":"routes to api.deepseek.com"}\n' >"$DOCTOR_HOME2/.claude/settings.local.json"
doctor_other() { env -u CLAUDE_CONFIG_DIR -u CODEX_HOME HOME="$DOCTOR_HOME2" WOLFMUX_CLAUDE_BIN="$WORK/stubbin/claude" WOLFMUX_CODEX_BIN="$WORK/app/Resources/codex" "$REPO/bin/teamctl" doctor 2>&1 </dev/null; }
check "doctor: every provider has a section with its own Keychain service; a missing key of an optional one is a note, only Z.ai's is a warning" 'for p in kimi moonshot deepseek minimax qwen; do doctor_utf8 | grep -q "no Keychain item .wolfmux-$p." || exit 1; done && [ "$(doctor_utf8 | grep -c "optional, not set up: no Keychain item")" = 5 ] && doctor_utf8 | grep -q "WARNING.*no Keychain item .zai-coding-plan." && ! doctor_utf8 | grep "WARNING" | grep -q "wolfmux-"'
closed_check "doctor: a metered provider says so, and that teamctl refuses it (the environment does not count)" 'doctor_utf8 | grep -q "billing: METERED (.*prepaid balance.*); teamctl refuses" && WOLFMUX_METERED=on doctor_utf8 | grep -q "teamctl refuses" && doctor_utf8 | grep -q "billing: plan (Kimi for Coding"'
check "doctor: a settings file that names the host of any provider (not only Z.ai) is reported" 'doctor_other | grep -q "settings.local.json mentions api.deepseek.com" && ! doctor_utf8 | grep -q "mentions api.deepseek.com"'
# doctor --probe reads a key and sends it, so plain doctor must not, and with no key set up (as here:
# the throwaway HOME has no Keychain) not even --probe may start curl. A stand-in curl on the PATH
# writes a line to a file when it is started, and that file must not appear. The checks that do send
# (against a stand-in curl and against a localhost mock) are in tests/providers.sh.
PROBE_STUB="$WORK/probe-stub"
/bin/mkdir -p "$PROBE_STUB"
printf '#!/bin/bash\necho call >>"%s/calls"\ncat >/dev/null\nprintf 000\n' "$PROBE_STUB" >"$PROBE_STUB/curl"
/bin/chmod 755 "$PROBE_STUB/curl"
doctor_probe() { PATH="$PROBE_STUB:$PATH" env -u CLAUDE_CONFIG_DIR -u CODEX_HOME HOME="$DOCTOR_HOME" LC_ALL=en_US.UTF-8 WOLFMUX_CLAUDE_BIN="$WORK/stubbin/claude" WOLFMUX_CODEX_BIN="$WORK/app/Resources/codex" "$REPO/bin/teamctl" doctor --probe 2>&1 </dev/null; }
check "doctor --probe: says what it sends (one incomplete request, nothing billed, key on stdin), and with no key set up sends nothing" '/bin/rm -f "$PROBE_STUB/calls"; out="$(doctor_probe)"; printf "%s" "$out" | grep -q "POST /v1/messages with an empty body" && printf "%s" "$out" | grep -q "nothing is billed" && printf "%s" "$out" | grep -q "probe: nothing was sent" && [ ! -e "$PROBE_STUB/calls" ]'
check "doctor: without --probe no key is read and curl is never started, and no probe line is printed" '/bin/rm -f "$PROBE_STUB/calls"; out="$(PATH="$PROBE_STUB:$PATH" doctor_utf8)"; ! printf "%s" "$out" | grep -q "probe" && [ ! -e "$PROBE_STUB/calls" ]'
check "doctor --probe: the exit status is the same as plain doctor when nothing could be sent, and an unknown option is a usage error (64)" 'doctor_utf8 >/dev/null; a=$?; doctor_probe >/dev/null; b=$?; [ "$a" = "$b" ] && env HOME="$DOCTOR_HOME" "$REPO/bin/teamctl" doctor --bogus >/dev/null 2>&1; [ $? -eq 64 ]'
check "doctor: the kimi and moonshot blocks say which console each key comes from, without --probe" 'out="$(doctor_utf8)"; printf "%s" "$out" | grep -q "key: A Kimi Code membership key comes from the Kimi Code console" && printf "%s" "$out" | grep -q "key: A Moonshot key comes from the Kimi API platform" && printf "%s" "$out" | grep -q "belongs to the moonshot provider" && printf "%s" "$out" | grep -q "belongs to the kimi provider"'
check "help: teamctl help lists doctor --probe" 'teamctl help | grep -q "teamctl doctor \[--probe\]"'
check "doctor: no variable in any script is followed directly by a non-ASCII character" '! LC_ALL=C grep -nE "\\\$[A-Za-z_][A-Za-z0-9_]*[^ -~]" "$REPO"/bin/* "$REPO"/config/wolfmux/lib/*.sh "$REPO"/config/wolfmux/hooks/* "$REPO"/*.sh "$REPO"/tests/*.sh "$REPO"/tests/stub-agent'
# `bd update --claim` sets in_progress: an inbox that lists only `open` hides the task a
# restarted worker is in the middle of, and it would answer "ready" and wait for ever.
check "inbox: every inbox command we print or teach lists claimed and blocked work too" '! grep -rn --exclude="AUDIT-*.md" -- "--status open --include-infra" "$REPO/bin" "$REPO/config/wolfmux" "$REPO/codex" "$REPO/docs" "$REPO/README.md"'
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
check "spawn: kickoff prompt passed by default, omitted with --no-kickoff" 'teamctl capture backend -n 8 | grep -q "argc=8" && teamctl capture qa -n 8 | grep -q "argc=7"'
# Every lead of a project works in the SAME folder, so `claude --continue` (the newest
# transcript there) cannot tell two leads apart. Each agent gets its own id instead.
check "conversations: a fresh agent is started with its own id, and it is stored" 'id="$(teamctl status --json | jq -r "[.agents[] | select(.role == \"backend\")][0].session_id")"; [ -n "$id" ] && [ "$id" != "null" ] && teamctl capture backend --all | grep -q "STUB session_id=$id" && teamctl capture backend --all | grep -q "STUB resumed=none"'
check "conversations: two agents of one team never share an id" '[ "$(teamctl status --json | jq -r "[.agents[] | select(.family != \"codex\") | .session_id] | unique | length")" = "$(teamctl status --json | jq -r "[.agents[] | select(.family != \"codex\")] | length")" ]'
check "conversations: a Codex agent is given none (it has no id flag; it resumes its own last one)" '[ -z "$(teamctl status --json | jq -r "[.agents[] | select(.family == \"codex\")][0].session_id")" ]'
check "conversations: a plain restart mints a new id and passes it as --session-id, never --resume" 'was="$(teamctl status --json | jq -r "[.agents[] | select(.role == \"qa\")][0].session_id")"; teamctl restart qa && sleep 2 && now="$(teamctl status --json | jq -r "[.agents[] | select(.role == \"qa\")][0].session_id")"; [ -n "$now" ] && [ "$now" != "$was" ] && teamctl capture qa --all | grep -q "STUB session_id=$now" && teamctl capture qa --all | grep -q "STUB resumed=none"'
check "conversations: --continue for an agent that never said a word starts its conversation fresh under the same id (the CLI would refuse to resume it)" 'id="$(teamctl status --json | jq -r "[.agents[] | select(.role == \"qa\")][0].session_id")"; teamctl restart qa --continue && sleep 2 && teamctl status --json | jq -e "[.agents[] | select(.role == \"qa\")][0] | .state == \"running\"" && teamctl capture qa --all | grep "STUB session_id=" | tail -1 | grep -q "session_id=$id" && teamctl capture qa --all | grep "STUB resumed=" | tail -1 | grep -q "resumed=none" && teamctl capture qa --all | grep -q "nothing to continue yet"'
spoke qa
check "conversations: restart --continue reopens THAT agent's stored id, not the newest transcript" 'id="$(teamctl status --json | jq -r "[.agents[] | select(.role == \"qa\")][0].session_id")"; teamctl restart qa --continue && sleep 2 && teamctl capture qa --all | grep -q "STUB resumed=$id" && ! teamctl capture qa --all | grep "STUB flags=" | tail -1 | grep -q -- "--continue"'
check "conversations: --resume of an id nobody ever used is refused (exit 1) before anything is restarted" 'was="$(teamctl status --json | jq -r "[.agents[] | select(.role == \"qa\")][0].session_id")"; out="$(teamctl restart qa --resume 22222222-2222-3333-4444-555555555555 2>&1)"; [ $? -eq 1 ] && printf "%s" "$out" | grep -q "no conversation 22222222-2222-3333-4444-555555555555" && [ "$(teamctl status --json | jq -r "[.agents[] | select(.role == \"qa\")][0].session_id")" = "$was" ]'
check "conversations: --resume names a Claude Code conversation: a Codex agent (the lead here) is refused it (exit 64) and told to use --continue" 'out="$(teamctl restart lead --resume 11111111-2222-3333-4444-555555555555 2>&1)"; [ $? -eq 64 ] && printf "%s" "$out" | grep -q -- "--continue"'
fake_conversation 11111111-2222-3333-4444-555555555555
spoke backend
check "conversations: --resume of the conversation another agent has on record is refused (exit 1), names that agent, and changes nothing" 'was="$(teamctl status --json | jq -r "[.agents[] | select(.role == \"qa\")][0].session_id")"; theirs="$(teamctl status --json | jq -r "[.agents[] | select(.role == \"backend\")][0].session_id")"; out="$(teamctl restart qa --resume "$theirs" 2>&1)"; [ $? -eq 1 ] && printf "%s" "$out" | grep -q "is the one .backend. has on record" && [ "$(teamctl status --json | jq -r "[.agents[] | select(.role == \"qa\")][0].session_id")" = "$was" ]'
/bin/mkdir -p "$WORK/no-respawn" && printf '#!/bin/bash\nfor a in "$@"; do [ "$a" = respawn-pane ] && exit 1; done\nexec "%s" "$@"\n' "$(command -v tmux)" >"$WORK/no-respawn/tmux" && chmod +x "$WORK/no-respawn/tmux" # a tmux that cannot respawn a pane
check "conversations: a restart that produces no pane fails (exit 1) and leaves the agent's conversation id as it was" 'was="$(teamctl status --json | jq -r "[.agents[] | select(.role == \"qa\")][0].session_id")"; [ -n "$was" ] && { PATH="$WORK/no-respawn:$PATH" teamctl restart qa; [ $? -eq 1 ]; } && [ "$(teamctl status --json | jq -r "[.agents[] | select(.role == \"qa\")][0].session_id")" = "$was" ]'
check "conversations: --resume <id> wins, is stored, and comes back after another restart" 'teamctl restart qa --resume 11111111-2222-3333-4444-555555555555 && sleep 2 && teamctl capture qa --all | grep -q "STUB resumed=11111111-2222-3333-4444-555555555555" && [ "$(teamctl status --json | jq -r "[.agents[] | select(.role == \"qa\")][0].session_id")" = "11111111-2222-3333-4444-555555555555" ] && teamctl restart qa --continue && sleep 2 && teamctl capture qa --all | grep -q "STUB resumed=11111111-2222-3333-4444-555555555555"'
check "conversations: a malformed id is refused, and nothing is restarted" '! teamctl restart qa --resume not-a-uuid && ! teamctl restart qa --resume "" && [ "$(teamctl status --json | jq -r "[.agents[] | select(.role == \"qa\")][0].session_id")" = "11111111-2222-3333-4444-555555555555" ]'
teamctl restart qa >/dev/null 2>&1 # a fresh conversation: the pane's command carries no --continue
sleep 2
spoke qa
QA_PANE="$(teamctl status --json | jq -r '[.agents[] | select(.role == "qa")][0].pane')"
check "conversations: a pane that is run again by hand (no teamctl restart) starts a new conversation under a new id, instead of dying on one that is in use" 'was="$(teamctl status --json | jq -r "[.agents[] | select(.role == \"qa\")][0].session_id")"; tmux -L "$WOLFMUX_TMUX_SOCKET" respawn-pane -k -t "$QA_PANE" && sleep 2 && now="$(teamctl status --json | jq -r "[.agents[] | select(.role == \"qa\")][0].session_id")" && [ -n "$now" ] && [ "$now" != "$was" ] && teamctl status --json | jq -e "[.agents[] | select(.role == \"qa\")][0].state == \"running\"" && teamctl capture qa --all | grep "STUB session_id=" | tail -1 | grep -q "session_id=$now"'
check "conversations: a record from before ids keeps --continue and warns which folder it guesses in" 'f="$(ls -d "$WOLFMUX_DATA"/state/*/agents | head -1)/qa.json"; jq "del(.session_id)" "$f" >"$f.x" && mv "$f.x" "$f" && teamctl restart qa --continue && sleep 2 && teamctl capture qa --all | grep -q "STUB flags=.*--continue" && teamctl capture qa --all | grep -q "STUB resumed=none" && teamctl capture qa --all | grep -q "no stored conversation id for .qa."'
teamctl restart qa >/dev/null 2>&1 # back to a normal record for the checks that follow
sleep 2
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
teamctl spawn hint-k kimi >/dev/null 2>&1 # with the kickoff prompt, unlike the three above
teamctl spawn hint-s sonnet >/dev/null 2>&1
sleep 2
check "providers: a plain provider key starts an agent, labelled from the table, through its own launcher name" '[ "$(agent kimi-w)" = "{\"label\":\"Kimi Code\",\"family\":\"claude\",\"state\":\"running\"}" ] && teamctl capture kimi-w --all | grep -q "STUB role=kimi-w actor=kimi-w model=kimi " && [ "$(jq -r .launcher "$(ls -d "$WOLFMUX_DATA"/state/*/agents | head -1)/kimi-w.json" | xargs basename)" = "stub-agent" ] && [ "$(agent mm-w)" = "{\"label\":\"MiniMax M3\",\"family\":\"claude\",\"state\":\"running\"}" ]'
check "providers: <provider>:<model-id> pins a model of that provider, as claude:<id> does" 'teamctl capture qw-w --all | grep -q "STUB modelarg=qwen3.7-max" && [ "$(agent qw-w)" = "{\"label\":\"qwen3.7-max\",\"family\":\"claude\",\"state\":\"running\"}" ]'
check "providers: a provider agent is a Claude Code agent (bypass flag, worker settings, guard) and never sees a credential in its pane" 'teamctl capture kimi-w --all | grep -q "STUB flags=--dangerously-skip-permissions" && teamctl capture kimi-w --all | grep -q "STUB guard=true" && teamctl capture kimi-w --all | grep -Eq "^STUB leaked= *$"'
check "providers: the kickoff of a provider worker names its Keychain slot and endpoint and says the lead or the human runs doctor --probe on a 401 (GLM workers too, a subscription model gets no such line)" 'teamctl capture hint-k --all | grep -q "STUB kickoff_probe_hint=yes" && teamctl capture hint-k --all | grep -q "STUB kickoff_probe_slot=wolfmux-kimi" && teamctl capture hint-k --all | grep -q "STUB kickoff_probe_endpoint=https://api.kimi.com/coding/" && teamctl capture backend --all | grep -q "STUB kickoff_probe_slot=zai-coding-plan" && teamctl capture hint-s --all | grep -q "STUB kickoff_probe_hint=no" && teamctl capture hint-s --all | grep -q "STUB kickoff_in_progress=yes"'
check "providers: the pane of a provider agent prints, above the CLI, the Keychain slot it uses and the command for a 401; a subscription model prints no such line" 'teamctl capture hint-k --all | grep -q "^\[wolfmux\] key: .wolfmux-kimi. -> https://api.kimi.com/coding/.*teamctl doctor --probe" && ! teamctl capture hint-s --all | grep -q "\[wolfmux\] key:" && teamctl capture backend --all | grep -q "^\[wolfmux\] key: .zai-coding-plan."'
check "providers: status --json says how each one is billed (a plan for Kimi Code, none for a subscription model)" 'teamctl status --json | jq -e "([.agents[] | select(.role == \"kimi-w\")][0].billing == \"plan\") and ([.agents[] | select(.role == \"backend\")][0].billing == \"plan\") and ([.agents[] | select(.role == \"lead\")][0].billing == \"subscription\")"'
check "providers: the status table marks nothing while nothing is metered" '! teamctl status | grep -q "metered"'
# the metered gate: a provider that bills per token is off until the owner says otherwise
closed_check "metered: spawn refuses a metered provider by default (exit 77), says how the owner switches it on, and creates nothing" 'out="$(teamctl spawn m1 moonshot --no-kickoff 2>&1)"; [ $? -eq 77 ] && printf "%s" "$out" | grep -q "WOLFMUX_METERED=on" && printf "%s" "$out" | grep -qi "owner" && [ -z "$(git branch --list "ai/m1-*")" ] && ! teamctl status --json | jq -e ".agents[] | select(.role == \"m1\")"'
closed_check "metered: the environment alone never opens the gate (WOLFMUX_METERED=on on the command line), for a plain key, a pinned model id and a lead" 'WOLFMUX_METERED=on teamctl spawn m1 moonshot --no-kickoff; [ $? -eq 77 ] && WOLFMUX_METERED=on teamctl spawn m1 deepseek:deepseek-v4-flash --no-kickoff; [ $? -eq 77 ] && WOLFMUX_METERED=on teamctl start deepseek --team gated --no-attach --skip-beads; [ $? -eq 77 ] && ! teamctl teams | grep -q "^gated " && [ -z "$(git branch --list "ai/m1-*")" ]'
closed_check "metered: WOLFMUX_HOME pointed at a folder whose config says on does not open it either: spawn, spawn <p>:<id>, start (exit 77 each) and doctor" 'WOLFMUX_HOME="$REDIRECTED_HOME" teamctl spawn gate-probe moonshot --no-kickoff; [ $? -eq 77 ] && WOLFMUX_HOME="$REDIRECTED_HOME" teamctl spawn gate-probe deepseek:deepseek-v4-flash --no-kickoff; [ $? -eq 77 ] && WOLFMUX_HOME="$REDIRECTED_HOME" teamctl start deepseek --team gated --no-attach --skip-beads; [ $? -eq 77 ] && [ -z "$(git branch --list "ai/gate-probe-*")" ] && ! teamctl teams | grep -q "^gated " && WOLFMUX_HOME="$REDIRECTED_HOME" doctor_utf8 | grep -q "teamctl refuses"'
# if a gate that is not closed let anything through, do not leave it around for the checks below
teamctl destroy --team gated --purge --yes >/dev/null 2>&1
teamctl stop gate-probe >/dev/null 2>&1
teamctl remove gate-probe --force --yes >/dev/null 2>&1
closed_check "metered: an agent cannot open the gate by asking for a lead that costs money (worker spawning is off, and the gate is checked first)" 'TEAM_ROLE=backend teamctl spawn m1 moonshot --no-kickoff; [ $? -eq 77 ] && [ -z "$(git branch --list "ai/m1-*")" ]'
# What an open gate would show, from agent records made by hand (as "idle-one" and "rogue" are planted below).
METER_AGENTS="$(ls -d "$WOLFMUX_DATA"/state/*/agents | head -1)"
plant() { # <agents dir> <role> <kind> <model> <label> <billing>
  jq -n --arg role "$2" --arg kind "$3" --arg model "$4" --arg label "$5" --arg billing "$6" --arg dir "$PROJECT" \
    '{role: $role, kind: $kind, model: $model, label: $label, family: "claude", billing: $billing, launcher: "/bin/true",
      workdir: (if $kind == "lead" then $dir else "/nonexistent/wolfmux" end), branch: ("ai/" + $role + "-1"), base_ref: "main", base_commit: "",
      kickoff: "0", spawned_by: "operator", permissions: "skip", pane_id: "", state: "stopped", created_at: "2099-01-01T00:00:00Z"}' >"$1/$2.json"
}
plant "$METER_AGENTS" meter-1 worker moonshot "Kimi K3 API" metered
plant "$METER_AGENTS" meter-2 worker deepseek:deepseek-v4-flash "deepseek-v4-flash" metered
check "metered: status --json says metered for a metered record and plan for a plan one" 'teamctl status --json | jq -e "([.agents[] | select(.role == \"meter-1\")][0].billing == \"metered\") and ([.agents[] | select(.role == \"meter-2\")][0].billing == \"metered\") and ([.agents[] | select(.role == \"kimi-w\")][0].billing == \"plan\")"'
check "metered: the status table puts a \$ after the label of a metered agent, and only of those, with a legend line" 'out="$(teamctl status)"; printf "%s\n" "$out" | grep -q "🐶 meter-1 .*Kimi K3 API\\$ " && printf "%s\n" "$out" | grep -q "🐶 meter-2 .*deepseek-v4-flash\\$ " && printf "%s\n" "$out" | grep -q "🐶 kimi-w .*Kimi Code  " && ! printf "%s\n" "$out" | grep -q "Kimi Code\\$" && printf "%s\n" "$out" | grep -q "^  \\$ = metered"'
PAID_TEAM_DIR="$(dirname "$METER_AGENTS")/teams/paid"
/bin/mkdir -p "$PAID_TEAM_DIR/agents"
plant "$PAID_TEAM_DIR/agents" lead lead deepseek "DeepSeek V4" metered
check "metered: a metered lead shows its \$ in its own team, and --json says metered" 'teamctl status --team paid | grep -q "🐺 lead .*DeepSeek V4\\$ " && teamctl status --json --team paid | jq -e ".agents[0].billing == \"metered\""'
/bin/rm -rf "$PAID_TEAM_DIR"
check "providers: teamctl help, the usage line and the unknown-model error list every provider key" 'for k in kimi moonshot deepseek minimax qwen kimi:\<model-id\> moonshot:\<model-id\> deepseek:\<model-id\> minimax:\<model-id\> qwen:\<model-id\>; do teamctl help | grep -qF -- "$k" || exit 1; teamctl spawn 2>&1 | grep -qF -- "$k" || exit 1; teamctl spawn x nosuchmodel 2>&1 | grep -qF -- "$k" || exit 1; teamctl start 2>&1 | grep -qF -- "$k" || exit 1; done'
for role in kimi-w mm-w qw-w hint-k hint-s meter-1 meter-2; do teamctl stop "$role" >/dev/null 2>&1; teamctl remove "$role" --yes >/dev/null 2>&1; done

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

check "hooks: every Claude agent is wired to teamctl _hook for the five turn events, a Codex agent to none" 'teamctl capture backend --all | grep -q "STUB hooks=PostToolUse,PreCompact,SessionStart,Stop,UserPromptSubmit" && teamctl capture backend --all | grep -q "STUB rundir=yes" && ! teamctl capture fe-review --all | grep -q "STUB hooks=P"'
check "hooks: PostToolUse with nothing queued counts the call and says nothing; the tenth call and a queued attention go through the full hook" 'd="$WORK/run-hot"; /bin/mkdir -p "$d" && for i in 1 2 3; do printf "{}" | TEAM_ROLE=qa WOLFMUX_RUN_DIR="$d" teamctl _hook PostToolUse || exit 1; done; [ "$(/bin/cat "$d/calls")" = 3 ] && : >"$d/attention" && printf "{}" | TEAM_ROLE=qa WOLFMUX_RUN_DIR="$d" teamctl _hook PostToolUse && [ ! -e "$d/attention" ] && [ "$(/bin/cat "$d/calls")" = 4 ]'
check "hooks: a turn is busy from the prompt to the stop; garbage in the call counter or on stdin never fails a hook" 'd="$WORK/run-state"; /bin/mkdir -p "$d" && printf "{}" | TEAM_ROLE=qa WOLFMUX_RUN_DIR="$d" teamctl _hook UserPromptSubmit && [ "$(/bin/cat "$d/state")" = busy ] && printf "not json" | TEAM_ROLE=qa WOLFMUX_RUN_DIR="$d" WOLFMUX_NOTIFY=off teamctl _hook Stop && [ "$(/bin/cat "$d/state")" = idle ] && printf "a[\$(touch %s/pwned)]\n" "$WORK" >"$d/calls" && printf "{}" | TEAM_ROLE=qa WOLFMUX_RUN_DIR="$d" teamctl _hook PostToolUse && [ ! -e "$WORK/pwned" ] && [ "$(/bin/cat "$d/calls")" = 1 ] && { printf "{}" | TEAM_ROLE=qa WOLFMUX_RUN_DIR="$d" teamctl _hook Bogus; [ $? -eq 0 ]; }'
tmux -L "$WOLFMUX_TMUX_SOCKET" set-environment -g WOLFMUX_NOTIFY lead
teamctl restart qa >/dev/null 2>&1
sleep 2
check "notify: WOLFMUX_NOTIFY=lead keeps workers quiet: the Stop hook stays (mail reaches an agent through it) and posts nothing for a worker, the lead still notifies" 'teamctl capture qa --all | grep "STUB notify=" | tail -1 | grep -q "{\"stop\":true,\"silenced\":\"post:example,stop:desktop-notify\"}" && /bin/rm -f "$WORK/tty-quiet" "$WORK/tty-lead" && printf "%s" "{\"last_assistant_message\":\"done\"}" | WOLFMUX_NOTIFY=lead TEAM_ROLE=qa WOLFMUX_RUN_DIR="$WORK/run-qa" WOLFMUX_NOTIFY_TTY="$WORK/tty-quiet" teamctl _hook Stop && [ ! -s "$WORK/tty-quiet" ] && printf "%s" "{\"last_assistant_message\":\"done\"}" | WOLFMUX_NOTIFY=lead TEAM_ROLE=lead WOLFMUX_RUN_DIR="$WORK/run-lead" WOLFMUX_NOTIFY_TTY="$WORK/tty-lead" teamctl _hook Stop && grep -q "lead: done" "$WORK/tty-lead"'
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

echo "== context use in status (issue #5)"
BACKEND_TRANS="$(transcripts_of "$BACKEND_DIR")"
BACKEND_ID="$(teamctl status --json | jq -r '[.agents[] | select(.role == "backend")][0].session_id')" # status reads THIS conversation
/bin/mkdir -p "$BACKEND_TRANS"
{
  echo 'this line is not json'
  echo '{"type":"user","message":{"content":"hi"}}'
  echo '{"type":"assistant","message":{"usage":{"input_tokens":50000,"cache_read_input_tokens":20000,"cache_creation_input_tokens":5000}}}'
  echo '{"type":"assistant","message":{"usage":{"input_tokens":100000,"cache_read_input_tokens":30000,"cache_creation_input_tokens":12000}}}'
} >"$BACKEND_TRANS/$BACKEND_ID.jsonl"
check "status: context in use is what the last assistant turn saw (input plus both caches), every counted turn is a request" 'teamctl status --json | jq -e "[.agents[] | select(.role == \"backend\")][0] | .context_tokens == 142000 and .requests == 2 and .context_window == 200000"'
check "status: the CONTEXT column shows the tokens and the share of the window" 'teamctl status | grep -E "backend .*142k +71%"'
check "status: nothing readable shows as -, in json as null and 0" 'teamctl status --json | jq -e "[.agents[] | select(.role == \"qa\")][0] | .context_tokens == null and .requests == 0" && teamctl status | grep "🐶 qa " | grep -Eq "0 +- "'
{
  for i in $(seq 1 500); do echo '{"type":"user","message":{"content":"filler"}}'; done
  echo 'garbage again, inside the tail'
  echo '{"type":"assistant","message":{"usage":{"input_tokens":100000,"cache_read_input_tokens":30000,"cache_creation_input_tokens":12000}}}'
} >"$BACKEND_TRANS/$BACKEND_ID.jsonl"
check "status: only the tail of a long transcript is read, and a malformed line never breaks it" 'teamctl status --json | jq -e "[.agents[] | select(.role == \"backend\")][0] | .context_tokens == 142000 and .requests == 1"'
# Another conversation in the same folder, written to later: another lead of the project, or a session of your own.
echo '{"type":"assistant","message":{"usage":{"input_tokens":7000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' >"$BACKEND_TRANS/somebody-elses-session.jsonl"
touch -t 202609230900 "$BACKEND_TRANS/$BACKEND_ID.jsonl" && touch -t 202609230905 "$BACKEND_TRANS/somebody-elses-session.jsonl"
check "status: CONTEXT is read from the agent's own conversation (its stored id), not from a newer transcript in the same folder" 'teamctl status --json | jq -e "[.agents[] | select(.role == \"backend\")][0] | .context_tokens == 142000 and .requests == 1"'
CODEX_TREE="$WORK/codex-worker-tree"
/bin/mkdir -p "$CODEX_TREE" "$WOLFMUX_CODEX_SESSIONS/2026/09/23"
codex_meta() { printf '{"type":"session_meta","payload":{"cwd":"%s"}}\n' "$1"; }
codex_tok() { printf '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":%s},"last_token_usage":{"total_tokens":%s},"model_context_window":%s}}}\n' "$1" "$1" "$2"; }
CODEX_ROLLOUT="$WOLFMUX_CODEX_SESSIONS/2026/09/23/rollout-a.jsonl"
{ codex_meta "$CODEX_TREE"; codex_tok 40000 258400; codex_tok 80000 258400; codex_tok 129200 258400; } >"$CODEX_ROLLOUT"
{ codex_meta "/somewhere/else"; codex_tok 900000 400000; } >"$WOLFMUX_CODEX_SESSIONS/2026/09/23/rollout-b.jsonl"
touch -t 202609230900 "$CODEX_ROLLOUT" && touch -t 202609230905 "$WOLFMUX_CODEX_SESSIONS/2026/09/23/rollout-b.jsonl"
CTX_AGENTS="$(ls -d "$WOLFMUX_DATA"/state/*/agents | head -1)"
plant_ctx() { # <role> <model> <family> <workdir> — a record made by hand, as "plant" does below
  jq -n --arg role "$1" --arg model "$2" --arg family "$3" --arg dir "$4" \
    '{role: $role, kind: "worker", model: $model, model_id: "", label: $model, family: $family, billing: "plan", launcher: "/bin/true",
      workdir: $dir, branch: ("ai/" + $role + "-1"), base_ref: "main", base_commit: "", kickoff: "0", spawned_by: "operator",
      permissions: "skip", pane_id: "", state: "stopped", created_at: "2099-01-01T00:00:00Z"}' >"$CTX_AGENTS/$1.json"
}
plant_ctx ctx-codex astra codex "$CODEX_TREE"
plant_ctx ctx-old fable claude "$BACKEND_DIR" # no session_id: a record from before conversation ids
check "status: a record from before conversation ids still reads the newest transcript of its folder" 'teamctl status --json | jq -e "[.agents[] | select(.role == \"ctx-old\")][0] | .context_tokens == 7000 and .session_id == \"\""'
check "status: a codex agent is read from the rollout whose session cwd is its worktree: last token_count event, its window, its request count" 'teamctl status --json | jq -e "[.agents[] | select(.role == \"ctx-codex\")][0] | .context_tokens == 129200 and .requests == 3 and .context_window == 258400"'
check "status: the codex agent's column" 'teamctl status | grep -E "ctx-codex .*129k +50%"'
plant_ctx ctx-1m "claude:claude-opus-4-1[1m]" claude "/nonexistent/ctx"
plant_ctx ctx-kimi kimi claude "/nonexistent/ctx"
plant_ctx ctx-ds "deepseek:deepseek-v4-flash" claude "/nonexistent/ctx"
check "status: the window is declared by the provider table, 1M for a model id that ends in [1m], 200k for the rest" 'teamctl status --json | jq -e "([.agents[] | select(.role == \"ctx-1m\")][0].context_window == 1048576) and ([.agents[] | select(.role == \"ctx-kimi\")][0].context_window == 262144) and ([.agents[] | select(.role == \"ctx-ds\")][0].context_window == 786432) and ([.agents[] | select(.role == \"ctx-1m\")][0].context_tokens == null)"'
/bin/rm -f "$CTX_AGENTS/ctx-old.json" "$CTX_AGENTS/ctx-codex.json" "$CTX_AGENTS/ctx-1m.json" "$CTX_AGENTS/ctx-kimi.json" "$CTX_AGENTS/ctx-ds.json"

echo "== a fresh conversation in an existing built worktree (spawn --from-worktree, issue #5)"
teamctl spawn builder glm53 --no-kickoff >/dev/null 2>&1
sleep 2
BUILDER_DIR="$(teamctl status --json | jq -r '.agents[] | select(.role == "builder") | .workdir')"
(cd "$BUILDER_DIR" && echo "node_modules/" >.gitignore && git add .gitignore && git -c user.name=builder -c user.email=b@example.invalid commit -qm "chore: ignore node_modules" && mkdir -p node_modules && echo x >node_modules/x)
check "spawn: --from-worktree refuses a running worker, and creates nothing" 'teamctl spawn x1 glm53 --from-worktree builder; [ $? -eq 1 ] && [ -z "$(git branch --list "ai/x1-*")" ]'
check "spawn: --from-worktree refuses the lead (it has no worktree to hand over)" 'teamctl spawn x2 glm53 --from-worktree lead; [ $? -eq 1 ]'
teamctl stop builder >/dev/null 2>&1
echo "half done" >"$BUILDER_DIR/wip.txt"
check "spawn: --from-worktree refuses a worktree with uncommitted changes, and lists them" 'out="$(teamctl spawn builder2 flash --from-worktree builder 2>&1)"; [ $? -eq 1 ] && printf "%s" "$out" | grep -q "wip.txt" && ! teamctl status --json | jq -e ".agents[] | select(.role == \"builder2\")" && [ -z "$(git branch --list "ai/builder2-*")" ]'
/bin/rm "$BUILDER_DIR/wip.txt"
teamctl policy worker-spawn on >/dev/null 2>&1
check "spawn: --from-worktree is the lead's decision: a worker may not take another worker's worktree, even with worker-spawn on (exit 77), and nothing changes" 'TEAM_ROLE=qa teamctl spawn thief flash --from-worktree builder --no-kickoff; [ $? -eq 77 ] && teamctl status --json | jq -e "([.agents[] | select(.role == \"builder\")] | length == 1) and ([.agents[] | select(.role == \"thief\")] | length == 0)" && [ -z "$(git branch --list "ai/thief-*")" ]'
teamctl policy worker-spawn off >/dev/null 2>&1
BUILDER_OLD_BRANCH="$(git -C "$BUILDER_DIR" branch --show-current)"
check "spawn: --from-worktree starts a fresh worker in the same worktree, on a new branch, and the old record is gone" 'teamctl spawn builder2 flash --from-worktree builder && sleep 2 && teamctl status --json | jq -e --arg dir "$BUILDER_DIR" "([.agents[] | select(.role == \"builder2\")][0] | .state == \"running\" and .workdir == \$dir and (.branch | startswith(\"ai/builder2-\"))) and ([.agents[] | select(.role == \"builder\")]) == []"'
check "spawn: --from-worktree bases the new branch on the project's current HEAD" 'teamctl diff builder2 | grep -q "base:    main @ $(git rev-parse --short=12 HEAD)"'
check "spawn: the old branch and its commits stay" '[ "$(git show "$BUILDER_OLD_BRANCH:.gitignore" 2>/dev/null)" = "node_modules/" ] && [ "$(git -C "$BUILDER_DIR" branch --show-current)" != "$BUILDER_OLD_BRANCH" ]'
check "spawn: what git ignores (node_modules) is still there, so no install is repeated, and the fresh pane runs" '[ -f "$BUILDER_DIR/node_modules/x" ] && teamctl capture builder2 -n 8 | grep -q "STUB role=builder2" && teamctl capture builder2 -n 8 | grep -q "STUB kickoff_in_progress=yes"'
check "spawn: the event log says the worktree changed hands" 'grep -q "\"type\":\"from-worktree\"" "$(ls -d "$WOLFMUX_DATA"/state/*/events.jsonl | head -1)"'
teamctl stop builder2 >/dev/null 2>&1
teamctl remove builder2 --yes >/dev/null 2>&1
git branch -D "$BUILDER_OLD_BRANCH" >/dev/null 2>&1

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
spoke lead # the Claude lead said something: this is the conversation the team keeps
CLAUDE_LEAD_ID="$(follow status --json | jq -r '[.agents[] | select(.role == "lead")][0].session_id')"
end_agent "$(role_pane lead)"
sleep 1
check "start again: asking for the other lead model brings the lead back as that model" 'follow start astra --no-attach --skip-beads && sleep 1 && follow status --json | jq -e "[.agents[] | select(.role == \"lead\")][0] | .state == \"running\" and .model == \"astra\"" && follow status --json | jq -e ".agents | map(select(.role == \"docs\"))[0].state == \"running\""'
for pane in $(tmux -L "$WOLFMUX_TMUX_SOCKET" list-panes -a -F '#{pane_id}'); do end_agent "$pane"; done
sleep 1
check "start again: status says the session has ended when every agent has exited" 'follow status | grep -q "ended: every agent has exited"'
check "start again: when every agent has exited, start opens a fresh session, not the dead one" 'follow start fable --no-attach --skip-beads --continue && sleep 1 && [ "$(tmux -L "$WOLFMUX_TMUX_SOCKET" list-panes -a | wc -l | tr -d " ")" = 1 ] && follow status --json | jq -e "([.agents[] | select(.role == \"lead\")][0].state == \"running\") and ([.agents[] | select(.role == \"docs\")][0].state == \"stopped\")"'
check "start again: with a Codex lead in between, --continue brings a Claude lead back in the last Claude lead's own conversation (the team kept its id), not in the newest one of the folder" '[ -n "$CLAUDE_LEAD_ID" ] && [ "$(follow status --json | jq -r "[.agents[] | select(.role == \"lead\")][0].session_id")" = "$CLAUDE_LEAD_ID" ] && teamctl capture lead --all | grep -q "STUB resumed=$CLAUDE_LEAD_ID" && ! teamctl capture lead --all | grep -q "no stored conversation id"'
check "start again: a stopped worker kept its worktree and returns with restart" 'follow restart docs && sleep 1 && follow status --json | jq -e "[.agents[] | select(.role == \"docs\")][0].state == \"running\"" && lead_left'
# The tmux server is gone (a reboot, or tmux was ended): every record remains, no session does.
follow start astra --team night --no-attach --skip-beads >/dev/null 2>&1
follow spawn qa flash --team night --no-kickoff >/dev/null 2>&1
tmux -L "$WOLFMUX_TMUX_SOCKET" kill-server >/dev/null 2>&1
sleep 1
check "restart without a session: a worker's refusal in a named team names the exact commands, with the team and --continue" 'out="$(follow restart qa --continue --team night 2>&1)"; [ $? -eq 1 ] && printf "%s" "$out" | grep -q -- "teamctl start astra --team night --continue" && printf "%s" "$out" | grep -q -- "teamctl restart qa --team night --continue"'
check "restart without a session: a worker's refusal in the first team names them without --team" 'out="$(follow restart docs --team default 2>&1)"; [ $? -eq 1 ] && printf "%s" "$out" | grep -q -- "teamctl start fable --continue" && ! printf "%s" "$out" | grep -q -- "--team"'
spoke lead default # the lead said something before the machine went down: there is a conversation to come back to
check "restart without a session: restart lead --continue starts the team again in the lead's own conversation" 'id="$(follow status --json --team default | jq -r "[.agents[] | select(.role == \"lead\")][0].session_id")"; follow restart lead --continue --team default </dev/null && sleep 1 && follow status --json --team default | jq -e "([.agents[] | select(.role == \"lead\")][0] | .state == \"running\" and .model == \"fable\") and ([.agents[] | select(.role == \"docs\")][0].state == \"stopped\")" && [ -n "$id" ] && teamctl capture lead --team default --all | grep -q "STUB resumed=$id"'
fake_conversation 99999999-8888-7777-6666-555555555555
check "restart without a session: --resume <id> reaches the lead through the start it falls back to" 'tmux -L "$WOLFMUX_TMUX_SOCKET" kill-server; sleep 1; follow restart lead --resume 99999999-8888-7777-6666-555555555555 --team default </dev/null && sleep 1 && teamctl capture lead --team default --all | grep -q "STUB resumed=99999999-8888-7777-6666-555555555555" && [ "$(follow status --json --team default | jq -r "[.agents[] | select(.role == \"lead\")][0].session_id")" = "99999999-8888-7777-6666-555555555555" ]'
check "restart without a session: the same in a named team, as the model that led it (Codex resumes with: resume --last)" 'follow restart lead --continue --team night </dev/null && sleep 1 && follow status --json --team night | jq -e "[.agents[] | select(.role == \"lead\")][0] | .state == \"running\" and .model == \"astra\"" && teamctl capture lead --team night --all | grep -q "STUB lastarg=--last"'
check "restart without a session: a plain restart of the lead starts a fresh conversation" 'tmux -L "$WOLFMUX_TMUX_SOCKET" kill-server; sleep 1; follow restart lead --team default </dev/null && sleep 1 && teamctl capture lead --team default --all | grep "STUB flags=" | grep -vq -- "--continue" && teamctl capture lead --team default --all | grep -q "STUB resumed=none" && [ "$(follow status --json --team default | jq -r "[.agents[] | select(.role == \"lead\")][0].session_id")" != "99999999-8888-7777-6666-555555555555" ]'
# What restart_without_session hands to cmd_start, with the libraries loaded and cmd_start replaced by a
# printer: <BD_BIN> is "" (bd is not installed) or a program that finds no workspace (bd is there, this project has none).
restart_args() {
  /bin/mkdir -p "$WORK/rws"
  bash -c 'set -euo pipefail; for m in provider-env common registry beads agents; do . "$1/config/wolfmux/lib/$m.sh"; done
    BD_BIN="$2"; ROOT="$3"; TEAM=default; STATE_DIR="$3/state"; mkdir -p "$STATE_DIR/agents"
    printf "%s\n" "{\"role\":\"lead\",\"kind\":\"lead\",\"model\":\"fable\"}" >"$STATE_DIR/agents/lead.json"
    cmd_start() { printf "START %s\n" "$*"; }
    restart_without_session lead 0' _ "$REPO" "$1" "$WORK/rws" 2>&1
}
check "restart without a session: bd not installed is left to start, which dies loudly as a manual start does (no --skip-beads)" 'out="$(restart_args "")"; printf "%s" "$out" | grep -q "^START fable$" && ! printf "%s" "$out" | grep -q -- "--skip-beads"'
check "restart without a session: bd installed but no Beads workspace in this project is skipped, as before" 'restart_args /usr/bin/false | grep -q "^START fable --skip-beads$"'
teamctl destroy --team night --purge --yes >/dev/null 2>&1
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
check "teams: a name of 50 characters is a team name for every command (status says there is no such team, not that the name is bad); 51 is refused by start and by attach alike, and the message says how long it is" 'long50="$(printf "a%.0s" $(seq 1 50))"; long51="${long50}a"; out="$(teamctl status --team "$long50" 2>&1)"; ! printf "%s" "$out" | grep -q "invalid team name" && for c in "start fable --no-attach --skip-beads" attach status; do out="$(teamctl $c --team "$long51" 2>&1)"; [ $? -eq 64 ] || exit 1; printf "%s" "$out" | grep -q "is 51 characters, max 50" || exit 1; done'
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

echo "== tab completion (teamctl _complete: read-only, silent, harmless)"
# Two teams exist here (default and review). A pending approval file is written BY HAND
# (never by _complete) before the snapshot below, so approve/deny have something to offer.
APPROVALS="$(/bin/ls -d "$WOLFMUX_DATA"/state/*/)approvals"
/bin/mkdir -p "$APPROVALS"
jq -n '{id: "A90", role: "backend", tool: "Bash", summary: "test", cwd: ".", status: "pending", created_at: "x", created_epoch: 0, decided_by: "", reason: ""}' >"$APPROVALS/A90.json"
COMP_BEFORE="$(find "$WOLFMUX_DATA" | sort)"
COMP_SESSIONS="$(tmux -L "$WOLFMUX_TMUX_SOCKET" ls 2>/dev/null | wc -l | tr -d ' ')"
comp_err="$WORK/complete.err"
complete_is() { # <description> <expected-grep-ERE> <args after "teamctl _complete --">
  local desc="$1" pattern="$2"
  shift 2
  local out
  out="$("$REPO/bin/teamctl" _complete -- "$@" 2>"$comp_err")"
  local rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$comp_err" ] && printf '%s\n' "$out" | grep -Eq -- "$pattern"; then
    passed=$((passed + 1))
    printf '  pass  %s\n' "$desc"
  else
    failed=$((failed + 1))
    printf '  FAIL  %s (rc=%s out=%s)\n' "$desc" "$rc" "$(printf '%s' "$out" | tr '\n' '|')"
  fi
}
complete_isnt() { # <description> <forbidden-grep-ERE> <args ...>: rc 0, silent, and no match
  local desc="$1" pattern="$2"
  shift 2
  local out
  out="$("$REPO/bin/teamctl" _complete -- "$@" 2>"$comp_err")"
  local rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$comp_err" ] && ! printf '%s\n' "$out" | grep -Eq -- "$pattern"; then
    passed=$((passed + 1))
    printf '  pass  %s\n' "$desc"
  else
    failed=$((failed + 1))
    printf '  FAIL  %s (rc=%s out=%s)\n' "$desc" "$rc" "$(printf '%s' "$out" | tr '\n' '|')"
  fi
}
complete_empty() { # <description> <args ...>: rc 0, silent, no output at all
  local desc="$1"
  shift
  local out
  out="$("$REPO/bin/teamctl" _complete -- "$@" 2>"$comp_err")"
  local rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$comp_err" ] && [ -z "$out" ]; then
    passed=$((passed + 1))
    printf '  pass  %s\n' "$desc"
  else
    failed=$((failed + 1))
    printf '  FAIL  %s (rc=%s out=%s)\n' "$desc" "$rc" "$(printf '%s' "$out" | tr '\n' '|')"
  fi
}
complete_is "completion: the first word offers the public commands with descriptions" '^start	|^spawn	|^status	|^doctor	' ""
complete_is "completion: the aliases workers, open and log are offered" '^workers	|^open	|^log	' ""
complete_is "completion: --team, help and version are offered as the first word" '^--team	|^help	|^version	' ""
complete_empty "completion: no internal command is offered" "_"
complete_is "completion: re<TAB> offers remove and restart" '^remove	|^restart	' "re"
complete_is "completion: the options of start" '^--no-attach	|^--continue	|^--handover	|^--ticket	|^--init-beads	|^--skip-beads	|^--lead-permissions	|^--worker-permissions	|^--worker-spawn	|^--resume	' "start" "--"
complete_is "completion: the options of spawn, --resume included" '^--base	|^--from-worktree	|^--branch	|^--ticket	|^--repo	|^--no-kickoff	|^--resume	' "spawn" "--"
complete_is "completion: the options of capture and doctor" '^--lines$|^--all$' "capture" "--"
complete_is "completion: doctor offers --probe; diff its modes" '^--probe$' "doctor" "--"
complete_is "completion: diff offers its modes" '^--stat$|^--names$|^--commits$|^--working$' "diff" "--"
complete_is "completion: status and teams offer --json, approvals --all" '^--json$' "status" "--"
complete_is "completion: --team completes the team names of the project" '^default$|^review$|^default	|^review	' "--team" ""
complete_is "completion: --team= completes in place" '^--team=review' "--team=rev"
complete_empty "completion: several teams and no --team: no roles are offered" "restart" ""
complete_is "completion: restart offers the roles of the team --team names" '^lead$|^backend$|^lead	|^backend	' "--team" "review" "restart" ""
complete_is "completion: the role prefix filters" '^backend' "--team" "default" "restart" "ba"
complete_is "completion: remove offers workers only, never the lead" '^backend	|^qa	' "--team" "default" "remove" ""
complete_isnt "completion: remove never offers the lead" '^lead($TAB|\$)' "--team" "default" "remove" ""
complete_is "completion: --from-worktree offers workers only" '^backend	|^qa	' "--team" "default" "spawn" "x" "--from-worktree" ""
complete_is "completion: nudge and capture and diff offer roles" '^lead	|^backend	|^qa	' "--team" "review" "nudge" ""
complete_is "completion: start completes the model keys with their labels" '^glm53	GLM-5.3$|^flash	GLM-5.3 Flash$|^fable	Fable 5.1$' "start" ""
complete_is "completion: spawn <role> completes the models, providers included" '^kimi	' "spawn" "x" ""
complete_is "completion: policy completes the keys" '^lead-permissions$|^worker-spawn$|^branch-template$' "policy" ""
complete_is "completion: policy <key> completes the fixed choices" '^on$|^off$' "policy" "worker-spawn" ""
complete_is "completion: policy <key> completes skip and ask" '^skip$|^ask$' "policy" "worker-permissions" ""
complete_empty "completion: branch-template is free text: no value is offered" "policy" "branch-template" ""
complete_empty "completion: an unknown team is silent and harmless" "--team" "nowhere" "restart" ""
complete_is "completion: layout completes the layout names" '^lead-left$|^lead-top$|^tiled$' "layout" ""
complete_is "completion: approve and deny offer the pending approval ids" '^A90$|^A90	' "--team" "default" "approve" ""
complete_is "completion: deny offers the ids from their prefix" '^A90$|^A90	' "--team" "default" "deny" "A"
complete_is "completion: --branch and --base complete local branch names" '^main$|^release$' "spawn" "x" "--branch" ""
complete_is "completion: --base completes branch names too" '^release$|^main$' "spawn" "x" "--base" ""
complete_is "completion: --repo hands file completion back to the shell" '^__files__$' "spawn" "x" "--repo" ""
complete_empty "completion: after an option that takes free text nothing is offered: restart --resume" "--team" "default" "restart" "--resume" ""
complete_empty "completion: the same for start --handover (no models) and nudge --id (no roles)" "start" "--handover" ""
complete_empty "completion: and for nudge --id" "--team" "default" "nudge" "--id" ""
complete_empty "completion: and for capture -n" "--team" "default" "capture" "-n" ""
complete_is "completion: capture -n 20 <Tab> offers the roles: -n took its value" '^backend	' "--team" "default" "capture" "-n" "20" ""
complete_is "completion: completion completes the shells" '^zsh$|^bash$' "completion" ""
check "completion: it left the state directory, the tmux sessions and stderr untouched" '[ "$(find "$WOLFMUX_DATA" | sort)" = "$COMP_BEFORE" ] && [ "$(tmux -L "$WOLFMUX_TMUX_SOCKET" ls 2>/dev/null | wc -l | tr -d " ")" = "$COMP_SESSIONS" ] && [ ! -s "$comp_err" ]'
/bin/rm -f "$APPROVALS/A90.json" # the request planted above: no later check may find it pending
complete_is "completion: start --lead-permissions completes its choices" '^skip$|^ask$' "start" "fable" "--lead-permissions" ""
complete_is "completion: spawn --worker-spawn is not an option of spawn, start's is completed with on and off" '^on$|^off$' "start" "fable" "--worker-spawn" ""
outside() { (cd "$WORK" && "$REPO/bin/teamctl" _complete -- "$@" 2>"$comp_err"); } # $WORK is no git repository
# Each answer is captured whole before it is searched: a grep -q on the pipe would close it under the backend.
check "completion: outside a git repository what needs no project is still offered: commands, options, models, policy keys" 'a="$(outside "")" && [ ! -s "$comp_err" ] && b="$(outside start "--")" && c="$(outside spawn x "")" && d="$(outside policy "")" && [ ! -s "$comp_err" ] && printf "%s\n" "$a" | grep -q "^restart	" && printf "%s\n" "$b" | grep -q "^--continue" && printf "%s\n" "$c" | grep -q "^fable	" && printf "%s\n" "$d" | grep -qx "worker-spawn"'
check "completion: outside a git repository what belongs to a project is empty, exit 0, nothing on stderr: roles, teams, branches, approvals" 'for words in "restart|" "--team|" "spawn|x|--base|" "approve|"; do old_ifs="$IFS"; IFS="|"; set -- $words ""; IFS="$old_ifs"; out="$(outside "$@")" || exit 1; [ -z "$out" ] || exit 1; done; [ ! -s "$comp_err" ]'

echo "== tab completion (the shims)"
SHIM_DIR="$REPO/config/wolfmux/completion"
check "shims: the zsh shim registers _teamctl with compdef when compinit has run, and only then" 'zsh -f -c "autoload -Uz compinit; compinit -u -d $WORK/zcompdump; source $SHIM_DIR/teamctl.zsh; print -r -- \$_comps[teamctl]" | grep -qx "_teamctl"'
check "shims: without compinit the zsh shim is silent, errors nowhere, and registers nothing" 'zsh -f -c "out=\$(source $SHIM_DIR/teamctl.zsh 2>&1); print -r -- \"\$out\${_comps[teamctl]-none}\"" | grep -qx "none"'
check "shims: a real bash completion for teamctl re<TAB> offers remove and restart" 'PATH="$REPO/bin:$PATH" bash --noprofile --norc -c "source $SHIM_DIR/teamctl.bash; COMP_WORDS=(teamctl re); COMP_CWORD=1; _teamctl_bash; printf \"%s\n\" \"\${COMPREPLY[@]}\"" | grep -qx "remove" && PATH="$REPO/bin:$PATH" bash --noprofile --norc -c "source $SHIM_DIR/teamctl.bash; COMP_WORDS=(teamctl re); COMP_CWORD=1; _teamctl_bash; printf \"%s\n\" \"\${COMPREPLY[@]}\"" | grep -qx "restart"'
check "shims: bash completes the values too (models) and falls back to directories on __files__" 'PATH="$REPO/bin:$PATH" bash --noprofile --norc -c "source $SHIM_DIR/teamctl.bash; COMP_WORDS=(teamctl spawn x \"\"); COMP_CWORD=3; _teamctl_bash; printf \"%s\n\" \"\${COMPREPLY[@]}\"" | grep -qx "glm53" && ( cd "$WORK" && PATH="$REPO/bin:$PATH" bash --noprofile --norc -c "source $SHIM_DIR/teamctl.bash; COMP_WORDS=(teamctl spawn x --repo \"\"); COMP_CWORD=4; _teamctl_bash; printf \"%s\n\" \"\${COMPREPLY[@]}\"" | grep -qx "data" )'
git branch 'a$(x)' >/dev/null 2>&1 # git takes almost anything as a branch name; a shell must not run it
check "shims: bash inserts a hostile branch name quoted, never as it is (a\$(x) could run on Enter)" 'out="$(PATH="$REPO/bin:$PATH" bash --noprofile --norc -c "source $SHIM_DIR/teamctl.bash; COMP_WORDS=(teamctl spawn x --base a); COMP_CWORD=4; _teamctl_bash; printf \"%s\n\" \"\${COMPREPLY[@]}\"")"; printf "%s\n" "$out" | grep -Fqx "a\\\$\\(x\\)" && ! printf "%s\n" "$out" | grep -Fqx "a\$(x)"'
git branch -D 'a$(x)' >/dev/null 2>&1
check "shims: the documented way to load it works in macOS bash 3.2 (eval, not source <(…)) and registers the completer" 'PATH="$REPO/bin:$PATH" /bin/bash --noprofile --norc -c "eval \"\$(teamctl completion bash)\"; complete -p teamctl" | grep -q -- "-F _teamctl_bash teamctl"'
check "shims: a reader that has gone away before the script is printed is no crash: nothing on stderr (it was: stopped unexpectedly, exit 141)" '{ sleep 1; teamctl completion bash 2>"$WORK/completion.err"; } | true; [ ! -s "$WORK/completion.err" ]'
check "shims: the documented way to load it in zsh (source <(teamctl completion zsh)) registers the completer" 'PATH="$REPO/bin:$PATH" zsh -f -c "autoload -Uz compinit; compinit -u -d $WORK/zcompdump2; source <(teamctl completion zsh); print -r -- \$_comps[teamctl]" | grep -qx "_teamctl"'
check "shims: teamctl completion prints them; no argument or an unknown shell is a usage error (exit 64)" 'teamctl completion zsh | grep -q "_teamctl" && teamctl completion bash | grep -q "_teamctl_bash" && { teamctl completion tcsh >/dev/null 2>&1; [ $? -eq 64 ]; } && { teamctl completion >/dev/null 2>&1; [ $? -eq 64 ]; }'

echo "== a lead recovers and cleans up a team it founded (issue #2)"
# review founds "child" with a handover, then child's lead dies. Its founder, review.lead, must be able to
# bring it back or delete it without you and without founding a replacement. The first team's lead
# ("lead" in Beads) is a third party to child, and so is every worker.
as_agent() { # <team> <role> <teamctl args…>: what that agent's own pane runs (a pane exports both variables)
  local team="$1" role="$2"
  shift 2
  TEAM_ROLE="$role" WOLFMUX_TEAM="$team" WOLFMUX_NOTIFY_TTY="$WORK/tty-founder" WOLFMUX_OSASCRIPT="$FAKE_OSA" "$REPO/bin/teamctl" "$@"
}
lead_pane_of() { teamctl status --json --team "$1" | jq -r '.agents[] | select(.role == "lead") | .pane'; }
# refused_for "<team> <role>" <yes|no> <command>...: each is refused with exit 77 (on team child); yes/no: with the founder's hint or without it
FOUNDER_HINT="you founded it: once its lead has stopped you may restart or destroy it"
refused_for() {
  local who="$1" hint="$2" command out
  shift 2
  for command in "$@"; do
    out="$(as_agent $who $command --team child 2>&1)"
    [ $? -eq 77 ] || { echo "not refused (77): $who $command" >&2; return 1; }
    if [ "$hint" = yes ]; then
      printf '%s' "$out" | grep -q "$FOUNDER_HINT" || { echo "no hint: $who $command" >&2; return 1; }
    elif printf '%s' "$out" | grep -q "you founded it"; then
      echo "unexpected hint: $who $command" >&2
      return 1
    fi
  done
}
as_agent review lead start fable --team child --no-attach --skip-beads --handover abc-88 >/dev/null 2>&1
teamctl spawn kid flash --team child --no-kickoff >/dev/null 2>&1
sleep 2
CHILD_DIR="$(ls -d "$WOLFMUX_DATA"/state/*/teams/child)"
CHILD_SESSION="$FIRST_SESSION-child"
CHILD_LEAD_RECORD="$CHILD_DIR/agents/lead.json"
CHILD_CREATED="$(jq -r .created_at "$CHILD_LEAD_RECORD")"
check "founder: status --json names the founder, and a running team is not orphaned" 'teamctl status --json --team child | jq -e ".founder == \"review.lead\" and .orphaned == false and .agents[0].spawned_by == \"review.lead\"" && teamctl status --json --team review | jq -e ".founder == \"operator\" and .orphaned == false"'
check "founder: while the founded team's lead runs, its founder is refused (exit 77) and the refusal says it may act once that lead has stopped" 'refused_for "review lead" yes "restart lead" "restart kid --continue" "stop lead" "destroy --yes" "destroy --purge --force" "remove kid --force --yes" "start fable --continue" && teamctl status --json --team child | jq -e ".session_running and .orphaned == false"'
check "founder: the lead of another team and any worker are refused (exit 77) as before, with no such hint" 'refused_for "default lead" no "stop lead" "restart lead" "destroy --purge --force" "start fable --continue" && refused_for "review backend" no "stop lead" "restart lead" "destroy --purge --force" "start fable --continue" && refused_for "child kid" no "stop lead" "restart lead" "destroy --purge --force"'
end_agent "$(lead_pane_of child)"
sleep 1
check "founder: once its lead has exited the team is orphaned: teams and status say so, and who may act on it" 'teamctl teams | grep -E "^child +orphaned " | grep -q "review.lead" && teamctl teams | grep -q "child is orphaned: its lead is not running. May act on it: you, review.lead (its founder)" && teamctl status --json --team child | jq -e ".orphaned == true and .founder == \"review.lead\"" && teamctl status --team child | grep -q "orphaned: its lead is not running. May act on it: you, review.lead (its founder)" && teamctl status --json --team review | jq -e ".orphaned == false"'
check "founder: teams --json carries founder and orphaned as well" 'teamctl teams --json | jq -e "([.[] | select(.team == \"child\")][0] | .orphaned == true and .founder == \"review.lead\" and .state == \"orphaned\") and ([.[] | select(.team == \"review\")][0] | .orphaned == false and .founder == \"operator\")"'
check "founder: an orphaned team is still closed to a third party (exit 77), and the founder gets no more than restart, stop, remove and destroy (policy stays with the lead)" 'refused_for "default lead" no "stop lead" "restart lead" "destroy --purge --force" "start fable --continue" && refused_for "review backend" no "stop lead" "restart lead --continue" && refused_for "review lead" no "policy worker-spawn on"'
spoke lead child
CHILD_CONVERSATION="$(teamctl status --json --team child | jq -r '[.agents[] | select(.role == "lead")][0].session_id')"
check "founder: it restarts the orphaned lead in its last conversation (exit 0), you are told, and it stays the founder" ': >"$WORK/tty-founder"; as_agent review lead restart lead --continue --team child </dev/null && sleep 1 && teamctl status --json --team child | jq -e "([.agents[] | select(.role == \"lead\")][0].state == \"running\") and .founder == \"review.lead\" and .orphaned == false" && [ -n "$CHILD_CONVERSATION" ] && teamctl capture lead --team child --all | grep -q "STUB resumed=$CHILD_CONVERSATION" && grep -q "review.lead restarted team .child., which it founded" "$WORK/tty-founder"'
check "founder: the event log says who acted (by is the founder's Beads identity, not the plain role)" 'jq -e "select(.type == \"restart\" and .role == \"lead\" and .by == \"review.lead\")" "$CHILD_DIR/events.jsonl"'
tmux -L "$WOLFMUX_TMUX_SOCKET" kill-session -t "=$CHILD_SESSION" >/dev/null 2>&1
sleep 1
check "founder: with no session at all it is orphaned too, and restart lead brings it back: a fresh start still gets its handover, and the founder and creation time are kept" ': >"$WORK/tty-founder"; teamctl teams | grep -Eq "^child +orphaned " && as_agent review lead restart lead --team child </dev/null && sleep 2 && teamctl status --json --team child | jq -e ".founder == \"review.lead\" and .agents[0].spawned_by == \"review.lead\" and .orphaned == false" && teamctl capture lead --team child --all | grep -q "STUB lastarg=.*abc-88" && [ "$(jq -r .handover "$CHILD_LEAD_RECORD")" = abc-88 ] && [ "$(jq -r .created_at "$CHILD_LEAD_RECORD")" = "$CHILD_CREATED" ] && grep -q "review.lead restarted team .child., which it founded" "$WORK/tty-founder"'
tmux -L "$WOLFMUX_TMUX_SOCKET" kill-session -t "=$CHILD_SESSION" >/dev/null 2>&1
sleep 1
check "restart without a session: a plain restart by you keeps the founder, the handover and the creation time as well (wolfmux-a65)" 'teamctl restart lead --team child </dev/null && sleep 2 && teamctl status --json --team child | jq -e ".founder == \"review.lead\" and .agents[0].spawned_by == \"review.lead\"" && teamctl capture lead --team child --all | grep -q "STUB lastarg=.*abc-88" && [ "$(jq -r .created_at "$CHILD_LEAD_RECORD")" = "$CHILD_CREATED" ]'
tmux -L "$WOLFMUX_TMUX_SOCKET" kill-session -t "=$CHILD_SESSION" >/dev/null 2>&1
sleep 1
spoke lead child # the plain restart above gave it a new conversation: it said something in that one too
CHILD_CONVERSATION="$(teamctl status --json --team child | jq -r '[.agents[] | select(.role == "lead")][0].session_id')"
check "founder: start <model> --team <team> --continue works for the founder of a team whose lead is not running" 'as_agent review lead start fable --team child --continue --no-attach --skip-beads && sleep 2 && teamctl status --json --team child | jq -e ".founder == \"review.lead\" and .orphaned == false" && [ -n "$CHILD_CONVERSATION" ] && teamctl capture lead --team child --all | grep "STUB resumed=" | tail -1 | grep -q "resumed=$CHILD_CONVERSATION" && [ "$(jq -r .handover "$CHILD_LEAD_RECORD")" = abc-88 ]'
end_agent "$(lead_pane_of child)"
sleep 1
check "founder: it stops the founded team's lead while that lead is not running (exit 0), and you are told" ': >"$WORK/tty-founder"; as_agent review lead stop lead --team child && teamctl status --json --team child | jq -e "[.agents[] | select(.role == \"lead\")][0].state == \"stopped\"" && grep -q "review.lead stopped the lead of team .child., which it founded" "$WORK/tty-founder"'
check "founder: it takes a stopped worker of the founded team off the books (exit 0), and you are told" ': >"$WORK/tty-founder"; as_agent review lead remove kid --force --yes --team child && ! teamctl status --json --team child | jq -e ".agents[] | select(.role == \"kid\")" && grep -q "review.lead removed kid from team .child., which it founded" "$WORK/tty-founder"'
check "founder: it deletes the founded team (destroy --purge --force, exit 0): its records and branches are gone, and you are told" ': >"$WORK/tty-founder"; as_agent review lead destroy --team child --purge --force && ! teamctl teams | grep -q "^child " && [ ! -e "$CHILD_DIR" ] && [ -z "$(git branch --list "ai/child/*")" ] && grep -q "review.lead destroyed team .child., which it founded" "$WORK/tty-founder"'
check "founder: the purge is written to the founder's own event log, by the founder (the deleted team's log went with it)" 'jq -e "select(.type == \"destroy\" and .by == \"review.lead\" and (.detail | contains(\"child\")))" "$(ls -d "$WOLFMUX_DATA"/state/*/teams/review)/events.jsonl"'
# The first team's lead is "lead" in Beads. Ending the team with a plain destroy deletes the lead's record
# (the workers' stay), and the founder must not lose its authority with it.
teamctl spawn w1 flash --team fresh --no-kickoff >/dev/null 2>&1
sleep 1
end_agent "$(lead_pane_of fresh)"
sleep 1
check "founder: the first team's lead (plain 'lead' in Beads) restarts the team it founded just the same (exit 0)" ': >"$WORK/tty-founder"; as_agent default lead restart lead --team fresh --continue </dev/null && sleep 1 && teamctl status --json --team fresh | jq -e ".founder == \"lead\" and .orphaned == false" && grep -q "lead restarted team .fresh., which it founded" "$WORK/tty-founder"'
end_agent "$(lead_pane_of fresh)"
sleep 1
check "founder: a plain destroy does not cost the founder its authority (the founder is kept with the team, not only in the lead's record): it can still delete the team afterwards" 'as_agent default lead destroy --team fresh --yes </dev/null && [ ! -e "$(ls -d "$WOLFMUX_DATA"/state/*/teams/fresh)/agents/lead.json" ] && teamctl status --json --team fresh | jq -e ".founder == \"lead\" and .orphaned == true" && teamctl teams | grep -E "^fresh +orphaned " | grep -q " lead " && as_agent default lead destroy --team fresh --purge --force && ! teamctl teams | grep -q "^fresh " && [ -z "$(git branch --list "ai/fresh/*")" ]'
teamctl destroy --team fresh --purge --yes >/dev/null 2>&1
echo "== branch names that fit a project's rules (issue #3)"
teamctl start fable --team naming --no-attach --skip-beads >/dev/null 2>&1
teamctl spawn plain flash --team naming --no-kickoff >/dev/null 2>&1
sleep 2
NAMING_AGENTS="$(ls -d "$WOLFMUX_DATA"/state/*/teams/naming/agents)"
naming_branch() { teamctl status --json --team naming | jq -r --arg role "$1" '.agents[] | select(.role == $role) | .branch'; }
check "branch names: with no template the shape is the one wolfmux has always used, and the record says teamctl created that branch" 'case "$(naming_branch plain)" in ai/naming/plain-*) true ;; *) false ;; esac && git rev-parse -q --verify "refs/heads/$(naming_branch plain)" >/dev/null && [ "$(jq -r .branch_created "$NAMING_AGENTS/plain.json")" = "1" ]'
teamctl spawn sam flash --team naming --branch feature-AFD-1844-sam --no-kickoff >/dev/null 2>&1
sleep 2
SAM_TREE="$(teamctl status --json --team naming | jq -r '.agents[] | select(.role == "sam") | .workdir')"
check "branch names: --branch gives the worker exactly that branch, and its pane opens on it" '[ "$(naming_branch sam)" = "feature-AFD-1844-sam" ] && git rev-parse -q --verify refs/heads/feature-AFD-1844-sam >/dev/null && [ "$(git -C "$SAM_TREE" branch --show-current)" = "feature-AFD-1844-sam" ] && teamctl capture sam --team naming --all | grep -q "STUB cwd=.* branch=feature-AFD-1844-sam"'
check "branch names: --branch refuses a name git would not take (64) and one that exists already (1); neither leaves a record, a worktree or a branch behind" 'teamctl spawn bad1 flash --team naming --branch "no spaces" --no-kickoff; [ $? -eq 64 ] && { teamctl spawn bad2 flash --team naming --branch main --no-kickoff; [ $? -eq 1 ]; } && ! teamctl status --json --team naming | jq -e ".agents[] | select(.role == \"bad1\" or .role == \"bad2\")" && git rev-parse -q --verify refs/heads/main >/dev/null && [ "$(git rev-parse refs/heads/main)" = "$(git rev-parse HEAD)" ]'
check "branch names: a template with no {ts}, an unknown placeholder, an unclosed brace or nothing at all is refused (exit 64) and nothing is stored" '( for t in "feature-{ticket}-{role}" "ai/{role}-{ts}-{author}" "ai/{role}-{ts" ""; do teamctl policy branch-template "$t" --team naming; [ $? -eq 64 ] || exit 1; done ) && teamctl policy --team naming | grep -q "ai/{team}/{role}-{ts}"'
teamctl policy branch-template 'feature-{ticket}-{role}-{ts}' --team naming >/dev/null 2>&1
check "branch names: a template with {ticket} and no ticket is a usage error that names the flag (exit 64); nothing is created" 'out="$(teamctl spawn dev flash --team naming --no-kickoff 2>&1)"; [ $? -eq 64 ] && printf "%s" "$out" | grep -q -- "--ticket" && ! teamctl status --json --team naming | jq -e ".agents[] | select(.role == \"dev\")" && [ -z "$(git branch --list "feature-*-dev-*")" ]'
check "branch names: an invalid ticket key is refused before anything is created (exit 64)" '( for k in "AFD 1844" "AFD/1844" "-AFD" ""; do teamctl spawn dev flash --team naming --ticket "$k" --no-kickoff; [ $? -eq 64 ] || exit 1; done ) && ! teamctl status --json --team naming | jq -e ".agents[] | select(.role == \"dev\")"'
teamctl spawn dev flash --team naming --ticket AFD-1844 --no-kickoff >/dev/null 2>&1
sleep 2
check "branch names: the template plus --ticket gives a conforming name, with the uniqueness stamp kept" 'printf "%s" "$(naming_branch dev)" | grep -Eq "^feature-AFD-1844-dev-[0-9]{8}-[0-9]{6}$" && git rev-parse -q --verify "refs/heads/$(naming_branch dev)" >/dev/null'
teamctl start flash --team ticketed --no-attach --skip-beads --ticket TEAM-7 >/dev/null 2>&1
teamctl policy branch-template 'feature-{ticket}-{role}-{ts}' --team ticketed >/dev/null 2>&1
teamctl spawn one flash --team ticketed --no-kickoff >/dev/null 2>&1
teamctl spawn two flash --team ticketed --ticket OTHER-9 --no-kickoff >/dev/null 2>&1
sleep 2
ticketed_branch() { teamctl status --json --team ticketed | jq -r --arg role "$1" '.agents[] | select(.role == $role) | .branch'; }
check "branch names: teamctl start --ticket is the team's default ticket, and a spawn's own --ticket wins over it" 'printf "%s" "$(ticketed_branch one)" | grep -q "^feature-TEAM-7-one-" && printf "%s" "$(ticketed_branch two)" | grep -q "^feature-OTHER-9-two-"'
check "branch names: teamctl policy shows the team's template, and 'default' puts the built-in shape back" 'teamctl policy --team ticketed | grep -q "feature-{ticket}-{role}-{ts}" && teamctl policy branch-template default --team ticketed && teamctl policy --team ticketed | grep -q "ai/{team}/{role}-{ts}"'
git branch made-by-teamctl
git branch legacy-keep
git branch ai/old-style
plant_branch() { # <role> <branch> [<branch_created>]
  jq -n --arg role "$1" --arg branch "$2" --arg created "${3:-}" \
    '{role: $role, kind: "worker", model: "glm53", label: "GLM-5.3", family: "claude", launcher: "/bin/true",
      workdir: "/nonexistent/wolfmux", branch: $branch, base_ref: "main", base_commit: "", kickoff: "0",
      spawned_by: "operator", permissions: "skip", pane_id: "", state: "stopped"}
     + (if $created == "" then {} else {branch_created: $created} end)' >"$NAMING_AGENTS/$1.json"
}
plant_branch mine made-by-teamctl 1
plant_branch theirs legacy-keep 0
plant_branch older ai/old-style
check "branch names: only a branch teamctl created is ever deleted, whatever it is called; a record from before the field keeps the old ai/ rule, and a branch teamctl did not make is named and left alone" 'out="$(teamctl remove mine theirs older --team naming --yes 2>&1)"; ! git rev-parse -q --verify refs/heads/made-by-teamctl >/dev/null && git rev-parse -q --verify refs/heads/legacy-keep >/dev/null && ! git rev-parse -q --verify refs/heads/ai/old-style >/dev/null && printf "%s" "$out" | grep -q "legacy-keep"'
check "branch names: the guard holds a worker to its own branch whatever that branch is called" 'ans="$(jq -cn --arg c "git checkout main" --arg d "$SAM_TREE" "{hook_event_name: \"PreToolUse\", tool_name: \"Bash\", tool_input: {command: \$c}, cwd: \$d}" | TEAM_ROLE=sam WOLFMUX_ROOT="$ROOT_REAL" WOLFMUX_WORKTREE="$SAM_TREE" WOLFMUX_BRANCH=feature-AFD-1844-sam "$REPO/bin/teamctl" _guard)"; printf "%s" "$ans" | jq -e ".hookSpecificOutput.permissionDecision == \"deny\"" >/dev/null && printf "%s" "$ans" | grep -q "feature-AFD-1844-sam"'
teamctl destroy --team naming --purge --force >/dev/null 2>&1
teamctl destroy --team ticketed --purge --force >/dev/null 2>&1

echo "== a teammate in a sibling repository (issue #4)"
SIBLING="$WORK/sibling repo" # the space is deliberate here too
/bin/mkdir -p "$SIBLING"
(cd "$SIBLING" && git init -q -b main && echo "b" >b.txt &&
  git add -A && git -c user.name=smoke -c user.email=smoke@example.invalid commit -qm "initial commit of the sibling" &&
  git branch release-b && git branch keep-me) >/dev/null 2>&1
SIBLING_REAL="$(cd "$SIBLING" && pwd -P)"
teamctl start flash --team cross --no-attach --skip-beads >/dev/null 2>&1
teamctl spawn srv flash --team cross --repo "$SIBLING" --base release-b --no-kickoff >/dev/null 2>&1
sleep 2
cross_field() { teamctl status --json --team cross | jq -r --arg role "$1" --arg f "$2" '.agents[] | select(.role == $role) | .[$f]'; }
SRV_TREE="$(cross_field srv workdir)"
SRV_BRANCH="$(cross_field srv branch)"
check "cross-repo: the branch and the worktree are created in the sibling repository, from a ref of that repository, and the pane opens there" '[ -n "$SRV_BRANCH" ] && git -C "$SIBLING_REAL" rev-parse -q --verify "refs/heads/$SRV_BRANCH" >/dev/null && ! git -C "$PROJECT" rev-parse -q --verify "refs/heads/$SRV_BRANCH" >/dev/null && [ -f "$SRV_TREE/b.txt" ] && [ ! -e "$SRV_TREE/README.md" ] && teamctl diff srv --team cross | grep -q "base:    release-b" && teamctl capture srv --team cross --all | grep -q "STUB cwd=.*/teams/cross/srv-"'
check "cross-repo: the worktree lives under that repository's own key, and status names the repository (column and JSON)" 'case "$SRV_TREE" in *"/worktrees/sibling-repo-"*"/teams/cross/srv-"*) true ;; *) false ;; esac && [ "$(cross_field srv repo)" = "$SIBLING_REAL" ] && [ "$(cross_field lead repo)" = "" ] && teamctl status --team cross | grep -q "REPO" && teamctl status --team cross | grep -q "sibling repo" && ! teamctl status --team default | grep -q "REPO"'
check "cross-repo: --repo refuses a path that is no directory, no git repository, or a repository without a commit (exit 64); nothing is created" '/bin/mkdir -p "$WORK/notarepo" "$WORK/emptyrepo" && (cd "$WORK/emptyrepo" && git init -q -b main) && ( for p in "$WORK/nosuchdir" "$WORK/notarepo" "$WORK/emptyrepo"; do teamctl spawn nope flash --team cross --repo "$p" --no-kickoff; [ $? -eq 64 ] || exit 1; done ) && ! teamctl status --json --team cross | jq -e ".agents[] | select(.role == \"nope\")"'
guard_srv() { # <tool> <json tool_input> — the guard's answer for the cross-repo worker
  local answer
  answer="$(jq -cn --arg tool "$1" --argjson input "$2" --arg cwd "$SRV_TREE" '{hook_event_name: "PreToolUse", tool_name: $tool, tool_input: $input, cwd: $cwd}' |
    TEAM_ROLE=srv WOLFMUX_ROOT="$ROOT_REAL" WOLFMUX_WORKTREE="$SRV_TREE" WOLFMUX_BRANCH="$SRV_BRANCH" WOLFMUX_REPO="$SIBLING_REAL" "$REPO/bin/teamctl" _guard)"
  if [ -z "$answer" ]; then printf 'allow\n'; else printf '%s' "$answer" | jq -r '.hookSpecificOutput.permissionDecision // "allow"'; fi
}
at() { jq -cn --arg p "$1" '{file_path: $p}'; }
check "cross-repo: isolation stays on and holds that worker to its worktree in the sibling repository; the lead's project and the sibling's own checkout are both read-only" '[ "$(guard_srv Write "$(at "$SRV_TREE/b.txt")")" = allow ] && [ "$(guard_srv Write "$(at "$ROOT_REAL/README.md")")" = deny ] && [ "$(guard_srv Write "$(at "$SIBLING_REAL/b.txt")")" = deny ] && [ "$(guard_srv Read "$(at "$SRV_TREE/b.txt")")" = allow ] && teamctl capture srv --team cross --all | grep -q "STUB guard=true" && teamctl _prompt srv --team cross | grep -qF "ANOTHER repository: $SIBLING_REAL"'
# bd resolves its workspace through git, so a teammate in another repository would look for
# Beads THERE. Its inbox is the team's, wherever its worktree is.
if [ "${HAVE_BD:-0}" -eq 1 ]; then
  check "cross-repo: the teammate still reads the team's own Beads workspace, not the sibling repository's" 'teamctl capture srv --team cross --all | grep -q "STUB beadsdir=.*/\.beads" && ! teamctl capture srv --team cross --all | grep -q "STUB beadsdir=$SIBLING_REAL"'
fi
(cd "$SRV_TREE" && echo x >x.txt && git add -A && git -c user.name=srv -c user.email=srv@example.invalid commit -qm "feat: only in the sibling repo") >/dev/null 2>&1
echo "loose" >"$SRV_TREE/loose.txt"
check "cross-repo: diff, status and worktrees read that repository, not the project" 'teamctl diff srv --team cross --commits | grep -q "feat: only in the sibling repo" && [ "$(cross_field srv commits_ahead)" = "1" ] && [ "$(cross_field srv uncommitted)" = "1" ] && teamctl worktrees --team cross | grep -q "sibling-repo-" && teamctl worktrees --team cross | grep -qF "$SIBLING_REAL"'
check "cross-repo: remove without --force still refuses to discard work, and names the commit and the file that exist nowhere else" 'teamctl stop srv --team cross && out="$(teamctl remove srv --team cross 2>&1)"; [ $? -eq 1 ] && printf "%s" "$out" | grep -q "feat: only in the sibling repo" && printf "%s" "$out" | grep -q "loose.txt" && [ -d "$SRV_TREE" ]'
check "cross-repo: remove --force takes the worktree and the branch in the sibling repository; every other branch of both repositories stays" 'teamctl remove srv --team cross --force --yes && [ ! -e "$SRV_TREE" ] && ! git -C "$SIBLING_REAL" rev-parse -q --verify "refs/heads/$SRV_BRANCH" >/dev/null && git -C "$SIBLING_REAL" rev-parse -q --verify refs/heads/keep-me >/dev/null && git -C "$SIBLING_REAL" rev-parse -q --verify refs/heads/release-b >/dev/null && [ -z "$(git -C "$PROJECT" status --porcelain)" ] && ! git -C "$SIBLING_REAL" worktree list | grep -q "/teams/cross/"'
# The two features together (integration of issues #4 and #5): a worktree handed over stays in its own repository.
teamctl spawn srv3 flash --team cross --repo "$SIBLING" --no-kickoff >/dev/null 2>&1
sleep 2
SRV3_TREE="$(cross_field srv3 workdir)"
SRV3_BRANCH="$(cross_field srv3 branch)"
teamctl stop srv3 --team cross >/dev/null 2>&1
check "cross-repo and --from-worktree: --repo does not combine with --from-worktree (exit 64), and nothing changes" 'teamctl spawn srv4 flash --team cross --from-worktree srv3 --repo "$SIBLING" --no-kickoff; [ $? -eq 64 ] && [ "$(cross_field srv3 workdir)" = "$SRV3_TREE" ] && [ "$(git -C "$SRV3_TREE" branch --show-current)" = "$SRV3_BRANCH" ]'
check "cross-repo and --from-worktree: the worktree of a teammate in another repository is handed over there: repo kept, new branch in that repository and not in the project, named by the team template" 'teamctl spawn srv4 flash --team cross --from-worktree srv3 --no-kickoff && sleep 1 && [ "$(cross_field srv4 repo)" = "$SIBLING_REAL" ] && [ "$(cross_field srv4 workdir)" = "$SRV3_TREE" ] && b="$(cross_field srv4 branch)" && case "$b" in ai/cross/srv4-*) true ;; *) false ;; esac && git -C "$SIBLING_REAL" rev-parse -q --verify "refs/heads/$b" >/dev/null && ! git rev-parse -q --verify "refs/heads/$b" >/dev/null'
check "cross-repo and --from-worktree: remove --force takes the new branch in that repository; the old branch of the handed-over worktree stays" 'b="$(cross_field srv4 branch)" && teamctl stop srv4 --team cross && teamctl remove srv4 --team cross --force --yes && [ ! -e "$SRV3_TREE" ] && ! git -C "$SIBLING_REAL" rev-parse -q --verify "refs/heads/$b" >/dev/null && git -C "$SIBLING_REAL" rev-parse -q --verify "refs/heads/$SRV3_BRANCH" >/dev/null'
git -C "$SIBLING_REAL" branch -D "$SRV3_BRANCH" >/dev/null 2>&1
teamctl spawn srv2 flash --team cross --repo "$SIBLING" --no-kickoff >/dev/null 2>&1
sleep 2
SRV2_TREE="$(cross_field srv2 workdir)"
SRV2_BRANCH="$(cross_field srv2 branch)"
check "cross-repo: destroy --purge deletes that worktree and branch in the sibling repository and leaves the rest of it alone" '[ -n "$SRV2_BRANCH" ] && [ -d "$SRV2_TREE" ] && teamctl destroy --team cross --purge --force && [ ! -e "$SRV2_TREE" ] && ! git -C "$SIBLING_REAL" rev-parse -q --verify "refs/heads/$SRV2_BRANCH" >/dev/null && git -C "$SIBLING_REAL" rev-parse -q --verify refs/heads/keep-me >/dev/null && git -C "$SIBLING_REAL" rev-parse -q --verify refs/heads/main >/dev/null && ! git -C "$SIBLING_REAL" worktree list | grep -q "/teams/cross/"'


echo "== several leads in one folder come back in their own conversations (issue #7)"
# Every lead works in the project folder, so the newest transcript there belongs to one of them at most.
teamctl start fable --team twin-a --no-attach --skip-beads >/dev/null 2>&1
teamctl start opus --team twin-b --no-attach --skip-beads >/dev/null 2>&1
sleep 2
spoke lead twin-a
spoke lead twin-b
TWIN_A="$(teamctl status --json --team twin-a | jq -r '.agents[0].session_id')"
TWIN_B="$(teamctl status --json --team twin-b | jq -r '.agents[0].session_id')"
touch "$(transcripts_of "$PROJECT")/$TWIN_B.jsonl" # twin-b's is the newest transcript in the folder: what claude --continue would open for both
check "leads in one folder: two leads of one project have two conversation ids, both kept in the same folder" '[ -n "$TWIN_A" ] && [ "$TWIN_A" != "null" ] && [ "$TWIN_A" != "$TWIN_B" ] && [ -f "$(transcripts_of "$PROJECT")/$TWIN_A.jsonl" ] && [ -f "$(transcripts_of "$PROJECT")/$TWIN_B.jsonl" ]'
check "leads in one folder: restarted with --continue, each lead reopens its own conversation, not the newest one in the folder" 'teamctl restart lead --team twin-a --continue && teamctl restart lead --team twin-b --continue && sleep 2 && teamctl capture lead --team twin-a --all | grep "STUB resumed=" | tail -1 | grep -q "resumed=$TWIN_A" && teamctl capture lead --team twin-b --all | grep "STUB resumed=" | tail -1 | grep -q "resumed=$TWIN_B" && ! teamctl capture lead --team twin-a --all | grep "STUB flags=" | tail -1 | grep -q -- "--continue"'
check "leads in one folder: one lead cannot be pinned to the conversation of another team's lead (exit 1, names it)" 'out="$(teamctl restart lead --team twin-a --resume "$TWIN_B" 2>&1)"; [ $? -eq 1 ] && printf "%s" "$out" | grep -q "is the one .twin-b.lead. has on record" && [ "$(teamctl status --json --team twin-a | jq -r ".agents[0].session_id")" = "$TWIN_A" ]'
twin_kept() { jq -r '.lead_session // empty' "$(ls -d "$WOLFMUX_DATA"/state/*/teams/"$1")/meta.json"; }
check "leads in one folder: a lead restart that produces no pane leaves its id on record and with the team, so destroy and start --continue still find its conversation" '{ PATH="$WORK/no-respawn:$PATH" teamctl restart lead --team twin-a; [ $? -eq 1 ]; } && [ "$(teamctl status --json --team twin-a | jq -r ".agents[0].session_id")" = "$TWIN_A" ] && [ "$(twin_kept twin-a)" = "$TWIN_A" ]'
check "leads in one folder: the same after a reboot (no tmux session left): start --continue brings each lead back in its own" 'teamctl destroy --team twin-a --yes && teamctl destroy --team twin-b --yes; teamctl start fable --team twin-a --no-attach --skip-beads --continue && teamctl start opus --team twin-b --no-attach --skip-beads --continue && sleep 2 && teamctl capture lead --team twin-a --all | grep -q "STUB resumed=$TWIN_A" && teamctl capture lead --team twin-b --all | grep -q "STUB resumed=$TWIN_B"'
check "leads in one folder: status shows each lead the context of its own conversation" 'echo "{\"type\":\"assistant\",\"message\":{\"usage\":{\"input_tokens\":11000}}}" >>"$(transcripts_of "$PROJECT")/$TWIN_A.jsonl" && echo "{\"type\":\"assistant\",\"message\":{\"usage\":{\"input_tokens\":22000}}}" >>"$(transcripts_of "$PROJECT")/$TWIN_B.jsonl" && [ "$(teamctl status --json --team twin-a | jq -r ".agents[0].context_tokens")" = 11000 ] && [ "$(teamctl status --json --team twin-b | jq -r ".agents[0].context_tokens")" = 22000 ]'
teamctl start fable --team firstday --no-attach --skip-beads --continue >/dev/null 2>&1
sleep 2
check "leads in one folder: a first start with --continue has no conversation on record: it is what it always was, the newest one in the folder, the pane says so, and no id is invented for the CLI to refuse" '[ -z "$(teamctl status --json --team firstday | jq -r ".agents[0].session_id")" ] && teamctl status --json --team firstday | jq -e ".agents[0].state == \"running\"" && teamctl capture lead --team firstday --all | grep -q "STUB flags=.*--continue" && teamctl capture lead --team firstday --all | grep -q "STUB resumed=none" && teamctl capture lead --team firstday --all | grep -q "no stored conversation id for .lead."'
teamctl destroy --team firstday --purge --yes >/dev/null 2>&1
teamctl destroy --team twin-a --purge --yes >/dev/null 2>&1
teamctl destroy --team twin-b --purge --yes >/dev/null 2>&1

echo "== deleting a whole team (destroy --purge)"
teamctl start fable --team scrap --no-attach --skip-beads >/dev/null 2>&1
teamctl spawn tidy flash --team scrap --no-kickoff >/dev/null 2>&1
teamctl spawn busy glm53 --team scrap --no-kickoff >/dev/null 2>&1
sleep 2
BUSY_TREE="$(teamctl status --json --team scrap | jq -r '.agents[] | select(.role == "busy") | .workdir')"
TIDY_TREE="$(teamctl status --json --team scrap | jq -r '.agents[] | select(.role == "tidy") | .workdir')"
echo "half done" >"$BUSY_TREE/draft.txt"
echo "committed" >"$BUSY_TREE/kept.txt"
# More than a report shows (10 commits, 15 files): the report is cut, the command must not be
# (issue #6). git flushes each commit into the pipe, so with enough commits `| head` closed it
# under git every time: SIGPIPE, exit 141, and nothing deleted. fast-import makes 3000 in a blink.
many_commits() { # <worktree> <count>: that many empty commits on the branch it has checked out
  local ref i
  ref="$(git -C "$1" symbolic-ref HEAD)"
  { printf 'commit %s\ncommitter smoke <s@example.invalid> 1 +0000\ndata 4\nstep\nfrom %s^0\n\n' "$ref" "$ref"
    for i in $(seq 2 "$2"); do printf 'commit %s\ncommitter smoke <s@example.invalid> 1 +0000\ndata 4\nstep\n\n' "$ref"; done; } | git -C "$1" fast-import --quiet
}
many_commits "$BUSY_TREE" 3000
(cd "$BUSY_TREE" && git add kept.txt && git -c user.name=busy -c user.email=b@example.invalid commit -qm "feat: only on this branch")
for i in $(seq 1 20); do echo "$i" >"$BUSY_TREE/loose-$i.txt"; done
/bin/mkdir -p "$(transcripts_of "$BUSY_TREE")" "$(transcripts_of "$TIDY_TREE")" "$WOLFMUX_CLAUDE_PROJECTS/-somebody-elses-project"
echo '{"turn":1}' >"$(transcripts_of "$BUSY_TREE")/session.jsonl"
SCRAP_STATE="$(ls -d "$WOLFMUX_DATA"/state/*/teams/scrap)"
BUSY_TRANSCRIPTS="$(transcripts_of "$BUSY_TREE")"
check "purge: a worker may not delete a team (exit 77)" 'TEAM_ROLE=busy WOLFMUX_TEAM=scrap teamctl destroy --purge --force; [ $? -eq 77 ] && [ -d "$BUSY_TREE" ]'
check "purge: work that exists nowhere else is listed, and without an answer nothing at all is touched" 'out="$(teamctl destroy --team scrap --purge 2>&1 </dev/null)"; [ $? -eq 1 ] && printf "%s" "$out" | grep -q "draft.txt" && printf "%s" "$out" | grep -q "feat: only on this branch" && printf "%s" "$out" | grep -q -- "--force" && [ -d "$BUSY_TREE" ] && tmux -L "$WOLFMUX_TMUX_SOCKET" has-session -t "=$FIRST_SESSION-scrap" && teamctl status --json --team scrap | jq -e "[.agents[] | select(.state == \"running\")] | length == 3"'
check "purge: it says how much space the team takes" 'teamctl destroy --team scrap --purge 2>&1 </dev/null | grep -Eq "total +[0-9.]+ ?(KB|MB|GB)"'
check "purge: a worker with more commits and files than the report shows is still reported in full: the list is cut, the command is not (exit 1 waiting for an answer, never 141)" 'out="$(teamctl destroy --team scrap --purge 2>&1 </dev/null)"; [ $? -eq 1 ] && printf "%s" "$out" | grep -q "3001 commits" && printf "%s" "$out" | grep -q "and 2991 more commits" && printf "%s" "$out" | grep -q "and 6 more files"'
teamctl stop tidy --team scrap >/dev/null 2>&1
many_commits "$TIDY_TREE" 3000
# teamctl guards its own tool calls, so no command crashes on demand: the handler that bin/teamctl
# installs is run with the libraries, over a child killed by SIGPIPE (what `| head` did, issue #6).
crash_with() { bash -c 'set -euo pipefail; for m in provider-env common registry; do . "$1/config/wolfmux/lib/$m.sh"; done; TEAMCTL_ARGS="destroy --team x --purge"; trap teamctl_on_exit EXIT; bash -c "$2"; echo finished' _ "$REPO" "$1" 2>&1; }
check "a crash is never silent: bin/teamctl installs the exit handler, and it names the signal and the command; a plain failure, Ctrl-C or a closed terminal adds nothing (issue #6)" 'grep -q "^trap .teamctl_on_exit. EXIT" "$REPO/bin/teamctl" && crash_out="$(crash_with "kill -PIPE \$\$")"; [ $? -eq 141 ] && printf "%s" "$crash_out" | grep -q "stopped unexpectedly (exit 141: signal 13) in: teamctl destroy --team x --purge" && plain_out="$(crash_with "exit 3")"; [ $? -eq 3 ] && [ -z "$plain_out" ] && int_out="$(crash_with "kill -INT \$\$")"; [ $? -eq 130 ] && [ -z "$int_out" ] && hup_out="$(crash_with "kill -HUP \$\$")"; [ $? -eq 129 ] && ! printf "%s" "$hup_out" | grep -q "stopped unexpectedly"'
check "remove --force: a worker with thousands of unmerged commits is removed, not left behind by a silent exit 141" 'teamctl remove tidy --team scrap --force --yes && [ ! -e "$TIDY_TREE" ] && [ -z "$(git branch --list "ai/scrap/tidy-*")" ]'
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
