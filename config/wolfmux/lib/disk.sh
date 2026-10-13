#!/bin/bash
# disk.sh — the regenerable build output of lane worktrees, and the free space left.
#
# A lane worktree is cheap to make and expensive to keep. On one project here each one
# carried about 2.3 GB of node_modules, 0.9 GB of .next and half a gigabyte of copied
# assets, nothing ever removed any of it, 27 parked lanes of a single project reached
# 65 GB, ~/.wolfmux reached 102 GB, and the machine filled its disk and rebooted three
# times with every team's work in flight (issue #11). teamctl creates those directories,
# so teamctl cleans them up: `stop` takes the build caches, `remove` and
# `destroy --worktrees` take everything, `prune` sweeps every parked lane, and `spawn`
# refuses to add a lane to a disk that is nearly full.
#
# Nothing here ever deletes work. Four rules hold for every deletion in this file:
#   1  only a name on WOLFMUX_BUILD_DIRS — the one list, right below;
#   2  never a path that git tracks in that worktree, whatever it is called (a project
#      that commits its dist is not ours to break);
#   3  never a worktree that holds uncommitted changes to tracked files, or untracked
#      files that are not themselves build output: it is skipped, and the skip is said;
#   4  only inside a worktree that wolfmux made for this project and this team. Every
#      path is resolved with `pwd -P` and checked against that prefix, so a record
#      someone edited by hand, or a directory that is really a symlink leading out,
#      cannot aim a deletion anywhere else.
#
# Sizes are measured with disk_kb / human_size (lib/agents.sh), the same two helpers
# `teamctl destroy --purge` already reports with.

# Every directory a cleanup may delete: build output and package caches that a build
# command makes again from the sources. ONE list, so the whole of it can be read and
# changed at a glance. A name on this list is still only deleted when rules 2-4 hold.
WOLFMUX_BUILD_DIRS="node_modules .next dist .turbo build coverage .cache .parcel-cache .vite .svelte-kit .nuxt target"

# `teamctl stop` is reversible with `teamctl restart`, and a lane that has to reinstall
# its dependencies before it can do anything is a slow, noisy surprise. So stop takes the
# build caches only and keeps node_modules; remove, destroy --worktrees and prune, where
# the lane is going away or parked, take the whole list.
WOLFMUX_KEEP_ON_STOP="node_modules"

# Of the names above, the three most likely to hold something a person wrote by hand. They
# matter in one place: whether `teamctl remove` asks before discarding a lane
# (disk_work_dirty_list). When a project ignores these directories git says nothing about
# them and nothing changes; when it tracks them rule 2 protects them. The case left over is
# a directory git neither tracks nor ignores, and there a dist/deploy.sh somebody wrote is
# more likely than build output nobody will miss — so remove asks instead of assuming.
WOLFMUX_WORK_LIKE_DIRS="build dist target"

# The default disk-min-gb: a lane costs about 3 GB of node_modules and build output, so
# 20 GB is seven more lanes' worth of room, and macOS wants several gigabytes of its own
# for swap, updates and Spotlight. Low enough not to nag, high enough that the guard
# trips while there is still time to run `teamctl prune`.
WOLFMUX_DISK_MIN_GB_DEFAULT=20

# The machine's "something heavy is running" flag, held with lockf(1) by whoever is doing the
# heavy thing — a test gate, a measurement run, a build. It is a LOCK, not a file that exists:
# lockf keeps the file afterwards (-k), so the file being there says nothing at all. Only an
# attempt to take the lock answers, and that is what disk_heavy_run_in_progress does.
WOLFMUX_HEAVY_LOCK="${WOLFMUX_HEAVY_LOCK:-$WOLFMUX_DATA/machine-heavy.lock}"
LOCKF_BIN="$(find_tool lockf /usr/bin/lockf || true)"

# Where every sweep is written down, for the whole machine and not per team: the question
# "what did this thing delete, and when" is asked across teams and long after the team that
# held the lane is gone. One JSON object per line, appended, like a team's events.jsonl.
disk_reclaim_log_file() { printf '%s/state/reclaimed.jsonl\n' "$WOLFMUX_DATA"; }

# disk_names <all|caches> — the directory names a cleanup of that kind may delete
disk_names() {
  local name keep=""
  if [ "$1" = "caches" ]; then keep="$WOLFMUX_KEEP_ON_STOP"; fi
  for name in $WOLFMUX_BUILD_DIRS; do
    case " $keep " in *" $name "*) continue ;; esac
    printf '%s\n' "$name"
  done
}

# --- free space ----------------------------------------------------------------------
# disk_free_kb [<path>] — kilobytes free where wolfmux keeps its data, empty when df
# cannot say. -P keeps one filesystem on one line however long the device is called.
disk_free_kb() {
  local path="${1:-$WOLFMUX_DATA}"
  while [ ! -d "$path" ] && [ "$path" != "/" ] && [ -n "$path" ]; do path="$(dirname "$path")"; done
  df -Pk "$path" 2>/dev/null | awk 'NR == 2 { print $4; exit }'
}

# disk_free_label — free space for a status line, or a word when df said nothing
disk_free_label() {
  local kb
  kb="$(disk_free_kb)"
  case "${kb:-x}" in "" | *[!0-9]*) printf 'unknown\n' ;; *) human_size "$kb" ;; esac
}

# --- is this worktree ours to clean? -------------------------------------------------
# disk_real <path> — absolute, every symlink resolved; empty when the path is not there
disk_real() { (cd "$1" 2>/dev/null && pwd -P) || true; }

