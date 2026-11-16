# ADR-0034: What a worker's conversation starts with is a policy (`worker-context`)

**Date**: 2026-11-13
**Status**: accepted
**Deciders**: the owner (the complaint), the memory-management team's lead (measurement and code)

## Context

Workers shared the owner's `~/.claude` in full, deliberately (ROADMAP.md, "Workers share
`~/.claude`"). Measured on the owner's machine with Claude Code 2.1.323: the first request of a
freshly spawned worker was 111,365 tokens before it had read its task. That is more than half of
a 200k window, it is sent again with every request, and a worker reached the threshold for
compaction after a few dozen tool calls. About 60,000 of those tokens were the skill and agent
listings and the session hooks of nine plugins, about 30,000 the rules in `~/.claude`. The
plugins' PreToolUse and PostToolUse hooks also ran on every tool call of every worker, about
150 ms each time. A `claude -p` probe of the same setup: everything 85,700 tokens; plugins off
56,500; nothing from `~/.claude` 19,000.

## Decision

A policy key, `worker-context`, per team (`teamctl policy`, `WOLFMUX_WORKER_CONTEXT`):

- `full`: everything, as before.
- `trim` (the default): the owner's rules and settings stay. Every plugin that is enabled in
  `~/.claude/settings.json` or listed in `plugins/installed_plugins.json` is set to `false` in the
  worker's generated settings.
- `lean`: `trim`, and the worker is started with `--setting-sources project,local`, so nothing
  from `~/.claude` is read. The project's own `CLAUDE.md` and `.claude/` still are, and so are the
  per-agent settings (hooks, guard) and the login.

The lead is never trimmed. A stored or configured value that cannot be read means `full`: an
error never takes something of the owner's away from a worker.

## Alternatives Considered

### Alternative 1: leave it, and tell the owner to uninstall plugins
- **Why not**: the plugins serve the owner's own sessions. The cost is a worker's, so the
  switch belongs to the worker.

### Alternative 2: default `lean`
- **Pros**: the smallest start, 19,000 tokens.
- **Cons**: the owner's global rules (coding style, testing, security) would silently stop
  applying to workers.
- **Why not**: rules are instructions the owner wrote; listings of skills a worker never calls
  are not. `trim` removes the second and keeps the first. `lean` is one command away.

### Alternative 3: an allow-list of plugins per team
- **Why not**: no need has shown yet. `full` is there for a team that wants its plugins.

## Consequences

### Positive
- A worker has roughly twice the room for the work itself, and every request is smaller.
- No plugin hook runs on a worker's tool calls.

### Negative
- A worker no longer has the plugins' skills and subagents (a reviewer agent, a TDD skill).
  The owner's rules that name them still load; the worker cannot follow that part.
- `trim` reads two files of Claude Code's own bookkeeping to learn the plugin names. If their
  shape changes, nothing is switched off and the worker starts as with `full`.

### Risks
- A change of default: workers behaved differently before v1.24.0. `teamctl policy worker-context
  full` brings the old behaviour back for a team; `WOLFMUX_WORKER_CONTEXT=full` in the config
  file does it everywhere.
