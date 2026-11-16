#!/bin/bash
# tests/native-callsites.sh — v1.24.0 (D8): the v1.23.0 code that asked bd directly works on a
# native-store project and never runs bd there. BD_BIN is a stub that records any call.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-native-callsites.XXXXXX")"
export WOLFMUX_HOME="$REPO/config/wolfmux"
export WOLFMUX_DATA="$WORK/data"
export WOLFMUX_PROVIDERS=""
export WOLFMUX_TMUX_SOCKET="wolfmux-native-callsites-$$"
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR WOLFMUX_IDENTITY WOLFMUX_RUN_DIR WOLFMUX_TEAM WOLFMUX_TEAM_ARG
unset WOLFMUX_STORE WOLFMUX_SQLITE_BIN TMUX TMUX_PANE WOLFMUX_NOTIFY BEADS_DIR

for module in provider-env common registry tmuxctl worktree beads policy approvals agents store inbox mail tasks reclaim finish restore doctor; do
  # shellcheck source=/dev/null
  . "$WOLFMUX_HOME/lib/$module.sh"
done

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
cleanup() { /bin/rm -rf "$WORK"; }
trap cleanup EXIT

# Any bd call leaves a mark; a native project must never make one.
BD_MARK="$WORK/bd-called"
/bin/mkdir -p "$WORK/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s"\nexit 1\n' "$BD_MARK" >"$WORK/bin/bd"
/bin/chmod +x "$WORK/bin/bd"
BD_BIN="$WORK/bin/bd"
no_bd() { [ ! -e "$BD_MARK" ]; }

dir="$WORK/proj"
/bin/mkdir -p "$dir"
(cd "$dir" && "$GIT_BIN" init -q -b main && echo hi >README.md && "$GIT_BIN" add -A &&
  "$GIT_BIN" -c user.name=t -c user.email=t@example.invalid commit -qm init) >/dev/null
cd "$dir" || exit 1
load_project
TEAM="$WOLFMUX_DEFAULT_TEAM"
team_paths "$TEAM"
/bin/mkdir -p "$STATE_DIR/agents"
store_set_kind native
store_native_ensure

echo "== the human's inbox (badge, popup)"
mid="$(store_msg_create lead "$WOLFMUX_HUMAN" "Look at this" "the body of it")"
mail_announce create "$(store_item_json "$mid")" lead
check "a native message to the human adds one index row (mail_announce)" '[ "$(human_inbox_count)" = 1 ]'
: >"$(human_inbox_file)"
check "human_inbox_reconcile reads the native store" 'human_inbox_reconcile && [ "$(human_inbox_count)" = 1 ]'
check "_hi_native_show prints the body" '_hi_native_show "$mid" | grep -q "the body of it"'
_hi_load
check "_hi_close marks it read in the store" '_hi_close "$mid" && [ "$(store_item_json "$mid" | "$JQ_BIN" -r .status)" = closed ]'
check "_hi_close empties the index" '[ "$(human_inbox_count)" = 0 ]'
check "the notices footer names teamctl mail, not bd" 'grep -q "Tasks and messages themselves: teamctl mail" "$WOLFMUX_HOME/lib/inbox.sh"'

echo "== a message shown by a hook"
m2="$(store_msg_create lead w9 "Hi" "b")"
/bin/mkdir -p "$WORK/spool/seen"
store_item_json "$m2" >"$WORK/spool/1.json"
_mail_mark_shown "$WORK/spool/1.json" "$WORK/spool/seen" w9
check "native: a shown message is marked read in the store (detached)" \
  'for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(store_item_json "$m2" | "$JQ_BIN" -r .status)" = closed ] && break; sleep 0.5; done; [ "$(store_item_json "$m2" | "$JQ_BIN" -r .status)" = closed ]'

