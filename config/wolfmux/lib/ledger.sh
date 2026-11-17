#!/bin/bash
# ledger.sh — a lead that stays small (ADR-0040).
#
# Three things, each for the one conversation that cannot be thrown away, the lead's:
#
#   reports   $PROJECT_STATE/reports/<task-id>.md   the whole report `teamctl done` builds, kept as
#             a file beside the store (one place for both stores). The lead's mail names the path
#             and stays under WOLFMUX_REPORT_NOTICE_MAX characters. A task done again after a
#             reopen keeps its earlier reports as <task-id>.1.md, <task-id>.2.md (1 is the oldest).
#   decisions $STATE_DIR/decisions                  one line per decision the lead recorded with
#             `teamctl decide`: "<UTC time><TAB><text>". At most WOLFMUX_DECISIONS_MAX, oldest leave
#             first. A file on both stores, never beads or rows.
#   ledger    `teamctl ledger`                      the team's open work, what was done lately and
#             the decisions, generated from the store, at most WOLFMUX_LEDGER_MAX characters. The
#             lead's SessionStart after a compaction or a resume attaches it (ledger_hook).

WOLFMUX_REPORT_NOTICE_MAX=600  # characters of a Done report that reach the lead through its hooks
WOLFMUX_LEDGER_MAX=4000        # characters of `teamctl ledger`, and of what SessionStart attaches
WOLFMUX_DECISION_MAX=300       # characters of one decision
WOLFMUX_DECISIONS_MAX=30       # decisions kept
WOLFMUX_LEDGER_TITLE=60        # characters of a task title on a ledger line
WOLFMUX_LEDGER_DONE_HOURS=24   # done tasks of at least this many hours back are listed

# --- reports ------------------------------------------------------------------------------

# ledger_reports_dir — where the report files live; needs PROJECT_STATE (load_project or
# store_ensure_project)
ledger_reports_dir() { printf '%s/reports\n' "$PROJECT_STATE"; }

# ledger_report_path <task-id> — the newest report of that task (it may not exist)
ledger_report_path() { printf '%s/%s.md\n' "$(ledger_reports_dir)" "$1"; }

# ledger_report_save <task-id> <text> — writes the report, atomically. An earlier report of the
# same task moves to the first free <task-id>.<n>.md first, so nothing of it is lost. Prints the
# path. 1 when the directory cannot be written or the id is not one.
ledger_report_save() {
  local id="$1" text="$2" dir file n=1 tmp
  valid_bead_id "$id" || return 1
  dir="$(ledger_reports_dir)"
  /bin/mkdir -p "$dir" 2>/dev/null || return 1
  file="$dir/$id.md"
  if [ -e "$file" ]; then
    while [ -e "$dir/$id.$n.md" ]; do n=$((n + 1)); done
    /bin/mv -f "$file" "$dir/$id.$n.md" 2>/dev/null || return 1
  fi
  tmp="$file.tmp.$$"
  printf '%s\n' "$text" >"$tmp" 2>/dev/null || {
    /bin/rm -f "$tmp"
    return 1
  }
  /bin/mv -f "$tmp" "$file" 2>/dev/null || return 1
  printf '%s\n' "$file"
}

# ledger_report_older <task-id> — the earlier reports of that task, oldest first, one path a line
ledger_report_older() {
  local dir n=1
  dir="$(ledger_reports_dir)"
  while [ -e "$dir/$1.$n.md" ]; do
    printf '%s\n' "$dir/$1.$n.md"
    n=$((n + 1))
  done
}

# _ledger_cut <max> <text> — the text, or its first <max> characters followed by " [cut]"
# (the marker counts inside <max>). Characters, not bytes: bash substrings under a UTF-8 locale.
_ledger_cut() {
  local max="$1" text="$2"
  if [ "${#text}" -le "$max" ]; then
    printf '%s' "$text"
  elif [ "$max" -le 6 ]; then
    printf '%s' "${text:0:$max}"
  else
    printf '%s [cut]' "${text:0:$((max - 6))}"
  fi
}