# disk_confined <path> [<worktrees dir>] [<repository>] — a lane worktree of that worktree
# directory, and not the directory itself. Rule 4: the only answer that lets anything be
# deleted. The two optional arguments are this team's own by default; a teammate spawned
# with `teamctl spawn --repo` lives under its own repository's worktree directory, and
# worker_trees_dir / worker_repo say which (disk_clean_role passes them).
disk_confined() {
  local real base trees="${2:-${WORKTREES_DIR:-}}" repo="${3:-$ROOT}"
  real="$(disk_real "$1")"
  base="$(disk_real "$trees")"
  [ -n "$real" ] && [ -n "$base" ] || return 1
  [ "$real" != "$base" ] || return 1
  [ "$real" != "$(disk_real "$repo")" ] || return 1 # a checkout itself, never
  # The first team's worktree directory is also the parent of the named teams' ones
  # (teams/<name>/<lane>), so for it the prefix alone would reach another team's lanes.
  # Another team's lanes are that team's to clean.
  if [ "${TEAM:-}" = "$WOLFMUX_DEFAULT_TEAM" ]; then
    case "$real/" in "$base"/teams/*) return 1 ;; esac
  fi
  case "$real/" in "$base"/?*/) return 0 ;; esac
  return 1
}

# disk_cleanable <path> — 0 when this worktree may be cleaned at all. Sets
# DISK_SKIP_REASON otherwise. Rules 3 and 4. The untracked test uses the whole list and
# not the kind: a lane with node_modules is cleanable even when node_modules is kept.
disk_cleanable() {
  local path="$1" trees="${2:-${WORKTREES_DIR:-}}" repo="${3:-$ROOT}" status line entry first
  DISK_SKIP_REASON=""
  if [ ! -d "$path" ]; then
    DISK_SKIP_REASON="its worktree is gone"
    return 1
  fi
  if ! disk_confined "$path" "$trees" "$repo"; then
    DISK_SKIP_REASON="it is not a lane of team '${TEAM:-?}' under $(short_path "${trees:-(no worktree directory resolved)}")"
    return 1
  fi
  if ! "$GIT_BIN" -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    DISK_SKIP_REASON="git does not know that directory"
    return 1
  fi
  status="$("$GIT_BIN" -C "$path" status --porcelain 2>/dev/null)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      '?? '*) ;;
      *)
        DISK_SKIP_REASON="it has uncommitted changes to tracked files"
        return 1
        ;;
    esac
    entry="${line#?? }"
    first="${entry%%/*}" # an untracked directory is reported as "node_modules/"
    # Our own trash counts as build output: a cleanup that was killed halfway left it, and
    # if it made the worktree look dirty the lane could never be cleaned again.
    case "$first" in .wolfmux-removing-*) continue ;; esac
    case " $WOLFMUX_BUILD_DIRS " in
      *" $first "*) ;;
      *)
        DISK_SKIP_REASON="it has untracked files that are not build output ($first)"
        return 1
        ;;
    esac
  done <<EOF
$status
EOF
  return 0
}

# --- is anything here a person's work? -----------------------------------------------
# disk_work_dirty_list <path> — the lines of `git status --porcelain` that are somebody's
# work. Everything is, except an untracked entry that can only be build output: a name on
# WOLFMUX_BUILD_DIRS that is NOT one of WOLFMUX_WORK_LIKE_DIRS, or our own
# .wolfmux-removing-* trash.
#
# Two of those exceptions are this tool's own doing, and counting them as work was wrong.
# A lane made with --link-node-modules carries an untracked node_modules SYMLINK whenever
# .gitignore says "node_modules/" with the trailing slash (the common form: that pattern
# matches directories, not links), and an interrupted cleanup leaves trash. `teamctl
# remove` counted either as a dirty file and demanded --force — the discard-work door —
# for a lane wolfmux itself had made that way. An untracked build / dist / target that the
# project neither tracks nor ignores stays work: see WOLFMUX_WORK_LIKE_DIRS.
#
# This is deliberately NOT wt_dirty_count: that one answers "is anything uncommitted here",
# which is the right question for the status and worktrees tables. This one answers "would
# removing this lane lose something a person wrote", which is the question `remove` asks.
disk_work_dirty_list() {
  local path="$1" status line entry first work
  [ -d "$path" ] || return 0
  status="$("$GIT_BIN" -C "$path" status --porcelain 2>/dev/null || true)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      '?? '*) ;;
      *)
        printf '%s\n' "$line" # a tracked file changed: always work
        continue
        ;;
    esac
    entry="${line#?? }"
    first="${entry%%/*}" # an untracked directory is reported as "node_modules/"
    case "$first" in .wolfmux-removing-*) continue ;; esac
    work=0
    case " $WOLFMUX_WORK_LIKE_DIRS " in *" $first "*) work=1 ;; esac
    if [ "$work" -eq 0 ]; then
      case " $WOLFMUX_BUILD_DIRS " in *" $first "*) continue ;; esac
    fi
    printf '%s\n' "$line"
  done <<EOF
$status
EOF
}

# disk_work_dirty_count <path> — how many of those there are
disk_work_dirty_count() { disk_work_dirty_list "$1" | wc -l | tr -d ' '; }

