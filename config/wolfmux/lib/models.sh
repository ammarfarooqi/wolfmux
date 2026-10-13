#!/bin/bash
# models.sh — what the model keys fable, opus, sonnet and haiku mean today, and which model
# each agent actually started with. Sourced by common.sh (so by teamctl) and by the
# subscription launcher (bin/claude-fable). Compatible with macOS /bin/bash 3.2. No credential.
#
# Where a model id comes from (never a guess):
#
#   Claude Code itself is the source of truth. `claude --help` (2.1.296) says of --model:
#   "Provide an alias for the latest model (e.g. 'fable', 'opus', or 'sonnet') or a model's
#   full name", and its documentation says the aliases resolve to Claude Code's built-in
#   defaults, which move with its releases (code.claude.com/docs, "Pin model versions":
#   opus meant Opus 5 from v2.1.219 and Opus 5.5 from v2.1.280). The CLI has no command
#   that lists models, and the Models API wants an API key, which a subscription has not.
#   So the documented way to learn what an alias means FOR THIS ACCOUNT is to use it: one
#   print-mode call with --model <alias> --output-format json. Its result names the model
#   that answered (modelUsage, with its context window), and the same call proves that id
#   usable. With every customisation off and no tools it is ~700 tokens (measured on
#   2026-10-13: haiku $0.00014 at list price, fable $0.014; 3 to 4 seconds).
#
#   That probe runs at most once per alias per day, and only where an agent is about to
#   start (spawn, start, restart) or when you ask (teamctl models --refresh). Nothing that
#   draws a screen probes: status, the status bar, completion and doctor read the cache.
#
#   WOLFMUX_MODEL_POLICY=latest   (default) an alias means what the probe saw today
#   WOLFMUX_MODEL_POLICY=pinned   an alias means the built-in id below; nothing is probed
#   WOLFMUX_<ALIAS>_MODEL=<id>    a pin: that id under either policy, and no probe
#
# A probe that fails falls back to the built-in id and says so at every spawn until one
# succeeds. A failure is retried after WOLFMUX_MODEL_RETRY seconds (default 3600), so an
# offline machine is not asked again at every spawn.

WOLFMUX_MODEL_ALIASES="fable opus sonnet haiku"
# Fields are split on the unit separator, never on a tab: a tab is whitespace to `read`, so
# two tabs in a row (an empty field) would collapse into one and shift every field after it.
_MODELS_SEP=$'\037'

# models_is_alias <key>: one of the four keys whose meaning moves with Claude Code's releases
models_is_alias() {
  [ -n "${1:-}" ] || return 1
  case " $WOLFMUX_MODEL_ALIASES " in *" $1 "*) return 0 ;; esac
  return 1
}

# models_builtin <alias> — sets MB_ID and MB_CONTEXT: the ids this release pins. Each one is
# what the probe answered on 2026-10-13 (Claude Code 2.1.296), with the context window that
# answer declared (the same window when the id itself is passed with --model). Update them
# per release: policy pinned, a failed probe and a launcher run by hand under policy pinned use them.
models_builtin() {
  MB_CONTEXT="1000000"
  case "$1" in
    fable) MB_ID="claude-fable-5-1" ;;
    opus) MB_ID="claude-opus-5-5" ;;
    sonnet) MB_ID="claude-sonnet-5-5" ;;
    haiku) MB_ID="claude-haiku-5-5" ;;
    *)
      MB_ID="" MB_CONTEXT=""
      return 1
      ;;
  esac
}

# models_policy — latest or pinned. Anything else counts as latest (doctor says so).
models_policy() {
  case "${WOLFMUX_MODEL_POLICY:-latest}" in
    pinned) printf 'pinned\n' ;;
    *) printf 'latest\n' ;;
  esac
}

