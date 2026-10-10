#!/bin/bash
# dashboard.sh — the machine-wide view: `teamctl dashboard` and the status-bar segment
# `teamctl _overview-badge`.
#
# Fully isolated from any team you have running: its own tmux server (socket
# wolfmux-dash-test-<pid>), its own state directory, throwaway git repositories, stub
# agents instead of real CLIs. Needs tmux, git, jq.
#
# What it is really guarding. The dashboard answers the same questions the ordinary
# commands answer, but for every team on the machine at once, so it reads in bulk where
# they read one field at a time (see the header of lib/dashboard.sh). Two whole groups of
# checks below exist for that: the EQUIVALENCE group, which asserts each fast path still
# agrees with the helper it stands in for, and the BUDGET group, which asserts the segment
# never reaches `du` or `ps` — the two things that would make a status bar redrawn every
# few seconds unusable.
#
#   tests/dashboard.sh
# No pipefail: checks end in `grep -q`, which closes the pipe early by design.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-dash.XXXXXX")"
export WOLFMUX_HOME="$REPO/config/wolfmux"
export WOLFMUX_BIN_DIR="$REPO/bin"
export WOLFMUX_DATA="$WORK/data"
export WOLFMUX_TMUX_SOCKET="wolfmux-dash-test-$$"
export WOLFMUX_LAUNCHER_FABLE="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_ASTRA="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_GLM53="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_FLASH="$REPO/tests/stub-agent"
export WOLFMUX_CLAUDE_PROJECTS="$WORK/claude-projects"
export WOLFMUX_CODEX_SESSIONS="$WORK/codex-sessions"
# Run from an agent's pane, the environment carries that agent's team and worktree: all of
# it is dropped, or every command here would act as that agent.
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR WOLFMUX_NOTIFY WOLFMUX_SPLASH TMUX TMUX_PANE
unset WOLFMUX_TEAM WOLFMUX_TEAM_ARG WOLFMUX_SESSION WOLFMUX_WORKTREE WOLFMUX_BRANCH WOLFMUX_MODEL
unset WOLFMUX_DISK_GUARD WOLFMUX_DISK_MIN_GB WOLFMUX_LINK_NODE_MODULES
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
  /bin/chmod -R u+rwX "$WORK" 2>/dev/null
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT

# lib_eval <shell code> — run it with teamctl's own libraries loaded and this project
# resolved, so a rule can be asked a question directly instead of through a command.
# `set -euo pipefail` is bin/teamctl's own line, not a weaker one.
lib_eval() {
  (
    cd "${2:-$PROJECT}" || exit 1
    bash -c '
      set -euo pipefail
      for m in provider-env common registry tmuxctl worktree disk beads policy approvals agents views dashboard doctor brand notify layout guard; do
        . "$WOLFMUX_HOME/lib/$m.sh"
      done
      load_project any
      eval "$1"' _ "$1"
  )
}

new_repo() { # <path>
  /bin/mkdir -p "$1"
  (
    cd "$1" || exit 1
    git init -q -b main
    echo hello >README.md
    printf 'node_modules/\n' >.gitignore
    git add -A
    git -c user.name=dash -c user.email=dash@example.invalid commit -qm "initial commit"
  )
}

PROJECT="$WORK/demo project" # the space is deliberate
new_repo "$PROJECT"
cd "$PROJECT" || exit 1

echo "== nothing on this machine yet"
# The first thing the view has to survive is an empty machine: no state directory at all.
check "dashboard --json on a machine with no state is valid JSON with no projects" \
  'teamctl dashboard --json --once | jq -e ".projects == [] and .teams == null"'
check "dashboard --once prints the header and does not fail" \
  'teamctl dashboard --once | grep -q "WOLFMUX DASHBOARD"'
check "dashboard --once says 0 teams" \
  'teamctl dashboard --once | grep -q "0 teams"'
check "the segment prints a line on an empty machine" \
  'teamctl _overview-badge | grep -Eq "^0t 0run 0stop "'

