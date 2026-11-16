#!/bin/bash
# registry.sh — the agent registry: which role runs which model in which worktree.
#
# This is the ONLY module that touches teamctl's state files. It stores process
# and worktree facts, nothing else — tasks and messages live in Beads (bd).
# Every command goes through the functions below, so the JSON-file backend can
# be swapped (e.g. for SQLite) without changing a single command.
#
#   $STATE_DIR/meta.json            project root, tmux session, lead model
#   $STATE_DIR/agents/<role>.json   one record per agent
#   $STATE_DIR/events.jsonl         append-only lifecycle log
#   $STATE_DIR/nudge/<role>         epoch of the last pane notification
#   $STATE_DIR/run/<role>/          the agent's mail, memory and turn state (lib/hooks.sh owns the layout)

_reg_write_atomic() {
  local path="$1" tmp
  tmp="$path.tmp.$$"
  /bin/cat >"$tmp"
  /bin/mv -f "$tmp" "$path"
}

reg_path() { printf '%s/agents/%s.json\n' "$STATE_DIR" "$1"; }

reg_exists() { [ -f "$(reg_path "$1")" ]; }

# reg_put <role> — record JSON on stdin
reg_put() {
  local role="$1" json
  json="$(/bin/cat)"
  printf '%s\n' "$json" | "$JQ_BIN" -e . >/dev/null 2>&1 || die "refusing to store invalid agent record for '$role'"
  printf '%s\n' "$json" | "$JQ_BIN" . | _reg_write_atomic "$(reg_path "$role")"
}

reg_get() {
  reg_exists "$1" || return 1
  /bin/cat "$(reg_path "$1")"
}

# reg_field <role> <field> — prints the value, empty when absent
reg_field() {
  reg_exists "$1" || return 1
  "$JQ_BIN" -r --arg f "$2" '.[$f] // empty' "$(reg_path "$1")"
}

# reg_set <role> <field> <value> [<field> <value> ...] — string fields
reg_set() {
  local role="$1" record
  shift
  record="$(reg_get "$role")" || die "no such agent: $role"
  while [ "$#" -ge 2 ]; do
    record="$(printf '%s' "$record" | "$JQ_BIN" --arg f "$1" --arg v "$2" '.[$f] = $v')"
    shift 2
  done
  printf '%s' "$record" | "$JQ_BIN" --arg t "$(now_iso)" '.updated_at = $t' | reg_put "$role"
}