# models_pin_var <alias> — sets MODELS_PIN_VAR (WOLFMUX_OPUS_MODEL) and MODELS_PIN (its value)
models_pin_var() {
  case "$1" in
    fable) MODELS_PIN_VAR="WOLFMUX_FABLE_MODEL" ;;
    opus) MODELS_PIN_VAR="WOLFMUX_OPUS_MODEL" ;;
    sonnet) MODELS_PIN_VAR="WOLFMUX_SONNET_MODEL" ;;
    haiku) MODELS_PIN_VAR="WOLFMUX_HAIKU_MODEL" ;;
    *)
      MODELS_PIN_VAR="" MODELS_PIN=""
      return 1
      ;;
  esac
  MODELS_PIN="${!MODELS_PIN_VAR:-}"
}

# --- reading an id -------------------------------------------------------------
_MODELS_LOWER="abcdefghijklmnopqrstuvwxyz"
_MODELS_UPPER="ABCDEFGHIJKLMNOPQRSTUVWXYZ"

# models_parse <id> — sets MP_FAMILY MP_MAJOR MP_MINOR for claude-<family>-<n>[-<n>][-<date>]
# (a [1m] marker is ignored). Returns 1 for any other shape; nothing is inferred from one.
models_parse() {
  local id="${1%%\[*}" rest part IFS=-
  MP_FAMILY="" MP_MAJOR="" MP_MINOR=""
  case "$id" in claude-?*-?*) ;; *) return 1 ;; esac
  rest="${id#claude-}"
  MP_FAMILY="${rest%%-*}"
  rest="${rest#*-}"
  case "$MP_FAMILY" in "" | *[!${_MODELS_LOWER}]*) return 1 ;; esac
  for part in $rest; do
    case "$part" in "" | *[!0123456789]*) return 1 ;; esac
    [ "${#part}" -lt 8 ] || continue # a date stamp: claude-haiku-4-5-20251001
    if [ -z "$MP_MAJOR" ]; then
      MP_MAJOR="$part"
    elif [ -z "$MP_MINOR" ]; then
      MP_MINOR="$part"
    else
      return 1
    fi
  done
  [ -n "$MP_MAJOR" ]
}

# models_family_label <family> — sets MODELS_LABEL to the family's name: opus -> Opus
models_family_label() {
  local first="${1:0:1}" before
  before="${_MODELS_LOWER%%"$first"*}"
  MODELS_LABEL="${_MODELS_UPPER:${#before}:1}${1:1}"
}

# models_label_of <id> — sets MODELS_LABEL: "Opus 5.5" for claude-opus-5-5, "Haiku 4.5" for
# claude-haiku-4-5-20251001. An id of any other shape is shown as it is.
models_label_of() {
  if ! models_parse "$1"; then
    MODELS_LABEL="$1"
    return 0
  fi
  models_family_label "$MP_FAMILY"
  MODELS_LABEL="$MODELS_LABEL $MP_MAJOR${MP_MINOR:+.$MP_MINOR}"
}

# models_newer <a> <b> — true when <a> is a later member of the same family than <b>.
# Two ids that cannot both be read, or of different families, are never "newer".
models_newer() {
  local fam major minor
  models_parse "$2" || return 1
  fam="$MP_FAMILY" major="$MP_MAJOR" minor="${MP_MINOR:-0}"
  models_parse "$1" || return 1
  [ "$MP_FAMILY" = "$fam" ] || return 1
  [ "$((10#$MP_MAJOR))" -gt "$((10#$major))" ] && return 0
  [ "$((10#$MP_MAJOR))" -eq "$((10#$major))" ] && [ "$((10#${MP_MINOR:-0}))" -gt "$((10#$minor))" ]
}

# --- the cache: one validated answer per alias and day ------------------------------
# $WOLFMUX_DATA/models/<alias>.ok    ok|id|day|epoch|context|       the last probe that worked
# $WOLFMUX_DATA/models/<alias>.fail  fail||day|epoch||reason        the last one that did not (removed
#                                                                    by the next one that works)
models_cache_dir() { printf '%s/models\n' "${WOLFMUX_DATA:-$HOME/.wolfmux}"; }

models_today() {
  [ -n "${_MODELS_TODAY:-}" ] || _MODELS_TODAY="$(date -u +%Y-%m-%d)"
  printf '%s\n' "$_MODELS_TODAY"
}

