#!/bin/bash
# providers.sh — the provider table and the one third-party launcher, rehearsed in a
# throwaway HOME. No network, no tmux, no real Claude Code binary, no key: the launcher
# is run with WOLFMUX_DRY_RUN=1 (which stops before any Keychain read) or for the paths
# that must refuse, with the Keychain item deliberately absent.
#
# The launcher is one file called through symlinks named claude-<provider>, so the
# symlinks are made here, in the temp directory, not in ~/bin.
#
#   tests/providers.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-providers.XXXXXX")"
PROBE_MOCK_PID=""
trap '[ -z "$PROBE_MOCK_PID" ] || kill "$PROBE_MOCK_PID" 2>/dev/null; /bin/rm -rf "$WORK"' EXIT
export HOME="$WORK/home" # no login keychain here, so every provider's key is missing
/bin/mkdir -p "$HOME"
export WOLFMUX_HOME="$REPO/config/wolfmux"
export WOLFMUX_CLAUDE_BIN="/usr/bin/true" # what "would exec" names; never started
unset WOLFMUX_EXTRA_SETTINGS WOLFMUX_DRY_RUN WOLFMUX_METERED CLAUDE_CONFIG_DIR

# shellcheck source=/dev/null
. "$REPO/config/wolfmux/lib/provider-env.sh" # sources lib/providers.sh: the table

passed=0
failed=0
skipped=0
skip() { # <description> <why>
  skipped=$((skipped + 1))
  printf '  SKIP  %s\n        (%s)\n' "$1" "$2"
}
check() { # <description> <command string>
  # Subshell: a check below may `exit 1` from inside a loop to fail itself, and that
  # must not end the run (tests/permissions.sh has no such check, hence no subshell).
  if (eval "$2") >/dev/null 2>&1; then
    passed=$((passed + 1))
    printf '  pass  %s\n' "$1"
  else
    failed=$((failed + 1))
    printf '  FAIL  %s\n' "$1"
  fi
}

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

TABLE="$REPO/config/wolfmux/lib/providers.sh"
sourced_silent() { [ -z "$(bash -c '. "$1"' _ "$TABLE" 2>&1)" ]; }
sourced_sets_no_row() { # a row is a case branch: sourcing must not evaluate one
  [ -z "$(bash -c '. "$1"; printf "%s" "${PROVIDER_NAME:-}${PROVIDER_BASE_URL:-}${PROVIDER_KEYCHAIN:-}"' _ "$TABLE")" ]
}

printf '%s\n' '#!/bin/bash' 'env' >"$WORK/show-env" # stands in for the claude binary
chmod +x "$WORK/show-env"
printf '%s\n' '{"env":{"WOLFMUX_TEST_AGENT_SETTINGS":"1"}}' >"$WORK/agent.json" # stands in for what teamctl writes per pane

# A config directory that says the meter is open, exactly as an agent could write one in
# its own worktree: lib symlinked to this checkout, a config file saying on. The gate
# must ignore it, because the file it reads is found through the account and not through
# $WOLFMUX_HOME. The throwaway $HOME gets the same file, for the same reason.
FAKE_HOME="$WORK/wolfmux-meter-open"
/bin/mkdir -p "$FAKE_HOME" "$WORK/last-wins" "$HOME/.config/wolfmux"
/bin/ln -s "$REPO/config/wolfmux/lib" "$FAKE_HOME/lib"
printf '%s\n' "# a comment first" "  " "WOLFMUX_METERED = on  " >"$FAKE_HOME/config"
printf '%s\n' "WOLFMUX_METERED=on" >"$HOME/.config/wolfmux/config"

# The owner's own file is never written by this test, only read: if it really says on,
# the end-to-end checks below cannot hold and are skipped rather than quietly passed.
OWNER_CONFIG="$(wolfmux_owner_config || true)"
OWNER_METERED=0
if wolfmux_metered_on; then OWNER_METERED=1; fi
GATE_SKIP="the owner's own config ($OWNER_CONFIG) says WOLFMUX_METERED=on, so a closed gate cannot be observed"

BIN="$WORK/bin"
/bin/mkdir -p "$BIN"
for p in $WOLFMUX_PROVIDERS; do /bin/ln -s "$REPO/bin/claude-glm" "$BIN/claude-$p"; done
/bin/ln -s "$REPO/bin/claude-glm" "$BIN/claude-glm-flash"
/bin/ln -s "$REPO/bin/claude-glm" "$BIN/claude-nosuchprovider"

# Every per-provider setting is removed first, so a value in the environment of
# whoever runs this test cannot change what a check sees.
CLEAN=(-u WOLFMUX_METERED -u WOLFMUX_EXTRA_SETTINGS)
for p in $WOLFMUX_PROVIDERS; do
  for suffix in MODEL FAST_MODEL AUTH_MODE CONTEXT; do
    CLEAN+=(-u "WOLFMUX_$(upper "$p")_$suffix")
  done
done

dry() { # <launcher> [VAR=value ...] : dry run, stdout and stderr together
  local launcher="$1"
  shift
  env "${CLEAN[@]}" WOLFMUX_DRY_RUN=1 "$@" "$BIN/$launcher" 2>&1
}
live() { # <launcher> [VAR=value ...] : a real launch attempt (it must refuse)
  local launcher="$1"
  shift
  env "${CLEAN[@]}" -u WOLFMUX_DRY_RUN "$@" "$BIN/$launcher" 2>&1
}
dry_redirected() { # like dry, but pointed at the config directory that says "open"
  local launcher="$1"
  shift
  env "${CLEAN[@]}" WOLFMUX_DRY_RUN=1 WOLFMUX_HOME="$FAKE_HOME" "$@" "$BIN/$launcher" 2>&1
}
live_redirected() { # the same, for a real launch attempt
  local launcher="$1"
  shift
  env "${CLEAN[@]}" -u WOLFMUX_DRY_RUN WOLFMUX_HOME="$FAKE_HOME" "$@" "$BIN/$launcher" 2>&1
}
dry_args() { # <launcher> <arg>... : a dry run with command-line arguments
  local launcher="$1"
  shift
  env "${CLEAN[@]}" WOLFMUX_DRY_RUN=1 "$BIN/$launcher" "$@" 2>&1
}
field() { # <dry-run output> <label> : the value after "<label>:"
  printf '%s\n' "$1" | /usr/bin/sed -n "s/^$2: *//p" | /usr/bin/head -1
}
labels() { # the labels of a dry run, in order, comma separated
  printf '%s\n' "$1" | /usr/bin/sed -n 's/^\([a-z][a-z ]*\):.*/\1/p' | tr '\n' ','
}

echo "== the table (lib/providers.sh)"
check "providers.sh runs nothing when sourced: silent, and no row is evaluated" \
  'sourced_silent && sourced_sets_no_row'
check "providers.sh holds no credential: only the NAME of a Keychain service" \
  '! LC_ALL=C /usr/bin/grep -nE "(sk-[A-Za-z0-9]{12,}|Bearer [A-Za-z0-9]{12,}|api[_-]?key *= *[A-Za-z0-9])" "$TABLE" &&
   ! LC_ALL=C /usr/bin/grep -n "find-generic-password.* -w" "$TABLE"'
