#!/bin/bash
# guard.sh — a teammate stays in its own worktree and on its own branch.
#
# Every worker already gets a private git worktree and branch, and is told to stay
# there. This makes it more than a request: Claude Code runs `teamctl _guard` as a
# PreToolUse hook before every tool call of a worker (hooks run in bypass mode too),
# and a call that reaches outside is refused with a reason the model can act on.
#
#   changing files   only inside the worker's own worktree (and temporary directories)
#   reading files    anywhere except other teammates' worktrees, teamctl's state, the
#                    memory folders of team memory (~/.wolfmux/memory, lib/memory.sh) and the
#                    leads' conversations (Claude Code's folder for the project, all of it
#                    but its shared memory/), compared without regard to letter case
#   shell commands   refused when they name another worktree, write into a checkout the
#                    worker may only read, move or delete branches, switch to another
#                    branch, touch git worktrees, push to main, or drive tmux; and when a
#                    tool that walks a tree (grep -r, rg, find, ls -R, du, tar) is pointed
#                    at a folder that holds the memory folders or the leads' conversations
#
# Two checkouts are read-only for a worker: the lead's (the project, WOLFMUX_ROOT) and,
# for a teammate spawned with --repo, the main checkout of the repository its worktree
# belongs to (WOLFMUX_REPO). Its own worktree is neither of those.
#
# What it is: a guard against mistakes and role confusion, precise for the file tools,
# a set of heuristics for the shell. What it is not: a sandbox. Every agent is your
# macOS user; a process that sets out to get around it can. The lead is not guarded:
# reviewing and merging the teammates' work is its job.
# Policy: `teamctl policy worker-isolation on|off` (default on). Fails open: if the
# guard cannot tell where the worker belongs, it allows, because it must never be the
# reason an agent stops working.

# guard_abspath <path> <cwd> — absolute, without "/./", symlinks of the existing part resolved, in the
# letter case the disk has: /bin/pwd -P asks the file system, where bash's own pwd -P keeps
# ~/.WOLFMUX/MEMORY as it was typed, and the disk is case-insensitive
guard_abspath() {
  local path="$1" cwd="$2" dir rest=""
  case "$path" in
    /*) ;;
    "~") path="$HOME" ;;
    "~/"*) path="$HOME/${path#\~/}" ;;
    *) path="$cwd/$path" ;;
  esac
  path="$(guard_squeeze "$path")"
  dir="$path"
  while [ ! -d "$dir" ] && [ "$dir" != "/" ] && [ -n "$dir" ]; do
    rest="/$(basename "$dir")$rest"
    dir="$(dirname "$dir")"
  done
  dir="$(cd "$dir" 2>/dev/null && /bin/pwd -P)" || dir="/"
  printf '%s%s\n' "${dir%/}" "$rest"
}

# guard_inside <path> <directory>
guard_inside() {
  case "$1/" in "$2"/*) return 0 ;; esac
  return 1
}

# guard_lower <text> — in lower case (ASCII). The memory, state, worktree and conversation folders are
# compared in lower case: on a case-insensitive disk ~/.WOLFMUX/Memory IS ~/.wolfmux/memory.
guard_lower() { printf '%s' "$1" | LC_ALL=C /usr/bin/tr '[:upper:]' '[:lower:]'; }

# guard_transcript <lower-case path> — inside the folder of the leads' conversations, and not in the
# project's shared memory/ there (which every session may read: lib/memory.sh)
guard_transcript() {
  [ -n "$GUARD_TRANSCRIPTS_LC" ] && guard_inside "$1" "$GUARD_TRANSCRIPTS_LC" && ! guard_inside "$1" "$GUARD_TRANSCRIPTS_LC/memory"
}

# guard_holds_private <lower-case path> — the path is a folder that holds a memory folder or the leads'
# conversations (~, ~/.wolfmux, ~/.claude): a search of it reads them too
guard_holds_private() {
  [ "$1" != "/" ] || return 0
  guard_inside "$GUARD_MEMORY_LC" "$1" && return 0
  [ -n "$GUARD_TRANSCRIPTS_LC" ] && guard_inside "$GUARD_TRANSCRIPTS_LC" "$1"
}

# guard_glob_root <absolute glob pattern> — the folder it searches: everything before the first part
# with a wildcard in it (/a/b/**/*.md is a search of /a/b)
guard_glob_root() {
  local root
  root="$(printf '%s' "$1" | sed -E 's#/[^/]*[][*?{}].*$##')"
  printf '%s\n' "${root:-/}"
}

