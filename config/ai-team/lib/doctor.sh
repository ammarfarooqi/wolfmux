#!/bin/bash
# doctor.sh — teamctl doctor: prove what can be proven locally about where each
# agent's traffic and billing go, and say plainly what cannot be proven.
# Prints variable NAMES and file locations only — never a credential value.

DOC_WARN=0
DOC_FAIL=0

_ok() { printf '  %sok%s    %s\n' "$_C_GRN" "$_C_OFF" "$*"; }
_note() { printf '  %s..%s    %s\n' "$_C_DIM" "$_C_OFF" "$*"; }
_fail() {
  DOC_FAIL=$((DOC_FAIL + 1))
  printf '  %sFAIL%s  %s\n' "$_C_RED" "$_C_OFF" "$*"
}
# A billing or routing risk: loud on purpose.
_risk() {
  DOC_WARN=$((DOC_WARN + 1))
  printf '  %s!! WARNING !!%s  %s\n' "$_C_RED$_C_BLD" "$_C_OFF" "$*"
}
_head() { printf '\n%s%s%s\n' "$_C_BLD" "$*" "$_C_OFF"; }

_doc_launcher() { # <launcher-name>
  local path="$AI_TEAM_BIN_DIR/$1"
  if [ -x "$path" ]; then
    if [ -L "$path" ]; then _ok "launcher  $(short_path "$path") -> $(readlink "$path")"; else _ok "launcher  $(short_path "$path")"; fi
  else
    _fail "launcher missing or not executable: $(short_path "$path")"
  fi
}

# Names of provider variables that Claude Code settings files would inject.
# These are applied INSIDE Claude Code, after a launcher has scrubbed the
# environment, so they defeat the launcher and must be reported loudly.
_doc_settings_file() { # <path>
  local file="$1" keys helper
  [ -f "$file" ] || return 0
  keys="$("$JQ_BIN" -r '(.env // {}) | keys[] | select(test("^(ANTHROPIC_|CLAUDE_CODE_USE_|AWS_BEARER_TOKEN_BEDROCK)"))' "$file" 2>/dev/null | tr '\n' ' ')"
  helper="$("$JQ_BIN" -r 'if .apiKeyHelper then "yes" else "" end' "$file" 2>/dev/null)"
  if [ -n "$keys" ]; then
    _risk "$(short_path "$file") sets env: $keys— applies to EVERY claude session, including claude-fable. Remove it."
  fi
  if [ -n "$helper" ]; then
    _risk "$(short_path "$file") defines apiKeyHelper — every claude session would use that key instead of the subscription. Remove it."
  fi
  if [ -z "$keys$helper" ]; then _ok "no provider override in $(short_path "$file")"; fi
}

_doc_profiles() {
  local file hits found=0
  for file in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zshenv" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc"; do
    [ -f "$file" ] || continue
    # grep exits 1 on "no match"; under pipefail that must not abort the report.
    hits="$(grep -nE '^[[:space:]]*(export[[:space:]]+)?(ANTHROPIC_[A-Z_]+|OPENAI_API_KEY|OPENAI_BASE_URL|CODEX_API_KEY|ZAI_[A-Z_]+)=' "$file" 2>/dev/null | sed -E 's/=.*$//' | tr '\n' ' ' || true)"
    if [ -n "$hits" ]; then
      found=1
      _risk "$(short_path "$file") exports provider variables (line:name): $hits"
    fi
  done
  if [ "$found" -eq 0 ]; then _ok "no provider variables exported by your shell profiles"; fi
}

_doc_tools() {
  local tool path
  _head "Tools"
  for tool in tmux git jq sqlite3; do
    path="$(find_tool "$tool" "/opt/homebrew/bin/$tool" "/usr/bin/$tool" || true)"
    if [ -n "$path" ]; then _ok "$tool  $path"; elif [ "$tool" = "sqlite3" ]; then _note "sqlite3 not found (unused in V1)"; else _fail "$tool not found"; fi
  done
  case ":$PATH:" in
    *":$AI_TEAM_BIN_DIR:"*) _ok "$(short_path "$AI_TEAM_BIN_DIR") is on PATH" ;;
    *) _fail "$(short_path "$AI_TEAM_BIN_DIR") is not on PATH in this shell (open a new terminal, or check the ai-team block in ~/.zshrc)" ;;
  esac
  if [ -r "$AI_TEAM_HOME/TEAM_PROTOCOL.md" ]; then _ok "team protocol  $(short_path "$AI_TEAM_HOME/TEAM_PROTOCOL.md")"; else _fail "team protocol file missing"; fi
}

