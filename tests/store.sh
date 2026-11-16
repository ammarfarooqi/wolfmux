#!/bin/bash
# tests/store.sh — contract tests for lib/store.sh: the same checks against both backends
# (native always; the beads half only when `bd` is installed, otherwise reported skipped),
# then native-only hostile-input, concurrency and store_kind checks. Standalone, under 60s.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-store-test.XXXXXX")"
export WOLFMUX_HOME="$REPO/config/wolfmux"
export WOLFMUX_DATA="$WORK/data"
export WOLFMUX_PROVIDERS=""
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR WOLFMUX_TEAM WOLFMUX_TEAM_ARG WOLFMUX_STORE WOLFMUX_SQLITE_BIN TMUX TMUX_PANE WOLFMUX_NOTIFY

for module in provider-env common registry tmuxctl worktree beads policy approvals agents; do
  # shellcheck source=/dev/null
  . "$WOLFMUX_HOME/lib/$module.sh"
done
# shellcheck source=/dev/null
. "$WOLFMUX_HOME/lib/store.sh"

passed=0
failed=0
check() { # <description> <command string>
  if eval "$2" >/dev/null 2>&1; then
    passed=$((passed + 1))
    printf '  pass  %s\n' "$1"
  else
    failed=$((failed + 1))
    printf '  FAIL  %s\n' "$1"
  fi
}
skip() { printf '  skip  %s\n' "$1"; }

cleanup() { /bin/rm -rf "$WORK"; }
trap cleanup EXIT

new_repo() { # <name> — a throwaway git repo, cd'd into, with the project loaded
  local dir="$WORK/$1"
  /bin/mkdir -p "$dir"
  (cd "$dir" && "$GIT_BIN" init -q -b main && echo hello >README.md && "$GIT_BIN" add -A \
    && "$GIT_BIN" -c user.name=test -c user.email=test@example.invalid commit -qm initial) >/dev/null
  cd "$dir" || exit 1
  load_project
}
new_native_repo() { # <name> — a fresh repo, switched to and usable on the native store
  new_repo "$1"
  store_set_kind native
  store_native_ensure
}
new_beads_repo() { # <name> — a fresh repo, with a Beads workspace, switched to beads
  new_repo "$1"
  beads_ensure yes >/dev/null 2>&1
  store_set_kind beads
}

HAVE_BD=0
command -v bd >/dev/null 2>&1 && HAVE_BD=1

