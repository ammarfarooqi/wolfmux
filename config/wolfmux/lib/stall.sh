#!/bin/bash
# lib/stall.sh: a stalled agent is reported to the lead (v1.25.0, ADR-0038, task wolfmux-lpi item 5).
#
# A turn of Claude Code that ends on an API error ("API Error: 529 Overloaded", a usage limit) or
# on the CLI's own "Autocompact is thrashing" stop leaves the agent idle with its task in progress,
# and NO hook fires in it: the error is an assistant row with isApiErrorMessage true (model
# <synthetic>), followed by turn_duration, and nothing else. 2026-11-16: a worker sat like that for
# over three hours and nobody was told. So something OUTSIDE the stalled agent has to look:
#
#   · the lead's wake waiter (cmd_inbox_wake), while the lead is idle: once per WOLFMUX_STALL_LOOK
#     seconds of its loop (a counter in the loop, no fork in between);
#   · the lead's own context watch on its tenth tool call (_memory_context_watch), while the lead
#     works: in the background, at most once per WOLFMUX_STALL_LOOK seconds;
#   · `teamctl status`, whoever runs it.
#
# What a look costs per agent on the books: one jq over its record and one stat of its transcript.
# Only a transcript quiet for WOLFMUX_STALL_AFTER seconds is read (its last 40 lines, one jq), and
# only one that ends on an error row costs a store query (is a task of it in progress?).
#
# What it cannot see: an agent stuck any other way (a hung tool, a dialog, a pane that died), a
# Codex agent (no such rows), the lead itself (nobody outside it to tell), and anything while no
# lead runs and nobody calls status. It never types into a pane and never restarts an agent: the
# lead is told once per error row, with the command that would go on.

WOLFMUX_STALL_AFTER="${WOLFMUX_STALL_AFTER:-300}"
WOLFMUX_STALL_LOOK="${WOLFMUX_STALL_LOOK:-60}"

_stall_number() { case "$1" in "" | *[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac; }

# stall_of <role> - 0 when the agent's conversation ended on an error row and has been quiet for
# WOLFMUX_STALL_AFTER seconds. Sets STALL_TEXT (the error's first line), STALL_AT (its timestamp,
# as the CLI wrote it) and STALL_IDLE (seconds since the transcript was last written).
stall_of() {
  local rec family state sid wd transcript written after row
  STALL_TEXT="" STALL_AT="" STALL_IDLE=0
  rec="$(reg_path "$1" 2>/dev/null)" || return 1
  [ -f "$rec" ] || return 1
  IFS=$'\037' read -r family state sid wd <<EOF
$("$JQ_BIN" -r '[.family // "claude", .state // "", .session_id // "", .workdir // ""] | join("\u001f")' "$rec" 2>/dev/null)
EOF
  [ "$family" = claude ] && [ "$state" = running ] && [ -n "$sid" ] || return 1
  transcript="$(session_transcript "$sid" "$wd" 2>/dev/null)" || return 1
  [ -n "$transcript" ] && [ -r "$transcript" ] || return 1
  written="$(stat -f %m "$transcript" 2>/dev/null || stat -c %Y "$transcript" 2>/dev/null || printf 0)"
  case "$written" in "" | *[!0-9]*) return 1 ;; esac
  after="$(_stall_number "$WOLFMUX_STALL_AFTER" 300)"
  STALL_IDLE=$(($(now_epoch) - written))
  [ "$STALL_IDLE" -ge "$after" ] || return 1
  # The last row that is about the conversation: the main thread's answers and prompts. A prompt
  # after the error (mail typed in, a human) means it went on; system rows (turn_duration) do not.
  row="$(/usr/bin/tail -n 40 "$transcript" 2>/dev/null | "$JQ_BIN" -R -r '
    fromjson? | objects | select(.isSidechain != true) |
    if .type == "assistant" then
      (if .isApiErrorMessage == true then
        "E\u001f" + (.timestamp // "") + "\u001f" + ([.message.content[]? | objects | .text? | strings] | join(" ") | split("\n")[0] | .[0:200])
      else "A" end)
    elif .type == "user" and .isMeta != true then "U"
    else empty end' 2>/dev/null | /usr/bin/tail -n 1)" || row=""
  case "$row" in E*) ;; *) return 1 ;; esac
  IFS=$'\037' read -r _ STALL_AT STALL_TEXT <<EOF
