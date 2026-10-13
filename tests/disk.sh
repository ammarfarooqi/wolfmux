#!/bin/bash
# disk.sh — the lane-worktree cleanup, the spawn guard, and every safety rule that keeps
# them away from your work (issue #11).
#
# Fully isolated from any team you have running: its own tmux server (socket
# wolfmux-disk-test-<pid>), its own state directory, a throwaway git repository, stub
# agents instead of real CLIs. Needs tmux, git, jq.
#
# The build trees it makes are a few megabytes of /dev/urandom, never a real install, so
# the whole file costs about 20 MB of disk while it runs and gives it back in the trap.
#
#   tests/disk.sh
# No pipefail: checks end in `grep -q`, which closes the pipe early by design.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-disk.XXXXXX")"
export WOLFMUX_HOME="$REPO/config/wolfmux"
export WOLFMUX_BIN_DIR="$REPO/bin"
export WOLFMUX_DATA="$WORK/data"
export WOLFMUX_TMUX_SOCKET="wolfmux-disk-test-$$"
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
teamctl() { "$REPO/bin/teamctl" "$@"; }

passed=0
failed=0
skipped=0
# One skip per thing this machine cannot answer: the heavy-lock checks need lockf(1), which
# macOS ships and some Linuxes do not. A skip is printed with its reason and counted, the way
# tests/dashboard.sh and tests/smoke.sh already do it — never silently passed.
skip() { # <description> <why>
  skipped=$((skipped + 1))
  printf '  SKIP  %s\n        (%s)\n' "$1" "$2"
}
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

PROJECT="$WORK/demo project" # the space is deliberate
/bin/mkdir -p "$PROJECT"
cd "$PROJECT" || exit 1
git init -q -b main
echo "hello" >README.md
printf 'node_modules/\n.next/\n' >.gitignore
git add -A
git -c user.name=disk -c user.email=disk@example.invalid commit -qm "initial commit"

# lib_eval <shell code> — run it with teamctl's own libraries loaded and this project
# resolved, so a rule can be asked a question directly instead of through a command.
# `set -euo pipefail` is bin/teamctl's own line, not a weaker one: under plain `set -u` an
# arithmetic abort or a failing command inside a library is invisible here, and that is
# exactly the shape of the leading-zero bug these checks now cover.
lib_eval() {
  (
    cd "$PROJECT" || exit 1
    bash -c '
      set -euo pipefail
      for m in provider-env common registry tmuxctl worktree disk beads policy approvals agents views doctor brand notify layout guard; do
        . "$WOLFMUX_HOME/lib/$m.sh"
      done
      load_project
      eval "$1"' _ "$1"
  )
}

kb_of() { du -sk "$@" 2>/dev/null | awk '{ total += $1 } END { print total + 0 }'; }
mkfile() { /bin/dd if=/dev/urandom of="$1" bs=1024 count="$2" 2>/dev/null; }

# mk_build_tree <worktree> — about 5 MB of what a real lane would hold
mk_build_tree() {
  /bin/mkdir -p "$1/node_modules/pkg" "$1/.next/cache" "$1/dist"
  mkfile "$1/node_modules/pkg/lib.js" 3000
  mkfile "$1/.next/cache/blob" 1000
  mkfile "$1/dist/bundle.js" 1000
}

TREES="$(lib_eval 'printf "%s\n" "$WORKTREES_DIR"')"
[ -n "$TREES" ] || { echo "cannot resolve this project's worktree directory" >&2; exit 1; }
/bin/mkdir -p "$TREES"

# new_lane <name> — a git worktree where wolfmux puts them, without starting an agent
new_lane() {
  git -C "$PROJECT" worktree add -q -b "ai/$1" "$TREES/$1" HEAD >/dev/null 2>&1
  printf '%s\n' "$TREES/$1"
}

echo "== the allowlist, the numbers, and nothing else touched"
L1="$(new_lane unit-1)"
mk_build_tree "$L1"
EXPECT_ALL="$(kb_of "$L1/node_modules" "$L1/.next" "$L1/dist")"
EXPECT_CACHES="$(kb_of "$L1/.next" "$L1/dist")"
check "a dry run reports the exact kilobytes of the allowlisted directories and deletes nothing" \
  '[ "$(lib_eval "disk_clean_worktree \"$L1\" all 0 && printf %s \"\$DISK_FREED_KB\"")" = "$EXPECT_ALL" ] && [ -d "$L1/node_modules" ] && [ -d "$L1/.next" ] && [ -d "$L1/dist" ]'
check "the dry run names what it would take, node_modules first on the list" \
  '[ "$(lib_eval "disk_clean_worktree \"$L1\" all 0 && printf %s \"\$DISK_CLEANED\"")" = "node_modules .next dist" ]'
check "kind 'caches' leaves node_modules out of the number and out of the list" \
  '[ "$(lib_eval "disk_clean_worktree \"$L1\" caches 0 && printf %s \"\$DISK_FREED_KB\"")" = "$EXPECT_CACHES" ] && [ "$(lib_eval "disk_clean_worktree \"$L1\" caches 0 && printf %s \"\$DISK_CLEANED\"")" = ".next dist" ]'
check "freed kilobytes turn into GB only above a gigabyte (human_size, the same helper destroy --purge uses)" \
  '[ "$(lib_eval "human_size 2097152")" = "2.0 GB" ] && [ "$(lib_eval "human_size 5120")" = "5 MB" ] && [ "$(lib_eval "human_size 7")" = "7 KB" ]'
lib_eval "disk_clean_worktree \"$L1\" caches 1" >/dev/null
check "applying 'caches' deletes the build caches and keeps node_modules" \
  '[ ! -e "$L1/.next" ] && [ ! -e "$L1/dist" ] && [ -d "$L1/node_modules/pkg" ]'
lib_eval "disk_clean_worktree \"$L1\" all 1" >/dev/null
check "applying 'all' takes node_modules too, and leaves the sources and the git state alone" \
  '[ ! -e "$L1/node_modules" ] && [ -f "$L1/README.md" ] && [ -z "$(git -C "$L1" status --porcelain)" ] && git -C "$L1" rev-parse --verify -q HEAD >/dev/null'
check "nothing is left behind: no half-deleted directory, no trash" \
  '[ -z "$(/bin/ls -A "$L1" | grep "wolfmux-removing")" ]'

echo "== what is never deleted"
L2="$(new_lane unit-tracked)"
/bin/mkdir -p "$L2/dist"
printf 'committed\n' >"$L2/dist/keep.txt"
git -C "$L2" add -f dist/keep.txt >/dev/null 2>&1
git -C "$L2" -c user.name=disk -c user.email=disk@example.invalid commit -qm "a project that commits its dist"
mkfile "$L2/dist/bundle.js" 500
/bin/mkdir -p "$L2/node_modules/pkg"
mkfile "$L2/node_modules/pkg/lib.js" 500
# `dist` is on the list AND git tracks it here: rule 2 wins, and node_modules still goes.
lib_eval "disk_clean_worktree \"$L2\" all 1" >/dev/null
check "a directory git tracks survives, whatever it is called, and the rest is still taken" \
  '[ -f "$L2/dist/keep.txt" ] && [ -f "$L2/dist/bundle.js" ] && [ ! -e "$L2/node_modules" ]'
check "a tracked directory is not counted as freed either" \
  '[ "$(lib_eval "disk_clean_worktree \"$L2\" all 0 && printf %s \"\$DISK_FREED_KB\"")" = "0" ]'

L3="$(new_lane unit-dirty)"
mk_build_tree "$L3"
printf 'work in progress\n' >>"$L3/README.md"
check "a worktree with an uncommitted change to a tracked file is refused, with the reason" \
  '! lib_eval "disk_clean_worktree \"$L3\" all 1" && lib_eval "disk_clean_worktree \"$L3\" all 1 || printf %s \"\$DISK_SKIP_REASON\"" | grep -q "uncommitted changes to tracked files"'
check "and nothing of it was touched" '[ -d "$L3/node_modules/pkg" ] && [ -d "$L3/.next" ]'

L4="$(new_lane unit-untracked)"
mk_build_tree "$L4"
printf 'notes an agent left\n' >"$L4/NOTES.md"
check "a worktree with untracked files that are not build output is refused, and the file is named" \
  '! lib_eval "disk_clean_worktree \"$L4\" all 1" && lib_eval "disk_clean_worktree \"$L4\" all 1 || printf %s \"\$DISK_SKIP_REASON\"" | grep -q "not build output (NOTES.md)"'