# ============================================================================
# the ITEM-shape contract, run once per backend
# ============================================================================
run_contract() { # <label>
  local label="$1" tid bid mid rid out blocked
  echo "== $label: tasks"
  tid="$(store_task_create alice bob 2 "Ship it" "the body")"
  check "task_create prints a valid id" 'valid_bead_id "$tid"'
  out="$(store_item_json "$tid")"
  check "item_json: issue_type task" '[ "$(printf %s "$out" | "$JQ_BIN" -r .issue_type)" = task ]'
  check "item_json: title round-trips" '[ "$(printf %s "$out" | "$JQ_BIN" -r .title)" = "Ship it" ]'
  check "item_json: status open" '[ "$(printf %s "$out" | "$JQ_BIN" -r .status)" = open ]'
  check "item_json: assignee bob" '[ "$(printf %s "$out" | "$JQ_BIN" -r .assignee)" = bob ]'
  check "item_json: notes empty" '[ "$(printf %s "$out" | "$JQ_BIN" -r .notes)" = "" ]'

  bid="$(store_task_create alice carol 1 "Blocker" "x")"
  store_task_dep_add "$tid" "$bid"
  check "tasks_json includes blocked_by for an open blocker" \
    '[ "$(store_tasks_json "" "" | "$JQ_BIN" -r --arg id "$tid" ".[] | select(.id==\$id) | .blocked_by | length")" = 1 ]'
  store_task_close "$bid" "done with it" "" carol
  check "tasks_json: blocked_by drops a closed blocker" \
    '[ "$(store_tasks_json "" "" | "$JQ_BIN" -r --arg id "$tid" ".[] | select(.id==\$id) | .blocked_by | length")" = 0 ]'

  check "task_claim: open task, nobody assigned yet -> claimed" 'store_task_claim "$tid" bob'
  check "task_claim: same identity again is idempotent" 'store_task_claim "$tid" bob'
  check "task_claim: a different identity is refused, nothing changes" '! store_task_claim "$tid" erin'
  check "item_json after claim: in_progress, assignee bob" \
    '[ "$(store_item_json "$tid" | "$JQ_BIN" -r "[.status,.assignee] | @csv")" = "\"in_progress\",\"bob\"" ]'

  store_task_status "$tid" blocked
  check "task_status: moved to blocked" '[ "$(store_item_json "$tid" | "$JQ_BIN" -r .status)" = blocked ]'
  store_task_note "$tid" dave "waiting on design"
  check "task_note: appended, carries author and text" \
    'printf %s "$(store_item_json "$tid" | "$JQ_BIN" -r .notes)" | grep -q "dave.*waiting on design"'
  store_task_close "$tid" "shipped" failed bob
  check "task_close failed: status closed" '[ "$(store_item_json "$tid" | "$JQ_BIN" -r .status)" = closed ]'

  echo "== $label: messages"
  mid="$(store_msg_create alice bob "Subject one" "body one")"
  check "msg_create prints a valid id" 'valid_bead_id "$mid"'
  check "inbox_json: bob sees the unread message" \
    '[ "$(store_inbox_json bob | "$JQ_BIN" -r --arg id "$mid" "[.[] | select(.id==\$id)] | length")" = 1 ]'
  rid="$(store_msg_create bob alice "Re: Subject one" "reply body" "$mid")"
  check "msg_create (reply) prints a valid id" 'valid_bead_id "$rid"'
  check "thread_json: both messages present" \
    '[ "$(store_thread_json "$mid" | "$JQ_BIN" "length")" -ge 2 ]'
  check "msg_create: replying to a TASK id (a worker's report about it) still creates the message" \
    'tmid="$(store_msg_create bob alice "Re: a task" "about $tid" "$tid")"; valid_bead_id "$tmid"'
  store_msg_read bob "$mid"
  check "msg_read: no longer in bob's inbox" \
    '[ "$(store_inbox_json bob | "$JQ_BIN" -r --arg id "$mid" "[.[] | select(.id==\$id)] | length")" = 0 ]'
  check "msg_read: a foreign id is skipped, not an error" 'store_msg_read bob "$rid"'

  echo "== $label: memories"
  store_memory_set release-notes "first draft" alice
  check "memory_list_json finds the key" \
    '[ "$(store_memory_list_json | "$JQ_BIN" -r "[.[] | select(.key==\"release-notes\")] | length")" = 1 ]'
  store_memory_set release-notes "second draft, replaced" bob
  check "memory_set replaces an existing key" \
    '[ "$(store_memory_list_json | "$JQ_BIN" -r ".[] | select(.key==\"release-notes\") | .text")" = "second draft, replaced" ]'
  check "memory_list_json query matches a substring" \
    '[ "$(store_memory_list_json replaced | "$JQ_BIN" length)" -ge 1 ]'
  check "memory_text includes the heading and text" \
    'store_memory_text 10000 | grep -q "### release-notes" && store_memory_text 10000 | grep -q "second draft, replaced"'
  check "memory_text respects a tiny budget (nothing, or well under it)" \
    '[ "$(store_memory_text 1 | wc -c | tr -d " ")" -le 1 ]'
  store_memory_forget release-notes
  check "memory_forget removes the key" \
    '[ "$(store_memory_list_json | "$JQ_BIN" -r "[.[] | select(.key==\"release-notes\")] | length")" = 0 ]'
  check "memory_forget on a missing key fails" '! store_memory_forget release-notes'
}

new_native_repo native-contract
run_contract "native"