check "every provider in WOLFMUX_PROVIDERS has a row; an unknown name returns 1" \
  'for p in $WOLFMUX_PROVIDERS; do wolfmux_provider_info "$p" || exit 1; done; ! wolfmux_provider_info nosuchprovider'
check "every row sets every field, billing is plan or metered, label is 14 characters at most" \
  'for p in $WOLFMUX_PROVIDERS; do
     wolfmux_provider_info "$p" || exit 1
     [ "$PROVIDER_NAME" = "$p" ] || exit 1
     for f in PROVIDER_VENDOR PROVIDER_LABEL PROVIDER_BASE_URL PROVIDER_KEYCHAIN PROVIDER_BILLING \
       PROVIDER_BILLING_NOTE PROVIDER_MAIN_MODEL PROVIDER_FAST_MODEL PROVIDER_CONTEXT \
       PROVIDER_AUTH_VAR PROVIDER_PINNABLE; do
       [ -n "${!f}" ] || exit 1
     done
     [ -n "${PROVIDER_EXTRA_ENV+x}" ] && [ -n "${PROVIDER_KEY_URL+x}" ] || exit 1
     [ -n "${PROVIDER_KEY_PREFIX+x}" ] && [ -n "${PROVIDER_KEY_SOURCE+x}" ] || exit 1
     case "$PROVIDER_BILLING" in plan | metered) ;; *) exit 1 ;; esac
     case "$PROVIDER_AUTH_VAR" in ANTHROPIC_AUTH_TOKEN | ANTHROPIC_API_KEY) ;; *) exit 1 ;; esac
     case "$PROVIDER_CONTEXT" in "" | *[!0-9]*) exit 1 ;; esac
     [ "${#PROVIDER_LABEL}" -le 14 ] || exit 1
     case "$PROVIDER_BASE_URL" in https://*) ;; *) exit 1 ;; esac
   done'
check "only glm is unpinnable, and only glm keeps the old Keychain service name" \
  'for p in $WOLFMUX_PROVIDERS; do
     wolfmux_provider_info "$p"
     if [ "$p" = glm ]; then
       [ "$PROVIDER_PINNABLE" = 0 ] && [ "$PROVIDER_KEYCHAIN" = zai-coding-plan ] || exit 1
     else
       [ "$PROVIDER_PINNABLE" = 1 ] && [ "$PROVIDER_KEYCHAIN" = "wolfmux-$p" ] || exit 1
     fi
   done'
check "wolfmux_provider_of_launcher maps the names, and only those" \
  '[ "$(wolfmux_provider_of_launcher claude-glm)" = "glm main" ] &&
   [ "$(wolfmux_provider_of_launcher claude-glm-flash)" = "glm fast" ] &&
   [ "$(wolfmux_provider_of_launcher claude-kimi)" = "kimi main" ] &&
   [ "$(wolfmux_provider_of_launcher claude-qwen)" = "qwen main" ] &&
   ! wolfmux_provider_of_launcher claude-kimi-flash &&
   ! wolfmux_provider_of_launcher claude-fable &&
   ! wolfmux_provider_of_launcher claude'
check "wolfmux_provider_setting reads WOLFMUX_<PROVIDER>_<SUFFIX>, empty when unset" \
  '[ "$(WOLFMUX_KIMI_MODEL=pinned-id wolfmux_provider_setting kimi MODEL)" = "pinned-id" ] &&
   [ -z "$(env -u WOLFMUX_QWEN_CONTEXT bash -c ". \"$REPO/config/wolfmux/lib/provider-env.sh\"; wolfmux_provider_setting qwen CONTEXT")" ]'
check "the glm names provider-env.sh still exports match the glm row (no drift)" \
  'wolfmux_provider_info glm &&
   [ "$WOLFMUX_ZAI_BASE_URL" = "$PROVIDER_BASE_URL" ] &&
   [ "$WOLFMUX_ZAI_KEYCHAIN_SERVICE" = "$PROVIDER_KEYCHAIN" ]'
check "wolfmux_zai_key_exists and _key_help are still there, as glm wrappers" \
  'type wolfmux_zai_key_exists >/dev/null && type wolfmux_zai_key_help >/dev/null &&
   wolfmux_zai_key_help | /usr/bin/grep -q "add-generic-password -U -s zai-coding-plan" &&
   ! wolfmux_zai_key_exists' # throwaway HOME
check "every provider's key help names that provider's Keychain service" \
  'for p in $WOLFMUX_PROVIDERS; do
     wolfmux_provider_info "$p"
     wolfmux_provider_key_help "$p" | /usr/bin/grep -q -- "-s $PROVIDER_KEYCHAIN" || exit 1
     wolfmux_provider_key_exists "$p" && exit 1 # no keychain in a throwaway HOME
   done; true'
check "WOLFMUX_CONFIG_KEYS gained a setting per provider, plus WOLFMUX_METERED" \
  'for key in $(for p in $WOLFMUX_PROVIDERS; do
       u="$(upper "$p")"
       echo "WOLFMUX_${u}_AUTH_MODE WOLFMUX_${u}_CONTEXT"
       wolfmux_provider_info "$p"
       [ "$PROVIDER_PINNABLE" = 1 ] && echo "WOLFMUX_${u}_MODEL WOLFMUX_${u}_FAST_MODEL"
     done) WOLFMUX_METERED; do
     case " $WOLFMUX_CONFIG_KEYS " in *" $key "*) ;; *) exit 1 ;; esac
   done'
check "_wolfmux_metered_in_file: on, with comments and whitespace around it" \
  'F="$WORK/last-wins/config"
   printf "%s\n" "# off" "  " "WOLFMUX_METERED = on  " >"$F" && _wolfmux_metered_in_file "$F"'
check "_wolfmux_metered_in_file: off, a commented line, an unrelated key, the last line winning" \
  'F="$WORK/last-wins/config"
   printf "%s\n" "WOLFMUX_METERED=off" >"$F" && ! _wolfmux_metered_in_file "$F" &&
   printf "%s\n" "#WOLFMUX_METERED=on" >"$F" && ! _wolfmux_metered_in_file "$F" &&
   printf "%s\n" "WOLFMUX_METERED_X=on" >"$F" && ! _wolfmux_metered_in_file "$F" &&
   printf "%s\n" "WOLFMUX_METERED=on" "WOLFMUX_METERED=off" >"$F" && ! _wolfmux_metered_in_file "$F" &&
   printf "%s" "WOLFMUX_METERED=on" >"$F" && _wolfmux_metered_in_file "$F"' # no closing newline
check "_wolfmux_metered_in_file fails closed on a missing, empty or unnamed file" \
  '! _wolfmux_metered_in_file "$WORK/no-such-file" &&
   ! _wolfmux_metered_in_file "" &&
   : >"$WORK/last-wins/config" && ! _wolfmux_metered_in_file "$WORK/last-wins/config"'
# _fake_id <name> <command...> — run <command> with the account name the gate reads answering
# <name>, as review round 2 did: bash expands ~0, ~-0 and ~- from the directory stack and not
# from the password database, so a name like that must be refused before the expansion.
eval '/usr/bin/id() {
  if [ -n "${WM_FAKE_ID_NAME+set}" ]; then printf "%s\n" "$WM_FAKE_ID_NAME"; else command /usr/bin/id "$@"; fi
}'
_fake_id() { ( WM_FAKE_ID_NAME="$1"; shift; "$@" ); }

