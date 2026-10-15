#!/bin/bash
# reclaim.sh — a finished lane takes itself off the books: worktree, branch and record.
#
# lib/disk.sh takes back what a build makes again. The bigger half of a lane is the checkout
# itself — 33.3 GB of the 52.6 GB left under ~/.wolfmux/worktrees after a full sweep, measured
# 2026-10-13 — and only `teamctl remove <role>` gave that back: by hand, one lane at a time,
# which nobody did. This file does it by itself. It is the one place in teamctl that deletes
# a worktree and a branch without having been asked about that lane, so it is built the other
# way round from a cleanup: a lane goes only when EVERY gate below says yes, and a gate that
# cannot be answered says no. A lane kept for nothing costs disk and says so; a lane removed
# wrongly costs work.
#
#   1  it is parked. A running lane, or one whose state cannot be told, is never asked more
#   2  `teamctl keep` does not protect it
#   3  nothing in it is uncommitted: no change to a tracked file, and no untracked file that
#      is not build output (the question `teamctl remove` asks: disk_work_dirty_list)
#   4  the worktree's HEAD is the tip of the lane's branch. A detached HEAD, or another branch
#      checked out there, holds commits that are dangling the moment the worktree goes — that
#      is how three commits were lost on 2026-10-13 and found again only with git fsck
#   5  the branch's CONTENT is in main or in the team's integration branch (reclaim_content)
#   6  no stash entry was made on the lane's branch (reclaim_stash)
#   7  Beads says its work is done: no task of its own that is not closed, and at least one
#      that is. A lane with no task has no answer to "is it finished", so it stays
#   8  GitHub says no pull request is open on its branch. No gh, a gh that fails, a gh that
#      does not answer in time: the lane stays. Deleting a worktree under a reviewer is a
#      failure this project has already paid for once
#
# The order is cheapest first and the network last: Beads and GitHub are only asked about a
# lane that every local gate has already let through.
#
# What the removal itself never does: pass --force to git, fall back to rm -rf, delete a
# branch teamctl did not create, or delete anything before the branch's full sha is on the
# screen and in ~/.wolfmux/state/reclaimed.jsonl. A sha in the record is the difference
# between `git branch <name> <sha>` and an evening with `git fsck --lost-found`.
#
# What a lane that stays is NOT: invisible. `teamctl status` shows it as
# "holding <size>: <reason>", from what the last check wrote into the lane's record
# (hold_why, hold_kb, hold_at). Status itself asks nothing: not du, not Beads, not GitHub.

GH_BIN="$(find_tool gh /opt/homebrew/bin/gh /usr/local/bin/gh || true)"

# How long Beads and GitHub get to answer, in seconds. A question that is not answered in
# time is "cannot tell", and cannot tell means the lane stays.
#
# The number is a measurement, not a taste. On the machine this was written on, 2026-10-14,
# with a load average of 18.8: `bd where` took 18 s, the same `bd list` took 24 s, 33 s, 4 s
# and 4 s in five minutes, and twice that day a bd call hung for over a minute. 20 s — the
# first value here — would have kept every lane on a busy afternoon. 45 s covers the slowest
# answer that was an answer; the hangs are what the limit is for.
RECLAIM_ASK_SECONDS=45

_RECLAIM_NL='
'

# reclaim_short <role> <sha> — the sha as git abbreviates it in that lane's repository
reclaim_short() {
  local short
  short="$(git_for_role "$1" rev-parse --short "$2" 2>/dev/null || true)"
  if [ -n "$short" ]; then printf '%s\n' "$short"; else printf '%.7s\n' "$2"; fi
}

# reclaim_count <n> <singular> <plural> — "1 file", "3 files"
reclaim_count() {
  if [ "$1" = "1" ]; then printf '1 %s\n' "$2"; else printf '%s %s\n' "$1" "$3"; fi
}

