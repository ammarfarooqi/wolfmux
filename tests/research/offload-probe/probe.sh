#!/bin/bash
# offload probe: does a PostToolUse hook's hookSpecificOutput.updatedToolOutput replace a Bash
# result before the model sees it? (v1.25.0 stage A, wolfmux-ik5). Usage:
#   probe.sh <name> <replace|none> <event list, e.g. "PostToolUse PostToolUseFailure"> "<shell command>"
# Writes tests/research/results/offload-<name>/: settings.json, input-*.json (what the hook got),
# tool_result.jsonl, answer.txt (the stream is deleted: it holds the owner's setup).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
name="$1" mode="$2" events="$3" cmd="$4"
out="$here/../results/offload-$name"
rm -rf "$out"; mkdir -p "$out"
hooks='{}'
for ev in $events; do
  hooks="$(jq -c --arg ev "$ev" --arg c "PROBE_EVENT=$ev PROBE_MODE=$mode PROBE_OUT='$out' '$here/hook.sh'" \
    '. + {($ev): [{matcher: "Bash", hooks: [{type: "command", command: $c}]}]}' <<<"$hooks")"
done
jq -n --argjson h "$hooks" '{hooks: $h}' >"$out/settings.json"
prompt="Run exactly this shell command with the Bash tool, once: $cmd
Then reply with the tool result exactly as you received it, verbatim, inside a code block, and nothing else."
cd "${TMPDIR:-/tmp}"
env -u TEAM_ROLE -u WOLFMUX_RUN_DIR claude -p "$prompt" --model haiku --settings "$out/settings.json" \
  --allowedTools Bash --output-format stream-json --verbose --max-turns 4 >"$out/stream.jsonl" 2>"$out/stderr.txt" || true
jq -r 'select(.type=="result") | .result' "$out/stream.jsonl" >"$out/answer.txt" || true
jq -c 'select(.type=="user") | .message.content[]? | select(.type=="tool_result") | {is_error, content: (.content|tostring)}' "$out/stream.jsonl" >"$out/tool_result.jsonl"
echo "== $name ($mode, $events): $cmd"
echo "-- hook inputs: $(ls "$out" | grep -c '^input-' || true)"
echo "-- tool_result the model got:"
jq -c 'select(.type=="user") | .message.content[]? | select(.type=="tool_result") | {is_error, content: (.content|tostring|.[0:300])}' "$out/stream.jsonl"
echo "-- answer:"; cut -c1-300 "$out/answer.txt" | head -8
rm -f "$out/stream.jsonl"
