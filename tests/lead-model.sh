#!/bin/bash
# lead-model.sh — leads run Opus, Fable on demand (v1.21.0): policy lead-model (what a NEW lead starts on),
# teamctl model <role> <model> [--now] (what an agent starts on next, and a safe switch now), the record
# following a /model typed into a pane (agent_adopt_live), and teamctl restart --model.
#
# No model is called. Claude Code is a stand-in that answers the probe from a file per alias and is
# otherwise tests/stub-agent, which prints how it was started (--model, --resume). Everything runs in a
# throwaway HOME, data directory, git repository and tmux server (socket wolfmux-test-leadmodel-<pid>),
# set up and removed by this one script. Never a real team. Needs tmux, git and jq.
#
#   tests/lead-model.sh
# No pipefail: checks end in `grep -q`, which closes the pipe early by design.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-leadmodel.XXXXXX")"
export HOME="$WORK/home"
/bin/mkdir -p "$HOME"
export WOLFMUX_HOME="$REPO/config/wolfmux"
export WOLFMUX_BIN_DIR="$REPO/bin"
export WOLFMUX_DATA="$WORK/data"
export WOLFMUX_TMUX_SOCKET="wolfmux-test-leadmodel-$$" WOLFMUX_LEGACY_SOCKET="wolfmux-test-leadmodel-old-$$"
export WOLFMUX_CLAUDE_PROJECTS="$WORK/claude-projects" WOLFMUX_CODEX_SESSIONS="$WORK/codex-sessions"
FAKE="$WORK/fake"
export FAKE
/bin/mkdir -p "$FAKE/answers" "$WOLFMUX_CLAUDE_PROJECTS"
# The stand-in for Claude Code behind every subscription key: `-p` is the probe, answered from answers/<alias>.
/bin/cat >"$FAKE/claude" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-p" ]; then
  model="" prev=""
  for arg in "$@"; do
    if [ "$prev" = "--model" ]; then model="$arg"; fi
    prev="$arg"
  done
  [ -f "$FAKE/answers/$model" ] || exit 1
  printf '{"type":"result","subtype":"success","is_error":false,"result":"ok","modelUsage":{"%s":{"inputTokens":2,"contextWindow":1000000}}}\n' "$(cat "$FAKE/answers/$model")"
  exit 0