check "and nothing of it was touched" '[ -d "$L4/node_modules/pkg" ] && [ -f "$L4/NOTES.md" ]'

OUTSIDE="$WORK/outside"
/bin/mkdir -p "$OUTSIDE"
(cd "$OUTSIDE" && git init -q -b main && echo x >f && git add -A && git -c user.name=d -c user.email=d@e.invalid commit -qm i) >/dev/null 2>&1
mk_build_tree "$OUTSIDE"
check "a path outside this project's worktree directory is refused, however good it looks" \
  '! lib_eval "disk_clean_worktree \"$OUTSIDE\" all 1" && [ -d "$OUTSIDE/node_modules/pkg" ] && [ -d "$OUTSIDE/.next" ]'
mk_build_tree "$PROJECT"
check "your own checkout is refused, and the worktree directory itself is refused" \
  '! lib_eval "disk_clean_worktree \"$PROJECT\" all 1" && ! lib_eval "disk_clean_worktree \"$TREES\" all 1" && [ -d "$PROJECT/node_modules/pkg" ]'
/bin/rm -rf "$PROJECT/node_modules" "$PROJECT/.next" "$PROJECT/dist"
check "a symlink that leads out of the worktree: the link goes, never what it points at" \
  'L="$(new_lane unit-link)" && /bin/ln -s "$OUTSIDE/node_modules" "$L/node_modules" && lib_eval "disk_clean_worktree \"$L\" all 1" && [ ! -e "$L/node_modules" ] && [ -f "$OUTSIDE/node_modules/pkg/lib.js" ]'
check "a cleanup killed halfway leaves trash the next run clears, never a half-deleted node_modules" \
  'L="$(new_lane unit-trash)" && /bin/mkdir -p "$L/.wolfmux-removing-node_modules.999/pkg" && mkfile "$L/.wolfmux-removing-node_modules.999/pkg/x" 200 && lib_eval "disk_clean_worktree \"$L\" all 1" && [ -z "$(/bin/ls -A "$L" | grep wolfmux-removing)" ]'
check "free disk is a plain number of kilobytes, and a label when df says nothing" \
  'lib_eval "disk_free_kb" | grep -Eq "^[0-9]+$" && lib_eval "disk_free_label" | grep -Eq "(KB|MB|GB)$"'
check "a worktree whose .git file is gone is refused: git has to be the one that answers" \
  'L="$(new_lane unit-nogit)" && mk_build_tree "$L" && /bin/rm -f "$L/.git" && ! lib_eval "disk_clean_worktree \"$L\" all 1" && [ -d "$L/node_modules/pkg" ] && lib_eval "disk_clean_worktree \"$L\" all 1 || printf %s \"\$DISK_SKIP_REASON\"" | grep -q "git does not know"'
check "a path that climbs out of the worktree directory is refused (pwd -P resolves it first)" \
  '! lib_eval "disk_clean_worktree \"$TREES/..\" all 1" && ! lib_eval "disk_clean_worktree \"$TREES/../..\" all 1" && ! lib_eval "disk_clean_worktree \"$TREES/unit-1/../../..\" all 1" && ! lib_eval "disk_clean_worktree / all 1"'
# The first team's worktree directory is the parent of the named teams' ones, so its prefix
# alone would reach their lanes. It must not: another team's lanes are that team's to clean.
check "a named team's lane is never confined for the first team, nor is the teams/ directory itself" \
  '/bin/mkdir -p "$TREES/teams/other" && git -C "$PROJECT" worktree add -q -b ai/other/lane1 "$TREES/teams/other/lane1" HEAD >/dev/null 2>&1 && mk_build_tree "$TREES/teams/other/lane1" && ! lib_eval "disk_clean_worktree \"$TREES/teams/other/lane1\" all 1" && ! lib_eval "disk_clean_worktree \"$TREES/teams\" all 1" && [ -d "$TREES/teams/other/lane1/node_modules/pkg" ]'
check "the refusal never trails off when there is no worktree directory to name" \
  '! lib_eval "WORKTREES_DIR=; disk_cleanable \"$TREES/unit-1\"" && lib_eval "WORKTREES_DIR=; disk_cleanable \"$TREES/unit-1\" || printf %s \"\$DISK_SKIP_REASON\"" | grep -q "no worktree directory resolved"'
git -C "$PROJECT" worktree remove --force "$TREES/teams/other/lane1" >/dev/null 2>&1
git -C "$PROJECT" branch -D ai/other/lane1 >/dev/null 2>&1

echo "== the remembered lane size"
STATE="$(lib_eval 'printf "%s\n" "$STATE_DIR"')"
/bin/mkdir -p "$STATE"
cache_says() { printf '%s' "$1" >"$STATE/disk-kb"; lib_eval 'disk_team_kb_cached'; }
check "a fresh number is used, and garbage, a short line and an empty file are not" \
  '[ "$(cache_says "$(date +%s) 4096")" = "4096" ] && [ -z "$(cache_says "garbage")" ] && [ -z "$(cache_says "123")" ] && [ -z "$(cache_says "")" ] && [ -z "$(cache_says "-5 -5")" ]'
check "a stale number is dropped, and so is one stamped in the future (a clock that went back)" \
  '[ -z "$(cache_says "1000000000 4096")" ] && [ -z "$(cache_says "9999999999999 500")" ] && [ -z "$(cache_says "$(($(date +%s) + 86400)) 500")" ]'
# This block exists to fall back silently. A leading zero in the file used to reach the
# arithmetic and make teamctl status print "08: value too great for base" instead.
check "a leading zero in either field is dropped silently, with no shell error on stderr" \
  '[ -z "$(cache_says "08 500")" ] && [ -z "$(cache_says "$(date +%s) 08")" ] && [ -z "$(printf "08 500" >"$STATE/disk-kb"; lib_eval "disk_team_kb_cached" 2>&1)" ] && [ "$(cache_says "$(date +%s) 0")" = "0" ]'
check "a command that just freed something corrects the number instead of measuring again, and never below zero" \
  'printf "%s 4096\n" "$(date +%s)" >"$STATE/disk-kb" && lib_eval "disk_cache_adjust 1024" && [ "$(lib_eval "disk_team_kb_cached")" = "3072" ] && lib_eval "disk_cache_adjust 999999" && [ "$(lib_eval "disk_team_kb_cached")" = "0" ]'
/bin/rm -f "$STATE/disk-kb"

echo "== what counts as a person's work, for the question teamctl remove asks"
# node_modules and the caches are never handwriting, and the node_modules symlink plus our
# own trash are this tool's own doing. build, dist and target are different: when a project
# ignores them git says nothing, when it tracks them rule 2 protects them, and what is left
# is a directory git neither tracks nor ignores — where a dist/deploy.sh somebody wrote is
# likelier than build output nobody will miss. remove has to ask about those.
WL="$(new_lane unit-work)"
check "an untracked dist, build or target that git neither tracks nor ignores counts as work" \
  'for d in dist build target; do /bin/mkdir -p "$WL/$d"; printf "#!/bin/sh\n" >"$WL/$d/deploy.sh"; [ "$(lib_eval "disk_work_dirty_count \"$WL\"")" = "1" ] || exit 1; lib_eval "disk_work_dirty_list \"$WL\"" | grep -q "?? $d/" || exit 1; /bin/rm -rf "$WL/$d"; done'
check "node_modules, the build caches and our own trash never count as work" \
  '/bin/mkdir -p "$WL/node_modules/pkg" "$WL/.next" "$WL/.turbo" "$WL/.wolfmux-removing-node_modules.1" && [ "$(lib_eval "disk_work_dirty_count \"$WL\"")" = "0" ]'
check "a node_modules SYMLINK does not count either, which is the case the ignore line misses" \
  '/bin/rm -rf "$WL/node_modules" && /bin/ln -s "$PROJECT" "$WL/node_modules" && git -C "$WL" status --porcelain | grep -q "?? node_modules" && [ "$(lib_eval "disk_work_dirty_count \"$WL\"")" = "0" ]'
check "a changed tracked file always counts, and so does any other untracked file" \
  'printf "x\n" >>"$WL/README.md" && printf "notes\n" >"$WL/NOTES.md" && [ "$(lib_eval "disk_work_dirty_count \"$WL\"")" = "2" ]'
