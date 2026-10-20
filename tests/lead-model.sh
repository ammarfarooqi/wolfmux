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
export WOLFMUX_CLAUDE_SESSIONS="$WORK/claude-sessions"
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
# Restore's integration cases record the actual launch arguments and supply the
# session record and limit error that the real Claude CLI would write.
model="" resumed="" prev=""
for arg in "$@"; do
  if [ "$prev" = "--model" ]; then model="$arg"; fi
  if [ "$prev" = "--resume" ]; then resumed="$arg"; fi
  prev="$arg"
done
marker="$FAKE/restore-${WOLFMUX_TEAM:-}"
if [ -n "$resumed" ] && [ -f "$marker" ]; then
  jq -cn --args '$ARGS.positional' -- "$@" >>"$marker.argv"
  if [ "$model" = claude-fable-5-1 ]; then
    IFS= read -r transcript <"$marker"
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{timestamp:$ts,isApiErrorMessage:true,message:{content:[{type:"text",text:"You have reached your Fable limit"}]}}' >>"$transcript"
  fi
  mkdir -p "$WOLFMUX_CLAUDE_SESSIONS"
  jq -cn --arg sid "$resumed" '{sessionId:$sid}' >"$WOLFMUX_CLAUDE_SESSIONS/$$.json"
fi
exec "$STUB_AGENT" "$@"
EOF
/bin/chmod 755 "$FAKE/claude"
# Restore sends a Beads message and a real teamctl nudge. Keep the message local.
/bin/cat >"$FAKE/bd" <<'EOF'
#!/bin/bash
case "$1" in create) echo test-restore ;; *) echo '[]' ;; esac
EOF
/bin/cat >"$FAKE/memory_pressure" <<'EOF'
#!/bin/bash
echo 'System-wide memory free percentage: 80%'
EOF
/bin/chmod 755 "$FAKE/bd" "$FAKE/memory_pressure"
export PATH="$FAKE:$PATH"
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
# Showing what a transcript says is useful even when its age is unknown. Changing the
# next launch needs evidence that the answer followed the recorded start.
L3_FILE="$(ls -d "$WOLFMUX_DATA"/state/*/agents/l3.json)"
L3_T="$(transcript_of l3)"
record l3 >"$WORK/l3-original.json"
unproven_change() { # <record filter> <answer time>: a status read must leave the record alone
  jq "$1" "$WORK/l3-original.json" >"$L3_FILE"
  /bin/cp "$L3_FILE" "$WORK/l3-before.json"
  answer claude-opus-5-5 "$2" >"$L3_T"
  teamctl status --json >/dev/null 2>&1 && /usr/bin/cmp -s "$WORK/l3-before.json" "$L3_FILE"
}
check "a legacy record with no model id is displayed from the transcript, not adopted" \
  'unproven_change "del(.model_id)" "$(later)"'
check "a record with no model time is not rewritten from another family in its transcript" \
  'unproven_change "del(.model_at)" "$(later)"'
check "an answer with no timestamp is not adopted" \
  'unproven_change "." ""'
check "an answer with an invalid timestamp is not adopted" \
  'unproven_change "." "unknown"'
check "an answer in the same second as the recorded start cannot prove a later model change" \
  'unproven_change "." "$(jq -r .model_at "$WORK/l3-original.json")"'
check "a date-shaped timestamp with trailing garbage is not adopted" \
  'unproven_change "." "2099-01-01T00:00:00garbageZ"'
check "an out-of-range month is not adopted" \
  'unproven_change "." "2099-99-01T00:00:00Z"'
check "an out-of-range hour is not adopted" \
  'unproven_change "." "2099-01-01T25:00:00Z"'
check "February 29 in a non-leap century is not adopted" \
  'unproven_change "." "2100-02-29T00:00:00Z"'
/bin/cp "$WORK/l3-original.json" "$L3_FILE"
answer claude-opus-5-5 "2400-02-29T00:00:00.123Z" >"$L3_T"
check "a later answer on a valid leap day is adopted, including fractional seconds" \
  '[ "$(field l3 model)" = opus ] && [ "$(record l3 | jq -r .model_at)" = "2400-02-29T00:00:00.123Z" ]'