# --- the cleaning itself -------------------------------------------------------------
# disk_clean_worktree <path> <all|caches> <apply 0|1> — the allowlisted directories of
# ONE worktree. Sets DISK_FREED_KB (kilobytes, also when apply is 0) and DISK_CLEANED
# (the names, for the line a command prints). Returns 1 and touches nothing when
# disk_cleanable said no.
#
# Each directory is renamed inside its own worktree before it is deleted, and a rename
# is one atomic step. So a cleanup killed halfway — the disk fills, the machine reboots —
# leaves a .wolfmux-removing-* directory that the next run clears, never a node_modules
# that is half there and looks installed. A lane that lost its node_modules still has
# every source file and all of its git state; it needs one `npm install` (or whatever
# the project installs with) before its tools run again.
disk_clean_worktree() {
  local path="$1" kind="$2" apply="$3" trees="${4:-}" repo="${5:-}" real name target trash kb leftover
  DISK_FREED_KB=0
  DISK_CLEANED=""
  disk_cleanable "$path" "${trees:-${WORKTREES_DIR:-}}" "${repo:-$ROOT}" || return 1
  real="$(disk_real "$path")"
  # What an interrupted cleanup left. It is counted and named like anything else, so the
  # line a command prints says where the space came from instead of appearing out of thin air.
  for leftover in "$real"/.wolfmux-removing-*; do
    [ -e "$leftover" ] || continue
    DISK_FREED_KB=$((DISK_FREED_KB + $(disk_kb "$leftover")))
    case " $DISK_CLEANED " in *" cleanup-trash "*) ;; *) DISK_CLEANED="$DISK_CLEANED cleanup-trash" ;; esac
    if [ "$apply" -eq 1 ]; then /bin/rm -rf "$leftover"; fi
  done
  for name in $(disk_names "$kind"); do
    target="$real/$name"
    [ -e "$target" ] || [ -L "$target" ] || continue
    # Rule 2, asked of git itself, per candidate.
    if [ -n "$("$GIT_BIN" -C "$real" ls-files -- "$name" 2>/dev/null | head -1)" ]; then continue; fi
    if [ -L "$target" ]; then
      # a linked node_modules (teamctl spawn --link-node-modules): the link goes, its target never
      if [ "$apply" -eq 1 ]; then /bin/rm -f "$target"; fi
      DISK_CLEANED="$DISK_CLEANED $name"
      continue
    fi
    [ -d "$target" ] || continue
    # Rule 4 again, for the candidate: a directory whose real path leaves the worktree
    # (someone put a symlink in the middle of it) is left alone.
    case "$(disk_real "$target")/" in "$real"/?*/) ;; *) continue ;; esac
    kb="$(disk_kb "$target")"
    DISK_FREED_KB=$((DISK_FREED_KB + kb))
    DISK_CLEANED="$DISK_CLEANED $name"
    if [ "$apply" -eq 1 ]; then
      trash="$real/.wolfmux-removing-$name.$$"
      /bin/mv -f "$target" "$trash" 2>/dev/null || trash=""
      if [ -n "$trash" ]; then /bin/rm -rf "$trash"; else /bin/rm -rf "$target"; fi
    fi
  done
  DISK_CLEANED="${DISK_CLEANED# }"
  return 0
}

# disk_clean_role <role> <all|caches> <apply 0|1> — the same for an agent on record, and
# the form every command uses: the record says which repository the teammate belongs to
# (`teamctl spawn --repo` can make that another one), so rule 4 is checked against that
# repository's worktree directory and not blindly against this project's.
# The lead works in a checkout of yours and nothing of its is ever deleted.
disk_clean_role() {
  local role="$1"
  DISK_FREED_KB=0
  DISK_CLEANED=""
  DISK_SKIP_REASON=""
  if [ "$(reg_field "$role" kind)" != "worker" ]; then
    DISK_SKIP_REASON="it works in your own checkout"
    return 1
  fi
  disk_clean_worktree "$(reg_field "$role" workdir)" "$2" "$3" "$(worker_trees_dir "$role")" "$(worker_repo "$role")"
}

# --- what a team's lanes take, without making `teamctl status` slow ------------------
# du over one lane's node_modules walks tens of thousands of files: one real one here is
# 69,336 files and 802 MB, and a warm `du -sk` of it takes 0.62 s. Over the 36 lane
# worktrees on this machine that is 12.4 s. `teamctl status` runs every few minutes, so it
# never measures: the commands that change the lanes anyway (stop, remove, prune, destroy,
# and `teamctl teams`, which does measure) leave the number behind and status reads it.
WOLFMUX_DISK_CACHE_SECONDS=900

disk_cache_file() { printf '%s/disk-kb\n' "$STATE_DIR"; }

# The same number for the lanes that are PARKED, in a file of its own. It answers a different
# question from the total — "how much of this is sitting there doing nothing", which is the
# one the status bar's `held` field shows — and it is a second file rather than a second
# column so that a file written by an older version still parses, and an older version still
# parses a file written by this one.
#
# Written by disk_team_kb_measure (that is: by `teamctl teams`, the one command that measures)
# and corrected by `teamctl prune`, which knows exactly how much it took out of PARKED lanes
# because parked lanes are the only ones it sweeps. The sweep on park does NOT correct it:
# the lane it just swept was running when the number was measured, so it was not in it, and
# subtracting from a total that never contained it would make the number smaller than the
# truth. It waits for the next measurement instead, and `teamctl bar --explain` says so.
disk_parked_cache_file() { printf '%s/disk-parked-kb\n' "$STATE_DIR"; }

# disk_parked_put <kilobytes> — remember it, stamped now
disk_parked_put() {
  [ -d "$STATE_DIR" ] || return 0
  printf '%s %s\n' "$(now_epoch)" "${1:-0}" >"$(disk_parked_cache_file)" 2>/dev/null || true
}

# disk_parked_kb <state-dir> — the remembered parked total of ONE team, empty when there is
# no readable number. Deliberately WITHOUT the freshness rule disk_team_kb_cached applies:
# a parked lane is a lane in which nothing is running, so its size does not change by itself,
# and an hour-old measurement of it is still the measurement. Every field is checked the same
# way (no leading zero: shell arithmetic would read 08 as octal and abort).
disk_parked_kb() {
  local line stamp kb
  line="$(/bin/cat "$1/disk-parked-kb" 2>/dev/null || true)"
  [ -n "$line" ] || return 0
  stamp="${line%% *}"
  kb="${line##* }"
  [ "$stamp" != "$line" ] || return 0
  case "${stamp:-x}" in "" | *[!0-9]* | 0?*) return 0 ;; esac
  case "${kb:-x}" in "" | *[!0-9]* | 0?*) return 0 ;; esac
  printf '%s\n' "$kb"
}

# disk_parked_adjust <kilobytes freed> — a prune that just emptied parked lanes corrects it
disk_parked_adjust() {
  local kb stamp line
  [ "${1:-0}" -gt 0 ] || return 0
  kb="$(disk_parked_kb "$STATE_DIR")"
  [ -n "$kb" ] || return 0
  line="$(/bin/cat "$(disk_parked_cache_file)" 2>/dev/null || true)"
  stamp="${line%% *}"
  kb=$((kb - $1))
  [ "$kb" -ge 0 ] || kb=0
  printf '%s %s\n' "$stamp" "$kb" >"$(disk_parked_cache_file)" 2>/dev/null || true
}

