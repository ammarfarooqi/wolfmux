#!/bin/bash
# finish.sh — a finished team takes itself off the books, and a team that is not finished says
# what it holds (v1.17.0 stage 4).
#
# The rule this suite is built around (the lead's decision, 2026-10-14): ONLY `teamctl finish`
# says a team is done. A lead that is not running is not evidence of anything — a crashed lead
# and a finished one look the same from outside — and `teamctl stop` promises in writing to
# keep everything. So most checks here are about teams that must SURVIVE, each with the reason
# it has to print, and the rest are about the one verb that may take a team.
#
# Isolated like tests/reclaim.sh: its own tmux server, its own state directory, a throwaway
# repository with a bare origin, stub agents, and stub `bd` and `gh` first on PATH. Nothing
# here asks a real Beads workspace or a real GitHub anything. Needs tmux, git, jq.
#
#   tests/finish.sh
# No pipefail: checks end in `grep -q`, which closes the pipe early by design.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-finish.XXXXXX")"
export TMPDIR="$WORK/tmp"
/bin/mkdir -p "$TMPDIR"
export WOLFMUX_HOME="$REPO/config/wolfmux"
export WOLFMUX_BIN_DIR="$REPO/bin"
export WOLFMUX_DATA="$WORK/data"
export WOLFMUX_TMUX_SOCKET="wolfmux-finish-test-$$"
export WOLFMUX_LAUNCHER_FABLE="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_GLM53="$REPO/tests/stub-agent"
export WOLFMUX_CLAUDE_PROJECTS="$WORK/claude-projects"
# Run from an agent's pane, the environment carries that agent's team and worktree: all of
# it is dropped, or every command here would act as that agent.
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR WOLFMUX_NOTIFY WOLFMUX_SPLASH TMUX TMUX_PANE
unset WOLFMUX_TEAM WOLFMUX_TEAM_ARG WOLFMUX_SESSION WOLFMUX_WORKTREE WOLFMUX_BRANCH WOLFMUX_MODEL
unset WOLFMUX_DISK_GUARD WOLFMUX_DISK_MIN_GB WOLFMUX_LINK_NODE_MODULES WOLFMUX_AUTO_PRUNE WOLFMUX_HEAVY_LOCK
unset WOLFMUX_AUTO_RECLAIM BEADS_DIR
teamctl() { "$REPO/bin/teamctl" "$@"; }
tmuxt() { tmux -L "$WOLFMUX_TMUX_SOCKET" "$@"; }

passed=0
failed=0
# The body runs in a SUBSHELL: a bare `exit 1` inside a check, or a variable read under
# `set -u` after a chain short-circuited, would otherwise end the whole suite, and a
# truncated run looks exactly like a clean one.
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
  tmuxt kill-server >/dev/null 2>&1
  /bin/rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$WOLFMUX_TMUX_SOCKET"
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT

