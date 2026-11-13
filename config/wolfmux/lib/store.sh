#!/bin/bash
# store.sh — one interface for tasks, messages and memory, over two backends: a native
# sqlite3 file (default for a new project) or Beads (bd, kept for teams already on it).
# Every caller in wolfmux uses only the functions below; nothing else touches a bead or
# the store.db file directly. load_project (common.sh) must have run first: it sets ROOT
# and PROJECT_STATE, which every function here assumes.
#
# An ITEM is one JSON object, the same shape from both backends:
#   {id, issue_type: "task"|"message", title, description, status, priority, assignee,
#    created_by, created_at, updated_at, reply_to, notes}
# (status of a message: open = unread, closed = read; notes: text, "" when none;
# reply_to: id or ""; a task ITEM also carries blocked_by: array of unclosed blocker ids.)
#
# Dispatch: a public store_* function validates what is cheap to validate the same way for
# both backends, then calls store_native_<name> or store_beads_<name>, named after store_kind.

# --- which backend ------------------------------------------------------------------
# store_kind: the file wins; else WOLFMUX_STORE; else beads for a project that already has
# agent state from before v1.13 (teams started on Beads keep using it after an upgrade);
# else native, for a project with nothing on disk yet.
store_kind() {
  local f="$PROJECT_STATE/store" v p
  if [ -f "$f" ]; then
    v="$(/bin/cat "$f" 2>/dev/null || true)"
    case "$v" in native | beads) printf '%s\n' "$v"; return 0 ;; esac
  fi
  case "${WOLFMUX_STORE:-}" in
    native | beads) printf '%s\n' "$WOLFMUX_STORE"; return 0 ;;
  esac
  for p in "$PROJECT_STATE"/agents/*.json "$PROJECT_STATE"/teams/*/agents/*.json; do
    [ -e "$p" ] || continue
    printf 'beads\n'
    return 0
  done
  if [ -f "$PROJECT_STATE/meta.json" ]; then printf 'beads\n'; else printf 'native\n'; fi
}

# store_set_kind <native|beads> — the file, written atomically (two processes may run at once)
store_set_kind() {
  local kind="$1" tmp
  case "$kind" in native | beads) ;; *) return 1 ;; esac
  /bin/mkdir -p "$PROJECT_STATE"
  tmp="$PROJECT_STATE/store.tmp.$$"
  printf '%s\n' "$kind" >"$tmp"
  /bin/mv -f "$tmp" "$PROJECT_STATE/store"
}

# --- the public interface: validate what both backends share, then dispatch -----------
store_ensure() { "store_$(store_kind)_ensure"; }

store_task_create() {
  case "${3:-}" in [0-4]) ;; *) return 1 ;; esac
  "store_$(store_kind)_task_create" "$@"
}

store_task_dep_add() { "store_$(store_kind)_task_dep_add" "$@"; }
store_item_json() { "store_$(store_kind)_item_json" "$@"; }
store_tasks_json() { "store_$(store_kind)_tasks_json" "${1:-}" "${2:-}"; }
store_task_claim() { "store_$(store_kind)_task_claim" "$@"; }

store_task_status() {
  case "${2:-}" in open | in_progress | blocked) ;; *) return 1 ;; esac
  "store_$(store_kind)_task_status" "$@"
}

store_task_close() {
  case "${3:-}" in "" | failed) ;; *) return 1 ;; esac
  "store_$(store_kind)_task_close" "$@"
}

store_task_note() { "store_$(store_kind)_task_note" "$@"; }
store_msg_create() { "store_$(store_kind)_msg_create" "$@"; }
store_inbox_json() { "store_$(store_kind)_inbox_json" "$@"; }
store_msg_read() { "store_$(store_kind)_msg_read" "$@"; }
store_thread_json() { "store_$(store_kind)_thread_json" "$@"; }

store_memory_set() {
  case "${1:-}" in "" | *[!${_WM_LOWER}${_WM_DIGITS}-]*) return 1 ;; esac
  [ "${#1}" -le 64 ] || return 1
  "store_$(store_kind)_memory_set" "$@"
}

store_memory_text() { "store_$(store_kind)_memory_text" "${1:-0}"; }
store_memory_list_json() { "store_$(store_kind)_memory_list_json" "${1:-}"; }
store_memory_forget() { "store_$(store_kind)_memory_forget" "$@"; }

# =======================================================================================
# The native backend: one sqlite3 file per project, $PROJECT_STATE/store.db.
# =======================================================================================

WOLFMUX_SQLITE_MIN_MINOR=38 # 3.38: the ->> operator this backend is built on
SQLITE_BIN="${WOLFMUX_SQLITE_BIN:-}"
if [ -z "$SQLITE_BIN" ]; then
  if [ -x /usr/bin/sqlite3 ]; then SQLITE_BIN=/usr/bin/sqlite3; else SQLITE_BIN="$(command -v sqlite3 2>/dev/null || true)"; fi
fi

store_db() { printf '%s/store.db\n' "$PROJECT_STATE"; }

# _store_sqlite_ok — sqlite3 exists and is 3.38 or newer
_store_sqlite_ok() {
  local v major minor
  [ -n "$SQLITE_BIN" ] && [ -x "$SQLITE_BIN" ] || return 1
  v="$("$SQLITE_BIN" -version 2>/dev/null | /usr/bin/awk '{print $1}')" || return 1
  major="${v%%.*}"
  minor="${v#*.}"
  minor="${minor%%.*}"
  case "$major" in '' | *[!0-9]*) return 1 ;; esac
  case "$minor" in '' | *[!0-9]*) return 1 ;; esac
  [ "$major" -gt 3 ] && return 0
  [ "$major" -eq 3 ] && [ "$minor" -ge "$WOLFMUX_SQLITE_MIN_MINOR" ]
}

# _sq '<single SQL statement>' '<json params>' — the values travel as one JSON document
# (p.j), hex-encoded into a blob literal fed on stdin; the SQL text is always a constant.
# WITH binds to one statement, so this is only for a single statement (a read, or one
# INSERT ... RETURNING). foreign_keys is a per-connection setting, so it is set every call;
# journal_mode is set once in store_native_ensure (it persists in the file) because setting
# it again here would print "wal" ahead of the real result.
_sq() {
  local hex
  hex="$(printf '%s' "$2" | /usr/bin/xxd -p | tr -d '\n')"
  printf "WITH p(j) AS (SELECT CAST(x'%s' AS TEXT)) %s\n" "$hex" "$1" \
    | "$SQLITE_BIN" -cmd '.timeout 5000' -cmd 'PRAGMA foreign_keys=ON;' "$(store_db)"
}

# _sqx '<SQL statements>' '<json params>' — several statements, atomic (BEGIN IMMEDIATE ...
# COMMIT). WITH cannot span statements, so the params load into a TEMP TABLE instead.
# changes() reflects the most recently completed mutating statement; a plain SELECT between
# a mutation and a later statement that reads changes() does not disturb it.
_sqx() {
  local hex
  hex="$(printf '%s' "$2" | /usr/bin/xxd -p | tr -d '\n')"
  { printf "BEGIN IMMEDIATE;\nCREATE TEMP TABLE p AS SELECT CAST(x'%s' AS TEXT) AS j;\n" "$hex"
    printf '%s\n' "$1"
    printf 'COMMIT;\n'
  } | "$SQLITE_BIN" -cmd '.timeout 5000' -cmd 'PRAGMA foreign_keys=ON;' "$(store_db)"
}

# json_object fragments shared by every query that reads a task or a message row. The
# surrounding query must alias the table "task" or "msg".
_STORE_TASK_JSON="json_object('id','t'||task.id,'issue_type','task','title',task.title,'description',task.description,'status',task.status,'priority',task.priority,'assignee',task.assignee,'created_by',task.created_by,'created_at',task.created_at,'updated_at',task.updated_at,'reply_to','','notes',task.notes,'blocked_by',(SELECT COALESCE(json_group_array(bx),'[]') FROM (SELECT 't'||d.blocker_id AS bx FROM task_dep d JOIN task b ON b.id=d.blocker_id WHERE d.task_id=task.id AND b.status<>'closed' ORDER BY d.blocker_id)))"
_STORE_MSG_JSON="json_object('id','m'||msg.id,'issue_type','message','title',msg.subject,'description',msg.body,'status',msg.status,'priority',2,'assignee',msg.recipient,'created_by',msg.sender,'created_at',msg.created_at,'updated_at',msg.updated_at,'reply_to',COALESCE('m'||msg.reply_to,''),'notes','')"

_STORE_SCHEMA_SQL="
PRAGMA journal_mode=WAL;
BEGIN IMMEDIATE;
CREATE TABLE IF NOT EXISTS meta(schema_version INTEGER NOT NULL);
INSERT INTO meta(schema_version) SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM meta);
CREATE TABLE IF NOT EXISTS task(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL DEFAULT '',
  description TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'open',
  priority INTEGER NOT NULL DEFAULT 2,
  assignee TEXT NOT NULL DEFAULT '',
  created_by TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  notes TEXT NOT NULL DEFAULT '',
  close_reason TEXT NOT NULL DEFAULT '',
  failed INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS task_dep(
  task_id INTEGER NOT NULL REFERENCES task(id),
  blocker_id INTEGER NOT NULL REFERENCES task(id),
  PRIMARY KEY(task_id, blocker_id)
);
CREATE TABLE IF NOT EXISTS msg(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sender TEXT NOT NULL DEFAULT '',
  recipient TEXT NOT NULL DEFAULT '',
  subject TEXT NOT NULL DEFAULT '',
  body TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'open',
  reply_to INTEGER REFERENCES msg(id),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS memory(
  key TEXT PRIMARY KEY,
  text TEXT NOT NULL,
  author TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS event(
  at TEXT NOT NULL, actor TEXT NOT NULL DEFAULT '', kind TEXT NOT NULL, ref TEXT NOT NULL DEFAULT '', detail TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS migrated(
  old_id TEXT PRIMARY KEY, new_id TEXT NOT NULL, kind TEXT NOT NULL, migrated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_task_assignee_status ON task(assignee, status);
CREATE INDEX IF NOT EXISTS idx_msg_recipient_status ON msg(recipient, status);
COMMIT;
"

# store_native_ensure — create the file and schema; idempotent. Several processes doing
# this at once on a brand-new file can still race the one-time WAL conversion itself
# ("database is locked", not covered by .timeout the way an ordinary busy wait is), so a
# failure here is retried rather than trusted as real on the first try.
store_native_ensure() {
  _store_sqlite_ok || die "store: sqlite3 ${WOLFMUX_SQLITE_MIN_MINOR:+3.$WOLFMUX_SQLITE_MIN_MINOR}+ required for the native store (found: ${SQLITE_BIN:-none}); the other backend is WOLFMUX_STORE=beads"
  /bin/mkdir -p "$PROJECT_STATE"
  local tries=0 err
  while :; do
    err="$(printf '%s\n' "$_STORE_SCHEMA_SQL" | "$SQLITE_BIN" -cmd '.timeout 5000' "$(store_db)" 2>&1 >/dev/null)"
    [ -z "$err" ] && return 0
    tries=$((tries + 1))
    if [ "$tries" -ge 20 ]; then
      printf '%s\n' "$err" >&2
      return 1
    fi
    sleep 0.1
  done
}

# --- ids: t<number> and m<number> ------------------------------------------------------
# _store_native_num <prefix char> <id> — prints the digits after the prefix, or fails
_store_native_num() {
  local id="$2" num
  case "$id" in
    "$1"[0-9]*) num="${id#?}" ;;
    *) return 1 ;;
  esac
  case "$num" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s\n' "$num"
}

store_native_item_json() {
  local id="$1" num
  if num="$(_store_native_num t "$id" 2>/dev/null)"; then
    store_native_task_item_json "$num"
  elif num="$(_store_native_num m "$id" 2>/dev/null)"; then
    store_native_msg_item_json "$num"
  else
    return 1
  fi
}

store_native_task_item_json() {
  local out
  out="$(_sq "SELECT ${_STORE_TASK_JSON} FROM task WHERE task.id=(SELECT CAST(j->>'num' AS INTEGER) FROM p);" \
    "$("$JQ_BIN" -cn --arg num "$1" '{num:$num}')")"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

store_native_msg_item_json() {
  local out
  out="$(_sq "SELECT ${_STORE_MSG_JSON} FROM msg WHERE msg.id=(SELECT CAST(j->>'num' AS INTEGER) FROM p);" \
    "$("$JQ_BIN" -cn --arg num "$1" '{num:$num}')")"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

store_native_task_create() {
  local creator="$1" assignee="$2" priority="$3" title="$4" body="$5" out
  out="$(_sqx "
INSERT INTO task(title,description,status,priority,assignee,created_by,created_at,updated_at)
SELECT j->>'title', j->>'body', 'open', CAST(j->>'priority' AS INTEGER), j->>'assignee', j->>'creator', j->>'now', j->>'now' FROM p;
SELECT 't'||last_insert_rowid();
INSERT INTO event(at,actor,kind,ref,detail) SELECT j->>'now', j->>'creator', 'task_create', 't'||last_insert_rowid(), '' FROM p;" \
    "$("$JQ_BIN" -cn --arg creator "$creator" --arg assignee "$assignee" --arg priority "$priority" --arg title "$title" --arg body "$body" --arg now "$(now_iso)" \
      '{creator:$creator,assignee:$assignee,priority:$priority,title:$title,body:$body,now:$now}')")"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

store_native_task_dep_add() {
  local tnum bnum
  tnum="$(_store_native_num t "$1")" || return 1
  bnum="$(_store_native_num t "$2")" || return 1
  _sqx "INSERT OR IGNORE INTO task_dep(task_id,blocker_id) SELECT CAST(j->>'t' AS INTEGER), CAST(j->>'b' AS INTEGER) FROM p;" \
    "$("$JQ_BIN" -cn --arg t "$tnum" --arg b "$bnum" '{t:$t,b:$b}')" >/dev/null
}

store_native_tasks_json() {
  local assignee="${1:-}" statuses="${2:-}" out
  out="$(_sq "SELECT COALESCE((SELECT json_group_array(json(x)) FROM (
    SELECT ${_STORE_TASK_JSON} AS x FROM task
    WHERE ((SELECT j->>'assignee' FROM p)='' OR task.assignee=(SELECT j->>'assignee' FROM p))
      AND ((SELECT j->>'statuses' FROM p)='' OR (','||(SELECT j->>'statuses' FROM p)||',') LIKE ('%,'||task.status||',%'))
    ORDER BY task.priority ASC, task.created_at ASC, task.id ASC)), '[]');" \
    "$("$JQ_BIN" -cn --arg assignee "$assignee" --arg statuses "$statuses" '{assignee:$assignee,statuses:$statuses}')")"
  printf '%s\n' "${out:-[]}"
}

# store_native_task_claim <id> <identity> — atomic: WHERE already restricts the update to a
# claimable row, so a matched row IS the claim; changes() (via the row-count check below)
# tells the caller whether it happened. Ten processes racing all BEGIN IMMEDIATE on the same
# file: exactly one UPDATE sees status='open' before the others see it as 'in_progress'.
store_native_task_claim() {
  local num out
  num="$(_store_native_num t "$1")" || return 1
  out="$(_sqx "
UPDATE task SET status='in_progress', assignee=(SELECT j->>'identity' FROM p), updated_at=(SELECT j->>'now' FROM p)
WHERE id=(SELECT CAST(j->>'num' AS INTEGER) FROM p)
  AND ( (status='open' AND (assignee='' OR assignee=(SELECT j->>'identity' FROM p)))
     OR (status='in_progress' AND assignee=(SELECT j->>'identity' FROM p)) );
SELECT changes();
INSERT INTO event(at,actor,kind,ref,detail) SELECT (SELECT j->>'now' FROM p), (SELECT j->>'identity' FROM p), 'task_claim', 't'||(SELECT j->>'num' FROM p), '' FROM p WHERE changes()=1;" \
    "$("$JQ_BIN" -cn --arg num "$num" --arg identity "$2" --arg now "$(now_iso)" '{num:$num,identity:$identity,now:$now}')")"
  [ "$out" = "1" ]
}

store_native_task_status() {
  local num
  num="$(_store_native_num t "$1")" || return 1
  _sqx "
UPDATE task SET status=(SELECT j->>'status' FROM p), updated_at=(SELECT j->>'now' FROM p) WHERE id=(SELECT CAST(j->>'num' AS INTEGER) FROM p);
INSERT INTO event(at,actor,kind,ref,detail) SELECT (SELECT j->>'now' FROM p), '', 'task_status', 't'||(SELECT j->>'num' FROM p), (SELECT j->>'status' FROM p) FROM p WHERE changes()=1;" \
    "$("$JQ_BIN" -cn --arg num "$num" --arg status "$2" --arg now "$(now_iso)" '{num:$num,status:$status,now:$now}')" >/dev/null
}

store_native_task_close() {
  local num failed=0
  num="$(_store_native_num t "$1")" || return 1
  [ "${3:-}" = "failed" ] && failed=1
  _sqx "
UPDATE task SET status='closed', close_reason=(SELECT j->>'reason' FROM p), failed=(SELECT CAST(j->>'failed' AS INTEGER) FROM p), updated_at=(SELECT j->>'now' FROM p) WHERE id=(SELECT CAST(j->>'num' AS INTEGER) FROM p);
INSERT INTO event(at,actor,kind,ref,detail) SELECT (SELECT j->>'now' FROM p), '', 'task_close', 't'||(SELECT j->>'num' FROM p), (SELECT j->>'reason' FROM p) FROM p WHERE changes()=1;" \
    "$("$JQ_BIN" -cn --arg num "$num" --arg reason "$2" --arg failed "$failed" --arg now "$(now_iso)" '{num:$num,reason:$reason,failed:$failed,now:$now}')" >/dev/null
}

# store_native_task_note <id> <author> <text> — appended with author and time, in one TEXT
# column (not a side table): no row order to keep straight, no ambiguity to resolve later.
store_native_task_note() {
  local num line
  num="$(_store_native_num t "$1")" || return 1
  line="$(printf '%s %s: %s' "$2" "$(now_iso)" "$3")"
  _sqx "
UPDATE task SET notes=(CASE WHEN notes='' THEN (SELECT j->>'line' FROM p) ELSE notes||char(10)||(SELECT j->>'line' FROM p) END), updated_at=(SELECT j->>'now' FROM p) WHERE id=(SELECT CAST(j->>'num' AS INTEGER) FROM p);
INSERT INTO event(at,actor,kind,ref,detail) SELECT (SELECT j->>'now' FROM p), (SELECT j->>'author' FROM p), 'task_note', 't'||(SELECT j->>'num' FROM p), '' FROM p WHERE changes()=1;" \
    "$("$JQ_BIN" -cn --arg num "$num" --arg line "$line" --arg author "$2" --arg now "$(now_iso)" '{num:$num,line:$line,author:$author,now:$now}')" >/dev/null
}

store_native_msg_create() {
  local sender="$1" recipient="$2" subject="$3" body="$4" reply_to="${5:-}" rnum="" out
  if [ -n "$reply_to" ]; then rnum="$(_store_native_num m "$reply_to")" || return 1; fi
  out="$(_sqx "
INSERT INTO msg(sender,recipient,subject,body,status,reply_to,created_at,updated_at)
SELECT j->>'sender', j->>'recipient', j->>'subject', j->>'body', 'open',
       (CASE WHEN (SELECT j->>'reply_to' FROM p)='' THEN NULL ELSE CAST(j->>'reply_to' AS INTEGER) END),
       j->>'now', j->>'now' FROM p;
SELECT 'm'||last_insert_rowid();
INSERT INTO event(at,actor,kind,ref,detail) SELECT j->>'now', j->>'sender', 'msg_create', 'm'||last_insert_rowid(), '' FROM p;" \
    "$("$JQ_BIN" -cn --arg sender "$sender" --arg recipient "$recipient" --arg subject "$subject" --arg body "$body" --arg reply_to "$rnum" --arg now "$(now_iso)" \
      '{sender:$sender,recipient:$recipient,subject:$subject,body:$body,reply_to:$reply_to,now:$now}')")"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

store_native_inbox_json() {
  local identity="$1" tasks msgs
  tasks="$(store_native_tasks_json "$identity" "open,in_progress,blocked")"
  msgs="$(_sq "SELECT COALESCE((SELECT json_group_array(json(x)) FROM (
    SELECT ${_STORE_MSG_JSON} AS x FROM msg WHERE msg.recipient=(SELECT j->>'identity' FROM p) AND msg.status='open' ORDER BY msg.created_at ASC)), '[]');" \
    "$("$JQ_BIN" -cn --arg identity "$identity" '{identity:$identity}')")"
  "$JQ_BIN" -cn --argjson a "${tasks:-[]}" --argjson b "${msgs:-[]}" '$a + $b'
}

store_native_msg_read() {
  local identity="$1" id num
  shift
  for id in "$@"; do
    num="$(_store_native_num m "$id" 2>/dev/null)" || continue
    _sqx "
UPDATE msg SET status='closed', updated_at=(SELECT j->>'now' FROM p) WHERE id=(SELECT CAST(j->>'num' AS INTEGER) FROM p) AND recipient=(SELECT j->>'identity' FROM p) AND status='open';
INSERT INTO event(at,actor,kind,ref,detail) SELECT (SELECT j->>'now' FROM p), (SELECT j->>'identity' FROM p), 'msg_read', 'm'||(SELECT j->>'num' FROM p), '' FROM p WHERE changes()=1;" \
      "$("$JQ_BIN" -cn --arg num "$num" --arg identity "$identity" --arg now "$(now_iso)" '{num:$num,identity:$identity,now:$now}')" >/dev/null
  done
  return 0
}

# store_native_thread_json <id> — the message, what it replies to, and its direct replies.
store_native_thread_json() {
  local num out
  num="$(_store_native_num m "$1")" || return 1
  out="$(_sq "SELECT COALESCE((SELECT json_group_array(json(x)) FROM (
    SELECT ${_STORE_MSG_JSON} AS x, msg.created_at AS ord FROM msg WHERE msg.id=(SELECT CAST(j->>'num' AS INTEGER) FROM p)
    UNION ALL
    SELECT ${_STORE_MSG_JSON} AS x, msg.created_at AS ord FROM msg WHERE msg.id=(SELECT reply_to FROM msg WHERE id=(SELECT CAST(j->>'num' AS INTEGER) FROM p))
    UNION ALL
    SELECT ${_STORE_MSG_JSON} AS x, msg.created_at AS ord FROM msg WHERE msg.reply_to=(SELECT CAST(j->>'num' AS INTEGER) FROM p)
    ORDER BY ord ASC)), '[]');" \
    "$("$JQ_BIN" -cn --arg num "$num" '{num:$num}')")"
  [ -n "$out" ] && [ "$out" != "[]" ] || return 1
  printf '%s\n' "$out"
}

store_native_memory_set() {
  local key="$1" text="$2" author="$3"
  # "INSERT ... SELECT ... FROM p" directly followed by "ON CONFLICT" does not parse (SQLite
  # reads "FROM p ON ..." as a join); VALUES with scalar subqueries sidesteps that.
  _sqx "
INSERT INTO memory(key,text,author,updated_at) VALUES ((SELECT j->>'key' FROM p), (SELECT j->>'text' FROM p), (SELECT j->>'author' FROM p), (SELECT j->>'now' FROM p))
  ON CONFLICT(key) DO UPDATE SET text=excluded.text, author=excluded.author, updated_at=excluded.updated_at;
INSERT INTO event(at,actor,kind,ref,detail) SELECT j->>'now', j->>'author', 'memory_set', j->>'key', '' FROM p;" \
    "$("$JQ_BIN" -cn --arg key "$key" --arg text "$text" --arg author "$author" --arg now "$(now_iso)" '{key:$key,text:$text,author:$author,now:$now}')" >/dev/null
}

store_native_memory_list_json() {
  local query="${1:-}" out
  out="$(_sq "SELECT COALESCE((SELECT json_group_array(json_object('key',key,'text',text,'author',author,'updated_at',updated_at)) FROM (
    SELECT * FROM memory WHERE (SELECT j->>'q' FROM p)=''
      OR LOWER(key) LIKE '%'||LOWER((SELECT j->>'q' FROM p))||'%' OR LOWER(text) LIKE '%'||LOWER((SELECT j->>'q' FROM p))||'%'
    ORDER BY updated_at DESC)), '[]');" \
    "$("$JQ_BIN" -cn --arg q "$query" '{q:$q}')")"
  printf '%s\n' "${out:-[]}"
}

# store_native_memory_text <max-chars> — whole memories only, newest first, stop (do not
# truncate) at the first one that would not fit.
store_native_memory_text() {
  local rows
  rows="$(store_native_memory_list_json)"
  printf '%s' "${rows:-[]}" | "$JQ_BIN" -r --argjson max "$1" '
    reduce .[] as $m ({out:"", stop:false};
      if .stop then . else
        (.out + (if .out=="" then "" else "\n\n" end) + "### " + $m.key + "\n" + $m.text) as $cand |
        (if ($cand|length) <= $max then {out:$cand, stop:false} else {out:.out, stop:true} end)
      end) | .out'
}

store_native_memory_forget() {
  local out
  out="$(_sqx "
DELETE FROM memory WHERE key=(SELECT j->>'key' FROM p);
SELECT changes();
INSERT INTO event(at,actor,kind,ref,detail) SELECT (SELECT j->>'now' FROM p), '', 'memory_forget', (SELECT j->>'key' FROM p), '' FROM p WHERE changes()=1;" \
    "$("$JQ_BIN" -cn --arg key "$1" --arg now "$(now_iso)" '{key:$key,now:$now}')")"
  [ "$out" = "1" ]
}

store_native_unread_count() { _sq "SELECT COUNT(*) FROM msg WHERE status='open';" '{}'; }

# =======================================================================================
# The beads backend: the same functions over bd. teamctl's own Beads glue (lib/beads.sh)
# makes sure a workspace exists; this module only ever reads and writes issues in it.
# =======================================================================================

# _store_bd <bd args...> — run from $ROOT, as the spec requires; BEADS_DIR, if the caller
# set it, reaches bd unchanged (nothing here clears or overrides the environment).
_store_bd() { (cd "$ROOT" && "$BD_BIN" "$@"); }

_STORE_ITEM_JQ='{id, issue_type, title, description: (.description // ""), status, priority, assignee: (.assignee // ""), created_by: (.created_by // ""), created_at, updated_at, reply_to: "", notes: (.notes // "")}'

store_beads_ensure() { :; } # lib/beads.sh (beads_ensure) makes the workspace; nothing else to do

store_beads_task_create() {
  local creator="$1" assignee="$2" priority="$3" title="$4" body="$5" id
  id="$(_store_bd create "$title" -t task -p "$priority" -a "$assignee" --actor "$creator" --description "$body" --json 2>/dev/null | "$JQ_BIN" -r '.id // empty')"
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

store_beads_task_dep_add() { _store_bd dep add "$1" "$2" --json >/dev/null 2>&1; }

store_beads_item_json() {
  local id="$1" raw kind item blocked_by
  raw="$(_store_bd show "$id" --json --long 2>/dev/null)" || return 1
  [ "$(printf '%s' "$raw" | "$JQ_BIN" 'length' 2>/dev/null || printf 0)" -gt 0 ] || return 1
  kind="$(printf '%s' "$raw" | "$JQ_BIN" -r '.[0].issue_type')"
  item="$(printf '%s' "$raw" | "$JQ_BIN" -c ".[0] | $_STORE_ITEM_JQ + {reply_to: ((.dependencies // []) | map(select(.dependency_type==\"replies-to\")) | if length>0 then .[0].id else \"\" end)}")"
  if [ "$kind" = "task" ]; then
    blocked_by="$(printf '%s' "$raw" | "$JQ_BIN" -c '[(.[0].dependencies // [])[] | select(.dependency_type=="blocks" and .status!="closed") | .id]')"
    item="$(printf '%s' "$item" | "$JQ_BIN" -c --argjson b "${blocked_by:-[]}" '. + {blocked_by: $b}')"
  fi
  printf '%s\n' "$item"
}

# store_beads_tasks_json <assignee or ""> <statuses or ""> — --all is only safe to combine
# with an explicit --status filter; with none, --status itself would otherwise exclude closed.
store_beads_tasks_json() {
  local assignee="${1:-}" statuses="${2:-}" args raw items ids status_map
  args=(list --json --include-infra --long --type task --limit 0)
  [ -n "$assignee" ] && args+=(--assignee "$assignee")
  if [ -n "$statuses" ]; then args+=(--status "$statuses"); else args+=(--all); fi
  raw="$(_store_bd "${args[@]}" 2>/dev/null)" || { printf '[]\n'; return 0; }
  items="$(printf '%s' "$raw" | "$JQ_BIN" -c "map($_STORE_ITEM_JQ + {_blockers: [(.dependencies // [])[] | select(.type==\"blocks\") | .depends_on_id]})")"
  ids="$(printf '%s' "$items" | "$JQ_BIN" -r '[.[]._blockers[]] | unique | join(",")')"
  if [ -n "$ids" ]; then
    status_map="$(_store_bd list --id "$ids" --all --json --include-infra --limit 0 2>/dev/null | "$JQ_BIN" -c 'map({(.id): .status}) | add // {}')"
  else
    status_map='{}'
  fi
  printf '%s' "$items" | "$JQ_BIN" -c --argjson sm "${status_map:-\{\}}" '
    map(. + {blocked_by: [._blockers[] | select($sm[.] != "closed")]} | del(._blockers)) | sort_by([.priority, .created_at])'
}

store_beads_task_claim() { _store_bd update "$1" --claim --actor "$2" --json >/dev/null 2>&1; }
store_beads_task_status() { _store_bd update "$1" --status "$2" --json >/dev/null 2>&1; }

# store_beads_task_close — no identity travels with this call, so a close whose actor is
# not the assignee (bd's own guard, independent of claim) needs --force to go through;
# the interface gives the caller no way to supply the assignee's identity instead.
store_beads_task_close() {
  local id="$1" reason="$2"
  if [ "${3:-}" = "failed" ]; then _store_bd update "$id" --add-label failed --json >/dev/null 2>&1 || return 1; fi
  _store_bd close "$id" -r "$reason" --force --json >/dev/null 2>&1
}

store_beads_task_note() {
  _store_bd note "$1" --actor "$2" --json -- "$(printf '%s %s: %s' "$2" "$(now_iso)" "$3")" >/dev/null 2>&1
}

store_beads_msg_create() {
  local sender="$1" recipient="$2" subject="$3" body="$4" reply_to="${5:-}" id
  # bash 3.2: "${arr[@]}" on a still-empty array raises "unbound variable" under set -u,
  # so the reply dependency is a plain conditional call, not an optional array element.
  if [ -n "$reply_to" ]; then
    id="$(_store_bd create "$subject" -t message -a "$recipient" --actor "$sender" --description "$body" --deps "replies-to:$reply_to" --json 2>/dev/null | "$JQ_BIN" -r '.id // empty')"
  else
    id="$(_store_bd create "$subject" -t message -a "$recipient" --actor "$sender" --description "$body" --json 2>/dev/null | "$JQ_BIN" -r '.id // empty')"
  fi
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

store_beads_inbox_json() {
  local identity="$1" tasks msgs
  tasks="$(store_beads_tasks_json "$identity" "open,in_progress,blocked")"
  msgs="$(_store_bd list --assignee "$identity" --status open --type message --include-infra --json --limit 0 2>/dev/null \
    | "$JQ_BIN" -c "map($_STORE_ITEM_JQ) | sort_by(.created_at)" 2>/dev/null)"
  "$JQ_BIN" -cn --argjson a "${tasks:-[]}" --argjson b "${msgs:-[]}" '$a + $b'
}

# store_beads_msg_read — guarded by --if-assignee/--if-status so a stale or foreign id is a
# no-op (exit 13), not an error; that is exactly "skipped".
store_beads_msg_read() {
  local identity="$1" id
  shift
  for id in "$@"; do
    _store_bd update "$id" --status closed --if-assignee "$identity" --if-status open --actor "$identity" --json >/dev/null 2>&1 || true
  done
  return 0
}

# store_beads_thread_json — bd show --thread already walks the whole conversation; one
# dep lookup per message maps each to what it replies to (batching several ids in one
# `bd dep list` call returns hydrated issues with no field saying which request they
# answer, so this asks one at a time instead).
store_beads_thread_json() {
  local id="$1" raw n mapped mid parent
  raw="$(_store_bd show "$id" --thread --json 2>/dev/null)" || return 1
  n="$(printf '%s' "$raw" | "$JQ_BIN" 'length' 2>/dev/null || printf 0)"
  [ "$n" -gt 0 ] || return 1
  mapped="$(printf '%s' "$raw" | "$JQ_BIN" -c "map($_STORE_ITEM_JQ)")"
  for mid in $(printf '%s' "$raw" | "$JQ_BIN" -r '.[].id'); do
    parent="$(_store_bd dep list "$mid" --direction=down --type replies-to --json 2>/dev/null | "$JQ_BIN" -r '.[0].id // empty' 2>/dev/null)"
    mapped="$(printf '%s' "$mapped" | "$JQ_BIN" -c --arg id "$mid" --arg p "${parent:-}" 'map(if .id==$id then .reply_to=$p else . end)')"
  done
  printf '%s\n' "$mapped"
}

store_beads_memory_set() { _store_bd remember "$2" --key "$1" --actor "$3" --json >/dev/null 2>&1; }

# store_beads_memory_list_json — bd's memory store has no author or updated_at to give back,
# and `bd memories --json` is a {key: text} map with no declared ordering: both fields come
# back empty, and store_beads_memory_text cannot promise "newest first" on this backend.
store_beads_memory_list_json() {
  local query="${1:-}" raw
  raw="$(_store_bd memories "$query" --json 2>/dev/null)" || { printf '[]\n'; return 0; }
  printf '%s' "$raw" | "$JQ_BIN" -c '[to_entries[] | select(.key != "schema_version") | {key: .key, text: .value, author: "", updated_at: ""}]'
}

store_beads_memory_text() {
  local rows
  rows="$(store_beads_memory_list_json)"
  printf '%s' "${rows:-[]}" | "$JQ_BIN" -r --argjson max "$1" '
    reduce .[] as $m ({out:"", stop:false};
      if .stop then . else
        (.out + (if .out=="" then "" else "\n\n" end) + "### " + $m.key + "\n" + $m.text) as $cand |
        (if ($cand|length) <= $max then {out:$cand, stop:false} else {out:.out, stop:true} end)
      end) | .out'
}

store_beads_memory_forget() { _store_bd forget "$1" --json >/dev/null 2>&1; }
store_beads_unread_count() { _store_bd list --type message --status open --include-infra --json --limit 0 2>/dev/null | "$JQ_BIN" 'length' 2>/dev/null || printf 0; }

# =======================================================================================
# teamctl store (cmd_store, will be wired in by bin/teamctl at integration)
# =======================================================================================

_store_migrated_new_id() {
  _sq "SELECT COALESCE((SELECT new_id FROM migrated WHERE old_id=(SELECT j->>'old' FROM p)), '');" "$("$JQ_BIN" -cn --arg old "$1" '{old:$old}')"
}

_store_migrate_record() {
  _sqx "INSERT OR IGNORE INTO migrated(old_id,new_id,kind,migrated_at) SELECT j->>'old', j->>'new', j->>'kind', j->>'now' FROM p;" \
    "$("$JQ_BIN" -cn --arg old "$1" --arg new "$2" --arg kind "$3" --arg now "$(now_iso)" '{old:$old,new:$new,kind:$kind,now:$now}')" >/dev/null
}

# _store_migrate_tasks — pass 1: every non-closed task, new ids recorded in `migrated`
_store_migrate_tasks() {
  local old_id item title desc assignee prio created_by new_id
  for old_id in $(_store_bd list --type task --all --include-infra --json --limit 0 2>/dev/null | "$JQ_BIN" -r 'map(select(.status != "closed")) | .[].id'); do
    [ -n "$(_store_migrated_new_id "$old_id")" ] && continue
    item="$(_store_bd show "$old_id" --json 2>/dev/null)" || continue
    title="$(printf '%s' "$item" | "$JQ_BIN" -r '.[0].title')"
    desc="$(printf '%s' "$item" | "$JQ_BIN" -r '.[0].description // ""')"
    assignee="$(printf '%s' "$item" | "$JQ_BIN" -r '.[0].assignee // ""')"
    prio="$(printf '%s' "$item" | "$JQ_BIN" -r '.[0].priority')"
    created_by="$(printf '%s' "$item" | "$JQ_BIN" -r '.[0].created_by // ""')"
    new_id="$(store_native_task_create "$created_by" "$assignee" "$prio" "$title" "$desc")" || continue
    store_native_task_note "$new_id" migrate "migrated from $old_id"
    _store_migrate_record "$old_id" "$new_id" task
  done
}

# _store_migrate_task_deps — pass 2: dependencies between migrated tasks (a blocker that
# was not migrated, because it was closed, is dropped: its block is already moot)
_store_migrate_task_deps() {
  local old_id new_id old_blocker new_blocker
  for old_id in $(_sq "SELECT COALESCE((SELECT json_group_array(old_id) FROM migrated WHERE kind='task'), '[]');" '{}' | "$JQ_BIN" -r '.[]'); do
    new_id="$(_store_migrated_new_id "$old_id")"
    [ -n "$new_id" ] || continue
    for old_blocker in $(_store_bd dep list "$old_id" --direction=down --type blocks --json 2>/dev/null | "$JQ_BIN" -r '.[].id' 2>/dev/null); do
      new_blocker="$(_store_migrated_new_id "$old_blocker")"
      [ -n "$new_blocker" ] && store_native_task_dep_add "$new_id" "$new_blocker"
    done
  done
}

# _store_migrate_messages — every unread message; no per-message note mechanism exists, so
# the "migrated from <old-id>" line goes at the top of the body instead
_store_migrate_messages() {
  local old_id item sender recipient subject body
  for old_id in $(_store_bd list --type message --status open --include-infra --json --limit 0 2>/dev/null | "$JQ_BIN" -r '.[].id'); do
    [ -n "$(_store_migrated_new_id "$old_id")" ] && continue
    item="$(_store_bd show "$old_id" --json 2>/dev/null)" || continue
    sender="$(printf '%s' "$item" | "$JQ_BIN" -r '.[0].created_by // ""')"
    recipient="$(printf '%s' "$item" | "$JQ_BIN" -r '.[0].assignee // ""')"
    subject="$(printf '%s' "$item" | "$JQ_BIN" -r '.[0].title')"
    body="$(printf '%s' "$item" | "$JQ_BIN" -r '.[0].description // ""')"
    new_id="$(store_native_msg_create "$sender" "$recipient" "$subject" "$(printf 'migrated from %s\n\n%s' "$old_id" "$body")")" || continue
    _store_migrate_record "$old_id" "$new_id" message
  done
}

_store_migrate_memories() {
  local raw key text
  raw="$(_store_bd memories --json 2>/dev/null)" || return 0
  for key in $(printf '%s' "$raw" | "$JQ_BIN" -r 'to_entries | map(select(.key != "schema_version")) | .[].key'); do
    text="$(printf '%s' "$raw" | "$JQ_BIN" -r --arg k "$key" '.[$k]')"
    store_native_memory_set "$key" "$text" migrate 2>/dev/null || true
  done
}

_store_cmd_migrate() {
  [ -n "$BD_BIN" ] || die "store: cannot migrate: bd is not installed"
  store_native_ensure || die "store: cannot migrate: native store is not usable"
  _store_migrate_tasks
  _store_migrate_task_deps
  _store_migrate_messages
  _store_migrate_memories
  store_set_kind native
  say "store: migrated into the native store ($(store_db)); switched. Nothing was deleted from Beads."
}

_store_cmd_status() {
  local kind where
  kind="$(store_kind)"
  case "$kind" in
    native) where="$(store_db)" ;;
    beads) where="$(beads_dir 2>/dev/null || printf 'not initialized')" ;;
  esac
  say "store: $kind  ($where)"
  say "  open tasks: $(store_tasks_json "" "open,in_progress,blocked" 2>/dev/null | "$JQ_BIN" 'length' 2>/dev/null || printf 0)   unread messages: $("store_${kind}_unread_count" 2>/dev/null || printf 0)   memories: $(store_memory_list_json 2>/dev/null | "$JQ_BIN" 'length' 2>/dev/null || printf 0)"
}

# cmd_store [native|beads [--migrate]] — teamctl store (lib/beads.sh owns the workspace
# bootstrap itself; this only switches which backend wolfmux reads and writes)
cmd_store() {
  load_project
  case "${1:-}" in
    "") _store_cmd_status ;;
    native)
      if [ "${2:-}" = "--migrate" ]; then
        _store_cmd_migrate
      else
        store_native_ensure || die "store: native store is not usable"
        store_set_kind native
        say "store: switched to native ($(store_db)). Agents started before the switch were taught the other store's commands and should be restarted."
      fi
      ;;
    beads)
      [ -n "$BD_BIN" ] || die "store: cannot switch to beads: bd is not installed"
      beads_dir >/dev/null 2>&1 || die "store: cannot switch to beads: no Beads workspace in $(short_path "$ROOT") (teamctl start --init-beads)"
      store_set_kind beads
      say "store: switched to beads. Agents started before the switch were taught the other store's commands and should be restarted."
      ;;
    *) die_usage "usage: teamctl store [native|beads [--migrate]]" ;;
  esac
}
