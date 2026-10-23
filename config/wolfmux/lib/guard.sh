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
#                    memory folders of team memory (~/.wolfmux/memory, lib/memory.sh), the
#                    leads' conversations (Claude Code's folder for the project, all of it
#                    but its shared memory/), Claude Code's own records of sessions
#                    (file-history, todos, paste-cache, sessions, session-env, history.jsonl)
#                    and Claude Code's temporary folder (/private/tmp/claude-<uid>) except the
#                    worker's own scratchpad there, compared without regard to letter case
#   shell commands   refused when they name another worktree, write into a checkout the
#                    worker may only read, move or delete branches, switch to another
#                    branch, touch git worktrees, push to main, drive tmux, resume a Claude
#                    Code conversation, drop the identity teamctl reads, link to a private
#                    place; and when a tool that walks a tree (grep -r, rg, fd, ag, ack, find,
#                    ls -R, du, tar) is pointed at a folder that holds a private folder.
#                    The command is read as the shell reads it (GUARD_SCAN): words unquoted,
#                    a relative path where the shell would be after its cd, what sh -c, eval,
#                    a heredoc or a pipe into a shell runs, three levels deep.
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
# reason an agent stops working. It is fast because Claude Code runs a tool call whose
# hook times out (10 s, lib/agents.sh): a command too big or too slow to check is refused.

# guard_phys <path> <cwd> — sets GUARD_P: the path absolute, "//" and "/./" squeezed, symlinks of the existing
# part resolved (the builtin cd -P: no fork), the rest as written. Letter case as typed: every compare is
# without regard to case (cmd_guard sets nocasematch), as the disk is.
guard_phys() {
  local path="$1" dir rest="" back="$PWD" two='//' dot='/./' one='/'
  case "$path" in
    /*) ;;
    "~") path="$HOME" ;;
    "~/"*) path="$HOME/${path#\~/}" ;;
    *) path="${2%/}/$path" ;;
  esac
  while :; do
    case "$path" in
      *//*) path="${path//$two/$one}" ;;
      */./*) path="${path//$dot/$one}" ;;
      *) break ;;
    esac
  done
  case "$path" in */.) path="${path%/.}" ;; esac
  dir="${path:-/}"
  while [ "$dir" != "/" ] && [ -n "$dir" ] && [ ! -d "$dir" ]; do
    rest="/${dir##*/}$rest"
    dir="${dir%/*}"
  done
  if CDPATH='' cd -P -- "${dir:-/}" 2>/dev/null; then
    dir="$PWD"
    cd -- "$back" 2>/dev/null || true
  else
    dir="/"
  fi
  GUARD_P="${dir%/}$rest"
  GUARD_P="${GUARD_P:-/}"
}

# guard_abspath <path> <cwd> — guard_phys, printed
guard_abspath() {
  guard_phys "$1" "$2"
  printf '%s\n' "$GUARD_P"
}

# guard_inside <path> <directory>
guard_inside() {
  case "$1/" in "$2"/*) return 0 ;; esac
  return 1
}

# guard_link <symlink> — sets GUARD_P to where it leads, physical (a link to a folder costs no fork)
guard_link() {
  local back="$PWD" to
  if [ -d "$1" ]; then
    CDPATH='' cd -P -- "$1" 2>/dev/null || return 1
    GUARD_P="$PWD"
    cd -- "$back" 2>/dev/null || true
    return 0
  fi
  to="$(/usr/bin/readlink "$1" 2>/dev/null)" || return 1
  case "$to" in /*) ;; *) to="${1%/*}/$to" ;; esac
  guard_phys "$to" /
}

# guard_transcript <path> — inside the folder of the leads' conversations, and not in the project's shared
# memory/ there (which every session may read: lib/memory.sh)
guard_transcript() {
  [ -n "$GUARD_TRANSCRIPTS" ] && guard_inside "$1" "$GUARD_TRANSCRIPTS" && ! guard_inside "$1" "$GUARD_TRANSCRIPTS/memory"
}

# guard_claude_private <path> — inside one of Claude Code's own records of sessions outside any project, under
# ~/.claude and under CLAUDE_CONFIG_DIR: file-history/ (a copy of every file a session changed, from before the
# change), todos/, paste-cache/, sessions/ (every live session's id, folder and tmux pane), session-env/ and
# history.jsonl (every prompt typed to any session). Any session's, a lead's included: no worker reads them.
guard_claude_private() {
  local private
  for private in ${GUARD_CLAUDE[@]+"${GUARD_CLAUDE[@]}"}; do
    guard_inside "$1" "$private" && return 0
  done
  return 1
}

# guard_ctmp <path> — inside Claude Code's temporary folder (every session's tool output and scratchpad, the
# leads' too) and not in the worker's own scratchpad root there
guard_ctmp() {
  local p
  for p in ${GUARD_SCRATCH[@]+"${GUARD_SCRATCH[@]}"}; do
    guard_inside "$1" "$p" && return 1
  done
  for p in ${GUARD_CTMP[@]+"${GUARD_CTMP[@]}"}; do
    guard_inside "$1" "$p" && return 0
  done
  return 1
}

# guard_private <absolute path> — sets GUARD_WHY to the private place the path is in (trees, memory, transcripts,
# claude, ctmp), or to nothing
guard_private() {
  GUARD_WHY=""
  if guard_inside "$1" "$GUARD_OWN"; then return 0; fi
  if guard_inside "$1" "$GUARD_TREES" || guard_inside "$1" "$GUARD_STATE"; then
    GUARD_WHY=trees
  elif guard_inside "$1" "$GUARD_MEMORY"; then
    GUARD_WHY=memory
  elif guard_transcript "$1"; then
    GUARD_WHY=transcripts
  elif guard_claude_private "$1"; then
    GUARD_WHY=claude
  elif guard_ctmp "$1"; then
    GUARD_WHY=ctmp
  fi
  return 0
}

# guard_holds_private <path> — the path is a folder that holds a memory folder, the leads' conversations, Claude
# Code's records or its temporary folder (/, ~, ~/.wolfmux, ~/.claude, /tmp): a search of it reads them too
guard_holds_private() {
  local private
  [ "$1" != "/" ] || return 0
  guard_inside "$GUARD_MEMORY" "$1" && return 0
  for private in ${GUARD_CLAUDE[@]+"${GUARD_CLAUDE[@]}"} ${GUARD_CTMP[@]+"${GUARD_CTMP[@]}"}; do
    guard_inside "$private" "$1" && return 0
  done
  [ -n "$GUARD_TRANSCRIPTS" ] && guard_inside "$GUARD_TRANSCRIPTS" "$1"
}

# guard_glob_root <glob pattern> — sets GUARD_P to the folder it searches: everything before the first part
# with a wildcard in it (/a/b/**/*.md is a search of /a/b)
guard_glob_root() {
  local rest="$1" out="" part
  while :; do
    part="${rest%%/*}"
    case "$part" in *[][*?{}]*) break ;; esac
    out="$out$part"
    [ "$part" != "$rest" ] || break
    out="$out/"
    rest="${rest#*/}"
  done
  GUARD_P="${out:-/}"
}

guard_deny() {
  "$JQ_BIN" -cn --arg reason "Wolfmux: $1 You are '${TEAM_ROLE:-}' and work only in your own worktree ($GUARD_OWN) on your own branch. If something outside it has to change, ask your lead: bd create \"<what and why>\" -t message -a $(team_identity "${WOLFMUX_TEAM:-$WOLFMUX_DEFAULT_TEAM}" "$WOLFMUX_LEAD_ROLE")" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  return 0
}