guard_deny() {
  "$JQ_BIN" -cn --arg reason "Wolfmux: $1 You are '${TEAM_ROLE:-}' and work only in your own worktree ($GUARD_OWN) on your own branch. If something outside it has to change, ask your lead: bd create \"<what and why>\" -t message -a $(team_identity "${WOLFMUX_TEAM:-$WOLFMUX_DEFAULT_TEAM}" "$WOLFMUX_LEAD_ROLE")" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  return 0
}

# guard_squeeze <text> — "//" becomes "/" (not after a colon: URLs stay intact), and "/./" becomes "/"
guard_squeeze() { printf '%s' "$1" | sed -E -e 's#([^:/])/{2,}#\1/#g' -e ':a' -e 's#/\./#/#g' -e 'ta' -e 's#(.)/\.$#\1#'; }

# guard_tokenize <command> <token> <path>... — replace every spelling of the paths
guard_tokenize() {
  local c="$1" token="$2" path spelling
  shift 2
  for path in "$@"; do
    [ -n "$path" ] || continue
    path="$(guard_squeeze "${path%/}")"
    for spelling in "$path" "${path#/private}"; do
      if [ -n "$spelling" ] && [ "$spelling" != "/" ]; then c="${c//"$spelling"/$token}"; fi
    done
  done
  printf '%s' "$c"
}

