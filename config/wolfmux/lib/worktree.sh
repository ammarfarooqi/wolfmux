#!/bin/bash
# worktree.sh — git worktrees and branches for workers, plus read-only inspection.
#
# Every worker gets its own branch (ai/<role>-<stamp>) in its own worktree under
# ~/.wolfmux/worktrees/<project>/, outside the repository, so no two agents can
# edit the same working tree and nothing is nested inside your project.

gitr() { "$GIT_BIN" -C "$ROOT" "$@"; }

wt_require_commit() {
  gitr rev-parse --verify -q 'HEAD^{commit}' >/dev/null ||
    die "this repository has no commits yet; make an initial commit first (worktrees need one)."
}

# wt_create <role> <stamp> <base-commit> — prints the worktree path
# wt_branch_name <role> <stamp> — ai/<role>-<stamp>, or ai/<team>/<role>-<stamp> in a named team
wt_branch_name() {
  if [ "$TEAM" = "$WOLFMUX_DEFAULT_TEAM" ]; then printf 'ai/%s-%s\n' "$1" "$2"; else printf 'ai/%s/%s-%s\n' "$TEAM" "$1" "$2"; fi
}

wt_create() {
  local role="$1" stamp="$2" base="$3" branch path
  branch="$(wt_branch_name "$role" "$stamp")"
  path="$WORKTREES_DIR/$role-$stamp"
  [ ! -e "$path" ] || die "worktree path already exists: $path"
  gitr worktree add -q -b "$branch" "$path" "$base" >&2 || die "git worktree add failed for $role"
  printf '%s\n' "$path"
}

# wt_discard_new <path> <branch> — undo wt_create when the pane could not be created.
# Only ever called for a worktree made seconds ago in the same command.
wt_discard_new() {
  gitr worktree remove --force "$1" >/dev/null 2>&1 || true
  gitr branch -D "$2" >/dev/null 2>&1 || true
}

# wt_dirty_count <path> — uncommitted + untracked entries
wt_dirty_count() {
  local changes=""
  if [ -d "$1" ]; then
    changes="$("$GIT_BIN" -C "$1" status --porcelain 2>/dev/null || true)"
  fi
  if [ -z "$changes" ]; then
    printf '0\n'
  else
    printf '%s\n' "$changes" | wc -l | tr -d ' '
  fi
}

# wt_ahead <base-commit> <branch> — commits on the branch that the base lacks
wt_ahead() {
  gitr rev-list --count "$1..$2" 2>/dev/null || printf '?\n'
}

wt_branch_exists() { gitr show-ref --verify -q "refs/heads/$1"; }

# wt_remove_if_clean <path> — 0 removed, 1 kept (dirty), 2 already absent
wt_remove_if_clean() {
  local path="$1"
  [ -d "$path" ] || return 2
  [ "$(wt_dirty_count "$path")" = "0" ] || return 1
  gitr worktree remove "$path" >/dev/null 2>&1 || return 1
  return 0
}

# wt_delete_branch_if_merged <branch> — git's own safety check (-d, never -D)
wt_delete_branch_if_merged() {
  gitr branch -d "$1" >/dev/null 2>&1
}

cmd_worktrees() {
  local role kind path branch base ahead dirty present
  require_tools
  load_project
  printf '%-14s %-32s %-7s %-7s %s\n' "ROLE" "BRANCH" "AHEAD" "DIRTY" "WORKTREE"
  for role in $(reg_list); do
    reg_exists "$role" || continue
    kind="$(reg_field "$role" kind)"
    path="$(reg_field "$role" workdir)"
    if [ "$kind" = "lead" ]; then
      branch="$(gitr symbolic-ref --short -q HEAD || printf '(detached)')"
      printf '%-14s %-32s %-7s %-7s %s\n' "$role" "$branch" "-" "$(wt_dirty_count "$ROOT")" "$(short_path "$ROOT") (main checkout)"
      continue
    fi
    branch="$(reg_field "$role" branch)"
    base="$(reg_field "$role" base_commit)"
    ahead="$(wt_ahead "$base" "$branch")"
    if [ -d "$path" ]; then
      dirty="$(wt_dirty_count "$path")"
      present="$(short_path "$path")"
    else
      dirty="-"
      present="$(short_path "$path") (removed)"
    fi
    printf '%-14s %-32s %-7s %-7s %s\n' "$role" "$branch" "$ahead" "$dirty" "$present"
  done
  say ""
  say "git worktree list:"
  gitr worktree list | sed 's/^/  /'
}

# teamctl diff <role> [--stat|--names|--commits|--working]
cmd_diff() {
  local role="${1:-}" mode="full" branch base path pager=()
  require_role_arg "$role"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --stat) mode="stat" ;;
      --names | --name-only | --name-status) mode="names" ;;
      --commits | --log) mode="commits" ;;
      --working | --uncommitted) mode="working" ;;
      *) die_usage "usage: teamctl diff <role> [--stat|--names|--commits|--working]" ;;
    esac
    shift
  done
  require_tools
  load_project
  reg_exists "$role" || die "no such agent: $role  (see: teamctl status)"
  [ "$(reg_field "$role" kind)" = "worker" ] || die "'$role' works in the main checkout; use plain git there."
  branch="$(reg_field "$role" branch)"
  base="$(reg_field "$role" base_commit)"
  path="$(reg_field "$role" workdir)"
  wt_branch_exists "$branch" || die "branch $branch no longer exists"
  [ -t 1 ] || pager=(--no-pager)

  case "$mode" in
    commits) gitr ${pager[@]+"${pager[@]}"} log --no-decorate --format='%h %ad %s' --date=short "$base..$branch" ;;
    stat) gitr ${pager[@]+"${pager[@]}"} diff --stat "$base...$branch" ;;
    names) gitr ${pager[@]+"${pager[@]}"} diff --name-status "$base...$branch" ;;
    working)
      [ -d "$path" ] || die "worktree is gone: $path"
      "$GIT_BIN" -C "$path" status --short
      "$GIT_BIN" -C "$path" ${pager[@]+"${pager[@]}"} diff HEAD
      ;;
    full)
      say "# role:    $role"
      say "# branch:  $branch"
      say "# base:    $(reg_field "$role" base_ref) @ $(printf '%s' "$base" | cut -c1-12)"
      say "# commits: $(wt_ahead "$base" "$branch") ahead of base, uncommitted entries in worktree: $(wt_dirty_count "$path")"
      say "#"
      gitr --no-pager log --no-decorate --format='# %h %ad %s' --date=short "$base..$branch"
      say ""
      gitr ${pager[@]+"${pager[@]}"} diff --stat --patch "$base...$branch"
      ;;
  esac
}
