# ADR-0038: One context number per agent, and a worker window that cannot thrash

**Date**: 2026-11-16
**Status**: accepted. Built: the number, the window, the watch, the thrash message, and reporting a stalled agent (decision 7).
**Deciders**: the owner (the complaint), the memory-management team's lead (scope), its research worker (measurement, `tests/research/results/part-b-handover.md`), its ctx and ctx2 workers (code, the real-CLI runs)

## Context

Measured on 2026-11-16 with Claude Code 2.1.325 (`tests/research/results/v1.25-research.md`, 1.4):

- The CLI compacts at about its window minus 33,000 tokens (165-171k of 200k, 66-89k of 100k; the
  vendor says "about 967k of 1M"). After a compaction the next request is the first request of
  the conversation, F, plus what the compaction kept, K (19-47k).
- `teamctl status` and the context watch divided by the model table's window, or by a 200,000
  fallback. A worker told to compact at 100,000 was shown "6%" while its CLI compacted; a worker
  at 186k of a 400k window was told "93%, start nothing new".
- With a 100k window and F = 54k the room after a compaction was 4-5k: 10 compactions in 5
  minutes, then the CLI stopped with "Autocompact is thrashing". Nobody was told.
- A compact window given to `teamctl spawn` or `teamctl task --spawn` never arrived: the settings
  file is written inside the pane (`teamctl _run-agent`), and a pane has the tmux server's
  environment, not the spawning command's.
- The watch fired inside in-process subagents. Their PostToolUse input carries `agent_id` and
  `agent_type`, with the MAIN conversation's `transcript_path` and `session_id`
  (`tests/research/results/subagent-hook-probe.jsonl`).

## Decision

1. **One limit.** `context_limit_for` (`lib/policy.sh`) is the only place a limit is worked out:
   the smaller of the window the agent's CLI was told to compact at and its model's window, minus
   `WOLFMUX_COMPACT_RESERVE` (33000). `agent_context` (status, dashboard) reads the compact window
   from the agent's record (`compact_window`); the watch reads `CLAUDE_CODE_AUTO_COMPACT_WINDOW`
   from its own environment, which is the running CLI's. Both resolve the model's window through
   `models_running`. Every place prints `ctx_display`'s `142k/167k 85%`: status, dashboard, the
   watch's notices, the lead's message, the checkpoint header and the PreCompact section.
   `WOLFMUX_CONTEXT_WARN` and `_ROTATE` are shares of the limit. A model whose window nobody
   declared has no limit: tokens alone, no percentage, no warning (the house rule of v1.14.1).
   Codex keeps the window its rollout states, unreduced: where it compacts was not measured.
2. **The window is made from what was measured.** `worker_compact_plan`: the override when one is
   given, else `F + K + 33000 + WOLFMUX_CONTEXT_ROOM` (150000), never above the model's window,
   and never below `F + K + 33000 + WOLFMUX_CONTEXT_MIN_ROOM` (30000): a smaller one is raised and
   the reason is printed in the pane and written to the event log, once per start. F is the last
   first request the watch measured for a worker of this team (`$STATE_DIR/context/worker`, 90000
   until one exists); K is the largest kept part measured there and never under 45000, because
   one agent's compactions kept 19k to 47k and the window cannot be changed while it runs. A
   model whose own window is below the floor gets its own window and a note saying how little
   room that leaves. The lead still gets no window.
3. **An asked window reaches the worker.** `teamctl spawn`, `task --spawn` and `restart` write
   their own `WOLFMUX_WORKER_COMPACT_WINDOW` on the record (`compact_override`); the pane reads
   the record first, then its own environment (what `teamctl start` or the config file gave).
4. **The warning comes first.** The hot path looks every tenth tool call. Within
   `WOLFMUX_CONTEXT_NEAR` (10) points of the next threshold not yet announced the watch leaves a
   `near` file in the run directory, and the hot path then lets every call through: one more
   builtin file test per call, no fork. It can still be late when ten calls add more than the
   distance to the threshold plus those 10 points; to miss the compaction itself they would have
   to add half the limit.
5. **Subagents are left alone**: the watch returns at once when the input has `agent_id`.
6. **Two compactions close together are one message.** SessionStart with source `compact` records
   K and appends the tool-call counter and the time to `memory/compactions`. Two entries within
   `WOLFMUX_THRASH_CALLS` (10) tool calls: one message to the lead per conversation, with the
   tokens before, the limit, the window, F, K, the room left and the restart command. The task
   said "requests"; a hook can count tool calls for free and a request makes one or more. This
   comes before the CLI's own stop ("3 times in a row"), which fires no hook.

7. **A stalled agent is reported, from outside it.** A turn that ends on an API error row
   (`isApiErrorMessage: true`, which covers a 529, a usage limit and the CLI's own thrash stop)
   leaves the agent idle with its task in progress, and no hook of that agent runs again. Three
   lookers, all outside it, run `stall_scan` (`lib/stall.sh`):
   - **the lead's wake waiter** (`cmd_inbox_wake`), while the lead is idle: once per
     `WOLFMUX_STALL_LOOK` (60) seconds of its 15-second loop, counted down in the loop, no fork
     between looks. A message it files is handed over by the same loop at once.
   - **the lead's tenth tool call** (`recall_hook PostToolUse`), while the lead works and its
     waiter does not run: at most once per 60 s (a stamp file's time), in the background, so the
     lead's call never waits. Not in the hot path of `bin/teamctl`: no fork is added there.
   - **`teamctl status`**, whoever runs it, which also prints a `stalled` line.
   A look costs, per agent on the books: one jq over its record and one stat of its transcript.
   Only a transcript quiet for `WOLFMUX_STALL_AFTER` (300) seconds is read (40 lines, one jq),
   and only one that ends on an error row costs a store query. The lead is told ONCE per error
   row (a `mkdir` of `state/stall/<role>.<timestamp>`, atomic between two lookers): the role,
   the error's first line, since when, the task, and `teamctl restart <role> --continue`
   followed by a message. Nothing is typed into a pane and nothing restarts an agent.
   It cannot see: an agent stuck any other way (a hung tool, a dialog, a dead pane), a Codex
   agent, a stalled LEAD (nobody outside it to tell), and anything while no lead runs and nobody
   calls status.

## Consequences

- A worker's default window moves from the model's (200k to 1M) to about 280-320k: compactions
  come earlier than under v1.24.0 for 1M models, on purpose (each request is cheaper), and later
  than a hand-set 100-200k.
- Records gain `compact_window`, `compact_override`, `compact_first`, `compact_kept`,
  `compact_note`; `status --json` gains `context_limit`; `memory/ctx` is
  `{used, limit, window, first, kept, percent, at}` (`tokens` is gone).
- The 33,000 reserve is an observation. A CLI release that changes it makes every share wrong by
  the difference until `WOLFMUX_COMPACT_RESERVE` is changed.
- Near a threshold every tool call costs the full hook (one bash with all modules, a tail and a
  jq) instead of the hot path, for the 10 points before each of the two thresholds.

## Not built

- No rotation: nothing gives a task a fresh conversation by itself.
- Not confirmed against the real CLI: that the `compact_boundary` row is already in the transcript
  when SessionStart:compact fires (if it is not, K is the previous compaction's), and the three
  pane checks of the hand-over.
