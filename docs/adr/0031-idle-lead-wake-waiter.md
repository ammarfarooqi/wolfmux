# ADR-0031: An idle lead wakes itself, through a waiter hook, when nobody is using its pane

**Date**: 2026-11-04
**Status**: accepted
**Deciders**: the owner (GO through the communication lead), wolfmux-idle-wake.lead, the wake lane

## Context

Under the default policy `human-pane-typing off` (v1.20.0), a notice for the lead is filed and
never typed while a client is attached to the team. The lead then gets it from its own hooks:
the Stop hook at a turn end, or the UserPromptSubmit hook at the next prompt. But
`inbox_human_pane` read the lead's pane as "watched" whenever ANY client was attached, so the
Stop hook stayed silent too, and only the next prompt delivered. An idle lead has no next
prompt. On 2026-11-03 tagging.lead sat 16 hours on 4 messages (issue #34). The desktop banner
fired 5 times and did not help. The owner rejected typed `[wolfmux]` lines in his conversation
twice (2026-10-10, 2026-10-15), so typing could not be the fix.

## Decision

1. **"A human is using this pane"** means: an attached client shows it AND its terminal has
   focus (`focused` in `#{client_flags}`) or saw a key within `WOLFMUX_WATCH_QUIET` (120 s)
   (`tm_pane_in_use`). It fails closed. This replaces "the lead's pane while any client is
   attached" and "a client shows it" in `inbox_human_pane`, for every role.
2. **The wake channel** is a Claude Code hook with `asyncRewake` (`teamctl _inbox-wake`), on the
   lead's Stop and SessionStart. It waits in the background while the lead is idle. When a notice
   is waiting and nobody is using the lead's pane, it prints the notices and exits 2; Claude Code
   gives them to the model and the lead takes a turn. Nothing is typed.
3. **Typing and the turn-end hook do not change for a Claude-family lead** while a client is
   attached: nothing is typed into its pane, and its Stop hook stays silent, in use or not. A
   Stop hook's text prints in full in the pane ("Stop hook feedback"); a wake prints one line,
   `wolfmux: team notice`.
4. **Sender words**: a held notice tells the sender whether the lead wakes itself, and
   `teamctl status` shows held notices under the lead.
5. **Policy `lead-wake unwatched|off`**, default `unwatched`, the owner's alone.

## Alternatives Considered

### Alternative a: "watching" = focus or a recent keystroke, and type the notice
- **Pros**: the measured `focused` flag tells the tab in front of the human from background tabs
  and from another app being in front (measured 2026-11-04 on the live socket).
- **Cons**: it would put `[wolfmux] Beads update ...` lines back into the owner's conversation.
- **Why not**: rejected by the owner on 2026-10-10 and 2026-10-15. Adopted as the GATE only
  (decision 1), not as the channel.

### Alternative b: a lead-side loop (a session cron every N minutes)
- **Pros**: no new mechanism.
- **Cons**: every tick is a full-context model request for every lead, idle or not: at 3 ticks an
  hour, 72 requests a day per lead at 100-400k tokens each. Latency up to N minutes, and each
  tick prints in the pane anyway.
- **Why not**: cost and latency. The communication lead keeps its own 20-minute sweep.

### Alternative c: a louder sender side only
- **Pros**: small.
- **Cons**: the banner already existed and was ignored 5 times.
- **Why not**: it does not reach the agent. Adopted as a supplement (decision 4).

### Alternative d: an asyncRewake waiter hook (chosen)
- **Pros**: no keystroke, so a half-typed line cannot be glued to anything (issue #9). Measured
  on Claude Code 2.1.318 (2026-11-04, throwaway socket): exit 2 wakes the idle model within
  about 2 s, even with a dialog open; the pane shows only the `rewakeSummary` line; a
  half-typed draft survives; `timeout: 604800` is accepted.
- **Cons**: a background process per idle lead; `rewakeSummary` is marked internal in the binary.

## Consequences

### Positive
- A lead in a background tab, or in iTerm2 while the owner is in another app, acts on its
  notices within about 15 s (`WOLFMUX_WAKE_POLL`).
- The tab in front of the owner behaves exactly as before.
- A sender learns at once whether the lead will wake ("held for X (idle since 10:46Z): it wakes
  itself within ~15s") or why not.

### Negative
- Each wake is one model turn. Once a week an idle lead also takes one short "nothing to do"
  turn: Claude Code kills a hook at its timeout without a wake, so the waiter ends itself
  300 s before `WOLFMUX_WAKE_TIMEOUT` and re-arms through that turn.
- Leads pick up the hook only at their next start or restart.

### Risks
- A hook that exits 2 with nothing to hand over wakes the agent, whose next Stop starts the hook
  again: a wake loop, measured in the spike. The waiter exits 2 only with notices, or once for
  the re-arm, and a test pins it.
- Every Stop starts its own copy (measured), so one waiter per role is a generation token in
  `inbox/.wake.<role>`; UserPromptSubmit replaces it, so a waiter never fires into a turn the
  human started. A prompt in the same second as the Stop that armed it can leave it armed; a
  wake then is queued by Claude Code, not lost.
- After `kill -9` of Claude the hook lives on under PID 1 (measured): the waiter ends itself
  when its parent pid is gone or it is re-parented to PID 1, and when its pane or team is gone.
- A terminal that never reports focus reads focused for ever (measured), so its lead never
  wakes itself: that fails closed, as before v1.23.0. `WOLFMUX_WATCH_FOCUS_MAX` caps how long
  focus alone counts.
- `rewakeSummary` may change in a later Claude Code; the line would then read the default
  "Stop hook feedback" summary, without the notice text.
