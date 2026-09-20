# ADR-0013: One manager — policy for permissions and spawning, native agent teams off in workers

**Date**: 2026-09-20
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

First real use exposed three problems. (1) A GLM worker's subagents appeared as extra
terminal panes and asked *the worker* for permission: the owner's settings enable Claude
Code's experimental agent teams, and with that feature on any subagent a session names
becomes a teammate whose team lead and permission approver is that session. A worker
had become a second manager. (2) Agents stalled on permission prompts; the owner wants
the lead and the workers in bypass mode, and the lead able to approve or reject workers'
requests. (3) A worker could add teammates with nothing controlling it and without the
lead knowing.

## Decision

The lead is the only manager. `teamctl` identifies the caller from the pane it runs in
and reserves `start`, `stop`, `restart`, `destroy`, `policy`, `approve`, `deny` for the
lead and the human. A per-project policy holds `lead-permissions` (skip|ask, default
skip), `worker-permissions` (skip|lead|ask, default skip) and `worker-spawn` (on|off,
default off). Every Claude-based worker is launched with agent teams switched off through
a generated per-agent settings file. In `lead` mode a `PermissionRequest` hook routes each
request to the lead (`teamctl approvals|approve|deny`). A spawn by a worker records
`spawned_by` and is announced in the lead's pane.

## Alternatives Considered

### Alternative 1: Keep native agent teams inside workers, only set bypass mode
- **Pros**: no prompts, so the visible symptom disappears
- **Cons**: teammates would still report to a worker, invisible to `teamctl status`, outside worktree isolation
- **Why not**: the hierarchy problem stays; only its symptom goes away

### Alternative 2: Approve by typing into the worker's prompt (`send-keys 1`)
- **Pros**: no hook needed; works for any CLI
- **Cons**: depends on scraping the screen to know what is being approved; races with the TUI
- **Why not**: violates "state is structured, not scraped"; Claude Code offers a documented hook

### Alternative 3: Turn agent teams off globally in the owner's settings
- **Pros**: one line
- **Cons**: changes the owner's normal sessions and the lead
- **Why not**: the owner uses that feature; only workers must not become managers

## Consequences

### Positive
- one hierarchy, visible in `teamctl status` (permission mode, spawned by, pending approvals)
- no agent stalls on a prompt by default; a stricter mode exists without losing flow
- verified on the real CLI: with the override no team directory is created for the session

### Negative
- bypass mode means an agent can run any command as the user; isolation is by worktree and protocol, not by sandbox
- `lead` mode does not exist for Codex-based workers (they fall back to `ask`)
- the manager check is cooperative, not a security boundary

### Risks
- Claude Code renaming the environment variable or the hook contract — `tests/smoke.sh` checks the generated settings and the hook's decision objects; the probe in VERIFICATION.md shows how to re-check the real CLI
