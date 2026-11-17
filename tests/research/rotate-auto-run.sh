#!/bin/bash
# rotate-auto-run.sh <scratch-dir> - one real-CLI measurement of the AUTOMATIC rotation (ADR-0039, A3).
# Haiku lead and worker on this checkout, isolated by iso.sh (own socket, own data directory), policy
# defaults (worker-rotation auto). The worker gets the calc task of the research (four helpers, one commit
# each) WITHOUT a step log. Nobody runs teamctl rotate: the rotate threshold, set low through the
# environment, is crossed in the middle of the task; the hook tells the worker to end its turn, and the
# Stop hook rotates it. ROT_MODE=self (rotate-self-run.sh) instead tells the worker, in its task, to run
# `teamctl rotate w1` itself after its second commit, with the thresholds out of the way.
#
# The thresholds (auto mode), and why: WOLFMUX_WORKER_COMPACT_WINDOW=200000 gives a limit of 167000
# (window - 33000). The first request of a worker is about 63k (38%); reading docs/spec.md (60,694
# characters) adds about 15k (about 47%); each helper adds a few thousand. Rotate at 55% (about 92k) is
# then crossed after one or two helpers of four, warn at 50% (about 83k) just before. Override with
# ROT_ROTATE / ROT_WARN.
#
# It prints: did the agent end its turn after the message, after how many seconds and tool calls; did the
# rotation happen by itself; is "new <id>" recorded and rotated_from set; how many notices the lead got;
# did the fresh conversation go on and close the task; finished steps redone; uncommitted work kept; is
# the lock gone; was there a second rotation.
# Needs: tmux, the real `claude`, jq, sqlite3, python3. It types two keys into its OWN lead pane (folder
# trust), nothing else. A worker cannot run it (the guard keeps tmux from it): the lead or the owner does.
set -u
here="${ROT_HERE:-$(cd "$(dirname "$0")/../.." && pwd -P)}"
scratch="${1:?usage: rotate-auto-run.sh <scratch-dir>}"
scratch="$(/bin/mkdir -p "$scratch" && cd "$scratch" && pwd -P)"
# Bash reads a script as it runs: run a copy in the scratch directory, so an edit of this file in the
# worktree cannot break a run that is under way.
if [ -z "${ROT_COPIED:-}" ]; then
  /bin/cp -f "$0" "$scratch/rotate-auto-run.sh"
  ROT_COPIED=1 ROT_HERE="$here" exec /bin/bash "$scratch/rotate-auto-run.sh" "$@"
fi
mode="${ROT_MODE:-auto}"
sock="${ISO_SOCKET:-wolfmux-rot$mode}"
export ISO_SOCKET="$sock"
if [ "$mode" = self ]; then
  export ISO_ENV="WOLFMUX_WORKER_COMPACT_WINDOW=200000 WOLFMUX_CONTEXT_WARN=off WOLFMUX_CONTEXT_ROTATE=off"
else
  export ISO_ENV="WOLFMUX_WORKER_COMPACT_WINDOW=200000 WOLFMUX_CONTEXT_WARN=${ROT_WARN:-50} WOLFMUX_CONTEXT_ROTATE=${ROT_ROTATE:-55}"
fi
iso() { "$here/tests/research/iso.sh" "$scratch" "$@"; }
log() { printf '%s %s\n' "$(/bin/date +%H:%M:%S)" "$*"; }
out="$scratch/result.txt"
JQ="$(command -v jq)"
SQL="$(command -v sqlite3)"

# --- the scratch: bin/ links and the calc project --------------------------------------------------
/bin/mkdir -p "$scratch/bin"
ln -sf "$here/bin/teamctl" "$scratch/bin/teamctl"
for m in claude-fable claude-haiku claude-sonnet; do ln -sf "$here/bin/claude-fable" "$scratch/bin/$m"; done
if [ ! -d "$scratch/proj/.git" ]; then
  /bin/cp -R "$here/tests/research/fixtures/calc" "$scratch/proj"
  (cd "$scratch/proj" && git init -q -b main && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -qm "calc: base")
