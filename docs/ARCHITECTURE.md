# Architecture

## Two tools, two planes

| Plane | Tool | Owns | Never touches |
|-------|------|------|---------------|
| Control | `teamctl` | tmux panes, which model runs where, git worktrees and branches, start / stop / restart / destroy, diagnostics | — |
| Data | `teamctl`'s store interface (`lib/store.sh`, `store_*`) | tasks, dependencies, messages, team memory, history, who-did-what | tmux, worktrees |

Tasks, messages and memory sit behind one interface with two backends: a native
`sqlite3` file per project (the default for one with nothing on disk yet) or Beads
(`bd`), kept for a project already on it (`teamctl store`, [ADR-0031](adr/0031-a-store-of-our-own.md)).
Every module above the interface (`mail.sh`, `tasks.sh`, `memory.sh`) calls `store_*`
only, so neither they nor an agent's commands differ by backend. On the native
backend, a write that should notify someone calls `mail_announce` itself; on the
Beads backend a three-line event hook calls `teamctl _deliver` instead. Delivery
itself is one more seam below both: a Claude Code agent's CLI hooks carry the body
straight into its conversation ([ADR-0028](adr/0028-mail-through-the-clis-hooks.md));
a role with no running pane, or a Codex-family agent (no such hooks), still gets the
one-line typed notice this always worked by.

![Two tools, two planes: teamctl, the tmux server with lead and workers, Beads, and the hook between them](diagrams/architecture.svg)

## Components

### Launchers (`~/bin`)

Each launcher cleans **its own process environment** and then `exec`s the real CLI.
The user's shell is never modified. The list of variables to remove lives in one
file, `lib/provider-env.sh`, shared with `teamctl doctor` so scrubbing and
diagnostics can never drift apart.

| Launcher | CLI | Billing | What it pins |
|----------|-----|---------|--------------|
| `claude-fable` | Claude Code | Claude subscription (`/login`) | `--model claude-fable-5-1[1m]`; no key, no endpoint |
| `claude-opus` · `claude-sonnet` · `claude-haiku` | symlinks to `claude-fable` | same | the model named by the link (`claude-opus-5`, `claude-sonnet-5`, `claude-haiku-4-5-…`) |
| `codex-astra` | Codex CLI | ChatGPT / Codex subscription | `forced_login_method="chatgpt"`, `model_provider="openai"`, `model="gpt-6-astra"`. Starts Codex by its **real path**: Codex looks for its helper programs next to the path it was started as |
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
| `registry.sh` | the only module that touches state files; project lock; nudge debounce |
| `tmuxctl.sh` | every tmux call |
| `worktree.sh` | worktree and branch creation, `worktrees`, `diff` |
| `beads.sh` | Beads bootstrap (stealth init) and hook installation, for a project on that backend |
| `policy.sh` | who is calling (`caller_role`), manager-only commands, the policy keys (`POLICY_KEYS`) |
| `approvals.sh` | the lead decides workers' permission requests (`_permission-hook`, `approvals`, `approve`, `deny`) |
| `agents.sh` | `start`, `spawn`, the pane process (`_run-agent`), `stop`, `restart`, `destroy`, `nudge` |
| `views.sh` | `status`, `panes`, `capture`, `log`, `focus`, `attach` |
| `doctor.sh` | `teamctl doctor` |
| `completion.sh` | `teamctl _complete`, the one backend behind the zsh and bash tab-completion shims |
| `hooks.sh` | `teamctl _hook <Event>`: reads the CLI's hook JSON, lets `mail_hook` / `tasks_hook` / `memory_hook` add text, answers in the shape the event expects. Never fails, never delays an agent |
| `store.sh` | `store_*`: one interface over the two task/message/memory backends, plus `teamctl store` |
| `mail.sh` | `send`, `inbox`, delivery (`mail_announce`, `_deliver`, the hook drain) |
| `tasks.sh` | `task`, `claim`, `done`, `blocked`, `tasks`, `show`, `note`, `reopen`, `close`, and the Stop-hook reminder for work left open |
| `memory.sh` | team memory and checkpoints at `SessionStart`, the context watch at `PostToolUse`, `PreCompact`'s own note, `checkpoint`, `remember`, `memories`, `forget` |

The **model table** in `common.sh` is the single place that knows which launcher
serves which model key (`fable`, `astra`, `glm53`, `flash`) and which CLI family it
belongs to. Nothing else in the code is model-specific, which is what makes the
two leads interchangeable.

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

### The store (`lib/store.sh`)

`store_kind` picks the backend: the file `$PROJECT_STATE/store` wins if one exists;
else `WOLFMUX_STORE`; else `beads` for a project that already has agent state from
before v1.13 (a registry record, or `meta.json`); else `native`. A public `store_*`
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
once without the embedded-Dolt single-writer queue ([ADR-0031](adr/0031-a-store-of-our-own.md),
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

![Sequence: a task goes out through Beads, a fixed line reaches the worker's pane, the result comes back the same way](diagrams/message-flow.svg)

1. lead: `teamctl send backend "Subject" "…"` — durable in the store, native or Beads
2. on the native backend the write calls `mail_announce` itself; on Beads, Beads
   fires `.beads/hooks/on_create` with the bead as JSON on stdin and the hook calls
   `teamctl _deliver backend --event create` in the background. Either way the next
   step is `_mail_deliver_to`, the one path to a recipient.
3. a role with no running pane, or a Codex-family agent (no hooks of its own), gets
   the old typed nudge instead (one fixed line, debounced 3 s under a per-role guard:
   `[wolfmux] New mail for backend: it is shown with this line. If nothing is shown,
   run: teamctl inbox`). Otherwise the item is spooled to `$STATE_DIR/run/backend/mail/new/`
   and flagged for attention
4. idle: the next `PostToolUse`, `UserPromptSubmit` or `Stop` hook on backend's own
   CLI drains the spool and puts the rendered item straight into its conversation
   (`additionalContext`), no command run. Busy: a detached watchdog waits
   `WOLFMUX_MAIL_WAKE_AFTER` seconds of apparent idle before typing the one-line
   notice, in case the turn was interrupted and fired no `Stop`
5. the worker reads the body in its own conversation and acts on it directly — no
   round trip through `teamctl show` or `teamctl inbox` just to see what arrived

The message body never travels through tmux on the hook path, so there is nothing
to quote, escape or truncate. The same path tells the lead when a worker closes a
task or marks one blocked (`mail_announce` / the Beads hook, by the same rule:
the assignee when someone else changed its task, the lead when a worker blocks or
closes one, never the actor itself). Comments fire no hook, on either backend.

### Completion

Worker tests → commits on its branch → sends `Done: …` to the lead (summary, test
status, commit hash, risks) → closes its task. Lead runs `teamctl diff <role>`,
reviews, then requests changes, cherry-picks, rejects, or asks another worker to
review. Only the lead changes the main checkout.

## One manager

The lead is the only manager. Three mechanisms keep it that way:

1. **Manager-only commands.** `caller_role` reads the `@ai_role` of the pane a command
   runs in (falling back to `TEAM_ROLE`; empty means the human). `start`, `stop`,
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
