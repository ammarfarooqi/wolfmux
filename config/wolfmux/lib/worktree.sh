#!/bin/bash
# worktree.sh — git worktrees and branches for workers, plus read-only inspection.
#
# Every worker gets its own branch in its own worktree under ~/.wolfmux/worktrees/,
# outside the repository, so no two agents can edit the same working tree and nothing
# is nested inside your project.
#
# The branch NAME comes from a template, because a repository may enforce a shape (a
# ticket key, a prefix) and a worker that cannot satisfy it commits with the project's
# skip switch instead. The default template is the shape wolfmux has always produced.
#
# Every git command about a worker goes through git_for_role, which reads that worker's
# record for the repository its worktree belongs to. Today that is always this project.

gitr() { "$GIT_BIN" -C "$ROOT" "$@"; }

# git_in <repo> <git argument>... — git in a repository named by path
git_in() {
  local repo="$1"
  shift
  "$GIT_BIN" -C "$repo" "$@"
}

# worker_repo <role> — the repository this worker's worktree and branch live in.
# An empty 'repo' field means this project.
worker_repo() {
  local repo
  repo="$(reg_field "$1" repo 2>/dev/null || true)"
  if [ -n "$repo" ]; then printf '%s\n' "$repo"; else printf '%s\n' "$ROOT"; fi
}

# git_for_role <role> <git argument>... — git in that worker's repository. When the
# record names a repository that is gone, git fails here and nothing is deleted.
git_for_role() {
  local role="$1"
  shift
  "$GIT_BIN" -C "$(worker_repo "$role")" "$@"
}

# worker_trees_dir <role> — the directory this worker's worktree must lie in.
worker_trees_dir() {
  local repo
  repo="$(reg_field "$1" repo 2>/dev/null || true)"
  if [ -z "$repo" ]; then
    printf '%s\n' "$WORKTREES_DIR"
  else
    printf '%s/worktrees/%s/teams/%s\n' "$WOLFMUX_DATA" "$(project_key "$repo")" "$TEAM"
  fi
}

wt_require_commit() {
  git_in "$1" rev-parse --verify -q 'HEAD^{commit}' >/dev/null ||
    die "$(short_path "$1") has no commits yet; make an initial commit first (worktrees need one)."
}

# --- branch names ---------------------------------------------------------------
# A template with the placeholders below. {ts} is the timestamp that keeps two workers
# of the same role apart, so a template without it is refused: a repeated branch name
# would collide with a branch that already holds somebody's work.
WOLFMUX_BRANCH_PLACEHOLDERS="team role ts ticket"

# wt_default_template — the shape wolfmux has always produced, per kind of team
wt_default_template() {
  if [ "$TEAM" = "$WOLFMUX_DEFAULT_TEAM" ]; then printf 'ai/{role}-{ts}\n'; else printf 'ai/{team}/{role}-{ts}\n'; fi
}

# branch_template_error <template> — why it cannot be used; empty when it can
branch_template_error() {
  local template="$1" rest name
  if [ -z "$template" ]; then
    printf 'the template is empty (for the built-in shape: teamctl policy branch-template default)\n'
    return 0
  fi
  if [ "${#template}" -gt 200 ]; then
    printf 'the template is %s characters, max 200\n' "${#template}"
    return 0
  fi
  rest="$template"
  while [ -n "$rest" ]; do
    case "$rest" in *"{"*) ;; *) break ;; esac
    rest="${rest#*\{}"
    case "$rest" in
      *"}"*) ;;
      *)
        printf "a '{' is never closed\n"
        return 0
        ;;
    esac
    name="${rest%%\}*}"
    case " $WOLFMUX_BRANCH_PLACEHOLDERS " in
      *" $name "*) ;;
      *)
        printf 'unknown placeholder {%s} (known: {team} {role} {ts} {ticket})\n' "$name"
        return 0
        ;;
    esac
    rest="${rest#*\}}"
  done
  case "$template" in
    *"{ts}"*) ;;
    *)
      printf 'every template needs {ts}: it is what keeps two workers of the same role on two branches\n'
      return 0
      ;;
  esac
  printf ''
}

branch_template_valid() { [ -z "$(branch_template_error "$1")" ]; }

# wt_branch_name <role> <stamp> <ticket> — the branch a spawn creates, from the team's
# template. A template that asks for a ticket and a spawn that has none is a usage error:
# guessing a name here is what the whole setting exists to prevent.
wt_branch_name() {
  local role="$1" stamp="$2" ticket="$3" template name
  template="$(policy_get branch-template)"
  [ -n "$template" ] || template="$(wt_default_template)"
  case "$template" in
    *"{ticket}"*)
      [ -n "$ticket" ] ||
        die_usage "the branch template of team '$TEAM' is '$template', so this spawn needs a ticket key: teamctl spawn $role <model> --ticket <KEY>   (a default for the whole team: teamctl start <model> --ticket <KEY>)"
      ;;
  esac
  name="$template"
  name="${name//\{team\}/$TEAM}"
  name="${name//\{role\}/$role}"
  name="${name//\{ts\}/$stamp}"
  name="${name//\{ticket\}/$ticket}"
  printf '%s\n' "$name"
}

