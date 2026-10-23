#!/bin/bash
# memory.sh — team memory (v1.22.0): policy team-memory, teamctl memory, the prompt block, the
# autoMemoryDirectory setting, the boot prompt at every launch, the worktree guard on the folder, the
# --continue refusal, destroy --purge [--memory], finish, install.sh and uninstall.sh --purge[-memory].
#
# No model is called. Claude Code is a stand-in that answers the alias probe and records how it was
# started (its argv, one JSON line per launch), then runs tests/stub-agent. The memory skeleton is a FAKE
# one in a throwaway WOLFMUX_HOME (its bin/mem handles init, boot and check), so this suite never depends
# on the real skeleton. Everything runs in a throwaway HOME, data directory, git repository and tmux server
# (socket wolfmux-test-memory-<pid>), set up and removed by this one script. Never a real team.
#
#   tests/memory.sh
# No pipefail: checks end in `grep -q`, which closes the pipe early by design.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-memory.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
export HOME="$WORK/home"
/bin/mkdir -p "$HOME"
# WOLFMUX_HOME is the repository's config/wolfmux, entry by entry, plus the fake skeleton
CONF="$WORK/conf"
/bin/mkdir -p "$CONF"
for entry in "$REPO"/config/wolfmux/*; do
  [ "$(basename "$entry")" = memory-skeleton ] || /bin/ln -s "$entry" "$CONF/$(basename "$entry")"
done
export WOLFMUX_HOME="$CONF"
export WOLFMUX_BIN_DIR="$REPO/bin"
export WOLFMUX_DATA="$WORK/data"
export WOLFMUX_TMUX_SOCKET="wolfmux-test-memory-$$" WOLFMUX_LEGACY_SOCKET="wolfmux-test-memory-old-$$"
export WOLFMUX_CLAUDE_PROJECTS="$WORK/claude-projects" WOLFMUX_CODEX_SESSIONS="$WORK/codex-sessions"
export WOLFMUX_CLAUDE_SESSIONS="$WORK/claude-sessions"
FAKE="$WORK/fake"
export FAKE
/bin/mkdir -p "$FAKE" "$WOLFMUX_CLAUDE_PROJECTS"
# The stand-in for Claude Code: `-p` is the alias probe; any other start is written down, then stub-agent.
/bin/cat >"$FAKE/claude" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-p" ]; then
  printf '{"type":"result","subtype":"success","is_error":false,"result":"ok","modelUsage":{"claude-opus-5-5":{"inputTokens":2,"contextWindow":1000000}}}\n'
  exit 0
fi
jq -cn --args '$ARGS.positional' -- "$@" >>"$FAKE/argv-${WOLFMUX_TEAM:-default}-${TEAM_ROLE:-x}"
printf '%s|%s\n' "${SHELL:-}" "${CLAUDE_CODE_SHELL:-}" >"$FAKE/shell-${WOLFMUX_TEAM:-default}-${TEAM_ROLE:-x}"
exec "$STUB_AGENT" "$@"
EOF
/bin/cat >"$FAKE/bd" <<'EOF'
#!/bin/bash
case "$1" in create) echo test-memory ;; *) echo '[]' ;; esac
EOF
/bin/chmod 755 "$FAKE/claude" "$FAKE/bd"
export PATH="$FAKE:$PATH"
export STUB_AGENT="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_FABLE="$FAKE/claude" WOLFMUX_LAUNCHER_OPUS="$FAKE/claude"
export WOLFMUX_LAUNCHER_SONNET="$FAKE/claude" WOLFMUX_LAUNCHER_HAIKU="$FAKE/claude"
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR WOLFMUX_NOTIFY WOLFMUX_SPLASH WOLFMUX_METERED TMUX TMUX_PANE MEM_ROOT
unset WOLFMUX_TEAM WOLFMUX_TEAM_ARG WOLFMUX_SESSION WOLFMUX_WORKTREE WOLFMUX_BRANCH WOLFMUX_MODEL WOLFMUX_EXTRA_SETTINGS
unset WOLFMUX_FABLE_MODEL WOLFMUX_OPUS_MODEL WOLFMUX_SONNET_MODEL WOLFMUX_HAIKU_MODEL WOLFMUX_MODEL_POLICY CLAUDE_CONFIG_DIR
unset WOLFMUX_LEAD_MODEL WOLFMUX_ORPHAN_STEWARD WOLFMUX_HUMAN_PANE_TYPING WOLFMUX_INBOX_WATCHED WOLFMUX_FAKE_PS_TABLE
# BEADS_DIR of the shell that runs this suite decided whether `teamctl finish` could ask Beads (and so take the team)
# or found "no Beads workspace" and kept it: the project below has a .beads of its own instead, and the fake bd answers.
unset BEADS_DIR
export WOLFMUX_NOTIFY=off WOLFMUX_SPLASH=off WOLFMUX_INBOX_WATCHED=""
export WOLFMUX_NOTIFY_TTY="$WORK/tty" # a notice for you lands in this file, not on a screen

# The fake skeleton: bin/mem finds its folder from its own place (MEM_ROOT wins), as the real one does.
SKEL="$CONF/memory-skeleton"
/bin/mkdir -p "$SKEL/bin" "$SKEL/core" "$SKEL/.meta"
printf '# Memory index\n' >"$SKEL/MEMORY.md"
printf 'boot steps\n' >"$SKEL/core/boot.md"
printf 'schema\n' >"$SKEL/.meta/schema.md"
/bin/cat >"$SKEL/bin/mem" <<'EOF'
#!/bin/bash
root="${MEM_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}"
case "${1:-}" in
  init) /bin/mkdir -p "$root/core" && echo init >>"$root/.inits" ;;
  boot) [ -f "$root/core/card.md" ] || printf '# Card\nwork this way\n' >"$root/core/card.md"; /bin/cat "$root/core/card.md" ;;
  check) echo "mem check: 0 problems"; exit "${FAKE_MEM_CHECK_RC:-0}" ;;
  *) exit 64 ;;
esac
EOF
/bin/chmod 755 "$SKEL/bin/mem"

teamctl() { "$REPO/tests/in-pane" "$@"; }
as_agent() { # <team> <role> <teamctl args…>: what that agent's own pane runs
  local team="$1" role="$2"
  shift 2
  TEAM_ROLE="$role" WOLFMUX_TEAM="$team" "$REPO/tests/in-pane" "$@"
}

passed=0
failed=0
check() { # <description> <command string>: in a subshell, so an exit in it fails this check, not the suite
  if (eval "$2") >"$WORK/check.out" 2>&1; then
    passed=$((passed + 1))
    printf '  pass  %s\n' "$1"
  else
    failed=$((failed + 1))
    printf '  FAIL  %s\n' "$1"
    cat "$WORK/check.out"
  fi
}
cleanup() {
  tmux -L "$WOLFMUX_TMUX_SOCKET" kill-server >/dev/null 2>&1
  /bin/rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$WOLFMUX_TMUX_SOCKET"
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT

STATE() { ls -d "$WOLFMUX_DATA"/state/*/ | head -1 | sed 's|/$||'; } # the project's state directory
record() { cat "$(STATE)/teams/$2/agents/$1.json"; }                     # <role> <team>
settings_of() { cat "$(STATE)/teams/$2/settings/$1.json"; }              # <role> <team>
last_argv() { tail -1 "$FAKE/argv-$1-$2" 2>/dev/null; }                  # <team> <role>: its latest launch
launches() { wc -l <"$FAKE/argv-$1-$2" 2>/dev/null | tr -d ' '; }
launched_after() { # <team> <role> <count before>: a new launch was recorded
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    [ "$(launches "$1" "$2")" -gt "$3" ] 2>/dev/null && return 0
    sleep 0.3
  done
  return 1
}
transcript_of() { # <role> <team>: the file of that agent's own conversation (its folder is made)
  local dir
  dir="$WOLFMUX_CLAUDE_PROJECTS/$(cd "$(record "$1" "$2" | jq -r .workdir)" && pwd -P | sed 's|[^A-Za-z0-9]|-|g')"
  /bin/mkdir -p "$dir"
  printf '%s/%s.jsonl\n' "$dir" "$(record "$1" "$2" | jq -r .session_id)"
}
# typed <answer> <command…>: run it on a terminal of its own and type <answer> when it asks for a name
typed() {
  python3 -I - "$@" <<'PY'
import os, pty, select, sys, time
answer = sys.argv[1].encode() + b"\r"
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[2], sys.argv[2:])
out, sent, t0 = b"", False, time.time()
while time.time() - t0 < 30:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
        if not sent and b"team name" in out:
            os.write(fd, answer)
            sent = True
sys.stdout.write(out.decode("utf-8", "replace"))
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
PY
}

PROJECT="$WORK/demo project" # the space is deliberate
/bin/mkdir -p "$PROJECT"
cd "$PROJECT" || exit 1
git init -q -b main
echo "hello" >README.md
git add -A
git -c user.name=memory -c user.email=memory@example.invalid commit -qm "initial commit"
/bin/mkdir -p "$PROJECT/.beads" # a Beads workspace, so finish asks the fake bd (no open task) whatever the caller's BEADS_DIR
teamctl start opus --team mem --no-attach --skip-beads >/dev/null 2>&1
teamctl start opus --team other --no-attach --skip-beads >/dev/null 2>&1
teamctl spawn w1 opus --team mem --no-kickoff >/dev/null 2>&1
KEY="$(basename "$(STATE)")"
DIR="$WOLFMUX_DATA/memory/$KEY/mem"

echo "== policy team-memory: off by default, yours alone to turn on"
check "teamctl policy lists team-memory, default off, and teamctl memory status says off" \
  'teamctl policy --team mem | grep -Eq "^  team-memory +off " && teamctl memory status | grep -q "^team-memory:  off"'
check "an agent may not set it (77): teamctl policy team-memory mem from the mem lead's own pane" \
  'as_agent mem lead policy team-memory mem; [ $? -eq 77 ] && [ ! -d "$DIR" ]'
check "  ... nor teamctl memory enable (77), and nothing was created or logged" \
  'as_agent mem lead memory enable mem; [ $? -eq 77 ] && [ ! -d "$DIR" ] && [ ! -f "$(STATE)/team-memory.jsonl" ]'
check "enable refuses a team the project does not have (64)" \
  'teamctl memory enable nosuchteam; [ $? -eq 64 ]'
OUT="$(teamctl memory enable mem 2>&1)"
check "you enable it: the policy names mem, for the whole project" \
  '[ "$(jq -r .policy_team_memory "$(STATE)/policy.json")" = mem ] && teamctl policy --team other | grep -Eq "^  team-memory +mem "'
check "  ... the folder is created mode 700 from the installed skeleton: files 600, bin/mem 700, mem init ran" \
  '[ "$(stat -f %Lp "$DIR")" = 700 ] && [ "$(stat -f %Lp "$DIR/MEMORY.md")" = 600 ] && [ "$(stat -f %Lp "$DIR/core/boot.md")" = 600 ] &&
   [ "$(stat -f %Lp "$DIR/bin/mem")" = 700 ] && [ "$(stat -f %Lp "$WOLFMUX_DATA/memory")" = 700 ] && grep -q init "$DIR/.inits"'
