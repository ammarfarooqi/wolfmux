#!/bin/bash
# reclaim.sh — taking a finished lane off the books by itself, and every gate that stops it
# from taking one that is not finished (v1.17.0 stage 2).
#
# This is the one suite about a command that deletes a worktree and a branch, so most of it
# is about lanes that must SURVIVE: one check per gate, each with the reason it has to print.
#
# Fully isolated from any team you have running: its own tmux server (socket
# wolfmux-reclaim-test-<pid>), its own state directory, a throwaway git repository with a
# bare `origin` beside it, stub agents instead of real CLIs. Beads and GitHub are STUBS too
# (a `bd` and a `gh` put first on PATH, answering from files this script writes): nothing
# here asks a real Beads workspace or a real GitHub anything. Needs tmux, git, jq.
#
#   tests/reclaim.sh
# No pipefail: checks end in `grep -q`, which closes the pipe early by design.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-reclaim.XXXXXX")"
# A temporary directory of this suite's own: the gates write scratch files (what Beads said,
# what gh said, an object directory for the squash question), and the last check asserts
# that none is left behind. In the shared one, another team's teamctl would be in the count.
export TMPDIR="$WORK/tmp"
/bin/mkdir -p "$TMPDIR"
export WOLFMUX_HOME="$REPO/config/wolfmux"
export WOLFMUX_BIN_DIR="$REPO/bin"
export WOLFMUX_DATA="$WORK/data"
export WOLFMUX_TMUX_SOCKET="wolfmux-reclaim-test-$$"
export WOLFMUX_LAUNCHER_FABLE="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_ASTRA="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_GLM53="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_FLASH="$REPO/tests/stub-agent"
export WOLFMUX_CLAUDE_PROJECTS="$WORK/claude-projects"
# Run from an agent's pane, the environment carries that agent's team and worktree: all of
# it is dropped, or every command here would act as that agent.
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR WOLFMUX_NOTIFY WOLFMUX_SPLASH TMUX TMUX_PANE
unset WOLFMUX_TEAM WOLFMUX_TEAM_ARG WOLFMUX_SESSION WOLFMUX_WORKTREE WOLFMUX_BRANCH WOLFMUX_MODEL
unset WOLFMUX_DISK_GUARD WOLFMUX_DISK_MIN_GB WOLFMUX_LINK_NODE_MODULES WOLFMUX_AUTO_PRUNE WOLFMUX_HEAVY_LOCK
unset WOLFMUX_AUTO_RECLAIM
teamctl() { "$REPO/bin/teamctl" "$@"; }

passed=0
failed=0
skipped=0
# The body runs in a SUBSHELL, as in tests/disk.sh and for the reason written there: a bare
# `exit 1` inside a check, or a variable read under `set -u` after a chain short-circuited,
# would otherwise end the whole suite, and a truncated run looks exactly like a clean one.
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
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT

