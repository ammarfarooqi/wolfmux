# ADR-0006: Pane notifications through Beads hooks and one fixed line

**Date**: 2026-09-20
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

Agents need to learn that something was assigned or sent to them. Typing message bodies
into a TUI with `tmux send-keys` invites quoting bugs, truncation and keystroke
injection. Beads documents event hooks precisely so an orchestrator can do delivery
without Beads knowing about it.

## Decision

`.beads/hooks/on_create|on_update|on_close` are three-line shims to `beads-nudge`, which
calls `teamctl nudge <assignee> --quiet --id <bead>` in the background when the assignee
is someone other than the actor (and tells the lead when a worker closes or blocks a
task). `teamctl nudge` validates both values, debounces bursts under a per-role guard,
and types one fixed template.

## Alternatives Considered

### Alternative 1: Ask senders to run `teamctl nudge` themselves
- **Pros**: explicit; no hook
- **Cons**: agents forget; two steps per message
- **Why not**: unreliable

### Alternative 2: Send the body through `send-keys`
- **Pros**: no second lookup for the recipient
- **Cons**: quoting, length and injection problems
- **Why not**: forbidden by the brief, for good reason

### Alternative 3: Polling inside each agent
- **Pros**: no tmux involvement
- **Cons**: burns model calls to discover nothing
- **Why not**: wasteful

## Consequences

### Positive
- bodies never travel through a terminal
- works identically for lead and workers, and for humans using `bd`
- never blocks or fails a `bd` command

### Negative
- comments fire no hook in Beads, so they notify nobody
- a CLI showing a modal dialog can swallow the notice

### Risks
- keystroke injection via bead fields — prevented by strict validation and a fixed template; covered by a smoke test