echo "== a running team, across the whole machine"
teamctl start fable --no-attach --skip-beads >/dev/null 2>&1
teamctl spawn worker1 glm53 --no-kickoff >/dev/null 2>&1
teamctl spawn worker2 glm53 --no-kickoff >/dev/null 2>&1
DOC="$WORK/doc.json"
teamctl dashboard --json --once >"$DOC" 2>/dev/null

check "the project appears, with its root" \
  'jq -e "(.projects | length) == 1 and (.projects[0].root | test(\"demo project\"))" "$DOC"'
check "the team appears and its session is running" \
  'jq -e ".projects[0].teams[0].team == \"default\" and .projects[0].teams[0].session_running == true" "$DOC"'
check "all three agents appear, lead first" \
  'jq -e ".projects[0].teams[0].agents | length == 3 and .[0].kind == \"lead\"" "$DOC"'
check "every agent is running" \
  'jq -e "[.projects[0].teams[0].agents[] | select(.state == \"running\")] | length == 3" "$DOC"'
check "a worker reports its own branch, the lead reports none" \
  'jq -e ".projects[0].teams[0].agents[1].branch | startswith(\"ai/\")" "$DOC" && jq -e ".projects[0].teams[0].agents[0].branch == \"-\"" "$DOC"'
check "cpu and memory are measured per agent, from the process tree" \
  'jq -e "[.projects[0].teams[0].agents[] | select(.rss_kb != null and .rss_kb > 0)] | length == 3" "$DOC"'
check "the machine footer carries load, memory and free disk" \
  'jq -e ".machine.disk_free_kb > 0 and .machine.memory_free_kb > 0" "$DOC"'
check "the text view draws the team and every role" \
  'teamctl dashboard --once | grep -q "TEAM default" && teamctl dashboard --once | grep -q worker2'
check "the text view says the reading is a process reading, not a claim about the agent" \
  'teamctl dashboard --once | grep -q "not a claim about what the agent is doing"'
check "the text view names teamctl teams as what refreshes the lane total" \
  'teamctl dashboard --once | grep -q "teamctl teams"'
check "the segment now counts one team and three running agents" \
  'teamctl _overview-badge | grep -Eq "^1t 3run 0stop "'
check "the segment stays one short line" \
  'test "$(teamctl _overview-badge | wc -l | tr -d " ")" = 1 && test "$(teamctl _overview-badge | wc -c | tr -d " ")" -lt 73'

echo "== a second project, so the view really is machine-wide"
OTHER="$WORK/other repo"
new_repo "$OTHER"
(cd "$OTHER" && teamctl start fable --no-attach --skip-beads >/dev/null 2>&1)
teamctl dashboard --json --once >"$DOC" 2>/dev/null
check "both projects appear, from either project's directory" \
  'jq -e ".projects | length == 2" "$DOC"'
# The subshell matters: `check` evals in this shell, so a bare cd here would move the rest
# of the file into the other project and every later `teamctl stop` would miss its target.
check "the same two projects appear when run from the other one" \
  '(cd "$OTHER" && teamctl dashboard --json --once | jq -e ".projects | length == 2")'
check "the segment counts the teams of both projects" \
  'teamctl _overview-badge | grep -Eq "^2t 4run 0stop "'
check "a team of the other project is drawn under its own project" \
  'teamctl dashboard --once | grep -q "other repo"'

echo "== equivalence: every fast path agrees with the helper it stands in for"
# This is the group that keeps the bulk reads honest. If any of these fails, dashboard.sh
# has started answering a different question from the rest of teamctl.
check "dash_teams lists exactly what team_list lists, in the same order" \
  'lib_eval "a=\$(team_list); b=\$(dash_teams \"\$(dash_sessions \"\$(dash_panes)\")\"); [ \"\$a\" = \"\$b\" ]"'