# --- Beads and GitHub, as stubs ------------------------------------------------------
# What each one answers is a file under $RECLAIM_STUB, so a check sets up the world it needs
# and reads back exactly what teamctl asked (bd.log, gh.log).
#   bd.mode / gh.mode   ok (default) | fail | hang | garbage
#                       bd only: noworkspace | array | oldbd
#   tasks/<assignee>.json   one bead; `bd list` prints all of them, the way the real one does
#   prs/<branch, / as _>.json   what `gh pr list --head <branch>` prints ([] when absent)
#
# The stub bd answers in the two shapes the real one was measured to give (bd 1.3.0,
# 2026-10-14): a bare array from a plain `bd list --json`, and the same list wrapped as
# {"issues": [...], "meta": {...}} as soon as --brief or --skip-labels is passed. Mode
# `array` gives the bare array whatever the flags, and `oldbd` is a bd that does not know
# those two flags at all.
export RECLAIM_STUB="$WORK/stub"
/bin/mkdir -p "$RECLAIM_STUB/bin" "$RECLAIM_STUB/tasks" "$RECLAIM_STUB/prs" "$RECLAIM_STUB/beads"
/bin/cat >"$RECLAIM_STUB/bin/bd" <<'EOF'
#!/bin/bash
mode="$(/bin/cat "$RECLAIM_STUB/bd.mode" 2>/dev/null || echo ok)"
printf 'bd %s\n' "$*" >>"$RECLAIM_STUB/bd.log"
case "${1:-}" in
  where)
    [ "$mode" != "noworkspace" ] || exit 1
    printf '%s\n' "$RECLAIM_STUB/beads"
    ;;
  list)
    echo "warning: beads.role not configured (GH#2950)." >&2 # the real one says this every time
    case "$mode" in
      fail) echo "bd: the database is locked" >&2; exit 3 ;;
      hang) exec /bin/sleep 30 ;;
      garbage) echo "this is not JSON"; exit 0 ;;
      noworkspace) echo "Error: no beads database found" >&2; exit 1 ;;
    esac
    wrapped=0
    for arg in "$@"; do
      case "$arg" in --brief | --skip-labels) wrapped=1 ;; esac
    done
    if [ "$mode" = "oldbd" ] && [ "$wrapped" -eq 1 ]; then echo "Error: unknown flag: --brief" >&2; exit 1; fi
    [ "$mode" != "array" ] || wrapped=0
    if [ "$wrapped" -eq 1 ]; then
      jq -s '{issues: ., meta: {count: length, skip_labels: true}, schema_version: 1}' "$RECLAIM_STUB"/tasks/*.json 2>/dev/null || echo '{"issues": [], "meta": {"count": 0}, "schema_version": 1}'
    else
      jq -s . "$RECLAIM_STUB"/tasks/*.json 2>/dev/null || echo "[]"
    fi
    ;;
esac
exit 0
EOF
/bin/cat >"$RECLAIM_STUB/bin/gh" <<'EOF'
#!/bin/bash
mode="$(/bin/cat "$RECLAIM_STUB/gh.mode" 2>/dev/null || echo ok)"
printf 'gh %s (in %s)\n' "$*" "$PWD" >>"$RECLAIM_STUB/gh.log"
case "$mode" in
  fail) echo "gh: To get started with GitHub CLI, please run: gh auth login" >&2; exit 4 ;;
  hang) exec /bin/sleep 30 ;;
  garbage) echo "<html>rate limited</html>"; exit 0 ;;
esac
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
gh_mode() { printf '%s\n' "$1" >"$RECLAIM_STUB/gh.mode"; }
# task <assignee> <status> — the one task that assignee has, in that status
task() { printf '{"id":"demo-%s","title":"the work of %s","status":"%s","issue_type":"task","assignee":"%s"}\n' "$1" "$1" "$2" "$1" >"$RECLAIM_STUB/tasks/$1.json"; }
# open_pr <branch> <number>
open_pr() { printf '[{"number":%s}]\n' "$2" >"$RECLAIM_STUB/prs/$(printf '%s' "$1" | tr '/' '_').json"; }

# --- the project, with a remote ------------------------------------------------------
PROJECT="$WORK/demo project" # the space is deliberate
ORIGIN="$WORK/origin.git"
/bin/mkdir -p "$PROJECT"
git init -q --bare -b main "$ORIGIN"
cd "$PROJECT" || exit 1
git init -q -b main
pg() { git -C "$PROJECT" -c user.name=reclaim -c user.email=reclaim@example.invalid "$@"; }
echo "hello" >README.md
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n' >lines.txt
printf 'node_modules/\n.next/\n' >.gitignore
git add -A
pg commit -qm "initial commit"
git remote add origin "$ORIGIN"
git push -q -u origin main >/dev/null 2>&1
# The project's Beads workspace, as far as teamctl looks before it asks bd anything: the
# directory `bd init` makes in the project root. A project without one is never asked.
/bin/mkdir -p "$PROJECT/.beads"
unset BEADS_DIR

# lib_eval <shell code> — run it with teamctl's own libraries loaded and this project
# resolved, so a gate can be asked directly. `set -euo pipefail` is bin/teamctl's own line.
lib_eval() {
  (
    cd "$PROJECT" || exit 1
    bash -c '
      set -euo pipefail
      for m in provider-env common registry tmuxctl worktree disk reclaim beads policy approvals agents views dashboard doctor brand notify layout guard; do
        . "$WOLFMUX_HOME/lib/$m.sh"
      done
      load_project
      eval "$1"' _ "$1"
  )
}
# verdict <role> [<shell code to run first>] — what the gate says about that lane, asked of
# the library directly: "yes: <what proved it>" or "no: <the reason>". `type` first, for the
# reason tests/disk.sh keeps relearning: where the function does not exist, a bare
# `! lib_eval …` reads the failure as "the gate said no" and passes without a gate existing.
verdict() {
  lib_eval "${2:-:}; type reclaim_check >/dev/null 2>&1 || { printf 'no such function'; exit 0; }
    if reclaim_check $1; then printf 'yes: %s' \"\$RECLAIM_PASSED\"; else printf 'no: %s' \"\$RECLAIM_WHY\"; fi
    reclaim_beads_forget" 2>/dev/null
}

kb_of() { du -sk "$@" 2>/dev/null | awk '{ total += $1 } END { print total + 0 }'; }
short() { git -C "$PROJECT" rev-parse --short "$1"; }
# commit_in <worktree> <file> <text> <message>
commit_in() {
  printf '%s\n' "$3" >"$1/$2"
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" -c user.name=lane -c user.email=lane@example.invalid commit -qm "$4"
}
LEDGER="$WOLFMUX_DATA/state/reclaimed.jsonl"

echo "== the instruments: the stubs answer, and plain git cherry misses what it is said to catch"
check "teamctl finds the stub gh and the stub bd, so nothing here reaches a real GitHub or Beads" \
  '[ "$(lib_eval "printf %s \"\$GH_BIN\"")" = "$RECLAIM_STUB/bin/gh" ] && [ "$(lib_eval "printf %s \"\$BD_BIN\"")" = "$RECLAIM_STUB/bin/bd" ]'

teamctl start fable --no-attach --skip-beads >/dev/null 2>&1
# Every lane below is parked with the policy OFF, so that parking removes nothing and each
# gate can be asked on its own. The default (on) has its own block further down.
teamctl policy auto-reclaim off >/dev/null 2>&1
ROLES="done1 squashed picked fresh unpushed pushedonly dirty notes buildonly detached stashy taskopen notask pr kept limit localmain"
for r in $ROLES running; do teamctl spawn "$r" glm53 --no-kickoff >/dev/null 2>&1; done
sleep 3
STATUS="$(teamctl status --json)"
dir_of() { printf '%s' "$STATUS" | jq -r --arg r "$1" '.agents[] | select(.role == $r) | .workdir'; }
br_of() { printf '%s' "$STATUS" | jq -r --arg r "$1" '.agents[] | select(.role == $r) | .branch'; }
tip_of() { git -C "$PROJECT" rev-parse -q --verify "refs/heads/$(br_of "$1")"; }
check "every lane is a real worktree teamctl made, with a real record" \
  '(for r in $ROLES running; do d="$(dir_of "$r")"; [ -n "$d" ] && [ -f "$d/README.md" ] && [ -n "$(br_of "$r")" ] || exit 1; done)'

# What each lane holds.
commit_in "$(dir_of done1)" done1.txt "work" "done1: the work"
commit_in "$(dir_of squashed)" s1.txt "one" "squashed: first"
commit_in "$(dir_of squashed)" s2.txt "two" "squashed: second"
commit_in "$(dir_of squashed)" s3.txt "three" "squashed: third"
commit_in "$(dir_of picked)" p1.txt "one" "picked: first"
commit_in "$(dir_of picked)" p2.txt "two" "picked: second"
commit_in "$(dir_of unpushed)" u.txt "work nobody has" "unpushed: the work"
commit_in "$(dir_of pushedonly)" po.txt "work on the remote" "pushedonly: the work"
for r in dirty notes buildonly detached stashy taskopen notask pr kept localmain; do
  commit_in "$(dir_of "$r")" "$r.txt" "work" "$r: the work"
done
# The known limit: two commits, one of which changes a line whose NEIGHBOUR main will change.
commit_in "$(dir_of limit)" limit.txt "work" "limit: first"
printf 'one\ntwo\nthree\nfour\nfive\nSIX-from-the-lane\nseven\neight\nnine\nten\n' >"$(dir_of limit)/lines.txt"
git -C "$(dir_of limit)" add -A >/dev/null 2>&1
git -C "$(dir_of limit)" -c user.name=lane -c user.email=lane@example.invalid commit -qm "limit: second"

for r in $ROLES; do teamctl stop "$r" >/dev/null 2>&1; done

# What the lead did with them.
pg push -q origin "$(br_of pushedonly)" >/dev/null 2>&1
for r in done1 dirty notes buildonly detached stashy taskopen notask pr kept; do
  pg merge -q --no-ff -m "merge $r" "$(br_of "$r")" >/dev/null 2>&1
done
pg merge -q --squash "$(br_of squashed)" >/dev/null 2>&1
pg commit -qm "squashed: all three as one commit"
SQUASH_SHA="$(git -C "$PROJECT" rev-parse HEAD)"
pg cherry-pick "main..$(br_of picked)" >/dev/null 2>&1
# main changes the line two below the lane's, and only then is the lane squashed in.
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\nEIGHT-from-main\nnine\nten\n' >"$PROJECT/lines.txt"
pg commit -qam "main: a change next to what the limit lane touched"
pg merge -q --squash "$(br_of limit)" >/dev/null 2>&1
pg commit -qm "limit: squashed, after main moved the neighbouring line"
pg push -q origin main >/dev/null 2>&1
PUSHED_MAIN="$(git -C "$PROJECT" rev-parse main)"
# Merged into main AFTER the push, and main is not pushed again: content that is in main and
# nowhere else.
pg merge -q --no-ff -m "merge localmain" "$(br_of localmain)" >/dev/null 2>&1

# What is left lying in some of them.
printf 'work in progress\n' >>"$(dir_of dirty)/README.md"
printf 'notes an agent left\n' >"$(dir_of notes)/NOTES.md"
/bin/mkdir -p "$(dir_of buildonly)/.turbo" && printf 'cache\n' >"$(dir_of buildonly)/.turbo/x"
git -C "$(dir_of detached)" checkout -q --detach >/dev/null 2>&1
commit_in "$(dir_of detached)" loose.txt "a commit on no branch" "detached: on no branch at all"
DETACHED_HEAD="$(git -C "$(dir_of detached)" rev-parse HEAD)"
# A stash made on that detached HEAD says "(no branch)": it can be tied to no lane.
printf 'stashed on no branch\n' >>"$(dir_of detached)/README.md"
git -C "$(dir_of detached)" -c user.name=lane -c user.email=lane@example.invalid stash push -q -m "nobody's" >/dev/null 2>&1
printf 'stashed away\n' >>"$(dir_of stashy)/README.md"
git -C "$(dir_of stashy)" -c user.name=lane -c user.email=lane@example.invalid stash push -q -m "half an idea" >/dev/null 2>&1
STASH_SHA="$(git -C "$PROJECT" stash list --format='%H %gs' | grep 'half an idea' | cut -d' ' -f1)"
teamctl keep kept >/dev/null 2>&1

# Beads and GitHub.
for r in $ROLES; do task "$r" closed; done
task taskopen in_progress
/bin/rm -f "$RECLAIM_STUB/tasks/notask.json"
open_pr "$(br_of pr)" 7

# The positive control the brief asked for. `git cherry` compares commit by commit, so three
# commits squashed into one read as three commits that are nowhere: this is pure git, it
# passes on every tree, and it is what makes the squash check below mean something.
check "CONTROL: plain git cherry reports all three commits of a squashed lane as missing from main" \
  '[ "$(git -C "$PROJECT" cherry main "$(br_of squashed)" | grep -c "^+")" = "3" ]'
check "CONTROL: and a containment test agrees with it, which is the answer the brief warned about" \
  '! git -C "$PROJECT" merge-base --is-ancestor "$(br_of squashed)" main'

echo "== gate by gate: a lane that passes every one"
check "a lane whose task is closed, whose content is merged, with nothing uncommitted and no PR, passes" \
  'verdict done1 | grep -q "^yes: content in origin/main (merged, at $(short "$PUSHED_MAIN"))"'
check "the line that says why it passed names the closed task and the PR answer too" \
  'verdict done1 | grep -q "task closed (demo-done1)" && verdict done1 | grep -q "no open PR"'
check "a lane that never committed anything has nothing to lose, and passes once its task is closed" \
  'verdict fresh | grep -q "^yes: content in"'
check "untracked build output is not work: a lane holding only that still passes" \
  '[ -d "$(dir_of buildonly)/.turbo" ] && verdict buildonly | grep -q "^yes: content in"'

echo "== gate 3: is the content really in main"
check "a lane with an unpushed, unmerged commit is KEPT, and the reason names the tip" \
  '[ "$(verdict unpushed)" = "no: unpushed at $(short "$(tip_of unpushed)")" ]'
check "a lane that is on the remote but not merged says unmerged instead: it could be fetched back" \
  '[ "$(verdict pushedonly)" = "no: unmerged at $(short "$(tip_of pushedonly)")" ]'
check "a lane whose three commits were SQUASHED into one passes, which plain git cherry cannot see" \
  'verdict squashed | grep -q "^yes: content in origin/main (squashed as $(short "$SQUASH_SHA"))"'
# The throwaway commit that question needs is written to a scratch object directory, never
# into the repository. Asked on a path that does not exist the check below would pass for
# nothing, so its first half is the verdict itself: the squash WAS judged, and it left no
# object behind. (git count-objects counts loose objects, which is where a commit-tree lands.)
check "judging a squash leaves nothing in the repository: not one object more than before" \
  'before="$(git -C "$PROJECT" count-objects | cut -d" " -f1)" && verdict squashed | grep -q "(squashed as " && [ "$(git -C "$PROJECT" count-objects | cut -d" " -f1)" = "$before" ] && [ -z "$(/bin/ls -A "$TMPDIR" | grep "^wolfmux-reclaim-objects")" ]'
check "a lane whose commits were cherry-picked passes: every one of them has an equal in main" \
  'verdict picked | grep -q "^yes: content in origin/main (cherry-picked, at $(short "$PUSHED_MAIN"))"'
check "content that is in main and not on any remote still counts, and the line says main is not pushed" \
  'verdict localmain | grep -q "^yes: content in main (merged, at $(short "$(git -C "$PROJECT" rev-parse main)"); main is not pushed)"'
# The limit, pinned: main changed the line next to the lane's hunk before the squash, so the
# patch id of the squash differs from the lane's own and nothing matches. The lane is KEPT.
# A false keep costs disk and says so; the other direction would cost work.
check "KNOWN LIMIT: squashed after main changed a neighbouring line, the lane is KEPT, not removed" \
  '[ "$(verdict limit)" = "no: unpushed at $(short "$(tip_of limit)")" ]'
check "the team's integration branch counts as well as main: content merged there passes" \
  'B="$(br_of unpushed)" && pg checkout -q -b integration >/dev/null 2>&1 && pg merge -q --no-ff -m "into integration" "$B" >/dev/null 2>&1 && out="$(verdict unpushed)"; pg checkout -q main >/dev/null 2>&1; printf "%s" "$out" | grep -q "^yes: content in integration (merged, at "'
check "and once the checkout is back on main, that same lane is kept again: integration is not main" \
  '[ "$(verdict unpushed)" = "no: unpushed at $(short "$(tip_of unpushed)")" ]'

echo "== gate 4: nothing uncommitted, nothing on no branch, nothing stashed"
check "an uncommitted change to a tracked file keeps the lane, and the reason says dirty" \
  '[ "$(verdict dirty)" = "no: dirty: 1 uncommitted file" ]'
check "an untracked file that is not build output keeps the lane too" \
  '[ "$(verdict notes)" = "no: dirty: 1 uncommitted file" ]'
# Nobody asked for this one and it is how work was lost on 2026-10-13: commits that only a
# worktree's HEAD holds are dangling the moment the worktree goes.
check "a worktree whose HEAD is not the tip of its branch is kept, and the reason names THAT sha" \
  '[ "$(verdict detached)" = "no: its worktree is at $(short "$DETACHED_HEAD"), which is not the tip of its branch" ]'
check "a stash made on the lane's branch keeps the lane, with the count and the newest sha" \
  '[ "$(verdict stashy)" = "no: 1 stash entry on its branch, newest $(short "$STASH_SHA")" ]'
# refs/stash is ONE list for the whole repository, not one per worktree: measured, a lane's
# entry survives the removal of its worktree and its branch. So a stash made somewhere else
# must not hold every lane of the repository hostage.
check "a stash made on ANOTHER branch does not keep this lane: the stash list is the whole repository's" \
  'git -C "$PROJECT" stash list | grep -q "half an idea" && [ "$(git -C "$(dir_of done1)" stash list | wc -l | tr -d " ")" = "2" ] && verdict done1 | grep -q "^yes: "'
check "CONTROL: git itself shows the lane's stash from the main checkout, which is why the gate reads branch names" \
  'git -C "$PROJECT" stash list --format="%gs" | grep -q "^On $(br_of stashy): half an idea"'

echo "== gate 2: the task bead"
check "a lane whose task is still open is kept, and the reason names the bead" \
  '[ "$(verdict taskopen)" = "no: task open (demo-taskopen)" ]'
check "a lane with no task at all is kept: whether its work is done has no answer" \
  '[ "$(verdict notask)" = "no: no task bead on record" ]'
# Two lanes above already show that a lane is judged by its OWN tasks: `notask` stays although
# sixteen other lanes have a closed task, and `done1` goes although `taskopen` has an open one.
check "Beads is asked for closed tasks as well as open ones: a closed task is what says a lane is done" \
  'grep "^bd list " "$RECLAIM_STUB/bd.log" | grep -q -- "--all"'
# What a question costs: 4 to 33 seconds each on the machine this was written on, under load.
# So Beads is asked once for the whole project, never once per lane.
check "Beads is asked ONCE per run, however many lanes there are to judge" \
  ': >"$RECLAIM_STUB/bd.log"; teamctl reclaim --dry-run >/dev/null 2>&1; [ "$(grep -c "^bd list " "$RECLAIM_STUB/bd.log")" = "1" ]'
# The real bd wraps its list in an object as soon as --brief or --skip-labels is passed, and
# prints a bare array without them. The stub does the same; both have to be read.
check "the answer is read in both shapes bd gives it: the wrapped list and the bare array" \
  'verdict done1 | grep -q "task closed (demo-done1)" && grep "^bd list " "$RECLAIM_STUB/bd.log" | tail -1 | grep -q -- "--brief" && bd_mode array && out="$(verdict done1)"; bd_mode ok; printf "%s" "$out" | grep -q "task closed (demo-done1)"'
check "a bd too old to know --brief is asked once more without it, and its answer is used" \
  'bd_mode oldbd; : >"$RECLAIM_STUB/bd.log"; out="$(verdict done1)"; bd_mode ok; printf "%s" "$out" | grep -q "^yes: .*task closed (demo-done1)" && [ "$(grep -c "^bd list " "$RECLAIM_STUB/bd.log")" = "2" ]'
# The reason carries bd's own last line: its warnings come first, what stopped it comes last.
check "when bd fails, the lane is kept and the reason says what bd said" \
  'bd_mode fail; out="$(verdict done1)"; bd_mode ok; [ "$out" = "no: cannot ask Beads (bd failed, exit 3: bd: the database is locked)" ]'
check "when bd answers with something that is not a list of beads, the lane is kept" \
  'bd_mode garbage; out="$(verdict done1)"; bd_mode ok; [ "$out" = "no: cannot ask Beads (its answer could not be read)" ]'
check "when bd says there is no database, the lane is kept, with bd's own words" \
  'bd_mode noworkspace; out="$(verdict done1)"; bd_mode ok; [ "$out" = "no: cannot ask Beads (bd failed, exit 1: Error: no beads database found)" ]'
# A team that runs without Beads must not pay for a question nobody can answer: bd is not
# called at all. The control is the line before it in the log — bd WAS called a moment ago,
# with the workspace there.
check "a project with no Beads workspace is kept without bd being asked at all" \
  'verdict done1 >/dev/null; n="$(grep -c "^bd list " "$RECLAIM_STUB/bd.log")"; [ "$n" -ge 1 ] && /bin/mv "$PROJECT/.beads" "$PROJECT/.beads.off" && out="$(verdict done1)"; /bin/mv "$PROJECT/.beads.off" "$PROJECT/.beads"; printf "%s" "$out" | grep -q "^no: cannot ask Beads (no Beads workspace in " && [ "$(grep -c "^bd list " "$RECLAIM_STUB/bd.log")" = "$n" ]'
check "and a workspace kept somewhere else is found through BEADS_DIR" \
  '/bin/mv "$PROJECT/.beads" "$PROJECT/.beads.off" && out="$(BEADS_DIR="$RECLAIM_STUB/beads" verdict done1)"; /bin/mv "$PROJECT/.beads.off" "$PROJECT/.beads"; printf "%s" "$out" | grep -q "^yes: .*task closed (demo-done1)"'
check "when bd is not installed at all, the lane is kept" \
  '[ "$(verdict done1 "BD_BIN=")" = "no: cannot ask Beads (bd is not installed)" ]'
# bd hung for over a minute twice on the machine this was written on. A hang is "cannot
# tell", and it must be a bounded one: the check is on the answer AND on the clock.
check "when bd hangs, the gate gives up after its time limit and keeps the lane" \
  'bd_mode hang; start="$(date +%s)"; out="$(verdict done1 "RECLAIM_ASK_SECONDS=2")"; took=$(( $(date +%s) - start )); bd_mode ok; [ "$out" = "no: cannot ask Beads (bd did not answer in 2 s)" ] && [ "$took" -le 15 ]'

echo "== gate 5: no open pull request"
check "a lane with an open PR is kept, and the reason names the PR" \
  '[ "$(verdict pr)" = "no: open PR #7" ]'
check "gh is asked about that branch, for open PRs only, from the lane's own repository" \
  'grep -- "--head $(br_of pr) " "$RECLAIM_STUB/gh.log" | grep -- "--state open" | grep -q "(in $(cd "$PROJECT" && pwd -P))"'
check "when gh fails, the lane is kept: deleting a worktree under a reviewer has been paid for once" \
  'gh_mode fail; out="$(verdict done1)"; gh_mode ok; [ "$out" = "no: cannot ask GitHub (gh failed, exit 4: gh: To get started with GitHub CLI, please run: gh auth login)" ]'
check "when gh answers with something that is not a list of PRs, the lane is kept" \
  'gh_mode garbage; out="$(verdict done1)"; gh_mode ok; [ "$out" = "no: cannot ask GitHub (its answer could not be read)" ]'
check "when gh is not installed at all, the lane is kept" \
  '[ "$(verdict done1 "GH_BIN=")" = "no: cannot ask GitHub (gh is not installed)" ]'
check "when gh hangs, the gate gives up after its time limit and keeps the lane" \
  'gh_mode hang; start="$(date +%s)"; out="$(verdict done1 "RECLAIM_ASK_SECONDS=2")"; took=$(( $(date +%s) - start )); gh_mode ok; [ "$out" = "no: cannot ask GitHub (gh did not answer in 2 s)" ] && [ "$took" -le 15 ]'
# GitHub is the slow question and the one that needs a network, so it is asked last and only
# of a lane that every other gate has already let through.
# The first half is the control: gh WAS asked about the lane that reached that gate, so the
# silence about the other two is a decision and not a gh nobody ever calls. The log is
# emptied first: `unpushed` did reach gh once above, rightly, while its content sat in the
# integration branch.
check "gh is never asked about a lane that an earlier gate already keeps" \
  ': >"$RECLAIM_STUB/gh.log"; verdict pr >/dev/null; verdict taskopen >/dev/null; verdict unpushed >/dev/null; grep -q -- "--head $(br_of pr) " "$RECLAIM_STUB/gh.log" && ! grep -q -- "--head $(br_of taskopen) " "$RECLAIM_STUB/gh.log" && ! grep -q -- "--head $(br_of unpushed) " "$RECLAIM_STUB/gh.log"'

echo "== the two that are never asked anything"
check "a lane the lead protects with teamctl keep is kept, whatever else is true of it" \
  '[ "$(verdict kept)" = "no: teamctl keep protects this lane" ]'
check "a running lane is never touched" \
  'verdict running | grep -q "^no: it is still running"'
check "the lead is not a lane: it works in your own checkout" \
  'verdict lead | grep -q "^no: it works in your own checkout"'

echo "== teamctl reclaim --dry-run: every parked lane, what would go and what holds the rest"
DRY="$(teamctl reclaim --dry-run 2>&1)"
check "the dry run says plainly that nothing is deleted" \
  'printf "%s" "$DRY" | grep -q "DRY RUN: nothing is deleted"'
check "it names every lane that would go, with its branch and the sha that branch is at" \
  '(for r in done1 squashed picked fresh buildonly localmain; do printf "%s" "$DRY" | grep -E "^  $r +[0-9.]+ (KB|MB|GB) +would remove: " | grep -q "$(br_of "$r") was at $(tip_of "$r")" || exit 1; done)'
check "it names every lane that stays, with what that lane holds and why" \
  'printf "%s" "$DRY" | grep -qE "^  unpushed +[0-9.]+ (KB|MB|GB) +holding: unpushed at $(short "$(tip_of unpushed)")" && printf "%s" "$DRY" | grep -qE "^  pr +[0-9.]+ (KB|MB|GB) +holding: open PR #7" && printf "%s" "$DRY" | grep -qE "^  taskopen +[0-9.]+ (KB|MB|GB) +holding: task open \(demo-taskopen\)" && printf "%s" "$DRY" | grep -qE "^  dirty +[0-9.]+ (KB|MB|GB) +holding: dirty: 1 uncommitted file"'
check "a running lane is listed as left alone" \
  'printf "%s" "$DRY" | grep -qE "^  running +[0-9.]+ (KB|MB|GB) +running, left alone"'
check "it adds up what would be freed and what is still held" \
  'printf "%s" "$DRY" | grep -qE "^  total +[0-9.]+ (KB|MB|GB) +is what this would free in 6 parked lanes \(1 running, 11 holding [0-9.]+ (KB|MB|GB)\)"'
# A stash made on a detached HEAD belongs to no branch, so no lane is kept for it. It is
# said once per repository, so that somebody who is missing something has a place to look.
check "a stash on no branch keeps no lane, and is named once for the repository it is in" \
  '[ "$(printf "%s\n" "$DRY" | grep -c "1 stash entry on no branch (not attributed to any lane)")" = "1" ]'
# "Nothing was deleted" is true of a command that does not exist, too. So it only counts
# next to the sign that the dry run really judged these lanes.
check "and it deleted nothing: every worktree, every branch and every record is still there" \
  'printf "%s" "$DRY" | grep -q "would remove: " && (for r in $ROLES; do [ -d "$(dir_of "$r")" ] && git -C "$PROJECT" show-ref --verify -q "refs/heads/$(br_of "$r")" || exit 1; done) && [ "$(teamctl status --json | jq ".agents | length")" = "19" ]'
check "a worker may look, because looking is not changing" \
  'TEAM_ROLE=done1 teamctl reclaim --dry-run >/dev/null 2>&1'
# The MESSAGE, not just the status: an unknown command exits 64 as well.
check "an unknown option is a usage error that names the real usage" \
  'out="$(teamctl reclaim --nonsense 2>&1)"; [ $? -eq 64 ] && printf "%s" "$out" | grep -q -- "teamctl reclaim \[--team <name>\] \[--all-teams\] \[--dry-run\]"'
check "a worker cannot run it for real: it is the lead's call (exit 77, and nothing is touched)" \
  'out="$(TEAM_ROLE=done1 teamctl reclaim 2>&1)"; [ $? -eq 77 ] && printf "%s" "$out" | grep -q "teamctl reclaim. is reserved for the lead" && [ -d "$(dir_of done1)" ]'

echo "== teamctl reclaim: the lanes that pass go, and every sha is said before anything is deleted"
GONE="done1 squashed picked fresh buildonly localmain"
STAY="unpushed pushedonly dirty notes detached stashy taskopen notask pr kept limit"
for r in $GONE; do eval "TIP_$r=\$(tip_of $r)"; eval "KB_$r=\$(kb_of \"\$(dir_of $r)\")"; done
/bin/rm -f "$LEDGER"
RUN="$(teamctl reclaim 2>&1)"
check "every lane that passed is gone: its worktree, its branch and its record" \
  '(for r in $GONE; do [ ! -e "$(dir_of "$r")" ] && ! git -C "$PROJECT" show-ref --verify -q "refs/heads/$(br_of "$r")" && [ -z "$(teamctl status --json | jq -r --arg r "$r" ".agents[] | select(.role == \$r) | .role")" ] || exit 1; done)'
check "every lane that did not pass is untouched: worktree, branch, record and its commits" \
  'printf "%s" "$RUN" | grep -q " removed: " && (for r in $STAY; do [ -f "$(dir_of "$r")/README.md" ] && [ "$(git -C "$PROJECT" rev-parse -q --verify "refs/heads/$(br_of "$r")")" = "$(git -C "$(dir_of "$r")" rev-parse "$(br_of "$r")")" ] && [ -n "$(teamctl status --json | jq -r --arg r "$r" ".agents[] | select(.role == \$r) | .role")" ] || exit 1; done) && [ -f "$(dir_of unpushed)/u.txt" ] && [ -f "$(dir_of dirty)/README.md" ] && [ -f "$(dir_of notes)/NOTES.md" ]'
check "the running lane is still running, with everything it had" \
  'printf "%s" "$RUN" | grep -qE "^  running +[0-9.]+ (KB|MB|GB) +running, left alone" && [ -d "$(dir_of running)" ] &&[ "$(teamctl status --json | jq -r ".agents[] | select(.role == \"running\") | .state")" = "running" ]'
check "for every lane it removed, it printed the branch and the full sha that branch was at" \
  '(for r in $GONE; do eval "t=\$TIP_$r"; printf "%s" "$RUN" | grep -q "$r: branch $(br_of "$r") was at $t" || exit 1; done)'
check "and it printed that BEFORE the line that reports the removal, lane by lane" \
  '(for r in $GONE; do a="$(printf "%s\n" "$RUN" | grep -n "$r: branch $(br_of "$r") was at " | head -1 | cut -d: -f1)"; b="$(printf "%s\n" "$RUN" | grep -nE "^  $r +[0-9.]+ (KB|MB|GB) +removed: " | head -1 | cut -d: -f1)"; [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || exit 1; done)'
check "the sha it printed is enough to bring a removed lane back: the commit is still in the repository" \
  '! git -C "$PROJECT" show-ref --verify -q "refs/heads/$(br_of squashed)" && printf "%s" "$RUN" | grep -q "was at $TIP_squashed" && [ "$(git -C "$PROJECT" cat-file -t "$TIP_squashed")" = "commit" ] && git -C "$PROJECT" branch brought-back "$TIP_squashed" >/dev/null 2>&1 && [ "$(git -C "$PROJECT" log --format=%s -1 brought-back)" = "squashed: third" ] && git -C "$PROJECT" branch -D brought-back >/dev/null 2>&1'
check "the line that reports a removal says why the lane passed" \
  'printf "%s" "$RUN" | grep -E "^  squashed +[0-9.]+ (KB|MB|GB) +removed: " | grep -q "content in origin/main (squashed as $(short "$SQUASH_SHA")) · task closed (demo-squashed) · no open PR"'
check "a lane whose content is only in a main nobody has pushed is removed, and the line says so" \
  'printf "%s" "$RUN" | grep -E "^  localmain +[0-9.]+ (KB|MB|GB) +removed: " | grep -q "main is not pushed"'
check "it adds up what it freed and what is still held" \
  'printf "%s" "$RUN" | grep -qE "^  total +[0-9.]+ (KB|MB|GB) +freed from 6 parked lanes \(1 running, 11 holding [0-9.]+ (KB|MB|GB)\)"'

echo "== the ledger: every removal, with the sha that proved it"
check "every removal is one line in ~/.wolfmux/state/reclaimed.jsonl: team, role, bytes, a timestamp" \
  '(for r in $GONE; do jq -se --arg r "$r" "[.[] | select(.event == \"lane-removed\" and .role == \$r and .team == \"default\" and .trigger == \"reclaim\" and (.ts | test(\"^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T\")) and (.project | length > 0) and (.by | length > 0))] | length == 1" "$LEDGER" >/dev/null || exit 1; done)'
check "the bytes in the ledger are the bytes the lane really held, not a rounded label" \
  '(for r in done1 squashed; do eval "kb=\$KB_$r"; [ "$(jq -r --arg r "$r" "select(.role == \$r) | .freed_kb" "$LEDGER")" = "$kb" ] || exit 1; done)'
check "the ledger keeps the branch and the full tip sha: scrollback is not a record" \
  '(for r in $GONE; do eval "t=\$TIP_$r"; [ "$(jq -r --arg r "$r" "select(.role == \$r) | .tip" "$LEDGER")" = "$t" ] && [ "$(jq -r --arg r "$r" "select(.role == \$r) | .branch" "$LEDGER")" = "$(br_of "$r")" ] || exit 1; done)'
check "it keeps the reason the lane passed, and the sha that proved the content is in main" \
  '[ "$(jq -r "select(.role == \"squashed\") | .proof.sha" "$LEDGER")" = "$SQUASH_SHA" ] && [ "$(jq -r "select(.role == \"squashed\") | .proof.how" "$LEDGER")" = "squashed" ] && [ "$(jq -r "select(.role == \"done1\") | .proof.sha" "$LEDGER")" = "$PUSHED_MAIN" ] && [ "$(jq -r "select(.role == \"done1\") | .proof.ref" "$LEDGER")" = "origin/main" ] && jq -r "select(.role == \"done1\") | .reason" "$LEDGER" | grep -q "task closed (demo-done1)"'
check "a removal out of a main that is not pushed says so in the ledger, not only on the screen" \
  '[ "$(jq -r "select(.role == \"localmain\") | .main_pushed" "$LEDGER")" = "false" ] && [ "$(jq -r "select(.role == \"done1\") | .main_pushed" "$LEDGER")" = "true" ]'
check "no lane that was kept is in the ledger" \
  '[ -s "$LEDGER" ] && (for r in $STAY running; do [ -z "$(jq -r --arg r "$r" "select(.role == \$r) | .role" "$LEDGER")" ] || exit 1; done)'
check "the team's own event log has the removal too, with the tip" \
  'jq -se "[.[] | select(.type == \"reclaim\" and .role == \"done1\" and (.detail | test(\"tip=$TIP_done1\")))] | length == 1" "$(lib_eval "printf %s \"\$STATE_DIR\"")/events.jsonl" >/dev/null'

echo "== teamctl status: a lane that cannot go says what it holds and why"
ST="$(teamctl status 2>&1)"
check "status shows a kept lane as holding <size>: <reason>, with the sha for an unpushed one" \
  'printf "%s" "$ST" | grep -qE "holding [0-9.]+ (KB|MB|GB): unpushed at $(short "$(tip_of unpushed)")"'
check "each of the brief's reasons is worded the way it was asked for: unmerged, open PR, task open, dirty" \
  'printf "%s" "$ST" | grep -qE "holding [0-9.]+ (KB|MB|GB): unmerged at $(short "$(tip_of pushedonly)")" && printf "%s" "$ST" | grep -qE "holding [0-9.]+ (KB|MB|GB): open PR #7" && printf "%s" "$ST" | grep -qE "holding [0-9.]+ (KB|MB|GB): task open \(demo-taskopen\)" && printf "%s" "$ST" | grep -qE "holding [0-9.]+ (KB|MB|GB): dirty: 1 uncommitted file"'
check "a running lane has no such line: it is working, not holding" \
  '[ "$(printf "%s\n" "$ST" | grep -c "holding ")" = "11" ]'
check "status --json carries the same: what is held, why, and when that was checked" \
  'teamctl status --json | jq -e ".agents[] | select(.role == \"unpushed\") | (.holding.reason | startswith(\"unpushed at \")) and (.holding.kb > 0) and (.holding.checked_at | test(\"^[0-9][0-9][0-9][0-9]-\"))" >/dev/null && teamctl status --json | jq -e ".agents[] | select(.role == \"running\") | .holding == null" >/dev/null'
check "status reads what the last check wrote down: it asks neither Beads nor GitHub itself" \
  ': >"$RECLAIM_STUB/bd.log"; : >"$RECLAIM_STUB/gh.log"; teamctl status | grep -q "holding .*: open PR #7" && teamctl status --json | jq -e ".agents[] | select(.role == \"taskopen\") | .holding.reason == \"task open (demo-taskopen)\"" >/dev/null && [ ! -s "$RECLAIM_STUB/bd.log" ] && [ ! -s "$RECLAIM_STUB/gh.log" ]'

echo "== the knob: auto-reclaim, on by default, and off when nobody can read it"
# Both halves, on purpose: a tree that does not know the key refuses EVERY value with 64.
check "a policy value that is not on|off is refused (exit 64), and both real values are taken" \
  'teamctl policy auto-reclaim sometimes >/dev/null 2>&1; [ $? -eq 64 ] && teamctl policy auto-reclaim on >/dev/null 2>&1 && teamctl policy auto-reclaim off >/dev/null 2>&1'
check "teamctl policy shows the key with its value and its choices" \
  'teamctl policy | grep -Eq "^  auto-reclaim +(on|off) +\(on\|off\)"'
check "status --json shows it with the other policies" \
  '[ "$(teamctl status --json | jq -r ".policy.auto_reclaim")" = "off" ]'
# The v1.16.0 lesson: a knob that is not on WOLFMUX_CONFIG_KEYS is read out of the config
# file and dropped, with no error and no effect.
/bin/mkdir -p "$WORK/cfg"
printf 'WOLFMUX_AUTO_RECLAIM=off\n' >"$WORK/cfg/config"
check "WOLFMUX_AUTO_RECLAIM really survives a round trip through ~/.config/wolfmux/config" \
  '[ "$(lib_eval "WOLFMUX_HOME=$WORK/cfg; wolfmux_load_config; printf %s \"\$WOLFMUX_AUTO_RECLAIM\"")" = "off" ]'
check "and the policy default is what that file says, with no stored value in the way" \
  'META="$(lib_eval "printf %s \"\$STATE_DIR/meta.json\"")" && jq "del(.policy_auto_reclaim)" "$META" >"$META.t" && /bin/mv "$META.t" "$META" && [ "$(lib_eval "WOLFMUX_HOME=$WORK/cfg; wolfmux_load_config; policy_get auto-reclaim")" = "off" ]'
check "the default with no file and nothing set is on" \
  '[ "$(lib_eval "policy_get auto-reclaim")" = "on" ] && [ "$(WOLFMUX_AUTO_RECLAIM=on lib_eval "policy_get auto-reclaim")" = "on" ]'
# The asymmetry with auto-prune is deliberate and it is the point of this check: a sweep of
# build output costs a rebuild, this one deletes source, so a value nobody can read is "do
# nothing" here.
check "a value nobody can read is OFF: an unreadable setting is not permission to delete a lane" \
  '[ "$(WOLFMUX_AUTO_RECLAIM=banana lib_eval "policy_get auto-reclaim")" = "off" ] && [ "$(WOLFMUX_AUTO_RECLAIM=08 lib_eval "policy_get auto-reclaim")" = "off" ] && [ "$(WOLFMUX_AUTO_RECLAIM= lib_eval "policy_get auto-reclaim")" = "on" ]'

echo "== the default: parking a finished lane takes it off the books"
teamctl policy auto-reclaim on >/dev/null 2>&1
for r in autodone autolate autonext autokeep; do teamctl spawn "$r" glm53 --no-kickoff >/dev/null 2>&1; done
sleep 3
STATUS="$(teamctl status --json)"
for r in autodone autolate autokeep; do commit_in "$(dir_of "$r")" "$r.txt" "work" "$r: the work"; task "$r" closed; done
pg merge -q --no-ff -m "merge autodone" "$(br_of autodone)" >/dev/null 2>&1
pg merge -q --no-ff -m "merge autokeep" "$(br_of autokeep)" >/dev/null 2>&1
AUTODONE_TIP="$(tip_of autodone)"
STOP1="$(teamctl stop autodone 2>&1)"
check "stopping a lane whose work is all in main removes it then and there" \
  '[ ! -e "$(dir_of autodone)" ] && ! git -C "$PROJECT" show-ref --verify -q "refs/heads/$(br_of autodone)" && [ -z "$(teamctl status --json | jq -r ".agents[] | select(.role == \"autodone\") | .role")" ]'
check "it says where the branch was before it says the lane is gone" \
  'a="$(printf "%s\n" "$STOP1" | grep -n "autodone: branch $(br_of autodone) was at $AUTODONE_TIP" | head -1 | cut -d: -f1)"; b="$(printf "%s\n" "$STOP1" | grep -n "^reclaimed: autodone" | head -1 | cut -d: -f1)"; [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]'
check "the stop line no longer claims the worktree is untouched, and names both ways to keep a lane" \
  '! printf "%s" "$STOP1" | grep -q "are untouched" && printf "%s" "$STOP1" | grep -q "teamctl keep autodone" && printf "%s" "$STOP1" | grep -q "teamctl policy auto-reclaim off"'
check "that removal is in the ledger with stop as the trigger" \
  'jq -se "[.[] | select(.event == \"lane-removed\" and .role == \"autodone\" and .trigger == \"stop\" and .tip == \"$AUTODONE_TIP\")] | length == 1" "$LEDGER" >/dev/null'
STOP2="$(teamctl stop autolate 2>&1)"
check "stopping a lane whose work is NOT in main keeps it, and says what it holds and why" \
  '[ -f "$(dir_of autolate)/autolate.txt" ] && printf "%s" "$STOP2" | grep -qE "holding [0-9.]+ (KB|MB|GB): unpushed at $(short "$(tip_of autolate)")" && printf "%s" "$STOP2" | grep -q "are untouched"'
# The lane that was parked BEFORE its merge: nobody has to remember it. The next time a lane
# of the team is parked, every parked lane is asked again.
pg merge -q --no-ff -m "merge autolate" "$(br_of autolate)" >/dev/null 2>&1
AUTOLATE_TIP="$(tip_of autolate)"
STOP3="$(teamctl stop autonext 2>&1)"
check "a lane parked before its merge goes at the next park, without anyone asking" \
  '[ ! -e "$(dir_of autolate)" ] && printf "%s" "$STOP3" | grep -q "autolate: branch $(br_of autolate) was at $AUTOLATE_TIP" && printf "%s" "$STOP3" | grep -q "^reclaimed: autolate"'
check "and the lane that was just parked is kept, because it has no task that says its work is done" \
  '[ -d "$(dir_of autonext)" ] && printf "%s" "$STOP3" | grep -qE "holding [0-9.]+ (KB|MB|GB): no task bead on record"'
teamctl keep autokeep >/dev/null 2>&1
STOP4="$(teamctl stop autokeep 2>&1)"
# The whole line, not the phrase: stage 1's sweep says "teamctl keep protects this lane"
# about the build output, so the phrase alone passes on a tree with no reclaim in it.
check "teamctl keep protects a finished lane from this as well as from the sweep" \
  '[ -f "$(dir_of autokeep)/autokeep.txt" ] && printf "%s" "$STOP4" | grep -qE "^lane: +holding [0-9.]+ (KB|MB|GB): teamctl keep protects this lane"'

echo "== git has the last word: a worktree it will not remove is a lane that stays"
# The removal never passes --force, so git's own refusal keeps a lane that every gate let
# through. A locked worktree is the plain case (one holding populated submodules is the
# other). By then the ledger already says "lane-removed", because the sha has to be on record
# before anything may go, so the ledger has to take that back in a second line.
teamctl spawn autolock glm53 --no-kickoff >/dev/null 2>&1
sleep 2
STATUS="$(teamctl status --json)"
commit_in "$(dir_of autolock)" autolock.txt "work" "autolock: the work"
task autolock closed
pg merge -q --no-ff -m "merge autolock" "$(br_of autolock)" >/dev/null 2>&1
AUTOLOCK_TIP="$(tip_of autolock)"
git -C "$PROJECT" worktree lock "$(dir_of autolock)" >/dev/null 2>&1
STOP6="$(teamctl stop autolock 2>&1)"
# Asked once the lane is parked: a running lane is kept by gate 1 and would say nothing here.
check "the eight gates have nothing against a locked worktree: git alone knows it will refuse" \
  'case "$(verdict autolock)" in "yes: content in "*"(merged, at "*) true ;; *) false ;; esac'
# The "was at" line is the control: without it this passes on a tree that never tries.
check "a lane git refuses to remove stays whole: worktree, branch and record" \
  'printf "%s" "$STOP6" | grep -q "autolock: branch $(br_of autolock) was at $AUTOLOCK_TIP" && [ -f "$(dir_of autolock)/autolock.txt" ] && [ "$(tip_of autolock)" = "$AUTOLOCK_TIP" ] && [ -n "$(teamctl status --json | jq -r ".agents[] | select(.role == \"autolock\") | .role")" ]'
check "the reason is git's own words, and nothing claims the lane was reclaimed" \
  'printf "%s" "$STOP6" | grep -qE "^lane: +holding [0-9.]+ (KB|MB|GB): git refused to remove its worktree: cannot remove a locked working tree" && ! printf "%s" "$STOP6" | grep -q "^reclaimed: autolock"'
check "the ledger takes back the removal it had written down: lane-kept after lane-removed, same tip" \
  'jq -se "[.[] | select(.role == \"autolock\")] | length == 2 and .[0].event == \"lane-removed\" and .[1].event == \"lane-kept\" and .[1].tip == \"$AUTOLOCK_TIP\" and .[1].trigger == \"stop\" and (.[1].reason | test(\"locked working tree\"))" "$LEDGER" >/dev/null'
check "teamctl status repeats that reason for the lane" \
  'teamctl status | grep -qE "holding [0-9.]+ (KB|MB|GB): git refused to remove its worktree: cannot remove a locked working tree"'
git -C "$PROJECT" worktree unlock "$(dir_of autolock)" >/dev/null 2>&1
check "once the worktree is unlocked the lane goes, and the ledger ends on lane-removed" \
  'teamctl reclaim >/dev/null 2>&1; [ ! -e "$(dir_of autolock)" ] && ! git -C "$PROJECT" show-ref --verify -q "refs/heads/$(br_of autolock)" && [ "$(jq -sr "[.[] | select(.role == \"autolock\")] | last | .event + \" \" + .trigger" "$LEDGER")" = "lane-removed reclaim" ]'

echo "== auto-reclaim off: parking removes nothing, and says what is ready"
teamctl policy auto-reclaim off >/dev/null 2>&1
teamctl spawn manual glm53 --no-kickoff >/dev/null 2>&1
sleep 2
STATUS="$(teamctl status --json)"
commit_in "$(dir_of manual)" manual.txt "work" "manual: the work"
task manual closed
pg merge -q --no-ff -m "merge manual" "$(br_of manual)" >/dev/null 2>&1
STOP5="$(teamctl stop manual 2>&1)"
check "with the policy off, a finished lane is parked and kept" \
  '[ "$(teamctl status --json | jq -r ".policy.auto_reclaim")" = "off" ] && [ -f "$(dir_of manual)/manual.txt" ] &&git -C "$PROJECT" show-ref --verify -q "refs/heads/$(br_of manual)"'
check "and both stop and status say that nothing is in its way, and which command takes it" \
  'printf "%s" "$STOP5" | grep -q "nothing is in the way" && printf "%s" "$STOP5" | grep -q "teamctl reclaim" && teamctl status | grep -qE "holding [0-9.]+ (KB|MB|GB): nothing is in the way"'
check "teamctl reclaim, asked by hand, takes it whatever the policy says" \
  'teamctl reclaim >/dev/null 2>&1; [ ! -e "$(dir_of manual)" ]'

echo "== a plain teamctl destroy parks every lane, so it asks every lane"
teamctl policy auto-reclaim on >/dev/null 2>&1
teamctl spawn enddone glm53 --no-kickoff >/dev/null 2>&1
teamctl spawn endopen glm53 --no-kickoff >/dev/null 2>&1
sleep 3
STATUS="$(teamctl status --json)"
commit_in "$(dir_of enddone)" enddone.txt "work" "enddone: the work"
commit_in "$(dir_of endopen)" endopen.txt "work" "endopen: the work"
task enddone closed
task endopen closed
pg merge -q --no-ff -m "merge enddone" "$(br_of enddone)" >/dev/null 2>&1
ENDDONE_TIP="$(tip_of enddone)"
DESTROY="$(teamctl destroy --yes 2>&1)"
check "destroy without --worktrees takes the lane whose work is all in main, and says where it was" \
  '[ ! -e "$(dir_of enddone)" ] && printf "%s" "$DESTROY" | grep -q "enddone: branch $(br_of enddone) was at $ENDDONE_TIP" && printf "%s" "$DESTROY" | grep -q "reclaimed: enddone"'
check "it keeps the lane that still holds work, with its branch, and says what it holds" \
  '[ -f "$(dir_of endopen)/endopen.txt" ] && git -C "$PROJECT" show-ref --verify -q "refs/heads/$(br_of endopen)" && printf "%s" "$DESTROY" | grep -qE "endopen: holding [0-9.]+ (KB|MB|GB): unpushed at $(short "$(tip_of endopen)")"'
check "that removal is in the ledger with destroy as the trigger" \
  'jq -se "[.[] | select(.event == \"lane-removed\" and .role == \"enddone\" and .trigger == \"destroy\")] | length == 1" "$LEDGER" >/dev/null'
check "the closing line no longer says every worktree was kept" \
  '! printf "%s" "$DESTROY" | grep -q "^worktrees kept\." && printf "%s" "$DESTROY" | grep -q "teamctl reclaim --dry-run"'

echo "== every branch teamctl deletes says where it was, whichever command deletes it"
# 2026-10-13: a team was purged while a branch tip was on no remote, and three commits lived
# on only as dangling objects. They were found with git fsck. A sha in the terminal and in
# the ledger is the difference between a one-minute recovery and that.
teamctl start fable --no-attach --skip-beads >/dev/null 2>&1
teamctl policy auto-reclaim off >/dev/null 2>&1
teamctl spawn byhand glm53 --no-kickoff >/dev/null 2>&1
teamctl spawn bytrees glm53 --no-kickoff >/dev/null 2>&1
sleep 3
STATUS="$(teamctl status --json)"
commit_in "$(dir_of byhand)" byhand.txt "work nobody merged" "byhand: the work"
commit_in "$(dir_of bytrees)" bytrees.txt "work" "bytrees: the work"
pg merge -q --no-ff -m "merge bytrees" "$(br_of bytrees)" >/dev/null 2>&1
BYHAND_TIP="$(tip_of byhand)"
BYTREES_TIP="$(tip_of bytrees)"
teamctl stop byhand >/dev/null 2>&1
REMOVE="$(teamctl remove byhand --force --yes 2>&1)"
check "teamctl remove --force prints the branch and the full sha before it deletes the branch" \
  'a="$(printf "%s\n" "$REMOVE" | grep -n "byhand: branch $(br_of byhand) was at $BYHAND_TIP" | head -1 | cut -d: -f1)"; b="$(printf "%s\n" "$REMOVE" | grep -n "^removed: byhand" | head -1 | cut -d: -f1)"; [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && ! git -C "$PROJECT" show-ref --verify -q "refs/heads/$(br_of byhand)"'
check "and the discarded work can be brought back from the sha it printed" \
  'printf "%s" "$REMOVE" | grep -q "git -C .* branch $(br_of byhand) $BYHAND_TIP" && [ "$(git -C "$PROJECT" cat-file -t "$BYHAND_TIP")" = "commit" ]'
check "that removal is in the ledger and in the event log, with the tip" \
  'jq -se "[.[] | select(.event == \"lane-removed\" and .role == \"byhand\" and .trigger == \"remove\" and .tip == \"$BYHAND_TIP\")] | length == 1" "$LEDGER" >/dev/null && jq -se "[.[] | select(.type == \"remove\" and .role == \"byhand\" and (.detail | test(\"tip=$BYHAND_TIP\")))] | length == 1" "$(lib_eval "printf %s \"\$STATE_DIR\"")/events.jsonl" >/dev/null'
TREES_OUT="$(teamctl destroy --worktrees --yes 2>&1)"
check "destroy --worktrees says where a fully merged branch was when it deletes it" \
  'printf "%s" "$TREES_OUT" | grep -q "bytrees: branch $(br_of bytrees) was at $BYTREES_TIP" && ! git -C "$PROJECT" show-ref --verify -q "refs/heads/$(br_of bytrees)"'

echo "== parking never fails because the check after it did"
# bin/teamctl runs under `set -euo pipefail`, and both commands that park a lane ask the
# reclaim check AFTER the lane is parked. A failure in there would end the command before it
# said "stopped: <role>": the lane parked, and an error where the confirmation should be.
# Nothing in the check fails today, so the failure is put there: a copy of teamctl's home in
# which one function is replaced by one that leaves a mark and returns 7. The mark is the
# control in every check below; without it they pass wherever that function is never called.
# broken_home <name> <lib module> <function> — prints the home; the mark is $WORK/<name>.called
broken_home() {
  /bin/cp -R "$REPO/config/wolfmux" "$WORK/home-$1"
  printf '\n%s() { : >"%s"; return 7; }\n' "$3" "$WORK/$1.called" >>"$WORK/home-$1/lib/$2.sh"
  printf '%s' "$WORK/home-$1"
}
HOOK_HOME="$(broken_home hook reclaim reclaim_on_park)"
BOOK_HOME="$(broken_home book disk disk_parked_adjust)"
teamctl start fable --no-attach --skip-beads >/dev/null 2>&1
teamctl policy auto-reclaim on >/dev/null 2>&1
teamctl spawn hookstop glm53 --no-kickoff >/dev/null 2>&1
teamctl spawn hookbook glm53 --no-kickoff >/dev/null 2>&1
sleep 3
state_of() { teamctl status --json | jq -r --arg r "$1" '.agents[] | select(.role == $r) | .state'; }
STOP7="$(WOLFMUX_HOME="$HOOK_HOME" teamctl stop hookstop 2>&1)"
STOP7_RC=$?
check "teamctl stop exits 0 and says stopped: when the check after the park fails" \
  '[ -e "$WORK/hook.called" ] && [ "$STOP7_RC" -eq 0 ] && printf "%s" "$STOP7" | grep -q "^stopped: hookstop " && [ "$(state_of hookstop)" = "stopped" ]'
STOP8="$(WOLFMUX_HOME="$BOOK_HOME" teamctl stop hookbook 2>&1)"
STOP8_RC=$?
# The "holding" line shows the real check ran its whole course before its bookkeeping failed.
check "and when it is the bookkeeping at the end of the check that fails" \
  '[ -e "$WORK/book.called" ] && [ "$STOP8_RC" -eq 0 ] && printf "%s" "$STOP8" | grep -qE "^lane: +holding [0-9.]+ (KB|MB|GB): no task bead on record" && printf "%s" "$STOP8" | grep -q "^stopped: hookbook " && [ "$(state_of hookbook)" = "stopped" ]'
# Asked of the library directly, under lib_eval's own `set -euo pipefail` and with no
# `|| true` at the call: a `return 0` at the end of the function is not enough for this one,
# because `set -e` ends the shell at the failing line and the `return` is never reached.
/bin/rm -f "$WORK/book.called"
check "reclaim_on_park itself returns 0 to a caller under set -e, with no || true to save it" \
  '[ "$(WOLFMUX_HOME="$BOOK_HOME" lib_eval "reclaim_on_park \"\" stop 0 \"\" >/dev/null; printf reached" 2>/dev/null)" = "reached" ] && [ -e "$WORK/book.called" ]'
/bin/rm -f "$WORK/hook.called"
DESTROY2="$(WOLFMUX_HOME="$HOOK_HOME" teamctl destroy --yes 2>&1)"
DESTROY2_RC=$?
check "teamctl destroy finishes and says what it kept when the check after it fails" \
  '[ -e "$WORK/hook.called" ] && [ "$DESTROY2_RC" -eq 0 ] && printf "%s" "$DESTROY2" | grep -q "^worktrees kept, except a lane reclaimed above"'

echo "== teamctl reclaim --all-teams: the whole machine, and yours alone to run"
teamctl start fable --team second --no-attach --skip-beads >/dev/null 2>&1
teamctl policy auto-reclaim off --team second >/dev/null 2>&1
teamctl spawn far glm53 --team second --no-kickoff >/dev/null 2>&1
teamctl spawn lost glm53 --team second --no-kickoff >/dev/null 2>&1
sleep 3
SECOND="$(teamctl --team second status --json)"
FAR="$(printf '%s' "$SECOND" | jq -r '.agents[] | select(.role == "far") | .workdir')"
FAR_BR="$(printf '%s' "$SECOND" | jq -r '.agents[] | select(.role == "far") | .branch')"
LOST="$(printf '%s' "$SECOND" | jq -r '.agents[] | select(.role == "lost") | .workdir')"
LOST_BR="$(printf '%s' "$SECOND" | jq -r '.agents[] | select(.role == "lost") | .branch')"
commit_in "$FAR" far.txt "work" "far: the work"
commit_in "$LOST" lost.txt "work that is nowhere else" "lost: the work"
pg merge -q --no-ff -m "merge far" "$FAR_BR" >/dev/null 2>&1
FAR_TIP="$(git -C "$PROJECT" rev-parse "refs/heads/$FAR_BR")"
LOST_TIP="$(git -C "$PROJECT" rev-parse "refs/heads/$LOST_BR")"
# In Beads an agent of a named team is <team>.<role>. The bare name `far` is somebody else:
# an agent of the first team. Its open task must not hold second.far's lane, and a lane
# judged by the bare name would be held by it.
task second.far closed
task second.lost closed
task far in_progress
teamctl stop far --team second >/dev/null 2>&1
teamctl stop lost --team second >/dev/null 2>&1
check "a lead is refused with 77, told why, and told what it may run instead" \
  'out="$(TEAM_ROLE=lead teamctl reclaim --all-teams --dry-run 2>&1)"; rc=$?; [ "$rc" -eq 77 ] && printf "%s" "$out" | grep -q "machine owner.s alone to run" && printf "%s" "$out" | grep -q "teamctl reclaim for your own team"'
check "the refusal holds for the real run as well, and nothing is touched by it" \
  'TEAM_ROLE=lead teamctl reclaim --all-teams >/dev/null 2>&1; [ $? -eq 77 ] && [ -f "$FAR/far.txt" ]'
ALL="$(teamctl reclaim --all-teams --dry-run 2>&1)"
check "the dry run reports every team of the machine under its project, and deletes nothing" \
  'printf "%s" "$ALL" | grep -q "^PROJECT " && printf "%s" "$ALL" | grep -q "^  TEAM second" && printf "%s" "$ALL" | grep -qE "^    far +[0-9.]+ (KB|MB|GB) +would remove: $FAR_BR was at $FAR_TIP" && [ -f "$FAR/far.txt" ]'
check "a named team's lane is judged by its full name in Beads, second.far, not by the bare role" \
  'jq -e "select(.assignee == \"far\") | .status == \"in_progress\"" "$RECLAIM_STUB/tasks/far.json" >/dev/null && printf "%s" "$ALL" | grep -E "^    far +[0-9.]+ (KB|MB|GB) +would remove: " | grep -q "task closed (demo-second.far)"'
check "it gives a total per team and one for the machine" \
  'printf "%s" "$ALL" | grep -qE "^    team total +[0-9.]+ (KB|MB|GB) +would be freed in this team" && printf "%s" "$ALL" | grep -qE "^  machine total +[0-9.]+ (KB|MB|GB) +is what this would free in [0-9]+ parked lanes? across [0-9]+ teams in [0-9]+ projects?"'
ALLRUN="$(teamctl reclaim --all-teams 2>&1)"
check "run for real it takes the finished lane of the other team, and says where its branch was" \
  '[ ! -e "$FAR" ] && ! git -C "$PROJECT" show-ref --verify -q "refs/heads/$FAR_BR" && printf "%s" "$ALLRUN" | grep -q "far: branch $FAR_BR was at $FAR_TIP"'
check "and leaves that team's unfinished lane exactly as it was" \
  '[ -f "$LOST/lost.txt" ] && [ "$(git -C "$PROJECT" rev-parse "refs/heads/$LOST_BR")" = "$LOST_TIP" ] && printf "%s" "$ALLRUN" | grep -qE "^    lost +[0-9.]+ (KB|MB|GB) +holding: unpushed at "'
check "the ledger names the team the lane belonged to" \
  'jq -se "[.[] | select(.event == \"lane-removed\" and .role == \"far\" and .team == \"second\" and .tip == \"$FAR_TIP\")] | length == 1" "$LEDGER" >/dev/null'

echo "== destroy --purge: the path that lost work, and what it prints now"
PURGE="$(teamctl destroy --purge --force --team second 2>&1)"
check "purge prints the branch and the full sha of every lane it deletes, unmerged ones above all" \
  'printf "%s" "$PURGE" | grep -q "lost: branch $LOST_BR was at $LOST_TIP" && ! git -C "$PROJECT" show-ref --verify -q "refs/heads/$LOST_BR"'
check "the purged work can be brought back from the sha it printed, with no git fsck" \
  'printf "%s" "$PURGE" | grep -q "git -C .* branch $LOST_BR $LOST_TIP" && [ "$(git -C "$PROJECT" cat-file -t "$LOST_TIP")" = "commit" ] &&git -C "$PROJECT" branch back-from-purge "$LOST_TIP" >/dev/null 2>&1 && [ "$(git -C "$PROJECT" log --format=%s -1 back-from-purge)" = "lost: the work" ]'
# The team's own event log goes with the team, so the machine-wide ledger is the only record
# that outlives a purge.
check "and the ledger still has it after the team and its own log are gone" \
  'jq -se "[.[] | select(.event == \"lane-removed\" and .role == \"lost\" and .team == \"second\" and .trigger == \"purge\" and .tip == \"$LOST_TIP\")] | length == 1" "$LEDGER" >/dev/null'
check "every line of the ledger is one JSON object, appended: it is machine-readable, not prose" \
  '[ "$(wc -l <"$LEDGER" | tr -d " ")" -ge 10 ] && jq -e . "$LEDGER" >/dev/null'
# The first half is the control: lanes WERE judged and removed in this run, through every
# path above — dry runs, real runs, hangs that were killed, tools that failed.
check "no scratch file is left behind by any of it: no Beads answer, no gh answer, no object directory" \
  'grep -q "lane-removed" "$LEDGER" && [ -z "$(/bin/ls -A "$TMPDIR" | grep "^wolfmux-reclaim")" ]'

echo
echo "result: $passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
