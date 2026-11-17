#!/bin/bash
# rotate.sh - tests for lib/rotate.sh (ADR-0039): teamctl rotate, the hand-over wolfmux writes,
# its one delivery at SessionStart, policy worker-rotation at Stop, the lock, the wait, who may
# rotate whom, and restart --continue waking an agent with a task in_progress.
#
# Isolated: its own tmux server (socket wolfmux-rotate-<pid>), state directory, throwaway git
# repository and stub agents. Native store first, then a Beads project with a bd stub.
#
#   tests/rotate.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-rotate.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
export WOLFMUX_HOME="$REPO/config/wolfmux"
export WOLFMUX_BIN_DIR="$REPO/bin"
export WOLFMUX_DATA="$WORK/data"
export WOLFMUX_TMUX_SOCKET="wolfmux-rotate-$$"
export WOLFMUX_LAUNCHER_ASTRA="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_GLM53="$REPO/tests/stub-agent"
export WOLFMUX_CLAUDE_PROJECTS="$WORK/claude-projects"
export WOLFMUX_CODEX_SESSIONS="$WORK/codex-sessions"
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR WOLFMUX_NOTIFY WOLFMUX_SPLASH WOLFMUX_METERED TMUX TMUX_PANE BEADS_DIR
unset WOLFMUX_TEAM WOLFMUX_TEAM_ARG WOLFMUX_SESSION WOLFMUX_WORKTREE WOLFMUX_BRANCH WOLFMUX_MODEL WOLFMUX_EXTRA_SETTINGS WOLFMUX_RUN_DIR
unset WOLFMUX_WORKER_ROTATION WOLFMUX_CONTEXT_ROTATE WOLFMUX_CONTEXT_WARN WOLFMUX_ROTATE_WAIT
export WOLFMUX_NOTIFY=off WOLFMUX_SPLASH=off
teamctl() { "$REPO/bin/teamctl" "$@"; }
JQ="$(command -v jq)"