# disk_team_kb_measure — du over this team's lane worktrees; remembers the number, and the
# parked part of it. One du per lane either way: the running test is tmux and the registry,
# which this walk is already holding.
disk_team_kb_measure() {
  local role kb=0 parked=0 one
  # disk_lane_running asks tmux about $SESSION. Every caller so far sets it first; resolving
  # it here when it is empty means a future one that forgets cannot abort the command under
  # `set -u`, and the value is the one session_name_for_project would have given anyway.
  [ -n "${SESSION:-}" ] || SESSION="$(session_name_for_project)"
  for role in $(reg_list); do
    [ "$(reg_field "$role" kind)" = "worker" ] || continue
    one="$(disk_kb "$(reg_field "$role" workdir)")"
    kb=$((kb + one))
    # Not running, by disk_lane_running's own rule, where not knowing counts as running: an
    # uncertain lane is never advertised as space that is sitting idle.
    if ! disk_lane_running "$role"; then parked=$((parked + one)); fi
  done
  if [ -d "$STATE_DIR" ]; then
    printf '%s %s\n' "$(now_epoch)" "$kb" >"$(disk_cache_file)" 2>/dev/null || true
    disk_parked_put "$parked"
  fi
  printf '%s\n' "$kb"
}

# disk_cache_adjust <kilobytes freed> — a command that just deleted something knows how
# much, so it corrects the remembered number instead of measuring every lane again (that
# du is the slow thing this cache exists to avoid). No fresh number to correct: nothing
# happens, and status says it was not measured.
disk_cache_adjust() {
  local kb stamp
  [ "${1:-0}" -gt 0 ] || return 0
  kb="$(disk_team_kb_cached)"
  [ -n "$kb" ] || return 0
  stamp="$(/bin/cat "$(disk_cache_file)" 2>/dev/null | cut -d' ' -f1)"
  kb=$((kb - $1))
  [ "$kb" -ge 0 ] || kb=0
  printf '%s %s\n' "$stamp" "$kb" >"$(disk_cache_file)" 2>/dev/null || true
}

