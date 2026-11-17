# ADR-0039: Rotation: a nearly full worker gets a fresh conversation, with a hand-over wolfmux writes

**Date**: 2026-11-17
**Status**: accepted. Built: `teamctl rotate`, the hand-over, policy `worker-rotation`, `restart --continue` waking an agent with a task in progress.
**Deciders**: the owner, the memory-management team's lead (scope), its rotate, rotate2 and rotate3 workers (code, tests, the real-CLI runs)

## Context

Measured with Claude Code 2.1.325 (`tests/research/results/v1.25-research.md`, 1.4 and 1.5; ADR-0038):

- A worker whose conversation is nearly full compacts: the CLI keeps 19k to 47k tokens and stands still
  20 to 190 s each time. Or it waits until the lead restarts it by hand. v1.25.0 only reports both.
- "Restart the worker" had never been tested with uncommitted work in the tree. In the one measured restart
  (1.5) the new conversation found its place in 2 requests, 9.6 s and 117k input tokens, but only because
  that task demanded a step log in NOTES.md.
- The checkpoint the agent is asked to write (`teamctl checkpoint`) was not written in any measured run.
- `teamctl restart <role> --continue` left an idle agent idle until somebody messaged it.

## Decision

1. **`teamctl rotate <role> [--reason <text>] [--now]`** (`lib/rotate.sh`). The lead may rotate any worker
   of its team; a worker may rotate only itself, through the pane proof (exit 77 otherwise). The lead role
   is refused in this release (restart it), and so is a Codex agent.
   - **wolfmux writes the hand-over**, nobody is asked: `run/<role>/memory/handover.md`, beside
     `checkpoint.md`, at most `WOLFMUX_HANDOVER_CHARS` (12,000) characters. Parts, in order, each with its
     own cap so none can push another out: a. the role's task in progress (id, title, body, notes; native
     store or Beads), 2,500; b. the agent's own checkpoint text, without the automatic sections, 1,200;
     c. the commits since the base, `git status --short`, `git diff --stat` staged and unstaged, 1,800,
     then the uncommitted diff itself (`git diff`, then `git diff --cached`), 3,000, so the new conversation
     sees what was half done and not only that lines changed; d. the last five answers of the main
     conversation (text blocks only: no tool call, no thinking, no subagent), each cut at 1,500, newest
     last, 2,400 in all; e. the paths (old transcript, `run/<role>/out/`, the hand-over); f. the reason and
     who asked; e and f together 700. A part that is cut says so.
   - Then `cmd_restart` gives the same role a fresh conversation in the same worktree, on the same branch,
     with the same model and settings; the compact window is worked out again as at a start. The old id is
     kept in the record (`rotated_from`) and in `memory/rotated`; `teamctl restart <role> --resume <id>`
     reopens it.
   - The new conversation's SessionStart (source `startup`) carries the hand-over first, before the notes
     and the mail briefing, with one line: a fresh conversation for the same task; the task is already
     claimed and in progress; the tree state below is current as of the rotation and the work in it is
     yours; continue from it, do not start over. Once: a `handover.pending` file is removed when it is shown, so a later
     compaction, resume or second start does not show it again.
   - The task stays in progress and assigned. Nothing in the tree is stashed, reset or cleaned.
   - **Timing**: by default it waits until the agent's turn has ended (its Stop hook writes `idle` to
     `run/<role>/state`), at most `WOLFMUX_ROTATE_WAIT` (120) seconds, so the restart does not land in the
     middle of a write. When that runs out it refuses, says so and names `--now`. `--now` does not wait.
   - One rotation at a time per role: `run/<role>/rotate.lock`, a directory (`mkdir` is atomic). It is
     removed after a subshell, not by an EXIT trap, because another module replaces the EXIT trap.
   - The lead gets one notice per rotation (role, reason, who asked, old and new figure, the hand-over
     path), not when the lead ran the command itself. The new figure is the team's measured first request
     and the new limit, not a reading of the new conversation (it has made no request yet).
