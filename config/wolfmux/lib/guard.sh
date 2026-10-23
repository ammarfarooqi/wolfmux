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
#                    at a folder that holds the memory folders or the leads' conversations;
#                    a relative path counts where the shell would be, after its cd (guard_follow)
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
  local private
  [ "$1" != "/" ] || return 0
  guard_inside "$GUARD_MEMORY_LC" "$1" && return 0
  for private in ${GUARD_CLAUDE_LC[@]+"${GUARD_CLAUDE_LC[@]}"}; do
    guard_inside "$private" "$1" && return 0
  done
  [ -n "$GUARD_TRANSCRIPTS_LC" ] && guard_inside "$GUARD_TRANSCRIPTS_LC" "$1"
}

# guard_claude_private <lower-case path> — inside one of Claude Code's own records of sessions outside any project:
# file-history/ (the copy of every file a session changed with Edit or Write, from before the change), todos/ and
# paste-cache/, under ~/.claude and under CLAUDE_CONFIG_DIR. Any session's, a lead's included: no worker reads them.
guard_claude_private() {
  local private
  for private in ${GUARD_CLAUDE_LC[@]+"${GUARD_CLAUDE_LC[@]}"}; do
    guard_inside "$1" "$private" && return 0
  done
  return 1
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

# guard_squeeze <text> — "//" becomes "/" (not after a colon: URLs stay intact), "/./" becomes "/", and a
# word that ends in "/." loses it, mid-line too (`grep -r x ~/. | head`): "/." alone is "/"
guard_squeeze() {
  printf '%s' "$1" | sed -E -e 's#([^:/])/{2,}#\1/#g' -e ':a' -e 's#/\./#/#g' -e 'ta' \
    -e 's#(^|[[:space:]=])/\.([[:space:];&|)]|$)#\1/\2#g' -e 's#([^[:space:]=])/\.([[:space:];&|)]|$)#\1\2#g'
}

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
# is still a cd. A quoted word with no space in it that holds .wolfmux/memory is a path
# too (`cat "x/.wolfmux/memory/y"`); a sentence that mentions the folder is not.
# <joiner> (default a space) is what the lines are joined with: ";" keeps
# one command per line apart for guard_tree_walk. A line that ends in a "\" goes on in the next one, as
# in the shell. Quoted prose leaves an empty word ("") where it was, so that `grep -rn "TODO" ~` still
# has a pattern in front of its folder (guard_tree_walk).
guard_strip_prose() {
  local mark=$'\001' joiner="${2:- }"
  local -a words=()
  # <words> (any third argument): a quoted string with no space in it stays too, for guard_follow
  if [ -n "${3:-}" ]; then words=(-e 's/"([^"[:space:]]+)"/'"$mark"'\1'"$mark"'/g' -e "s/'([^'[:space:]]+)'/$mark\\1$mark/g"); fi
  printf '%s\n' "$1" |
    awk '
      skipping { if ($0 ~ "^[[:space:]]*" marker "[[:space:]]*[)\"]*[[:space:]]*$") skipping = 0; next }
      { if (match($0, /\\+$/) && RLENGTH % 2 == 1) printf "%s ", substr($0, 1, length($0) - 1); else print }
      match($0, /<<-?[[:space:]]*["\047\\]?[A-Za-z_][A-Za-z0-9_]*/) {
        marker = substr($0, RSTART, RLENGTH); sub(/^<<-?[[:space:]]*["\047\\]?/, "", marker); skipping = 1
      }' |
    tr '\n' "$joiner" |
    sed -E \
      -e 's/"((@[A-Z]+@|~|\.{0,2}\/)[^"]*)"/'"$mark"'\1'"$mark"'/g' \
      -e "s/'((@[A-Z]+@|~|\.{0,2}\/)[^']*)'/$mark\\1$mark/g" \
      -e 's/"([^"[:space:]]*\.wolfmux\/memory[^"[:space:]]*)"/'"$mark"'\1'"$mark"'/g' \
      -e "s/'([^'[:space:]]*\\.wolfmux\\/memory[^'[:space:]]*)'/$mark\\1$mark/g" \
      ${words[@]+"${words[@]}"} \
      -e 's/"[^"]*"/""/g' \
      -e "s/'[^']*'/\"\"/g" \
      -e "s/$mark/\"/g"
}

# guard_inner_commands <command> — the command text that a shell or eval in it runs, one per line (its own newlines
# as \001): the word after sh|bash|zsh|dash|ksh -c (also -lc, -ic, -ec …) or after <<<, the body of a heredoc fed to
# one, and all that eval is given. guard_strip_prose would drop it as quoted prose; guard_shell checks it as a command.
guard_inner_commands() {
  printf '%s\n' "$1" | LC_ALL=C /usr/bin/awk '
    # one shell word from s at p, unquoted as the shell would (double, single and ANSI-C quotes, \x); p ends after it
    function word(   out, ch, q, c2) {
      out = ""
      while (p <= n) {
        ch = substr(s, p, 1)
        if (ch ~ /[ \t\n;&|()<>]/) break
        if (ch == "\047") {
          q = index(substr(s, p + 1), "\047")
          if (q == 0) { out = out substr(s, p + 1); p = n + 1; break }
          out = out substr(s, p + 1, q - 1); p += q + 1; continue
        }
        if (ch == "$" && substr(s, p + 1, 1) == "\047") {
          for (p += 2; p <= n; p++) {
            ch = substr(s, p, 1)
            if (ch == "\\" && p < n) { c2 = substr(s, ++p, 1); out = out (c2 == "n" ? "\n" : (c2 == "t" ? "\t" : c2)); continue }
            if (ch == "\047") { p++; break }
            out = out ch
          }
          continue
        }
        if (ch == "\"") {
          for (p++; p <= n; p++) {
            ch = substr(s, p, 1)
            if (ch == "\\" && p < n && index("\\\"$`\n", substr(s, p + 1, 1))) { out = out substr(s, ++p, 1); continue }
            if (ch == "\"") { p++; break }
            out = out ch
          }
          continue
        }
        if (ch == "\\" && p < n) { c2 = substr(s, p + 1, 1); if (c2 != "\n") out = out c2; p += 2; continue }
        out = out ch; p++
      }
      return out
    }
    function emit(text) { if (text != "") { gsub(/\n/, "\001", text); print text } }
    { s = s (NR > 1 ? "\n" : "") $0 }
    END {
      n = length(s); p = 1
      shell = "(^|[^A-Za-z0-9_.-])[\"\047]?([^[:space:];&|()<>\"\047`]*/)?(ba|z|da|k|fi|tc|c)?sh[\"\047]?"
      opts = "([ \t]+-[-A-Za-z]+([ \t]+[a-z]+)?)*"
      kinds = 4
      re[1] = shell opts "[ \t]+-[A-Za-z]*c[A-Za-z]*[ \t]+"
      re[2] = shell opts "[ \t]*<<<[ \t]*"
      re[3] = shell opts "[ \t]*<<-?[ \t]*[\"\047\\\\]?[A-Za-z_][A-Za-z0-9_]*[\"\047]?"
      re[4] = "(^|[^A-Za-z0-9_.-])eval[ \t]+"
      while (p <= n) {
        rest = substr(s, p); best = 0; at = 0
        for (k = 1; k <= kinds; k++) if (match(rest, re[k]) && (best == 0 || RSTART < at)) { best = k; at = RSTART; len = RLENGTH }
        if (best == 0) break
        p += at - 1 + len
        if (best <= 2) { emit(word()); continue }
        if (best == 4) {
          out = ""
          while (p <= n) {
            while (p <= n && substr(s, p, 1) ~ /[ \t]/) p++
            if (p > n || substr(s, p, 1) ~ /[\n;&|()<>]/) break
            w = word(); out = out (out == "" ? "" : " ") w
          }
          emit(out); continue
        }
        # a heredoc: its marker, then the lines up to the one that is only the marker
        marker = substr(rest, at, len); sub(/^.*<<-?[ \t]*["\047\\]?/, "", marker); sub(/["\047]$/, "", marker)
        nl = index(substr(s, p), "\n"); if (nl == 0) break
        p += nl; body = ""
        while (p <= n) {
          nl = index(substr(s, p), "\n"); line = nl ? substr(s, p, nl - 1) : substr(s, p)
          p += nl ? nl : n
          probe = line; sub(/^\t+/, "", probe)
          if (probe == marker) break
          body = body (body == "" ? "" : "\n") line
        }
        emit(body)
      }
    }'
}

# guard_home <command> — ~ and $HOME (also ${HOME}) spelled out as the home directory, so that
# ~/.wolfmux/state and "$HOME/.wolfmux/memory" are the paths the tokens below look for. Only a ~
# that starts a word, as the shell expands it (and a quoted one too: refusing more is the safe side).
# ~<name> is that user's home: yours for your own name, /Users/<name> for another; ~+ is the folder the
# command runs in (GUARD_CWD).
guard_home() {
  local c="$1" h="${HOME%/}"
  [ -n "$h" ] || {
    printf '%s' "$c"
    return 0
  }
  c="${c//\$\{HOME\}/$h}"
  c="${c//\$HOME/$h}"
  printf '%s' "$c" | LC_ALL=C /usr/bin/awk -v h="$h" -v me="${USER:-}" -v here="${GUARD_CWD:-.}" '
    { out = ""; line = $0
      while (match(line, /(^|[[:space:]=:;&|(<>"\047`])~([A-Za-z_][A-Za-z0-9._-]*|\+)?(\/|[[:space:];&|)"\047`]|$)/)) {
        lead = substr(line, RSTART, 1); if (RSTART == 1 && substr(line, 1, 1) == "~") lead = ""
        name = substr(line, RSTART + length(lead) + 1, RLENGTH - length(lead) - 1); sub(/[\/[:space:];&|)"\047`]$/, "", name)
        out = out substr(line, 1, RSTART - 1) lead (name == "" || name == me ? h : (name == "+" ? here : "/Users/" name))
        line = substr(line, RSTART + length(lead) + 1 + length(name))
      }
      print out line }'
}

# guard_resolve_word <word> <cwd> — the path a word names: absolute, its ".." climbed through the disk where the
# folders exist and by the letter past them (guard_abspath leaves a/missing/../.. as it is)
guard_resolve_word() {
  local path
  path="$(guard_abspath "$1" "$2")"
  case "$path" in
    */../* | */..)
      path="$(printf '%s\n' "$path" | LC_ALL=C /usr/bin/awk -F/ '{ n = 0
        for (i = 2; i <= NF; i++) { if ($i == "..") { if (n) n-- } else if ($i != "" && $i != ".") part[++n] = $i }
        out = ""; for (i = 1; i <= n; i++) out = out "/" part[i]; print (out == "" ? "/" : out) }')"
      ;;
  esac
  printf '%s\n' "${path:-/}"
}

# guard_climbs <word> — the word is a path the text does not spell out: one that climbs (a ".." part) or starts
# where the command runs ("." or "./…")
guard_climbs() {
  case "$1" in .. | ../* | */../* | */.. | . | ./*) return 0 ;; esac
  return 1
}

# guard_follow <command, ~ and $HOME spelled out> — reads the command word by word and follows the folder the
# shell is in as cd, pushd and popd move it (a cd inside ( ), $( ), a pipe or & stays there, as in the shell).
# It sets:
#   GUARD_EXTRA     the paths the text does not spell out, absolute: every word that climbs or starts here
#                   (../x, ./x: guard_climbs), resolved against the folder the shell is in at that word, and
#                   while that folder is not your own worktree, every relative word (cd ~/.wolfmux && cat
#                   memory/x); every folder a cd moves to; the part of a wildcard word before the wildcard
#   GUARD_FOLLOWED  the command again, one line, with those words spelled out (for guard_tree_walk)
#   GUARD_HERES     every folder a cd moved to, one per line (what sh -c or eval runs may run there)
#   GUARD_WILD      a reason to refuse: a wildcard that could still become a private folder or is your home
#                   itself (cat ~/.wolfmux/mem*/…, grep -r x ~/.*), or a command too long to follow
# A quoted word with no space in it counts as a word here (cd ~/.wolfmux && cat "memory/x"). Out of reach: a cd
# to a folder built at run time (d=~/.wolfmux; cd $d && cat memory/x) leaves the folder where it was, and so do
# CDPATH and a cd to a wildcard (docs/SECURITY.md).
guard_follow() {
  local line kind tok value raw path pre prefix lp private home outside=0 count=0 resolved=0 redir=0 at=1
  local here="$GUARD_CWD" old="" list pipe piped=0 depth=0 cd="" cdarg="" taken=0
  local wild='[][*?{}]*' # in a variable: bash 3.2 ends ${word%%…} at the first "}" of a literal pattern
  local -a sub_here=() sub_list=() sub_pipe=() sub_piped=() dirs=()
  home="$(guard_lower "${HOME%/}")"
  list="$here" pipe="$here"
  GUARD_EXTRA="" GUARD_FOLLOWED="" GUARD_HERES="" GUARD_WILD=""
  guard_inside "$here" "$GUARD_OWN" || outside=1
  while IFS= read -r line; do
    count=$((count + 1))
    if [ "$count" -gt 4000 ]; then GUARD_WILD="that command is too long for the guard to follow (over 4000 words); split it." && return 0; fi
    kind="${line:0:1}" tok="${line:1}"
    if [ "$kind" = o ]; then
      # a redirection: the next word is a file, and the command goes on
      if [ "$tok" = ">" ]; then redir=1 GUARD_FOLLOWED="$GUARD_FOLLOWED >" && continue; fi
      if [ -n "$cd" ]; then guard_follow_cd; fi
      case "$tok" in
        ";") if [ "$piped" -eq 1 ]; then here="$pipe"; fi && piped=0 list="$here" pipe="$here" ;;
        a) if [ "$piped" -eq 1 ]; then here="$pipe"; fi && piped=0 pipe="$here" ;;
        "|") here="$pipe" piped=1 ;;
        "&") here="$list" piped=0 pipe="$list" ;;
        "(")
          sub_here[$depth]="$here" sub_list[$depth]="$list" sub_pipe[$depth]="$pipe" sub_piped[$depth]="$piped"
          depth=$((depth + 1)) list="$here" pipe="$here" piped=0
          ;;
        ")")
          if [ "$depth" -gt 0 ]; then
            depth=$((depth - 1))
            here="${sub_here[$depth]}" list="${sub_list[$depth]}" pipe="${sub_pipe[$depth]}" piped="${sub_piped[$depth]}"
          fi
          ;;
      esac
      at=1 redir=0 outside=0
      guard_inside "$here" "$GUARD_OWN" || outside=1
      if [ "$tok" = a ]; then tok=";"; fi
      GUARD_FOLLOWED="$GUARD_FOLLOWED $tok"
      continue
    fi
    value="$tok"
    if [ "$redir" -eq 1 ]; then
      redir=0
    elif [ "$at" -eq 1 ]; then
      case "$value" in
        cd | pushd | popd) cd="$value" cdarg="" taken=0 at=0 ;;
        "{" | "!" | if | then | else | elif | while | until | do | time | builtin | command | nohup | exec | [A-Za-z_]*=*) ;;
        *) at=0 ;;
      esac
    elif [ -n "$cd" ] && [ "$taken" -eq 0 ]; then
      case "$value" in
        -) cdarg=- taken=1 ;;
        -- | -[LPe@]*) ;;
        *'$'* | *[][*?{}]*) cdarg="?" taken=1 ;;
        *) cdarg="$value" taken=1 ;;
      esac
    fi
    case "$value" in
      '""' | *'$'*) ;; # quoted prose, or built at run time: out of reach (docs/SECURITY.md)
      *[][*?{}]*)
        raw="${value%%$wild}" prefix="${value%%$wild}"
        if guard_climbs "$prefix"; then
          prefix="$(guard_resolve_word "$prefix" "$here")" resolved=$((resolved + 1))
        elif [ "$outside" -eq 1 ]; then
          case "$prefix" in /* | -*) ;; *) prefix="$here/$prefix" ;; esac
        fi
        case "$prefix" in
          /*)
            value="$prefix${value#"$raw"}"
            GUARD_EXTRA="$GUARD_EXTRA $prefix"
            lp="$(guard_lower "$prefix")"
            lp="${lp%/}"
            if [ "$lp" = "$home" ]; then
              GUARD_WILD="$(printf "that command has a wildcard in your home folder (%s), which also matches the leads' private folders under it; name the files." "$tok")" && return 0
            fi
            for private in "$GUARD_MEMORY_LC" "$GUARD_STATE_LC" "$GUARD_TREES_LC" "$GUARD_TRANSCRIPTS_LC" ${GUARD_CLAUDE_LC[@]+"${GUARD_CLAUDE_LC[@]}"}; do
              [ -n "$private" ] || continue
              case "$private/" in "$lp"*) GUARD_WILD="$(printf "that command has a wildcard (%s) that can match a private folder (%s); name the files." "$tok" "$private")" && return 0 ;; esac
            done
            ;;
        esac
        ;;
      *)
        # --file=../x and X=../x name ../x
        path="$value" pre=""
        case "$path" in -*=* | [A-Za-z_]*=*) pre="${path%%=*}=" path="${path#*=}" ;; esac
        if guard_climbs "$path"; then
          path="$(guard_resolve_word "$path" "$here")" resolved=$((resolved + 1))
          GUARD_EXTRA="$GUARD_EXTRA $path" value="$pre$path"
        elif [ "$outside" -eq 1 ]; then
          case "$path" in "" | /* | -*) ;; *) GUARD_EXTRA="$GUARD_EXTRA $here/$path" value="$pre$here/$path" ;; esac
        fi
        ;;
    esac
    if [ "$resolved" -gt 100 ]; then GUARD_WILD="that command has more than 100 relative paths for the guard to follow; split it." && return 0; fi
    GUARD_FOLLOWED="$GUARD_FOLLOWED $value"
  done < <(guard_strip_prose "$1" ";" words | LC_ALL=C /usr/bin/awk '
    # one line per word ("w" and the word, unquoted; "w" "" for quoted prose) and per operator: "o;" (; and the
    # end of a line), "oa" (&& ||), "o|", "o&", "o(" "o)" (also $( and `), "o>" (any redirection)
    function flush() { if (w != "" || q) print "w" (w == "" ? "\"\"" : w); w = ""; q = 0 }
    function op(o) { flush(); print "o" o }
    { s = s (NR > 1 ? ";" : "") $0 }
    END {
      n = length(s); w = ""; q = 0; inq = 0; bt = 0
      for (i = 1; i <= n; i++) {
        ch = substr(s, i, 1)
        if (inq) { if (ch == "\"") inq = 0; else w = w ch; continue }
        if (ch == "\"") { inq = 1; q = 1; continue }
        if (ch == " " || ch == "\t") { flush(); continue }
        two = substr(s, i, 2)
        if (two == "&&" || two == "||") { op("a"); i++; continue }
        if (two == "|&") { op("|"); i++; continue }
        if (two == ">&" || two == "<&" || two == "&>" || two == ">|") { op(">"); i++; if (substr(s, i + 1, 1) == ">") i++; continue }
        if (ch == ">" || ch == "<") { op(">"); continue }
        if (ch == ";" || ch == "|" || ch == "&" || ch == "(" || ch == ")") { op(ch); continue }
        if (ch == "`") { op(bt ? ")" : "("); bt = !bt; continue }
        w = w ch
      }
      flush()
    }')
  if [ -n "$cd" ]; then guard_follow_cd; fi
  GUARD_EXTRA="$(guard_squeeze "$GUARD_EXTRA")"
  return 0
}

# guard_follow_cd — guard_follow's cd, pushd or popd, once its words are read: moves guard_follow's "here" (bash
# functions see their caller's locals). A bare cd goes home, cd - goes back, a run-time folder ("?") stays put.
guard_follow_cd() {
  local to="" n="${#dirs[@]}"
  case "$cd" in
    popd)
      if [ "$n" -gt 0 ]; then to="${dirs[$((n - 1))]}" && unset "dirs[$((n - 1))]"; fi
      ;;
    *)
      case "$cdarg" in
        "") if [ "$cd" = cd ]; then to="$(guard_abspath "$HOME" /)"; fi ;;
        -) to="$old" ;;
        "?") ;;
        *) to="$(guard_resolve_word "$cdarg" "$here")" ;;
      esac
      if [ -n "$to" ] && [ "$cd" = pushd ]; then dirs[$n]="$here"; fi
      ;;
  esac
  cd=""
  [ -n "$to" ] || return 0
  old="$here" here="$to"
  GUARD_EXTRA="$GUARD_EXTRA $to"
  GUARD_HERES="$GUARD_HERES$to"$'\n'
  return 0
}

# guard_tree_walk <command, ~ and $HOME spelled out> — prints a reason when a tool that walks a whole tree
# (grep -r, rg, find, ls -R, du, tar) is given a folder that holds a memory folder or the leads'
# conversations: `grep -r x ~` reads ~/.wolfmux/memory as surely as a cat of it does. Absolute arguments
# are seen, and relative ones that climb or start here (../../.., ., ./x: guard_climbs), resolved against
# GUARD_CWD (guard_shell passes the command as guard_follow spelled it out, in the folder each cd moved
# to: they come absolute); grep's and rg's pattern is not a folder. Prose (quoted text, heredoc bodies) is not a command
# (guard_strip_prose); lines that end in "\" go on in the next one.
guard_tree_walk() {
  local line i j n tool word lw walks takes pattern skip ended
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
    walks=0 takes="" pattern=0 skip=0 ended=0
    case "$tool" in
      rg) walks=1 takes="ABCEMTefgjmrt" pattern=1 ;;
      find | du | tar | gtar | bsdtar) walks=1 ;;
      grep | egrep | fgrep) takes="ABCDdefm" pattern=1 ;;
      ls) ;;
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
      # grep and rg: the first word that is not an option is the PATTERN, not a folder (grep -rn "/Users/" src/),
      # unless -e, -f, --regexp or --file gave the pattern; the argument of an option is neither.
      if [ -n "$takes" ] && [ "$skip" -eq 1 ]; then
        skip=0
        continue
      fi
      if [ -n "$takes" ] && [ "$ended" -eq 0 ]; then
        case "$word" in
          --) ended=1 && continue ;;
          --regexp=* | --file=*) pattern=0 && continue ;;
          --regexp | --file) pattern=0 skip=1 && continue ;;
          --files) pattern=0 && continue ;;
          --type | --type-not | --glob | --iglob | --max-count | --context | --after-context | --before-context | --include | --exclude | --exclude-dir | --max-depth | --threads | --replace) skip=1 && continue ;;
          --*) continue ;;
          -?*)
            j=1
            while [ "$j" -lt "${#word}" ]; do
              case "$takes" in
                *"${word:$j:1}"*)
                  case "${word:$j:1}" in e | f) pattern=0 ;; esac
                  if [ "$j" -eq $((${#word} - 1)) ]; then skip=1; fi
                  break
                  ;;
              esac
              j=$((j + 1))
            done
            continue
            ;;
        esac
      fi
      if [ "$pattern" -eq 1 ]; then
        pattern=0
        continue
      fi
      # a word that climbs (../../..) or starts here (., ./x) is the folder it names
      if guard_climbs "$word"; then word="$(guard_resolve_word "$word" "${GUARD_CWD:-$PWD}")"; fi
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
  local c lc word inner h heres extra followed depth="${2:-0}"
  # Literal paths become tokens first, so no path can confuse a pattern below. A path can
  # be written in more than one way (as configured, with symlinks resolved, /private/tmp
  # as /tmp, doubled slashes, "/./", ~, ~<name> or $HOME for a home directory), so every spelling we know
  # of is replaced. Paths the text does not spell out (../x, ./x, a relative word after cd ~/.wolfmux, a
  # wildcard) are resolved as the shell would, folder by folder (guard_follow). What stays out of reach: a
  # cd to a folder built at run time (d=~/.wolfmux; cd $d && cat memory/…), a path built at run time, code
  # in a string (python3 -c "…") — the guard reads text, not what the shell will resolve (docs/SECURITY.md).
  c="$(guard_squeeze "$(guard_home "$1")")"
  guard_follow "$c"
  if [ -n "$GUARD_WILD" ]; then printf '%s' "$GUARD_WILD" && return 0; fi
  extra="$GUARD_EXTRA" followed="$GUARD_FOLLOWED" heres="$GUARD_HERES"
  # What sh -c, bash -lc, a here-string, a heredoc fed to a shell, or eval will run is a command and
  # not prose, though it is quoted: each is checked as one (guard_inner_commands), three levels deep, in the
  # folder the command starts in and in every folder a cd in it moved to (which one it runs in is not followed).
  while IFS= read -r inner; do
    [ -n "$inner" ] || continue
    if [ "$depth" -ge 3 ]; then printf 'that command nests sh -c or eval more than three levels deep; run the inner command itself.' && return 0; fi
    while IFS= read -r h; do
      word="$(GUARD_CWD="$h" && guard_shell "${inner//$'\001'/$'\n'}" $((depth + 1)))"
      if [ -n "$word" ]; then printf '%s' "$word" && return 0; fi
    done < <(printf '%s\n%s' "$GUARD_CWD" "$heres" | LC_ALL=C /usr/bin/awk 'NF && !seen[$0]++' | /usr/bin/head -5)
  done < <(guard_inner_commands "$1")
  # Other teammates' worktrees, teamctl's state, the memory folders, the leads' conversations and Claude Code's
  # other records, in lower case (the disk does not tell ~/.WOLFMUX/MEMORY from ~/.wolfmux/memory), and after
  # the prose is gone: a commit message or a heredoc may SAY .wolfmux/memory, a command may not name it. The
  # paths resolved above come first, on a line of their own: nothing that follows can turn them into prose.
  lc="$(guard_lower "${extra# }"$'\n'"$c")"
  lc="$(guard_tokenize "$lc" @OWN@ "$(guard_lower "$GUARD_OWN")" "$(guard_lower "${WOLFMUX_WORKTREE:-}")")"
  lc="$(guard_tokenize "$lc" @TREES@ "$GUARD_TREES_LC" "$(guard_lower "$WOLFMUX_DATA/worktrees")")"
  lc="$(guard_tokenize "$lc" @STATE@ "$GUARD_STATE_LC" "$(guard_lower "$WOLFMUX_DATA/state")")"
  lc="$(guard_tokenize "$lc" @MEMORY@ "$GUARD_MEMORY_LC" "$(guard_lower "$WOLFMUX_DATA/memory")")"
  lc="$(guard_tokenize "$lc" @TRANSCRIPTS@ "$GUARD_TRANSCRIPTS_LC" "$(guard_lower "$GUARD_TRANSCRIPTS_AS")")"
  lc="$(guard_tokenize "$lc" @CLAUDE@ ${GUARD_CLAUDE_LC[@]+"${GUARD_CLAUDE_LC[@]}"})"
  lc="$(guard_strip_prose "$lc")"
  case "$lc" in
    *@TREES@* | *@STATE@*) printf "that command names another teammate's worktree or teamctl's state." && return 0 ;;
    *@MEMORY@* | *.wolfmux/memory*) printf "that command names a lead's private memory folder (~/.wolfmux/memory), which no worker reads." && return 0 ;;
    *@CLAUDE@*) printf "that command names Claude Code's own records of sessions (file-history, todos, paste-cache under ~/.claude), which hold copies of other agents' work; no worker reads them." && return 0 ;;
  esac
  case "$(printf '%s' "$lc" | sed -E 's#@TRANSCRIPTS@/memory([^a-z0-9_.-]|$)#\1#g')" in
    *@TRANSCRIPTS@*) printf "that command names the folder of the leads' conversations (%s); only its memory/ is shared." "$GUARD_TRANSCRIPTS" && return 0 ;;
  esac
  # the tree walk reads the command with its relative words spelled out in the folder they are used in
  word="$(guard_tree_walk "$followed")"
  if [ -n "$word" ]; then printf '%s' "$word" && return 0; fi
  c="$(guard_tokenize "$c" @OWN@ "$GUARD_OWN" "${WOLFMUX_WORKTREE:-}")"
  c="$(guard_tokenize "$c" @TREES@ "$GUARD_TREES" "$WOLFMUX_DATA/worktrees")"
  c="$(guard_tokenize "$c" @STATE@ "$GUARD_STATE" "$WOLFMUX_DATA/state")"
  c="$(guard_tokenize "$c" @MEMORY@ "$GUARD_MEMORY" "$WOLFMUX_DATA/memory")"
  c="$(guard_tokenize "$c" @ROOT@ "$GUARD_ROOT" "${WOLFMUX_ROOT:-}" "$GUARD_REPO")"
  # A quoted one-word "tmux" ('tmux', "/opt/homebrew/bin/tmux") is the program, not prose
  c="$(printf '%s' "$c" | sed -E "s#[\"']([^\"'[:space:]]*/)?tmux[\"']# \\1tmux #g")"
  c="$(guard_strip_prose "$c")"
  local edge='(^|[;&|(){}[:space:]])' git='git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-][^[:space:]]*)?)*[[:space:]]+'
  local ids='(TEAM_ROLE|TMUX_PANE|WOLFMUX_TEAM|BEADS_ACTOR)' after='([[:space:];&|)]|$)'

  if printf '%s' "$c" | grep -Eq "(^|[;&|(){}[:space:]/\\])tmux([[:space:]]|\$)"; then
    printf 'tmux belongs to teamctl; panes of other agents are not yours to read or type into.' && return 0
  fi
  # Who may act is decided by the identity this pane gives the agent (caller_resolve, lib/policy.sh): a command
  # that drops or rewrites it would run teamctl as somebody else. Cooperative, like the rest of the guard.
  if printf '%s' "$c" | grep -Eq "(^|[^A-Za-z0-9_\${])${ids}\\+?=" ||
    printf '%s' "$c" | grep -Eq "${edge}(unset|export[[:space:]]+-[a-z]*n[a-z]*)([[:space:]]+-[a-z]+)*([[:space:]]+[A-Za-z_][A-Za-z0-9_]*)*[[:space:]]+${ids}${after}" ||
    printf '%s' "$c" | grep -Eq "(^|[[:space:]])(-u|--unset)([[:space:]]+|=)?${ids}${after}" ||
    printf '%s' "$c" | grep -Eq "${edge}env([[:space:]]+(-[uPSC][[:space:]]+[^-[:space:];&|][^[:space:];&|]*|-[^[:space:];&|]*|[A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*))*[[:space:]]+(-[A-Za-z0-9]*i[A-Za-z0-9]*|--ignore-environment|-)${after}" ||
    printf '%s' "$c" | grep -Eq "${edge}exec[[:space:]]+-[a-z]*c"; then
    printf 'that command unsets or overrides TEAM_ROLE, TMUX_PANE, WOLFMUX_TEAM or BEADS_ACTOR (env -i, env -u, unset, X=…): teamctl decides who may act by the identity your pane gives you, and a command without it is not you. Run it with them as they are.' && return 0
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
  # Claude Code's records of sessions outside the project folders (guard_claude_private), as configured and resolved
  GUARD_CLAUDE_LC=()
  for path in "${HOME:+$HOME/.claude}" "${CLAUDE_CONFIG_DIR:-}"; do
    [ -n "$path" ] || continue
    for target in file-history todos paste-cache; do
      GUARD_CLAUDE_LC+=("$(guard_lower "$(guard_abspath "$path/$target" /)")" "$(guard_lower "$(guard_squeeze "${path%/}/$target")")")
    done
  done
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
  GUARD_CWD="$(cd "$cwd" && /bin/pwd -P)" || GUARD_CWD="$GUARD_OWN"
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
      if guard_claude_private "$lpath"; then
        guard_deny "'$target' is in Claude Code's own records of sessions (file-history, todos, paste-cache); no worker writes there." && return 0
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
        case "$pattern" in
          /* | "~" | "~/"*) target="$(guard_glob_root "$pattern")" ;;
          # a relative pattern that climbs (../../../../../memory/**) searches where it climbs to, from path or here
          .. | ../* | */../* | */..) target="$(guard_glob_root "$(guard_resolve_word "$pattern" "$(guard_abspath "${target:-$cwd}" "$cwd")")")" ;;
        esac
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
      elif guard_claude_private "$lpath"; then
        guard_deny "'$target' is in Claude Code's own records of sessions (file-history keeps a copy of every file a session changed, a lead's too), which no worker reads."
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
        if guard_claude_private "$lpath"; then
          guard_deny "'$target' is in Claude Code's own records of sessions (file-history, todos, paste-cache)." && return 0
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
      # A shell that runs inside a private folder reads it with every relative word
      lpath="$(guard_lower "$GUARD_CWD")"
      if ! guard_inside "$GUARD_CWD" "$GUARD_OWN" && { guard_inside "$lpath" "$GUARD_TREES_LC" || guard_inside "$lpath" "$GUARD_STATE_LC" ||
        guard_inside "$lpath" "$GUARD_MEMORY_LC" || guard_transcript "$lpath" || guard_claude_private "$lpath"; }; then
        guard_deny "this shell runs in $GUARD_CWD, a folder that is not yours to read; cd back into your worktree." && return 0
      fi
      reason="$(guard_shell "$target" 2>/dev/null || true)"
      if [ -n "$reason" ]; then guard_deny "$reason"; fi
      ;;
  esac
  return 0
}
