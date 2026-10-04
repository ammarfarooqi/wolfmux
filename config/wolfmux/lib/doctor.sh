#!/bin/bash
# doctor.sh — teamctl doctor: prove what can be proven locally about where each
# agent's traffic and billing go, and say plainly what cannot be proven.
# Prints variable NAMES and file locations only — never a credential value.

DOC_WARN=0
DOC_FAIL=0
DOC_PROBE=0  # 1 under --probe: the only mode in which doctor reads a key value
DOC_PROBED=0 # requests the probe sent

_ok() { printf '  %sok%s    %s\n' "$_C_GRN" "$_C_OFF" "$*"; }
_note() { printf '  %s..%s    %s\n' "$_C_DIM" "$_C_OFF" "$*"; }
_fail() {
  DOC_FAIL=$((DOC_FAIL + 1))
  printf '  %sFAIL%s  %s\n' "$_C_RED" "$_C_OFF" "$*"
}
# A result that is not a verdict (a probe nobody answered): counted, but not shouted.
_warn() {
  DOC_WARN=$((DOC_WARN + 1))
  printf '  %swarn%s  %s\n' "$_C_YEL" "$_C_OFF" "$*"
}
# A billing or routing risk: loud on purpose.
_risk() {
  DOC_WARN=$((DOC_WARN + 1))
  printf '  %s!! WARNING !!%s  %s\n' "$_C_RED$_C_BLD" "$_C_OFF" "$*"
}
_head() { printf '\n%s%s%s\n' "$_C_BLD" "$*" "$_C_OFF"; }

_doc_launcher() { # <launcher-name>
  local path="$WOLFMUX_BIN_DIR/$1"
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
    _risk "$(short_path "$file") sets env: ${keys}— applies to EVERY claude session, including claude-fable. Remove it."
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
    hits="$(LC_ALL=C grep -nE '^[[:space:]]*(export[[:space:]]+)?(ANTHROPIC_[A-Z_]+|OPENAI_API_KEY|OPENAI_BASE_URL|CODEX_API_KEY|ZAI_[A-Z_]+)=' "$file" 2>/dev/null | sed -E 's/=.*$//' | tr '\n' ' ' || true)"
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
    *":$WOLFMUX_BIN_DIR:"*) _ok "$(short_path "$WOLFMUX_BIN_DIR") is on PATH" ;;
    *) _fail "$(short_path "$WOLFMUX_BIN_DIR") is not on PATH in this shell (open a new terminal, or check the wolfmux block in ~/.zshrc)" ;;
  esac
  if [ -r "$WOLFMUX_HOME/TEAM_PROTOCOL.md" ]; then _ok "team protocol  $(short_path "$WOLFMUX_HOME/TEAM_PROTOCOL.md")"; else _fail "team protocol file missing"; fi
  # Tab completion: the shims install.sh puts in ~/.config/wolfmux/completion and the
  # line in ~/.zshrc that sources them (ADR-0026).
  if [ -r "$WOLFMUX_HOME/completion/teamctl.zsh" ]; then
    if [ -f "$HOME/.zshrc" ] && grep -q 'completion/teamctl.zsh' "$HOME/.zshrc"; then
      _ok "completion  installed; ~/.zshrc sources it (open a new terminal, then: teamctl <Tab>)"
    else
      _note "completion  installed; ~/.zshrc does not source it yet (re-run: ./install.sh)"
    fi
  else
    _note "completion  not installed (re-run ./install.sh; teamctl completion <zsh|bash> prints the script)"
  fi
}