check "wolfmux_owner_config names the owner's own file, absolute, never \$HOME or \$WOLFMUX_HOME" \
  'C="$(wolfmux_owner_config)" && case "$C" in /*/.config/wolfmux/config) ;; *) exit 1 ;; esac
   case "$C" in "$HOME"/*) exit 1 ;; esac # $HOME is the throwaway one here
   [ "$C" = "$(HOME=/nowhere WOLFMUX_HOME=/nowhere-else wolfmux_owner_config)" ]'
check "wolfmux_owner_config refuses the directory-stack tilde forms: ~0, ~-0, ~- are not accounts" \
  '/bin/mkdir -p "$FAKE_HOME/.config/wolfmux" &&
   printf "%s\n" "WOLFMUX_METERED=on" >"$FAKE_HOME/.config/wolfmux/config" || exit 1
   for n in 0 00 1 - -0 -1 +1 ""; do
     ( cd "$FAKE_HOME" && ! _fake_id "$n" wolfmux_owner_config && ! _fake_id "$n" wolfmux_metered_on ) || exit 1
   done
   [ "$(wolfmux_owner_config)" = "$(cd / && wolfmux_owner_config)" ]'

check "the metered refusal names the file the gate reads, never \$WOLFMUX_HOME/config" \
  'L="$(WOLFMUX_HOME="$FAKE_HOME" wolfmux_owner_config_label)" &&
   [ "$L" = "$(wolfmux_owner_config_label)" ] &&
   case "$L" in *"$FAKE_HOME"*) exit 1 ;; *.config/wolfmux/config) ;; *) exit 1 ;; esac
   ! LC_ALL=C /usr/bin/grep -q "WOLFMUX_METERED=on in \$(short_path" "$REPO/config/wolfmux/lib/common.sh" &&
   [ "$(LC_ALL=C /usr/bin/grep -c "wolfmux_owner_config_label" "$REPO/config/wolfmux/lib/doctor.sh")" -eq 2 ]'

check "wolfmux_metered_on takes no argument and no override: redirection cannot answer for it" \
  '[ "$OWNER_METERED" = 1 ] ||
   { ! WOLFMUX_HOME="$FAKE_HOME" wolfmux_metered_on &&
     ! HOME="$HOME" wolfmux_metered_on &&
     ! WOLFMUX_METERED=on wolfmux_metered_on &&
     ! wolfmux_metered_on "$FAKE_HOME/config"; }'
check "the launcher asks wolfmux_metered_on, and parses no config file of its own" \
  '[ "$(LC_ALL=C /usr/bin/grep -c "wolfmux_metered_on" "$REPO/bin/claude-glm")" -ge 1 ] &&
   ! LC_ALL=C /usr/bin/grep -q "WOLFMUX_METERED:-" "$REPO/bin/claude-glm"'
check "CLAUDE_CODE_EFFORT_LEVEL is the subscription's own: scrubbed for a third party, kept for claude-fable" \
  'case "$WOLFMUX_CLAUDE_THIRD_PARTY_VARS" in *CLAUDE_CODE_EFFORT_LEVEL*) ;; *) exit 1 ;; esac
   case "$WOLFMUX_CLAUDE_PROVIDER_VARS" in *CLAUDE_CODE_EFFORT_LEVEL*) exit 1 ;; esac
   F="$(env "${CLEAN[@]}" WOLFMUX_DRY_RUN=1 CLAUDE_CODE_EFFORT_LEVEL=owners-effort "$REPO/bin/claude-fable" 2>&1)"
   case "$F" in *CLAUDE_CODE_EFFORT_LEVEL*) exit 1 ;; esac
   case "$F" in *"scrubbed vars:"*) ;; *) exit 1 ;; esac
   K="$(dry claude-kimi CLAUDE_CODE_EFFORT_LEVEL=owners-effort)"
   case "$K" in *"scrubbed vars:"*CLAUDE_CODE_EFFORT_LEVEL*) ;; *) exit 1 ;; esac'

echo
echo "== the launcher, for every provider in the table"
for p in $WOLFMUX_PROVIDERS; do
  wolfmux_provider_info "$p"
  U="$(upper "$p")"
  OUT="$(dry "claude-$p")"
  check "$p: provider and endpoint lines come from the table" \
    '[ "$(field "$OUT" provider)" = "'"$p"' ('"$PROVIDER_VENDOR"')" ] &&
     [ "$(field "$OUT" endpoint)" = "'"$PROVIDER_BASE_URL"'" ]'
  check "$p: model line names the main model and the haiku/background tier" \
    '[ "$(field "$OUT" model)" = "'"$PROVIDER_MAIN_MODEL"'   (haiku/background tier: '"$PROVIDER_FAST_MODEL"')" ]'
  check "$p: context line declares the table's window" \
    'case "$(field "$OUT" "context window")" in "'"$PROVIDER_CONTEXT"' tokens"*) ;; *) exit 1 ;; esac'
  if [ "$PROVIDER_BILLING" = metered ]; then
    check "$p: billing line says METERED" \
      '[ "$(field "$OUT" billing)" = "METERED: '"$PROVIDER_BILLING_NOTE"'" ]'
    if [ "$OWNER_METERED" = 1 ]; then
      skip "$p: the gate is closed, and a real launch is refused (exit 78)" "$GATE_SKIP"
      skip "$p: neither the environment nor a redirected config directory opens the gate" "$GATE_SKIP"
    else
      check "$p: the gate is closed, and a real launch is refused (exit 78, naming the owner's file)" \
        '[ "$(field "$OUT" "metered gate")" = "closed" ]
         R="$(live "claude-'"$p"'")"
         { live "claude-'"$p"'" >/dev/null 2>&1; [ $? -eq 78 ]; } &&
         case "$R" in *"WOLFMUX_METERED=on"*) ;; *) exit 1 ;; esac
         case "$R" in *"$OWNER_CONFIG"*) ;; *) exit 1 ;; esac
         true'
      check "$p: neither the environment nor a redirected config directory opens the gate" \
        '[ "$(field "$(dry "claude-'"$p"'" WOLFMUX_METERED=on)" "metered gate")" = "closed" ] &&
         [ "$(field "$(dry_redirected "claude-'"$p"'")" "metered gate")" = "closed" ] &&
         [ "$(field "$(dry_redirected "claude-'"$p"'" WOLFMUX_METERED=on)" "metered gate")" = "closed" ] &&
         { live "claude-'"$p"'" WOLFMUX_METERED=on >/dev/null 2>&1; [ $? -eq 78 ]; } &&
         { live_redirected "claude-'"$p"'" >/dev/null 2>&1; [ $? -eq 78 ]; } &&
         live_redirected "claude-'"$p"'" | /usr/bin/grep -q "meter is closed"' # $HOME says on too: see the setup
    fi
  else
    check "$p: billing line says plan, and a plan provider is never gated either way" \
      '[ "$(field "$OUT" billing)" = "plan: '"$PROVIDER_BILLING_NOTE"'" ] &&
       [ -z "$(field "$OUT" "metered gate")" ] &&
       [ -z "$(field "$(dry_redirected "claude-'"$p"'")" "metered gate")" ] &&
       ! live "claude-'"$p"'" | /usr/bin/grep -q WOLFMUX_METERED'
    check "$p: without a Keychain item a real launch exits 78 and prints that provider's help" \
      'OUT2="$(live "claude-'"$p"'")"
       { live "claude-'"$p"'" >/dev/null 2>&1; [ $? -eq 78 ]; } &&
       case "$OUT2" in *"no Keychain item for service '"'$PROVIDER_KEYCHAIN'"'"*) ;; *) exit 1 ;; esac
       case "$OUT2" in *"add-generic-password -U -s '"$PROVIDER_KEYCHAIN"'"*) ;; *) exit 1 ;; esac'
  fi
  check "$p: auth mode defaults to helper and names this provider's Keychain service" \
    'case "$(field "$OUT" "auth mode")" in
       "helper   (key source: macOS Keychain service '"'$PROVIDER_KEYCHAIN'"')") ;;
       *) exit 1 ;;
     esac'
  check "$p: AUTH_MODE helper and env are accepted, anything else exits 64" \
    'dry "claude-'"$p"'" WOLFMUX_'"$U"'_AUTH_MODE=helper >/dev/null 2>&1 &&
     dry "claude-'"$p"'" WOLFMUX_'"$U"'_AUTH_MODE=env >/dev/null 2>&1 &&
     { dry "claude-'"$p"'" WOLFMUX_'"$U"'_AUTH_MODE=nonsense >/dev/null 2>&1; [ $? -eq 64 ]; } &&
     dry "claude-'"$p"'" WOLFMUX_'"$U"'_AUTH_MODE=nonsense | /usr/bin/grep -q "WOLFMUX_'"$U"'_AUTH_MODE must be"'
  check "$p: an inherited endpoint, model or window is scrubbed, then set from the table" \
    'BAD="$(dry "claude-'"$p"'" ANTHROPIC_BASE_URL=https://evil.invalid ANTHROPIC_MODEL=inherited-model \
       CLAUDE_CODE_MAX_CONTEXT_TOKENS=5 CLAUDE_CODE_USE_BEDROCK=1 ANTHROPIC_API_KEY=inherited-key)"
     [ "$(field "$BAD" endpoint)" = "'"$PROVIDER_BASE_URL"'" ] &&
     case "$(field "$BAD" "context window")" in "'"$PROVIDER_CONTEXT"' tokens"*) ;; *) exit 1 ;; esac
     case "$BAD" in *inherited-model* | *inherited-key* | *evil.invalid*) exit 1 ;; esac
     S="$(field "$BAD" "scrubbed vars")"
     case "$S" in *ANTHROPIC_BASE_URL*) ;; *) exit 1 ;; esac
     case "$S" in *CLAUDE_CODE_USE_BEDROCK*) ;; *) exit 1 ;; esac
     case "$S" in *CLAUDE_CODE_MAX_CONTEXT_TOKENS*) ;; *) exit 1 ;; esac'
  check "$p: the login guard is on" '[ -n "$(field "$OUT" "login guard")" ]'
  check "$p: the dry run reads no key, and would exec carries the Keychain command, never a key" \
    'case "$OUT" in *"keychain item:   MISSING"*) ;; *) exit 1 ;; esac
     E="$(field "$OUT" "would exec")"
     case "$E" in *"find-generic-password"*"'"$PROVIDER_KEYCHAIN"'"*) ;; *) exit 1 ;; esac
     case "$E" in *ANTHROPIC_AUTH_TOKEN* | *ANTHROPIC_API_KEY*) exit 1 ;; esac
     ENV_OUT="$(dry "claude-'"$p"'" WOLFMUX_'"$U"'_AUTH_MODE=env)"
     case "$(field "$ENV_OUT" "would exec")" in *apiKeyHelper* | *find-generic-password*) exit 1 ;; esac
     true'
  if [ -n "$PROVIDER_EXTRA_ENV" ]; then
    check "$p: the vendor's extra environment is exported and reported" \
      '[ "$(field "$OUT" "extra env")" = "'"$PROVIDER_EXTRA_ENV"'" ]'
  else
    check "$p: no extra environment is invented for a provider that asks for none" \
      '[ -z "$(field "$OUT" "extra env")" ]'
  fi
  if [ "$PROVIDER_PINNABLE" = 1 ]; then
    check "$p: a model pin from the environment wins" \
      'P="$(dry "claude-'"$p"'" WOLFMUX_'"$U"'_MODEL=pinned-main WOLFMUX_'"$U"'_FAST_MODEL=pinned-fast)"
       [ "$(field "$P" model)" = "pinned-main   (haiku/background tier: pinned-fast)" ] &&
       case "$(field "$P" "would exec")" in *"--model pinned-main"*) ;; *) exit 1 ;; esac'
  else
    check "$p: a model pin from the environment is ignored (the plan covers two ids)" \
      'P="$(dry "claude-'"$p"'" WOLFMUX_'"$U"'_MODEL=pinned-main WOLFMUX_'"$U"'_FAST_MODEL=pinned-fast)"
       [ "$(field "$P" model)" = "'"$PROVIDER_MAIN_MODEL"'   (haiku/background tier: '"$PROVIDER_FAST_MODEL"')" ]'
  fi
  check "$p: a window of the owner's is declared instead of the table's, and says so" \
    'W="$(field "$(dry "claude-'"$p"'" WOLFMUX_'"$U"'_CONTEXT=123456)" "context window")"
     case "$W" in "123456 tokens ("*"WOLFMUX_'"$U"'_CONTEXT"*) ;; *) exit 1 ;; esac'
done

echo
echo "== the launcher, cases that are not per provider"
check "the login guard token is exported for every provider: one unconditional line, no provider branch" \
  '[ "$(LC_ALL=C /usr/bin/grep -c "^export CLAUDE_CODE_OAUTH_TOKEN=\"\$WOLFMUX_GLM_GUARD_TOKEN\"$" "$REPO/bin/claude-glm")" = 1 ]'
check "an unknown launcher name exits 64 and says which names exist" \
  '{ dry claude-nosuchprovider >/dev/null 2>&1; [ $? -eq 64 ]; } &&
   dry claude-nosuchprovider | /usr/bin/grep -q "claude-kimi"'
check "claude-glm-flash runs the fast model as the primary one" \
  'wolfmux_provider_info glm
   [ "$(field "$(dry claude-glm-flash)" model)" = "$PROVIDER_FAST_MODEL   (haiku/background tier: $PROVIDER_FAST_MODEL)" ] &&
   [ "$(field "$(dry claude-glm-flash)" launcher)" = "claude-glm-flash" ]'
check "WOLFMUX_GLM_CONTEXT=1m keeps its meaning: the [1m] suffix, on both tiers" \
  '[ "$(field "$(dry claude-glm WOLFMUX_GLM_CONTEXT=1m)" "context window")" = "1M ([1m] suffix)" ] &&
   [ "$(field "$(dry claude-glm WOLFMUX_GLM_CONTEXT=1m)" model)" = "glm-5.3[1m]   (haiku/background tier: glm-5.3-flash[1m])" ] &&
   [ "$(field "$(dry claude-glm-flash WOLFMUX_GLM_CONTEXT=1m)" model)" = "glm-5.3-flash[1m]   (haiku/background tier: glm-5.3-flash[1m])" ]'
check "WOLFMUX_GLM_CONTEXT nonsense warns and falls back to 200000; 1m is glm's alone" \
  'dry claude-glm WOLFMUX_GLM_CONTEXT=huge | /usr/bin/grep -q "must be .1m. or a number" &&
   [ "$(field "$(dry claude-glm WOLFMUX_GLM_CONTEXT=huge)" "context window")" = "200000 tokens (declared; WOLFMUX_GLM_CONTEXT=1m for the 1M window)" ] &&
   dry claude-kimi WOLFMUX_KIMI_CONTEXT=1m | /usr/bin/grep -q "must be a number" &&
   [ "$(field "$(dry claude-kimi WOLFMUX_KIMI_CONTEXT=1m)" "context window")" != "1M ([1m] suffix)" ]'
check "a model id ending in [1m] declares an auto-compact window, any other a max context" \
  'for p in $WOLFMUX_PROVIDERS; do
     wolfmux_provider_info "$p"
     case "$PROVIDER_MAIN_MODEL" in
       *"[1m]") F="$(field "$(dry "claude-$p")" "context window")"; case "$F" in *"auto-compact"*) ;; *) exit 1 ;; esac ;;
     esac
   done'
check "a --model id decides the window: no [1m] means a max-context window, not auto-compact" \
  'D="$(dry_args claude-deepseek --model deepseek-v4-flash)"
   [ "$(field "$D" model)" = "deepseek-v4-flash   (haiku/background tier: deepseek-v4-flash)" ] || exit 1
   case "$(field "$D" "context window")" in
     "786432 tokens (declared;"*) ;;
     *) exit 1 ;;
   esac
   case "$(field "$D" "would exec")" in *"--model deepseek-v4-flash"*) ;; *) exit 1 ;; esac
   true' # deepseek'"'"'s table id is deepseek-v4-pro[1m], so the default would have been auto-compact
check "a --model id ending in [1m] decides the other way, even when the table id does not" \
  'K="$(dry_args claude-kimi --model some-id[1m])"
   [ "$(field "$K" model)" = "some-id[1m]   (haiku/background tier: kimi-for-coding)" ] || exit 1
   case "$(field "$K" "context window")" in *"auto-compact window"*) ;; *) exit 1 ;; esac
   case "$(field "$K" "context window")" in "262144 tokens"*) ;; *) exit 1 ;; esac
   true'
check "--model=<id> is read too, and glm ignores a pin however it arrives" \
  '[ "$(field "$(dry_args claude-kimi --model=other-id)" model)" = "other-id   (haiku/background tier: kimi-for-coding)" ] &&
   [ "$(field "$(dry_args claude-glm --model glm-5.3-flash)" model)" = "glm-5.3   (haiku/background tier: glm-5.3-flash)" ] &&
   [ "$(field "$(dry_args claude-glm --model glm-5.3-flash)" "context window")" = "200000 tokens (declared; WOLFMUX_GLM_CONTEXT=1m for the 1M window)" ]'
check "wolfmux_args_model_value reads both spellings, and says no when there is none" \
  '[ "$(wolfmux_args_model_value --model a-id)" = "a-id" ] &&
   [ "$(wolfmux_args_model_value -p hi --model=b-id --max-turns 1)" = "b-id" ] &&
   [ "$(wolfmux_args_model_value --model-ish x --model c-id)" = "c-id" ] &&
   ! wolfmux_args_model_value -p "say hi" &&
   ! wolfmux_args_model_value'
check "the glm dry run has exactly the lines it had before, plus provider: (and nothing else)" \
  '[ "$(labels "$(dry claude-glm)")" = "launcher,provider,billing,endpoint,model,context window,auth mode,keychain item,login guard,overlay,agent settings,scrubbed vars,would exec," ]'
check "the scrub really happens: no inherited provider or session variable survives into the CLI" \
  'E="$(env "${CLEAN[@]}" -u WOLFMUX_DRY_RUN WOLFMUX_CLAUDE_BIN="$WORK/show-env" \
      ANTHROPIC_SMALL_FAST_MODEL=inherited-fast ANTHROPIC_API_KEY=inherited-key \
      ANTHROPIC_CUSTOM_HEADERS=inherited-header AWS_BEARER_TOKEN_BEDROCK=inherited-bedrock \
      CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_EFFORT_LEVEL=inherited-effort \
      CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=inherited-session \
      "$BIN/claude-kimi" doctor 2>&1)"
   [ -n "$E" ] || exit 1
   case "$E" in *inherited-*) exit 1 ;; esac
   case "$E" in *CLAUDE_CODE_USE_BEDROCK=*) exit 1 ;; esac
   case "$E" in *CLAUDECODE=*) exit 1 ;; esac
   true'
check "every variable a worker needs is still exported (source level: two of them show nowhere else)" \
  'for name in ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
     ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL \
     CLAUDE_CODE_SUBAGENT_MODEL API_TIMEOUT_MS CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC \
     CLAUDE_CODE_OAUTH_TOKEN; do
     LC_ALL=C /usr/bin/grep -q "^export $name=" "$REPO/bin/claude-glm" || exit 1
   done'
check "env auth mode exports the vendor's own variable, never a hardcoded one" \
  '[ "$(LC_ALL=C /usr/bin/grep -c "^  export \"\$PROVIDER_AUTH_VAR=\$KEY_VALUE\"$" "$REPO/bin/claude-glm")" = 1 ] &&
   ! LC_ALL=C /usr/bin/grep -nE "^ *export (ANTHROPIC_AUTH_TOKEN|ANTHROPIC_API_KEY)=" "$REPO/bin/claude-glm"'
check "a claude subcommand is passed straight through, with no model and no settings" \
  '[ -z "$(env "${CLEAN[@]}" -u WOLFMUX_DRY_RUN "$BIN/claude-kimi" doctor 2>&1)" ]' # /usr/bin/true prints nothing
check "the overlay and the per-agent settings file reach every provider" \
  'for p in $WOLFMUX_PROVIDERS; do
     O="$(dry "claude-$p")"
     case "$(field "$O" overlay)" in */glm-worker-settings.json) ;; *) exit 1 ;; esac
     [ "$(field "$O" "agent settings")" = "none (not started by teamctl)" ] || exit 1
     E="$(field "$(dry "claude-$p" WOLFMUX_EXTRA_SETTINGS="$WORK/agent.json")" "agent settings")"
     [ "$E" = "$WORK/agent.json" ] || exit 1
   done'