fi
exec "$STUB_AGENT" "$@"
EOF
/bin/chmod 755 "$FAKE/claude"
echo "claude-fable-5-1" >"$FAKE/answers/fable"
echo "claude-opus-5-5" >"$FAKE/answers/opus"
echo "claude-sonnet-5-5" >"$FAKE/answers/sonnet"
echo "claude-haiku-5-5" >"$FAKE/answers/haiku"
export STUB_AGENT="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_FABLE="$FAKE/claude" WOLFMUX_LAUNCHER_OPUS="$FAKE/claude"
export WOLFMUX_LAUNCHER_SONNET="$FAKE/claude" WOLFMUX_LAUNCHER_HAIKU="$FAKE/claude"
export WOLFMUX_LAUNCHER_ASTRA="$REPO/tests/stub-agent" WOLFMUX_LAUNCHER_CLAUDE="$REPO/tests/stub-agent"
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR WOLFMUX_NOTIFY WOLFMUX_SPLASH WOLFMUX_METERED TMUX TMUX_PANE
unset WOLFMUX_TEAM WOLFMUX_TEAM_ARG WOLFMUX_SESSION WOLFMUX_WORKTREE WOLFMUX_BRANCH WOLFMUX_MODEL WOLFMUX_EXTRA_SETTINGS
unset WOLFMUX_FABLE_MODEL WOLFMUX_OPUS_MODEL WOLFMUX_SONNET_MODEL WOLFMUX_HAIKU_MODEL WOLFMUX_MODEL_POLICY CLAUDE_CONFIG_DIR
unset WOLFMUX_LEAD_MODEL WOLFMUX_ORPHAN_STEWARD WOLFMUX_HUMAN_PANE_TYPING WOLFMUX_INBOX_WATCHED
export WOLFMUX_NOTIFY=off WOLFMUX_SPLASH=off
# Nobody is at any pane unless a check says so (the seam inbox_human_pane reads), and a transcript written a
# moment ago counts as quiet: the checks below write it themselves.
export WOLFMUX_INBOX_WATCHED="" WOLFMUX_MODEL_NOW_QUIET=0
# The project has several teams below, so every command names one: the default team, unless the command names
# another (the last --team wins).
teamctl() { "$REPO/bin/teamctl" --team default "$@"; }
as_agent() { # <team> <role> <teamctl args…>: what that agent's own pane runs, on the default team
  local team="$1" role="$2"
  shift 2
  TEAM_ROLE="$role" WOLFMUX_TEAM="$team" "$REPO/bin/teamctl" --team default "$@"
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

field() { teamctl status --json --team "${3:-default}" | jq -r --arg r "$1" --arg f "$2" '.agents[] | select(.role == $r) | .[$f] // ""'; } # <role> <field> [<team>]
record() { # <role> [<team>]
  if [ -n "${2:-}" ]; then cat "$WOLFMUX_DATA"/state/*/teams/"$2"/agents/"$1".json; else cat "$(ls -d "$WOLFMUX_DATA"/state/*/agents/"$1".json)"; fi
}
events() { cat "$(ls -d "$WOLFMUX_DATA"/state/*/events.jsonl)"; }
transcript_of() { # <role>: the file of that agent's own conversation (its folder is made)
  local dir
  dir="$WOLFMUX_CLAUDE_PROJECTS/$(cd "$(field "$1" workdir)" && pwd -P | sed 's|[^A-Za-z0-9]|-|g')"
  /bin/mkdir -p "$dir"
  printf '%s/%s.jsonl\n' "$dir" "$(field "$1" session_id)"
}
answer() { # <model id> <timestamp> [<stop reason>]: one answer, as Claude Code writes it into a transcript
  printf '{"type":"assistant","timestamp":"%s","message":{"model":"%s","stop_reason":"%s","usage":{"input_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[]}}\n' "$2" "$1" "${3:-end_turn}"
}
turn_end() { printf '{"type":"system","subtype":"turn_duration","timestamp":"%s"}\n' "$1"; }
later() { date -u -v+1M +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%S.000Z; }
# The process in its pane: a restart (respawn-pane) starts another one, and tmux clears the pane's scrollback.
pane_pid() { tmux -L "$WOLFMUX_TMUX_SOCKET" display-message -p -t "$(field "$1" pane)" '#{pane_pid}' 2>/dev/null; }
last_says() { # <role> <text>: the LAST start of that agent's pane printed that line
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    teamctl capture "$1" --all 2>/dev/null | grep "^STUB ${2%%=*}=" | tail -1 | grep -qxF -- "STUB $2" && return 0
    sleep 0.3
  done
  return 1
}
restarted() { # <role> <pid before>: its pane runs another process now
  local i now
  for i in 1 2 3 4 5 6 7 8 9 10; do
    now="$(pane_pid "$1")"
    [ -n "$now" ] && [ "$now" != "$2" ] && return 0
    sleep 0.3
  done
  return 1
}

PROJECT="$WORK/demo project" # the space is deliberate
/bin/mkdir -p "$PROJECT"
cd "$PROJECT" || exit 1
git init -q -b main
echo "hello" >README.md
git add -A
git -c user.name=leadmodel -c user.email=leadmodel@example.invalid commit -qm "initial commit"

echo "== policy lead-model: a new lead runs Opus unless Fable is asked for"
check "teamctl policy lists lead-model, default opus, for the whole project" \
  'teamctl policy 2>/dev/null | grep -Eq "^  lead-model +opus "'
teamctl start --no-attach --skip-beads >/dev/null 2>&1
check "teamctl start with no model: the new lead runs Opus (policy lead-model, default opus)" \
  '[ "$(record lead | jq -r .model)" = opus ] && [ "$(record lead | jq -r .model_id)" = claude-opus-5-5 ] && last_says lead "modelarg=claude-opus-5-5"'
