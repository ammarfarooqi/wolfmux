#!/bin/bash
# offload proof against the real CLI, with the real hooks of this checkout (v1.25.0, wolfmux-ik5):
#   probe2.sh <name> <deny|-> "<shell command>"
# Settings as write_agent_settings makes them for an agent with output-offload on: PreToolUse
# `teamctl _offload-pre` on Bash, PostToolUse `teamctl _hook PostToolUse`, bashOutputMaxChars and
# BASH_MAX_OUTPUT_LENGTH 16000, WOLFMUX_OFFLOAD_SAFETY on. deny: a second PreToolUse entry that
# denies every Bash call (stands in for the worktree guard).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
name="$1" deny="$2" cmd="$3"
out="$here/../results/offload-$name"
rm -rf "$out"; mkdir -p "$out/run"
tc="$repo/bin/teamctl"
pre="$(jq -cn --arg c "\"$tc\" _offload-pre" '[{matcher: "Bash", hooks: [{type: "command", command: $c, timeout: 10}]}]')"
if [ "$deny" = deny ]; then
  pre="$(jq -c --arg c "printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"probe guard: refused\"}}'" \
    '[{matcher: ".*", hooks: [{type: "command", command: $c, timeout: 10}]}] + .' <<<"$pre")"
fi
jq -n --argjson pre "$pre" --arg post "\"$tc\" _hook PostToolUse" '{hooks: {PreToolUse: $pre,
  PostToolUse: [{hooks: [{type: "command", command: $post, timeout: 20}]}]},
  env: {BASH_MAX_OUTPUT_LENGTH: "16000", WOLFMUX_OFFLOAD_SAFETY: "on"}, bashOutputMaxChars: 16000}' >"$out/settings.json"
prompt="Run exactly this shell command with the Bash tool, once: $cmd
Then reply with: the exit code you saw, the LAST line of the tool result, and every line of the result that contains FAIL. Nothing else."
cd "${TMPDIR:-/tmp}"
env -u TEAM_ROLE WOLFMUX_HOME="$repo/config/wolfmux" WOLFMUX_RUN_DIR="$out/run" \
  claude -p "$prompt" --model haiku --settings "$out/settings.json" --allowedTools Bash \
  --output-format stream-json --verbose --max-turns 4 >"$out/stream.jsonl" 2>"$out/stderr.txt" </dev/null || true
jq -r 'select(.type=="result") | .result' "$out/stream.jsonl" >"$out/answer.txt" || true
jq -c 'select(.type=="user") | .message.content[]? | select(.type=="tool_result") | {is_error, content: (.content|tostring)}' "$out/stream.jsonl" >"$out/tool_result.jsonl"
echo "== $name ($deny): $cmd"
jq -r '"is_error=\(.is_error) chars=\(.content|length)\n" + (.content|.[0:500]) + "\n  ...\n" + (.content|.[-400:])' "$out/tool_result.jsonl"
echo "-- logs: $(ls "$out/run/out" 2>/dev/null | tr '\n' ' ')"
echo "-- answer:"; head -8 "$out/answer.txt"