git -C "$PROJECT" worktree remove --force "$TREES/unit-work" >/dev/null 2>&1
git -C "$PROJECT" branch -D ai/unit-work >/dev/null 2>&1

echo "== a number that is not base ten"
check "policy refuses a leading zero: 08 would abort shell arithmetic, 010 would quietly mean 8" \
  'for v in 08 010 09 twenty -5 1e3 10001; do teamctl policy disk-min-gb "$v" >/dev/null 2>&1; [ $? -eq 64 ] || exit 1; done'
check "a leading zero in the environment falls back to the default, it never reaches the arithmetic" \
  '[ "$(WOLFMUX_DISK_MIN_GB=08 lib_eval "policy_get disk-min-gb")" = "20" ] && [ "$(WOLFMUX_DISK_MIN_GB=010 lib_eval "policy_get disk-min-gb")" = "20" ]'
# A stored value cannot come through teamctl policy any more, but meta.json is a file
# anyone can edit, so the same has to hold for a value already in it.
check "and so does one already stored in meta.json, which teamctl policy would no longer accept" \
  'META="$(lib_eval "printf %s \"\$STATE_DIR/meta.json\"")" && /bin/mkdir -p "$(dirname "$META")" && printf "{\"policy_disk_min_gb\":\"08\"}\n" >"$META" && [ "$(lib_eval "policy_get disk-min-gb")" = "20" ] && printf "{\"policy_disk_min_gb\":\"8\"}\n" >"$META" && [ "$(lib_eval "policy_get disk-min-gb")" = "8" ] && /bin/rm -f "$META"'
check "and the one arithmetic site forces base ten anyway, so even 08 cannot abort a spawn" \
  'lib_eval "policy_get() { case \"\$1\" in disk-guard) printf refuse ;; disk-min-gb) printf 08 ;; esac; printf \"\\n\"; }; disk_guard_spawn"'
for name in unit-1 unit-tracked unit-dirty unit-untracked unit-link unit-trash unit-nogit; do
  git -C "$PROJECT" worktree remove --force "$TREES/$name" >/dev/null 2>&1
  git -C "$PROJECT" branch -D "ai/$name" >/dev/null 2>&1
done

echo "== the commands, in a throwaway team"
teamctl start fable --no-attach --skip-beads >/dev/null 2>&1
# This whole block runs with auto-prune OFF, and every check in it is about what that path
# does: `teamctl prune` itself, and the stop that takes the build caches and keeps
# node_modules, which is what stop did up to v1.16.1 and what the policy brings back. The
# DEFAULT (auto-prune on, where parking a lane sweeps the lot) is the block at the end of
# this file. Both paths ship, so both are tested, and neither is tested through the other.
teamctl policy auto-prune off >/dev/null 2>&1
teamctl spawn parked glm53 --no-kickoff >/dev/null 2>&1
teamctl spawn busy glm53 --no-kickoff >/dev/null 2>&1
teamctl spawn messy glm53 --no-kickoff >/dev/null 2>&1
sleep 2
PARKED="$(teamctl status --json | "$(command -v jq)" -r '.agents[] | select(.role == "parked") | .workdir')"
BUSY="$(teamctl status --json | "$(command -v jq)" -r '.agents[] | select(.role == "busy") | .workdir')"
MESSY="$(teamctl status --json | "$(command -v jq)" -r '.agents[] | select(.role == "messy") | .workdir')"
check "three lanes exist, each with its own worktree" '[ -d "$PARKED" ] && [ -d "$BUSY" ] && [ -d "$MESSY" ]'
mk_build_tree "$PARKED"
mk_build_tree "$BUSY"
mk_build_tree "$MESSY"
printf 'half-finished\n' >>"$MESSY/README.md"
# Both are parked: prune only ever looks at lanes that are not running, and the point of
# `messy` is that a parked lane holding real work is still left alone.
teamctl stop messy >/dev/null 2>&1

STOP_OUT="$(teamctl stop parked 2>&1)"
check "stop takes the build caches, keeps node_modules, and says how much it freed" \
  '[ ! -e "$PARKED/.next" ] && [ ! -e "$PARKED/dist" ] && [ -d "$PARKED/node_modules/pkg" ] && printf "%s" "$STOP_OUT" | grep -q "freed:.*MB of build output"'
check "stop says the worktree, branch and commits are untouched, and they are" \
  'printf "%s" "$STOP_OUT" | grep -q "worktree, branch and commits are untouched" && [ -f "$PARKED/README.md" ]'
check "stopping a lane that holds unfinished work keeps its build output and says why" \
  'teamctl restart messy >/dev/null 2>&1; sleep 1; teamctl stop messy 2>&1 | grep -q "kept:    its build output (it has uncommitted changes to tracked files)" && [ -d "$MESSY/.next" ]'

/bin/mkdir -p "$PARKED/.wolfmux-removing-node_modules.999/pkg"
mkfile "$PARKED/.wolfmux-removing-node_modules.999/pkg/x" 200
DRY="$(teamctl prune --dry-run 2>&1)"
check "prune --dry-run reports a total and deletes nothing" \
  'printf "%s" "$DRY" | grep -q "DRY RUN: nothing is deleted" && printf "%s" "$DRY" | grep -qE "^  total +[0-9.]+ (KB|MB|GB) +is what this would free" && [ -d "$PARKED/node_modules/pkg" ]'
check "prune --dry-run leaves the interrupted-cleanup trash alone too" \
  '[ -f "$PARKED/.wolfmux-removing-node_modules.999/pkg/x" ]'
# The sizes, not the shape of the line: asserting /[0-9.]+ (KB|MB|GB)/ is how the first
# version of the still-held total passed while leaving out the two lanes that held the most.
# Expected floor = what is left of the lane prune sweeps, plus the WHOLE of the running and
# the skipped one. disk_clean_worktree with apply 0 changes nothing, so it can be asked.
P_FREED="$(lib_eval "disk_clean_worktree \"$PARKED\" all 0 && printf %s \"\$DISK_FREED_KB\"")"
EXP_FLOOR=$(($(kb_of "$PARKED") - P_FREED + $(kb_of "$BUSY") + $(kb_of "$MESSY")))
check "prune --dry-run leaves a running lane out of the freed total and prints its real size" \
  'printf "%s" "$DRY" | grep -qE "^  busy +$(lib_eval "human_size $(kb_of "$BUSY")") +running, left alone"'
check "prune --dry-run skips the lane that holds other changes, and names the reason" \
  'printf "%s" "$DRY" | grep -q "messy.*skipped: it has uncommitted changes to tracked files"'
check "a skipped lane shows its real size, so what one stray file is pinning is visible" \
  'printf "%s" "$DRY" | grep -qE "^  messy +$(lib_eval "human_size $(kb_of "$MESSY")") +skipped:"'
check "the still-held total is the real number: it counts the skipped and running lanes, which hold the most" \
  '[ "$EXP_FLOOR" -gt "$P_FREED" ] && printf "%s" "$DRY" | grep -qE "^  still held +$(lib_eval "human_size "$EXP_FLOOR"") +is still in these lanes" && printf "%s" "$DRY" | grep -q "comes back only with teamctl remove <role>"'
check "and it is bigger than the swept lane's leftovers alone, which is all the first version counted" \
  '! printf "%s" "$DRY" | grep -qE "^  still held +$(lib_eval "human_size $(($(kb_of "$PARKED") - P_FREED))") "'
# One signal is not enough for a command that sweeps many lanes unattended: a record that
# claims a running agent while the session shows no pane of its means we do not know.
RECORDS="$(/bin/ls -d "$WOLFMUX_DATA"/state/*/agents | head -1)"
"$(command -v jq)" '.state = "running" | .pane_id = "%999"' "$RECORDS/parked.json" >"$RECORDS/parked.json.tmp" && /bin/mv "$RECORDS/parked.json.tmp" "$RECORDS/parked.json"
check "prune refuses the whole sweep when a record and tmux disagree, and touches nothing" \
  'out="$(teamctl prune 2>&1)"; [ $? -ne 0 ] && printf "%s" "$out" | grep -q "cannot tell whether .parked. is running" && printf "%s" "$out" | grep -q "Nothing was touched" && [ -d "$PARKED/node_modules/pkg" ]'
