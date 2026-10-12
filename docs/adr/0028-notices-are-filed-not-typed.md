# ADR-0028: A notice is filed, not typed into the human's conversation

**Date**: 2026-10-10
**Status**: accepted
**Deciders**: the repository owner (issue #11), the v1.14.0 author as reviewer, the v1.15.0 author

## Context

`teamctl` typed every notice — `[wolfmux] Beads update for <role> …`, and the spawn,
approval and policy lines — straight into the target pane with `send-keys`. ADR-0021 and
v1.14.0 stopped a notice landing *inside* a half-typed line. Issue #11 is the complaint
underneath that one: the lead's pane **is** the human's conversation, so a notice typed
into it perfectly is still an interruption, and the owner sees several a day.

The constraint that shapes everything is that a notice has two readers who want opposite
things. The **human** wants to know mail arrived and to read it when he chooses. The
**agent** needs the text as input, or it never runs the command the notice names — and
typing is the only way to put input into a CLI from outside. A status line or a popup
reaches the human only; removing the typing reaches the agent not at all.

Claude Code does have two channels that are not keystrokes: a `Stop` hook, which can
answer `{"decision":"block","reason":…}` and make the agent carry on, and
`UserPromptSubmit`, whose stdout is added to the model's context. Neither fires for an
agent that is sitting idle, and Codex has neither.

## Decision

Every notice is appended to a per-role file (`$STATE_DIR/inbox/<role>`) before anything
else is decided about it, and read from there by five channels: the status-bar count, the
`prefix N` popup, one collapsing desktop notification, the agent's `Stop` and
`UserPromptSubmit` hooks, and — only where it is still the right channel — typing.
`WOLFMUX_NUDGE_TYPE` (default `detached-lead`) says where that is: workers as before,
plus the lead **only while no client is attached to the team's session**.

Each line carries two independent state letters: new/seen for the human, and
undelivered/delivered for the agent.

## Alternatives Considered

### Alternative 1: keep typing, but only into a pane whose agent is idle
- **Pros**: no new machinery; the agent always gets the notice as input.
- **Cons**: "is this agent idle" is not a question anything answers. The only evidence is
  what the TUI has drawn, and the v1.14.0 work already showed how fragile reading that is
  (a dim placeholder read as typing until the dim runs were stripped).
- **Why not**: it does not address the complaint at all. An idle lead pane is exactly the
  pane the human is talking in.

### Alternative 2: a tmux popup instead of typing
- **Pros**: nothing in the conversation; no file format to design.
- **Cons**: a popup is for the human only, so the agent would never learn about the bead.
- **Why not**: rejected once already, in round 2 of the v1.14.0 review, for that reason.

### Alternative 3: one state per line instead of two
- **Pros**: simpler record and simpler code.
- **Cons**: wrong in both directions, and it was tried first: handing a notice to the
  agent cleared the human's badge, and the human reading it hid the notice from the agent.
- **Why not**: the two readers are independent by construction.

### Alternative 4: raise the desktop notification on a timer, after checking the agent did not pick the notice up
- **Pros**: would fire only for an agent that really is idle.
- **Cons**: another detached waiter per notice, and the timer is a guess at turn length;
  a long turn still looks like an idle agent.
- **Why not**: declining to type is already the honest trigger — "this cannot reach the
  agent now". If the agent was mid-turn its `Stop` hook delivers the notice as well, and
  the human has still been told once that mail arrived.

### Alternative 5: reuse `WOLFMUX_NUDGE_DEBOUNCE` (3 s) for that notification
- **Pros**: one knob fewer.
- **Cons**: 3 s was sized for typing one cheap line into a pane. A macOS banner has a
  sound and interrupts whatever the human is doing, and this machine runs three projects
  and twenty-five teams whose Beads events fire on create, update and close — dozens of
  banners in a busy hour.
- **Why not**: it would be the same complaint with a different sound. It has its own knob
  at 120 s per role, and it collapses to one banner carrying the count.

## Consequences

### Positive
- Nothing is typed into the human's conversation while he is watching the team.
- Nothing is lost on any path: the bead stays in Beads and the notice stays in the file
  whatever happens to the typing, the waiter or the hooks.
- The agent learns about a bead with no keystroke anywhere, so the 300 ms window inside
  `tm_type_line` (ADR-0021, still open) no longer applies to the lead at all.
- All of v1.14.0's machinery is kept and only narrowed, so the typed paths that remain
  behave exactly as they did.

### Negative
- An approval request reaches an idle, attached lead only when the human expands it, when
  the desktop notification is noticed, or when the lead is next prompted — plus a 20 s
  grace after which it is typed in after all, because a *worker* is blocked on it.
- A Codex lead is deliberately noisier than a Claude lead: Codex has no hooks, so typing
  is the only channel that reaches that agent at all.
- The status-line badge appears only for teams started after the upgrade: `status-left`
  is read when the tmux server starts.
- `teamctl inbox` takes a word that meant an agent's Beads inbox everywhere else. The
  alias `teamctl notices` and two sentences in `TEAM_PROTOCOL.md` and the role prompt are
  the mitigation.

### Risks
- A client attached, the human looking at another pane, and the lead idle: the bead waits
  for the badge, the notification, or the next prompt. Named in ROADMAP as a known limit;
  `WOLFMUX_NUDGE_TYPE=all` restores the old behaviour for anybody who prefers it.
- The `Stop` hook answers `block`. Two guards keep that from looping — the lines are
  marked delivered before the answer is printed, and no turn is blocked again inside
  `WOLFMUX_INBOX_STOP_COOLDOWN` (10 s) — and `tests/inbox.sh` checks each separately.
