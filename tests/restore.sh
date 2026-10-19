#!/bin/bash
# Restore only scratch teams. All external actions are recorded by stand-ins;
# the snapshot pane list also has a check against a throwaway tmux server.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"

fixture() {
  export RESTORE_TEST="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-restore-test.XXXXXX")"
  export REAL_TMUX="$(command -v tmux)" REAL_JQ="$(command -v jq)"
  export TEST_PID=$$ TEST_ROOT="$RESTORE_TEST/project with spaces"
  export WOLFMUX_HOME="$REPO/config/wolfmux" WOLFMUX_DATA="$RESTORE_TEST/data"
  export WOLFMUX_TMUX_SOCKET="restore-test-$$" WOLFMUX_ROOT="$TEST_ROOT"
  export WOLFMUX_CLAUDE_PROJECTS="$RESTORE_TEST/transcripts"
  export WOLFMUX_CLAUDE_SESSIONS="$RESTORE_TEST/sessions"
  export WOLFMUX_RESTORE_TEAMCTL="$RESTORE_TEST/bin/restart"
  export WOLFMUX_MEMORY_PRESSURE="$RESTORE_TEST/bin/memory_pressure"
  export WOLFMUX_OSASCRIPT="$RESTORE_TEST/bin/osascript"
  export WOLFMUX_RESTORE_LOAD=1 WOLFMUX_RESTORE_LIMIT_WAIT=0
  export WOLFMUX_RESTORE_UP_MAX=0 WOLFMUX_RESTORE_WAIT_MAX=0
  mkdir -p "$RESTORE_TEST/bin" "$TEST_ROOT" "$WOLFMUX_DATA/state" "$WOLFMUX_CLAUDE_PROJECTS/test" "$WOLFMUX_CLAUDE_SESSIONS" "$RESTORE_TEST/up"
  trap '"$REAL_TMUX" -S "$RESTORE_TEST/sock" kill-server >/dev/null 2>&1 || true; /bin/rm -rf "$RESTORE_TEST"' EXIT
  git -C "$TEST_ROOT" init -q
  cat >"$RESTORE_TEST/bin/tmux" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$RESTORE_TEST/tmux.log"
case "$1" in -L|-S) shift 2 ;; *) exit 91 ;; esac
case "$1" in
  list-clients) cat "$RESTORE_TEST/clients" 2>/dev/null; exit 0 ;;
  has-session) name="${3#=}"; test -f "$RESTORE_TEST/up/$name" ;;
  list-panes) name="${4#=}"; test -f "$RESTORE_TEST/up/$name" && printf '%%%s lead\n' "$name" ;;
  display-message)
    if [ "${3:-}" != -t ]; then echo 'new-server 100'; exit 0; fi
    name="${4#%}"
    test -f "$RESTORE_TEST/up/$name" || exit 1
    if [ -f "$RESTORE_TEST/defer" ]; then
      count=$(cat "$RESTORE_TEST/polls" 2>/dev/null || echo 0)
      count=$((count + 1)); echo "$count" >"$RESTORE_TEST/polls"
      if [ "$count" -ge 3 ] && [ ! -f "$WOLFMUX_CLAUDE_SESSIONS/$TEST_PID.json" ]; then
        cp "$RESTORE_TEST/record" "$WOLFMUX_CLAUDE_SESSIONS/$TEST_PID.json"
        echo "ready $name" >>"$RESTORE_TEST/actions"
      fi
    fi
    echo '0 '
    ;;
  *) echo "unexpected tmux: $*" >&2; exit 92 ;;
esac
STUB
  cat >"$RESTORE_TEST/bin/restart" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$RESTORE_TEST/actions"
