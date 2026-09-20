# ADR-0003: Beads in embedded mode with a stealth init

**Date**: 2026-09-20
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

Beads' documentation recommends server mode (a `dolt sql-server` process plus the `dolt`
CLI) when several agents write on one machine, and warns about embedded mode being
single-writer. The owner wants no daemon and no database server. A default `bd init`
also commits files to the current branch, edits AGENTS.md and installs git hooks.

## Decision

Projects are initialized with `bd init --stealth --skip-hooks --skip-agents --non-
interactive --prefix <derived>` and run in embedded mode. `teamctl start` offers this
init and never runs a default one.

## Alternatives Considered

### Alternative 1: Server mode
- **Pros**: true concurrent writers
- **Cons**: a database server, a pinned extra binary, ports, lifecycle to manage
- **Why not**: breaks the no-daemon constraint without measured need

### Alternative 2: Default `bd init`
- **Pros**: the mainstream Beads setup; data can be shared through git
- **Cons**: auto-commit on the owner's branch, AGENTS.md edits, git hooks
- **Why not**: violates 'inspect and preserve'

## Consequences

### Positive
- zero processes to manage; nothing tracked in the repository
- measured: 16 parallel writers and 8 readers all succeed; claims stay atomic

### Negative
- writers queue on a file lock (about 20 s for that 24-process burst)
- no cross-machine sync unless the owner later opts in

### Risks
- lock contention with many agents — documented upgrade path to server mode
