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
unset WOLFMUX_DISK_GUARD WOLFMUX_DISK_MIN_GB WOLFMUX_LINK_NODE_MODULES WOLFMUX_AUTO_PRUNE WOLFMUX_HEAVY_LOCK
teamctl() { "$REPO/bin/teamctl" "$@"; }

passed=0
failed=0
skipped=0
skip() { # <description> <why>
  skipped=$((skipped + 1))
  printf '  SKIP  %s\n        (%s)\n' "$1" "$2"
}
# The body runs in a SUBSHELL, so a check can fail without taking the suite with it. Two
# ordinary things in a failing check end a bare `eval`: a `exit 1` used inside a loop to
# fail the check, and reading a variable that was only assigned earlier in the same `&&`
# chain, which under `set -u` aborts the shell as soon as that chain short-circuits. The
# second one ended tests/disk.sh silently mid-run on a pristine library, with no summary
# line, which is indistinguishable from a short clean run.
check() { # <description> <command string>
  if ( eval "$2" ) >/dev/null 2>&1; then
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
      for m in provider-env common registry tmuxctl worktree disk beads policy approvals agents views dashboard doctor brand notify inbox layout guard; do
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
  'teamctl _overview-badge | grep -Eq "^teams 0 run 0 idle 0 "'

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
  'teamctl _overview-badge | grep -Eq "^teams 1 run 3 idle 0 "'
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
  'teamctl _overview-badge | grep -Eq "^teams 2 run 4 idle 0 "'
check "a team of the other project is drawn under its own project" \
  'teamctl dashboard --once | grep -q "other repo"'

echo "== equivalence: every fast path agrees with the helper it stands in for"
# This is the group that keeps the bulk reads honest. If any of these fails, dashboard.sh
# has started answering a different question from the rest of teamctl.
check "dash_teams lists exactly what team_list lists, in the same order" \
  'lib_eval "a=\$(team_list); b=\$(dash_teams \"\$(dash_sessions \"\$(dash_panes)\")\"); [ \"\$a\" = \"\$b\" ]"'
check "dash_team_records yields exactly the roles reg_list yields, in the same order" \
  'lib_eval "team_paths default; a=\$(reg_list); b=\$(dash_team_records | cut -d \"\$DASH_US\" -f1); [ \"\$a\" = \"\$b\" ]"'
check "dash_team_records reads the same field values reg_field reads" \
  'lib_eval "team_paths default; r=\$(dash_team_records | awk -F \"\$DASH_US\" \"\\\$1 == \\\"worker1\\\"\"); [ \"\$(printf %s \"\$r\" | cut -d \"\$DASH_US\" -f3)\" = \"\$(reg_field worker1 model)\" ] && [ \"\$(printf %s \"\$r\" | cut -d \"\$DASH_US\" -f5)\" = \"\$(reg_field worker1 workdir)\" ]"'
# A record's fields are split on the unit separator, because a tab is whitespace to `read`: an
# empty field vanished and every field after it moved up one place. A Codex agent has no
# conversation id, so its family was read as that id and its branch as its family: no context,
# and somebody else's value in the BRANCH column. A team of its own here, read in place.
CX_STATE="$WORK/cx-state"
CX_TREE="$WORK/cx-tree"
/bin/mkdir -p "$CX_STATE/agents" "$CX_TREE" "$WOLFMUX_CODEX_SESSIONS/2026/03/03"
jq -n --arg dir "$CX_TREE" '{role: "cx", kind: "worker", model: "astra", label: "GPT-6 Astra", workdir: $dir, session_id: "", family: "codex",
  branch: "ai/cx-1", spawned_by: "lead", created_at: "2026-03-03T00:00:00Z"}' >"$CX_STATE/agents/cx.json"
{
  jq -cn --arg dir "$CX_TREE" '{type: "session_meta", payload: {cwd: $dir}}'
  echo '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":5000},"model_context_window":272000}}}'
} >"$WOLFMUX_CODEX_SESSIONS/2026/03/03/rollout-2026-03-03T00-00-00-cx.jsonl"
export CX_STATE
check "an empty field moves nothing: a Codex agent (no conversation id) keeps its own branch, and its context is read as Codex's" \
  'lib_eval "team_paths default; STATE_DIR=\$CX_STATE; dash_team_json \"\" \"\" 1 | \$JQ_BIN -e \".agents[0] | .role == \\\"cx\\\" and .branch == \\\"ai/cx-1\\\" and .context == \\\"5.0k 1%\\\"\""'
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

