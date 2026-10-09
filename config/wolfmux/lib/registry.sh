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

reg_delete() { /bin/rm -f "$(reg_path "$1")" "$STATE_DIR/nudge/$1"; }

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

# event_log <type> <role> [detail] — one small O_APPEND write per event
event_log() {
  [ -d "$STATE_DIR" ] || return 0
  "$JQ_BIN" -cn --arg ts "$(now_iso)" --arg type "$1" --arg role "${2:-}" --arg detail "${3:-}" \
    --arg by "${TEAM_ROLE:-operator}" '{ts: $ts, type: $type, role: $role, by: $by, detail: $detail}' \
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
  local marker="$STATE_DIR/nudge/$1.pending" now gap
  now="$(now_epoch)"
  if [ $((now - $(_nudge_num "$marker/ts"))) -gt \
    $((${WOLFMUX_NUDGE_DEFER_MAX:-600} + NUDGE_PENDING_SLACK_SECONDS)) ]; then return 0; fi
  gap=$((${WOLFMUX_NUDGE_RETRY:-3} * 3))
  if [ "$gap" -lt "$NUDGE_PENDING_SLACK_SECONDS" ]; then gap="$NUDGE_PENDING_SLACK_SECONDS"; fi
  [ $((now - $(_nudge_num "$marker/beat"))) -gt "$gap" ]
}

# nudge_pending_open <role> — 0 when this process is now the role's one waiter.
# Called while holding nudge_begin <role>, so two processes never race here.
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

# nudge_pending_put_bead <role> <bead> — the collapsible slot: the newest bead id
# wins, and two different ids mean the generic line that points at the whole inbox.
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
  local marker="$STATE_DIR/nudge/$1.pending" held
  [ -d "$marker" ] || return 1
  held="$(/usr/bin/wc -l <"$marker/lines" 2>/dev/null | /usr/bin/tr -d ' ')"
  case "$held" in "" | *[!0-9]*) held=0 ;; esac
  if [ "$held" -ge "$NUDGE_PENDING_MAX_LINES" ]; then return 0; fi
  printf '%s\n' "$2" >>"$marker/lines"
}

nudge_pending_lines() { /bin/cat "$STATE_DIR/nudge/$1.pending/lines" 2>/dev/null || true; }

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
  trap 'lock_release' EXIT
}

lock_release() {
  if [ -n "$LOCK_HELD" ]; then
    /bin/rm -rf "$LOCK_HELD"
    LOCK_HELD=""
  fi
}
