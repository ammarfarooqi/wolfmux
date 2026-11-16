# ADR-0036: A trimmed agent also starts without unusable tools, connectors and named instruction files; the lead may opt in

**Date**: 2026-11-16
**Status**: accepted, amends [0034](0034-what-a-worker-starts-with.md)
**Deciders**: the owner (the complaint), the memory-management team's lead (scope), its research worker (measurement and code)

## Context

ADR-0034 took the plugins out of a worker's conversation. Measured again on 2026-11-16 with Claude
Code 2.1.325 (Haiku 5.5, real panes, `worker-context trim`): a worker's first request was still
81,024 tokens and the lead's 115,652. That part is sent again with every request, and it decides
how much room a compaction leaves: the CLI compacts at about its window minus 33,000 and starts
again at this fixed part plus what the compaction kept. A worker with a 200k window worked in
20,000 to 43,000 tokens between compactions.

What a trimmed worker still carried and never used:

- Tool schemas. A pane has 15 tools on the wire, 72,593 characters. `Artifact` alone is 37,384.
  An agent in a pane cannot publish a page, answer a dialog nobody watches, send feedback,
  schedule a wake-up, or run a second agent system.
- The claude.ai connectors of the owner's account. They connect after the first request and then
  add their tool names and instructions: 36,879 characters during a two-line task.
- Instruction files that repeat others. `~/.claude/rules/ecc/zh/` is a Chinese translation of
  `common/`: 9,142 characters, 7,785 tokens, measured.

Each has a per-process switch that needs nothing changed in `~/.claude`: a bare tool name in
`permissions.deny` takes the tool out of the request, `ENABLE_CLAUDEAI_MCP_SERVERS=false`, and
`claudeMdExcludes`. All three were verified against the real CLI before this was written.

## Decision

1. Under `worker-context trim` and `lean`, a worker's generated settings also deny, by bare
   name, Artifact, AskUserQuestion, SendFeedback, ScheduleWakeup, Workflow, ReportFindings and
   ListAgents, and set `ENABLE_CLAUDEAI_MCP_SERVERS=false`. `full` is unchanged.
2. A policy key `context-exclude` (`WOLFMUX_CONTEXT_EXCLUDE`): globs of instruction files, which
   become `claudeMdExcludes`. Empty by default. Nothing the owner wrote is left out unless the
   owner names it.
3. `teamctl doctor` names a rules folder that repeats a sibling folder in a second language
   (four of five file names shared, the folder mostly not ASCII, the sibling ASCII), with the
   exact policy line and an estimate of the saving. It is a note, not a warning.
4. A policy key `lead-context` (`full` | `trim`, default `full`, `WOLFMUX_LEAD_CONTEXT`). `trim`
   gives the lead the same three reductions, except that AskUserQuestion stays, and its plugins
   are not touched.
5. A value nobody can read means `full`, and for `context-exclude` an empty list.

## Measured

Print-mode probes with the settings wolfmux generates from the owner's `~/.claude` (Haiku 5.5,
`claude -p`; commands and usage blocks in `tests/research/results/part-a-probes.jsonl`):

| First request | Worker | Lead |
|---|---|---|
| v1.24.0 (`trim`; lead untouched) | 74,171 | 90,006 |
| v1.25.0 `trim` / `lead-context trim` | 51,884 | 67,793 |
| with `context-exclude '**/rules/ecc/zh/**'` | 44,099 | 60,008 |

Print mode offers 13 tools, of which 4 are on the deny list; a pane offers 15, with all 7. In
real team runs (project settings equal to rows 1 to 3 together): worker 81,024 to 54,289, its
summed input for the same task 589,753 to 339,615; lead 115,652 to 70,017.

The "before" row moves with the connectors: when they had not connected yet, the same probe
measured 56,744. The "after" rows do not move.

## Alternatives Considered

### Alternative 1: `--tools` with a short allow list
- **Pros**: the smallest request (23,746 with six tools).
- **Cons**: a new tool of a later CLI is missing until wolfmux learns its name, and a worker
  loses Agent and Skill, which the owner's rules name.
- **Why not**: a deny list fails open: an unknown tool stays.

### Alternative 2: leave the Chinese rules out by default
- **Why not**: wolfmux does not decide which of the owner's files matter. It finds the folder
  and prints the line; the owner runs it.

### Alternative 3: trim the lead by default
- **Why not**: the lead is the conversation the owner talks to, and may use a connector there.
  Opt-in keeps ADR-0034's promise.

## Consequences

### Positive
- A third less in every request of a worker, and more room between compactions.
- No connector tool names arrive in the middle of a worker's conversation.

### Negative
- A worker cannot use a claude.ai connector. `worker-context full` brings them back for a team.
- A rule of the owner's that tells an agent to use a denied tool cannot be followed by a worker.

### Risks
- Skills of account-synced plugins (`~/.claude/plugins/synced/`, 123 of 209 listed skills) are
  still listed: no per-process switch for them was found.
- A later CLI may rename a tool or the connector switch. Then the reduction is not made; nothing
  else breaks. `tests/context.sh` checks what is written, the probes what the CLI does with it.
