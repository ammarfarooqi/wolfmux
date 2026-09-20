# ADR-0015: Notifications lead back to the team — through the attached terminal, else through Wolfmux.app

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
attached terminal known to support OSC 9 (iTerm2, kitty, Ghostty, WezTerm).

**Amended the same day.** The first version fell back to `osascript` when nothing was
attached, on the theory that there was then "nowhere to go back to". The owner's next
notification was exactly that case — a team left to work in the background is the normal
case, not the rare one — and it opened Script Editor again. macOS opens whichever
application *owns* a notification, so Wolfmux now brings its own owner: `install.sh`
builds `~/.config/wolfmux/Wolfmux.app` (an AppleScript applet with the wolf as its icon).
`teamctl _notify` leaves the message in `~/.wolfmux/notify/pending` and launches the
application, which fetches it (`teamctl _notify-pending`, once, and only if it is fresh)
and posts it. Started with nothing to fetch, it has been clicked: `teamctl _open-team`
opens a terminal window attached to the team (iTerm2 or Terminal by AppleScript; other
terminals are brought forward). `osascript` remains only for a machine without the app.
The same file sets
`ECC_DISABLED_HOOKS`, merged with what the owner already disables, so the plugin's
notifier does not fire a second time. `WOLFMUX_NOTIFY=all|lead|off`.

## Alternatives Considered

### Alternative 1: tmux passthrough (`allow-passthrough on`, wrap OSC 9 in a DCS)
- **Pros**: the documented way to get a sequence through tmux
- **Cons**: lets any program in a pane send any escape sequence to the outer terminal; needs tmux 3.3; only works for a visible pane; the plugin would still not use it
- **Why not**: writing to the client's tty needs no tmux option and reaches exactly the terminals we chose

### Alternative 2: install `terminal-notifier` and run a command on click
- **Pros**: works for any terminal, attached or not
- **Cons**: a dependency unmaintained since 2017, with click actions that are unreliable on current macOS
- **Why not**: `osacompile` ships with macOS and gives the same thing: an application that owns the notification

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
- macOS asks twice, once each: to allow notifications from Wolfmux, and to let Wolfmux control the terminal. Until the first is allowed, a detached team's notifications do not show
- an application is built at install time; it is rebuilt only when its source changes, because macOS ties the "may control iTerm" permission to the exact build
- the lead now has a generated settings file too (before, only workers did). It holds the `Stop` hook and the `ECC_DISABLED_HOOKS` value, nothing about teams or permissions, so [ADR-0013](0013-one-manager-policy.md) stands
- Wolfmux knows the name of one third-party hook. Without the plugin the variable is inert
- Codex-based agents do not notify yet (Codex has a `notify` program setting; untested here, see ROADMAP)

### Risks
- model output inside an escape sequence: control characters are removed before the write, the text is cut to 100 characters, and `tests/smoke.sh` feeds it an OSC 52 and a clear-screen sequence and counts the escape bytes that come out
- a write that lands between two of tmux's own writes to the same tty: it is one short `printf`, the same technique the plugin uses outside tmux
- Claude Code renaming `last_assistant_message`: the text degrades to "finished", the notification still arrives