# disk_team_kb_cached — the remembered number while it is fresh, empty otherwise
disk_team_kb_cached() {
  local line stamp kb
  line="$(/bin/cat "$(disk_cache_file)" 2>/dev/null || true)"
  [ -n "$line" ] || return 0
  stamp="${line%% *}"
  kb="${line##* }"
  # Each field on its own, and no leading zero: this block exists to fall back silently on
  # a garbled file, and "08 500" in it used to make teamctl status print a raw
  # "08: value too great for base" from the arithmetic below. A single 0 is fine.
  case "${stamp:-x}" in "" | *[!0-9]* | 0?*) return 0 ;; esac
  case "${kb:-x}" in "" | *[!0-9]* | 0?*) return 0 ;; esac
  # Both ends: a stamp in the future (a clock that went back, a garbled write) would
  # otherwise stay "fresh" for ever and pin status to a number nobody can correct.
  [ "$stamp" -le "$(now_epoch)" ] || return 0
  [ $(($(now_epoch) - 10#$stamp)) -le "$WOLFMUX_DISK_CACHE_SECONDS" ] || return 0
  printf '%s\n' "$kb"
}

# disk_team_label — this team's lane total for a status line
disk_team_label() {
  local kb
  kb="$(disk_team_kb_cached)"
  if [ -n "$kb" ]; then human_size "$kb"; else printf 'not measured (teamctl teams measures it)\n'; fi
}

# --- the guard before a lane is created ----------------------------------------------
# disk_guard_spawn — free disk, checked before anything is made. Adding a lane means
# another node_modules and another build, and that cost is invisible until the machine
# stops. Policy: disk-guard (refuse | warn | off) and disk-min-gb.
disk_guard_spawn() {
  local mode min free_kb
  mode="$(policy_get disk-guard)"
  [ "$mode" != "off" ] || return 0
  min="$(policy_get disk-min-gb)"
  [ "$min" -gt 0 ] || return 0
  free_kb="$(disk_free_kb)"
  # df could not say: the guard never becomes the reason a spawn fails.
  case "${free_kb:-x}" in "" | *[!0-9]*) return 0 ;; esac
  # 10# forces base ten. policy_valid already refuses a leading zero, and this is the one
  # arithmetic site the value reaches, so neither a stored nor a configured "08" can abort it.
  [ "$free_kb" -lt $((10#$min * 1048576)) ] || return 0
  if [ "$mode" = "warn" ]; then
    warn "$(human_size "$free_kb") free, under the $min GB this team asks for; spawning anyway (teamctl policy disk-guard = warn). Free space: teamctl prune --dry-run"
    return 0
  fi
  die "$(human_size "$free_kb") free on this disk, under the $min GB this team asks for, and a lane needs room for its own node_modules and build (about 3 GB on this project). Look at what the parked lanes hold, then take it: teamctl prune --dry-run · teamctl prune. Change the limit: teamctl policy disk-min-gb <gb> · spawn anyway: teamctl policy disk-guard warn" 75
}

# --- node_modules linking at spawn ---------------------------------------------------
# disk_link_node_modules <repo> <worktree> — the lane shares the installed dependencies of
# the repository it belongs to, instead of installing 2.3 GB of its own. Off by default and
# for a reason: it is ONE directory for every lane and for the checkout itself, so an
# `npm install` in any lane changes the dependencies of all of them, and two lanes that
# need different versions of a package cannot both be right. Only a real directory in that
# repository is linked; one without node_modules, or whose node_modules is itself a link,
# is left alone. <repo> is the teammate's own repository, which `teamctl spawn --repo` can
# make a different one from yours.
disk_link_node_modules() {
  local repo="$1" path="$2"
  [ -d "$repo/node_modules" ] && [ ! -L "$repo/node_modules" ] || return 1
  [ ! -e "$path/node_modules" ] && [ ! -L "$path/node_modules" ] || return 1
  /bin/ln -s "$repo/node_modules" "$path/node_modules" 2>/dev/null || return 1
}

# disk_link_wanted <flag 0|1> — did this spawn ask for it, or does the team's policy?
disk_link_wanted() {
  [ "$1" -eq 1 ] && return 0
  [ "$(policy_get link-node-modules)" = "on" ]
}

# disk_lane_running <role> — is this lane alive? Answered from two places, because prune
# sweeps many lanes unattended and a wrong "parked" would take node_modules out from under
# a running build:
#   0  a live pane is there, or the record says running while the team's session is up and
#      no pane of its can be found — then we do not know, and not knowing is running
#   1  a pane that has exited, a record that says stopped with no pane id, or no session at
#      all (the machine rebooted: nothing of that team can be alive)
# Sets DISK_LANE_DOUBT when the record and tmux disagree, so the caller can refuse the whole
# sweep instead of guessing lane by lane.
disk_lane_running() {
  local role="$1" pane state pane_id
  DISK_LANE_DOUBT=""
  pane="$(tm_pane_for_role "$SESSION" "$role" 2>/dev/null || true)"
  if [ -n "$pane" ]; then
    [ "$(tm_pane_state "$pane")" = "running" ] && return 0
    return 1 # the pane is there and it has exited: we know
  fi
  state="$(reg_field "$role" state 2>/dev/null || true)"
  pane_id="$(reg_field "$role" pane_id 2>/dev/null || true)"
  if [ "$state" != "running" ] && [ -z "$pane_id" ]; then return 1; fi
  tm_session_exists "$SESSION" || return 1 # no session: nothing of this team can be alive
  DISK_LANE_DOUBT="its record says state=${state:-unknown} pane=${pane_id:-none}, and session $SESSION shows no pane for it"
  return 0
}

# --- is the machine busy with something heavy right now? -----------------------------
# disk_heavy_run_in_progress — 0 when a heavy run holds the machine's heavy lock, and the
# automatic sweep must therefore keep its hands off; 1 when it is free. Sets
# DISK_HEAVY_REASON for the line the command prints.
#
# A lane that is MID-BUILD is the one case where taking node_modules does real damage: the
# build fails halfway through with an error nobody can place. `teamctl stop` cannot see that
# build — it runs in whatever shell the person or the gate started it in, not in the lane's
# pane — so the signal has to come from the convention this machine already uses for its
# heavy runs: `lockf ~/.wolfmux/machine-heavy.lock <command>`.
#
# The lock is probed by TRYING to take it for an instant (-t 0, and `true` as the command),
# which is the only thing that answers the question: the file is kept between runs (-k), so
# its existence says nothing. -k is passed here too, for the lock ordering the lockf manual
# asks for: a probe that created and then unlinked the file could make a heavy run that
# started in between lock an inode nobody else will ever open.
#
#   0 from lockf    we got the lock, so nothing holds it: free
#   75 EX_TEMPFAIL  somebody else holds it: a heavy run is in progress
#   anything else   we cannot tell, and not knowing is "busy" — the same rule
#                   disk_lane_running follows for a lane it cannot place
#
# No lockf on this machine at all, or no directory for the lock to live in, is different
# from "cannot tell": the signal cannot exist there, so nothing can be holding it. The
# alternative would be an automatic sweep that silently never runs on such a machine, which
# is the failure this whole release exists to stop.
disk_heavy_run_in_progress() {
  local rc=0
  DISK_HEAVY_REASON=""
  [ -n "$LOCKF_BIN" ] || return 1
  [ -d "$(dirname "$WOLFMUX_HEAVY_LOCK")" ] || return 1
  "$LOCKF_BIN" -k -s -t 0 "$WOLFMUX_HEAVY_LOCK" /usr/bin/true >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 1 ;;
    75) DISK_HEAVY_REASON="a heavy run holds $(short_path "$WOLFMUX_HEAVY_LOCK"); it is swept once that ends" ;;
    *) DISK_HEAVY_REASON="$(short_path "$WOLFMUX_HEAVY_LOCK") could not be read (lockf exit $rc), and not knowing counts as busy" ;;
  esac
  return 0
}

# --- one lane the lead wants left alone ----------------------------------------------
# disk_keep_build <role> — is this lane protected from the automatic sweep? The flag lives
# in the lane's own record (keep_build), and `teamctl keep <role>` is the one way to set it.
disk_keep_build() { [ "$(reg_field "$1" keep_build 2>/dev/null || true)" = "on" ]; }

# disk_reclaim_log <role> <kilobytes> <trigger> <names> — one line in the machine-wide
# ledger: when, which team of which project, which lane, how much, what took it and what it
# took. Never fatal: a ledger that cannot be written must not stop a cleanup.
disk_reclaim_log() {
  local file
  file="$(disk_reclaim_log_file)"
  [ -d "$(dirname "$file")" ] || return 0
  [ -n "$JQ_BIN" ] || return 0
  "$JQ_BIN" -cn --arg ts "$(now_iso)" --arg project "${PROJECT_KEY:-}" --arg team "${TEAM:-}" \
    --arg role "$1" --arg kb "${2:-0}" --arg trigger "${3:-}" --arg took "${4:-}" \
    --arg by "${EVENT_BY:-${TEAM_ROLE:-operator}}" \
    '{ts: $ts, project: $project, team: $team, role: $role, freed_kb: ($kb | tonumber? // 0),
      trigger: $trigger, took: $took, by: $by}' \
    >>"$file" 2>/dev/null || true
}

# --- the sweep a lane gets when it is parked ------------------------------------------
# disk_park_sweep <role> <trigger> — everything that has to hold before a parked lane's
# build output goes, and then the deletion. This is what makes the reclaim automatic: the
# space came back only when somebody remembered `teamctl prune`, and nobody did (90.3 GB
# under ~/.wolfmux/worktrees here, 50.9 GB of it build output, measured 2026-10-13).
#
#   0  something was taken: DISK_FREED_KB and DISK_CLEANED say how much and what
#   1  nothing was taken: PARK_SWEEP_WHY says why, in words a command can print
#
# How much it takes depends on the policy, and the OFF case is today's behaviour exactly:
#   auto-prune on (default)  the whole allowlist, node_modules included. A parked lane is
#                            parked for days and node_modules is most of its weight.
#   auto-prune off           the build caches only — what `teamctl stop` has always taken,
#                            so switching the policy off restores v1.16.1's stop precisely.
#
# Four refusals come before the deletion, and each one is a lane left whole: the policy, the
# lane's own keep flag, a lane that is still running, and a heavy run on the machine. The
# rules in the header of this file (nothing git tracks, nothing a person wrote, nothing
# outside a lane of this team) are checked after that, by disk_clean_role, as for every
# other cleanup here.
disk_park_sweep() {
  local role="$1" trigger="${2:-park}" kind="all"
  DISK_FREED_KB=0
  DISK_CLEANED=""
  PARK_SWEEP_WHY=""
  # As in disk_team_kb_measure: disk_lane_running asks tmux about $SESSION, and a caller that
  # has not set it must not abort the command under `set -u`.
  [ -n "${SESSION:-}" ] || SESSION="$(session_name_for_project)"
  if [ "$(policy_get auto-prune)" != "on" ]; then kind="caches"; fi
  if disk_keep_build "$role"; then
    PARK_SWEEP_WHY="teamctl keep protects this lane"
    return 1
  fi
  if disk_lane_running "$role"; then
    PARK_SWEEP_WHY="it is still running${DISK_LANE_DOUBT:+: $DISK_LANE_DOUBT}"
    return 1
  fi
  if disk_heavy_run_in_progress; then
    PARK_SWEEP_WHY="$DISK_HEAVY_REASON"
    return 1
  fi
  if ! disk_clean_role "$role" "$kind" 1; then
    PARK_SWEEP_WHY="$DISK_SKIP_REASON"
    return 1
  fi
  if [ -z "$DISK_CLEANED" ]; then
    PARK_SWEEP_WHY="it had no build output left to take"
    return 1
  fi
  disk_cache_adjust "$DISK_FREED_KB"
  disk_reclaim_log "$role" "$DISK_FREED_KB" "$trigger" "$DISK_CLEANED"
  return 0
}

# disk_park_sweep_say <role> <trigger> — the sweep plus the one line a command prints about
# it, so `stop` and `destroy` cannot word the same event two ways. Returns what the sweep did.
disk_park_sweep_say() {
  local role="$1"
  if disk_park_sweep "$role" "${2:-park}"; then
    say "freed:   $(human_size "$DISK_FREED_KB") of build output ($DISK_CLEANED)"
    if [ "$(policy_get auto-prune)" = "on" ]; then
      say "         it installs again before its tools run (keep it next time: teamctl keep $role · for the team: teamctl policy auto-prune off)"
    fi
    return 0
  fi
  say "kept:    its build output ($PARK_SWEEP_WHY)"
  return 1
}

# --- teamctl keep <role> [on|off] ----------------------------------------------------
# One lane the automatic sweep leaves alone. The surface is a verb and not a spawn flag on
# purpose: whether a checkout is expensive enough to protect is learnt AFTER it has been
# built — a 40-minute install, a downloaded model, a seeded database — and a flag given at
# spawn time can never be taken back. With no role it lists what is protected, so a flag
# nobody can see cannot quietly keep gigabytes.
cmd_keep() {
  local role="${1:-}" value="${2:-on}" found=0
  require_tools
  load_project
  if [ -z "$role" ]; then
    say "lanes the automatic sweep leaves alone, in team '$TEAM' of $(short_path "$ROOT")"
    for role in $(reg_list); do
      [ "$(reg_field "$role" kind)" = "worker" ] || continue
      disk_keep_build "$role" || continue
      printf '  %-18s %9s   kept: build output is never swept automatically\n' \
        "$role" "$(human_size "$(disk_kb "$(reg_field "$role" workdir)")")"
      found=1
    done
    [ "$found" -eq 1 ] || say "  none: every parked lane of this team is swept (teamctl policy auto-prune = $(policy_get auto-prune))"
    say ""
    say "protect one: teamctl keep <role>   ·   let it be swept again: teamctl keep <role> off"
    return 0
  fi
  require_role_arg "$role"
  case "$value" in on | off) ;; *) die_usage "usage: teamctl keep [<role> [on|off]]   (no role: what is protected now)" ;; esac
  reg_exists "$role" || die "no such agent: $role  (see: teamctl status)"
  [ "$(reg_field "$role" kind)" = "worker" ] || die "'$role' is the lead; it works in your own checkout and nothing of its is ever swept"
  require_manager keep
  ensure_state_dirs
  lock_acquire
  reg_set "$role" keep_build "$value"
  event_log keep "$role" "keep_build=$value"
  lock_release
  if [ "$value" = "on" ]; then
    say "keeping: $role — its build output is never swept automatically (teamctl prune still takes it when you ask)"
  else
    say "released: $role — its build output is swept again when the lane is parked"
  fi
}

