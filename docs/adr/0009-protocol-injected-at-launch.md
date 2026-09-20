# ADR-0009: The team protocol is injected at launch, not written into instruction files

**Date**: 2026-09-20
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

Agents need the team rules. The owner already maintains CLAUDE.md / AGENTS.md files and
asked that they not be replaced; a global edit would also load team rules into every
ordinary session.

## Decision

`_run-agent` builds a prompt from a short identity header plus `TEAM_PROTOCOL.md` and
passes it with `--append-system-prompt` (Claude Code) or `-c
developer_instructions='''…'''` (Codex). Workers additionally get a one-sentence kickoff
prompt; the lead gets none.

## Alternatives Considered

### Alternative 1: Add a reference to global CLAUDE.md / AGENTS.md
- **Pros**: what the brief proposed
- **Cons**: affects every session; edits owner files
- **Why not**: unnecessary

### Alternative 2: Write an AGENTS.md into each worktree
- **Pros**: visible to any tool
- **Cons**: pollutes branches with a generated file
- **Why not**: would end up in commits

## Consequences

### Positive
- no instruction file is touched
- only team sessions see the protocol
- identical mechanism for both CLI families

### Negative
- the protocol is not visible in the repository the agent works on
- the kickoff costs one small model turn per spawned worker (`--no-kickoff` avoids it)

### Risks
- a protocol containing `'''` would break the TOML literal — detected, with a fallback to a pointer sentence