check "  ... and it is logged: team-memory.jsonl and the event log" \
  'jq -e "select(.action == \"enable\" and .team == \"mem\" and .previous == \"off\" and .by == \"operator\")" "$(STATE)/team-memory.jsonl" &&
   grep -q "team-memory=mem" "$(STATE)/events.jsonl"'
echo "my note" >"$DIR/MEMORY.md"
teamctl memory enable mem >/dev/null 2>&1
check "enable again: the existing folder is kept, never overwritten (mem init runs again, it is idempotent)" \
  '[ "$(cat "$DIR/MEMORY.md")" = "my note" ] && [ "$(grep -c init "$DIR/.inits")" = 2 ]'
check "teamctl memory path prints the folder" '[ "$(teamctl memory path)" = "$DIR" ]'

echo "== the prompt block, the setting and the boot prompt: the mem lead, nobody else"
check "teamctl _prompt lead --team mem carries the Team memory block: folder, rule, shared folder, boot line" \
  'P="$(teamctl _prompt lead --team mem)" && printf "%s" "$P" | grep -q "^## Team memory" && printf "%s" "$P" | grep -qF "$DIR" &&
   printf "%s" "$P" | grep -q "Never copy its contents into Beads, Jira, Slack" && printf "%s" "$P" | grep -qF "$WOLFMUX_CLAUDE_PROJECTS/" &&
   printf "%s" "$P" | grep -qF "Run \`$DIR/bin/mem boot\` before anything else, and again after every compaction. The card wins over a re-sent handover on HOW to work; the handover is a task."'
check "  ... the shared project memory folder is Claude Code's own name for the project folder" \
  'teamctl _prompt lead --team mem | grep -qF "$WOLFMUX_CLAUDE_PROJECTS/$(printf "%s" "$PROJECT" | sed "s|[^A-Za-z0-9]|-|g")/memory/"'
check "the other team's lead and the mem team's worker get no block" \
  '! teamctl _prompt lead --team other | grep -q "^## Team memory" && ! teamctl _prompt w1 --team mem | grep -q "^## Team memory"'
/bin/chmod 600 "$DIR/bin/mem"
check "no runnable bin/mem in the folder (missing, or edited by hand): no block" \
  '! teamctl _prompt lead --team mem | grep -q "^## Team memory"'
/bin/chmod 700 "$DIR/bin/mem"
BEFORE="$(launches mem lead)"
teamctl restart lead --team mem >/dev/null 2>&1
check "a fresh restart of the mem lead: its first prompt is the boot" \
  'launched_after mem lead "$BEFORE" && last_argv mem lead | jq -e --arg d "$DIR" ".[-1] == (\"Team memory is on. Run \" + \$d + \"/bin/mem boot, read what it prints, re-create the crons it lists, then read your Beads inboxes.\")"'
check "  ... and its settings carry autoMemoryDirectory = the folder" \
  '[ "$(settings_of lead mem | jq -r .autoMemoryDirectory)" = "$DIR" ]'
teamctl restart w1 --team mem >/dev/null 2>&1
BEFORE="$(launches other lead)"
teamctl restart lead --team other >/dev/null 2>&1
check "nobody else has the setting: the other lead, the mem team's worker" \
  'launched_after other lead "$BEFORE" && settings_of lead other | jq -e "has(\"autoMemoryDirectory\") | not" && settings_of w1 mem | jq -e "has(\"autoMemoryDirectory\") | not"'
check "  ... nor the boot prompt" \
  '! last_argv other lead | grep -q "Team memory is on" && ! last_argv mem w1 | grep -q "Team memory is on"'
: >"$(transcript_of lead mem)"
BEFORE="$(launches mem lead)"
teamctl restart lead --team mem --continue >/dev/null 2>&1
check "a resumed launch (--continue, its own id): --resume <id>, and the boot prompt again" \
  'launched_after mem lead "$BEFORE" && last_argv mem lead | jq -e --arg id "$(record lead mem | jq -r .session_id)" \
     "(index(\"--resume\") as \$i | .[\$i + 1] == \$id) and (.[-1] | startswith(\"Team memory is on. Run \"))"'

echo "== --continue with no stored conversation id"
jq '.session_id = ""' "$(STATE)/teams/mem/agents/lead.json" >"$WORK/r" && cat "$WORK/r" >"$(STATE)/teams/mem/agents/lead.json"
jq '.lead_session = ""' "$(STATE)/teams/mem/meta.json" >"$WORK/m" && cat "$WORK/m" >"$(STATE)/teams/mem/meta.json"
BEFORE="$(launches mem lead)"
OUT="$(teamctl restart lead --team mem --continue 2>&1)"
check "refused for the mem lead: claude --continue would open the newest conversation of the shared folder" \
  '! teamctl restart lead --team mem --continue >/dev/null 2>&1 && printf "%s" "$OUT" | grep -q "no stored conversation id" && sleep 1 && [ "$(launches mem lead)" = "$BEFORE" ]'
# The last stop is the pane's own `_run-agent … --continue` (a pane run again by hand). Should it ever not refuse,
# it would exec the stand-in, which never exits: in the background, killed after a few seconds.
WOLFMUX_TEAM=mem "$REPO/bin/teamctl" _run-agent "$PROJECT" lead --continue >"$WORK/run-agent.out" 2>&1 &
PID=$!
for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
if kill -0 "$PID" 2>/dev/null; then kill "$PID" 2>/dev/null; echo killed >>"$WORK/run-agent.out"; fi
wait "$PID" 2>/dev/null
check "  ... and by _run-agent itself, the last stop before the CLI: it ends with the reason and launches nothing" \
  'grep -q "no stored conversation id" "$WORK/run-agent.out" && ! grep -q killed "$WORK/run-agent.out" && [ "$(launches mem lead)" = "$BEFORE" ] && [ ! -f "$FAKE/argv-mem-x" ]'
tmux -L "$WOLFMUX_TMUX_SOCKET" kill-session -t "=$(jq -r .session "$(STATE)/teams/mem/meta.json")" >/dev/null 2>&1
check "  ... and as teamctl start --continue too (no session)" \
  '! teamctl start opus --team mem --continue --no-attach --skip-beads >/dev/null 2>&1 && [ "$(launches mem lead)" = "$BEFORE" ]'
teamctl start opus --team mem --no-attach --skip-beads --handover demo-abc1 >/dev/null 2>&1
check "a fresh start with a handover: one first prompt, the boot first, then the handover" \
  'launched_after mem lead "$BEFORE" && last_argv mem lead | jq -e ".[-1] | startswith(\"Team memory is on. Run \") and contains(\" After that, your handover: \") and contains(\"bd show demo-abc1\")"'
# A crash, not a stop: the record and the snapshot survive, and teamctl restore brings the team back (tests/lead-model.sh)
printf '#!/bin/bash\necho "System-wide memory free percentage: 80%%"\n' >"$FAKE/memory_pressure"
/bin/chmod 755 "$FAKE/memory_pressure"
SID="$(record lead mem | jq -r .session_id)"
: >"$(transcript_of lead mem)"
jq -cn --arg key "$KEY" --arg root "$(jq -r .root "$(STATE)/teams/mem/meta.json")" --arg session "$(jq -r .session "$(STATE)/teams/mem/meta.json")" --arg sid "$SID" \
  '{epoch:100,ts:"2026-01-01T00:00:00Z",server:"old-server 1",tabs:[],
    teams:[{key:$key,team:"mem",root:$root,session:$session,model:"opus",family:"claude",label:"Opus",session_id:$sid,founder:"operator"}]}' >"$WOLFMUX_DATA/state/running.json"
tmux -L "$WOLFMUX_TMUX_SOCKET" kill-session -t "=$(jq -r .session "$(STATE)/teams/mem/meta.json")" >/dev/null 2>&1
BEFORE="$(launches mem lead)"
WOLFMUX_RESTORE_TEAMCTL="$REPO/bin/teamctl" WOLFMUX_MEMORY_PRESSURE="$FAKE/memory_pressure" WOLFMUX_RESTORE_LOAD=1 WOLFMUX_RESTORE_WAIT_MAX=0 \
  WOLFMUX_RESTORE_UP_MAX=10 WOLFMUX_RESTORE_POLL=1 WOLFMUX_RESTORE_LIMIT_WAIT=0 teamctl restore --yes --no-tabs >"$WORK/restore.out" 2>&1
check "teamctl restore after a crash: the lead resumes its own conversation, and its first prompt is the boot (no handover again)" \
  'launched_after mem lead "$BEFORE" && last_argv mem lead | jq -e --arg id "$SID" "(index(\"--resume\") as \$i | .[\$i + 1] == \$id) and (.[-1] | startswith(\"Team memory is on. Run \")) and (.[-1] | contains(\"handover\") | not)" ||
   { cat "$WORK/restore.out"; exit 1; }'
teamctl restart w1 --team mem >/dev/null 2>&1
jq '.session_id = ""' "$(STATE)/teams/other/agents/lead.json" >"$WORK/r" && cat "$WORK/r" >"$(STATE)/teams/other/agents/lead.json"
BEFORE="$(launches other lead)"
OUT="$(teamctl restart lead --team other --continue 2>&1)"
check "while team memory is on, the other team's lead is refused too: its --continue could open the mem lead's conversation" \
  '! teamctl restart lead --team other --continue >/dev/null 2>&1 && printf "%s" "$OUT" | grep -q "no stored conversation id" &&
   printf "%s" "$OUT" | grep -q "team '\''mem'\'' keeps it" && sleep 1 && [ "$(launches other lead)" = "$BEFORE" ]'

echo "== teamctl memory status and check"
printf '%04000d\n' 0 >>"$DIR/MEMORY.md"
OUT="$(teamctl memory status 2>&1)"
check "status names the policy, the folder, the index against its 25000-byte cap, the card, the lead and the restart rule" \
  'for f in "^team-memory:  mem" "^folder: .*files" "^index: .*MEMORY.md [0-9]+ of 25000 bytes" "^card: " "^lead: .*running" "^note: .*next restart"; do
     printf "%s\n" "$OUT" | grep -Eq "$f" || { echo "missing: $f"; exit 1; }; done'
check "  ... says the running lead was started WITH the setting" 'printf "%s" "$OUT" | grep -q "WITH the setting"'
ID="$(record lead mem | jq -r .session_id)"
printf '9001\t1\tclaude --resume %s\n9002\t1\tclaude --resume %s\n' "$ID" "$ID" >"$WORK/ps-table"
check "  ... warns when two processes carry the lead's conversation id" \
  'WOLFMUX_PS_BIN="$REPO/tests/fake-ps" WOLFMUX_FAKE_PS_TABLE="$WORK/ps-table" teamctl memory status 2>&1 | grep -q "2 lead sessions of team mem are alive"'
cp "$(STATE)/teams/mem/agents/lead.json" "$WORK/lead.json"
jq '.family = "codex"' "$WORK/lead.json" >"$(STATE)/teams/mem/agents/lead.json"
check "  ... warns when the lead runs Codex (no autoMemoryDirectory; resume --last opens the shared folder's newest)" \
  'teamctl memory status 2>&1 | grep -q "the lead of mem runs Codex"'
