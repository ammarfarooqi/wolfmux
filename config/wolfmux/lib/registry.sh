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
