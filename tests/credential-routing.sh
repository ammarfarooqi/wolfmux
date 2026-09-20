#!/bin/bash
# credential-routing.sh — MANUAL, opt-in evidence test. Not part of smoke.sh.
#
# Question it answers: for each way a third-party worker can be launched, which KIND of
# credential and which model id does Claude Code actually put on the wire?
#
# The provider is an argument (default glm) and its model ids come from the table in
# config/wolfmux/lib/providers.sh, so this test says what the launcher would say.
#
# How: Claude Code is pointed at tests/mock_anthropic.py on 127.0.0.1. The mock
# classifies the Authorization / x-api-key headers, never stores their values,
# and rejects every request with HTTP 400 — so there is no inference, no billing,
# and nothing leaves this machine. All keys used here are dummies, EXCEPT in the
# "hazard" scenarios, which exist to show that a process holding only a custom
# base URL sends your real claude.ai login to it. That value reaches localhost
# only and is recorded merely as OTHER_REAL_CREDENTIAL(len=N).
#
# Side effect: each run starts `claude -p` in a temp directory; the transcripts it
# leaves under ~/.claude/projects are removed at the end.
#
#   tests/credential-routing.sh [<provider>]   # needs: claude (logged in), python3, jq
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=/dev/null
. "$REPO/config/wolfmux/lib/provider-env.sh"

PROVIDER="${1:-glm}"
wolfmux_provider_info "$PROVIDER" || {
  echo "unknown provider '$PROVIDER'. One of: $WOLFMUX_PROVIDERS" >&2
  exit 64
}
MAIN_MODEL="$PROVIDER_MAIN_MODEL"
FAST_MODEL="$PROVIDER_FAST_MODEL"
AUTH_VAR="$PROVIDER_AUTH_VAR"

PORT="${PORT:-18765}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-routing.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)" # physical path: that is what Claude Code names its transcript folder after
LOG="$WORK/requests.log"
CLAUDE_BIN="$(wolfmux_resolve_claude)" || {
  echo "claude not found" >&2
  exit 1
}

python3 "$REPO/tests/mock_anthropic.py" "$LOG" "$PORT" >/dev/null 2>&1 &
MOCK_PID=$!
disown "$MOCK_PID" 2>/dev/null || true # no "Terminated" job notice when it is stopped
cleanup() {
  kill "$MOCK_PID" 2>/dev/null
  local slug
  slug="$(printf '%s' "$WORK/cwd" | sed 's|[^A-Za-z0-9]|-|g')"
  case "$slug" in *wolfmux-routing*) /bin/rm -rf "$HOME/.claude/projects/$slug" ;; esac
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT
sleep 1
/bin/mkdir -p "$WORK/cwd"
cd "$WORK/cwd" || exit 1

# The same mapping bin/claude-glm exports for this provider.
PROVIDER_MODEL_ENV=("ANTHROPIC_MODEL=$MAIN_MODEL" "ANTHROPIC_DEFAULT_OPUS_MODEL=$MAIN_MODEL"
  "ANTHROPIC_DEFAULT_SONNET_MODEL=$MAIN_MODEL" "ANTHROPIC_DEFAULT_FABLE_MODEL=$MAIN_MODEL"
  "ANTHROPIC_DEFAULT_HAIKU_MODEL=$FAST_MODEL" "CLAUDE_CODE_SUBAGENT_MODEL=$MAIN_MODEL")

# run <label> [--settings <json>] <ENV=value ...>
run() {
  local label="$1" settings=()
  shift
  if [ "${1:-}" = "--settings" ]; then
    settings=(--settings "$2")
    shift 2
  fi
  printf '### %s\n' "$label" >>"$LOG"
  (
    wolfmux_scrub_claude_env
    env CLAUDE_CODE_SAFE_MODE=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 API_TIMEOUT_MS=8000 \
      ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" "${PROVIDER_MODEL_ENV[@]}" "$@" \
      "$CLAUDE_BIN" ${settings[@]+"${settings[@]}"} -p "say hi" --model "$MAIN_MODEL" --max-turns 1 >/dev/null 2>&1 </dev/null
  )
}

# One fixed dummy for every provider: tests/mock_anthropic.py classifies this exact
# value as DUMMY_ZAI_KEY, and what this test asks is which KIND of credential goes on
# the wire, not which vendor the dummy belongs to.
DUMMY="dummy-zai-key"
HELPER="{\"apiKeyHelper\":\"echo $DUMMY\"}"
GUARD="CLAUDE_CODE_OAUTH_TOKEN=$WOLFMUX_GLM_GUARD_TOKEN"
UP="$(printf '%s' "$PROVIDER" | tr '[:lower:]' '[:upper:]')"

echo "provider: $PROVIDER ($PROVIDER_VENDOR); models $MAIN_MODEL / $FAST_MODEL; env mode exports $AUTH_VAR"
run "1. helper mode + guard  (the default claude-$PROVIDER launch)" --settings "$HELPER" "$GUARD"
run "2. env mode + guard     (WOLFMUX_${UP}_AUTH_MODE=env)" "$AUTH_VAR=$DUMMY" "$GUARD"
run "3. HAZARD: only the base URL is inherited, no guard"
run "4. same, with the guard (what a child of a worker presents)" "$GUARD"

awk '/^###/ { print ""; print; next } { print }' "$LOG" |
  jq -Rr 'if startswith("{") then (fromjson | "   \(.method) \(.path)  authorization=\(.authorization)  x-api-key=\(.x_api_key)  model=\(.model)") else . end'

cat <<'EOF'

expected
  1, 2  DUMMY_ZAI_KEY  and this provider's model id: the worker authenticates with that
        provider's key only (the mock calls any dummy key DUMMY_ZAI_KEY, whatever the vendor)
  3     OTHER_REAL_CREDENTIAL: the reason the guard exists
  4     GUARD_PLACEHOLDER: a child process fails closed instead of presenting your claude.ai login
EOF