cat "$WORK/lead.json" >"$(STATE)/teams/mem/agents/lead.json"
check "teamctl memory check runs mem check and passes its exit code" \
  'teamctl memory check | grep -q "0 problems" && { FAKE_MEM_CHECK_RC=1 teamctl memory check >/dev/null 2>&1; [ $? -eq 1 ]; }'
check "check (it writes, and prints names) and path are the owner's: a worker and the other team's lead get 77" \
  'for who in "mem w1" "other lead"; do for c in check path; do as_agent $who memory $c >"$WORK/o" 2>&1; [ $? -eq 77 ] && ! grep -qF "$DIR" "$WORK/o" || { echo "not refused: $who memory $c"; exit 1; }; done; done'
check "  ... the mem lead runs both: path is the folder, check passes on mem check's answer" \
  '[ "$(as_agent mem lead memory path)" = "$DIR" ] && as_agent mem lead memory check | grep -q "0 problems"'
check "  ... status stays open to anyone: sizes and counts, never what a note says" \
  'as_agent mem w1 memory status >"$WORK/o" 2>&1 && grep -q "^team-memory:  mem" "$WORK/o" && ! grep -q "my note" "$WORK/o"'

echo "== teamctl capture of the mem lead's pane is yours alone (mem boot prints the card there)"
check "a worker and the other team's lead get 77 for that pane" \
  'as_agent mem w1 capture lead >"$WORK/o" 2>&1; [ $? -eq 77 ] && grep -q "private team memory" "$WORK/o" &&
   as_agent other lead capture lead --team mem >"$WORK/o" 2>&1; [ $? -eq 77 ] && grep -q "private team memory" "$WORK/o"'
check "  ... you capture it, and the mem lead still captures its worker" \
  'teamctl capture lead --team mem >/dev/null && as_agent mem lead capture w1 >/dev/null'

echo "== the card is never in the prompt (ps and teamctl _prompt show a prompt to anyone)"
printf '# Card\nCARD-MARKER-7f3e work this way\n' >"$DIR/core/card.md"
echo "INDEX-MARKER-91c2" >>"$DIR/MEMORY.md"
check "the block holds no card body and nothing else of the folder: the planted markers are absent from the prompt" \
  'P="$(teamctl _prompt lead --team mem)" && printf "%s" "$P" | grep -q "^## Team memory" && ! printf "%s" "$P" | grep -q "CARD-MARKER-7f3e" &&
   ! printf "%s" "$P" | grep -q "INDEX-MARKER-91c2" && ! printf "%s" "$P" | grep -qi "card truncated"'
check "  ... nor in the argv of the lead's launch (what ps shows)" \
  'BEFORE="$(launches mem lead)" && teamctl restart lead --team mem >/dev/null 2>&1 && launched_after mem lead "$BEFORE" && last_argv mem lead | grep -q "Team memory is ON for team mem" && ! last_argv mem lead | grep -q "CARD-MARKER-7f3e"'
check "  ... and status no longer compares the prompt with the card" \
  'touch "$DIR/core/card.md" && ! teamctl memory status 2>&1 | grep -q "older than core/card.md"'

echo "== the worktree guard keeps workers out of the folder"
W1="$(record w1 mem | jq -r .workdir)"
guard() { # <tool> <tool_input json> [<data dir>] [<cwd>]: the decision for worker w1
  local answer
  answer="$(jq -cn --arg tool "$1" --argjson input "$2" --arg cwd "${4:-$W1}" '{hook_event_name: "PreToolUse", tool_name: $tool, tool_input: $input, cwd: $cwd}' |
    WOLFMUX_DATA="${3:-$WOLFMUX_DATA}" TEAM_ROLE=w1 WOLFMUX_TEAM=mem WOLFMUX_ROOT="$PROJECT" WOLFMUX_WORKTREE="$W1" WOLFMUX_BRANCH="$(record w1 mem | jq -r .branch)" "$REPO/bin/teamctl" _guard)"
  if printf '%s' "$answer" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then echo deny; else echo allow; fi
}
sh() { jq -cn --arg c "$1" '{command: $c}'; }
file() { jq -cn --arg p "$1" '{file_path: $p}'; } # helpers instead of nested \"quotes\": bash 3.2 misreads those inside $( )
search() { jq -cn --arg p "$1" '{pattern: "x", path: $p}'; }
check "a worker's Read of the folder and of a file in it is denied" \
  '[ "$(guard Read "$(file "$DIR/MEMORY.md")")" = deny ] && [ "$(guard Grep "$(search "$DIR")")" = deny ] && [ "$(guard Glob "$(search "$WOLFMUX_DATA")")" = deny ]'
check "  ... a Write into it is denied too" \
  '[ "$(guard Write "$(file "$DIR/core/x.md")")" = deny ] && [ "$(guard Edit "$(file "$DIR/MEMORY.md")")" = deny ]'
check "a Bash read that spells the path out is denied (no .wolfmux in it: the path itself is the token)" \
  '[ "$(guard Bash "$(sh "cat \"$DIR/MEMORY.md\"")")" = deny ] && [ "$(guard Bash "$(sh "ls $WOLFMUX_DATA/memory")")" = deny ]'
/bin/mkdir -p "$HOME/hdata/memory/p/t"
check "a ~-spelled and a \$HOME-spelled Bash read are denied (~ and \$HOME are expanded first)" \
  '[ "$(guard Bash "$(sh "cat ~/hdata/memory/p/t/MEMORY.md")" "$HOME/hdata")" = deny ] && [ "$(guard Bash "$(sh "cat \$HOME/hdata/memory/p/t/MEMORY.md")" "$HOME/hdata")" = deny ] &&
   [ "$(guard Bash "$(sh "cat \"\${HOME}/hdata/memory/x\"")" "$HOME/hdata")" = deny ]'
check "  ... the same expansion closes ~/ and \$HOME spellings of teamctl's state" \
  '[ "$(guard Bash "$(sh "cat ~/hdata/state/x.json")" "$HOME/hdata")" = deny ] && [ "$(guard Bash "$(sh "cat \"\$HOME/hdata/state/x.json\"")" "$HOME/hdata")" = deny ]'
check "a command that names .wolfmux/memory is denied, quoted or not; prose that only mentions it (a commit message) passes" \
  '[ "$(guard Bash "$(sh "echo hi; cat x/.wolfmux/memory/y")")" = deny ] && [ "$(guard Bash "$(sh "cat ~/.wolfmux/memory/x")")" = deny ] &&
   [ "$(guard Bash "$(sh "cat \"x/.wolfmux/memory/y\"")")" = deny ] && [ "$(guard Bash "$(sh "cat '\''~/.wolfmux/memory/x'\''")")" = deny ] &&
   [ "$(guard Bash "$(sh "git commit -m \"docs: mention .wolfmux/memory\"")")" = allow ] && [ "$(guard Bash "$(sh "bd comment x-1 \"the folder is .wolfmux/memory\"")")" = allow ] &&
   [ "$(guard Bash "$(printf "cat >notes.md <<EOF\nsee .wolfmux/memory/x\nEOF\n" | jq -Rsc "{command: .}")")" = allow ]'
pat() { jq -cn --arg p "$1" '{pattern: $p}'; }
pat_in() { jq -cn --arg p "$1" --arg d "$2" '{pattern: $p, path: $d}'; }
at() { jq -cn --arg p "$1" '{path: $p}'; }
# denied_all / allowed_all <command>…: every Bash command gets that decision (the lists are arrays, built below
# with ordinary quoting: inside a check's eval'd string, nested quotes are hard to read)
denied_all() {
  local c
  for c in "$@"; do [ "$(guard Bash "$(sh "$c")")" = deny ] || { echo "allowed: $c" && return 1; }; done
}
allowed_all() {
  local c
  for c in "$@"; do [ "$(guard Bash "$(sh "$c")")" = allow ] || { echo "denied: $c" && return 1; }; done
}
check "letter case and /./ do not slip past: ~/HDATA/MEMORY, \$HOME/HDATA/Memory and ~/hdata/./memory are the folder" \
  '[ "$(guard Bash "$(sh "cat ~/HDATA/MEMORY/p/t/MEMORY.md")" "$HOME/hdata")" = deny ] && [ "$(guard Read "$(file "$HOME/HDATA/Memory/p/t/MEMORY.md")" "$HOME/hdata")" = deny ] &&
   [ "$(guard Bash "$(sh "cat ~/hdata/./memory/p/t/MEMORY.md")" "$HOME/hdata")" = deny ] && [ "$(guard Read "$(file "$HOME/hdata/./memory/p/t/MEMORY.md")" "$HOME/hdata")" = deny ]'
check "an absolute Glob pattern is its own target: one into the folder, and ~/**, are denied" \
  '[ "$(guard Glob "$(pat "$HOME/hdata/memory/**/*.md")" "$HOME/hdata")" = deny ] && [ "$(guard Glob "$(pat "~/**/*.md")" "$HOME/hdata")" = deny ] &&
   [ "$(guard Glob "$(pat "$W1/**/*.sh")" "$HOME/hdata")" = allow ]'
check "a search of a whole tree that holds the folder is denied: grep -r, rg, find, ls -R, du, tar of ~ or of /" \
  'for c in "grep -r x ~" "grep -rn x ~/hdata/" "rg x ~" "find / -name x" "find ~ -name x" "ls -R ~" "du -sh ~/hdata" "tar czf /tmp/x.tgz ~" "sudo grep -R x \"\$HOME\""; do
     [ "$(guard Bash "$(sh "$c")" "$HOME/hdata")" = deny ] || { echo "allowed: $c"; exit 1; }; done'
check "  ... a search of a narrower folder, a plain listing of ~ and the same words in a commit message pass" \
  'for c in "grep -rn TODO ." "find . -name \"*.sh\"" "ls -la ~" "du -sh ~/Documents" "grep secret ~/notes.txt" "git commit -m \"grep -r x ~\""; do
     [ "$(guard Bash "$(sh "$c")" "$HOME/hdata")" = allow ] || { echo "denied: $c"; exit 1; }; done'
TRANSCRIPT="$(transcript_of lead mem)"
TDIR="$(dirname "$TRANSCRIPT")"
check "the leads' conversation folder is closed to workers: Read of the mem lead's transcript, Grep of the folder, a Write into it" \
  '[ "$(guard Read "$(file "$TRANSCRIPT")")" = deny ] && [ "$(guard Grep "$(search "$TDIR")")" = deny ] && [ "$(guard Write "$(file "$TDIR/x.jsonl")")" = deny ]'
check "  ... and a Grep of a folder that holds it (as ~/.claude holds projects/), and a Bash command that spells it" \
  '[ "$(guard Grep "$(search "$WOLFMUX_CLAUDE_PROJECTS")")" = deny ] && [ "$(guard Grep "$(search "$WORK")")" = deny ] &&
   [ "$(guard Bash "$(sh "cat $TDIR/x.jsonl")")" = deny ] && [ "$(guard Bash "$(sh "tail -5 \"$TRANSCRIPT\"")")" = deny ]'
check "  ... its memory/ (Claude Code's shared project memory) stays open to them" \
  '[ "$(guard Read "$(file "$TDIR/memory/MEMORY.md")")" = allow ] && [ "$(guard Bash "$(sh "cat $TDIR/memory/MEMORY.md")")" = allow ]'
