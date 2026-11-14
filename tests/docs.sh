#!/bin/bash
# docs.sh — does the documentation name everything the tool offers?
#
# Reads the CODE for what exists (teamctl's commands and their options, policy keys, model
# keys, settings, launchers, the installer's options; the third-party providers from their table) and the DOCUMENTS for whether each is
# named. Nothing is started: no tmux, no agents, no network. A few seconds.
#
# Run it after adding a command, an option or a setting: it fails, and says what is missing
# where, until README.md, docs/USAGE.md, the user manual and `teamctl help` know about it.
#
#   tests/docs.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
LIB="$REPO/config/wolfmux/lib"
TEAMCTL="$REPO/bin/teamctl"
README="$(/bin/cat "$REPO/README.md")"
USAGE="$(/bin/cat "$REPO/docs/USAGE.md")"
MANUAL="$(/bin/cat "$REPO/config/wolfmux/README.md")"
SETUP="$(/bin/cat "$REPO/docs/SETUP.md")"
# what `teamctl help` prints, without running anything
HELP="$(/usr/bin/awk '/^usage\(\) \{/ { inside = 1; next } inside && /^EOF$/ { exit } inside { print }' "$TEAMCTL")"

passed=0
failed=0
# report <description> <missing items> — passes when nothing is missing, names it otherwise
report() {
  if [ -z "$2" ]; then
    passed=$((passed + 1))
    printf '  pass  %s\n' "$1"
  else
    failed=$((failed + 1))
    printf '  FAIL  %s\n        missing:%s\n' "$1" "$2"
  fi
}

# has <text> <extended regex>
has() { printf '%s\n' "$1" | LC_ALL=C /usr/bin/grep -Eq -- "$2"; }

# near <text> <command> <option> — is the option on a line that names the command, or on
# one of the three lines after it (help and tables continue a synopsis on the next lines)
near() {
  printf '%s\n' "$1" | LC_ALL=C /usr/bin/awk -v pattern="teamctl $2([^a-z-]|\$)" -v option="$3" '
    $0 ~ pattern { window = 4 }
    window > 0 && index($0, option) { found = 1; exit }
    window > 0 { window-- }
    END { exit found ? 0 : 1 }'
}

# public_commands — one line per command teamctl dispatches: "<name> <handler> [<alias>...]".
# Internal commands (_name), the pointers to Beads, and version/help are left out.
public_commands() {
  /usr/bin/awk '
    /case "\$command" in/ { inside = 1; next }
    inside && /^  esac/ { exit }
    inside && /^    [a-z_-]+( \| [a-z_-]+)*\) / {
      if ($0 ~ /moved_to_beads|removed_command|usage|WOLFMUX_VERSION/) next
      names = $0; sub(/\).*/, "", names); gsub(/[ |]+/, " ", names); sub(/^ /, "", names)
      if (names ~ /^_/) next
      handler = $0; sub(/^[^)]*\) /, "", handler); sub(/ .*/, "", handler)
      count = split(names, name, " ")
      line = name[1] " " handler
      for (i = 2; i <= count; i++) line = line " " name[i]
      print line
    }' "$TEAMCTL"
}

# options_of <function> — the long options its argument loop accepts, one case label per
# line. The spellings on one label are synonyms ("--names|--name-only"): naming one is enough.
options_of() {
  /bin/cat "$LIB"/*.sh | /usr/bin/awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\) \\{" { inside = 1; next }
    inside && /^}/ { exit }
    inside && /^ +[^()$"#]*--[a-z][^()$"#]*\)/ {
      labels = $0; sub(/\).*/, "", labels)
      count = split(labels, label, /[ |]+/)
      group = ""
      for (i = 1; i <= count; i++) if (label[i] ~ /^--[a-z]/) { sub(/=.*/, "", label[i]); group = group (group == "" ? "" : "|") label[i] }
      if (group != "") print group
    }' | /usr/bin/sort -u
}

# script_options <file> — the long options of a top-level script (install.sh, …)
script_options() {
  /usr/bin/awk '/^ +[^()$"#]*--[a-z][^()$"#]*\)/ {
      labels = $0; sub(/\).*/, "", labels)
      count = split(labels, label, /[ |]+/)
      for (i = 1; i <= count; i++) if (label[i] ~ /^--[a-z]/ && label[i] != "--help") print label[i]
    }' "$1" | /usr/bin/sort -u
}