echo "== the status bar: labelled fields, and held (v1.17.0)"
# v1.16.1 printed "21t 18run 92stop ld3.56 mem7G dsk66G", which is what Ammar called
# unreadable: four units as suffixes, two abbreviated labels, "92stop" as one token. It also
# could not say the one number that tells you there is something to reclaim. These checks are
# about the LINE, so they assert the label of every field and the alphabet it has to live in.
check "every field carries its name in front of its number, in the order teams run idle load mem disk held" \
  'teamctl _overview-badge | grep -Eq "^teams [0-9]+ run [0-9]+ idle [0-9]+ (exit [0-9]+ )?load [0-9.]+ mem [0-9]+[MG] disk [0-9]+[MG] held ([0-9.]+[MG]|-)$"'
check "none of the old suffix fields is left anywhere on the line" \
  '! teamctl _overview-badge | grep -Eq "[0-9]t |[0-9]run|[0-9]stop|ld[0-9]|mem[0-9]|dsk[0-9]"'
# The trap in cmd_overview_badge: it filters the line through tr -dc 'A-Za-z0-9 .:/+-' and
# then cuts it at 72. A separator outside that set is stripped SILENTLY, so a line built with
# a middle dot or a pipe would reach tmux with its fields run together and nothing to show
# why. Asserted on the real line: what the filter would remove, and the length.
check "the line survives its own filter unchanged: every character of it is in the badge alphabet" \
  'raw="$(teamctl _overview-badge)"; filtered="$(printf "%s" "$raw" | LC_ALL=C tr -dc "A-Za-z0-9 .:/+-")"; [ -n "$raw" ] && [ "$raw" = "$filtered" ]'
check "and it is one line well inside the 72 characters the badge is cut at" \
  'test "$(teamctl _overview-badge | wc -l | tr -d " ")" = 1 && test "$(teamctl _overview-badge | wc -c | tr -d " ")" -lt 73'
check "held is a dash while no team has been measured, never a zero that would read as nothing to reclaim" \
  'lib_eval "team_paths default; rm -f \"\$(disk_parked_cache_file)\""; teamctl _overview-badge | grep -q "held -$"'
check "held is what the parked lanes of every team hold, added up from what teamctl teams measured" \
  'lib_eval "team_paths default; printf \"%s 3145728\n\" \"\$(now_epoch)\" > \"\$(disk_parked_cache_file)\""; teamctl _overview-badge | grep -q "held 3.0G"'
check "a second team's parked lanes are added to it, so the number is the machine's and not one team's" \
  'lib_eval "team_paths default; printf \"%s 3145728\n\" \"\$(now_epoch)\" > \"\$(disk_parked_cache_file)\"; PROJECT_STATE=\"\$WOLFMUX_DATA/state/other-team-probe\"; mkdir -p \"\$PROJECT_STATE/teams/second\"; team_paths second; printf \"%s 1048576\n\" \"\$(now_epoch)\" > \"\$(disk_parked_cache_file)\""; teamctl _overview-badge | grep -q "held 4.0G"'
# The probe team goes before the checks below: with its number still on file, `held` could
# never be a dash and the three checks that assert one would have passed for a second team's
# reason instead of their own.
/bin/rm -rf "$WOLFMUX_DATA/state/other-team-probe"
check "an old parked number is still used: a parked lane is one where nothing runs, so its size does not change" \
  'lib_eval "team_paths default; printf \"%s 2097152\n\" \"\$(( \$(now_epoch) - 90000 ))\" > \"\$(disk_parked_cache_file)\""; teamctl _overview-badge | grep -q "held 2.0G"'
check "a garbled parked file is dropped silently, and a leading zero never reaches the arithmetic" \
  'lib_eval "team_paths default; printf \"08 500\n\" > \"\$(disk_parked_cache_file)\""; out="$(teamctl _overview-badge 2>&1)"; printf "%s" "$out" | grep -q "held -$" && ! printf "%s" "$out" | grep -qi "value too great\|syntax error"'
