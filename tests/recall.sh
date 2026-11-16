#!/bin/bash
# memory.sh — tests for lib/memory.sh: team memory at session start, context watch,
# checkpoints, and the lib/agents.sh _ctx_of_transcript refactor it rides on.
#
# Fully isolated from any team you have running: its own tmux server (socket
# wolfmux-memtest-<pid>), its own state directory, a throwaway git repository, a stub
# agent instead of a real CLI, and a real `bd` (Beads) workspace in that throwaway repo.
#
#   tests/memory.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
command -v bd >/dev/null 2>&1 || { echo "tests/memory.sh needs bd (Beads) installed"; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-memory-test.XXXXXX")"
export WOLFMUX_HOME="$REPO/config/wolfmux"
export WOLFMUX_BIN_DIR="$REPO/bin"
export WOLFMUX_DATA="$WORK/data"
export WOLFMUX_TMUX_SOCKET="wolfmux-memtest-$$"
export WOLFMUX_LAUNCHER_FABLE="$REPO/tests/stub-agent"
export WOLFMUX_CLAUDE_PROJECTS="$WORK/claude-projects"
export WOLFMUX_CODEX_SESSIONS="$WORK/codex-sessions"
# Run from an agent's pane (a teammate testing its change), the environment carries that
# agent's team, worktree and session: all of it is dropped, or every command below would
# act as that agent instead of the throwaway one this test builds.
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR WOLFMUX_NOTIFY WOLFMUX_SPLASH WOLFMUX_METERED TMUX TMUX_PANE
unset WOLFMUX_TEAM WOLFMUX_TEAM_ARG WOLFMUX_SESSION WOLFMUX_WORKTREE WOLFMUX_BRANCH WOLFMUX_MODEL WOLFMUX_EXTRA_SETTINGS WOLFMUX_RUN_DIR
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

PROJECT="$WORK/project"
/bin/mkdir -p "$PROJECT"
cd "$PROJECT" || exit 1
git init -q -b main
echo "hello" >README.md
git add -A
git -c user.name=test -c user.email=test@example.invalid commit -qm "initial commit"

echo "== setup: a lead (stub agent), so a registry (agents dir) exists =="
teamctl start fable --no-attach --init-beads >/dev/null 2>&1
sleep 1
check "setup: the lead is registered" 'teamctl status --json | jq -e ".agents[] | select(.role == \"lead\")"'

# hook() <role> <event> <run-dir> [env...] — teamctl _hook <event>, that role's own environment,
# JSON on stdin built from the remaining args as "key=value" pairs (jq -n style).
hook_json() { # key=value ... -> {"key":"value", ...}
  local out="{}" kv
  for kv in "$@"; do
    out="$(printf '%s' "$out" | "$(command -v jq)" --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k): $v}')"
  done
  printf '%s' "$out"
}
force_through() { : >"$2/attention"; } # the PostToolUse hot path: force the 10th-call bypass

echo "== team memory (SessionStart) =="
RUN_W1="$WORK/run-w1"
/bin/mkdir -p "$RUN_W1"
# "w1" has no registry record, so mail_hook's own SessionStart briefing ("nothing is
# assigned yet...") fires regardless (cmd_hook asks only a valid role name, not a
# registered one); these checks are about the memory heading specifically, not the whole
# hook answer being empty.
check "no memories: SessionStart says nothing about memory" '! printf "%s" "$(hook_json source=startup | TEAM_ROLE=w1 WOLFMUX_RUN_DIR="$RUN_W1" teamctl _hook SessionStart)" | grep -q "\[wolfmux memory\]"'
bd remember "always run tests before reporting" --key test-habit >/dev/null 2>&1
check "a remembered fact: SessionStart shows it under the wolfmux heading, bd's own banner lines gone" \
  'out="$(hook_json source=startup | TEAM_ROLE=w1 WOLFMUX_RUN_DIR="$RUN_W1" teamctl _hook SessionStart)"; printf "%s" "$out" | grep -q "\[wolfmux memory\] What this project" && printf "%s" "$out" | grep -q "always run tests before reporting" && ! printf "%s" "$out" | grep -q "If this output is truncated" && ! printf "%s" "$out" | grep -q "Stored via"'
bd forget test-habit >/dev/null 2>&1
check "forgotten again: SessionStart says nothing about memory" '! printf "%s" "$(hook_json source=startup | TEAM_ROLE=w1 WOLFMUX_RUN_DIR="$RUN_W1" teamctl _hook SessionStart)" | grep -q "\[wolfmux memory\]"'

echo "== context watch (PostToolUse) =="
TRANS="$WORK/transcript.jsonl"
# v1.24.0: the thresholds are checked against a 200000-token window, so the hooks below name a
# model that has one (glm53). fable has 1000000 in v1.23.0's model table (lib/models.sh), which wins.
usage_line() { printf '{"type":"assistant","message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$1"; }

RUN_W2="$WORK/run-w2"
/bin/mkdir -p "$RUN_W2"
usage_line 60000 >"$TRANS"
force_through "" "$RUN_W2"
check "30%: nothing said" '[ -z "$(hook_json transcript_path="$TRANS" | TEAM_ROLE=w2 WOLFMUX_RUN_DIR="$RUN_W2" WOLFMUX_MODEL=glm53 teamctl _hook PostToolUse)" ]'
check "30%: memory/ctx holds the numbers" '[ "$(jq -r .tokens "$RUN_W2/memory/ctx")" = 60000 ] && [ "$(jq -r .window "$RUN_W2/memory/ctx")" = 200000 ] && [ "$(jq -r .percent "$RUN_W2/memory/ctx")" = 30 ]'

usage_line 130000 >"$TRANS"
force_through "" "$RUN_W2"
check "65%: the warn text, once" 'hook_json transcript_path="$TRANS" | TEAM_ROLE=w2 WOLFMUX_RUN_DIR="$RUN_W2" WOLFMUX_MODEL=glm53 teamctl _hook PostToolUse | grep -q "Commit what works now"'
force_through "" "$RUN_W2"
check "65% again: not repeated" '[ -z "$(hook_json transcript_path="$TRANS" | TEAM_ROLE=w2 WOLFMUX_RUN_DIR="$RUN_W2" WOLFMUX_MODEL=glm53 teamctl _hook PostToolUse)" ]'

usage_line 170000 >"$TRANS"
force_through "" "$RUN_W2"
check "85%: the rotate text, once" 'hook_json transcript_path="$TRANS" | TEAM_ROLE=w2 WOLFMUX_RUN_DIR="$RUN_W2" WOLFMUX_MODEL=glm53 teamctl _hook PostToolUse | grep -q "Do not start anything new"'
poll_bead() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do bd list --assignee "$1" --status open --include-infra --json 2>/dev/null | jq -e "$2" >/dev/null 2>&1 && return 0; sleep 0.3; done; return 1; }
check "85%: a message bead for the lead appears (polled)" 'poll_bead lead "[.[] | select(.title == \"w2: context at 85%\")] | length > 0"'

RUN_LEAD2="$WORK/run-lead2"
/bin/mkdir -p "$RUN_LEAD2"
usage_line 170000 >"$TRANS"
force_through "" "$RUN_LEAD2"
check "the lead's own hook: the text, but no bead for itself" \
  'hook_json transcript_path="$TRANS" | TEAM_ROLE=lead WOLFMUX_RUN_DIR="$RUN_LEAD2" WOLFMUX_MODEL=glm53 teamctl _hook PostToolUse | grep -q "Do not start anything new"; sleep 1; [ "$(bd list --assignee lead --status open --include-infra --json 2>/dev/null | jq "[.[] | select(.title == \"lead: context at 85%\")] | length")" = 0 ]'

RUN_W3="$WORK/run-w3"
/bin/mkdir -p "$RUN_W3"
force_through "" "$RUN_W3"
check "missing transcript: nothing said, memory/ctx never written" \
  '[ -z "$(hook_json transcript_path=/nonexistent/x.jsonl | TEAM_ROLE=w3 WOLFMUX_RUN_DIR="$RUN_W3" WOLFMUX_MODEL=glm53 teamctl _hook PostToolUse)" ] && [ ! -e "$RUN_W3/memory/ctx" ]'
{ usage_line 50000; printf '{"type":"assistant","message":{"usage":{"input_toke'; } >"$TRANS"
force_through "" "$RUN_W3"
check "a half-written last line breaks nothing: the complete one still counts" \
  'hook_json transcript_path="$TRANS" | TEAM_ROLE=w3 WOLFMUX_RUN_DIR="$RUN_W3" WOLFMUX_MODEL=glm53 teamctl _hook PostToolUse >/dev/null; [ "$(jq -r .tokens "$RUN_W3/memory/ctx")" = 50000 ]'

RUN_W4="$WORK/run-w4"
/bin/mkdir -p "$RUN_W4"
usage_line 50000 >"$TRANS" # 25%
force_through "" "$RUN_W4"
check "thresholds from the environment: warn=20 fires at 25%" \
  'hook_json transcript_path="$TRANS" | TEAM_ROLE=w4 WOLFMUX_RUN_DIR="$RUN_W4" WOLFMUX_MODEL=glm53 WOLFMUX_CONTEXT_WARN=20 WOLFMUX_CONTEXT_ROTATE=40 teamctl _hook PostToolUse | grep -q "Commit what works now"'
RUN_W5="$WORK/run-w5"
/bin/mkdir -p "$RUN_W5"
usage_line 140000 >"$TRANS" # 70%
force_through "" "$RUN_W5"
check "off disables a threshold: warn=off at 70% says nothing (rotate default is 80)" \
  '[ -z "$(hook_json transcript_path="$TRANS" | TEAM_ROLE=w5 WOLFMUX_RUN_DIR="$RUN_W5" WOLFMUX_MODEL=glm53 WOLFMUX_CONTEXT_WARN=off teamctl _hook PostToolUse)" ]'
RUN_W6="$WORK/run-w6"
/bin/mkdir -p "$RUN_W6"
usage_line 130000 >"$TRANS" # 65%
force_through "" "$RUN_W6"
check "nonsense warn=150 falls back to the default (60): warns at 65%" \
  'hook_json transcript_path="$TRANS" | TEAM_ROLE=w6 WOLFMUX_RUN_DIR="$RUN_W6" WOLFMUX_MODEL=glm53 WOLFMUX_CONTEXT_WARN=150 teamctl _hook PostToolUse | grep -q "Commit what works now"'
RUN_W7="$WORK/run-w7"
/bin/mkdir -p "$RUN_W7"
force_through "" "$RUN_W7"
check "warn >= rotate falls back to both defaults: at 65%, warn fires and rotate does not" \
  'out="$(hook_json transcript_path="$TRANS" | TEAM_ROLE=w7 WOLFMUX_RUN_DIR="$RUN_W7" WOLFMUX_MODEL=glm53 WOLFMUX_CONTEXT_WARN=90 WOLFMUX_CONTEXT_ROTATE=50 teamctl _hook PostToolUse)"; printf "%s" "$out" | grep -q "Commit what works now" && ! printf "%s" "$out" | grep -q "Do not start anything new"'

echo "== checkpoints (teamctl checkpoint, _hook PreCompact) =="
RUN_CK="$WORK/run-ck"
/bin/mkdir -p "$RUN_CK"
TASK_ID="$(bd create "a task for ck" -t task -a ck --json | jq -r .id)"
BEADS_ACTOR=ck bd update "$TASK_ID" --claim >/dev/null 2>&1
check "checkpoint: no text is a usage error (64)" 'TEAM_ROLE=ck WOLFMUX_RUN_DIR="$RUN_CK" teamctl checkpoint; [ $? -eq 64 ]'
check "checkpoint: writes the file, with a header and the text" \
  'TEAM_ROLE=ck BEADS_ACTOR=ck WOLFMUX_RUN_DIR="$RUN_CK" teamctl checkpoint "done so far: A. next: B" >/dev/null && grep -q "^role: ck" "$RUN_CK/memory/checkpoint.md" && grep -q "done so far: A" "$RUN_CK/memory/checkpoint.md"'
check "checkpoint: the in_progress task is in the header" "grep -q \"task: $TASK_ID\" \"\$RUN_CK/memory/checkpoint.md\""
poll_note() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do bd show "$1" --json 2>/dev/null | jq -e '(.[0].notes // .notes // "") | contains("checkpoint")' >/dev/null 2>&1 && return 0; sleep 0.3; done; return 1; }
check "checkpoint: noted on the in_progress task bead (polled, detached)" "poll_note \"\$TASK_ID\""
check "checkpoint: a second write keeps the first as .prev.md" \
  'TEAM_ROLE=ck BEADS_ACTOR=ck WOLFMUX_RUN_DIR="$RUN_CK" teamctl checkpoint "a second note" >/dev/null && grep -q "done so far: A" "$RUN_CK/memory/checkpoint.prev.md" && grep -q "a second note" "$RUN_CK/memory/checkpoint.md"'