# --- Beads and GitHub, as stubs (the shapes tests/reclaim.sh measured) ----------------
#   bd.mode     ok | fail
#   tasks/<id>.json   one bead each; `bd list` prints all of them
#   prs/<branch, / as _>.json   what `gh pr list --head <branch>` prints ([] when absent)
export RECLAIM_STUB="$WORK/stub"
/bin/mkdir -p "$RECLAIM_STUB/bin" "$RECLAIM_STUB/tasks" "$RECLAIM_STUB/prs"
/bin/cat >"$RECLAIM_STUB/bin/bd" <<'EOF'
#!/bin/bash
mode="$(/bin/cat "$RECLAIM_STUB/bd.mode" 2>/dev/null || echo ok)"
printf 'bd %s\n' "$*" >>"$RECLAIM_STUB/bd.log"
case "${1:-}" in
  list)
    echo "warning: beads.role not configured (GH#2950)." >&2
    case "$mode" in fail) echo "bd: the database is locked" >&2; exit 3 ;; esac
    wrapped=0
    for arg in "$@"; do case "$arg" in --brief | --skip-labels) wrapped=1 ;; esac; done
    if [ "$wrapped" -eq 1 ]; then
      jq -s '{issues: ., meta: {count: length}, schema_version: 1}' "$RECLAIM_STUB"/tasks/*.json 2>/dev/null || echo '{"issues": [], "meta": {"count": 0}, "schema_version": 1}'
    else
      jq -s . "$RECLAIM_STUB"/tasks/*.json 2>/dev/null || echo "[]"
    fi
    ;;
esac
exit 0
EOF
/bin/cat >"$RECLAIM_STUB/bin/gh" <<'EOF'
#!/bin/bash
printf 'gh %s (in %s)\n' "$*" "$PWD" >>"$RECLAIM_STUB/gh.log"
head=""
while [ "$#" -gt 0 ]; do
  case "$1" in --head) head="${2:-}"; shift ;; esac
  shift
done
file="$RECLAIM_STUB/prs/$(printf '%s' "$head" | tr '/' '_').json"
if [ -f "$file" ]; then /bin/cat "$file"; else echo "[]"; fi
exit 0
EOF
/bin/chmod +x "$RECLAIM_STUB/bin/bd" "$RECLAIM_STUB/bin/gh"
export PATH="$RECLAIM_STUB/bin:$PATH"
bd_mode() { printf '%s\n' "$1" >"$RECLAIM_STUB/bd.mode"; }
# bead <id> <assignee> <status> [<type>]
bead() { printf '{"id":"%s","title":"%s","status":"%s","issue_type":"%s","assignee":"%s"}\n' "$1" "$1" "$3" "${4:-task}" "$2" >"$RECLAIM_STUB/tasks/$1.json"; }
open_pr() { printf '[{"number":%s}]\n' "$2" >"$RECLAIM_STUB/prs/$(printf '%s' "$1" | tr '/' '_').json"; }
close_pr() { /bin/rm -f "$RECLAIM_STUB/prs/$(printf '%s' "$1" | tr '/' '_').json"; }

# --- the project, with a remote ------------------------------------------------------
PROJECT="$WORK/demo project" # the space is deliberate
ORIGIN="$WORK/origin.git"
/bin/mkdir -p "$PROJECT"
git init -q --bare -b main "$ORIGIN"
cd "$PROJECT" || exit 1
git init -q -b main
pg() { git -C "$PROJECT" -c user.name=finish -c user.email=finish@example.invalid "$@"; }
echo "hello" >README.md
printf 'node_modules/\n' >.gitignore
git add -A
pg commit -qm "initial commit"
git remote add origin "$ORIGIN"
git push -q -u origin main >/dev/null 2>&1
/bin/mkdir -p "$PROJECT/.beads"

# lib_eval <shell code> — teamctl's own libraries loaded, this project resolved
lib_eval() {
  (
    cd "$PROJECT" || exit 1
    bash -c '
      set -euo pipefail
      for m in provider-env common registry tmuxctl worktree disk reclaim finish beads policy approvals agents views dashboard doctor brand notify inbox layout guard; do
        [ -r "$WOLFMUX_HOME/lib/$m.sh" ] || continue
        . "$WOLFMUX_HOME/lib/$m.sh"
      done
      load_project any
      eval "$1"' _ "$1"
  )
}

# The world of one team. The status JSON is read once per team, after its lanes exist.
st_of() { teamctl --team "$1" status --json 2>/dev/null; }
dir_of() { st_of "$1" | jq -r --arg r "$2" '.agents[] | select(.role == $r) | .workdir'; }
br_of() { st_of "$1" | jq -r --arg r "$2" '.agents[] | select(.role == $r) | .branch'; }
# Where a team's state is, and what its session is called: worked out ONCE per team, while the
# team exists, and kept. Asked again after a finish, the answer would be empty — and an empty
# path makes `[ ! -e "$path" ]` pass for nothing.
state_of() { printf '%s/state/%s/teams/%s\n' "$WOLFMUX_DATA" "$KEY" "$1"; }
session_of() { /bin/cat "$WORK/session.$1" 2>/dev/null || printf 'no-session-was-recorded-for-%s\n' "$1"; }
remember_session() { WOLFMUX_TEAM_ARG="$1" lib_eval "session_name_for_project" >"$WORK/session.$1"; }
has_session() { tmuxt has-session -t "=$1" 2>/dev/null; }
commit_in() {
  printf '%s\n' "$3" >"$1/$2"
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" -c user.name=lane -c user.email=lane@example.invalid commit -qm "$4"
}
# team_with <team> <lane>... — a team whose lanes each hold one commit, parked, then merged
# into main and pushed, with a closed task each: lanes that pass every gate of stage 2. They
# are parked BEFORE the merge, so the park itself keeps them, and they are still on record.
team_with() {
  local team="$1" r
  shift
  teamctl start fable --team "$team" --no-attach --skip-beads >/dev/null 2>&1
  remember_session "$team"
  for r in "$@"; do teamctl spawn "$r" glm53 --team "$team" --no-kickoff >/dev/null 2>&1; done
  sleep 3
  for r in "$@"; do
    commit_in "$(dir_of "$team" "$r")" "$team-$r.txt" "work" "$team/$r: the work"
    bead "demo-$team-$r" "$team.$r" closed
  done
  for r in "$@"; do teamctl stop "$r" --team "$team" >/dev/null 2>&1; done
  for r in "$@"; do pg merge -q --no-ff -m "merge $team/$r" "$(br_of "$team" "$r")" >/dev/null 2>&1; done
  pg push -q origin main >/dev/null 2>&1
}
# as_lead <team> <teamctl args>... — the way that team's lead calls teamctl from its pane
as_lead() {
  local team="$1"
  shift
  TEAM_ROLE=lead WOLFMUX_TEAM="$team" "$REPO/bin/teamctl" "$@"
}
LEDGER="$WOLFMUX_DATA/state/reclaimed.jsonl"
end_of() { jq -r ".$2 // empty" "$(state_of "$1")/lead-end.json" 2>/dev/null; }
listed() { teamctl teams --json 2>/dev/null | jq -e --arg t "$1" '[.[] | select(.team == $t)] | length == 1' >/dev/null; }
# why_in <team> — from `teamctl teams` on stdin, the line under that team's orphan line: the
# reason. The orphan line itself is kept word for word (tests/smoke.sh reads it).
why_in() { grep -A1 "^$1 is orphaned: its lead is not running\." | sed -n 2p; }

echo "== the instruments"
check "teamctl finds the stub gh and the stub bd, so nothing here reaches a real GitHub or Beads" \
  '[ "$(lib_eval "printf %s \"\$GH_BIN\"")" = "$RECLAIM_STUB/bin/gh" ] && [ "$(lib_eval "printf %s \"\$BD_BIN\"")" = "$RECLAIM_STUB/bin/bd" ]'
check "teamctl knows the verb: finish is in its help, and an unknown option of it names the real usage" \
  'teamctl help | grep -q "teamctl finish" && out="$(teamctl finish --nonsense 2>&1)"; [ $? -eq 64 ] && printf "%s" "$out" | grep -q -- "usage: teamctl finish \[--team <name>\] \[--dry-run\]"'

# ------------------------------------------------------------------------------------
echo "== evidence, not authority: what a lead's end leaves behind"
team_with waits w1
KEY="$(lib_eval 'printf %s "$PROJECT_KEY"')"
check "CONTROL: the helpers know where a team's state is and what its session is called" \
  '[ -n "$KEY" ] && [ -f "$(state_of waits)/meta.json" ] && has_session "$(session_of waits)"'
# The lead parks itself for the night: every task closed, every lane passing the gates. This
# is the tidiest lead there is, and it must come back to its team.
as_lead waits stop lead --team waits >/dev/null 2>&1
check "teamctl stop lead, run by the lead itself, records how its session ended: stop, by that lead" \
  '[ "$(end_of waits how)" = "stop" ] && [ "$(end_of waits by)" = "waits.lead" ] && [ -n "$(end_of waits ts)" ]'
check "CONTROL: the lane of that team passes every gate of stage 2 (so only the TEAM rule can keep the team)" \
  'teamctl --team waits reclaim --dry-run 2>/dev/null | grep -qE "^  w1 +[0-9.]+ (KB|MB|GB) +would remove: "'
W1_DIR="$(dir_of waits w1)"
SWEEP1="$(teamctl reclaim --all-teams 2>&1)"
check "a sweep of every team takes the finished LANE of a team whose lead stopped itself" \
  '[ -n "$W1_DIR" ] && [ ! -e "$W1_DIR" ] && ! teamctl --team waits status --json 2>/dev/null | jq -e ".agents[] | select(.role == \"w1\")" >/dev/null'
check "and it does NOT destroy that team: a lead that stopped itself is evidence, never authority" \
  'listed waits && [ -d "$(state_of waits)" ] && [ "$(end_of waits how)" = "stop" ]'
check "the sweep says why the team stays, with the lead's own end in the words" \
  'printf "%s" "$SWEEP1" | grep -E "waits" | grep -qE "orphaned, holding [0-9.]+ (KB|MB|GB): lead stopped itself [0-9:Z -]+, 0 tasks open, 0 lanes held"'
TEAMS1="$(teamctl teams 2>&1)"
check "teamctl teams lists it as orphaned, with the size it holds and the reason next to it" \
  'printf "%s\n" "$TEAMS1" | why_in waits | grep -qE "^  holding [0-9.]+ (KB|MB|GB): lead stopped itself [0-9:Z -]+, 0 tasks open, 0 lanes held$"'
check "and it says which verb would end it" \
  'printf "%s" "$TEAMS1" | grep -E "^waits is orphaned" | grep -q "teamctl finish --team waits"'
FIN1="$(teamctl finish --team waits 2>&1)"
check "teamctl finish destroys the team that would otherwise wait: records, state directory, session" \
  '! listed waits && [ ! -e "$(state_of waits)" ] && ! has_session "$(session_of waits)"'
check "it says so, and why nothing held it" \
  'printf "%s" "$FIN1" | grep -qE "finished: team .waits. is gone" && printf "%s" "$FIN1" | grep -q "0 tasks open, 0 lanes held"'
check "the ledger has one team-destroyed line for it, with the trigger and who ran it" \
  'jq -se "[.[] | select(.event == \"team-destroyed\" and .team == \"waits\" and .trigger == \"finish\" and .by == \"operator\" and (.project | length > 0))] | length == 1" "$LEDGER" >/dev/null'

# A lead whose session ended without any teamctl command: its pane is simply gone, the way a
# crash, a kill-server or a reboot leaves it. Everything else is as finished as it gets.
team_with crash c1
tmuxt kill-session -t "=$(session_of crash)" >/dev/null 2>&1
SWEEP2="$(teamctl reclaim --all-teams 2>&1)"
check "CONTROL: the sweep reached that team and took its finished lane" \
  '! teamctl --team crash status --json 2>/dev/null | jq -e ".agents[] | select(.role == \"c1\")" >/dev/null && jq -se "[.[] | select(.event == \"lane-removed\" and .team == \"crash\" and .role == \"c1\")] | length == 1" "$LEDGER" >/dev/null'
check "a team whose lead CRASHED with every task closed is NOT destroyed" \
  'listed crash && [ -d "$(state_of crash)" ] && [ ! -e "$(state_of crash)/lead-end.json" ]'
check "and it is listed with the honest reason: there is no record of how its lead ended" \
  'teamctl teams 2>&1 | why_in crash | grep -qE "^  holding [0-9.]+ (KB|MB|GB): no record of how the lead ended \(crash, kill or reboot\), 0 tasks open, 0 lanes held$"'
check "a second sweep still does not destroy it: an absence never becomes a finish" \
  'teamctl reclaim --all-teams >/dev/null 2>&1; listed crash && [ -d "$(state_of crash)" ]'

# ------------------------------------------------------------------------------------
echo "== a team that finished while one lane holds an open PR"
team_with later l1 l2
open_pr "$(br_of later l2)" 7
FIN2="$(as_lead later finish --team later 2>&1)"
check "finish keeps the team when one lane holds an open PR, and the line names the lane and the PR" \
  'listed later && printf "%s" "$FIN2" | grep -qE "kept: team .later. is holding [0-9.]+ (KB|MB|GB): lead ran teamctl finish [0-9:Z -]+, 0 tasks open, 1 lane held: l2 \(open PR #7\)"'
check "the lane that passed went, and the lane with the PR is untouched" \
  '! teamctl --team later status --json | jq -e ".agents[] | select(.role == \"l1\")" >/dev/null && [ -f "$(dir_of later l2)/later-l2.txt" ]'
check "finish ended the team's session all the same: the lead said it is done" \
  '! has_session "$(session_of later)"'
check "the end is recorded as finish, by that lead" \
  '[ "$(end_of later how)" = "finish" ] && [ "$(end_of later by)" = "later.lead" ]'
check "teamctl teams lists it with the same reason, naming the lane and the PR" \
  'teamctl teams 2>&1 | why_in later | grep -qE "^  holding [0-9.]+ (KB|MB|GB): lead ran teamctl finish [0-9:Z -]+, 0 tasks open, 1 lane held: l2 \(open PR #7\)$"'
check "teams --json carries the reason and its parts for a script" \
  'teamctl teams --json | jq -e ".[] | select(.team == \"later\") | .orphan.lead_end.how == \"finish\" and .orphan.lanes_held == 1 and .orphan.tasks_open == 0 and (.orphan.why | test(\"l2 \\\\(open PR #7\\\\)\"))" >/dev/null'
DRY="$(teamctl reclaim --all-teams --dry-run 2>&1)"
check "a dry sweep while the PR is open keeps it, and says so" \
  'listed later && printf "%s" "$DRY" | grep -E "later" | grep -q "1 lane held: l2 (open PR #7)"'
close_pr "$(br_of later l2)"
L2_DIR="$(dir_of later l2)"
SWEEP3="$(teamctl reclaim --all-teams 2>&1)"
check "once the PR is closed, the next sweep takes the lane AND the team: finish is what authorised it" \
  '! listed later && [ ! -e "$(state_of later)" ] && [ ! -e "$L2_DIR" ] && printf "%s" "$SWEEP3" | grep -qE "later.*finished and gone"'
check "that removal is a team-destroyed line in the ledger, with the sweep as the trigger" \
  'jq -se "[.[] | select(.event == \"team-destroyed\" and .team == \"later\" and .trigger == \"reclaim\")] | length == 1" "$LEDGER" >/dev/null'

# ------------------------------------------------------------------------------------
echo "== every task of the team, and Beads that cannot be asked"
team_with tasks t1
bead demo-ghost tasks.ghost in_progress # a role that is no longer on record still counts
bead demo-note tasks.lead open message  # a message is not a task
bead demo-other other.t1 open           # another team's task is not this team's
FIN3="$(as_lead tasks finish --team tasks 2>&1)"
check "an open task of any member of the team keeps it, and the line names the bead" \
  'listed tasks && printf "%s" "$FIN3" | grep -qE "kept: team .tasks. is holding [0-9.]+ (KB|MB|GB): lead ran teamctl finish [0-9:Z -]+, 1 task open: demo-ghost, 0 lanes held"'
check "an unread message to the lead does not keep it, and another team's task does not either" \
  '! printf "%s" "$FIN3" | grep -q "demo-note" && ! printf "%s" "$FIN3" | grep -q "demo-other"'
bead demo-ghost tasks.ghost closed
bd_mode fail
SWEEP4="$(teamctl reclaim --all-teams 2>&1)"
bd_mode ok
check "when Beads cannot be asked, the team is kept, and the reason quotes Beads" \
  'listed tasks && printf "%s" "$SWEEP4" | grep -E "tasks" | grep -q "tasks unknown (cannot ask Beads (bd failed, exit 3: bd: the database is locked))"'
teamctl reclaim --all-teams >/dev/null 2>&1
check "and once Beads answers that every task is closed, the sweep finishes it" \
  '! listed tasks && [ ! -e "$(state_of tasks)" ]'

# ------------------------------------------------------------------------------------
echo "== finish, run by the lead from a pane of the session it ends"
team_with inside i1
INSIDE_STATE="$(state_of inside)"
INSIDE_SESSION="$(session_of inside)"
# A plain `teamctl destroy` run this way gets the hangup at kill-session, and everything after
# that line may never run. finish kills its own session as the very LAST act.
tmuxt split-window -d -t "=$INSIDE_SESSION:" "cd \"$PROJECT\" && TEAM_ROLE=lead WOLFMUX_TEAM=inside \"$REPO/bin/teamctl\" finish --team inside >\"$WORK/inside.out\" 2>&1"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do has_session "$INSIDE_SESSION" || break; sleep 1; done
sleep 1
check "the session is gone, and so is everything finish had to do before it" \
  '! has_session "$INSIDE_SESSION" && [ ! -e "$INSIDE_STATE" ] && jq -se "[.[] | select(.event == \"team-destroyed\" and .team == \"inside\" and .by == \"inside.lead\")] | length == 1" "$LEDGER" >/dev/null'
check "its last words went to the finish log, which outlives the pane" \
  'grep -q "inside" "$WOLFMUX_DATA/state/finish.log"'

# ------------------------------------------------------------------------------------
echo "== who may finish a team, and looking first"
team_with guard g1
check "a worker of the team cannot finish it (exit 77, nothing touched)" \
  'out="$(TEAM_ROLE=g1 WOLFMUX_TEAM=guard teamctl finish --team guard 2>&1)"; [ $? -eq 77 ] && printf "%s" "$out" | grep -q "reserved for the lead" && listed guard && [ ! -e "$(state_of guard)/lead-end.json" ]'
check "the lead of ANOTHER team cannot finish it either" \
  'TEAM_ROLE=lead WOLFMUX_TEAM=crash teamctl finish --team guard >/dev/null 2>&1; [ $? -eq 77 ] && listed guard'
before="$(cd "$(state_of guard)" && find . -type f -exec md5 -q {} + 2>/dev/null | sort | md5 -q)"
GDRY="$(TEAM_ROLE=g1 WOLFMUX_TEAM=guard teamctl finish --team guard --dry-run 2>&1)"
check "anyone may look: finish --dry-run judges the team, says what it would do, and changes nothing" \
  'printf "%s" "$GDRY" | grep -q "DRY RUN: nothing is deleted" && printf "%s" "$GDRY" | grep -qE "would finish: team .guard." && [ "$(cd "$(state_of guard)" && find . -type f -exec md5 -q {} + 2>/dev/null | sort | md5 -q)" = "$before" ] && has_session "$(session_of guard)" && [ -d "$(dir_of guard g1)" ]'
# The lead's transcript is the one thing that would let a finished team be picked up again
# (claude --resume <id>). finish never deletes it, and the ledger keeps the id.
LEAD_SID="$(st_of guard | jq -r '.agents[] | select(.role == "lead") | .session_id')"
/bin/mkdir -p "$WOLFMUX_CLAUDE_PROJECTS/guard-lead"
printf '{"type":"user"}\n' >"$WOLFMUX_CLAUDE_PROJECTS/guard-lead/$LEAD_SID.jsonl"
as_lead guard finish --team guard >/dev/null 2>&1
check "finish never deletes the lead's transcript, and the ledger keeps its conversation id" \
  '! listed guard && [ -f "$WOLFMUX_CLAUDE_PROJECTS/guard-lead/$LEAD_SID.jsonl" ] && jq -se "[.[] | select(.event == \"team-destroyed\" and .team == \"guard\" and .lead_session == \"$LEAD_SID\")] | length == 1" "$LEDGER" >/dev/null'

# ------------------------------------------------------------------------------------
echo "== the record of the lead's end: written by stop and destroy, cleared by a start"
teamctl start fable --team evid --no-attach --skip-beads >/dev/null 2>&1
remember_session evid
sleep 2
teamctl stop lead --team evid >/dev/null 2>&1
check "a lead stopped by you is recorded as stopped by the operator" \
  '[ "$(end_of evid how)" = "stop" ] && [ "$(end_of evid by)" = "operator" ]'
check "and teams says so in words" \
  'teamctl teams 2>&1 | why_in evid | grep -qE "^  holding [0-9.]+ (KB|MB|GB): lead stopped by you [0-9:Z -]+, "'
teamctl restart lead --team evid >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$(state_of evid)/lead-end.json" ] || break; sleep 1; done
check "a new session of the lead clears the record: only the LAST session's end counts" \
  '[ ! -e "$(state_of evid)/lead-end.json" ] && teamctl --team evid status --json | jq -e ".agents[] | select(.role == \"lead\") | .state == \"running\"" >/dev/null'
teamctl spawn e1 glm53 --team evid --no-kickoff >/dev/null 2>&1
sleep 2
commit_in "$(dir_of evid e1)" evid.txt "work nobody merged" "evid/e1: the work"
bead demo-evid-e1 evid.e1 closed
teamctl destroy --team evid --yes >/dev/null 2>&1
check "a plain teamctl destroy is recorded too, and is not a finish: the team with work left stays listed" \
  '[ "$(end_of evid how)" = "destroy" ] && listed evid && teamctl teams 2>&1 | why_in evid | grep -qE "^  holding [0-9.]+ (KB|MB|GB): you ran teamctl destroy [0-9:Z -]+, 0 tasks open, 1 lane held: e1 \(unpushed at [0-9a-f]+\)$"'

# ------------------------------------------------------------------------------------
echo "== the status bar and the dashboard"
ORPH_N="$(teamctl dashboard --once --json 2>/dev/null | jq '[.projects[].teams[] | select(.state == "orphaned")] | length')"
BADGE="$(teamctl _overview-badge 2>/dev/null)"
check "CONTROL: there are orphaned teams on this test machine" \
  '[ "${ORPH_N:-0}" -ge 2 ]'
check "the status bar carries the orphaned count, and it is the dashboard's count" \
  'printf "%s" "$BADGE" | grep -qE "(^| )orph $ORPH_N( |$)"'
check "it is one line within the 72-character budget" \
  '[ "$(printf "%s\n" "$BADGE" | wc -l | tr -d " ")" = 1 ] && [ "$(printf "%s" "$BADGE" | wc -c | tr -d " ")" -le 72 ]'
check "and it survives cmd_overview_badge's own character filter unchanged" \
  'filtered="$(printf "%s" "$BADGE" | LC_ALL=C tr -dc "A-Za-z0-9 .:/+-")"; [ -n "$BADGE" ] && [ "$BADGE" = "$filtered" ]'
check "with no orphaned team the field is not there at all: no number is good news" \
  'line="$(lib_eval "dash_badge_compose 3 2 1 0 0 1.50 8G 76G 9.2G")"; [ "$line" = "teams 3 run 2 idle 1 load 1.50 mem 8G disk 76G held 9.2G" ]'
check "with orphaned teams the field sits after the counts, before load" \
  'line="$(lib_eval "dash_badge_compose 21 13 93 0 11 3.56 8G 76G 9.2G")"; [ "$line" = "teams 21 run 13 idle 93 orph 11 load 3.56 mem 8G disk 76G held 9.2G" ]'
check "over 72 characters, load is dropped first; mem and disk are never dropped" \
  'line="$(lib_eval "dash_badge_compose 21 13 93 2 11 13.56 18G 176G 99.2G")"; [ "${#line}" -le 72 ] && ! printf "%s" "$line" | grep -q " load " && printf "%s" "$line" | grep -q " mem 18G " && printf "%s" "$line" | grep -q " disk 176G " && printf "%s" "$line" | grep -q " orph 11 "'
check "the bar legend explains the field" \
  'teamctl bar --explain | grep -qE "^  orph +N +"'
DASH="$(teamctl dashboard --once 2>&1)"
check "the dashboard has the one line Ammar asked for: orphaned teams, how many, holding how much" \
  'printf "%s" "$DASH" | grep -qE "orphaned teams: $ORPH_N holding [0-9.]+ (KB|MB|GB)"'
check "and its JSON carries the same count for a script" \
  'teamctl dashboard --once --json | jq -e ".machine.orphaned.teams == $ORPH_N and (.machine.orphaned.kb | type == \"number\")" >/dev/null'

echo "== nothing left behind"
check "no scratch file is left behind by any of it" \
  'grep -q "team-destroyed" "$LEDGER" && [ -z "$(/bin/ls -A "$TMPDIR" | grep "^wolfmux-")" ]'
/bin/ls -A "$TMPDIR" | grep "^wolfmux-" | sed 's/^/        left in TMPDIR: /'

echo
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