# GUARD_SCAN — the awk program that reads one shell command (GA_CMD) as the shell would and decides whether it
# reaches outside, in ONE process: a guard that is slow is a guard that is skipped (the hook times out and the
# call runs). Paths and names come in the environment (GA_*, set by guard_bash). It prints:
#   T<seconds>  the clock it started from (guard_bash hands it to the next pass: GA_T0)
#   D<reason>   refuse (and stops)
#   L<path>     a path under the worker's worktree or /tmp that may be a symlink: guard_bash tests each with the
#               builtin [ -L ] and runs the program again with the links it found (GA_LINKS, "path<TAB>target")
#   B<name>     `git checkout <name>`: guard_bash asks git whether <name> is another local branch
#   OK          read to the end
# How it reads (run): the text is split into words the way the shell does (lex: quotes, $'…', \x and quoted
# parts inside a word removed, "\" + newline dropped, ~, ~user, ~+, $HOME and $PWD spelled out, heredoc bodies,
# $( ), ` ` and <( ) cut out to be read on their own). Then two passes over the simple commands:
#   A (checkA)  the cheap rules on every word as written: private folders, tmux and claude --resume as the
#               program, a dropped identity, a tree walk of a folder written out. The first hit refuses.
#   B (checkB)  in order, following the folder the shell is in (cd, pushd, popd, cd -; a cd in ( ), a pipe or &
#               stays there): every word that is a path, resolved (.., ./, relative words while the shell is
#               outside the own worktree, symlinks from GA_LINKS); wildcards; tree walks; git; the read-only
#               checkouts; links; then what sh -c, eval, a heredoc or pipe into a shell, env -S, ssh and watch
#               run, as a command one level deeper (four levels refuse).
# Budget, counted in steps so that it means the same on a busy machine: guard_bash refuses a command over 64 KB
# before awk starts; awk refuses over 256 KB of text lexed (an inner command counts again), 4000 words, 300 paths
# resolved outside the own worktree or 12,000 link candidates, and a wildcard word or a link candidate over 4096
# bytes. Every step is linear: a search reads the text in growing windows, plain characters are taken in runs, a
# word grows a kilobyte at a time (app), long strings are glued from pieces, and no sub() or match() runs on a
# long word (BSD awk tries every start position). A 60 KB command takes under half a second. A clock (whole
# seconds, every 1000 characters, 50 words and 50 paths) is the backstop: 5 seconds from the first pass, under
# the hook's 10.
# Out of reach: a folder or path built at run time (d=~/.wolfmux; cd $d), code in a string (python3 -c),
# CDPATH, a chain of more than three links (docs/SECURITY.md).
GUARD_SCAN='
function init(   n, t, k, at) {
  HOME = ENVIRON["GA_HOME"]; sub(/\/+$/, "", HOME); LHOME = tolower(HOME)
  USERN = ENVIRON["GA_USER"]; BRANCH = ENVIRON["GA_BRANCH"]
  NOWN = list(ENVIRON["GA_OWN"], OWN); NSCR = list(ENVIRON["GA_SCR"], SCR)
  NTREES = list(ENVIRON["GA_TREES"], TREES); NSTATE = list(ENVIRON["GA_STATE"], STATE)
  NMEM = list(ENVIRON["GA_MEM"], MEM); NTR = list(ENVIRON["GA_TR"], TR)
  NCL = list(ENVIRON["GA_CL"], CL); NCT = list(ENVIRON["GA_CT"], CT); NROOT = list(ENVIRON["GA_ROOT"], ROOT)
  n = split(ENVIRON["GA_LINKS"], t, "\n")
  for (k = 1; k <= n; k++) if ((at = index(t[k], "\t")) > 1) { LINK[tolower(substr(t[k], 1, at - 1))] = substr(t[k], at + 1); NLINK++; if (at - 1 > MAXLINK) MAXLINK = at - 1 }
  IDS = "(TEAM_ROLE|TMUX_PANE|WOLFMUX_TEAM|BEADS_ACTOR)"
  SHELLS = "^(ba|z|da|k|fi|tc|c|mk|yash|posh)?sh$"
  # the programs the rules name, for a program word with a wildcard or a group (gname)
  NMIND = split("tmux claude claude-code sh bash zsh dash ksh fish tcsh csh mksh yash posh eval source . env sudo doas exec command xargs gxargs nice timeout gtimeout git ln gln cp gcp node nodejs bun deno npx bunx pnpx ssh watch make gmake cd pushd popd echo printf cat unset export declare typeset local read readarray mapfile find fd fdfind grep rg", MINDL, " ")
  for (k = 1; k <= NMIND; k++) MIND[MINDL[k]] = 1
  PATS = "^(regexp|glob|iglob|include|exclude|exclude-dir|match|file-search-regex|grep|author|committer)$"
  R_TREES = "that command names another teammate\047s worktree or teamctl\047s state."
  R_MEM = "that command names a lead\047s private memory folder (~/.wolfmux/memory), which no worker reads."
  R_CLAUDE = "that command names Claude Code\047s own records of sessions (file-history, todos, paste-cache, sessions, session-env, history.jsonl under ~/.claude), which hold copies of other agents\047 work and their conversation ids; no worker reads them."
  R_TRANS = "that command names the folder of the leads\047 conversations (" ENVIRON["GA_TRSHOW"] "); only its memory/ is shared."
  R_CTMP = "that command names Claude Code\047s temporary folder (" ENVIRON["GA_CTSHOW"] "), which holds every session\047s tool output, the leads\047 too. Only your own scratchpad there is yours: a worker searches its worktree and its own scratchpad, never all of /tmp."
  R_LONG = "that command is too long for the guard to follow (over 4000 words); split it."
  R_SPLIT = "that command has too many paths outside your worktree for the guard to follow (over 300); split this command."
  R_SLOW = "that command takes the guard too long to check (over 5 seconds); split this command."
  R_BIG = "that command is too big for the guard to follow (over 256 KB of text to read, the commands it runs inside counted again); split this command."
  R_NEST = "that command nests sh -c or eval more than three levels deep; run the inner command itself."
  R_TMUX = "tmux belongs to teamctl; panes of other agents are not yours to read or type into."
  R_RESUME = "that command resumes a Claude Code conversation (claude --resume, -r, --continue, -c, --session-id), which reads it whoever\047s it is. A worker never resumes a conversation; ask the lead."
  R_ID = "that command unsets or overrides TEAM_ROLE, TMUX_PANE, WOLFMUX_TEAM or BEADS_ACTOR (env -i, env -u, unset, X=...): teamctl decides who may act by the identity your pane gives you, and a command without it is not you. Run it with them as they are."
  R_WT = "git worktrees are created and removed by teamctl only."
  R_BRANCH = "moving, renaming or deleting branches is the lead\047s business."
  R_SWITCH = "stay on your own branch (" BRANCH "); do not switch or create branches in this worktree."
  R_PUSH = "pushing to main, deleting or force-updating remote branches is for the lead."
  R_ROOT = "that command would change a checkout that is read-only for you (" ENVIRON["GA_RO"] "). Your work belongs in your own worktree."
  R_LINK = "that command makes a link to a place outside your worktree (your home folder, /Users or Claude Code\047s temporary folder); a later command could read a private folder through it. Copy what you need into your worktree instead."
  srand(); T0 = srand(); if (ENVIRON["GA_T0"] != "") T0 = ENVIRON["GA_T0"] + 0
}
# list(text, arr): the newline-separated paths, lower case, squeezed, without a trailing "/", each also without
# a leading /private (/private/tmp is /tmp); the count
function list(text, arr,   n, t, k, c, p) {
  n = split(text, t, "\n"); c = 0
  for (k = 1; k <= n; k++) {
    p = tolower(t[k]); gsub(/\/\/+/, "/", p); while (p ~ /\/\.\//) sub(/\/\.\//, "/", p); sub(/\/+$/, "", p)
    if (p == "") continue
    arr[++c] = p
    if (substr(p, 1, 9) == "/private/") arr[++c] = substr(p, 9)
  }
  return c
}
function clock(   now) { srand(); now = srand(); if (now - T0 >= 5 && DENY == "") DENY = R_SLOW }
# idx(s, p, t): where t is first found in s at or after p, 0 for none. It reads s in growing windows: the
# index(substr(s, p), t) it replaces copied the whole rest of the command at every quote, comment and line
function idx(s, p, t,   n, w, j) {
  n = length(s); w = 256
  while (p <= n) {
    if ((j = index(substr(s, p, w + length(t) - 1), t)) > 0) return p + j - 1
    p += w; w += w
  }
  return 0
}
# heredoc(s, p, n, delim, strip): the body that starts at p, up to the line that is delim (tabs taken off its
# lines for <<-), in HBODY; it returns where the text goes on after the delimiter line
function heredoc(s, p, n, delim, strip,   start, at, j, e, line) {
  start = p
  if (!strip) {
    if (substr(s, p, length(delim) + 1) == delim "\n" || (p + length(delim) - 1 == n && substr(s, p, length(delim)) == delim)) { HBODY = ""; return p + length(delim) + 1 }
    at = p
    while ((j = idx(s, at, "\n" delim)) > 0) {
      e = j + 1 + length(delim)
      if (e > n || substr(s, e, 1) == "\n") { HBODY = substr(s, start, j - start + 1); return e + 1 }
      at = j + 1
    }
    p = n + 1
  } else while (p <= n) {
    j = idx(s, p, "\n"); e = j ? j : n + 1
    line = substr(s, p, e - p); sub(/^\t+/, "", line)
    if (line == delim) break
    p = e + 1
  }
  HBODY = substr(s, start, p - start); e = p
  if (strip) { gsub(/\n\t+/, "\n", HBODY); sub(/^\t+/, "", HBODY); if (p <= n) e = (j ? j : n) + 1 }
  if (HBODY != "" && substr(HBODY, length(HBODY)) != "\n") HBODY = HBODY "\n"
  return e
}
# glue(arr, a, z): arr[a..z] joined, the halves first (adding one piece at a time copies the whole result each time)
function glue(arr, a, z,   m) { if (a > z) return ""; if (a == z) return arr[a]; m = int((a + z) / 2); return glue(arr, a, m) glue(arr, m + 1, z) }
# base(w): the last part of a path (by split: sub(/.*\//) tries every start position, a long word cost its length
# squared), without the leading = of zsh (=tmux runs tmux)
function base(w,   n, parts) { if (substr(w, 1, 1) == "=") w = substr(w, 2); n = split(w, parts, "/"); while (n > 1 && parts[n] == "") n--; return parts[n] }
# --- zsh glob groups ((a|b), mem(|)ory) and bash extglob (@(a|b)): the lexer writes their syntax as \006 ( \007 |
# \010 ), so a quoted ( | ) is never read as one. galts(v, f, out): the words a group word (flag G) stands for,
# each alternative, at most 64; a nested group, a ! * ? + before the (, or more alternatives stand for "*"
# (GSTAR, and every word then goes to wild()); a word with over 16 groups is one word, its star form
function galts(v, f, out,   L, p, at, j, pre, lc, body, na, al, nc, cur, nw, m, i, k) {
  GSTAR = 0; out[1] = v
  if (!index(f, "G")) return 1
  # over 4096 bytes it stays as it is: wild() refuses a wildcard word that long
  if ((L = length(v)) > 4096) { GSTAR = 1; return 1 }
  if (gsub(/\006/, "\006", v) > 16) { out[1] = gstar(v); GSTAR = 1; return 1 }
  nc = 1; cur[1] = ""; p = 1
  while ((at = idx(v, p, "\006")) > 0) {
    pre = substr(v, p, at - p); lc = substr(pre, length(pre))
    j = gclose(v, at + 1)
    body = substr(v, at + 1, j - at - 1 - GSHUT)
    if (lc != "" && index("!*?+@", lc)) pre = substr(pre, 1, length(pre) - 1)
    if (GNEST || (lc != "" && index("!*?+", lc))) { na = 1; al[1] = "*"; GSTAR = 1 } else na = split(body, al, "\007")
    if (na < 1) { na = 1; al[1] = "" }
    if (nc * na > 64) { na = 1; al[1] = "*"; GSTAR = 1 }
    m = 0; for (i = 1; i <= nc; i++) for (k = 1; k <= na; k++) nw[++m] = cur[i] pre al[k]
    nc = m; for (i = 1; i <= nc; i++) cur[i] = nw[i]
    p = j
  }
  for (i = 1; i <= nc; i++) { out[i] = cur[i] substr(v, p); gsub(/[\006\007\010]/, "", out[i]) }
  return nc
}
# gclose(v, j): where the text goes on after the group whose body starts at j; GNEST when a group is inside it,
# GSHUT when it is closed (by idx: one character at a time cost a long word its length squared)
function gclose(v, j,   depth, o, c) {
  depth = 1; GNEST = 0; GSHUT = 1; o = idx(v, j, "\006")
  while (depth > 0) {
    if (!(c = idx(v, j, "\010"))) { GSHUT = 0; return length(v) + 1 }
    if (o && o < c) { depth++; GNEST = 1; j = o + 1; o = idx(v, j, "\006") } else { depth--; j = c + 1 }
  }
  return j
}
# gstar(v): v with every group (and the ! * ? + @ before it) read as "*"
function gstar(v,   p, at, pre, k, pc) {
  p = 1; k = 0
  while ((at = idx(v, p, "\006")) > 0) {
    pre = substr(v, p, at - p); if (pre != "" && index("!*?+@", substr(pre, length(pre)))) pre = substr(pre, 1, length(pre) - 1)
    pc[++k] = pre "*"
    p = gclose(v, at + 1)
  }
  pc[++k] = substr(v, p)
  v = glue(pc, 1, k); gsub(/[\007\010]/, "", v)
  return v
}
# gname(w, f): the program a program word names, lower case; for a word with a wildcard or a group
# (/opt/homebrew/bin/tmu?, (tmux|x)) the first program the guard minds that it can match
function gname(w, f,   b, n, k, j, re) {
  b = tolower(base(w))
  if ((!index(f, "g") && !index(f, "G")) || length(w) > 256) return b
  n = galts(w, f, GN)
  for (k = 1; k <= n; k++) {
    b = tolower(base(GN[k]))
    if (b !~ /[*?[{]/) { if (b in MIND) return b; continue }
    re = globre(b)
    for (j = 1; j <= NMIND; j++) if (MINDL[j] ~ re) return MINDL[j]
  }
  return tolower(base(GN[1]))
}
function rep(v, a, b,   at, p, n, k, pc) {
  if (!(at = index(v, a))) return v
  p = 1; n = length(a); k = 0
  while (at > 0) { pc[++k] = substr(v, p, at - p) b; p = at + n; at = idx(v, p, a) }
  pc[++k] = substr(v, p)
  return glue(pc, 1, k)
}
function inside(p, dir) { return p == dir || substr(p, 1, length(dir) + 1) == dir "/" }
function inany(p, arr, n,   k, l) { l = tolower(p); for (k = 1; k <= n; k++) if (inside(l, arr[k])) return 1; return 0 }
function inown(p) { return inany(p, OWN, NOWN) }
function inroot(p) { return inany(p, ROOT, NROOT) }
# quoted text with a blank in it is prose (a commit message), unless it starts like a path
function isprose(v, f) { return index(f, "p") && v !~ /^(\/|\.\.?\/|~)/ && substr(v, 1, 1) != "\002" }

# --- the private folders, by name: hit(l, p) when l holds p as a whole name (what follows is no name character)
function namech(c) { return c ~ /[a-z0-9._-]/ }
function hit(l, p,   at, n) {
  n = length(p); at = index(l, p)
  while (at > 0) { if (!namech(substr(l, at + n, 1))) return 1; at = idx(l, at + 1, p) }
  return 0
}
function trhit(l, p,   at, n) {
  n = length(p); at = index(l, p)
  while (at > 0) {
    if (!namech(substr(l, at + n, 1)) && !(substr(l, at + n, 7) == "/memory" && !namech(substr(l, at + n + 7, 1)))) return 1
    at = idx(l, at + 1, p)
  }
  return 0
}
# the own worktree and the own scratchpad are blanked out first (w1 is not the start of w10)
function maskone(l, p,   at, n, q, k, pc) {
  if (!(at = index(l, p))) return l
  n = length(p); q = 1; k = 0
  while (at > 0) {
    if (!namech(substr(l, at + n, 1))) { pc[++k] = substr(l, q, at - q) "\004"; q = at + n; at = idx(l, q, p) }
    else at = idx(l, at + 1, p)
  }
  pc[++k] = substr(l, q)
  return glue(pc, 1, k)
}
function lit(w,   l, k) {
  l = tolower(w)
  for (k = 1; k <= NOWN; k++) l = maskone(l, OWN[k])
  for (k = 1; k <= NSCR; k++) l = maskone(l, SCR[k])
  for (k = 1; k <= NTREES; k++) if (hit(l, TREES[k])) return R_TREES
  for (k = 1; k <= NSTATE; k++) if (hit(l, STATE[k])) return R_TREES
  for (k = 1; k <= NMEM; k++) if (hit(l, MEM[k])) return R_MEM
  if (hit(l, ".wolfmux/memory")) return R_MEM
  for (k = 1; k <= NCL; k++) if (hit(l, CL[k])) return R_CLAUDE
  for (k = 1; k <= NTR; k++) if (trhit(l, TR[k])) return R_TRANS
  for (k = 1; k <= NCT; k++) if (hit(l, CT[k])) return R_CTMP
  return ""
}
# a folder that holds a private one: a search of it reads that too
function holds(l,   k) {
  if (l == "" || l == "/") return 1
  for (k = 1; k <= NMEM; k++) if (inside(MEM[k], l)) return 1
  for (k = 1; k <= NCL; k++) if (inside(CL[k], l)) return 1
  for (k = 1; k <= NTR; k++) if (inside(TR[k], l)) return 1
  for (k = 1; k <= NCT; k++) if (inside(CT[k], l)) return 1
  return 0
}

# --- the lexer: lex(s, d) fills TT[d,i] (w word, o operator, r redirection), TV[d,i] (the word unquoted),
# TF[d,i] (flags: q quoted, p a quoted blank, g a wildcard, $ built at run time, P process substitution),
# TR[d,i] (a redirection target: its operator), HB[d,i] (the body of a heredoc, on its << token) and the
# substitutions SX[d,k] (text), SA[d,k] (token), SK[d,k] (s or p)
function flag(f) { if (!index(LF, f)) LF = LF f }
# app(t): t added to the word being read. Pieces gather in LB and go to LW a kilobyte at a time (adding to one
# long LW piece by piece made a long word cost its length squared); LC is the last character of the word
function app(t) { if (t == "") return; LB = LB t; LC = substr(t, length(t)); if (length(LB) > 1024) { LW = LW LB; LB = "" } }
function qapp(t) { app(t); if (t ~ /[ \t\n]/) flag("p") }
function quoted(t) { qapp(t); flag("q"); LIN = 1 }
function endw(d,   w) {
  if (!LIN) return
  w = LW LB
  if (LBR && w ~ /\{[^}]*(,|\.\.)[^}]*\}/) flag("g")
  NT[d]++; TT[d, NT[d]] = "w"; TV[d, NT[d]] = w; TF[d, NT[d]] = LF; TR[d, NT[d]] = LRED; LRED = 0
  LW = ""; LB = ""; LC = ""; LF = ""; LIN = 0; LBR = 0; GD = 0
  if (++WORDS > 4000 && DENY == "") DENY = R_LONG
  if (WORDS % 50 == 0) clock()
}
function op(d, o) { NT[d]++; TT[d, NT[d]] = "o"; TV[d, NT[d]] = o; TF[d, NT[d]] = ""; TR[d, NT[d]] = 0; LRED = 0 }
function red(d, o) { NT[d]++; TT[d, NT[d]] = "r"; TV[d, NT[d]] = o; TF[d, NT[d]] = ""; TR[d, NT[d]] = 0; LRED = NT[d] }
# cmdpos(d): a command can start at the next word (a ( there is a subshell, elsewhere a glob group)
function cmdpos(d) { return !NT[d] || TT[d, NT[d]] == "o" || (TT[d, NT[d]] == "w" && !TR[d, NT[d]] && TV[d, NT[d]] ~ /^(!|\{|if|then|else|elif|do|while|until|time|coproc)$/) }
function addsub(d, t, at, kind) { NS[d]++; SX[d, NS[d]] = t; SA[d, NS[d]] = at; SK[d, NS[d]] = kind }
# what $( ) or ` ` gives in a word: which X, command -v X and type -p X give X itself; the rest is run time
function subword(t,   name) {
  name = t
  if (sub(/^[ \t]*(which|command[ \t]+-[vV]|type[ \t]+-[pP])[ \t]+/, "", name) && name ~ /^[^ \t;&|<>()`$\\"\047]+[ \t]*$/) { sub(/[ \t]+$/, "", name); app(name); return }
  app("\003"); flag("$")
}
function expand(name, as) {
  if (name == "HOME") app(HOME)
  else if (name == "USER" || name == "LOGNAME") app(USERN)
  else if (name == "PWD") app("\002")
  else { app(as); flag("$") }
}
function dollar(s, p, n, d,   c2, j, t, name) {
  c2 = substr(s, p + 1, 1)
  if (c2 == "(") {
    j = closep(s, p + 2, n); t = j ? substr(s, p + 2, j - p - 2) : substr(s, p + 2)
    addsub(d, t, NT[d] + 1, "s"); subword(t)
    return j ? j + 1 : n + 1
  }
  if (c2 == "{") {
    j = idx(s, p + 2, "}"); t = j ? substr(s, p + 2, j - p - 2) : substr(s, p + 2)
    if (t ~ /\$\(|`/) subs_in(t, d, NT[d] + 1)
    name = t; sub(/[^A-Za-z0-9_].*$/, "", name)
    expand(name, "${" t "}")
    return j ? j + 1 : n + 1
  }
  if (c2 ~ /[A-Za-z_]/) {
    t = substr(s, p + 1, 256); match(t, /^[A-Za-z_][A-Za-z0-9_]*/); name = substr(t, 1, RLENGTH)
    expand(name, "$" name)
    return p + 1 + RLENGTH
  }
  if (c2 != "" && index("0123456789@*#?$!-", c2)) { app("$" c2); flag("$"); return p + 2 }
  app("$")
  return p + 1
}
function tick(s, p, n, d,   c, c2, t, k, pc) {
  k = 0
  while (p <= n) {
    c = substr(s, p, 1)
    if (c == "\\") { c2 = substr(s, p + 1, 1); if (c2 == "`" || c2 == "$" || c2 == "\\") { pc[++k] = c2; p += 2; continue } }
    if (c == "`") { p++; break }
    if (match(substr(s, p, 256), /^[^`\\]+/)) { pc[++k] = substr(s, p, RLENGTH); p += RLENGTH; continue }
    pc[++k] = c; p++
  }
  t = glue(pc, 1, k)
  addsub(d, t, NT[d] + 1, "s"); subword(t)
  return p
}
function dq(s, p, n, d,   c, c2, t) {
  flag("q"); LIN = 1
  while (p <= n) {
    c = substr(s, p, 1)
    if (c == "\"") return p + 1
    if (c == "\\") {
      c2 = substr(s, p + 1, 1)
      if (c2 == "\n") { p += 2; continue }
      if (c2 == "$" || c2 == "`" || c2 == "\"" || c2 == "\\") { app(c2); p += 2; continue }
      app(c); p++; continue
    }
    if (c == "$") { p = dollar(s, p, n, d); continue }
    if (c == "`") { p = tick(s, p + 1, n, d); continue }
    if (match(substr(s, p, 256), /^[^"\\$`]+/)) { qapp(substr(s, p, RLENGTH)); p += RLENGTH; continue }
    app(c); p++
  }
  return p
}
function hexval(s, p, most,   v, k, c) {
  v = 0; k = 0; HEXP = p
  while (k < most && (c = tolower(substr(s, HEXP, 1))) != "" && index("0123456789abcdef", c)) { v = v * 16 + index("0123456789abcdef", c) - 1; HEXP++; k++ }
  return v
}
function ansi(s, p, n,   c, c2, v, k) {
  flag("q"); LIN = 1
  while (p <= n) {
    c = substr(s, p, 1)
    if (c == "\047") { p++; break }
    if (c == "\\" && p < n) {
      c2 = substr(s, p + 1, 1); p += 2
      if (c2 == "n") qapp("\n")
      else if (c2 == "t") qapp("\t")
      else if (c2 == "x") { v = hexval(s, p, 2); p = HEXP; qapp(v > 0 && v < 128 ? sprintf("%c", v) : "?") }
      else if (c2 == "u" || c2 == "U") { v = hexval(s, p, c2 == "u" ? 4 : 8); p = HEXP; qapp(v > 0 && v < 128 ? sprintf("%c", v) : "?") }
      else if (c2 ~ /[0-7]/) { v = c2 + 0; k = 1; while (k < 3 && substr(s, p, 1) ~ /[0-7]/) { v = v * 8 + substr(s, p, 1); p++; k++ } qapp(v > 0 && v < 128 ? sprintf("%c", v) : "?") }
      else if (c2 == "c") p++
      else if (index("abeEfrv", c2)) qapp(" ")
      else qapp(c2)
      continue
    }
    if (match(substr(s, p, 256), /^[^\047\\]+/)) { qapp(substr(s, p, RLENGTH)); p += RLENGTH; continue }
    qapp(c); p++
  }
  return p
}
function tilde(s, p, n,   t, name, c) {
  t = substr(s, p + 1, 256); match(t, /^[A-Za-z0-9._+-]*/); name = substr(t, 1, RLENGTH)
  c = substr(s, p + 1 + RLENGTH, 1)
  if (c != "" && c !~ /[\/ \t\n;&|()<>:]/) { app("~"); return p + 1 }
  if (name == "" || name == USERN) app(HOME)
  else if (name == "+") app("\002")
  else if (name == "-") { app("~-"); flag("$") }
  else app("/Users/" name)
  return p + 1 + RLENGTH
}
# closep(s, p, n): the ) that closes the $( or <( whose text starts at p (quotes, nesting, comments and heredoc
# bodies skipped); 0 when there is none
function closep(s, p, n,   depth, c, j, prev, hn, hd, hs, k, t, start) {
  depth = 1; prev = "\n"; hn = 0
  while (p <= n) {
    if (match(substr(s, p, 256), /^[^\\\047"`$#<\n()]+/)) { p += RLENGTH; prev = substr(s, p - 1, 1); continue }
    c = substr(s, p, 1)
    if (c == "\\") { p += 2; prev = "x"; continue }
    if (c == "\047") { j = idx(s, p + 1, "\047"); if (!j) return 0; p = j + 1; prev = "x"; continue }
    if (c == "\"") { p = dqskip(s, p + 1, n); if (!p) return 0; prev = "x"; continue }
    if (c == "`") { j = p + 1; while (j <= n && substr(s, j, 1) != "`") { if (substr(s, j, 1) == "\\") j++; j++ } if (j > n) return 0; p = j + 1; prev = "x"; continue }
    if (c == "$" && substr(s, p + 1, 1) == "(") { j = closep(s, p + 2, n); if (!j) return 0; p = j + 1; prev = "x"; continue }
    if (c == "#" && prev ~ /[ \t\n;&|(]/) { j = idx(s, p, "\n"); if (!j) return 0; p = j; continue }
    if (c == "<" && substr(s, p + 1, 1) == "<" && substr(s, p + 2, 1) != "<") {
      p += 2; hs[hn + 1] = 0; if (substr(s, p, 1) == "-") { p++; hs[hn + 1] = 1 }
      while (substr(s, p, 1) == " " || substr(s, p, 1) == "\t") p++
      start = p; while (p <= n && substr(s, p, 1) !~ /[ \t\n;&|()<>]/) p++
      t = substr(s, start, p - start); gsub(/[\047"\\]/, "", t); hd[++hn] = t; prev = "x"; continue
    }
    if (c == "\n" && hn) {
      p++
      for (k = 1; k <= hn; k++) p = heredoc(s, p, n, hd[k], hs[k])
      hn = 0; prev = "\n"; continue
    }
    if (c == "(") depth++
    else if (c == ")" && --depth == 0) return p
    prev = c; p++
  }
  return 0
}
function dqskip(s, p, n,   c, j) {
  while (p <= n) {
    if (match(substr(s, p, 256), /^[^\\"$`]+/)) { p += RLENGTH; continue }
    c = substr(s, p, 1)
    if (c == "\\") { p += 2; continue }
    if (c == "\"") return p + 1
    if (c == "$" && substr(s, p + 1, 1) == "(") { j = closep(s, p + 2, n); if (!j) return 0; p = j + 1; continue }
    if (c == "`") { j = p + 1; while (j <= n && substr(s, j, 1) != "`") { if (substr(s, j, 1) == "\\") j++; j++ } if (j > n) return 0; p = j + 1; continue }
    p++
  }
  return 0
}
# the $( ) and ` ` in a heredoc body or a ${ } (they run too)
function subs_in(t, d, at,   p, n, c, j) {
  n = length(t); p = 1
  while (p <= n) {
    if (match(substr(t, p, 256), /^[^\\$`]+/)) { p += RLENGTH; continue }
    c = substr(t, p, 1)
    if (c == "\\") { p += 2; continue }
    if (c == "$" && substr(t, p + 1, 1) == "(") { j = closep(t, p + 2, n); addsub(d, j ? substr(t, p + 2, j - p - 2) : substr(t, p + 2), at, "s"); p = j ? j + 1 : n + 1; continue }
    if (c == "`") { j = idx(t, p + 1, "`"); addsub(d, j ? substr(t, p + 1, j - p - 1) : substr(t, p + 1), at, "s"); p = j ? j + 1 : n + 1; continue }
    p++
  }
}
function lex(s, d,   n, p, c, c2, j, t, hn, hi, start, strip, clk) {
  NT[d] = 0; NS[d] = 0; LW = ""; LB = ""; LC = ""; LF = ""; LIN = 0; LRED = 0; LBR = 0; GD = 0; hn = 0
  n = length(s); p = 1; clk = 1000
  if ((STEPS += n) > 262144 && DENY == "") DENY = R_BIG
  while (p <= n) {
    if (DENY != "") return
    if (p >= clk) { clock(); clk = p + 1000 }
    # plain characters, taken as one run (one character at a time made a long word cost its length squared)
    if (match(substr(s, p, 256), /^[A-Za-z0-9_.\/,+%@^!:=-]+/)) { app(substr(s, p, RLENGTH)); LIN = 1; p += RLENGTH; continue }
    c = substr(s, p, 1)
    if (c == "\\") {
      c2 = substr(s, p + 1, 1)
      if (c2 != "\n" && p < n) { app(c2); flag("q"); LIN = 1 }
      p += 2; continue
    }
    if (c == "\047") { j = idx(s, p + 1, "\047"); if (!j) j = n + 1; quoted(substr(s, p + 1, j - p - 1)); p = j + 1; continue }
    if (c == "$" && substr(s, p + 1, 1) == "\047") { p = ansi(s, p + 2, n); continue }
    if (c == "$" && substr(s, p + 1, 1) == "\"") { p++; continue }
    if (c == "\"") { p = dq(s, p + 1, n, d); continue }
    if (c == "$") { p = dollar(s, p, n, d); LIN = 1; continue }
    if (c == "`") { p = tick(s, p + 1, n, d); LIN = 1; continue }
    if (c == " " || c == "\t" || c == "\r") { endw(d); p++; continue }
    if (c == "#" && !LIN) { j = idx(s, p, "\n"); if (!j) break; p = j; continue }
    if (c == "\n") {
      endw(d); op(d, ";"); p++
      for (hi = 1; hi <= hn; hi++) {
        p = heredoc(s, p, n, HD[hi], HS[hi])
        HB[d, HT[hi]] = HBODY
        if (!HQ[hi]) subs_in(HBODY, d, HT[hi])
      }
      hn = 0; continue
    }
    if (c == ";") { endw(d); op(d, ";"); p++; while (substr(s, p, 1) == ";" || substr(s, p, 1) == "&") p++; continue }
    if (c == "&") {
      endw(d); c2 = substr(s, p + 1, 1)
      if (c2 == "&") { op(d, "&&"); p += 2; continue }
      if (c2 == ">") { p += 2; if (substr(s, p, 1) == ">") p++; red(d, ">"); continue }
      op(d, "&"); p++; continue
    }
    # a glob group: ( inside a word, or where no command starts, up to its ) with | between (zsh reads
    # cat ~/.wolfmux/(memory|x) as one word); =( ) at the start of a word is a process substitution in zsh
    if (c == "(" && LIN && LW == "" && LB == "=" && LF == "") {
      j = closep(s, p + 1, n); t = j ? substr(s, p + 1, j - p - 1) : substr(s, p + 1)
      addsub(d, t, NT[d] + 1, "p"); LB = ""; LC = ""; app("\003"); flag("$"); flag("P")
      p = j ? j + 1 : n + 1; continue
    }
    if (c == "(" && (GD || (substr(s, p + 1, 1) != ")" && (LIN ? (LW != "" || LB !~ /^[A-Za-z_][A-Za-z0-9_]*\+?=$/) : !cmdpos(d))))) { GD++; app("\006"); flag("G"); LIN = 1; p++; continue }
    if (GD && c == "|") { app("\007"); p++; continue }
    if (GD && c == ")") { GD--; app("\010"); p++; continue }
    if (c == "|") {
      endw(d); c2 = substr(s, p + 1, 1)
      if (c2 == "|") { op(d, "||"); p += 2; continue }
      op(d, "|"); p += (c2 == "&") ? 2 : 1; continue
    }
    if (c == "(" || c == ")") { endw(d); op(d, c); p++; continue }
    if (c == "<" || c == ">") {
      c2 = substr(s, p + 1, 1)
      if (c2 == "(") {
        j = closep(s, p + 2, n); t = j ? substr(s, p + 2, j - p - 2) : substr(s, p + 2)
        addsub(d, t, NT[d] + 1, "p"); app("\003"); flag("$"); flag("P"); LIN = 1
        p = j ? j + 1 : n + 1; continue
      }
      if (LIN && LF == "" && LW == "" && LB ~ /^[0-9]+$/) { LB = ""; LC = ""; LIN = 0 }
      endw(d)
      if (substr(s, p, 3) == "<<<") { red(d, "<<<"); p += 3; continue }
      if (c == "<" && c2 == "<") {
        p += 2; strip = 0; if (substr(s, p, 1) == "-") { strip = 1; p++ }
        red(d, "<<"); LRED = 0
        while (substr(s, p, 1) == " " || substr(s, p, 1) == "\t") p++
        start = p; while (p <= n && substr(s, p, 1) !~ /[ \t\n;&|()<>]/) p++
        t = substr(s, start, p - start)
        hn++; HQ[hn] = (t ~ /[\047"\\]/); gsub(/[\047"\\]/, "", t); HD[hn] = t; HS[hn] = strip; HT[hn] = NT[d]; HB[d, NT[d]] = ""
        continue
      }
      t = c; p++; c2 = substr(s, p, 1)
      if (c2 == ">" || c2 == "|" || c2 == "&" || (c == "<" && c2 == ">")) { t = t c2; p++ }
      red(d, t); continue
    }
    if (c == "~" && (!LIN || LC == "=" || LC == ":")) { p = tilde(s, p, n); LIN = 1; continue }
    if (c == "*" || c == "?" || c == "[") flag("g")
    if (c == "{") LBR = 1 # a brace expansion when the word has a , or .. before a } (endw)
    app(c); LIN = 1; p++
  }
  endw(d)
}

# --- one simple command: collect(d, i) puts its words in A[d,1..CM[d]] (flags AF, tokens CW) and its
# redirections in CRD[d,1..CN[d]] (targets CRT); it returns the operator that ends it
function collect(d, i,   n) {
  n = NT[d]; CM[d] = 0; CN[d] = 0; CS[d] = i
  while (i <= n && TT[d, i] != "o") {
    if (TT[d, i] == "r") { CN[d]++; CRD[d, CN[d]] = i; CRT[d, CN[d]] = 0 }
    else if (TR[d, i]) CRT[d, CN[d]] = i
    else { CM[d]++; CW[d, CM[d]] = i; A[d, CM[d]] = TV[d, i]; AF[d, CM[d]] = TF[d, i] }
    i++
  }
  CE[d] = i
  return i
}
function join(d, a, z,   k, n, pc) { n = 0; for (k = a; k <= z; k++) pc[++n] = (k > a ? " " : "") A[d, k]; return glue(pc, 1, n) }
function addpi(d, t) { NPI[d]++; PI[d, NPI[d]] = t }
function hasopt(d, p, letter, long,   k, w) {
  for (k = p + 1; k <= CM[d]; k++) { w = A[d, k]; if ((w ~ ("^-[A-Za-z]*" letter) && w !~ /^--/) || (long != "" && index(w, long) == 1)) return 1 }
  return 0
}
# prog(d, i): the word that is the program, past assignments, reserved words and the commands that only run
# the next one (env, sudo, exec, nice, timeout, xargs, caffeinate, script, npx …); 0 for none. Sets PENVI
# (env -i), PEXECC (exec -c) and PI[d,…] (env -S and npx -c text, which is a command)
function prog(d, i,   m, w, b, j, c, arg) {
  m = CM[d]; PENVI = 0; PEXECC = 0; NPI[d] = 0
  while (i <= m) {
    w = A[d, i]; b = gname(w, AF[d, i])
    if (w ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/ || w ~ /^(!|\{|\}|if|then|else|elif|do|while|until|builtin|nohup|setsid|noglob)$/) { i++; continue }
    if (w == "time") { i++; while (i <= m && A[d, i] ~ /^-/) i++; continue }
    if (w == "command") { if (i < m && A[d, i + 1] ~ /^-[A-Za-z]*[vV]/) return i; i++; while (i <= m && A[d, i] ~ /^-/) i++; continue }
    if (w == "exec") { i++; while (i <= m && A[d, i] ~ /^-/) { if (A[d, i] ~ /c/) PEXECC = 1; if (A[d, i] ~ /a$/) i++; i++ } continue }
    if (b == "sudo" || b == "doas") { i++; while (i <= m && A[d, i] ~ /^-/) { if (A[d, i] ~ /^-[ugChpDRTrtU]$/) i++; i++ } continue }
    if (b == "env") {
      i++
      while (i <= m) {
        w = A[d, i]
        if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { i++; continue }
        if (w == "-" || w == "--ignore-environment") { PENVI = 1; i++; continue }
        if (w == "--") { i++; break }
        if (w ~ /^--split-string=/) { addpi(d, substr(w, 16)); i++; continue }
        if (w == "--split-string") { if (i < m) addpi(d, A[d, i + 1]); i += 2; continue }
        if (w ~ /^--(unset|chdir)$/) { i += 2; continue }
        if (w ~ /^--/) { i++; continue }
        if (w ~ /^-/) {
          # -i before the first option that takes a value (u P S C), which takes the rest or the next word
          j = match(w, /[uPSC]/)
          if (index(j ? substr(w, 1, j - 1) : w, "i")) PENVI = 1
          if (j) { c = substr(w, j, 1); arg = substr(w, j + 1); if (arg == "") { arg = (i < m) ? A[d, i + 1] : ""; i++ } if (c == "S") addpi(d, arg) }
          i++; continue
        }
        break
      }
      continue
    }
    if (b == "nice") { i++; if (i <= m && A[d, i] == "-n") i += 2; else if (i <= m && A[d, i] ~ /^-/) i++; continue }
    if (b == "timeout" || b == "gtimeout") { i++; while (i <= m && A[d, i] ~ /^-/) { if (A[d, i] ~ /^(-s|-k|--signal|--kill-after)$/) i++; i++ } i++; continue }
    if (b == "xargs" || b == "gxargs") { i++; while (i <= m && A[d, i] ~ /^-/) { if (A[d, i] ~ /^-[IJLnPRSsEda]$/) i++; i++ } continue }
    if (b == "caffeinate") { i++; while (i <= m && A[d, i] ~ /^-/) { if (A[d, i] ~ /^-[tw]$/) i++; i++ } continue }
    if (b == "script") { i++; while (i <= m && A[d, i] ~ /^-/) { if (A[d, i] ~ /^-[FtT]$/) i++; i++ } i++; continue }
    if (b == "stdbuf" || b == "gstdbuf") { i++; while (i <= m && A[d, i] ~ /^-/) { if (A[d, i] ~ /^-[ioe]$/) i++; i++ } continue }
    if (b == "ionice" || b == "taskpolicy") { i++; while (i <= m && A[d, i] ~ /^-/) { if (A[d, i] ~ /^-[cnpdgtb]$/) i++; i++ } continue }
    if (b == "arch") { i++; while (i <= m && A[d, i] ~ /^-/) { if (A[d, i] == "-arch") i++; i++ } continue }
    if (b == "npx" || b == "bunx" || b == "pnpx") {
      i++
      while (i <= m && A[d, i] ~ /^-/) { if (A[d, i] ~ /^(-c|--call)$/ && i < m) addpi(d, A[d, i + 1]); if (A[d, i] ~ /^(-p|--package|-c|--call)$/) i++; i++ }
      continue
    }
    return i
  }
  return 0
}
# the rules about the program itself: tmux; claude --resume; a program that drops the identity
function progrules(d, p,   m, b, k, w, start, neg) {
  m = CM[d]
  if (PENVI || PEXECC) return R_ID
  if (p < 1 || p > m) return ""
  b = gname(A[d, p], AF[d, p])
  if (b == "tmux") return R_TMUX
  sub(/@.*$/, "", b)
  start = 0
  if (b == "claude" || b == "claude-code") start = p + 1
  else if (b ~ /^(node|nodejs|bun|deno)$/) {
    for (k = p + 1; k <= m; k++) if (A[d, k] !~ /^-/) { if (tolower(A[d, k]) ~ /claude-code(\/|@|$)/) start = k + 1; break }
  }
  if (start) for (k = start; k <= m; k++) {
    w = A[d, k]
    if (isprose(w, AF[d, k])) continue
    if (w ~ /^--(resume|continue|session-id|fork-session)(=|$)/ || w ~ /^-[A-Za-z]*[cr][A-Za-z]*$/) return R_RESUME
  }
  if (b ~ /^(unset|local|read|readarray|mapfile|for|select)$/) { for (k = p + 1; k <= m; k++) if (A[d, k] ~ ("^" IDS "$")) return R_ID }
  if (b == "export" || b == "declare" || b == "typeset") {
    neg = 0
    for (k = p + 1; k <= m; k++) {
      if ((b == "export" && A[d, k] ~ /^-[A-Za-z]*n/) || (b != "export" && A[d, k] ~ /^\+/)) neg = 1
      else if (neg && A[d, k] ~ ("^" IDS "$")) return R_ID
    }
  }
  if (b == "printf") for (k = p + 1; k <= m; k++) if ((A[d, k] == "-v" && k < m && A[d, k + 1] ~ ("^" IDS "$")) || A[d, k] ~ ("^-v" IDS "$")) return R_ID
  return ""
}
function identity(d,   k, w, m) {
  m = CM[d]
  for (k = 1; k <= m; k++) {
    w = A[d, k]
    if (isprose(w, AF[d, k])) continue
    if (w ~ ("(^|[^A-Za-z0-9_${])" IDS "\\+?=")) return R_ID
    if ((w == "-u" || w == "--unset") && k < m && A[d, k + 1] ~ ("^" IDS "$")) return R_ID
    if (w ~ ("^(-u|--unset=)" IDS "$")) return R_ID
  }
  return ""
}
# slots(d, p): which words of a search tool are options (SO 1; 2 an option argument; 3 an option whose value is a
# pattern) and which is the pattern (SP), read after ALL options (grep -r ~ -e x has no pattern word); WALKS when
# the tool walks a whole tree; TOOL its name
function slots(d, p,   m, b, k, w, takes, longs, pats, gp, pat, gotpat, j, c, e, skip, skippat, dflag, ended, isgrep, k0) {
  m = CM[d]; WALKS = 0; TOOL = ""
  for (k = 1; k <= m; k++) { SO[d, k] = 0; SP[d, k] = 0 }
  if (p < 1) return
  b = gname(A[d, p], AF[d, p]); TOOL = b; k0 = p + 1
  takes = ""; longs = ""; pats = "e"; gp = "ef"; pat = 0; isgrep = 0
  if (b ~ /^(grep|egrep|fgrep|zgrep|ggrep)$/) { takes = "ABCDdefm"; longs = "|regexp|file|include|exclude|exclude-dir|context|after-context|before-context|max-count|directories|devices|label|binary-files|"; pat = 1; isgrep = 1 }
  else if (b == "rg") { WALKS = 1; takes = "ABCEMTdefgjmrt"; pats = "eg"; longs = "|regexp|file|glob|iglob|type|type-not|type-add|type-clear|max-count|context|after-context|before-context|max-depth|maxdepth|threads|replace|sort|sortr|max-filesize|encoding|ignore-file|pre|pre-glob|colors|color|engine|path-separator|context-separator|field-match-separator|field-context-separator|dfa-size-limit|regex-size-limit|max-columns|hostname-bin|hyperlink-format|"; pat = 1 }
  else if (b == "ag") { WALKS = 1; takes = "ABCGgm"; pats = "Gg"; gp = "g"; longs = "|after|before|context|file-search-regex|max-count|depth|ignore|ignore-dir|pager|path-to-ignore|"; pat = 1 }
  else if (b == "ack") { WALKS = 1; takes = "ABCm"; longs = "|after-context|before-context|context|max-count|match|type|ignore-dir|ignore-file|output|"; pat = 1 }
  else if (b == "fd" || b == "fdfind") { WALKS = 1; takes = "etEdjScxX"; pats = "E"; gp = ""; longs = "|extension|type|exclude|max-depth|min-depth|exact-depth|threads|size|color|exec|exec-batch|base-directory|max-results|changed-within|changed-before|owner|format|"; pat = 1 }
  else if (b ~ /^(find|gfind|du|gdu|tar|gtar|bsdtar)$/) WALKS = 1
  else if (b == "git") {
    k = p + 1
    while (k <= m && A[d, k] ~ /^-/) { if (A[d, k] ~ /^(-C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env)$/) k++; k++ }
    if (k > m) return
    k0 = k + 1
    if (A[d, k] == "grep") { takes = "efABCmO"; longs = "|regexp|file|after-context|before-context|context|max-count|"; pat = 1 }
    else if (A[d, k] ~ /^(log|show|diff|whatchanged|rev-list|shortlog|reflog)$/) { takes = "SGn"; pats = "SG"; gp = ""; longs = "|grep|author|committer|"; pat = 0 }
    else return
  } else if (b != "ls" && b != "gls") return
  gotpat = 0; skip = 0; ended = 0; skippat = 0; dflag = 0
  for (k = k0; k <= m; k++) {
    w = A[d, k]
    if (skip) { SO[d, k] = 2; if (skippat) SP[d, k] = 1; if (dflag && w == "recurse") WALKS = 1; skip = 0; continue }
    if (ended || w == "-" || w !~ /^-/) continue
    SO[d, k] = 1
    if (w == "--") { ended = 1; continue }
    if (substr(w, 1, 2) == "--") {
      e = substr(w, 3); sub(/=.*$/, "", e)
      if (isgrep && (e == "recursive" || e == "dereference-recursive" || w == "--directories=recurse")) WALKS = 1
      if ((b == "ls" || b == "gls") && e == "recursive") WALKS = 1
      if (e ~ /^(regexp|file|files|match|type-list)$/ && b != "fd" && b != "fdfind") gotpat = 1
      if (index(longs, "|" e "|") && !index(w, "=")) { skip = 1; skippat = (e ~ PATS); dflag = (isgrep && e == "directories") }
      else if (e ~ PATS) SO[d, k] = 3
      continue
    }
    for (j = 2; j <= length(w); j++) {
      c = substr(w, j, 1)
      if (isgrep && (c == "r" || c == "R")) WALKS = 1
      if ((b == "ls" || b == "gls") && c == "R") WALKS = 1
      if (index(takes, c)) {
        if (index(gp, c)) gotpat = 1
        if (substr(w, j + 1) == "") { skip = 1; skippat = (index(pats, c) > 0); dflag = (isgrep && c == "d") }
        else if (isgrep && c == "d" && substr(w, j + 1) == "recurse") WALKS = 1
        else if (index(pats, c)) SO[d, k] = 3
        break
      }
    }
  }
  if (pat && !gotpat) for (k = k0; k <= m; k++) if (!SO[d, k]) { SP[d, k] = 1; break }
}
function walkmsg(tool, w) { return tool " walks all of " w ", which holds the leads\047 private memory folders (~/.wolfmux/memory), their conversations, Claude Code\047s records or its temporary folder; search a narrower folder." }

# --- paths: canon(p) makes p plain (.., ., //, and the symlinks guard_bash found, part by part)
# Every step is linear in the path: a path with no //, . or .. part and no link known is plain already; the
# prefixes looked up in LINK (lower case, pre[]) are built only up to the longest link (MAXLINK); the result is
# glued, not added to part by part.
function canon(p,   n, parts, k, seg, cnt, st, i, pre, tp, m) {
  if (!NLINK && substr(p, 1, 1) == "/" && p !~ /\/\/|\/\.\.?(\/|$)/) { if (length(p) > 1 && substr(p, length(p)) == "/") p = substr(p, 1, length(p) - 1); return p }
  n = split(p, parts, "/"); cnt = 0
  for (k = 1; k <= n; k++) {
    seg = parts[k]
    if (seg == "" || seg == ".") continue
    if (seg == "..") { if (cnt) cnt--; continue }
    st[++cnt] = seg
    if (NLINK) {
      pre[cnt] = lpre(pre, cnt, seg)
      if (pre[cnt] in LINK) { m = split(LINK[pre[cnt]], tp, "/"); cnt = 0; for (i = 1; i <= m; i++) if (tp[i] != "") { st[++cnt] = tp[i]; pre[cnt] = lpre(pre, cnt, tp[i]) } }
    }
  }
  if (!cnt) return "/"
  for (i = 1; i <= cnt; i++) st[i] = "/" st[i]
  return glue(st, 1, cnt)
}
# lpre(pre, i, seg): the lower-case path of parts 1..i, "\005" once it is longer than any link
function lpre(pre, i, seg,   b) {
  b = (i > 1) ? pre[i - 1] : ""
  if (b == "\005" || length(b) + 1 + length(seg) > MAXLINK) return "\005"
  return b "/" tolower(seg)
}
function rpath(v, here) { v = rep(v, "\002", here); if (substr(v, 1, 1) == "/") return canon(v); return canon(here "/" v) }
# wpath(v, here): the path a word names (an option or assignment: its value), "" for none; a path that ends
# outside the own worktree counts against the budget
function wpath(v, here,   r) {
  if (v ~ /^-/) { if (!index(v, "=")) return ""; v = substr(v, index(v, "=") + 1) }
  else if (v ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) v = substr(v, index(v, "=") + 1)
  if (v == "" || v ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) return ""
  r = rpath(v, here)
  if (!inown(r) && ++RESOLVED > 300 && DENY == "") DENY = R_SPLIT
  if (++PATHS % 50 == 0) clock()
  return r
}
# cand(p): print the parts of p under the own worktree or /tmp, for guard_bash to test for symlinks
function cand(p,   l, k, start, q, n) {
  l = tolower(p); start = 0
  for (k = 1; k <= NOWN; k++) if (inside(l, OWN[k])) { start = length(OWN[k]) + 1; break }
  if (!start && match(l, /^(\/private)?\/(tmp|var\/folders)\//)) start = RLENGTH
  if (!start) return
  # up to 4096 bytes: the system names no longer path, so a link further on is never reached
  q = start
  while ((n = idx(p, q + 1, "/")) > 0 && n <= 4097) { emit(substr(p, 1, n - 1)); q = n }
  if (length(p) <= 4096) emit(p)
}
function emit(x) {
  if (x in SEEN) return
  SEEN[x] = 1
  if (++NCAND > 12000) { if (DENY == "") DENY = R_SPLIT; return }
  print "L" x
}
# a wildcard: refused when its folder is your home, or when the part with the wildcard can match the next part
# of a private folder (ls /tmp/*.log passes, ls /tmp/* and cat ~/.wolfmux/mem*/… do not)
function globre(g,   i, n, c, r, j) {
  r = "^"; n = length(g)
  for (i = 1; i <= n; i++) {
    c = substr(g, i, 1)
    if (c == "*") r = r ".*"
    else if (c == "?") r = r "."
    else if (c == "[") { j = index(substr(g, i + 1), "]"); if (j) { r = r "."; i += j } else r = r "\\[" }
    else if (c == "{") { j = index(substr(g, i + 1), "}"); if (j && substr(g, i + 1, j - 1) ~ /,|\.\./) { r = r ".*"; i += j } else r = r "\\{" }
    else if (index("\\^$.|+()", c)) r = r "\\" c
    else r = r c
  }
  return r "$"
}
function wildin(l, re, arr, n,   k, pre, rest) {
  pre = (l == "/") ? "/" : l "/"
  for (k = 1; k <= n; k++) if (substr(arr[k], 1, length(pre)) == pre) { rest = substr(arr[k], length(pre) + 1); sub(/\/.*$/, "", rest); if (rest ~ re) return arr[k] }
  return ""
}
function wild(v, here,   pre, dir, comp, l, r, re) {
  v = rep(v, "\002", here)
  if (v ~ /^-/) { if (!index(v, "=")) return ""; v = substr(v, index(v, "=") + 1) }
  else if (v ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) v = substr(v, index(v, "=") + 1)
  if (length(v) > 4096) return "that command has a wildcard word over 4096 characters, too long for the guard to follow; name the files."
  if (!match(v, /[*?[]|\{[^}]*(,|\.\.)/)) return ""
  pre = substr(v, 1, RSTART - 1)
  dir = pre; sub(/[^\/]*$/, "", dir)
  comp = substr(v, length(dir) + 1); sub(/\/.*$/, "", comp)
  if (substr(dir, 1, 1) != "/") dir = here "/" dir
  dir = canon(dir); l = tolower(dir)
  if ((r = lit(dir)) != "") return r
  if (l == LHOME) return "that command has a wildcard in your home folder (" v "), which also matches the leads\047 private folders under it; name the files."
  re = globre(tolower(comp))
  if ((r = wildin(l, re, MEM, NMEM)) != "" || (r = wildin(l, re, STATE, NSTATE)) != "" || (r = wildin(l, re, TREES, NTREES)) != "" || (r = wildin(l, re, TR, NTR)) != "" || (r = wildin(l, re, CL, NCL)) != "" || (r = wildin(l, re, CT, NCT)) != "")
    return "that command has a wildcard (" v ") that can match a private folder (" r "); name the files."
  return ""
}

# --- the rules that need the command in order (checkB)
function gitrules(d, p,   m, k, j, w, sc, name) {
  m = CM[d]; k = p + 1
  while (k <= m && A[d, k] ~ /^-/) { if (A[d, k] ~ /^(-C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env|--exec-path)$/) k++; k++ }
  if (k > m) return ""
  sc = A[d, k]
  if (sc == "worktree") { for (j = k + 1; j <= m; j++) if (A[d, j] !~ /^-/) { if (A[d, j] ~ /^(add|remove|move|prune|repair|lock|unlock)$/) return R_WT; break } }
  if (sc == "branch") for (j = k + 1; j <= m; j++) { w = A[d, j]; if (w ~ /^--(delete|move|copy|force)$/ || (w ~ /^-[A-Za-z]*[dDmMcCf]/ && w !~ /^--/)) return R_BRANCH }
  if (sc == "update-ref") return R_BRANCH
  if (sc == "switch") return R_SWITCH
  if (sc == "checkout") {
    name = ""
    for (j = k + 1; j <= m; j++) {
      w = A[d, j]
      if (w == "--") break
      if (w ~ /^(-b|-B|--orphan|--detach)$/ || w ~ /^-[A-Za-z]*[bB]$/) return R_SWITCH
      if (w ~ /^-/) continue
      if (name == "") name = w
    }
    if (name != "" && name != BRANCH) BR[++NB] = name
  }
  if (sc == "push") for (j = k + 1; j <= m; j++) { w = A[d, j]; if (w ~ /^(--all|--mirror|--delete|-d)$/ || w ~ /^\+/ || w ~ /(^|:)(refs\/heads\/)?(main|master)$/) return R_PUSH }
  return ""
}
function rootrules(d, p, b, here,   m, k, w, v) {
  m = CM[d]
  if (!NROOT) return ""
  for (k = 1; k <= m; k++) {
    w = A[d, k]; v = ""
    if ((w == "-C" || w == "--git-dir" || w == "--work-tree") && k < m) v = A[d, k + 1]
    else if (w ~ /^(--git-dir|--work-tree)=/) v = substr(w, index(w, "=") + 1)
    else if (w ~ /^-C./) v = substr(w, 3)
    if (v != "" && !index(AF[d, k], "$") && inroot(rpath(v, here))) return R_ROOT
  }
  if (p < 1) return ""
  if (b ~ /^(rm|mv|rmdir|chmod|chown|ln|truncate|dd|tee|install)$/ || ((b == "sed" || b == "perl") && hasopt(d, p, "i", "--in-place"))) {
    for (k = p + 1; k <= m; k++) if (RP[d, k] != "" && inroot(RP[d, k])) return R_ROOT
  }
  if (b ~ /^(cp|rsync|ditto)$/ && m > p && RP[d, m] != "" && inroot(RP[d, m])) return R_ROOT
  return roottext(d, p, b)
}
# a read-only checkout whose path has a blank in it, written without quotes (rm -rf $ROOT/src): the shell splits it,
# but the command still means that checkout (and would hit another folder). The words joined again, read as text.
function roottext(d, p, b,   k, j, w, r, sp, n, pc) {
  sp = 0
  for (k = 1; k <= NROOT; k++) if (index(ROOT[k], " ")) sp = 1
  if (!sp) return ""
  n = 0
  for (k = CS[d]; k < CE[d]; k++) if (TT[d, k] == "r" || !isprose(TV[d, k], TF[d, k])) pc[++n] = " " TV[d, k]
  w = tolower(glue(pc, 1, n))
  for (k = 1; k <= NROOT; k++) if (index(ROOT[k], " ")) w = rep(w, ROOT[k], "@root@")
  if (!index(w, "@root@")) return ""
  if (w ~ /(^| )(>|>>|>\||>&|<>) @root@/) return R_ROOT
  gsub(/ (>|>>|>\||>&|<>|<|<&|<<<|<<) [^ ]*/, "", w)
  if (w ~ /(^| )(cd|pushd)( -[a-z@]+)* @root@/ || w ~ /(^| )(-c ?|--git-dir[ =]|--work-tree[ =])@root@/) return R_ROOT
  if (b ~ /^(rm|mv|rmdir|chmod|chown|ln|truncate|dd|tee|install)$/ || ((b == "sed" || b == "perl") && hasopt(d, p, "i", "--in-place"))) return R_ROOT
  if (b ~ /^(cp|rsync|ditto)$/ && w ~ /@root@[^ ]*$/) return R_ROOT
  return ""
}
function lnrule(d, p, here,   m, k, w, r, l) {
  m = CM[d]
  for (k = p + 1; k <= m; k++) {
    w = A[d, k]
    if (w ~ /^-/ || isprose(w, AF[d, k]) || index(AF[d, k], "$")) continue
    r = rpath(w, here); l = tolower(r)
    if (inown(r) || inany(r, SCR, NSCR)) continue
    if (inside(l, LHOME) || substr(l, 1, 7) == "/users/" || inany(r, CT, NCT) || holds(l) || lit(r) != "") return R_LINK
  }
  return ""
}
function cdto(d, p, b, here,   m, k, w) {
  m = CM[d]
  if (b == "popd") { if (ND[d] > 0) return DS[d, --ND[d]]; return "" }
  for (k = p + 1; k <= m; k++) { w = A[d, k]; if (w == "--") { k++; break } if (w !~ /^-./) break }
  if (k > m) return (b == "cd") ? canon(HOME) : ""
  w = A[d, k]
  if (w == "-") return OLD[d]
  if (index(AF[d, k], "$") || index(AF[d, k], "g")) return ""
  # a group word is followed only when it stands for one word (cd ~/(src)); with more it is a wildcard
  if (index(AF[d, k], "G")) { if (galts(w, AF[d, k], ALT) > 1 || GSTAR) return ""; w = ALT[1] }
  w = rpath(w, here)
  if (b == "pushd") DS[d, ND[d]++] = here
  return w
}
# what a command prints into a pipe, when it can be read off the text: echo, printf, cat of a heredoc or <<<
function producer(d, p,   m, b, k, n, pc) {
  m = CM[d]
  if (p < 1) return ""
  b = gname(A[d, p], AF[d, p])
  if (b == "echo") { k = p + 1; while (k <= m && A[d, k] ~ /^-[neE]+$/) k++; return join(d, k, m) }
  if (b == "printf") { k = p + 1; if (k <= m && A[d, k] == "-v") k += 2; n = 0; for (; k <= m; k++) pc[++n] = A[d, k] "\n"; return glue(pc, 1, n) }
  if (b == "cat" && p == m) return stdintext(d)
  return ""
}
function stdintext(d,   k, j, n, pc) {
  n = 0
  for (k = 1; k <= CN[d]; k++) { j = CRD[d, k]; if (TV[d, j] == "<<") pc[++n] = HB[d, j]; else if (TV[d, j] == "<<<" && CRT[d, k]) pc[++n] = TV[d, CRT[d, k]] "\n" }
  return glue(pc, 1, n)
}
function runstdin(d, here, inp,   t) { t = stdintext(d); if (t == "") t = inp; if (t == "") return ""; return run(t, d + 1, here) }
# a <( ) whose output a shell or source reads: what its last command prints
function runproc(d, tok, here,   k, i, e, t) {
  for (k = 1; k <= NS[d]; k++) if (SA[d, k] == tok && SK[d, k] == "p") {
    if (d + 1 > 3) return R_NEST
    lex(SX[d, k], d + 1); t = ""; i = 1
    while (i <= NT[d + 1]) { e = collect(d + 1, i); if (CM[d + 1] > 0) t = producer(d + 1, prog(d + 1, 1)); i = e + 1 }
    if (t != "") return run(t, d + 1, here)
  }
  return ""
}
# what this command runs as another command: the script of sh -c (options before or after -c, --), a shell
# that reads stdin (a heredoc, <<<, a pipe from echo/printf/cat, -s, -, /dev/stdin, <( )), eval, source of
# stdin, env -S, npx -c, ssh HOST TEXT (in your home), watch TEXT, make -f - with a heredoc
function inner(d, p, b, here, inp,   m, k, j, w, hasc, stdin, r, t) {
  m = CM[d]
  for (k = 1; k <= NPI[d]; k++) if ((r = run(PI[d, k], d + 1, here)) != "") return r
  for (k = 1; k <= m; k++) {
    w = A[d, k]
    if (isprose(w, AF[d, k]) || gname(w, AF[d, k]) !~ SHELLS) continue
    hasc = 0; stdin = 0; j = k + 1
    while (j <= m) {
      w = A[d, j]
      if (w == "--") { j++; break }
      if (w == "-") { stdin = 1; j++; break }
      if (w ~ /^[-+][oO]$/ || w == "--rcfile" || w == "--init-file") { j += 2; continue }
      if (w ~ /^--./) { j++; continue }
      if (w ~ /^[-+][A-Za-z]+$/) { if (w ~ /^-[A-Za-z]*c/) hasc = 1; if (w ~ /^-[A-Za-z]*s/) stdin = 1; j++; continue }
      break
    }
    if (hasc) { if (j <= m && (r = run(A[d, j], d + 1, here)) != "") return r; continue }
    if (stdin || j > m || A[d, j] ~ /^\/dev\/(stdin|fd\/0)$/) { if ((r = runstdin(d, here, inp)) != "") return r; continue }
    if (index(AF[d, j], "P") && (r = runproc(d, CW[d, j], here)) != "") return r
  }
  if (p < 1) return ""
  if (b == "eval" && p < m && (r = run(join(d, p + 1, m), d + 1, here)) != "") return r
  if ((b == "source" || b == ".") && p < m) {
    if (A[d, p + 1] ~ /^(-|\/dev\/stdin|\/dev\/fd\/0)$/) { if ((r = runstdin(d, here, inp)) != "") return r }
    else if (index(AF[d, p + 1], "P") && (r = runproc(d, CW[d, p + 1], here)) != "") return r
  }
  if (b == "ssh") {
    for (k = p + 1; k <= m; k++) { w = A[d, k]; if (w !~ /^-/) break; if (w ~ /^-[46AaCfGgKkMNnqsTtVvXxYy]*[BbcDEeFIiJLlmOopQRSWw]$/) k++ }
    if (k < m && (r = run(join(d, k + 1, m), d + 1, HOME)) != "") return r
  }
  if (b == "watch") {
    for (k = p + 1; k <= m; k++) { w = A[d, k]; if (w !~ /^-/) break; if (w ~ /^(-n|--interval|-q|--equexit)$/) k++ }
    if (k <= m && (r = run(join(d, k, m), d + 1, here)) != "") return r
  }
  if (b == "make" || b == "gmake") for (k = p + 1; k < m; k++) if (A[d, k] == "-f" && A[d, k + 1] ~ /^(-|\/dev\/stdin)$/) {
    t = stdintext(d); if (t == "") t = inp
    gsub(/\n\t+/, "\n", t); sub(/^\t+/, "", t)
    if (t != "" && (r = run(t, d + 1, here)) != "") return r
  }
  return ""
}

# --- the two passes
# alit(v, f, here): lit() on the word, and on every word a group word stands for
function alit(v, f, here,   n, k, r) {
  if ((r = lit(rep(v, "\002", here))) != "" || !index(f, "G")) return r
  n = galts(v, f, ALT)
  for (k = 1; k <= n; k++) if ((r = lit(rep(ALT[k], "\002", here))) != "") return r
  return ""
}
function checkA(d, here,   m, k, j, v, r, p, q, b, n, i) {
  m = CM[d]
  for (k = 1; k <= m; k++) { v = A[d, k]; if (!isprose(v, AF[d, k]) && (r = alit(v, AF[d, k], here)) != "") return r }
  for (k = 1; k <= CN[d]; k++) if ((j = CRT[d, k])) { v = TV[d, j]; if (!isprose(v, TF[d, j]) && (r = alit(v, TF[d, j], here)) != "") return r }
  p = prog(d, 1)
  if ((r = progrules(d, p)) != "" || (r = identity(d)) != "") return r
  if (p < 1) return ""
  b = gname(A[d, p], AF[d, p])
  for (k = p + 1; k <= m; k++) if (A[d, k] ~ /^-(exec|execdir|ok|okdir)$/ || ((b == "fd" || b == "fdfind") && A[d, k] ~ /^(-x|-X|--exec|--exec-batch)$/)) {
    q = prog(d, k + 1)
    if ((r = progrules(d, q)) != "") return r
  }
  slots(d, p)
  if (WALKS) for (k = p + 1; k <= m; k++) {
    v = A[d, k]
    if (SO[d, k] == 1 || SO[d, k] == 3 || SP[d, k] || isprose(v, AF[d, k]) || index(AF[d, k], "$")) continue
    n = galts(v, AF[d, k], ALT)
    for (i = 1; i <= n; i++) { v = rep(ALT[i], "\002", here); if (substr(v, 1, 1) == "/" && holds(tolower(canon(v)))) return walkmsg(TOOL, A[d, k]) }
  }
  return ""
}
function phaseA(d, here,   i, e, r) {
  i = 1
  while (i <= NT[d]) {
    e = collect(d, i)
    if ((CM[d] > 0 || CN[d] > 0) && (r = checkA(d, here)) != "") return r
    if (DENY != "") return DENY
    i = e + 1
  }
  return ""
}
# globby(v, f, gs): the word goes to wild() (a wildcard written out, or a group read as "*")
function globby(v, f, gs) { return gs || (index(f, "g") && v ~ /[*?[]|\{[^}]*(,|\.\.)/) }
function checkB(d, here, s, e, topipe,   m, k, j, v, r, p, b, walks, tool, inp, tgt, any, rp, n, i, gs) {
  m = CM[d]; NEWHERE = ""
  inp = PROD[d]; PROD[d] = ""
  for (k = 1; k <= NS[d]; k++) if (SA[d, k] >= s && SA[d, k] < e && (r = run(SX[d, k], d + 1, here)) != "") return r
  collect(d, s)
  p = prog(d, 1); b = (p ? gname(A[d, p], AF[d, p]) : "")
  slots(d, p); walks = WALKS; tool = TOOL; any = 0
  # every word a group word stands for is checked; with more than one, the group is also a wildcard
  for (k = 1; k <= m; k++) {
    RP[d, k] = ""; v = A[d, k]
    if (isprose(v, AF[d, k]) || SP[d, k] || SO[d, k] == 3 || (SO[d, k] == 1 && !index(v, "=")) || index(AF[d, k], "$")) continue
    n = galts(v, AF[d, k], ALT); gs = GSTAR
    if (n > 1 && (r = wild(gstar(v), here)) != "") return r
    for (i = 1; i <= n; i++) {
      v = ALT[i]
      if (globby(v, AF[d, k], gs)) { if ((r = wild(v, here)) != "") return r; continue }
      rp = wpath(v, here)
      if (rp == "") continue
      if (RP[d, k] == "" || inroot(rp)) RP[d, k] = rp
      if ((r = lit(rp)) != "") return r
      cand(rp)
      if (walks && k > p && SO[d, k] != 1) { if (SO[d, k] == 0) any = 1; if (holds(tolower(rp))) return walkmsg(tool, v) }
    }
  }
  if (DENY != "") return DENY
  if (walks && !any && p > 0 && tool !~ /tar$/ && holds(tolower(here))) return walkmsg(tool, here)
  for (k = 1; k <= CN[d]; k++) if ((j = CRT[d, k])) {
    v = TV[d, j]
    if (isprose(v, TF[d, j]) || index(TF[d, j], "$")) continue
    n = galts(v, TF[d, j], ALT); gs = GSTAR
    if (n > 1 && (r = wild(gstar(v), here)) != "") return r
    for (i = 1; i <= n; i++) {
      v = ALT[i]
      if (globby(v, TF[d, j], gs)) { if ((r = wild(v, here)) != "") return r; continue }
      rp = rpath(v, here)
      if ((r = lit(rp)) != "") return r
      if (TV[d, CRD[d, k]] ~ />/ && inroot(rp)) return R_ROOT
      cand(rp)
    }
  }
  if (b == "git" && (r = gitrules(d, p)) != "") return r
  if ((r = rootrules(d, p, b, here)) != "") return r
  if ((b == "ln" || (b == "cp" && hasopt(d, p, "s", "--symbolic-link"))) && (r = lnrule(d, p, here)) != "") return r
  tgt = ""
  if (b == "cd" || b == "pushd" || b == "popd") {
    tgt = cdto(d, p, b, here)
    if (tgt != "") { if ((r = lit(tgt)) != "") return r; if (inroot(tgt)) return R_ROOT; cand(tgt) }
  }
  if ((r = inner(d, p, b, here, inp)) != "") return r
  if (topipe) PROD[d] = producer(d, p)
  if (tgt != "") { OLD[d] = here; NEWHERE = tgt }
  return ""
}
function phaseB(d, here,   i, e, o, r, list, pipe, piped, sd) {
  list = here; pipe = here; piped = 0; sd = 0; OLD[d] = ""; ND[d] = 0; PROD[d] = ""
  i = 1
  while (i <= NT[d]) {
    e = collect(d, i)
    o = (e <= NT[d]) ? TV[d, e] : ";"
    if (CM[d] > 0 || CN[d] > 0) {
      if ((r = checkB(d, here, i, e, o == "|")) != "") return r
      if (NEWHERE != "") here = NEWHERE
    }
    if (DENY != "") return DENY
    if (o == ";") { if (piped) here = pipe; piped = 0; list = here; pipe = here; PROD[d] = "" }
    else if (o == "&&" || o == "||") { if (piped) here = pipe; piped = 0; pipe = here; PROD[d] = "" }
    else if (o == "|") { here = pipe; piped = 1 }
    else if (o == "&") { here = list; piped = 0; pipe = list; PROD[d] = "" }
    else if (o == "(") { SHH[d, sd] = here; SHL[d, sd] = list; SHP[d, sd] = pipe; SHQ[d, sd] = piped; sd++; list = here; pipe = here; piped = 0 }
    else if (o == ")") { if (sd > 0) { sd--; here = SHH[d, sd]; list = SHL[d, sd]; pipe = SHP[d, sd]; piped = SHQ[d, sd] } }
    i = e + 1
  }
  return ""
}
function run(text, d, here,   r) {
  if (d > 3) return R_NEST
  if (DENY != "") return DENY
  lex(text, d)
  if (DENY != "") return DENY
  if ((r = phaseA(d, here)) != "") return r
  return phaseB(d, here)
}
# strs(text, here): the strings of a tool call (\001 between them), each read as one quoted word: the private
# folders by name, then the path it names from here (a leading ~/ is the home folder); prose (a blank in it) is skipped
function strs(text, here,   n, sv, k, v, r, rp) {
  n = split(text, sv, "\001")
  for (k = 1; k <= n; k++) {
    v = sv[k]
    if (v == "" || isprose(v, (v ~ /[ \t\n]/) ? "qp" : "q")) continue
    if (v == "~" || substr(v, 1, 2) == "~/") v = HOME substr(v, 2)
    if ((r = lit(v)) != "") return r
    if ((rp = wpath(v, here)) == "") continue
    if ((r = lit(rp)) != "") return r
    cand(rp)
    if (DENY != "") return DENY
  }
  return ""
}
BEGIN {
  init()
  print "T" T0
  if (ENVIRON["GA_MODE"] == "strings") r = strs(ENVIRON["GA_CMD"], ENVIRON["GA_CWD"])
  else r = run(ENVIRON["GA_CMD"], 0, ENVIRON["GA_CWD"])
  if (r != "") { print "D" r; exit }
  for (k = 1; k <= NB; k++) print "B" BR[k]
  print "OK"
}'

# guard_bash <command> [strings] — sets GUARD_REASON when the command reaches outside (GUARD_SCAN, then the
# symlinks it names, then git checkout of another branch); with "strings", <command> is the strings of a tool
# call, \001 after each, read as words (strs)
guard_bash() {
  local out line path links="" new pass=0 ok name checkouts="" t0=""
  GUARD_REASON=""
  # the size first, before any work (cmd_guard runs with LC_ALL=C: bytes; guard_check's jq hands over \001 for one
  # over 65536 characters, so that bash never reads it): a bigger one is no command a worker types
  if [ "${#1}" -gt 65536 ] || [ "$1" = $'\001' ]; then GUARD_REASON="that command is over 64 KB; split this command; the guard reads at most 64 KB." && return 0; fi
  while [ "$pass" -lt 4 ]; do
    pass=$((pass + 1)) new="" ok=0 checkouts=""
    out="$(GA_CMD="$1" GA_MODE="${2:-}" GA_T0="$t0" GA_LINKS="$links" GA_CWD="$GUARD_CWD" GA_HOME="$HOME" GA_USER="${USER:-}" GA_BRANCH="$GUARD_BRANCH" \
      GA_OWN="$GUARD_L_OWN" GA_SCR="$GUARD_L_SCR" GA_TREES="$GUARD_L_TREES" GA_STATE="$GUARD_L_STATE" GA_MEM="$GUARD_L_MEM" \
      GA_TR="$GUARD_L_TR" GA_CL="$GUARD_L_CL" GA_CT="$GUARD_L_CT" GA_ROOT="$GUARD_L_ROOT" GA_TRSHOW="$GUARD_TRANSCRIPTS" \
      GA_CTSHOW="${GUARD_CTMP[0]:-}" GA_RO="$GUARD_READONLY" LC_ALL=C /usr/bin/awk "$GUARD_SCAN" 2>/dev/null)"
    while IFS= read -r line; do
      case "$line" in
        D*) GUARD_REASON="${line#D}" && return 0 ;;
        L*)
          path="${line#L}"
          [ -L "$path" ] || continue
          case "$links" in *"$path"$'\t'*) continue ;; esac
          if guard_link "$path"; then new="$new$path"$'\t'"$GUARD_P"$'\n'; fi
          ;;
        B*) checkouts="$checkouts${line#B}"$'\n' ;;
        T*) t0="${line#T}" ;; # the clock of the first pass: the next passes count from it
        OK) ok=1 ;;
      esac
    done <<<"$out"
    # an awk that stopped half way (an error) decided nothing: refuse rather than let the command through
    if [ "$ok" -ne 1 ]; then GUARD_REASON="the guard could not read that command; simplify it or split it." && return 0; fi
    [ -n "$new" ] || break
    links="$links$new"
  done
  while IFS= read -r name; do
    [ -n "$name" ] && [ "$name" != "$GUARD_BRANCH" ] && [ -n "$GIT_BIN" ] || continue
    if "$GIT_BIN" -C "$GUARD_OWN" show-ref --verify -q "refs/heads/$name" 2>/dev/null; then
      GUARD_REASON="$(printf 'stay on your own branch (%s); "%s" is another branch.' "$GUARD_BRANCH" "$name")" && return 0
    fi
  done <<<"$checkouts"
  return 0
}

# guard_setup — every path the checks compare, resolved once (guard_phys: no fork). GUARD_L_* are the same as
# newline lists for GUARD_SCAN: as configured and as resolved, in both of which a command may spell them.
guard_setup() {
  local path target p
  guard_phys "$WOLFMUX_WORKTREE" /
  GUARD_OWN="$GUARD_P"
  guard_phys "$WOLFMUX_DATA/worktrees" /
  GUARD_TREES="$GUARD_P" GUARD_L_TREES="$GUARD_P"$'\n'"$WOLFMUX_DATA/worktrees"
  guard_phys "$WOLFMUX_DATA/state" /
  GUARD_STATE="$GUARD_P" GUARD_L_STATE="$GUARD_P"$'\n'"$WOLFMUX_DATA/state"
  guard_phys "$WOLFMUX_DATA/memory" /
  GUARD_MEMORY="$GUARD_P" GUARD_L_MEM="$GUARD_P"$'\n'"$WOLFMUX_DATA/memory"
  GUARD_L_OWN="$GUARD_OWN"$'\n'"$WOLFMUX_WORKTREE"
  GUARD_ROOT=""
  if [ -n "${WOLFMUX_ROOT:-}" ] && [ -d "$WOLFMUX_ROOT" ]; then guard_phys "$WOLFMUX_ROOT" / && GUARD_ROOT="$GUARD_P"; fi
  # Every lead runs in the project's own folder, so Claude Code keeps every lead's conversation in ONE
  # folder named after it (transcripts_dir, spelled out here without its forks): a worker never needs them,
  # and the memory team's lead reads its private memory there (mem boot prints the card). Its memory/ is the
  # project's shared memory, which every session may read.
  GUARD_TRANSCRIPTS="" GUARD_L_TR=""
  if [ -n "$GUARD_ROOT" ]; then
    p="${GUARD_ROOT//[^A-Za-z0-9]/-}"
    path="${WOLFMUX_CLAUDE_PROJECTS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}/$p"
    guard_phys "$path" /
    GUARD_TRANSCRIPTS="$GUARD_P" GUARD_L_TR="$GUARD_P"$'\n'"$path"
  fi
  # Claude Code's records of sessions outside the project folders (guard_claude_private), as configured and resolved
  GUARD_CLAUDE=() GUARD_L_CL=""
  for path in "${HOME:+$HOME/.claude}" "${CLAUDE_CONFIG_DIR:-}"; do
    [ -n "$path" ] || continue
    for target in file-history todos paste-cache sessions session-env history.jsonl; do
      guard_phys "$path/$target" /
      GUARD_CLAUDE+=("$GUARD_P" "${path%/}/$target")
    done
  done
  if [ -n "${WOLFMUX_CLAUDE_SESSIONS:-}" ]; then
    guard_phys "$WOLFMUX_CLAUDE_SESSIONS" /
    GUARD_CLAUDE+=("$GUARD_P" "$WOLFMUX_CLAUDE_SESSIONS")
  fi
  for path in "${GUARD_CLAUDE[@]}"; do GUARD_L_CL="$GUARD_L_CL$path"$'\n'; done
  # Claude Code's temporary folder: every session's task output and scratchpad, the leads' too. Each session's
  # own root there is named after the folder it runs in, every character that is not a letter or digit as "-":
  # the worker's own is open to it. WOLFMUX_CLAUDE_TMP is for tests only: the hook's environment comes from the
  # agent's launch (lib/agents.sh), and no command a worker runs can set it for the hook.
  path="${WOLFMUX_CLAUDE_TMP:-/private/tmp/claude-${UID:-$(id -u)}}"
  guard_phys "$path" /
  GUARD_CTMP=("$GUARD_P" "$path") GUARD_SCRATCH=() GUARD_L_SCR=""
  GUARD_L_CT="$GUARD_P"$'\n'"$path"
  for p in "$GUARD_OWN" "$WOLFMUX_WORKTREE"; do
    p="${p//[^A-Za-z0-9]/-}"
    GUARD_SCRATCH+=("${GUARD_CTMP[0]}/$p" "$path/$p")
    GUARD_L_SCR="$GUARD_L_SCR${GUARD_CTMP[0]}/$p"$'\n'"$path/$p"$'\n'
  done
  # A teammate spawned with --repo has its worktree in another repository: that repository's
  # own checkout is read-only for it, exactly as the lead's is.
  GUARD_REPO=""
  if [ -n "${WOLFMUX_REPO:-}" ] && [ -d "$WOLFMUX_REPO" ]; then guard_phys "$WOLFMUX_REPO" / && GUARD_REPO="$GUARD_P"; fi
  if [ "$GUARD_REPO" = "$GUARD_ROOT" ]; then GUARD_REPO=""; fi
  GUARD_READONLY="$GUARD_ROOT"
  if [ -n "$GUARD_REPO" ]; then GUARD_READONLY="$GUARD_ROOT and $GUARD_REPO"; fi
  GUARD_L_ROOT="$GUARD_ROOT"$'\n'"${WOLFMUX_ROOT:-}"$'\n'"$GUARD_REPO"$'\n'"${GUARD_REPO:+${WOLFMUX_REPO:-}}"
  GUARD_BRANCH="${WOLFMUX_BRANCH:-}"
}

# guard_check — cmd_guard's work; the decision on stdout (nothing: allow)
guard_check() {
  local tool="" cwd="" command="" file="" target="" pattern="" path s i=0 all=""
  local -a strings=() cmds=()
  [ -n "${TEAM_ROLE:-}" ] && [ "$TEAM_ROLE" != "$WOLFMUX_LEAD_ROLE" ] || return 0
  [ -n "$JQ_BIN" ] && [ -n "${WOLFMUX_WORKTREE:-}" ] && [ -d "$WOLFMUX_WORKTREE" ] || return 0 # cannot tell: allow
  # one jq call reads the hook's input on stdin: the tool, its folder, the strings the checks read, each ended by
  # a NUL. A tool the guard has no rules of its own for (an MCP tool, and any other: the hook runs for all) also
  # hands over every string in its input (s…; \001 alone when they add up to over 64 KB) and the fields named
  # command, cmd or script at any depth (c…), which may be shell text
  while IFS= read -r -d '' s; do
    case "$i" in
      0) tool="$s" ;;
      1) cwd="$s" ;;
      2) command="$s" ;;
      3) file="$s" ;;
      4) target="$s" ;;
      5) pattern="$s" ;;
      *) case "$s" in c*) cmds[${#cmds[@]}]="${s#c}" ;; s*) strings[${#strings[@]}]="${s#s}" ;; *) strings[${#strings[@]}]="$s" ;; esac ;;
    esac
    i=$((i + 1))
  done < <("$JQ_BIN" -j '([0] | implode) as $z
    | [.tool_name, .cwd, (.tool_input.command | if type == "string" and length > 65536 then "\u0001" else . end), (.tool_input.file_path // .tool_input.notebook_path), (.tool_input.file_path // .tool_input.path), .tool_input.pattern]
      + (if ((.tool_name // "") | tostring | test("^(Edit|Write|MultiEdit|NotebookEdit|Read|Grep|Glob|LS|Bash|Monitor|PowerShell)$")) then []
         else ([.tool_input | .. | strings]) as $s
           | if ($s | map(length) | add // 0) > 65536 then ["s\u0001"]
             else ($s | map("s" + .)) + [.tool_input | .. | objects | to_entries[] | select(.key | test("^(command|cmd|script)$")) | .value | strings | "c" + .] end end)
    | map((. // "" | tostring) + $z) | add' 2>/dev/null)
  [ -n "$tool" ] || return 0
  guard_setup
  [ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$GUARD_OWN"
  guard_phys "$cwd" /
  GUARD_CWD="$GUARD_P"
  case "$tool" in
    Edit | Write | MultiEdit | NotebookEdit)
      [ -n "$file" ] || return 0
      guard_phys "$file" "$cwd"
      path="$GUARD_P"
      case "$path" in */../* | */..) guard_deny "'$file' does not resolve to a plain path." && return 0 ;; esac
      if guard_inside "$path" "$GUARD_OWN"; then return 0; fi
      guard_private "$path"
      case "$GUARD_WHY" in
        trees) guard_deny "'$file' belongs to another teammate or to teamctl." && return 0 ;;
        memory) guard_deny "'$file' is in a lead's private memory folder; no worker writes there." && return 0 ;;
        transcripts) guard_deny "'$file' is in the folder of the leads' conversations; no worker writes there." && return 0 ;;
        claude) guard_deny "'$file' is in Claude Code's own records of sessions (file-history, todos, paste-cache, sessions, session-env, history.jsonl); no worker writes there." && return 0 ;;
        ctmp) guard_deny "'$file' is in Claude Code's temporary folder of other sessions; your own scratchpad there is the one you may write in." && return 0 ;;
      esac
      if [ -n "$GUARD_ROOT" ] && guard_inside "$path" "$GUARD_ROOT"; then
        guard_deny "'$file' is in the lead's checkout, which is read-only for you." && return 0
      fi
      if [ -n "$GUARD_REPO" ] && guard_inside "$path" "$GUARD_REPO"; then
        guard_deny "'$file' is in the main checkout of $GUARD_REPO. Your worktree of that repository is where your work goes; the checkout itself is read-only for you." && return 0
      fi
      for s in /private/tmp /tmp /private/var/folders /var/folders "$HOME/.claude"; do
        if guard_inside "$path" "$s"; then return 0; fi
      done
      guard_deny "'$file' is outside your worktree, so you may not change it."
      ;;
    Read | Grep | Glob | LS)
      set -- "$target"
      if [ "$tool" = "Glob" ] && [ -n "$pattern" ]; then
        # the folder a Glob searches: its pattern up to the first wildcard, from its path or from here, with
        # symlinks resolved (a link w -> ~/.wolfmux makes w/memory/** a search of the memory folder); its path too
        guard_phys "${target:-$cwd}" "$cwd"
        case "$pattern" in
          /* | "~" | "~/"*) guard_glob_root "$pattern" && set -- "$GUARD_P" ;;
          *) guard_glob_root "$GUARD_P/$pattern" && set -- "$GUARD_P" "$target" ;;
        esac
      fi
      for target in "$@"; do
        [ -n "$target" ] || continue
        guard_phys "$target" "$cwd"
        path="$GUARD_P"
        case "$path" in */../* | */..) guard_deny "'$target' does not resolve to a plain path." && return 0 ;; esac
        if guard_inside "$path" "$GUARD_OWN"; then continue; fi
        guard_private "$path"
        case "$GUARD_WHY" in
          trees) guard_deny "'$target' is another teammate's worktree or teamctl's state; their work in progress is not yours to read." && return 0 ;;
          memory) guard_deny "'$target' is in a lead's private memory folder (~/.wolfmux/memory), which no worker reads." && return 0 ;;
          transcripts) guard_deny "'$target' is in the folder of the leads' conversations, which no worker reads (its memory/ is shared: that one you may read)." && return 0 ;;
          claude) guard_deny "'$target' is in Claude Code's own records of sessions (file-history keeps a copy of every file a session changed, sessions/ and history.jsonl every session's id and prompts, a lead's too), which no worker reads." && return 0 ;;
          ctmp) guard_deny "'$target' is in Claude Code's temporary folder, which holds every session's tool output, the leads' too; only your own scratchpad there is yours." && return 0 ;;
        esac
        if { [ "$tool" = "Grep" ] || [ "$tool" = "Glob" ]; } && guard_holds_private "$path"; then
          # A search of a folder that holds them (~/.wolfmux, ~/.claude, your home, /tmp) would read them too.
          guard_deny "a search of '$target' would reach into the private memory folders (~/.wolfmux/memory), the leads' conversations, Claude Code's records or its temporary folder under it; search a narrower folder." && return 0
        fi
      done
      ;;
    Bash | Monitor | PowerShell)
      # Monitor runs its command in the same shell as Bash, and sends every line it prints back
      [ -n "$command" ] || return 0
      # A shell that runs inside a private folder reads it with every relative word
      guard_private "$GUARD_CWD"
      if [ -n "$GUARD_WHY" ]; then
        guard_deny "this shell runs in $GUARD_CWD, a folder that is not yours to read; cd back into your worktree." && return 0
      fi
      guard_bash "$command"
      if [ -n "$GUARD_REASON" ]; then guard_deny "$GUARD_REASON"; fi
      ;;
    *)
      # An MCP tool, or any other tool (the hook runs for every tool): its input has no fixed shape, so every
      # string that is an absolute path (or a file:// URL) counts. Another teammate's worktree, teamctl's state,
      # the memory folders, the leads' conversations, Claude Code's records and its temporary folder are off
      # limits for any of them; the lead's checkout only for a tool whose name says it changes things.
      for target in ${strings[@]+"${strings[@]}"}; do
        case "$target" in file://localhost/*) target="${target#file://localhost}" ;; file:///*) target="${target#file://}" ;; esac
        case "$target" in /* | "~"/*) ;; *) continue ;; esac
        guard_phys "$target" "$cwd"
        path="$GUARD_P"
        if guard_inside "$path" "$GUARD_OWN"; then continue; fi
        guard_private "$path"
        case "$GUARD_WHY" in
          trees) guard_deny "'$target' is another teammate's worktree or teamctl's state." && return 0 ;;
          memory) guard_deny "'$target' is in a lead's private memory folder." && return 0 ;;
          transcripts) guard_deny "'$target' is in the folder of the leads' conversations." && return 0 ;;
          claude) guard_deny "'$target' is in Claude Code's own records of sessions (file-history, todos, paste-cache, sessions, session-env, history.jsonl)." && return 0 ;;
          ctmp) guard_deny "'$target' is in Claude Code's temporary folder of other sessions." && return 0 ;;
        esac
        if { { [ -n "$GUARD_ROOT" ] && guard_inside "$path" "$GUARD_ROOT"; } ||
          { [ -n "$GUARD_REPO" ] && guard_inside "$path" "$GUARD_REPO"; }; }; then
          case "$tool" in
            *[Ww]rite* | *[Ee]dit* | *[Cc]reate* | *[Dd]elete* | *[Rr]emove* | *[Mm]ove* | *[Rr]ename* | *[Pp]atch* | *[Aa]pply* | *[Aa]ppend* | *[Ii]nsert* | *[Rr]eplace* | *[Mm]kdir* | *[Uu]pload* | *[Ss]ave*)
              guard_deny "'$target' is in a checkout that is read-only for you ($GUARD_READONLY)." && return 0
              ;;
          esac
        fi
      done
      # every string as a quoted word of a command (the word checks of GUARD_SCAN), and command, cmd and script
      # fields as shell text
      for s in ${strings[@]+"${strings[@]}"}; do all="$all$s"$'\001'; done
      [ "$all" = $'\001\001' ] && all=$'\001' # over 64 KB in all
      if [ -n "$all" ]; then
        guard_bash "$all" strings
        if [ -n "$GUARD_REASON" ]; then guard_deny "$GUARD_REASON" && return 0; fi
      fi
      for s in ${cmds[@]+"${cmds[@]}"}; do
        guard_bash "$s"
        if [ -n "$GUARD_REASON" ]; then guard_deny "$GUARD_REASON" && return 0; fi
      done
      ;;
  esac
  return 0
}

# cmd_guard — internal (`teamctl _guard`): PreToolUse hook of a worker, JSON on stdin. Every path is compared
# without regard to letter case, as the disk does (~/.WOLFMUX/Memory IS ~/.wolfmux/memory).
cmd_guard() {
  local nocase=0 LC_ALL=C # bytes, as sed counts them for the names of Claude Code's folders
  shopt -q nocasematch && nocase=1
  shopt -s nocasematch
  guard_check
  [ "$nocase" -eq 1 ] || shopt -u nocasematch
  return 0
}
