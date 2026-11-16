#!/bin/bash
# probe.sh <name> [claude flags...] — one print-mode Haiku request ("Reply with the single word ok")
# from the scratch project, with the flags under test, to MEASURE what a first request weighs.
# Appends one JSON line to tests/research/results/${PROBE_OUT:-probes.jsonl}: the name, the exact command line,
# and the usage block the CLI reports. Needs tests/research/.scratch-path (the scratch directory).
set -u
here="$(cd "$(dirname "$0")" && pwd -P)"
scratch="$(cat "$here/.scratch-path")"
name="$1"
shift
out="$here/results/${PROBE_OUT:-probes.jsonl}"
mkdir -p "$here/results"
raw="$("$here/iso.sh" "$scratch/r1" claude -p "Reply with the single word ok" --model haiku --output-format json "$@" </dev/null 2>/dev/null)"
printf '%s' "$raw" | jq -c --arg name "$name" --arg cmd "claude -p \"Reply with the single word ok\" --model haiku --output-format json $*" \
  '(if type == "array" then (map(select(.type == "result")) | last) else . end) as $r
   | {name: $name, cmd: $cmd, at: (now | todate), usage: $r.usage, turns: $r.num_turns, ms: $r.duration_ms, api_ms: $r.duration_api_ms,
      first_request_tokens: (($r.usage.input_tokens // 0) + ($r.usage.cache_creation_input_tokens // 0) + ($r.usage.cache_read_input_tokens // 0))}' \
  >>"$out" 2>/dev/null || printf '{"name":"%s","error":%s}\n' "$name" "$(printf '%s' "$raw" | head -c 600 | jq -Rs .)" >>"$out"
tail -n 1 "$out" | jq -c '{name, first_request_tokens, turns, ms, api_ms, error}'