# guard_strip_prose <tokenized command> — words are not commands. A commit message or a
# Beads description may say "tmux" or "git checkout main" or name the lead's checkout;
# only what the shell would run counts. Heredoc bodies go, then quoted text goes, unless
# it looks like a path (starts with one of our tokens, /, ~, ./ or ../): `cd "/some dir"`
# is still a cd. <joiner> (default a space) is what the lines are joined with: ";" keeps
# one command per line apart for guard_tree_walk.
guard_strip_prose() {
  local mark=$'\001' joiner="${2:- }"
  printf '%s\n' "$1" |
    awk '
      skipping { if ($0 ~ "^[[:space:]]*" marker "[[:space:]]*[)\"]*[[:space:]]*$") skipping = 0; next }
      { print }
      match($0, /<<-?[[:space:]]*["\047\\]?[A-Za-z_][A-Za-z0-9_]*/) {
        marker = substr($0, RSTART, RLENGTH); sub(/^<<-?[[:space:]]*["\047\\]?/, "", marker); skipping = 1
      }' |
    tr '\n' "$joiner" |
    sed -E \
      -e 's/"((@[A-Z]+@|~|\.{0,2}\/)[^"]*)"/'"$mark"'\1'"$mark"'/g' \
      -e "s/'((@[A-Z]+@|~|\.{0,2}\/)[^']*)'/$mark\\1$mark/g" \
      -e 's/"[^"]*"/ /g' \
      -e "s/'[^']*'/ /g" \
      -e "s/$mark/\"/g"
}

# guard_home <command> — ~ and $HOME (also ${HOME}) spelled out as the home directory, so that
# ~/.wolfmux/state and "$HOME/.wolfmux/memory" are the paths the tokens below look for. Only a ~
# that starts a word, as the shell expands it (and a quoted one too: refusing more is the safe side).
guard_home() {
  local c="$1" h="${HOME%/}"
  [ -n "$h" ] || {
    printf '%s' "$c"
    return 0
  }
  c="${c//\$\{HOME\}/$h}"
  c="${c//\$HOME/$h}"
  printf '%s' "$c" | LC_ALL=C /usr/bin/awk -v h="$h" '
    { out = ""; line = $0
      while (match(line, /(^|[[:space:]=:;&|(<>"\047`])~(\/|[[:space:];&|)"\047`]|$)/)) {
        lead = substr(line, RSTART, 1); if (RSTART == 1 && substr(line, 1, 1) == "~") lead = ""
        out = out substr(line, 1, RSTART - 1) lead h
        line = substr(line, RSTART + length(lead) + 1)
      }
      print out line }'
}

# guard_tree_walk <command, ~ and $HOME spelled out> — prints a reason when a tool that walks a whole tree
# (grep -r, rg, find, ls -R, du, tar) is given a folder that holds a memory folder or the leads'
# conversations: `grep -r x ~` reads ~/.wolfmux/memory as surely as a cat of it does. Only absolute
# arguments are seen; prose (quoted text, heredoc bodies) is not a command (guard_strip_prose).
guard_tree_walk() {
  local line i n tool word lw walks
  local -a words
  GUARD_WALK_AT=""
  while IFS= read -r line; do
    words=()
    read -r -a words <<<"$line" || true
    n="${#words[@]}"
    i=0
    # past assignments and the words that only run the next one (sudo grep, env X=1 find, time du)
    while [ "$i" -lt "$n" ]; do
      case "${words[$i]}" in
        *=* | sudo | command | env | time | nice | nohup | exec | builtin | xargs) i=$((i + 1)) ;;
        *) break ;;
      esac
    done
    [ "$i" -lt "$n" ] || continue
    tool="$(basename -- "${words[$i]}" 2>/dev/null || true)"
    walks=0
    case "$tool" in
      rg | find | du | tar | gtar | bsdtar) walks=1 ;;
      grep | egrep | fgrep | ls) ;;
      *) continue ;;
    esac
    i=$((i + 1))
    while [ "$i" -lt "$n" ]; do
      word="${words[$i]}"
      word="${word//\"/}"
      word="${word//\'/}"
      i=$((i + 1))
      case "$tool:$word" in
        ls:--recursive | ls:-*R* | *grep:--recursive | *grep:--dereference-recursive | *grep:--directories=recurse | *grep:-[rR]* | *grep:-[!-]*[rR]*) walks=1 ;;
      esac
      case "$word" in /*) ;; *) continue ;; esac
      while [ "${#word}" -gt 1 ] && [ "${word%/}" != "$word" ]; do word="${word%/}"; done
      lw="$(guard_lower "$word")"
      if guard_holds_private "$lw"; then
        GUARD_WALK_AT="$word"
      fi
    done
    if [ "$walks" -eq 1 ] && [ -n "${GUARD_WALK_AT:-}" ]; then
      printf "%s walks all of %s, which holds the leads' private memory folders (~/.wolfmux/memory) or their conversations; search a narrower folder." "$tool" "$GUARD_WALK_AT"
      return 0
    fi
    GUARD_WALK_AT=""
  done < <(guard_strip_prose "$1" ";" | LC_ALL=C /usr/bin/tr ';|&()`' '\n\n\n\n\n\n' && printf '\n')
  return 0
}

# guard_shell <command> — prints a reason when the command reaches outside
guard_shell() {
  local c lc word
  # Literal paths become tokens first, so no path can confuse a pattern below. A path can
  # be written in more than one way (as configured, with symlinks resolved, /private/tmp
  # as /tmp, doubled slashes, "/./", ~ or $HOME for the home directory), so every spelling we know
  # of is replaced. What stays out of reach: a relative path after a cd (cd ~/.wolfmux &&
  # cat memory/…), a path built at run time, code in a string (python3 -c "…") — the guard
  # reads text, not what the shell will resolve (docs/SECURITY.md).
  c="$(guard_squeeze "$(guard_home "$1")")"
  # Other teammates' worktrees, teamctl's state, the memory folders and the leads' conversations, in
  # lower case (the disk does not tell ~/.WOLFMUX/MEMORY from ~/.wolfmux/memory), and after the prose
  # is gone: a commit message or a heredoc may SAY .wolfmux/memory, a command may not name it.
  lc="$(guard_lower "$c")"
  lc="$(guard_tokenize "$lc" @OWN@ "$(guard_lower "$GUARD_OWN")" "$(guard_lower "${WOLFMUX_WORKTREE:-}")")"
  lc="$(guard_tokenize "$lc" @TREES@ "$GUARD_TREES_LC" "$(guard_lower "$WOLFMUX_DATA/worktrees")")"
  lc="$(guard_tokenize "$lc" @STATE@ "$GUARD_STATE_LC" "$(guard_lower "$WOLFMUX_DATA/state")")"
  lc="$(guard_tokenize "$lc" @MEMORY@ "$GUARD_MEMORY_LC" "$(guard_lower "$WOLFMUX_DATA/memory")")"
  lc="$(guard_tokenize "$lc" @TRANSCRIPTS@ "$GUARD_TRANSCRIPTS_LC" "$(guard_lower "$GUARD_TRANSCRIPTS_AS")")"
  lc="$(guard_strip_prose "$lc")"
  case "$lc" in
    *@TREES@* | *@STATE@*) printf "that command names another teammate's worktree or teamctl's state." && return 0 ;;
    *@MEMORY@* | *.wolfmux/memory*) printf "that command names a lead's private memory folder (~/.wolfmux/memory), which no worker reads." && return 0 ;;
  esac
  case "$(printf '%s' "$lc" | sed -E 's#@TRANSCRIPTS@/memory([^a-z0-9_.-]|$)#\1#g')" in
    *@TRANSCRIPTS@*) printf "that command names the folder of the leads' conversations (%s); only its memory/ is shared." "$GUARD_TRANSCRIPTS" && return 0 ;;
  esac
  word="$(guard_tree_walk "$c")"
  if [ -n "$word" ]; then printf '%s' "$word" && return 0; fi
  c="$(guard_tokenize "$c" @OWN@ "$GUARD_OWN" "${WOLFMUX_WORKTREE:-}")"
  c="$(guard_tokenize "$c" @TREES@ "$GUARD_TREES" "$WOLFMUX_DATA/worktrees")"
  c="$(guard_tokenize "$c" @STATE@ "$GUARD_STATE" "$WOLFMUX_DATA/state")"
  c="$(guard_tokenize "$c" @MEMORY@ "$GUARD_MEMORY" "$WOLFMUX_DATA/memory")"
  c="$(guard_tokenize "$c" @ROOT@ "$GUARD_ROOT" "${WOLFMUX_ROOT:-}" "$GUARD_REPO")"
  c="$(guard_strip_prose "$c")"
  local edge='(^|[;&|(){}[:space:]])' git='git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-][^[:space:]]*)?)*[[:space:]]+'

  if printf '%s' "$c" | grep -Eq "${edge}tmux([[:space:]]|\$)"; then
    printf 'tmux belongs to teamctl; panes of other agents are not yours to read or type into.' && return 0
  fi
  if printf '%s' "$c" | grep -Eq "${edge}${git}worktree[[:space:]]+(add|remove|move|prune|repair|lock|unlock)"; then
    printf 'git worktrees are created and removed by teamctl only.' && return 0
  fi
  if printf '%s' "$c" | grep -Eq "${edge}${git}(branch[[:space:]]+(-[dDmMcCf]|--delete|--move|--copy|--force)|update-ref([[:space:]]|\$))"; then
    printf 'moving, renaming or deleting branches is the lead'"'"'s business.' && return 0
  fi
  if printf '%s' "$c" | grep -Eq "${edge}${git}switch([[:space:]]|\$)" ||
    printf '%s' "$c" | grep -Eq "${edge}${git}checkout[[:space:]]+(-b|-B|--orphan|--detach)([[:space:]]|\$)"; then
    printf 'stay on your own branch (%s); do not switch or create branches in this worktree.' "$GUARD_BRANCH" && return 0
  fi
  # `git checkout <name>`: only a problem when <name> is another local branch
  word="$(printf '%s' "$c" | sed -nE "s/.*${edge}${git}checkout[[:space:]]+([^-[:space:]][^[:space:];&|]*).*/\\4/p" | head -1)"
  if [ -n "$word" ] && [ "$word" != "$GUARD_BRANCH" ] && [ -n "$GIT_BIN" ] &&
    "$GIT_BIN" -C "$GUARD_OWN" show-ref --verify -q "refs/heads/$word" 2>/dev/null; then
    printf 'stay on your own branch (%s); "%s" is another branch.' "$GUARD_BRANCH" "$word" && return 0
  fi
  if printf '%s' "$c" | grep -Eq "${edge}${git}push([[:space:]]|\$)" &&
    printf '%s' "$c" | grep -Eq '(--all|--mirror|--delete|[[:space:]]-d[[:space:]]|:(main|master)([[:space:]]|$)|[[:space:]](main|master)([[:space:]]|$)|[[:space:]]\+[^[:space:]]+)'; then
    printf 'pushing to main, deleting or force-updating remote branches is for the lead.' && return 0
  fi
  case "$c" in
    *@ROOT@*)
      if printf '%s' "$c" | grep -Eq "${edge}(cd|pushd)[[:space:]]+[\"']?@ROOT@" ||
        printf '%s' "$c" | grep -Eq "(-C|--git-dir|--work-tree)[[:space:]=]*[\"']?@ROOT@" ||
        printf '%s' "$c" | grep -Eq ">[>|]?[[:space:]]*[\"']?@ROOT@" ||
        printf '%s' "$c" | grep -Eq "${edge}(rm|mv|rmdir|chmod|chown|ln|truncate|dd|tee|install|sed[[:space:]]+-[a-zA-Z]*i[^[:space:];&|]*|perl[[:space:]]+-[a-zA-Z]*i[^[:space:];&|]*)[[:space:]][^;&|]*@ROOT@" ||
        printf '%s' "$c" | grep -Eq "${edge}(cp|rsync|ditto)[[:space:]][^;&|]*@ROOT@[^[:space:];&|]*[\"']?[[:space:]]*(\$|[;&|])"; then
        printf 'that command would change a checkout that is read-only for you (%s). Your work belongs in your own worktree.' "$GUARD_READONLY" && return 0
      fi
      ;;
  esac
  return 0
}

# cmd_guard — internal (`teamctl _guard`): PreToolUse hook of a worker, JSON on stdin
cmd_guard() {
  local input tool cwd target reason path lpath allowed pattern
  input="$(/bin/cat 2>/dev/null || true)"
  [ -n "$JQ_BIN" ] && [ -n "$input" ] || return 0
  [ -n "${TEAM_ROLE:-}" ] && [ "$TEAM_ROLE" != "$WOLFMUX_LEAD_ROLE" ] || return 0
  [ -n "${WOLFMUX_WORKTREE:-}" ] && [ -d "$WOLFMUX_WORKTREE" ] || return 0 # cannot tell: allow
  GUARD_OWN="$(cd "$WOLFMUX_WORKTREE" && /bin/pwd -P)" || return 0
  GUARD_TREES="$(guard_abspath "$WOLFMUX_DATA/worktrees" /)"
  GUARD_STATE="$(guard_abspath "$WOLFMUX_DATA/state" /)"
  GUARD_MEMORY="$(guard_abspath "$WOLFMUX_DATA/memory" /)"
  GUARD_ROOT=""
  if [ -n "${WOLFMUX_ROOT:-}" ] && [ -d "$WOLFMUX_ROOT" ]; then GUARD_ROOT="$(cd "$WOLFMUX_ROOT" && /bin/pwd -P)"; fi
  # Every lead runs in the project's own folder, so Claude Code keeps every lead's conversation in ONE
  # folder named after it (transcripts_dir): a worker never needs them, and the memory team's lead
  # reads its private memory there (mem boot prints the card). Its memory/ is the project's shared
  # memory, which every session may read.
  GUARD_TRANSCRIPTS="" GUARD_TRANSCRIPTS_AS=""
  if [ -n "$GUARD_ROOT" ]; then
    GUARD_TRANSCRIPTS_AS="$(transcripts_dir "$GUARD_ROOT" 2>/dev/null || true)"
    if [ -n "$GUARD_TRANSCRIPTS_AS" ]; then GUARD_TRANSCRIPTS="$(guard_abspath "$GUARD_TRANSCRIPTS_AS" /)"; fi
  fi
  GUARD_TREES_LC="$(guard_lower "$GUARD_TREES")" GUARD_STATE_LC="$(guard_lower "$GUARD_STATE")"
  GUARD_MEMORY_LC="$(guard_lower "$GUARD_MEMORY")" GUARD_TRANSCRIPTS_LC="$(guard_lower "$GUARD_TRANSCRIPTS")"
  # A teammate spawned with --repo has its worktree in another repository: that repository's
  # own checkout is read-only for it, exactly as the lead's is.
  GUARD_REPO=""
  if [ -n "${WOLFMUX_REPO:-}" ] && [ -d "$WOLFMUX_REPO" ]; then GUARD_REPO="$(cd "$WOLFMUX_REPO" && /bin/pwd -P)"; fi
  if [ "$GUARD_REPO" = "$GUARD_ROOT" ]; then GUARD_REPO=""; fi
  GUARD_READONLY="$GUARD_ROOT"
  if [ -n "$GUARD_REPO" ]; then GUARD_READONLY="$GUARD_ROOT and $GUARD_REPO"; fi
  GUARD_BRANCH="${WOLFMUX_BRANCH:-}"

  tool="$(printf '%s' "$input" | "$JQ_BIN" -r '.tool_name // ""' 2>/dev/null || true)"
  cwd="$(printf '%s' "$input" | "$JQ_BIN" -r '.cwd // ""' 2>/dev/null || true)"
  [ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$GUARD_OWN"
  case "$tool" in
    Edit | Write | MultiEdit | NotebookEdit)
      target="$(printf '%s' "$input" | "$JQ_BIN" -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null || true)"
      [ -n "$target" ] || return 0
      path="$(guard_abspath "$target" "$cwd")"
      lpath="$(guard_lower "$path")"
      case "$path" in */../* | */..) guard_deny "'$target' does not resolve to a plain path." && return 0 ;; esac
      if guard_inside "$path" "$GUARD_OWN"; then return 0; fi
      if guard_inside "$lpath" "$GUARD_TREES_LC" || guard_inside "$lpath" "$GUARD_STATE_LC"; then
        guard_deny "'$target' belongs to another teammate or to teamctl." && return 0
      fi
      if guard_inside "$lpath" "$GUARD_MEMORY_LC"; then
        guard_deny "'$target' is in a lead's private memory folder; no worker writes there." && return 0
      fi
      if guard_transcript "$lpath"; then
        guard_deny "'$target' is in the folder of the leads' conversations; no worker writes there." && return 0
      fi
      if [ -n "$GUARD_ROOT" ] && guard_inside "$path" "$GUARD_ROOT"; then
        guard_deny "'$target' is in the lead's checkout, which is read-only for you." && return 0
      fi
      if [ -n "$GUARD_REPO" ] && guard_inside "$path" "$GUARD_REPO"; then
        guard_deny "'$target' is in the main checkout of $GUARD_REPO. Your worktree of that repository is where your work goes; the checkout itself is read-only for you." && return 0
      fi
      for allowed in /private/tmp /tmp /private/var/folders /var/folders "$HOME/.claude"; do
        if guard_inside "$path" "$allowed"; then return 0; fi
      done
      guard_deny "'$target' is outside your worktree, so you may not change it."
      ;;
    Read | Grep | Glob | LS)
      target="$(printf '%s' "$input" | "$JQ_BIN" -r '.tool_input.file_path // .tool_input.path // ""' 2>/dev/null || true)"
      # Glob takes an absolute pattern without a path: /a/b/**/*.md searches /a/b
      if [ "$tool" = "Glob" ]; then
        pattern="$(printf '%s' "$input" | "$JQ_BIN" -r '.tool_input.pattern // ""' 2>/dev/null || true)"
        case "$pattern" in /* | "~" | "~/"*) target="$(guard_glob_root "$pattern")" ;; esac
      fi
      [ -n "$target" ] || return 0
      path="$(guard_abspath "$target" "$cwd")"
      lpath="$(guard_lower "$path")"
      case "$path" in */../* | */..) guard_deny "'$target' does not resolve to a plain path." && return 0 ;; esac
      if guard_inside "$path" "$GUARD_OWN"; then return 0; fi
      if guard_inside "$lpath" "$GUARD_TREES_LC" || guard_inside "$lpath" "$GUARD_STATE_LC"; then
        guard_deny "'$target' is another teammate's worktree or teamctl's state; their work in progress is not yours to read."
      elif guard_inside "$lpath" "$GUARD_MEMORY_LC"; then
        guard_deny "'$target' is in a lead's private memory folder (~/.wolfmux/memory), which no worker reads."
      elif guard_transcript "$lpath"; then
        guard_deny "'$target' is in the folder of the leads' conversations, which no worker reads (its memory/ is shared: that one you may read)."
      elif [ "$tool" = "Grep" ] || [ "$tool" = "Glob" ] && guard_holds_private "$lpath"; then
        # A search of a folder that holds them (~/.wolfmux, ~/.claude, your home) would read them too.
        guard_deny "a search of '$target' would reach into the private memory folders (~/.wolfmux/memory) or the leads' conversations under it; search a narrower folder."
      fi
      ;;
    mcp__*)
      # An MCP tool's input has no fixed shape: every string that is an absolute path counts.
      # Another teammate's worktree, teamctl's state, the memory folders and the leads' conversations
      # are off limits for any of them; the lead's checkout only for a tool whose name says it changes things.
      while IFS= read -r target; do
        case "$target" in /* | "~"/*) ;; *) continue ;; esac
        path="$(guard_abspath "$target" "$cwd")"
        lpath="$(guard_lower "$path")"
        if guard_inside "$path" "$GUARD_OWN"; then continue; fi
        if guard_inside "$lpath" "$GUARD_TREES_LC" || guard_inside "$lpath" "$GUARD_STATE_LC"; then
          guard_deny "'$target' is another teammate's worktree or teamctl's state." && return 0
        fi
        if guard_inside "$lpath" "$GUARD_MEMORY_LC"; then
          guard_deny "'$target' is in a lead's private memory folder." && return 0
        fi
        if guard_transcript "$lpath"; then
          guard_deny "'$target' is in the folder of the leads' conversations." && return 0
        fi
        if { { [ -n "$GUARD_ROOT" ] && guard_inside "$path" "$GUARD_ROOT"; } ||
          { [ -n "$GUARD_REPO" ] && guard_inside "$path" "$GUARD_REPO"; }; } &&
          printf '%s' "$tool" | grep -Eiq '(write|edit|create|delete|remove|move|rename|patch|apply|append|insert|replace|mkdir|upload|save)'; then
          guard_deny "'$target' is in a checkout that is read-only for you ($GUARD_READONLY)." && return 0
        fi
      done < <(printf '%s' "$input" | "$JQ_BIN" -r '.tool_input | [.. | strings] | .[]' 2>/dev/null | head -100)
      ;;
    Bash)
      target="$(printf '%s' "$input" | "$JQ_BIN" -r '.tool_input.command // ""' 2>/dev/null || true)"
      [ -n "$target" ] || return 0
      reason="$(guard_shell "$target" 2>/dev/null || true)"
      if [ -n "$reason" ]; then guard_deny "$reason"; fi
      ;;
  esac
  return 0
}
