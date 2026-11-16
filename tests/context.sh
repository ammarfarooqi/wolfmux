#!/bin/bash
# context.sh: tests for what an agent's conversation starts with (v1.25.0, ADR-0037):
# the reductions of worker-context trim and lean, the lead-context and context-exclude policies
# (lib/policy.sh), and the rules-folder hint of teamctl doctor (lib/doctor.sh).
#
# Fully isolated from any team you have running: its own tmux server, its own state directory,
# a throwaway git repository, a throwaway ~/.claude, a stub agent instead of a real CLI, the
# native store. What the real CLI does with these settings is measured, not stubbed:
# tests/research/results/part-a-probes.jsonl.
#
#   tests/context.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-context-test.XXXXXX")"
export WOLFMUX_HOME="$REPO/config/wolfmux"
export WOLFMUX_BIN_DIR="$REPO/bin"
export WOLFMUX_DATA="$WORK/data"
export WOLFMUX_TMUX_SOCKET="wolfmux-ctxtest-$$"
export WOLFMUX_LAUNCHER_FABLE="$REPO/tests/stub-agent"
export WOLFMUX_CLAUDE_PROJECTS="$WORK/claude-projects"
export WOLFMUX_CODEX_SESSIONS="$WORK/codex-sessions"
export WOLFMUX_NOTIFY=off WOLFMUX_SPLASH=off
# Run from an agent's pane, the environment carries that agent's team, worktree and policy
# defaults: all of it is dropped, or the commands below would act as that agent.
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR WOLFMUX_IDENTITY WOLFMUX_METERED TMUX TMUX_PANE WOLFMUX_STORE
unset WOLFMUX_TEAM WOLFMUX_TEAM_ARG WOLFMUX_SESSION WOLFMUX_WORKTREE WOLFMUX_BRANCH WOLFMUX_MODEL WOLFMUX_EXTRA_SETTINGS WOLFMUX_RUN_DIR
unset WOLFMUX_WORKER_CONTEXT WOLFMUX_LEAD_CONTEXT WOLFMUX_CONTEXT_EXCLUDE WOLFMUX_WORKER_COMPACT_WINDOW WOLFMUX_BROWSER_WRITES
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
  tmux -L "$WOLFMUX_TMUX_SOCKET" kill-server >/dev/null 2>&1
  /bin/rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$WOLFMUX_TMUX_SOCKET"
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT

# A throwaway ~/.claude stands in for yours: two plugins, your recorded acceptance of bypass
# mode, and a rules pack with an English folder, a Chinese copy of it and an unrelated folder.
FAKE_CLAUDE="$WORK/claude-home"
/bin/mkdir -p "$FAKE_CLAUDE/plugins" "$FAKE_CLAUDE/rules/pack/common" "$FAKE_CLAUDE/rules/pack/zh" "$FAKE_CLAUDE/rules/pack/web"
printf '%s\n' '{"enabledPlugins":{"alpha@market":true},"skipDangerousModePermissionPrompt":true}' >"$FAKE_CLAUDE/settings.json"
printf '%s\n' '{"version":2,"plugins":{"gamma@other":[{"scope":"user"}]}}' >"$FAKE_CLAUDE/plugins/installed_plugins.json"
for name in style testing security; do
  printf '# %s\n\nWrite small functions. Test first. Never hardcode a secret.\n' "$name" >"$FAKE_CLAUDE/rules/pack/common/$name.md"
  printf '# %s\n\n始终创建新对象，永远不要修改现有对象。先写测试。永远不要硬编码密钥。\n' "$name" >"$FAKE_CLAUDE/rules/pack/zh/$name.md"
done
for name in layout motion fonts; do printf '# %s\n\nUse semantic HTML.\n' "$name" >"$FAKE_CLAUDE/rules/pack/web/$name.md"; done
export CLAUDE_CONFIG_DIR="$FAKE_CLAUDE"

PROJECT="$WORK/project"
/bin/mkdir -p "$PROJECT"
cd "$PROJECT" || exit 1
git init -q -b main
echo "hello" >README.md
git add -A
git -c user.name=test -c user.email=test@example.invalid commit -qm "initial commit"

SEVEN='["Artifact","AskUserQuestion","SendFeedback","ScheduleWakeup","Workflow","ReportFindings","ListAgents"]'
SIX='["Artifact","SendFeedback","ScheduleWakeup","Workflow","ReportFindings","ListAgents"]'
settings_of() { find "$WOLFMUX_DATA/state" -path "*settings/$1.json" -not -path "*/teams/*" | head -1; }
# restarted <role>: restart it and wait until its pane has written a new settings file
restarted() {
  local file marker="$WORK/marker" tries=0
  : >"$marker"
  sleep 1
  teamctl restart "$1" >/dev/null 2>&1
  while [ "$tries" -lt 40 ]; do
    file="$(settings_of "$1")"
    if [ -n "$file" ] && [ "$file" -nt "$marker" ]; then return 0; fi
    sleep 0.25
    tries=$((tries + 1))
  done
  return 1
}