teamctl start fable --team fab --no-attach --skip-beads >/dev/null 2>&1
check "teamctl start fable still gives a Fable lead" \
  '[ "$(record lead fab | jq -r .model)" = fable ] && [ "$(record lead fab | jq -r .model_id)" = claude-fable-5-1 ]'
check "an agent may not set lead-model (77): it is the human's, for every team of the project" \
  'as_agent default lead policy lead-model fable; [ $? -eq 77 ]'
check "lead-model refuses a model teamctl does not know (64)" \
  'teamctl policy lead-model gpt-9; [ $? -eq 64 ]'
teamctl policy lead-model sonnet >/dev/null 2>&1
teamctl start --team son --no-attach --skip-beads >/dev/null 2>&1
check "lead-model sonnet, set by you: the next new team's lead runs Sonnet; the running leads keep theirs" \
  '[ "$(record lead son | jq -r .model)" = sonnet ] && [ "$(record lead | jq -r .model)" = opus ] && [ "$(record lead fab | jq -r .model)" = fable ]'
teamctl policy lead-model default >/dev/null 2>&1
check "lead-model default goes back to the config value, else opus" \
  'teamctl policy | grep -Eq "^  lead-model +opus " && [ "$(WOLFMUX_LEAD_MODEL=haiku teamctl policy | grep -E "^  lead-model" | awk "{print \$2}")" = haiku ]'
teamctl stop lead --team son >/dev/null 2>&1
teamctl destroy --team son --yes >/dev/null 2>&1
teamctl start --team son --no-attach --skip-beads >/dev/null 2>&1
check "a team that had a lead comes back on THAT lead's model with no model named (sonnet, not the policy's opus)" \
  '[ "$(record lead son | jq -r .model)" = sonnet ]'

echo "== teamctl model: the recorded model, what the next start uses"
teamctl spawn w1 fable --no-kickoff >/dev/null 2>&1
BEFORE="$(pane_pid w1)"
OUT="$(teamctl model w1 opus 2>&1)"
check "teamctl model w1 opus (running, no --now): recorded only; it says it switches at the next restart" \
  '[ "$(record w1 | jq -r .model)" = opus ] && [ "$(record w1 | jq -r .model_id)" = claude-fable-5-1 ] &&
   printf "%s" "$OUT" | grep -q "until its next restart" && [ "$(pane_pid w1)" = "$BEFORE" ]'
check "status still names the model the pane runs (Fable 5.1) until it runs another" \
  '[ "$(field w1 label)" = "Fable 5.1" ] && [ "$(field w1 model)" = opus ]'
teamctl restart w1 --continue >/dev/null 2>&1
check "restart honours the record: w1 comes back on Opus, in its own conversation" \
  'restarted w1 "$BEFORE" && last_says w1 "modelarg=claude-opus-5-5" && last_says w1 "session_id=$(record w1 | jq -r .session_id)" &&
   [ "$(record w1 | jq -r .model_id)" = claude-opus-5-5 ] && [ "$(field w1 label)" = "Opus 5.5" ]'
teamctl spawn w2 fable --no-kickoff >/dev/null 2>&1
teamctl stop w2 >/dev/null 2>&1
OUT="$(teamctl model w2 sonnet 2>&1)"
check "a stopped agent: the whole record moves (Sonnet 5.5 in status), and the next restart starts it on Sonnet" \
  '[ "$(record w2 | jq -r .model)" = sonnet ] && [ "$(field w2 label)" = "Sonnet 5.5" ] && printf "%s" "$OUT" | grep -q "from its next start"'
teamctl restart w2 >/dev/null 2>&1
check "  ... and it does" 'last_says w2 "modelarg=claude-sonnet-5-5"'
check "teamctl model --type is not offered (64): /model writes ~/.claude/settings.json for every session" \
  'teamctl model w1 fable --type; [ $? -eq 64 ]'
check "teamctl model refuses a model it does not know (64), and the record is untouched" \
  'teamctl model w1 gpt-9; [ $? -eq 64 ] && [ "$(record w1 | jq -r .model)" = opus ]'
check "a worker may not run teamctl model (77); nor the lead of another team" \
  'as_agent default w1 model w1 fable; [ $? -eq 77 ] && as_agent fab lead model w1 fable; [ $? -eq 77 ] && [ "$(record w1 | jq -r .model)" = opus ]'
