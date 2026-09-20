# ADR-0002: Beads for tasks and messages; teamctl limited to processes

**Date**: 2026-09-20
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

The first design had `teamctl` own a filesystem inbox and task store, to be moved to
SQLite later. During the build the owner asked to replace that with Beads and to make
`teamctl` responsible only for tmux processes, models, worktrees and lifecycle. Beads
already provides atomic claims, dependencies, history, actor identity and a message bead
type with threading.

## Decision

Beads is the data plane for tasks and messages. `teamctl` stores no task or message,
reads no bead, and exposes no `send` / `inbox` / `task` command (they print the `bd`
equivalents). The two are joined only by a Beads event hook that calls `teamctl nudge`.

## Alternatives Considered

### Alternative 1: Keep the custom file store
- **Pros**: no new dependency; trivially inspectable
- **Cons**: reinvents claims, dependencies, history, threading; the owner rejected it
- **Why not**: owner decision

### Alternative 2: Thin `teamctl send` wrappers over `bd`
- **Pros**: shorter commands for agents
- **Cons**: two vocabularies for one thing, and `teamctl` would again know about messages
- **Why not**: contradicts the narrowed scope

### Alternative 3: Implement `bd mail` via Beads' mail delegate
- **Pros**: agents sometimes type `bd mail` by habit
- **Cons**: makes `teamctl` a mail provider
- **Why not**: same reason

## Consequences

### Positive
- one well-tested tracker instead of a home-grown one
- clean separation: data plane vs control plane
- the planned SQLite migration disappears

### Negative
- a new dependency (a 140 MB binary) with its own upgrade rules
- agents must learn `bd`, including the non-obvious `--include-infra` for inboxes

### Risks
- Beads is young and changes quickly — mitigated by pinning the tested version in the docs and keeping the glue to one hook
