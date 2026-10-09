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

# The default disk-min-gb: a lane costs about 3 GB of node_modules and build output, so
# 20 GB is seven more lanes' worth of room, and macOS wants several gigabytes of its own
# for swap, updates and Spotlight. Low enough not to nag, high enough that the guard
# trips while there is still time to run `teamctl prune`.
WOLFMUX_DISK_MIN_GB_DEFAULT=20

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

# disk_confined <path> — a lane worktree of THIS team's worktree directory, and not the
# directory itself. Rule 4: the only answer that lets anything be deleted.
disk_confined() {
  local real base
  real="$(disk_real "$1")"
  base="$(disk_real "${WORKTREES_DIR:-}")"
  [ -n "$real" ] && [ -n "$base" ] || return 1
  [ "$real" != "$base" ] || return 1
  [ "$real" != "$(disk_real "$ROOT")" ] || return 1 # your own checkout, never
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
  local path="$1" status line entry first
  DISK_SKIP_REASON=""
  if [ ! -d "$path" ]; then
    DISK_SKIP_REASON="its worktree is gone"
    return 1
  fi
  if ! disk_confined "$path"; then
    DISK_SKIP_REASON="it is not a lane of team '${TEAM:-?}' under $(short_path "${WORKTREES_DIR:-(no worktree directory resolved)}")"
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
  local path="$1" kind="$2" apply="$3" real name target trash kb leftover
  DISK_FREED_KB=0
  DISK_CLEANED=""
  disk_cleanable "$path" || return 1
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

# disk_clean_role <role> <all|caches> <apply 0|1> — the same for an agent on record.
# The lead works in your own checkout and nothing of its is ever deleted.
disk_clean_role() {
  local role="$1"
  DISK_FREED_KB=0
  DISK_CLEANED=""
  DISK_SKIP_REASON=""
  if [ "$(reg_field "$role" kind)" != "worker" ]; then
    DISK_SKIP_REASON="it works in your own checkout"
    return 1
  fi
  disk_clean_worktree "$(reg_field "$role" workdir)" "$2" "$3"
}

# --- what a team's lanes take, without making `teamctl status` slow ------------------
# du over one lane's node_modules walks tens of thousands of files: one real one here is
# 69,336 files and 802 MB, and a warm `du -sk` of it takes 0.62 s. Over the 36 lane
# worktrees on this machine that is 12.4 s. `teamctl status` runs every few minutes, so it
# never measures: the commands that change the lanes anyway (stop, remove, prune, destroy,
# and `teamctl teams`, which does measure) leave the number behind and status reads it.
WOLFMUX_DISK_CACHE_SECONDS=900

disk_cache_file() { printf '%s/disk-kb\n' "$STATE_DIR"; }

# disk_team_kb_measure — du over this team's lane worktrees; remembers the number
disk_team_kb_measure() {
  local role kb=0
  for role in $(reg_list); do
    if [ "$(reg_field "$role" kind)" = "worker" ]; then kb=$((kb + $(disk_kb "$(reg_field "$role" workdir)"))); fi
  done
  if [ -d "$STATE_DIR" ]; then printf '%s %s\n' "$(now_epoch)" "$kb" >"$(disk_cache_file)" 2>/dev/null || true; fi
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
  case "${stamp:-x}${kb:-x}" in *[!0-9]*) return 0 ;; esac
  # Both ends: a stamp in the future (a clock that went back, a garbled write) would
  # otherwise stay "fresh" for ever and pin status to a number nobody can correct.
  [ "$stamp" -le "$(now_epoch)" ] || return 0
  [ $(($(now_epoch) - stamp)) -le "$WOLFMUX_DISK_CACHE_SECONDS" ] || return 0
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
# disk_link_node_modules <worktree> — the lane shares the project's installed
# dependencies instead of installing 2.3 GB of its own. Off by default and for a reason:
# it is ONE directory for every lane and for your own checkout, so an `npm install` in
# any lane changes the dependencies of all of them, and two lanes that need different
# versions of a package cannot both be right. Only a real directory in the project root
# is linked; a root without one is left alone.
disk_link_node_modules() {
  local path="$1"
  [ -d "$ROOT/node_modules" ] && [ ! -L "$ROOT/node_modules" ] || return 1
  [ ! -e "$path/node_modules" ] && [ ! -L "$path/node_modules" ] || return 1
  /bin/ln -s "$ROOT/node_modules" "$path/node_modules" 2>/dev/null || return 1
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

# --- teamctl prune [--dry-run] [--keep-node-modules] ---------------------------------
# Every PARKED lane of this team. A parked lane is what actually hoards: it keeps its
# whole node_modules and .next for as long as nobody removes the role, and a lane is
# parked for days. A running lane is never touched. --dry-run reports and deletes
# nothing, and needs no manager: looking is not changing.
cmd_prune() {
  local dry=0 kind="all" apply=1 role path rest total=0 floor=0 cleaned=0 skipped=0 running=0 hint=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      --keep-node-modules) kind="caches" ;;
      *) die_usage "usage: teamctl prune [--team <name>] [--dry-run] [--keep-node-modules]" ;;
    esac
    shift
  done
  if [ "$dry" -eq 1 ]; then apply=0; fi
  require_tools
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
  # A doubtful lane stops the whole sweep before anything is deleted: one wrong "parked"
  # costs a running build its dependencies, and prune is the command nobody is watching.
  for role in $(reg_list); do
    [ "$(reg_field "$role" kind)" = "worker" ] || continue
    if disk_lane_running "$role" && [ -n "$DISK_LANE_DOUBT" ]; then
      [ "$apply" -eq 0 ] || lock_release
      die "cannot tell whether '$role' is running: $DISK_LANE_DOUBT. Nothing was touched. Look: teamctl status · teamctl panes. Then park it for real (teamctl stop $role$hint) or bring it back (teamctl restart $role$hint) and run prune again."
    fi
  done
  for role in $(reg_list); do
    [ "$(reg_field "$role" kind)" = "worker" ] || continue
    path="$(reg_field "$role" workdir)"
    if disk_lane_running "$role"; then
      printf '  %-18s %9s   running, left alone\n' "$role" "-"
      running=$((running + 1))
      continue
    fi
    if ! disk_clean_worktree "$path" "$kind" "$apply"; then
      # The size is printed even here, because this is what one stray file is pinning.
      printf '  %-18s %9s   skipped: %s\n' "$role" "$(human_size "$(disk_kb "$path")")" "$DISK_SKIP_REASON"
      skipped=$((skipped + 1))
      continue
    fi
    total=$((total + DISK_FREED_KB))
    # What is left after the sweep is the floor: tracked files, mostly. prune can never
    # take those (rule 2), so it says how much of it there is instead of looking finished.
    rest="$(disk_kb "$path")"
    if [ "$apply" -eq 0 ]; then rest=$((rest - DISK_FREED_KB)); fi
    [ "$rest" -ge 0 ] || rest=0
    floor=$((floor + rest))
    if [ -z "$DISK_CLEANED" ]; then
      printf '  %-18s %9s   nothing to take\n' "$role" "0 KB"
    else
      cleaned=$((cleaned + 1))
      printf '  %-18s %9s   %s\n' "$role" "$(human_size "$DISK_FREED_KB")" "$DISK_CLEANED"
    fi
  done
  say ""
  if [ "$dry" -eq 1 ]; then
    printf '  %-18s %9s   is what this would free in %s parked lane%s (%s running, %s skipped)\n' \
      "total" "$(human_size "$total")" "$cleaned" "$([ "$cleaned" = "1" ] || printf s)" "$running" "$skipped"
    say "  take it: teamctl prune$hint"
  else
    printf '  %-18s %9s   freed from %s parked lane%s (%s running, %s skipped)\n' \
      "total" "$(human_size "$total")" "$cleaned" "$([ "$cleaned" = "1" ] || printf s)" "$running" "$skipped"
    say "  $(disk_free_label) free on this disk now."
    event_log prune "" "kind=$kind freed_kb=$total lanes=$cleaned"
    disk_cache_adjust "$total"
    lock_release
  fi
  # Measured on this machine: of 25 GB in 38 lane worktrees only about 4 GB was on the
  # allowlist. The rest is the checkout itself (one project copies 530 MB of public/ into
  # every lane), and only taking the lane off the books gives that back.
  if [ "$floor" -gt 0 ]; then
    printf '  %-18s %9s   is in files git tracks: prune can never take those. Only teamctl remove <role>%s does.\n' \
      "still held" "$(human_size "$floor")" "$hint"
  fi
  if [ "$skipped" -gt 0 ]; then
    say "  A skipped lane holds something that is not build output. Look: teamctl diff <role> --working · let it go: teamctl remove <role>"
  fi
}