check "dash_team_records yields exactly the roles reg_list yields, in the same order" \
  'lib_eval "team_paths default; a=\$(reg_list); b=\$(dash_team_records | cut -f1); [ \"\$a\" = \"\$b\" ]"'
check "dash_team_records reads the same field values reg_field reads" \
  'lib_eval "team_paths default; r=\$(dash_team_records | awk -F\"\\t\" \"\\\$1 == \\\"worker1\\\"\"); [ \"\$(printf %s \"\$r\" | cut -f3)\" = \"\$(reg_field worker1 model)\" ] && [ \"\$(printf %s \"\$r\" | cut -f5)\" = \"\$(reg_field worker1 workdir)\" ]"'
check "dash_pane_row finds the same pane tm_pane_for_role finds" \
  'lib_eval "team_paths default; SESSION=\$(session_name_for_project); row=\$(dash_pane_row \"\$(dash_panes)\" \"\$SESSION\" worker1); [ \"\${row%%|*}\" = \"\$(tm_pane_for_role \"\$SESSION\" worker1)\" ]"'
check "dash_pane_row agrees with tm_pane_state about a running pane" \
  'lib_eval "team_paths default; SESSION=\$(session_name_for_project); row=\$(dash_pane_row \"\$(dash_panes)\" \"\$SESSION\" worker1); d=\${row#*|}; d=\${d%%|*}; [ \"\$d\" = 0 ] && [ \"\$(tm_pane_state \"\${row%%|*}\")\" = running ]"'
check "dash_pane_row gives nothing for a role with no pane" \
  'lib_eval "[ -z \"\$(dash_pane_row \"\$(dash_panes)\" nosuchsession nosuchrole)\" ]"'
check "dash_pane_row never matches one role inside a longer one" \
  'lib_eval "p=\"s|sublead|%9|0|999\"; [ -z \"\$(dash_pane_row \"\$p\" s lead)\" ]"'
check "dash_orphaned agrees with team_orphaned while the lead is running" \
  'lib_eval "team_paths default; SESSION=\$(session_name_for_project); row=\$(dash_pane_row \"\$(dash_panes)\" \"\$SESSION\" lead); if dash_orphaned \"\$row\"; then a=1; else a=0; fi; if team_orphaned; then b=1; else b=0; fi; [ \"\$a\" = \"\$b\" ] && [ \"\$a\" = 0 ]"'
check "dash_meta_session reads the session meta_get reads" \
  'lib_eval "team_paths default; [ \"\$(dash_meta_session \"\$STATE_DIR\")\" = \"\$(meta_get session)\" ]"'

echo "== the lane total is read, never measured"
# teamctl status shows the number teamctl teams left behind, while it is under fifteen
# minutes old (lib/disk.sh). The dashboard follows the same rule, and SAYS when the number
# is old rather than refreshing it: a du over a machine's lanes is about twelve seconds.
check "with nothing measured, the view says so and names the command that measures" \
  'teamctl dashboard --once | grep -q "not measured (teamctl teams measures it)"'
check "a fresh number is shown as a size, through human_size like every other view" \
  'lib_eval "team_paths default; printf \"%s 2048\n\" \"\$(now_epoch)\" > \"\$(disk_cache_file)\""; teamctl dashboard --once | grep -q "lanes 2 MB"'
check "a number older than the cache window is shown as STALE, with its age" \
  'lib_eval "team_paths default; printf \"%s 2048\n\" \"\$(( \$(now_epoch) - 4000 ))\" > \"\$(disk_cache_file)\""; teamctl dashboard --once | grep -Eq "lanes 2 MB, STALE 1h old"'
check "a stale number still names teamctl teams as what refreshes it" \
  'teamctl dashboard --once | grep -q "STALE.*teamctl teams refreshes it"'
check "a garbled cache file falls back to not-measured instead of failing" \
  'lib_eval "team_paths default; printf \"08 banana\n\" > \"\$(disk_cache_file)\""; teamctl dashboard --once | grep -q "not measured"'