# ledger_report_notice <task-id> <identity> <title> <summary> <tests-line> <branch> <sha> <stat-line> <path>
# — the text the lead gets for one `teamctl done`, the body of the "Done:" message. Together with
# the "[wolfmux mail] " _mail_render_bead puts before it, at most WOLFMUX_REPORT_NOTICE_MAX
# characters: every fixed line is capped first, and the summary gets what is left, cut with a
# marker that names where the rest is.
ledger_report_notice() {
  local id="$1" who="$2" title="$3" summary="$4" tests="$5" branch="$6" sha="$7" stat="$8" path="$9"
  local head tail room
  title="$(_hook_title "$title")"
  head="DONE $id by $(_ledger_cut 60 "$who"): $(_ledger_cut "$WOLFMUX_LEDGER_TITLE" "$title")"
  tail="$(_ledger_cut 120 "$(printf '%s' "$tests" | LC_ALL=C tr '\n\r\t' '   ')")
branch: $(_ledger_cut 80 "$branch") at ${sha:-?}"
  [ -z "$stat" ] || tail="$tail
$(_ledger_cut 90 "${stat# }")"
  tail="$tail
full report: $(_ledger_cut 140 "$path")
read it: teamctl show $id --report
This item is already marked read and needs no reply."
  # 15 = "[wolfmux mail] ", 2 = the newlines around the summary
  room=$((WOLFMUX_REPORT_NOTICE_MAX - 15 - ${#head} - ${#tail} - 2))
  [ "$room" -ge 20 ] || room=20
  summary="$(printf '%s' "$summary" | LC_ALL=C /usr/bin/tr -d '\000-\010\013-\037\177')"
  if [ "${#summary}" -gt "$room" ]; then
    summary="${summary:0:$((room - 34))} [cut: the rest is in the report]"
  fi
  printf '%s\n%s\n%s' "$head" "$summary" "$tail"
}

# --- decisions ----------------------------------------------------------------------------

ledger_decisions_file() { printf '%s/decisions\n' "$STATE_DIR"; }

# _ledger_decisions_write <content> — the whole file, atomically; "" removes every decision
_ledger_decisions_write() {
  local file tmp
  file="$(ledger_decisions_file)"
  /bin/mkdir -p "${file%/*}" 2>/dev/null || return 1
  tmp="$file.tmp.$$"
  if [ -n "$1" ]; then printf '%s\n' "$1" >"$tmp" 2>/dev/null; else : >"$tmp" 2>/dev/null; fi || {
    /bin/rm -f "$tmp"
    return 1
  }
  /bin/mv -f "$tmp" "$file"
}

# ledger_decisions_text — "1. <date> <text>" per decision, oldest first (newest last)
ledger_decisions_text() {
  local file
  file="$(ledger_decisions_file)"
  [ -s "$file" ] || return 0
  /usr/bin/awk -F'\t' 'NF >= 2 { n++; t = $2; for (i = 3; i <= NF; i++) t = t " " $i; printf "%d. %s %s\n", n, substr($1, 1, 10), t }' "$file"
}

# teamctl decide "<text>" | --list | --drop <n> — the lead's decisions, kept for the ledger
cmd_decide() {
  local mode="add" text="" drop="" file kept count
  case "${1:-}" in
    --list)
      [ "$#" -eq 1 ] || die_usage 'usage: teamctl decide "<text>" | --list | --drop <n>'
      mode="list"
      ;;
    --drop)
      [ "$#" -eq 2 ] || die_usage 'usage: teamctl decide --drop <n>'
      drop="$2"
      case "$drop" in '' | *[!0-9]* | 0*) die_usage "--drop needs the number of a decision, as teamctl decide --list shows it" ;; esac
      mode="drop"
      ;;
    -*) die_usage "unknown option for decide: $1" ;;
    *)
      [ "$#" -eq 1 ] || die_usage 'usage: teamctl decide "<text>"   (one argument: quote the text)'
      text="$(printf '%s' "$1" | LC_ALL=C tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\010\013-\037\177')"
      text="$(printf '%s' "$text" | /usr/bin/sed -e 's/^ *//' -e 's/ *$//')"
      [ -n "$text" ] || die_usage 'a decision cannot be empty: teamctl decide "<text>"'
      [ "${#text}" -le "$WOLFMUX_DECISION_MAX" ] ||
        die_usage "a decision is at most $WOLFMUX_DECISION_MAX characters (this one has ${#text}); say it shorter, and put the detail in a task note"
      ;;
  esac
  require_tools
  load_project
  file="$(ledger_decisions_file)"
  if [ "$mode" = "list" ]; then
    kept="$(ledger_decisions_text)"
    if [ -n "$kept" ]; then say "$kept"; else say "no decisions recorded"; fi
    return 0
  fi
  require_manager decide
  if [ "$mode" = "drop" ]; then
    count="$(/usr/bin/awk 'NF' "$file" 2>/dev/null | /usr/bin/wc -l | tr -d ' ')"
    [ "$drop" -le "${count:-0}" ] || die "no decision $drop; there are ${count:-0}: teamctl decide --list"
    kept="$(/usr/bin/awk -v n="$drop" 'NF { i++; if (i != n) print }' "$file")"
    _ledger_decisions_write "$kept" || die "could not write $(short_path "$file")"
    say "dropped decision $drop"
    return 0
  fi
  kept="$(/usr/bin/awk 'NF' "$file" 2>/dev/null)"
  kept="${kept:+$kept
}$(now_iso)	$text"
  # at most WOLFMUX_DECISIONS_MAX: the oldest leave first
  kept="$(printf '%s\n' "$kept" | /usr/bin/tail -n "$WOLFMUX_DECISIONS_MAX")"
  _ledger_decisions_write "$kept" || die "could not write $(short_path "$file")"
  count="$(printf '%s\n' "$kept" | /usr/bin/wc -l | tr -d ' ')"
  say "decision $count recorded"
}