# --- teamctl prune [--dry-run] [--keep-node-modules] ---------------------------------
# Every PARKED lane of this team. A parked lane is what actually hoards: it keeps its
# whole node_modules and .next for as long as nobody removes the role, and a lane is
# parked for days. A running lane is never touched. --dry-run reports and deletes
# nothing, and needs no manager: looking is not changing.
#
# prune_team_doubt — the first lane of the loaded team whose running state cannot be told,
# as a sentence; nothing when every lane can be placed. One wrong "parked" costs a running
# build its dependencies, and prune is the command nobody is watching, so a team with a
# doubtful lane is not swept at all.
prune_team_doubt() {
  local role
  for role in $(reg_list); do
    [ "$(reg_field "$role" kind)" = "worker" ] || continue
    if disk_lane_running "$role" && [ -n "$DISK_LANE_DOUBT" ]; then
      printf "cannot tell whether '%s' is running: %s" "$role" "$DISK_LANE_DOUBT"
      return 0
    fi
  done
  return 0
}

# prune_team <kind> <apply 0|1> <indent> — the per-lane lines of the LOADED team, and what
# they add up to: PRUNE_TOTAL (freed, or would be), PRUNE_FLOOR (still held), PRUNE_CLEANED,
# PRUNE_SKIPPED, PRUNE_RUNNING. The caller has loaded the team, set SESSION, taken the lock
# when applying, and checked prune_team_doubt. Split out of cmd_prune so that one team and
# every team on the machine run the same sweep rather than two that can drift.
prune_team() {
  local kind="$1" apply="$2" indent="${3:-  }" role path rest rnote
  PRUNE_TOTAL=0 PRUNE_FLOOR=0 PRUNE_CLEANED=0 PRUNE_SKIPPED=0 PRUNE_RUNNING=0
  for role in $(reg_list); do
    [ "$(reg_field "$role" kind)" = "worker" ] || continue
    path="$(reg_field "$role" workdir)"
    # A teammate spawned with --repo works in another repository, and its lane lives under
    # that repository's worktree directory. The line says so, because "which node_modules
    # was that" is the first question a mixed sweep raises.
    rnote="$(reg_field "$role" repo 2>/dev/null || true)"
    [ -z "$rnote" ] || rnote=" (in $(short_path "$rnote"))"
    # Every lane prune does not empty adds its whole remaining size to the floor below —
    # a running or skipped lane most of all, because it still holds its node_modules too.
    if disk_lane_running "$role"; then
      rest="$(disk_kb "$path")"
      PRUNE_FLOOR=$((PRUNE_FLOOR + rest))
      printf '%s%-18s %9s   running, left alone%s\n' "$indent" "$role" "$(human_size "$rest")" "$rnote"
      PRUNE_RUNNING=$((PRUNE_RUNNING + 1))
      continue
    fi
    # The lead's keep flag holds here too: `teamctl prune` is the automatic sweep asked for
    # by hand, and a lane worth protecting from one is worth protecting from the other.
    # `teamctl remove <role>` is still how a protected lane goes, as it always was.
    if disk_keep_build "$role"; then
      rest="$(disk_kb "$path")"
      PRUNE_FLOOR=$((PRUNE_FLOOR + rest))
      printf '%s%-18s %9s   kept: teamctl keep protects this lane%s\n' "$indent" "$role" "$(human_size "$rest")" "$rnote"
      PRUNE_SKIPPED=$((PRUNE_SKIPPED + 1))
      continue
    fi
    if ! disk_clean_role "$role" "$kind" "$apply"; then
      # The size is printed here too, because this is what one stray file is pinning.
      rest="$(disk_kb "$path")"
      PRUNE_FLOOR=$((PRUNE_FLOOR + rest))
      printf '%s%-18s %9s   skipped: %s%s\n' "$indent" "$role" "$(human_size "$rest")" "$DISK_SKIP_REASON" "$rnote"
      PRUNE_SKIPPED=$((PRUNE_SKIPPED + 1))
      continue
    fi
    PRUNE_TOTAL=$((PRUNE_TOTAL + DISK_FREED_KB))
    # What is left of a lane prune did sweep is tracked files, mostly: rule 2 means prune
    # can never take those, so it says how much there is instead of looking finished.
    rest="$(disk_kb "$path")"
    if [ "$apply" -eq 0 ]; then rest=$((rest - DISK_FREED_KB)); fi
    [ "$rest" -ge 0 ] || rest=0
    PRUNE_FLOOR=$((PRUNE_FLOOR + rest))
    if [ -z "$DISK_CLEANED" ]; then
      printf '%s%-18s %9s   nothing to take%s\n' "$indent" "$role" "0 KB" "$rnote"
    else
      PRUNE_CLEANED=$((PRUNE_CLEANED + 1))
      printf '%s%-18s %9s   %s%s\n' "$indent" "$role" "$(human_size "$DISK_FREED_KB")" "$DISK_CLEANED" "$rnote"
      [ "$apply" -eq 0 ] || disk_reclaim_log "$role" "$DISK_FREED_KB" prune "$DISK_CLEANED"
    fi
  done
  # The lanes this emptied were parked, which is the one thing prune sweeps, so the parked
  # number the status bar shows can be corrected exactly instead of measured again.
  if [ "$apply" -eq 1 ]; then
    event_log prune "" "kind=$kind freed_kb=$PRUNE_TOTAL lanes=$PRUNE_CLEANED"
    disk_cache_adjust "$PRUNE_TOTAL"
    disk_parked_adjust "$PRUNE_TOTAL"
  fi
}

