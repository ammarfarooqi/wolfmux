#!/bin/bash
# providers.sh — the table of Anthropic-compatible providers a worker can run on.
#
# Sourced by lib/provider-env.sh, so the launchers, teamctl and doctor all read the
# same rows. It holds no credential (only the NAME of a Keychain service) and runs
# nothing when sourced. Compatible with macOS /bin/bash 3.2, which has no associative
# arrays: a row is a case branch that sets PROVIDER_* variables.
#
# A row is facts about a vendor, not a preference. What the owner may change lives in
# ~/.config/wolfmux/config (WOLFMUX_<PROVIDER>_MODEL and friends, see the manual).
#
# Deliberately absent: any setting for the base URL. A setting that can redirect a key
# to another endpoint is the thing ADR-0001 exists to prevent.

WOLFMUX_PROVIDERS="glm kimi moonshot deepseek minimax qwen"

# wolfmux_provider_info <provider> — sets the PROVIDER_* variables of one row.
# Returns 1 for a name that is not in the table, having set nothing of use.
#
#   PROVIDER_NAME        the key in WOLFMUX_PROVIDERS
#   PROVIDER_VENDOR      human name, for the dry run and the status table
#   PROVIDER_LABEL       short label for the status table (14 characters at most)
#   PROVIDER_BASE_URL    the vendor's Anthropic-compatible endpoint
#   PROVIDER_KEYCHAIN    macOS Keychain service name holding the key
#   PROVIDER_KEY_LABEL   the -l label of that Keychain item (cosmetic, shown in Keychain Access)
#   PROVIDER_BILLING     plan (a subscription) | metered (billed per token)
#   PROVIDER_BILLING_NOTE  one line for the dry run and doctor
#   PROVIDER_MAIN_MODEL  model id for the main tier
#   PROVIDER_FAST_MODEL  model id for the haiku/background tier (may equal MAIN)
#   PROVIDER_CONTEXT     context window to declare, in tokens
#   PROVIDER_AUTH_VAR    the variable env auth mode exports the key as
#   PROVIDER_EXTRA_ENV   NAME=value pairs the vendor's own guide asks for ("" if none)
#   PROVIDER_PINNABLE    1 when the owner may pin a model id, 0 when the plan forbids it
#   PROVIDER_KEY_URL     where the owner gets a key ("" when the vendor has no such page)
wolfmux_provider_info() {
  PROVIDER_NAME="$1"
  PROVIDER_EXTRA_ENV=""
  PROVIDER_KEY_URL=""
  case "$1" in
    glm)
      PROVIDER_VENDOR="Z.ai GLM Coding Plan"
      PROVIDER_LABEL="GLM-5.3"
      PROVIDER_BASE_URL="https://api.z.ai/api/anthropic"
      PROVIDER_KEYCHAIN="zai-coding-plan"
      PROVIDER_KEY_LABEL="Z.ai Coding Plan API key"
      PROVIDER_BILLING="plan"
      PROVIDER_BILLING_NOTE="Z.ai GLM Coding Plan subscription"
      PROVIDER_MAIN_MODEL="glm-5.3"
      PROVIDER_FAST_MODEL="glm-5.3-flash"
      PROVIDER_CONTEXT="200000"
      PROVIDER_AUTH_VAR="ANTHROPIC_AUTH_TOKEN"
      # The Coding Plan covers these two model ids; a third could only be billed
      # some other way, so glm is the one provider whose model cannot be pinned.
      PROVIDER_PINNABLE=0
      ;;
    kimi)
      PROVIDER_VENDOR="Moonshot AI (Kimi Code membership)"
      PROVIDER_LABEL="Kimi Code"
      PROVIDER_BASE_URL="https://api.kimi.com/coding/"
      PROVIDER_KEYCHAIN="wolfmux-kimi"
      PROVIDER_KEY_LABEL="Kimi Code API key"
      PROVIDER_BILLING="plan"
      PROVIDER_BILLING_NOTE="Kimi for Coding membership"
      # kimi-k2.7-code rejects a request that carries no thinking block and
      # kimi-for-coding-highspeed is tier gated, so neither is the fast tier here.
      PROVIDER_MAIN_MODEL="kimi-for-coding"
      PROVIDER_FAST_MODEL="kimi-for-coding"
      # Conservative: the membership pages disagree about the window. Raise it with
      # WOLFMUX_KIMI_CONTEXT once you have seen what your own membership serves.
      PROVIDER_CONTEXT="262144"
      PROVIDER_AUTH_VAR="ANTHROPIC_API_KEY"
      PROVIDER_EXTRA_ENV="CLAUDE_CODE_EFFORT_LEVEL=high"
      PROVIDER_PINNABLE=1
      PROVIDER_KEY_URL="https://www.kimi.com/code/docs/en/third-party-tools/claude-code"
      ;;
    moonshot)
      PROVIDER_VENDOR="Moonshot AI (open platform)"
      PROVIDER_LABEL="Kimi K3 API"
      PROVIDER_BASE_URL="https://api.moonshot.ai/anthropic"
      PROVIDER_KEYCHAIN="wolfmux-moonshot"
      PROVIDER_KEY_LABEL="Moonshot API key"
      PROVIDER_BILLING="metered"
      PROVIDER_BILLING_NOTE="Moonshot open platform, prepaid balance"
      PROVIDER_MAIN_MODEL="kimi-k3[1m]"
      PROVIDER_FAST_MODEL="kimi-k3[1m]"
      PROVIDER_CONTEXT="1048576"
      PROVIDER_AUTH_VAR="ANTHROPIC_AUTH_TOKEN"
      PROVIDER_EXTRA_ENV="CLAUDE_CODE_EFFORT_LEVEL=max"
      PROVIDER_PINNABLE=1
      PROVIDER_KEY_URL="https://platform.kimi.ai/docs/guide/claude-code-kimi"
      ;;
    deepseek)
      PROVIDER_VENDOR="DeepSeek"
      PROVIDER_LABEL="DeepSeek V4"
      PROVIDER_BASE_URL="https://api.deepseek.com/anthropic"
      PROVIDER_KEYCHAIN="wolfmux-deepseek"
      PROVIDER_KEY_LABEL="DeepSeek API key"
      PROVIDER_BILLING="metered"
      PROVIDER_BILLING_NOTE="DeepSeek prepaid balance (no subscription exists)"
      PROVIDER_MAIN_MODEL="deepseek-v4-pro[1m]"
      PROVIDER_FAST_MODEL="deepseek-v4-flash"
      PROVIDER_CONTEXT="786432"
      PROVIDER_AUTH_VAR="ANTHROPIC_AUTH_TOKEN"
      PROVIDER_EXTRA_ENV="CLAUDE_CODE_EFFORT_LEVEL=max"
      PROVIDER_PINNABLE=1
      PROVIDER_KEY_URL="https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code/"
      ;;
    minimax)
      PROVIDER_VENDOR="MiniMax (Token Plan)"
      PROVIDER_LABEL="MiniMax M3"
      PROVIDER_BASE_URL="https://api.minimax.io/anthropic"
      PROVIDER_KEYCHAIN="wolfmux-minimax"
      PROVIDER_KEY_LABEL="MiniMax API key"
      # The key decides, not the URL: a Subscription Key is the Token Plan, a
      # pay-as-you-go key on this same endpoint is metered. Stored as a plan because
      # that is what the owner is told to put in the Keychain.
      PROVIDER_BILLING="plan"
      PROVIDER_BILLING_NOTE="MiniMax Token Plan subscription (a pay-as-you-go key on the same endpoint is metered)"
      PROVIDER_MAIN_MODEL="MiniMax-M3[1m]"
      PROVIDER_FAST_MODEL="MiniMax-M3[1m]"
      PROVIDER_CONTEXT="1000000"
      PROVIDER_AUTH_VAR="ANTHROPIC_AUTH_TOKEN"
      PROVIDER_PINNABLE=1
      PROVIDER_KEY_URL="https://platform.minimax.io/docs/coding-plan/claude-code"
      ;;
    qwen)
      PROVIDER_VENDOR="Alibaba Model Studio (Coding Plan, international)"
      PROVIDER_LABEL="Qwen 3.7 Plus"
      PROVIDER_BASE_URL="https://coding-intl.dashscope.aliyuncs.com/apps/anthropic"
      PROVIDER_KEYCHAIN="wolfmux-qwen"
      PROVIDER_KEY_LABEL="Alibaba Model Studio API key"
      # A Coding Plan key starts with sk-sp-; any other Model Studio key gets a 403
      # here, which is the vendor saying "that key is billed the other way".
      PROVIDER_BILLING="plan"
      PROVIDER_BILLING_NOTE="Model Studio Coding Plan subscription (sk-sp- key)"
      PROVIDER_MAIN_MODEL="qwen3.7-plus"
      PROVIDER_FAST_MODEL="qwen3.7-plus"
      # Conservative: the Coding Plan pages do not state the window.
      PROVIDER_CONTEXT="262144"
      PROVIDER_AUTH_VAR="ANTHROPIC_AUTH_TOKEN"
      PROVIDER_PINNABLE=1
      PROVIDER_KEY_URL="https://www.alibabacloud.com/help/en/model-studio/claude-code"
      ;;
    *)
      return 1
      ;;
  esac
}