echo
echo "== key shape and source (the table's PROVIDER_KEY_PREFIX and PROVIDER_KEY_SOURCE)"
check "only kimi (sk-kim) and qwen (sk-sp-) have a key prefix; the others are empty, meaning no check" \
  'for p in $WOLFMUX_PROVIDERS; do
     wolfmux_provider_info "$p"
     case "$p" in
       kimi) [ "$PROVIDER_KEY_PREFIX" = "sk-kim" ] || exit 1 ;;
       qwen) [ "$PROVIDER_KEY_PREFIX" = "sk-sp-" ] || exit 1 ;;
       *) [ -z "$PROVIDER_KEY_PREFIX" ] || exit 1 ;;
     esac
     case "$PROVIDER_KEY_PREFIX" in *[!A-Za-z0-9._-]*) exit 1 ;; esac # a literal prefix: no glob, no space, no quote
   done'
check "kimi and moonshot say which console each key comes from, and that the two are not interchangeable" \
  'wolfmux_provider_info kimi; K="$PROVIDER_KEY_SOURCE"
   wolfmux_provider_info moonshot; M="$PROVIDER_KEY_SOURCE"
   case "$K" in *"Kimi Code"*"kimi.com/code"*"platform.kimi.ai"*"moonshot"*) ;; *) exit 1 ;; esac
   case "$M" in *"platform.kimi.ai"*"Kimi Code"*"kimi provider"*) ;; *) exit 1 ;; esac'
