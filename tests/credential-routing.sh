#!/bin/bash
# credential-routing.sh — MANUAL, opt-in evidence test. Not part of smoke.sh.
#
# Question it answers: for each way a GLM worker can be launched, which KIND of
# credential and which model id does Claude Code actually put on the wire?
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
#   tests/credential-routing.sh        # needs: claude (logged in), python3, jq
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=/dev/null
. "$REPO/config/ai-team/lib/provider-env.sh"

PORT="${PORT:-18765}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ai-team-routing.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)" # physical path: that is what Claude Code names its transcript folder after
LOG="$WORK/requests.log"
CLAUDE_BIN="$(ai_team_resolve_claude)" || {
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
  case "$slug" in *ai-team-routing*) /bin/rm -rf "$HOME/.claude/projects/$slug" ;; esac
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT
sleep 1
/bin/mkdir -p "$WORK/cwd"
cd "$WORK/cwd" || exit 1

GLM_ENV=(ANTHROPIC_MODEL=glm-5.3 ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.3 ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.3
  ANTHROPIC_DEFAULT_FABLE_MODEL=glm-5.3 ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-5.3-flash CLAUDE_CODE_SUBAGENT_MODEL=glm-5.3)

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
    ai_team_scrub_claude_env
    env CLAUDE_CODE_SAFE_MODE=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 API_TIMEOUT_MS=8000 \
      ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" "${GLM_ENV[@]}" "$@" \
      "$CLAUDE_BIN" ${settings[@]+"${settings[@]}"} -p "say hi" --model glm-5.3 --max-turns 1 >/dev/null 2>&1 </dev/null
  )
}

HELPER='{"apiKeyHelper":"echo dummy-zai-key"}'
GUARD="CLAUDE_CODE_OAUTH_TOKEN=$AI_TEAM_GLM_GUARD_TOKEN"

run "1. helper mode + guard  (the default claude-glm launch)" --settings "$HELPER" "$GUARD"
run "2. env mode + guard     (AI_TEAM_GLM_AUTH_MODE=env)" ANTHROPIC_AUTH_TOKEN=dummy-zai-key "$GUARD"
run "3. HAZARD: only the base URL is inherited, no guard"
run "4. same, with the guard (what a child of a GLM worker presents)" "$GUARD"

awk '/^###/ { print ""; print; next } { print }' "$LOG" |
  jq -Rr 'if startswith("{") then (fromjson | "   \(.method) \(.path)  authorization=\(.authorization)  x-api-key=\(.x_api_key)  model=\(.model)") else . end'

cat <<'EOF'

expected
  1, 2  DUMMY_ZAI_KEY  and a glm-* model id: the worker authenticates with the Z.ai key only
  3     OTHER_REAL_CREDENTIAL: the reason the guard exists
  4     GUARD_PLACEHOLDER: a child process fails closed instead of presenting your claude.ai login
EOF