echo "== setup: a lead and a worker (stub agents), native store =="
teamctl start fable --no-attach >/dev/null 2>&1
sleep 1
teamctl spawn qa fable --no-kickoff >/dev/null 2>&1
sleep 2
QA="$(settings_of qa)"
LEAD="$(settings_of lead)"
check "setup: both agents have a settings file" '[ -r "$QA" ] && [ -r "$LEAD" ]'

echo "== worker-context: the reductions of trim and lean =="
check "trim (the default): the seven tools a pane agent cannot use are denied by bare name" 'jq -e --argjson want "$SEVEN" ".permissions.deny == \$want" "$QA"'
check "trim: the claude.ai connectors are off for the worker" 'jq -e ".env.ENABLE_CLAUDEAI_MCP_SERVERS == \"false\"" "$QA"'
check "trim: your plugins are still switched off, and nothing of yours is excluded by default" 'jq -e ".enabledPlugins == {\"alpha@market\": false, \"gamma@other\": false} and (has(\"claudeMdExcludes\") | not)" "$QA"'
check "trim: the reductions sit next to what a worker had before (agent teams off, the turn hooks, the guard)" 'jq -e ".env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS == \"0\" and .hooks.PostToolUse != null and .hooks.PreToolUse != null" "$QA"'
teamctl policy worker-context lean >/dev/null 2>&1
restarted qa
check "lean: the same seven tools and the connectors are off, and your acceptance of bypass mode is still carried" 'jq -e --argjson want "$SEVEN" ".permissions.deny == \$want and .env.ENABLE_CLAUDEAI_MCP_SERVERS == \"false\" and .skipDangerousModePermissionPrompt == true" "$QA"'
teamctl policy worker-context full >/dev/null 2>&1
restarted qa
check "full: unchanged, no tool is denied, the connectors stay, no plugin is switched off" 'jq -e "(has(\"permissions\") | not) and (.env | has(\"ENABLE_CLAUDEAI_MCP_SERVERS\") | not) and (has(\"enabledPlugins\") | not)" "$QA"'
teamctl policy worker-context trim >/dev/null 2>&1
teamctl policy browser-writes allow >/dev/null 2>&1
restarted qa
check "trim next to browser-writes allow: the allow rule and the deny list are both there" 'jq -e --argjson want "$SEVEN" ".permissions.deny == \$want and .permissions.allow == [\"mcp__claude-in-chrome__*\"]" "$QA"'
teamctl policy browser-writes ask >/dev/null 2>&1

echo "== context-exclude =="
check "context-exclude: empty by default, in the policy listing and in status --json" 'teamctl policy | grep -q "context-exclude  *none" && teamctl status --json | jq -e ".policy.context_exclude == []"'
teamctl policy context-exclude '**/rules/pack/zh/**' '**/drafts/*.md' >/dev/null 2>&1
restarted qa
check "context-exclude: two globs become claudeMdExcludes for a trimmed worker, in the order given" 'jq -e ".claudeMdExcludes == [\"**/rules/pack/zh/**\", \"**/drafts/*.md\"]" "$QA"'
check "context-exclude: the listing and status --json show the list" 'teamctl policy | grep -qF "**/rules/pack/zh/** **/drafts/*.md" && teamctl status --json | jq -e ".policy.context_exclude | length == 2"'
check "context-exclude: the lead is untouched while lead-context is full" 'jq -e "(has(\"claudeMdExcludes\") | not) and (has(\"permissions\") | not)" "$LEAD"'
teamctl policy worker-context lean >/dev/null 2>&1
restarted qa
check "context-exclude: a lean worker gets the list too" 'jq -e ".claudeMdExcludes | length == 2" "$QA"'
teamctl policy worker-context full >/dev/null 2>&1
restarted qa
check "context-exclude: a full worker loads everything, the list is not applied" 'jq -e "has(\"claudeMdExcludes\") | not" "$QA"'
teamctl policy worker-context trim >/dev/null 2>&1
check "context-exclude: a glob with a character a shell or JSON would read is refused (exit 64) and the list stays" 'out="$(teamctl policy context-exclude "a;rm -rf b" 2>&1)"; [ $? -eq 64 ] && printf "%s" "$out" | grep -q "glob" && teamctl status --json | jq -e ".policy.context_exclude | length == 2"'
check "context-exclude: more globs than the limit are refused" 'out="$(teamctl policy context-exclude a b c d e f g h i j k l m n o p q 2>&1)"; [ $? -eq 64 ]'
check "context-exclude: none goes back to leaving nothing out" 'teamctl policy context-exclude none | grep -q "context-exclude = none" && teamctl status --json | jq -e ".policy.context_exclude == []"'
check "context-exclude: the configured default applies, and a stored list outranks it" '[ "$(WOLFMUX_CONTEXT_EXCLUDE="**/x/**" teamctl status --json | jq -r ".policy.context_exclude[0]")" = "**/x/**" ] && teamctl policy context-exclude "**/y/**" >/dev/null && [ "$(WOLFMUX_CONTEXT_EXCLUDE="**/x/**" teamctl status --json | jq -r ".policy.context_exclude[0]")" = "**/y/**" ]'
teamctl policy context-exclude none >/dev/null 2>&1
check "context-exclude: a configured value that is no list of globs leaves nothing out" '[ "$(WOLFMUX_CONTEXT_EXCLUDE="\$(id)" teamctl status --json | jq -c ".policy.context_exclude")" = "[]" ]'