# models_cache_read <alias> <ok|fail> — sets MC_ID MC_DAY MC_EPOCH MC_CONTEXT MC_NOTE; 1 = none
models_cache_read() {
  local file status="" line=""
  file="$(models_cache_dir)/$1.$2"
  MC_ID="" MC_DAY="" MC_EPOCH="" MC_CONTEXT="" MC_NOTE=""
  [ -r "$file" ] || return 1
  IFS= read -r line <"$file" || [ -n "$line" ] || return 1
  IFS='|' read -r status MC_ID MC_DAY MC_EPOCH MC_CONTEXT MC_NOTE <<EOF
$line
EOF
  [ "$status" = "$2" ] || return 1
  case "$MC_EPOCH" in "" | *[!0123456789]*) MC_EPOCH=0 ;; esac
  case "$MC_CONTEXT" in *[!0123456789]*) MC_CONTEXT="" ;; esac
  if [ "$2" = "ok" ]; then valid_model_id "$MC_ID" || return 1; fi
  return 0
}

# models_cache_write <alias> <ok|fail> <id> <context> <note> — atomic (a rename)
models_cache_write() {
  local dir tmp note
  dir="$(models_cache_dir)"
  /bin/mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$dir/.$1.$2.$$"
  note="$(printf '%s' "$5" | LC_ALL=C tr -c 'A-Za-z0-9 ._:/()+=,-' ' ' | cut -c1-160)"
  printf '%s|%s|%s|%s|%s|%s\n' "$2" "$3" "$(models_today)" "$(date +%s)" "$4" "$note" >"$tmp" 2>/dev/null &&
    /bin/mv -f "$tmp" "$dir/$1.$2" 2>/dev/null
}