2. **Policy `worker-rotation off|ask|auto`, default `auto`.** At a worker's Stop (`rotate_at_stop`, from
   `recall_hook`): at or past its rotate threshold (`WOLFMUX_CONTEXT_ROTATE`, a share of the limit,
   ADR-0038), or after the thrash event (two compactions within `WOLFMUX_THRASH_CALLS` tool calls),
   - **auto**: it is rotated at that turn end. The agent is not asked to write anything, but it is told to
     end its turn (see "The turn end" below).
   - **ask**: the lead gets one message with the exact command, `teamctl rotate <role>`.
   - **off**: v1.25.0's behaviour.
   The hook does only file tests and one jq; it takes the lock and starts `teamctl _rotate-auto` detached
   (see "Surviving the restart"), which asks the policy, the family and the task store. It fires at most
   once per conversation (`memory/rotate-fired`). Never in a subagent (input with `agent_id`), never for
   the lead, never for Codex, never while the role has no task in progress. The v1.25.0 notices (80%,
   thrash) now name `teamctl rotate` instead of `teamctl restart`.
   - **The turn end.** A worker on a task runs one long turn; a rotation at Stop waits for a turn end that
     the v1.25.0 text never asked for. So at the crossing of the rotate threshold (PostToolUse) and at the
     thrash event (SessionStart, source `compact`), when a rotation can follow, the agent is told: if you
     have a task in progress, commit what works, do not start its next step, then END YOUR TURN with one
     line that says where you stand; wolfmux then replaces this conversation with a fresh one that gets a
     hand-over and continues the task; do not close the task, do not hand it back, no message to the lead
     is needed. "Can follow" is what a hook can know without the store: not the lead, policy `auto` (the
     team's `meta.json`, else `WOLFMUX_WORKER_ROTATION`, else the default), not a Codex agent (its
     record), not held back by the loop guard. One jq at the crossing, no `bd`; the PostToolUse hot path
     is unchanged. Whether a task is in progress is still asked by the detached process, so the line
     starts "if you have a task in progress". Under `ask` and `off` the v1.25.0 text stays. Under `auto`
     the lead's "context at N%" message (and the thrash message) is not sent at the crossing: the
     rotation's own notice follows. It is sent when the rotation does not happen: the loop guard (at the
     Stop), no task in progress (by the detached process, once per conversation, `memory/rotate-declined`),
     Codex (at the crossing, as before).
   - **The loop guard.** The loop to prevent is a conversation that STARTS past the threshold. The watch
     writes `memory/below-seen` the first time it sees the conversation under the rotate threshold (an
     existence test on every later look, no fork; removed at `startup` and `clear`). A conversation a
     rotation started (`new <id>` in `memory/rotated`) is rotated again only when that file exists; a
     conversation that was rotated away and is resumed by hand is not rotated again. Otherwise the lead
     gets v1.25.0's context message.
   - **No task.** When the detached process finds no task in progress it removes `memory/rotate-fired`,
     so the same conversation rotates at a later Stop once it has a task. Not under `ask`: one message per
     conversation is right there.
   - **The lock.** A `rotate.lock` older than `WOLFMUX_ROTATE_LOCK_STALE` (600) seconds, by the epoch in
     its `by` file or else the directory's mtime, is taken over, at a Stop and by `teamctl rotate`; a
     younger one is refused, and the refusal names its age. A detached process that never ran or was
     killed no longer blocks every later rotation.
   - **Surviving the restart.** The process that rotates is started from the conversation it ends: from
     its Stop hook, or from its own Bash tool when a worker runs `teamctl rotate <own role>`.
     `tmux respawn-pane -k` ends the pane, and with it its process group and session (SIGHUP). macOS has
     no `setsid` binary; `_rotate_detach` uses `/usr/bin/perl` (shipped with macOS), whose POSIX module
     has `setsid()`: it forks, so the child is no group leader, the child ignores SIGHUP (an ignored
     signal stays ignored across exec), calls `setsid()` (a new session and process group, no controlling
     terminal) and execs; without perl only SIGHUP is ignored, as `nohup` does. What must outlive the
     restart is written before it: the old id in `memory/rotated`, `rotated_from`, the event. The new
     conversation's own SessionStart writes `new <its id>`, so the loop guard does not depend on the
     rotating process at all. A worker's own `teamctl rotate` takes the lock, hands the rotation to such a
     process (`teamctl _rotate-run`), prints "rotation started: end your turn" and returns; the process
     waits for the turn end as the default does (`--now`: it does not wait).
3. **`teamctl restart <role> --continue` wakes an agent with a task in progress**: one notice through the
   inbox (`inbox_add`, the path every notice takes): "continue task <id>".
