# ADR-0007: Z.ai key through apiKeyHelper, with a login guard

**Date**: 2026-09-20
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

Z.ai documents `ANTHROPIC_AUTH_TOKEN` in the environment. An environment variable is
inherited by everything the agent runs, so one `env` dump puts the key into a
transcript. Claude Code also supports `apiKeyHelper`. Testing against a localhost mock
revealed a worse problem: a process that inherits only `ANTHROPIC_BASE_URL` falls
through to the stored claude.ai login and sends it to that URL.

## Decision

Default: pass `apiKeyHelper` (a Keychain read) through `--settings`, so the key never
enters the environment. Fallback: `WOLFMUX_GLM_AUTH_MODE=env` in the config file. In
both modes export `CLAUDE_CODE_OAUTH_TOKEN` as an inert placeholder: it outranks the
stored login and is outranked by both real delivery modes, so children of a worker fail
closed at Z.ai instead of presenting the Claude subscription token. `claude-fable`
removes the placeholder.

## Alternatives Considered

### Alternative 1: Env mode only
- **Pros**: exactly what the vendor documents
- **Cons**: key visible to every subprocess of the worker
- **Why not**: kept as the fallback, not the default

### Alternative 2: Helper mode without a guard
- **Pros**: simplest secure-looking option
- **Cons**: measured: child processes leak the claude.ai login to Z.ai
- **Why not**: unsafe

### Alternative 3: A separate `CLAUDE_CONFIG_DIR` for workers
- **Pros**: workers could not even see the Claude login
- **Cons**: loses the owner's plugins, skills and hooks; first-run onboarding in every worker
- **Why not**: too invasive for V1

## Consequences

### Positive
- the key is never in a worker's environment by default
- the Claude login cannot reach Z.ai from any process in a worker's tree
- evidence is reproducible with `tests/credential-routing.sh`

### Negative
- helper mode sends the key as both `x-api-key` and `Authorization`; acceptance by Z.ai was not verified at build time
- nested `claude` calls from a worker fail by design in helper mode

### Risks
- Claude Code changing its credential precedence — the routing test detects it