check "the same doubt stops a dry run, so the report can never be read as a safe list" \
  'teamctl prune --dry-run >/dev/null 2>&1; [ $? -ne 0 ]'
teamctl stop parked >/dev/null 2>&1
check "a worker may look (--dry-run) but not prune: the deleting is the lead's (exit 77)" \
  'TEAM_ROLE=busy teamctl prune --dry-run >/dev/null 2>&1 && { TEAM_ROLE=busy teamctl prune >/dev/null 2>&1; [ $? -eq 77 ]; }'

KEEP="$(teamctl prune --keep-node-modules 2>&1)"
check "prune --keep-node-modules takes the caches only" \
  '[ -d "$PARKED/node_modules/pkg" ] && printf "%s" "$KEEP" | grep -q "takes:.*\.next" && ! printf "%s" "$KEEP" | grep -q "takes: node_modules"'
PRUNE="$(teamctl prune 2>&1)"
check "prune takes node_modules from the parked lane and reports the freed total" \
  '[ ! -e "$PARKED/node_modules" ] && printf "%s" "$PRUNE" | grep -qE "^  total +[0-9.]+ (KB|MB|GB) +freed from 1 parked lane"'
check "prune clears the interrupted-cleanup trash as well" \
  '[ -z "$(/bin/ls -A "$PARKED" | grep wolfmux-removing)" ]'
check "prune never touches a running lane" '[ -d "$BUSY/node_modules/pkg" ] && [ -d "$BUSY/.next" ]'
check "prune never touches the lane it skipped" '[ -d "$MESSY/node_modules/pkg" ]'
check "prune leaves the parked lane's sources and git state intact" \
  '[ -f "$PARKED/README.md" ] && [ -z "$(git -C "$PARKED" status --porcelain)" ]'
check "prune says what to do about a skipped lane" 'printf "%s" "$PRUNE" | grep -q "teamctl remove <role>"'

/bin/mkdir -p "$PARKED/.wolfmux-removing-node_modules.998/pkg"
mkfile "$PARKED/.wolfmux-removing-node_modules.998/pkg/x" 200
REMOVE="$(teamctl remove parked --yes 2>&1)"
check "remove takes the whole worktree and says what that freed" \
  '[ ! -d "$PARKED" ] && printf "%s" "$REMOVE" | grep -qE "removed: parked .*freed [0-9]"'
check "remove sweeps the build output first, so cleanup trash never makes it ask for --force" \
  'printf "%s" "$REMOVE" | grep -q "parked: took .* of build output first" && ! printf "%s" "$REMOVE" | grep -q "still holds work"'
# A record is a file anyone can edit; prune has to answer about the directory, not the record.
STRAY="$WORK/stray-lane"
/bin/mkdir -p "$STRAY"
(cd "$STRAY" && git init -q -b main && echo x >f && git add -A && git -c user.name=d -c user.email=d@e.invalid commit -qm i) >/dev/null 2>&1
mk_build_tree "$STRAY"
"$(command -v jq)" --arg w "$STRAY" '.role = "forged" | .workdir = $w | .state = "stopped" | .pane_id = ""' "$RECORDS/busy.json" >"$RECORDS/forged.json"
check "a hand-edited record whose workdir points outside is skipped, and that directory is untouched" \
  'teamctl prune 2>&1 | grep -q "forged.*skipped: it is not a lane of team" && [ -d "$STRAY/node_modules/pkg" ] && [ -d "$STRAY/.next" ]'
/bin/rm -f "$RECORDS/forged.json"

echo "== the guard before a lane is created"
check "status shows free disk and what the guard is set to" \
  'teamctl status | grep -qE "disk +[0-9.]+ (KB|MB|GB) free .* spawn guard: refuse under 20 GB"'
check "status never measures the lanes by itself: it reads the number teamctl teams left" \
  'teamctl status | grep -q "not measured (teamctl teams measures it)" && teamctl teams | grep -qE "^default +(running|ended) " && teamctl status | grep -qE "this team.s lanes: [0-9.]+ (KB|MB|GB)"'
check "status --json carries the disk numbers and the three new policy keys" \
  'teamctl status --json | jq -e ".disk.free_kb > 0 and .policy.disk_guard == \"refuse\" and .policy.disk_min_gb == 20 and .policy.link_node_modules == \"off\""'
teamctl policy disk-min-gb 9999 >/dev/null 2>&1
GUARD="$(teamctl spawn late glm53 --no-kickoff 2>&1)"
check "under the threshold a spawn is refused (exit 75), names the number, and creates nothing" \
  'printf "%s" "$GUARD" | grep -q "under the 9999 GB this team asks for" && printf "%s" "$GUARD" | grep -q "teamctl prune --dry-run" && [ -z "$(git -C "$PROJECT" branch --list "ai/late-*")" ] && ! teamctl status --json | jq -e ".agents[] | select(.role == \"late\")"'
check "the refusal is exit 75, not a usage error" 'teamctl spawn late glm53 --no-kickoff >/dev/null 2>&1; [ $? -eq 75 ]'
teamctl policy disk-guard warn >/dev/null 2>&1
WARN="$(teamctl spawn late glm53 --no-kickoff 2>&1)"
sleep 1
check "policy disk-guard warn lets the same spawn through, with the warning" \
  'printf "%s" "$WARN" | grep -q "spawning anyway" && teamctl status --json | jq -e ".agents[] | select(.role == \"late\") | .state == \"running\""'
teamctl policy disk-guard off >/dev/null 2>&1
check "policy disk-guard off asks nothing at all" \
  'teamctl spawn later glm53 --no-kickoff 2>&1 | grep -q "spawned:   later" && ! teamctl spawn later glm53 2>&1 | grep -q "free on this disk"'
check "a policy value that is not a number, or not one of the words, is refused (exit 64)" \
  'teamctl policy disk-min-gb twenty >/dev/null 2>&1; [ $? -eq 64 ] && { teamctl policy disk-min-gb -5 >/dev/null 2>&1; [ $? -eq 64 ]; } && { teamctl policy disk-guard maybe >/dev/null 2>&1; [ $? -eq 64 ]; } && { teamctl policy link-node-modules sometimes >/dev/null 2>&1; [ $? -eq 64 ]; }'
teamctl policy disk-guard refuse >/dev/null 2>&1
teamctl policy disk-min-gb 0 >/dev/null 2>&1
check "disk-min-gb 0 switches the limit off without switching the guard off" \
  'teamctl policy | grep -q "disk-min-gb         0" && teamctl spawn zero glm53 --no-kickoff 2>&1 | grep -q "spawned:   zero"'

echo "== one node_modules for every lane, behind the flag"
/bin/mkdir -p "$PROJECT/node_modules/rootpkg"
mkfile "$PROJECT/node_modules/rootpkg/index.js" 500
LINKED="$(teamctl spawn shared glm53 --no-kickoff --link-node-modules 2>&1)"
SHARED="$(teamctl status --json | jq -r '.agents[] | select(.role == "shared") | .workdir')"
check "--link-node-modules points the lane at the project's node_modules and says what that means" \
  '[ -L "$SHARED/node_modules" ] && [ -f "$SHARED/node_modules/rootpkg/index.js" ] && printf "%s" "$LINKED" | grep -q "an install in any lane changes them all"'
check "without the flag, and with the policy off, a lane gets no link" \
  'P="$(teamctl status --json | jq -r ".agents[] | select(.role == \"later\") | .workdir")" && [ ! -e "$P/node_modules" ]'
teamctl policy link-node-modules on >/dev/null 2>&1
check "policy link-node-modules on does it for every spawn" \
  'teamctl spawn shared2 glm53 --no-kickoff >/dev/null 2>&1 && P="$(teamctl status --json | jq -r ".agents[] | select(.role == \"shared2\") | .workdir")" && [ -L "$P/node_modules" ]'
teamctl stop shared2 >/dev/null 2>&1
# .gitignore here says "node_modules/" with the trailing slash, the common form, which
# matches directories only — so git calls the lane's node_modules SYMLINK untracked, and
# remove used to refuse a lane the new flag had made, pointing at --force. --force is the
# discard-work door; nobody should be trained to type it on an ordinary lane.
SHARED2="$(teamctl status --json | jq -r '.agents[] | select(.role == "shared2") | .workdir')"
check "a linked node_modules really is what git calls untracked (the case this covers)" \
  '[ -L "$SHARED2/node_modules" ] && git -C "$SHARED2" status --porcelain | grep -q "?? node_modules"'
