#!/bin/bash
# provider-env.sh — single source of truth for the environment variables that can
# redirect, re-authenticate or re-bill an agent CLI.
#
# Sourced by the launchers in ~/bin (to scrub their own process environment) and
# by `teamctl doctor` (to report what a launcher would have to scrub).
# Contains no credentials. Compatible with macOS /bin/bash 3.2.

AI_TEAM_ZAI_BASE_URL="https://api.z.ai/api/anthropic"
AI_TEAM_ZAI_KEYCHAIN_SERVICE="zai-coding-plan"

# Exported as CLAUDE_CODE_OAUTH_TOKEN inside every GLM worker. It is not a secret
# and authenticates nowhere. Measured against a localhost mock endpoint: a Claude
# Code process that inherits ANTHROPIC_BASE_URL but no token presents the real
# claude.ai login to that URL. This inert value ranks above the stored login
# (and below ANTHROPIC_AUTH_TOKEN and apiKeyHelper), so anything a GLM worker
# spawns fails closed at Z.ai instead of handing it the Claude subscription token.
AI_TEAM_GLM_GUARD_TOKEN="ai-team-glm-worker-no-anthropic-credential"

# Settings a launcher may take from ~/.config/ai-team/config (KEY=value lines).
AI_TEAM_CONFIG_KEYS="AI_TEAM_GLM_AUTH_MODE AI_TEAM_GLM_CONTEXT AI_TEAM_FABLE_MODEL AI_TEAM_ASTRA_MODEL
AI_TEAM_LEAD_PERMISSIONS AI_TEAM_WORKER_PERMISSIONS AI_TEAM_WORKER_SPAWN AI_TEAM_APPROVAL_TIMEOUT"

# Credential, endpoint, provider and model overrides understood by Claude Code.
# Any of these, inherited by accident, can move traffic off the Claude subscription.
AI_TEAM_CLAUDE_PROVIDER_VARS="
ANTHROPIC_API_KEY
ANTHROPIC_AUTH_TOKEN
ANTHROPIC_BASE_URL
ANTHROPIC_DEFAULT_OPUS_MODEL
ANTHROPIC_DEFAULT_SONNET_MODEL
ANTHROPIC_DEFAULT_HAIKU_MODEL
ANTHROPIC_DEFAULT_FABLE_MODEL
ANTHROPIC_DEFAULT_MODEL
ANTHROPIC_MODEL
ANTHROPIC_SMALL_FAST_MODEL
ANTHROPIC_CUSTOM_HEADERS
ANTHROPIC_PROFILE
ANTHROPIC_BEDROCK_BASE_URL
ANTHROPIC_VERTEX_BASE_URL
ANTHROPIC_VERTEX_PROJECT_ID
ANTHROPIC_FOUNDRY_BASE_URL
ANTHROPIC_FOUNDRY_RESOURCE
ANTHROPIC_FOUNDRY_API_KEY
AWS_BEARER_TOKEN_BEDROCK
CLAUDE_CODE_USE_BEDROCK
CLAUDE_CODE_USE_VERTEX
CLAUDE_CODE_USE_FOUNDRY
CLAUDE_CODE_SKIP_BEDROCK_AUTH
CLAUDE_CODE_SKIP_VERTEX_AUTH
CLAUDE_CODE_SKIP_FOUNDRY_AUTH
CLAUDE_CODE_SUBAGENT_MODEL
CLAUDE_CODE_EXTRA_BODY
CLAUDE_CODE_MAX_CONTEXT_TOKENS
CLAUDE_CODE_AUTO_COMPACT_WINDOW
CLAUDE_CODE_API_KEY_HELPER_TTL_MS
"

# Prefixes swept after the explicit list, so a variable added by a future CLI
# release is still removed.
AI_TEAM_CLAUDE_PROVIDER_PREFIXES="ANTHROPIC_ CLAUDE_CODE_USE_"

# Set by Claude Code inside the subprocesses it spawns. A launcher started from an
# agent's shell (or from a tmux server that an agent started) must not inherit
# them, or the new CLI believes it is a child session and skips transcript
# persistence and prompt history.
AI_TEAM_CLAUDE_SESSION_VARS="
CLAUDECODE
CLAUDE_CODE_CHILD_SESSION
CLAUDE_CODE_SESSION_ID
CLAUDE_CODE_BRIDGE_SESSION_ID
CLAUDE_CODE_MESSAGING_SOCKET
CLAUDE_CODE_MESSAGING_TOKEN
CLAUDE_CODE_ENTRYPOINT
CLAUDE_CODE_EXECPATH
CLAUDE_CODE_SESSION_ATTENDED
CLAUDE_JOB_DIR
CLAUDE_PID
CLAUDE_EFFORT
"

# Variables that can move Codex off the ChatGPT login and onto metered API billing.
AI_TEAM_CODEX_PROVIDER_VARS="
OPENAI_API_KEY
OPENAI_BASE_URL
OPENAI_API_BASE
OPENAI_ORG_ID
OPENAI_ORGANIZATION
OPENAI_PROJECT
CODEX_API_KEY
CODEX_ACCESS_TOKEN
AZURE_OPENAI_API_KEY
"
AI_TEAM_CODEX_PROVIDER_PREFIXES="OPENAI_"

# Subcommands of `claude` that do not start a model session; --model and
# --append-system-prompt are not injected in front of them.
AI_TEAM_CLAUDE_SUBCOMMANDS="agents attach auth auto-mode doctor gateway import install logs mcp plugin plugins project respawn rm setup-token stop kill ultrareview update upgrade"

