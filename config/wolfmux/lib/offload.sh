#!/bin/bash
# offload.sh — a long command output stays out of the agent's context window (v1.25.0, ADR-0036).
#
# Measured on 2026-11-16: Bash output is a third of everything a worker adds to its context, and
# Claude Code never clears an old tool result, so one test log read once rides along in every
# later request until a compaction. This module keeps the full text in a file and gives the
# model a shortened form: the first and last lines, every line in between that looks like a
# failure, the counts, and the path.
#
#   $STATE_DIR/run/<role>/out/<n>.log   the full text of one long output; the newest
#                                       WOLFMUX_OFFLOAD_KEEP per role are kept
#   $STATE_DIR/run/<role>/out/next      the next <n>
#
# Settings (environment or ~/.config/wolfmux/config):
#   WOLFMUX_OFFLOAD       on | off      off: every output reaches the model as it is
#   WOLFMUX_OFFLOAD_MIN   characters    an output longer than this is shortened (default 4000)
#
# Rule, as for every hook: nothing here may fail or delay an agent. When the log cannot be
# written the output goes through unchanged.

WOLFMUX_OFFLOAD="${WOLFMUX_OFFLOAD:-on}"
WOLFMUX_OFFLOAD_MIN="${WOLFMUX_OFFLOAD_MIN:-4000}"
WOLFMUX_OFFLOAD_HEAD=40     # lines kept from the start
WOLFMUX_OFFLOAD_TAIL=40     # lines kept from the end
WOLFMUX_OFFLOAD_MATCHES=60  # lines of the cut middle that match the pattern, at most
WOLFMUX_OFFLOAD_LINE_MAX=400 # characters of one shown line, at most (a minified file is one line)
WOLFMUX_OFFLOAD_KEEP=200    # logs kept per role
WOLFMUX_OFFLOAD_PATTERN='FAIL|[Ee]rror|panic|not ok'
# The CLI's own cap on a Bash result (bashOutputMaxChars / BASH_MAX_OUTPUT_LENGTH, default 30000),
# lowered for every agent with this feature on: a backstop for a call that was not rewritten
# (run_in_background, exec). Above it the CLI keeps the whole output in a file and shows 2 KB.
WOLFMUX_OFFLOAD_BACKSTOP="${WOLFMUX_OFFLOAD_BACKSTOP:-16000}"

# offload_wanted — 0 when this team's agents get the feature: the output-offload policy (needs
# lib/policy.sh, loaded by teamctl) and WOLFMUX_OFFLOAD both say on
offload_wanted() {
  offload_enabled || return 1
  [ "$(policy_get output-offload 2>/dev/null || printf on)" != "off" ]
}

# offload_enabled — 0 when outputs are to be shortened
offload_enabled() {
  case "$WOLFMUX_OFFLOAD" in off | OFF | 0 | no | false) return 1 ;; esac
  return 0
}

# offload_min — the limit as a number (a bad value falls back to the default)
offload_min() {
  case "$WOLFMUX_OFFLOAD_MIN" in "" | *[!0-9]*) printf '4000\n' ;; *) printf '%s\n' "$WOLFMUX_OFFLOAD_MIN" ;; esac
}

