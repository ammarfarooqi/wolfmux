# ADR-0016: A guard that keeps each teammate in its own worktree and on its own branch

**Date**: 2026-09-20
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

Every worker has had its own git worktree and branch since v1.0, and its instructions
say "work only here". That was all: with `worker-permissions skip` (the default) a
worker's CLI runs in bypass mode and can edit the lead's checkout, read or change a
teammate's half-finished work, switch or delete branches, or type into another pane.
The owner asked for assurance that a teammate is tied to one worktree, that context
does not leak between teammates, and that nobody touches other worktrees or branches.
Every agent is the same macOS user, so a hard boundary would need containers or
separate accounts, which this project rules out (local, visible, no daemon).

## Decision

Claude Code runs `teamctl _guard` as a `PreToolUse` hook before every tool call of a
worker (hooks run in bypass mode too). File tools are checked exactly: a worker may
change files only inside its own worktree or a temporary directory, and may not read
another teammate's worktree or teamctl's state. Shell commands are checked by
heuristics: refused when they name another worktree, write into the lead's checkout,
move, delete or switch branches, touch `git worktree`, push to main, or drive tmux.
A refusal returns `permissionDecision: deny` with a reason that says what to do instead
(message the lead). The lead is not guarded. Policy `worker-isolation on|off`, default on.
The guard fails open.

## Alternatives Considered

### Alternative 1: Claude Code `permissions.deny` rules per worker
- **Pros**: declarative, enforced by the CLI itself
- **Cons**: rules name what to block; "everything except my worktree" is not expressible, and teammates that join later would not be covered by a list written at launch
- **Why not**: a hook can compute "inside my worktree?" per call

### Alternative 2: git hooks (`reference-transaction`, `pre-push`) in each worktree
- **Pros**: catches ref changes however they are made
- **Cons**: needs `extensions.worktreeConfig` or writes into the owner's `.git/hooks`; this project promised not to touch the repository's configuration
- **Why not**: intrusive; kept as a possible addition (ROADMAP)

### Alternative 3: a real sandbox (sandbox-exec, containers, one macOS user per agent)
- **Pros**: an actual boundary
- **Cons**: breaks the subscription logins that live in the user's keychain and home, hides the agents from the visible tmux model, and is a project of its own
- **Why not**: out of proportion to the threat: agents that make mistakes, not agents that attack

### Alternative 4: instructions only (the state before)
- **Why not**: it is what the owner asked to improve on; a long session drifts

## Consequences

### Positive
- the common ways a teammate strays (Edit/Write outside, `cd` into the main checkout, `git checkout main`, reading a sibling worktree) are stopped, with an explanation the model follows
- the boundary is visible: session prompt, `teamctl policy`, `teamctl status --json`
- no change to the repository, no new dependency

### Negative
- shell checking is pattern matching. `python -c`, a script file, or a path assembled at run time get past it. It guards against mistakes and role confusion, not against a process that sets out to get around it
- a legitimate command can be refused (for example one that mentions the lead's checkout next to `rm`); the reason tells the worker to ask the lead, and the policy can be switched off per project
- Codex-based workers have no such hook; their own sandbox applies only when they are not in bypass mode

### Risks
- Claude Code changing the `PreToolUse` contract: `tests/smoke.sh` pins the decision object; a changed contract degrades to "not guarded", never to "worker blocked", because the guard prints nothing it is not sure of
- not yet observed against a live tool call: inference was avoided on purpose and the GLM quota was exhausted on the day. The `Stop` hook from the same generated settings file has been seen firing in the owner's team
