# Architecture

## Two tools, two planes

| Plane | Tool | Owns | Never touches |
|-------|------|------|---------------|
| Control | `teamctl` | tmux panes, which model runs where, git worktrees and branches, start / stop / restart / destroy, diagnostics | — |
| Data | `teamctl`'s store interface (`lib/store.sh`, `store_*`) | tasks, dependencies, messages, shared team notes, history, who-did-what | tmux, worktrees |

The glue between them is a three-line Beads event hook that calls
`teamctl nudge <role>`, and one question going the other way. Beads does not know tmux
exists; `teamctl` never writes a bead, and it reads Beads in exactly one place: before a
finished lane is taken off the books, `lib/reclaim.sh` asks which tasks are closed
(`bd list`, once per run, read-only). Until v1.17.0 it read nothing at all; the question is
the price of not deleting a lane whose task is still open.
Tasks, messages and memory sit behind one interface with two backends: a native
`sqlite3` file per project (the default for one with nothing on disk yet) or Beads
(`bd`), kept for a project already on it (`teamctl store`, [ADR-0035](adr/0035-a-store-of-our-own.md)).
Every module above the interface (`mail.sh`, `tasks.sh`, `memory.sh`) calls `store_*`
only, so neither they nor an agent's commands differ by backend. On the native
backend, a write that should notify someone calls `mail_announce` itself; on the
Beads backend a three-line event hook calls `teamctl _deliver` instead. Delivery
itself is one more seam below both: a Claude Code agent's CLI hooks carry the body
straight into its conversation ([ADR-0032](adr/0032-mail-through-the-clis-hooks.md));
a role with no running pane, or a Codex-family agent (no such hooks), still gets the
one-line notice v1.23.0 gave it, typed only where the typing gates allow.

![Two tools, two planes: teamctl, the tmux server with lead and workers, Beads, and the hook between them](diagrams/architecture.svg)

## Components

### Launchers (`~/bin`)

Each launcher cleans **its own process environment** and then `exec`s the real CLI.
The user's shell is never modified. The list of variables to remove lives in one
file, `lib/provider-env.sh`, shared with `teamctl doctor` so scrubbing and
diagnostics can never drift apart.

| Launcher | CLI | Billing | What it pins |
|----------|-----|---------|--------------|
| `claude-fable` | Claude Code | Claude subscription (`/login`) | `--model <id>`: the id teamctl resolved and recorded for the agent (`lib/models.sh`); run by hand, a pin, or Claude Code's own alias `fable` (its newest Fable). No key, no endpoint |
| `claude-opus` · `claude-sonnet` · `claude-haiku` | symlinks to `claude-fable` | same | the family named by the link, resolved the same way (`claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5` on 2026-10-13) |
| `codex-astra` | Codex CLI | ChatGPT / Codex subscription | `forced_login_method="chatgpt"`, `model_provider="openai"`, `model="gpt-6.2-astra"`. Starts Codex by its **real path**: Codex looks for its helper programs next to the path it was started as |
| `claude-glm` | Claude Code | the provider named by the link: a plan (Z.ai, Kimi, MiniMax, Qwen) or a metered API (Moonshot platform, DeepSeek: refused until `WOLFMUX_METERED=on`) | endpoint, key, model ids and context window from one table (`lib/providers.sh`); every model alias → that provider's main id, background tier → its fast id; a declared window so Claude Code prints no unknown-model notice |
| `claude-glm-flash`, `claude-kimi`, `claude-moonshot`, `claude-deepseek`, `claude-minimax`, `claude-qwen` | symlinks to `claude-glm` | same | the link name picks the provider; `-flash` picks GLM's fast tier |

Scrubbed in every Claude launcher: all `ANTHROPIC_*` and `CLAUDE_CODE_USE_*`
variables (explicit list plus a prefix sweep for future ones), model and subagent
overrides, and the session variables Claude Code sets in its own subprocesses
(`CLAUDECODE`, `CLAUDE_CODE_CHILD_SESSION`, …) — otherwise a CLI started from an
agent's shell believes it is a child session and stops persisting transcripts.
Scrubbed in `codex-astra`: all `OPENAI_*`, `CODEX_API_KEY`, `CODEX_ACCESS_TOKEN`.

`WOLFMUX_DRY_RUN=1 <launcher>` prints exactly what would be executed, without
secrets and without starting anything.

Persistent launcher settings come from `~/.config/wolfmux/config` (parsed as
`KEY=value`, never sourced). A file is needed because a pane's environment comes
from the tmux server, not from the shell that ran `teamctl spawn`.

### teamctl (`~/bin/teamctl` + `~/.config/wolfmux/lib/`)

About 8,600 lines of bash in small modules, written for macOS `/bin/bash` 3.2
under `set -euo pipefail`, depending only on `tmux`, `git`, `jq` and, for the native
store, `sqlite3` 3.38+ (Beads stays optional: needed only to keep a project on that
backend, or to switch to it with `teamctl store beads`).

| Module | Responsibility |
|--------|----------------|
| `provider-env.sh` | the scrub lists, binary resolution, the login guard (every provider), config parsing |
| `providers.sh` | the provider table: vendor, label, endpoint, Keychain service, billing, default model ids, context window, auth variable, key URL per provider |
| `common.sh` | output, validation, tool lookup, **the model table**, project resolution |
| `registry.sh` | the only module that touches state files; project lock; nudge debounce and deferred notices |
| `tmuxctl.sh` | every tmux call, including "is a human typing in this pane" |
| `worktree.sh` | worktree and branch creation, `worktrees`, `diff` |
| `disk.sh` | the build-output allowlist and its safety rules, `prune`, free-disk reading, the spawn guard, shared `node_modules` |
| `reclaim.sh` | taking a finished lane off the books by itself: the eight gates (parked, not kept, nothing uncommitted, HEAD on its branch, content in main, no stash on its branch, task closed in Beads, no open PR), the removal, `reclaim`, what a kept lane is holding, and the ledger line every removed lane gets. The one module that asks Beads and GitHub a question, each with a time limit |
| `beads.sh` | Beads bootstrap (stealth init) and hook installation |
| `policy.sh` | who is calling (`caller_role`), manager-only commands, the policy keys |
| `beads.sh` | Beads bootstrap (stealth init) and hook installation, for a project on that backend |
| `policy.sh` | who is calling (`caller_role`), manager-only commands, the policy keys (`POLICY_KEYS`) |
| `approvals.sh` | the lead decides workers' permission requests (`_permission-hook`, `approvals`, `approve`, `deny`) |
| `agents.sh` | `start`, `spawn`, the pane process (`_run-agent`), `stop`, `restart`, `destroy`, `nudge` |
| `views.sh` | `status`, `panes`, `capture`, `log`, `focus`, `attach` |
| `doctor.sh` | `teamctl doctor` |
| `models.sh` | what `fable`, `opus`, `sonnet`, `haiku` mean today (`WOLFMUX_MODEL_POLICY`): pins, the daily probe of Claude Code and its cache, labels derived from ids, the drift check, `teamctl models`, `_model-badge`. Also the one answer to "which model does this agent run" (`models_running`, fed by one pass over the transcript's tail, `models_transcript_tail`): `status`, `teams`, the dashboard, `models` and `doctor` all call it, so no two views can name different models for one agent. Sourced by `common.sh` and by `claude-fable` |
| `completion.sh` | `teamctl _complete`, the one backend behind the zsh and bash tab-completion shims |
| `hooks.sh` | `teamctl _hook <Event>`: reads the CLI's hook JSON, lets `mail_hook` / `tasks_hook` / `memory_hook` add text, answers in the shape the event expects. Never fails, never delays an agent |
| `store.sh` | `store_*`: one interface over the two task/message/memory backends, plus `teamctl store` |
| `mail.sh` | `send`, `inbox`, delivery (`mail_announce`, `_deliver`, the hook drain) |
| `tasks.sh` | `task`, `claim`, `done`, `blocked`, `tasks`, `show`, `note`, `reopen`, `close`, and the Stop-hook reminder for work left open |
| `memory.sh` | shared team notes and checkpoints at `SessionStart`, the context watch at `PostToolUse`, `PreCompact`'s own note, `checkpoint`, `remember`, `memories`, `forget` |

The **model table** in `common.sh` is the single place that knows which launcher
serves which model key (`fable`, `astra`, `glm53`, `flash`) and which CLI family it
belongs to. Nothing else in the code is model-specific, which is what makes the
two leads interchangeable.

Four of its keys also declare their own context window (`MODEL_CONTEXT`), the number
`teamctl status`'s CONTEXT column shows a share of: `fable`, `opus` and `sonnet` are
1,000,000 tokens, `haiku` 200,000 — Anthropic's model table, confirmed against this
machine's own transcripts (the largest prompt each model has actually accepted; see
`docs/BUILD-LOG.md` entry 28). A model id `model_context_window` cannot place — a
pinned `claude:<id>` or `codex:<id>` without the `[1m]` marker, `astra`, anything
unrecognised — has no declared window at all: the function returns nothing rather
than a guess, and the CONTEXT column falls back to the token count alone, with no
percentage.

