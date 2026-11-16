#!/bin/bash
# run-suite.sh <log-dir> <suite>...: run stub suites from an agent's pane with a clean environment
# (env -i: HOME, PATH, TERM, USER, LANG=en_US.UTF-8 (tests/inbox.sh compares badge glyphs) and WOLFMUX_HOME of this checkout, nothing else), one after the other.
# Each suite's full output goes to <log-dir>/<suite>.log; stdout gets one line per suite:
# its summary line and the number of FAIL lines.
set -u
here="$(cd "$(dirname "$0")/../.." && pwd -P)"
logs="$1"
shift
/bin/mkdir -p "$logs"
cd "$here" || exit 1
for suite in "$@"; do
  start="$(/bin/date +%s)"
  /usr/bin/env -i HOME="$HOME" PATH="$PATH" TERM="${TERM:-xterm-256color}" USER="${USER:-$(/usr/bin/id -un)}" LANG=en_US.UTF-8 \
    WOLFMUX_HOME="$here/config/wolfmux" bash "tests/$suite.sh" >"$logs/$suite.log" 2>&1
  code=$?
  printf '%s: exit %s, %ss, %s FAIL lines, last: %s\n' "$suite" "$code" "$(($(/bin/date +%s) - start))" \
    "$(/usr/bin/grep -c '^  FAIL' "$logs/$suite.log")" "$(/usr/bin/tail -n 1 "$logs/$suite.log")"
done
