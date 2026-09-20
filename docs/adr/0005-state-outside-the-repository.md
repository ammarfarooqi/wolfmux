# ADR-0005: teamctl state and worktrees outside the repository

**Date**: 2026-09-20
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

The brief suggested a project-local `.wolfmux/` directory plus a `.gitignore` entry.
After tasks and messages moved to Beads, what remains is a tiny registry (role, model,
worktree, branch, pane) and an event log. Worktrees must not be nested in the project.

## Decision

State lives in `~/.wolfmux/state/<project>-<hash>/`, worktrees in `~/.ai-
team/worktrees/<project>-<hash>/`. The project is identified by the main checkout's
path, resolved through git's common directory so it also works from a worker's external
worktree.

## Alternatives Considered

### Alternative 1: `.wolfmux/` in the project + `.gitignore`
- **Pros**: easy to find
- **Cons**: edits a tracked file or leaves an untracked directory; dirties `git status`
- **Why not**: unnecessary once the state is this small

### Alternative 2: Keep everything in tmux pane options
- **Pros**: no files at all
- **Cons**: lost on `stop`, so `restart` and `destroy --worktrees` could not work
- **Why not**: insufficient

## Consequences

### Positive
- nothing of `teamctl`'s is ever written into a repository
- one directory to inspect or delete

### Negative
- moving a repository orphans its state (git worktrees break on a move anyway)

### Risks
- two projects with the same directory name — the path hash separates them
