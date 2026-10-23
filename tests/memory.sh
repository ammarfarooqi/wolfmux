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
check() { # <description> <command string>
  if eval "$2" >"$WORK/check.out" 2>&1; then
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
tmux -L "$WOLFMUX_TMUX_SOCKET" kill-session -t "=$(jq -r .session "$(STATE)/teams/mem/meta.json")" >/dev/null 2>&1
check "  ... and as teamctl start --continue too (no session)" \
  '! teamctl start opus --team mem --continue --no-attach --skip-beads >/dev/null 2>&1 && [ "$(launches mem lead)" = "$BEFORE" ]'
teamctl start opus --team mem --no-attach --skip-beads >/dev/null 2>&1
jq '.session_id = ""' "$(STATE)/teams/other/agents/lead.json" >"$WORK/r" && cat "$WORK/r" >"$(STATE)/teams/other/agents/lead.json"
BEFORE="$(launches other lead)"
check "the other team's lead still continues without an id (the old newest-transcript guess)" \
  'teamctl restart lead --team other --continue >/dev/null 2>&1 && launched_after other lead "$BEFORE" && last_argv other lead | jq -e "index(\"--continue\") != null"'

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
check "teamctl memory check runs mem check and passes its exit code" \
  'teamctl memory check | grep -q "0 problems" && FAKE_MEM_CHECK_RC=1 teamctl memory check >/dev/null 2>&1; [ $? -eq 1 ]'

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
guard() { # <tool> <tool_input json> [<data dir>]: the decision for worker w1
  local answer
  answer="$(jq -cn --arg tool "$1" --argjson input "$2" --arg cwd "$W1" '{hook_event_name: "PreToolUse", tool_name: $tool, tool_input: $input, cwd: $cwd}' |
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
check "the honest gap, pinned: a relative path after a cd is not seen (docs/SECURITY.md)" \
  '[ "$(guard Bash "$(sh "cd \"$WOLFMUX_DATA\" && cat memory/x")")" = allow ]'
check "the worker's own work is untouched by the rule" \
  '[ "$(guard Bash "$(sh "cat README.md && git status")")" = allow ] && [ "$(guard Read "$(file "$W1/README.md")")" = allow ]'

echo "== disable: you, or the mem team's own lead; nothing is deleted"
check "a worker may not disable it (77), nor the other team's lead (77)" \
  'as_agent mem w1 memory disable; [ $? -eq 77 ] && as_agent other lead memory disable; [ $? -eq 77 ] && [ "$(jq -r .policy_team_memory "$(STATE)/policy.json")" = mem ]'
: >"$WORK/tty"
check "the mem team's own lead may: the policy is off, the folder stays, it is logged, and you are told" \
  'as_agent mem lead memory disable >/dev/null && [ "$(jq -r .policy_team_memory "$(STATE)/policy.json")" = off ] && [ -f "$DIR/MEMORY.md" ] &&
   jq -e "select(.action == \"disable\" and .previous == \"mem\" and .by == \"mem.lead\")" "$(STATE)/team-memory.jsonl" && grep -q "switched team memory off" "$WORK/tty"'
check "off: teamctl memory path prints nothing and exits 1; status lists the kept folder" \
  'out="$(teamctl memory path)"; [ $? -eq 1 ] && [ -z "$out" ] && teamctl memory status | grep -q "^kept folders: mem"'
check "off: the mem lead's prompt and settings are back to plain at its next start" \
  '! teamctl _prompt lead --team mem | grep -q "^## Team memory" && teamctl restart lead --team mem >/dev/null 2>&1 && sleep 1 && settings_of lead mem | jq -e "has(\"autoMemoryDirectory\") | not"'
teamctl policy team-memory mem >/dev/null 2>&1
check "teamctl policy team-memory mem, by you, is enable: the same folder, kept" \
  '[ "$(jq -r .policy_team_memory "$(STATE)/policy.json")" = mem ] && [ -f "$DIR/MEMORY.md" ]'

echo "== the folder outlives destroy --purge and finish"
teamctl destroy --team mem --purge --yes >/dev/null 2>&1
check "teamctl destroy --purge: the team is gone, its memory folder is not" \
  '[ ! -d "$(STATE)/teams/mem/agents" ] && [ -f "$DIR/MEMORY.md" ] && [ -x "$DIR/bin/mem" ]'
teamctl start opus --team mem --no-attach --skip-beads >/dev/null 2>&1
teamctl finish --team mem >/dev/null 2>&1
check "teamctl finish: the team is taken, its memory folder is not" \
  '[ ! -f "$(STATE)/teams/mem/meta.json" ] && [ -f "$DIR/MEMORY.md" ]'
teamctl start opus --team mem --no-attach --skip-beads >/dev/null 2>&1
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
OUT="$(env HOME="$IHOME" $NOSOCK "$COPY/uninstall.sh" --purge 2>&1)"
RC=$?
check "uninstall.sh --purge refuses while a memory folder holds anything, says what it would delete, removes nothing" \
  '[ "$RC" -eq 1 ] && printf "%s" "$OUT" | grep -q "proj-abc123/mem" && printf "%s" "$OUT" | grep -q -- "--purge-memory" &&
   [ -f "$IHOME/.wolfmux/memory/proj-abc123/mem/MEMORY.md" ] && [ -d "$IHOME/.config/wolfmux" ] && [ -f "$IHOME/bin/teamctl" ]'
check "uninstall.sh --purge --purge-memory goes ahead: ~/.wolfmux is gone, memory included" \
  'env HOME="$IHOME" $NOSOCK "$COPY/uninstall.sh" --purge --purge-memory >/dev/null 2>&1 && [ ! -e "$IHOME/.wolfmux" ] && [ ! -e "$IHOME/.config/wolfmux" ]'

echo
echo "memory: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