fi
base="$(git -C "$scratch/proj" rev-parse HEAD)"

# --- the team -----------------------------------------------------------------------------------------
log "start (mode $mode, socket $sock, data $scratch/data, $ISO_ENV)"
iso teamctl start haiku --no-attach >"$scratch/start.log" 2>&1
session="$(tmux -L "$sock" list-sessions -F '#S' 2>/dev/null | head -1)"
for _ in $(seq 1 30); do
  if tmux -L "$sock" capture-pane -p -t "$session" 2>/dev/null | grep -qi "trust"; then
    tmux -L "$sock" send-keys -t "$session" Down
    sleep 0.3
    tmux -L "$sock" send-keys -t "$session" Enter
    log "folder trust accepted in the lead pane"
    break
  fi
  sleep 1
done
sleep 5
log "pane environment: $(tmux -L "$sock" show-environment -g 2>/dev/null | grep -E '^WOLFMUX_(CONTEXT_ROTATE|CONTEXT_WARN|WORKER_COMPACT_WINDOW)=' | tr '\n' ' ')"
task_text="Implement the four helpers that docs/spec.md specifies (mul, div, mod, pow) in lib/calc.sh.
- docs/spec.md is the only source of truth: read it in full before you start, the special cases are in it.
- One function per commit, in the order of the document, each with its checks in tests/run.sh.
- Before every commit run bash tests/run.sh and read its complete output.
- When all four are in: teamctl done, naming the test command and its result."
if [ "$mode" = self ]; then
  task_text="$task_text
- Right after your second commit (div), run: teamctl rotate w1   (it gives you a fresh conversation for this task; do what it prints)."
fi
iso teamctl task w1 "calc: four helpers" -d "$task_text" --spawn haiku >"$scratch/task.log" 2>&1
log "task given: $(tail -1 "$scratch/task.log")"
rec() { "$JQ" -r --arg f "$1" '.[$f] // empty' "$(find "$scratch/data" -path '*/agents/w1.json' | head -1)" 2>/dev/null; }
wt=""
for _ in $(seq 1 60); do wt="$(rec workdir)"; [ -n "$wt" ] && [ -d "$wt" ] && break; sleep 1; done
[ -n "$wt" ] || { log "no worker worktree"; exit 1; }
log "worker worktree $wt"
old_sid="$(rec session_id)"

# --- wait for the rotation, nobody asks for it; keep the last uncommitted diff before it ------------
deadline=$(($(/bin/date +%s) + ${ROT_MAX:-900}))
while [ "$(/bin/date +%s)" -lt "$deadline" ]; do
  [ -z "$(rec rotated_from)" ] || break
  git -C "$wt" diff >"$scratch/diff.now" 2>/dev/null && /bin/mv -f "$scratch/diff.now" "$scratch/at-rotate.diff"
  git -C "$wt" log --oneline "$base..HEAD" >"$scratch/at-rotate.log" 2>/dev/null
  sleep 0.5
done
t_rot="$(python3 -c 'import time; print(time.time())')"
new_sid="$(rec session_id)"
if [ -z "$(rec rotated_from)" ]; then log "no rotation within ${ROT_MAX:-900} s"; else log "rotated: $old_sid -> $new_sid"; fi
# The run directory exists once the worker's hooks have run; looked up now, not at the start.
run=""
for _ in $(seq 1 30); do run="$(find "$scratch/data" -type d -path '*/run/w1' | head -1)"; [ -n "$run" ] && break; sleep 1; done
log "run dir: ${run:-NOT FOUND}"

# --- wait for the task to close (or ROT_MAX), then 60 s for a second rotation ------------------------
deadline=$(($(/bin/date +%s) + ${ROT_MAX:-900}))
while [ "$(/bin/date +%s)" -lt "$deadline" ]; do
  iso teamctl tasks --all --status closed 2>/dev/null | grep -q "calc: four helpers" && break
  sleep 5
done
log "task closed or time up; 60 s more for a second rotation"
sleep 60