Beside it, the **provider table** in `lib/providers.sh` is the single place that knows a
provider: vendor, endpoint, Keychain service, billing (`plan` or `metered`), default model
ids, context window, auth variable, key URL. The model table, `teamctl`, `doctor`, the
dry run and this documentation read it instead of carrying their own copies, which is
what keeps a vendor change a one-row fix.

### tmux

Teams run on a **dedicated tmux server** (`tmux -L wolfmux`) started with its own
config file (`~/.config/wolfmux/tmux.conf`). The user's default tmux server and any
`~/.tmux.conf` are untouched; the team config sources the user's config first if one
exists. It adds mouse support, 100k lines of scrollback, role titles on pane
borders, `remain-on-exit` (a crashed agent keeps its pane and its error), and
current-directory inheritance for new panes. One extra key: `prefix T` re-tiles.

- The server is started with a scrubbed environment, so panes never inherit
  provider or agent-session variables from whoever started it.
- A pane runs the agent **directly** (`tmux split-window … teamctl _run-agent <root>
  <role>`, passed as separate arguments, so there is no `sh -c` and no quoting
  layer). `_run-agent` exports the role, changes into the worktree, builds the
  protocol prompt and `exec`s the launcher, so the pane's process *is* the agent.
- Panes are found by a pane option, `@ai_role`, not by index or title. tmux is the
  source of truth for "is this agent alive" (`pane_dead`, `pane_dead_status`).
- New panes are split off the last pane, then the window is re-tiled, which keeps
  spawn order: lead top-left, then workers left-to-right, top-to-bottom.

### Git worktrees

`teamctl spawn <role> <model>` creates a branch named by the team's branch template
(by default `ai/<role>-<timestamp>`, `ai/<team>/<role>-<timestamp>`; `teamctl policy
branch-template`, `--branch`, `--ticket`) from the
lead's current `HEAD` (or `--base <ref>`) in a worktree at
`~/.wolfmux/worktrees/<project>-<hash>/<role>-<timestamp>/` — outside the
repository, so nothing is nested in the project. Git itself refuses to check one
branch out twice, and `teamctl` refuses a duplicate role, so two agents can never
share a working tree. Claude Code keys folder trust on the main checkout, so
trusting the project once covers every worker worktree.

**What a worktree grows, and who takes it back.** `.git` is shared, so a worktree starts
as a copy of the tracked files, but whatever the agent installs and builds inside it is
its own: on one project here 2.3 GB of `node_modules`, 0.9 GB of `.next` and half a
gigabyte of copied assets per lane. Nothing used to remove it, 27 parked lanes of one
project reached 65 GB, and the machine filled its disk. The copy of the tracked files is
the bigger half, and `lib/reclaim.sh` gives that back by removing a whole lane once it is
finished — its own rules are in that file's header, and the short of them is that a lane
goes only when every gate says yes and a gate that cannot be answered says no. Of what the
agent installed and built, `lib/disk.sh` is the one module that deletes any: one allowlist of regenerable directory names, and four rules —
only a name on the list, never a path git tracks, never a worktree holding uncommitted or
untracked work of its own, and only inside the worktree directory of that lane's own
repository (`worker_trees_dir`, so a lane spawned with `--repo` is checked against that
repository and not this project) with every path resolved by `pwd -P`. `stop` takes the
build caches, `remove` and
`destroy --worktrees` take everything, `prune` sweeps the parked lanes, `spawn` refuses
under `disk-min-gb`, and each directory is renamed inside its worktree before deletion so
an interrupted cleanup leaves recognizable trash rather than a half-deleted
`node_modules`. `teamctl status` never measures (a `du` over 36 lanes here costs 12.4 s):
the commands that change the lanes leave the number in `~/.wolfmux/state/<project>/disk-kb`
and status reads it.

### Beads
### The store (`lib/store.sh`)

`store_kind` picks the backend: the file `$PROJECT_STATE/store` wins if one exists;
else `WOLFMUX_STORE`; else `beads` for a project that already has agent state and no
`store` file (a registry record, or `meta.json`: it was started before v1.24.0); else `native`. A public `store_*`
function validates what both backends share the same way, then dispatches to
`store_native_<name>` or `store_beads_<name>`.

**Native.** `$PROJECT_STATE/store.db`, `sqlite3` in WAL mode, created on first use:
`task` and `msg` (one table each, a task's id printed as `t<n>`, a message's as
`m<n>`), `task_dep`, `memory` (key, text, author), `event` (an append-only log) and
`migrated` (old Beads id → new native id, for `--migrate`). A call's parameters
travel as one JSON document, hex-encoded and fed to `sqlite3` on stdin rather than
interpolated into the SQL text, bound in a `WITH` clause for a single statement
(`_sq`) or a temp table for several under one `BEGIN IMMEDIATE … COMMIT` (`_sqx`); the
SQL text itself is always a constant. WAL mode is what lets several agents write at
once without the embedded-Dolt single-writer queue ([ADR-0035](adr/0035-a-store-of-our-own.md),
with the measurements that motivated it).