# Review round 3: what sh -c and eval run, paths that climb, a dropped identity, Claude Code's own records,
# grep's pattern, wildcards and ~user, and the folder a cd moves to (GUARD_SCAN in lib/guard.sh)
MEM="$DIR/MEMORY.md"
UP="../../../../.." # from W1 (worktrees/<key>/teams/mem/<lane>) up to the data directory
/bin/mkdir -p "$HOME/.claude/file-history/abc" "$HOME/.claude/todos" "$HOME/.claude/paste-cache" "$HOME/Documents"
INNER_DENY=("bash -c \"cat $MEM\"" "sh -c 'cat ~/.wolfmux/memory/x'" "zsh -c 'cat $MEM'" "dash -lc 'cat ~/.wolfmux/memory/x'"
  "bash -ic 'cat $MEM'" "eval \"cat $MEM\"" "eval 'cat' '$MEM'" "bash -c 'bash -c \"cat $MEM\"'" "bash -c 'tmux capture-pane -p'"
  "$(printf 'bash <<EOF\ncat %s\nEOF' "$MEM")" "bash <<< 'cat $MEM'" "sh -c 'sh -c \"sh -c \\\"sh -c ls\\\"\"'")
INNER_ALLOW=("bash -c 'npm test'" 'sh -c "git status && ls src"' 'eval "$(ssh-agent -s)"' "bash tests/memory.sh")
check "R1: the text sh -c, bash -lc, zsh -c, eval, a here-string or a heredoc runs is a command (three levels deep at most)" \
  'denied_all "${INNER_DENY[@]}" && allowed_all "${INNER_ALLOW[@]}"'
CLIMB_DENY=("cat $UP/memory/$KEY/mem/MEMORY.md" "grep -r x $UP" "cat ../other-lane/README.md" "cat $W1/$UP/memory/$KEY/mem/MEMORY.md"
  "cat $TDIR/memory/../x.jsonl" "cat $TDIR/memory/..")
CLIMB_ALLOW=("cat ./README.md ../$(basename "$W1")/README.md" "git log main..HEAD && git diff HEAD~3..HEAD" "cd src && cat ../README.md")
check "R2: a word that climbs (..) is the path it climbs to; ./x and main..HEAD are what they look like" \
  'denied_all "${CLIMB_DENY[@]}" && allowed_all "${CLIMB_ALLOW[@]}"'
check "  ... a relative Glob pattern that climbs is refused, from the cwd or from its path; one that stays home is not" \
  '[ "$(guard Glob "$(pat "$UP/memory/**/*.md")")" = deny ] && [ "$(guard Glob "$(pat_in "../../memory/**" "$W1/../../..")")" = deny ] &&
   [ "$(guard Glob "$(pat "src/**/*.sh")")" = allow ] && [ "$(guard Glob "$(pat "../$(basename "$W1")/src/*.sh")")" = allow ]'
check "  ... and a shell that runs inside the memory folder is refused whatever it says" \
  '[ "$(guard Bash "$(sh "cat MEMORY.md")" "" "$DIR")" = deny ] && [ "$(guard Bash "$(sh "ls")" "" "$TDIR")" = deny ]'
IDENTITY_DENY=("env -u TMUX_PANE -u TEAM_ROLE teamctl capture lead --team mem" "env -i PATH=/usr/bin teamctl memory path"
  "unset TEAM_ROLE; teamctl memory check" "unset -v FOO TMUX_PANE && teamctl status" "TEAM_ROLE= teamctl memory path"
  "TMUX_PANE=%9 teamctl capture lead" "export WOLFMUX_TEAM=other; teamctl status" "export -n BEADS_ACTOR; bd list" "env - teamctl status"
  "/opt/homebrew/bin/tmux capture-pane -p -t %1" "'tmux' capture-pane -p" '"tmux" list-panes' '"/opt/homebrew/bin/tmux" ls' '\tmux ls')
IDENTITY_ALLOW=("env LC_ALL=C grep -i foo src/x" 'echo "$TEAM_ROLE" && teamctl status' 'git commit -m "unset TEAM_ROLE is refused now"'
  'git commit -m "fix: the tmux rule"' "cat ~/.config/tmux/tmux.conf")
check "R3: a command that drops or rewrites TEAM_ROLE, TMUX_PANE, WOLFMUX_TEAM or BEADS_ACTOR is refused; so is tmux by path or in quotes" \
  'denied_all "${IDENTITY_DENY[@]}" && allowed_all "${IDENTITY_ALLOW[@]}"'
check "R4: Claude Code's file-history, todos and paste-cache are closed to Read, Grep, LS, Write, Glob, MCP and Bash" \
  '[ "$(guard Read "$(file "$HOME/.claude/file-history/abc/x@v1")")" = deny ] && [ "$(guard Grep "$(search "$HOME/.claude/todos")")" = deny ] &&
   [ "$(guard LS "$(at "$HOME/.claude/paste-cache")")" = deny ] && [ "$(guard Write "$(file "$HOME/.claude/file-history/abc/y")")" = deny ] &&
   [ "$(guard Glob "$(pat "$HOME/.claude/file-history/**")")" = deny ] && [ "$(guard mcp__fs__read "$(at "$HOME/.claude/todos/a.json")")" = deny ] &&
   denied_all "cat ~/.claude/file-history/abc/x@v1" "ls \$HOME/.claude/paste-cache" "grep -r x ~/.claude" &&
   [ "$(guard Write "$(file "$HOME/.claude/settings-note.md")")" = allow ]'
check "  ... under CLAUDE_CONFIG_DIR too" \
  '/bin/mkdir -p "$WORK/ccfg/file-history" && [ "$(CLAUDE_CONFIG_DIR="$WORK/ccfg" guard Read "$(file "$WORK/ccfg/file-history/abc/x")")" = deny ] &&
   [ "$(CLAUDE_CONFIG_DIR="$WORK/ccfg" guard Bash "$(sh "cat $WORK/ccfg/todos/a.json")")" = deny ]'
PATTERN_ALLOW=('grep -rn "/Users/" src/' 'rg "$HOME" .' 'grep -rn "/" .' 'grep -rn -A 3 "/" src')
PATTERN_DENY=('grep -rn "TODO" ~' "grep -r -e x ~" "rg -e x ~/.claude" "rg --files ~")
check "R8: grep's and rg's pattern is not a folder, unless -e, -f or --files says the pattern is elsewhere" \
  'allowed_all "${PATTERN_ALLOW[@]}" && denied_all "${PATTERN_DENY[@]}"'
WILD_DENY=("cat ~/.claude/file-hist*/abc/x" "cat $WOLFMUX_DATA/mem*/$KEY/mem/MEMORY.md" "cat $WOLFMUX_DATA/*/$KEY/mem/MEMORY.md" "grep -r x ~/.*" "ls ~/*"
  "cat ~${USER:-me}/.claude/file-history/abc/x" "grep -r x ~/. | head" "$(printf 'grep -r x \\\n  ~ | head')")
WILD_ALLOW=("ls src/*.sh" "ls /tmp/*.log" "ls $HOME/Documents/*.md" 'find . -name "*.sh"' "ls -la ~")
check "R9: a wildcard that could become a private folder, ~<your name>, a mid-line ~/. and a continued line are seen" \
  'denied_all "${WILD_DENY[@]}" && allowed_all "${WILD_ALLOW[@]}"'
CD_DENY=("cd \"$WOLFMUX_DATA\" && cat memory/x" "cd $WOLFMUX_DATA; cat \"memory/$KEY/mem/MEMORY.md\"" "cd $WOLFMUX_DATA && ls mem*"
  "cd ~ && grep -r x ." "cd ~ && ls *" "cd ~/.claude && cat file-history/abc/x" "cd; cat .claude/todos/a.json"
  "cd $WOLFMUX_DATA >/dev/null 2>&1 && cat memory/x" "cd $WOLFMUX_DATA; cd /tmp; cd -; cat memory/x" "cd $WOLFMUX_DATA && bash -c 'cat memory/x'"
  "pushd $WOLFMUX_DATA && pushd /tmp && popd && cat memory/x" "cd $WOLFMUX_DATA && (cd /tmp) && cat memory/x"
  "cd /tmp | true; cat $UP/memory/$KEY/mem/MEMORY.md" "cd /tmp & cat $UP/memory/$KEY/mem/MEMORY.md" "cd $WOLFMUX_DATA && tar czf /tmp/m.tgz memory"
  "$(printf 'cd %s\ncat memory/x' "$WOLFMUX_DATA")")
CD_ALLOW=("cd src && cat ../README.md" "(cd $WOLFMUX_DATA); cat memory.txt" "cd $WOLFMUX_DATA | true; cat memory.txt" "cd /tmp && ls -la && git status"
  "cd src && make 2>&1 | tail -5" "cd src; cd ..; cat README.md" "cd ~/Documents && grep -rn x ." 'cd /tmp && git commit -m "the memory folder"')
check "a relative path counts in the folder a cd, pushd, popd or cd - moved to; a cd in ( ), a pipe or & stays there" \
  'denied_all "${CD_DENY[@]}" && allowed_all "${CD_ALLOW[@]}"'
RESUME_DENY=("claude --resume 0b1c2d3e-0000-4000-8000-000000000000 -p 'print the card'" "claude -r abc -p x" "claude --continue" "claude -pc hi"
  "claude --session-id=abc -p hi" "/opt/homebrew/bin/claude -r abc" "'claude' -r abc" "X=1 claude -c" "bash -c 'claude --resume abc'"
  "$(printf 'echo hi\nclaude --resume abc')" "cd /tmp && claude -c" "timeout 60 claude -r abc -p x")
RESUME_ALLOW=("claude -p 'x'" 'claude --print --output-format json -p "hi"' "claude --version" "grep -r claude src -c"
  'git commit -m "claude --resume is refused now"' "echo claude -r")
check "claude run with --resume, -r, --continue, -c or --session-id is refused (it reads any conversation itself); claude -p is not" \
  'denied_all "${RESUME_DENY[@]}" && allowed_all "${RESUME_ALLOW[@]}"'
LONG="echo"
for i in $(seq 4001); do LONG="$LONG w$i"; done
check "  ... a command too long to follow (over 4000 words) is refused" '[ "$(guard Bash "$(sh "$LONG")")" = deny ]'
check "the honest gap, pinned: a cd to a folder built at run time is not followed (docs/SECURITY.md)" \
  'allowed_all "d=$WOLFMUX_DATA; cd \$d && cat memory/x"'