check "wolfmux_provider_of_model: the provider a model key runs on, nothing for a subscription model" \
  '[ "$(wolfmux_provider_of_model glm53)" = glm ] && [ "$(wolfmux_provider_of_model flash)" = glm ] &&
   [ "$(wolfmux_provider_of_model kimi)" = kimi ] && [ "$(wolfmux_provider_of_model qwen:qwen3.7-max)" = qwen ] &&
   [ "$(wolfmux_provider_of_model moonshot)" = moonshot ] &&
   ! wolfmux_provider_of_model fable && ! wolfmux_provider_of_model astra && ! wolfmux_provider_of_model claude:kimi &&
   ! wolfmux_provider_of_model codex:glm && ! wolfmux_provider_of_model "" && ! wolfmux_provider_of_model nosuchmodel'

echo
echo "== teamctl doctor --probe: one incomplete request per key, only the status shown"
# Nothing here touches your Keychain or the network. The Keychain is a function that answers a
# fake key (bash lets a function be called /usr/bin/security, as the checks above did for
# /usr/bin/id), curl is a stand-in that records how it was called, and the one check that runs
# the real curl talks to tests/mock_probe.py on 127.0.0.1.
DOCTOR_LIB="$REPO/config/wolfmux/lib/doctor.sh"
PROBE_BIN="$WORK/probe-bin"
PROBE_LOG="$WORK/probe-log"
/bin/mkdir -p "$PROBE_BIN"
/bin/cat >"$PROBE_BIN/curl" <<'STUB'
#!/bin/bash
# Stand-in for curl: records how it was called, answers with the status in $PROBE_STUB_CODE.
echo call >>"$PROBE_STUB_LOG.calls"
printf '%s\n' "$@" >"$PROBE_STUB_LOG.argv"
env >"$PROBE_STUB_LOG.env"
/bin/cat >"$PROBE_STUB_LOG.stdin"
printf '%s' "${PROBE_STUB_CODE:-000}"
STUB
/bin/chmod +x "$PROBE_BIN/curl"