passed=0
failed=0
check() { # <description> <command string>, in a subshell
  if (eval "$2") >"$WORK/check.out" 2>&1; then
    passed=$((passed + 1))
    printf '  pass  %s\n' "$1"
  else
    failed=$((failed + 1))
    printf '  FAIL  %s\n' "$1"
    /usr/bin/sed 's/^/        /' "$WORK/check.out" | /usr/bin/head -n 12
  fi
}
cleanup() {
  if [ -n "${KEEP:-}" ]; then echo "kept $WORK"; return 0; fi
  tmux -L "$WOLFMUX_TMUX_SOCKET" kill-server >/dev/null 2>&1
  /bin/rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$WOLFMUX_TMUX_SOCKET"
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT
poll() { local i; for i in $(seq 1 40); do eval "$1" >/dev/null 2>&1 && return 0; sleep 0.25; done; return 1; }

# project <dir> <store> - a git repository with a lead (astra stub) and workers w1, w2 (glm53 stub)
project() {
  /bin/mkdir -p "$1"
  cd "$1" || exit 1
  git init -q -b main
  echo hello >README.md
  git add -A
  git -c user.name=t -c user.email=t@example.invalid commit -qm "initial commit"
  WOLFMUX_STORE="$2" teamctl start astra --no-attach --skip-beads >/dev/null 2>&1 || WOLFMUX_STORE="$2" teamctl start astra --no-attach >/dev/null 2>&1
  teamctl spawn w1 glm53 >/dev/null 2>&1
  teamctl spawn w2 glm53 >/dev/null 2>&1
  sleep 1
}
field() { teamctl status --json | "$JQ" -r --arg r "$1" --arg f "$2" '[.agents[] | select(.role == $r)][0][$f] // empty'; }
record() { "$JQ" -r --arg f "$2" '.[$f] // empty' "$(find "$WOLFMUX_DATA" -path "*/agents/$1.json" | head -1)"; }
rundir() { find "$WOLFMUX_DATA" -type d -path "*/run/$1" | head -1; }
hook() { # <role> <event> <json>
  printf '%s' "$3" | TEAM_ROLE="$1" BEADS_ACTOR="$1" WOLFMUX_ROOT="$PWD" WOLFMUX_RUN_DIR="$(rundir "$1")" WOLFMUX_MODEL=glm53 teamctl _hook "$2"
}
ctx_of() { "$JQ" -r '[.. | objects | .additionalContext? // empty] | join("\n")' 2>/dev/null; }
lmail() { BEADS_ACTOR=lead WOLFMUX_IDENTITY=lead teamctl mail --peek 2>/dev/null; }
lcount() { BEADS_ACTOR=lead WOLFMUX_IDENTITY=lead teamctl mail --peek --json 2>/dev/null | "$JQ" --arg t "$1" '[.[] | select((.title // .subject // "") == $t)] | length'; }

echo "== the hand-over: order and caps (rotate_handover_write) =="
HO="$WORK/ho"
/bin/mkdir -p "$HO/tree"
(cd "$HO/tree" && git init -q -b main && echo a >a && git add -A && git -c user.name=t -c user.email=t@x commit -qm base && echo b >b && git add -A && git -c user.name=t -c user.email=t@x commit -qm "step one done" && echo dirty >>a)
BASE="$(git -C "$HO/tree" rev-list --max-parents=0 HEAD)"
BIG="$(printf 'B%.0s' $(seq 1 50000))"
TASKJ="$("$JQ" -cn --arg d "$BIG" '{id: "t9", title: "a long task", description: $d, notes: "step 1 done"}')"
printf 'my own words: next is step 2\n## state at compaction 2026\nauto stuff\n' >"$HO/checkpoint.md"
for i in 1 2 3 4 5 6 7; do printf '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"secret thought %s"},{"type":"text","text":"answer number %s"},{"type":"tool_use","name":"Bash","input":{}}]}}\n' "$i" "$i"; done >"$HO/t.jsonl"
write_ho() {
  (for m in provider-env common registry hooks recall rotate; do . "$WOLFMUX_HOME/lib/$m.sh"; done
    rotate_handover_write "$HO/handover.md" "$TASKJ" "$HO/checkpoint.md" "$HO/tree" "$BASE" "$HO/t.jsonl" "$HO/out/" "a reason" "the lead")
}
write_ho
H="$HO/handover.md"
check "a 50,000-character task body: the whole file stays at most 12,000 characters" '[ "$(wc -m <"$H" | tr -d " ")" -le 12001 ]'
check "the body is cut and says so, and the git part, the answers, the paths and the reason are all still there" \
  'grep -q "cut at 2500" "$H" && grep -q "step one done" "$H" && grep -q "^ M a" "$H" && grep -q "answer number 7" "$H" && grep -q "old transcript: $HO/t.jsonl" "$H" && grep -q "reason: a reason" "$H" && grep -q "asked by: the lead" "$H"'
check "parts in order a, b, c, d, f, e: the reason and who asked come before the paths, which are cut first" \
  '[ "$(grep -o "^## [a-f]\." "$H" | tr -d "\n")" = "## a.## b.## c.## d.## f.## e." ]'
check "part c carries the uncommitted diff itself, inside the 12,000" 'grep -q "^### the uncommitted diff" "$H" && grep -q "^+dirty" "$H"'
BIGDIFF="$(printf 'line %s of a long change\n' $(seq 1 2000))"
printf '%s\n' "$BIGDIFF" >"$HO/tree/b"
write_ho
check "a long diff is cut at 3,000 with a marker; the answers and the reason stay" \
  'grep -q "cut at 3000" "$H" && grep -q "answer number 7" "$H" && grep -q "reason: a reason" "$H" && [ "$(wc -m <"$H" | tr -d " ")" -le 12001 ]'
(cd "$HO/tree" && git checkout -q -- b)
write_ho
check "the agent own checkpoint text only, not the automatic section" 'grep -q "my own words" "$H" && ! grep -q "auto stuff" "$H"'
check "the last five answers, newest last; no thinking, no tool call" \
  '! grep -q "answer number 2$" "$H" && grep -q "answer number 3" "$H" && [ "$(grep -n "answer number" "$H" | tail -1 | grep -c "number 7")" = 1 ] && ! grep -q "secret thought" "$H"'

echo "== native store: teamctl rotate =="
project "$WORK/native" native
W1="$(field w1 workdir)"
R1="$(rundir w1)"
TID="$(teamctl task w1 "Build the thing" -d "step 1, step 2, step 3" 2>/dev/null | tail -1 | sed -E 's/^task ([^ ]+) ->.*/\1/')"
TEAM_ROLE=w1 BEADS_ACTOR=w1 teamctl claim "$TID" >/dev/null 2>&1
echo "half done" >"$W1/work.txt"
echo "edit in progress" >>"$W1/README.md"
OLD="$(record w1 session_id)"
check "the lead role is refused, and the refusal says why" 'out="$(teamctl rotate lead --now 2>&1)"; [ $? -ne 0 ] && printf "%s" "$out" | grep -q "not rotated"'
check "a worker rotating another role is refused" \
  'out="$(TEAM_ROLE=w2 "$REPO/tests/in-pane" rotate w1 --now 2>&1)"; [ $? -ne 0 ] && printf "%s" "$out" | grep -q "may rotate only itself"'
LEADS="$(record lead session_id)"
untouched() { [ "$(record lead session_id)" = "$LEADS" ] && [ "$(record w1 session_id)" = "$OLD" ] && [ ! -e "$R1/memory/handover.pending" ]; }
check "release review HIGH 1: ROTATE_ACTING=1 from a worker does not let it restart the lead" \
  'out="$(ROTATE_ACTING=1 TEAM_ROLE=w2 "$REPO/tests/in-pane" restart lead 2>&1)"; [ $? -ne 0 ] && printf "%s" "$out" | grep -q "reserved for the lead" && untouched'
check "release review HIGH 1: ROTATE_ACTING=1 from a worker does not let it restart another worker" \
  'out="$(ROTATE_ACTING=1 TEAM_ROLE=w2 "$REPO/tests/in-pane" restart w1 2>&1)"; [ $? -ne 0 ] && printf "%s" "$out" | grep -q "reserved for the lead" && untouched'
check "the internal _rotate-run, typed by a worker for the lead: refused (77), nothing written" \
  'TEAM_ROLE=w2 "$REPO/tests/in-pane" _rotate-run lead x y 1 >/dev/null 2>&1; [ $? -eq 77 ] && untouched'
check "the internal _rotate-run, typed by a worker for another worker: refused (77), nothing written" \
  'TEAM_ROLE=w2 "$REPO/tests/in-pane" _rotate-run w1 x y 1 >/dev/null 2>&1; [ $? -eq 77 ] && untouched'
check "the internal _rotate-auto, typed by a worker for another worker: refused (77), nothing written" \
  'TEAM_ROLE=w2 "$REPO/tests/in-pane" _rotate-auto w1 x "$OLD" >/dev/null 2>&1; [ $? -eq 77 ] && untouched'
check "the internal _rotate-run, typed by the lead for a worker: refused (77); the lead uses teamctl rotate" \
  'TEAM_ROLE=lead "$REPO/tests/in-pane" _rotate-run w1 x y 1 >/dev/null 2>&1; [ $? -eq 77 ] && untouched'
check "the internal _rotate-run, typed by a worker for itself with no rotation lock taken: refused (77)" \
  'TEAM_ROLE=w1 "$REPO/tests/in-pane" _rotate-run w1 x y 1 >/dev/null 2>&1; [ $? -eq 77 ] && untouched && [ ! -e "$R1/rotate.lock" ]'
printf 'busy\n' >"$R1/state"
check "the wait runs out: refused, it says so and names --now, nothing written" \
  'out="$(WOLFMUX_ROTATE_WAIT=1 teamctl rotate w1 2>&1)"; [ $? -ne 0 ] && printf "%s" "$out" | grep -q -- "--now" && [ ! -e "$R1/memory/handover.md" ] && [ "$(record w1 session_id)" = "$OLD" ]'
/bin/mkdir "$R1/rotate.lock"
check "the lock: a second rotation while one is under way is refused" \
  'out="$(teamctl rotate w1 --now 2>&1)"; [ $? -ne 0 ] && printf "%s" "$out" | grep -q "already under way" && [ "$(record w1 session_id)" = "$OLD" ]'
/bin/rmdir "$R1/rotate.lock"
check "--now does not wait: rotated although the turn is busy" 'teamctl rotate w1 --now --reason "test reason" | grep -q "rotated: w1"'
NEW="$(record w1 session_id)"
check "a fresh conversation: a new id, the old one kept as rotated_from" '[ -n "$NEW" ] && [ "$NEW" != "$OLD" ] && [ "$(record w1 rotated_from)" = "$OLD" ]'
check "same worktree and branch; the uncommitted work is untouched" '[ "$(record w1 workdir)" = "$W1" ] && [ "$(cat "$W1/work.txt")" = "half done" ]'
check "the task stays in_progress and assigned" 'teamctl tasks --all --status in_progress | grep -q "$TID"'
check "the hand-over carries the task, the uncommitted file and the reason" \
  'grep -q "Build the thing" "$R1/memory/handover.md" && grep -q "work.txt" "$R1/memory/handover.md" && grep -q "reason: test reason" "$R1/memory/handover.md"'
check "one notice to the lead (the operator asked), with the hand-over path" \
  'poll "lmail | grep -q \"w1: rotated\"" && lmail | grep -q "handover.md"'
S1="$(hook w1 SessionStart '{"source":"startup"}' | ctx_of)"
check "the new conversation's SessionStart carries it, with the one line, first" \
  'printf "%s" "$S1" | head -1 | grep -q "fresh conversation for the same task" && printf "%s" "$S1" | grep -q "Build the thing"'
check "the line says the task is already claimed and the tree state is current; continue from it" \
  'printf "%s" "$S1" | head -1 | grep -q "already claimed and in progress" && printf "%s" "$S1" | head -1 | grep -q "current as of the rotation" && printf "%s" "$S1" | grep -q "^+edit in progress"'
check "delivered once: a second startup, a compaction and a resume do not show it again" \
  '! { hook w1 SessionStart "{\"source\":\"startup\"}"; hook w1 SessionStart "{\"source\":\"compact\"}"; hook w1 SessionStart "{\"source\":\"resume\"}"; } | ctx_of | grep -q "fresh conversation for the same task"'

printf 'busy\n' >"$R1/state"
BEFORE="$(record w1 session_id)"
(WOLFMUX_ROTATE_WAIT=20 teamctl rotate w1 --reason "waited" >"$WORK/wait.out" 2>&1; echo "$?" >"$WORK/wait.rc") &
sleep 1.5
check "the default waits for the turn end: nothing yet while the turn is busy" '[ ! -e "$WORK/wait.rc" ] && [ "$(record w1 session_id)" = "$BEFORE" ]'
printf 'idle\n' >"$R1/state"
check "the default waits for the turn end: rotated once the agent is idle" \
  'poll "[ -e \"$WORK/wait.rc\" ]" && [ "$(cat "$WORK/wait.rc")" = 0 ] && [ "$(record w1 session_id)" != "$BEFORE" ] && grep -q "reason: waited" "$R1/memory/handover.md"'

echo "== policy worker-rotation at Stop =="
stop_at() { # <role> <percent> <session> [agent_id]
  "$JQ" -n --argjson p "$2" '{used: 1, limit: 2, percent: $p}' >"$(rundir "$1")/memory/ctx"
  if [ -n "${4:-}" ]; then hook "$1" Stop "{\"session_id\":\"$3\",\"agent_id\":\"$4\"}"; else hook "$1" Stop "{\"session_id\":\"$3\"}"; fi >/dev/null
}
/bin/rm -f "$R1/memory/rotated"
CUR="$(record w1 session_id)"
stop_at w1 85 "$CUR" sub1
check "Stop with agent_id (a subagent): nothing happens" 'sleep 1; [ "$(record w1 session_id)" = "$CUR" ] && [ ! -e "$R1/memory/rotate-fired" ]'
stop_at w1 50 "$CUR"
check "Stop under the threshold: nothing happens" 'sleep 1; [ "$(record w1 session_id)" = "$CUR" ]'
teamctl policy worker-rotation off >/dev/null 2>&1
stop_at w1 85 "$CUR"
check "policy off: no rotation" 'sleep 2; [ "$(record w1 session_id)" = "$CUR" ] && [ ! -e "$R1/rotate.lock" ]'
/bin/rm -f "$R1/memory/rotate-fired"
teamctl policy worker-rotation ask >/dev/null 2>&1
stop_at w1 85 "$CUR"
check "policy ask: no rotation, one message to the lead with the exact command" \
  'poll "lmail | grep -q \"teamctl rotate w1\"" && [ "$(record w1 session_id)" = "$CUR" ]'
/bin/rm -f "$R1/memory/rotate-fired"
teamctl policy worker-rotation auto >/dev/null 2>&1
printf 'idle\n' >"$R1/state"
stop_at w1 85 "$CUR"
check "policy auto at 85%: rotated at the turn end, without asking the agent" 'poll "[ \"\$(record w1 session_id)\" != \"$CUR\" ]" && poll "[ ! -e \"$R1/rotate.lock\" ]"'
AUTO="$(record w1 session_id)"
stop_at w1 90 "$AUTO"
check "the fresh conversation past the threshold at its first Stop is not rotated again; the lead gets the context message" \
  'sleep 2; [ "$(record w1 session_id)" = "$AUTO" ] && poll "lmail | grep -q \"w1: context at 90%\""'
# A3 finding 2: the guard is for a conversation that STARTS past the threshold, not for one that
# filled up with work. The watch marks the first look under the threshold (memory/below-seen).
TR="$WORK/tr.jsonl"
usage_line() { printf '{"type":"assistant","message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$1"; }
post() { # <role> <session> [NAME=value...]: a PostToolUse look past the hot path
  local r="$1" s="$2"
  shift 2
  : >"$(rundir "$r")/attention"
  printf '{"session_id":"%s","transcript_path":"%s"}' "$s" "$TR" |
    env "$@" TEAM_ROLE="$r" BEADS_ACTOR="$r" WOLFMUX_ROOT="$PWD" WOLFMUX_RUN_DIR="$(rundir "$r")" WOLFMUX_MODEL=glm53 "$REPO/bin/teamctl" _hook PostToolUse
}
usage_line 84000 >"$TR" # 50% of 167000
post w1 "$AUTO" >/dev/null
/bin/rm -f "$R1/memory/rotate-fired"
stop_at w1 85 "$AUTO"
check "a conversation a rotation started that was seen under the threshold once, then filled up, is rotated again" \
  '[ -e "$R1/memory/below-seen" ] && poll "[ \"\$(record w1 session_id)\" != \"$AUTO\" ]" && poll "[ ! -e \"$R1/rotate.lock\" ]"'
AUTO="$(record w1 session_id)"
hook w1 SessionStart '{"source":"startup","session_id":"sid-from-the-hook"}' >/dev/null
check "the new conversation's own SessionStart records it as started by a rotation (new <id>), and forgets below-seen" \
  'grep -qx "new sid-from-the-hook" "$R1/memory/rotated" && [ ! -e "$R1/memory/below-seen" ]'
R2="$(rundir w2)"
CUR2="$(record w2 session_id)"
stop_at w2 95 "$CUR2"
check "no task in_progress: no rotation" 'sleep 2; [ "$(record w2 session_id)" = "$CUR2" ] && [ ! -e "$R2/rotate.lock" ]'
check "no task: rotate-fired is cleared, and the lead gets the context message" \
  'poll "[ ! -e \"$R2/memory/rotate-fired\" ]" && poll "lmail | grep -q \"w2: context at 95%\""'
stop_at w2 95 "$CUR2"
check "no task, the next Stop: no second message in the same conversation" 'sleep 2; [ "$(lcount "w2: context at 95%")" = 1 ]'
T2="$(teamctl task w2 "Second thing" -d "one step" 2>/dev/null | tail -1 | sed -E 's/^task ([^ ]+) ->.*/\1/')"
TEAM_ROLE=w2 BEADS_ACTOR=w2 teamctl claim "$T2" >/dev/null 2>&1
printf 'idle\n' >"$R2/state"
stop_at w2 95 "$CUR2"
check "once it has a task, the same conversation is rotated at its next Stop" \
  'poll "[ \"\$(record w2 session_id)\" != \"$CUR2\" ]" && poll "[ ! -e \"$R2/rotate.lock\" ]"'
teamctl close "$T2" -r "test done" >/dev/null 2>&1
/bin/mkdir -p "$R1/rotate.lock"
/bin/rm -f "$R1/memory/rotate-fired" "$R1/memory/rotated"
stop_at w1 95 "$AUTO"
check "the lock: a Stop while a rotation holds it starts no second one" 'sleep 2; [ "$(record w1 session_id)" = "$AUTO" ]'
/bin/rmdir "$R1/rotate.lock"
/bin/rm -f "$R1/memory/rotate-fired" "$R1/memory/rotated"
: >"$R1/memory/thrash-told"
stop_at w1 40 "$AUTO"
check "the thrash event (two compactions within the tool-call window) rotates at the turn end, under the threshold" \
  'poll "[ \"\$(record w1 session_id)\" != \"$AUTO\" ]" && poll "[ ! -e \"$R1/rotate.lock\" ]" && grep -q "reason: compacted twice" "$R1/memory/handover.md"'

echo "== A3 finding 4: a lock nobody removes =="
AUTO="$(record w1 session_id)"
/bin/mkdir -p "$R1/rotate.lock"
printf 'stop %s\n' "$(($(date +%s) - 700))" >"$R1/rotate.lock/by"
check "teamctl rotate takes over a lock older than 600 s" 'teamctl rotate w1 --now | grep -q "rotated: w1" && [ ! -e "$R1/rotate.lock" ]'
/bin/mkdir -p "$R1/rotate.lock"
printf 'stop %s\n' "$(($(date +%s) - 30))" >"$R1/rotate.lock/by"
check "a young lock is refused, and the refusal names its age" \
  'out="$(teamctl rotate w1 --now 2>&1)"; [ $? -ne 0 ] && printf "%s" "$out" | grep -qE "(29|3[0-9]) s old"'
/bin/rm -rf "$R1/rotate.lock"
/bin/mkdir -p "$R1/rotate.lock"
touch -t "$(date -v-1H +%Y%m%d%H%M.%S)" "$R1/rotate.lock"
/bin/rm -f "$R1/memory/rotate-fired" "$R1/memory/rotated" "$R1/memory/thrash-told"
AUTO="$(record w1 session_id)"
printf 'idle\n' >"$R1/state"
stop_at w1 95 "$AUTO"
check "a Stop takes over a lock older than 600 s with no by file (the directory's mtime)" \
  'poll "[ \"\$(record w1 session_id)\" != \"$AUTO\" ]" && poll "[ ! -e \"$R1/rotate.lock\" ]"'

echo "== A3 finding 1: at the crossing the agent is told to end its turn when a rotation follows =="
AUTO="$(record w1 session_id)"
/bin/rm -f "$R1/memory/warned" "$R1/memory/rotate-fired" "$R1/memory/below-seen"
usage_line 84000 >"$TR" # 50%: seen under the threshold, so the loop guard does not hold it back
post w1 "$AUTO" >/dev/null
usage_line 142000 >"$TR" # 85%
OUT1="$(post w1 "$AUTO" | ctx_of)"
check "policy auto, a worker: commit, do not start the next step, END YOUR TURN; wolfmux replaces the conversation and continues the task" \
  'printf "%s" "$OUT1" | grep -q "END YOUR TURN" && printf "%s" "$OUT1" | grep -q "If you have a task in progress" && printf "%s" "$OUT1" | grep -q "hand-over" && printf "%s" "$OUT1" | grep -q "Do not close the task" && ! printf "%s" "$OUT1" | grep -q "The lead has been told"'
check "policy auto: the lead gets no context message at the crossing (the rotation's notice follows)" \
  'sleep 2; ! lmail | grep -q "w1: context at 85%"'
check "the warn text is not added when both thresholds are crossed at once" '! printf "%s" "$OUT1" | grep -q "Commit what works now"'
teamctl policy worker-rotation ask >/dev/null 2>&1
/bin/rm -f "$R1/memory/warned"
OUT2="$(post w1 "$AUTO" | ctx_of)"
check "policy ask: the v1.25.0 wording, and the lead is told at the crossing with teamctl rotate named" \
  'printf "%s" "$OUT2" | grep -q "finish or hand back the current step" && ! printf "%s" "$OUT2" | grep -q "END YOUR TURN" && poll "lmail | grep -q \"w1: context at 85%\"" && lmail | grep -q "teamctl rotate w1"'
teamctl policy worker-rotation auto >/dev/null 2>&1
/bin/rm -f "$R1/memory/thrash-told" "$R1/memory/compactions"
compact() { printf '%s\n' "$1" >"$R1/calls"; printf '{"source":"compact","session_id":"%s","transcript_path":"%s"}' "$AUTO" "$TR" | WOLFMUX_COMPACT_WAIT=1 TEAM_ROLE=w1 BEADS_ACTOR=w1 WOLFMUX_ROOT="$PWD" WOLFMUX_RUN_DIR="$R1" WOLFMUX_MODEL=glm53 "$REPO/bin/teamctl" _hook SessionStart; }
compact 40 >/dev/null
OUT3="$(compact 44 | ctx_of)"
check "the thrash event under auto: the agent is told to end its turn; the lead gets no thrash message" \
  'printf "%s" "$OUT3" | grep -q "compacted twice within 4 tool calls" && printf "%s" "$OUT3" | grep -q "END YOUR TURN" && sleep 3 && ! lmail | grep -q "w1: compacted twice"'
/bin/rm -f "$R1/memory/thrash-told"

echo "== A3 review: at the Stop that starts a rotation, wolfmux's Stop hooks add nothing =="
inbox_stop() { printf '{}' | env TEAM_ROLE="$1" BEADS_ACTOR="$1" WOLFMUX_RUN_DIR="$(rundir "$1")" WOLFMUX_TEAM=default WOLFMUX_INBOX_CLIENTS=0 WOLFMUX_INBOX_STOP_COOLDOWN=0 "$REPO/tests/in-pane" _inbox-stop; }
AUTO="$(record w1 session_id)"
/bin/rm -f "$R1/memory/warned" "$R1/memory/rotate-fired" "$R1/memory/below-seen" "$R1/memory/rotate-due" "$R1"/tasks/reminded-*
usage_line 84000 >"$TR"
post w1 "$AUTO" >/dev/null
usage_line 142000 >"$TR"
post w1 "$AUTO" >/dev/null
check "the crossing under auto writes memory/rotate-due, for every Stop hook to see" '[ -e "$R1/memory/rotate-due" ]'
WOLFMUX_NUDGE_TYPE=off teamctl send w1 "a late message" "for the fresh conversation" >/dev/null 2>&1
sleep 1
check "_inbox-stop says nothing while a rotation is due: the notice waits for the fresh conversation" '[ -z "$(inbox_stop w1)" ]'
printf 'busy\n' >"$R1/state"
SOUT="$(printf '{"session_id":"%s"}' "$AUTO" | TEAM_ROLE=w1 BEADS_ACTOR=w1 WOLFMUX_TEAM=default WOLFMUX_INBOX_CLIENTS=0 WOLFMUX_ROOT="$PWD" WOLFMUX_RUN_DIR="$R1" WOLFMUX_MODEL=glm53 "$REPO/tests/in-pane" _hook Stop)"
check "the Stop that starts the rotation adds no context (no task reminder), so the turn ends and it is rotated" \
  '! printf "%s" "$SOUT" | grep -q "You are stopping while" && [ -z "$(printf "%s" "$SOUT" | ctx_of)" ] && poll "[ \"\$(record w1 session_id)\" != \"$AUTO\" ]" && poll "[ ! -e \"$R1/rotate.lock\" ]"'
check "after the rotation the notice is still there for the fresh conversation, and rotate-due is gone" \
  '[ ! -e "$R1/memory/rotate-due" ] && inbox_stop w1 | grep -q "a late message"'
CUR2="$(record w2 session_id)"
T3="$(teamctl task w2 "Third thing" -d "one step" 2>/dev/null | tail -1 | sed -E 's/^task ([^ ]+) ->.*/\1/')"
TEAM_ROLE=w2 BEADS_ACTOR=w2 teamctl claim "$T3" >/dev/null 2>&1
/bin/rm -f "$R2/memory/rotate-fired" "$R2/memory/rotated" "$R2/memory/rotate-declined"
printf 'busy\n' >"$R2/state"
ROTATED_BEFORE="$(lcount "w2: rotated")"
stop_at w2 95 "$CUR2"
printf 'busy\n' >"$R2/state" # the Stop hook wrote idle; the turn goes on (the old conversation finishes the task)
sleep 1.5
teamctl close "$T3" -r "finished in the old conversation" >/dev/null 2>&1
printf 'idle\n' >"$R2/state"
check "the task closed while the rotation waited for the turn end: not rotated, rotate-fired cleared, said in rotate.log, no message to the lead" \
  'sleep 3; [ "$(record w2 session_id)" = "$CUR2" ] && [ ! -e "$R2/memory/rotate-fired" ] && [ ! -e "$R2/rotate.lock" ] && grep -q "no task in progress any more" "$R2/rotate.log" && [ "$(lcount "w2: rotated")" = "$ROTATED_BEFORE" ]'

echo "== release review MEDIUM 2: a stale rotate.lock with a leftover rotate-due does not silence the Stop hooks =="
AUTO="$(record w1 session_id)"
/bin/rm -f "$R1"/tasks/reminded-* "$R1/memory/rotate-fired"
/bin/mkdir -p "$R1/rotate.lock"
printf 'stop 1 dead.1\n' >"$R1/rotate.lock/by"
: >"$R1/memory/rotate-due"
WOLFMUX_NUDGE_TYPE=off teamctl send w1 "a message past a dead rotation" "must arrive" >/dev/null 2>&1
sleep 1
check "_inbox-stop: rotate-due with a stale lock is not honoured; the notice is handed over" \
  'inbox_stop w1 | grep -q "a message past a dead rotation"'
"$JQ" -n '{used: 1, limit: 2, percent: 40}' >"$R1/memory/ctx"
printf 'busy\n' >"$R1/state"
SOUT3="$(printf '{"session_id":"%s"}' "$AUTO" | TEAM_ROLE=w1 BEADS_ACTOR=w1 WOLFMUX_TEAM=default WOLFMUX_INBOX_CLIENTS=0 WOLFMUX_ROOT="$PWD" WOLFMUX_RUN_DIR="$R1" WOLFMUX_MODEL=glm53 "$REPO/tests/in-pane" _hook Stop)"
check "the Stop hook: a stale lock and rotate-due are removed, and the turn end speaks again (the task reminder)" \
  '[ ! -e "$R1/rotate.lock" ] && [ ! -e "$R1/memory/rotate-due" ] && printf "%s" "$SOUT3" | grep -q "You are stopping while" && [ "$(record w1 session_id)" = "$AUTO" ]'
/bin/mkdir -p "$R1/rotate.lock"
printf 'stop %s fresh.1\n' "$(date +%s)" >"$R1/rotate.lock/by"
: >"$R1/memory/rotate-due"
WOLFMUX_NUDGE_TYPE=off teamctl send w1 "a message during a live rotation" "waits" >/dev/null 2>&1
sleep 1
check "_inbox-stop: rotate-due with a fresh lock is still honoured (silent)" '[ -z "$(inbox_stop w1)" ]'
/bin/rm -rf "$R1/rotate.lock" "$R1/memory/rotate-due"
inbox_stop w1 >/dev/null

echo "== release review MEDIUM 3: a rotation whose restart fails leaves nothing behind and tells the lead =="
# A record whose working directory is gone makes cmd_restart die after the hand-over is written.
REC1="$(find "$WOLFMUX_DATA" -path "*/agents/w1.json" | head -1)"
/bin/cp "$REC1" "$WORK/w1.json.saved"
"$JQ" '.workdir = "/nonexistent/wolfmux-gone"' "$WORK/w1.json.saved" >"$REC1"
AUTO="$(record w1 session_id)"
/bin/rm -f "$R1/memory/rotate-fired" "$R1/memory/rotated" "$R1/memory/thrash-told" "$R1/memory/handover.pending"
FAILED_BEFORE="$(lcount "w1: rotation failed")"
printf 'idle\n' >"$R1/state"
: >"$R1/memory/rotate-due"
stop_at w1 95 "$AUTO"
check "auto path, the restart fails: no handover.pending, no rotated line, no rotate-due, rotate-fired cleared, the lock gone" \
  'poll "[ ! -e \"$R1/rotate.lock\" ]" && sleep 1 && [ ! -e "$R1/memory/handover.pending" ] && ! grep -qx "$AUTO" "$R1/memory/rotated" 2>/dev/null && [ ! -e "$R1/memory/rotate-due" ] && [ ! -e "$R1/memory/rotate-fired" ] && [ "$(record w1 session_id)" = "$AUTO" ]'
check "auto path, the restart fails: one message at the lead with the log line, the context figure and the retry command" \
  'poll "[ \"\$(lcount \"w1: rotation failed\")\" = $((FAILED_BEFORE + 1)) ]" && lmail | grep -q "working directory is gone" && lmail | grep -q "teamctl rotate w1" && lmail | grep -q "context: "'
check "lead path, the restart fails: refused, the same three files gone, no message at the lead" \
  '! teamctl rotate w1 --now >/dev/null 2>&1 && [ ! -e "$R1/memory/handover.pending" ] && ! grep -qx "$AUTO" "$R1/memory/rotated" 2>/dev/null && [ ! -e "$R1/rotate.lock" ] && sleep 1 && [ "$(lcount "w1: rotation failed")" = $((FAILED_BEFORE + 1)) ]'
/bin/cp "$WORK/w1.json.saved" "$REC1"

echo "== release review LOW 4: a rotation that ends removes its own lock only, never one taken over since =="
AUTO="$(record w1 session_id)"
printf 'busy\n' >"$R1/state"
TEAM_ROLE=w1 WOLFMUX_ROTATE_WAIT=4 "$REPO/tests/in-pane" rotate w1 >/dev/null 2>&1
sleep 1.5 # the detached process is past its entry check and waits for the turn end
printf 'rotate %s other.1\n' "$(date +%s)" >"$R1/rotate.lock/by" # a second rotation took the lock over meanwhile
check "the first one gives up (its wait runs out) and leaves the second one's lock in place" \
  'poll "grep -q \"did not end its turn\" \"$R1/rotate.log\"" && sleep 1 && [ -d "$R1/rotate.lock" ] && grep -q "other.1" "$R1/rotate.lock/by" && [ "$(record w1 session_id)" = "$AUTO" ]'
/bin/rm -rf "$R1/rotate.lock" "$R1/memory/rotate-due"

echo "== A3 finding 5: the rotating process outlives the pane it was started from =="
PANE_OUT="$WORK/pane"
/bin/mkdir -p "$PANE_OUT"
pane_hup() { # <alive-file> <how: detach|plain>: a stand-in pane in its own process group starts a child, then the group gets SIGHUP
  /usr/bin/perl -e 'setpgrp(0, 0); exec @ARGV' /bin/bash -c '
    for m in provider-env common registry hooks recall rotate; do . "$WOLFMUX_HOME/lib/$m.sh"; done
    if [ "$2" = detach ]; then _rotate_detach "$3/log" /bin/bash -c "sleep 2; echo alive >$1"; else (/bin/bash -c "sleep 2; echo alive >$1" </dev/null >/dev/null 2>&1 &); fi
    sleep 30' pane "$1" "$2" "$PANE_OUT" &
  local pid=$!
  sleep 0.8
  kill -HUP -- "-$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  sleep 2.5
}
pane_hup "$PANE_OUT/plain" plain
check "control: a plain background child of the pane dies with the pane's process group" '[ ! -e "$PANE_OUT/plain" ]'
pane_hup "$PANE_OUT/detached" detach
check "_rotate_detach: the child is in its own session and ignores SIGHUP; it outlives the pane" '[ -e "$PANE_OUT/detached" ]'
AUTO="$(record w1 session_id)"
printf 'busy\n' >"$R1/state"
SELF="$(TEAM_ROLE=w1 WOLFMUX_ROTATE_WAIT=30 "$REPO/tests/in-pane" rotate w1 2>&1)"
check "a worker rotating itself: it returns at once with 'rotation started: end your turn', nothing restarted yet" \
  'printf "%s" "$SELF" | grep -q "rotation started: end your turn" && sleep 1 && [ "$(record w1 session_id)" = "$AUTO" ] && [ -d "$R1/rotate.lock" ]'
/bin/rm -f "$R1"/tasks/reminded-*
SOUT2="$(printf '{"session_id":"%s"}' "$AUTO" | TEAM_ROLE=w1 BEADS_ACTOR=w1 WOLFMUX_TEAM=default WOLFMUX_INBOX_CLIENTS=0 WOLFMUX_ROOT="$PWD" WOLFMUX_RUN_DIR="$R1" WOLFMUX_MODEL=glm53 "$REPO/tests/in-pane" _hook Stop)"
check "... its turn end gets no task reminder from wolfmux while that rotation waits" '[ -z "$(printf "%s" "$SOUT2" | ctx_of)" ] && [ "$(cat "$R1/state")" = idle ]'
check "... and the detached process rotates it once its turn has ended; the lock goes" \
  'poll "[ \"\$(record w1 session_id)\" != \"$AUTO\" ]" && poll "[ ! -e \"$R1/rotate.lock\" ]" && [ "$(record w1 rotated_from)" = "$AUTO" ]'

echo "== restart --continue wakes an agent with a task in_progress =="
check "a notice 'continue task <id>' is filed through the inbox" \
  'teamctl restart w1 --continue >/dev/null 2>&1; grep -rq "continue task $TID" "$(dirname "$(dirname "$R1")")/inbox"'
check "an agent with no task gets no such notice" \
  'teamctl restart w2 --continue >/dev/null 2>&1; ! grep -rq "continue task" "$(dirname "$(dirname "$R1")")/inbox/w2" 2>/dev/null'

echo "== Beads store (bd stub): the task comes from bd, the lead is told through bd =="
FAKE="$WORK/fake"
/bin/mkdir -p "$FAKE"
/bin/cat >"$FAKE/bd" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$FAKE_LOG"
case "$1" in
  create) echo '{"id":"bd-m1"}' ;;
  list) case "$*" in *in_progress*w1*|*w1*in_progress*) echo '[{"id":"bd-7","issue_type":"task","title":"Beads task title","description":"beads body","status":"in_progress","priority":1,"assignee":"w1","notes":"bd note line","created_at":"2026-11-17T00:00:00Z","updated_at":"2026-11-17T00:00:00Z"}]' ;; *) echo '[]' ;; esac ;;
  where) echo "$PWD/.beads" ;;
  *) echo '[]' ;;