_doc_fable() {
  local bin inherited auth_json auth_method
  _head "Lead option 1 — Claude Code + Fable 5.1   (expected billing: Claude subscription)"
  _doc_launcher claude-fable
  if bin="$(ai_team_resolve_claude)"; then _ok "claude    $bin  ($("$bin" --version 2>/dev/null | head -1))"; else _fail "Claude Code CLI not found"; fi
  inherited="$(ai_team_list_set_vars "$AI_TEAM_CLAUDE_PROVIDER_VARS" "$AI_TEAM_CLAUDE_PROVIDER_PREFIXES" | tr '\n' ' ')"
  case " $inherited" in *" ANTHROPIC_API_KEY "*) _risk "ANTHROPIC_API_KEY is set in this environment. claude-fable removes it, but plain 'claude' would bill the Anthropic API." ;; *) _ok "ANTHROPIC_API_KEY is not inherited" ;; esac
  case " $inherited" in *" ANTHROPIC_BASE_URL "*) _risk "ANTHROPIC_BASE_URL is set in this environment. claude-fable removes it, but plain 'claude' would send traffic there." ;; *) _ok "no custom ANTHROPIC_BASE_URL is inherited" ;; esac
  case " $inherited" in *" ANTHROPIC_AUTH_TOKEN "*) _risk "ANTHROPIC_AUTH_TOKEN is set in this environment. claude-fable removes it; plain 'claude' would use it." ;; esac
  [ -z "$inherited" ] || _note "provider variables present here (all removed by the launchers): $inherited"
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    _risk "CLAUDE_CONFIG_DIR is set ($CLAUDE_CONFIG_DIR): Claude Code reads settings and login from there, not ~/.claude. The checks below follow it; make sure that is intended."
  fi
  _doc_settings_file "$CLAUDE_DIR/settings.json"
  _doc_settings_file "$CLAUDE_DIR/settings.local.json"
  if [ -n "${ROOT:-}" ]; then
    _doc_settings_file "$ROOT/.claude/settings.json"
    _doc_settings_file "$ROOT/.claude/settings.local.json"
  fi
  # Ask Claude Code itself which credential it would use from the launcher's
  # scrubbed environment (local status query; no model call, no secret printed).
  auth_json="$("$AI_TEAM_BIN_DIR/claude-fable" auth status --json 2>/dev/null || true)"
  auth_method="$(printf '%s' "$auth_json" | "$JQ_BIN" -r '.authMethod // "unknown"' 2>/dev/null || printf 'unknown')"
  case "$auth_method" in
    claude.ai) _ok "claude-fable authenticates with: claude.ai login (subscription: $(printf '%s' "$auth_json" | "$JQ_BIN" -r '.subscriptionType // "unknown"'))" ;;
    unknown) _risk "could not read Claude Code's auth status — run 'claude' and /login with your subscription account" ;;
    *) _risk "claude-fable would authenticate with '$auth_method', not your claude.ai login — that is not subscription billing. Run: claude auth status" ;;
  esac
  _note "Configured for subscription authentication; verify account status in the CLI (/status)."
}

_doc_astra() {
  local bin status inherited
  _head "Lead option 2 — Codex CLI + GPT-6 Astra   (expected billing: ChatGPT/Codex subscription)"
  _doc_launcher codex-astra
  if bin="$(ai_team_resolve_codex)"; then
    _ok "codex     $bin  ($("$bin" --version 2>/dev/null | head -1))"
    status="$("$bin" login status 2>&1 | head -1 | sed -E 's/sk-[A-Za-z0-9_*.-]+/<redacted>/g' || true)"
    case "$status" in
      *ChatGPT*) _ok "codex login status: $status" ;;
      *[Aa][Pp][Ii]*) _risk "codex login status: $status — API-key login means metered API billing. Run: codex logout && codex login" ;;
      *) _risk "codex login status: ${status:-unknown} — sign in with ChatGPT: codex login" ;;
    esac
  else
    _fail "Codex CLI not found (PATH and ChatGPT.app were checked)"
  fi
  inherited="$(ai_team_list_set_vars "$AI_TEAM_CODEX_PROVIDER_VARS" "$AI_TEAM_CODEX_PROVIDER_PREFIXES" | tr '\n' ' ')"
  case " $inherited" in *" OPENAI_API_KEY "*) _risk "OPENAI_API_KEY is set in this environment. codex-astra removes it, but other tools here would bill the OpenAI API." ;; *) _ok "OPENAI_API_KEY is not inherited" ;; esac
  case " $inherited" in *" CODEX_API_KEY "*) _risk "CODEX_API_KEY is set in this environment. codex-astra removes it; plain 'codex exec' would bill the API." ;; esac
  if [ -n "${CODEX_HOME:-}" ]; then
    _risk "CODEX_HOME is set ($CODEX_HOME): Codex reads config and login from there, not ~/.codex. The checks below follow it; make sure that is intended."
  fi
  if [ -f "$CODEX_DIR/auth.json" ] && [ "$("$JQ_BIN" -r 'if (.OPENAI_API_KEY // null) != null then "yes" else "no" end' "$CODEX_DIR/auth.json" 2>/dev/null)" = "yes" ]; then
    _risk "$(short_path "$CODEX_DIR/auth.json") stores an API key. codex-astra forces ChatGPT login, but remove it: codex logout && codex login"
  else
    _ok "no API key stored in $(short_path "$CODEX_DIR/auth.json")"
  fi
  if grep -qE '^[[:space:]]*model_provider[[:space:]]*=' "$CODEX_DIR/config.toml" 2>/dev/null; then
    _note "~/.codex/config.toml sets model_provider; codex-astra overrides it with the built-in 'openai' provider"
  fi
  if [ -f "$CODEX_DIR/rules/ai-team.rules" ]; then _ok "Codex rule file lets Astra run teamctl and bd: $(short_path "$CODEX_DIR/rules/ai-team.rules")"; else _note "no ~/.codex/rules/ai-team.rules: Astra will ask before each teamctl / bd command"; fi
  _note "Configured for subscription authentication; verify account status in the CLI (/status)."
}

