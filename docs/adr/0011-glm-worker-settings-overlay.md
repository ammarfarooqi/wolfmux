# ADR-0011: A settings overlay for GLM workers, with claude-mem off

**Date**: 2026-09-20
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

Workers share the owner's `~/.claude`, which is intended. One installed plugin, `claude-
mem`, runs a long-lived summarizer that makes its own model calls and inherits the
environment of whichever session starts it. Started from a GLM worker it would send
memory traffic from the owner's normal sessions to Z.ai, under a Claude model id.

## Decision

`~/.config/wolfmux/glm-worker-settings.json` is merged into the single `--settings`
value of GLM workers. It ships with `claude-mem@thedotmack` disabled. Deleting the file
restores identical behaviour to normal sessions; `doctor` reports what it disables.

## Alternatives Considered

### Alternative 1: Do nothing
- **Pros**: workers identical to normal sessions
- **Cons**: rare but real cross-provider data routing; memory polluted by worker sessions
- **Why not**: conflicts with provider isolation

### Alternative 2: Disable all plugins in workers
- **Pros**: maximal isolation
- **Cons**: workers lose the owner's skills and rules
- **Why not**: too blunt

## Consequences

### Positive
- a transparent, editable mechanism for any worker-only setting
- verified with `claude --settings … plugin list`: only that plugin flips

### Negative
- it changes a plugin's behaviour in workers without the owner having asked for it — hence it is documented prominently and trivially reversible

### Risks
- other daemon-spawning plugins installed later — stated as a general rule in SECURITY.md
