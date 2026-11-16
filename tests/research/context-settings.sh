#!/bin/bash
# context-settings.sh <worker|lead> <mode> [<context-exclude globs>]: print the settings fragment
# that lib/policy.sh gives an agent of that kind under that worker-context / lead-context value,
# built from YOUR ~/.claude, without a team: the same functions write_agent_settings calls.
# Used by the probes that prove what the fragment saves (tests/research/probe.sh).
set -u
here="$(cd "$(dirname "$0")/../.." && pwd -P)"
JQ_BIN="$(command -v jq)"
meta_get() { return 1; }            # no team: every policy falls back to its default
project_policy_get() { return 1; }
# shellcheck source=/dev/null
. "$here/config/wolfmux/lib/policy.sh"
kind="$1" mode="$2"
export WOLFMUX_CONTEXT_EXCLUDE="${3:-}"
if [ "$kind" = "worker" ]; then
  export WOLFMUX_WORKER_CONTEXT="$mode"
else
  export WOLFMUX_LEAD_CONTEXT="$mode"
fi
agent_context_settings "$kind"
