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
  store_task_close "$bid" "done with it"
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
  store_task_close "$tid" "shipped" failed
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