esac
EOF
/bin/chmod 755 "$FAKE/bd"
export FAKE_LOG="$WORK/bd.log"
cd "$WORK" || exit 1
tmux -L "$WOLFMUX_TMUX_SOCKET" kill-server >/dev/null 2>&1
PATH="$FAKE:$PATH" WOLFMUX_STORE=beads project "$WORK/beads" beads
/bin/mkdir -p .beads
RB="$(find "$WOLFMUX_DATA" -type d -path "*/state/beads-*/run/w1" | head -1)" # not the native project's w1
check "beads: rotate --now writes the task from bd (id, body, notes) into the hand-over" \
  'PATH="$FAKE:$PATH" WOLFMUX_STORE=beads teamctl rotate w1 --now >/dev/null 2>&1; grep -q "bd-7" "$RB/memory/handover.md" && grep -q "beads body" "$RB/memory/handover.md" && grep -q "bd note line" "$RB/memory/handover.md"'
check "beads: the lead is told through bd create" 'poll "grep -q \"create.*w1: rotated\" \"$FAKE_LOG\""'
RB2="$(find "$WOLFMUX_DATA" -type d -path "*/state/beads-*/run/w2" | head -1)"
"$JQ" -n '{used: 1, limit: 2, percent: 95}' >"$RB2/memory/ctx"
printf '{"session_id":"s-b2"}' | PATH="$FAKE:$PATH" WOLFMUX_STORE=beads TEAM_ROLE=w2 BEADS_ACTOR=w2 WOLFMUX_ROOT="$PWD" WOLFMUX_RUN_DIR="$RB2" WOLFMUX_MODEL=glm53 teamctl _hook Stop >/dev/null
check "beads: no task in bd: rotate-fired is cleared and the lead is told through bd create" \
  'poll "[ ! -e \"$RB2/memory/rotate-fired\" ]" && poll "grep -q \"create.*w2: context at 95%\" \"$FAKE_LOG\""'

echo
echo "rotate.sh: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