# _models_config_value <key> — that key's value in the config file (the last line that sets it,
# read the way wolfmux_load_config reads it), or nothing
_models_config_value() {
  local file="${WOLFMUX_HOME:-$HOME/.config/wolfmux}/config" line key value found=""
  [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in \#* | "") continue ;; *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    key="${key//[[:space:]]/}"
    [ "$key" = "$1" ] || continue
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    found="${value%"${value##*[![:space:]]}"}"
  done <"$file"
  printf '%s\n' "$found"
}

# _models_time <epoch> — 07:12Z
_models_time() { date -u -r "$1" +%H:%MZ 2>/dev/null || printf '?'; }
# _models_ok_epoch <alias> — when the last probe that worked ran (0: never)
_models_ok_epoch() { if models_cache_read "$1" ok; then printf '%s\n' "$MC_EPOCH"; else printf '0\n'; fi; }

# models_alias_id <alias> — what the alias means right now, WITHOUT any network call.
# Sets MA_ID MA_CONTEXT MA_STATE MA_SOURCE:
#   pin       WOLFMUX_<ALIAS>_MODEL is set                      (either policy)
#   pinned    policy pinned: the built-in id
#   today     latest: validated by a probe today
#   stale     latest: validated on an earlier day; the next spawn of it probes again
#   fallback  latest: the last probe failed; the built-in id until one works
#   unprobed  latest: never probed on this machine; the built-in id until the first spawn
models_alias_id() {
  local alias="$1"
  models_builtin "$alias" || return 1
  models_pin_var "$alias"
  MA_CONTEXT="$MB_CONTEXT"
  if [ -n "$MODELS_PIN" ]; then
    MA_ID="$MODELS_PIN" MA_STATE="pin" MA_SOURCE="config pin ($MODELS_PIN_VAR)"
    # The environment outranks the config file, so a pin can also come from a shell, or from a
    # tmux server that took the config's values in when the team started: say so, because then
    # deleting the line from the config is not enough.
    if [ "$(_models_config_value "$MODELS_PIN_VAR")" != "$MODELS_PIN" ]; then
      MA_SOURCE="environment pin ($MODELS_PIN_VAR is set in this environment, not in the config file)"
    fi
    # Its window is known only when a probe answered for that very id, or it is the built-in one.
    if models_cache_read "$alias" ok && [ "$MC_ID" = "$MA_ID" ] && [ -n "$MC_CONTEXT" ]; then
      MA_CONTEXT="$MC_CONTEXT"
    elif [ "$MA_ID" != "$MB_ID" ]; then MA_CONTEXT=""; fi
    return 0
  fi
  if [ "$(models_policy)" = "pinned" ]; then
    MA_ID="$MB_ID" MA_STATE="pinned" MA_SOURCE="built-in (policy pinned)"
    return 0
  fi
  if models_cache_read "$alias" ok; then
    MA_ID="$MC_ID" MA_CONTEXT="${MC_CONTEXT:-$MB_CONTEXT}"
    if [ "$MC_DAY" = "$(models_today)" ]; then
      MA_STATE="today" MA_SOURCE="Claude Code, asked today $(_models_time "$MC_EPOCH")"
      return 0
    fi
    MA_STATE="stale" MA_SOURCE="Claude Code, asked $MC_DAY (the next spawn of $alias asks again)"
    # A newer failure outranks an older success: the id that worked then may be gone now.
    if models_cache_read "$alias" fail && [ "$MC_EPOCH" -ge "$(_models_ok_epoch "$alias")" ]; then
      MA_ID="$MB_ID" MA_CONTEXT="$MB_CONTEXT" MA_STATE="fallback"
      MA_SOURCE="fallback: asking Claude Code failed $MC_DAY $(_models_time "$MC_EPOCH"): $MC_NOTE"
    fi
    return 0
  fi
  MA_ID="$MB_ID"
  if models_cache_read "$alias" fail; then
    MA_STATE="fallback" MA_SOURCE="fallback: asking Claude Code failed $MC_DAY $(_models_time "$MC_EPOCH"): $MC_NOTE"
  else
    MA_STATE="unprobed" MA_SOURCE="built-in (not asked yet: the next spawn of $alias asks Claude Code)"
  fi
}

# models_alias_info <alias> — model_info's part for the four aliases: MODEL_ID, MODEL_LABEL,
# MODEL_CONTEXT, MODEL_SOURCE, from what is known without a network call.
models_alias_info() {
  models_alias_id "$1" || return 1
  models_label_of "$MA_ID"
  MODEL_ID="$MA_ID" MODEL_LABEL="$MODELS_LABEL" MODEL_CONTEXT="$MA_CONTEXT" MODEL_SOURCE="$MA_SOURCE"
}

# models_newest_known <alias> — sets MN_ID: the latest id of that family this machine knows
# of: the last validated probe answer or the built-in id, whichever is later. No network.
models_newest_known() {
  MN_ID=""
  models_builtin "$1" || return 1
  MN_ID="$MB_ID"
  if models_cache_read "$1" ok && models_newer "$MC_ID" "$MN_ID"; then MN_ID="$MC_ID"; fi
  return 0
}

# --- the probe -----------------------------------------------------------------------
# _models_run_bounded <seconds> <out> <err> <command...> — runs it with stdin closed, kills it
# when it outlives <seconds>. Returns its status, 124 on a timeout. (No `timeout` on macOS.)
_models_run_bounded() {
  local limit="$1" out="$2" err="$3" pid ticks=0
  shift 3
  "$@" </dev/null >"$out" 2>"$err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$((limit * 5))" ]; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.2
    ticks=$((ticks + 1))
  done
  wait "$pid"
}

# models_probe <alias> — asks Claude Code, through the subscription launcher (which scrubs every
# provider variable first), which model that alias means for this account. Sets PROBE_ID and
# PROBE_CONTEXT, or PROBE_ERROR and returns 1. tests point WOLFMUX_LAUNCHER_<ALIAS> at a stand-in.
models_probe() {
  local alias="$1" launcher work rc=0 rows id ctx served="" reason=""
  PROBE_ID="" PROBE_CONTEXT="" PROBE_ERROR=""
  launcher="$(launcher_path "$alias" 2>/dev/null)" || launcher=""
  if [ -z "$launcher" ] || [ ! -x "$launcher" ]; then
    PROBE_ERROR="launcher missing: ${launcher:-$alias}"
    return 1
  fi
  work="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-model-probe.XXXXXX")" || {
    PROBE_ERROR="no temporary directory"
    return 1
  }
  # In an empty directory, with every customisation off (no CLAUDE.md, hooks, plugins, MCP
  # servers or tools), nothing saved, and a one-line system prompt: the smallest call there is.
  (cd "$work" && _models_run_bounded "${WOLFMUX_MODEL_PROBE_TIMEOUT:-45}" "$work/out" "$work/err" \
    env -u WOLFMUX_EXTRA_SETTINGS "$launcher" -p --model "$alias" --output-format json \
    --no-session-persistence --safe-mode --strict-mcp-config --tools "" \
    --system-prompt "Reply with the word ok." "ok") || rc=$?
  rows="$("$JQ_BIN" -r 'select(type == "object" and .is_error != true) | (.modelUsage // {}) | to_entries[]
           | [.key, ((.value.contextWindow // "") | tostring)] | join("\u001f")' "$work/out" 2>/dev/null || true)"
  while IFS="$_MODELS_SEP" read -r id ctx; do
    [ -n "$id" ] || continue
    served="$served $id"
    valid_model_id "$id" || continue
    models_parse "$id" && [ "$MP_FAMILY" = "$alias" ] || continue
    if [ -z "$PROBE_ID" ] || models_newer "$id" "$PROBE_ID"; then
      PROBE_ID="$id"
      case "$ctx" in "" | *[!0123456789]*) PROBE_CONTEXT="" ;; *) PROBE_CONTEXT="$ctx" ;; esac
    fi
  done <<EOF
$rows
EOF
  if [ -z "$PROBE_ID" ]; then
    if [ "$rc" -eq 124 ]; then
      PROBE_ERROR="no answer within ${WOLFMUX_MODEL_PROBE_TIMEOUT:-45}s"
    elif [ -n "$served" ]; then
      PROBE_ERROR="Claude Code served${served} for $alias, not a $alias model"
    else
      reason="$("$JQ_BIN" -r 'select(type == "object") | .result // empty' "$work/out" 2>/dev/null | head -n 1 || true)"
      [ -n "$reason" ] || reason="$(grep -h -v '^[[:space:]]*$' "$work/err" "$work/out" 2>/dev/null | head -n 1 || true)"
      PROBE_ERROR="${reason:-exit $rc and no answer}"
    fi
  fi
  /bin/rm -rf "$work"
  [ -n "$PROBE_ID" ]
}