# Each loop is ALSO written in a subshell. Since `check` now evaluates every body in one,
# this is belt and braces rather than the only thing standing between a failing check and
# the end of the suite — and it still says plainly that `exit 1` here means "fail me".
check "and so are a short line, an empty file and a negative number" \
  '(for v in "" "123" "-5 -5" "banana soup"; do lib_eval "team_paths default; printf \"%s\n\" \"$v\" > \"\$(disk_parked_cache_file)\""; teamctl _overview-badge | grep -q "held -$" || exit 1; done)'
# The equivalence rule of this file, applied to the new fast reader: dash_parked_kb reads the
# file with the shell's own `read` so that the badge costs no process per team, and it must
# answer exactly what disk_parked_kb answers.
check "dash_parked_kb agrees with disk_parked_kb, on a good file and on every bad one" \
  'lib_eval "team_paths default; for v in \"\$(now_epoch) 4096\" \"08 500\" \"123\" \"\" \"-5 -5\"; do printf \"%s\n\" \"\$v\" > \"\$(disk_parked_cache_file)\"; dash_parked_kb \"\$STATE_DIR\"; [ \"\$DASH_PARKED_KB\" = \"\$(disk_parked_kb \"\$STATE_DIR\")\" ] || exit 1; done"'
check "teamctl teams leaves a parked number behind, and the bar then shows it" \
  'teamctl teams >/dev/null 2>&1; lib_eval "team_paths default; [ -f \"\$(disk_parked_cache_file)\" ]" && teamctl bar | grep -Eq "held ([0-9.]+[MG]|-)"'

echo "== teamctl bar --explain: the legend a status bar cannot carry"
BAR="$(teamctl bar --explain 2>&1)"
check "teamctl bar prints the line the status bar is given, character for character" \
  '[ "$(teamctl bar | head -n 1)" = "$(teamctl _overview-badge)" ]'
check "--explain names every field of the line" \
  '(for f in teams run idle exit load mem disk held; do printf "%s" "$BAR" | grep -Eq "^  $f +N " || exit 1; done)'
check "--explain says held is read and never measured, and names what makes it current" \
  'printf "%s" "$BAR" | grep -q "NEVER measured here" && printf "%s" "$BAR" | grep -q "teamctl teams"'
check "--explain says what held cannot know, instead of presenting it as current" \
  'printf "%s" "$BAR" | grep -q "a lane parked or removed since"'
check "--explain repeats the house rule: there is no honest idle-or-working signal" \
  'printf "%s" "$BAR" | grep -q "no honest signal"'
check "a bare teamctl bar points at the legend rather than printing it" \
  'teamctl bar | grep -q "teamctl bar --explain" && [ "$(teamctl bar | wc -l | tr -d " ")" -lt 5 ]'
# The usage LINE, not just the exit code: a tree with no `bar` command refuses it with 64
# as an unknown command, which would pass an exit-code-only check for the wrong reason.
check "an unknown option is a usage error (exit 64) naming the real usage, not a wrong line" \
  'out="$(teamctl bar --nonsense 2>&1)"; [ $? -eq 64 ] && printf "%s" "$out" | grep -q -- "usage: teamctl bar \[--explain\]"'

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