echo "== lead-context =="
check "lead-context: full by default, and the lead's settings carry no reduction" 'teamctl policy | grep -q "lead-context  *full" && teamctl status --json | jq -e ".policy.lead_context == \"full\"" && jq -e "(has(\"permissions\") | not) and (.env | has(\"ENABLE_CLAUDEAI_MCP_SERVERS\") | not) and (has(\"enabledPlugins\") | not)" "$LEAD"'
teamctl policy context-exclude '**/rules/pack/zh/**' >/dev/null 2>&1
teamctl policy lead-context trim >/dev/null 2>&1
restarted lead
check "lead-context trim: six tools are denied and AskUserQuestion stays" 'jq -e --argjson want "$SIX" ".permissions.deny == \$want" "$LEAD"'
check "lead-context trim: the connectors are off and the context-exclude list applies to the lead" 'jq -e ".env.ENABLE_CLAUDEAI_MCP_SERVERS == \"false\" and .claudeMdExcludes == [\"**/rules/pack/zh/**\"]" "$LEAD"'
check "lead-context trim: your plugins stay on for the lead, and its hooks are as before" 'jq -e "(has(\"enabledPlugins\") | not) and .hooks.Stop != null and .hooks.SessionStart != null" "$LEAD"'
check "lead-context: nonsense is refused (exit 64) with the choices named" 'out="$(teamctl policy lead-context lean 2>&1)"; [ $? -eq 64 ] && printf "%s" "$out" | grep -q "full|trim"'
check "lead-context: a configured value nobody can read means full, and a stored choice outranks the environment" '[ "$(WOLFMUX_LEAD_CONTEXT=full teamctl status --json | jq -r .policy.lead_context)" = trim ] && teamctl policy lead-context full >/dev/null && [ "$(WOLFMUX_LEAD_CONTEXT=bogus teamctl status --json | jq -r .policy.lead_context)" = full ]'
restarted lead
check "lead-context full again: the reductions are gone from the lead's settings" 'jq -e "(has(\"permissions\") | not) and (has(\"claudeMdExcludes\") | not)" "$LEAD"'
teamctl policy context-exclude none >/dev/null 2>&1

echo "== teamctl doctor: a rules folder that repeats another one in a second language =="
DOC="$WORK/doctor.out"
teamctl doctor >"$DOC" 2>&1
check "doctor: names the folder and the one it repeats" 'grep -q "rules: .*rules/pack/zh repeats .*rules/pack/common in a second language" "$DOC"'
check "doctor: prints the exact policy line that leaves it out" 'grep -qF "teamctl policy context-exclude '"'"'**/rules/pack/zh/**'"'"'" "$DOC"'
check "doctor: says what it saves, from the size of the folder" 'grep -Eq "saves about [1-9][0-9]* tokens per request \([1-9][0-9]* characters" "$DOC"'
check "doctor: a folder with other files (web) and the English folder itself are not reported" '! grep -q "rules/pack/web repeats" "$DOC" && ! grep -q "rules/pack/common repeats" "$DOC"'
check "doctor: the hint is a note, it adds no warning and no failure of its own" '! grep -E "warn|FAIL" "$DOC" | grep -q "rules:"'
WOLFMUX_CONTEXT_EXCLUDE='**/rules/pack/zh/**' teamctl doctor >"$DOC" 2>&1
check "doctor: once the configured context-exclude names it, the folder is reported as left out" 'grep -q "rules/pack/zh repeats .* and is left out by context-exclude" "$DOC" && ! grep -q "saves about" "$DOC"'
/bin/rm -rf "$FAKE_CLAUDE/rules/pack/zh"
teamctl doctor >"$DOC" 2>&1
check "doctor: with no such folder it says so" 'grep -q "rules: no folder under .* repeats another one in a second language" "$DOC"'

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