# A remove that REFUSES must leave the lane exactly as it found it: "nothing was removed"
# has to be true. So the build output is swept per lane, after every refusal and question,
# and only for a lane that is going.
mk_build_tree_caches() { /bin/mkdir -p "$1/.next/cache"; mkfile "$1/.next/cache/blob" 500; }
mk_build_tree_caches "$SHARED2"
printf 'notes an agent left\n' >"$SHARED2/NOTES.md"
R0="$(teamctl remove shared2 2>&1)"
check "remove refuses a lane that holds one file a person wrote, even with a linked node_modules" \
  'printf "%s" "$R0" | grep -q "shared2 still holds work" && printf "%s" "$R0" | grep -q "1 uncommitted file" && printf "%s" "$R0" | grep -q "NOTES.md" && [ -d "$SHARED2" ]'
check "the count and the listed lines agree: the linked node_modules is in neither" \
  '! printf "%s" "$R0" | grep -qE "^ +\?\? node_modules$"'
check "and the refused lane keeps its node_modules link and its caches: nothing was removed, for real" \
  '[ -L "$SHARED2/node_modules" ] && [ -f "$SHARED2/node_modules/rootpkg/index.js" ] && [ -f "$SHARED2/.next/cache/blob" ] && ! printf "%s" "$R0" | grep -q "took .* of build output first"'
/bin/rm -f "$SHARED2/NOTES.md"
R2="$(teamctl remove shared2 --yes 2>&1)"
check "remove takes a --link-node-modules lane off the books without --force, and never the project's copy" \
  '[ ! -d "$SHARED2" ] && ! printf "%s" "$R2" | grep -q "still holds work" && ! printf "%s" "$R2" | grep -q -- "--force" && [ -f "$PROJECT/node_modules/rootpkg/index.js" ]'
check "it says what the sweep took and reports the lane's whole size as freed" \
  'printf "%s" "$R2" | grep -q "shared2: took .* of build output first" && printf "%s" "$R2" | grep -qE "removed: shared2 .*freed [0-9.]+ (KB|MB|GB)"'
teamctl stop shared >/dev/null 2>&1
check "cleaning a lane whose node_modules is a link removes the link and never the project's copy" \
  'teamctl prune >/dev/null 2>&1; [ ! -e "$SHARED/node_modules" ] && [ -f "$PROJECT/node_modules/rootpkg/index.js" ]'

check "remove asks about a lane holding an untracked dist that git neither tracks nor ignores" \
  'LATER="$(teamctl status --json | jq -r ".agents[] | select(.role == \"later\") | .workdir")" && teamctl stop later >/dev/null 2>&1 && /bin/mkdir -p "$LATER/dist" && printf "#!/bin/sh\necho ship\n" >"$LATER/dist/deploy.sh" && out="$(teamctl remove later 2>&1)"; [ $? -ne 0 ] && printf "%s" "$out" | grep -q "later still holds work" && printf "%s" "$out" | grep -q "?? dist/" && [ -f "$LATER/dist/deploy.sh" ]'

echo "== a lane in ANOTHER repository (teamctl spawn --repo)"
# The highest-stakes path in this change: a deletion inside a worktree of a repository that
# is not this project. Rule 4 has to be asked about THAT repository's worktree directory,
# not this project's, or the lane is either skipped (and hoards) or — worse — a path of the
# other repository is measured against the wrong prefix.
REPO2="$WORK/other repo" # the space is deliberate here too
/bin/mkdir -p "$REPO2"
(
  cd "$REPO2" || exit 1
  git init -q -b main
  printf 'second\n' >README.md
  printf 'node_modules/\n.next/\n' >.gitignore
  git add -A
  git -c user.name=disk -c user.email=disk@example.invalid commit -qm "initial commit"
) >/dev/null 2>&1
# What teamctl stores is the physical path git reports, and under $TMPDIR on macOS that is
# not the path we built ("/var/…" is a symlink to "/private/var/…"). Compare like with like.
REPO2="$(cd "$REPO2" && pwd -P)"
/bin/mkdir -p "$REPO2/node_modules/rootpkg2"
mkfile "$REPO2/node_modules/rootpkg2/index.js" 400
teamctl policy link-node-modules off >/dev/null 2>&1
teamctl spawn far glm53 --no-kickoff --repo "$REPO2" >/dev/null 2>&1
sleep 1
FAR="$(teamctl status --json | jq -r '.agents[] | select(.role == "far") | .workdir')"
TREES2="$(dirname "$FAR")"
check "the lane really is in the other repository's worktree directory, not this project's" \
  '[ -n "$FAR" ] && [ -d "$FAR" ] && [ "$(teamctl status --json | jq -r ".agents[] | select(.role == \"far\") | .repo")" = "$REPO2" ] && case "$FAR" in "$TREES"*) exit 1 ;; esac && case "$TREES2" in "$WOLFMUX_DATA"/worktrees/*) ;; *) exit 1 ;; esac'
mk_build_tree "$FAR"
STOP2="$(teamctl stop far 2>&1)"
check "stop clears a --repo lane's build caches and keeps its node_modules" \
  '[ ! -e "$FAR/.next" ] && [ ! -e "$FAR/dist" ] && [ -d "$FAR/node_modules/pkg" ] && printf "%s" "$STOP2" | grep -q "freed:.*of build output"'
# A mixed sweep: the --repo lane and this project's own lanes in one run.
PRUNE2="$(teamctl prune 2>&1)"
check "prune takes the --repo lane's node_modules, in the other repository, and names that repository" \
  '[ ! -e "$FAR/node_modules" ] && printf "%s" "$PRUNE2" | grep -qE "^  far +[0-9.]+ (KB|MB|GB) +node_modules \(in .*other repo\)"'
check "the same run leaves this project's running lane alone" '[ -d "$BUSY/node_modules/pkg" ]'
check "and neither repository's own checkout was touched" \
  '[ -f "$REPO2/node_modules/rootpkg2/index.js" ] && [ -f "$PROJECT/node_modules/rootpkg/index.js" ] && [ -f "$REPO2/README.md" ]'
# Rule 4, asked about the second repository: anything that is not one of ITS lane worktrees.
check "a path in the other repository that is not one of its lanes is refused: its root, its worktrees directory, a parent" \
  '! lib_eval "disk_clean_worktree \"$REPO2\" all 1 \"$TREES2\" \"$REPO2\"" && ! lib_eval "disk_clean_worktree \"$TREES2\" all 1 \"$TREES2\" \"$REPO2\"" && ! lib_eval "disk_clean_worktree \"$TREES2/..\" all 1 \"$TREES2\" \"$REPO2\"" && ! lib_eval "disk_clean_worktree \"$FAR/../..\" all 1 \"$TREES2\" \"$REPO2\"" && [ -f "$REPO2/node_modules/rootpkg2/index.js" ]'
check "and this project's worktree directory is not a prefix the other repository's lane is measured against" \
  '! lib_eval "disk_clean_worktree \"$FAR\" all 1" && lib_eval "disk_clean_worktree \"$FAR\" all 1 || printf %s \"\$DISK_SKIP_REASON\"" | grep -q "it is not a lane of team"'
# Rule 2 through the OTHER repository's git.
check "a file that the other repository tracks is not deleted, even under a name on the list" \
  '/bin/mkdir -p "$FAR/dist" && printf "committed\n" >"$FAR/dist/keep.txt" && git -C "$FAR" add -f dist/keep.txt >/dev/null 2>&1 && git -C "$FAR" -c user.name=disk -c user.email=disk@example.invalid commit -qm "the other repo commits its dist" && mkfile "$FAR/dist/bundle.js" 300 && /bin/mkdir -p "$FAR/node_modules/pkg" && mkfile "$FAR/node_modules/pkg/lib.js" 300 && teamctl prune >/dev/null 2>&1 && [ -f "$FAR/dist/keep.txt" ] && [ -f "$FAR/dist/bundle.js" ] && [ ! -e "$FAR/node_modules" ]'
