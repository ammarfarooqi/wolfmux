# Part B (wolfmux-lpi): what is left after the ctx worker's first conversation

Written 2026-11-16 by `ctx`, who stopped at its 300,000-token hand-over point. Items 1 to 4 of the
task are built and have stub checks; item 5, part of item 6 and every real-CLI run are open.
Branch `ai/memory-management/ctx-20261116-161633`, base `release/v1.25.0` 5b41a79. The decision
record is `docs/adr/0038-one-context-number.md`; read its "Not built" section first.

## Built (and where)

| Item | What | Where | Check |
|---|---|---|---|
| 1 | one figure `used/limit share`, the same function for every view | `context_limit_for`, `context_limit` (`lib/policy.sh`); `agent_context` sets `CTX_LIMIT` (`lib/agents.sh`); `ctx_display` (`lib/views.sh`); the watch (`lib/recall.sh`); checkpoint header and PreCompact section (`_memory_ctx_line`) | `tests/recall.sh` (context sections), `tests/dashboard.sh`, `tests/models.sh` |
| 1 | a window given on spawn, task --spawn, restart reaches the worker | `agent_compact_asked`, `agent_compact_override`, `agent_compact_resolve` (`lib/agents.sh`) | `tests/smoke.sh` "a window given only to the command" |
| 2 | window = F + K + 33000 + room, raised when it would thrash, capped by the model | `worker_compact_plan` (`lib/policy.sh`); F and K kept in `$STATE_DIR/context/<kind>` by `_memory_measured_put` | `tests/recall.sh` "the window a worker's CLI is told to compact at", `tests/smoke.sh` two "compaction:" checks |
| 3 | the warning before the compaction (the `near` file), nothing inside a subagent | `_memory_check_thresholds`, `_memory_context_watch`; one more file test in the hot path of `bin/teamctl` | `tests/recall.sh` "near a threshold", "inside an in-process subagent" |
| 4 | two compactions within 10 tool calls: one message to the lead | `_memory_compacted`, `_memory_tell_thrash` | `tests/recall.sh` "compactions:" |

Hot path, measured (200 calls each, `PATH=/nonexistent`, a Read result, not a tenth call):
before 17 trace lines, 0 forks, 4.64 ms per call; after 18 trace lines, 0 forks, 4.74 ms.

Unknown 1 of the hand-over is answered by one print-mode Haiku probe (not a pane run):
`tests/research/results/subagent-hook-probe.jsonl`. Unknown 2 is answered by reading the code
(the settings file is written in the pane) and fixed. Unknowns 3 and 4 were not looked at.

## Left

1. **Item 5, the stalled agent. Nothing is built and nothing was investigated**: I did not read
   what `WOLFMUX_INBOX_STALL_NOTIFY`, the wake waiter or `teamctl status` already do. The facts
   the task and the first hand-over give: the stop is an assistant row with
   `isApiErrorMessage: true` (model `<synthetic>` for the thrash stop, text starting "Autocompact
   is thrashing"), followed by `turn_duration`; no hook fires. `models_turn_idle`
   (`lib/models.sh`) already reads the tail of a transcript for "the turn ended", and
   `run/<role>/calls` has the agent's last sign of life as its mtime. A second `near`-like file
   is NOT a way in: the stalled agent runs no hook.
2. **Real CLI: no pane run was made (0 of 6).** Checks (a), (b), (c) of the first hand-over are
   open. For one compaction in check (a) the floor has to be lowered as well as the room:
   `ISO_ENV="WOLFMUX_CONTEXT_ROOM=0 WOLFMUX_CONTEXT_MIN_ROOM=0"` on `teamctl start` gives the
   132k window the hand-over describes; with the default floor the window is raised to 163k and
   the 97k task never compacts. To confirm there: the `compact_boundary` row is in the transcript
   when SessionStart:compact fires (else `memory/kept` holds the previous compaction's value),
   and `CLAUDE_CODE_AUTO_COMPACT_WINDOW` from the settings file's `env` is in the hook's
   environment (it is in the Bash tool's; the watch depends on it).
3. **Item 6, the rest**: `docs/ARCHITECTURE.md` has a section "The context number" without the stall part. `teamctl help` names the
   figure but not `WOLFMUX_CONTEXT_ROOM`. Environment-only knobs named only in ADR-0038 and
   `lib/policy.sh` / `lib/recall.sh`: `WOLFMUX_COMPACT_RESERVE`, `WOLFMUX_CONTEXT_FIRST`,
   `WOLFMUX_CONTEXT_KEPT`, `WOLFMUX_CONTEXT_MIN_ROOM`, `WOLFMUX_CONTEXT_NEAR`,
   `WOLFMUX_THRASH_CALLS`. `WOLFMUX_STALL_AFTER` does not exist yet.
4. **Not proven**: that each new check fails on the base. They exercise functions and a format
   that did not exist, but nobody ran the new `tests/recall.sh` against 5b41a79.
5. **Things I decided that the task did not say**, for the lead to overrule:
   - K never counts under 45000 and the team keeps the LARGEST kept part (the hand-over said
     "K = 45000 until a compaction happened").
   - A window that would thrash is raised, not refused, so `task --spawn` never fails on it.
   - A model with no declared window has no limit even when its record carries a compact window
     (the CLI caps the window at the model's, so the record is only an upper bound).
   - The figure is `142k/167k 85%`; the status CONTEXT column grew from 9 to 14 characters.
   - Mail and task hooks still speak inside subagents; only the watch was changed.
