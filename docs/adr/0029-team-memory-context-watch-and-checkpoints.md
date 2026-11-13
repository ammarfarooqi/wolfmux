# ADR-0029: Team memory at session start, a context watch, and checkpoints

**Date**: 2026-11-13
**Status**: accepted
**Deciders**: the owner (the complaint), the memory-management team

## Context

Three things were missing, and each one cost real hours:

- Nothing an agent learned about a project reached the next agent. Every worker rediscovered how
  the tests are run and what breaks.
- Nobody told an agent that its conversation was filling up. A worker reached 255k tokens without
  one commit (2026-10-04); the lead could see the CONTEXT column (ADR-0025) only by asking.
- After a compaction, or in a fresh conversation given to a full agent, the agent had to work out
  again where it was. `teamctl restart <role>` kept the worktree and lost the thread.

Beads already has a store every worktree and every team of a project reads: `bd remember`,
`bd memories`, `bd prime --memories-only`. It was never shown to an agent, because wolfmux
initializes Beads without its own agent hooks (ADR-0003).

## Decision

1. Team memory is Beads' memories. Wolfmux adds no store and no wrapper command. The SessionStart
   hook (ADR-0028) puts them into every new, resumed or compacted conversation, capped
   (4,000 characters). The protocol tells agents what is worth a `bd remember`: how to build and
   test, what broke and why, a decision and its reason. Not the task at hand.
2. The context watch: every tenth tool call the PostToolUse hook reads how full the conversation
   is from the transcript the CLI names, with the reader `teamctl status` already uses. At
   `WOLFMUX_CONTEXT_WARN` (60%) the agent is told once to commit and to write a checkpoint. At
   `WOLFMUX_CONTEXT_ROTATE` (80%) it is told once to start nothing new, and the lead gets a
   message with the command that gives the task a fresh conversation.
3. A checkpoint is the agent's own note of where it stands: `teamctl checkpoint "<done / next /
   watch out>"`. It is kept in the agent's run directory with a generated header (time, branch,
   HEAD, uncommitted files, its task) and appended as a note to its task in Beads. A PreCompact
   hook adds the git state by itself, since an agent cannot be asked anything at that moment.
4. SessionStart shows the checkpoint to that role's next conversation: after a compaction, a
   resume, or a restart. So `teamctl restart <role>` is the rotation: same worktree, same branch,
   a new conversation that starts from the checkpoint, the inbox and the team memory.

## Alternatives Considered

### Alternative 1: a memory service (a vector store, a knowledge graph, a memory agent)
- **Pros**: semantic recall over a large history.
- **Cons**: a daemon, an embedding model or a second LLM in the loop, and a store outside the
  project. A team's working memory is small and specific, and the agents can already search
  (`bd memories <word>`, `git log`, `grep`).
- **Why not**: GOALS.md rules out a daemon, and files plus search is what the agents use well.

### Alternative 2: Claude Code's own auto memory (`MEMORY.md`)
- **Why not**: it is per user account and per project folder of one CLI. A GLM worker, a Codex
  worker and the next team would not share it; Beads' store is the one all of them reach.

### Alternative 3: rotate an agent automatically at the threshold
- **Pros**: no lead in the loop.
- **Cons**: stopping a CLI in the middle of a tool call loses uncommitted work; the agent is the
  only one who knows whether this is a good moment.
- **Why not**: the agent is told, the lead is told, and the lead decides (ADR-0013).

## Consequences

### Positive
- What one worker learned is in the next worker's first request.
- An agent hears about its context at 60%, not at the limit, and the lead hears at 80%.
- A compaction or a restart no longer loses the thread.

### Negative
- Memories are written by agents and read by agents: a wrong one is repeated until someone
  runs `bd forget`. They are shown as what an earlier agent wrote, not as rules.
- The thresholds are a share of the window teamctl believes the model has; a provider that
  serves a smaller window than it declares makes them late.

### Risks
- A checkpoint is only as good as what the agent wrote. The generated header and the git state
  at compaction are the floor.