echo "== reclaim and finish"
printf '{"role":"w1","kind":"worker"}\n' | reg_put w1
t1="$(store_task_create lead "$(team_identity "$TEAM" w1)" 2 "Do it" "x")"
t2="$(store_task_create lead "$(team_identity "$TEAM" w1)" 2 "Done one" "x")"
store_task_close "$t2" "finished" >/dev/null 2>&1 || true
f="$WORK/tasks.json"
check "reclaim_native_tasks writes a list in bd's shape" 'reclaim_native_tasks "$f" && [ "$("$JQ_BIN" length "$f")" = 2 ]'
check "a closed task carries closed_at" '[ -n "$("$JQ_BIN" -r --arg id "$t2" ".[] | select(.id==\$id) | .closed_at // empty" "$f")" ]'
check "reclaim_beads_load reads the native store" 'reclaim_beads_load && [ -f "$RECLAIM_BEADS_FILE" ]'
reclaim_task w1 >/dev/null 2>&1 || true
check "reclaim_task: the lane's open task holds it" '[ "$RECLAIM_WHY" = "task open ($t1)" ]'
store_task_close "$t1" "finished" >/dev/null 2>&1 || true
reclaim_beads_forget
check "reclaim_task: a lane whose tasks are closed is done" 'reclaim_task w1 && [ -n "$RECLAIM_TASK" ]'
reclaim_beads_forget
reclaim_beads_forget
store_task_create lead "$(team_identity "$TEAM" w1)" 2 "Again" "x" >/dev/null
check "team_tasks_open counts the open task only" 'team_tasks_open && [ "$TEAM_TASKS_OPEN" = 1 ]'
team_beads_forget

echo "== restore"
STUB_LOG="$WORK/restore-args"
restore_teamctl() { printf '%s\n' "$WORK/bin/teamctl-stub"; }
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s"\nprintf "m42\\n"\n' "$STUB_LOG" >"$WORK/bin/teamctl-stub"
/bin/chmod +x "$WORK/bin/teamctl-stub"
check "restore_kind sees the native store" '[ "$(restore_kind "$dir")" = native ]'
check "restore_read_hint names teamctl mail" '[ "$(restore_read_hint "$dir" "$TEAM")" = "teamctl mail" ]'
check "restore_tell sends through teamctl send and prints its id" '[ "$(restore_tell "$dir" "$TEAM" "T" "B")" = m42 ] && grep -q "send $WOLFMUX_LEAD_ROLE T B" "$STUB_LOG"'

echo "== doctor and agents"
check "restart probes Beads only on a beads store" 'grep -q "\"\$(store_kind)\" = \"beads\" \] && \[ -n \"\$BD_BIN\" \] && ! beads_dir" "$WOLFMUX_HOME/lib/agents.sh"'
check "the --repo BEADS_DIR export is beads only" 'grep -q "BEADS_DIR:-}\" \] && \[ \"\$(store_kind)\" = \"beads\" \]" "$WOLFMUX_HOME/lib/agents.sh"'
check "the spawn refusal names teamctl send" 'grep -q "Ask it: teamctl send" "$WOLFMUX_HOME/lib/agents.sh"'

echo "== the handover a founded team's lead starts with"
printf '{"role":"%s","kind":"lead","handover":"demo-abc1","spawned_by":"lead"}\n' "$WOLFMUX_LEAD_ROLE" | reg_put "$WOLFMUX_LEAD_ROLE"
HANDOVER="$(handover_text)"
check "a native lead's handover prompt says teamctl show <id>" 'printf "%s" "$HANDOVER" | grep -qF "teamctl show demo-abc1"'
check "  ... and never names bd" '! printf "%s" "$HANDOVER" | grep -qw bd'

check "no bd call was made on the native project" 'no_bd'
[ -e "$BD_MARK" ] && sed 's/^/    bd: /' "$BD_MARK"
# Last: doctor reports bd's version when it is installed, and only that, on a native project.
check "doctor's Beads section says the store is native" '_doc_beads 2>&1 | grep -q "store is native"'
check "doctor asks bd nothing but its version there" '[ "$(grep -cv "^version$" "$BD_MARK" 2>/dev/null)" = 0 ]'

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