check "checkpoint --show: prints the stored file" 'TEAM_ROLE=ck WOLFMUX_RUN_DIR="$RUN_CK" teamctl checkpoint --show | grep -q "a second note"'

printf '%s' "from a file" >"$WORK/body.txt"
check "--body-file: the file's content becomes the checkpoint" \
  'TEAM_ROLE=ck BEADS_ACTOR=ck WOLFMUX_RUN_DIR="$RUN_CK" teamctl checkpoint --body-file "$WORK/body.txt" >/dev/null && grep -q "from a file" "$RUN_CK/memory/checkpoint.md"'
printf '\x1b[31mEARLY\x1b[0m%s' "$(printf 'A%.0s' $(seq 1 20000))" >"$WORK/big.txt"
check "a 20k text is cut (to the 8000-char cap, plus header), escape sequences are gone" \
  'TEAM_ROLE=ck BEADS_ACTOR=ck WOLFMUX_RUN_DIR="$RUN_CK" teamctl checkpoint --body-file "$WORK/big.txt" >/dev/null
   sz="$(wc -c <"$RUN_CK/memory/checkpoint.md" | tr -d "[:space:]")"
   [ "$sz" -lt 8300 ] && grep -q EARLY "$RUN_CK/memory/checkpoint.md" && ! grep -qP "\x1b" "$RUN_CK/memory/checkpoint.md"'