4. **Protocol**, worker section, two lines: a task of more than one step keeps a short step log in the
   task (`teamctl note`); after a rotation, read the hand-over and continue, do not start over.

## What was measured

Stub checks (`tests/rotate.sh`, 35, native store and Beads with a `bd` stub): caps (a 50,000-character
task body leaves the git part, the answers, the paths and the reason in place, whole file at most 12,000;
the uncommitted diff is there, and a long one is cut at 3,000 with a marker), the first line's wording,
the order of the parts, own checkpoint text only, five answers without thinking or tool calls, the refusals
(lead role, a worker rotating another, the wait running out, the lock), `--now`, the default wait that ends
when the agent goes idle, a fresh id with the old one kept, the same worktree and the uncommitted file
untouched, the task still in progress, one notice to the lead, delivery once, policy off, ask and auto,
`agent_id` input, under the threshold, no task, no second automatic rotation, the lock at Stop, the thrash
event, `restart --continue` filing "continue task <id>" and not for an agent without a task. On main
(7883db6) the first 29 of them gave 10 passed and 19 failed: the 10 are the refusals and no-ops. The
diff in part c and the first line's wording were seen to fail before their code; the default-wait and
thrash checks were added after the code existed and were not seen red.

A3 added 18 checks (`tests/rotate.sh` 53 in all; `tests/recall.sh` 70): the agent's line under `auto`
and under `ask`, no lead message at the crossing under `auto`, the thrash event under `auto`, a
conversation a rotation started that was under the threshold once and is rotated again, `new <id>`
written by the new conversation's SessionStart, rotate-fired cleared and one lead message when there is
no task (native and Beads), a stale lock taken over by `teamctl rotate` and by a Stop (by file and by
mtime), a young lock refused with its age, `_rotate_detach` outliving a SIGHUP to the pane's process
group (with a control: a plain background child dies), and a worker's own `teamctl rotate` returning at
once and rotating at its turn end. Against the code before A3 (7d6812e) the 16 checks of `tests/rotate.sh`
that test A3 behaviour failed and the control passed. `tests/recall.sh`: four checks of the v1.25.0
lead messages now run under policy `ask`.

The real CLI: see "The real-CLI run" below.

## The real-CLI run

Run by the lead on 2026-11-17 with `tests/research/rotate-run.sh` (Haiku 5.5 lead and worker, isolated
socket and data directory, native store, policy defaults). The task: the calc four-helpers task of the
research, one commit per helper, with NO step log (the research run had one in NOTES.md). Rotated with
`--now` 34 s after the task was given, with one helper committed (mul) and 18 lines of the next one's
checks uncommitted in `tests/run.sh`. This was the code before the last two changes below.

| | research 1.5 (restart, step log) | this run (rotate, no step log) |
|---|---|---|
| seconds until the first edit of the right file | 9.6 | 21.5 |
| requests until then | 2 | 4 |
| input tokens of those requests | 117k | 273,875 (63,164 / 67,401 / 71,038 / 72,272) |
| redid a finished step | no | no: one commit and one definition per helper |
| kept the uncommitted work | (none existed) | yes: the div checks went into the div commit; no checkout, stash, reset, restore or clean |
| task closed | 49 s after the restart | 61 s after the rotation, tests 1213 passed, 0 failed |

The research number is NOT beaten. As they are: the research run had a step log and this task has none,
by design; requests 1 to 3 were the new conversation reading `docs/spec.md` again, which the task demands,
not finding its place; the size of each request is the fixed start of a conversation (about 63k), not the
hand-over (1,694 characters). Its first command re-derived what the hand-over already said (`echo
$TEAM_ROLE; pwd; git status --short; git log --oneline -3; teamctl claim t1; cat docs/spec.md; ...`).
Two changes followed from that, each with a stub check, not yet measured on the real CLI: part c carries
the uncommitted diff itself, and the first line says the task is already claimed and the tree state is
current.

## The A3 real-CLI runs

`memory/rotate-due` (A3 review): written at the crossing when a rotation will follow, and by a worker's
own `teamctl rotate`. While it exists, `_inbox-stop` says nothing (Claude Code runs the Stop entries in
parallel, so only a file written before the Stop is seen by all of them), and `_hook Stop` runs no module
after recall once a rotation is started or under way. That means no task reminder, and no mail is marked
delivered and then dropped. After its wait, the automatic path asks the store again, and with no task in
progress any more it does not rotate (rotate.log says so, and rotate-fired is cleared).