check "the team's own lead may (as for restart)" \
  'as_agent default lead model w2 haiku && [ "$(record w2 | jq -r .model)" = haiku ]'

echo "== teamctl model --now: switched only when it is safe"
T="$(transcript_of w1)"
{ answer claude-opus-5-5 "$(later)" tool_use; } >>"$T"
BEFORE="$(pane_pid w1)"
OUT="$(teamctl model w1 sonnet --now 2>&1)"
check "--now while it is in a turn (last answer asked for a tool): recorded only, not restarted, and it says why" \
  '[ "$(record w1 | jq -r .model)" = sonnet ] && printf "%s" "$OUT" | grep -q "not switched now: it is not between turns" && sleep 1 && [ "$(pane_pid w1)" = "$BEFORE" ]'
{ answer claude-opus-5-5 "$(later)"; turn_end "$(later)"; } >>"$T"
OUT="$(WOLFMUX_INBOX_WATCHED="$(field w1 pane)" teamctl model w1 sonnet --now 2>&1)"
check "--now while a human is watching its pane: recorded only, not restarted (v1.20.0 rule)" \
  'printf "%s" "$OUT" | grep -q "not switched now: a human is watching this pane" && sleep 1 && [ "$(pane_pid w1)" = "$BEFORE" ]'
check "--now while it writes (transcript not quiet for WOLFMUX_MODEL_NOW_QUIET seconds): recorded only" \
  'WOLFMUX_MODEL_NOW_QUIET=600 teamctl model w1 sonnet --now 2>&1 | grep -q "not switched now: it is not between turns (written in the last 600s)" && [ "$(pane_pid w1)" = "$BEFORE" ]'
OUT="$(teamctl model w1 sonnet --now 2>&1)"
check "--now between turns, nobody at the pane: a resume-restart on Sonnet, same conversation" \
  'restarted w1 "$BEFORE" && last_says w1 "modelarg=claude-sonnet-5-5" && last_says w1 "resumed=$(record w1 | jq -r .session_id)" &&
   printf "%s" "$OUT" | grep -q "settings.json is not touched"'
# Stamped before the Haiku restart below, as a real answer is: a later one would be adopted as a /model.
{ answer claude-sonnet-5-5 "2020-01-01T00:00:00.000Z"; turn_end "2020-01-01T00:00:01.000Z"; } >>"$T"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>"}}' \
  '{"type":"user","isMeta":true,"message":{"role":"user","content":"Caveat: local command"}}' \
  '{"type":"user","message":{"role":"user","content":"<local-command-stdout>Set model to sonnet</local-command-stdout>"}}' >>"$T"
BEFORE="$(pane_pid w1)"
check "a slash command typed after the turn ended is not a turn: --now still switches (Haiku)" \
  'teamctl model w1 haiku --now >/dev/null 2>&1 && restarted w1 "$BEFORE" && last_says w1 "modelarg=claude-haiku-5-5"'
printf '%s\n' '{"type":"user","message":{"role":"user","content":"do the next thing"}}' >>"$T"
check "a prompt after the turn ended is a turn under way: --now records only" \
  'teamctl model w1 sonnet --now 2>&1 | grep -q "not switched now: it is not between turns (running)"'
teamctl spawn x1 fable --no-kickoff >/dev/null 2>&1
check "--now across CLIs (Claude to Codex): recorded only, a Claude conversation cannot go on in Codex" \
  'teamctl model x1 astra --now 2>&1 | grep -q "not switched now: a claude conversation cannot go on in a codex model" && [ "$(record x1 | jq -r .family)" = codex ]'

echo "== the record follows a /model typed into a pane"
teamctl spawn l1 fable --no-kickoff >/dev/null 2>&1
T="$(transcript_of l1)"
answer claude-opus-5-5 "$(later)" >"$T"
BEFORE="$(pane_pid l1)"
teamctl restart l1 --continue >/dev/null 2>&1
check "record Fable, its transcript says Opus (a /model after its start): restart launches Opus" \
  'restarted l1 "$BEFORE" && last_says l1 "modelarg=claude-opus-5-5" && [ "$(record l1 | jq -r .model)" = opus ]'