# The six checks above, and the one directly above this comment, all hand an empty window
# STRAIGHT TO the formatter — the last one by replacing agent_context with a fake that
# hardcodes it. They prove the formatter copes. They do NOT prove anything ever produces
# an empty window, so none of them would notice if the real reader stopped producing one.
#
# That gap matters more than it looks. Before v1.14.1, agent_context ended with
#     [ -n "$CTX_WINDOW" ] || CTX_WINDOW="${computed:-200000}"
# so CTX_WINDOW could NEVER be empty and this whole path was unreachable. v1.14.1 dropped
# the 200000 and made "" mean unknown. That change arrives here through a CLEAN MERGE —
# the lines are nowhere near the ones this branch touches, so git produces no conflict
# marker and nothing prompts a resolver to look. A behaviour change with no marker is
# exactly the shape that gets merged unexamined, and this function is going to be merged
# through again.
#
# So the two checks below drive the REAL agent_context end to end: a Codex rollout that
# reports its token count and declares NO model_context_window, for a model whose own key
# declares no window either (astra). On v1.14.1 and later CTX_WINDOW comes back empty and
# the cell must show the count with no share. On an older tree an empty CTX_WINDOW cannot
# be produced at all, so rather than fail for a reason that has nothing to do with this
# code, they SKIP and print why — the same rule the suite already uses for a signal the
# launch has made untestable.
# The genuinely-empty case lives on the CLAUDE path: _ctx_of_claude never sets CTX_WINDOW,
# so agent_context fills it from model_context_window, which from v1.14.1 declares nothing
# for a pinned id with no [1m]. The CODEX path cannot reach "" at all — its jq defaults a
# missing model_context_window to 0 — so that side is a separate "0" case below. Both must
# render without a share, and dash_context_label treats "" and 0 alike for that reason.
# worker2 is used throughout so these rollouts never become the newest file for worker1,
# whose own CTX_FILE check would then read this one instead.
if lib_eval 'model_context_window claude:claude-test-9' >/dev/null 2>&1; then
  skip "the real reader leaves CTX_WINDOW empty for a model with no declared window" \
    "this tree's model_context_window still declares a window for every model, so an empty CTX_WINDOW cannot be produced here: needs v1.14.1 or later"
  skip "and the dashboard cell for that agent shows the count with no share" \
    "same reason"
else
  check "the real reader leaves CTX_WINDOW empty for a model with no declared window" \
    'lib_eval "team_paths default; w=\$(reg_field worker2 workdir); s=nowin-0000-0000-0000-000000000001; d=\$(transcripts_dir \"\$w\"); mkdir -p \"\$d\"; printf \"%s\n\" \"{\\\"type\\\":\\\"assistant\\\",\\\"message\\\":{\\\"usage\\\":{\\\"input_tokens\\\":2000,\\\"cache_read_input_tokens\\\":140000,\\\"cache_creation_input_tokens\\\":0}}}\" > \"\$d/\$s.jsonl\"; agent_context \"\$w\" claude:claude-test-9 claude \"\$s\"; [ -n \"\$CTX_TOKENS\" ] && [ -z \"\$CTX_WINDOW\" ]"'
  check "and the dashboard cell for that agent shows the count with no share" \
    'lib_eval "team_paths default; w=\$(reg_field worker2 workdir); s=nowin-0000-0000-0000-000000000001; d=\$(transcripts_dir \"\$w\"); mkdir -p \"\$d\"; printf \"%s\n\" \"{\\\"type\\\":\\\"assistant\\\",\\\"message\\\":{\\\"usage\\\":{\\\"input_tokens\\\":2000,\\\"cache_read_input_tokens\\\":140000,\\\"cache_creation_input_tokens\\\":0}}}\" > \"\$d/\$s.jsonl\"; agent_context \"\$w\" claude:claude-test-9 claude \"\$s\"; out=\$(dash_context_label \"\$CTX_TOKENS\" \"\$CTX_WINDOW\"); [ \"\$out\" = 142k ] && case \"\$out\" in *%*) exit 1 ;; esac"'
fi
# The Codex side of the same contract: a rollout that declares no window yields 0, not "",
# and 0 must render exactly like "" — no share, never 0%.
check "a Codex rollout with no declared window yields 0, and still renders with no share" \
  'lib_eval "team_paths default; w=\$(reg_field worker2 workdir); r=\$WOLFMUX_CODEX_SESSIONS/2026/02/02; mkdir -p \"\$r\"; f=\$r/rollout-2026-02-02T00-00-00-nowin.jsonl; printf \"%s\n%s\n\" \"{\\\"type\\\":\\\"session_meta\\\",\\\"payload\\\":{\\\"cwd\\\":\\\"\$w\\\"}}\" \"{\\\"type\\\":\\\"event_msg\\\",\\\"payload\\\":{\\\"type\\\":\\\"token_count\\\",\\\"info\\\":{\\\"last_token_usage\\\":{\\\"total_tokens\\\":142000}}}}\" > \"\$f\"; agent_context \"\$w\" astra codex \"\"; [ \"\$CTX_WINDOW\" = 0 ] && out=\$(dash_context_label \"\$CTX_TOKENS\" \"\$CTX_WINDOW\"); [ \"\$out\" = 142k ]"'

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
# The `held` field is the first number on this line that comes from a du — somebody else's,
# taken by teamctl teams and left in a file. It must stay somebody else's: a badge that
# measured the parked lanes itself would spend twelve seconds every few seconds.
/bin/rm -f "$WORK/du-was-called"
PATH="$SPY:$PATH" teamctl _overview-badge >/dev/null 2>&1
PATH="$SPY:$PATH" teamctl bar --explain >/dev/null 2>&1
check "neither the badge's held field nor the legend runs du: both read what teamctl teams left" \
  'test ! -e "$WORK/du-was-called"'
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
  'WOLFMUX_DATA="$WORK/nowhere" teamctl _overview-badge | grep -Eq "^teams 0 run [0-9]+ idle [0-9]+ .* disk "'
