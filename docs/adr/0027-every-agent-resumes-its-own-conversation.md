# ADR-0027: Every agent resumes its own conversation, by id

**Date**: 2026-10-04
**Status**: accepted
**Deciders**: the owner (issue #7, PR #8), the lead of team adding-providers

## Context

`teamctl start … --continue` and `teamctl restart <role> --continue` ran `claude --continue`, which
opens the newest transcript **of the working folder**. Every lead of a project works in the project
folder, and so do the owner's own sessions. On 2026-09-24 four leads of one project were restarted
with `--continue` and all four came back in the same conversation. teamctl stored no conversation id,
so it had nothing better to ask for.

Measured with Claude Code 2.1.289 (no model call is made on a refusal):

| Asked of the CLI | Answer |
|------------------|--------|
| `--session-id <uuid>` for a new conversation | accepted; a malformed id: `Invalid session ID. Must be a valid UUID.` |
| `--session-id <id>` when a transcript of that id exists | `Session ID <id> is already in use.`, exit |
| `--resume <id>` when no transcript of that id exists | `No conversation found with session ID: <id>`, exit |
| `--resume <id>` from another folder than the one the transcript is in | the conversation is found and continued |

## Decision

Every Claude-family agent is started with a conversation id that teamctl mints (`--session-id <uuid>`)
and stores in its record (`session_id`). `--continue` reopens exactly that id (`--resume <id>`).
`--resume <session-id>` on `start`, `restart` and `spawn` pins one by hand. The lead's id is also kept in
the team's `meta.json`, because a plain `teamctl destroy` deletes the lead's record.

Because the CLI refuses both an unknown id on resume and a used id on a new start, teamctl decides from
the transcript on disk which of the two to pass:

| Situation | Passed to the CLI |
|-----------|-------------------|
| `--continue`, stored id, transcript exists | `--resume <id>` |
| `--continue`, stored id, no transcript (the agent never said a word) | `--session-id <id>`, and the kickoff if it had one |
| `--continue`, no id on record (an older record, a first `start --continue`, a purged team) | `--continue`, with one warning line |
| a fresh start or a plain restart | `--session-id <new id>` |
| the pane is run again by hand and the stored id already has a transcript | a new id is minted and stored |
| `--resume <id>` and no transcript of that id in any folder | refused (exit 1) before anything is restarted |
| `--resume` for a Codex agent | refused (exit 64) |

`teamctl status` reads CONTEXT from the same transcript, by id.

## Alternatives Considered

### Alternative 1: touch the wanted transcript just before the start
- **Pros**: no change to teamctl's records.
- **Cons**: it was tried on the day of the incident and lost the race against the copies still running.
- **Why not**: it keeps guessing by modification time, which is the fault.

### Alternative 2: resume a freshly minted id when none is on record
- **Pros**: one code path.
- **Cons**: the CLI answers `No conversation found` and the pane dies. This is what the first version of
  the change did for `teamctl destroy` followed by `teamctl start <model> --continue`.
- **Why not**: it turns the most ordinary way of coming back the next day into a dead lead.

### Alternative 3: ids for Codex agents too
- **Pros**: the same guarantee for an Astra lead.
- **Cons**: Codex takes no id for a new conversation, so teamctl could only learn one afterwards, from
  rollout files matched by working folder, which is the same ambiguity.
- **Why not**: not solvable from teamctl's side today; documented instead.

## Consequences

### Positive
- Several leads in one folder, and a lead next to the owner's own sessions, each come back in their own
  conversation, and each status line shows its own context.

### Negative
- An agent started before 1.12 has no id until its next plain restart or a `--resume`.
- A Codex lead in a shared folder is as ambiguous as before.

### Risks
- The transcript location is Claude Code's own layout (`~/.claude/projects/<folder>/<id>.jsonl`). If it
  moves, teamctl finds no transcript and starts a conversation fresh under its stored id, which the CLI
  would refuse as in use. `tests/stub-agent` refuses what the CLI refuses, so the suite sees the logic,
  not the layout: the layout is checked by hand against a new CLI version (`docs/VERIFICATION.md`).
