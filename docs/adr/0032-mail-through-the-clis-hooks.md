# ADR-0032: Mail reaches an agent through its CLI's hooks, with the body, in the middle of a turn

**Date**: 2026-11-13
**Status**: accepted
**Deciders**: the owner (the complaint), the memory-management team (lead's design and seam, workers' modules)

## Context

Since v1.0 a message or a task reached an agent as one fixed line typed into its pane
(ADR-0006, ADR-0015). Measured on 2026-11-13 with Claude Code 2.1.323 and bd 1.3.0:

- A CLI that is in the middle of a turn queues the typed line until the turn ends. A worker
  inside one long turn did not read "commit now" for two hours (2026-10-04).
- Reading the message then costs three or four model round trips (`bd show`, the inbox
  `bd list`, `bd close`), each with the whole conversation as input. `bd` itself takes 0.3 to
  0.7 s per call, and six concurrent writers took 3.7 s: embedded Dolt is single-writer.
- A line typed while a dialog is open is swallowed. The debounce drops a notice for the second
  message of a burst; the first notice's inbox command is what covers it.
- A new worker's kickoff says "check your inbox": its first turns go into finding its own task.

The CLI has a better channel. Verified against the real CLI, not a stub: the answer of a
SessionStart, UserPromptSubmit or PostToolUse hook may carry `additionalContext`, which the CLI
puts into the conversation, and a Stop hook that answers `{"decision":"block","reason":…}` makes
the agent go on with that text. Every provider that runs through Claude Code (GLM, Kimi, MiniMax,
Qwen, Moonshot, DeepSeek) has the same hooks.

## Decision

1. Beads stays the record of tasks and messages (ADR-0002). What changes is the delivery.
2. Every Claude Code agent's generated settings call `teamctl _hook <Event>` for SessionStart,
   UserPromptSubmit, PostToolUse, PreCompact and Stop. `lib/hooks.sh` owns that call: it reads
   the CLI's JSON, lets the feature modules add text (`<module>_hook`, `hook_context`), and
   answers in the shape the event expects. A hook never fails and never delays an agent.
3. The hot path is above the module loader in `bin/teamctl`: PostToolUse with nothing queued
   counts the call and ends, about 3 ms, no module, no fork. A queued `attention` file, or every
   tenth call, goes through the full hook (about 60 ms).
4. Each agent has a run directory, `$STATE_DIR/run/<role>/`: the call counter (its age is the
   agent's last sign of life), the turn state (`busy` from the prompt to the stop, else `idle`),
   and the modules' own folders. It is deleted with the agent.
5. The Beads hook hands the bead it already receives to `teamctl _deliver`, which writes it into
   the recipient's spool (`run/<role>/mail/new/`). The agent's next tool call, its next prompt or
   its stop shows it: heading, sender, body. A message is marked read for the agent. A new
   conversation is briefed from Beads itself at SessionStart: assignment and inbox are in the
   conversation before the first prompt.
6. Something is typed into a pane only to wake an agent that is idle: one fixed line, to which
   the UserPromptSubmit hook attaches the mail. A busy agent is not typed at. Because a busy
   state can be stale (an interrupted turn fires no Stop hook), a detached watchdog types the
   line after `WOLFMUX_MAIL_WAKE_AFTER` seconds (90) if the mail is still unread and the agent
   has been quiet that long. A line typed into a busy CLI is only queued, so a wrong guess costs
   one short turn and never a message.
   **Amended in v1.24.0** (the merge onto v1.23.0): this point is replaced. Nothing here types
   any more. An item files one notice through v1.23.0's inbox (ADR-0028), whose gates decide
   whether a line is typed (ADR-0029) and whose wake waiter wakes an idle lead (ADR-0031); the
   inbox hooks attach the spooled body, and the watchdog and `WOLFMUX_MAIL_WAKE_AFTER` are gone.
7. Short verbs for what the protocol asked for in three to five `bd` calls: `teamctl send`,
   `teamctl mail`, `teamctl task`, `teamctl done`, `teamctl blocked`. Plain `bd` keeps working.
8. A Stop hook looks once at Beads and tells an agent, once per task, that it is stopping with a
   task in progress or with an assigned task it never started.
9. Codex agents have no such hooks in this version: they keep the typed notice with its `bd`
   commands, and their kickoff names `teamctl mail`.

## Alternatives Considered

### Alternative 1: Beads server mode, to make every `bd` call faster
- **Pros**: no single-writer queue; a call no longer opens an embedded database.
- **Cons**: needs the `dolt` binary and a server process that `teamctl` would have to own;
  it shortens each `bd` call but keeps the three or four model round trips per message, which
  are the larger cost by an order of magnitude.
- **Why not**: the round trips are gone with hooks, and what is left of `bd` on the path runs
  detached. Server mode stays what ROADMAP.md says: opt-in, when lock waits show.

### Alternative 2: Claude Code's own agent teams (teammates, mailboxes, SendMessage)
- **Pros**: delivery between Claude Code sessions is built in.
- **Cons**: Claude Code only. A team here mixes Claude, GLM, Kimi and Codex CLIs, and a
  teammate's manager and permission approver is the session that named it (ADR-0013).
- **Why not**: it would replace the one-manager design and leave every other CLI out.

### Alternative 3: an MCP mail server (mcp_agent_mail and the like)
- **Pros**: tools for send and fetch, file reservations, a web view.
- **Cons**: a daemon and a network service (GOALS.md says neither); the agent still has to
  decide to call the fetch tool, so a busy agent reads its mail no earlier than it does today.
- **Why not**: a hook is the one channel that puts text in front of an agent that did not ask.

### Alternative 4: keep typing, but type the body
- **Why not**: ADR-0006 stands. Free text typed into a prompt has to be quoted, can be
  truncated, and lands as a queued prompt at the end of the turn anyway.

## Consequences

### Positive
- A message is in the recipient's conversation at its next tool call, at no extra model round trip.
- A new worker starts on its task in its first turn.
- Nothing is typed into a working agent, so nothing can be swallowed by a dialog.
- `teamctl` knows whether an agent is in a turn, and when its CLI last moved.

### Negative
- Five hooks per agent, one of them after every tool call. The measured cost is 3 ms in the
  usual case; it is a cost all the same, and a CLI change to hook semantics would be ours to follow.
- Mail text is put into a conversation without the agent asking. It is labelled as data from a
  named sender, capped, and may not imitate wolfmux's own lines; it is still text from another agent.
- Codex agents are second class until Codex's hooks are wired.

### Risks
- A hook that hangs would hold an agent for its timeout (20 s). Everything slow is detached, and
  every failure path ends in "say nothing".
- A Stop answer that repeats would keep an agent from ever stopping. Mail is consumed when shown,
  and the task reminder is once per task.