# models_refresh <alias> [force] — before an agent starts on an alias: probe it unless today's
# answer is cached, the alias is pinned, the policy is pinned, or a failure is too recent to
# retry. force (teamctl models --refresh) ignores today's answer and the retry window. Warns,
# on stderr, whenever the alias falls back to its built-in id. Never fails the caller.
models_refresh() {
  local alias="$1" force="${2:-}" retry="${WOLFMUX_MODEL_RETRY:-3600}" now
  models_is_alias "$alias" || return 0
  models_alias_id "$alias" || return 0
  case "$MA_STATE" in pin | pinned) return 0 ;; esac
  case "$retry" in "" | *[!0123456789]*) retry=3600 ;; esac
  if [ -z "$force" ]; then
    [ "$MA_STATE" != "today" ] || return 0
    now="$(date +%s)"
    if models_cache_read "$alias" fail && [ "$((now - MC_EPOCH))" -lt "$retry" ] && [ "$MC_EPOCH" -ge "$(_models_ok_epoch "$alias")" ]; then
      models_warn_fallback "$alias"
      return 0
    fi
  fi
  if models_probe "$alias"; then
    models_cache_write "$alias" ok "$PROBE_ID" "$PROBE_CONTEXT" "" || true
    /bin/rm -f "$(models_cache_dir)/$alias.fail"
  else
    models_cache_write "$alias" fail "" "" "$PROBE_ERROR" || true
  fi
  models_warn_fallback "$alias"
  return 0
}

# models_warn_fallback <alias> — the visible warning of a fallback, if there is one
models_warn_fallback() {
  models_alias_id "$1" || return 0
  [ "$MA_STATE" = "fallback" ] || return 0
  warn "$1: could not confirm the newest model ($MA_SOURCE). Using the built-in id $MA_ID instead. Check: teamctl models --refresh"
}