# offload_new_log <run-dir> — prints the path of a new, empty log file; fails when it cannot
offload_new_log() {
  local dir="$1/out" n=0
  /bin/mkdir -p "$dir" 2>/dev/null || return 1
  if [ -r "$dir/next" ]; then IFS= read -r n <"$dir/next" || true; fi
  case "$n" in "" | *[!0-9]*) n=0 ;; esac
  n=$((10#$n + 1))
  printf '%s\n' "$n" >"$dir/next" 2>/dev/null || return 1
  : >"$dir/$n.log" 2>/dev/null || return 1
  # Pruning lists the directory: once every 20 logs is enough to hold it near the limit.
  if [ $((n % 20)) -eq 0 ]; then offload_prune "$dir"; fi
  printf '%s\n' "$dir/$n.log"
}

# offload_prune <out-dir> — keeps the newest WOLFMUX_OFFLOAD_KEEP logs
offload_prune() {
  local dir="$1"
  (cd "$dir" 2>/dev/null && /bin/ls -t | /usr/bin/grep -E '^[0-9]+\.log$' | /usr/bin/tail -n "+$((WOLFMUX_OFFLOAD_KEEP + 1))" |
    while IFS= read -r f; do /bin/rm -f "./$f"; done) 2>/dev/null || true
}

# offload_summary <log> [<exit-code>] — the shortened form of the text in <log>, to stdout.
# One awk pass: it keeps the head, a ring of the last lines, and the matching lines between.
offload_summary() {
  local log="$1" rc="${2:-}" chars
  chars="$(LC_ALL=en_US.UTF-8 /usr/bin/wc -m <"$log" 2>/dev/null | /usr/bin/tr -d ' ')"
  LC_ALL=C /usr/bin/awk -v head="$WOLFMUX_OFFLOAD_HEAD" -v tail="$WOLFMUX_OFFLOAD_TAIL" \
    -v maxm="$WOLFMUX_OFFLOAD_MATCHES" -v linemax="$WOLFMUX_OFFLOAD_LINE_MAX" -v pat="$WOLFMUX_OFFLOAD_PATTERN" \
    -v logpath="$log" -v chars="${chars:-?}" -v rc="$rc" '
    function show(s) { if (length(s) > linemax) return substr(s, 1, linemax) " [line cut]"; return s }
    {
      if (NR <= head) { first[NR] = $0; next }
      # a line leaving the tail ring falls into the cut middle
      if (NR - tail > head) {
        old = ring[(NR - tail) % tail]
        if (old ~ pat) { nm++; if (nm <= maxm) { mline[nm] = NR - tail; mtext[nm] = old } }
      }
      ring[NR % tail] = $0
    }
    END {
      n = NR
      printf "[wolfmux] long output shortened: %d lines, %s characters%s.\n", n, chars, (rc != "" ? ", exit code " rc : "")
      printf "[wolfmux] full text: %s (search it with grep; do not cat it)\n", logpath
      for (i = 1; i <= n && i <= head; i++) print show(first[i])
      from = head + 1; to = n - tail
      if (to >= from) {
        printf "[wolfmux] ... lines %d-%d cut", from, to
        if (nm > 0) printf "; %d of them match %s%s:\n", nm, pat, (nm > maxm ? ", the first " maxm " follow" : "")
        else printf "; none matches %s\n", pat
        for (i = 1; i <= nm && i <= maxm; i++) printf "%d: %s\n", mline[i], show(mtext[i])
        printf "[wolfmux] ... end of the cut; the last %d lines:\n", tail
      }
      start = (to >= from) ? to + 1 : head + 1
      for (i = start; i <= n; i++) print show(ring[i % tail])
    }' "$log"
}

# ---- the wrap (Claude family): a PreToolUse hook rewrites a Bash call's command ------------------
#
# Why a rewrite and not only a PostToolUse answer: a command that exits non-zero (a failing test
# run) fires PostToolUseFailure, which cannot replace the result, and the CLI cuts that result to
# its first ~10,000 characters, so the FAIL lines at the end of a long log never reach the model
# (tests/research/results/offload-probes.md, probes 3 and 5).
#
# The rewrite puts a prefix in front of the agent's command, on its first line (so bash's line
# numbers in an error message stay what they were), and nothing after it:
#   - it sends the shell's stdout and stderr to the log (one file, so the order is the order
#     written) and keeps the originals on fds 7 and 8;
#   - an EXIT trap puts them back and prints the result: whole when it is short, shortened when
#     it is long (lib/offload-show.sh). The shell's exit status is kept. An `exit 3` in the
#     command, `set -e`, and a syntax error (bash's message lands in the log) all end through it.
#   - TERM and INT traps do the same for a command the CLI ends at its timeout, then exit 143/130.
# The command runs in the same shell, unchanged: cd and export persist as before. When the line
# cannot set itself up (helper missing, log not writable) it does nothing and the command runs
# as it would have. A command is never run twice: the line only redirects and sets traps.
#
# Never wrapped: run_in_background calls, a command with the word `exec` in it (an exec'd
# program would replace the shell and its trap), a command already wrapped.

WOLFMUX_OFFLOAD_MARK="__wm_fin" # the function the line defines; also how a wrapped command is recognised

# offload_next_log <run-dir> — the path of the next log; the file is created by the wrapped
# shell itself, so a call that is not wrapped leaves nothing behind
offload_next_log() {
  offload_alloc_log "$1" || return 1
  printf '%s\n' "$OFFLOAD_LOG"
}

# offload_alloc_log <run-dir> — the same into OFFLOAD_LOG, without a fork (the PreToolUse path)
offload_alloc_log() {
  local dir="$1/out" n=0
  [ -d "$dir" ] || /bin/mkdir -p "$dir" 2>/dev/null || return 1
  if [ -r "$dir/next" ]; then IFS= read -r n <"$dir/next" || true; fi
  case "$n" in "" | *[!0-9]*) n=0 ;; esac
  n=$((10#$n + 1))
  printf '%s\n' "$n" >"$dir/next" 2>/dev/null || return 1
  if [ $((n % 20)) -eq 0 ]; then offload_prune "$dir"; fi
  OFFLOAD_LOG="$dir/$n.log"
}

# offload_wrap_line <log> <show-script> — the line put in front of a command. Plain sh, so a
# lead whose shell is zsh runs it too. Paths with a single quote are refused (prints nothing).
offload_wrap_line() {
  offload_make_line "$1" "$2" || return 1
  printf '%s' "$OFFLOAD_LINE"
}

# offload_make_line <log> <show-script> — the same into OFFLOAD_LINE, without a fork
offload_make_line() {
  local log="$1" show="$2"
  case "$log$show" in *"'"*) return 1 ;; esac
  OFFLOAD_LINE="__wm_fin() { trap - EXIT TERM INT; exec 1>&7 2>&8 7>&- 8>&-; /bin/bash '$show' '$log' \"\$1\" || /bin/cat '$log'; }; if [ -r '$show' ] && exec 7>&1 8>&2 >'$log' 2>&1; then trap '__wm_rc=\$?; __wm_fin \$__wm_rc; exit \$__wm_rc' EXIT; trap '__wm_fin 143; exit 143' TERM; trap '__wm_fin 130; exit 130' INT; fi; "
}

# offload_should_wrap <command> — 0 when the command may be wrapped
offload_should_wrap() {
  case "$1" in *"$WOLFMUX_OFFLOAD_MARK"*) return 1 ;; esac
  printf '%s' "$1" | /usr/bin/grep -Eq '(^|[^A-Za-z0-9_-])exec([^A-Za-z0-9_-]|$)' && return 1
  return 0
}