check "the stopped count is never negative when records and panes disagree" \
  'WOLFMUX_DATA="$WORK/nowhere" teamctl _overview-badge | grep -vq -- "idle -"'

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
  'teamctl _overview-badge | grep -Eq "^teams 2 run 3 idle 1 "'
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
  'teamctl _overview-badge | grep -Eq "^teams [0-9]+ "'
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
  '(for o in --json --once --interval --full; do teamctl _complete -- dashboard -- | grep -q -- "^$o" || exit 1; done)'
check "the view changes nothing: no team is stopped, started or removed by it" \
  'before=$(teamctl dashboard --json --once | jq -S ".projects"); teamctl dashboard --once >/dev/null; teamctl _overview-badge >/dev/null; after=$(teamctl dashboard --json --once | jq -S ".projects"); test "$before" = "$after"'

echo "== the key that opens it, and how tmux.conf finds teamctl"
check "the tmux configuration binds prefix O to the popup" \
  'grep -Eq "^bind O display-popup -E .*dashboard" "$REPO/config/wolfmux/tmux.conf"'
check "status-right carries the segment" \
  'grep -q "_overview-badge" "$REPO/config/wolfmux/tmux.conf"'
check "the other lane's status-left and status-interval are left alone" \
  'test "$(grep -c "^set -g status-right " "$REPO/config/wolfmux/tmux.conf")" = 1'
# The server inherits whatever PATH it was started with, so a bare `teamctl` in this file
# works only while ~/bin happens to be on it. Every entry resolves it through ONE shared
# user option instead, with a fallback that keeps this file correct on its own. Both
# consumers must use the same mechanism, or the next reader will add a second one.
# Asserted per ENTRY, not as a count of the whole file. A count was right while this
# branch owned the only two use sites, and became wrong the moment v1.15.0's bind N and
# status-left joined them in the same file — a test that breaks on another lane's merge
# says nothing about this one's code. What matters is that each of MY two entries resolves
# teamctl through the shared option, which is what these two greps check.
check "the key resolves teamctl through the shared option" \
  'grep -q "^bind O .*@wolfmux_teamctl,#{@wolfmux_teamctl},teamctl" "$REPO/config/wolfmux/tmux.conf"'
check "and the segment resolves it the same way: one mechanism, not two" \
  'grep -q "^set -g status-right .*@wolfmux_teamctl,#{@wolfmux_teamctl},teamctl" "$REPO/config/wolfmux/tmux.conf"'
check "neither entry calls a bare teamctl any more" \
  '! grep -Eq "^(bind O|set -g status-right ).*[^}]teamctl (dashboard|_overview-badge)" "$REPO/config/wolfmux/tmux.conf"'
