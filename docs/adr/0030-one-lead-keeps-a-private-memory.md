# ADR-0030: One lead per project keeps a private memory, switched on by the owner alone

**Date**: 2026-10-23
**Status**: accepted
**Deciders**: the repository owner (who asked for it), `comms-memory.lead` (the plan), the v1.22.0 author

## Context

The communication-management lead is a long-lived conversation. Each restart, compaction or handover
loses how it was told to work, and the brief it is re-sent is a task, not a way of working. Claude Code
can load an auto memory from a folder (`autoMemoryDirectory`): measured on Claude Code 2.1.308, a session
started with the setting loaded a marker from a private `MEMORY.md`, and the control run did not. That
memory has to stay private to that one lead: what it holds is the human's working relationship with it,
and every agent of every team runs as the same macOS user, in the same project folder.

Two traps were found while planning. The comms lead's record has `kickoff 0` and no handover, so a fresh
restart gave it no first prompt and it sat idle. And `start --continue` / `restart --continue` with no
stored conversation id falls back to `claude --continue`, which opens the NEWEST conversation in the
folder all leads of a project share: the memory would be read into somebody else's conversation.

## Decision

A project-level policy `team-memory <team>|off`, default off, names ONE team. Only the owner turns it
on (`teamctl memory enable <team>`, `require_operator`; an agent gets exit 77); the owner or that team's
own lead may turn it off. Its lead, and nobody else, gets `~/.wolfmux/memory/<project-key>/<team>/`
(mode 700, copied once from `~/.config/wolfmux/memory-skeleton/`) as `autoMemoryDirectory`, a "Team
memory" block at the end of its system prompt (`--append-system-prompt`, no new hook), and a first prompt
at EVERY launch: `Team memory is on. Run <dir>/bin/mem boot, read what it prints, re-create the crons it
lists, then read your Beads inboxes.` Its `--continue` is refused while no conversation id is stored.
Workers are refused the folder by the worktree guard. Nothing deletes it except `destroy --purge
--memory` (the team's name typed at a terminal) and `uninstall.sh --purge --purge-memory`.

## The boot prompt: which CLI forms take a first prompt

The boot prompt rides as the CLI's positional prompt, the last argument, as the worker kickoff already
does. The forms the memory lead can be launched with:

- fresh: `claude --session-id <id> "<boot>"` — the same form as every worker's kickoff since v1.9;
- resumed: `claude --resume <id> "<boot>"` — documented in the CLI reference as
  `claude -r "<session>" "query"` ("Resume session by ID or name"), and the CLI's own usage line is
  `claude [options] [command] [prompt]` (Claude Code 2.1.309);
- a stored id with no transcript yet: `claude --session-id <id> "<boot>"` again;
- `claude --continue "<boot>"` is never used for this lead: that launch is refused (above). The CLI
  reference documents `-c` with a query only for print mode (`claude -c -p "query"`).

A live interactive measurement through a bare pty (Python `pty`, Claude Code 2.1.309, Haiku, a scratch
folder) did not reach a first turn within 90 seconds for either form, so it neither confirmed nor refuted
them; the print-mode part of the same probe answered. The positional form therefore rests on the CLI's
documentation and on the fresh form already in daily use. No `teamctl nudge` fallback was built. A
resumed Codex lead is given no first prompt (`codex resume --last "<text>"` could read the text as a
session id) and the pane says so.

## Alternatives Considered

### Alternative 1: a SessionStart hook that prints the card
- **Pros**: no first prompt needed; runs on `/clear` too.
- **Cons**: a new hook in that lead's settings, a second channel beside the prompt, and a hook's output
  is context, not an instruction to act on (`mem boot` also re-creates crons).
- **Why not**: the prompt block plus the boot prompt does the same with nothing new to run.

### Alternative 2: any lead may enable its own memory
- **Pros**: no owner step.
- **Cons**: which conversation may keep notes no team can see is a decision about the owner's own work;
  a lead that wants it has every reason to grant it to itself.
- **Why not**: owner-only enable, as for `orphan-steward` and `lead-model`. Disable only narrows what
  is kept, so the lead itself may do it, and the owner is told.

### Alternative 3: `teamctl nudge` typed into the pane after launch
- **Pros**: works whatever the CLI's argument parsing does.
- **Cons**: typed text in a pane the human may be watching is what ADR-0028 removed; it races the CLI's
  own start screen.
- **Why not**: the positional prompt is documented; the nudge stays the fallback if a CLI ever drops it.

## Consequences

### Positive
- A restarted comms lead wakes up, runs `mem boot`, and works from its card instead of idling.
- `--continue` can no longer mix two leads' conversations for the memory team.
- Nothing about other teams changes: no setting, no block, no prompt, no guard change for their files.

### Negative
- A change of the policy or of `core/card.md` reaches a running lead only at its next restart;
  `teamctl memory status` warns when the card is newer than the lead's start.
- One team per project.

### Risks
- The guard reads text. A relative path after a `cd`, or a path built at run time, is not seen
  (`tests/memory.sh` pins the `cd` case). Leads of other teams are not guarded at all, and a team with
  `worker-isolation off` has no guard. docs/SECURITY.md lists every layer and where it ends.
- `teamctl memory check` prints the skeleton's lint lines to anyone who runs it; the skeleton must keep
  those to structure and counts.
- The boot prompt with `--resume` is documented, not yet observed on a live pane: the first real
  restart of the memory lead is that observation.