# --- the ledger ---------------------------------------------------------------------------

# _ledger_team_rows <rows-json> — only the tasks of the loaded team: the default team's are those
# whose assignee has no team prefix, a named team's those that start with "<team>." (as
# `teamctl tasks` shows them)
_ledger_team_rows() {
  printf '%s' "${1:-[]}" | "$JQ_BIN" -c --arg t "$TEAM" --arg d "$WOLFMUX_DEFAULT_TEAM" '
    [.[] | select(
      (($t == $d) and (((.assignee // "") | test("\\.")) | not)) or
      (($t != $d) and ((.assignee // "") | startswith($t + ".")))
    )]'
}

# _ledger_began_file — where the lead's SessionStart wrote when its conversation began
_ledger_began_file() { printf '%s/run/%s/ledger-began\n' "$STATE_DIR" "$WOLFMUX_LEAD_ROLE"; }

# _ledger_cutoff — the epoch from which done tasks are listed: the start of the lead's
# conversation or 24 hours back, whichever is earlier (so more is listed)
_ledger_cutoff() {
  local now began=""
  now="$(now_epoch)"
  now=$((now - WOLFMUX_LEDGER_DONE_HOURS * 3600))
  if [ -r "$(_ledger_began_file)" ]; then IFS= read -r began <"$(_ledger_began_file)" || true; fi
  case "$began" in '' | *[!0-9]*) began="$now" ;; esac
  [ "$began" -lt "$now" ] || began="$now"
  printf '%s\n' "$began"
}

# _ledger_lines <budget> <more-text> — stdin lines while they fit in <budget> characters; the
# lines that do not fit become one "(N more: <more-text>)" line, which the budget allows for.
# <keep>: "first" keeps the first lines, "last" the last ones (decisions: the newest).
_ledger_lines() {
  local budget="$1" more="$2" keep="${3:-first}" lines=() line out="" used=0 n=0 total i
  while IFS= read -r line; do lines+=("$line"); done
  total="${#lines[@]}"
  [ "$total" -gt 0 ] || return 0
  budget=$((budget - ${#more} - 16))
  if [ "$keep" = "last" ]; then
    i=$((total - 1))
    while [ "$i" -ge 0 ]; do
      line="${lines[$i]}"
      [ $((used + ${#line} + 1)) -le "$budget" ] || break
      out="$line${out:+
$out}"
      used=$((used + ${#line} + 1))
      n=$((n + 1))
      i=$((i - 1))
    done
    [ "$n" -eq "$total" ] || out="($((total - n)) older: $more)${out:+
$out}"
  else
    for line in "${lines[@]}"; do
      [ $((used + ${#line} + 1)) -le "$budget" ] || break
      out="${out:+$out
}$line"
      used=$((used + ${#line} + 1))
      n=$((n + 1))
    done
    [ "$n" -eq "$total" ] || out="${out:+$out
}($((total - n)) more: $more)"
  fi
  printf '%s\n' "$out"
}

# ledger_text <all-tasks-json> — the ledger of the loaded team (TEAM, STATE_DIR, PROJECT_STATE),
# at most WOLFMUX_LEDGER_MAX characters. Empty when there is nothing in it at all.
ledger_text() {
  local rows="$1" cutoff open done_rows decisions open_t done_t dec_t head budget open_b done_b dec_b out
  rows="$(_ledger_team_rows "$rows")" || rows="[]"
  cutoff="$(_ledger_cutoff)"
  open="$(printf '%s' "$rows" | "$JQ_BIN" -r --argjson w "$WOLFMUX_LEDGER_TITLE" '
    .[] | select(.status != "closed")
    | "\(.id) \(if ((.blocked_by // []) | length) > 0 then "waiting" else .status end) \(.assignee // "-") \((.title // "") | gsub("[\\n\\r\\t]"; " ") | if length > $w then .[0:$w] + "..." else . end)"' 2>/dev/null)"
  done_rows="$(printf '%s' "$rows" | "$JQ_BIN" -r --argjson cut "$cutoff" '
    def epoch: (tostring | capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")) as $c
      | (($c.d + "Z") | fromdateiso8601)
        - (if ($c.z // "Z") == "Z" then 0
           else ($c.z | gsub(":"; "")) as $o
             | (if $o[0:1] == "-" then -1 else 1 end) * (($o[1:3] | tonumber) * 3600 + ($o[3:5] | tonumber) * 60) end);
    [.[] | select(.status == "closed") | . + {_at: ((.updated_at // "") | try epoch catch 0)} | select(._at >= $cut)]
    | sort_by(._at) | .[] | "\(.id) \(.assignee // "-")"' 2>/dev/null)"
  decisions="$(ledger_decisions_text)"
  [ -n "$open" ] || [ -n "$done_rows" ] || [ -n "$decisions" ] || return 0
  # the report path of each done task, or "no report" (a task closed by `teamctl close`)
  if [ -n "$done_rows" ]; then
    done_rows="$(printf '%s\n' "$done_rows" | while IFS=' ' read -r id who; do
      if [ -e "$(ledger_report_path "$id")" ]; then
        printf '%s %s report: %s\n' "$id" "$who" "$(ledger_report_path "$id")"
      else
        printf '%s %s (no report)\n' "$id" "$who"
      fi
    done)"
  fi
  head="[wolfmux ledger] team $TEAM, from the store at $(now_iso). Full detail: teamctl tasks, teamctl show <id> --report, teamctl decide --list."
  open_t="open and in progress:"
  done_t="done since $(/bin/date -u -r "$cutoff" +%Y-%m-%dT%H:%MZ 2>/dev/null):"
  dec_t="decisions (oldest first):"
  # Room: the header and the three section titles first. Decisions may take up to a third of
  # what is left, done tasks a quarter, open work the rest (and whatever the others leave).
  budget=$((WOLFMUX_LEDGER_MAX - ${#head} - ${#open_t} - ${#done_t} - ${#dec_t} - 12))
  dec_b=$((budget / 3))
  [ "${#decisions}" -ge "$dec_b" ] || dec_b="${#decisions}"
  done_b=$((budget / 4))
  [ "${#done_rows}" -ge "$done_b" ] || done_b="${#done_rows}"
  open_b=$((budget - dec_b - done_b))
  open="$(printf '%s\n' "$open" | /usr/bin/awk 'NF' | _ledger_lines "$open_b" "teamctl tasks")"
  done_b=$((budget - dec_b - ${#open}))
  done_rows="$(printf '%s\n' "$done_rows" | /usr/bin/awk 'NF' | _ledger_lines "$done_b" "teamctl tasks --status closed")"
  dec_b=$((budget - ${#open} - ${#done_rows}))
  decisions="$(printf '%s\n' "$decisions" | /usr/bin/awk 'NF' | _ledger_lines "$dec_b" "teamctl decide --list" last)"
  out="$head
$open_t
${open:-(none)}
$done_t
${done_rows:-(none)}
$dec_t
${decisions:-(none)}"
  # the budget above already keeps it inside; this is the backstop
  printf '%s\n' "$out" | _hook_cap "$WOLFMUX_LEDGER_MAX"
}

# teamctl ledger — the team's ledger, as the lead's SessionStart attaches it after a compaction
cmd_ledger() {
  local rows text
  [ "$#" -eq 0 ] || die_usage "usage: teamctl ledger"
  require_tools
  load_project
  rows="$(store_tasks_json "" "")" || die "could not read the store"
  text="$(ledger_text "$rows")"
  if [ -n "$text" ]; then say "$text"; else say "the ledger is empty: no open task, nothing done in the last ${WOLFMUX_LEDGER_DONE_HOURS}h, no decision"; fi
}

# --- the lead's SessionStart ----------------------------------------------------------------

# _ledger_hook_team — TEAM, STATE_DIR and PROJECT_STATE from the run directory, without the tmux
# call load_project would make. STATE_DIR is $PROJECT_STATE or $PROJECT_STATE/teams/<team>.
_ledger_hook_team() {
  STATE_DIR="${HOOK_RUN%/run/*}"
  case "$STATE_DIR" in
    */teams/*)
      TEAM="${STATE_DIR##*/teams/}"
      PROJECT_STATE="${STATE_DIR%/teams/*}"
      ;;
    *)
      TEAM="$WOLFMUX_DEFAULT_TEAM"
      PROJECT_STATE="$STATE_DIR"
      ;;
  esac
  valid_team_name "$TEAM"
}

# ledger_session_start — the lead's part of SessionStart (ADR-0040): a new conversation records
# when it began; one that was compacted or resumed gets the ledger back. Never a worker, never at
# a fresh start, never with nothing in it. One Beads read, inside the hook run's one budget.
ledger_session_start() {
  local rows text
  [ "$HOOK_ROLE" = "$WOLFMUX_LEAD_ROLE" ] || return 0
  _ledger_hook_team || return 0
  case "$HOOK_SOURCE" in
    startup | clear)
      now_epoch >"$HOOK_RUN/ledger-began" 2>/dev/null || true
      return 0
      ;;
    compact | resume) ;;
    *) return 0 ;;
  esac
  case "$(store_kind)" in
    beads) rows="$(_bd_bounded 5 store_tasks_json "" "")" || rows="" ;;
    *) rows="$(store_tasks_json "" "")" || rows="" ;;
  esac
  if ! printf '%s' "$rows" | "$JQ_BIN" -e 'type == "array"' >/dev/null 2>&1; then
    hook_context "[wolfmux ledger] the store did not answer in time, so the ledger is not shown here. Read it now: teamctl ledger"
    return 0
  fi
  text="$(ledger_text "$rows")"
  [ -z "$text" ] || hook_context "$text"
}

# ledger_hook <Event> — the contract is lib/hooks.sh's header
ledger_hook() {
  case "$1" in
    SessionStart) ledger_session_start ;;
  esac
}
