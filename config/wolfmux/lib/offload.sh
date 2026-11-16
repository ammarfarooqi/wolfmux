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
      printf "[wolfmux] full text: %s (search it with grep; do not cat it)\n", log
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
