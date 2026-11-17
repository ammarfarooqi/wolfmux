#!/bin/bash
# rotate-run.sh <scratch-dir> - one real-CLI measurement of a rotation (ADR-0039, v1.26.0 acceptance 3).
# Haiku lead and worker on this checkout, isolated by iso.sh (own socket, own data directory). The worker
# gets the calc task of the research (four helpers, one commit each) WITHOUT a step log; once it has at
# least one step committed and an uncommitted change in the tree, it is rotated with --now. Then the run
# waits for the task to close (at most ROT_MAX seconds, default 900) and prints the numbers:
#   seconds and requests from the rotation until the new conversation edits lib/calc.sh, the input tokens
#   of those requests, whether it redid a finished step, whether it kept the uncommitted work.
# Needs: tmux, the real `claude`, jq. It types two keys into its OWN lead pane (folder trust), nothing else.
# A worker cannot run it (the guard keeps tmux from it): the lead or the owner does.
set -u
here="$(cd "$(dirname "$0")/../.." && pwd -P)"
scratch="${1:?usage: rotate-run.sh <scratch-dir>}"
scratch="$(/bin/mkdir -p "$scratch" && cd "$scratch" && pwd -P)"
sock="${ISO_SOCKET:-wolfmux-rotrun}"
export ISO_SOCKET="$sock"
iso() { "$here/tests/research/iso.sh" "$scratch" "$@"; }
log() { printf '%s %s\n' "$(/bin/date +%H:%M:%S)" "$*"; }
out="$scratch/result.txt"

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
log "start (socket $sock, data $scratch/data)"
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
task_text="Implement the four helpers that docs/spec.md specifies (mul, div, mod, pow) in lib/calc.sh.
- docs/spec.md is the only source of truth: read it in full before you start, the special cases are in it.
- One function per commit, in the order of the document, each with its checks in tests/run.sh.
- Before every commit run bash tests/run.sh and read its complete output.
- When all four are in: teamctl done, naming the test command and its result."
iso teamctl task w1 "calc: four helpers" -d "$task_text" --spawn haiku >"$scratch/task.log" 2>&1
log "task given: $(tail -1 "$scratch/task.log")"
JQ="$(command -v jq)"
rec() { "$JQ" -r --arg f "$1" '.[$f] // empty' "$(find "$scratch/data" -path '*/agents/w1.json' | head -1)" 2>/dev/null; }
wt=""
for _ in $(seq 1 60); do wt="$(rec workdir)"; [ -n "$wt" ] && [ -d "$wt" ] && break; sleep 1; done
[ -n "$wt" ] || { log "no worker worktree"; exit 1; }
log "worker worktree $wt"

# --- wait for: one step committed, an uncommitted change; then rotate -------------------------------
deadline=$(($(/bin/date +%s) + 600))
while [ "$(/bin/date +%s)" -lt "$deadline" ]; do
  commits="$(git -C "$wt" rev-list --count "$base..HEAD" 2>/dev/null || echo 0)"
  dirty="$(git -C "$wt" status --short -- lib tests 2>/dev/null)"
  if [ "${commits:-0}" -ge 1 ] && [ -n "$dirty" ]; then break; fi
  sleep 0.3
done
old_sid="$(rec session_id)"
git -C "$wt" log --oneline "$base..HEAD" >"$scratch/at-rotate.log"
git -C "$wt" diff >"$scratch/at-rotate.diff"
committed_fns="$(git -C "$wt" show HEAD:lib/calc.sh | grep -oE '^(mul|div|mod|pow)\(\)' | tr -d '()' | tr '\n' ' ')"
t0="$(python3 -c 'import time; print(time.time())')"
iso teamctl rotate w1 --now --reason "measurement: rotate in the middle" >"$scratch/rotate.log" 2>&1
log "rotated: $(cat "$scratch/rotate.log" | tail -1)"
log "at rotation: commits $(wc -l <"$scratch/at-rotate.log" | tr -d ' ') ($committed_fns), uncommitted diff $(wc -l <"$scratch/at-rotate.diff" | tr -d ' ') lines"
new_sid="$(rec session_id)"

# --- wait for the task to close (or ROT_MAX) --------------------------------------------------------
deadline=$(($(/bin/date +%s) + ${ROT_MAX:-900}))
while [ "$(/bin/date +%s)" -lt "$deadline" ]; do
  iso teamctl tasks --all --status closed 2>/dev/null | grep -q "calc: four helpers" && break
  sleep 5
done
log "task closed or time up"

# --- the numbers ------------------------------------------------------------------------------------
trans="$(find "$HOME/.claude/projects" -name "$new_sid.jsonl" 2>/dev/null | head -1)"
{
  printf 'old conversation %s, new %s\ntranscript %s\n' "$old_sid" "$new_sid" "$trans"
  printf 'at rotation: committed functions: %s\n' "$committed_fns"
  printf 'uncommitted diff at rotation:\n%s\n' "$(cat "$scratch/at-rotate.diff")"
  python3 - "$trans" "$t0" <<'PY'
import json, sys, datetime
path, t0 = sys.argv[1], float(sys.argv[2])
rows = [json.loads(l) for l in open(path) if l.strip()]
seen, tokens, first_edit = [], 0, None
for r in rows:
    if r.get("type") != "assistant" or r.get("isSidechain"):
        continue
    m = r.get("message", {})
    mid = m.get("id")
    if mid and mid not in seen:
        seen.append(mid)
        u = m.get("usage", {})
        tokens += u.get("input_tokens", 0) + u.get("cache_creation_input_tokens", 0) + u.get("cache_read_input_tokens", 0)
    for c in m.get("content", []) or []:
        if c.get("type") == "tool_use" and c.get("name") in ("Edit", "Write", "MultiEdit") and "lib/calc.sh" in json.dumps(c.get("input", {})):
            ts = datetime.datetime.fromisoformat(r["timestamp"].replace("Z", "+00:00")).timestamp()
            first_edit = (ts - t0, len(seen), tokens)
            break
    if first_edit:
        break
if first_edit:
    print("first edit of lib/calc.sh: %.1f s after the rotation, %d requests, %d input tokens" % first_edit)
else:
    print("no edit of lib/calc.sh in the new conversation")
cmds = [c.get("input", {}).get("command", "") for r in rows if r.get("type") == "assistant"
        for c in (r.get("message", {}).get("content", []) or []) if c.get("type") == "tool_use" and c.get("name") == "Bash"]
bad = [c for c in cmds if any(k in c for k in ("git checkout", "git stash", "git reset", "git restore", "git clean"))]
print("commands that could drop the uncommitted work: %s" % (bad or "none"))
PY
  printf 'final log:\n%s\n' "$(git -C "$wt" log --oneline "$base..HEAD")"
  printf 'definitions in lib/calc.sh: %s\n' "$(grep -oE '^(mul|div|mod|pow)\(\)' "$wt/lib/calc.sh" | sort | uniq -c | tr '\n' ' ')"
  printf 'commits per helper: %s\n' "$(git -C "$wt" log --format=%s "$base..HEAD" | grep -oE 'add (mul|div|mod|pow)' | sort | uniq -c | tr '\n' ' ')"
  printf 'tests: %s\n' "$(cd "$wt" && bash tests/run.sh 2>&1 | tail -1)"
  printf 'hand-over: %s\n' "$(find "$scratch/data" -name handover.md | head -1)"
} >"$out" 2>&1
cat "$out"
log "done; stop the team with: tmux -L $sock kill-server"