teamctl spawn far2 glm53 --no-kickoff --repo "$REPO2" --link-node-modules >/dev/null 2>&1
sleep 1
FAR2="$(teamctl status --json | jq -r '.agents[] | select(.role == "far2") | .workdir')"
check "--link-node-modules on a --repo lane links to THAT repository's node_modules, not this project's" \
  '[ -L "$FAR2/node_modules" ] && [ -f "$FAR2/node_modules/rootpkg2/index.js" ] && [ ! -e "$FAR2/node_modules/rootpkg" ] && [ "$(/usr/bin/readlink "$FAR2/node_modules")" = "$REPO2/node_modules" ]'
teamctl stop far2 >/dev/null 2>&1
check "cleaning it takes the link and never the other repository's copy" \
  'teamctl prune >/dev/null 2>&1; [ ! -e "$FAR2/node_modules" ] && [ -f "$REPO2/node_modules/rootpkg2/index.js" ]'
check "removing a --repo lane takes its worktree in the other repository and says where it was" \
  'out="$(teamctl remove far2 --yes 2>&1)"; [ $? -eq 0 ] && [ ! -d "$FAR2" ] && printf "%s" "$out" | grep -q "in .*other repo" && printf "%s" "$out" | grep -qE "freed [0-9.]+ (KB|MB|GB)" && [ -f "$REPO2/node_modules/rootpkg2/index.js" ] && [ -f "$REPO2/README.md" ]'

echo "== destroy --worktrees gets the gigabytes back too"
DEST="$(teamctl destroy --worktrees --yes 2>&1)"
check "destroy --worktrees takes each lane's build output before it decides what to remove" \
  'printf "%s" "$DEST" | grep -qE "freed [0-9.]+ (KB|MB|GB) of build output"'
check "and the lane that holds real work is still kept, with its work" \
  '[ -d "$MESSY" ] && git -C "$MESSY" status --porcelain | grep -q "README.md"'

echo "== after a reboot: no session, records still claiming running"
# The case issue #11 is actually about. The machine filled its disk and restarted three
# times; every record still said "running" and there was no tmux server left. prune has to
# clean there — with no session nothing of that team can be alive — and it must NOT read the
# stale records as a disagreement and refuse. destroy above already ended the session.
check "the test server really is gone, so this is the post-reboot state" \
  '! tmux -L "$WOLFMUX_TMUX_SOCKET" has-session -t "=$(lib_eval "session_name_for_project")" 2>/dev/null'
REBOOTED="$(new_lane rebooted)"
mk_build_tree "$REBOOTED"
"$(command -v jq)" --arg w "$REBOOTED" '.role = "rebooted" | .workdir = $w | .branch = "ai/rebooted" | .state = "running" | .pane_id = "%99"' "$RECORDS/messy.json" >"$RECORDS/rebooted.json"
check "prune cleans a lane whose record still says running when there is no session, and exits 0" \
  'out="$(teamctl prune 2>&1)"; [ $? -eq 0 ] && ! printf "%s" "$out" | grep -q "cannot tell whether" && [ ! -e "$REBOOTED/node_modules" ] && [ ! -e "$REBOOTED/.next" ] && [ -f "$REBOOTED/README.md" ]'
/bin/rm -f "$RECORDS/rebooted.json"

# ======================================================================================
# v1.17.0: the sweep happens when the lane is PARKED, without anybody remembering to ask.
#
# Why this block exists at all. v1.16.1 had `teamctl prune`, it worked, and 90.3 GB sat
# under ~/.wolfmux/worktrees anyway, 50.9 GB of it build output (measured 2026-10-13): a
# command nobody runs reclaims nothing. So parking a lane now sweeps it, and these checks
# assert the sweep on a REAL parked lane's directory — the lane teamctl made, the record
# teamctl wrote — never a mocked path, because a mocked path would have passed in v1.16.1
# too and proved nothing about the default.
# ======================================================================================
echo "== auto-prune: parking a lane sweeps it (the default)"
LEDGER="$WOLFMUX_DATA/state/reclaimed.jsonl"
/bin/rm -f "$LEDGER"
# A fresh team: `destroy --worktrees` above ended the session, and the lane that still holds
# work is taken off the books so that it cannot colour the totals below.
teamctl remove messy --force --yes >/dev/null 2>&1
teamctl start fable --no-attach --skip-beads >/dev/null 2>&1
teamctl policy auto-prune on >/dev/null 2>&1
teamctl spawn sweeper glm53 --no-kickoff >/dev/null 2>&1
sleep 2
SWEEP="$(teamctl status --json | jq -r '.agents[] | select(.role == "sweeper") | .workdir')"
check "the lane is a real worktree teamctl made, with a real record" \
  '[ -n "$SWEEP" ] && [ -d "$SWEEP" ] && [ -f "$SWEEP/README.md" ] && git -C "$SWEEP" rev-parse --verify -q HEAD >/dev/null'
mk_build_tree "$SWEEP"
SWEEP_KB="$(kb_of "$SWEEP/node_modules" "$SWEEP/.next" "$SWEEP/dist")"
STOP3="$(teamctl stop sweeper 2>&1)"
check "parking the lane takes node_modules as well, not only the build caches" \
  '[ ! -e "$SWEEP/node_modules" ] && [ ! -e "$SWEEP/.next" ] && [ ! -e "$SWEEP/dist" ]'
check "it says how much it took, and that the lane installs again before its tools run" \
  'printf "%s" "$STOP3" | grep -qE "^freed: +[0-9.]+ (KB|MB|GB) of build output \(node_modules" && printf "%s" "$STOP3" | grep -q "installs again"'
check "it names both ways out: the one lane, and the team" \
  'printf "%s" "$STOP3" | grep -q "teamctl keep sweeper" && printf "%s" "$STOP3" | grep -q "teamctl policy auto-prune off"'
check "the sources, the commits and the git state of the parked lane are untouched" \
  '[ -f "$SWEEP/README.md" ] && [ -z "$(git -C "$SWEEP" status --porcelain)" ] && git -C "$SWEEP" rev-parse --verify -q HEAD >/dev/null'
check "nothing is left half-deleted: no trash directory stays behind" \
  '[ -z "$(/bin/ls -A "$SWEEP" | grep wolfmux-removing)" ]'
# Ammar asked for this by name: a log, under ~/.wolfmux/state, of what was taken.
check "the sweep is written down in ~/.wolfmux/state/reclaimed.jsonl: team, role, bytes and a timestamp" \
  '[ -f "$LEDGER" ] && jq -se "[.[] | select(.role == \"sweeper\" and .team == \"default\" and .trigger == \"stop\" and .freed_kb > 0 and (.ts | test(\"^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T\")))] | length == 1" "$LEDGER" >/dev/null'
check "the bytes in the ledger are the bytes that were really there, not a rounded label" \
  '[ "$(jq -r "select(.role == \"sweeper\") | .freed_kb" "$LEDGER" | head -1)" = "$SWEEP_KB" ]'
check "the ledger names the project and who did it, so a line is readable long after the team is gone" \
  'jq -e "select(.role == \"sweeper\") | (.project | length > 0) and (.by | length > 0) and (.took | test(\"node_modules\"))" "$LEDGER" >/dev/null'
check "every line of the ledger is one JSON object, appended: it is machine-readable, not prose" \
  '[ "$(wc -l <"$LEDGER" | tr -d " ")" -ge 1 ] && jq -e . "$LEDGER" >/dev/null'

echo "== auto-prune off is v1.16.1's stop, exactly"
teamctl policy auto-prune off >/dev/null 2>&1
teamctl spawn keeper2 glm53 --no-kickoff >/dev/null 2>&1
sleep 2
K2="$(teamctl status --json | jq -r '.agents[] | select(.role == "keeper2") | .workdir')"
mk_build_tree "$K2"
teamctl stop keeper2 >/dev/null 2>&1
check "with the policy off, parking takes the caches and keeps node_modules" \
  '[ -d "$K2/node_modules/pkg" ] && [ ! -e "$K2/.next" ] && [ ! -e "$K2/dist" ]'
check "and the line says nothing about installing again, because nothing was uninstalled" \
  '! teamctl stop keeper2 2>&1 | grep -q "installs again"'
check "a policy value that is not on|off is refused (exit 64)" \
  'teamctl policy auto-prune sometimes >/dev/null 2>&1; [ $? -eq 64 ]'
check "teamctl policy shows the key with its value and its choices" \
  'teamctl policy | grep -Eq "^  auto-prune +(on|off) +\(on\|off\)"'