[ "$1" = --team ] || exit 93
team="$2"; shift 2
[ "$1" = restart ] || exit 0
[ ! -f "$RESTORE_TEST/fail-restart" ] || exit 9
if [ -f "$RESTORE_TEST/fail-model" ] && [ "${3:-}" = --model ]; then exit 8; fi
dir="$WOLFMUX_DATA/state/$TEST_KEY/teams/$team"
sid=$("$REAL_JQ" -r '.session_id // ""' "$dir/agents/lead.json")
[ -n "$sid" ] || sid="found-$team"
touch "$RESTORE_TEST/up/$team"
rm -f "$WOLFMUX_CLAUDE_SESSIONS/$TEST_PID.json" "$RESTORE_TEST/polls"
"$REAL_JQ" -cn --arg sid "$sid" --arg tmux "$team:0" '{sessionId:$sid,tmux:$tmux}' >"$RESTORE_TEST/record"
if [ ! -f "$RESTORE_TEST/defer" ]; then
  cp "$RESTORE_TEST/record" "$WOLFMUX_CLAUDE_SESSIONS/$TEST_PID.json"
  echo "ready $team" >>"$RESTORE_TEST/actions"
fi
if [ -f "$RESTORE_TEST/limit" ]; then
  "$REAL_JQ" -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{timestamp:$ts,isApiErrorMessage:true,message:{content:[{type:"text",text:"You have reached your Fable limit"}]}}' >>"$WOLFMUX_CLAUDE_PROJECTS/test/$sid.jsonl"
fi
STUB
  cat >"$RESTORE_TEST/bin/bd" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$RESTORE_TEST/beads"
[ ! -f "$RESTORE_TEST/fail-beads" ] || exit 1
echo test-abc
STUB
  cat >"$RESTORE_TEST/bin/memory_pressure" <<'STUB'
#!/bin/bash
echo "System-wide memory free percentage: $(cat "$RESTORE_TEST/free" 2>/dev/null || echo 80)%"
STUB
  cat >"$RESTORE_TEST/bin/osascript" <<'STUB'
#!/bin/bash
echo osascript >>"$RESTORE_TEST/actions"
if [ "$1" = -e ]; then cat "$RESTORE_TEST/iterm" 2>/dev/null || echo true; exit 0; fi
cat >"$RESTORE_TEST/apple"
[ ! -f "$RESTORE_TEST/fail-osascript" ] || { echo 'Automation denied'; exit 1; }
STUB
  cat >"$RESTORE_TEST/bin/jq" <<'STUB'
#!/bin/bash
echo jq >>"$RESTORE_TEST/jq.log"
exec "$REAL_JQ" "$@"
STUB
  chmod +x "$RESTORE_TEST/bin/"*
  export PATH="$RESTORE_TEST/bin:$PATH"
  for module in provider-env common registry tmuxctl worktree disk reclaim finish beads policy approvals agents views dashboard restore brand inbox; do
    . "$WOLFMUX_HOME/lib/$module.sh"
  done
  TEAMCTL_SELF="$REPO/bin/teamctl"
  export TEST_KEY="$(project_key "$TEST_ROOT")"
  cd "$TEST_ROOT"
}

team() {
  local name="$1" family="${2:-claude}" sid="${3-sid-$1}" founder="${4:-operator}" dir
  dir="$WOLFMUX_DATA/state/$TEST_KEY/teams/$name"
  mkdir -p "$dir/agents"
  jq -n --arg root "$TEST_ROOT" --arg session "$name" --arg founder "$founder" '{root:$root,session:$session,founder:$founder}' >"$dir/meta.json"
  jq -cn --arg sid "$sid" --arg family "$family" --arg founder "$founder" --arg root "$TEST_ROOT" '{role:"lead",model:"fable",label:"Fable",family:$family,session_id:$sid,spawned_by:$founder,workdir:$root}' >"$dir/agents/lead.json"
  [ -z "$sid" ] || touch "$WOLFMUX_CLAUDE_PROJECTS/test/$sid.jsonl"
}
snapshot() {
  local name
  for name in "$@"; do
    jq -cn --arg key "$TEST_KEY" --arg team "$name" --arg root "$TEST_ROOT" '{key:$key,team:$team,root:$root,session:$team,model:"fable",family:"claude",label:"Fable",session_id:("sid-"+$team),founder:"operator"}'
  done | jq -cs '{epoch:100,ts:"2026-01-01T00:00:00Z",server:"old-server 1",teams:.,tabs:(reverse | map({key,team,session}))}' >"$WOLFMUX_DATA/state/running.json"
}
run_restore() { cmd_restore "$@" >"$RESTORE_TEST/out" 2>&1; }
has() { grep -Fq -- "$2" "$1"; }
absent() { ! grep -Fq -- "$2" "$1"; }
actions() { cat "$RESTORE_TEST/actions"; }