check "PreCompact: creates the file when there was none, appends the automatic section" \
  '/bin/rm -f "$RUN_CK/memory/checkpoint.md"; printf "{}" | TEAM_ROLE=ck WOLFMUX_RUN_DIR="$RUN_CK" teamctl _hook PreCompact >/dev/null; grep -q "state at compaction" "$RUN_CK/memory/checkpoint.md"'
check "PreCompact: three compactions keep the agent's own text and only the newest two automatic sections, not all three" \
  'TEAM_ROLE=ck BEADS_ACTOR=ck WOLFMUX_RUN_DIR="$RUN_CK" teamctl checkpoint "OWNTEXT123" >/dev/null 2>&1
   printf "{}" | TEAM_ROLE=ck WOLFMUX_RUN_DIR="$RUN_CK" teamctl _hook PreCompact >/dev/null
   sleep 1
   printf "{}" | TEAM_ROLE=ck WOLFMUX_RUN_DIR="$RUN_CK" teamctl _hook PreCompact >/dev/null
   sleep 1
   printf "{}" | TEAM_ROLE=ck WOLFMUX_RUN_DIR="$RUN_CK" teamctl _hook PreCompact >/dev/null
   grep -q OWNTEXT123 "$RUN_CK/memory/checkpoint.md" && [ "$(grep -c "state at compaction" "$RUN_CK/memory/checkpoint.md")" = 2 ]'

