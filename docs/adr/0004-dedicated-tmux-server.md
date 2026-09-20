# ADR-0004: A dedicated tmux server and config instead of ~/.tmux.conf

**Date**: 2026-09-20
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

The team needs mouse support, large scrollback, role titles, `remain-on-exit` and
directory inheritance. The owner had no `~/.tmux.conf` and asked that their tmux setup
not be disturbed. A tmux server also hands the environment of whoever started it to
every pane.

## Decision

Teams run on their own server, `tmux -L ai-team -f ~/.config/ai-team/tmux.conf`. The
file sources the user's tmux config first if one exists. The server is started with
provider and agent-session variables removed.

## Alternatives Considered

### Alternative 1: Create or edit `~/.tmux.conf`
- **Pros**: what the brief literally described
- **Cons**: changes every tmux session the owner ever starts; `remain-on-exit` is annoying outside a team
- **Why not**: more invasive than needed

### Alternative 2: Per-session options on the default server
- **Pros**: one server
- **Cons**: racy (a pane can die before its options are set) and environment hygiene depends on how the default server was started
- **Why not**: not deterministic

## Consequences

### Positive
- zero global footprint; delete one file to remove it
- clean pane environments by construction
- `tmux -L ai-team kill-server` stops every team and nothing else

### Negative
- `tmux ls` without `-L ai-team` shows nothing; `teamctl attach` hides that

### Risks
- a user expecting their own key bindings — covered by sourcing their config first