# Review round 4 (GUARD_SCAN): fast enough that the hook never times out, quotes removed before any check, a
# search pattern is no path, links followed, Claude Code's sessions, history and temporary folder closed
export WOLFMUX_CLAUDE_TMP="$WORK/ctmp" # Claude Code's temporary folder, for this suite (lib/guard.sh)
SCRATCH="$WOLFMUX_CLAUDE_TMP/$(printf '%s' "$W1" | LC_ALL=C sed 's|[^A-Za-z0-9]|-|g')"
/bin/mkdir -p "$SCRATCH/s1/scratchpad" "$WOLFMUX_CLAUDE_TMP/-lead-project/s2/tasks" "$HOME/.claude/sessions" "$HOME/.claude/session-env"
timed() { # <limit ms> <allow|deny> <command>: teamctl _guard decides so, in under <limit> ms (perl Time::HiRes)
  local input branch t0 t1 got=allow
  input="$(jq -cn --arg c "$3" --arg cwd "$W1" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: $cwd}')"
  branch="$(record w1 mem | jq -r .branch)"
  t0="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
  if printf '%s' "$input" | TEAM_ROLE=w1 WOLFMUX_TEAM=mem WOLFMUX_ROOT="$PROJECT" WOLFMUX_WORKTREE="$W1" WOLFMUX_BRANCH="$branch" "$REPO/bin/teamctl" _guard | grep -q '"deny"'; then got=deny; fi
  t1="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
  [ "$got" = "$2" ] && [ $((t1 - t0)) -lt "$1" ] || { printf '%s in %s ms (%s bytes): %s\n' "$got" $((t1 - t0)) "${#3}" "$3" | head -1 | cut -c1-160 && return 1; }
}
B1="cat $MEM; cd /tmp; cd /usr; cd /var; cd /etc; sh -c 'ls"
P99="prettier --write" P101="prettier --write"
for i in $(seq 101); do
  P101="$P101 ./a$i"
  if [ "$i" -le 99 ]; then B1="$B1 x/../f$i" P99="$P99 ./src/a$i.ts"; fi
done
B1="$B1'"
check "G1: the review's B1 command is refused in under 2 s, 99 paths in the worktree pass in under 1 s, git status in under 0.3 s" \
  'timed 2000 deny "$B1" && timed 1000 allow "$P99" && timed 300 allow "git status"'
# Review round 5 (H1): the size is capped before any work, and every step after it is linear in the command
HD60="$(awk 'BEGIN { print "cat > out.txt <<\047EOF\047"; for (i = 0; i < 6000; i++) print "some data"; printf "EOF" }')"
W60="echo $(awk 'BEGIN { for (i = 0; i < 60000; i++) printf "A" }')"
W65="echo $(awk 'BEGIN { for (i = 0; i < 66000; i++) printf "A" }')"
HD400="$(awk 'BEGIN { print "cat > out.txt <<\047EOF\047"; for (i = 0; i < 200000; i++) print "x"; printf "EOF" }')"
check "H1: a 60 KB heredoc and one 60 KB word pass in under 0.5 s; 65 KB and a 400 KB heredoc are refused at once (under 0.3 s)" \
  'timed 500 allow "$HD60" && timed 500 allow "$W60" && timed 300 deny "$W65" && timed 300 deny "$HD400"'
check "H2: a worker runs its Bash tool in bash (SHELL and CLAUDE_CODE_SHELL are /bin/bash at its launch); a lead keeps its own shell" \
  '[ "$(cat "$FAKE/shell-mem-w1")" = "/bin/bash|/bin/bash" ] && case "$(cat "$FAKE/shell-mem-lead")" in *"|") true ;; *) false ;; esac'
R5_ZSH=("cat ~/.wolfmux/(memory|x)/x" "cat ~/.wolfmux/mem(|)ory/x" "cat ~/.claude/(sessions)/1.json" "cat $WOLFMUX_DATA/(state)/x.json"
  "cp -R ~/.wolfmux/(memory|x) /tmp/m" "cat ~/.wolfmux/@(memory|x)/x" "cat ~/.wolfmux/(\")\"|memory)/x" "cd ~/(.wolfmux|zz) && cat memory/x"
  "bash =(echo 'cat ~/.wolfmux/memory/x')" "source =(echo 'cat ~/.wolfmux/memory/x')" "=tmux -V" "=claude -r abc" "/opt/homebrew/bin/tmu? -V"
  "/bin/ba(s)h -c 'cat ~/.wolfmux/mem\"\"ory/x'")
R5_ZSH_ALLOW=("f() { echo hi; }; f" "x=(a b c); echo \${x[1]}" "( cd src && ls )" "if (true); then echo y; fi" "ls src/(lib|x)"
  'git commit -m "fix (a|b) in src"' 'case "$x" in (a|b) echo y;; esac' "echo \$((1+2))")
check "H2: zsh glob groups ((a|b), mem(|)ory, @( ), a quoted ) inside), =( ), =cmd and a wildcard program word are read as zsh reads them; f() { }, x=( ), ( ) and case ( ) pass" \
  'denied_all "${R5_ZSH[@]}" && allowed_all "${R5_ZSH_ALLOW[@]}"'
deep() { jq -cn --arg p "$1" '{deep: {list: ["a", $p]}}'; }
cmdf() { jq -cn --arg c "$1" '{opts: {cmd: $c}}'; }
check "H3: the hook runs for every tool: Monitor and PowerShell commands are shell text; any other tool has every string and its command/cmd/script fields checked" \
  '[ "$(guard Monitor "$(sh "cat ~/.wolfmux/memory/x")")" = deny ] && [ "$(guard PowerShell "$(sh "cat $DIR/MEMORY.md")")" = deny ] &&
   [ "$(guard Monitor "$(sh "npm test")")" = allow ] && [ "$(guard FooTool "$(deep "$DIR/MEMORY.md")")" = deny ] &&
   [ "$(guard FooTool "$(deep "~/.wolfmux/memory/x")")" = deny ] && [ "$(guard FooTool "$(cmdf "cd $WOLFMUX_DATA && cat memory/x")")" = deny ] &&
   [ "$(guard mcp__x__run "$(jq -cn --arg c "cat $DIR/MEMORY.md" "{script: \$c}")")" = deny ] &&
   [ "$(guard FooTool "$(jq -cn "{p: \"src/lib/x.ts\", q: \"tests/a.sh\", note: \"see .wolfmux/memory docs\"}")")" = allow ] &&
   [ "$(guard TodoWrite "$(jq -cn "{todos: [{content: \"fix the guard\", status: \"pending\"}]}")")" = allow ] &&
   jq -e ".hooks.PreToolUse[0].matcher == \".*\"" "$(STATE)/teams/mem/settings/w1.json" >/dev/null'
# Review round 5 (H4): UP climbs from the worktree to the data folder, so the cases name memory/... only by resolving
UP="" UPD="$(cd "$W1" && pwd -P)"
while [ "$UPD" != "$WOLFMUX_DATA" ] && [ "$UPD" != / ]; do UP="$UP../" UPD="$(dirname "$UPD")"; done
MSG60="git commit -m \"$(awk 'BEGIN { for (i = 0; i < 15000; i++) printf "a/b " }')\""
R5_PROSE=("cd $WORK && cat 'Library/Application Support/../../data/memory/$KEY/mem/MEMORY.md'"
  "mkdir -p 'a b' && cat 'a b/../${UP}memory/$KEY/mem/MEMORY.md'" "cat 'x y'/../${UP}memory/$KEY/mem/MEMORY.md"
  "cd $WOLFMUX_DATA && cat 'memory/$KEY/mem/core/my notes.md'" 'git commit -m "see ~/.wolfmux/memory"')
R5_PROSE_ALLOW=('git commit -m "fix a/b in src"' 'git commit -m "docs: see src/lib/x.ts and tests/a b.sh"' 'cat "src/my file.ts"')
check "H4: a quoted word with a blank is a path when it holds a / (the review's three cases, and an MCP string); a commit message that names a private folder (see ~/.wolfmux/memory) is refused, so rephrase it; fix a/b in src passes, a 60 KB message in under 0.5 s" \
  '[ "$UPD" = "$WOLFMUX_DATA" ] && denied_all "${R5_PROSE[@]}" && [ "$(guard FooTool "$(deep "a b/../${UP}memory/$KEY/mem/MEMORY.md")")" = deny ] &&
   allowed_all "${R5_PROSE_ALLOW[@]}" && timed 500 allow "$MSG60"'
end_link_followed() { # links where the path ends: f -> the memory index, g -> f, rx.ts -> the lead's checkout (no file there yet)
  local r=0
  /bin/ln -s "$DIR/MEMORY.md" "$W1/f" && /bin/ln -s "$W1/f" "$W1/g" && /bin/ln -s "$PROJECT/rx.ts" "$W1/rx.ts" || return 1
  [ "$(guard Read "$(file f)")" = deny ] && [ "$(guard Read "$(file "$W1/g")")" = deny ] && [ "$(guard Grep "$(search f)")" = deny ] &&
    [ "$(guard Write "$(file rx.ts)")" = deny ] && [ "$(guard Edit "$(file "$W1/rx.ts")")" = deny ] && denied_all "cat g" "echo x > rx.ts" || r=1
  /bin/rm -f "$W1/f" "$W1/g" "$W1/rx.ts"
  return "$r"
}
R5_LINKS=("ln -s ~/.wolfmux/mem\$(true)ory/$KEY/mem/MEMORY.md f" "gln -s ~ h" "xargs ln -s <<< \"$WOLFMUX_DATA h\""
  "git update-index --add --cacheinfo 120000,\$(printf %s $WOLFMUX_DATA | git hash-object -w --stdin),h" "find . -name x -exec ln -s {} h \\;")
check "H5: a link where the path ends is followed by Read, Grep, Write, Edit and Bash (f -> the memory index, g -> f, rx.ts -> the lead's checkout); ln with a word built at run time, gln, xargs ln, find -exec ln and git update-index 120000 are refused" \
  'end_link_followed && denied_all "${R5_LINKS[@]}" && allowed_all "ln -s src/lib lib" "git update-index --refresh"'
R5_RT=("cat ~/.wolfmux/mem\${x}ory/x" "cat ~/.wolfmux/mem\$(true)ory/x" "cat ~/.wolfmux/mem\$@ory/x" "cat ~/.wolfmux/mem\`true\`ory/x"
  "cat ~/.wolf\$1mux/memory/x" "cd $WOLFMUX_DATA && cat mem\${x}ory/$KEY/mem/MEMORY.md" "cd $WORK/da\${x}ta && cat memory/$KEY/mem/MEMORY.md"
  "bash -c \"\$(printf 'cd $WOLFMUX_DATA && cat memory/$KEY/mem/MEMORY.md')\"" "eval \"\$(printf 'cd $WOLFMUX_DATA; cat memory/$KEY/mem/MEMORY.md')\""
  "xargs -I{} sh -c '{}' <<< 'cd $WOLFMUX_DATA && cat memory/$KEY/mem/MEMORY.md'")
R5_RT_ALLOW=('echo $HOME/x' 'cd "$(git rev-parse --show-toplevel)" && ls' 'bash -c "$(printf "echo hi")"' 'git commit -m "fix $x in a/b"'
  'eval "$(ssh-agent -s)"' 'for f in src/*.ts; do cat "$f"; done')
