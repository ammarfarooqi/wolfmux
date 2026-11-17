# ADR-0040: A lead that stays small: the report is a file, the mail is short, a ledger comes back

**Date**: 2026-11-17
**Status**: accepted
**Deciders**: the memory-management lead, from the v1.25.0 research (proposal 5), task wolfmux-vaz

## Context

The lead's conversation is the one that cannot be thrown away, and it fills fastest. Measured in
the v1.25.0 research (`tests/research/results/v1.25-research.md`, 1.2 and 1.3): Bash output is 40%
of what the lead adds and its own tool inputs 20.7%; on a toy task 5 of the lead's 12 requests
were mail housekeeping. A worker's `teamctl done` report arrived whole, at the next tool call: the
summary, up to 30 commit lines and every character of `--body-file`, capped only at 6,000
characters of body. After a compaction the lead had lost the table of who does what, and asked the
store again, one command at a time.

## Decision

1. **A report is a file; the lead's mail is a short notice.** `teamctl done` builds the report as
   before (summary, tests line, branch, commits, diff stat, `--body-file`) and writes it to
   `<state>/reports/<task-id>.md`, beside the store, one place for both stores. A task done again
   after a reopen keeps its earlier reports as `<task-id>~1.md`, `<task-id>~2.md` (1 the oldest;
   `~` is in no task id, so a Beads child `X.1` is not X's first older report), numbered under a
   lock.
   The "Done:" message to the lead carries only the notice, at most 600 characters with the
   `[wolfmux mail] ` it is shown with: `DONE <id> by <who>: <title, 60>`, the summary (cut with
   a marker that names the report when it does not fit), the tests line, the branch at the short
   sha, the diff stat line, the report's path, `read it: teamctl show <id> --report`, and "This
   item is already marked read and needs no reply." `teamctl done` marks it read in the store at
   once, on both stores, so the sentence is true and a compacted lead is not handed it again.
   The 600 hold whatever the fields are: the summary keeps at least 120 characters; when the
   fixed lines leave less, the report path goes first (`--report` reaches it), then the tests
   line, diff stat and branch shrink, and a final cap holds the rest. Counting is in characters
   (UTF-8) under any locale. If the notice cannot be built or sent, the lead gets a one-line
   notice with the command; `done` never fails after the close without saying so. The short
   form is shown only for a message carrying the mark `teamctl done` sets
   (`WOLFMUX_DONE_NOTICE`, in the spooled item), never for text that merely looks like one.
   `teamctl show <id> --report` prints the file; `teamctl show <id>` names it (and the earlier
   ones). A lead without hooks (Codex) gets the one-line notice, which names the message id; the
   message names the command.
2. **No second notice.** The close of a task the lead has the report of was already not announced
   (v1.24.0, `WOLFMUX_MAIL_CLOSE_REPORTED`); a check now proves it on both stores. A second fault
   turned up while measuring: on Beads, `bd create --deps replies-to:` fires the update hook right
   after the create, with the message still open, so every reply message (every report) was
   queued twice and handed over again at the next tool call. `teamctl _deliver` now skips an
   update of a message that this recipient's spool already holds, waiting or shown; it waits up to
   2 s for the create's delivery, which runs detached at the same moment.
3. **A ledger.** `teamctl ledger` prints, from the store, at most 4,000 characters: one line per
   open, in-progress or blocked task of the team (id, state, assignee, title cut at 60), one line
   per task closed since the lead's conversation began or in the last 24 hours, whichever reaches
   further back (id, assignee, report path), and the decisions, newest last. Each section has a
   share of the 4,000; what does not fit becomes one `(N more: <command>)` line, and for the
   decisions the oldest give way. `teamctl decide "<text>"` (the lead, through the pane proof; at
   most 300 characters, refused when empty) appends a dated line to `$STATE_DIR/decisions`, a file
   on both stores, under a lock; at most 30 are kept, the oldest leave first. `--list` and
   `--drop <n>`; a text that starts with `-` is a text (alone, or after `--`). Decisions and done
   rows take their room first; open work is the section that says how many more.
4. **The lead's SessionStart.** `ledger_session_start` (lib/ledger.sh), a hook module of its own
   (`WOLFMUX_HOOK_MODULES`), returns at once for anyone but the lead. On `startup` and `clear` it
   writes when the conversation began; on `compact` and `resume` it attaches the ledger, unless it
   is empty. One store read, on Beads inside the hook run's one 5 s budget. A subagent's hook input
   (`agent_id`) attaches nothing: cmd_hook already says nothing for one (v1.24.1).
5. **Protocol.** Three lines in the lead's review step: read a report only when the notice is not
   enough; review a diff through a subagent that returns a verdict and the lines that matter, never
   `cat` a whole diff into the lead's own conversation; `teamctl decide` for what must outlive a
   compaction.

## Numbers

Characters that reach the lead through its hooks for one `teamctl done` with a 6,000-character
`--body-file` (stub agents, measured from the lead's next PostToolUse):

| Store | v1.25.0 | v1.26.0 |
|---|---|---|
| native | 6,168 | 377 |
| Beads | 6,184, and the same block again at the next tool call (12,368) | 386 |

With a 20,000-character `--body-file`: v1.25.0 cut it at 6,000 with "teamctl show <id> has the
rest"; now 599 at most, and the file holds every character. The ledger with 200 open tasks, a done
task and 30 decisions of up to 300 characters: 3,928 (native) and 3,942 (Beads) characters.

## Alternatives Considered

### Keep the report in the message, show only its head
- **Pros**: no new file, one store.
- **Cons**: the body is still the store's copy; `teamctl mail` and `show` would print it whole
  into the lead's conversation, and the cut would need a second path to read the rest.
- **Why not**: the file is what the lead can choose to read, with any tool, or not at all.

### Decisions as tasks or messages in the store
- **Pros**: one store for everything.
- **Cons**: on Beads every write fires the hooks and costs a `bd` start; a decision is not work and
  would show in `teamctl tasks` and the inbox.
- **Why not**: a small file per team is enough and identical on both stores.

### The ledger at every SessionStart
- **Why not**: a fresh conversation gets its brief from the human and its inbox; the ledger is
  for the one that lost its table to a summary.

## Consequences

### Positive
- One done costs the lead about 400 characters instead of 6,000 or more, and no reply.
- After a compaction the lead has its table back without a command.

### Negative
- The report is a file outside the store: `teamctl store --migrate` does not carry it (it stays
  where it is, beside both), and deleting the project's state deletes it.
- A lead that wants the detail spends one tool call on `teamctl show <id> --report`.

### Not covered
- On Beads, the second hook event of a reply message is dropped by looking at the recipient's
  spool. A Codex lead, or a lead whose pane is not running, has no spool, and may still get the
  one-line notice twice for one report.
- How much the lead reads diffs itself: the protocol says what to do, nothing enforces it.
- Mail other than a Done report (a worker's long `teamctl send --body-file`) still arrives whole,
  capped at 6,000 characters as before.
- A Codex lead gets no SessionStart: it reads the ledger with `teamctl ledger` when it wants it.
- "Since the lead's conversation began" is the time its last `startup` or `clear` SessionStart
  ran; a lead started before v1.26.0 has none, and the ledger then counts the last 24 hours.
- Not measured on the real CLI: the numbers above are from stub agents and the hooks' own output.