COMMANDS="$(public_commands)"

# missing_commands <text> <with-aliases: yes|no>
missing_commands() {
  local text="$1" aliases="$2" line name primary out=""
  while IFS= read -r line; do
    # shellcheck disable=SC2086
    set -- $line
    primary="$1"
    shift 2
    has "$text" "teamctl $primary([^a-z-]|\$)" || out="$out $primary"
    [ "$aliases" = "yes" ] || continue
    for name in "$@"; do
      has "$text" "alias[^a-z]*$name([^a-z-]|\$)" || out="$out $name(alias-of-$primary)"
    done
  done <<EOF
$COMMANDS
EOF
  printf '%s' "$out"
}

# missing_options <text>
missing_options() {
  local text="$1" line primary handler group option found out=""
  while IFS= read -r line; do
    # shellcheck disable=SC2086
    set -- $line
    primary="$1" handler="$2"
    # `log` is `capture --all` under another name: it has no options of its own
    [ "$handler" = "cmd_$(printf '%s' "$primary" | /usr/bin/tr '-' '_')" ] || continue
    for group in $(options_of "$handler"); do
      found=0
      for option in $(printf '%s' "$group" | /usr/bin/tr '|' ' '); do
        if near "$text" "$primary" "$option"; then found=1; fi
      done
      [ "$found" -eq 1 ] || out="$out $primary:$group"
    done
  done <<EOF
$COMMANDS
EOF
  printf '%s' "$out"
}

# ignored <file> — a file git is told to ignore (.gitignore, .git/info/exclude) is not part of
# the documentation: a private note, an audit in progress. Outside a git checkout nothing is.
ignored() { git -C "$REPO" check-ignore -q "$1" 2>/dev/null; }

# anchors_of <file> — the anchors GitHub gives its headings: lowercase, punctuation dropped,
# spaces to hyphens ("## The Z.ai key" -> the-zai-key)
anchors_of() {
  # a "# comment" inside a fenced example is not a heading
  LC_ALL=C /usr/bin/awk '/^```/ { fenced = !fenced; next } !fenced && /^##* / { sub(/^##* */, ""); print }' "$1" |
    LC_ALL=C /usr/bin/tr 'A-Z' 'a-z' | LC_ALL=C /usr/bin/sed 's/[^a-z0-9 _-]//g; s/ /-/g'
}

# missing_words <text> <word>... — whole words only: `--worker-spawn` does not name the policy
# key worker-spawn, and `codex-astra` does not name the model key astra
missing_words() {
  local text="$1" word pattern out=""
  shift
  for word in "$@"; do
    pattern="$(printf '%s' "$word" | LC_ALL=C /usr/bin/sed 's/[][(){}.*+?^$|\\]/\\&/g')"
    has "$text" "(^|[^A-Za-z0-9_-])$pattern([^A-Za-z0-9_-]|\$)" || out="$out $word"
  done
  printf '%s' "$out"
}

echo "== teamctl's commands"
[ -n "$COMMANDS" ] && [ -n "$HELP" ] || { echo "cannot read the command list or the help text out of bin/teamctl" >&2; exit 1; }
report "teamctl help names every command and alias" "$(missing_commands "$HELP" yes)"
report "README.md names every command and alias" "$(missing_commands "$README" yes)"
report "docs/USAGE.md names every command and alias" "$(missing_commands "$USAGE" yes)"
report "the user manual names every command" "$(missing_commands "$MANUAL" no)"

echo "== their options"
report "teamctl help shows every option next to its command" "$(missing_options "$HELP")"
report "README.md shows every option next to its command" "$(missing_options "$README")"
report "docs/USAGE.md shows every option next to its command" "$(missing_options "$USAGE")"