# The v1.16.0 lesson: a knob that is not on WOLFMUX_CONFIG_KEYS is read out of the config
# file and dropped, with no error and no effect. So the round trip is asserted, not assumed.
/bin/mkdir -p "$WORK/cfg"
printf 'WOLFMUX_AUTO_PRUNE=off\n' >"$WORK/cfg/config"
# WOLFMUX_HOME is moved INSIDE the eval, after the libraries have been sourced: lib_eval
# loads them from $WOLFMUX_HOME/lib, so pointing that at the throwaway config directory from
# the outside would leave it with nothing to source and the check would fail for that reason
# instead of for its own.
check "WOLFMUX_AUTO_PRUNE really survives a round trip through ~/.config/wolfmux/config" \
  '[ "$(lib_eval "WOLFMUX_HOME=$WORK/cfg; wolfmux_load_config; printf %s \"\$WOLFMUX_AUTO_PRUNE\"")" = "off" ]'
check "and the policy default is what that file says, with no stored value in the way" \
  'META="$(lib_eval "printf %s \"\$STATE_DIR/meta.json\"")" && jq "del(.policy_auto_prune)" "$META" >"$META.t" && /bin/mv "$META.t" "$META" && [ "$(lib_eval "WOLFMUX_HOME=$WORK/cfg; wolfmux_load_config; policy_get auto-prune")" = "off" ]'
check "the default with no file and nothing set is on" \
  '[ "$(lib_eval "policy_get auto-prune")" = "on" ] && [ "$(WOLFMUX_AUTO_PRUNE=on lib_eval "policy_get auto-prune")" = "on" ]'
check "a value nobody can read falls back to off: an unreadable setting is not permission to delete" \
  '[ "$(WOLFMUX_AUTO_PRUNE=banana lib_eval "policy_get auto-prune")" = "off" ] && [ "$(WOLFMUX_AUTO_PRUNE=08 lib_eval "policy_get auto-prune")" = "off" ]'
teamctl policy auto-prune on >/dev/null 2>&1

echo "== teamctl keep: one lane the sweep leaves alone"
teamctl spawn costly glm53 --no-kickoff >/dev/null 2>&1
sleep 2
COSTLY="$(teamctl status --json | jq -r '.agents[] | select(.role == "costly") | .workdir')"
mk_build_tree "$COSTLY"
check "teamctl keep protects a lane and says what it means" \
  'teamctl keep costly 2>&1 | grep -q "never swept automatically"'
check "the flag lives in the lane's own record, which is where the sweep reads it" \
  '[ "$(teamctl status --json | jq -r ".agents[] | select(.role == \"costly\") | .keep_build")" = "on" ]'
KEPT="$(teamctl stop costly 2>&1)"
check "parking a protected lane keeps every byte of its build output, and says why" \
  '[ -d "$COSTLY/node_modules/pkg" ] && [ -d "$COSTLY/.next" ] && printf "%s" "$KEPT" | grep -q "kept:    its build output (teamctl keep protects this lane)"'
check "teamctl prune honours it too: the sweep asked for by hand is still the automatic sweep" \
  'teamctl prune 2>&1 | grep -qE "^  costly +[0-9.]+ (KB|MB|GB) +kept: teamctl keep protects this lane" && [ -d "$COSTLY/node_modules/pkg" ]'
check "teamctl keep with no role lists what is protected, so a flag nobody can see cannot hoard" \
  'teamctl keep 2>&1 | grep -q "^  costly " && teamctl keep 2>&1 | grep -q "teamctl keep <role> off"'
check "nothing in the ledger claims a protected lane was swept" \
  '! jq -e "select(.role == \"costly\")" "$LEDGER" >/dev/null 2>&1'
check "teamctl keep <role> off lets it be swept again, and prune then takes it" \
  'teamctl keep costly off 2>&1 | grep -q "swept again" && teamctl prune >/dev/null 2>&1 && [ ! -e "$COSTLY/node_modules" ] && [ -f "$COSTLY/README.md" ]'
check "a worker cannot set the flag: it is the lead's call (exit 77)" \
  'TEAM_ROLE=costly teamctl keep costly >/dev/null 2>&1; [ $? -eq 77 ]'
check "but a worker may look, because looking is not changing" \
  'TEAM_ROLE=costly teamctl keep >/dev/null 2>&1'
check "keeping the lead is refused: it works in your own checkout and nothing of its is swept" \
  'teamctl keep lead >/dev/null 2>&1; [ $? -ne 0 ]'
check "an unknown value is a usage error, not a silently ignored word" \
  'teamctl keep costly maybe >/dev/null 2>&1; [ $? -eq 64 ]'

echo "== a lane mid-build is never swept: the machine's heavy lock"
# A build runs in whatever shell started it, not in the lane's pane, so `stop` cannot see
# it. The signal is the lock this machine already uses for its heavy runs:
# `lockf ~/.wolfmux/machine-heavy.lock <command>`. It is a LOCK and not a file that exists:
# the file is kept between runs, so only trying to take it answers the question.
teamctl spawn building glm53 --no-kickoff >/dev/null 2>&1
sleep 2
BUILDING="$(teamctl status --json | jq -r '.agents[] | select(.role == "building") | .workdir')"
mk_build_tree "$BUILDING"
check "the lock file merely existing is NOT a heavy run, or every sweep would stop for ever" \
  'touch "$WOLFMUX_DATA/machine-heavy.lock" && ! lib_eval "disk_heavy_run_in_progress"'
if [ -x /usr/bin/lockf ]; then
  /usr/bin/lockf -k -s "$WOLFMUX_DATA/machine-heavy.lock" /bin/sleep 25 &
  HEAVY_PID=$!
  sleep 1
  check "while a heavy run holds the lock, the sweep reports it is held and takes nothing" \
    'lib_eval "disk_heavy_run_in_progress"'
  HELD_OUT="$(teamctl stop building 2>&1)"
  check "parking a lane during a heavy run keeps its build output and names the lock" \
    '[ -d "$BUILDING/node_modules/pkg" ] && printf "%s" "$HELD_OUT" | grep -q "a heavy run holds" && printf "%s" "$HELD_OUT" | grep -q "machine-heavy.lock"'
  check "the lane is not written into the ledger, because nothing was taken from it" \
    '! jq -e "select(.role == \"building\")" "$LEDGER" >/dev/null 2>&1'
  kill "$HEAVY_PID" 2>/dev/null
  wait "$HEAVY_PID" 2>/dev/null
  sleep 1
  check "once the heavy run ends, the same lane is swept by the next prune" \
    '! lib_eval "disk_heavy_run_in_progress" && teamctl prune >/dev/null 2>&1 && [ ! -e "$BUILDING/node_modules" ]'
else
  skip "a heavy run on the machine stops the sweep, and the lane is swept once it ends" \
    "no /usr/bin/lockf here: the heavy-lock convention cannot exist on this machine"
fi
check "a running lane is never swept, whatever the policy says" \
  'teamctl spawn alive glm53 --no-kickoff >/dev/null 2>&1; sleep 2; A="$(teamctl status --json | jq -r ".agents[] | select(.role == \"alive\") | .workdir")" && mk_build_tree "$A" && ! lib_eval "SESSION=\$(session_name_for_project); disk_park_sweep alive" && [ -d "$A/node_modules/pkg" ] && lib_eval "SESSION=\$(session_name_for_project); disk_park_sweep alive || printf %s \"\$PARK_SWEEP_WHY\"" | grep -q "still running"'
check "a parked lane holding work a person wrote is never swept, and the reason is said" \
  'teamctl spawn written glm53 --no-kickoff >/dev/null 2>&1; sleep 2; W="$(teamctl status --json | jq -r ".agents[] | select(.role == \"written\") | .workdir")" && mk_build_tree "$W" && printf "notes\n" >"$W/NOTES.md" && teamctl stop written 2>&1 | grep -q "kept:    its build output (it has untracked files that are not build output (NOTES.md))" && [ -d "$W/node_modules/pkg" ]'

echo "== what the status bar reads: the parked number teamctl teams leaves behind"
# Before the second team is created: lib_eval calls load_project, which refuses to guess
# with several teams and no --team, so every lib_eval below this point would die for that
# reason rather than for its own.
check "teamctl teams writes the parked total of this team next to the lane total" \
  'teamctl teams >/dev/null 2>&1; lib_eval "[ -f \"\$(disk_parked_cache_file)\" ] && disk_parked_kb \"\$STATE_DIR\" | grep -Eq \"^[0-9]+$\""'