# reg_list — role names, lead first, then creation order
reg_list() {
  local file
  [ -d "$STATE_DIR/agents" ] || return 0
  for file in "$STATE_DIR"/agents/*.json; do
    [ -f "$file" ] || continue
    "$JQ_BIN" -r '[(if .kind == "lead" then 0 else 1 end), .created_at, .role] | @tsv' "$file"
  done | sort | cut -f3
}

# An agent that is taken off the books leaves nothing: its record, its notification stamp, and its
# run directory (mail, memory, turn state: lib/hooks.sh). The role was validated when it was recorded.
reg_delete() {
  /bin/rm -f "$(reg_path "$1")" "$STATE_DIR/nudge/$1"
  case "$1" in "" | *[/.]*) return 0 ;; esac
  /bin/rm -rf "$STATE_DIR/run/$1"
}

meta_get() {
  [ -f "$STATE_DIR/meta.json" ] || return 1
  "$JQ_BIN" -r --arg f "$1" '.[$f] // empty' "$STATE_DIR/meta.json"
}

# meta_put <field> <value> [...]
meta_put() {
  local record="{}"
  [ -f "$STATE_DIR/meta.json" ] && record="$(/bin/cat "$STATE_DIR/meta.json")"
  while [ "$#" -ge 2 ]; do
    record="$(printf '%s' "$record" | "$JQ_BIN" --arg f "$1" --arg v "$2" '.[$f] = $v')"
    shift 2
  done
  printf '%s\n' "$record" | "$JQ_BIN" . | _reg_write_atomic "$STATE_DIR/meta.json"
}

# event_log <type> <role> [detail]: one small O_APPEND write per event. by: the agent's role, or
# EVENT_BY when an agent acts on a team that is not its own (a founder: its Beads identity, so that
# "lead" in the log is never taken for the lead of the team it acted on), "operator" for you.
event_log() {
  [ -d "$STATE_DIR" ] || return 0
  "$JQ_BIN" -cn --arg ts "$(now_iso)" --arg type "$1" --arg role "${2:-}" --arg detail "${3:-}" \
    --arg by "${EVENT_BY:-${TEAM_ROLE:-operator}}" '{ts: $ts, type: $type, role: $role, by: $by, detail: $detail}' \
    >>"$STATE_DIR/events.jsonl"
}

# --- nudge bookkeeping ---------------------------------------------------------
# One logical Beads change can fire several hooks at once (create + update), so
# a per-role guard makes check-debounce-send-mark a single critical section.
NUDGE_STALE_SECONDS=15

nudge_last() {
  if [ -f "$STATE_DIR/nudge/$1" ]; then /bin/cat "$STATE_DIR/nudge/$1"; else printf '0\n'; fi
}
nudge_mark() { now_epoch >"$STATE_DIR/nudge/$1"; }

# nudge_begin <role> — 0 when this process may notify the role now
nudge_begin() {
  local guard="$STATE_DIR/nudge/$1.lock" started
  /bin/mkdir -p "$STATE_DIR/nudge"
  if ! /bin/mkdir "$guard" 2>/dev/null; then
    started="$(/bin/cat "$guard/ts" 2>/dev/null || printf '0')"
    [ $(($(now_epoch) - started)) -gt "$NUDGE_STALE_SECONDS" ] || return 1
    /bin/rm -rf "$guard"
    /bin/mkdir "$guard" 2>/dev/null || return 1
  fi
  now_epoch >"$guard/ts"
}
nudge_end() { /bin/rm -rf "$STATE_DIR/nudge/$1.lock"; }

# --- deferred notices ----------------------------------------------------------
# A pane a human may be typing in is never typed into (tm_pane_human_busy). The
# notice is parked in a per-role marker instead, and ONE detached waiter per role
# delivers it as soon as the pane is idle. Beads nudges collapse into a single line,
# because that line always ends with the full inbox command; fixed notices (spawn,
# approval, policy) each name a different event, so they queue.
#
# The marker is a directory, created with the same atomic mkdir as nudge_begin:
#   ts     when it was claimed        beat   the waiter's heartbeat
#   bead   the newest bead id         mixed  present once two ids collapsed
#   lines  queued fixed notices, one per line
NUDGE_PENDING_SLACK_SECONDS=15
NUDGE_PENDING_MAX_LINES=20

# _nudge_num <file> — the number in a marker file; 0 when missing or damaged
_nudge_num() {
  local value
  value="$(/bin/cat "$1" 2>/dev/null || printf '0')"
  case "$value" in "" | *[!0-9]*) value=0 ;; esac
  printf '%s\n' "$value"
}

nudge_pending_exists() { [ -d "$STATE_DIR/nudge/$1.pending" ]; }
nudge_pending_clear() { /bin/rm -rf "$STATE_DIR/nudge/$1.pending"; }
nudge_pending_beat() { now_epoch >"$STATE_DIR/nudge/$1.pending/beat" 2>/dev/null || true; }

# nudge_pending_stale <role> — 0 when the marker may be taken over: its waiter
# stopped beating, or the marker outlived the longest wait a waiter can run for.
nudge_pending_stale() {
  local marker="$STATE_DIR/nudge/$1.pending" now gap cap
  now="$(now_epoch)"
  cap="$(nudge_pending_cap "$1" "${WOLFMUX_NUDGE_DEFER_MAX:-600}")"
  case "$cap" in "" | *[!0-9]*) cap=600 ;; esac
  if [ $((now - $(_nudge_num "$marker/ts"))) -gt $((cap + NUDGE_PENDING_SLACK_SECONDS)) ]; then return 0; fi
  gap=$((${WOLFMUX_NUDGE_RETRY:-3} * 3))
  if [ "$gap" -lt "$NUDGE_PENDING_SLACK_SECONDS" ]; then gap="$NUDGE_PENDING_SLACK_SECONDS"; fi
  [ $((now - $(_nudge_num "$marker/beat"))) -gt "$gap" ]
}

# nudge_pending_open <role> — 0 when this process is now the role's one waiter.
#
# Usually called while holding nudge_begin <role>. notify_lead's no-lock path is the
# exception: when the lock could not be taken in 30 tries it parks the notice rather
# than typing it, and parking means coming through here without the lock. That is safe
# without being tidy — mkdir is atomic, so of two processes exactly one gets the marker
# and the loser takes the exists branch, leaving one waiter either way. What that path
# does lose is the reap: nudge_pending_reap only runs under the lock, so a stale marker
# is not cleared there and the notice joins it instead. The next locked notice reaps it.
nudge_pending_open() {
  local marker="$STATE_DIR/nudge/$1.pending"
  /bin/mkdir -p "$STATE_DIR/nudge"
  if ! /bin/mkdir "$marker" 2>/dev/null; then
    nudge_pending_stale "$1" || return 1
    /bin/rm -rf "$marker"
    /bin/mkdir "$marker" 2>/dev/null || return 1
  fi
  now_epoch >"$marker/ts"
  now_epoch >"$marker/beat"
}

# nudge_pending_reap <role> — 0 when a marker with no waiter behind it was removed.
# A waiter can die (a closed terminal, a reboot, a kill), and the marker it leaves
# would otherwise swallow every later notice for that role: the exists path would park
# a bead into it forever and nobody would ever deliver. Both call sites reap before
# they look, while holding nudge_begin, so no live waiter is ever taken out from under.
nudge_pending_reap() {
  nudge_pending_exists "$1" || return 1
  nudge_pending_stale "$1" || return 1
  nudge_pending_clear "$1"
}

# nudge_pending_put_bead <role> <bead> — the collapsible slot: the newest bead id
# wins, and two different ids mean the generic line that points at the whole inbox.
#
# An empty bead id (a nudge with no --id) counts as different from a real one, so a
# bare nudge followed by one with --id also collapses to the generic line. Pessimistic
# in the safe direction: the generic line names the whole inbox, which covers both.
nudge_pending_put_bead() {
  local marker="$STATE_DIR/nudge/$1.pending" prev
  [ -d "$marker" ] || return 1
  if [ -f "$marker/bead" ]; then
    prev="$(/bin/cat "$marker/bead" 2>/dev/null || true)"
    if [ "${2:-}" != "$prev" ]; then : >"$marker/mixed"; fi
  fi
  printf '%s\n' "${2:-}" >"$marker/bead"
}

nudge_pending_has_bead() { [ -f "$STATE_DIR/nudge/$1.pending/bead" ]; }

# nudge_pending_bead <role> — the bead id to name, or nothing when several collapsed
nudge_pending_bead() {
  local marker="$STATE_DIR/nudge/$1.pending"
  if [ -f "$marker/mixed" ]; then return 0; fi
  /bin/cat "$marker/bead" 2>/dev/null || true
}

# nudge_pending_put_line <role> <text> — a fixed notice names its own event, so it
# queues. Bounded, so a caller in a loop can never grow the file without end.
nudge_pending_put_line() {
  local marker="$STATE_DIR/nudge/$1.pending" held=0
  [ -d "$marker" ] || return 1
  # The < redirect is the shell's, so a missing file prints ITS error, which 2>/dev/null
  # on wc never catches: that reached a user's terminal and an agent's hook stderr.
  if [ -f "$marker/lines" ]; then
    held="$(/usr/bin/wc -l <"$marker/lines" | /usr/bin/tr -d ' ')"
    case "$held" in "" | *[!0-9]*) held=0 ;; esac
  fi
  if [ "$held" -ge "$NUDGE_PENDING_MAX_LINES" ]; then return 0; fi
  printf '%s\n' "$2" >>"$marker/lines"
}

nudge_pending_has_lines() { [ -s "$STATE_DIR/nudge/$1.pending/lines" ]; }

# nudge_pending_shift_line <role> — print the first queued line AND take it out of the
# marker. Delivered lines must leave the marker as they go: a waiter that stops part
# way, or is killed mid-delivery, must never re-send what already went out.
# An empty line is not a notice, so it is dropped and the next one looked at, rather
# than taken out and reported as "nothing left": that would stop the caller's delivery
# loop with real notices still queued behind the blank. Bounded by the size of the file
# itself, so a shift that cannot write can never spin here.
nudge_pending_shift_line() {
  local marker="$STATE_DIR/nudge/$1.pending" first tries=0
  while [ "$tries" -le "$NUDGE_PENDING_MAX_LINES" ]; do
    tries=$((tries + 1))
    [ -s "$marker/lines" ] || return 1
    first="$(/usr/bin/head -1 "$marker/lines")"
    if /usr/bin/tail -n +2 "$marker/lines" >"$marker/lines.next" 2>/dev/null; then
      /bin/mv -f "$marker/lines.next" "$marker/lines"
    else
      /bin/rm -f "$marker/lines.next"
    fi
    [ -s "$marker/lines" ] || /bin/rm -f "$marker/lines"
    if [ -n "$first" ]; then
      printf '%s\n' "$first"
      return 0
    fi
  done
  return 1
}

# nudge_pending_put_cap <role> <seconds> — lower how long this marker's waiter may wait,
# never raise it. An approval notice is useless once the worker has stopped waiting for
# the decision, so it asks for a short cap; the most urgent notice in the marker wins.
nudge_pending_put_cap() {
  local marker="$STATE_DIR/nudge/$1.pending" held
  [ -d "$marker" ] || return 1
  case "${2:-}" in "" | *[!0-9]*) return 0 ;; esac
  if [ -f "$marker/cap" ]; then
    held="$(_nudge_num "$marker/cap")"
    if [ "$held" -gt 0 ] && [ "$held" -le "$2" ]; then return 0; fi
  fi
  printf '%s\n' "$2" >"$marker/cap"
}

# nudge_pending_cap <role> <fallback> — the marker's cap, or the fallback
nudge_pending_cap() {
  local held
  held="$(_nudge_num "$STATE_DIR/nudge/$1.pending/cap")"
  if [ "$held" -gt 0 ]; then printf '%s\n' "$held"; else printf '%s\n' "$2"; fi
}

# nudge_pending_put_idle <role> <seconds> — how long the pane must have had no keystroke
# before this marker's waiter may type into it (tm_pane_human_busy's check (a)). RAISE
# only, never lower, which is the opposite of the cap and for the same reason: the cap
# bounds how long a notice is worth waiting for, so the most urgent notice wins, while
# this bounds how quiet the pane must be, so the most CAUTIOUS notice wins. One marker
# per role holds notices from several paths; a notice parked for the human's own
# conversation may not be delivered later under a worker's five-second rule.
nudge_pending_put_idle() {
  local marker="$STATE_DIR/nudge/$1.pending" held
  [ -d "$marker" ] || return 1
  case "${2:-}" in "" | *[!0-9]*) return 0 ;; esac
  if [ -f "$marker/idle" ]; then
    held="$(_nudge_num "$marker/idle")"
    if [ "$held" -ge "$2" ]; then return 0; fi
  fi
  printf '%s\n' "$2" >"$marker/idle"
}

# nudge_pending_idle <role> <fallback> — the marker's idle window, or the fallback
nudge_pending_idle() {
  local held
  held="$(_nudge_num "$STATE_DIR/nudge/$1.pending/idle")"
  if [ "$held" -gt 0 ]; then printf '%s\n' "$held"; else printf '%s\n' "$2"; fi
}

# --- project lock: serializes spawn / stop / restart / destroy ------------------
# mkdir is atomic on every POSIX filesystem; macOS ships no flock(1).
LOCK_HELD=""

lock_acquire() {
  local lock="$STATE_DIR/.lock" waited=0 holder
  while ! /bin/mkdir "$lock" 2>/dev/null; do
    holder="$(/bin/cat "$lock/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      /bin/rm -rf "$lock" # holder died without releasing
      continue
    fi
    # No pid after two seconds: the holder died between mkdir and writing it.
    # (A live holder writes its pid within microseconds of the mkdir.)
    if [ -z "$holder" ] && [ "$waited" -ge 10 ]; then
      /bin/rm -rf "$lock"
      continue
    fi
    waited=$((waited + 1))
    [ "$waited" -le 150 ] || die "another teamctl operation holds the project lock (pid ${holder:-unknown})"
    sleep 0.2
  done
  printf '%s\n' "$$" >"$lock/pid"
  LOCK_HELD="$lock"
  trap 'teamctl_on_exit' EXIT # releases the lock, reports a crash (common.sh)
}

lock_release() {
  if [ -n "$LOCK_HELD" ]; then
    /bin/rm -rf "$LOCK_HELD"
    LOCK_HELD=""
  fi
}