$row
EOF
  [ -n "$STALL_TEXT" ] || STALL_TEXT="(an API error row with no text)"
  return 0
}

# _stall_task <identity> - the id of a task of it in progress, or nothing
_stall_task() {
  store_tasks_json "$1" in_progress 2>/dev/null | "$JQ_BIN" -r '[.[] | select(.status == "in_progress")][0].id // empty' 2>/dev/null
}

# stall_tell <role> - after stall_of: ONE message to the lead per error row. The stamp directory
# is made with mkdir, the atomic test-and-set: two lookers at the same moment send one message.
stall_tell() {
  local role="$1" team identity lead task dir key since mins body
  team="${TEAM:-${WOLFMUX_TEAM:-$WOLFMUX_DEFAULT_TEAM}}"
  identity="$(team_identity "$team" "$role")"
  task="$(_stall_task "$identity")"
  [ -n "$task" ] || return 1
  dir="$STATE_DIR/stall"
  /bin/mkdir -p "$dir" 2>/dev/null || return 1
  key="$(printf '%s' "$STALL_AT" | /usr/bin/tr -cd '0-9')"
  [ -n "$key" ] || key="none"
  /bin/mkdir "$dir/$role.$key" 2>/dev/null || return 1
  since="${STALL_AT:-unknown}"
  mins=$((STALL_IDLE / 60))
  lead="$(team_identity "$team" "$WOLFMUX_LEAD_ROLE")"
  body="$role has stopped: its last turn ended on an error and it has been idle for $mins min, with task $task in progress. No hook fires in an agent after that, so nothing else will tell you.
error: $STALL_TEXT
since: $since
To go on: teamctl restart $role --continue
then:     teamctl send $role \"go on with $task\""
  memory_store_lead_message "$lead" "$identity" "$role: stalled on an error since $since" "$body" >/dev/null 2>&1 || {
    /bin/rmdir "$dir/$role.$key" 2>/dev/null || true
    return 1
  }
  event_log stall "$role" "reported to the lead: $STALL_TEXT (since $since, task $task)" 2>/dev/null || true
  return 0
}

# stall_scan - one look over the loaded team's agents (not the lead). Prints the roles it told
# the lead about, one per line. Never fails.
stall_scan() {
  local role
  [ -d "$STATE_DIR/agents" ] || return 0
  for role in $(reg_list 2>/dev/null); do
    [ "$role" = "$WOLFMUX_LEAD_ROLE" ] && continue
    stall_of "$role" || continue
    stall_tell "$role" && printf '%s\n' "$role"
  done
  return 0
}

# stall_scan_due - 0 at most once per WOLFMUX_STALL_LOOK seconds per team (a stamp file's time),
# for the lookers that run often: the lead's tenth tool call.
stall_scan_due() {
  local stamp="$STATE_DIR/stall/.looked" look last
  look="$(_stall_number "$WOLFMUX_STALL_LOOK" 60)"
  /bin/mkdir -p "$STATE_DIR/stall" 2>/dev/null || return 1
  last="$(stat -f %m "$stamp" 2>/dev/null || stat -c %Y "$stamp" 2>/dev/null || printf 0)"
  case "$last" in "" | *[!0-9]*) last=0 ;; esac
  [ $(($(now_epoch) - last)) -ge "$look" ] || return 1
  : >"$stamp" 2>/dev/null || return 1
  return 0
}