# Measured, not assumed: these two are why the mechanism above is written that way. They
# need a real client, because tmux runs #() only while it is drawing a status line.
PROBE="$WORK/probe"
/bin/mkdir -p "$PROBE/pathdir"
printf '#!/bin/sh\ntouch "%s/by-option"\necho o\n' "$PROBE" >"$PROBE/stub"
printf '#!/bin/sh\ntouch "%s/by-path"\necho p\n' "$PROBE" >"$PROBE/pathdir/teamctl"
/bin/chmod +x "$PROBE/stub" "$PROBE/pathdir/teamctl"
PROBE_SOCKET="wolfmux-dash-probe-$$"
probe_run() { # <socket> — start a server with a real client and the conditional in status-right
  PATH="$PROBE/pathdir:$PATH" tmux -L "$PROBE_SOCKET" -f /dev/null new-session -d -s p 'sleep 60'
  tmux -L "$PROBE_SOCKET" set-option -g status-interval 1
  tmux -L "$PROBE_SOCKET" set-option -g status-right '#(#{?@wolfmux_teamctl,#{@wolfmux_teamctl},teamctl} badge)'
  script -q /dev/null tmux -L "$PROBE_SOCKET" attach -t p >/dev/null 2>&1 &
  PROBE_CLIENT=$!
  sleep 4
}
probe_stop() {
  # The braces keep the shell's own "Terminated" job notice off the report.
  { kill "$PROBE_CLIENT" && wait "$PROBE_CLIENT"; } 2>/dev/null
  tmux -L "$PROBE_SOCKET" kill-server 2>/dev/null
  /bin/rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$PROBE_SOCKET"
}
probe_run
check "with the option unset, tmux.conf's fallback runs the bare teamctl on PATH" \
  'test -e "$PROBE/by-path" && test ! -e "$PROBE/by-option"'
/bin/rm -f "$PROBE/by-path" "$PROBE/by-option"
tmux -L "$PROBE_SOCKET" set-option -g @wolfmux_teamctl "$PROBE/stub" 2>/dev/null
tmux -L "$PROBE_SOCKET" refresh-client -S 2>/dev/null
sleep 5
check "with the option set, that absolute path runs and PATH is not used" \
  'test -e "$PROBE/by-option" && test ! -e "$PROBE/by-path"'
check "a nested format really is expanded inside #() on this tmux" \
  'test -e "$PROBE/by-option"'
probe_stop

echo "== the socket is handed in, never assumed"
# tmx targets $WOLFMUX_TMUX_SOCKET, default "wolfmux". A #() job inherits the tmux SERVER's
# environment, and nothing in it says which socket the job is drawn on — so a badge that
# asked tmux itself would silently report the DEFAULT socket's state instead of this one's.
# tmux.conf hands #{socket_path} over. These checks are what stops that regressing.
check "tmux.conf passes the socket to the segment" \
  'grep -q "_overview-badge \\\\\"#{socket_path}\\\\\"" "$REPO/config/wolfmux/tmux.conf" || grep -F -q "_overview-badge \"#{socket_path}\"" "$REPO/config/wolfmux/tmux.conf"'
# A SECOND server, with no agents of ours on it. Asked about that socket the segment must
# say 0 running; asked about the default it must still see this suite's own agents. If the
# argument were ignored the two would be identical, so the difference is the whole proof.
OTHER_SOCKET="wolfmux-dash-sock-$$"
tmux -L "$OTHER_SOCKET" -f /dev/null new-session -d -s s1 'sleep 60' 2>/dev/null
OTHER_SOCKET_PATH="$(tmux -L "$OTHER_SOCKET" display-message -p '#{socket_path}' 2>/dev/null)"
BADGE_OTHER="$(teamctl _overview-badge "$OTHER_SOCKET_PATH" 2>/dev/null)"
BADGE_DEFAULT="$(teamctl _overview-badge 2>/dev/null)"
tmux -L "$OTHER_SOCKET" kill-server 2>/dev/null
/bin/rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$OTHER_SOCKET"
check "the handed-in socket really is the one asked" \
  'test -S "$OTHER_SOCKET_PATH" -o -n "$OTHER_SOCKET_PATH"; printf "%s" "$BADGE_OTHER" | grep -Eq "^teams [0-9]+ run 0 "'
check "and it is not simply reporting the default: the two answers differ" \
  'test "$BADGE_OTHER" != "$BADGE_DEFAULT"'
check "the default socket still reports this suite's own running agents" \
  'teamctl _overview-badge | grep -Eq "^teams [0-9]+ run [1-9][0-9]* "'
check "a socket path that is not a socket is ignored, and the fallback stands" \
  'teamctl _overview-badge "$WORK/not-a-socket" | grep -Eq "^teams [0-9]+ run [1-9][0-9]* "'