check "H6: a word is also read with every part built at run time deleted (mem\${x}ory, mem\$(true)ory, .wolf\$1mux); what \$( ) prints is the text of sh -c or eval, and xargs input the text of sh -c '{}'; an MCP string may be FILE:, file:/, have leading blanks or climb with .." \
  'denied_all "${R5_RT[@]}" && allowed_all "${R5_RT_ALLOW[@]}" &&
   [ "$(guard mcp__fs__write_file "$(at "FILE://$PROJECT/x")")" = deny ] && [ "$(guard mcp__fs__write_file "$(at "  $PROJECT/x")")" = deny ] &&
   [ "$(guard mcp__fs__write_file "$(at "file:$PROJECT/x")")" = deny ] && [ "$(guard mcp__fs__write_file "$(at "${UP}../demo project/x")")" = deny ] &&
   [ "$(guard mcp__fs__read "$(at "fIlE:$DIR/MEMORY.md")")" = deny ] && [ "$(guard mcp__fs__write_file "$(at "./src/x.ts")")" = allow ]'
# Review round 5 (H7): the guard needs only what every Mac has, /bin/bash 3.2 and BSD awk (/usr/bin/awk)
GAWK_ONLY='\b(gensub|asorti?|strtonum|systime|strftime|mktime|patsplit|isarray|typeof|lshift|rshift|compl)[[:space:]]*\(|IGNORECASE|PROCINFO|FPAT|BEGINFILE|ENDFILE|nextfile|\\y|re-interval'
BASH4_ONLY='\$\{[A-Za-z_][A-Za-z_0-9]*(,,?|\^\^?)\}|declare -[a-zA-Z]*[AnNg]|local -[a-zA-Z]*[An]|mapfile|readarray|&>>|\|&|;;&|coproc|EPOCH|\[\[ -v |wait -n'
R5_PORT=("cat > out.txt <<'EOF'
some data
EOF" "echo \$'a\\x41\\101\\u0041' \"dq \$x \${y:-z} \$(date) \`id\`\" 'sq' # a comment" 'ls src/(a|b).ts mem(|)o *(.) && x=( a b ) && f() { echo; }'
  'for f in *.ts; do bash -c "echo $f"; done | sort' 'git commit -m "fix a/b in src"' 'printf %s {a,b}{1..3} ~/x <(ls) >>log 2>&1')
bsdawk() { # <OK|D> <command>: /usr/bin/awk reads it with the guard's program ($SCAN) to the end, and prints nothing on stderr
  local out
  out="$(GA_CMD="$2" GA_CWD="$W1" GA_HOME="$HOME" LC_ALL=C /usr/bin/awk "$SCAN" 2>"$WORK/awk.err")" && [ ! -s "$WORK/awk.err" ] &&
    case "$1" in OK) [ "$(printf '%s\n' "$out" | tail -1)" = OK ] ;; *) printf '%s\n' "$out" | grep -q '^D' ;; esac ||
    { cat "$WORK/awk.err"; printf '%s: %s\n' "$1" "$2" | cut -c1-160; return 1; }
}
portable() { # no gawk-only feature in the awk program, none of bash 4 around it, awk and bash by their macOS paths
  local SCAN c g="$REPO/config/wolfmux/lib/guard.sh"
  SCAN="$(/bin/bash -c '. "$1" && printf "%s" "$GUARD_SCAN"' _ "$g")" && [ -n "$SCAN" ] &&
    ! printf '%s\n' "$SCAN" | grep -v '^[[:space:]]*#' | grep -qE "$GAWK_ONLY" && grep -q 'LC_ALL=C /usr/bin/awk "\$GUARD_SCAN"' "$g" &&
    [ "$(head -1 "$REPO/bin/teamctl")" = '#!/bin/bash' ] && /bin/bash -n "$g" &&
    ! awk '/^GUARD_SCAN=/ { s = 1 } !s && !/^[[:space:]]*#/ { print } s && /^}\047$/ { s = 0 }' "$g" | grep -qE "$BASH4_ONLY" || return 1
  for c in "${R5_PORT[@]}"; do bsdawk OK "$c" || return 1; done
  bsdawk D "cat ~/.wolfmux/memory/x" && bsdawk D "tmux ls"
}
check "H7: the guard runs on what every Mac has: no gawk-only feature, /usr/bin/awk reads heredocs, \$'…', groups, \$( ) and comments to the end with nothing on stderr; teamctl is #!/bin/bash, guard.sh has no bash 4 feature" \
  'portable'
R4_ALLOW=('grep -n "tmux" src/x.sh' "rg -n 'tmux' src" "git log -S tmux" "echo tmux" "which tmux" 'grep -rn "../utils" src/' 'rg "../lib" src'
  "git grep -n '../shared'" "$P101" "cat $SCRATCH/s1/scratchpad/notes.md" "ls /tmp/*.log")
check "G2, G3, G10: tmux as a word, a search pattern with .., 101 paths inside the worktree and the own scratchpad all pass" \
  'allowed_all "${R4_ALLOW[@]}"'
R4_QUOTED=("cat ~/.wolfmux/mem\"\"ory/x" 'cat ~/.wolfmux/mem\ory/x' 'cat ~/.wolfmux/"memory"/x' "cat $WOLFMUX_DATA/sta\"\"te/x.json"
  'cat ~/.claude/file""-history/x' "cat $WOLFMUX_DATA/mem\"\"ory/$KEY/mem/MEMORY.md" "\\cd $WOLFMUX_DATA && cat memory/x"
  "$(printf 'cat ~/.wolfmux/mem\\\nory/x')" "bash -c -- 'cd $WOLFMUX_DATA && cat memory/x'" "bash -c -x 'cat ~/.wolfmux/memory/x'"
  "bash -c -e 'cat ~/.wolfmux/memory/x'" "bash +x -c 'cat ~/.wolfmux/memory/x'" "bash --rcfile /dev/null -c 'cat ~/.wolfmux/memory/x'"
  "$(printf 'cat <<X | bash\ncat ~/.wolfmux/memory/x\nX')" "echo 'cat ~/.wolfmux/memory/x' | sh" "$(printf 'bash - <<X\ncat ~/.wolfmux/memory/x\nX')")
check "G5, G9: quotes and backslashes inside a word, a continued line, options around -c and text piped into a shell are seen" \
  'denied_all "${R4_QUOTED[@]}"'
R4_SEARCH=("grep -r ~ -e secret" "grep -d recurse secret ~" "grep --directories recurse secret ~" "fd card ~" "ag secret ~" "ack secret ~"
  "git log --format=%H -- ../x" "find $WOLFMUX_CLAUDE_TMP -name x.output")
check "G3, G4: the pattern is chosen after every option; fd, ag and ack walk; ../x after -- is a path (from the worktree root: the lanes' folder)" \
  'denied_all "${R4_SEARCH[@]}"'
R4_RECORDS=("cat ~/.claude/sessions/123.json" "ls \$HOME/.claude/session-env" "tail ~/.claude/history.jsonl"
  "cat $WOLFMUX_CLAUDE_TMP/-lead-project/s2/tasks/a.output" "ls $WOLFMUX_CLAUDE_TMP/*" "ssh localhost 'cat ~/.wolfmux/memory/x'"
  "watch -n1 'cat ~/.wolfmux/memory/x'")
check "G7: Claude Code's sessions, session-env, history.jsonl and other sessions' temporary folders are closed; ssh and watch text is a command" \
  'denied_all "${R4_RECORDS[@]}" && [ "$(guard Read "$(file "$HOME/.claude/history.jsonl")")" = deny ] &&
   [ "$(guard Read "$(file "$WOLFMUX_CLAUDE_TMP/-lead-project/s2/tasks/a.output")")" = deny ] && [ "$(guard mcp__fs__read "$(at "file://$HOME/.claude/todos/a.json")")" = deny ] &&
   [ "$(guard Write "$(file "$SCRATCH/s1/scratchpad/n.md")")" = allow ] && [ "$(guard Write "$(file "$WOLFMUX_CLAUDE_TMP/-lead-project/s2/x")")" = deny ]'
link_followed() { # a link in the worktree that leads to the data directory: every way through it is refused
  local r=0
  /bin/ln -s "$WOLFMUX_DATA" "$W1/w" || return 1
  denied_all "cat w/memory/$KEY/mem/MEMORY.md" "cd w && cat memory/$KEY/mem/MEMORY.md" && [ "$(guard Glob "$(pat "w/memory/**")")" = deny ] &&
    [ "$(guard Read "$(file "$W1/w/memory/$KEY/mem/MEMORY.md")")" = deny ] || r=1
  /bin/rm -f "$W1/w"
  return "$r"
}
check "G6: a link to a private place is refused; one made anyway is followed by Bash, Glob and Read" \
  'denied_all "ln -s $WOLFMUX_DATA w" "ln -sf ~/.claude/projects p" && link_followed'
R4_CLAUDE=("timeout -s KILL 60 claude -r abc" "nice -n 5 claude -r abc" "caffeinate -i claude -r abc" "script -q /dev/null claude -r abc"
  "nohup claude --resume abc" "echo abc | xargs -I{} claude --resume {}" "npx @anthropic-ai/claude-code --resume abc" "\$(which claude) -r abc"
  "\$(command -v claude) --continue" 'unset "TMUX_PANE"' "env -u \"TMUX_PANE\" teamctl status" "declare +x TMUX_PANE; teamctl status"
  "typeset +x TEAM_ROLE" 'read TMUX_PANE <<< ""' "printf -v TMUX_PANE ''" "env -S 'TMUX_PANE= teamctl status'")
check "G8: claude --resume after timeout, nice, caffeinate, script, nohup, xargs, npx or \$(which claude); quoted and un-export identity drops" \
  'denied_all "${R4_CLAUDE[@]}" && allowed_all "c=claude; \$c -r abc"'
check "G10: a worktree whose name starts with yours (w1, w10) is not yours" \
  '/bin/mkdir -p "${W1}0" && denied_all "cat ${W1}0/README.md" "ls ${W1}0"'
check "the worker's own work is untouched by the rule" \
  '[ "$(guard Bash "$(sh "cat README.md && git status")")" = allow ] && [ "$(guard Read "$(file "$W1/README.md")")" = allow ]'

echo "== disable: you, or the mem team's own lead; nothing is deleted"
check "a worker may not disable it (77), nor the other team's lead (77)" \
  'as_agent mem w1 memory disable; [ $? -eq 77 ] && as_agent other lead memory disable; [ $? -eq 77 ] && [ "$(jq -r .policy_team_memory "$(STATE)/policy.json")" = mem ]'
check "teamctl policy team-memory off: a worker (77); TEAM_ROLE=lead from outside any pane (77), for policy and disable alike" \
  'as_agent mem w1 policy team-memory off >/dev/null 2>&1; [ $? -eq 77 ] &&
   TEAM_ROLE=lead WOLFMUX_TEAM=mem "$REPO/bin/teamctl" policy team-memory off >/dev/null 2>&1; [ $? -eq 77 ] &&
   TEAM_ROLE=lead WOLFMUX_TEAM=mem "$REPO/bin/teamctl" memory disable >/dev/null 2>&1; [ $? -eq 77 ] && [ "$(jq -r .policy_team_memory "$(STATE)/policy.json")" = mem ]'
: >"$WORK/tty"
check "the mem team's own lead may: the policy is off, the folder stays, it is logged, and you are told" \
  'as_agent mem lead memory disable >/dev/null && [ "$(jq -r .policy_team_memory "$(STATE)/policy.json")" = off ] && [ -f "$DIR/MEMORY.md" ] &&
   jq -e "select(.action == \"disable\" and .previous == \"mem\" and .by == \"mem.lead\")" "$(STATE)/team-memory.jsonl" && grep -q "switched team memory off" "$WORK/tty"'