# --- the numbers ------------------------------------------------------------------------------------
old_t="$(find "$HOME/.claude/projects" -name "$old_sid.jsonl" 2>/dev/null | head -1)"
new_t="$(find "$HOME/.claude/projects" -name "$new_sid.jsonl" 2>/dev/null | head -1)"
db="$(find "$scratch/data" -name store.db | head -1)"
if [ "$mode" = self ]; then marker="rotation started: end your turn"; else marker="END YOUR TURN"; fi
{
  printf 'mode %s; old conversation %s, new %s\nold transcript %s\nnew transcript %s\n' "$mode" "$old_sid" "$new_sid" "$old_t" "$new_t"
  python3 - "$old_t" "$marker" "$t_rot" <<'PY'
import json, sys, datetime
path, marker, t_rot = sys.argv[1], sys.argv[2], float(sys.argv[3])
def ts(r):
    try: return datetime.datetime.fromisoformat(r["timestamp"].replace("Z", "+00:00")).timestamp()
    except Exception: return None
try: rows = [json.loads(l) for l in open(path) if l.strip()]
except Exception as e:
    print("old transcript unreadable: %s" % e); sys.exit(0)
# The marker is in several rows (hook attachments and others): the first one WITH a timestamp.
at = next((i for i, r in enumerate(rows) if ts(r) is not None and marker in json.dumps(r)), None)
if at is None:
    print("the message (%r) is not in the old transcript" % marker); sys.exit(0)
t_msg = ts(rows[at])
print("the message: %s" % rows[at].get("timestamp"))
calls, ends, first_end, after_calls, after_commits = 0, 0, None, 0, 0
for i in range(at + 1, len(rows)):
    r = rows[i]
    if r.get("type") != "assistant" or r.get("isSidechain"): continue
    m = r.get("message", {})
    uses = [c for c in (m.get("content") or []) if c.get("type") == "tool_use"]
    if first_end is None:
        calls += len(uses)
    else:
        after_calls += len(uses)
        after_commits += sum(1 for c in uses if "git commit" in json.dumps(c.get("input", {})))
    if m.get("stop_reason") != "end_turn": continue
    ends += 1
    if first_end is None: first_end = i
    text = " ".join(c.get("text", "") for c in (m.get("content") or []) if c.get("type") == "text").strip()
    rest = json.dumps(rows[i + 1:i + 8])
    if i + 1 >= len(rows): what = "nothing: the end of this conversation (the rotation)"
    elif "You are stopping while" in rest: what = "a wolfmux Stop notice (the task reminder), which continued the turn"
    elif "hook_additional_context" in rest or "Stop hook feedback" in rest: what = "a Stop hook's context, which continued the turn"
    else: what = "more rows (%s)" % ", ".join(sorted({str(x.get("type", "?")) for x in rows[i + 1:i + 8]}))
    print("turn end %d: %s, %.1f s after the message; last line: %s" % (ends, r.get("timestamp"), ts(r) - t_msg, text[:200]))
    print("  followed by: %s" % what)
if first_end is None:
    print("ended its turn after the message: NO (%d tool calls after it)" % calls)
else:
    print("ended its turn after the message: yes, %.1f s and %d tool calls after it" % (ts(rows[first_end]) - t_msg, calls))
    print("old conversation AFTER that first turn end: %d tool calls, %d commits (must be 0 and 0)" % (after_calls, after_commits))
    print("rotation %.1f s after the first turn end (as the run saw it, 0.5 s polling)" % (t_rot - ts(rows[first_end])))
PY
  printf 'rotated_from: %s (old id %s)\n' "$(rec rotated_from)" "$old_sid"
  printf 'asked by (hand-over): %s\n' "$(grep -m1 '^asked by:' "$run/memory/handover.md" 2>/dev/null)"
  printf 'reason (hand-over): %s\n' "$(grep -m1 '^reason:' "$run/memory/handover.md" 2>/dev/null)"
  printf 'new <id> recorded in memory/rotated: %s\n' "$(grep -qx "new $new_sid" "$run/memory/rotated" 2>/dev/null && echo yes || echo NO)"
  printf 'memory/rotated:\n%s\n' "$(cat "$run/memory/rotated" 2>/dev/null)"
  printf 'rotations (old ids in memory/rotated): %s\n' "$(grep -vc '^new ' "$run/memory/rotated" 2>/dev/null)"
  printf 'messages to the lead about w1:\n%s\n' "$("$SQL" "$db" "select created_at || '  ' || subject from msg where subject like 'w1:%' and recipient like '%lead' order by id" 2>/dev/null)"
  printf 'notices "w1: rotated": %s; "w1: context at": %s\n' \
    "$("$SQL" "$db" "select count(*) from msg where subject like 'w1: rotated%'" 2>/dev/null)" \
    "$("$SQL" "$db" "select count(*) from msg where subject like 'w1: context at%'" 2>/dev/null)"
  printf 'task: %s\n' "$(iso teamctl tasks --all --status open,in_progress,closed 2>/dev/null | grep 'calc: four helpers')"
  printf 'lock: %s\n' "$([ -e "$run/rotate.lock" ] && echo "STILL THERE ($(cat "$run/rotate.lock/by" 2>/dev/null))" || echo gone)"
  printf 'rotate.log:\n%s\n' "$(tail -n 20 "$run/rotate.log" 2>/dev/null)"
  printf 'at rotation: commits:\n%s\nuncommitted diff (%s lines)\n' "$(cat "$scratch/at-rotate.log" 2>/dev/null)" "$(wc -l <"$scratch/at-rotate.diff" 2>/dev/null | tr -d ' ')"
  # Kept: every added line of the uncommitted diff is in a commit made after it, or in the tree now.
  kept=0 lost=0
  after="$(git -C "$wt" log -p "$base..HEAD" 2>/dev/null; git -C "$wt" diff 2>/dev/null; cat "$wt/lib/calc.sh" "$wt/tests/run.sh" 2>/dev/null)"
  while IFS= read -r line; do
    case "$line" in "+++"*) continue ;; "+"*) ;; *) continue ;; esac
    l="${line#+}"
    [ -n "${l//[[:space:]]/}" ] || continue
    if printf '%s\n' "$after" | grep -qF -- "$l"; then kept=$((kept + 1)); else lost=$((lost + 1)); printf '  not found later: %s\n' "$l"; fi
  done <"$scratch/at-rotate.diff"
  printf 'uncommitted work kept: %s of %s added lines found later\n' "$kept" "$((kept + lost))"
  python3 - "$new_t" <<'PY'