# wolfmux_provider_of_launcher <basename> — prints "<provider> <variant>", variant
# main or fast. One launcher file serves every provider; the name it is called by
# decides which row applies (the claude-fable precedent, ADR-0017).
wolfmux_provider_of_launcher() {
  local self="$1" provider
  if [ "$self" = "claude-glm-flash" ]; then
    printf '%s\n' "glm fast"
    return 0
  fi
  for provider in $WOLFMUX_PROVIDERS; do
    if [ "$self" = "claude-$provider" ]; then
      printf '%s\n' "$provider main"
      return 0
    fi
  done
  return 1
}

# The launcher names that exist, for a "you called me by a name I do not know" message.
wolfmux_provider_launcher_names() {
  local provider out=""
  for provider in $WOLFMUX_PROVIDERS; do
    out="$out claude-$provider"
    [ "$provider" = glm ] && out="$out claude-glm-flash"
  done
  printf '%s\n' "${out# }"
}

# wolfmux_provider_setting <provider> <MODEL|FAST_MODEL|AUTH_MODE|CONTEXT> — the value
# of WOLFMUX_<PROVIDER>_<SUFFIX>, or empty. Indirect expansion, so one function covers
# every provider without a case branch per setting.
wolfmux_provider_setting() {
  local name
  name="WOLFMUX_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')_$2"
  printf '%s\n' "${!name:-}"
}

