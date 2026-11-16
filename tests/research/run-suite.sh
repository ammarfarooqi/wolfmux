#!/bin/bash
# run-suite.sh <log-dir> <suite>...: run stub suites from an agent's pane without that agent's
# environment leaking into them (TEAM_ROLE, WOLFMUX_*, CLAUDE*, TMUX), one after the other.
# Each suite's full output goes to <log-dir>/<suite>.log; stdout gets one line per suite:
# its summary line and the number of FAIL lines.
set -u
here="$(cd "$(dirname "$0")/../.." && pwd -P)"
logs="$1"
shift
/bin/mkdir -p "$logs"
for name in $(compgen -e); do
  case "$name" in
    WOLFMUX_* | CLAUDE* | TEAM_ROLE | BEADS_ACTOR | TMUX | TMUX_PANE) unset "$name" ;;
  esac
done
export WOLFMUX_HOME="$here/config/wolfmux"
cd "$here" || exit 1
for suite in "$@"; do
  start="$(/bin/date +%s)"
  bash "tests/$suite.sh" >"$logs/$suite.log" 2>&1
  code=$?
  printf '%s: exit %s, %ss, %s FAIL lines, last: %s\n' "$suite" "$code" "$(($(/bin/date +%s) - start))" \
    "$(/usr/bin/grep -c '^  FAIL' "$logs/$suite.log")" "$(/usr/bin/tail -n 1 "$logs/$suite.log")"
done
