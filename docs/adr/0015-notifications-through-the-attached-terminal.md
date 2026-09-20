# ADR-0015: Notifications go through the terminal attached to the team

**Date**: 2026-09-20
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

The owner clicked a "Claude Code — task complete" notification and landed in Script
Editor instead of the agent. The notification came from the ECC plugin's `Stop` hook.
Outside tmux that hook writes OSC 9 to the terminal, so iTerm2 owns the notification
and a click focuses the right tab. Inside tmux it deliberately falls back to
`osascript` (tmux swallows OSC 9), and macOS files every `osascript` notification under
Script Editor. Every Wolfmux agent runs inside tmux, so every notification was of the
broken kind. tmux knows which terminals are attached to a session and what they are
(`list-clients`: `client_tty`, `client_termtype`).

## Decision

Inside a team, notifications are `teamctl`'s job. Every Claude-based agent — the lead
included — gets a generated settings file with a `Stop` hook, `teamctl _notify`. It
writes `ESC ] 9 ; <role>: <first line of the last message> BEL` to the tty of each
attached terminal known to support OSC 9 (iTerm2, kitty, Ghostty, WezTerm). With none
attached it falls back to `osascript` and says `teamctl attach`. The same file sets
`ECC_DISABLED_HOOKS`, merged with what the owner already disables, so the plugin's
notifier does not fire a second time. `WOLFMUX_NOTIFY=all|lead|off`.

## Alternatives Considered

### Alternative 1: tmux passthrough (`allow-passthrough on`, wrap OSC 9 in a DCS)
- **Pros**: the documented way to get a sequence through tmux
- **Cons**: lets any program in a pane send any escape sequence to the outer terminal; needs tmux 3.3; only works for a visible pane; the plugin would still not use it
- **Why not**: writing to the client's tty needs no tmux option and reaches exactly the terminals we chose

### Alternative 2: install `terminal-notifier` and activate the terminal on click
- **Pros**: works for any terminal, attached or not
- **Cons**: a new dependency for a cosmetic path; activates the application, not the tab
- **Why not**: iTerm2 already does the precise thing for free

### Alternative 3: patch or reconfigure the plugin
- **Pros**: one notifier
- **Cons**: the plugin is the owner's and updates itself; its tmux fallback is reasonable for everyone who is not running a team
- **Why not**: not ours to change. Its documented switch is enough

### Alternative 4: leave it
- **Why not**: a notification that opens the wrong application trains you to ignore notifications

## Consequences

### Positive
- clicking a notification brings the tab with the team to the front; the text names the agent, and the lead carries the wolf
- one notification per finished turn instead of two
- no tmux option changed, nothing installed

### Negative
- the lead now has a generated settings file too (before, only workers did). It holds the `Stop` hook and the `ECC_DISABLED_HOOKS` value, nothing about teams or permissions, so [ADR-0013](0013-one-manager-policy.md) stands
- Wolfmux knows the name of one third-party hook. Without the plugin the variable is inert
- Codex-based agents do not notify yet (Codex has a `notify` program setting; untested here, see ROADMAP)

### Risks
- model output inside an escape sequence: control characters are removed before the write, the text is cut to 100 characters, and `tests/smoke.sh` feeds it an OSC 52 and a clear-screen sequence and counts the escape bytes that come out
- a write that lands between two of tmux's own writes to the same tty: it is one short `printf`, the same technique the plugin uses outside tmux
- Claude Code renaming `last_assistant_message`: the text degrades to "finished", the notification still arrives