# --- which model an agent runs ---------------------------------------------------------
# models_transcript_model <session-id> <workdir> — prints the model of the last answer in that
# conversation's transcript (what was actually served), or nothing.
models_transcript_model() {
  local file
  [ -n "${1:-}" ] || return 0
  file="$(session_transcript "$1" "${2:-}" 2>/dev/null || true)"
  models_transcript_file_model "$file"
}

# models_transcript_file_model <transcript> — the same, for a transcript file already found
models_transcript_file_model() {
  [ -n "${1:-}" ] && [ -r "$1" ] || return 0
  tail -n 400 "$1" 2>/dev/null |
    "$JQ_BIN" -R -r 'fromjson? | select(.type == "assistant") | .message.model // empty | select(startswith("claude-"))' 2>/dev/null |
    tail -n 1 || true
}

# models_context_of_id <id> — the context window Claude Code declared for exactly that id (in a
# probe answer this machine kept, or in the built-in table), or nothing: an id no answer named
# has no known window, and a share of some other model's window would be a wrong number.
models_context_of_id() {
  local alias
  models_parse "$1" || return 0
  alias="$MP_FAMILY"
  models_is_alias "$alias" || return 0
  if models_cache_read "$alias" ok && [ "$MC_ID" = "$1" ] && [ -n "$MC_CONTEXT" ]; then
    printf '%s\n' "$MC_CONTEXT"
  elif models_builtin "$alias" && [ "$MB_ID" = "$1" ]; then
    printf '%s\n' "$MB_CONTEXT"
  fi
  return 0
}

# models_agent_rows <state-dir>... — one row (fields split by $_MODELS_SEP) per agent record of
# an alias model in those team state directories:
#   team role alias recorded-id state session-id workdir resolved-from
models_agent_rows() {
  local dir team file files
  for dir in "$@"; do
    [ -d "$dir/agents" ] || continue
    case "$dir" in */teams/*) team="${dir##*/teams/}" ;; *) team="$WOLFMUX_DEFAULT_TEAM" ;; esac
    files=()
    for file in "$dir"/agents/*.json; do [ -f "$file" ] && files+=("$file"); done
    [ "${#files[@]}" -gt 0 ] || continue
    "$JQ_BIN" -r --arg team "$team" --arg aliases " $WOLFMUX_MODEL_ALIASES " \
      'select((.model // "") as $m | $m != "" and ($aliases | contains(" " + $m + " "))) |
       [$team, .role, .model, (.model_id // ""), (.state // ""), (.session_id // ""), (.workdir // ""), (.model_source // "")]
       | join("\u001f")' "${files[@]}" 2>/dev/null || true
  done
}

# models_project_state_dirs <project-state> — the state directory of every team of a project
models_project_state_dirs() {
  local d
  [ -d "$1" ] || return 0
  printf '%s\n' "$1"
  for d in "$1"/teams/*/; do [ -d "$d" ] && printf '%s\n' "${d%/}"; done
  return 0
}

# models_drift <team> <role> <alias> <recorded-id> <session-id> <workdir>
# Sets MD_RUNNING (the id, or empty = unknown), MD_HOW (transcript / record / unknown),
# MD_NEWEST, MD_VERDICT (current / behind / unknown) and MD_RESTART (the command that moves it).
models_drift() {
  local seen
  MD_RUNNING="$4" MD_HOW="record"
  seen="$(models_transcript_model "$5" "$6")"
  if [ -n "$seen" ]; then
    # What was served outranks what was asked for: Claude Code falls back to an earlier model
    # at startup when the one asked for is not available.
    MD_RUNNING="$seen" MD_HOW="transcript"
  elif [ -z "$MD_RUNNING" ]; then
    MD_HOW="unknown"
  fi
  models_newest_known "$3" || MN_ID=""
  MD_NEWEST="$MN_ID"
  MD_RESTART="teamctl restart $2"
  if [ "$1" != "$WOLFMUX_DEFAULT_TEAM" ]; then MD_RESTART="$MD_RESTART --team $1"; fi
  MD_RESTART="$MD_RESTART --continue"
  if [ -z "$MD_RUNNING" ]; then
    MD_VERDICT="unknown"
  elif models_newer "$MD_NEWEST" "$MD_RUNNING"; then
    MD_VERDICT="behind"
  else
    MD_VERDICT="current"
  fi
}