_doc_fable() {
  local bin inherited auth_json auth_method other
  _head "Lead option 1 — Claude Code + Fable 5.1   (expected billing: Claude subscription)"
  _doc_launcher claude-fable
  for other in claude-opus claude-sonnet claude-haiku; do
    if [ -x "$WOLFMUX_BIN_DIR/$other" ]; then _ok "launcher  $other (same login, another model: teamctl spawn <role> ${other#claude-})"; else _note "launcher $other is missing; ./install.sh links it"; fi
  done
  if bin="$(wolfmux_resolve_claude)"; then _ok "claude    $bin  ($("$bin" --version 2>/dev/null | head -1))"; else _fail "Claude Code CLI not found"; fi
  inherited="$(wolfmux_list_set_vars "$WOLFMUX_CLAUDE_PROVIDER_VARS" "$WOLFMUX_CLAUDE_PROVIDER_PREFIXES" | tr '\n' ' ')"
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
  auth_json="$("$WOLFMUX_BIN_DIR/claude-fable" auth status --json 2>/dev/null || true)"
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
  if bin="$(wolfmux_resolve_codex)"; then
    _ok "codex     $bin  ($("$bin" --version 2>/dev/null | head -1))"
    status="$("$bin" login status 2>&1 | head -1 | LC_ALL=C sed -E 's/sk-[A-Za-z0-9_*.-]+/<redacted>/g' || true)"
    case "$status" in
      *ChatGPT*) _ok "codex login status: $status" ;;
      *[Aa][Pp][Ii]*) _risk "codex login status: $status — API-key login means metered API billing. Run: codex logout && codex login" ;;
      *) _risk "codex login status: ${status:-unknown} — sign in with ChatGPT: codex login" ;;
    esac
  else
    _fail "Codex CLI not found (PATH and ChatGPT.app were checked)"
  fi
  inherited="$(wolfmux_list_set_vars "$WOLFMUX_CODEX_PROVIDER_VARS" "$WOLFMUX_CODEX_PROVIDER_PREFIXES" | tr '\n' ' ')"
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
  if [ -f "$CODEX_DIR/rules/wolfmux.rules" ]; then _ok "Codex rule file lets Astra run teamctl and bd: $(short_path "$CODEX_DIR/rules/wolfmux.rules")"; else _note "no ~/.codex/rules/wolfmux.rules: Astra will ask before each teamctl / bd command"; fi
  _note "Configured for subscription authentication; verify account status in the CLI (/status)."
}

# _doc_overlay: the Claude Code settings overlay every third-party provider's agents get
_doc_overlay() {
  local overlay="$WOLFMUX_HOME/glm-worker-settings.json"
  if [ -r "$overlay" ]; then
    if "$JQ_BIN" -e . "$overlay" >/dev/null 2>&1; then
      _ok "worker settings overlay: $(short_path "$overlay")  (applies to every provider below; plugins off there: $("$JQ_BIN" -r '[(.enabledPlugins // {}) | to_entries[] | select(.value == false) | .key] | join(", ") | if . == "" then "none" else . end' "$overlay"))"
    else
      _fail "worker settings overlay is not valid JSON: $(short_path "$overlay")"
    fi
  else
    _note "no worker settings overlay: agents on other providers load exactly your normal Claude Code plugins"
  fi
}

# --- teamctl doctor --probe ----------------------------------------------------------------------
# For every provider whose key is in the Keychain: ONE request to that provider's endpoint, and
# the HTTP status is all that is reported. Plain doctor stays offline and never reads a key value;
# this is the only code in doctor that does (issue #1: a key of the wrong kind was reported ok).
#
# The request is an incomplete one on purpose: POST <endpoint>/v1/messages with the body {}.
# It asks for no completion, so nothing is generated and nothing is billed, not even by a metered
# provider. It is not a model listing because GET /v1/models does not tell: Z.ai answers it
# without any key, Moonshot and Qwen have no such route (measured 2026-09-23, docs/adr/0024).
# The six endpoints answer that POST with a fake key 401 (the key is checked first, the body
# after), so a good key should get 400 or 422. That good-key side is inferred, not measured,
# which is why the raw status is printed next to "accepted".
#
# The key reaches curl on its stdin and nowhere else: not its arguments, not the environment of
# any process, not a file (a here-document or here-string is a temporary file in bash 3.2, so a
# pipe from the printf builtin is used), and not the screen. curl reads no ~/.curlrc (-q), does
# not follow a redirect, and is given an https address only.
DOC_PROBE_TIMEOUT=15