selection() {
  for name in crash stopped finished gone old; do team "$name"; done
  snapshot crash stopped finished gone
  for name in stopped finished; do
    printf '{"ts":"2026-01-02T00:00:00Z","reason":"%s"}\n' "$name" >"$WOLFMUX_DATA/state/$TEST_KEY/teams/$name/lead-end.json"
  done
  rm "$WOLFMUX_DATA/state/$TEST_KEY/teams/gone/agents/lead.json"
  run_restore --yes --no-tabs
  has "$RESTORE_TEST/actions" '--team crash restart lead --resume sid-crash'
  absent "$RESTORE_TEST/actions" '--team old'
  for name in stopped finished gone; do
    has "$RESTORE_TEST/out" "skip $name"
    absent "$RESTORE_TEST/actions" "--team $name"
  done
}
resume_order() {
  team a; team b codex; team c claude ''; snapshot a b c
  run_restore --yes --no-tabs
  printf '%s\n' '--team a restart lead --resume sid-a' 'ready a' '--team a nudge lead --id test-abc' '--team b restart lead --continue' 'ready b' '--team b nudge lead --id test-abc' '--team c restart lead --continue' 'ready c' '--team c nudge lead --id test-abc' >"$RESTORE_TEST/expected"
  cmp "$RESTORE_TEST/expected" "$RESTORE_TEST/actions"
  has "$RESTORE_TEST/out" 'no stored conversation id'
  has "$RESTORE_TEST/out" 'Codex: --continue'
  [ "$(wc -l <"$RESTORE_TEST/beads" | tr -d ' ')" = 3 ]
  for name in a b c; do
    has "$RESTORE_TEST/beads" "-t message -a $name.lead"
    jq -e '.type == "restore" and .by == "operator"' "$WOLFMUX_DATA/state/$TEST_KEY/teams/$name/events.jsonl"
  done
  [ "$(jq -s 'length' "$WOLFMUX_DATA/state/restore.log")" = 3 ]
}
wait_record() {
  team a; team b; snapshot a b
  touch "$RESTORE_TEST/defer"
  RESTORE_UP_MAX=5 RESTORE_POLL=1
  run_restore --yes --no-tabs
  has "$RESTORE_TEST/out" 'up: conversation sid-a is running'
  [ "$(sed -n '2p' "$RESTORE_TEST/actions")" = 'ready a' ]
  [ "$(sed -n '4p' "$RESTORE_TEST/actions")" = '--team b restart lead --resume sid-b' ]
}
missing_transcript() {
  team a; snapshot a; rm "$WOLFMUX_CLAUDE_PROJECTS/test/sid-a.jsonl"
  run_restore --yes --no-tabs
  has "$RESTORE_TEST/actions" '--team a restart lead --continue'
  has "$RESTORE_TEST/out" 'has no transcript here'
}
busy_memory() {
  team a; team b; snapshot a b; echo 24 >"$RESTORE_TEST/free"
  if run_restore --yes --no-tabs; then return 1; fi
  has "$RESTORE_TEST/out" 'gave up waiting: memory free 24%'
  has "$RESTORE_TEST/out" 'NOT restored b'
  [ ! -f "$RESTORE_TEST/actions" ]
}
busy_load() {
  team a; snapshot a; WOLFMUX_RESTORE_LOAD=20.01
  if run_restore --yes --no-tabs; then return 1; fi
  has "$RESTORE_TEST/out" 'load 20.01'
  [ ! -f "$RESTORE_TEST/actions" ]
}
room_recovers() {
  echo 24 >"$RESTORE_TEST/free"
  RESTORE_WAIT_MAX=2 RESTORE_WAIT_STEP=1
  sleep() { echo 25 >"$RESTORE_TEST/free"; }
  WOLFMUX_RESTORE_LOAD=20.00
  restore_room >"$RESTORE_TEST/out"
  has "$RESTORE_TEST/out" 'waiting: memory free 24%'
}
limit_report() {
  team a; snapshot a; touch "$RESTORE_TEST/limit"
  [ "$(policy_get restore-on-limit)" = report ]
  run_restore --yes --no-tabs
  has "$RESTORE_TEST/out" 'blocked on a model limit'
  has "$RESTORE_TEST/out" 'Fable limit'
  [ "$(grep -c ' restart ' "$RESTORE_TEST/actions")" = 1 ]
}
limit_model() {
  team a; snapshot a; touch "$RESTORE_TEST/limit"
  export WOLFMUX_RESTORE_ON_LIMIT=opus
  run_restore --yes --no-tabs
  has "$RESTORE_TEST/actions" '--team a restart lead --model opus --resume sid-a'
  has "$RESTORE_TEST/out" 'moved a: to opus'
}
limit_stale() {
  team a; snapshot a
  echo '{"timestamp":"2000-01-01T00:00:00Z","isApiErrorMessage":true,"message":{"content":[{"text":"Fable limit"}]}}' >"$WOLFMUX_CLAUDE_PROJECTS/test/sid-a.jsonl"
  run_restore --yes --no-tabs
  absent "$RESTORE_TEST/out" 'blocked on a model limit'
}
worker_refused() {
  team a; snapshot a
  if (TEAM_ROLE=worker run_restore --yes --no-tabs); then return 1; else [ "$?" = 77 ]; fi
  [ ! -f "$RESTORE_TEST/actions" ]
}
other_lead_refused() {
  team a; snapshot a
  if (TEAM_ROLE=lead WOLFMUX_TEAM=other run_restore --yes); then return 1; else [ "$?" = 77 ]; fi
}
dry_worker() {
  team a; snapshot a; cp "$WOLFMUX_DATA/state/running.json" "$RESTORE_TEST/before"
  TEAM_ROLE=worker run_restore --dry-run
  has "$RESTORE_TEST/out" 'will restore 1 team'
  [ ! -f "$RESTORE_TEST/actions" ] && [ ! -f "$RESTORE_TEST/beads" ]
  [ ! -f "$WOLFMUX_DATA/state/restore.log" ]
  cmp "$RESTORE_TEST/before" "$WOLFMUX_DATA/state/running.json"
}
steward() {
  team a; team b claude sid-b other.lead; snapshot a b
  export TEAM_ROLE=lead WOLFMUX_TEAM=comms WOLFMUX_ORPHAN_STEWARD=comms
  run_restore --yes --no-tabs
  has "$RESTORE_TEST/actions" '--team a restart'
  absent "$RESTORE_TEST/actions" '--team b'
  has "$RESTORE_TEST/out" 'founded by other.lead'
  jq -e '.by == "comms.lead"' "$WOLFMUX_DATA/state/restore.log"
}
tabs_order() {
  team a; team b; snapshot a b
  run_restore --yes
  [ "$(grep 'write text' "$RESTORE_TEST/apple" | head -1 | grep -c -- '--team b attach')" = 1 ]
  [ "$(grep 'write text' "$RESTORE_TEST/apple" | tail -1 | grep -c -- '--team a attach')" = 1 ]
  [ "$(tail -2 "$RESTORE_TEST/actions" | grep -c '^osascript$')" = 2 ]
}
tabs_attached() {
  team a; team b; snapshot a b; echo b >"$RESTORE_TEST/clients"
  run_restore --yes
  absent "$RESTORE_TEST/apple" '--team b attach'
  has "$RESTORE_TEST/out" 'already on a screen: b'
}
tabs_failure() {
  team a; snapshot a; touch "$RESTORE_TEST/fail-osascript"
  run_restore --yes
  has "$RESTORE_TEST/out" 'osascript failed'
  has "$RESTORE_TEST/out" '--team a attach'
}
tabs_not_running() {
  team a; snapshot a; echo false >"$RESTORE_TEST/iterm"
  run_restore --yes
  has "$RESTORE_TEST/out" 'iTerm2 is not running'
  has "$RESTORE_TEST/out" '--team a attach'
  [ ! -f "$RESTORE_TEST/apple" ]
}
no_tabs() {
  team a; snapshot a; run_restore --yes --no-tabs
  absent "$RESTORE_TEST/actions" osascript
}
idempotent() {
  team a; snapshot a; run_restore --yes --no-tabs
  cp "$RESTORE_TEST/actions" "$RESTORE_TEST/before"
  run_restore --yes --no-tabs
  has "$RESTORE_TEST/out" 'already up: a'
  cmp "$RESTORE_TEST/before" "$RESTORE_TEST/actions"
}
confirm_abort() {
  team a; snapshot a
  if run_restore --no-tabs <<<no; then return 1; fi
  has "$RESTORE_TEST/out" 'aborted'
  [ ! -f "$RESTORE_TEST/actions" ]
}
confirm_eof() {
  team a; snapshot a
  if run_restore --no-tabs </dev/null; then return 1; fi
  [ ! -f "$RESTORE_TEST/actions" ]
}
confirm_enter() {
  team a; team b; snapshot a b
  run_restore --no-tabs <<<''
  [ "$(grep -c 'Press Enter' "$RESTORE_TEST/out")" = 1 ]
  has "$RESTORE_TEST/out" '2 of 2 team(s) brought back'
}
restart_failure() {
  team a; snapshot a; touch "$RESTORE_TEST/fail-restart"
  if run_restore --yes --no-tabs; then return 1; fi
  has "$RESTORE_TEST/out" 'restart failed (exit 9)'
  absent "$RESTORE_TEST/actions" nudge
}
beads_failure() {
  team a; snapshot a; touch "$RESTORE_TEST/fail-beads"
  run_restore --yes --no-tabs
  has "$RESTORE_TEST/actions" '--team a nudge lead'
  absent "$RESTORE_TEST/actions" '--id'
}
snapshot_content() {
  team a; team b codex; team orphan
  "$REAL_TMUX" -S "$RESTORE_TEST/sock" -f /dev/null new-session -d -s a 'sleep 120'
  "$REAL_TMUX" -S "$RESTORE_TEST/sock" set-option -p -t a @ai_role lead
  "$REAL_TMUX" -S "$RESTORE_TEST/sock" new-session -d -s b 'sleep 120'
  "$REAL_TMUX" -S "$RESTORE_TEST/sock" set-option -p -t b @ai_role lead
  local panes
  panes="$("$REAL_TMUX" -S "$RESTORE_TEST/sock" list-panes -a -F '#{session_name}|#{@ai_role}|#{pane_id}|#{pane_dead}|#{pane_pid}')"
  printf '123 100|20|a\n123 100|10|b\n123 100|30|b\n' >"$RESTORE_TEST/clients"
  : >"$RESTORE_TEST/tmux.log"; : >"$RESTORE_TEST/jq.log"
  restore_snapshot_tick "$panes"
  [ "$(wc -l <"$RESTORE_TEST/tmux.log" | tr -d ' ')" = 1 ]
  [ "$(wc -l <"$RESTORE_TEST/jq.log" | tr -d ' ')" = 1 ]
  "$REAL_JQ" -e --arg root "$TEST_ROOT" '.server == "123 100" and ([.teams[].team] | sort) == ["a","b"] and [.tabs[].team] == ["b","a"] and all(.teams[]; .root == $root and .session_id == ("sid-" + .team)) and any(.teams[]; .team == "b" and .family == "codex")' "$WOLFMUX_DATA/state/running.json"
  cp "$WOLFMUX_DATA/state/running.json" "$RESTORE_TEST/before"
  restore_snapshot_tick ''
  cmp "$RESTORE_TEST/before" "$WOLFMUX_DATA/state/running.json"
  [ "$(wc -l <"$RESTORE_TEST/tmux.log" | tr -d ' ')" = 1 ]
  [ "$(wc -l <"$RESTORE_TEST/jq.log" | tr -d ' ')" = 1 ]
  [ ! -f "$RESTORE_TEST/beads" ]
}
snapshot_rollover() {
  team a; snapshot a
  cp "$WOLFMUX_DATA/state/running.json" "$RESTORE_TEST/old"
  echo 'new-server 100|10|a' >"$RESTORE_TEST/clients"
  restore_snapshot_tick 'a|lead|%1|0|42'
  cmp "$RESTORE_TEST/old" "$WOLFMUX_DATA/state/running.prev.json"
  restore_snapshot_lines >"$RESTORE_TEST/lines"
  [ "$(grep -c '^T' "$RESTORE_TEST/lines")" = 1 ]
}
record_rejects_stale() {
  local marker="$RESTORE_TEST/marker"
  printf '{"sessionId":"sid-a"}\n' >"$WOLFMUX_CLAUDE_SESSIONS/$TEST_PID.json"
  touch -t 200001010000 "$WOLFMUX_CLAUDE_SESSIONS/$TEST_PID.json"
  touch "$marker"
  if _restore_session_record sid-a a "$marker"; then return 1; fi
}
policy_validation() {
  policy_valid restore-on-limit report
  policy_valid restore-on-limit opus
  if policy_valid restore-on-limit nonsense; then return 1; fi
}
record_pretty() {
  local marker="$RESTORE_TEST/marker"
  touch -t 200001010000 "$marker"
  jq -n '{sessionId:"sid-a",tmux:"a:0"}' >"$WOLFMUX_CLAUDE_SESSIONS/$TEST_PID.json"
  [ "$(_restore_session_record sid-a a "$marker")" = sid-a ]
  [ "$(_restore_session_record '' a "$marker")" = sid-a ]
}
record_space_path() {
  local marker="$RESTORE_TEST/marker"
  WOLFMUX_CLAUDE_SESSIONS="$RESTORE_TEST/sessions with spaces"
  mkdir -p "$WOLFMUX_CLAUDE_SESSIONS"
  touch -t 200001010000 "$marker"
  printf '{"sessionId":"sid-a"}\n' >"$WOLFMUX_CLAUDE_SESSIONS/$TEST_PID.json"
  [ "$(_restore_session_record sid-a a "$marker")" = sid-a ]
}
attach_space_path() {
  TEAMCTL_SELF="$RESTORE_TEST/bin/team ctl"
  cat >"$TEAMCTL_SELF" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >"$RESTORE_TEST/attach-args"
STUB
  chmod +x "$TEAMCTL_SELF"
  eval "$(_restore_cmd_text "$TEST_ROOT" a)"
  has "$RESTORE_TEST/attach-args" '--team a attach'
}
limit_model_wait() {
  team a; snapshot a; touch "$RESTORE_TEST/limit" "$RESTORE_TEST/defer"
  WOLFMUX_RESTORE_ON_LIMIT=opus RESTORE_UP_MAX=5 RESTORE_POLL=1
  run_restore --yes
  [ "$(grep -c '^ready a$' "$RESTORE_TEST/actions")" = 2 ]
  [ "$(sed -n '5p' "$RESTORE_TEST/actions")" = 'ready a' ]
}
limit_model_failure() {
  team a; snapshot a; touch "$RESTORE_TEST/limit" "$RESTORE_TEST/fail-model"
  WOLFMUX_RESTORE_ON_LIMIT=opus
  run_restore --yes --no-tabs
  has "$RESTORE_TEST/out" 'the move to opus failed: exit 8'
  absent "$RESTORE_TEST/out" 'policy restore-on-limit is report'
}
config_roundtrip() {
  mkdir -p "$RESTORE_TEST/config"
  echo WOLFMUX_RESTORE_ON_LIMIT=opus >"$RESTORE_TEST/config/config"
  unset WOLFMUX_RESTORE_ON_LIMIT
  WOLFMUX_HOME="$RESTORE_TEST/config" wolfmux_load_config
  [ "$(policy_get restore-on-limit)" = opus ]
}

if [ "${1:-}" = --case ]; then
  set -e
  fixture
  "$2"
  exit
fi

passed=0 failed=0
for name in selection resume_order wait_record missing_transcript busy_memory busy_load room_recovers limit_report limit_model limit_stale worker_refused other_lead_refused dry_worker steward tabs_order tabs_attached tabs_failure tabs_not_running no_tabs idempotent confirm_abort confirm_eof confirm_enter restart_failure beads_failure snapshot_content snapshot_rollover record_rejects_stale policy_validation record_pretty record_space_path attach_space_path limit_model_wait limit_model_failure config_roundtrip; do
  output="$(mktemp "${TMPDIR:-/tmp}/restore-check.XXXXXX")"
  if bash "$0" --case "$name" >"$output" 2>&1; then
    passed=$((passed + 1)); printf '  pass  %s\n' "$name"
  else
    failed=$((failed + 1)); printf '  FAIL  %s\n' "$name"; cat "$output"
  fi
  rm -f "$output"
done
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