SQ="'" # a single quote, for the patterns below (they live inside single-quoted check strings)
KEY_KIMI="sk-kimi-DoNotPrintMe0123456789"          # fake, the shape of a Kimi Code key
KEY_PLATFORM="sk-PlatformKeyDoNotPrint0123456789"  # fake, the shape of a Moonshot platform key
# probe <provider> <what the Keychain answers> <status curl answers> [<base url> [<keychain exit status>]]
# prints the probe's report and, last, the warning and failure counts. The Keychain answer is a
# plain variable, never exported, so a leak into the environment of curl would show.
probe() {
  local provider="$1" key="$2" code="$3" base="${4:-}" rc="${5:-0}"
  /bin/rm -f "$PROBE_LOG".*
  (
    FAKE_KEYCHAIN_VALUE="$key"
    FAKE_KEYCHAIN_RC="$rc"
    PROBE_BASE_URL="$base"
    PATH="$PROBE_BIN:$PATH"
    export PATH
    export PROBE_STUB_LOG="$PROBE_LOG" PROBE_STUB_CODE="$code"
    . "$REPO/config/wolfmux/lib/common.sh"
    . "$DOCTOR_LIB"
    eval '/usr/bin/security() { printf "%s\n" "$FAKE_KEYCHAIN_VALUE"; return "$FAKE_KEYCHAIN_RC"; }'
    if [ -n "$PROBE_BASE_URL" ]; then # a base URL the table does not have, to see what the probe refuses
      eval "$(declare -f wolfmux_provider_info | /usr/bin/sed '1s/^wolfmux_provider_info/_probe_orig_info/')"
      wolfmux_provider_info() { _probe_orig_info "$1" || return 1; PROVIDER_BASE_URL="$PROBE_BASE_URL"; }
    fi
    _doc_probe_provider "$provider"
    printf 'counts: warn=%s fail=%s\n' "$DOC_WARN" "$DOC_FAIL"
  ) 2>&1
}
counts() { printf '%s\n' "$1" | /usr/bin/sed -n 's/^counts: //p'; }
curl_calls() { [ -f "$PROBE_LOG.calls" ] && /usr/bin/wc -l <"$PROBE_LOG.calls" | tr -d ' ' || echo 0; }

check "probe: 200, 400, 422 and 429 mean the key was accepted, and the raw status is printed next to it" \
  'for c in 200 400 422 429; do
     R="$(probe kimi "$KEY_KIMI" $c)"
     case "$R" in *"probe: key accepted by https://api.kimi.com/coding/ (HTTP $c"*) ;; *) exit 1 ;; esac
     [ "$(counts "$R")" = "warn=0 fail=0" ] || exit 1
   done'
check "probe: 401 and 403 are a FAIL naming the Keychain slot, the endpoint and the console the key comes from" \
  'for c in 401 403; do
     R="$(probe kimi "$KEY_KIMI" $c)"
     printf "%s\n" "$R" | /usr/bin/grep -q "^  FAIL  probe: the key in .wolfmux-kimi. is rejected by https://api.kimi.com/coding/ (HTTP $c)" || exit 1
     case "$R" in *"kimi.com/code/console"*) ;; *) exit 1 ;; esac
     [ "$(counts "$R")" = "warn=0 fail=1" ] || exit 1
   done'
check "probe: no answer and any other status are a warning that says the key was not checked" \
  'R="$(probe kimi "$KEY_KIMI" 000)"
   case "$R" in *"probe: no answer from https://api.kimi.com/coding/"*"not checked"*) ;; *) exit 1 ;; esac
   [ "$(counts "$R")" = "warn=1 fail=0" ] || exit 1
   for c in 302 404 500 503; do
     R="$(probe kimi "$KEY_KIMI" $c)"
     case "$R" in *"https://api.kimi.com/coding/ answered HTTP $c"*) ;; *) exit 1 ;; esac
     [ "$(counts "$R")" = "warn=1 fail=0" ] || exit 1
   done'
check "probe: a kimi key that does not start with sk-kim is called what it looks like, and the endpoint still decides" \
  'R="$(probe kimi "$KEY_PLATFORM" 401)"
   case "$R" in *"the key in ${SQ}wolfmux-kimi$SQ does not start with ${SQ}sk-kim$SQ"*"Moonshot platform key"*"moonshot provider"*) ;; *) exit 1 ;; esac
   case "$R" in *"is rejected by https://api.kimi.com/coding/ (HTTP 401)"*) ;; *) exit 1 ;; esac
   [ "$(counts "$R")" = "warn=1 fail=1" ] || exit 1
   R="$(probe kimi "$KEY_KIMI" 400)"
   case "$R" in *"does not start with"*) exit 1 ;; esac'