# offload_wrap_command <command> <log> <show-script> — the rewritten command, to stdout
offload_wrap_command() {
  local line
  line="$(offload_wrap_line "$2" "$3")" || {
    printf '%s' "$1"
    return 0
  }
  printf '%s%s' "$line" "$1"
}

# offload_finish <log> <exit-code> — what the model sees at the end of a wrapped command: the
# whole text when it is short (and the log goes), the shortened form when it is long.
offload_finish() {
  local log="$1" rc="${2:-}" chars
  [ -f "$log" ] || return 0
  chars="$(LC_ALL=en_US.UTF-8 /usr/bin/wc -m <"$log" 2>/dev/null | /usr/bin/tr -d ' ')"
  case "$chars" in "" | *[!0-9]*) chars=0 ;; esac
  if [ "$chars" -le "$(offload_min)" ]; then
    /bin/cat "$log"
    /bin/rm -f "$log"
  else
    offload_summary "$log" "$rc"
  fi
}

# offload_pre_hook — `teamctl _offload-pre`, a PreToolUse hook for Bash: the CLI's JSON on stdin,
# an updatedInput on stdout, or nothing. Run from the fast path at the top of bin/teamctl, so it
# costs one bash start and one jq. No permissionDecision: whether the call may run is still
# decided by the CLI and the other hooks (the worktree guard).
offload_pre_hook() {
  local jq
  offload_enabled || return 0
  [ -n "${WOLFMUX_RUN_DIR:-}" ] && [ -d "$WOLFMUX_RUN_DIR" ] || return 0
  jq="${JQ_BIN:-}"
  if [ -z "$jq" ]; then
    for jq in /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq ""; do [ -x "$jq" ] && break; done
    [ -n "$jq" ] || jq="$(command -v jq 2>/dev/null || true)"
  fi
  [ -n "$jq" ] || return 0
  offload_alloc_log "$WOLFMUX_RUN_DIR" || return 0
  offload_make_line "$OFFLOAD_LOG" "${WOLFMUX_HOME:-$HOME/.config/wolfmux}/lib/offload-show.sh" || return 0
  "$jq" -c --arg line "$OFFLOAD_LINE" --arg mark "$WOLFMUX_OFFLOAD_MARK" '
    .tool_input as $in
    | if .tool_name == "Bash" and ($in.command | type) == "string" and ($in.run_in_background != true)
         and ($in.command | test("(^|[^A-Za-z0-9_-])exec([^A-Za-z0-9_-]|$)") | not)
         and ($in.command | contains($mark) | not)
      then {hookSpecificOutput: {hookEventName: "PreToolUse",
                                 updatedInput: ($in + {command: ($line + $in.command)})}}
      else empty end' 2>/dev/null || true
}