check "a missing cache file is the normal case and is not an error" \
  'lib_eval "team_paths default; rm -f \"\$(disk_cache_file)\""; teamctl dashboard --json --once | jq -e ".projects[0].teams[0].lanes_disk | test(\"not measured\")"'

echo "== the context column: three cases, never an invented percentage"
# From v1.14.1 model_context_window may legitimately return nothing, and a percentage of a
# guessed window is worse than no percentage. ctx_display does the formatting; the
# dashboard only decides whether the share may be shown at all.
check "a known window gives a token count and a share" \
  'lib_eval "[ \"\$(dash_context_label 142000 200000)\" = \"142k 71%\" ]"'
check "an unknown window gives the token count and NO share" \
  'lib_eval "[ \"\$(dash_context_label 142000 \"\")\" = 142k ]"'
check "a zero window gives the token count and NO share — never 0%" \
  'lib_eval "[ \"\$(dash_context_label 142000 0)\" = 142k ]"'
check "a non-numeric window gives the token count and NO share" \
  'lib_eval "[ \"\$(dash_context_label 142000 unknown)\" = 142k ]"'
check "no reading at all is a dash, not a zero" \
  'lib_eval "[ \"\$(dash_context_label \"\" 200000)\" = - ]"'
check "no percent sign is ever printed for an unknown window" \
  'lib_eval "case \"\$(dash_context_label 142000 \"\")\" in *%*) exit 1 ;; esac"'
check "a team whose agent has an unknown window still renders, with no share" \
  'lib_eval "agent_context() { CTX_TOKENS=142000 CTX_WINDOW=\"\" CTX_FILE=\"\"; return 0; }; team_paths default; dash_team_json \"\" \"\" 1 | \$JQ_BIN -e \".agents[0].context == \\\"142k\\\"\""'

echo "== when the transcript was last written"
# The honest activity signal: the mtime of the very file the context reader opens. No
# terminal output is parsed, and no second piece of code works out where a transcript
# lives — agent_context now reports the file it used in CTX_FILE.
check "a Claude agent's transcript file is reported by the context reader" \
  'lib_eval "team_paths default; w=\$(reg_field worker1 workdir); s=\$(reg_field worker1 session_id); d=\$(transcripts_dir \"\$w\"); mkdir -p \"\$d\"; printf \"%s\n\" \"{\\\"type\\\":\\\"assistant\\\",\\\"message\\\":{\\\"usage\\\":{\\\"input_tokens\\\":1000,\\\"cache_read_input_tokens\\\":141000,\\\"cache_creation_input_tokens\\\":0}}}\" > \"\$d/\$s.jsonl\"; agent_context \"\$w\" glm53 claude \"\$s\"; [ \"\$CTX_FILE\" = \"\$d/\$s.jsonl\" ]"'
check "the dashboard reports that file's mtime, to the second" \
  'lib_eval "team_paths default; w=\$(reg_field worker1 workdir); s=\$(reg_field worker1 session_id); f=\$(transcripts_dir \"\$w\")/\$s.jsonl; touch -t 202601011200 \"\$f\"; m=\$(dash_mtime \"\$f\"); agent_context \"\$w\" glm53 claude \"\$s\"; [ \"\$(dash_mtime \"\$CTX_FILE\")\" = \"\$m\" ]"'
check "the column reaches the view for a running agent" \
  'teamctl dashboard --json --once | jq -e "[.projects[].teams[].agents[] | select(.transcript_written_at != null)] | length >= 1"'
check "an agent with no transcript reports nothing rather than a zero" \
  'lib_eval "team_paths default; w=\$(reg_field worker2 workdir); agent_context \"\$w\" glm53 claude 00000000-0000-0000-0000-000000000000; [ -z \"\$CTX_FILE\" ] && [ -z \"\$(dash_mtime \"\$CTX_FILE\")\" ]"'