check "the parked total counts the lanes that are NOT running, and never more than the lane total" \
  'lib_eval "p=\$(disk_parked_kb \"\$STATE_DIR\"); t=\$(disk_team_kb_cached); [ -n \"\$p\" ] && [ -n \"\$t\" ] && [ \"\$p\" -le \"\$t\" ]"'
check "an old parked number is still used, because a parked lane's size does not change by itself" \
  'lib_eval "printf \"%s 4096\n\" \"\$(( \$(now_epoch) - 90000 ))\" > \"\$(disk_parked_cache_file)\"; [ \"\$(disk_parked_kb \"\$STATE_DIR\")\" = 4096 ]"'
check "a garbled, short, empty or leading-zero parked file is dropped silently" \
  '(for v in "garbage" "123" "" "08 500" "-5 -5"; do lib_eval "printf \"%s\n\" \"$v\" > \"\$(disk_parked_cache_file)\"; [ -z \"\$(disk_parked_kb \"\$STATE_DIR\")\" ]" || exit 1; done)'
check "a prune corrects it by exactly what it took out of parked lanes" \
  'lib_eval "printf \"%s 8192\n\" \"\$(now_epoch)\" > \"\$(disk_parked_cache_file)\"; disk_parked_adjust 2048; [ \"\$(disk_parked_kb \"\$STATE_DIR\")\" = 6144 ]" && lib_eval "disk_parked_adjust 999999; [ \"\$(disk_parked_kb \"\$STATE_DIR\")\" = 0 ]"'

echo "== teamctl prune --all-teams: the whole machine, and yours alone to run"
# A lead cannot prune another team (exit 77, rule 4 of lib/disk.sh), which is right and
# stays. But from a plain terminal there was no way to see what the whole machine held:
# prune --dry-run answers for one team, teamctl teams for one project, and 21 teams is 21
# commands and no total.
teamctl start fable --team second --no-attach --skip-beads >/dev/null 2>&1
teamctl spawn far-away glm53 --team second --no-kickoff >/dev/null 2>&1
sleep 2
SECOND="$(teamctl --team second status --json | jq -r '.agents[] | select(.role == "far-away") | .workdir')"
mk_build_tree "$SECOND"
teamctl stop far-away --team second >/dev/null 2>&1
teamctl policy auto-prune off --team second >/dev/null 2>&1
mk_build_tree "$SECOND"
ALL="$(teamctl prune --all-teams --dry-run 2>&1)"
check "the dry run reports every team of the machine under its project, and deletes nothing" \
  'printf "%s" "$ALL" | grep -q "^PROJECT " && printf "%s" "$ALL" | grep -q "^  TEAM default" && printf "%s" "$ALL" | grep -q "^  TEAM second" && [ -d "$SECOND/node_modules/pkg" ]'
check "it gives a total per team and one for the machine" \
  'printf "%s" "$ALL" | grep -qE "^    team total +[0-9.]+ (KB|MB|GB) +would be freed in this team" && printf "%s" "$ALL" | grep -qE "^  machine total +[0-9.]+ (KB|MB|GB) +is what this would free in [0-9]+ parked lanes? across [0-9]+ teams in [0-9]+ projects?"'
check "it says plainly that nothing is deleted" \
  'printf "%s" "$ALL" | grep -q "DRY RUN: nothing is deleted"'
check "a lead is refused with 77, told why, and told what it may run instead" \
  'out="$(TEAM_ROLE=lead teamctl prune --all-teams --dry-run 2>&1)"; rc=$?; [ "$rc" -eq 77 ] && printf "%s" "$out" | grep -q "machine owner.s alone to run" && printf "%s" "$out" | grep -q "no standing outside its own team" && printf "%s" "$out" | grep -q "no --all-teams"'
check "the refusal sends nobody to a lead who could not grant it anyway" \
  'out="$(TEAM_ROLE=lead teamctl prune --all-teams 2>&1)"; printf "%s" "$out" | grep -q "nobody to ask" && ! printf "%s" "$out" | grep -q "bd create"'
check "the refusal holds for the destructive form as well, and nothing is touched by it" \
  'out="$(TEAM_ROLE=lead teamctl prune --all-teams 2>&1)"; rc=$?; [ "$rc" -eq 77 ] && [ -d "$SECOND/node_modules/pkg" ]'
check "a worker is refused too" \
  'TEAM_ROLE=far-away teamctl prune --all-teams --dry-run >/dev/null 2>&1; [ $? -eq 77 ]'
check "the empty-role rule is the whole rule: a lead of the OTHER team is refused as well" \
  'WOLFMUX_TEAM=second TEAM_ROLE=lead teamctl prune --all-teams --dry-run >/dev/null 2>&1; [ $? -eq 77 ]'
check "one team's --dry-run is still open to anyone, because looking is not changing" \
  'TEAM_ROLE=far-away teamctl prune --dry-run --team second >/dev/null 2>&1'
ALLRUN="$(teamctl prune --all-teams 2>&1)"
check "run for real it sweeps the lanes of every team, this project's and the second team's" \
  '[ ! -e "$SECOND/node_modules" ] && [ -f "$SECOND/README.md" ]'
check "and reports what it freed per team and for the machine" \
  'printf "%s" "$ALLRUN" | grep -qE "^    team total +[0-9.]+ (KB|MB|GB) +freed in this team" && printf "%s" "$ALLRUN" | grep -qE "^  machine total +[0-9.]+ (KB|MB|GB) +freed from [0-9]+ parked lanes? across"'
check "every lane it emptied is in the ledger, with prune as the trigger" \
  'jq -se "[.[] | select(.trigger == \"prune\")] | length >= 1" "$LEDGER" >/dev/null'
check "a team whose lane cannot be placed is skipped WHOLE and named, and the rest still runs" \
  'R="$(/bin/ls -d "$WOLFMUX_DATA"/state/*/teams/second/agents | head -1)" && jq ".state = \"running\" | .pane_id = \"%998\"" "$R/far-away.json" >"$R/far-away.json.t" && /bin/mv "$R/far-away.json.t" "$R/far-away.json" && out="$(teamctl prune --all-teams 2>&1)"; rc=$?; [ "$rc" -eq 0 ] && printf "%s" "$out" | grep -q "cannot tell whether .far-away. is running" && printf "%s" "$out" | grep -q "skipped whole and nothing of it was touched" && printf "%s" "$out" | grep -q "Teams skipped whole"'
check "and the one-team form still refuses outright instead of skipping, which is its own rule" \
  'teamctl prune --team second >/dev/null 2>&1; [ $? -ne 0 ]'
check "--all-teams --keep-node-modules takes the caches only, across the machine" \
  'teamctl prune --all-teams --keep-node-modules 2>&1 | grep -q "takes:.*\.next" && ! teamctl prune --all-teams --dry-run --keep-node-modules 2>&1 | grep -q "takes: node_modules"'
check "an unknown option is still a usage error" \
  'teamctl prune --all-teams --nonsense >/dev/null 2>&1; [ $? -eq 64 ]'

echo "== a plain teamctl destroy parks every lane, so it sweeps every lane"
# The second path that leaves lanes parked, and the one that does it in bulk: destroy
# without --worktrees ends the session and keeps every worktree. Before v1.17.0 each of
# those lanes kept its whole node_modules until somebody ran prune.
teamctl policy auto-prune on --team second >/dev/null 2>&1
teamctl restart far-away --team second >/dev/null 2>&1
sleep 2
mk_build_tree "$SECOND"
DESTROY2="$(teamctl destroy --team second --yes 2>&1)"
check "destroy without --worktrees sweeps the build output of every lane it parks" \
  '[ ! -e "$SECOND/node_modules" ] && [ ! -e "$SECOND/.next" ] && printf "%s" "$DESTROY2" | grep -qE "^  far-away: freed [0-9.]+ (KB|MB|GB) of build output"'
check "it still keeps the worktree, the sources and the branch, as it always did" \
  '[ -d "$SECOND" ] && [ -f "$SECOND/README.md" ] && printf "%s" "$DESTROY2" | grep -q "worktrees kept"'
check "and that sweep is in the ledger too, with destroy as the trigger" \
  'jq -se "[.[] | select(.trigger == \"destroy\" and .role == \"far-away\")] | length >= 1" "$LEDGER" >/dev/null'

echo
echo "result: $passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