To be measured by the lead with `tests/research/rotate-auto-run.sh` (the automatic rotation: Haiku,
policy defaults, the calc task without a step log, `WOLFMUX_WORKER_COMPACT_WINDOW=200000` for a limit of
167,000 and the rotate threshold at 55%, crossed after one or two of the four helpers) and
`tests/research/rotate-self-run.sh` (the worker runs `teamctl rotate w1` after its second commit). 

**Auto run, first (e9f4f77, Haiku, CLI 2.1.326).** The message came at 94k/167k (56%). The agent
committed div, ran `teamctl checkpoint` and ended its turn 6 s and 1 tool call later. The detached process
survived the restart: one "w1: rotated" notice and no "context at" notice, `rotated_from` set, the lock gone.
But wolfmux's own task reminder ("You are stopping while ...") came at that same Stop, as additional
context, which continues the turn. The agent finished mod and pow in the OLD conversation and closed the
task, and only then was it rotated, 31 s after its first turn end. The rotation saved nothing. Why the
first idle was not seen: cmd_hook writes `state` at the end of the Stop hook, and it writes `busy` when the
hook said something, so the waiting process saw `busy` until the next quiet Stop. Fixed in 028b66d:
`memory/rotate-due` (see "The turn end"), and the task is asked again after the wait. To be measured again.

**Self run (e9f4f77).** Second commit at 10:48:54; `teamctl rotate w1` printed "rotation started: end your
turn" at 10:48:56; the agent ran `teamctl checkpoint` and ended its turn at 10:49:03 (7 s, 1 tool call).
The task reminder cost one more request, and the agent stopped again at 10:49:05. It was rotated at
10:49:07, 2 s after that turn end. The lead got one notice, `rotated_from` was set and the lock was gone.
The new conversation's first command (10:49:16) was a grep of the spec's mod section, with no git status
and no claim again. Its first edit of lib/calc.sh came 24 s and 3 requests after the rotation. It
committed mod and pow and closed the task 63 s after the rotation. Nothing was redone (one commit per
helper), nothing was uncommitted at the rotation, and the tests showed 1212 passed, 0 failed. The context
was 94,718 at the end of the old conversation and 83,519 at the end of the new one. It tried to write its
test log into `run/w1/out/` (named in part e) and the guard refused it: part e now says "to read, not to write".

## Consequences

- A worker past its rotate threshold no longer compacts its way to the end: its next turn end gives it a
  fresh conversation of about its first request plus the hand-over (at most 12,000 characters, about 3k
  tokens), where a compaction kept 19k to 47k and stood still.
- Records gain `rotated_from`; run directories gain `memory/handover.md`, `memory/handover.pending`,
  `memory/rotated`, `memory/rotate-fired`, `memory/below-seen`, `memory/rotate-declined`, `rotate.lock`,
  `rotate.log`.
- Under the default the agent, not the lead, gets the line at the crossing; the lead hears of the
  rotation once, from the rotation itself.
- A rotation at a Stop restarts the pane right after the turn ended. A turn that ended only to wait for a
  long background command loses the wait (the command's output is in the tree or in `run/<role>/out/`).

## Not covered

- The lead is not rotated. A lead's conversation holds the team's plan, and a hand-over for it was not
  designed.
- Codex agents are not rotated: where Codex compacts was not measured (ADR-0038), and its resume path differs.
- The hand-over cannot carry what was only in the conversation and not in an answer, a note, a commit or
  the tree. The step log in the task (protocol) is what covers that.
- The wait reads the Stop hook's `idle`; an agent stuck in a dialog or a hung tool never gets there, so
  only `--now` rotates it.
- One real-CLI run, Haiku, a toy task. Not measured on Opus or Fable, not measured under `ask`.
- Whether an agent obeys "END YOUR TURN" is up to the model. One that works on runs until the CLI
  compacts, as in v1.25.0, and is rotated at the turn end after that.
- The hook's "can follow" does not see the task store: a worker with no task in progress is told to end
  its turn "if you have a task in progress", and the lead is told by the detached process at the Stop.
  A worker with no task that never ends its turn is not reported at the crossing.
- `rotated_from` is set before the restart; a restart that fails puts the session id back but leaves
  `rotated_from` naming the conversation that was kept.
- Without `/usr/bin/perl` the rotating process ignores SIGHUP but stays in the pane's session; not tested.