import json, sys
try: rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
except Exception as e:
    print("new transcript unreadable: %s" % e); sys.exit(0)
cmds = [c.get("input", {}).get("command", "") for r in rows if r.get("type") == "assistant"
        for c in (r.get("message", {}).get("content", []) or []) if c.get("type") == "tool_use" and c.get("name") == "Bash"]
print("new conversation: %d Bash commands" % len(cmds))
bad = [c for c in cmds if any(k in c for k in ("git checkout", "git stash", "git reset", "git restore", "git clean"))]
print("commands that could drop the uncommitted work: %s" % (bad or "none"))
PY
  printf 'final log:\n%s\n' "$(git -C "$wt" log --oneline "$base..HEAD")"
  printf 'definitions in lib/calc.sh: %s\n' "$(grep -oE '^(mul|div|mod|pow)\(\)' "$wt/lib/calc.sh" | sort | uniq -c | tr '\n' ' ')"
  printf 'commits per helper (a count over 1 is a redone step): %s\n' "$(git -C "$wt" log --format=%s "$base..HEAD" | grep -oE 'add (mul|div|mod|pow)' | sort | uniq -c | tr '\n' ' ')"
  printf 'tests: %s\n' "$(cd "$wt" && bash tests/run.sh 2>&1 | tail -1)"
} >"$out" 2>&1
cat "$out"
log "done ($out); stop the team with: tmux -L $sock kill-server"