# _doc_probe_url_ok <url>: https, and nothing that could end a quoted value of curl's config
_doc_probe_url_ok() {
  case "$1" in https://*) ;; *) return 1 ;; esac
  case "${1#https://}" in
    "" | *[!${_WM_LOWER}${_WM_UPPER}${_WM_DIGITS}._~:/%-]*) return 1 ;;
  esac
}

# _doc_probe_key_ok <key>: what an API key is made of. Anything else (a space, a quote, a
# backslash, a line break) could add a line to curl's config, so it is not sent.
_doc_probe_key_ok() {
  case "$1" in
    "" | *[!${_WM_LOWER}${_WM_UPPER}${_WM_DIGITS}._~+/=:-]*) return 1 ;;
  esac
}

# _doc_probe_key <provider>: the key, on stdout: the one place in doctor that reads it
_doc_probe_key() {
  wolfmux_provider_info "$1" || return 1
  /usr/bin/security find-generic-password -s "$PROVIDER_KEYCHAIN" -w 2>/dev/null
}

# _doc_probe_config <url> <key>: what curl reads from its stdin: the address, the two headers a
# provider worker's key helper sends (a vendor reads one or the other), the API version, and an
# empty JSON object. The key is an argument of the printf builtin, so no process ever has it.
_doc_probe_config() {
  printf 'url = "%s"\nheader = "x-api-key: %s"\nheader = "authorization: Bearer %s"\nheader = "anthropic-version: 2023-06-01"\nheader = "content-type: application/json"\ndata = "{}"\n' "$1" "$2" "$2"
}

# _doc_probe_send <curl> <url> <key>: prints the HTTP status, 000 when nobody answered;
# returns 2, sending nothing, for an address that is not a plain https one
_doc_probe_send() {
  local curl_bin="$1" url="$2" key="$3" code
  _doc_probe_url_ok "$url" || return 2
  code="$(_doc_probe_config "$url" "$key" | "$curl_bin" -q -s -o /dev/null -w '%{http_code}' --max-time "$DOC_PROBE_TIMEOUT" --config - 2>/dev/null)" || true
  case "$code" in [0-9][0-9][0-9]) ;; *) code=000 ;; esac
  printf '%s\n' "$code"
}

# _doc_probe_provider <provider>: the report lines of one provider's probe (call it only for a
# provider whose Keychain item exists)
_doc_probe_provider() {
  local p="$1" curl_bin url key code note source
  wolfmux_provider_info "$p" || return 0
  source="${PROVIDER_KEY_SOURCE:-Where to get one: $PROVIDER_KEY_URL}"
  if ! _doc_probe_url_ok "$PROVIDER_BASE_URL"; then
    _fail "probe: refusing to send a key to $PROVIDER_BASE_URL: the endpoint must be an https address of plain characters"
    return 0
  fi
  curl_bin="$(find_tool curl /usr/bin/curl || true)"
  if [ -z "$curl_bin" ]; then
    _fail "probe: curl not found, so no key can be checked"
    return 0
  fi
  if ! key="$(_doc_probe_key "$p")"; then
    _warn "probe: could not read the key from '$PROVIDER_KEYCHAIN' (is the login keychain unlocked?): nothing was sent"
    return 0
  fi
  if [ -z "$key" ]; then
    _warn "probe: the Keychain item '$PROVIDER_KEYCHAIN' is empty: nothing was sent"
    return 0
  fi
  if ! _doc_probe_key_ok "$key"; then
    _warn "probe: the key in '$PROVIDER_KEYCHAIN' has a character no API key has (a space, a quote, a backslash or a line break), so nothing was sent. Store it again: security add-generic-password -U -s $PROVIDER_KEYCHAIN -a \"\$USER\" -l \"$PROVIDER_KEY_LABEL\" -w"
    return 0
  fi
  if [ -n "$PROVIDER_KEY_PREFIX" ]; then
    case "$key" in
      "$PROVIDER_KEY_PREFIX"*) ;;
      *) _warn "probe: the key in '$PROVIDER_KEYCHAIN' does not start with '$PROVIDER_KEY_PREFIX' (a $PROVIDER_LABEL key does). $source" ;;
    esac
  fi
  url="${PROVIDER_BASE_URL%/}/v1/messages"
  code="$(_doc_probe_send "$curl_bin" "$url" "$key")" || code=000
  key=""
  DOC_PROBED=$((DOC_PROBED + 1))
  case "$code" in
    2??) _ok "probe: key accepted by $PROVIDER_BASE_URL (HTTP $code)" ;;
    400 | 422) _ok "probe: key accepted by $PROVIDER_BASE_URL (HTTP $code: past authentication, only the empty request was refused, as intended)" ;;
    429) _ok "probe: key accepted by $PROVIDER_BASE_URL (HTTP $code: rate limited, but the key was read and not refused)" ;;
    401 | 403)
      _fail "probe: the key in '$PROVIDER_KEYCHAIN' is rejected by $PROVIDER_BASE_URL (HTTP $code)"
      printf '                   %s\n' "$source"
      ;;
    000) _warn "probe: no answer from $PROVIDER_BASE_URL within $DOC_PROBE_TIMEOUT seconds (offline, or the endpoint is down): the key was not checked" ;;
    *) _warn "probe: $PROVIDER_BASE_URL answered HTTP $code, which says nothing about the key: not checked" ;;
  esac
}