echo "== tab completion (the drift guard)"
# _complete must name everything the tool really offers: every public command as the
# first word, and, per command, every option its parser accepts. Read from the CODE
# (public_commands and options_of above), asked of the BACKEND. Read-only and offline.
complete_run() { WOLFMUX_HOME="$REPO/config/wolfmux" "$TEAMCTL" _complete "$@" 2>/dev/null; }
TAB="$(
  printf '\t'
)"
FIRST_WORDS="$(complete_run -- "")"
out=""
while IFS= read -r line; do
  # shellcheck disable=SC2086
  set -- $line
  primary="$1"
  printf '%s\n' "$FIRST_WORDS" | LC_ALL=C grep -Eq -- "^$primary($TAB|\$)" || out="$out $primary"
done <<EOF
$COMMANDS
EOF
report "_complete offers every public command as the first word" "$out"
out=""
for alias in workers open log; do
  printf '%s\n' "$FIRST_WORDS" | LC_ALL=C grep -Eq -- "^$alias($TAB|\$)" || out="$out $alias"
done
printf '%s\n' "$FIRST_WORDS" | LC_ALL=C grep -Eq -- "^--team($TAB|\$)" || out="$out --team"
printf '%s\n' "$FIRST_WORDS" | LC_ALL=C grep -Eq -- "^help($TAB|\$)" || out="$out help"
printf '%s\n' "$FIRST_WORDS" | LC_ALL=C grep -Eq -- "^version($TAB|\$)" || out="$out version"
report "_complete offers the aliases workers, open, log, and --team, help, version" "$out"
if printf '%s\n' "$FIRST_WORDS" | LC_ALL=C grep -q '^_'; then
  report "_complete offers no internal command" " _"
else
  report "_complete offers no internal command" ""
fi
out=""
while IFS= read -r line; do
  # shellcheck disable=SC2086
  set -- $line
  primary="$1" handler="$2"
  # `log` is `capture --all` under another name: no options of its own
  [ "$handler" = "cmd_$(printf '%s' "$primary" | /usr/bin/tr '-' '_')" ] || continue
  for group in $(options_of "$handler"); do
    found=0
    for option in $(printf '%s' "$group" | /usr/bin/tr '|' ' '); do
      printf '%s\n' "$(complete_run -- "$primary" --)" | LC_ALL=C grep -Eq -- "^$option($TAB|\$)" && found=1
    done
    [ "$found" -eq 1 ] || out="$out $primary:$group"
  done
done <<EOF
$COMMANDS
EOF
report "_complete offers every option a command's parser accepts" "$out"

echo "== policy keys and models"
# shellcheck disable=SC2046
POLICY_KEYS="$(/usr/bin/sed -n 's/^POLICY_KEYS="\(.*\)"$/\1/p' "$LIB/policy.sh")"
MODEL_KEYS="$(/usr/bin/awk '/^model_info\(\) \{/ { inside = 1; next } inside && /^}/ { exit }
  inside && /^    [a-z][a-z0-9]*:?\*?\)/ { key = $1; sub(/\*?\).*/, "", key); print key }' "$LIB/common.sh")"
# The third-party providers are not case labels in model_info: they come from the provider table
# (glm is left out: its keys are glm53 and flash). A pinnable one also takes "<key>:<model-id>".
# provider-env.sh has no side effects when sourced, so the table is read by sourcing it.
PROVIDER_KEYS="$( . "$LIB/provider-env.sh"
  for provider in $WOLFMUX_PROVIDERS; do
    [ "$provider" = glm ] && continue
    wolfmux_provider_info "$provider" || continue
    printf '%s\n' "$provider"
    if [ "$PROVIDER_PINNABLE" = 1 ]; then printf '%s:\n' "$provider"; fi
  done)"