check "a socket argument can never make the segment fail or speak" \
  'out="$(teamctl _overview-badge "/nowhere/at/all" 2>&1)"; test "$?" = 0 && printf "%s" "$out" | grep -Eq "^teams [0-9]+ "'
check "dash_socket_set refuses anything that is not a socket" \
  'lib_eval "DASH_SOCKET=\"\"; dash_socket_set /etc/hosts; dash_socket_set \"\"; dash_socket_set /nowhere; [ -z \"\$DASH_SOCKET\" ]"'
# A second server that stays up for the rest of this group: a REAL socket with none of this
# suite's agents on it, which is what makes the two answers distinguishable.
OTHER_SOCKET2="wolfmux-dash-sock2-$$"
tmux -L "$OTHER_SOCKET2" -f /dev/null new-session -d -s s2 'sleep 90' 2>/dev/null
OTHER_SOCKET_PATH2="$(tmux -L "$OTHER_SOCKET2" display-message -p '#{socket_path}' 2>/dev/null)"
check "the second server really is a socket, or the checks below measure nothing" \
  'test -S "$OTHER_SOCKET_PATH2"'
check "the popup is handed the socket too, as an explicit --socket" \
  'grep -F -q -- "dashboard --socket \"#{socket_path}\"" "$REPO/config/wolfmux/tmux.conf"'
check "--socket asks that server: a second, agent-less one reads 0 running" \
  'teamctl dashboard --json --once --socket "$OTHER_SOCKET_PATH2" | jq -e "[.projects[].teams[].agents[] | select(.state == \"running\")] | length == 0"'
check "--socket needs a value, and a bad one falls back instead of reporting an empty machine" \
  'teamctl dashboard --socket >/dev/null 2>&1; test "$?" = 64 && teamctl dashboard --json --once --socket /etc/hosts | jq -e "[.projects[].teams[].agents[] | select(.state == \"running\")] | length > 0"'
# THE REGRESSION. The ordinary way a human runs this is from inside their OWN tmux session,
# where $TMUX names their personal socket — a real socket, so every check on it passes. A
# view that trusted it would list panes from that server, find nothing tagged @ai_role, and
# report every team as having zero agents alive while the teams run fine on the wolfmux
# socket. Teams still appear, because they come from the state directories, so it looks
# plausible and is wrong. This is the check that would have caught it.
check "TMUX pointing at a real NON-wolfmux socket does not steal the answer" \
  'TMUX="$OTHER_SOCKET_PATH2,999,0" teamctl dashboard --json --once | jq -e "[.projects[].teams[].agents[] | select(.state == \"running\")] | length > 0"'
check "and the same is true of the text view a human actually reads" \
  'TMUX="$OTHER_SOCKET_PATH2,999,0" teamctl dashboard --once | grep -Eq "[1-9][0-9]* running"'
# reads_tmux_env <file> — does that file READ the $TMUX environment variable in code, as
# opposed to mentioning it in a comment? $TMUX_BIN and $WOLFMUX_TMUX_SOCKET are different
# names, and the character class excludes them rather than a second filter that could rot.
# One definition, used for the real check and for the two fixtures that prove it works.
reads_tmux_env() {
  grep -nE '[$]\{?TMUX\}?([^_A-Za-z]|$)' "$1" | grep -vE '^[0-9]+: *#' | grep -q .
}
printf 'x="$TMUX"\n' >"$WORK/guard-trips.sh"
printf 'a="$TMUX_BIN"\nb="$WOLFMUX_TMUX_SOCKET"\n# $TMUX in a comment is fine\n' >"$WORK/guard-clean.sh"
check "no code path reads the TMUX environment variable, so this cannot come back" \
  '! reads_tmux_env "$REPO/config/wolfmux/lib/dashboard.sh"'
check "that guard is not vacuous: it does trip on a real read of \$TMUX" \
  'reads_tmux_env "$WORK/guard-trips.sh"'
check "and it does not trip on TMUX_BIN, WOLFMUX_TMUX_SOCKET or a comment" \
  '! reads_tmux_env "$WORK/guard-clean.sh"'
tmux -L "$OTHER_SOCKET2" kill-server 2>/dev/null
/bin/rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$OTHER_SOCKET2"

echo
echo "result: $passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