# _doc_provider <provider>: one third-party provider that Claude Code can be pointed at. The
# Z.ai key is the default workers' key, so a missing one is a risk; every other provider is
# optional and a missing key is only a note. Prints names and locations, never a key.
_doc_provider() {
  local p="$1" file leaked=0 mode host pattern name upper
  wolfmux_provider_info "$p" || return 0
  upper="$(printf '%s' "$p" | tr '[:lower:]' '[:upper:]')"
  host="${PROVIDER_BASE_URL#*://}"
  host="${host%%/*}"
  if [ "$p" = "glm" ]; then
    _head "Workers — Claude Code + GLM-5.3 / GLM-5.3 Flash   (expected billing: Z.ai GLM Coding Plan)"
    _doc_launcher claude-glm
    _doc_launcher claude-glm-flash
  else
    if [ "$PROVIDER_BILLING" = "metered" ]; then
      _head "Optional: Claude Code + $PROVIDER_VENDOR   (expected billing: METERED, $PROVIDER_BILLING_NOTE)"
    else
      _head "Optional: Claude Code + $PROVIDER_VENDOR   (expected billing: $PROVIDER_BILLING_NOTE)"
    fi
    # Optional: a launcher that install.sh has not linked yet is a note, as for claude-opus.
    if [ -x "$WOLFMUX_BIN_DIR/claude-$p" ]; then _doc_launcher "claude-$p"; else _note "launcher claude-$p is missing; ./install.sh links it"; fi
  fi
  if wolfmux_provider_key_exists "$p"; then
    if [ "$DOC_PROBE" = 1 ]; then
      _ok "Keychain item '$PROVIDER_KEYCHAIN' exists (value read for the probe below, never printed)"
      _doc_probe_provider "$p"
    else
      _ok "Keychain item '$PROVIDER_KEYCHAIN' exists (value not read)"
    fi
  elif [ "$p" = "glm" ]; then
    _risk "Z.ai credential is missing: no Keychain item '$PROVIDER_KEYCHAIN'. Workers cannot start. Add it:"
    printf '                   security add-generic-password -U -s %s -a "$USER" -l "Z.ai Coding Plan API key" -w\n' "$PROVIDER_KEYCHAIN"
  else
    _note "optional, not set up: no Keychain item '$PROVIDER_KEYCHAIN' (key from $PROVIDER_KEY_URL). To use it, add the key:"
    printf '                   security add-generic-password -U -s %s -a "$USER" -l "%s key" -w\n' "$PROVIDER_KEYCHAIN" "$PROVIDER_LABEL"
  fi
  [ -z "$PROVIDER_KEY_SOURCE" ] || _note "key: $PROVIDER_KEY_SOURCE"
  _ok "endpoint  $PROVIDER_BASE_URL  (set only inside the launcher process)"
  mode="$(wolfmux_provider_setting "$p" AUTH_MODE)"
  case "${mode:-helper}" in
    helper) _ok "key delivery: apiKeyHelper (Keychain read on demand; the key never enters an agent's environment)" ;;
    env)
      _note "key delivery: $PROVIDER_AUTH_VAR (the vendor's documented mode; the key is visible to an agent's subprocesses)"
      if [ "$PROVIDER_AUTH_VAR" = ANTHROPIC_API_KEY ]; then
        _note "Claude Code asks 'Do you want to use this API key?' when a worker starts with $PROVIDER_AUTH_VAR, and an unattended worker waits at that prompt (default No). Helper mode has no such prompt; env mode cannot fix a rejected key: teamctl doctor --probe says whether the key is accepted."
      fi
      ;;
    *) _fail "WOLFMUX_${upper}_AUTH_MODE='$mode' in $(short_path "$WOLFMUX_HOME/config") is invalid (use helper or env)" ;;
  esac
  _ok "login guard on: nothing an agent on $PROVIDER_LABEL spawns can present your claude.ai login to $host"
  if [ "$p" = "glm" ]; then
    _doc_overlay
    _ok "models    glm-5.3 (claude-glm), glm-5.3-flash (claude-glm-flash); every Claude alias is mapped to one of the two"
  else
    _ok "models    $PROVIDER_MAIN_MODEL (claude-$p), background tier $PROVIDER_FAST_MODEL; another one: WOLFMUX_${upper}_MODEL, or teamctl spawn <role> $p:<model-id>"
  fi
  if [ "$PROVIDER_BILLING" = "metered" ]; then
    if wolfmux_metered_on; then
      _note "billing: METERED ($PROVIDER_BILLING_NOTE). WOLFMUX_METERED=on in $(wolfmux_owner_config_label): teamctl starts metered agents, every token they use is billed"
    else
      _ok "billing: METERED ($PROVIDER_BILLING_NOTE); teamctl refuses to start it until $(wolfmux_owner_config_label) says WOLFMUX_METERED=on (the owner's decision; the environment does not count)"
    fi
  else
    _ok "billing: plan ($PROVIDER_BILLING_NOTE)"
  fi
  # Hosts are matched with their dots escaped; a settings file or profile that names one would
  # redirect plain 'claude' (or hand it this provider's model ids), whatever the launcher scrubs.
  pattern="$(printf '%s' "$host" | sed 's/\./\\./g')"
  name="$host"
  if [ "$p" = "glm" ]; then
    pattern="$pattern|bigmodel\\.cn|glm-[0-9]"
    name="Z.ai/GLM"
  fi
  for file in "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.local.json" "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zshenv" "$HOME/.profile"; do
    if [ -f "$file" ] && grep -qiE "$pattern" "$file" 2>/dev/null; then
      leaked=1
      _risk "$(short_path "$file") mentions $name: its settings must live only in the launchers, or plain 'claude' is redirected."
    fi
  done
  if [ "$leaked" -eq 0 ]; then _ok "no $name configuration outside the launchers (plain 'claude' stays on Anthropic)"; fi
  if [ "$p" = "glm" ]; then
    _note "Configured for the Coding Plan endpoint; verify the plan and quota at z.ai, and in a worker with /status."
  else
    _note "Configured for the endpoint above; verify the account, its balance or quota with the vendor, and in an agent with /status."
  fi
}

