# ADR-0018: Several named teams in one project

**Date**: 2026-09-20
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

A project had exactly one team: one tmux session, one registry, one lead. The owner had
an Astra-led team running, ran `teamctl start fable` to get a second, Fable-led team, and
was attached to the Astra session instead, because "a session exists" was the whole test.
They want several teams side by side, each named by them, and `teamctl status` showing
all of them as a hierarchy: team, its manager with the wolf, its teammates below.
Constraints: projects that have one team must not notice any change (state on disk, tmux
session name, Beads names, commands); all teams of a project share one Beads database;
and another session was changing the same files at the same time, so the change had to
stay additive.

## Decision

A project has teams. The first is called `default` and lives exactly where the only team
used to live. A team named with `--team <name>` (lowercase, digits, `-`) gets its own tmux
session (`team-<project>-<name>`), its own state under `state/<project>/teams/<name>/`,
its own worktrees and `ai/<name>/…` branches, its own lead, policy and arrangement.
Roles are per team, so two teams can each have a `backend`. In the shared Beads database
an agent of a named team is `<team>.<role>`; the first team keeps plain roles. `--team`
may stand before or after any command. Without it: inside a pane the agent's own team;
at your terminal the only team there is; with several, the command says which exist and
asks you to choose, except `status` and `teams`, which show all. `teamctl start <model>`
without `--team` means the first team, and if that one is running under another model it
no longer attaches: it prints how to open it and how to start a second team. A lead
manages its own team only.

## Alternatives Considered

### Alternative 1: One tmux session, one window per team
- **Pros**: one attach shows everything
- **Cons**: a terminal tab shows one window at a time anyway; `teamctl attach` would need window switching; a team's arrangement, status line and notifications are per session today
- **Why not**: a team is the unit you open in a tab

### Alternative 2: Role names unique across the project, leads called `<team>-lead`
- **Pros**: Beads names stay plain, no `<team>.` prefix
- **Cons**: "lead" stops being a constant (the pane mark, the manager check and the protocol all key on it); two teams could not both have a `backend`
- **Why not**: more special cases than a name prefix

### Alternative 3: Auto-name a second team after the requested model
- **Pros**: `teamctl start fable` would just work as the owner first tried it
- **Cons**: the same command is also how a single team is re-opened and recovered; creating teams implicitly makes a typo a team
- **Why not**: the refusal prints the exact command, which costs one copy and paste and never surprises

### Alternative 4: A separate Beads database per team
- **Why not**: Beads lives in the repository (`.beads/`), there is one per project, and cross-team hand-offs (`-a review.lead`) are a feature

## Consequences

### Positive
- any number of teams per project, each opened in its own tab, all visible in one `teamctl status`
- nothing moves for existing projects; an older `teamctl` simply does not see named teams
- worktree guard, notifications, approvals and arrangement are per team without new code: they all hang off the team's state directory and session

### Negative
- agents of a named team must use `<team>.<role>` in Beads. The session context says so, and the protocol's examples are rewritten for them at launch, but a model can still address a plain `lead` by mistake, which is the first team's lead
- with several teams, commands typed at your own terminal need `--team`
- teams of one project share the repository: two teams working on the same files will meet at merge time like any two branches

### Risks
- a team renamed or deleted by hand on disk while its session runs: state and session would disagree; `teamctl destroy --team <name>` is the supported way out