# Names of exported variables starting with any of the given prefixes.
_ai_team_vars_with_prefixes() {
  local prefix name
  for prefix in "$@"; do
    # compgen -e prints exported names only; never values.
    for name in $(compgen -e | grep -E "^${prefix}" || true); do
      printf '%s\n' "$name"
    done
  done
}

# Print the names (never the values) of set variables from a list plus prefixes.
# usage: ai_team_list_set_vars "<newline list>" "<space separated prefixes>"
ai_team_list_set_vars() {
  local list="$1" prefixes="$2" name
  {
    for name in $list; do
      if [ -n "${!name+x}" ]; then printf '%s\n' "$name"; fi
    done
    # shellcheck disable=SC2086
    _ai_team_vars_with_prefixes $prefixes
  } | sort -u
}

ai_team_scrub_claude_env() {
  local name
  for name in $(ai_team_list_set_vars "$AI_TEAM_CLAUDE_PROVIDER_VARS" "$AI_TEAM_CLAUDE_PROVIDER_PREFIXES"); do
    unset "$name"
  done
  for name in $AI_TEAM_CLAUDE_SESSION_VARS; do
    unset "$name"
  done
  # A real CLAUDE_CODE_OAUTH_TOKEN is subscription auth and stays. The GLM guard
  # value, inherited from a worker's shell, would only break this launcher.
  if [ "${CLAUDE_CODE_OAUTH_TOKEN:-}" = "$AI_TEAM_GLM_GUARD_TOKEN" ]; then
    unset CLAUDE_CODE_OAUTH_TOKEN
  fi
}

# ai_team_load_config — take allow-listed KEY=value settings from the config file.
# The file is parsed, never sourced, and an already-set environment variable wins.
ai_team_load_config() {
  local file="${AI_TEAM_HOME:-$HOME/.config/ai-team}/config" line key value allowed
  [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "" | \#*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    key="${key//[[:space:]]/}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    for allowed in $AI_TEAM_CONFIG_KEYS; do
      if [ "$key" = "$allowed" ] && [ -z "${!key+x}" ]; then
        export "$key=$value"
      fi
    done
  done <"$file"
}

ai_team_scrub_codex_env() {
  local name
  for name in $(ai_team_list_set_vars "$AI_TEAM_CODEX_PROVIDER_VARS" "$AI_TEAM_CODEX_PROVIDER_PREFIXES"); do
    unset "$name"
  done
}

# ai_team_merge_settings <helper-command-or-empty> <json-file>... — one JSON value
# for Claude Code's --settings flag. Later files win; missing files are skipped.
# Used for: the GLM worker overlay, the per-agent settings teamctl generates
# ($AI_TEAM_EXTRA_SETTINGS), and the Keychain key helper.
ai_team_merge_settings() {
  local helper="$1" jq_bin merged="{}" file
  shift
  jq_bin="$(command -v jq 2>/dev/null || true)"
  [ -n "$jq_bin" ] || jq_bin="/usr/bin/jq"
  for file in "$@"; do
    [ -n "$file" ] && [ -r "$file" ] || continue
    merged="$("$jq_bin" -c -n --argjson a "$merged" --slurpfile b "$file" '$a * $b[0]')" || {
      echo "ai-team: $file is not valid JSON — fix or delete it" >&2
      return 1
    }
  done
  if [ -n "$helper" ]; then
    merged="$(printf '%s' "$merged" | "$jq_bin" -c --arg helper "$helper" '. + {apiKeyHelper: $helper}')" || return 1
  fi
  printf '%s\n' "$merged"
}

# Resolve the real Claude Code binary. Never resolves to one of our launchers,
# because none of them is named `claude`.
ai_team_resolve_claude() {
  local candidate
  for candidate in "${AI_TEAM_CLAUDE_BIN:-}" "$(command -v claude 2>/dev/null || true)" "$HOME/.local/bin/claude"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# Resolve the Codex CLI: explicit override, PATH, then the copy bundled with the
# ChatGPT / Codex desktop app.
ai_team_resolve_codex() {
  local candidate
  for candidate in "${AI_TEAM_CODEX_BIN:-}" "$(command -v codex 2>/dev/null || true)" \
    "/Applications/ChatGPT.app/Contents/Resources/codex" \
    "/Applications/Codex.app/Contents/Resources/codex"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# True when the first argument names a `claude` subcommand.
ai_team_is_claude_subcommand() {
  local first="${1:-}" sub
  for sub in $AI_TEAM_CLAUDE_SUBCOMMANDS; do
    [ "$first" = "$sub" ] && return 0
  done
  return 1
}

# True when the caller already chose a model.
ai_team_args_have_model() {
  local arg
  for arg in "$@"; do
    case "$arg" in --model | --model=*) return 0 ;; esac
  done
  return 1
}

# True when the Z.ai Coding Plan key exists in the login Keychain. Reads no secret.
ai_team_zai_key_exists() {
  /usr/bin/security find-generic-password -s "$AI_TEAM_ZAI_KEYCHAIN_SERVICE" >/dev/null 2>&1
}

ai_team_zai_key_help() {
  cat <<EOF
Add your Z.ai Coding Plan API key to the macOS Keychain (you will be prompted for
the key; it is never echoed, never written to shell history):

  security add-generic-password -U -s ${AI_TEAM_ZAI_KEYCHAIN_SERVICE} -a "\$USER" -l "Z.ai Coding Plan API key" -w

EOF
}
