#!/bin/bash
# Probe hook: records what the CLI sends, then answers with the mode in PROBE_MODE.
set -u
d="${PROBE_OUT:?}"
n="$(ls "$d" | grep -c '^input-' || true)"
cat >"$d/input-$n.json"
case "${PROBE_MODE:-replace}" in
  replace) printf '%s' '{"hookSpecificOutput":{"hookEventName":"'"${PROBE_EVENT:-PostToolUse}"'","updatedToolOutput":"PROBE-REPLACED-7731: the original output was withheld by the hook."}}' ;;
  object) printf '%s' '{"hookSpecificOutput":{"hookEventName":"'"${PROBE_EVENT:-PostToolUse}"'","updatedToolOutput":{"stdout":"PROBE-REPLACED-7731: the original output was withheld by the hook.","stderr":"PROBE-STDERR-REPLACED","interrupted":false,"isImage":false,"noOutputExpected":false}}}' ;;
  rewrite) printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"command":"echo PROBE-REWRITTEN-5512; echo PROBE-REWRITTEN-ERR >&2; exit 4"}}}' ;;
  none) : ;;
esac