_doc_glm() {
  local file leaked=0 glm_mode
  glm_mode="$( (ai_team_load_config; printf '%s' "${AI_TEAM_GLM_AUTH_MODE:-helper}") )"
  _head "Workers — Claude Code + GLM-5.3 / GLM-5.3 Flash   (expected billing: Z.ai GLM Coding Plan)"
  _doc_launcher claude-glm
  _doc_launcher claude-glm-flash
  if ai_team_zai_key_exists; then
    _ok "Keychain item '$AI_TEAM_ZAI_KEYCHAIN_SERVICE' exists (value not read)"
  else
    _risk "Z.ai credential is missing: no Keychain item '$AI_TEAM_ZAI_KEYCHAIN_SERVICE'. Workers cannot start. Add it:"
    printf '                   security add-generic-password -U -s %s -a "$USER" -l "Z.ai Coding Plan API key" -w\n' "$AI_TEAM_ZAI_KEYCHAIN_SERVICE"
  fi
  _ok "endpoint  $AI_TEAM_ZAI_BASE_URL  (Coding Plan endpoint; set only inside the launcher process)"
  case "$glm_mode" in
    helper) _ok "key delivery: apiKeyHelper (Keychain read on demand; the key never enters a worker's environment)" ;;
    env) _note "key delivery: ANTHROPIC_AUTH_TOKEN (Z.ai's documented mode; the key is visible to a worker's subprocesses)" ;;
    *) _fail "AI_TEAM_GLM_AUTH_MODE='$glm_mode' in $(short_path "$AI_TEAM_HOME/config") is invalid (use helper or env)" ;;
  esac
  _ok "login guard on: nothing a GLM worker spawns can present your claude.ai login to Z.ai"
  if [ -r "$AI_TEAM_HOME/glm-worker-settings.json" ]; then
    if "$JQ_BIN" -e . "$AI_TEAM_HOME/glm-worker-settings.json" >/dev/null 2>&1; then
      _ok "worker settings overlay: $(short_path "$AI_TEAM_HOME/glm-worker-settings.json")  (plugins off in workers: $("$JQ_BIN" -r '[(.enabledPlugins // {}) | to_entries[] | select(.value == false) | .key] | join(", ") | if . == "" then "none" else . end' "$AI_TEAM_HOME/glm-worker-settings.json"))"
    else
      _fail "worker settings overlay is not valid JSON: $(short_path "$AI_TEAM_HOME/glm-worker-settings.json")"
    fi
  else
    _note "no worker settings overlay: GLM workers load exactly your normal Claude Code plugins"
  fi
  _ok "models    glm-5.3 (claude-glm), glm-5.3-flash (claude-glm-flash); every Claude alias is mapped to one of the two"
  for file in "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.local.json" "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zshenv" "$HOME/.profile"; do
    if [ -f "$file" ] && grep -qiE 'api\.z\.ai|bigmodel\.cn|glm-[0-9]' "$file" 2>/dev/null; then
      leaked=1
      _risk "$(short_path "$file") mentions Z.ai/GLM — Z.ai settings must live only in the launchers, or plain 'claude' is redirected."
    fi
  done
  if [ "$leaked" -eq 0 ]; then _ok "no Z.ai configuration outside the launchers (plain 'claude' stays on Anthropic)"; fi
  _note "Configured for the Coding Plan endpoint; verify the plan and quota at z.ai, and in a worker with /status."
}