# True when this provider's key is in the login Keychain. Reads no secret: `security`
# is asked whether the item exists, not for its value.
wolfmux_provider_key_exists() {
  wolfmux_provider_info "$1" || return 1
  /usr/bin/security find-generic-password -s "$PROVIDER_KEYCHAIN" >/dev/null 2>&1
}

# wolfmux_owner_config — the ONE file that may open the metered gate: the owner's
# ~/.config/wolfmux/config, located through the password database.
#
# Not through $HOME and not through $WOLFMUX_HOME. Both are environment values, so an
# agent that can set either could point billing consent at a file it wrote itself: it
# would not need the owner's config, or write access to it, to spend the owner's money.
# The login name of the effective user is the only input, and it is checked against a
# safe character set before the expansion that turns it into a home directory (bash 3.2
# has no other way to expand ~name).
#
# What this is NOT: a sandbox. An agent that can run arbitrary code as this user can do
# anything this user can do, including editing the owner's config. The gate stops the
# ordinary path (a variable, a redirected config directory), not same-user code.
wolfmux_owner_config() {
  local name home
  name="$(/usr/bin/id -un 2>/dev/null)" || return 1
  case "$name" in
    "" | *[!A-Za-z0-9._-]*) return 1 ;; # nothing that could carry shell syntax
    -*) return 1 ;;                     # ~- and ~-N are the directory stack, not a user
    *[!0-9]*) ;;                        # a non-digit somewhere: a login name
    *) return 1 ;;                      # all digits: ~N is the directory stack too
  esac
  eval "home=~$name" 2>/dev/null || return 1
  case "$home" in
    /*) ;;
    *) return 1 ;; # no such user: bash left the tilde unexpanded
  esac
  printf '%s\n' "$home/.config/wolfmux/config"
}

# wolfmux_owner_config_label — the same file, for a sentence addressed to a human: shortened
# when short_path is loaded, and the literal ~/.config/wolfmux/config when the lookup failed.
# It decides nothing; a message that names $WOLFMUX_HOME instead would send the owner to edit
# a file the gate does not read.
wolfmux_owner_config_label() {
  local file
  file="$(wolfmux_owner_config)" || {
    printf '~/.config/wolfmux/config\n'
    return 0
  }
  if command -v short_path >/dev/null 2>&1; then
    short_path "$file"
  else
    printf '%s\n' "$file"
  fi
}

# _wolfmux_metered_in_file <file> — the parser, and nothing else: true when this file
# has an active WOLFMUX_METERED=on line. Same rules as wolfmux_load_config (the file is
# parsed, never sourced; comments and blank lines skipped, whitespace trimmed, the last
# line wins). Which file is policy, and policy lives in wolfmux_metered_on.
_wolfmux_metered_in_file() {
  local file="$1" line key value answer=""
  [ -n "$file" ] && [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "" | \#*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    key="${key//[[:space:]]/}"
    [ "$key" = WOLFMUX_METERED ] || continue
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    answer="$value"
  done <"$file"
  [ "$answer" = "on" ]
}

# wolfmux_metered_on — true only when the OWNER said so, in the owner's own file. No
# argument, no override, no test seam: a way to ask this question about another file
# would be the hole it exists to close. It fails closed (an unreadable or missing file
# is a no).
wolfmux_metered_on() {
  _wolfmux_metered_in_file "$(wolfmux_owner_config)"
}

wolfmux_provider_key_help() {
  wolfmux_provider_info "$1" || return 1
  cat <<EOF
Add your $PROVIDER_KEY_LABEL to the macOS Keychain (you will be prompted for
the key; it is never echoed, never written to shell history):

  security add-generic-password -U -s ${PROVIDER_KEYCHAIN} -a "\$USER" -l "$PROVIDER_KEY_LABEL" -w

EOF
  [ -z "$PROVIDER_KEY_URL" ] || printf 'Where to get one: %s\n\n' "$PROVIDER_KEY_URL"
}