check "probe: qwen wants sk-sp-, every provider without a prefix in the table gets no shape warning" \
  'R="$(probe qwen "sk-abcdefghijkl0123456789" 401)"
   case "$R" in *"does not start with ${SQ}sk-sp-$SQ"*) ;; *) exit 1 ;; esac
   R="$(probe qwen "sk-sp-abcdefghijkl0123456789" 400)"
   case "$R" in *"does not start with"*) exit 1 ;; esac
   for p in glm moonshot deepseek minimax; do
     R="$(probe "$p" "whatever-shape-0123456789" 400)"
     case "$R" in *"does not start with"*) exit 1 ;; esac
     [ "$(counts "$R")" = "warn=0 fail=0" ] || exit 1
   done'
check "probe: the key is never printed, whatever the status or the shape" \
  'for combo in "kimi $KEY_KIMI 400" "kimi $KEY_KIMI 401" "kimi $KEY_KIMI 000" "kimi $KEY_PLATFORM 401" "kimi $KEY_PLATFORM 500" "qwen $KEY_PLATFORM 403" "moonshot $KEY_PLATFORM 429"; do
     # shellcheck disable=SC2086
     R="$(probe $combo)"
     case "$R" in *DoNotPrint*) exit 1 ;; esac
   done'
check "probe: curl gets exactly the fixed flags, no redirect is followed, and the key is on stdin only (not argv, not the environment)" \
  'probe kimi "$KEY_KIMI" 400 >/dev/null
   [ "$(/bin/cat "$PROBE_LOG.argv")" = "$(printf "%s\n" -q -s -o /dev/null -w "%{http_code}" --max-time 15 --config -)" ] || exit 1
   ! /usr/bin/grep -qE "^(-L|--location|--location-trusted|-H|--header|-d|--data)\$" "$PROBE_LOG.argv" || exit 1
   ! /usr/bin/grep -q DoNotPrint "$PROBE_LOG.argv" "$PROBE_LOG.env" || exit 1
   [ "$(/usr/bin/grep -c "^header = \"x-api-key: $KEY_KIMI\"\$" "$PROBE_LOG.stdin")" = 1 ] &&
   [ "$(/usr/bin/grep -c "^header = \"authorization: Bearer $KEY_KIMI\"\$" "$PROBE_LOG.stdin")" = 1 ] &&
   /usr/bin/grep -q "^header = \"anthropic-version: 2023-06-01\"\$" "$PROBE_LOG.stdin" &&
   /usr/bin/grep -q "^data = \"{}\"\$" "$PROBE_LOG.stdin"'
check "probe: the request goes to <table endpoint>/v1/messages for every provider, with one slash between" \
  'for p in $WOLFMUX_PROVIDERS; do
     wolfmux_provider_info "$p"
     E="${PROVIDER_BASE_URL%/}/v1/messages"
     probe "$p" "sk-any-key-0123456789" 400 >/dev/null
     /usr/bin/grep -qxF "url = \"$E\"" "$PROBE_LOG.stdin" || exit 1
     [ "$(curl_calls)" = 1 ] || exit 1
   done'
check "probe: an endpoint that is not https, or has a character that could end a config line, is refused before the key is read, and curl is never started" \
  'for base in "http://127.0.0.1:9/anthropic" "ftp://x.example/" "file:///etc/passwd" "HTTPS://api.kimi.com/coding/" "https://x.example/a\"b" "https://x.example/a b" "https://x.example/a\\b"; do
     R="$(probe kimi "$KEY_KIMI" 400 "$base")"
     case "$R" in *"probe: refusing to send a key to"*"https"*) ;; *) exit 1 ;; esac
     [ "$(counts "$R")" = "warn=0 fail=1" ] || exit 1
     [ "$(curl_calls)" = 0 ] || exit 1
     case "$R" in *DoNotPrint*) exit 1 ;; esac
   done'
check "probe: a key with a space, quote, backslash, newline or control character is not sent (it could add a line to curl's config)" \
  'for key in "sk-abc def" "sk-abc\"def" "sk-abc\\def" "$(printf "sk-abc\nurl = \"https://evil.invalid/\"")" "$(printf "sk-abc\rdef")" "$(printf "sk-abc\tdef")"; do
     R="$(probe kimi "$key" 400)"
     case "$R" in *"nothing was sent"*) ;; *) exit 1 ;; esac
     case "$R" in *evil.invalid*) exit 1 ;; esac
     [ "$(counts "$R")" = "warn=1 fail=0" ] || exit 1
     [ "$(curl_calls)" = 0 ] || exit 1
   done'
check "probe: a Keychain that will not answer, or an empty item, is a warning and nothing is sent" \
  'R="$(probe kimi "" 400 "" 44)"
   case "$R" in *"could not read the key from ${SQ}wolfmux-kimi$SQ"*) ;; *) exit 1 ;; esac
   [ "$(counts "$R")" = "warn=1 fail=0" ] && [ "$(curl_calls)" = 0 ] || exit 1
   R="$(probe kimi "" 400)"
   case "$R" in *"the Keychain item ${SQ}wolfmux-kimi$SQ is empty"*) ;; *) exit 1 ;; esac
   [ "$(counts "$R")" = "warn=1 fail=0" ] && [ "$(curl_calls)" = 0 ] || exit 1'
check "probe: a metered provider is probed the same way, and the report has no word about the metered gate (nothing is billed)" \
  'for p in moonshot deepseek; do
     R="$(probe "$p" "sk-any-key-0123456789" 401)"
     case "$R" in *"is rejected by"*) ;; *) exit 1 ;; esac
     case "$R" in *WOLFMUX_METERED*) exit 1 ;; esac
     [ "$(curl_calls)" = 1 ] || exit 1
   done'
check "doctor.sh: one curl call, its config from stdin; no header, data or redirect option on it, no here-string, the Keychain value read in one place" \
  '[ "$(/usr/bin/grep -c "curl_bin\" -" "$DOCTOR_LIB")" = 1 ] &&
   /usr/bin/grep "curl_bin\" -" "$DOCTOR_LIB" | /usr/bin/grep -q -- "--config -" &&
   ! /usr/bin/grep "curl_bin\" -" "$DOCTOR_LIB" | /usr/bin/grep -qE -- " (-H|--header|-L|--location|--location-trusted|-d|--data)( |\$)" &&
   ! /usr/bin/grep -n "<<<" "$DOCTOR_LIB" &&
   [ "$(/usr/bin/grep -c "find-generic-password.* -w" "$DOCTOR_LIB")" = 1 ]'

if command -v python3 >/dev/null 2>&1; then
  python3 "$REPO/tests/mock_probe.py" "$WORK/mock.log" "$WORK/mock.port" >/dev/null 2>&1 &
  PROBE_MOCK_PID=$!
  disown "$PROBE_MOCK_PID" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    [ -s "$WORK/mock.port" ] && break
    sleep 0.1
  done