# prune_footer <dry> <hint> <label> <scope> <total> <floor> <cleaned> <running> <skipped> —
# the lines under one team's lanes, and under the machine's when every team was swept. The
# label and the scope are the only difference between the two ("total … in 3 parked lanes"
# against "machine total … in 41 parked lanes across 21 teams in 7 projects"), so the
# numbers underneath cannot be worded two ways.
prune_footer() {
  local dry="$1" hint="$2" label="$3" scope="$4" total="$5" floor="$6" cleaned="$7" running="$8" skipped="$9"
  say ""
  if [ "$dry" -eq 1 ]; then
    printf '  %-18s %9s   is what this would free in %s parked lane%s%s (%s running, %s skipped)\n' \
      "$label" "$(human_size "$total")" "$cleaned" "$([ "$cleaned" = "1" ] || printf s)" "$scope" "$running" "$skipped"
    say "  take it: teamctl prune$hint"
  else
    printf '  %-18s %9s   freed from %s parked lane%s%s (%s running, %s skipped)\n' \
      "$label" "$(human_size "$total")" "$cleaned" "$([ "$cleaned" = "1" ] || printf s)" "$scope" "$running" "$skipped"
    say "  $(disk_free_label) free on this disk now."
  fi
  # Measured on this machine: of 25 GB in 38 lane worktrees only about 4 GB was on the
  # allowlist. The rest is the checkout itself (one project copies 530 MB of public/ into
  # every lane), and only taking the lane off the books gives that back.
  if [ "$floor" -gt 0 ]; then
    printf '  %-18s %9s   is still in these lanes: files git tracks, plus every lane above that was skipped or left running.\n' \
      "still held" "$(human_size "$floor")"
    say "  What git tracks comes back only with teamctl remove <role>$hint. A skipped lane keeps its node_modules as well; a running one is swept once it is parked."
  fi
  if [ "$skipped" -gt 0 ]; then
    say "  A skipped lane holds something that is not build output. Look: teamctl diff <role> --working · let it go: teamctl remove <role>"
  fi
}

