# ADR-0023: A founder recovers or cleans up a team whose lead is not running

**Date**: 2026-09-23
**Status**: accepted
**Deciders**: repository owner (GitHub issue #2); Claude (implementer)

## Context

A lead may found a team and hand work over to it ([ADR-0019](0019-deleting-a-team-and-founding-one.md)), and
does not manage that team afterwards: its own lead does. That is right while that lead runs. When it does not
(a session restart killed its pane, the machine rebooted, or it is finished and past its context budget) nobody
inside Wolfmux could restart, stop or delete the team: the founder was refused with "you do not manage it", and
only the human, from outside, could act. The founded team's record, worktrees and branches stayed for ever, and a
replacement team had to be founded to take the work over. The human had asked not to be pulled in for this.

## Decision

The founder of a team may run `restart`, `stop`, `remove` and `destroy` (every form, `--purge` included) on it,
and `start <model> --team <it> --continue`, while that team's lead is not running: its pane exited or is gone, or
there is no tmux session at all. Never `policy`, `approve` or `deny`. While the lead runs, the refusal (exit 77)
stays and says "you founded it: once its lead has stopped you may restart or destroy it". Another team's lead and
every worker are refused as before.

The founder is the Beads identity in the lead record's `spawned_by` (`lead`, `review.lead`), written when the team
was started, and kept in `meta.json` as well, because a plain `teamctl destroy` deletes the lead's record and the
workers' records stay. One helper, `founder_may_act` (lib/policy.sh), is asked by `require_manager` and
`start_permitted`. Every such act is announced to the human the way founding a team is (`notify_deliver`) and is
logged with `by` set to the founder's Beads identity, not the plain role: `lead` in the log would be taken for the
lead of the team acted on. A purge deletes the team's own log, so it is also written to the founder's own team's log.

`teamctl teams` and `teamctl status` mark a team without a running lead `orphaned` and say who may act on it: you,
and, when an agent founded it, that founder. `status --json` and the new `teams --json` carry `founder` and
`orphaned`.

A lead record that is written again for a team that already has one (a restart without a session, or another
model asked for) keeps `handover`, `spawned_by` and `created_at`. It is done inside `cmd_start`, before the pane
is created: the pane reads the record as it starts, so setting them afterwards would race the handover prompt.
Without this the founder would lose its authority with the first restart.

## Alternatives Considered

### Alternative 1: `teamctl adopt <team>` / `takeover`, moving management to the caller
- **Pros**: an explicit, recorded handing over of a team
- **Cons**: a new command, a second notion of "manager" that has to be undone, and a lead could adopt a team whose lead is alive
- **Why not**: the founder relationship already exists and is recorded; acting only while no lead runs cannot conflict with a manager

### Alternative 2: `teamctl handback`, the founded lead hands management back before it stops
- **Pros**: no new authority rule
- **Cons**: it needs the founded lead to remember, and the case in the issue is precisely a lead that died or was spent without doing anything
- **Why not**: it cannot help when the lead is already gone

### Alternative 3: any lead may act on any team whose lead is not running
- **Pros**: simpler rule
- **Cons**: one team's lead could delete another team's work because it looks dead for a moment
- **Why not**: the founder handed the work over and is the one who answers for it; nobody else is

## Consequences

### Positive
- dead or finished founded teams are recovered or deleted without the human and without founding a replacement
- an orphaned team is visible, with who may act on it

### Negative
- a founder may act on a team whose lead is only briefly not running (for example between `stop` and `restart` by the human); you are told each time and the lead's conversation is kept (`--continue`)
- the founder is stored in two places (the lead's record and `meta.json`)

### Risks
- like all of the policy this is cooperative: an agent runs as your macOS user, and the records are files. The founder identity is what `spawned_by` says; a lead that edits state files can claim it. The check stops mistakes and prompts, not an adversary