if [ "$HAVE_BD" -eq 1 ]; then
  new_beads_repo beads-contract
  run_contract "beads"
  echo "== beads: a title that starts with a dash (Riley 11)"
  dtid="$(store_task_create lead bob 2 "-p" "x")"
  check "beads task_create: a title \"-p\" is a title, not a flag" \
    'valid_bead_id "$dtid" && [ "$(store_item_json "$dtid" | "$JQ_BIN" -r .title)" = "-p" ]'
  dmid="$(store_msg_create lead bob "--help" "x")"
  check "beads msg_create: a subject \"--help\" is a subject, not a flag" \
    'valid_bead_id "$dmid" && [ "$(store_item_json "$dmid" | "$JQ_BIN" -r .title)" = "--help" ]'
  drid="$(store_msg_create bob lead "-r reply" "x" "$dmid")"
  check "beads msg_create (reply): a subject starting with a dash works" \
    'valid_bead_id "$drid" && [ "$(store_item_json "$drid" | "$JQ_BIN" -r .title)" = "-r reply" ]'
  echo "== beads: close carries the actor, no --force (Riley 1)"
  gid_b="$(store_task_create lead bob 2 "Guarded" "x")"
  check "beads task_close: a non-assignee actor is refused by bd, the task stays open" \
    '! store_task_close "$gid_b" "not mine" "" mallory && [ "$(store_item_json "$gid_b" | "$JQ_BIN" -r .status)" = open ]'
  check "beads task_close: the assignee closes it without force" \
    'store_task_close "$gid_b" "mine" "" bob && [ "$(store_item_json "$gid_b" | "$JQ_BIN" -r .status)" = closed ]'
  gid_c="$(store_task_create lead bob 2 "Lead closes" "x")"
  check "beads task_close: force (the lead) closes another's task" \
    'store_task_close "$gid_c" "lead" "" lead force && [ "$(store_item_json "$gid_c" | "$JQ_BIN" -r .status)" = closed ]'
else
  skip "beads contract: bd is not installed"
fi

# ============================================================================
# native only: hostile input, size, concurrency, store_ensure, missing sqlite3
# ============================================================================
new_native_repo native-hostile