# agent_label <role> — the label of an agent of the loaded team, from the id its record says
# it started with. A record of an alias written before ids were recorded says nothing about
# the version, so its label says so too ("Opus ?") rather than repeat the table it came from.
agent_label() {
  local model id
  model="$(reg_field "$1" model 2>/dev/null || true)"
  id="$(reg_field "$1" model_id 2>/dev/null || true)"
  if [ -n "$id" ] && { models_is_alias "$model" || [ "${model%%:*}" = "claude" ]; }; then
    models_label_of "$id"
    printf '%s\n' "$MODELS_LABEL"
  elif models_is_alias "$model"; then
    models_family_label "$model"
    printf '%s ?\n' "$MODELS_LABEL"
  else
    reg_field "$1" label 2>/dev/null || true
  fi
}

# --- teamctl models [--json] [--refresh] ------------------------------------------------
cmd_models() {
  local json=0 refresh=0 alias aliases="" agents="" root state_dir
  local team role model recorded state session workdir source label
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      --refresh) refresh=1 ;;
      *) die_usage "unknown option for models: $1 (teamctl models [--json] [--refresh])" ;;
    esac
    shift
  done
  [ -n "$JQ_BIN" ] || die "jq is required for models"
  if [ "$refresh" -eq 1 ]; then
    if [ "$(models_policy)" = "pinned" ]; then
      info "policy pinned: nothing is probed (WOLFMUX_MODEL_POLICY=latest probes)"
    else
      for alias in $WOLFMUX_MODEL_ALIASES; do
        models_pin_var "$alias"
        if [ -n "$MODELS_PIN" ]; then
          info "$alias: pinned by $MODELS_PIN_VAR, not probed"
          continue
        fi
        info "$alias: asking Claude Code which model it means ..."
        models_refresh "$alias" force
      done
    fi
  fi
  for alias in $WOLFMUX_MODEL_ALIASES; do
    models_alias_id "$alias" || continue
    models_label_of "$MA_ID"
    aliases="$aliases$("$JQ_BIN" -cn --arg alias "$alias" --arg id "$MA_ID" --arg label "$MODELS_LABEL" --arg state "$MA_STATE" \
      --arg source "$MA_SOURCE" --arg ctx "$MA_CONTEXT" \
      '{alias: $alias, id: $id, label: $label, state: $state, source: $source, context_window: ($ctx | tonumber? // null)}')
"
  done
  root="$(resolve_root 2>/dev/null || true)"
  if [ -n "$root" ]; then
    while IFS= read -r state_dir; do
      [ -n "$state_dir" ] || continue
      while IFS="$_MODELS_SEP" read -r team role model recorded state session workdir source; do
        [ -n "$role" ] && [ "$state" = "running" ] || continue
        models_drift "$team" "$role" "$model" "$recorded" "$session" "$workdir"
        if [ -n "$MD_RUNNING" ]; then
          models_label_of "$MD_RUNNING"
          label="$MODELS_LABEL"
        else
          models_family_label "$model"
          label="$MODELS_LABEL ?"
        fi
        agents="$agents$("$JQ_BIN" -cn --arg team "$team" --arg role "$role" --arg alias "$model" --arg recorded "$recorded" \
          --arg running "$MD_RUNNING" --arg how "$MD_HOW" --arg label "$label" --arg newest "$MD_NEWEST" \
          --arg verdict "$MD_VERDICT" --arg restart "$MD_RESTART" --arg source "$source" \
          '{team: $team, role: $role, alias: $alias, recorded_id: (if $recorded == "" then null else $recorded end),
            running_id: (if $running == "" then null else $running end), known_from: $how, label: $label,
            newest_known: $newest, verdict: $verdict, restart: $restart,
            resolved_from: (if $source == "" then null else $source end)}')
"
      done <<EOF
$(models_agent_rows "$state_dir")
EOF
    done <<EOF