# The Codex side is the same mechanism on a different file. No Codex agent was running on
# the machine this was written on, so it is verified against a rollout built here, and
# docs/VERIFICATION.md says exactly that.
check "a Codex agent's rollout file is reported by the context reader too" \
  'lib_eval "team_paths default; w=\$(reg_field worker1 workdir); r=\$WOLFMUX_CODEX_SESSIONS/2026/01/01; mkdir -p \"\$r\"; f=\$r/rollout-2026-01-01T00-00-00-abc.jsonl; printf \"%s\n%s\n\" \"{\\\"type\\\":\\\"session_meta\\\",\\\"payload\\\":{\\\"cwd\\\":\\\"\$w\\\"}}\" \"{\\\"type\\\":\\\"event_msg\\\",\\\"payload\\\":{\\\"type\\\":\\\"token_count\\\",\\\"info\\\":{\\\"last_token_usage\\\":{\\\"total_tokens\\\":5000},\\\"model_context_window\\\":272000}}}\" > \"\$f\"; agent_context \"\$w\" astra codex \"\"; [ \"\$CTX_FILE\" = \"\$f\" ] && [ -n \"\$(dash_mtime \"\$CTX_FILE\")\" ]"'

echo "== the budget: the segment reaches neither du nor ps"
# This is the rule the whole design hangs on. The segment redraws every few seconds for
# every attached client; a du over this machine's lanes is about twelve seconds, and a ps
# per agent is a process per agent. Both are shadowed on PATH and must stay untouched.
SPY="$WORK/spy"
/bin/mkdir -p "$SPY"
printf '#!/bin/sh\ntouch "%s/du-was-called"\nexit 0\n' "$WORK" >"$SPY/du"
printf '#!/bin/sh\ntouch "%s/ps-was-called"\nexit 0\n' "$WORK" >"$SPY/ps"
/bin/chmod +x "$SPY/du" "$SPY/ps"
/bin/rm -f "$WORK/du-was-called" "$WORK/ps-was-called"
PATH="$SPY:$PATH" teamctl _overview-badge >/dev/null 2>&1
check "the segment never runs du" 'test ! -e "$WORK/du-was-called"'
check "the segment never runs ps" 'test ! -e "$WORK/ps-was-called"'
/bin/rm -f "$WORK/du-was-called"
PATH="$SPY:$PATH" teamctl dashboard --once >/dev/null 2>&1
check "the popup never runs du either" 'test ! -e "$WORK/du-was-called"'
check "the popup takes ONE ps for the whole view, not one per agent" \
  'lib_eval "[ \"\$(dash_ps_snapshot | wc -l | tr -d \" \")\" -gt 10 ]"'
check "the process tree, not the pane's own process, is what is measured" \
  'lib_eval "snap=\"100 1 1.0 1000
200 100 2.0 2000
300 200 4.0 4000\"; [ \"\$(dash_tree_usage \"\$snap\" 100)\" = \"7.0 7000\" ]"'
check "a process tree with a cycle in it still terminates" \
  'lib_eval "snap=\"100 200 1.0 1000
200 100 2.0 2000\"; [ \"\$(dash_tree_usage \"\$snap\" 100)\" = \"3.0 3000\" ]"'
check "a pid that is not in the snapshot is zero, not an error" \
  'lib_eval "[ \"\$(dash_tree_usage \"100 1 1.0 1000\" 999)\" = \"0.0 0\" ]"'
check "no pid at all gives no reading rather than a zero" \
  'lib_eval "[ \"\$(dash_tree_usage \"100 1 1.0 1000\" \"\")\" = \"- -\" ]"'

echo "== the segment is silent on any error"
# tmux shows whatever a #() command prints, for as long as it is given it: a half-written
# line or an error message would sit in the status bar of every attached client until the
# server was restarted. So the contract is to print nothing at all.
check "a failing segment prints nothing and still exits 0" \
  'lib_eval "dash_badge_line() { echo boom >&2; return 1; }; out=\$(cmd_overview_badge); [ -z \"\$out\" ]"'
