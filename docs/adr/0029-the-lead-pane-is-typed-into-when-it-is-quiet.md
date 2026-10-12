# ADR-0029: The lead's pane is typed into when it is quiet, not never

**Date**: 2026-10-12
**Status**: accepted
**Deciders**: the repository owner (issue #12), `communication-management.lead` (who measured it), the v1.16.1 author

## Context

ADR-0028 answered "a client is attached to this team" with filing only: the notice went
into the per-role inbox file and nothing was typed into the lead's pane. Its own Context
section already said the thing that makes that wrong — "Neither fires for an agent that is
sitting idle" — and its Risks section named the case as a known limit. The limit then
happened, in production, and cost most of a working day.

Measured by `communication-management.lead` on 2026-10-12: the `dashboard-wiring` team's
lead sat idle from 13:58Z; P1 notices sent to it at 16:13Z and 16:53Z were never delivered;
it was still asleep at 17:35Z. Comms' own inbox showed six notices as "NEW, not yet given
to the agent". Nothing was lost — the beads were in Beads and the lines were in the file —
but nothing handed them over either. The `Stop` hook fires on a TURN BOUNDARY, and an
agent that is already idle has no further boundary; `UserPromptSubmit` needs a human
keystroke. Filing is a record, not a channel.

The requirement that put the suppression there has not changed, and it is the owner's
words: "i dont want to keep seeing these updates in the mid of my convos these messages
should be hidden". So two things have to hold at once, and that tension is the decision.

## Decision

For the LEAD under the default `detached-lead` rule with a client attached, a notice is no
longer filed-and-dropped: it goes down the same path a busy WORKER pane has used since
v1.14.0 — `tm_pane_human_busy`, the per-role marker, the one detached waiter — with the
keystroke window widened from `WOLFMUX_NUDGE_HUMAN_IDLE` (5 s) to
`WOLFMUX_NUDGE_LEAD_IDLE` (300 s), because that pane is the human's own conversation and
five seconds of silence there is a pause for thought, not an empty chair. A quiet pane is
typed into at once; a busy one parks the notice and the waiter delivers it when the pane
goes quiet. `off` and `workers` still mean never, for anybody.

The change is an ORDER change in `_nudge_one` plus one new window: the suppression check
used to sit AHEAD of the waiter, so v1.14.0's guarantee — "never glued onto a half-typed
line, but eventually typed" — had quietly become "never typed at all".

## Alternatives Considered

### Alternative 1: leave it filed, and have the lead's own hooks poll
- **Pros**: nothing new is typed anywhere; the suppression stays absolute.
- **Cons**: there is no hook that fires without a turn boundary or a keystroke. A poller
  would have to be a process of our own typing into the pane anyway, which is this
  decision with an extra process in front of it.
- **Why not**: it is the same keystroke through a longer pipe.

### Alternative 2: deliver on the desktop notification only, and leave the agent asleep
- **Pros**: no line in the conversation, ever.
- **Cons**: the notice is FOR THE AGENT. A banner reaches the human, who then has to
  prompt the lead by hand — which is exactly the manual step the measured day consisted
  of. It also makes every cross-team message depend on somebody being at the machine.
- **Why not**: it does not reach the reader the notice is addressed to.

### Alternative 3: reuse `WOLFMUX_NUDGE_HUMAN_IDLE` (5 s) for the lead's pane too
- **Pros**: no new knob.
- **Cons**: 5 s was sized for a worker's pane, which nobody sits in front of. In the
  human's own conversation, five seconds without a keystroke is reading the last answer.
  A notice typed in then is precisely the complaint issue #11 was filed about.
- **Why not**: it would fix issue #12 by reopening issue #11.

### Alternative 4: a knob so the owner chooses, defaulting to the v1.15.0 behaviour
- **Pros**: nobody's expectation changes without being asked.
- **Cons**: the default is what every team on the machine runs, and the default would stay
  the broken one. A fix nobody switches on is not a fix.
- **Why not**: the window IS the knob, and it defaults to the cautious end (300 s) rather
  than to the broken end (never).

## Consequences

### Positive
- A notice filed for an idle lead reaches that lead with no human keystroke, which is the
  one thing v1.15.0 could not do.
- Nothing new was invented: the marker, the one waiter, the debounce, the collapse, the
  reap, the heartbeat, `inbox_mark_typed` and `trap '' HUP INT TERM` are v1.14.0's, in
  v1.14.0's order.
- The marker carries the window (`nudge_pending_put_idle`, raise-only), so a notice parked
  for the human's own pane is never delivered later under a worker's 5-second rule.
- The suites now contain an IDLE agent, in both directions. No suite had one before, which
  is why 933 passing checks did not catch this.

### Negative
- One more knob to know about: `WOLFMUX_NUDGE_LEAD_IDLE`.
- A human who sits reading the lead's pane for more than 300 s without touching a key can
  still be typed into. The 300 ms window inside `tm_type_line` (ADR-0021) therefore
  applies to the lead's pane again, where ADR-0028 had removed it.
- `teamctl nudge lead` now usually answers `deferred:` or `notified:` where it answered
  `filed:`. `filed:` remains for `off` and `workers`.

### Risks
- The keystroke check needs an attached client's `#{client_activity}`, and `send-keys`
  does not move it, so no test can type as the human. `tests/nudge-typing.sh` compares the
  window against the real client's real activity timestamp instead — the same comparison
  the code makes — and the half-typed-line twin is checked directly.
- `_notify_type_or_park` (the spawn, policy and approval lines) is NOT changed by this
  ADR: it is reached only when typing was already allowed, or through the approval grace,
  and it keeps the 5-second window. If a spawn or policy notice for an attached lead ever
  needs the same treatment, it is a separate decision on a separate path.