# wt_require_branch_name <repo> <name> — git's own rules decide what a branch may be called
wt_require_branch_name() {
  case "$2" in
    -*) die_usage "'$2' is not a branch name: it starts with '-'" ;;
  esac
  git_in "$1" check-ref-format --branch "$2" >/dev/null 2>&1 ||
    die_usage "'$2' is not a branch name git accepts (it is what 'git check-ref-format --branch' refuses)"
}

# wt_create <repo> <path> <branch> <base-commit> — prints the worktree path
wt_create() {
  local repo="$1" path="$2" branch="$3" base="$4"
  [ ! -e "$path" ] || die "worktree path already exists: $path"
  git_in "$repo" worktree add -q -b "$branch" "$path" "$base" >&2 || die "git worktree add failed in $(short_path "$repo") for branch $branch"
  printf '%s\n' "$path"
}

# wt_discard_new <repo> <path> <branch> — undo wt_create when the pane could not be created.
# Only ever called for a worktree made seconds ago in the same command.
wt_discard_new() {
  git_in "$1" worktree remove --force "$2" >/dev/null 2>&1 || true
  git_in "$1" branch -D "$3" >/dev/null 2>&1 || true
}

# branch_is_ours <role> — may teamctl delete this worker's branch? Only a branch teamctl
# created is ever deleted, whatever it is called. A record written before the field existed
# has none: teamctl only ever created ai/… branches then, and only deleted those, so that
# shape still counts as ours and older teams keep working.
branch_is_ours() {
  local branch created
  branch="$(reg_field "$1" branch 2>/dev/null || true)"
  [ -n "$branch" ] || return 1
  created="$(reg_field "$1" branch_created 2>/dev/null || true)"
  case "$created" in
    1) return 0 ;;
    "") case "$branch" in ai/*) return 0 ;; esac ;;
  esac
  return 1
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

# wt_ahead <role> <base-commit> <branch> — commits on the branch that the base lacks
wt_ahead() {
  git_for_role "$1" rev-list --count "$2..$3" 2>/dev/null || printf '?\n'
}

# wt_branch_exists <role> <branch> — in that worker's own repository
wt_branch_exists() { git_for_role "$1" show-ref --verify -q "refs/heads/$2"; }

# wt_branch_exists_in <repo> <branch>
wt_branch_exists_in() { git_in "$1" show-ref --verify -q "refs/heads/$2"; }

# wt_remove_if_clean <role> <path> — 0 removed, 1 kept (dirty), 2 already absent
wt_remove_if_clean() {
  local role="$1" path="$2"
  [ -d "$path" ] || return 2
  [ "$(wt_dirty_count "$path")" = "0" ] || return 1
  git_for_role "$role" worktree remove "$path" >/dev/null 2>&1 || return 1
  return 0
}

# wt_delete_branch_if_merged <role> <branch> — git's own safety check (-d, never -D),
# and only for a branch teamctl created
wt_delete_branch_if_merged() {
  branch_is_ours "$1" || return 1
  git_for_role "$1" branch -d "$2" >/dev/null 2>&1
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
    ahead="$(wt_ahead "$role" "$base" "$branch")"
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
  wt_branch_exists "$role" "$branch" || die "branch $branch no longer exists in $(short_path "$(worker_repo "$role")")"
  [ -t 1 ] || pager=(--no-pager)

  case "$mode" in
    commits) git_for_role "$role" ${pager[@]+"${pager[@]}"} log --no-decorate --format='%h %ad %s' --date=short "$base..$branch" ;;
    stat) git_for_role "$role" ${pager[@]+"${pager[@]}"} diff --stat "$base...$branch" ;;
    names) git_for_role "$role" ${pager[@]+"${pager[@]}"} diff --name-status "$base...$branch" ;;
    working)
      [ -d "$path" ] || die "worktree is gone: $path"
      "$GIT_BIN" -C "$path" status --short
      "$GIT_BIN" -C "$path" ${pager[@]+"${pager[@]}"} diff HEAD
      ;;
    full)
      say "# role:    $role"
      say "# branch:  $branch"
      say "# base:    $(reg_field "$role" base_ref) @ $(printf '%s' "$base" | cut -c1-12)"
      say "# commits: $(wt_ahead "$role" "$base" "$branch") ahead of base, uncommitted entries in worktree: $(wt_dirty_count "$path")"
      say "#"
      git_for_role "$role" --no-pager log --no-decorate --format='# %h %ad %s' --date=short "$base..$branch"
      say ""
      git_for_role "$role" ${pager[@]+"${pager[@]}"} diff --stat --patch "$base...$branch"
      ;;
  esac
}