cmd_prune() {
  local dry=0 kind="all" apply=1 all_teams=0 hint="" doubt=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      --keep-node-modules) kind="caches" ;;
      --all-teams) all_teams=1 ;;
      *) die_usage "usage: teamctl prune [--team <name>] [--all-teams] [--dry-run] [--keep-node-modules]" ;;
    esac
    shift
  done
  if [ "$dry" -eq 1 ]; then apply=0; fi
  require_tools
  if [ "$all_teams" -eq 1 ]; then
    prune_all_teams "$kind" "$apply" "$dry"
    return 0
  fi
  load_project
  [ "$dry" -eq 1 ] || require_manager prune
  SESSION="$(session_name_for_project)"
  if [ "$TEAM" != "$WOLFMUX_DEFAULT_TEAM" ]; then hint=" --team $TEAM"; fi
  if [ "$apply" -eq 1 ]; then
    ensure_state_dirs
    lock_acquire
  fi
  if [ "$dry" -eq 1 ]; then
    say "prune team '$TEAM' of $(short_path "$ROOT")   ·   DRY RUN: nothing is deleted"
  else
    say "prune team '$TEAM' of $(short_path "$ROOT")"
  fi
  say "  takes: $(disk_names "$kind" | tr '\n' ' ') ·  keeps: every source file, every commit, git state"
  say ""
  doubt="$(prune_team_doubt)"
  if [ -n "$doubt" ]; then
    [ "$apply" -eq 0 ] || lock_release
    die "$doubt. Nothing was touched. Look: teamctl status · teamctl panes. Then park it for real (teamctl stop <role>$hint) or bring it back (teamctl restart <role>$hint) and run prune again."
  fi
  prune_team "$kind" "$apply"
  prune_footer "$dry" "$hint" total "" "$PRUNE_TOTAL" "$PRUNE_FLOOR" "$PRUNE_CLEANED" "$PRUNE_RUNNING" "$PRUNE_SKIPPED"
  [ "$apply" -eq 0 ] || lock_release
}

# --- teamctl prune --all-teams [--dry-run] [--keep-node-modules] ---------------------
# Every team of every project on this machine, in one command, and YOURS alone to run.
#
# A lead may not: exit 77. That is not a courtesy — `teamctl prune` is refused across team
# boundaries by rule 4 of this file (a lane of another team is that team's to clean), and a
# lead that could sweep the machine would be managing teams nobody made it manager of.
# is_manager cannot express this, because it says 0 for the lead of the team it is standing
# in as well as for you; require_operator (lib/policy.sh) asks the one question that can.
#
# Why it exists: you work from a plain terminal with no TEAM_ROLE, and until now there was
# no way to see what the whole machine was hoarding — `teamctl prune --dry-run` answers for
# one team and `teamctl teams` for one project. 21 teams across several projects is 21
# commands and no total.
#
# A team whose lanes cannot all be placed is reported and skipped WHOLE, and the run goes on.
# The one-team form still dies instead, and that difference is deliberate: there, the doubt
# is about the lanes you asked about, and stopping is the answer; here, one unplaceable team
# must not leave the other twenty unswept, and skipping it touches nothing of it.
prune_all_teams() {
  local kind="$1" apply="$2" dry="$3" key team rc doubt
  local total=0 floor=0 cleaned=0 running=0 skipped=0 teams=0 projects=0 held=""
  require_operator "prune --all-teams" "every team of every project on this machine" \
    "teamctl prune for your own team (no --all-teams), and teamctl prune --dry-run for a look at it"
  if [ "$dry" -eq 1 ]; then
    say "prune EVERY team on this machine   ·   DRY RUN: nothing is deleted"
  else
    say "prune EVERY team on this machine"
  fi
  say "  takes: $(disk_names "$kind" | tr '\n' ' ') ·  keeps: every source file, every commit, git state"
  for key in $(dash_projects); do
    rc=0
    # dash_project_load is the dashboard's loader, and loading is all it does: it points
    # ROOT / PROJECT_STATE / PROJECT_TREES at a project read out of its meta.json. Reused
    # rather than written again here, so there is one reader of that file and not two.
    dash_project_load "$key" || rc=$?
    if [ "$rc" -ne 0 ]; then
      say ""
      say "PROJECT $key   skipped: its state could not be read"
      continue
    fi
    projects=$((projects + 1))
    say ""
    say "PROJECT $key   $(short_path "$ROOT")"
    for team in $(team_list); do
      team_paths "$team"
      SESSION="$(session_name_for_project)"
      teams=$((teams + 1))
      say "  TEAM $team"
      doubt="$(prune_team_doubt)"
      if [ -n "$doubt" ]; then
        held="$held $key/$team"
        printf '    %s\n' "$doubt — this team was skipped whole and nothing of it was touched"
        continue
      fi
      if [ "$apply" -eq 1 ]; then
        ensure_state_dirs
        lock_acquire
      fi
      prune_team "$kind" "$apply" "    "
      [ "$apply" -eq 0 ] || lock_release
      printf '    %-16s %9s   %s in this team (%s parked lane%s swept, %s running, %s skipped)\n' \
        "team total" "$(human_size "$PRUNE_TOTAL")" \
        "$([ "$dry" -eq 1 ] && printf 'would be freed' || printf freed)" \
        "$PRUNE_CLEANED" "$([ "$PRUNE_CLEANED" = "1" ] || printf s)" "$PRUNE_RUNNING" "$PRUNE_SKIPPED"
      total=$((total + PRUNE_TOTAL))
      floor=$((floor + PRUNE_FLOOR))
      cleaned=$((cleaned + PRUNE_CLEANED))
      running=$((running + PRUNE_RUNNING))
      skipped=$((skipped + PRUNE_SKIPPED))
    done
  done
  prune_footer "$dry" " --all-teams" "machine total" \
    " across $teams team$([ "$teams" = "1" ] || printf s) in $projects project$([ "$projects" = "1" ] || printf s)" \
    "$total" "$floor" "$cleaned" "$running" "$skipped"
  if [ -n "$held" ]; then
    say "  Teams skipped whole, because a lane of theirs could not be placed:$held"
  fi
}