**Beads**, kept for a project already on it. Initialized per project in **stealth,
embedded** mode: `bd init --stealth --skip-hooks --skip-agents --non-interactive
--prefix <name>`. That makes no commit, adds no tracked file (it uses
`.git/info/exclude`), installs no git hooks and edits no AGENTS.md. Embedded means
Dolt runs inside each `bd` process; there is no server. Linked worktrees find the
main checkout's `.beads/` through git's common directory, so every agent shares one
database with no configuration. `store_beads_*` shells out to `bd`, bounded to 5
seconds inside a hook (`_bd_bounded`, lib/store.sh): a hook may never hang an agent
on a slow write queue (Beads issue #6039); the native backend is fast enough that
nothing bounds it.

Conventions on the Beads backend (the full set is in `TEAM_PROTOCOL.md`; an agent
never runs these directly — `teamctl send` / `task` / … call them underneath):

| Need | Beads primitive |
|------|-----------------|
| task | `bd create "Title" -t task -a <role>`; claim with `bd update <id> --claim` (atomic) |
| dependency | `bd dep add <task> <blocker>` |
| message | a bead of type `message`; assignee = recipient, open = unread, `bd close <id> -r read` = read |
| thread | `--deps replies-to:<id>`, shown with `bd show <id> --thread` |
| inbox | `bd list --assignee <role> --status open,in_progress,blocked --include-infra` (without `--include-infra`, message beads are hidden) |
| identity | `BEADS_ACTOR=<role>`, exported into every pane |

## Flows

### Spawning a worker

1. validate role and model key (a metered model is refused while `WOLFMUX_METERED` is off); take the project lock (`mkdir`, released on exit)
2. `git worktree add -b <branch from the template> <path> <base>`, in the project or,
   with `--repo <path>`, in that repository (its own worktrees directory and its own base)
3. write the registry record (role, model, launcher, worktree, branch, base)
4. split a pane that runs `teamctl _run-agent <root> <role>`; tag it with `@ai_role`
5. re-tile; record the pane id. If the pane cannot be created, the fresh worktree,
   branch and record are rolled back.

### A message from lead to worker

![Sequence: a task goes out through the store, the worker's hooks hand it over, the result comes back the same way](diagrams/message-flow.svg)

1. lead: `teamctl send backend "Subject" "…"` — durable in the store, native or Beads
2. on the native backend the write calls `mail_announce` itself; on Beads, Beads
   fires `.beads/hooks/on_create` with the bead as JSON on stdin and the hook calls
   `teamctl _deliver backend --event create` in the background. Either way the next
   step is `_mail_deliver_to`, the one path to a recipient.
3. for a Claude-family agent whose pane runs, the item is spooled to
   `$STATE_DIR/run/backend/mail/new/` and flagged for attention. Then, for every agent,
   exactly one notice through `_nudge_one` (v1.24.0, ADR-0032): one line in the inbox file
   (`lib/inbox.sh`: the badge, the popup, the desktop notification, the lead's wake waiter)
   and, only where v1.23.0's typing gates allow, the typed line. A Codex-family agent gets
   just that, as in v1.23.0
4. whichever channel comes first hands the item over with its body: the next `PostToolUse`
   (mid-turn) drains the spool and marks the inbox line delivered; the `Stop` hook, the
   `UserPromptSubmit` hook or the lead's wake waiter hand the notice over with the spooled
   body attached and move it to `mail/seen`. Nothing is shown twice
5. the worker reads the body in its own conversation and acts on it directly — no
   round trip through `teamctl show` or `teamctl mail` just to see what arrived

The message body never travels through tmux on the hook path, so there is nothing
to quote, escape or truncate. The same path tells the lead when a worker closes a
task or marks one blocked (`mail_announce` / the Beads hook, by the same rule:
the assignee when someone else changed its task, the lead when a worker blocks or
closes one, never the actor itself). Comments fire no hook, on either backend.

### Never into a half-typed line

A pane is a keyboard somebody may be using. Typing a notice into it mid-sentence
submitted the human's unfinished text and the notice together as one message, which
is what GitHub issue #9 reported.

**Why type at all, rather than use the status line or a popup?** Because the notice is
for the AGENT in that pane, not for the human. The agent reads it as input and runs the
inbox command it names. `display-message` and `display-popup` put text in front of a
human only, so an agent would never see it, and the lead's pane — the one a human sits
at, which is exactly where issue #9 happens — would stop being notified at all. Typing
is the only channel that reaches the agent, so detect-and-defer is the shape the channel
forces. Do not "simplify" it into a popup.

Before anything is typed, `tm_pane_human_busy` asks three cheap questions, and any yes
means busy:

| Check | How | Needs a client attached? |
|-------|-----|--------------------------|
| the pane is in copy mode or scrollback | `#{pane_in_mode}` is 1, so keys would drive the mode, not the prompt | no |
| somebody is at this pane and pressed a key moments ago | it is the active pane of the active window of an attached session, and that client's `#{client_activity}` is less than the caller's window old — `WOLFMUX_NUDGE_HUMAN_IDLE` (5 s) for a worker, `WOLFMUX_NUDGE_LEAD_IDLE` (300 s) for the lead's own pane, which is the human's conversation. tmux moves `client_activity` on real keystrokes only: not on pane output, not on `send-keys` from outside, and a detached session lists no client at all | yes, by construction |
| the input line already holds something | the row at `#{cursor_y}`, captured with `-e`, with escape sequences and DIM runs removed, then box glyphs, non-breaking spaces, whitespace and ONE leading prompt marker removed, is not empty | no |

**Only the keystroke check needs a client**, and it needs one by construction: the sole
evidence that a key was pressed is an attached client's `#{client_activity}`. The
input-line check runs whether or not anybody is attached.

It used to need a client too, on the reasoning that with nobody attached nobody can be
typing. That is false, and it reopened issue #9: type a line, do not submit it, then
detach — or just walk away from `teamctl attach --team X` — and the notice was typed over
the half-typed line and submitted with it. Review round 2 reproduced exactly the reported
symptom on a detached session.

What separates a TUI's own furniture from somebody's typing is **dim**, not the client
list. Measured 2026-10-09 against a real Claude Code in a throwaway tmux socket, nothing
submitted:

| the input box | the row as `capture-pane -e` hands it over | read as |
|---------------|--------------------------------------------|---------|
| empty | `❯<NBSP> ESC[2m Try "fix typecheck errors"` | clean — the placeholder IS dim |
| typed into | `❯<NBSP> i said install bun if requir` | **dirty** — no escape sequences at all |

So the dim strip cannot eat text a human typed, and dropping the client gate cannot bring
back the regression it was there for (an idle agent whose hint made it read busy for as
long as the hint showed, so every nudge waited out the expiry and was dropped). The price
is the other direction: a placeholder drawn in a plain colour rather than dim now reads as
typing on a **detached** pane as well as an attached one, and that agent's notices wait out
the cap and are dropped. Nobody has seen such a placeholder — every Claude Code one
measured, live and in the probe, was `ESC[2m` — and Codex is unmeasured.
`WOLFMUX_NUDGE_COLLISION_CHECK=0` is the way out. [ROADMAP](ROADMAP.md) carries it as a
known limit.

Everything from the point where the row is looked at **fails closed**: a capture that
fails, a cursor row that makes no sense, and a client list that cannot be read all count
as busy. The one exception is the first `display-message`: when that fails there is no
session and no pane to fail closed for. A false busy only delays, and every delay is
bounded by the expiry.

Busy means the notice is **parked, not dropped**: a per-role marker under
`~/.wolfmux/state/<project>/nudge/<role>.pending` holds it and ONE detached waiter per
role looks again every `WOLFMUX_NUDGE_RETRY` (3 s, floored at 1) for up to the marker's
cap — `WOLFMUX_NUDGE_DEFER_MAX` (600 s), or `WOLFMUX_NUDGE_APPROVAL_DEFER_MAX` (60 s) for
an approval notice, which is worthless once the worker has stopped waiting for the
decision. It looks once BEFORE its first sleep, so an already-idle pane is notified at
once. Beads nudges that pile up while it waits **collapse into one line** (two different
bead ids, or an empty id beside a real one, give the generic line, which names the whole
inbox anyway); spawn, approval and policy notices each name their own event, so they
queue instead, and the pane is asked again before EVERY queued line, each line leaving
the marker as it is typed so a stop part-way can never re-send what already went out.
On expiry the marker is removed and `nudge-defer-expired` goes into `events.jsonl`.

The per-role lock is never held across the wait. A marker whose waiter died is **reaped**
by the next notice for that role (`nudge_pending_reap`, under the lock): without that it
would swallow every later notice for ever. The waiter itself ignores `HUP`, `INT` and
`TERM` — macOS has no `setsid(1)` — so closing the terminal that ran `teamctl` does not
kill it. `teamctl nudge` says `deferred: …`, names the check that fired, and exits 3.
`WOLFMUX_NUDGE_COLLISION_CHECK=0` brings the old blind typing back.

One window stays open: `tm_type_line` sends the text, waits 300 ms so a TUI does not read
the Enter as part of a paste, then sends Enter. A human who had been quiet for the pane's
whole keystroke window — `WOLFMUX_NUDGE_HUMAN_IDLE` for a worker, `WOLFMUX_NUDGE_LEAD_IDLE`
for the lead's own pane — can start typing inside those 300 ms and have their first
keystrokes land after the notice. Closing it needs tmux to report a key arriving
mid-line, and there is no such channel. Measured with a watcher typing from the moment a
notice appears, re-checking between queued lines cut the glued lines from 5 of 5 to 2 of
5 and kept the other 3 for later.

**What that number does and does not bound.** The watcher types with `tmux send-keys`,
which does not move `#{client_activity}`, so the keystroke check can never fire for it:
the figures bound the input-line check alone. A real person at a real keyboard also trips
the keystroke check, so they are protected by more than this, and a review round-2 run
with a much more aggressive send-keys watcher glued 6 of 6 — same reason. An honest
measurement needs keystrokes pushed through an attached client's own stdin; that harness
does not exist yet (one attempt deadlocked) and is a named follow-up. What both runs did
confirm, which is what matters for correctness, is that no notice was ever delivered twice
and none was lost.

The message body never travels through tmux, so there is nothing to quote, escape
or truncate. The same hook tells the lead when a worker closes a task or marks
one blocked. Comments fire no hook, by Beads' design.

### The notice inbox (v1.15.0)

Everything above is about not typing a notice **over** something. Issue #11 is the
different complaint underneath it: the lead's pane **is** the human's conversation, so a
notice typed into it perfectly is still an interruption. The answer is to stop treating
typing as the channel and make it one of five.

`lib/inbox.sh` appends every notice to `$STATE_DIR/inbox/<role>` before anything else
happens to it, one line per notice:

```
<epoch>\t<kind>\t<state>\t<text>        kind: beads | spawn | approval | policy
```

`<state>` is two letters because a notice has two readers with opposite needs, and the
two facts are **independent**: the first letter is `n`ew or `s`een — whether the HUMAN
has expanded it, which is what the status-bar count shows — and the second is
`u`ndelivered or `d`elivered, whether the AGENT has been given it. Handing a notice to
the agent must not clear the human's badge, and the human expanding it must not hide it
from the agent. One `>>` append of one short line per notice, so two notifiers writing
at the same moment cannot interleave; the read-modify-write paths take a per-role lock
and give up rather than wait. Same rule as `lib/notify.sh`: a notice may never fail or
delay a caller. The file is capped at 200 lines, oldest dropped.

Who is **typed** into, and why each row is what it is:

| pane | typed into | why |
| --- | --- | --- |
| a worker, Claude-family | yes, when idle (unchanged) | nobody is sitting in front of it, and it wakes the agent at once |
| the lead, Claude-family, **no client attached** | yes | nobody is looking; the line only goes to scrollback, and the agent wakes at once. `#{client_activity}` moves on real keystrokes only, and a detached session lists no client at all, so "is anybody watching" is one cheap tmux read |
| the lead, Claude-family, **a client attached** | only while that pane is **quiet** | this is the whole point, and v1.16.1 is where it stopped being "never" (issue #12). Quiet means all three `tm_pane_human_busy` checks say no, with the keystroke window widened to `WOLFMUX_NUDGE_LEAD_IDLE` (300 s): no keystroke in that pane for five minutes, nothing on the input line, no copy mode. Busy instead, and the notice waits in the per-role marker for the one waiter, exactly as a busy worker pane does. v1.15.0 answered "a client is attached" by filing only, and filing reaches the agent through its **Stop** hook, which fires on a turn boundary — an agent that is already idle has no further boundary, so such a notice was never handed over at all |
| any pane, **Codex-family** (`astra`, `codex:<id>`) | yes, lead included | Codex has no hooks, so typing is the only channel that reaches that agent at all. A Codex lead is deliberately noisier than a Claude lead; this row is the exception to the one above, not an oversight |
| the lead, an **approval**, a client attached | after a grace period, if still pending | an approval holds a WORKER until the lead answers; see below |

`WOLFMUX_NUDGE_TYPE` decides WHO is typed into: `off` · `workers` · `detached-lead`
(default) · `all` (the pre-1.15.0 behaviour). For the attached lead under the default,
`WOLFMUX_NUDGE_LEAD_IDLE` decides WHEN: how long that pane must have had no keystroke
first. Everything the v1.14.0 fix built is kept and only narrowed — the human-busy check, the per-role marker, the one detached waiter, the
heartbeat, the stale takeover, the per-marker caps, the reap, and `trap '' HUP INT TERM`
— because the typed paths above still go through all of it.

**How the agent learns about the bead**, with nothing typed. `write_agent_settings`
writes a per-agent Claude Code settings file at run time, and that is where the hooks
go; nothing is added to `~/.claude/settings.json`.

- `teamctl _inbox-stop` is a **second entry in the Stop array**, beside the notification
  hook rather than instead of it. When the role's inbox holds undelivered notices it
  answers `{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"<the notices + the agent's own Beads command>"}}`,
  so the agent carries straight on and reads its beads. Claude Code shows that as
  `Stop hook feedback`; v1.22.1 replaced `{"decision":"block","reason":…}`, which it shows
  as `Stop hook error`, and both go through the same loop protections (`stop_hook_active`,
  the 8-continuation cap). A loop is impossible here for two reasons and both are needed:
  the lines are marked delivered **before** the answer is printed, so one notice can never
  continue a turn twice, and no turn is continued again inside
  `WOLFMUX_INBOX_STOP_COOLDOWN` (10 s), so a burst of beads one a second cannot continue
  one turn a second. In a pane a human is using (an attached client shows it and its
  terminal has focus or saw a key in the last 2 minutes: `tm_pane_in_use`, v1.23.0), and
  in a Claude lead's pane whenever a client is attached, it answers **nothing**, under
  either value of `human-pane-typing` (v1.20.0 for `off`, v1.22.1 for `idle`): Claude Code
  prints the answer in full in the pane. The notices wait for the next prompt, or for the
  lead's wake waiter (below).
- `teamctl _inbox-prompt` runs on **UserPromptSubmit**: Claude Code adds such a hook's
  stdout to the model's context, so the notices arrive alongside whatever the human just
  typed. No cooldown — a human pressed Enter.

One hand-over carries at most `WOLFMUX_INBOX_HANDOVER_MAX` (20) notices. The cap matters
because `WOLFMUX_INBOX_MAX` × `WOLFMUX_INBOX_TEXT_MAX` is ~80 KB, reachable with nothing
going wrong — an attached lead, an idle agent, a busy hour — and the first prompt would
otherwise hand over the lot. The OLDEST batch goes first and the rest stay **undelivered**,
so the next turn takes the next batch and the body says how many are still waiting. A cap
that marked them delivered without showing them would be the lost-notice bug in a new
place, which is why it is written this way round.

Neither hook fires for an agent that is simply **sitting idle**, and that was the hole in
this design: a bead landing for an idle lead with a client attached waited for the human
(tagging.lead, 16 hours, issue #34). Three things close it:

- **The wake waiter** (v1.23.0, [ADR-0031](adr/0031-idle-lead-wake-waiter.md)).
  `teamctl _inbox-wake` is a Claude Code hook with `asyncRewake` on the lead's Stop and
  SessionStart. It runs in the background while the lead is idle and looks every
  `WOLFMUX_WAKE_POLL` (15) s. With a notice waiting and nobody using the lead's pane, it
  takes the notices, prints them and exits 2: Claude Code gives the text to the model and
  the lead takes a turn; the pane shows only `wolfmux: team notice`. Nothing is typed. One
  waiter per role (a token in `inbox/.wake.<role>`; UserPromptSubmit replaces it), exit 2
  only with notices, a re-arm before Claude Code's 7-day hook timeout, and it ends itself
  when its agent, its pane or its team is gone. Policy `lead-wake` (default `unwatched`)
  is the human's off switch.

- **The badge.** `status-left` calls `teamctl _inbox-badge <session-name>` every 5 s. It
  resolves the project and team from the session's own `@wolfmux_root` and
  `@wolfmux_team` options, so it needs no working directory; it prints `📨 <count>`, plus
  `🔔` while a permission request of the team is pending, and **nothing at all** on any error,
  because a badge may never break a status bar. (U+1F4E8 rather than U+1F54A DOVE: the
  dove is neither `Emoji_Presentation` nor East Asian Wide, so it needs U+FE0F to draw as
  an emoji and tmux miscounts its width, which pushes the rest of the line about.
  `WOLFMUX_INBOX_MARK` and `WOLFMUX_INBOX_APPROVAL_MARK` change both.)
- **One desktop notification**, through the `notify_deliver` path that already exists, so
  a click opens the team and nothing reaches the conversation. It is raised the moment we
  **decline to type** for the lead, not after a timer: nothing can tell us whether the
  agent's turn will ever end, so "it cannot reach the agent now" is the honest trigger,
  and if the agent was mid-turn its next prompt delivers the notice as well (its Stop
  hook keeps out of a pane the human is watching). It
  **collapses** — one banner per role per `WOLFMUX_INBOX_STALL_NOTIFY_DEBOUNCE` (120 s,
  deliberately not the 3 s nudge debounce: a banner with a sound is the one channel that
  interrupts whatever the human is doing, and this machine runs dozens of teams whose
  Beads events fire on create, update and close) — and it carries the **count** from the
  file, "team/lead: 4 notices waiting", rather than the one notice that triggered it.
  Inside the window the notice still lands in the file and the badge still rises.
  `WOLFMUX_INBOX_STALL_NOTIFY=off`, or `WOLFMUX_NOTIFY=off`, drops it.

What is left: a lead whose pane the human IS using (focused, or a key lately) waits for
his next prompt, by design; and a terminal that never reports focus reads focused for
ever, so its lead waits too (`WOLFMUX_WATCH_FOCUS_MAX` caps that). Nothing is lost — the
bead is in Beads and the notice is in the file.

**Approvals may not get slower than they were.** A permission request blocks a worker
until the lead decides, which is why its deferral cap is 60 s rather than 600. So: a
detached lead is typed into immediately, exactly as before; an attached lead gets the
louder `🔔` mark at once, and if the request is **still pending**
`WOLFMUX_INBOX_APPROVAL_GRACE` (20 s) later it is typed in after all, through the same
busy-and-park machinery as any other notice. `WOLFMUX_INBOX_APPROVAL_TYPE=never` leaves
it to the badge, `always` types it at once, and `WOLFMUX_NUDGE_TYPE=off` outranks all
three. The existing 60 s cap and the worker's own fallback prompt are untouched
underneath.

**Pending, not unread, and the difference matters.** The timer asks the approvals store
whether the request is still `pending`; approved, denied and expired all cancel it,
because in each of those nothing is blocked any more. It deliberately does NOT ask
whether the human has read the notice: `teamctl inbox --all` (what `prefix N` opened
before v1.20.0) marks every role's notices seen, so a glance at a *worker's* line used to cancel the typing of an approval
the human had never read, handing a blocked worker back to the attention the grace
exists to avoid. A store that cannot be read fails towards typing — a stalled worker is
the harm, one line in a pane is the cost. An approval is the one notice that can still
put a line in the human's conversation, and a blocked worker is the reason.

**Consequence to be plain about**: `notify_lead`'s spawn and policy notices go through
the same route, so an **approval request reaches an idle, attached lead only when the
human expands it, when the desktop notification is noticed, or when the lead is next
prompted** — plus the 20 s grace above. The worker's own 10-minute fallback prompt still
covers the case underneath. No new timer was invented for it.

**v1.20.0: the count is the human's Beads messages, not the notices.** Since v1.20.0 the
`<count>` above is the number of open Beads messages assigned to the human (`human`, or
`WOLFMUX_HUMAN`) in the project, and pane notices are not counted at all. The Beads hook
hands every message bead to `teamctl _human-inbox-hook` in the background, which keeps
`~/.wolfmux/state/<project>/human-inbox` (id, sender, subject, created; `\037` between
fields; whole-file rewrite, temp file and `mv`, under a mkdir lock): an open message for
the human is added, one closed or reassigned is dropped. The badge counts that file's
rows and never runs bd. `prefix N`, and a click on the badge (`#[range=user|inbox]` in
`status-left`; on tmux 3.7c a click on a user range fires `MouseDown1Status` with
`#{mouse_status_range}` = `inbox`), open `teamctl _human-inbox`: it draws the file at
once, makes ONE targeted `bd list --assignee human --type message --status open`,
rewrites the file and draws again, so an index that drifted is put right whenever the
human looks. Marking read runs `bd close` as the human (`BEADS_ACTOR=human`), because bd
refuses to close a bead assigned to somebody other than the actor.

`teamctl inbox [<role>] [--all] [--json] [--keep]` (alias `notices`) shows the pane
notices, for debugging. Reading marks the notices not-new and leaves the delivered
column alone. The key is `N` and not `I` because `config/wolfmux/tmux.conf` sources the user's own
`~/.tmux.conf` first: every wolfmux binding comes later and wins inside the wolfmux
server, and `I` is tmux-plugins/tpm's on a machine that has it.

### Completion

Worker tests → commits on its branch → sends `Done: …` to the lead (summary, test
status, commit hash, risks) → closes its task. Lead runs `teamctl diff <role>`,
reviews, then requests changes, cherry-picks, rejects, or asks another worker to
review. Only the lead changes the main checkout.

## One manager

The lead is the only manager. Three mechanisms keep it that way:

1. **Manager-only commands.** `caller_role` reads the `@ai_role` of the pane a command
   runs in (falling back to `TEAM_ROLE`; empty means the human), and the pane proof
   below checks that claim. `start`, `stop`,
   `restart`, `destroy`, `policy`, `approve` and `deny` require the lead or the human;
   `spawn` does too unless the `worker-spawn` policy is `on`.
2. **No native teams inside workers.** `_run-agent` writes a per-agent settings file; for a worker it holds
   `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "0"` and `teammateMode = "in-process"`. teamctl
   hands the file to the launcher through `WOLFMUX_EXTRA_SETTINGS`; the launcher merges it
   into its single `--settings` value. With Claude Code's agent-teams feature on, any
   subagent a session names becomes a teammate whose team lead — and permission
   approver — is that session, so a worker would become a second manager.
3. **Awareness.** A spawn by a worker records `spawned_by`, shows in `teamctl status`,
   and types `[wolfmux] Team change: <spawner> spawned teammate <role> (<model>)` into
   the lead's pane. Policy changes made from outside are announced the same way.

4. **Lanes.** A worker's generated settings carry a `PreToolUse` hook, `teamctl _guard`
   (`lib/guard.sh`). It knows the worker's worktree and branch from the environment
   `_run-agent` exports (`WOLFMUX_WORKTREE`, `WOLFMUX_BRANCH`, `WOLFMUX_ROOT`) and
   answers `deny` with a reason for tool calls that leave the lane. File tools are
   resolved to real paths; shell commands are matched after every spelling of the known
   directories has been replaced by a token. See [ADR-0016](adr/0016-worktree-guard.md).

5. **Identity is the pane.** An agent's identity lives in its environment (`TEAM_ROLE`,
   `WOLFMUX_TEAM`, `BEADS_ACTOR`, `TMUX_PANE`), and everything the agent starts inherits
   it. On 2026-10-19 the comms lead was sent to the background (`/bg`): Claude Code turned
   its pane into the agent view, the agent view started Claude's daemon from inside the
   pane, and every background chat of that daemon carried the lead's environment. Three
   chats acted as the comms lead for two days. So a claim counts only with the **pane
   proof** (`identity_in_own_pane`, `lib/common.sh`): `TMUX_PANE` is a pane of the team's
   server, one tmux read shows that pane's `@ai_role` and session match, and the pane's
   process is the caller or one of its ancestors (one `ps -axo pid=,ppid=`, walked in
   awk). A daemon's chat runs under `claude daemon run`, whose parent is pid 1, so it fails.
   - The inbox hooks (`_inbox-prompt`, `_inbox-stop`) and the notification hook
     (`_notify`) give an unproven chat nothing, take nothing from its inbox and block
     nothing. `_inbox-prompt` tells it, on every prompt, that it is NOT that agent. One
     `identity-refused` line goes to the event log, at most once a minute per role.
   - `caller_role` keeps an unproven claim (it never turns into the human), and every
     check of who may act (`is_operator`, `is_manager`, `is_founder`, `is_steward`, so
     every manager-only command, plus `start` and `restore`) refuses it with exit 77.
     Read-only commands (`status`, `teams`, `dashboard`, `inbox`, `diff`, `capture`,
     `doctor`, `version`) keep working for it.
   - Prevention: every Claude agent runs with Claude Code's agent view off
     (`disableAgentView: true` and `env.CLAUDE_CODE_DISABLE_AGENT_VIEW = "1"` in its
     settings file, and `CLAUDE_CODE_DISABLE_AGENT_VIEW=1` in its environment), so `/bg`
     cannot turn its pane into the agent view. A running agent gets this at its next
     start or restart, not before.
   - The tmux server never starts with an agent's identity (`tmx_boot` removes it), so a
     pane you split for yourself, and tmux's own `run-shell` and `#()` commands, run as you.
   Like the rest of this section it is a cooperative check, not a security boundary: every
   agent is your macOS user.

### Permission modes

| Mode | Claude Code | Codex |
|------|-------------|-------|
| `skip` | `--dangerously-skip-permissions` | `--dangerously-bypass-approvals-and-sandbox` |
| `lead` (workers) | a `PermissionRequest` hook → `teamctl _permission-hook` | not available; behaves as `ask` |
| `ask` | the CLI's own prompts | the CLI's own approvals and sandbox |

In `lead` mode the hook files `approvals/A<n>.json` (tool, a 400-character summary of
the input, role, time), types `[wolfmux] Permission request A<n> from <role>` into the
lead's pane, and polls for up to `WOLFMUX_APPROVAL_TIMEOUT` seconds. `teamctl approve`
/ `deny` flip the record; the hook returns Claude Code's documented decision object
(`behavior: allow` or `deny` with the lead's reason). On timeout, or when no lead pane
is alive, it returns nothing, which means "show the normal prompt".

![Sequence: a worker's permission request is filed, the lead approves or denies, the decision returns to the worker's CLI](diagrams/approval-flow.svg)

### Browser writes

`skip` mode's `--dangerously-skip-permissions` auto-approves ordinary permission checks, but
it does not switch off Claude Code's auto-mode classifier: that runs separately and can still
deny a call its own way, for example an "External System Writes" decision on a
`mcp__claude-in-chrome__*` write. The classifier only runs while the permission decision is
still `ask`; an explicit `permissions.allow` rule for the tool resolves the call before the
classifier ever sees it. `write_agent_settings` (`lib/agents.sh`) writes that rule into every
agent's settings — lead and workers alike — when the team's `browser-writes` policy
(`lib/policy.sh`) is `allow`. Default is `ask` (no rule, byte-identical settings document to
before this existed): it is a team-wide opt-in, not a blanket exemption for every skip-mode
agent, because the rule also removes the External System Writes check for every Chrome write
that team's agents make, which is the trade being made.

## The context number

One figure per agent, `used/limit share` (ADR-0038). `used` is the last request of the agent's
transcript (`models_transcript_tail`). `limit` comes from one function, `context_limit_for`
(`lib/policy.sh`): the smaller of the window the agent's CLI was told to compact at and its
model's window, minus the 33,000 tokens Claude Code keeps in reserve.

```
teamctl spawn / restart      WOLFMUX_WORKER_COMPACT_WINDOW of that command -> record.compact_override
  pane: teamctl _run-agent   worker_compact_plan: override, else F + K + 33000 + room; raised when it
                             would thrash; capped by the model -> settings env CLAUDE_CODE_AUTO_COMPACT_WINDOW
                             and record.compact_window
the agent's hooks            PostToolUse (every 10th call; every call while run/<role>/near exists):
                             used and limit -> run/<role>/memory/ctx, warn and rotate once each
                             first request F -> $STATE_DIR/context/<kind>, for the next worker's window
                             SessionStart source=compact: kept part K, memory/compactions; two within
                             10 tool calls -> one message to the lead
teamctl status, dashboard    agent_context: transcript tail + record.compact_window -> CTX_LIMIT
```

The watch returns at once when the hook input carries `agent_id` (an in-process subagent). The
lead gets no compact window; its limit is its model's window minus the reserve. Codex is counted
against the window its rollout states.

### A stalled agent (lib/stall.sh)

A turn that ends on an API error row (`isApiErrorMessage`, model `<synthetic>`: a 529, a usage
limit, or the CLI's own "Autocompact is thrashing" stop) is followed by `turn_duration` and
nothing else. No hook of that agent runs again, so the look comes from outside it:

```
lead idle:   Stop/SessionStart -> _inbox-wake loop (every 15 s) --every 60 s--> stall_scan
lead busy:   10th tool call -> _hook PostToolUse -> recall_hook -> _recall_stall_look --60 s stamp--> stall_scan &
anyone:      teamctl status -> stall_scan (each team) -> "stalled" lines under the table
stall_scan:  per agent on the books (not the lead), cheapest test first:
             record (one jq): claude, running, a conversation id -> stat the transcript: quiet >= WOLFMUX_STALL_AFTER
             -> tail 40 + jq: the last main-thread row is an error row -> store: a task of it in_progress
             -> mkdir state/stall/<role>.<error timestamp> (once per error row) -> message to the lead
```

The message names the error's first line, since when, the task, and `teamctl restart <role>
--continue` followed by a message. Nothing is typed into a pane and nothing restarts an agent.
It cannot see an agent stuck any other way, a Codex agent, or the lead itself.

## Teams

A project has one or more teams ([ADR-0018](adr/0018-several-teams-per-project.md)).
`load_project` resolves the repository, then the team: `--team`, else the caller's own
(`@wolfmux_team` on the tmux session, `WOLFMUX_TEAM` in the agent's environment), else the
only one there is. Everything per team hangs off two variables it sets, `STATE_DIR` and
`WORKTREES_DIR`, which is why policy, approvals, arrangement, guard and notifications
needed no team logic of their own.

| | first team (`default`) | named team |
|---|---|---|
| tmux session | `team-<project>` | `team-<project>-<team>` |
| state | `~/.wolfmux/state/<project>/` | `…/<project>/teams/<team>/` |
| worktrees | `~/.wolfmux/worktrees/<project>/<role>-<stamp>` | `…/<project>/teams/<team>/<role>-<stamp>` |
| branches | `ai/<role>-<stamp>` | `ai/<team>/<role>-<stamp>` |   (the default template; `teamctl policy branch-template` sets another)
| Beads name | `<role>` | `<team>.<role>` |

The Beads hook reads the team out of the assignee's name (`review.backend`) and the lead to
tell out of the actor's (`review.lead`); `teamctl nudge` accepts the same names. For an agent
of a named team the protocol's examples are rewritten at launch (`-a lead` → `-a review.lead`).

![Several teams in one project](diagrams/teams.svg)

Founding and deleting ([ADR-0019](adr/0019-deleting-a-team-and-founding-one.md)). `teamctl
start` is yours and, for its own team, the lead's. One thing more: a lead may start a team
that does not exist yet (`start_permitted`; policy `lead-teams` of the founder's team,
default on), and `--handover <bead-id>` is stored in the new lead's record and becomes its
first prompt. The founder is
recorded as `spawned_by`, you are notified, and the founder does not manage the new team
while that team's lead runs. When it does not (`team_lead_running` asks tmux: no session,
a dead pane or none), `require_manager` and `start_permitted` let the founder run `restart`,
`stop`, `remove`, `destroy` and `start --continue` on it, announce each one to you and log it
with the founder's Beads name ([ADR-0023](adr/0023-founder-recovers-an-orphaned-team.md)).
`teamctl destroy --purge` is the reverse: `_purge_report` measures and lists first (size per
worktree, uncommitted files, commits the checked-out branch does not have, transcripts).
Nothing is touched until the answer is yes, `--force` was given, or `--yes` with nothing at
risk. `_purge_team` then ends the session and removes the team's own state files; a
worktree named in a record only when it lies inside the team's worktree directory (with
the transcript folder derived from its path); a branch only when teamctl created it
(`branch_created` in the record; a record from before that field counts its `ai/…` branch as
teamctl's) and it is not the
one checked out in your checkout.

What teams do not have apart: your checkout. Every lead works in the project root.

## The dashboard: one view of the whole machine

`status` and `teams` are per project. `teamctl dashboard` (`lib/dashboard.sh`, `prefix O`)
walks every project with state under `$WOLFMUX_DATA/state/`, every team of each, and every
agent of each team, and `status-right` carries a one-line summary of the same picture
(`teamctl _overview-badge`). Both are strictly read-only: they take no action on any team.

### The house rule: show what is known, say nothing where it is not

**Never a number that looks precise and is not.** This decided three things in this module,
and it is worth stating once because it keeps being the right answer:

- There is **no "idle" column**, because there is no honest signal for one.
  `#{pane_activity}` is empty on tmux 3.7c; a whole team shares one window, so
  `#{window_activity}` cannot speak for a single agent; and an agent waiting at its prompt
  and an agent working both run `node`. The alternative was to parse pane output, which
  `lib/views.sh` forbids outright. So the view reports the states tmux really knows —
  running, stopped, exited — and two measurements under their own names.
- **`cpu` / `mem` is a process reading, not a claim about what the agent is doing.** It is
  the whole process tree under the pane's pid, because an agent's CLI is a *child* of that
  pane's shell and the shell alone would report every agent asleep.
- **`wrote` is a file timestamp, nothing more** — the mtime of the very transcript file the
  context reader opened (`CTX_FILE`, set by `agent_context`). It happens to move on every
  turn an agent takes, which is what makes it useful, but it is not labelled as activity.
- **Context shows three cases, not two**: a known share, a token count with *no* share when
  the model's window genuinely cannot be known, and nothing at all when there is no
  transcript. A percentage of a guessed window is worse than no percentage, so the share is
  dropped rather than invented — never `0%`, never `100%`. `ctx_display` does the
  formatting and decides the share; the dashboard only decides whether it may be shown.

### Two costs it is built around

**It never runs `du`.** A `du` over a busy machine's lane worktrees takes seconds, which is
why `teamctl status` never measures either. Lane totals are the number `teamctl teams`
left behind in `state/<project>/disk-kb`, under the same fifteen-minute rule
(`disk_team_kb_cached`); when the number is older than that the view shows it as `STALE`
with its age and names `teamctl teams` as what refreshes it. A missing number is normal and
says so.

**One `ps` and one `tmux list-panes` for the whole view**, never one per agent — and
neither of them at all on the badge's path, which redraws every few seconds for every
attached client. The badge opens no transcript either; it costs about 18 ms of work.

### The fast path, and the test that keeps it honest

Every other view answers for one team, where a `jq` process per field is invisible. This
one walks 25 teams and 74 agents, and measured 6.1 s that way — `reg_list` spawns a `jq`
per record, `reg_field` one per field, and `team_orphaned` asks tmux three times per team.
So four helpers answer the *same* question from data already in hand, by globbing and bash
string matching instead of a process each:

| fast path | stands in for |
|-----------|---------------|
| `dash_team_records` | `reg_list` + `reg_field` (one slurped read, the registry's own sort key) |
| `dash_teams` | `team_list` |
| `dash_orphaned` | `team_orphaned` |
| `dash_pane_row` | `tm_pane_for_role` + `tm_pane_state` |

`tests/dashboard.sh` asserts that **each one agrees with the helper it replaces**. If they
ever diverge the suite fails, which is the point: these are faster routes to the same
answer, not second opinions. Everything else is reused as it stands — `agent_context`,
`ctx_display`, `disk_team_kb_cached`, `disk_free_kb`, `team_paths`, `human_size`,
`short_path`.

Two further details that are not obvious from the code. The project root comes from the
first readable `meta.json`, **including a team's**: the project-level one belongs to the
default team and is simply absent on a project that only ever had named teams. And a
project that cannot be read, or holds nothing at all, is *named* in the output rather than
dropped — the two are reported separately, because "I cannot read this" and "there is
nothing here" are different things to tell whoever is looking.

### The badge may never break a status bar

tmux displays whatever a `#()` command prints, for as long as it is given it, so a
half-written line or an error message would sit in the status bar of every attached client
until the server restarted. `cmd_overview_badge` therefore prints **nothing at all** on any
failure: one line only, printable characters only, bounded length.

## Arrangement and coming back

`lib/layout.sh`: `lead-left` (default: the lead is tmux's main pane at 55 % of the width,
workers stacked on the right), `lead-top`, `tiled`. Applied after every start, spawn, stop
and restart; the lead is first moved to the first pane, because a re-created lead pane
would otherwise not be tmux's "main" one. Stored per project in `meta.json`.

`remain-on-exit` keeps a finished agent's pane, so a session can outlive every process in
it. `teamctl start` therefore looks at what is alive: lead alive → attach; lead gone but a
worker alive → the lead is restarted in place; nothing alive → the session is killed,
worker records become `stopped` (worktrees and branches stay), and a new session starts —
on the new socket if that was the last session of a pre-rename server.

## Notifications

Every Claude-based agent gets a `Stop` hook, `teamctl _notify`, through its generated
settings file. It takes the first line of the agent's last message, strips control
characters, and writes an OSC 9 notification to the tty of each terminal attached to
the team (`tmux list-clients`, terminals known to support it: iTerm2, kitty, Ghostty,
WezTerm). The notification therefore belongs to the terminal, and clicking it brings
the tab with the team to the front. The usual notifiers cannot do that from inside
tmux: they fall back to `osascript`, whose notifications macOS files under Script
Editor. With nothing attached — a team left to work in the background — the message is
posted by `~/.config/wolfmux/Wolfmux.app`, a small application `install.sh` builds with
`osacompile`. macOS opens the owner of a notification when you click it; Wolfmux.app,
started with no message waiting, takes that as the click and runs `teamctl _open-team`,
which opens a terminal window attached to the team. The ECC plugin's own notifier is switched off inside team agents
(`ECC_DISABLED_HOOKS`, merged with whatever you already disable) so you get one
notification, not two. `WOLFMUX_NOTIFY=all|lead|off`. See
[ADR-0015](adr/0015-notifications-through-the-attached-terminal.md).

![Sequence: Stop hook, teamctl asks tmux for attached terminals, OSC 9 to that terminal, click returns to the team](diagrams/notification-flow.svg)

## The wolf

Cosmetic, and built so it can never fail a command (`lib/brand.sh`):

| Where | What |
|-------|------|
| opening a team (`teamctl start`, `teamctl attach`, plain `tmux attach`) | a popup with the wolf, the wordmark and a line about the team; a `client-attached` hook set per session. Any key closes it, or 3 seconds. `WOLFMUX_SPLASH=off` removes it |
| the manager's pane | `🐺 lead · <model>` in the border title and an amber border, focused or not; the pane opens with the wolf; a Claude lead is named `🐺 team/lead` inside Claude Code |
| every teammate's pane | `🐶 <role> · <model>` in the border title, `🐶 team/<role>` inside Claude Code, `🐶 <role>: …` in notifications |
| status line and terminal tab | `🐺 WOLFMUX` on the left of the status line; the tab title is `🐺 <session>` |
| `teamctl status` | `manager: 🐺 lead` |

One pixel drawing (`tools/wolf-art.py`) produces the terminal art in `lib/brand.sh`,
`docs/diagrams/wolf.svg` and the wolf inside the hero image.

## State and file layout

```
~/bin/                          teamctl + launchers
~/.config/wolfmux/              code, tmux.conf, TEAM_PROTOCOL.md, README.md, config, glm-worker-settings.json
~/.wolfmux/state/<project>/     meta.json (incl. policy), agents/<role>.json, settings/<role>.json, approvals/, events.jsonl, nudge/ (debounce stamps, <role>.lock, <role>.pending), disk-kb
~/.wolfmux/state/<project>/     meta.json (incl. policy), agents/<role>.json, settings/<role>.json, approvals/, events.jsonl, nudge/
                                store (which backend), store.db (native tasks, mail, memory)
                                run/<role>/ (call counter, turn state, mail spool, memory/checkpoint.md)
~/.wolfmux/worktrees/<project>/ one directory per worker
<project>/.beads/               tasks and messages, for a project kept on the Beads backend
macOS Keychain                  one service per provider: "zai-coding-plan" (Z.ai),
                                "wolfmux-kimi", "wolfmux-moonshot", "wolfmux-deepseek",
                                "wolfmux-minimax", "wolfmux-qwen"
```

`<project>` is `<directory-name>-<6 hex of the path hash>`. Nothing of `teamctl`'s
is written inside the repository. The registry holds process and worktree facts
only and is reached exclusively through `reg_*` functions, so the JSON files could
be replaced by another store without touching a command.

## How agents learn the rules

`_run-agent` builds a prompt from a short header (role, kind, model, worktree,
branch, base) plus `TEAM_PROTOCOL.md` and injects it at launch:
`--append-system-prompt` for Claude Code, `-c developer_instructions='''…'''` for
Codex. No CLAUDE.md or AGENTS.md is edited, and only team sessions see the
protocol. Workers also get a one-sentence kickoff prompt telling them to read
their inbox (`--no-kickoff` skips it); the lead gets none, because the human
drives it.
