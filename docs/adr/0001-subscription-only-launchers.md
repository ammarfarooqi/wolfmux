# ADR-0001: Subscription-only inference through per-process launchers

**Date**: 2026-09-20
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

Three providers are in play and the owner forbids any pay-as-you-go path. Claude Code
and Codex both switch provider, credential and model from environment variables and
settings files, so one stray export or settings entry silently moves traffic to a
metered API or to the wrong vendor. Z.ai's own instructions write its endpoint into
`~/.claude/settings.json`, which would redirect every Claude session on the machine.

## Decision

Each model is started through a small launcher in `~/bin` that removes every provider,
credential and model override from its own process (an explicit list plus prefix sweeps,
kept in one shared file) and then `exec`s the unmodified CLI. Provider configuration for
Z.ai is exported only inside the GLM launcher. Nothing provider-related is written to a
shell profile or a settings file.

## Alternatives Considered

### Alternative 1: Follow Z.ai's guide and edit `~/.claude/settings.json`
- **Pros**: one step; vendor documented
- **Cons**: redirects plain `claude` and the Fable lead to Z.ai
- **Why not**: violates the isolation requirement outright

### Alternative 2: Shell aliases or functions with inline variables
- **Pros**: no files in `~/bin`
- **Cons**: not usable from tmux panes or other agents; easy to bypass; tempts people to inline the key
- **Why not**: the orchestrator needs real executables

### Alternative 3: A local proxy / router (LiteLLM, OpenRouter)
- **Pros**: one endpoint for everything
- **Cons**: metered by nature, another daemon, another credential store
- **Why not**: explicitly forbidden

## Consequences

### Positive
- plain `claude` is untouched
- a launcher is safe to run from any environment, including another agent's shell
- `teamctl doctor` reuses the same list, so checks and scrubbing cannot drift

### Negative
- settings-file `env` entries still apply inside Claude Code after the scrub, so they must be detected rather than prevented
- the scrub list needs a glance when a CLI adds new variables (the prefix sweeps cover most)

### Risks
- a future variable outside the swept prefixes — mitigated by `doctor` and by pinning provider and login method on the command line