# reclaim_ask <seconds> <output file> <directory> <command>... — run something that may hang,
# with a limit. Its stdout goes to a FILE and never to a pipe: a child the command leaves
# behind (a database server, a sleeping helper) keeps a pipe open long after the command
# itself was killed, and reading it would wait for that child. Its stderr goes to
# <output file>.err, for the one line reclaim_said takes out of it. Its status comes back
# as ours; 124 means the limit passed and it was killed.
reclaim_ask() {
  local limit="$1" out="$2" dir="$3" pid rc=0 waited=0
  shift 3
  /bin/rm -f "$out.late"
  (cd "$dir" 2>/dev/null && exec "$@") >"$out" 2>"$out.err" </dev/null &
  pid=$!
  # The watchdog ends by itself within a second of the command ending, so nothing has to
  # find it and kill it afterwards. The mark is written BEFORE the kill: wait returns the
  # moment the command dies, and the mark has to be there by then.
  (
    while [ "$waited" -lt "$limit" ]; do
      sleep 1
      waited=$((waited + 1))
      kill -0 "$pid" 2>/dev/null || exit 0
    done
    : >"$out.late"
    kill -TERM "$pid" 2>/dev/null
    # A tool that ignores TERM would hold `wait` below, and with it `teamctl stop`, for ever.
    sleep 2
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  wait "$pid" 2>/dev/null || rc=$?
  if [ -e "$out.late" ]; then
    /bin/rm -f "$out.late"
    return 124
  fi
  return "$rc"
}

# reclaim_said <output file> — the last line a failed command wrote to stderr, made safe to
# print in a reason: one line, plain characters, at most 100 of them, and no "|" (status
# reads its rows split on that). The LAST line, because a tool's warnings come first and
# what stopped it comes last. Prints ": <that line>", or nothing when it said nothing.
reclaim_said() {
  local line
  line="$(sed -n '/[^[:space:]]/p' "$1.err" 2>/dev/null | sed -n '$p' | tr -d '\000-\037' | tr '|' '/' | cut -c1-100 || true)"
  [ -z "$line" ] || printf ': %s' "$line"
}

# reclaim_scratch_done <output file> — the scratch files of one question
reclaim_scratch_done() { /bin/rm -f "$1" "$1.err" "$1.late"; }

# --- gate 5: is the content in main ---------------------------------------------------
# reclaim_targets <role> <branch> — the refs a lane's content may have gone into, strongest
# first: the remote's copy of the default branch, the local default branch, the branch the
# lane was cut from, and the branch checked out in the lane's repository (where a lead
# integrates). Never the lane's own branch. Only refs that exist are printed.
reclaim_targets() {
  local role="$1" own="refs/heads/$2" name="" candidate base cur ref
  name="$(git_for_role "$role" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  name="${name#origin/}"
  if [ -z "$name" ]; then
    for candidate in main master; do
      if git_for_role "$role" show-ref --verify -q "refs/remotes/origin/$candidate" ||
        git_for_role "$role" show-ref --verify -q "refs/heads/$candidate"; then
        name="$candidate"
        break
      fi
    done
  fi
  base="$(reg_field "$role" base_ref 2>/dev/null || true)"
  cur="$(git_for_role "$role" symbolic-ref -q --short HEAD 2>/dev/null || true)"
  for candidate in "$name" "$base" "$cur"; do
    [ -n "$candidate" ] || continue
    printf 'refs/remotes/origin/%s\nrefs/heads/%s\n' "$candidate" "$candidate"
  done | awk '!seen[$0]++' | while IFS= read -r ref; do
    if [ "$ref" != "$own" ] && git_for_role "$role" show-ref --verify -q "$ref"; then printf '%s\n' "$ref"; fi
  done
}

# reclaim_squashed <role> <branch> <target> <tip> — 0 when the target holds one commit that
# is the whole of the branch. Sets RECLAIM_SQUASH_SHA to that commit.
#
# `git cherry` compares commit by commit, so three commits squashed into one read as three
# commits that are nowhere: measured on git 2.50.1, `git cherry main <branch>` printed three
# "+" lines, and a containment test (`git branch --contains`) says the same. So one throwaway
# commit is built that holds the branch's whole diff — `git commit-tree`, the branch's tree
# on top of the merge base — and git cherry is asked about THAT. It is still git that decides.
#
# The throwaway commit never enters your repository. It is written to a scratch object
# directory (GIT_OBJECT_DIRECTORY) with the repository's own objects as an alternate, so git
# sees both while it is asked and the scratch directory is deleted afterwards. Measured: the
# repository's loose-object count is the same before and after, and `git cat-file` there does
# not know the commit. Without this a check would leave one unreachable commit per lane per
# target in the repository each time it ran — and a check runs every time a lane is parked.
reclaim_squashed() {
  local role="$1" branch="$2" target="$3" tip="$4" repo objects scratch mb syn out="" equal=""
  RECLAIM_SQUASH_SHA=""
  repo="$(worker_repo "$role")"
  mb="$("$GIT_BIN" -C "$repo" merge-base "$target" "$tip" 2>/dev/null || true)"
  [ -n "$mb" ] || return 1
  objects="$("$GIT_BIN" -C "$repo" rev-parse --path-format=absolute --git-path objects 2>/dev/null || true)"
  case "$objects" in /*) ;; *) return 1 ;; esac
  scratch="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/wolfmux-reclaim-objects.XXXXXX" 2>/dev/null || true)"
  [ -n "$scratch" ] || return 1
  syn="$(GIT_OBJECT_DIRECTORY="$scratch" GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects" "$GIT_BIN" -C "$repo" \
    -c user.name=wolfmux -c user.email=wolfmux@localhost commit-tree "$tip^{tree}" -p "$mb" \
    -m "wolfmux: all of $branch as one commit, to ask git cherry about a squash" 2>/dev/null || true)"
  if [ -n "$syn" ]; then
    out="$(GIT_OBJECT_DIRECTORY="$scratch" GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects" "$GIT_BIN" -C "$repo" cherry "$target" "$syn" 2>/dev/null || true)"
    if [ "$out" = "- $syn" ]; then
      equal="$(GIT_OBJECT_DIRECTORY="$scratch" GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects" "$GIT_BIN" -C "$repo" \
        rev-list --left-right --cherry-mark "$target...$syn" 2>/dev/null | sed -n 's/^=//p' | grep -v "^$syn\$" | sed -n 1p || true)"
    fi
  fi
  # Only ever the directory mktemp just made, under the temporary directory.
  case "$scratch" in "${TMPDIR:-/tmp}"/wolfmux-reclaim-objects.*) /bin/rm -rf "$scratch" ;; esac
  [ -n "$syn" ] && [ "$out" = "- $syn" ] || return 1
  RECLAIM_SQUASH_SHA="$equal"
  return 0
}

# reclaim_content <role> <branch> <tip> — 0 when everything on that branch is in one of its
# targets. Sets RECLAIM_PROOF_REF (as a person writes it: origin/main), RECLAIM_PROOF_HOW,
# RECLAIM_PROOF_SHA (the commit that proves it), RECLAIM_PROOF_PUSHED and RECLAIM_CONTENT
# (the sentence). Three ways to be in a target, and git answers each of them:
#
#   merged         the tip is an ancestor of the target. Proof: the target's tip.
#   cherry-picked  `git cherry` finds an equal patch in the target for every commit. Not
#                  asked when the lane holds a merge commit: git cherry skips merges, and a
#                  merge that carries changes of its own would pass unseen.
#   squashed       the whole branch went in as ONE commit (reclaim_squashed, above).
#                  Proof: the commit in the target it is equal to.
#
# The limit of the third, pinned by tests/reclaim.sh: when the target changed a line next to
# one of the branch's hunks before the squash, the two patches differ in their context, their
# patch ids differ, and nothing matches. That lane is KEPT, as "unmerged". It errs toward
# disk, never toward work.
reclaim_content() {
  local role="$1" branch="$2" tip="$3" targets candidate ref="" target merges out label on_remote how="" sha=""
  RECLAIM_PROOF_REF="" RECLAIM_PROOF_HOW="" RECLAIM_PROOF_SHA="" RECLAIM_PROOF_PUSHED=1 RECLAIM_CONTENT=""
  targets="$(reclaim_targets "$role" "$branch")"
  # Three passes over the targets, cheapest question first: a lane that was simply merged is
  # answered by one git command per target, and the squash question — a scratch directory, a
  # commit, two more git commands — is only ever asked about a lane the first two could not
  # place. Within a pass the targets keep their order, the remote's main first.
  for candidate in $targets; do
    target="$(git_for_role "$role" rev-parse -q --verify "$candidate^{commit}" 2>/dev/null || true)"
    [ -n "$target" ] || continue
    if git_for_role "$role" merge-base --is-ancestor "$tip" "$target" 2>/dev/null; then
      how="merged" sha="$target" ref="$candidate"
      break
    fi
  done
  if [ -z "$how" ]; then
    for candidate in $targets; do
      target="$(git_for_role "$role" rev-parse -q --verify "$candidate^{commit}" 2>/dev/null || true)"
      [ -n "$target" ] || continue
      merges="$(git_for_role "$role" rev-list --count --merges "$target..$tip" 2>/dev/null || printf 'unknown')"
      [ "$merges" = "0" ] || continue
      out="$(git_for_role "$role" cherry "$target" "$tip" 2>/dev/null || true)"
      [ -n "$out" ] || continue
      # No pipe into grep here: under pipefail a grep that stops reading early can fail the
      # pipeline, and a failed "is there a + line" must never read as "there is none".
      case "$_RECLAIM_NL$out" in
        *"$_RECLAIM_NL+ "*) ;;
        *)
          how="cherry-picked" sha="$target" ref="$candidate"
          break
          ;;
      esac
    done
  fi
  if [ -z "$how" ]; then
    for candidate in $targets; do
      target="$(git_for_role "$role" rev-parse -q --verify "$candidate^{commit}" 2>/dev/null || true)"
      [ -n "$target" ] || continue
      if reclaim_squashed "$role" "$branch" "$target" "$tip"; then
        how="squashed" sha="${RECLAIM_SQUASH_SHA:-$target}" ref="$candidate"
        break
      fi
    done
  fi
  if [ -z "$how" ]; then
    # Which of the two it is only chooses the word. A branch that is on a remote can be
    # fetched back; one that is not exists on this disk and nowhere else, so when both are
    # true the more dangerous one is the one that is said.
    on_remote="$(git_for_role "$role" for-each-ref --count=1 --format='%(refname)' --contains "$tip" refs/remotes 2>/dev/null || true)"
    if [ -n "$on_remote" ]; then
      RECLAIM_WHY="unmerged at $(reclaim_short "$role" "$tip")"
    else
      RECLAIM_WHY="unpushed at $(reclaim_short "$role" "$tip")"
    fi
    return 1
  fi
  label="${ref#refs/remotes/}"
  label="${label#refs/heads/}"
  case "$ref" in
    refs/remotes/*) ;;
    *)
      # Content that is in a local main only still counts: teamctl never deletes main, so it
      # is not at the risk a lane is. But the record must not imply a safety that is not
      # there, so it says that this main is on no remote.
      on_remote="$(git_for_role "$role" for-each-ref --count=1 --format='%(refname)' --contains "$sha" refs/remotes 2>/dev/null || true)"
      [ -n "$on_remote" ] || RECLAIM_PROOF_PUSHED=0
      ;;
  esac
  RECLAIM_PROOF_REF="$label" RECLAIM_PROOF_HOW="$how" RECLAIM_PROOF_SHA="$sha"
  case "$how" in
    squashed) RECLAIM_CONTENT="squashed as $(reclaim_short "$role" "$sha")" ;;
    *) RECLAIM_CONTENT="$how, at $(reclaim_short "$role" "$sha")" ;;
  esac
  if [ "$RECLAIM_PROOF_PUSHED" -eq 0 ]; then RECLAIM_CONTENT="$RECLAIM_CONTENT; $label is not pushed"; fi
  RECLAIM_CONTENT="content in $label ($RECLAIM_CONTENT)"
  return 0
}

# --- gate 6: the stash ----------------------------------------------------------------
# reclaim_stash <role> <branch> — 0 when no stash entry was made on that branch.
#
# What this gate is NOT for, because the obvious intuition is wrong: a stash is not lost with
# its worktree. refs/stash lives in the repository's COMMON git directory and is one list for
# every worktree. Measured on git 2.50.1: `git stash list` gave the same entries in a lane and
# in the main checkout, and after `git worktree remove --force` plus `git branch -D` of the
# lane its entry was still listed and its commit still existed. So "the lane's stash list
# must be empty" would be wrong twice: nothing is lost, and one stash anywhere in a
# repository would keep every lane of it for ever.
#
# What it IS for: gate 5 asks whether the branch's commits are in main, and a stash is not a
# commit on that branch. An entry that says "On ai/x/sam" is work gate 5 cannot see, and once
# the branch is deleted it names a branch that no longer exists, in a list nobody reads. So
# entries made on THIS lane's branch keep the lane, with the count and the newest sha; drop
# or apply them and the next check lets the lane go. An entry made on a detached HEAD says
# "(no branch)" and can be tied to no lane: it keeps none, and reclaim_stash_note names it.
reclaim_stash() {
  local role="$1" branch="$2" list line subject count=0 newest=""
  if ! list="$(git_for_role "$role" stash list --format='%H %gs' 2>/dev/null)"; then
    RECLAIM_WHY="git could not list the stash of $(short_path "$(worker_repo "$role")")"
    return 1
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    subject="${line#* }"
    case "$subject" in
      "WIP on $branch: "* | "On $branch: "*)
        count=$((count + 1))
        [ -n "$newest" ] || newest="${line%% *}"
        ;;
    esac
  done <<EOF
$list
EOF
  [ "$count" -gt 0 ] || return 0
  RECLAIM_WHY="$(reclaim_count "$count" "stash entry" "stash entries") on its branch, newest $(reclaim_short "$role" "$newest")"
  return 1
}

# reclaim_stash_note <indent> <repository> — one line about the stash entries of that
# repository that were made on no branch, said once per repository in a run
RECLAIM_STASH_SAID=""
reclaim_stash_note() {
  local indent="$1" repo="$2" list line count=0
  case "$_RECLAIM_NL$RECLAIM_STASH_SAID" in *"$_RECLAIM_NL$repo$_RECLAIM_NL"*) return 0 ;; esac
  RECLAIM_STASH_SAID="$RECLAIM_STASH_SAID$repo$_RECLAIM_NL"
  list="$(git_in "$repo" stash list --format='%gs' 2>/dev/null || true)"
  while IFS= read -r line; do
    case "$line" in "WIP on (no branch): "* | "On (no branch): "*) count=$((count + 1)) ;; esac
  done <<EOF
$list
EOF
  [ "$count" -gt 0 ] || return 0
  say "$indent$(reclaim_count "$count" "stash entry" "stash entries") on no branch (not attributed to any lane) in $(short_path "$repo"). They keep no lane and nothing removes them: git -C \"$repo\" stash list"
}

# --- gate 7: Beads --------------------------------------------------------------------
# _reclaim_beads_down <why> [<scope>] — Beads cannot be asked. Remembered for the rest of the
# run, for this project unless <scope> says otherwise: a bd that hung once will hang again,
# and every further lane would wait the whole limit for the same non-answer. An answer that
# was cut short is a fact about one team's question, not about bd, so that one is remembered
# for the team alone (reclaim_beads_key).
_reclaim_beads_down() {
  RECLAIM_BEADS_DOWN="$1"
  RECLAIM_BEADS_DOWN_AT="${2:-$ROOT}"
  RECLAIM_WHY="cannot ask Beads ($1)"
  return 1
}

# reclaim_beads_forget — drop what Beads said. Called when a run ends, and before Beads is
# asked about another team.
RECLAIM_BEADS_FILE=""
RECLAIM_BEADS_AT=""
RECLAIM_BEADS_WHO=""
reclaim_beads_forget() {
  [ -z "$RECLAIM_BEADS_FILE" ] || /bin/rm -f "$RECLAIM_BEADS_FILE"
  RECLAIM_BEADS_FILE=""
  RECLAIM_BEADS_AT=""
  RECLAIM_BEADS_WHO=""
}

# reclaim_beads_key — what one answer is good for: one team of one project. The question
# names that team's lanes, so another team of the same project has to ask its own.
reclaim_beads_key() { printf '%s|%s\n' "$ROOT" "${TEAM:-}"; }

# The most beads one answer may hold. The question names a team's worker lanes, and a lane has
# a handful of tasks; an answer this long means the question was not read the way it was
# written, and an open task could be past the cut. So an answer of this length is "cannot
# tell", and the lanes stay.
RECLAIM_BEADS_LIMIT=1000

# reclaim_beads_load — ask Beads ONCE per team per run, for the tasks of that team's worker
# lanes and nothing else, and answer every lane from that. Sets RECLAIM_BEADS_FILE (a JSON
# array of beads) and RECLAIM_BEADS_WHO (the names asked about, one per line), or returns 1
# with RECLAIM_WHY set.
#
# Once, and not once per lane, because every bd call opens the whole store before it reads a
# row, and they run one at a time: 4 to 33 seconds each on 2026-10-14 (the measurement is
# next to RECLAIM_ASK_SECONDS), and 2.7 s for the smallest question on 2026-10-15 with
# nothing else waiting. A question per lane would make `teamctl stop` in a team with ten
# parked lanes a matter of minutes, and hold every other agent's bd call behind it.
#
# v1.19.0 asked for every bead in the project (`bd list --all --limit 0`): 1,465 beads, 1.2
# MB, on every `teamctl stop`, for the few that matter. This asks by name: the beads assigned
# to this team's worker lanes, messages left out, in one `bd query`. The answer is a bare
# array; a wrapped {"issues": [...]} is read as well, so a bd that changes its shape is not
# taken for a broken one.
reclaim_beads_load() {
  local out rc=0 key role who expr="" count
  key="$(reclaim_beads_key)"
  if [ "$RECLAIM_BEADS_AT" = "$key" ] && [ -n "$RECLAIM_BEADS_FILE" ] && [ -f "$RECLAIM_BEADS_FILE" ]; then return 0; fi
  if [ -n "${RECLAIM_BEADS_DOWN:-}" ] && { [ "${RECLAIM_BEADS_DOWN_AT:-}" = "$ROOT" ] || [ "${RECLAIM_BEADS_DOWN_AT:-}" = "$key" ]; }; then
    RECLAIM_WHY="cannot ask Beads ($RECLAIM_BEADS_DOWN)"
    return 1
  fi
  reclaim_beads_forget
  [ -n "$BD_BIN" ] || { _reclaim_beads_down "bd is not installed" || return 1; }
  # A project with no Beads workspace is not asked at all. `bd where` is how the rest of
  # teamctl finds one, and it took 18 s here under load; a team that runs without Beads
  # (teamctl start --skip-beads) would pay that, and then the whole limit, on every
  # `teamctl stop`, to learn what its directory already says. A workspace teamctl set up is
  # .beads in the project root (beads_ensure runs `bd init` there), and one kept anywhere
  # else is announced by BEADS_DIR. Neither: there is nothing to ask, and the lane stays.
  if [ ! -e "$ROOT/.beads" ] && [ -z "${BEADS_DIR:-}" ]; then
    _reclaim_beads_down "no Beads workspace in $(short_path "$ROOT")" || return 1
  fi
  # The names, as Beads knows them (<team>.<role>, or the bare role in the first team). A name
  # teamctl would never give (anything but letters, digits, '.', '_' and '-') is not put into
  # the question; that lane then has no answer, and stays.
  for role in $(reg_list); do
    [ "$(reg_field "$role" kind 2>/dev/null || true)" = "worker" ] || continue
    who="$(team_identity "$TEAM" "$role")"
    case "$who" in "" | *[!A-Za-z0-9._-]*) continue ;; esac
    expr="$expr${expr:+ OR }assignee=\"$who\""
    RECLAIM_BEADS_WHO="$RECLAIM_BEADS_WHO$who$_RECLAIM_NL"
  done
  [ -n "$expr" ] || { _reclaim_beads_down "no worker lane of team $TEAM has a name Beads could be asked about" "$key" || return 1; }
  out="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/wolfmux-reclaim.XXXXXX" 2>/dev/null || true)"
  [ -n "$out" ] || { _reclaim_beads_down "no scratch file could be made in ${TMPDIR:-/tmp}" || return 1; }
  # Said before the wait, on stderr: a command that goes quiet for half a minute looks hung,
  # and this is the one place where it may really be waiting that long.
  info "reclaim: asking Beads which tasks are closed (it gets $RECLAIM_ASK_SECONDS s to answer)"
  # --all: a closed task is what says a lane is done, and bd query leaves closed ones out
  # without it.
  reclaim_ask "$RECLAIM_ASK_SECONDS" "$out" "$ROOT" "$BD_BIN" query "($expr) AND type!=message" --all --limit "$RECLAIM_BEADS_LIMIT" --json || rc=$?
  if [ "$rc" -eq 124 ]; then
    reclaim_scratch_done "$out"
    _reclaim_beads_down "bd did not answer in $RECLAIM_ASK_SECONDS s" || return 1
  fi
  if [ "$rc" -ne 0 ]; then
    rc="bd failed, exit $rc$(reclaim_said "$out")"
    reclaim_scratch_done "$out"
    _reclaim_beads_down "$rc" || return 1
  fi
  if ! "$JQ_BIN" -c 'if type == "array" then . elif type == "object" and (.issues | type) == "array" then .issues else error("neither a list nor a wrapped list") end
        | if all(.[]; type == "object") then . else error("a list of something else") end' "$out" >"$out.beads" 2>/dev/null; then
    reclaim_scratch_done "$out"
    /bin/rm -f "$out.beads"
    _reclaim_beads_down "its answer could not be read" || return 1
  fi
  reclaim_scratch_done "$out"
  count="$("$JQ_BIN" -r 'length' "$out.beads" 2>/dev/null || true)"
  case "${count:-x}" in "" | *[!0-9]*)
    /bin/rm -f "$out.beads"
    _reclaim_beads_down "its answer could not be read" || return 1
    ;;
  esac
  if [ "$count" -ge "$RECLAIM_BEADS_LIMIT" ]; then
    /bin/rm -f "$out.beads"
    _reclaim_beads_down "its answer stopped at $RECLAIM_BEADS_LIMIT beads, and an open task could be past that" "$key" || return 1
  fi
  RECLAIM_BEADS_FILE="$out.beads"
  RECLAIM_BEADS_AT="$key"
  return 0
}

# reclaim_task <role> — 0 when Beads says this lane's work is done. Sets RECLAIM_TASK.
# The lane has no bead id on record, so its tasks are the ones assigned to the name its agent
# has in Beads (<team>.<role>, or the bare role in the first team). A message is not a task:
# an unread one does not hold a lane, and a read one does not finish it.
reclaim_task() {
  local role="$1" who open closed
  RECLAIM_TASK=""
  reclaim_beads_load || return 1
  who="$(team_identity "$TEAM" "$role")"
  # A lane that joined the team after the question was put was not named in it, so the
  # answer says nothing about it either way.
  case "$_RECLAIM_NL$RECLAIM_BEADS_WHO" in
    *"$_RECLAIM_NL$who$_RECLAIM_NL"*) ;;
    *)
      RECLAIM_WHY="Beads was not asked about $who in this run"
      return 1
      ;;
  esac
  open="$("$JQ_BIN" -r --arg who "$who" '[.[] | select(.assignee == $who and (.issue_type // "task") != "message" and (.status // "open") != "closed")] | (.[0].id // "")' "$RECLAIM_BEADS_FILE" 2>/dev/null || true)"
  closed="$("$JQ_BIN" -r --arg who "$who" '[.[] | select(.assignee == $who and (.issue_type // "task") != "message" and .status == "closed")] | sort_by(.closed_at // "") | (last.id // "")' "$RECLAIM_BEADS_FILE" 2>/dev/null || true)"
  if [ -n "$open" ]; then
    RECLAIM_WHY="task open ($open)"
    return 1
  fi
  if [ -z "$closed" ]; then
    RECLAIM_WHY="no task bead on record"
    return 1
  fi
  RECLAIM_TASK="$closed"
  return 0
}

# --- gate 8: GitHub -------------------------------------------------------------------
# _reclaim_github_down <repository> <why> — remembered per repository for the rest of the run
_reclaim_github_down() {
  RECLAIM_GITHUB_DOWN="$2"
  RECLAIM_GITHUB_DOWN_AT="$1"
  RECLAIM_WHY="cannot ask GitHub ($2)"
  return 1
}

# reclaim_pr <role> <branch> — 0 when gh says no pull request is open on that branch
reclaim_pr() {
  local role="$1" branch="$2" repo out rc=0 number
  repo="$(worker_repo "$role")"
  if [ "${RECLAIM_GITHUB_DOWN_AT:-}" = "$repo" ] && [ -n "${RECLAIM_GITHUB_DOWN:-}" ]; then
    RECLAIM_WHY="cannot ask GitHub ($RECLAIM_GITHUB_DOWN)"
    return 1
  fi
  [ -n "$GH_BIN" ] || { _reclaim_github_down "$repo" "gh is not installed" || return 1; }
  out="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/wolfmux-reclaim.XXXXXX" 2>/dev/null || true)"
  [ -n "$out" ] || { _reclaim_github_down "$repo" "no scratch file could be made in ${TMPDIR:-/tmp}" || return 1; }
  reclaim_ask "$RECLAIM_ASK_SECONDS" "$out" "$repo" "$GH_BIN" pr list --head "$branch" --state open --json number --limit 20 || rc=$?
  if [ "$rc" -eq 124 ]; then
    reclaim_scratch_done "$out"
    _reclaim_github_down "$repo" "gh did not answer in $RECLAIM_ASK_SECONDS s" || return 1
  fi
  if [ "$rc" -ne 0 ]; then
    # gh's own last line says which it is: not logged in, no GitHub remote, no network.
    rc="gh failed, exit $rc$(reclaim_said "$out")"
    reclaim_scratch_done "$out"
    _reclaim_github_down "$repo" "$rc" || return 1
  fi
  if ! "$JQ_BIN" -e 'type == "array" and all(.[]; type == "object")' "$out" >/dev/null 2>&1; then
    reclaim_scratch_done "$out"
    _reclaim_github_down "$repo" "its answer could not be read" || return 1
  fi
  number="$("$JQ_BIN" -r '.[0].number // ""' "$out" 2>/dev/null || true)"
  reclaim_scratch_done "$out"
  [ -n "$number" ] || return 0
  RECLAIM_WHY="open PR #$number"
  return 1
}

# --- every gate, in order -------------------------------------------------------------
# reclaim_local <role> — gates 1 to 4, the ones that need nothing but tmux and git and that
# are asked again under the lock just before a removal. Sets RECLAIM_BRANCH, RECLAIM_TIP and,
# when it says no, RECLAIM_WHY (and RECLAIM_RUNNING when the lane is simply running).
reclaim_local() {
  local role="$1" path head dirty
  RECLAIM_WHY="" RECLAIM_RUNNING="" RECLAIM_BRANCH="" RECLAIM_TIP=""
  if ! reg_exists "$role"; then
    RECLAIM_WHY="it is no longer on record"
    return 1
  fi
  if [ "$(reg_field "$role" kind 2>/dev/null || true)" != "worker" ]; then
    RECLAIM_WHY="it works in your own checkout"
    return 1
  fi
  # As in lib/disk.sh: disk_lane_running asks tmux about $SESSION, and not knowing whether a
  # lane runs counts as running.
  [ -n "${SESSION:-}" ] || SESSION="$(session_name_for_project)"
  if disk_lane_running "$role"; then
    RECLAIM_RUNNING=1
    RECLAIM_WHY="it is still running${DISK_LANE_DOUBT:+: $DISK_LANE_DOUBT}"
    return 1
  fi
  if disk_keep_build "$role"; then
    RECLAIM_WHY="teamctl keep protects this lane"
    return 1
  fi
  path="$(reg_field "$role" workdir 2>/dev/null || true)"
  RECLAIM_BRANCH="$(reg_field "$role" branch 2>/dev/null || true)"
  if [ -z "$path" ] || [ ! -d "$path" ]; then
    RECLAIM_WHY="its worktree is gone (clear the record: teamctl remove $role)"
    return 1
  fi
  if ! disk_confined "$path" "$(worker_trees_dir "$role")" "$(worker_repo "$role")"; then
    RECLAIM_WHY="its record points outside $(short_path "$(worker_trees_dir "$role")")"
    return 1
  fi
  # disk_work_dirty_list reads a git that fails as "nothing is dirty", which is the right
  # way round for a report and the wrong one for a deletion. So git has to answer first.
  if ! "$GIT_BIN" -C "$path" status --porcelain >/dev/null 2>&1; then
    RECLAIM_WHY="git cannot read its worktree"
    return 1
  fi
  dirty="$(disk_work_dirty_count "$path")"
  if [ "$dirty" != "0" ]; then
    RECLAIM_WHY="dirty: $(reclaim_count "$dirty" "uncommitted file" "uncommitted files")"
    return 1
  fi
  RECLAIM_TIP="$(git_for_role "$role" rev-parse -q --verify "refs/heads/$RECLAIM_BRANCH^{commit}" 2>/dev/null || true)"
  if [ -z "$RECLAIM_BRANCH" ] || [ -z "$RECLAIM_TIP" ]; then
    RECLAIM_WHY="its branch ${RECLAIM_BRANCH:-(none on record)} is not in $(short_path "$(worker_repo "$role")")"
    return 1
  fi
  head="$("$GIT_BIN" -C "$path" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null || true)"
  if [ "$head" != "$RECLAIM_TIP" ]; then
    RECLAIM_WHY="its worktree is at $(reclaim_short "$role" "${head:-0000000}"), which is not the tip of its branch"
    return 1
  fi
  return 0
}

# reclaim_check <role> — may this lane go? 0 yes, 1 no. Deletes nothing, and writes nothing
# into any repository or record: its only files are scratch ones under the temporary
# directory, which it removes.
#   yes: RECLAIM_PASSED says what proved it, RECLAIM_BRANCH / RECLAIM_TIP what would go
#   no:  RECLAIM_WHY says what holds it, in the words `teamctl status` prints
reclaim_check() {
  local role="$1"
  RECLAIM_PASSED="" RECLAIM_TASK=""
  RECLAIM_PROOF_REF="" RECLAIM_PROOF_HOW="" RECLAIM_PROOF_SHA="" RECLAIM_PROOF_PUSHED=1 RECLAIM_CONTENT=""
  reclaim_local "$role" || return 1
  reclaim_content "$role" "$RECLAIM_BRANCH" "$RECLAIM_TIP" || return 1
  reclaim_stash "$role" "$RECLAIM_BRANCH" || return 1
  reclaim_task "$role" || return 1
  reclaim_pr "$role" "$RECLAIM_BRANCH" || return 1
  RECLAIM_PASSED="$RECLAIM_CONTENT · task closed ($RECLAIM_TASK) · no open PR"
  return 0
}

# --- the record of every lane teamctl takes off the books -----------------------------
# lane_removal_log <role> <trigger> <kilobytes> <branch> <tip> <reason>
#                  [<proof ref> <proof how> <proof sha> <pushed 0|1>]
# One line in the machine-wide ledger (~/.wolfmux/state/reclaimed.jsonl) for a lane that is
# about to go, whichever command takes it: reclaim, remove, destroy --worktrees, destroy
# --purge. The tip is the point of it. A team's own event log is deleted with the team, and
# scrollback is not a record, so this file is the one place a deleted branch can be looked up
# afterwards. Returns 1 when the line could not be written.
lane_removal_log() {
  local file
  file="$(disk_reclaim_log_file)"
  /bin/mkdir -p "$(dirname "$file")" 2>/dev/null || true
  [ -n "$JQ_BIN" ] || return 1
  # The braces are for the redirection: a file that cannot be opened is reported by the shell
  # before jq runs, and that message belongs to nobody. The status is what says it failed.
  {
    "$JQ_BIN" -cn --arg ts "$(now_iso)" --arg project "${PROJECT_KEY:-}" --arg team "${TEAM:-}" \
      --arg role "$1" --arg trigger "$2" --arg kb "${3:-0}" --arg branch "${4:-}" --arg tip "${5:-}" \
      --arg reason "${6:-}" --arg ref "${7:-}" --arg how "${8:-}" --arg sha "${9:-}" --arg pushed "${10:-}" \
      --arg by "${EVENT_BY:-${TEAM_ROLE:-operator}}" --arg head "${LANE_HEAD:-}" \
      --arg workdir "$(reg_field "$1" workdir 2>/dev/null || true)" --arg session "$(reg_field "$1" session_id 2>/dev/null || true)" \
      '{ts: $ts, event: "lane-removed", project: $project, team: $team, role: $role, freed_kb: ($kb | tonumber? // 0),
        trigger: $trigger, took: "worktree branch record", by: $by, branch: $branch, tip: $tip,
        worktree_head: (if $head == "" then null else $head end), reason: $reason,
        proof: (if $ref == "" then null else {ref: $ref, how: $how, sha: $sha} end),
        main_pushed: (if $pushed == "" then null else $pushed == "1" end), workdir: $workdir, session: $session}' \
      >>"$file"
  } 2>/dev/null
}

# lane_removal_undone <role> <trigger> <branch> <tip> <why> — the lane whose removal was just
# written down stayed after all: git refused its worktree. The ledger is only ever added to,
# so the correction is a second line, "lane-kept", with the same branch and tip. Whoever finds
# a "lane-removed" there looks for a later "lane-kept" with that tip before believing it.
lane_removal_undone() {
  local file
  file="$(disk_reclaim_log_file)"
  [ -n "$JQ_BIN" ] || return 1
  {
    "$JQ_BIN" -cn --arg ts "$(now_iso)" --arg project "${PROJECT_KEY:-}" --arg team "${TEAM:-}" \
      --arg role "$1" --arg trigger "$2" --arg branch "${3:-}" --arg tip "${4:-}" --arg reason "${5:-}" \
      --arg by "${EVENT_BY:-${TEAM_ROLE:-operator}}" \
      '{ts: $ts, event: "lane-kept", project: $project, team: $team, role: $role, trigger: $trigger, by: $by,
        branch: $branch, tip: $tip, reason: $reason}' \
      >>"$file"
  } 2>/dev/null
}

# lane_tip <role> — the full sha the lane's recorded branch is at, empty when it is not there
lane_tip() {
  local branch
  branch="$(reg_field "$1" branch 2>/dev/null || true)"
  [ -n "$branch" ] || return 0
  git_for_role "$1" rev-parse -q --verify "refs/heads/$branch^{commit}" 2>/dev/null || true
}

# lane_tip_say <indent> <role> — "<role>: branch <branch> was at <sha>", printed before a
# lane goes, by every command that takes one: reclaim, remove, destroy --purge. Sets LANE_TIP
# and LANE_HEAD for the caller's log line.
#
# The worktree's own HEAD is said as well when it is somewhere else: a detached HEAD, or a
# branch the agent made by itself, is exactly the commit no branch name will lead back to
# once a forced removal has taken the worktree. (The automatic reclaim never gets this far
# with such a lane: gate 4 keeps it.)
lane_tip_say() {
  local branch path repo head=""
  LANE_TIP="$(lane_tip "$2")"
  LANE_HEAD=""
  branch="$(reg_field "$2" branch 2>/dev/null || true)"
  path="$(reg_field "$2" workdir 2>/dev/null || true)"
  repo="$(worker_repo "$2")"
  if [ -n "$LANE_TIP" ]; then
    say "$1$2: branch $branch was at $LANE_TIP   (bring it back: git -C \"$repo\" branch $branch $LANE_TIP)"
  fi
  if [ -n "$path" ] && [ -d "$path" ]; then head="$("$GIT_BIN" -C "$path" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null || true)"; fi
  if [ -n "$head" ] && [ "$head" != "$LANE_TIP" ]; then
    LANE_HEAD="$head"
    say "$1$2: its worktree was at $head, which is not the tip of that branch   (bring it back: git -C \"$repo\" branch rescued-$2 $head)"
  fi
}

# --- what a lane that stays is holding ------------------------------------------------
# reclaim_hold_put <role> <kilobytes> <reason> — into the lane's own record, which is where
# `teamctl status` reads it. Under the team's lock, and only for as long as the write takes.
reclaim_hold_put() {
  reg_exists "$1" || return 0
  lock_acquire
  if reg_exists "$1"; then reg_set "$1" hold_why "$3" hold_kb "$2" hold_at "$(now_epoch)"; fi
  lock_release
}

RECLAIM_READY="nothing is in the way: its work is all in main (take it: teamctl reclaim)"

# --- the removal ----------------------------------------------------------------------
# reclaim_remove <role> <trigger> <indent> — take a lane that passed reclaim_check off the
# books. The caller holds the team's lock and has asked reclaim_local again under it.
# Returns 1 with RECLAIM_WHY set, and the branch and the record untouched, when the ledger
# cannot be written or git itself refuses the worktree. Sets RECLAIM_FREED_KB.
reclaim_remove() {
  local role="$1" trigger="$2" indent="$3" path branch tip kb pane now refusal=""
  RECLAIM_FREED_KB=0
  path="$(reg_field "$role" workdir)"
  branch="$RECLAIM_BRANCH"
  tip="$RECLAIM_TIP"
  # Measured whole, before anything goes: the lane is leaving, so all of it is what this frees.
  kb="$(disk_kb "$path")"
  # The sha goes on the screen and into the ledger BEFORE anything is deleted, and a ledger
  # that cannot be written keeps the lane: a removal nobody can look up is not made.
  lane_tip_say "$indent" "$role"
  if ! lane_removal_log "$role" "$trigger" "$kb" "$branch" "$tip" "$RECLAIM_PASSED" \
    "$RECLAIM_PROOF_REF" "$RECLAIM_PROOF_HOW" "$RECLAIM_PROOF_SHA" "$RECLAIM_PROOF_PUSHED"; then
    RECLAIM_WHY="the ledger cannot be written ($(short_path "$(disk_reclaim_log_file)"))"
    return 1
  fi
  # Build output next: an untracked node_modules, or the link --link-node-modules leaves, is
  # what makes git call a finished worktree unclean.
  disk_clean_role "$role" all 1 || true
  # No --force and no rm -rf: git's own "is this worktree clean" is the last gate, and a
  # worktree git will not remove is a lane that stays.
  if ! refusal="$(git_for_role "$role" worktree remove "$path" 2>&1 >/dev/null)"; then
    # Git's own first line says which it is (a locked worktree, populated submodules); the
    # lines after it are how to force it, which is not this command's to suggest.
    refusal="$(printf '%s\n' "$refusal" | sed -n '/[^[:space:]]/p' | sed -n 1p | tr -d '\000-\037' | tr '|' '/' | sed 's/^fatal: //; s/[;,]$//' | cut -c1-100 || true)"
    RECLAIM_WHY="git refused to remove its worktree${refusal:+: $refusal}"
    # The ledger already says this lane was removed. It was not, and the ledger says that too.
    lane_removal_undone "$role" "$trigger" "$branch" "$tip" "$RECLAIM_WHY" || true
    return 1
  fi
  git_for_role "$role" worktree prune 2>/dev/null || true
  if branch_is_ours "$role"; then
    now="$(lane_tip "$role")"
    if [ "$now" != "$tip" ]; then
      warn "$role: branch $branch moved while its lane was being removed (it is at ${now:-nothing} now); it was left alone"
    elif [ "$branch" = "$(git_for_role "$role" symbolic-ref --short -q HEAD || true)" ]; then
      warn "$role: branch $branch is checked out in $(short_path "$(worker_repo "$role")"); it was left alone"
    else
      git_for_role "$role" branch -D "$branch" >/dev/null 2>&1 || warn "could not delete branch $branch"
    fi
  else
    say "$indent$role: teamctl did not create branch $branch; it was left alone"
  fi
  pane="$(tm_pane_for_role "$SESSION" "$role" 2>/dev/null || true)"
  if [ -n "$pane" ]; then tmx kill-pane -t "$pane" 2>/dev/null || true; fi
  /bin/rm -f "$STATE_DIR/settings/$role.json"
  event_log reclaim "$role" "trigger=$trigger branch=$branch tip=$tip proof=$RECLAIM_PROOF_HOW:$RECLAIM_PROOF_SHA freed_kb=$kb"
  reg_delete "$role"
  RECLAIM_FREED_KB="$kb"
  return 0
}

# reclaim_one <role> <trigger> <apply 0|1> <record 0|1> <indent> — ask one lane, and take it
# when it passes and apply is 1. The lock is taken only around the removal, never around the
# check: Beads and GitHub can take most of a minute to answer, and a team's lock held across
# that wait is every other teamctl command of that team dying on it (the lock gives up after
# 30 seconds).
#   RECLAIM_RESULT  gone | would | held | running | vanished
#   RECLAIM_KB      what it freed, would free, or holds (0 for running and vanished)
#
# <size> is `fresh` or `known`. A parked lane's size does not change by itself, so the sweep
# a park triggers reuses what the last check measured for every lane but the one that was
# just parked (`known`); `teamctl reclaim`, which is asked for, measures every lane (`fresh`).
# A du over one lane is a tenth of a second to several; over thirty lanes on every
# `teamctl stop` it is the difference between a command and a wait.
reclaim_one() {
  local role="$1" trigger="$2" apply="$3" record="$4" indent="$5" size="${6:-fresh}" path branch tip known=""
  RECLAIM_RESULT="" RECLAIM_KB=0
  path="$(reg_field "$role" workdir 2>/dev/null || true)"
  if [ "$size" = "known" ]; then
    known="$(reg_field "$role" hold_kb 2>/dev/null || true)"
    case "${known:-x}" in "" | *[!0-9]* | 0?*) known="" ;; esac
  fi
  if reclaim_check "$role"; then
    if [ "$apply" -ne 1 ]; then
      RECLAIM_RESULT="would"
      RECLAIM_KB="${known:-$(disk_kb "$path")}"
      return 0
    fi
    branch="$RECLAIM_BRANCH"
    tip="$RECLAIM_TIP"
    lock_acquire
    # Asked again now that nobody else can change the team: the check above took seconds.
    if reclaim_local "$role" && [ "$RECLAIM_TIP" = "$tip" ] && [ "$RECLAIM_BRANCH" = "$branch" ]; then
      if reclaim_remove "$role" "$trigger" "$indent"; then
        lock_release
        RECLAIM_RESULT="gone"
        RECLAIM_KB="$RECLAIM_FREED_KB"
        return 0
      fi
    elif [ -z "$RECLAIM_WHY" ]; then
      RECLAIM_WHY="it changed while it was being checked"
    fi
    lock_release
  fi
  # Another teamctl took this lane while it was being asked about (two lanes stopped at the
  # same moment each ask the whole team). There is nothing left to say about it.
  if ! reg_exists "$role"; then
    RECLAIM_RESULT="vanished"
    return 0
  fi
  if [ -n "$RECLAIM_RUNNING" ]; then
    RECLAIM_RESULT="running"
    return 0
  fi
  RECLAIM_RESULT="held"
  RECLAIM_KB="${known:-$(disk_kb "$path")}"
  if [ "$record" -eq 1 ]; then reclaim_hold_put "$role" "$RECLAIM_KB" "$RECLAIM_WHY"; fi
  return 0
}

# --- when a lane is parked ------------------------------------------------------------
# reclaim_on_park <role just parked, or empty> <trigger> <every lane aloud 0|1> <indent>
# The two paths that park a lane call this once the lane is parked and the team's lock is
# released: `teamctl stop` for one lane, a plain `teamctl destroy` for all of them.
#
# Integration is a plain `git merge` in your checkout, so teamctl never sees it happen. What
# it does see is the next lane being parked — so that is when EVERY parked lane of the team
# is asked again, and a lane that was parked before its merge goes then, without anybody
# having to remember it.
#
# Policy auto-reclaim (default on) decides whether a lane that passes is taken. Off: nothing
# is removed, and the lane's record says that nothing is in its way.
#
# Always returns 0, and is never called directly: reclaim_after_park, below, runs it in a
# subshell with `|| true`. Two things follow from that:
# - `set -e` is off for everything this calls, so no step below may count on the shell ending
#   for it. None does: the removal is reached only through `if` tests each step has to pass.
# - Nothing set in here reaches the caller. What became of a lane is read from its record
#   afterwards (reg_exists), which is where "off the books" is true or not.
reclaim_on_park() {
  local parked="$1" trigger="$2" aloud="$3" indent="$4" apply=0 role freed=0 mine asked=0
  if [ "$(policy_get auto-reclaim)" = "on" ]; then apply=1; fi
  [ -n "${SESSION:-}" ] || SESSION="$(session_name_for_project)"
  # The lane that was just parked is asked first, so its line comes first; it is also on the
  # team's list, and it is not asked a second time when the list comes round to it.
  for role in $parked $(reg_list); do
    mine=0
    if [ -n "$parked" ] && [ "$role" = "$parked" ]; then
      [ "$asked" -eq 0 ] || continue
      asked=1
      mine=1
    fi
    reg_exists "$role" || continue
    [ "$(reg_field "$role" kind)" = "worker" ] || continue
    # The lane that was just parked has just been swept, so its size is measured; every
    # other lane's is the one on record, when there is one.
    if [ "$mine" -eq 1 ] || [ "$aloud" -eq 1 ]; then
      reclaim_one "$role" "$trigger" "$apply" 1 "$indent" fresh
    else
      reclaim_one "$role" "$trigger" "$apply" 1 "$indent" known
    fi
    case "$RECLAIM_RESULT" in
      gone)
        freed=$((freed + RECLAIM_KB))
        say "${indent}reclaimed: $role — $RECLAIM_PASSED — freed $(human_size "$RECLAIM_KB")"
        ;;
      would)
        reclaim_hold_put "$role" "$RECLAIM_KB" "$RECLAIM_READY"
        if [ "$aloud" -eq 1 ]; then
          say "$indent$role: holding $(human_size "$RECLAIM_KB"): $RECLAIM_READY"
        elif [ "$mine" -eq 1 ]; then
          say "lane:    holding $(human_size "$RECLAIM_KB"): $RECLAIM_READY"
        fi
        ;;
      held)
        if [ "$aloud" -eq 1 ]; then
          say "$indent$role: holding $(human_size "$RECLAIM_KB"): $RECLAIM_WHY"
        elif [ "$mine" -eq 1 ]; then
          say "lane:    holding $(human_size "$RECLAIM_KB"): $RECLAIM_WHY   (every parked lane: teamctl reclaim --dry-run)"
        fi
        ;;
    esac
  done
  # Bookkeeping, and both callers run under `set -e` with the lane already parked: parking
  # must not fail because this did. Each line is guarded by itself, because under `set -e` a
  # `return 0` that follows a failing command is never reached (measured, bash 3.2).
  reclaim_beads_forget || true
  disk_cache_adjust "$freed" || true
  disk_parked_adjust "$freed" || true
  return 0
}

# reclaim_after_park <as reclaim_on_park> — what the two commands that park a lane call. The
# lane is parked by then, and the command has to say so whatever becomes of the check. So the
# check is run where it can end nothing but itself, in two shells, one inside the other:
#
# - The outer one makes a scratch directory, gives it to the check as its TMPDIR, and removes
#   it in a trap on EXIT. A check that is cut short cannot drop what Beads told it, and that
#   answer is a file; a line after the check would be skipped by the same `exit`. The
#   directory is made in that shell, so its trap removes only what that shell made. Being a
#   subshell, it leaves the caller's own EXIT trap and TMPDIR as they were.
# - The inner one runs the check and takes an `exit` in it (lock_acquire dies when the team's
#   lock stays held for 30 seconds). It is a shell of its own for a second reason:
#   lock_acquire re-arms the EXIT trap of the shell it runs in every time it takes the lock
#   (lib/registry.sh). In the outer shell that would throw the cleanup away at the first lane.
#
# `|| true` takes a check that fails, and this returns 0 whatever happened.
reclaim_after_park() {
  (
    RECLAIM_PARK_IN="${TMPDIR:-/tmp}"
    RECLAIM_PARK_SCRATCH="$(/usr/bin/mktemp -d "$RECLAIM_PARK_IN/wolfmux-reclaim-park.XXXXXX" 2>/dev/null || true)"
    if [ -n "$RECLAIM_PARK_SCRATCH" ]; then
      trap 'reclaim_park_done' EXIT
      export TMPDIR="$RECLAIM_PARK_SCRATCH"
    fi
    (reclaim_on_park "$@")
  ) || true
  return 0
}

# reclaim_park_done — the EXIT trap of reclaim_after_park's outer shell. Only ever the
# directory that shell made, under the temporary directory it made it in.
reclaim_park_done() {
  case "${RECLAIM_PARK_SCRATCH:-}" in
    "${RECLAIM_PARK_IN:-/nowhere}"/wolfmux-reclaim-park.*) /bin/rm -rf "$RECLAIM_PARK_SCRATCH" 2>/dev/null || true ;;
  esac
}

# --- teamctl reclaim [--dry-run] [--all-teams] ----------------------------------------
# reclaim_team <apply 0|1> <indent> — the per-lane lines of the LOADED team and what they add
# up to: RECLAIM_TOTAL (freed, or would be), RECLAIM_LANES, RECLAIM_HELD, RECLAIM_HELD_KB,
# RECLAIM_RUNNING_LANES. One function for one team and for every team on the machine, so the
# two cannot drift, as with prune_team.
reclaim_team() {
  local apply="$1" indent="${2:-  }" role repos="" repo rnote
  RECLAIM_TOTAL=0 RECLAIM_LANES=0 RECLAIM_HELD=0 RECLAIM_HELD_KB=0 RECLAIM_RUNNING_LANES=0
  for role in $(reg_list); do
    [ "$(reg_field "$role" kind)" = "worker" ] || continue
    repo="$(worker_repo "$role")"
    case "$_RECLAIM_NL$repos" in *"$_RECLAIM_NL$repo$_RECLAIM_NL"*) ;; *) repos="$repos$repo$_RECLAIM_NL" ;; esac
    rnote="$(reg_field "$role" repo 2>/dev/null || true)"
    [ -z "$rnote" ] || rnote=" (in $(short_path "$rnote"))"
    reclaim_one "$role" reclaim "$apply" "$apply" "$indent"
    case "$RECLAIM_RESULT" in
      gone)
        RECLAIM_TOTAL=$((RECLAIM_TOTAL + RECLAIM_KB))
        RECLAIM_LANES=$((RECLAIM_LANES + 1))
        printf '%s%-18s %9s   removed: %s%s\n' "$indent" "$role" "$(human_size "$RECLAIM_KB")" "$RECLAIM_PASSED" "$rnote"
        ;;
      would)
        RECLAIM_TOTAL=$((RECLAIM_TOTAL + RECLAIM_KB))
        RECLAIM_LANES=$((RECLAIM_LANES + 1))
        printf '%s%-18s %9s   would remove: %s was at %s — %s%s\n' "$indent" "$role" "$(human_size "$RECLAIM_KB")" "$RECLAIM_BRANCH" "$RECLAIM_TIP" "$RECLAIM_PASSED" "$rnote"
        ;;
      running)
        RECLAIM_RUNNING_LANES=$((RECLAIM_RUNNING_LANES + 1))
        printf '%s%-18s %9s   running, left alone%s\n' "$indent" "$role" "$(human_size "$(disk_kb "$(reg_field "$role" workdir)")")" "$rnote"
        ;;
      held)
        RECLAIM_HELD=$((RECLAIM_HELD + 1))
        RECLAIM_HELD_KB=$((RECLAIM_HELD_KB + RECLAIM_KB))
        printf '%s%-18s %9s   holding: %s%s\n' "$indent" "$role" "$(human_size "$RECLAIM_KB")" "$RECLAIM_WHY" "$rnote"
        ;;
    esac
  done
  if [ "$apply" -eq 1 ]; then
    event_log reclaim "" "freed_kb=$RECLAIM_TOTAL lanes=$RECLAIM_LANES holding=$RECLAIM_HELD"
    # Bookkeeping about lanes that are already gone. It must not turn a reclaim that worked
    # into a command that says it failed: that is how a deletion gets run a second time.
    disk_cache_adjust "$RECLAIM_TOTAL" || true
    disk_parked_adjust "$RECLAIM_TOTAL" || true
    layout_apply
  fi
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    reclaim_stash_note "$indent" "$repo"
  done <<EOF
$repos
EOF
}

# reclaim_footer <dry> <hint> <label> <scope> <total> <lanes> <running> <held> <held kb>
reclaim_footer() {
  local dry="$1" hint="$2" label="$3" scope="$4" total="$5" lanes="$6" running="$7" held="$8" held_kb="$9"
  say ""
  if [ "$dry" -eq 1 ]; then
    printf '  %-18s %9s   is what this would free in %s parked lane%s%s (%s running, %s holding %s)\n' \
      "$label" "$(human_size "$total")" "$lanes" "$([ "$lanes" = "1" ] || printf s)" "$scope" "$running" "$held" "$(human_size "$held_kb")"
    say "  take it: teamctl reclaim$hint"
  else
    printf '  %-18s %9s   freed from %s parked lane%s%s (%s running, %s holding %s)\n' \
      "$label" "$(human_size "$total")" "$lanes" "$([ "$lanes" = "1" ] || printf s)" "$scope" "$running" "$held" "$(human_size "$held_kb")"
    say "  $(disk_free_label) free on this disk now. Every removal, with the sha its branch was at: $(short_path "$(disk_reclaim_log_file)")"
  fi
  if [ "$held" -gt 0 ]; then
    say "  A lane that is holding says why above, and teamctl status repeats it. Let one go anyway: teamctl remove <role>$hint · keep one for good: teamctl keep <role>$hint"
  fi
}

RECLAIM_TAKES="a parked lane's worktree, branch and record  ·  only when its task is closed, its content is in main, nothing is uncommitted or stashed, and no PR is open"

cmd_reclaim() {
  local dry=0 apply=1 all_teams=0 hint="" doubt=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      --all-teams) all_teams=1 ;;
      *) die_usage "usage: teamctl reclaim [--team <name>] [--all-teams] [--dry-run]" ;;
    esac
    shift
  done
  if [ "$dry" -eq 1 ]; then apply=0; fi
  require_tools
  if [ "$all_teams" -eq 1 ]; then
    reclaim_all_teams "$apply" "$dry"
    return 0
  fi
  load_project
  [ "$dry" -eq 1 ] || require_manager reclaim
  SESSION="$(session_name_for_project)"
  if [ "$TEAM" != "$WOLFMUX_DEFAULT_TEAM" ]; then hint=" --team $TEAM"; fi
  if [ "$dry" -eq 1 ]; then
    say "reclaim team '$TEAM' of $(short_path "$ROOT")   ·   DRY RUN: nothing is deleted"
  else
    say "reclaim team '$TEAM' of $(short_path "$ROOT")"
  fi
  say "  takes: $RECLAIM_TAKES"
  say ""
  doubt="$(prune_team_doubt)"
  if [ -n "$doubt" ]; then
    die "$doubt. Nothing was touched. Look: teamctl status · teamctl panes. Then park it for real (teamctl stop <role>$hint) or bring it back (teamctl restart <role>$hint) and run reclaim again."
  fi
  if [ "$apply" -eq 1 ]; then ensure_state_dirs; fi
  reclaim_team "$apply"
  reclaim_beads_forget || true # bookkeeping, as in reclaim_team: the total below is still owed
  reclaim_footer "$dry" "$hint" total "" "$RECLAIM_TOTAL" "$RECLAIM_LANES" "$RECLAIM_RUNNING_LANES" "$RECLAIM_HELD" "$RECLAIM_HELD_KB"
}

# reclaim_all_teams <apply> <dry> — every team of every project on this machine, and YOURS
# alone to run: the same guard, for the same reason, as `teamctl prune --all-teams`
# (require_operator, lib/policy.sh). A lead has no standing outside its own team, and this
# form deletes other teams' lanes.
#
# It is the form that reaches what nothing else does: a team whose lead is gone has nobody
# left to park a lane, so its finished lanes are asked by no automatic path.
reclaim_all_teams() {
  local apply="$1" dry="$2" key team rc doubt
  local total=0 lanes=0 running=0 held=0 held_kb=0 teams=0 projects=0 skipped=""
  require_operator "reclaim --all-teams" "every team of every project on this machine" \
    "teamctl reclaim for your own team (no --all-teams), and teamctl reclaim --dry-run for a look at it"
  if [ "$dry" -eq 1 ]; then
    say "reclaim EVERY team on this machine   ·   DRY RUN: nothing is deleted"
  else
    say "reclaim EVERY team on this machine"
  fi
  say "  takes: $RECLAIM_TAKES"
  for key in $(dash_projects); do
    rc=0
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
        skipped="$skipped $key/$team"
        printf '    %s\n' "$doubt — this team was skipped whole and nothing of it was touched"
        continue
      fi
      reclaim_team "$apply" "    "
      printf '    %-16s %9s   %s in this team (%s parked lane%s, %s running, %s holding %s)\n' \
        "team total" "$(human_size "$RECLAIM_TOTAL")" \
        "$([ "$dry" -eq 1 ] && printf 'would be freed' || printf freed)" \
        "$RECLAIM_LANES" "$([ "$RECLAIM_LANES" = "1" ] || printf s)" "$RECLAIM_RUNNING_LANES" "$RECLAIM_HELD" "$(human_size "$RECLAIM_HELD_KB")"
      total=$((total + RECLAIM_TOTAL))
      lanes=$((lanes + RECLAIM_LANES))
      running=$((running + RECLAIM_RUNNING_LANES))
      held=$((held + RECLAIM_HELD))
      held_kb=$((held_kb + RECLAIM_HELD_KB))
    done
  done
  # Beads was asked once per team above, about that team's lanes alone (a new team makes
  # reclaim_beads_load forget the last answer); this drops the last one.
  reclaim_beads_forget || true # bookkeeping, as in reclaim_team: the total below is still owed
  reclaim_footer "$dry" " --all-teams" "machine total" \
    " across $teams team$([ "$teams" = "1" ] || printf s) in $projects project$([ "$projects" = "1" ] || printf s)" \
    "$total" "$lanes" "$running" "$held" "$held_kb"
  if [ -n "$skipped" ]; then
    say "  Teams skipped whole, because a lane of theirs could not be placed:$skipped"
  fi
}