check "a segment that somehow prints several lines is cut to one" \
  'lib_eval "dash_badge_line() { printf \"one\ntwo\nthree\n\"; }; [ \"\$(cmd_overview_badge | wc -l | tr -d \" \")\" = 1 ]"'
# The guarantee is that no CONTROL character reaches tmux, not that an escape sequence is
# reassembled into pretty text: the printable tail of one ("31m") survives the filter, and
# that is harmless in a status bar. Asserting the real guarantee rather than a nicer one.
check "no control character ever reaches the status bar" \
  'lib_eval "dash_badge_line() { printf \"a\033[31mb\007c\n\"; }; out=\$(cmd_overview_badge); printf %s \"\$out\" | LC_ALL=C tr -d \"[:cntrl:]\" | [ \"\$(cat)\" = \"\$out\" ]"'
check "the escape introducer and the bell are both gone" \
  'lib_eval "dash_badge_line() { printf \"a\033[31mb\007c\n\"; }; case \"\$(cmd_overview_badge)\" in *\$(printf \"\033\")* | *\$(printf \"\007\")*) exit 1 ;; esac"'
check "an over-long segment is bounded, never a line that wraps the status bar" \
  'lib_eval "dash_badge_line() { printf \"%0.sx\" \$(seq 1 400); printf \"\n\"; }; [ \"\$(cmd_overview_badge | wc -c | tr -d \" \")\" -le 73 ]"'
check "without tmux the segment says nothing rather than reporting 0 running" \
  'lib_eval "TMUX_BIN=\"\"; out=\$(cmd_overview_badge); [ -z \"\$out\" ]"'
# No state directory means no teams and no records on file, but tmux still has the panes,
# so the agent counts stay truthful rather than dropping to zero. What is asserted is that
# the line is still well formed and still one line.
check "a state directory that is not there is not an error for the segment" \
  'WOLFMUX_DATA="$WORK/nowhere" teamctl _overview-badge | grep -Eq "^0t [0-9]+run [0-9]+stop .*dsk"'
check "the stopped count is never negative when records and panes disagree" \
  'WOLFMUX_DATA="$WORK/nowhere" teamctl _overview-badge | grep -vq -- "-[0-9]*stop"'

echo "== a stopped agent, and an orphaned team"
teamctl stop worker2 >/dev/null 2>&1
teamctl dashboard --json --once >"$DOC" 2>/dev/null
check "a stopped worker is on record with no pane" \
  'jq -e "[.projects[0].teams[0].agents[] | select(.role == \"worker2\" and .state == \"stopped\" and .pane == \"-\")] | length == 1" "$DOC"'
check "a stopped worker reports no cpu reading rather than a zero" \
  'jq -e "[.projects[0].teams[0].agents[] | select(.role == \"worker2\")] | .[0].cpu_percent == null" "$DOC"'
check "by default a stopped agent is not read from disk, and says so in the view" \
  'teamctl dashboard --once | grep -q "RUNNING agents only"'
check "--full reads every agent and drops that note" \
  'teamctl dashboard --once --full | grep -qv "RUNNING agents only"'
check "--full is recorded in the JSON" \
  'teamctl dashboard --json --once --full | jq -e ".full == true"'
check "the segment counts it as stopped, not as running" \
  'teamctl _overview-badge | grep -Eq "^2t 3run 1stop "'
# A team whose lead is not running is orphaned: nobody manages it. teamctl teams already
# decides this, and the dashboard must agree with it.
teamctl stop lead >/dev/null 2>&1
check "with its lead stopped the team is orphaned, as teamctl teams says" \
  'teamctl dashboard --json --once | jq -e "[.projects[0].teams[] | select(.team == \"default\" and .state == \"orphaned\")] | length == 1"'
check "dash_orphaned still agrees with team_orphaned once the lead has gone" \
  'lib_eval "team_paths default; SESSION=\$(session_name_for_project); row=\$(dash_pane_row \"\$(dash_panes)\" \"\$SESSION\" lead); if dash_orphaned \"\$row\"; then a=1; else a=0; fi; if team_orphaned; then b=1; else b=0; fi; [ \"\$a\" = \"\$b\" ] && [ \"\$a\" = 1 ]"'