echo "== native: hostile text round-trips byte for byte"
HOSTILE='quotes " and '"'"' ; DROP TABLE task;-- newline
backtick ` and $(touch '"$WORK"'/pwned) emoji 🎉'
hid="$(store_task_create alice bob 2 "$HOSTILE" "$HOSTILE")"
check "hostile title round-trips exactly" \
  '[ "$(store_item_json "$hid" | "$JQ_BIN" -r .title)" = "$HOSTILE" ]'
check "hostile body round-trips exactly" \
  '[ "$(store_item_json "$hid" | "$JQ_BIN" -r .description)" = "$HOSTILE" ]'
check "nothing in the hostile text executed (no pwned file)" '[ ! -e "$WORK/pwned" ]'

echo "== native: a 300 KB body"
BIG="$(/usr/bin/python3 -c "print('x'*300000)" 2>/dev/null || /usr/bin/perl -e 'print "x" x 300000')"
gid="$(store_task_create alice bob 2 "Big" "$BIG")"
big_out="$(store_item_json "$gid" | "$JQ_BIN" -r .description)"
check "300 KB body round-trips at full length" '[ "$big_out" = "$BIG" ]'

echo "== native: concurrency"
claim_race_dir="$WORK/claim-race"
race_tid="$(store_task_create alice "" 2 "Race" "x")"
pids=""
i=1
while [ "$i" -le 10 ]; do
  (store_task_claim "$race_tid" "worker$i" && echo "worker$i" >>"$WORK/winner") &
  pids="$pids $!"
  i=$((i + 1))
done
wait $pids
winners="$(wc -l <"$WORK/winner" 2>/dev/null | tr -d ' ')"
check "ten parallel claims: exactly one winner" '[ "$winners" = 1 ]'

pids=""
i=1
while [ "$i" -le 20 ]; do
  (store_msg_create alice bob "concurrent $i" "x" >>"$WORK/msg-ids") &
  pids="$pids $!"
  i=$((i + 1))
done
wait $pids
msg_rows="$(wc -l <"$WORK/msg-ids" 2>/dev/null | tr -d ' ')"
msg_unique="$(sort -u "$WORK/msg-ids" 2>/dev/null | wc -l | tr -d ' ')"
check "twenty parallel msg_create: twenty rows, no errors" '[ "$msg_rows" = 20 ] && [ "$msg_unique" = 20 ]'

new_repo native-ensure-race
pids=""
i=1
while [ "$i" -le 5 ]; do
  (store_native_ensure 2>>"$WORK/ensure-err") &
  pids="$pids $!"
  i=$((i + 1))
done
wait $pids
check "store_ensure by five processes at once: no error, usable afterward" \
  '[ ! -s "$WORK/ensure-err" ] && tid="$(store_task_create a b 2 t b)" && valid_bead_id "$tid"'

echo "== native: missing sqlite3"
SQLITE_BIN_SAVE="$SQLITE_BIN"
SQLITE_BIN=/nonexistent
err_missing="$(store_native_ensure 2>&1)"
check "missing sqlite3: message names what is missing and the other backend" \
  'printf "%s" "$err_missing" | grep -qi "sqlite3" && printf "%s" "$err_missing" | grep -q "WOLFMUX_STORE=beads"'
SQLITE_BIN="$SQLITE_BIN_SAVE"

# ============================================================================
# store_kind
# ============================================================================
echo "== store_kind"
new_repo kind-fresh
check "store_kind: a fresh project defaults to native" '[ "$(store_kind)" = native ]'
new_repo kind-legacy
/bin/mkdir -p "$PROJECT_STATE/agents"
printf '{}' >"$PROJECT_STATE/agents/lead.json"
check "store_kind: an old agent record on disk means beads" '[ "$(store_kind)" = beads ]'
store_set_kind native
check "store_kind: the file wins over the old-record rule" '[ "$(store_kind)" = native ]'

echo "== teamctl store: switching is the lead's (Riley 7)"
new_repo switch-gate
store_set_kind beads
gate_out="$( (TEAM_ROLE=backend BEADS_ACTOR=backend cmd_store native) 2>&1)"
gate_rc=$?
check "store native from a worker is refused (77), the store stays beads" \
  '[ "$gate_rc" -eq 77 ] && [ "$(store_kind)" = beads ]'
check "store beads from a worker is refused (77) before any workspace check" \
  'out="$( (TEAM_ROLE=backend BEADS_ACTOR=backend cmd_store beads) 2>&1)"; [ $? -eq 77 ] && ! printf "%s" "$out" | grep -q "no Beads workspace"'
store_set_kind native
store_native_ensure
store_task_create lead bob 2 "Left behind" "x" >/dev/null
check "store status from a worker still reads" \
  '(TEAM_ROLE=backend BEADS_ACTOR=backend cmd_store) | grep -q "^store: native"'
if [ "$HAVE_BD" -eq 1 ]; then
  beads_ensure yes >/dev/null 2>&1
  behind_out="$( (cmd_store beads) 2>&1)"
  check "switching away from a store that holds work says how much stays behind" \
    'printf "%s" "$behind_out" | grep -q "1 open task.* stay behind in the native store"'
  store_task_create lead bob 2 "Beads work" "x" >/dev/null
  behind_out2="$( (cmd_store native) 2>&1)"
  check "store native without --migrate names --migrate for the Beads work left behind" \
    'printf "%s" "$behind_out2" | grep -q "stay behind in the beads store" && printf "%s" "$behind_out2" | grep -q -- "--migrate"'
else
  skip "store switch: stay-behind counts (bd is not installed)"
fi

new_repo kind-migrate
if [ "$HAVE_BD" -eq 1 ]; then
  beads_ensure yes >/dev/null 2>&1
  store_set_kind beads
  mtid="$(store_task_create alice bob 1 "Migrate me" "body text")"
  store_memory_set carryover "still here" alice
  cmd_store native --migrate >/dev/null 2>&1
  check "migrate: switched to native" '[ "$(store_kind)" = native ]'
  check "migrate: the task is present under a new id" \
    '[ "$(store_tasks_json "" "" | "$JQ_BIN" -r "[.[] | select(.title==\"Migrate me\")] | length")" = 1 ]'
  check "migrate: the memory carried over" \
    '[ "$(store_memory_list_json | "$JQ_BIN" -r "[.[] | select(.key==\"carryover\")] | length")" = 1 ]'
  cmd_store native --migrate >/dev/null 2>&1
  check "migrate: idempotent, a second run does not duplicate" \
    '[ "$(store_tasks_json "" "" | "$JQ_BIN" -r "[.[] | select(.title==\"Migrate me\")] | length")" = 1 ]'

  echo "== migrate: status, blockers and assignee survive; counts; all or nothing (Riley 5)"
  new_repo migrate-lossless
  beads_ensure yes >/dev/null 2>&1
  store_set_kind beads
  m_blocker="$(store_task_create lead qa 1 "M blocker" "b")"
  store_task_claim "$m_blocker" qa
  m_wait="$(store_task_create lead backend 2 "M waiting" "w")"
  store_task_dep_add "$m_wait" "$m_blocker"
  m_blk="$(store_task_create lead backend 2 "M blocked" "x")"
  store_task_status "$m_blk" blocked
  store_msg_create lead backend "M msg one" "1" >/dev/null
  store_msg_create lead qa "M msg two" "2" >/dev/null
  # a failing bd show for one task: nothing switches, the command fails and names the item
  _store_bd_real="$(declare -f _store_bd)"
  eval "_store_bd() { if [ \"\$1\" = show ] && [ \"\$2\" = \"$m_blk\" ]; then return 1; fi; (cd \"\$ROOT\" && \"\$BD_BIN\" \"\$@\"); }"
  fail_out="$( (cmd_store native --migrate) 2>&1)"
  fail_rc=$?
  eval "$_store_bd_real"
  check "migrate: one unreadable item -> non-zero exit, the store is NOT switched" '[ "$fail_rc" -ne 0 ] && [ "$(store_kind)" = beads ]'
  check "migrate: the failure names the item" 'printf "%s" "$fail_out" | grep -q "$m_blk"'
  eval "_store_bd() { if [ \"\$1\" = list ]; then return 1; fi; (cd \"\$ROOT\" && \"\$BD_BIN\" \"\$@\"); }"
  list_out="$( (cmd_store native --migrate) 2>&1)"
  list_rc=$?
  eval "$_store_bd_real"
  check "migrate: a failed bd list is a failure, not zero rows; not switched" '[ "$list_rc" -ne 0 ] && [ "$(store_kind)" = beads ]'
  ok_out="$( (cmd_store native --migrate) 2>&1)"
  ok_rc=$?
  check "migrate: the clean rerun succeeds and switches" '[ "$ok_rc" -eq 0 ] && [ "$(store_kind)" = native ]'
  check "migrate: prints seen and written counts per kind" \
    'printf "%s" "$ok_out" | grep -q "tasks: 3 seen, 3 written" && printf "%s" "$ok_out" | grep -q "messages: 2 seen, 2 written"'
  mrow() { store_tasks_json "" "" | "$JQ_BIN" -c --arg t "$1" '.[] | select(.title==$t)'; }
  check "migrate: an in_progress task stays in_progress, with its assignee" \
    '[ "$(mrow "M blocker" | "$JQ_BIN" -r "[.status,.assignee]|join(\" \")")" = "in_progress qa" ]'
  check "migrate: a blocked task stays blocked" '[ "$(mrow "M blocked" | "$JQ_BIN" -r .status)" = blocked ]'
  check "migrate: a waiting task still waits on its (new) blocker" \
    '[ "$(mrow "M waiting" | "$JQ_BIN" -r ".blocked_by[0]")" = "$(mrow "M blocker" | "$JQ_BIN" -r .id)" ]'
  check "migrate: both unread messages arrived" \
    '[ "$(store_inbox_json backend | "$JQ_BIN" "[.[]|select(.title==\"M msg one\")]|length")" = 1 ] && [ "$(store_inbox_json qa | "$JQ_BIN" "[.[]|select(.title==\"M msg two\")]|length")" = 1 ]'
else
  skip "migrate: bd is not installed"
fi

# ============================================================================
# timing (information, not a check)
# ============================================================================
echo "== timing (ms, average of 5; informational only)"
time_native() {
  new_native_repo "timing-native-$1"
  local t0 t1 n=5 i=1 total=0
  while [ "$i" -le "$n" ]; do
    t0="$(/bin/date +%s%N)"
    "$2" >/dev/null 2>&1
    t1="$(/bin/date +%s%N)"
    total=$((total + (t1 - t0) / 1000000))
    i=$((i + 1))
  done
  echo "  native $1: $((total / n)) ms avg"
}
time_native create 'store_task_create alice bob 2 timing body'
tid_for_inbox="$(store_task_create alice timeruser 2 t b)"
time_native inbox 'store_inbox_json timeruser'
time_native claim 'store_task_claim "$tid_for_inbox" "$(date +%s%N)"'

if [ "$HAVE_BD" -eq 1 ]; then
  time_beads() {
    new_beads_repo "timing-beads-$1"
    local t0 t1 n=5 i=1 total=0
    while [ "$i" -le "$n" ]; do
      t0="$(/bin/date +%s%N)"
      "$2" >/dev/null 2>&1
      t1="$(/bin/date +%s%N)"
      total=$((total + (t1 - t0) / 1000000))
      i=$((i + 1))
    done
    echo "  beads $1: $((total / n)) ms avg"
  }
  time_beads create 'store_task_create alice bob 2 timing body'
  tid_for_inbox_b="$(store_task_create alice timeruser 2 t b)"
  time_beads inbox 'store_inbox_json timeruser'
  time_beads claim 'store_task_claim "$tid_for_inbox_b" "$(date +%s%N)"'
else
  skip "timing (beads): bd is not installed"
fi

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
