# ADR-0019: Deleting a whole team, and a lead founding a new one

**Date**: 2026-09-20
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

Two questions from the owner once a project could hold several teams
([ADR-0018](0018-several-teams-per-project.md)). First: is there one command that ends a
team, deletes what it left behind and frees the space — with a guard for uncommitted work,
a look at what would be lost, and a force option? `teamctl destroy` keeps every worktree
by design, `destroy --worktrees` removes only what holds nothing, `remove` works role by
role. Measured on the owner's project: a worker costs a checkout of the tracked files
(99 MB there) plus whatever it installs or builds inside (up to the size of the main
checkout without `.git`, about 0.9 GB there); the lead costs nothing; teamctl's records a
few KB; the agents' Claude Code transcripts some MB. Second: can teams talk to each
other, and can a lead start a fresh team and hand everything over?

## Decision

`teamctl destroy --purge` deletes a team: session, every worker's worktree and `ai/`
branch, its records, and the agents' Claude Code transcripts (`--keep-transcripts` keeps
those). It looks first and touches nothing until it has an answer: a report per worker
(size, uncommitted files, commits the current branch does not have) and the total it
frees. Work that exists nowhere else: you are asked, with the list in front of you;
`--force` deletes it anyway; with nobody to ask and no `--force` it refuses and the team
keeps running. Nothing at risk: one question, or `--yes`. Every path comes from a record
and is checked to lie inside the team's worktree directory; only `ai/*` branches are
deleted; the first team's purge never touches `teams/`. `teamctl teams` shows DISK per team.

Teams talk through Beads, which they share: `-a <team>.lead` reaches another team's lead,
the first team's is plain `lead`; every agent is told so at launch. A lead may found a
team that does not exist yet and hand over: `teamctl start <model> --team <new>
--handover <bead-id>`; the new lead's first words are "read that bead". The founder is
recorded, you are notified, and the founder does not manage the new team. Policy
`lead-teams on|off` (default on). A lead can never start or take over a team that already
has a lead; a worker can never found one.

## Alternatives Considered

### Alternative 1: `destroy --worktrees --force` instead of a new flag
- **Pros**: no new word
- **Cons**: `--worktrees` means "tidy what is safe"; bolting "and the unsafe" onto it makes the careful command dangerous by one flag
- **Why not**: deleting a team is a different intent and gets its own word

### Alternative 2: Type the team's name to confirm
- **Pros**: hard to do by accident
- **Cons**: friction on every purge, including the common one where nothing is at risk
- **Why not**: the question is only asked about work that would be lost, with that work listed; `--force` is the deliberate bypass

### Alternative 3: Keep transcripts always
- **Pros**: nothing of the user's Claude data is ever removed
- **Cons**: they are the largest non-worktree item, they belong to worktrees that no longer exist, and "free the space" was the request
- **Why not**: deleted by default, said so in the report, `--keep-transcripts` for the other case

### Alternative 4: Hand over by typing into the new lead's pane
- **Why not**: the rule since ADR-0006: content travels through Beads, the pane only hears that something waits. A kickoff that names one bead id keeps that rule and has no timing problem

## Consequences

### Positive
- one command gives the space back, and cannot take work with it silently
- a long-running lead can split work off to a fresh team (new context window, another model) without the human relaying anything

### Negative
- commits of deleted `ai/` branches stay in `.git` until git collects garbage; the command says so and names `git gc --prune=now`
- a lead can spend subscription quota by founding teams; the notification and the policy switch are the brake

### Risks
- the transcript folder is derived from the worktree's path by Claude Code's naming rule; if that rule changes, purge leaves the transcripts behind (it never deletes a folder it did not compute from a checked worktree path)