_doc_providers() {
  local p
  if [ "$DOC_PROBE" = 1 ]; then
    _head "Key probe (teamctl doctor --probe)"
    _note "for each provider whose key is set up below: ONE request goes to that provider's endpoint, over https, and only the HTTP status is shown. It is POST /v1/messages with an empty body (no model, no message): no completion is asked for, so nothing is generated and nothing is billed, not even by a metered provider. The key travels on curl's stdin only."
  fi
  for p in $WOLFMUX_PROVIDERS; do _doc_provider "$p"; done
  if [ "$DOC_PROBE" = 1 ]; then
    _head "Key probe: summary"
    if [ "$DOC_PROBED" -eq 0 ]; then
      _note "probe: nothing was sent (no provider key is set up, or none could be read: see above)"
    else
      _note "probe: $DOC_PROBED request(s) sent; a key is only as good as the endpoint's answer above"
    fi
  fi
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
  _head "tmux team server (socket: $WOLFMUX_TMUX_SOCKET)"
  [ -n "$TMUX_BIN" ] || return 0
  _ok "tmux      $TMUX_BIN  ($("$TMUX_BIN" -V))"
  if [ -r "$WOLFMUX_HOME/tmux.conf" ]; then _ok "config    $(short_path "$WOLFMUX_HOME/tmux.conf") (team server only; ~/.tmux.conf is not touched)"; else _fail "team tmux config missing: $WOLFMUX_HOME/tmux.conf"; fi
  sessions="$(tmx list-sessions -F '#{session_name} (#{session_windows} window, attached: #{session_attached})' 2>/dev/null | tr '\n' ';' || true)"
  if [ -n "$sessions" ]; then _ok "running sessions: $sessions"; else _note "no team session running"; fi
  if [ "$WOLFMUX_TMUX_SOCKET" = "$WOLFMUX_LEGACY_SOCKET" ]; then
    _note "this server was started before the rename to Wolfmux; teamctl follows it until its last session ends, then uses the new socket"
  fi
  if [ -e "$HOME/.ai-team" ] || [ -e "$HOME/.config/ai-team" ]; then
    _note "files from this tool's old name (ai-team) are still in place: run migrate-from-ai-team.sh from the repository to carry state and worktrees over"
  fi
}

