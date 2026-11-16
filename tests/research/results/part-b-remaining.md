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

## Done in the second conversation (ctx2, task wolfmux-cj3)

1. **Each new check fails on the base.** All 31 new or edited checks of `tests/recall.sh` fail against the
   libraries of 5b41a79; five that passed there were merged into a check that does not, or sharpened
   (29% nothing said, warn=20 at 29%, the near file gone at 62%, one compaction tells nobody, astra with an
   asked window). The three smoke "compaction:" checks fail on the base (a copy of `tests/smoke.sh` cut
   after them: 103 passed, exactly those 3 failed).
2. **Real CLI, 4 pane runs**: `tests/research/results/part-b-real-cli.md`. Found and fixed: K at
   SessionStart:compact was the previous compaction's (e029b1e).
3. **Item 5, the stalled agent**: `lib/stall.sh`, ADR-0038 decision 7, a staged run on the real CLI.
4. **Item 6, the docs**: every new knob in `teamctl help` or the manual's settings table,
   `WOLFMUX_STALL_AFTER` a config key, ARCHITECTURE's stall section, the ROADMAP and TROUBLESHOOTING rows.

## Left

- The lead's tenth-call looker and the status looker of a stall were not seen on the real CLI (stub checks).
- A jump over the limit within one request cannot be warned (ADR-0038, "Not built").
- Codex: nothing measured, as before.
