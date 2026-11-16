# ADR-0035: A store of our own: native SQLite by default, Beads kept as the second

**Date**: 2026-11-13
**Status**: accepted
**Deciders**: the owner (the complaint), the memory-management team

## Context

ADR-0032's hooks made the three or four model round trips per message go away, but every
read or write still goes through `bd` (embedded Dolt), and that cost is now the larger one
left. Measured on 2026-11-13 with `bd` 1.3.0 and `/usr/bin/sqlite3` 3.51, WAL mode:

| | bd 1.3.0 (embedded Dolt) | sqlite3 3.51, WAL |
|---|---|---|
| create a message | 510 ms | 7 ms |
| read an inbox | 450 to 740 ms | 4 ms |
| atomic claim | 390 ms | 10 ms |
| concurrent writers | 6 creates: 3,700 ms | 12 inserts: 38 ms, no error |
| first use | `bd init`: 4.2 s | creating the file |

Embedded Dolt is single-writer: six concurrent `bd create` calls (a lead and five workers
starting at once) took 3.7 s between them, each one waiting its turn. Beads' own issue #6039
shows embedded Dolt stalling a hook past 30 s under load; `_bd_bounded` (ADR-0032) already has
to assume a Beads read may never return and cuts it off at 5 s, which is a workaround, not a
fix. None of this is Beads' fault - it is a full issue tracker with history, dependencies and
sync, built for a human running one command at a time, not for a hook on every tool call.

Precedent, found while surveying this: Overstory, a different multi-agent harness, keeps mail
in a SQLite WAL database "independent of beads (which is too slow for high-frequency
polling)" and delivers it through a UserPromptSubmit hook - the same shape ADR-0032 already
builds, for the same reason.

## Decision

Tasks, messages and memory move behind one interface (`lib/store.sh`, `store_*`) with two
backends: a native `sqlite3` file per project (`$PROJECT_STATE/store.db`, WAL mode), the
default for a project with no state yet, and Beads, kept for a team already on it and
available to switch to (`teamctl store beads`). Every module above the interface (mail, tasks,
memory) calls `store_*` only; neither it nor the protocol an agent reads ever names `bd`.
This supersedes the "Beads only" part of ADR-0002 and ADR-0003 for a new project: Beads is no
longer required to be installed, and `teamctl doctor` stops treating its absence as a problem
when nothing here needs it.

## Alternatives Considered

### Alternative 1: stay on embedded Beads, make it faster
- **Pros**: no second backend to keep correct; one less thing to explain to a new user.
- **Cons**: 0.3 to 0.7 s a call either way, a single writer, and issue #6039 stalling a hook
  past 30 s are Dolt's own shape, not a configuration fixable from outside it.
- **Why not**: the measurements above are the floor of what embedded Beads can do; the target
  is milliseconds, not hundreds of them.

### Alternative 2: Beads server mode
- **Pros**: no single-writer queue; a call no longer opens an embedded database each time.
- **Cons**: needs the `dolt` binary and a `sql-server` process running continuously - a
  daemon, which GOALS.md rules out.
- **Why not**: ADR-0032 already declined this for the same reason; it stays what ROADMAP.md
  says, opt-in, if lock waits ever show on the Beads path that remains.

### Alternative 3: another tracker CLI (e.g. `beads_rust`)
- **Pros**: a faster single-binary tracker, no embedded Dolt.
- **Cons**: no messages (tasks only, so mail would still need something else), a non-stock
  SQLite engine of its own, and a 26 MiB dependency for what a project already has a tracker
  for.
- **Why not**: it solves half the problem and adds a second large dependency to do it.

### Alternative 4: plain files, Maildir-style
- **Pros**: no database at all, trivially inspectable.
- **Cons**: an atomic claim, a dependency graph and an unread count all need locking wolfmux
  would have to write and trust by hand; macOS ships no `flock(1)`, so even the simplest lock
  is a program, not a shell one-liner.
- **Why not**: sqlite3 already is that locking, tested for decades, and it is one `BEGIN
  IMMEDIATE` away rather than a hand-rolled file protocol.

### Alternative 5: hybrid - messages native, tasks on Beads
- **Pros**: messages (the hot, frequent path) get fast; tasks keep Beads' dependency graph
  without reimplementing it.
- **Cons**: two stores to keep consistent, two things to explain, and the slow path (task
  claims, the one place a race matters most) is exactly the one left on Beads.
- **Why not**: one interface over one store per project is simpler to reason about than a
  split that keeps the slowest operation on the slower backend.

## Consequences

### Positive
- A task or message round trip drops from hundreds of milliseconds to single-digit ones; a
  burst of concurrent writers (a lead and several workers starting together) no longer queues.
- A new project needs no `bd init`, no Beads workspace, no `bd` on PATH at all.
- A team already on Beads is unaffected: `store_kind`'s own rule keeps it there, and nothing
  in the protocol or an agent's commands differs between backends.

### Negative
- A second backend exists, and the native schema does not have everything Beads does (no
  dependency type beyond a task's own blockers; a message can reply to another message, not
  to a task, so a report that is "about" a task carries that only in its text, not a thread
  link - found and worked around in `store_native_msg_create` while wiring this up).
- `_bd_bounded`'s 5 s cut-off is still needed for the Beads half; it does not get faster.

### Risks
- A project migrated from Beads (`teamctl store native --migrate`) keeps its Beads workspace
  untouched (nothing is deleted there) but now has two records of its history; the migration
  is idempotent, not reversible by itself.
- The native schema is new and has had far less real use than Beads; a shape it cannot yet
  express will surface as a gap in `store.sh`'s interface, to close the same way this one was.