check "off: teamctl memory path prints nothing and exits 1; status lists the kept folder" \
  'out="$(teamctl memory path)"; [ $? -eq 1 ] && [ -z "$out" ] && teamctl memory status | grep -q "^kept folders: mem"'
check "off: the mem lead's prompt and settings are back to plain at its next start" \
  '! teamctl _prompt lead --team mem | grep -q "^## Team memory" && teamctl restart lead --team mem >/dev/null 2>&1 && sleep 1 && settings_of lead mem | jq -e "has(\"autoMemoryDirectory\") | not"'
check "off stays off: WOLFMUX_TEAM_MEMORY=mem in the environment turns nothing on" \
  'WOLFMUX_TEAM_MEMORY=mem teamctl memory status | grep -q "^team-memory:  off" && ! WOLFMUX_TEAM_MEMORY=mem teamctl _prompt lead --team mem | grep -q "^## Team memory"'
/bin/rm "$CONF/config" && /bin/cp "$REPO/config/wolfmux/config" "$CONF/config" && echo "WOLFMUX_TEAM_MEMORY=mem" >>"$CONF/config"
check "  ... nor WOLFMUX_TEAM_MEMORY=mem in the config file" \
  'teamctl memory status | grep -q "^team-memory:  off" && teamctl policy --team mem | grep -Eq "^  team-memory +off " && ! teamctl _prompt lead --team mem | grep -q "^## Team memory"'
/bin/rm "$CONF/config" && /bin/ln -s "$REPO/config/wolfmux/config" "$CONF/config"
teamctl policy team-memory mem >/dev/null 2>&1
check "teamctl policy team-memory mem, by you, is enable: the same folder, kept" \
  '[ "$(jq -r .policy_team_memory "$(STATE)/policy.json")" = mem ] && [ -f "$DIR/MEMORY.md" ]'

echo "== the folder outlives destroy --purge and finish"
teamctl destroy --team mem --purge --yes >/dev/null 2>&1
check "teamctl destroy --purge: the team is gone, its memory folder is not" \
  '[ ! -d "$(STATE)/teams/mem/agents" ] && [ -f "$DIR/MEMORY.md" ] && [ -x "$DIR/bin/mem" ]'
BEFORE="$(launches mem lead)"
as_agent other lead start opus --team mem --no-attach --skip-beads >"$WORK/o" 2>&1
check "no owner, no memory: a mem team that another lead founds after the purge gets no block, no setting, no boot" \
  '[ "$(record lead mem | jq -r .spawned_by)" != operator ] && launched_after mem lead "$BEFORE" && ! teamctl _prompt lead --team mem | grep -q "^## Team memory" &&
   settings_of lead mem | jq -e "has(\"autoMemoryDirectory\") | not" && ! last_argv mem lead | grep -q "Team memory is" || { cat "$WORK/o"; exit 1; }'
check "  ... nor the folder's path: that lead's memory path and check get 77" \
  'as_agent mem lead memory path >/dev/null 2>&1; [ $? -eq 77 ] && as_agent mem lead memory check >/dev/null 2>&1; [ $? -eq 77 ]'
teamctl destroy --team mem --purge --yes >/dev/null 2>&1
teamctl start opus --team mem --no-attach --skip-beads >/dev/null 2>&1
teamctl finish --team mem >/dev/null 2>&1
check "teamctl finish: the team is taken, its memory folder is not" \
  '[ ! -f "$(STATE)/teams/mem/meta.json" ] && [ -f "$DIR/MEMORY.md" ]'
teamctl start opus --team mem --no-attach --skip-beads >/dev/null 2>&1
check "--memory without --purge: a usage error (64), nothing deleted" \
  'teamctl destroy --team mem --memory --yes </dev/null >/dev/null 2>&1; [ $? -eq 64 ] && [ -f "$(STATE)/teams/mem/meta.json" ] && [ -f "$DIR/MEMORY.md" ]'
check "destroy --purge --memory from an agent's pane, the mem lead's own: refused (77), even on a terminal that types the name" \
  'as_agent mem lead destroy --team mem --purge --memory --yes </dev/null >/dev/null 2>&1; [ $? -eq 77 ] &&
   typed mem env TEAM_ROLE=lead WOLFMUX_TEAM=mem "$REPO/tests/in-pane" destroy --team mem --purge --memory --yes >/dev/null 2>&1; [ $? -eq 77 ] &&
   [ -d "$(STATE)/teams/mem/agents" ] && [ -f "$(STATE)/teams/mem/meta.json" ] && [ -f "$DIR/MEMORY.md" ]'
check "destroy --purge --memory with nobody to type the name: refused, nothing deleted" \
  '! teamctl destroy --team mem --purge --memory --yes </dev/null >/dev/null 2>&1 && [ -f "$(STATE)/teams/mem/meta.json" ] && [ -f "$DIR/MEMORY.md" ]'
check "  ... the wrong name typed: refused, nothing deleted" \
  '! typed wrong "$REPO/bin/teamctl" destroy --team mem --purge --memory --yes >/dev/null 2>&1 && [ -f "$(STATE)/teams/mem/meta.json" ] && [ -f "$DIR/MEMORY.md" ]'
check "  ... the team's name typed: the team and its memory folder go, and the policy goes off" \
  'typed mem "$REPO/bin/teamctl" destroy --team mem --purge --memory --yes >/dev/null 2>&1 && [ ! -d "$DIR" ] && [ ! -f "$(STATE)/teams/mem/meta.json" ] &&
   [ "$(jq -r .policy_team_memory "$(STATE)/policy.json")" = off ]'