fi
if [ -n "$PROBE_MOCK_PID" ] && [ -s "$WORK/mock.port" ]; then
  MOCK="http://127.0.0.1:$(/bin/cat "$WORK/mock.port")"
  # The config the probe builds, given to the real curl with the flags the probe uses (the
  # check above pins them): what arrives at a server is what a vendor would see.
  mock_status() { # <path> <key>
    ( . "$REPO/config/wolfmux/lib/common.sh"; . "$DOCTOR_LIB"; _doc_probe_config "$MOCK$1" "$2" ) |
      /usr/bin/curl -q -s -o /dev/null -w '%{http_code}' --max-time 15 --config -
  }
  check "real curl: the probe's config makes one POST with both credential headers, the same value in each, and an empty JSON body" \
    '/bin/rm -f "$WORK/mock.log"
     [ "$(mock_status /anthropic/v1/messages sk-good-0123456789abcdef)" = 400 ] &&
     [ "$(mock_status /anthropic/v1/messages sk-bad-0123456789abcdef)" = 401 ] &&
     [ "$(/usr/bin/wc -l <"$WORK/mock.log" | tr -d " ")" = 2 ] &&
     for frag in "\"method\": \"POST\"" "\"path\": \"/anthropic/v1/messages\"" "\"x_api_key\": true" "\"bearer\": true" \
       "\"same_value\": true" "\"content_type\": \"application/json\"" "\"anthropic_version\": \"2023-06-01\"" "\"body\": \"{}\""; do
       /usr/bin/head -1 "$WORK/mock.log" | /usr/bin/grep -qF "$frag" || exit 1
     done'
  check "real curl: a redirect is not followed, so the key goes to one address and no other" \
    '/bin/rm -f "$WORK/mock.log"
     [ "$(mock_status /redirect/v1/messages sk-good-0123456789abcdef)" = 302 ] &&
     [ "$(/usr/bin/wc -l <"$WORK/mock.log" | tr -d " ")" = 1 ]'
else
  skip "real curl: the probe's config makes one POST with both credential headers and an empty body" "python3 is not available, or the mock did not start"
  skip "real curl: a redirect is not followed" "python3 is not available, or the mock did not start"
fi

echo "== the config file: an allow-listed key is taken, anything else is dropped"
# Nothing tested wolfmux_load_config at all, which is why the notice knobs could sit off
# WOLFMUX_CONFIG_KEYS unnoticed from v1.14.0 to v1.16.0: a key the list does not know is
# read out of the file and dropped, with no error and no effect. Measured 2026-10-12 with
# WOLFMUX_NUDGE_TYPE=all in the real config file, which the next nudge ignored.
# Each case runs in its own subshell with its own WOLFMUX_HOME, so the file under test is
# a throwaway one and none of this reaches ~/.config/wolfmux/config.
/bin/mkdir -p "$WORK/cfg"
cat >"$WORK/cfg/config" <<'EOF'
# a comment, and a blank line follow

WOLFMUX_NUDGE_TYPE=all
WOLFMUX_NUDGE_LEAD_IDLE = 42
WOLFMUX_INBOX_APPROVAL_TYPE=never
WOLFMUX_NUDGE_DEBOUNCE=99
WOLFMUX_NOT_A_SETTING=yes
no equals sign here
EOF
load_cfg() { # <key> — print what the config file gives that key, or nothing
  (
    unset "$1"
    WOLFMUX_HOME="$WORK/cfg"
    wolfmux_load_config
    printf '%s' "${!1:-}"
  )
}
check "config: an allow-listed key is taken from the file" '[ "$(load_cfg WOLFMUX_NUDGE_TYPE)" = "all" ]'
check "config: spaces around the = and the value are stripped" '[ "$(load_cfg WOLFMUX_NUDGE_LEAD_IDLE)" = "42" ]'
check "config: the approval knob is on the list too" '[ "$(load_cfg WOLFMUX_INBOX_APPROVAL_TYPE)" = "never" ]'
check "config: a key NOT on the list is dropped, which is the defect this guards" '[ -z "$(load_cfg WOLFMUX_NUDGE_DEBOUNCE)" ] && [ -z "$(load_cfg WOLFMUX_NOT_A_SETTING)" ]'
check "config: an environment variable that is already set wins over the file" '[ "$(WOLFMUX_NUDGE_TYPE=off; WOLFMUX_HOME="$WORK/cfg" wolfmux_load_config; printf "%s" "$WOLFMUX_NUDGE_TYPE")" = "off" ]'
check "config: every key on the list is a WOLFMUX_ name, so nothing else can be exported from that file" '! printf "%s\n" $WOLFMUX_CONFIG_KEYS | grep -qv "^WOLFMUX_"'
check "config: no file at all is not an error" '(WOLFMUX_HOME="$WORK/nowhere"; wolfmux_load_config)'

echo "== the config file through bin/teamctl itself: the real load order"
# Every check above unsets the key and calls the loader by hand, so none of them could see
# what bin/teamctl really did: source inbox.sh and agents.sh, which set their defaults as
# they are sourced, and only THEN load the file, whose loader skips a name that is already
# set. WOLFMUX_NUDGE_TYPE=off in the real config file did nothing (found 2026-10-15). So
# this runs the binary, with a WOLFMUX_HOME of its own whose lib/ is the repository's, in
# a throwaway git repository, on a tmux socket nothing listens on, and reads the value back
# off `teamctl policy`, which prints it.
/bin/mkdir -p "$WORK/realhome" "$WORK/realproj"
ln -s "$REPO/config/wolfmux/lib" "$WORK/realhome/lib"
cat >"$WORK/realhome/config" <<'EOF'
WOLFMUX_NUDGE_TYPE=off
WOLFMUX_HUMAN_PANE_TYPING=idle
EOF
(cd "$WORK/realproj" && git init -q 2>/dev/null)
real_policy() { # [VAR=value...] — teamctl policy as the binary runs it, with no agent's environment
  (cd "$WORK/realproj" && env -u TEAM_ROLE -u BEADS_ACTOR -u WOLFMUX_TEAM -u WOLFMUX_TEAM_ARG -u WOLFMUX_ROOT \
    -u TMUX -u TMUX_PANE -u WOLFMUX_NUDGE_TYPE -u WOLFMUX_HUMAN_PANE_TYPING \
    WOLFMUX_HOME="$WORK/realhome" WOLFMUX_DATA="$WORK/realdata" WOLFMUX_TMUX_SOCKET="wolfmux-test-providers-$$" \
    "$@" "$REPO/bin/teamctl" policy 2>&1)
}
check "real load order: WOLFMUX_NUDGE_TYPE in the config file takes effect in teamctl" 'real_policy | grep -q "WOLFMUX_NUDGE_TYPE=off"'
check "real load order: so does the human-pane-typing default" 'real_policy | grep -qE "^  human-pane-typing +idle "'
check "real load order: an environment variable still wins over the file" 'real_policy WOLFMUX_NUDGE_TYPE=workers | grep -q "WOLFMUX_NUDGE_TYPE=workers"'
check "real load order: with no config file the built-in defaults stand" '/bin/rm -f "$WORK/realhome/config" && real_policy | grep -q "WOLFMUX_NUDGE_TYPE=detached-lead" && real_policy | grep -qE "^  human-pane-typing +off "'

echo
echo "result: $passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
