# ADR-0025: Context use in status, and a fresh conversation in a built worktree

**Date**: 2026-09-23
**Status**: accepted
**Deciders**: the adding-providers team (lead's design, this worker's implementation)

## Context

Short follow-up tasks pay a large cold-start cost: every spawn is a fresh worktree
(dependency install, build) and a fresh conversation (project rules, the ticket). A lead
that wants to reuse a finished worker has no signal for whether its conversation still
has room, so the safe choice is always a new spawn. GitHub issue #5.

## Decision

1. `teamctl status` shows each agent's context use. It is read from what the CLI already
   wrote to disk, never from a live process:
   - Claude family: the newest `*.jsonl` transcript under the agent's transcripts
     directory (the path the purge code already computes). Context in use is what the
     last assistant turn saw: `input_tokens + cache_read_input_tokens +
     cache_creation_input_tokens`. Requests: assistant turns with usage.
   - Codex: the newest rollout under the codex sessions directory
     (`WOLFMUX_CODEX_SESSIONS` overrides it) whose `session_meta.cwd` equals the
     worktree; its last `token_count` event supplies usage, request count and the window
     Codex actually serves.
   - Only the last 400 lines of a transcript are read. A malformed line, a missing file
     or an unknown event shape means "unknown" (`-`), never an error. The window comes
     from the provider table, is 1M for a model id that ends in `[1m]`, else 200k.
2. `teamctl spawn <role> <model> --from-worktree <old-role>` starts a fresh conversation
   in an existing built worktree: the old worker must be stopped and its worktree clean
   (exit 1, the uncommitted files listed), a new branch is cut in that directory from
   `--base` (default: the project's HEAD), the old branch and commits stay, the old
   record moves to the new role, and the event log records the handover. If the pane
   cannot be created, the old worker is restored exactly as it was.
3. The protocol's LEAD section names the choice, per the CONTEXT column: restart (context
   has room), `--from-worktree` (context gone, checkout expensive), fresh spawn (rest).

## Alternatives Considered

### Alternative 1: ask a running CLI for its context through a control socket
- **Pros**: always current.
- **Cons**: no such interface exists for either CLI; it would need a daemon or pane
  scraping, both of which Wolfmux's design keeps out (ADR-0004, ADR-0008).
- **Why not**: the transcript is what the CLI itself records; reading its tail is fast
  and stateless.

### Alternative 2: let `--from-worktree` reuse the old role name
- **Pros**: one fewer name to invent.
- **Why not**: "spawn" creates a new role by contract; the same name already has a
  meaning (`teamctl restart <role>` reuses the conversation). The duplicate check gives
  that answer, and a distinct new name keeps the rollback trivial.

### Alternative 3: a `--warm` idle worker woken by Beads assignments
- **Pros**: no cold start at all for a standing seat.
- **Why not**: out of scope for issue #5. A pane process that idles for hours holds a
  tmux pane, a worktree and a model session that all keep costing (quota, or tokens);
  Beads wake-up would need a new delivery path beside the existing nudge, and a crashed
  idle worker is invisible where a stopped one is honest. What it would need: a policy
  switch, a wake notification through the Beads hook that starts a new turn instead of
  typing one line, and idle-timeout handling. Revisit if standing seats become a real
  pattern.

## Consequences

### Positive
- A lead can decide reuse against respawn with facts, and a follow-up task in a built
  worktree skips install and build.

### Negative
- The context figures are a tail heuristic: a very long conversation's request count is
  the tail's, not the whole file's.

### Risks
- Codex rollout matching depends on `session_meta.cwd` equaling the worktree path; if
  Codex changes that shape, codex agents show `-` (by design, never an error).