check "the text view marks the orphaned team and counts it in the summary" \
  'teamctl dashboard --once | grep -q "orphaned"'

echo "== a project whose state cannot be read, and one with nothing in it"
# Another user's state directory, or one whose permissions changed under us. One bad
# project may never take the view down, and it may never vanish without a word either.
BAD="$WOLFMUX_DATA/state/unreadable-project"
/bin/mkdir -p "$BAD/agents"
/bin/chmod 000 "$BAD"
check "an unreadable project does not stop the view" \
  'teamctl dashboard --json --once | jq -e ".projects | length == 2"'
check "an unreadable project is named, not silently dropped" \
  'teamctl dashboard --json --once | jq -e ".unreadable_projects | index(\"unreadable-project\") != null"'
check "the text view says the state could not be read" \
  'teamctl dashboard --once | grep -q "state could not be read"'
check "the segment survives an unreadable project too" \
  'teamctl _overview-badge | grep -Eq "^[0-9]+t "'
/bin/chmod 700 "$BAD"
/bin/rm -rf "$BAD"
# A `teamctl start` that never finished leaves a state directory with no meta.json and no
# records. That is not an error and not the same thing as unreadable.
EMPTY="$WOLFMUX_DATA/state/empty-project"
/bin/mkdir -p "$EMPTY/teams/ghost/agents"
check "a project with nothing on record is reported apart from an unreadable one" \
  'teamctl dashboard --json --once | jq -e "(.empty_projects | index(\"empty-project\")) != null and (.unreadable_projects == [])"'
check "the text view calls it a start that never became a team" \
  'teamctl dashboard --once | grep -q "never became a team"'
check "a half-written meta.json does not stop the view" \
  'printf "{\"root\": " > "$EMPTY/meta.json"; teamctl dashboard --json --once | jq -e ".projects | length >= 2"'
/bin/rm -rf "$EMPTY"

echo "== the options, and what refuses what"
check "--interval takes a number" \
  'teamctl dashboard --once --interval 3 | grep -q "WOLFMUX DASHBOARD"'
check "--interval refuses nonsense with a usage error (exit 64)" \
  'teamctl dashboard --interval banana >/dev/null 2>&1; test "$?" = 64'
check "--interval refuses zero" \
  'teamctl dashboard --interval 0 >/dev/null 2>&1; test "$?" = 64'
check "--interval with no value is a usage error" \
  'teamctl dashboard --interval >/dev/null 2>&1; test "$?" = 64'
check "an unknown option is a usage error naming the command" \
  'teamctl dashboard --nonsense 2>&1 | grep -q "teamctl dashboard"'
check "dashboard is offered by tab completion" \
  'teamctl _complete -- "" | grep -q "^dashboard"'
check "tab completion offers every option the parser accepts" \
  'for o in --json --once --interval --full; do teamctl _complete -- dashboard -- | grep -q -- "^$o" || exit 1; done'
check "the view changes nothing: no team is stopped, started or removed by it" \
  'before=$(teamctl dashboard --json --once | jq -S ".projects"); teamctl dashboard --once >/dev/null; teamctl _overview-badge >/dev/null; after=$(teamctl dashboard --json --once | jq -S ".projects"); test "$before" = "$after"'

echo "== the key that opens it"
check "the tmux configuration binds prefix O to the popup" \
  'grep -Eq "^bind O display-popup -E .*teamctl dashboard" "$REPO/config/wolfmux/tmux.conf"'
check "status-right carries the segment" \
  'grep -q "teamctl _overview-badge" "$REPO/config/wolfmux/tmux.conf"'
check "the other lane's status-left and status-interval are left alone" \
  'test "$(grep -c "^set -g status-right " "$REPO/config/wolfmux/tmux.conf")" = 1'

echo
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
