# ADR-0022: A worker's worktree can live in another repository, with isolation still on

**Date**: 2026-09-23
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

[GitHub issue #4](https://github.com/ammarfarooqi/wolfmux/issues/4). A feature spanned three
repositories; the wolfmux project was one of them. A team, even a founded one, lives inside
one project: its lead works in that checkout and its workers get worktrees of it. With the
worktree guard on, a worker could not touch the other repositories at all, so the only way
through was `teamctl policy worker-isolation off` — a project-wide switch. From then on every
worker lost the guard, including the ones that never left the project, and workers hand-made
worktrees in the other repositories that `teamctl status`, `diff`, `remove` and `destroy` knew
nothing about. The guard was removed exactly where mistakes were most expensive: three
repositories and a shared development database.

## Decision

`teamctl spawn <role> <model> --repo <path>` creates that worker's worktree **and** branch in
that repository. The record gains a `repo` field (empty = this project), and everything that
touches a worker's git state goes through `git_for_role <role>` instead of the project's
`gitr`: `status`, `diff`, `worktrees`, `remove`, `destroy --worktrees`, `destroy --purge` and
the purge report. "Commits your current branch does not have" therefore means that
repository's current branch.

- The worktree lives under `~/.wolfmux/worktrees/<that repository's project key>/teams/<team>/`,
  reusing `project_key`, so two repositories never share a worktree directory.
- `--base` is resolved in that repository, and defaults to its `HEAD`.
- `--repo` must point inside a git repository that has at least one commit (exit 64 otherwise).
  A path that resolves back to the project itself simply means the project, which is the default.
- **Isolation stays on**, and grows a second read-only checkout. The worker is held to its own
  worktree; the project's checkout (`WOLFMUX_ROOT`) is read-only for it as before, and so is
  the main checkout of its own repository (`WOLFMUX_REPO`, new). Without that second one the
  guard would refuse a write into that checkout only as "outside your worktree", which is true
  but silent about why, and would not hold at all for a repository that happens to sit in a
  temporary directory (the guard's scratch allow-list).
- `bd` resolves its workspace through git, so a worker in another repository would look for
  Beads there. `teamctl` sets `BEADS_DIR` for such a worker to the project's own workspace:
  its inbox, its lead and its team are unchanged; only its worktree moved.
- `teamctl status` grows a `REPO` column, but only while some agent of that team has one. The
  column would otherwise cost every team a column that says `-`. `--json` always carries `repo`.
- Deleting is symmetric with creating: what wolfmux made in that repository is what wolfmux
  removes there, and the worktree path is checked to lie inside that repository's own worktree
  directory before anything is deleted, exactly as for a project worker.

## Consequences

- Cross-repository work no longer costs the whole project its guard, and the worktrees are on
  the books, so `teamctl remove` and `destroy --purge` clean them up.
- A team still belongs to one project. Deliberately out of scope, and worth revisiting if they
  are asked for: isolation set per worker or per team rather than per project, an `--allow-path`
  allow-list of extra writable directories, and founding a whole team in another repository.
- The shell half of the guard stays heuristic. A worker's shell command that writes into its
  own repository's checkout is caught by the same patterns as one writing into the lead's, but
  a command that writes into some fourth repository is not: the guard is a guard against
  mistakes, not a sandbox, and that has not changed.
- `git_for_role` reads the record to find the repository. A record naming a repository that is
  gone makes git fail, so nothing is deleted — which is the safe direction.