$(models_project_state_dirs "$WOLFMUX_DATA/state/$(project_key "$root")")
EOF
  fi
  if [ "$json" -eq 1 ]; then
    printf '%s' "$aliases" | "$JQ_BIN" -s --arg policy "$(models_policy)" --argjson agents "$(printf '%s' "$agents" | "$JQ_BIN" -s '.')" \
      '{policy: $policy, aliases: ., agents: $agents}'
    return 0
  fi
  say "policy:  $(models_policy)   (WOLFMUX_MODEL_POLICY. latest: the newest model Claude Code serves you, probed at most once a day; pinned: the built-in ids)"
  say ""
  printf '  %-7s %-26s %-11s %s\n' ALIAS ID LABEL FROM
  printf '%s' "$aliases" | "$JQ_BIN" -r '[.alias, .id, .label, .source] | join("\u001f")' |
    while IFS="$_MODELS_SEP" read -r alias recorded label source; do
      printf '  %-7s %-26s %-11s %s\n' "$alias" "$recorded" "$label" "$source"
    done
  [ -n "$root" ] || return 0
  say ""
  if [ -z "$agents" ]; then
    say "agents:  none running on fable, opus, sonnet or haiku in this project"
    return 0
  fi
  say "agents running on fable, opus, sonnet or haiku in this project:"
  printf '  %-14s %-14s %-7s %-26s %-11s %-11s %s\n' TEAM ROLE ALIAS RUNNING LABEL "KNOWN FROM" "NEWER MODEL"
  printf '%s' "$agents" | "$JQ_BIN" -r '[.team, .role, .alias, (.running_id // "unknown"), .label, .known_from, .verdict, .newest_known, .restart] | join("\u001f")' |
    while IFS="$_MODELS_SEP" read -r team role model recorded label source state alias session; do
      case "$state" in
        behind) state="yes: $alias. Move it: $session" ;;
        unknown) state="unknown (started before this release). Record it: $session" ;;
        *) state="no" ;;
      esac
      printf '  %-14s %-14s %-7s %-26s %-11s %-11s %s\n' "$team" "$role" "$model" "$recorded" "$label" "$source" "$state"
    done
}

# --- teamctl _model-badge <root> <team> -------------------------------------------------
# The status bar's word on models, for the team of the session being drawn: how many of its
# running agents started on an older member of their family than the newest one this machine
# knows of, and how many started before ids were recorded. Reads records and the cache only:
# no network, no transcript, no ps. Prints NOTHING when there is nothing to say, or on any error.
cmd_model_badge() {
  local out
  out="$( (_model_badge_line "${1:-}" "${2:-}") 2>/dev/null | head -n 1 | LC_ALL=C tr -dc 'A-Za-z0-9 .:,+-' | cut -c1-48)" || return 0
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
}

_model_badge_line() {
  local root="$1" team="${2:-}" dir behind=0 unknown=0 t role alias id state rest
  [ -n "$team" ] || team="$WOLFMUX_DEFAULT_TEAM"
  [ -n "$root" ] && [ -d "$root" ] && [ -n "$JQ_BIN" ] || return 0
  valid_team_name "$team" || return 0
  dir="$WOLFMUX_DATA/state/$(project_key "$root")"
  if [ "$team" != "$WOLFMUX_DEFAULT_TEAM" ]; then dir="$dir/teams/$team"; fi
  while IFS="$_MODELS_SEP" read -r t role alias id state rest; do
    [ -n "$role" ] && [ "$state" = "running" ] || continue
    if [ -z "$id" ]; then
      unknown=$((unknown + 1))
    elif models_newest_known "$alias" && models_newer "$MN_ID" "$id"; then
      behind=$((behind + 1))
    fi
  done <<EOF
$(models_agent_rows "$dir")
EOF
  [ "$behind" -gt 0 ] || [ "$unknown" -gt 0 ] || return 0
  rest=""
  [ "$behind" -eq 0 ] || rest="$behind older"
  [ "$unknown" -eq 0 ] || rest="${rest:+$rest, }$unknown unknown"
  printf 'models: %s - teamctl models\n' "$rest"
}