_doc_beads() {
  local dir
  _head "Beads — tasks and messages"
  if [ -n "$BD_BIN" ]; then _ok "bd        $BD_BIN  ($("$BD_BIN" version 2>/dev/null | head -1))"; else _fail "bd not found. Install: https://github.com/gastownhall/beads#-installation"; return 0; fi
  if grep -qE 'disabled:[[:space:]]*true' "$HOME/.config/bd/config.yaml" 2>/dev/null; then _ok "bd usage metrics are off"; else _note "bd usage metrics are on (anonymous command names). Turn off: bd metrics off"; fi
  [ -n "${ROOT:-}" ] || { _note "not inside a git repository: project checks skipped"; return 0; }
  if dir="$(beads_dir)"; then
    _ok "workspace $(short_path "$dir")"
    case "$(beads_hooks_status "$dir")" in
      installed) _ok "pane-notification hooks installed (on_create, on_update, on_close)" ;;
      partial) _note "some pane-notification hooks are missing or not ours; teamctl start repairs what it safely can" ;;
      *) _note "pane-notification hooks not installed yet; teamctl start installs them" ;;
    esac
  else
    _note "Beads is not initialized in this repository yet; teamctl start offers to do it"
  fi
}

_doc_team() {
  local sessions
  _head "tmux team server (socket: $AI_TEAM_TMUX_SOCKET)"
  [ -n "$TMUX_BIN" ] || return 0
  _ok "tmux      $TMUX_BIN  ($("$TMUX_BIN" -V))"
  if [ -r "$AI_TEAM_HOME/tmux.conf" ]; then _ok "config    $(short_path "$AI_TEAM_HOME/tmux.conf") (team server only; ~/.tmux.conf is not touched)"; else _fail "team tmux config missing: $AI_TEAM_HOME/tmux.conf"; fi
  sessions="$(tmx list-sessions -F '#{session_name} (#{session_windows} window, attached: #{session_attached})' 2>/dev/null | tr '\n' ';' || true)"
  if [ -n "$sessions" ]; then _ok "running sessions: $sessions"; else _note "no team session running"; fi
}

_doc_policy() {
  local settings="$CLAUDE_DIR/settings.json" teams
  _head "Team policy (defaults from $(short_path "$AI_TEAM_HOME/config"); per project: teamctl policy)"
  _ok "manager: the lead only — workers cannot stop, restart, destroy, approve or change policy"
  _note "lead-permissions=$(policy_default lead-permissions)  worker-permissions=$(policy_default worker-permissions)  worker-spawn=$(policy_default worker-spawn)"
  case "$(policy_default lead-permissions)$(policy_default worker-permissions)" in
    *skip*) _note "skip = the CLI's bypass mode: that agent runs any command as you, without asking. Deny rules and explicit ask rules (teamctl destroy) still apply." ;;
  esac
  teams="$("$JQ_BIN" -r '.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS // ""' "$settings" 2>/dev/null || true)"
  if [ "$teams" = "1" ]; then
    _ok "Claude Code agent teams are on in your settings; teamctl turns them off inside workers, so a worker can never become a second manager"
  fi
}

cmd_doctor() {
  [ -n "$JQ_BIN" ] || die "jq is required for doctor"
  ROOT="$(resolve_root 2>/dev/null || true)"
  CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
  printf '%steamctl doctor%s  (teamctl %s)\n' "$_C_BLD" "$_C_OFF" "$AI_TEAM_VERSION"
  _doc_tools
  _doc_fable
  _doc_astra
  _doc_glm
  _head "Shell profiles"
  _doc_profiles
  _doc_beads
  _doc_team
  _doc_policy
  _head "Account-side settings no local tool can see — check them once"
  _note "claude.ai  > Settings > Usage: keep 'extra usage' OFF, or overage beyond the plan is metered."
  _note "chatgpt.com > Settings > Codex usage: do not buy or auto-refill credits if you want plan-only usage."
  _note "z.ai       > Billing: a zero cash balance makes pay-as-you-go impossible even if a call left the plan."
  printf '\n'
  if [ "$DOC_FAIL" -gt 0 ] || [ "$DOC_WARN" -gt 0 ]; then
    printf '%sresult: %d failure(s), %d warning(s)%s\n' "$_C_BLD" "$DOC_FAIL" "$DOC_WARN" "$_C_OFF"
    [ "$DOC_FAIL" -gt 0 ] && exit 1
    exit 2
  fi
  printf '%sresult: all checks passed%s\n' "$_C_BLD" "$_C_OFF"
}