TEAM_ROLE=ck BEADS_ACTOR=ck WOLFMUX_RUN_DIR="$RUN_CK" teamctl checkpoint "after compaction" >/dev/null 2>&1
check "SessionStart (resume) shows the checkpoint" \
  'hook_json source=resume | TEAM_ROLE=ck WOLFMUX_RUN_DIR="$RUN_CK" teamctl _hook SessionStart | grep -q "Where you left off"'
check "SessionStart (clear) does not: a clear is a blank slate" \
  '! (hook_json source=clear | TEAM_ROLE=ck WOLFMUX_RUN_DIR="$RUN_CK" teamctl _hook SessionStart | grep -q "Where you left off")'
touch -t 202001010000 "$RUN_CK/memory/checkpoint.md"
check "a checkpoint past WOLFMUX_CHECKPOINT_MAX_AGE_H is only mentioned, not injected" \
  'out="$(hook_json source=startup | TEAM_ROLE=ck WOLFMUX_RUN_DIR="$RUN_CK" teamctl _hook SessionStart)"; printf "%s" "$out" | grep -q "An old checkpoint exists" && ! printf "%s" "$out" | grep -q "after compaction"'

echo "== teamctl status --json: the _ctx_of_transcript refactor changes nothing it reports =="
AGENTS_DIR="$(ls -d "$WOLFMUX_DATA"/state/*/agents 2>/dev/null | head -1)"
if [ -n "$AGENTS_DIR" ]; then
  CTX_WORKDIR="$WORK/ctx-workdir"
  /bin/mkdir -p "$CTX_WORKDIR"
  jq -n --arg dir "$CTX_WORKDIR" \
    '{role: "ctxcheck", kind: "worker", model: "fable", model_id: "", label: "fable", family: "claude", billing: "subscription", launcher: "/bin/true",
      workdir: $dir, branch: "ai/ctxcheck-1", base_ref: "main", base_commit: "", kickoff: "0", spawned_by: "operator",
      permissions: "skip", pane_id: "", state: "stopped", created_at: "2099-01-01T00:00:00Z"}' >"$AGENTS_DIR/ctxcheck.json"
  CTX_TRANS_DIR="$WOLFMUX_CLAUDE_PROJECTS/$(cd "$CTX_WORKDIR" && pwd -P | sed 's|[^A-Za-z0-9]|-|g')"
  /bin/mkdir -p "$CTX_TRANS_DIR"
  {
    echo 'not json'
    usage_line 50000
    echo '{"type":"assistant","message":{"usage":{"input_tokens":80000,"cache_read_input_tokens":15000,"cache_creation_input_tokens":5000}}}'
  } >"$CTX_TRANS_DIR/no-session-id.jsonl"
  # v1.24.0 (D1): the window is v1.23.0's CONTEXT column (lib/models.sh models_running: an alias with no
  # observed model has none yet), checked by its own suites; this checks tokens and requests.
  check "status: context_tokens/requests after the refactor match the last assistant turn's usage" \
    'teamctl status --json | jq -e "[.agents[] | select(.role == \"ctxcheck\")][0] | .context_tokens == 100000 and .requests == 2"'
  /bin/rm -f "$AGENTS_DIR/ctxcheck.json"
else
  echo "  skip  status --json regression check (no agents directory was created)"
fi

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