_doc_policy() {
  local settings="$CLAUDE_DIR/settings.json" teams
  _head "Team policy (defaults from $(short_path "$WOLFMUX_HOME/config"); per project: teamctl policy)"
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
  local p metered
  DOC_PROBE=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --probe) DOC_PROBE=1 ;;
      *) die_usage "unknown option for doctor: $1 (teamctl doctor [--probe])" ;;
    esac
    shift
  done
  [ -n "$JQ_BIN" ] || die "jq is required for doctor"
  ROOT="$(resolve_root 2>/dev/null || true)"
  CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
  printf '%steamctl doctor%s  (teamctl %s)\n' "$_C_BLD" "$_C_OFF" "$WOLFMUX_VERSION"
  _doc_tools
  _doc_fable
  _doc_astra
  _doc_providers
  _head "Shell profiles"
  _doc_profiles
  _doc_beads
  _doc_team
  _doc_policy
  _head "Account-side settings no local tool can see — check them once"
  _note "claude.ai  > Settings > Usage: keep 'extra usage' OFF, or overage beyond the plan is metered."
  _note "chatgpt.com > Settings > Codex usage: do not buy or auto-refill credits if you want plan-only usage."
  _note "z.ai       > Billing: a zero cash balance makes pay-as-you-go impossible even if a call left the plan."
  metered=""
  for p in $WOLFMUX_PROVIDERS; do
    if wolfmux_provider_info "$p" && [ "$PROVIDER_BILLING" = "metered" ]; then metered="$metered $p"; fi
  done
  if [ -n "$metered" ]; then
    _note "metered providers ($(printf '%s' "$metered" | sed 's/^ //; s/ /, /g')): a prepaid balance is spent per token. Keep WOLFMUX_METERED off unless you mean it, and load only what you can lose."
  fi
  _note "minimax: the key decides the billing; a pay-as-you-go key on the Token Plan URL is metered. Use the plan's Subscription Key."
  printf '\n'
  if [ "$DOC_FAIL" -gt 0 ] || [ "$DOC_WARN" -gt 0 ]; then
    printf '%sresult: %d failure(s), %d warning(s)%s\n' "$_C_BLD" "$DOC_FAIL" "$DOC_WARN" "$_C_OFF"
    [ "$DOC_FAIL" -gt 0 ] && exit 1
    exit 2
  fi
  printf '%sresult: all checks passed%s\n' "$_C_BLD" "$_C_OFF"
}
