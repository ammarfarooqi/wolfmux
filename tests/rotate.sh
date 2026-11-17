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
  'grep -q "cut at 3200" "$H" && grep -q "step one done" "$H" && grep -q "^ M a" "$H" && grep -q "answer number 7" "$H" && grep -q "old transcript: $HO/t.jsonl" "$H" && grep -q "reason: a reason" "$H" && grep -q "asked by: the lead" "$H"'
check "parts in order a, b, c, d, e, f" \
  '[ "$(grep -o "^## [a-f]\." "$H" | tr -d "\n")" = "## a.## b.## c.## d.## e.## f." ]'
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
OLD="$(record w1 session_id)"
check "the lead role is refused, and the refusal says why" 'out="$(teamctl rotate lead --now 2>&1)"; [ $? -ne 0 ] && printf "%s" "$out" | grep -q "not rotated"'
check "a worker rotating another role is refused" \
  'out="$(TEAM_ROLE=w2 "$REPO/tests/in-pane" rotate w1 --now 2>&1)"; [ $? -ne 0 ] && printf "%s" "$out" | grep -q "may rotate only itself"'
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
check "delivered once: a second startup, a compaction and a resume do not show it again" \
  '! { hook w1 SessionStart "{\"source\":\"startup\"}"; hook w1 SessionStart "{\"source\":\"compact\"}"; hook w1 SessionStart "{\"source\":\"resume\"}"; } | ctx_of | grep -q "fresh conversation for the same task"'

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
R2="$(rundir w2)"
CUR2="$(record w2 session_id)"
stop_at w2 95 "$CUR2"
check "no task in_progress: no rotation" 'sleep 2; [ "$(record w2 session_id)" = "$CUR2" ] && [ ! -e "$R2/rotate.lock" ]'
/bin/mkdir -p "$R1/rotate.lock"
/bin/rm -f "$R1/memory/rotate-fired" "$R1/memory/rotated"
stop_at w1 95 "$AUTO"
check "the lock: a Stop while a rotation holds it starts no second one" 'sleep 2; [ "$(record w1 session_id)" = "$AUTO" ]'
/bin/rmdir "$R1/rotate.lock"

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
RB="$(rundir w1)"
check "beads: rotate --now writes the task from bd (id, body, notes) into the hand-over" \
  'PATH="$FAKE:$PATH" WOLFMUX_STORE=beads teamctl rotate w1 --now >/dev/null 2>&1; grep -q "bd-7" "$RB/memory/handover.md" && grep -q "beads body" "$RB/memory/handover.md" && grep -q "bd note line" "$RB/memory/handover.md"'
check "beads: the lead is told through bd create" 'poll "grep -q \"create.*w1: rotated\" \"$FAKE_LOG\""'

echo
echo "rotate.sh: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