/bin/cp "$WORK/l3-original.json" "$L3_FILE"
answer claude-fable-5-1 "2020-01-01T00:00:00.000Z" >"$L3_T"
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

echo "== restore-on-limit through the real restart --model"
# Catch lost --model/--resume arguments, a model record that is not updated,
# a false success report, and a cross-CLI move that bypasses restart's refusal.
restore_real_limit() (
  target="$1" team="limit-$1"
  export WOLFMUX_RESTORE_TEAMCTL="$REPO/bin/teamctl"
  export WOLFMUX_MEMORY_PRESSURE="$FAKE/memory_pressure"
  export WOLFMUX_RESTORE_LOAD=1 WOLFMUX_RESTORE_WAIT_MAX=0
  export WOLFMUX_RESTORE_UP_MAX=10 WOLFMUX_RESTORE_POLL=1 WOLFMUX_RESTORE_LIMIT_WAIT=0
  teamctl start fable --team "$team" --no-attach --skip-beads >/dev/null 2>&1 || return 1
  state="$(ls -d "$WOLFMUX_DATA"/state/*)"
  sid="$(record lead "$team" | jq -er .session_id)" || return 1
  session="$(jq -er .session "$state/teams/$team/meta.json")" || return 1
  [ "$(field lead model "$team")" = fable ] || return 1
  transcript="$WOLFMUX_CLAUDE_PROJECTS/$(printf '%s' "$PROJECT" | sed 's|[^A-Za-z0-9]|-|g')/$sid.jsonl"
  /bin/mkdir -p "$(dirname "$transcript")" || return 1
  : >"$transcript"
  printf '%s\n' "$transcript" >"$FAKE/restore-$team"
  # Simulate a crash, not a deliberate stop: the record and snapshot survive.
  jq -cn --arg key "${state##*/}" --arg team "$team" --arg root "$PROJECT" --arg session "$session" --arg sid "$sid" \
    '{epoch:100,ts:"2026-01-01T00:00:00Z",server:"old-server 1",tabs:[],
      teams:[{key:$key,team:$team,root:$root,session:$session,model:"fable",
              family:"claude",label:"Fable",session_id:$sid,founder:"operator"}]}' \
    >"$WOLFMUX_DATA/state/running.json" || return 1
  tmux -L "$WOLFMUX_TMUX_SOCKET" kill-session -t "=$session" || return 1
  teamctl policy restore-on-limit "$target" >/dev/null 2>&1 || return 1
  teamctl restore --yes --no-tabs >"$WORK/restore-$team.out" 2>&1 || return 1
  # Both real restarts must preserve the stored conversation. Only the Opus
  # move may launch a second CLI; Codex must be refused before any launch.
  argv="$FAKE/restore-$team.argv"
  jq -se --arg sid "$sid" '
    all(.[]; index("--resume") as $i | $i != null and .[$i + 1] == $sid) and
    .[0][(.[0] | index("--model")) + 1] == "claude-fable-5-1"' "$argv" || return 1
  [ "$(record lead "$team" | jq -r .session_id)" = "$sid" ] || return 1
  if [ "$target" = opus ]; then
    jq -se 'length == 2 and .[1][(.[1] | index("--model")) + 1] == "claude-opus-5-5"' "$argv" &&
      [ "$(field lead model "$team")" = opus ] &&
      jq -se --arg team "$team" 'any(.[]; .team == $team and .what == "restart --model opus" and .result == "done")' "$WOLFMUX_DATA/state/restore.log" &&
      grep -q "^  moved $team: to opus$" "$WORK/restore-$team.out"
  else
    jq -se 'length == 1' "$argv" &&
      [ "$(field lead model "$team")" = fable ] &&
      jq -se --arg team "$team" 'any(.[]; .team == $team and .what == "restart --model astra" and .result == "failed: exit 64")' "$WOLFMUX_DATA/state/restore.log" &&
      grep -q "$team: .*the move to astra failed: exit 64" "$WORK/restore-$team.out" &&
      ! grep -q "^  moved $team:" "$WORK/restore-$team.out"
  fi
)
check "restore-on-limit opus resumes the lead on Opus and reports the completed move" \
  'restore_real_limit opus'
check "restore-on-limit astra reports real restart exit 64 and leaves the Claude lead on Fable" \
  'restore_real_limit astra'

echo
echo "lead-model: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