# ---- teamctl run (Codex family): the same, as a command ------------------------------------------
#
# A Codex agent's results cannot be rewritten by a hook, so it runs a long command through this:
# the full output (stdout and stderr, in the order written) to the log, the result to stdout,
# whole when short and shortened when long, and the command's own exit code.

# offload_run_dir — the agent's run directory, or a private one for a human at a terminal
offload_run_dir() {
  if [ -n "${WOLFMUX_RUN_DIR:-}" ] && [ -d "$WOLFMUX_RUN_DIR" ]; then
    printf '%s\n' "$WOLFMUX_RUN_DIR"
  else
    printf '%s\n' "${TMPDIR:-/tmp}/wolfmux-run-$(id -u)"
  fi
}

# cmd_run -- <command> [args...]
cmd_run() {
  local log rc=0
  if [ "${1:-}" = "--" ]; then shift; fi
  [ "$#" -gt 0 ] || die_usage "teamctl run -- <command> [args...]"
  offload_enabled || exec "$@"
  log="$(offload_next_log "$(offload_run_dir)")" || exec "$@"
  if ! : >"$log" 2>/dev/null; then exec "$@"; fi
  trap 'offload_finish "$log" 143; exit 143' TERM
  trap 'offload_finish "$log" 130; exit 130' INT
  "$@" >"$log" 2>&1 || rc=$?
  trap - TERM INT
  offload_finish "$log" "$rc"
  return "$rc"
}

# ---- the safety net (a): PostToolUse on a result the rewrite did not cover -------------------------
#
# A Bash call that exits 0 fires PostToolUse, whose answer may replace the result, as the Bash
# result OBJECT (a string is refused: probe 1). This covers a call the rewrite left alone
# (run_in_background read back later, a command with exec in it). Above ~30,000 characters the CLI
# has kept the full text itself (tool_response.persistedOutputPath), which is used instead.

# offload_post <the CLI's JSON> — prints the PostToolUse answer, or nothing
offload_post() {
  local input="$1" jq log run
  offload_enabled || return 0
  jq="${JQ_BIN:-$(command -v jq 2>/dev/null || true)}"
  [ -n "$jq" ] || return 0
  # one jq: is this a long Bash result we did not shorten already?
  printf '%s' "$input" | "$jq" -e --argjson min "$(offload_min)" --arg mark "$WOLFMUX_OFFLOAD_MARK" '
    .tool_name == "Bash" and (.tool_response | type) == "object"
    and ((.tool_input.command // "") | contains($mark) | not)
    and ((.tool_response.stdout // "") | startswith("[wolfmux] long output shortened") | not)
    and (((.tool_response.stdout // "") | length) + ((.tool_response.stderr // "") | length) > $min)' >/dev/null 2>&1 || return 0
  run="$(offload_run_dir)"
  log="$(offload_next_log "$run")" || return 0
  printf '%s' "$input" | "$jq" -j '
    .tool_response | if (.persistedOutputPath // "") != "" then "\u0000" + .persistedOutputPath
                     else (.stdout // "") + (if (.stderr // "") != "" then "\n" + .stderr else "" end) end' >"$log" 2>/dev/null || return 0
  if [ "$(/usr/bin/head -c 1 "$log" | /usr/bin/od -An -c | /usr/bin/tr -d ' ')" = '\0' ]; then
    local persisted
    persisted="$(/usr/bin/tail -c +2 "$log")"
    /bin/cp "$persisted" "$log" 2>/dev/null || return 0
  fi
  printf '%s' "$input" | "$jq" -c --arg text "$(offload_summary "$log")" '
    {hookSpecificOutput: {hookEventName: "PostToolUse",
                          updatedToolOutput: (.tool_response + {stdout: $text, stderr: ""}
                                              | del(.persistedOutputPath, .persistedOutputSize))}}' 2>/dev/null || true
}