[ -n "$POLICY_KEYS" ] && [ -n "$MODEL_KEYS" ] && [ -n "$PROVIDER_KEYS" ] || { echo "cannot read the policy keys or the model keys out of the libraries" >&2; exit 1; }
MODEL_KEYS="$(printf '%s\n%s\n' "$MODEL_KEYS" "$PROVIDER_KEYS")"
for name in "teamctl help:$HELP" "README.md:$README" "docs/USAGE.md:$USAGE" "the user manual:$MANUAL"; do
  # shellcheck disable=SC2086
  report "${name%%:*} names every policy key" "$(missing_words "${name#*:}" $POLICY_KEYS)"
  # shellcheck disable=SC2086
  report "${name%%:*} names every model key" "$(missing_words "${name#*:}" $MODEL_KEYS)"
done

echo "== settings, launchers, the installer"
# WOLFMUX_CONFIG_KEYS is a literal list plus, for every provider, generated WOLFMUX_<P>_* names
# (and the global WOLFMUX_METERED): the value the library ends up with is what has to be documented.
SETTINGS="$( . "$LIB/provider-env.sh"; printf '%s\n' $WOLFMUX_CONFIG_KEYS | LC_ALL=C /usr/bin/grep -o 'WOLFMUX_[A-Z0-9_]*' | /usr/bin/sort -u)"
[ -n "$SETTINGS" ] || { echo "cannot read WOLFMUX_CONFIG_KEYS out of provider-env.sh" >&2; exit 1; }
# shellcheck disable=SC2086
report "the config template shows every setting it accepts" "$(missing_words "$(/bin/cat "$REPO/config/wolfmux/config")" $SETTINGS)"
# shellcheck disable=SC2086
DOCS_TEXT="$(for file in "$REPO"/docs/*.md; do [ -e "$file" ] && ! ignored "$file" && /bin/cat "$file"; done)"
# shellcheck disable=SC2086
report "every setting is explained in the user manual or under docs/" "$(missing_words "$MANUAL $DOCS_TEXT" $SETTINGS)"
# Launchers: the files in bin/, the names install.sh spells out, and one claude-<provider> per
# provider of the table (install.sh links those in a loop over the table, so they are not spelled out).
LAUNCHERS="$( (cd "$REPO/bin" && /bin/ls) | /usr/bin/grep -v '^teamctl$'
  LC_ALL=C /usr/bin/grep -o 'BIN_DIR/claude-[a-z][a-z-]*' "$REPO/install.sh" | /usr/bin/sed 's|.*/||'
  /usr/bin/sed -n 's/^for name in \(claude-[a-z -]*\); do$/\1/p' "$REPO/install.sh" | /usr/bin/tr ' ' '\n'
  printf '%s\n' "$PROVIDER_KEYS" | /usr/bin/sed -n 's/^\([a-z][a-z0-9]*\)$/claude-\1/p')"
LAUNCHERS="$(printf '%s\n' "$LAUNCHERS" | /usr/bin/sed '/^$/d' | /usr/bin/sort -u)"
[ -n "$LAUNCHERS" ] || { echo "cannot read the launcher names out of bin/ and install.sh" >&2; exit 1; }
# shellcheck disable=SC2086
report "README.md names every launcher" "$(missing_words "$README" $LAUNCHERS)"
# shellcheck disable=SC2086
report "the user manual names every launcher" "$(missing_words "$MANUAL" $LAUNCHERS)"
# shellcheck disable=SC2086
report "docs/SETUP.md names every launcher the installer puts in ~/bin" "$(missing_words "$SETUP" $LAUNCHERS)"
for script in "$REPO"/*.sh; do
  [ -e "$script" ] || continue
  options="$(script_options "$script")"
  if [ -z "$options" ] && LC_ALL=C /usr/bin/grep -Eq -- '(^|[^-])--[a-z][a-z-]+' "$script"; then
    echo "cannot read the options of $(basename "$script"): it mentions some, but not as case labels" >&2
    exit 1
  fi
  # shellcheck disable=SC2086
  report "docs/SETUP.md names every option of $(basename "$script")" "$(missing_words "$SETUP" $options)"
done
report "docs/SETUP.md says what the installer builds and links" "$(missing_words "$SETUP" Wolfmux.app "~/bin/codex")"

echo "== provider keys and auth modes"
TROUBLE="$(/bin/cat "$REPO/docs/TROUBLESHOOTING.md")"
# What the provider table says about a key: how it starts, and the consoles it names. The README and
# docs/SETUP.md must say the same, or a Kimi Code key and a platform.kimi.ai key look alike again (issue #1).
KEY_FACTS="$( . "$LIB/provider-env.sh"
  for provider in $WOLFMUX_PROVIDERS; do
    wolfmux_provider_info "$provider" || continue
    [ -z "$PROVIDER_KEY_PREFIX" ] || printf '%s\n' "$PROVIDER_KEY_PREFIX"
    printf '%s\n' "$PROVIDER_KEY_SOURCE" | LC_ALL=C /usr/bin/grep -o 'https://[^ )]*' | /usr/bin/sed 's/[.,;:]*$//'
  done | /usr/bin/sort -u)"
[ -n "$KEY_FACTS" ] || { echo "cannot read the key prefixes and key sources out of the provider table" >&2; exit 1; }
# missing_facts <text>: the facts the text does not contain, as fixed strings
missing_facts() {
  local fact out=""
  while IFS= read -r fact; do
    printf '%s\n' "$1" | LC_ALL=C /usr/bin/grep -Fq -- "$fact" || out="$out $fact"
  done <<FACTS
$KEY_FACTS
FACTS
  printf '%s' "$out"
}
report "README.md gives the key prefix and the console URL of every key the provider table describes" "$(missing_facts "$README")"
report "docs/SETUP.md gives the key prefix and the console URL of every key the provider table describes" "$(missing_facts "$SETUP")"
out=""
for pattern in "teamctl doctor --probe" "Detected a custom API key" "Both CLAUDE_CODE_OAUTH_TOKEN and apiKeyHelper set" "sk-kim"; do
  has "$TROUBLE" "$pattern" || out="$out $pattern"
done
report "docs/TROUBLESHOOTING.md has rows for a 401 (doctor --probe), the wrong Kimi key, the login-guard warning and the env-mode prompt" "$out"
out=""
has "$README" "^### Auth modes" || out="$out README.md:Auth-modes"
has "$MANUAL" "^## Auth modes and the key probe" || out="$out manual:Auth-modes"
has "$README" "CLAUDE_CODE_OAUTH_TOKEN and apiKeyHelper set" || out="$out README.md:login-guard-warning"
has "$README" "Do you want to use this API key" || out="$out README.md:env-mode-prompt"
report "the README and the user manual explain the auth modes: the expected login-guard warning and the env-mode prompt" "$out"

echo "== indexes and links"
out=""
for file in "$REPO"/docs/*.md; do
  [ -e "$file" ] && ! ignored "$file" || continue
  has "$README" "\\(docs/$(basename "$file")\\)" || out="$out docs/$(basename "$file")"
done
report "README.md links every document under docs/" "$out"
out=""
for file in "$REPO"/docs/adr/0*.md; do
  [ -e "$file" ] && ! ignored "$file" || continue
  LC_ALL=C /usr/bin/grep -Fq "($(basename "$file"))" "$REPO/docs/adr/README.md" || out="$out $(basename "$file")"
done
report "docs/adr/README.md lists every decision record" "$out"
out=""
for file in "$REPO"/docs/diagrams/*.svg; do
  [ -e "$file" ] && ! ignored "$file" || continue
  LC_ALL=C /usr/bin/grep -Fq "$(basename "$file")" "$REPO/docs/diagrams/README.md" || out="$out $(basename "$file")"
done
report "docs/diagrams/README.md shows every diagram" "$out"
out=""
for file in "$REPO"/README.md "$REPO"/docs/*.md "$REPO"/docs/adr/*.md "$REPO"/docs/diagrams/README.md "$REPO"/config/wolfmux/*.md; do
  [ -e "$file" ] && ! ignored "$file" || continue
  while IFS= read -r target; do
    case "$target" in "" | http://* | https://* | mailto:*) continue ;; esac
    anchor=""
    case "$target" in *\#*) anchor="${target#*#}" ;; esac
    linked="${target%%#*}"
    if [ -z "$linked" ]; then linked="$file"; else linked="$(dirname "$file")/$linked"; fi
    if [ ! -e "$linked" ]; then
      out="$out ${file#"$REPO"/}->$target"
    elif [ -n "$anchor" ] && [ "${linked%.md}" != "$linked" ] && ! anchors_of "$linked" | LC_ALL=C /usr/bin/grep -Fxq -- "$anchor"; then
      out="$out ${file#"$REPO"/}->$target"
    fi
  done < <(LC_ALL=C /usr/bin/grep -o '\]([^)]*)' "$file" | /usr/bin/sed 's/^\](//; s/)$//; s/ .*//')
done
report "every relative link in the documents leads to a file, and to a heading that exists" "$out"

echo
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
