# ADR-0010: Reuse the Codex CLI bundled with ChatGPT.app

**Date**: 2026-09-20
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

No `codex` was on PATH, but the ChatGPT desktop app ships a full Codex CLI that was
already signed in with ChatGPT and configured for `gpt-6-astra`. The app and any
standalone CLI share `~/.codex`, whose state databases are versioned.

## Decision

`codex-astra` resolves `AI_TEAM_CODEX_BIN`, then `codex` on PATH, then the app-bundled
binary. The installer links `~/bin/codex` to the bundled binary only when no `codex`
exists. `~/bin` is last in PATH, so a future official install takes over by itself.

## Alternatives Considered

### Alternative 1: Install the standalone CLI
- **Pros**: the documented route; self-updating
- **Cons**: a second copy at a different version sharing versioned state with the app
- **Why not**: unnecessary risk and a needless install

### Alternative 2: npm global install
- **Pros**: simple
- **Cons**: tied to one nvm Node version
- **Why not**: fragile

## Consequences

### Positive
- nothing new installed; always the same version as the app
- mirrors how the owner already links another app's CLI

### Negative
- updates arrive with the desktop app, not through `codex update`
- the bundled build is an alpha channel

### Risks
- the app removing or moving the binary — the resolver falls back to PATH and reports clearly