echo "== install.sh and uninstall.sh"
# A copy of the repository WITH a skeleton (the real one belongs to another lane), installed into a home of its own
COPY="$WORK/repo-copy"
/bin/mkdir -p "$COPY"
for entry in "$REPO"/*; do
  case "$(basename "$entry")" in docs | tests) ;; *) /bin/cp -R "$entry" "$COPY/" ;; esac
done
/bin/rm -rf "$COPY/config/wolfmux/memory-skeleton"
/bin/cp -R "$SKEL" "$COPY/config/wolfmux/memory-skeleton"
IHOME="$WORK/ihome"
/bin/mkdir -p "$IHOME/.wolfmux/memory/proj-abc123/mem/core"
echo "private" >"$IHOME/.wolfmux/memory/proj-abc123/mem/MEMORY.md"
NOSOCK="WOLFMUX_TMUX_SOCKET=wolfmux-test-memory-none-$$ WOLFMUX_LEGACY_SOCKET=wolfmux-test-memory-none-old-$$"
install_into() { env WOLFMUX_INSTALL_HOME="$IHOME" $NOSOCK "$1/install.sh" --no-path --no-completion --no-claude-permissions --no-claude-commands --no-codex-rules --no-notifier-app; }
install_into "$COPY" >"$WORK/install-1.log" 2>&1
check "install.sh copies the skeleton to ~/.config/wolfmux/memory-skeleton: files 644, bin/mem 755" \
  '[ "$(stat -f %Lp "$IHOME/.config/wolfmux/memory-skeleton/MEMORY.md")" = 644 ] && [ "$(stat -f %Lp "$IHOME/.config/wolfmux/memory-skeleton/bin/mem")" = 755 ] &&
   cmp -s "$SKEL/core/boot.md" "$IHOME/.config/wolfmux/memory-skeleton/core/boot.md"'
install_into "$COPY" >"$WORK/install-2.log" 2>&1
check "  ... and a re-run leaves an existing memory folder exactly as it was" \
  '[ "$(cat "$IHOME/.wolfmux/memory/proj-abc123/mem/MEMORY.md")" = private ] && ! grep -q "\.wolfmux/memory" "$WORK/install-1.log" "$WORK/install-2.log"'
/bin/rm -rf "$COPY/config/wolfmux/memory-skeleton"
check "a checkout without a skeleton still installs, silently" \
  'install_into "$COPY" >"$WORK/install-3.log" 2>&1 && ! grep -i "memory-skeleton" "$WORK/install-3.log"'
OUT="$(env HOME="$IHOME" $NOSOCK "$COPY/uninstall.sh" --purge-memory 2>&1)"
RC=$?
check "uninstall.sh --purge-memory alone: a usage error (64), one line that names --purge, nothing removed" \
  '[ "$RC" -eq 64 ] && [ "$(printf "%s\n" "$OUT" | wc -l | tr -d " ")" = 1 ] && printf "%s" "$OUT" | grep -q -- "--purge --purge-memory" &&
   [ -f "$IHOME/.wolfmux/memory/proj-abc123/mem/MEMORY.md" ] && [ -d "$IHOME/.config/wolfmux" ] && [ -f "$IHOME/bin/teamctl" ]'
OUT="$(env HOME="$IHOME" $NOSOCK "$COPY/uninstall.sh" --purge 2>&1)"
RC=$?
check "uninstall.sh --purge refuses while a memory folder holds anything, says what it would delete, removes nothing" \
  '[ "$RC" -eq 1 ] && printf "%s" "$OUT" | grep -q "proj-abc123/mem" && printf "%s" "$OUT" | grep -q -- "--purge-memory" &&
   [ -f "$IHOME/.wolfmux/memory/proj-abc123/mem/MEMORY.md" ] && [ -d "$IHOME/.config/wolfmux" ] && [ -f "$IHOME/bin/teamctl" ]'
check "uninstall.sh --purge --purge-memory goes ahead: ~/.wolfmux is gone, memory included" \
  'env HOME="$IHOME" $NOSOCK "$COPY/uninstall.sh" --purge --purge-memory >/dev/null 2>&1 && [ ! -e "$IHOME/.wolfmux" ] && [ ! -e "$IHOME/.config/wolfmux" ]'

# Round 3 (review 3): the command side. Appended here; the guard checks above belong to the guard lane.
echo "== --continue with the policy off: the old guess, for every lead"
jq '.session_id = ""' "$(STATE)/teams/other/agents/lead.json" >"$WORK/r" && cat "$WORK/r" >"$(STATE)/teams/other/agents/lead.json"
BEFORE="$(launches other lead)"
check "team memory off: a lead with no stored id continues again, as before team memory (the newest-transcript guess)" \
  '[ "$(jq -r .policy_team_memory "$(STATE)/policy.json")" = off ] && teamctl restart lead --team other --continue >/dev/null 2>&1 &&
   launched_after other lead "$BEFORE" && last_argv other lead | jq -e "index(\"--continue\") != null"'

echo "== capture follows what the running lead holds, not only the policy"
teamctl start opus --team mem --no-attach --skip-beads >/dev/null 2>&1
teamctl memory enable mem >/dev/null 2>&1
BEFORE="$(launches mem lead)"
teamctl restart lead --team mem >/dev/null 2>&1
check "the mem lead runs with the memory: the other team's lead may not capture its pane (77)" \
  'launched_after mem lead "$BEFORE" && [ "$(settings_of lead mem | jq -r .autoMemoryDirectory)" = "$DIR" ] &&
   as_agent other lead capture lead --team mem >"$WORK/o" 2>&1; [ $? -eq 77 ] && grep -q "private team memory" "$WORK/o"'
teamctl memory disable >/dev/null 2>&1
check "  ... after memory disable, the lead still holds it until its restart: capture stays refused (77)" \
  '[ "$(jq -r .policy_team_memory "$(STATE)/policy.json")" = off ] && [ "$(settings_of lead mem | jq -r .autoMemoryDirectory)" = "$DIR" ] &&
   as_agent other lead capture lead --team mem >/dev/null 2>&1; [ $? -eq 77 ]'
check "  ... you still capture it" 'teamctl capture lead --team mem >/dev/null'
BEFORE="$(launches mem lead)"
teamctl restart lead --team mem >/dev/null 2>&1
check "  ... restarted without it (its settings carry no autoMemoryDirectory): the pane is an ordinary pane again" \
  'launched_after mem lead "$BEFORE" && sleep 1 && settings_of lead mem | jq -e "has(\"autoMemoryDirectory\") | not" && as_agent other lead capture lead --team mem >/dev/null'

echo "== enable refuses a team an agent founded; adopt makes it yours"
as_agent other lead start opus --team agt --no-attach --skip-beads >/dev/null 2>&1
ADIR="$WOLFMUX_DATA/memory/$KEY/agt"
OUT="$(teamctl memory enable agt 2>&1)"
check "teamctl memory enable on a team the other lead founded: refused with the reason and the way out, nothing changed" \
  '[ "$(record lead agt | jq -r .spawned_by)" = other.lead ] && ! teamctl memory enable agt >/dev/null 2>&1 &&
   printf "%s" "$OUT" | grep -q "founded by other.lead, not by you" && printf "%s" "$OUT" | grep -q "teamctl memory adopt agt" &&
   [ ! -d "$ADIR" ] && [ "$(jq -r .policy_team_memory "$(STATE)/policy.json")" = off ]'
check "  ... and teamctl policy team-memory agt is refused the same way" \
  '! teamctl policy team-memory agt >"$WORK/o" 2>&1 && grep -q "teamctl memory adopt agt" "$WORK/o" && [ "$(jq -r .policy_team_memory "$(STATE)/policy.json")" = off ]'
check "adopt is yours alone: the founding lead and the team's own lead get 77, the founder stays" \
  'as_agent other lead memory adopt agt >/dev/null 2>&1; [ $? -eq 77 ] && as_agent agt lead memory adopt agt >/dev/null 2>&1; [ $? -eq 77 ] &&
   [ "$(record lead agt | jq -r .spawned_by)" = other.lead ] && [ "$(jq -r .founder "$(STATE)/teams/agt/meta.json")" = other.lead ]'
: >"$WORK/tty"
check "you adopt it: the lead record and meta.json say operator, it is logged twice, and you are told" \
  'teamctl memory adopt agt >/dev/null && [ "$(record lead agt | jq -r .spawned_by)" = operator ] && [ "$(jq -r .founder "$(STATE)/teams/agt/meta.json")" = operator ] &&
   jq -e "select(.action == \"adopt\" and .team == \"agt\" and .previous == \"other.lead\" and .by == \"operator\")" "$(STATE)/team-memory.jsonl" &&
   jq -e "select(.type == \"adopt\")" "$(STATE)/teams/agt/events.jsonl" && grep -q "adopted team" "$WORK/tty"'
check "  ... adopt again: nothing to adopt; a team you founded is said to be yours" \
  'teamctl memory adopt agt | grep -q "already yours" && teamctl memory adopt nosuchteam >/dev/null 2>&1; [ $? -eq 64 ]'
check "  ... now enable is accepted, and a restart keeps you the founder and gives its lead the memory" \
  'teamctl memory enable agt >/dev/null && [ -x "$ADIR/bin/mem" ] && BEFORE="$(launches agt lead)" && teamctl restart lead --team agt >/dev/null 2>&1 &&
   launched_after agt lead "$BEFORE" && [ "$(record lead agt | jq -r .spawned_by)" = operator ] && [ "$(settings_of lead agt | jq -r .autoMemoryDirectory)" = "$ADIR" ]'

echo "== no owner, no memory: after finish too"
teamctl memory enable mem >/dev/null 2>&1
teamctl finish --team mem >/dev/null 2>&1
BEFORE="$(launches mem lead)"
as_agent other lead start opus --team mem --no-attach --skip-beads >"$WORK/o" 2>&1
check "a mem team that another lead founds after finish gets no block, no setting, no boot (the policy still names mem)" \
  '[ "$(jq -r .policy_team_memory "$(STATE)/policy.json")" = mem ] && [ "$(record lead mem | jq -r .spawned_by)" = other.lead ] && launched_after mem lead "$BEFORE" &&
   ! teamctl _prompt lead --team mem | grep -q "^## Team memory" && settings_of lead mem | jq -e "has(\"autoMemoryDirectory\") | not" &&
   ! last_argv mem lead | grep -q "Team memory is" || { cat "$WORK/o"; exit 1; }'
check "  ... and status says why, with the way out (adopt), not \"start the team yourself\"" \
  'teamctl memory status 2>&1 | grep -q "founded by other.lead, not by you: its lead gets no memory.*teamctl memory adopt mem" && ! teamctl memory status 2>&1 | grep -q "Start the team yourself"'

echo "== memory status: the folder's path and the lead's conversation id for you and the memory lead only"
teamctl memory enable agt >/dev/null 2>&1
AID="$(record lead agt | jq -r .session_id)"
check "you see the folder's path and the lead's conversation id" \
  '[ -n "$AID" ] && teamctl memory status >"$WORK/o" 2>&1 && grep -q "^team-memory:  agt" "$WORK/o" && grep -qF "$ADIR" "$WORK/o" && grep -qF "$AID" "$WORK/o"'
check "  ... and so does the memory team's own lead" \
  'as_agent agt lead memory status >"$WORK/o" 2>&1 && grep -qF "$ADIR" "$WORK/o" && grep -qF "$AID" "$WORK/o"'
check "everyone else gets the sizes and counts without them: another team's lead, a caller outside its pane (no 77: status is open)" \
  'for who in "other lead" "mem lead"; do as_agent $who memory status >"$WORK/o" 2>&1 || exit 1
     grep -q "^folder: .*files" "$WORK/o" && grep -Eq "^index: .*MEMORY.md [0-9]+ of 25000 bytes" "$WORK/o" && ! grep -qF "$ADIR" "$WORK/o" && ! grep -qF "$AID" "$WORK/o" ||
       { echo "shown to: $who"; cat "$WORK/o"; exit 1; }; done &&
   TEAM_ROLE=lead WOLFMUX_TEAM=agt "$REPO/bin/teamctl" memory status >"$WORK/o" 2>&1 && grep -q "^team-memory:  agt" "$WORK/o" && ! grep -qF "$ADIR" "$WORK/o" && ! grep -qF "$AID" "$WORK/o"'

echo "== no runnable bin/mem: no setting, no boot, no block at the next start (not only the prompt)"
/bin/chmod 600 "$ADIR/bin/mem"
check "the running lead still holds the memory (its settings): capture of its pane stays refused (77)" \
  '[ "$(settings_of lead agt | jq -r .autoMemoryDirectory)" = "$ADIR" ] && as_agent other lead capture lead --team agt >/dev/null 2>&1; [ $? -eq 77 ]'
BEFORE="$(launches agt lead)"
teamctl restart lead --team agt >/dev/null 2>&1
check "  ... restarted: no autoMemoryDirectory in its settings, no boot prompt in its argv, no block in its prompt" \
  'launched_after agt lead "$BEFORE" && sleep 1 && settings_of lead agt | jq -e "has(\"autoMemoryDirectory\") | not" &&
   ! last_argv agt lead | grep -q "Team memory is" && ! teamctl _prompt lead --team agt | grep -q "^## Team memory"'
check "  ... and its pane is an ordinary pane again: the other team's lead captures it" \
  'as_agent other lead capture lead --team agt >/dev/null'
/bin/chmod 700 "$ADIR/bin/mem"
BEFORE="$(launches agt lead)"
teamctl restart lead --team agt >/dev/null 2>&1
check "bin/mem runnable again: the next start has the setting and the boot prompt back" \
  'launched_after agt lead "$BEFORE" && [ "$(settings_of lead agt | jq -r .autoMemoryDirectory)" = "$ADIR" ] && last_argv agt lead | jq -e ".[-1] | startswith(\"Team memory is on. Run \")"'
teamctl memory disable >/dev/null 2>&1
check "off: the kept folders' names are anyone's, their place only yours" \
  'teamctl memory status | grep -q "^kept folders: .*(under " && as_agent other lead memory status >"$WORK/o" 2>&1 && grep -q "^kept folders: " "$WORK/o" && ! grep -q "under " "$WORK/o"'

echo "== the memory lead's conversation id: hidden in every view, for anybody but you and that lead"
teamctl memory enable agt >/dev/null 2>&1
teamctl spawn w9 opus --team agt --no-kickoff >/dev/null 2>&1
AID="$(record lead agt | jq -r .session_id)"
WID="$(record w9 agt | jq -r .session_id)"
sid_seen() { # <teamctl args…> as the caller in $WHO ("" = you): the agt lead's session_id in status --json
  if [ -z "$WHO" ]; then teamctl status --json --team agt; else as_agent $WHO status --json --team agt; fi 2>/dev/null |
    jq -r '.agents[] | select(.role == "lead") | .session_id'
}
check "status --json: you see the memory lead's id" \
  '[ -n "$AID" ] && [ "$(WHO="" sid_seen)" = "$AID" ]'
check "  ... and so does the memory lead itself" \
  '[ "$(WHO="agt lead" sid_seen)" = "$AID" ]'
check "  ... another team's lead and a worker get \"hidden\"" \
  '[ "$(WHO="other lead" sid_seen)" = hidden ] && [ "$(WHO="agt w9" sid_seen)" = hidden ]'
check "  ... a worker's id stays visible to them (leads need ids for --resume); plain status shows the memory lead's to nobody else" \
  '[ -n "$WID" ] && [ "$(as_agent other lead status --json --team agt | jq -r ".agents[] | select(.role == \"w9\") | .session_id")" = "$WID" ] &&
   ! as_agent other lead status --team agt 2>&1 | grep -qF "$AID"'
teamctl policy orphan-steward other >/dev/null 2>&1
check "  ... the orphan steward (the other team's lead) gets \"hidden\" too" \
  'teamctl policy --team agt | grep -Eq "^  orphan-steward +other " && [ "$(WHO="other lead" sid_seen)" = hidden ]'
teamctl policy orphan-steward off >/dev/null 2>&1
check "teams --json and dashboard --json carry no conversation id at all (model ids only)" \
  'as_agent other lead teams --json >"$WORK/o" 2>&1 && ! grep -qF "$AID" "$WORK/o" && ! grep -qF "$WID" "$WORK/o" &&
   as_agent other lead dashboard --once --json --full >"$WORK/o" 2>&1 && ! grep -qF "$AID" "$WORK/o" &&
   teamctl dashboard --once --json --full >"$WORK/o" 2>&1 && ! grep -qF "$AID" "$WORK/o"'

echo
echo "memory: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
