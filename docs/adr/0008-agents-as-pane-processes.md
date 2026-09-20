# ADR-0008: Agents run as the pane's process, started without a shell

**Date**: 2026-09-20
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

The common way to start a CLI in tmux is to open a shell pane and type the command. That
races with shell start-up (prompt themes, plugins, spelling correction), depends on the
user's aliases, and leaves `teamctl` unable to tell whether the agent is alive.

## Decision

`split-window` / `new-session` receive the command as separate arguments (no `sh -c`):
`teamctl _run-agent <root> <role>`. That process exports the role, enters the worktree
and `exec`s the launcher, which `exec`s the CLI, so the pane's process is the agent.
`remain-on-exit` keeps a dead agent's pane and output.

## Alternatives Considered

### Alternative 1: Type the launcher into an interactive shell
- **Pros**: a shell is left behind after exit
- **Cons**: start-up races; notices could be typed into a shell; liveness unknowable
- **Why not**: not deterministic

### Alternative 2: A wrapper that stays alive as the parent
- **Pros**: could record exit codes itself
- **Cons**: tmux would report the wrapper as the pane's command
- **Why not**: defeats process inspection

## Consequences

### Positive
- no quoting layer at all
- `pane_dead` / `pane_dead_status` give exact liveness and exit codes
- `restart` is a clean `respawn-pane`

### Negative
- no shell remains in the pane after an agent exits (use `teamctl restart`)

### Risks
- a short PATH inside panes — `_run-agent` prepends `~/bin` and `~/.local/bin`, and tools are resolved with fallbacks