check "  ... adopted lazily by that read, and logged as a model event" \
  'events | jq -e "select(.type == \"model\" and .role == \"l1\" and (.detail | startswith(\"adopted opus\")))"'
teamctl spawn l2 fable --no-kickoff >/dev/null 2>&1
answer claude-sonnet-5-5 "$(later)" >"$(transcript_of l2)"
check "teamctl status adopts it too: the record says sonnet, status shows Sonnet without the * mark" \
  '[ "$(field l2 model)" = sonnet ] && [ "$(record l2 | jq -r .model)" = sonnet ] && [ "$(field l2 label_mark)" = "" ] && [ "$(field l2 known_from)" = record ]'
check "an answer from BEFORE the record's start is not adopted (a --continue still ends with the old model's answer)" \
  'teamctl spawn l3 fable --no-kickoff >/dev/null 2>&1 && answer claude-opus-5-5 "2020-01-01T00:00:00.000Z" >"$(transcript_of l3)" &&
   [ "$(field l3 model)" = fable ] && [ "$(record l3 | jq -r .model)" = fable ]'
check "another version of the same family is not adopted (Claude Code may serve an earlier one)" \
  'teamctl spawn l4 opus --no-kickoff >/dev/null 2>&1 && answer claude-opus-5 "$(later)" >"$(transcript_of l4)" &&
   [ "$(field l4 model)" = opus ] && [ "$(record l4 | jq -r .model_id)" = claude-opus-5-5 ]'
LEAD_T="$(transcript_of lead)"
answer claude-fable-5-1 "$(later)" >"$LEAD_T"
check "teamctl teams adopts it for a lead: the lead's record now says fable, and a restart of the lead keeps Fable" \
  'teamctl teams --json >/dev/null 2>&1 && [ "$(record lead | jq -r .model)" = fable ] && grep -q "\"lead_model\": *\"fable\"" "$(ls -d "$WOLFMUX_DATA"/state/*/meta.json)"'

echo "== teamctl restart --model (the restore lane's restore-on-limit)"
teamctl spawn r1 fable --no-kickoff >/dev/null 2>&1
answer claude-fable-5-1 "2020-01-01T00:00:00.000Z" >"$(transcript_of r1)"
R1_ID="$(record r1 | jq -r .session_id)"
BEFORE="$(pane_pid r1)"
OUT="$(teamctl restart r1 --model opus --resume "$R1_ID" 2>&1)"
check "restart r1 --model opus --resume <id>: Opus, that conversation, and the record says opus from now on" \
  'restarted r1 "$BEFORE" && last_says r1 "modelarg=claude-opus-5-5" && last_says r1 "resumed=$R1_ID" && [ "$(record r1 | jq -r .model)" = opus ] &&
   printf "%s" "$OUT" | grep -q "on opus"'
check "restart --model across CLIs with --continue is refused (64): a conversation cannot change CLI" \
  'teamctl restart r1 --model astra --continue; [ $? -eq 64 ] && [ "$(record r1 | jq -r .model)" = opus ]'
check "restart --model with an unknown model is refused (64)" \
  'teamctl restart r1 --model gpt-9; [ $? -eq 64 ]'
check "restart --model is reserved as restart is (77 for a worker)" \
  'as_agent default r1 restart r1 --model fable; [ $? -eq 77 ] && [ "$(record r1 | jq -r .model)" = opus ]'
tmux -L "$WOLFMUX_TMUX_SOCKET" kill-session -t "=$(tmux -L "$WOLFMUX_TMUX_SOCKET" list-sessions -F '#S' | grep -- '-fab$')" >/dev/null 2>&1
teamctl restart lead --team fab --model opus >/dev/null 2>&1
check "restart lead --model opus on a team with no session: the team comes back with an Opus lead" \
  '[ "$(record lead fab | jq -r .model)" = opus ] && [ "$(record lead fab | jq -r .model_id)" = claude-opus-5-5 ]'

echo
echo "lead-model: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
