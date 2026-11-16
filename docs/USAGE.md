# Usage

The installed user manual is [`config/wolfmux/README.md`](../config/wolfmux/README.md)
(`~/.config/wolfmux/README.md` on the machine). This page walks through one
complete session and lists every command.

Tasks, messages and shared team notes are `teamctl` commands (`send`, `task`, `checkpoint`, …),
not Beads: agents no longer need `bd`. They live in a native sqlite store by default, or
in Beads for a team already on it (`teamctl store`; [Beads cheat sheet](#beads-cheat-sheet)
if yours is). A message or task reaches a Claude Code agent through its CLI's hooks, with
the body, at its next tool call — a Codex agent gets the one-line notice, typed only where the typing gates allow. A worker's own
conversation starts under the `worker-context` policy (default `trim`: your rules and
settings; every plugin, the tools a pane agent cannot use and the claude.ai connectors off;
[what an agent starts with](#what-an-agent-starts-with)) and is told, as it fills up, to commit and checkpoint, then to
start nothing new (`WOLFMUX_CONTEXT_WARN` / `WOLFMUX_CONTEXT_ROTATE`); `teamctl restart
<role>` picks the work back up from that checkpoint.

**One context number.** Every view prints the same figure for an agent, `142k/167k 85%`:
what its conversation holds, the limit its CLI compacts at, and the share of that limit.
The limit is the window the CLI was started with (`WOLFMUX_WORKER_COMPACT_WINDOW` for a
worker, the model's own window for a lead) minus 33,000, the reserve Claude Code keeps.
`teamctl status`, the dashboard, the watch's notices, the lead's "context at N%" message
and a checkpoint's header all use it; `status --json` has `context_limit` next to
`context_window`. A model whose window nobody declared shows tokens alone and is never
warned by percentage. A worker's window is made from what was measured in this team
(first request + kept part + 33,000 + `WOLFMUX_CONTEXT_ROOM`, default 150000) and is
raised when it would leave under 30,000 tokens after a compaction. Near a threshold the
watch looks at every tool call instead of every tenth, so the warning comes before the
CLI compacts. Two compactions within 10 tool calls send the lead one message with the
numbers. The watch says nothing inside an in-process subagent.

## Upgrading from v1.24

`./install.sh` changes nothing in a running agent's settings: an agent's settings file is written
when its pane starts. What reaches a running team at the install, and what waits for a restart:

- **At once, with no restart:** the hooks run the installed library, so the context watch (its
  `used/limit share` figure, the warning before a compaction, silence inside a subagent, the
  "compacted twice" message) and the stalled-agent look (`teamctl status`, the lead's tenth tool
  call, the idle lead's wake waiter once it re-arms) work from the next call.
- **After `teamctl restart <role> --continue`** (and `teamctl start` for a new session): the long-output
  rewrite and its lower `bashOutputMaxChars`, the denied tools, the connector switch,
  `context-exclude`, and a worker's computed compact window. They are part of the settings the pane
  writes at start. Restart the lead too if you want it to benefit from `output-offload`.
- **Workers under the default `worker-context trim` no longer load the claude.ai connectors**
  (`ENABLE_CLAUDEAI_MCP_SERVERS=false`), nor seven tools a pane agent cannot use (Artifact,
  AskUserQuestion, SendFeedback, ScheduleWakeup, Workflow, ReportFindings, ListAgents). A worker that
  used a connector (Gmail, Slack) or a denied tool loses it. To keep them:
  `teamctl policy worker-context full`, then restart the workers. A rule of yours that tells an
  agent to use a denied tool cannot be followed by a worker. The lead is untouched unless you set
  `teamctl policy lead-context trim`.
- **Three new policies** ([what an agent starts with](#what-an-agent-starts-with)):
  `output-offload` (`on` by default: a Bash call's long output goes to a log and the agent sees the head,
  tail, failure lines and the path; `off` writes none of its hook entries), `context-exclude` (globs
  of instruction files a trimmed agent leaves out; empty by default) and `lead-context` (`full` by
  default). Nothing of yours is left out unless you name it. For a rules folder that repeats another in
  a second language, `teamctl doctor` prints the one line to run and what it saves, for example
  `teamctl policy context-exclude '**/rules/ecc/zh/**'`; it is a note, not a warning.
- **The CONTEXT column reads `used/limit share`**, for example `142k/167k 85%`: the limit is the
  window the agent's CLI compacts at, minus 33,000. A model whose window nobody declared shows tokens
  alone. `status --json` has `context_limit`; anything that read `memory/ctx`'s `tokens` reads `used`.
- **A worker's compact window is now computed** (first request + kept part + 33,000 +
  `WOLFMUX_CONTEXT_ROOM`), not the model's. On a 1M model that means compactions come earlier than
  under v1.24.0, on purpose. A window given on `spawn`, `task --spawn` or `restart` now reaches the worker.
- **Two new notices a lead can get:**
  - `<role>: compacted twice within <n> tool calls`: that agent is about to thrash. The message holds
    the tokens before the second compaction, the limit, the first request, what the compaction kept and
    the room left. Act on it with the line it prints:
    `WOLFMUX_WORKER_COMPACT_WINDOW=<tokens> teamctl restart <role>` (a new conversation from its checkpoint,
    with a larger window). Said once per conversation.
  - `<role>: stalled on an error since <time>`: its last turn ended on an API error (a 529, a usage
    limit, the CLI's own "Autocompact is thrashing" stop) and no hook of it runs again. It arrives after
    `WOLFMUX_STALL_AFTER` seconds (300) of quiet and once per error. Act on it with
    `teamctl restart <role> --continue`, then `teamctl send <role> "go on with <task>"`: a restart leaves
    an idle agent idle. It is found only while somebody looks (the lead's hooks, its idle waiter, or any
    `teamctl status`); a stalled lead, a hung tool or a dialog is not seen.
  - The existing `<role>: context at N%` message (default at 60% and 80% of the limit) now arrives before the
    CLI compacts, not after.

## Upgrading from v1.23.0

Installing v1.24.0 changes nothing in a project that is already running.

- **A project that already has agent state and no `store` file stays on Beads.** Its tasks,
  messages and notes are where they were, and `bd` keeps working underneath the `teamctl`
  verbs. A project with nothing on disk yet, one you start for the first time, is native.
- **To see which a project uses**, run `teamctl store` in it: `store: native (<file>)` or
  `store: beads (<directory>)`, then the open tasks, unread messages and notes it holds. The
  answer is kept in the file `~/.wolfmux/state/<project>/store`. `WOLFMUX_STORE=native|beads`
  decides when that file is absent.
- **To move to the native store**, run `teamctl store native --migrate`: it copies open tasks
  (with their status, assignee and blockers), unread messages and notes into the native file,
  prints how many of each it saw and wrote, and switches; it deletes nothing from Beads. If one
  item cannot be read or written it names it, exits 1 and does not switch; run it again once
  fixed (nothing already copied is copied twice). `teamctl store native` alone switches without copying;
  `teamctl store beads` switches back (it needs `bd` and a Beads workspace in the project).
  Switching is the lead's, or yours from a plain shell: any other agent is refused (exit 77),
  while `teamctl store` with no argument stays open to everyone. A switch without `--migrate`
  says how many open tasks and unread messages stay behind in the store it leaves.
  After either switch, restart the agents (`teamctl restart <role> --continue`): one that
  started before it was taught the other store's commands.
- **What an agent's `bd` commands become** on a native store, where `bd` does not see the work:
  `bd list --assignee <me> …` is `teamctl mail` (it also marks messages read), `bd show <id>`
  is `teamctl show <id>`, `bd create "…" -t message -a <role>` is `teamctl send <role> "…"`,
  `bd create "…" -t task -a <role>` is `teamctl task <role> "…"`, `bd update <id> --claim` is
  `teamctl claim`, `bd close <id> -r "…"` is `teamctl done "…"`, `bd update <id> --status
  blocked` is `teamctl blocked "…"`, `bd ready` is `teamctl tasks`, and a comment is
  `teamctl note <id> "…"`. The same verbs work on a Beads project, so nothing about them
  depends on the backend.
- **Two commands keep v1.23.0's meaning:** `teamctl inbox` (alias `notices`) is still the pane
  notices filed for a role, and `teamctl memory` is still the lead's private memory. The
  mail reader is `teamctl mail`; the store line's shared notes are `teamctl remember`,
  `memories`, `forget` and `checkpoint`.

## A complete session

```bash
cd ~/code/shop
teamctl start                    # a new lead runs Opus; or name a model: teamctl start astra
```

You are now attached to a tmux session with one pane, the Opus lead. Tell the
lead what you want, for example *"Add password reset. Backend and frontend in
parallel, QA afterwards."* The lead then works like this (you can type the same
commands yourself at any time):

```bash
# 1. plan: tasks with owners, acceptance criteria and dependencies
teamctl task backend "Reset API: POST /reset, POST /reset/confirm" -p 1 --body-file api-spec.md
teamctl task frontend "Reset screens" -p 1 -d "Two screens, contract in the API task"
teamctl task qa "E2E: reset flow" -p 2 -d "Happy path + expired token" --after <api-task> --after <ui-task>

# 2. staff: one pane, branch and worktree each
teamctl spawn backend glm53
teamctl spawn frontend glm53
teamctl spawn qa flash
```

Each worker boots, reads its inbox, claims its task and starts. They coordinate
directly:

```bash
# in the frontend pane
teamctl send backend "Need expires_at in the confirm response" "ISO-8601, UTC"
# backend's pane shows the message itself, at its next tool call — no extra command needed
```

When a worker finishes it commits, reports and closes:

```bash
git commit -am "feat: password reset API"
teamctl done <api-task> "Reset API" --tests "pytest: 38 passed"   # closes it, then a Done: message to the lead
```

The lead is notified, reviews and integrates:

```bash
teamctl status                       # who is running, commits ahead, dirty files
teamctl diff backend --stat          # then: teamctl diff backend
git cherry-pick 4f2a9c1              # in the project root — only the lead does this
teamctl send backend "Changes requested: rate-limit /reset"   # or this
```

End of day:

```bash
teamctl destroy                      # stops the panes; branches, commits and Beads stay
teamctl destroy --worktrees          # later: drops clean worktrees and fully merged branches teamctl created
```

## Several teams in one project

![Several teams in one project: own session, lead and worktrees each; one Beads for all](diagrams/teams.svg)

```bash
teamctl start astra                       # the first team ("default")
teamctl start --team review               # a second one, named by you, in its own tmux session; defaults to Opus
teamctl spawn fe-check sonnet --team review
teamctl status                            # every team: TEAM, its 🐺 lead, its 🐶 teammates
teamctl teams                             # the short list
teamctl attach --team review              # each team opens in its own terminal tab
teamctl destroy --team review --worktrees
```

| Rule | |
|------|---|
| naming | lowercase letters, digits, `-`, 50 characters at most; `--team <name>` may stand before or after the command |
| which team a command means | inside a pane: the agent's own team. At your terminal: the only team there is; with several, the command lists them and asks (`status` and `teams` show all) |
| `teamctl start <model>` without `--team` | the first team. If that is running under another model it is not opened for you; you are shown `teamctl attach` and `teamctl start <model> --team <name>` |
| roles | per team: two teams can each have a `backend`. Branches are `ai/<team>/<role>-…` by default, worktrees live under `…/teams/<team>/` |
| Beads | all teams share the project's Beads. The first team's agents are `lead`, `backend`, …; a named team's are `review.lead`, `review.backend`. Hand work across teams with `-a review.lead` |
| management | a lead manages its own team only; you manage all |
| your checkout | teammates are apart in worktrees, leads are not: every lead works in your checkout, on the branch that is checked out there. Let one lead integrate at a time |

## Branch names that fit your repository

A worker's branch name comes from the team's **branch template**. The built-in one produces
exactly the names wolfmux has always produced (`ai/<role>-<ts>`, `ai/<team>/<role>-<ts>`), so
a project that never touches this sees no change.

Set it when your repository enforces a shape, for example a ticket key in every branch name.
Without it every worker commit fails that rule and workers reach for the project's skip switch:

```bash
teamctl policy branch-template 'feature-{ticket}-{role}-{ts}'
teamctl start fable --ticket AFD-1844          # the whole team's default ticket key
teamctl spawn sam glm53                        # feature-AFD-1844-sam-20260923-112233
teamctl spawn kim glm53 --ticket AFD-1902      # this worker's own key wins
teamctl spawn one glm53 --branch release-hotfix-one   # or name the branch outright
teamctl policy branch-template default         # back to the built-in shape
teamctl policy                                 # shows the team's current template
```

| Placeholder | Is |
|-------------|-----|
| `{team}` | the team's name |
| `{role}` | the worker's role |
| `{ts}` | the timestamp, `20260923-112233`. **Required in every template** |
| `{ticket}` | the key from `--ticket`, or the team's default from `teamctl start --ticket` |

Rules worth knowing:

- `{ts}` is what keeps two workers of the same role on two branches, so a template without it
  is refused (exit 64), and so is an unknown placeholder.
- A template with `{ticket}` and a spawn that has no ticket key is refused, naming `--ticket`.
  It never guesses a name, because a wrong name is what the setting exists to prevent.
- `--branch <name>` skips the template and uses that name; git decides whether it is a legal
  branch name, and a branch that already exists is refused: wolfmux never adopts a branch it
  did not create, because `teamctl remove` deletes a worker's branch.
- teamctl deletes a worker's branch only when teamctl created it, whatever it is called. A
  branch it did not create is named in the output and left alone.
- `WOLFMUX_BRANCH_TEMPLATE` in `~/.config/wolfmux/config` is the default for every team.

## A worker in another repository

Work that spans repositories does not need the guard switched off. A spawn can put a worker's
worktree and branch in another git repository:

```bash
teamctl spawn srv glm53 --repo ../fanpro-studio-server
teamctl spawn srv glm53 --repo ../fanpro-studio-server --base release/2026-09
```

What that changes, and what it does not:

| | |
|---|---|
| worktree | `~/.wolfmux/worktrees/<that repository>/teams/<team>/<role>-<stamp>` |
| branch | created in **that** repository, from its `HEAD` or the `--base` you name, resolved there |
| isolation | stays **on**. The worker may change only its own worktree; your project's checkout *and* that repository's own checkout are read-only for it |
| status | a `REPO` column appears (only while some worker has one), and `--json` carries `repo` |
| diff, worktrees, remove, destroy | all run git in that worker's repository, so what wolfmux made there is what wolfmux removes there |
| team, Beads, lead, policy, panes | unchanged: it is an ordinary teammate of this team, and its inbox is this project's Beads |

Not covered, on purpose: switching isolation off for one worker, an allow-list of extra
writable paths, and founding a whole team in another repository. A team still belongs to
one project; only a worker's worktree moves.

## Disk: what a lane costs, and how it is given back

One lane worktree on this project carried 2.3 GB of `node_modules`, 0.9 GB of `.next` and
half a gigabyte of copied assets. Nothing used to remove any of it: not stopping the lane,
not parking it for a week. 27 parked lanes of one project reached 65 GB, `~/.wolfmux`
reached 102 GB, and the machine filled its disk and rebooted three times with every team's
work in flight. So teamctl cleans up after its own worktrees.

```bash
teamctl status                       # free disk, and what this team's lanes take
teamctl teams                        # measures it, team by team (a du per lane)
teamctl prune --dry-run              # what the parked lanes hold, deleting nothing
teamctl prune                        # take it
teamctl prune --keep-node-modules    # build caches only, so a restart stays cheap
teamctl prune --all-teams --dry-run  # the whole machine: every team of every project
teamctl keep <role>                  # never sweep that lane automatically
teamctl keep                         # which lanes are protected right now
teamctl bar --explain                # every field of the status bar, "held" included
```

Who takes what:

| Command | Takes |
|---------|-------|
| `teamctl stop <role>` | the whole list, `node_modules` included: parking a lane sweeps it (policy `auto-prune`, on by default). With `teamctl policy auto-prune off` it takes `.next`, `dist`, `.turbo`, `build`, `coverage`, `.cache`, `.parcel-cache`, `.vite`, `.svelte-kit`, `.nuxt`, `target` and keeps `node_modules`, which is what it did up to v1.16.1 |
| `teamctl prune` | the same list **and** `node_modules`, for every parked lane. A parked lane is what hoards |
| `teamctl prune --all-teams` | every team of every project on this machine, a total per team and one for the machine. **Yours alone to run**, from a terminal with no `TEAM_ROLE`: a lead has no standing outside its own team and is refused with exit 77 |
| `teamctl reclaim` | the **whole lane** — worktree, branch and record — of every parked lane that is finished, and nothing of a lane that is not ([a finished lane](#a-finished-lane-takes-itself-off-the-books)). Parking a lane does this by itself (policy `auto-reclaim`, on by default) |
| `teamctl reclaim --all-teams` | the same for every team of every project on this machine. **Yours alone to run**: exit 77 for a lead. It also finishes a team whose lead ran `teamctl finish` and that nothing holds any more |
| `teamctl finish [--dry-run]` | every finished lane, then the **team itself** — records, state directory, session — once no lane is left and no task of it is open ([a finished team](#a-finished-team-takes-itself-off-the-books)). The lead's (or your) way to say "we are done"; `--dry-run` deletes nothing and anyone may run it |
| `teamctl keep <role>` | nothing — that is the point. The lane is never swept or reclaimed automatically, and `prune` and `reclaim` honour it too |
| `teamctl destroy` (no `--worktrees`) | the build output of every lane, because ending the session parks all of them — and the whole of every lane that is finished, for the same reason |
| `teamctl remove <role>`, `teamctl destroy --worktrees` | all of it; the worktree is going away anyway. A `remove` that **refuses** — because the lane holds commits or files a person wrote — changes nothing at all: "nothing was removed" means the build output is still there too |

Five rules hold for every one of those deletions, and they are in one place
(`config/wolfmux/lib/disk.sh`):

1. only a name on that one list — a directory a build command makes again from the sources;
2. never a path git tracks in that worktree, whatever it is called (a project that commits
   its `dist` keeps it);
3. never a worktree with uncommitted changes to tracked files, or untracked files that are
   not themselves build output: it is skipped, and the skip is printed with the reason;
4. never a running lane, never a checkout of yours, and only inside a worktree wolfmux made
   for that lane's own repository and team — a lane spawned with `--repo` is checked against
   that repository's worktree directory, not this project's. Every path is resolved with
   `pwd -P` and checked against that prefix, so an edited record or a symlink leading out
   cannot aim a deletion elsewhere;
5. `--dry-run` prints the same report and deletes nothing.

A lane that lost its `node_modules` still has every source file and all of its git state;
it needs one `npm install` (or whatever the project installs with) before its tools run
again. Each directory is renamed inside its own worktree before it is deleted, and a rename
is one atomic step, so a cleanup killed halfway leaves a `.wolfmux-removing-*` directory
that the next run clears — never a `node_modules` that is half there and looks installed.

**What prune cannot reach.** Most of a lane is usually not build output. Measured on one
machine: of 25 GB across 38 lane worktrees, about 4 GB sat in a directory on the list; the
rest was files git tracks, because the whole checkout is copied into every lane (one project
copies 530 MB of `public/`, about 0.65 GB per lane before anything is installed). `prune`'s
"still held" line is that floor plus the whole of every lane it skipped or left running —
those are the expensive ones, because they keep their `node_modules` too. What git tracks
comes back only with `teamctl remove <role>`; a lane left running is swept by the next prune
once it is parked.

**Parking a lane sweeps it (v1.17.0).** Up to v1.16.1 `stop` kept `node_modules` so that
`restart` would be cheap, and `prune` was there for the rest — and nobody ran `prune`:
90.3 GB sat under `~/.wolfmux/worktrees` on this machine, 50.9 GB of it build output
(measured 2026-10-13). So the sweep now happens when the lane is parked, by `teamctl stop`
and by a plain `teamctl destroy`. Three ways to keep a lane's build output anyway:
`teamctl keep <role>` for one lane for good, `teamctl policy auto-prune off` for the team
(exactly v1.16.1's behaviour), or `WOLFMUX_AUTO_PRUNE=off` in `~/.config/wolfmux/config` as
the machine's default.

`teamctl keep` is a verb rather than a flag on `spawn` because you learn that a checkout is
expensive — a 40-minute install, a downloaded model, a seeded database — only after it has
been built, and a spawn flag cannot be taken back. `teamctl status --json` reports
`keep_build` per agent, and `teamctl keep` with no role lists what is protected, so a flag
nobody can see cannot quietly hoard. `teamctl remove <role>` is still how a protected lane goes.

**A lane mid-build is never swept.** A build runs in whatever shell started it, not in the
lane's pane, so `stop` cannot see it — and taking `node_modules` from under a running build
is the one way this could do real damage. The signal is the lock this machine's heavy runs
already hold: `lockf -k ~/.wolfmux/machine-heavy.lock <command>`. The file merely existing is
not a lock, so the sweep tries to take the lock for an instant, which is the only thing that
answers; while it is held the lane keeps its build output and the reason is printed. The
probe is read-only (`lockf -k -s -n -t 0`): it neither creates the file when it is absent nor
deletes it afterwards, so looking at the lock never changes it.

**Take that lock with `teamctl heavy`, not with `lockf` by hand.**

```bash
teamctl heavy tests/smoke.sh                 # holds the lock, says what it waited for
teamctl heavy --timeout 600 npm test         # or give up after ten minutes (exit 75)
```

It returns the command's own exit status, so it drops into a gate script where the bare
command stood. The reason it exists rather than a documented flag is the next paragraph.

**The warning about that lock, which is the convention's and not this tool's.** `lockf`
DELETES the file when its command ends unless `-k` is given, while the lock itself lives on
the inode. So a single holder without `-k` unlinks the file on exit and splits the path from
the locked inode: the holder still running keeps a lock nobody can see, and every later
holder and probe takes a fresh inode and believes it is alone. Mutual exclusion is gone for
every lane at once, with nothing printed. Measured on this machine on 2026-10-13 with `lsof`:
a live holder had inode 240542083 open, the path resolved to 240709857, and a `-t 0` probe of
the path returned "free". **Write every heavy run as `lockf -k`**; no probe can recover the
lock once the file has been unlinked under it, and `lockf`'s own manual recommends `-k` for
exactly this.

**The ledger.** Every sweep is appended to `~/.wolfmux/state/reclaimed.jsonl`, machine-wide:
one JSON object per line with the time, the project, the team, the lane, the kilobytes, the
trigger (`stop`, `destroy`, `prune`) and the directory names it took.

```bash
jq -r '"\(.ts) \(.team)/\(.role) \(.freed_kb) KB \(.trigger)"' ~/.wolfmux/state/reclaimed.jsonl | tail
```

A lane that was taken off the books is a line in the same file, marked
`"event": "lane-removed"`. It carries what a sweep line carries, and what you need to get
the lane back: `branch`, `tip` (the full sha that branch was at), `reason` (why it was
allowed to go), `proof` (`ref`, `how` and `sha`: the commit that shows its content is in
main), `main_pushed`, `workdir` and `session`. The trigger is the command that took it:
`stop`, `destroy`, `reclaim`, `remove`, `destroy-worktrees` or `purge`.

The line is written **before** anything is deleted, so that no removal can happen without
a record. One thing follows from that order: when git then refuses the worktree (a locked
one, or one that holds populated submodules — the reclaim never passes `--force`), the lane
stays whole and a second line says so, `"event": "lane-kept"`, with the same `branch` and
`tip` and git's own words as the `reason`. A `lane-removed` line with a later `lane-kept`
for the same tip is a lane that is still there.

```bash
# every lane teamctl ever removed here, and the command that brings each one back
jq -r 'select(.event == "lane-removed") | "\(.ts) \(.team)/\(.role) \(.trigger): git branch \(.branch) \(.tip)"' ~/.wolfmux/state/reclaimed.jsonl
```

### A finished lane takes itself off the books

The sweep gives back build output. The checkout itself is the bigger half of a lane —
33.3 GB of the 52.6 GB left under `~/.wolfmux/worktrees` after a full sweep, measured
2026-10-13 — and until v1.17.0 only `teamctl remove <role>` gave that back, by hand.

Now a parked lane that is **finished** goes by itself: its worktree, its branch and its
record. It is asked when a lane is parked — `teamctl stop <role>`, or a plain
`teamctl destroy` — and every other parked lane of the team is asked again at the same
moment. Integration is a plain `git merge` in your checkout, which teamctl never sees, so a
lane that was parked before its merge goes the next time any lane is parked, without
anybody remembering it. `teamctl reclaim` asks by hand, and `teamctl reclaim --dry-run`
shows the answer for every lane without deleting anything.

Parking comes first and does not depend on the answer. When the check after it fails, or
cannot finish — the team's lock stays held by another `teamctl` for 30 seconds, say —
`teamctl stop` still ends with `stopped: <role>` and exits 0, with the error printed above
that line. A plain `teamctl destroy` does the same. And `teamctl reclaim` does not report a
removal that worked as a failure because its bookkeeping afterwards (the remembered disk
numbers) could not be written.

A lane goes only when **all** of these hold. They are asked in this order, cheapest first
and the network last, and **a check that cannot be answered keeps the lane**:

1. **It is parked.** A running lane is never asked anything more, and neither is one whose
   state cannot be told.
2. **`teamctl keep` does not protect it.**
3. **Nothing is uncommitted.** No change to a tracked file, and no untracked file that is not
   build output. A file your `.gitignore` ignores is not work to git and does not count; it
   goes with the worktree, as it does with `teamctl remove`.
4. **The worktree's HEAD is the tip of the lane's branch.** A detached HEAD, or another
   branch checked out there, holds commits no branch name leads back to once the worktree is
   gone. That is how three commits were lost here on 2026-10-13.
5. **The branch's content is in main**, or in `origin/main`, or in the branch the lane was
   cut from, or in the branch checked out in your repository (where a lead integrates).
   Three ways count: *merged* (the tip is an ancestor), *cherry-picked* (`git cherry` finds
   an equal patch for every commit) and *squashed* (see below).
6. **No stash entry was made on the lane's branch.**
7. **Beads says its work is done**: under the lane's own name there (`<team>.<role>`), there
   is no task that is not closed and at least one that is. A lane with no task at all has no
   answer to "is it finished", so it stays. Unread messages are not tasks. Beads is asked
   once per run for the whole project, not once per lane, and gets 45 seconds to answer.
8. **No pull request is open on its branch**: `gh pr list --head <branch> --state open`
   comes back empty. No `gh`, a `gh` that fails, or one that does not answer within 45
   seconds: the lane stays.

The 45 seconds are a measurement: on 2026-10-14, with a load average of 18.8 on this machine,
the same `bd list` took 24 s, 33 s, 4 s and 4 s within five minutes, and one question for the
whole project (1,377 beads) took 12 s. A question that is not answered in time is "cannot
tell", the lane stays, and the next check asks again.

A lane that stays is not silent. `teamctl status` prints what it holds and why under its
row, from what the last check wrote into the lane's record:

```
    ⤷ sam   GLM-5.3   stopped   -   skip   lead   ai/review/sam-20261013-101500   3   0   41k 20%   ~/.wolfmux/worktrees/…/sam-…
        holding 1.9 GB: unmerged at 6c3143f
```

| The reason | What it means, and what lets the lane go |
|------------|-------------------------------------------|
| `unpushed at <sha>` | commits that are in no target and on no remote: they exist on this disk only. Merge the branch, or push it |
| `unmerged at <sha>` | the same, but the tip is on a remote, so it could be fetched back. Merge it |
| `dirty: N uncommitted files` | commit or discard them in that worktree (`teamctl diff <role> --working`) |
| `its worktree is at <sha>, which is not the tip of its branch` | the lane holds commits on no branch. Put a branch on that sha, or check the lane's own branch out again |
| `N stash entries on its branch, newest <sha>` | apply or drop them (`git stash list`) |
| `task open (<id>)` | close the task in Beads |
| `no task bead on record` | this lane was never given a task, so nothing says it is finished: `teamctl remove <role>` |
| `open PR #<n>` | merge or close the pull request |
| `cannot ask Beads (…)` · `cannot ask GitHub (…)` | the tool is missing, failed, or did not answer in time. The next check asks again |
| `teamctl keep protects this lane` | `teamctl keep <role> off` |
| `nothing is in the way: …` | policy `auto-reclaim` is off: `teamctl reclaim` takes it |

Status asks nothing itself — no `du`, no Beads, no GitHub — so the line can be older than the
lane; it says `checked 3 h ago` once it is more than ten minutes old. `teamctl reclaim
--dry-run` asks again, and a lane parked before v1.17.0 says `not checked yet` until
something does.

**A squash, and where it stops being seen.** `git cherry` compares commit by commit, so three
commits squashed into one read as three commits that are nowhere: measured on git 2.50.1,
`git cherry main <branch>` prints three `+` lines, and a containment test
(`git branch --contains`) says the same. So teamctl builds one throwaway commit that holds
the branch's whole diff (`git commit-tree`, on the merge base) and asks `git cherry` about
that; the commit in main it is equal to is the proof, and it is what the ledger records.
The throwaway commit is an unreachable object in your repository and goes with `git gc`.
**The known limit:** if main changed a line right next to one of the branch's hunks before
the squash, the two patches differ in their context, their patch ids differ, and nothing
matches. That lane is **kept**, as `unmerged`. It errs toward disk and never toward work,
and `teamctl remove <role>` is how it goes. The same holds for a lane that merged main into
itself: `git cherry` skips merge commits, so such a lane is only ever judged as a whole.

**The stash, and why it keeps a lane.** Not because it would be lost: a stash does **not**
die with its worktree. `refs/stash` lives in the repository's common git directory and is
one list for every worktree — measured on git 2.50.1: `git stash list` gave the same entries
in a lane and in the main checkout, and after `git worktree remove --force` and
`git branch -D` of the lane its entry was still listed and its commit was still there.
Nothing is lost either way. The lane is kept because a stash made on its branch is work the
"content in main" gate cannot see (a stash is not a commit on the branch), and because once
the branch is deleted the entry reads `On ai/x/sam` for a branch that no longer exists, in a
list nobody looks at. Apply or drop the entry and the next check lets the lane go. An entry
made on a detached HEAD says `(no branch)` and belongs to no lane; it keeps none, and
`teamctl reclaim --dry-run` names it once per repository so that somebody who is missing
something has a place to look.

**Main that is not pushed.** Content that is only in a local main still counts as "in main":
teamctl never deletes main, so it is not at the risk a lane is, and requiring a push would
block reclaim on a repository somebody keeps local on purpose. The line and the ledger say
so (`main is not pushed`, `"main_pushed": false`), so the record does not imply a safety
that is not there.

**Before a branch goes, where it was is said.** `sam: branch ai/review/sam-… was at <full
sha>`, on the screen and in the ledger, before anything is deleted — by `reclaim`, by
`remove`, by `destroy --worktrees` and by `destroy --purge`. A removed lane comes back with
`git branch <name> <sha>` for as long as git keeps the unreachable commits (two weeks by
default). The removal itself never passes `--force` to git and never falls back to `rm -rf`:
a worktree git will not remove is a lane that stays.

**What changes for a lead.** `teamctl stop` on a worker whose task is closed and whose work
is merged now removes that lane, record included, so `teamctl restart` on it is gone. That
is the point for a worker that is done, and wrong for one you mean to bring back:

```bash
teamctl keep sam                     # before stopping a worker you will restart or hand over
teamctl policy auto-reclaim off      # this team: nothing is removed unless you run teamctl reclaim
#WOLFMUX_AUTO_RECLAIM=off            # in ~/.config/wolfmux/config: the default for every team
```

The two knobs fall back the same way on a value nobody can read — off — and for this one it
is not a matter of taste: `auto-prune` deletes what a build makes again, `auto-reclaim`
deletes a checkout and a branch, so a typo in the config file must never read as "yes".

**Teams whose lead is gone.** Nobody parks a lane in a team that has ended, so no automatic
path asks its lanes again. `teamctl reclaim --all-teams`, from your own terminal, does:
every team of every project, one line per lane, a total per team and one for the machine.
A lead is refused with exit 77, as with `prune --all-teams`, and for the same reason.

**What `remove` asks about.** It refuses a lane that holds commits your branch does not have
or files somebody wrote, and lists them. Build output is not "files somebody wrote": a
`node_modules` (including the symlink `--link-node-modules` makes), the build caches and
wolfmux's own cleanup trash are swept without a question. `build`, `dist` and `target` are
the exception — when git neither tracks nor ignores one of those, `remove` treats it as work
and asks, because a `dist/deploy.sh` somebody wrote by hand lives exactly there.

**When prune refuses.** If a lane's record says it is running while the team's tmux session
shows no pane for it, prune stops the whole sweep and touches nothing: it sweeps lanes
unattended, and a wrong "parked" would take `node_modules` out from under a running build.
`teamctl status` and `teamctl panes` show which is right; then `teamctl stop <role>` or
`teamctl restart <role>` and run it again.

**The guard.** `teamctl spawn` checks free disk before it makes anything. Under
`disk-min-gb` (default 20) it refuses and names the number; `teamctl policy disk-guard warn`
makes it a warning instead, `off` removes the check, and `teamctl policy disk-min-gb <n>`
moves the limit (`0` = no limit).

**Sharing one node_modules.** `teamctl spawn <role> <model> --link-node-modules` points the
new lane's `node_modules` at its repository's copy instead of letting it install 2+ GB of
its own; `teamctl policy link-node-modules on` does it for every spawn. It is off by default
for a reason: that is ONE directory for every lane and for the checkout itself, so an
`npm install` in any lane changes the dependencies of all of them, and two lanes that need
different versions of a package cannot both be right. Only a brand-new worktree is linked;
`--from-worktree` hands over a lane that already has the dependencies it installed, and a
handover is not asked to clear the free-disk bar either, because it installs nothing.

**Why `teamctl status` never measures.** A `du` over one lane's `node_modules` walks tens of
thousands of files, and over 27 lanes it takes seconds. `status` runs every few minutes, so
it only reads the number that the last command to change the lanes left behind (and says
"not measured" when there is none). `teamctl teams` is the command that measures.

### A finished team takes itself off the books

`teamctl finish` is how a lead says the team is done. In order:

1. It writes down that the team was finished, and by whom (`lead-end.json` in the team's state).
2. It parks every lane and asks each one the gates of `teamctl reclaim`. Every lane that passes
   goes, whatever policy `auto-reclaim` says; `teamctl keep` still protects a lane.
3. It asks Beads for every task of the team: anything assigned to `<team>.<role>`, whether that
   role is still on record or not. A message is not a task.
4. No lane left and no task open: the team goes — its records, its state directory and its
   session — and one `team-destroyed` line goes into `~/.wolfmux/state/reclaimed.jsonl`, with
   the lead's conversation id. Transcripts are never deleted.
5. Something still holds it: the session ends all the same and the team stays, with the reason.
   The next `teamctl reclaim --all-teams` finishes it once nothing holds it.

Killing its own session is the very last thing `finish` does, so a lead can run it from its
own pane: nothing is left half done when the pane closes. What it said is also in
`~/.wolfmux/state/finish.log`.

**Only `finish` ever takes a team.** A lead that is not running proves nothing: a crashed lead
and a finished one look the same from outside. `teamctl stop lead` and a plain `teamctl destroy`
write down how the lead's session ended, but only so that `teamctl teams` can say it. Two
teams of this machine, as they read on 2026-10-14 (the first one's lead had parked itself with
a note to restart from, which is exactly why a stopped lead never counts as finished):

```
nudge-fix is orphaned: its lead is not running. May act on it: you. Bring it back: … · finish it: teamctl finish --team nudge-fix · delete it: …
  holding 0 KB: lead stopped itself 2026-10-13 10:34Z, 1 task open: fanpro-studio-fe-06ls0, 0 lanes held
onboarding-storage is orphaned: its lead is not running. May act on it: you. …
  holding 136 MB: no record of how the lead ended (crash, kill or reboot), 0 tasks open, 2 lanes held: sam-the-backend-guy (unpushed at 8fa6b5be); riley-the-reviewer (unpushed at f1f80681)
```

The status bar shows `orph N` when any team is orphaned (the gigabytes are already in `held`),
and the dashboard shows `orphaned teams: N holding X`.

## Deleting a team, and what a team costs

| What | Disk |
|------|------|
| each worker | a checkout of your tracked files, plus whatever it installs or builds inside (`node_modules`, `.venv`, build output). `.git` is shared, never copied |
| the lead | nothing: it works in your own checkout |
| teamctl's records | a few KB per team |
| the agents' Claude Code transcripts | some MB, under `~/.claude/projects/` |
| tmux | memory only (scrollback) |

`teamctl teams` shows DISK per team.

```bash
teamctl destroy --team review --purge      # look, ask, then delete the whole team
```

It prints every worker with its size, its uncommitted files and the commits your branch
does not have, and the total it frees, and has touched nothing at that point. If work
would be lost you are asked with that list in front of you; `--force` deletes anyway; with
nobody to ask and no `--force` it refuses and the team keeps running. Gone afterwards:
the session, every worktree, the team's `ai/…` branches, its records, its teammates' Claude
Code transcripts (`--keep-transcripts` keeps those). Never touched: your checkout, other
branches, Beads, other teams, the lead's own conversations (they live in your checkout's
folder under `~/.claude/projects/`), Codex's sessions.

## The dashboard: every team on the machine

`teamctl status` and `teamctl teams` answer for ONE project — the one you are standing in.
When several teams are running at once, across more than one repository, the question is
usually "what is running on this machine, and what is it costing me?". That is
`teamctl dashboard`, and inside a team session `prefix O` opens it as a popup.

```bash
teamctl dashboard                    # the popup's own view: redraws every 5 s, q closes it
teamctl dashboard --once             # print it once and exit
teamctl dashboard --once --full      # also read context and transcript times for stopped lanes
teamctl dashboard --json             # the same facts as JSON
teamctl dashboard --interval 15      # redraw less often
```

It walks every project with state under `~/.wolfmux/state/`, every team of each, and every
agent of each team:

```
🐺 WOLFMUX DASHBOARD   2026-10-10T08:18:40Z
 2 projects · 20 teams (13 orphaned) · 75 agents: 12 running · 63 stopped · 0 exited

PROJECT fanpro-studio-fe-099f81   ~/Documents/fpro/fanpro-studio-fe
  TEAM nudge-fix            running      lead Opus 5.5     agents 1    lanes 4.2 GB
      🐺 lead             Opus 5.5       running  cpu 2.4    mem 0.5G    ctx 490k 24%   wrote 2s     -
  TEAM onboarding           running      lead Fable 5.2    agents 25   lanes not measured (teamctl teams measures it)
      🐶 walk2            Opus 5.5       running  cpu 0.0    mem 0.4G    ctx 192k 19%   wrote 14m    ai/onboarding/walk2-…

MACHINE  load 2.9 · memory 8.1 GB free · disk 109.4 GB free
```

**It is read-only.** It stops nothing, starts nothing and deletes nothing. You look, then
you use the commands that act.

What the columns actually mean, because two of them are easy to over-read:

- **cpu / mem** — that agent's whole process tree, not just its pane's shell (an agent's
  CLI is a child of that shell, so the shell on its own tells you nothing). It is a
  process reading, not a claim about what the agent is doing.
- **wrote** — when the agent's own transcript file was last written. A file timestamp,
  nothing more. It does move on every turn an agent takes, which makes it the closest
  honest answer to "is this one still going", and it is why there is no "idle" column:
  tmux cannot tell a waiting agent from a working one, and terminal output is never parsed
  for state.
- **ctx** — what the conversation holds, from the same reader `teamctl status` uses. When
  the model's window cannot be known you get the token count and no percentage, never a
  made-up one.
- **lanes** — the lane total `teamctl teams` last measured. The dashboard never measures
  it: a `du` over a busy machine's lanes takes seconds, and this view redraws. When the
  number is older than fifteen minutes it is shown as `STALE`, with its age, and
  `teamctl teams` is named as the command that refreshes it.

By default the two per-agent file reads — context and `wrote` — are taken only for agents
that are RUNNING, which is what keeps a walk of a whole machine inside about a second.
`--full` reads them for every agent on record.

A project whose state cannot be read is named rather than silently dropped, and so is one
that holds nothing at all (an abandoned `teamctl start`). One bad project never takes the
view down.

### The segment in the status bar

`status-right` carries the same picture in one line, driven by `teamctl _overview-badge`:

```
teams 20 run 12 idle 63 load 2.92 mem 8G disk 109G held 9.2G
```

Every field carries its name in front of its number, and `teamctl bar --explain` is the
legend — a terminal has no hover, so the legend is a command:

| Field | Means |
|-------|-------|
| `teams` | teams on this machine, across every project |
| `run` | agent panes alive right now |
| `idle` | agents on record with no pane: parked, and restartable |
| `exit` | panes whose agent exited. Only there when there are any |
| `load` | the machine's one-minute load average |
| `mem` | memory a process could still get (free plus inactive) |
| `disk` | free space on the disk that holds `~/.wolfmux` |
| `held` | what the **parked** lanes of every team hold: the space `prune` and `remove` give back. `-` when no team has been measured yet |

`held` is read from what `teamctl teams` last measured and is never measured here — a `du`
over this machine's lanes is about twelve seconds. An old number is used on purpose, and
that is the difference from the free-disk and memory fields beside it: a parked lane is one
in which nothing is running, so its size does not change by itself. What it cannot know is a
lane parked or removed since; `teamctl teams` makes it current and
`teamctl prune --all-teams --dry-run` says where the space is.

Before v1.17.0 the line read `20t 12run 63stop ld2.92 mem8G dsk109G`, which nobody could
read at a glance, and it had no `held` field at all. The budget is 72 characters and the
alphabet is `A-Za-z0-9`, space and `. : / + -`: `cmd_overview_badge` strips everything else
**silently**, so a middle dot or a pipe between the fields would vanish without a trace. The
labels do the separating instead, and the line above is 60 characters.

It redraws every few seconds for every attached client, so it opens no transcript, runs no
`ps` and runs no `du`; it costs about 18 ms of work. If anything at all goes wrong it prints
nothing: a status bar keeps whatever it is given until the server restarts, so a broken badge
would be worse than no badge.

**It does not appear immediately, and that is normal.** tmux draws the status line *before*
it has run the `#()` command, and fills the result in on a later refresh. So right after you
attach a client, and after a tmux server restart, the segment is **blank for up to
`status-interval` seconds** before it appears. Nothing is wrong and nothing is lost; it is
inherent to the way tmux runs `#()`. Measured on tmux 3.7c: the first rendered draw of a
`#()` segment is empty, the next one carries its output.

## Teams working together

All teams of a project share its Beads, so they can talk: `-a review.lead` reaches the lead
of team review, a plain `-a lead` the first team's. A lead can also found a team and hand
work over, without you relaying anything:

```bash
bd create "Handover: payments" -t message -a next.lead --body-file handover.md    # → id shop-41
teamctl start fable --team next --no-attach --handover shop-41
```

The new lead starts by reading that bead, you get a notification, and the founder does not
manage the new team while that team's lead runs. `teamctl policy lead-teams off` keeps
founding teams to yourself. A lead can never take over a team that already has a lead; a
worker can never found one.

### After a reboot

After a reboot, `teamctl restore [--dry-run] [--yes] [--no-tabs]` brings back the teams
that were running at the last status-bar snapshot. Run it from your own terminal.
It prints the plan and asks once: Enter continues, anything else aborts. `--dry-run`
shows the plan without changes, `--yes` skips the question, and `--no-tabs` skips iTerm2.

Only leads restart. Claude resumes its stored conversation when the transcript exists;
Codex uses `--continue`. A Claude lead with no stored id is skipped, since `--continue`
could open another lead's conversation in the shared folder. The plan and final report
show how to bring it back by hand: `teamctl restart lead --team <name> --resume <session-id>`.
An id with no transcript is reported and starts fresh under that same id.
Leads already up, teams ended deliberately since the snapshot, and removed
teams are skipped. An orphan absent from the snapshot stays down. Running restore again
after an interruption skips the leads already back.

Restarts happen one at a time, waiting for the session record or 90 seconds with a live
pane. Under 25% free memory or load over 20, restore waits up to ten minutes and reports
teams it could not start. Each restored lead gets a Beads message and one nudge. Tabs
open afterward in the saved order, skipping sessions already attached. If iTerm2 is not
running or Automation fails, the report prints attach commands to run yourself.

The status bar saves `~/.wolfmux/state/running.json` at most once a minute while a client
is attached. After a server change it keeps the previous view in `running.prev.json`,
so attaching one team after a crash does not erase the other teams. Restore records its
actions in `~/.wolfmux/state/restore.log` and each team's event log. The orphan steward
may restore only human-founded teams in its own project; restart also writes its steward
ledger. Other agents get exit 77, but anyone may use `--dry-run`.

`teamctl policy restore-on-limit report` is the default: a usage limit in a newly restored
lead's transcript is reported. `teamctl policy restore-on-limit opus` asks for one restart
on that model with the same conversation. `WOLFMUX_RESTORE_ON_LIMIT` supplies the global
default. Restore installs no login item; you choose when to run it.

### When the lead of a founded team is gone

A founded team whose lead died (a session restart, a reboot, a lead that is finished) has
nobody to manage it. `teamctl teams` marks it `orphaned` and says who may act on it: you,
and the lead that founded it. The founder does not need you for this:

```bash
teamctl teams                                            # review: orphaned; may act: you, lead (its founder)
teamctl restart lead --team review --continue            # bring the lead back in its last conversation
teamctl stop lead --team review                          # or park it
teamctl remove tidy --team review --force --yes          # take a stopped teammate off the books
teamctl destroy --team review --purge --force            # or delete the whole team
```

That is `restart`, `model`, `stop`, `remove` and `destroy` in every form, and `teamctl start <model>
--team review --continue`; never `policy`, `approve` or `deny`. It holds only while the
team's lead is not running (its pane exited or is gone, or there is no tmux session at all);
while that lead runs, the founder is refused (exit 77) and told so. Every time the founder
acts you get a notification, and the event log records it with the founder's Beads name
(`by`). Another team's lead and any worker stay refused. A team you started yourself has no
founder but you. A restart without a session keeps the founder, the handover and the
creation time in the lead's record, so the founder keeps its authority after one.

**The orphan steward.** A team you started has no founding lead, so no agent may bring it
back. You can name one team that may, once, from your own terminal:

```bash
teamctl policy orphan-steward communication-management    # or WOLFMUX_ORPHAN_STEWARD in the config file; off ends it
```

Its lead, and nobody else in that team, may then run `teamctl restart lead --team <name>`
(also `--continue` and `--resume <id>`), `teamctl model lead <model> --team <name>`, and
`teamctl stop <role> --team <name>` on a team you
founded whose lead is not running. Nothing else: not `remove`, `destroy`, `start`, `policy`,
`approve`, `deny` or `spawn`, and nothing on a team another lead founded. Each act is written
to `~/.wolfmux/state/<project>/steward.jsonl` before it happens (no line, no act), you get a
notification, and the event log names the steward. An agent cannot set the key (exit 77); a
name that is not a team of the project is refused. `teamctl teams` then names it beside you:
`may act: you, communication-management.lead (steward)`. In an agent's pane it says "the
human" where it says "you" to you.

## Team memory: one lead's private notes

One team of a project may give its lead a private memory folder. Only the human turns it on:

```bash
teamctl memory enable communication-management   # or: teamctl policy team-memory communication-management
teamctl memory status                            # anyone: which team, sizes, index vs its 25,000-byte cap, the lead's state
                                                 # (the folder's path and the lead's conversation id: the human and that lead only)
teamctl restart lead --team communication-management --resume <its id>   # the lead gets it at its next start
teamctl memory disable                           # the human, or that lead itself: policy off, the folder stays
teamctl memory path                              # the human, or that lead itself: the folder
teamctl memory check                             # the human, or that lead itself: <folder>/bin/mem check
teamctl memory adopt <team>                      # the human only: a team an agent founded becomes the human's
```

The folder is `~/.wolfmux/memory/<project>/<team>/` (mode 700), copied once from the skeleton that
`install.sh` puts in `~/.config/wolfmux/memory-skeleton/`. That team's lead, and nobody else, gets the
three things below, and only while the human founded that team (a team another lead founds under the
same name after a purge or a `finish` gets nothing) and the folder's `bin/mem` can run. A team keeps its
founder through every restart, restore and model change, so `enable` refuses a team an agent founded
instead of promising a memory its lead would never get. `teamctl memory adopt <team>` makes such a team
the human's first: the lead's record and the team's `meta.json` say `operator` from then on, the founding
agent loses what a founder may do while the lead is down, and it is logged in `team-memory.jsonl` and the
team's event log. Then `enable` works:

- the folder as Claude Code's `autoMemoryDirectory`, so its `MEMORY.md` loads at every start;
- a short "Team memory" block at the end of its system prompt: the folder, the rule (private to that
  lead; nothing from it goes into Beads, Jira, Slack, repositories or reports, which carry counts only),
  the shared project memory folder `~/.claude/projects/<project path>/memory/`, and the line "Run
  `<folder>/bin/mem boot` before anything else, and again after every compaction" (the lead is told to
  run it again after every compaction; nothing enforces that in v1.22.0). The card
  (`core/card.md`) is NOT in the prompt: `ps` shows every process's arguments to every other process,
  and `teamctl _prompt` prints a prompt to anyone, so a prompt is not private;
- a first prompt at every launch, fresh, `--continue`, `--resume` and restore alike: run
  `<folder>/bin/mem boot` (it prints the card), re-create the crons it lists, then read the Beads
  inboxes. With a handover, the boot comes first and the handover after it, in the same prompt.

While team memory is on, `start --continue` and `restart --continue` of EVERY lead of the project are
refused while that lead has no stored conversation id, because `claude --continue` would open the newest
conversation in the folder every lead shares: the memory lead could get another lead's conversation, and
any other lead the memory lead's. The refusal names the memory team. With the policy off, a lead with no
id continues as before (the newest-transcript guess, with a warning). That lead's pane shows the card
after a boot, so `teamctl capture` of it is the human's alone (exit 77 for anyone else), also after the
policy moved, for as long as the running lead's settings still carry `autoMemoryDirectory` (until its
restart). `teamctl memory status` stays open to anyone and shows sizes, counts and the policy, never what
a note says; the folder's path and the lead's conversation id only to the human and that lead. `destroy --purge`, `finish` and `install.sh` leave the folder alone; `teamctl destroy --purge
--memory` and `uninstall.sh --purge --purge-memory` delete it. `--memory` is the human's alone (the pane
proof decides: an agent gets exit 77 even when it has a terminal to type the name on), and it also asks
for the team's name. `uninstall.sh --purge-memory` without `--purge` removes nothing (exit 64).

Workers are refused the folder by the worktree guard, and also the folder of the leads' conversations
(`~/.claude/projects/<project path>/`, except its shared `memory/`). A worker's search of a whole tree
that holds either one is refused too: `grep -r x ~`, `find / …`, `du -sh ~`, and a Grep of the whole
`~/.claude` folder. Search a narrower folder instead. Claude Code's own records (`~/.claude/sessions`,
`session-env`, `history.jsonl`, `file-history`, `todos`, `paste-cache`) and its temporary folder
(`/private/tmp/claude-<uid>`, except the worker's own scratchpad) are closed too, so a worker searches its
worktree and its scratchpad, never all of `/tmp`. A worker never resumes a conversation either:
`claude --resume`, `-r`, `--continue`, `-c` or `--session-id` in its Bash text is refused wherever `claude`
is the program (bare, by a path, after `env`, `sudo`, `nice`, `timeout`, `nohup`, `xargs` or `script`, as
`npx @anthropic-ai/claude-code`, inside `sh -c`, `eval` or a heredoc fed to a shell), because the CLI
would read that conversation itself; `claude -p` and `claude --version` pass. The guard reads every tool
call (Bash, Monitor, PowerShell, MCP and any other tool), not only the file tools, and a command over
64 KB is refused ("split this command"). A quoted word that holds a `/` is a path even with a blank in
it, so a commit message that names a private folder by path (`see ~/.wolfmux/memory`) or climbs out of
the worktree (`see ../README.md`) is refused on purpose: rephrase it ("see README.md in the project
root"). Where that guard ends is in
[SECURITY.md](SECURITY.md#team-memory-who-can-read-a-leads-private-folder).

Team memory is built for a Claude lead. A Codex lead has no `autoMemoryDirectory`, so `MEMORY.md` is not
loaded for it, and a resumed Codex lead (`codex resume --last`) opens the newest conversation of the
folder every lead shares and is given no first prompt. `teamctl memory status` warns when the memory
team's lead runs Codex; move it back with `teamctl model lead opus --team <team>`.

## teamctl

| Command | Does |
|---------|------|
| `teamctl start [<model>] [--team <name>] [--no-attach] [--continue] [--resume <session-id>] [--ticket <KEY>] [--init-beads\|--skip-beads] [--lead-permissions …] [--worker-permissions …] [--worker-spawn …]` | create the session and the lead pane; attach. No model named: keep an existing lead's recorded model, or use policy `lead-model` for a new lead (default Opus). Fable only when asked: `teamctl start fable`. `--ticket` sets the team's default ticket key ([branch names](#branch-names-that-fit-your-repository)). Any model can lead (table below). `--team` names a further team; `--continue` resumes the lead's own conversation (the id stored with it), `--resume` reopens the one you name ([which conversation comes back](#finding-the-manager-and-being-told-when-someone-finishes)). With a team already there: see [closing and coming back](#finding-the-manager-and-being-told-when-someone-finishes) |
| `teamctl start <model> --team <new> --handover <bead-id>` | found a fresh team whose lead starts by reading that bead ([teams working together](#teams-working-together)) |
| `teamctl policy [<key> <value>]` | show or change, per team: `lead-permissions` (skip\|ask), `worker-permissions` (skip\|lead\|ask), `browser-writes` (ask\|allow, DEFAULT ask: allow writes an explicit `permissions.allow` rule for `mcp__claude-in-chrome__*` into every agent's settings — lead and workers alike — so a Chrome write resolves before Claude Code's auto-mode classifier runs on it), `worker-spawn` (on\|off), `worker-isolation` (on\|off: the worktree guard), `lead-teams` (on\|off: may the lead found teams), `branch-template` (how workers' branches are named: [branch names](#branch-names-that-fit-your-repository)), `human-pane-typing` (off\|idle, DEFAULT off: never type a notice into a pane you are watching; only you may change it), `lead-wake` (unwatched\|off, DEFAULT unwatched: an idle lead wakes itself for a notice while you are not using its pane; only you may change it: [idle leads](#an-idle-lead-wakes-itself)), `orphan-steward` (a team of the project, or off; DEFAULT off; one value for the whole project: whose lead may restart or stop a team you founded while its lead is not running; only you may change it: [the orphan steward](#when-the-lead-of-a-founded-team-is-gone)), `disk-guard` (refuse\|warn\|off), `disk-min-gb` (a whole number of GB, 0 = no limit), `link-node-modules` (on\|off), `auto-prune` (on\|off, DEFAULT on: sweep a lane's build output as soon as the lane is parked — `teamctl keep <role>` protects one lane), `auto-reclaim` (on\|off, DEFAULT on: take a parked lane off the books by itself once its task is closed and its work is all in main — `teamctl keep <role>` protects one lane; a value that is neither on nor off counts as off: [a finished lane](#a-finished-lane-takes-itself-off-the-books)) |
| `teamctl start <model> [--team <name>] [--no-attach] [--continue] [--resume <session-id>] [--ticket <KEY>] [--init-beads\|--skip-beads] [--lead-permissions …] [--worker-permissions …] [--worker-spawn …]` | create the session and the lead pane; attach. `--ticket` sets the team's default ticket key ([branch names](#branch-names-that-fit-your-repository)). A fresh project's first start creates its store, native by default; `--init-beads` chooses Beads instead, `--skip-beads` skips that question for a project already on the Beads backend ([teamctl store](#mail-tasks-and-memory)). Any model can lead (table below). `--team` names a further team; `--continue` resumes the lead's own conversation (the id stored with it), `--resume` reopens the one you name ([which conversation comes back](#finding-the-manager-and-being-told-when-someone-finishes)). With a team already there: see [closing and coming back](#finding-the-manager-and-being-told-when-someone-finishes) |
| `teamctl start <model> --team <new> --handover <bead-id>` | found a fresh team whose lead starts by reading that bead ([teams working together](#teams-working-together)) |
| `teamctl policy [<key> <value>]` | show or change, per team: `lead-permissions` (skip\|ask), `worker-permissions` (skip\|lead\|ask), `worker-spawn` (on\|off), `worker-isolation` (on\|off: the worktree guard), `worker-context` (full\|trim\|lean: what of `~/.claude` a worker's conversation starts with, default `trim`), `lead-context` (full\|trim: the same reductions for the lead, default `full`), `context-exclude` (globs of instruction files a trimmed agent does not load, default none), `lead-teams` (on\|off: may the lead found teams), `branch-template` (how workers' branches are named: [branch names](#branch-names-that-fit-your-repository)) |
| `teamctl approvals [--all]`, `teamctl approve <id>…\|--all`, `teamctl deny <id> "<reason>"` | the lead decides workers' permission requests (`worker-permissions lead`) |
| `teamctl spawn <role> <model> [--base <ref>] [--branch <name>] [--ticket <KEY>] [--repo <path> \| --from-worktree <role>] [--no-kickoff] [--resume <session-id>] [--link-node-modules]` | new worker: branch + worktree + pane. Any model, whoever leads (table below). Refused when free disk is under `disk-min-gb`. `--branch` / `--ticket`: [branch names](#branch-names-that-fit-your-repository) · `--repo`: [a worker in another repository](#a-worker-in-another-repository). `--from-worktree <role>` starts the fresh worker in a stopped worker's built worktree, on a new branch (the old branch and commits stay): node_modules and build output survive, so install and build are not repeated — **if that lane was protected before it was parked**, because from v1.17.0 `teamctl stop` sweeps a lane's build output. `teamctl keep <role>` before stopping it, and the flag travels with the worktree. Refuses a running worker, and a worktree with uncommitted changes (lists them) (`--repo` does not combine with it: the worktree stays in its own repository). Only the lead, or you, may hand a worktree over; a worker is refused (exit 77) even with worker-spawn on. `--resume <session-id>` puts it into an existing conversation instead of a new one (and sends no kickoff). `--link-node-modules`: a brand-new lane shares its repository's `node_modules` instead of installing its own ([disk](#disk-what-a-lane-costs-and-how-it-is-given-back)) |
| `teamctl stop <role>` | close a pane; worktree, branch and commits stay. Its build output goes, `node_modules` included (policy `auto-prune`, on by default; `off` keeps `node_modules` as before v1.17.0). The one case where the lane itself goes: its task is closed and its work is all in main (policy `auto-reclaim`, on by default; `teamctl keep <role>` first, to keep a worker you mean to restart) |
| `teamctl remove <role>... [--force] [--yes]` | take a stopped worker off the books: worktree, branch, record and the gigabytes they held. Refuses when the worker holds uncommitted files or commits your branch does not have, and lists them; `--force` discards them after one question |
| `teamctl prune [--team <name>] [--all-teams] [--dry-run] [--keep-node-modules]` | the build output of every parked lane of the team, with a total in GB. Running lanes untouched; `--dry-run` deletes nothing; `--keep-node-modules` takes the build caches only; `--all-teams` does every team of every project on this machine and is yours alone to run — a lead is refused with exit 77 ([disk](#disk-what-a-lane-costs-and-how-it-is-given-back)) |
| `teamctl reclaim [--team <name>] [--all-teams] [--dry-run]` | take every finished parked lane of the team off the books: worktree, branch, record. One line per lane, `removed` or `holding` with the reason. `--dry-run` deletes nothing and anyone may run it; `--all-teams` is every team on the machine and yours alone to run (exit 77 for a lead) ([a finished lane](#a-finished-lane-takes-itself-off-the-books)) |
| `teamctl keep [<role> [on\|off]]` | never sweep that lane's build output, and never reclaim the lane, automatically — for a checkout that is expensive to rebuild, or a worker you mean to restart. `prune` and `reclaim` honour it too; with no role it lists what is protected ([disk](#disk-what-a-lane-costs-and-how-it-is-given-back)) |
| `teamctl bar [--explain]` | the one line tmux shows in `status-right`; `--explain` is the legend naming every field of it ([the segment in the status bar](#the-segment-in-the-status-bar)) |
| `teamctl heavy [--timeout <seconds>] [--quiet] <command>...` | run a heavy thing — a test gate, a measurement, a long build — holding the machine's heavy lock, so nothing else heavy runs beside it and no lane is swept while it does. Returns the **command's** exit status, not the wrapper's, and says what it waited for. `--timeout`: give up after that many seconds (exit 75) rather than wait; `--quiet`: say nothing about waiting. One voice about the lock: `lockf`'s own "already locked" line is silenced, the command's own output is not. An exit 75 that is the command's own is reported as the command's, not as the lock timing out. Prefer it to `lockf` by hand ([disk](#disk-what-a-lane-costs-and-how-it-is-given-back)) |
| `teamctl restart <role> [--model <model>] [--continue] [--resume <session-id>]` | same worktree and branch, on its recorded model; `--model` records and uses a different model. `--continue` resumes that agent's own conversation, `--resume` the one you name; both require the same CLI family. Without either it starts a new one |
| `teamctl model <role> <model> [--team <name>] [--now]` | record the model for the next start, restart or restore. `--now` also switches a Claude agent by a resume-restart when it is between turns, has a recorded conversation id, and nobody is at its pane. An unsafe switch waits until the next restart, with a reason printed. Same model keys as `spawn` |
| `teamctl policy lead-model <model>\|default` | only the human may set this project-wide default for new leads. Default Opus, or `WOLFMUX_LEAD_MODEL` when set; `default` returns to that config value. Existing teams keep their lead's model |
| `teamctl memory [status]` · `teamctl memory enable <team>` · `teamctl memory adopt <team>` · `teamctl memory disable` · `teamctl memory path` · `teamctl memory check` | team memory, see [Team memory](#team-memory-one-leads-private-notes). `status` anyone; `enable` the human only (77 for an agent; refused for a team an agent founded); `adopt` the human only (77 for an agent): the team's founder becomes the human, logged; `disable` the human or the memory team's own lead; `path` prints the folder (exit 1 when off) and `check` runs the folder's own `mem check` and passes its exit code: both the human's or the memory team's own lead's only (77 for anyone else; `check` writes the index and prints names) |
| `teamctl policy team-memory <team>\|off` | project-wide, default `off`: the same as `memory enable` / `memory disable` |
| `teamctl nudge <role>\|--all [--id <bead>] [--quiet]` | re-send the one-line notification. `--quiet`: nobody to notify is not an error (what the Beads hook passes). A pane somebody is typing in is never typed into: the notice waits for that pane to go idle and arrives by itself (`deferred: …`, exit 3). Notices that pile up while it waits arrive as one line. Your own lead pane holds a notice back for longer than a worker's: with a client attached it has to have had no keystroke for `WOLFMUX_NUDGE_LEAD_IDLE` (300 s) first. `filed: …` with exit 4 now means only that nothing is ever typed into that pane (`WOLFMUX_NUDGE_TYPE=off` or `workers`) |
| `teamctl inbox [<role>] [--all] [--json] [--keep]` (alias `notices`) | for debugging: the pane notices filed for a role, oldest first. Default: the lead of this team. They are not counted in the status bar (the `📨` number is your unread Beads messages); reading them does not change whether the agent has had them. `--all`: every role of the team. `--json`: one object per notice. `--keep`: print them and leave them marked new ([quiet notices](#quiet-notices-nothing-is-typed-into-your-conversation)) |
| `teamctl status [--json]` (alias `workers`) | team by team: role, model (the one it runs, as `teamctl models` says it; `*` = its last answer names that model and its record does not vouch for it, `?` = nobody can name it), running / exited(N) / stopped, pane, branch, commits ahead, dirty files, CONTEXT (`used/limit share`, e.g. `142k/167k 85%`: tokens in use, the limit its CLI compacts at and the share; tokens alone when the model's window is not known, never a guessed share; read from the transcript of the agent's own conversation; `-` when there is none), plus free disk and what the team's lanes take |
| `teamctl teams [--json]` | the short list per team: state (`running` or `orphaned`), lead, number of agents, the disk its teammates' worktrees take, who founded it, session. This is the command that measures that disk. `--json` and `status --json` carry `founder` and `orphaned`; an orphaned team says who may act on it ([when the lead of a founded team is gone](#when-the-lead-of-a-founded-team-is-gone)) |
| `teamctl dashboard [--json] [--once] [--interval <seconds>] [--full]` | every team on this machine, across every project, read-only; `prefix O` opens it as a popup and `q` closes it. See [The dashboard](#the-dashboard-every-team-on-the-machine). `--once` prints it and exits, `--interval` sets the redraw (default 5 s), `--full` also reads context and the transcript time for agents that are not running, `--socket <path>` asks that tmux server instead of the default |
| `teamctl panes` | tmux's view: command, pid, cwd |
| `teamctl capture <role> [-n\|--lines N] [--all]`, `teamctl log <role>` | recent / full terminal output — for diagnosing a stuck agent, never for task state |
| `teamctl focus <role>`, `teamctl attach` (alias `open`) | move your terminal |
| `teamctl layout [lead-left\|lead-top\|tiled]` | how the panes are arranged, for this team; `lead-left` is the default |
| `teamctl worktrees` | branch, commits ahead, dirty count per worker |
| `teamctl diff <role> [--stat\|--names\|--commits\|--working]` | the worker's changes since its base |
| `teamctl completion <zsh\|bash>` | print the tab-completion script of that shell, so `source <(teamctl completion zsh)` works (bash: `eval "$(teamctl completion bash)"`); `./install.sh` wires it into `~/.zshrc`, and `teamctl <Tab>` then offers commands, options and values (roles, teams, models, policy keys, layouts, approvals, branches) |
| `teamctl destroy [--worktrees] [--yes]` | end the session; never deletes dirty worktrees, unmerged branches, source, credentials or Beads data. A lane whose task is closed and whose work is all in main is reclaimed (policy `auto-reclaim`), and every other lane says what it is holding |
| `teamctl destroy --purge [--force] [--keep-transcripts] [--memory] [--yes]` | `--memory` also deletes the lead's memory folder: the human's alone (the pane proof; 77 for an agent, even with a terminal), after you type the team's name (no `--yes` for that part). `--memory` without `--purge` is a usage error (64). Delete the whole team and free its disk space: reports first, asks, then removes session, worktrees, the branches teamctl created, records and its teammates' Claude Code transcripts ([deleting a team](#deleting-a-team-and-what-a-team-costs)) |
| `teamctl doctor [--probe]` | launcher, credential, settings and login checks; `--probe` also asks each provider whose key is set up whether its endpoint accepts it. Also: which model each running agent started on, and the restart that moves it to a newer one; and the Beads store's mode, size and one call's time, with the compaction command when it is over the limit (run it once a week when doctor says so; wolfmux never runs it) |
| `teamctl models [--json] [--refresh]` | what `fable`, `opus`, `sonnet` and `haiku` mean today (alias, model id, label, where the id came from), and the model each running agent runs, with where that is known from: `record` (its record names it, and no later answer of its says otherwise) or `transcript` (its last answer names it, and its record does not). `status`, `teams` and the dashboard show the same answer. `--refresh` asks Claude Code again now; otherwise it is asked at most once a day per alias, when an agent starts (`WOLFMUX_MODEL_POLICY`) |

Roles are lowercase letters, digits and `-` (max 32). `lead` is reserved.
`start`, `stop`, `restart`, `model`, `remove`, `destroy`, `approve`, `deny` and changing the `policy`
are reserved for the lead of that team and for you; `spawn` too unless `worker-spawn` is on.
A worker gets exit 77. `--team <name>` goes with any command, before or after it.

### Mail, tasks and memory

| Command | Does |
|---------|------|
| `teamctl send <role>\|<team>.<role>\|--all "<subject>" ["<body>"] [--body-file <file>\|-] [--re <bead-id>]` | message an agent, every agent of this team, or reply to a bead; `human` (`WOLFMUX_HUMAN`) reaches the human's inbox (status-bar number, `prefix N`), and a message sent from a shell with no agent identity carries the human's name |
| `teamctl mail [<role>] [--peek] [--json]` | your (or that role's) unread mail and open tasks; `--peek` leaves it unread |
| `teamctl task <role> "<title>" [-d "<text>"\|--body-file <file>\|-] [-p <0-4>] [--after <bead-id>]… [--spawn <model>]` | assign work; `--after` adds a dependency, `--spawn` starts the role if it is not already running |
| `teamctl claim [<id>]` | claim your only open task, or the one you name; refuses one still waiting on an unclosed blocker |
| `teamctl done [<id>] "<summary>" [--tests "<command: result>"] [--body-file <file>] [--allow-dirty]` | close a task, then report it: a `Done:` message to the lead (summary, tests, branch, commit log). Only the task's assignee (or the lead) may; a message id, a closed task and a task still waiting on a blocker are refused |
| `teamctl blocked [<id>] "<why>"` | mark a task blocked and tell the lead why; only the task's assignee (or the lead) may |
| `teamctl tasks [<role>\|--all] [--status <list>] [--json]` | a list of tasks; default is your own team, not closed |
| `teamctl show <id> [--json]` | one task (body, notes, blockers), or a message with its whole thread |
| `teamctl note <id> "<text>"` | a durable note on a task; notifies nobody |
| `teamctl reopen <id> "<why>"` (lead) | send a closed task back: open, the reason noted, the assignee told |
| `teamctl close <id> -r "<reason>" [--failed]` (lead) | close or reject any task of this team |
| `teamctl checkpoint "<text>"\|--body-file <file>\|-\|--show [<role>]` | save where you left off, or print a role's stored checkpoint; shown again at the next `SessionStart` |
| `teamctl run -- <command> [args...]` | runs it; a long output goes to a log and you get its head, tail, failure lines and the path, with the command's own exit code (Codex agents; Claude Code agents get this by hook, policy `output-offload`, on by default) |
| `teamctl remember "<fact>" [--key <slug>]` | add to shared team notes, shown to every agent at session start (a note is at most 1500 characters; one that does not fit the 4000-character block is skipped, the others still show; control characters are removed and a line starting `[wolfmux` is quoted) |
| `teamctl memories [<query>] [--json]` | search shared team notes |
| `teamctl forget <key>` | remove one memory |
| `teamctl store [native\|beads [--migrate]]` | show, or switch, which backend holds this project's tasks, mail and memory; `--migrate` moves a Beads project's open work into the native store |

### Models

| Model key | Runs | Pays with |
|-----------|------|-----------|
| `glm53` · `flash` | Claude Code + GLM-5.3 / GLM-5.3 Flash | Z.ai GLM Coding Plan — the default for workers |
| `kimi` | Claude Code + Kimi for Coding | Kimi for Coding subscription |
| `minimax` | Claude Code + MiniMax M3 | MiniMax Coding Plan |
| `qwen` | Claude Code + Qwen 3.7 Plus | Alibaba Model Studio coding plan |
| `moonshot` | Claude Code + Kimi K3 API | Moonshot platform API: metered, off until the owner sets `WOLFMUX_METERED=on` |
| `deepseek` | Claude Code + DeepSeek V4 | DeepSeek API: metered, off until the owner sets `WOLFMUX_METERED=on` |
| `fable` · `opus` · `sonnet` · `haiku` | Claude Code + that Claude model | Claude subscription |
| `astra` | Codex CLI + GPT-6 Astra | ChatGPT / Codex subscription |
| `claude:<model-id>` · `codex:<model-id>` | any other model of those two subscriptions | the same subscription |
| `kimi:<id>` · `moonshot:<id>` · `deepseek:<id>` · `minimax:<id>` · `qwen:<id>` | any other model id of that provider (GLM is not pinnable) | the same plan, or the same metered account |

New leads run Opus unless you name another model or set `teamctl policy lead-model <model>`.
Existing leads keep their recorded model on start, restart and restore. For example, the
human chose Fable for deployment-manager's lead:

```bash
teamctl model lead fable --team deployment-manager
```

This records a choice for that team; it is not a built-in exception. To change a lead and
keep its conversation, use `teamctl model lead opus --now`, or explicitly restart it with
`teamctl restart lead --model opus --continue`. The first switches only when safe; the
second restarts immediately. A later answer from another Claude family is adopted into
the record on a `status`, `teams`, or `restart` read when the project lock is available.
Adoption needs an existing model id and an answer newer than the last recorded change.
Typing `/model` in Claude also writes `"model"` into `~/.claude/settings.json`, affecting
the default for new Claude sessions on the Mac. An explicit model choice overrides it;
Wolfmux supplies `--model` when launching an agent. `teamctl model --now` leaves that file alone.

An Opus team can take on an Astra teammate for one review (`teamctl spawn fe-review astra`),
an Astra team a Sonnet one (`teamctl spawn summary sonnet`), any team a Kimi one
(`teamctl spawn docs2 kimi`); tell the lead, or run it
yourself. Every teammate gets its own worktree and branch and the same Beads inbox. What
differs by CLI: Claude-based teammates have the worktree guard and the lead-approval mode;
Codex-based ones have neither (Codex has no such hooks) but do send notifications.

A provider worker needs its key in the Keychain first
([SETUP.md](SETUP.md#3-the-keys)); `teamctl doctor` says which are set up. `spawn` and
`start` refuse a metered key (exit 77, and the launcher exit 78) until the owner has set
`WOLFMUX_METERED=on`; `teamctl status` marks a running metered agent with `$` after its
label, with a legend line under the table.

`teamctl doctor --probe` is the check for a provider worker that answers 401. For every provider
whose Keychain item exists it sends one request to that provider's endpoint over https: `POST
/v1/messages` with an empty body. That asks for no completion, so nothing is generated and
nothing is billed, metered providers included. Only the HTTP status is shown. 200, 400, 422 and
429 mean the key was accepted (the raw status is printed next to it; a good key is expected to get
400 or 422, which was inferred from the rejected side, measured with a fake key); 401 and 403 are a
FAIL naming the Keychain slot, the endpoint and the console the key comes from; no answer, or any
other status, is a warning. The key travels on curl's stdin only: not in its arguments, not in any
environment, not in a file, not on screen, and no redirect is followed. Plain `teamctl doctor` stays
offline and never reads a key value.

## What an agent starts with

Everything in an agent's first request is sent again with every later request, and it decides
how much room a compaction leaves. Measured on Claude Code 2.1.325 (2026-11-16, ADR-0037):

| First request | Worker | Lead |
|---|---|---|
| v1.24.0 (`worker-context trim`, lead untouched) | 74,171 tokens | 90,006 |
| v1.25.0 `trim`, and `lead-context trim` | 51,884 | 67,793 |
| the same with a second-language rules folder left out | 44,099 | 60,008 |

These are print-mode probes (`claude -p`, Haiku 5.5) with the settings wolfmux generates. A pane
offers more tools, so both the request and the saving are larger there: 81,024 to 54,289 for a
worker and 115,652 to 70,017 for a lead in real team runs.

`teamctl policy worker-context full|trim|lean` (default `trim`, `WOLFMUX_WORKER_CONTEXT`):

- `full`: everything in your `~/.claude`, as you have it.
- `trim`: your rules and settings stay. Off for the worker: every plugin; the tools an agent in
  a pane cannot use (Artifact, AskUserQuestion, SendFeedback, ScheduleWakeup, Workflow,
  ReportFindings, ListAgents); the claude.ai connectors of your account, which otherwise join a
  conversation after its first request with all their tool names; and the files of
  `context-exclude`.
- `lean`: `trim`, and nothing from `~/.claude` is read at all.

`teamctl policy lead-context full|trim` (default `full`, `WOLFMUX_LEAD_CONTEXT`): `trim` gives
the lead the same reductions, except that it keeps AskUserQuestion (its way to ask you) and
your plugins. If you use a claude.ai connector (Gmail, Slack) from the lead's conversation,
stay on `full`.

`teamctl policy context-exclude '<glob>' ['<glob>' ...]` (default none,
`WOLFMUX_CONTEXT_EXCLUDE`, globs separated by spaces): instruction files, `CLAUDE.md` and rules,
that a trimmed agent does not load. Nothing of yours is left out unless you name it.
`teamctl policy context-exclude none` goes back to the default. `teamctl doctor` finds a rules
folder that repeats another one in a second language and prints the line to use, with what it
saves:

```text
rules: ~/.claude/rules/ecc/zh repeats ~/.claude/rules/ecc/common in a second language. Every agent reads both, with every request.
       leave it out for workers:  teamctl policy context-exclude '**/rules/ecc/zh/**'   (for the lead too: teamctl policy lead-context trim)
       saves about 7770 tokens per request (9142 characters; an estimate from its size)
```

A change applies to agents started or restarted from then on.

## Beads cheat sheet

For a project kept on the Beads backend (`teamctl store` says `beads`): the raw `bd`
commands `teamctl send`, `teamctl task` and the rest call underneath, useful when you
want Beads' own view (`bd ready`, dependency queries) or are scripting against it
directly. On the default native store these are not available; use the `teamctl`
verbs above instead, which work the same on either backend.

```bash
bd list --assignee $BEADS_ACTOR --status open,in_progress,blocked --include-infra   # inbox: your tasks (new, claimed, blocked) + unread messages; $BEADS_ACTOR is your role, or <team>.<role> in a named team
bd show <id>                  bd show <id> --thread           # read; whole conversation
bd close <id> -r read                                         # mark a message read
bd create "Subject" -t message -a <role> -d "body"            # send        (--body-file for long text)
bd create "Re: …" -t message -a <role> -d "…" --deps replies-to:<id>        # reply
bd create "Title" -t task -p 1 -a <role> -d "…"               # assign work
bd update <id> --claim        bd update <id> --status blocked # I'm on it / I'm stuck
bd close <id> -r "commit <sha>; tests pass"                   # done
bd update <id> --add-label failed && bd close <id> -r "FAILED: why"
bd ready                      bd list --status in_progress,blocked
bd list --type message --all                                  # message history
```

Status map: pending = open without assignee · assigned = open with assignee ·
in_progress · blocked · completed = closed · failed = closed + label `failed`.
Comments (`bd comment`) notify nobody; send a message when someone must act.

## Finding the manager, and being told when someone finishes

| You see | Meaning |
|---------|---------|
| the lead large on the left, teammates stacked on the right | the default arrangement. `teamctl layout lead-top` or `tiled` changes it for this team (`WOLFMUX_LAYOUT` for all); inside the team `Ctrl-b Space` cycles tmux's own arrangements and `Ctrl-b T` puts the last one back |
| a popup with the wolf when you open the team | `teamctl start` / `attach` worked. Any key closes it (or 3 seconds). Off: `WOLFMUX_SPLASH=off` in `~/.config/wolfmux/config` |
| `🐺 lead · <model>` and an amber pane border | the manager. Teammates are `🐶 <role> · <model>` with grey borders (blue when focused) |
| `🐺 WOLFMUX` in the status line, `🐺 <session>` as the tab title | this terminal tab is a Wolfmux team |
| a desktop notification `🐺 lead: …` or `🐶 backend: …` | that agent finished a turn. Click it: if the team is open in a tab, that tab comes to the front; if it is on no screen, a new terminal window opens attached to it (the notification then comes from **Wolfmux**, with the wolf as its icon). The first time, macOS asks to allow Wolfmux notifications and to let Wolfmux control your terminal: allow both. Scope: `WOLFMUX_NOTIFY=all` (default), `lead`, or `off`; terminal: `WOLFMUX_TERMINAL=iterm\|terminal` |

**Clearing up.** `teamctl destroy` ends the team and keeps every worktree. `teamctl destroy
--worktrees` also removes the workers that hold nothing: clean worktree, branch fully merged.
A worker that still holds work is kept and named, with the two ways out: `git merge <branch>`
to keep it, `teamctl remove <role> --force` to discard it.

**Staying in lane.** Each teammate works in its own worktree on its own branch, and a guard
refuses tool calls that reach outside (changing the lead's checkout, reading a teammate's
worktree, switching or deleting branches, pushing to main, tmux). The refusal tells the
worker to ask the lead. `teamctl policy worker-isolation off` turns it off for a project.

**Closing and coming back.** Quitting an agent's CLI leaves its pane on screen (so you can
read its last output); quitting all of them leaves a window of finished panes. `teamctl start
[<model>]` deals with both: if only the lead had exited it comes back in its place and the
workers are not touched; if everyone had exited, the old window is cleared and a new session
starts. Workers from before are listed as stopped, with their worktrees — `teamctl restart
<role> --continue` brings one back with its conversation. `teamctl start … --continue` does
the same for the lead. After a reboot no tmux session is left at all: `teamctl restart lead
--continue` (with `--team <name>` for a named team) starts the team again in the lead's last
conversation, then `restart` each teammate. To end a team on purpose: `teamctl destroy`.

**Which conversation comes back.** Every Claude-family agent is given its own conversation id
when it starts, and `--continue` reopens exactly that one. So with several teams in one
project each lead comes back in its own conversation, not in whichever was written to last.
`teamctl status --json` prints the stored id per agent (`.agents[].session_id`; the team-memory
lead's is `hidden` to anyone but the human and that lead), and `--resume <session-id>` pins a different one; it is stored, and it wins over `--continue`.
The lead's id is kept with the team, so `teamctl destroy` in the evening and `teamctl start
<model> --continue` in the morning is the same conversation. Four cases are worth knowing:

| Case | What `--continue` does |
|------|------------------------|
| the agent never said a word (the CLI wrote no transcript, and refuses to resume an id without one) | starts that conversation fresh, under the same id, and says so in the pane |
| no id on record: an agent from before 1.12, a first `start --continue`, a team that was purged | what it did before: the newest conversation in that folder, with one warning line. In a shared folder that is a guess; pin one with `--resume <session-id>` |
| a Claude lead after a Codex lead led the team in between | the last Claude lead's own conversation: the team keeps that id, and a Codex lead does not overwrite it |
| a Codex-family agent (`astra`, `codex:<id>`) | `resume --last`: Codex takes no conversation id from teamctl, so in a shared folder the ambiguity stays. `--resume` is refused for it (exit 64) |

`--resume` of an id that has no transcript anywhere is refused before anything is restarted,
and so is the id another agent of the project has on record: two agents in one conversation
write over each other. A restart that produces no pane leaves the id as it was.
`teamctl status` reads CONTEXT from the same conversation, by id, so two leads in one folder
each show their own.

Notifications and the session names (`🐺 team/lead`, `🐶 team/<role>`) reach an agent when it starts:
after an update, `teamctl restart <role> --continue`.

## Quiet notices: nothing is typed into your conversation

The lead's pane is where you talk to the lead. Until v1.15.0 every
`[wolfmux] Beads update for <role> …` line was typed straight into it, so a notice
could land in the middle of what you were saying. It does not any more.

A notice now goes into a file first — `~/.wolfmux/state/<project>/[teams/<team>/]inbox/<role>`,
one line each — and is read from there by whoever needs it:

| who | how they get it | does it touch your conversation |
| --- | --- | --- |
| you, for debugging | `teamctl inbox` / `teamctl inbox --all`. Not counted on the status line | no |

What the status line shows you is something else: your own Beads messages. `📨 3` on the left
is how many messages to `human` (setting `WOLFMUX_HUMAN`) are open in this project, counted
from an index the Beads hook keeps, so the status line never runs bd. `🔔` as well while a
permission request of this team waits for your decision. Nothing at all when there is
neither. `prefix N`, or a click on the number, opens them in a popup: up/down or a digit
selects, Enter reads one, `r` marks it read, `a` marks them all read after a y/n, `q` or Esc
closes. Opening it checks Beads once and corrects the index.

The badge, the click and `prefix N` come from `config/wolfmux/tmux.conf`, which a running tmux server has
already read. To put them on a server that is already up — teams running in it and all —
`tmux -L wolfmux source-file ~/.config/wolfmux/tmux.conf`. That applies the status line and the
key bindings at once, needs no server restart and **no team restart**; restarting a team for
this would regenerate every agent's settings document for nothing. Every setting in that file
is a `set -g` overwrite, so re-sourcing is safe to repeat, and it re-reads your own
`~/.tmux.conf` as well.
| you, when an agent is stuck | one desktop notification, at most one per role every two minutes, carrying the count: "team/lead: 4 notices waiting". A click opens the team | no |
| the agent | its own session hands them over when its turn ends, or when you next prompt it. In its transcript that is a `[wolfmux] You have team notices:` block. At a turn's end only in a pane **you are not using**, under either value of `human-pane-typing`, and Claude Code labels it `Stop hook feedback` (before 1.22.1: `Stop hook error`). Never at the turn end of a Claude lead you are attached to: Claude Code prints that text in full in the pane. In a pane you are using, the next prompt carries them: yours, or the agent's own loop. An **idle lead** wakes itself (below) | no |
| the agent, typed | a worker's idle pane is still typed into, as before, and the lead's pane while nobody is attached. A pane **you are using** never is (policy `human-pane-typing`, default `off`): one your client shows whose terminal has focus, or saw a key in the last 2 minutes. Nor is a Claude lead's pane while you are attached, in use or not. A tmux read that fails counts as in use. Under `human-pane-typing idle` the v1.16.1 rule is back: typed in once the pane is quiet, no keystroke in it for `WOLFMUX_NUDGE_LEAD_IDLE` (5 minutes), nothing half-typed on its input line, not in copy mode | never, under the default |

`teamctl policy human-pane-typing idle` is yours alone to run, from your own terminal: an
agent gets exit 77, because its own pane is the one it would be asking to type into.

### An idle lead wakes itself

Since v1.23.0 (issue #34). Before, an idle lead you were attached to was not woken by a
notice at all: tagging.lead sat 16 hours on 4 messages. Now:

- **What "using a pane" means.** Your client shows it, and its terminal has focus (tmux
  tracks focus per client), or you pressed a key there in the last 2 minutes
  (`WOLFMUX_WATCH_QUIET`, 120). A lead in a background tab, or in iTerm2 while you are in
  another app, is not in use.
- **The wake.** Every Claude lead runs a small waiter hook while it is idle
  (`teamctl _inbox-wake`, on Stop and on SessionStart). It looks every 15 seconds. When a
  notice is waiting and nobody is using the lead's pane, it hands the notices to the lead,
  which takes a turn. Nothing is typed. The pane shows one line, `wolfmux: team notice`,
  then the lead's turn. A half-typed line in its input box stays as it was. Its turn-end
  hook stays silent while you are attached, because it would print the notices in full.
- **The tab in front of you** behaves as before: the notice waits for your next prompt.
- **What a sender sees.** `teamctl nudge` says "held for tagging.lead (idle since
  10:46Z): it wakes itself within ~15s", or why it will not (its pane is in front of you,
  it is in a turn, `lead-wake` is off, or it was started before v1.23.0).
  `teamctl status` shows held notices under the lead: how many, the oldest, and whether it
  wakes itself.
- **Once a week.** Claude Code kills a hook at its timeout (7 days). The waiter ends
  itself 5 minutes before that, with one short turn: "your notice waiter re-arms ...
  nothing to do". That turn's end arms a fresh one.
- **Off switch.** `teamctl policy lead-wake off`, yours alone (an agent gets exit 77). A
  lead started before v1.23.0 gets the waiter at its next start or restart.
- **A terminal that never reports focus** reads focused for ever, so its lead never wakes
  itself (it waits, as before). The same holds for a tab attached in the background until
  you first visit it. `WOLFMUX_WATCH_FOCUS_MAX=600` makes focus count only with a key in the
  last 10 minutes.

Two things are tracked per notice, and they are independent: whether **you** have
expanded it (that is the count in the status bar) and whether the **agent** has been
given it. Reading your notices never hides them from the agent, and an agent reading
them never clears your count.

Under `human-pane-typing idle` only, two cases still put a line in your conversation on
purpose (under the default `off`, neither is typed into a pane you are watching). The Stop
hook is never one of them: since 1.22.1 it says nothing in a pane you watch under `idle`
too, where before it printed `Stop hook error: [wolfmux] You have team notices: …` after
the agent's turns.

- **A permission request.** It holds a worker until you answer, so if it is still
  PENDING after `WOLFMUX_INBOX_APPROVAL_GRACE` (20 s) it is typed in after all.
  Answering it (`teamctl approve` / `deny`), or its expiring, stops that — looking at it
  does not, because a glance unblocks no worker.
  `WOLFMUX_INBOX_APPROVAL_TYPE=never` turns the typing off and leaves it to the badge;
  `always` types it at once. `WOLFMUX_NUDGE_TYPE=off` outranks all three: nothing is
  typed, pending or not.
- **A Codex pane** (`astra`, `codex:<model>`), whatever its role. Codex has no hook to
  hand a notice over with, so typing is the only channel that reaches that agent at all.

The knob for the rest is `WOLFMUX_NUDGE_TYPE`: `off` (never type into anybody),
`workers`, `detached-lead` (the default — workers, plus the lead's pane while nobody is
attached) and `all` (the pre-1.15.0 behaviour). `human-pane-typing off` sits on top of all
four, so under it `all` types into the same panes as `detached-lead`.
`WOLFMUX_NUDGE_LEAD_IDLE` is how quiet the lead's pane has to be first under
`human-pane-typing idle`: 300 seconds, and only the keystroke check uses it — a half-typed
line or copy mode is busy at any setting. `WOLFMUX_HUMAN_PANE_TYPING` in the config file is
the policy's default for every team.
`WOLFMUX_INBOX_STALL_NOTIFY=off` drops the desktop notification, and `WOLFMUX_NOTIFY=off`
already does.

These six — `WOLFMUX_NUDGE_TYPE`, `WOLFMUX_NUDGE_LEAD_IDLE`,
`WOLFMUX_NUDGE_COLLISION_CHECK`, `WOLFMUX_INBOX_APPROVAL_TYPE`,
`WOLFMUX_INBOX_APPROVAL_GRACE` and `WOLFMUX_INBOX_STALL_NOTIFY` — go in
`~/.config/wolfmux/config` as `KEY=value` lines, which is where a knob has to live to
reach an agent's pane: a pane's environment comes from the tmux server, not from the
shell you typed `teamctl` in. Before v1.16.1 none of them was on that file's allowlist,
so writing one there was read and dropped, with no error and no effect. And before
v1.20.0 the six that `lib/inbox.sh` and `lib/agents.sh` give a default when they load were
still ignored there, because `teamctl` read the file after loading them; it reads the file
first now, and `tests/providers.sh` runs the real binary to check.

**v1.16.0 and earlier left one case broken, and v1.16.1 is the fix.** A client attached
and the lead idle meant the notice was filed and nothing else, and a filed notice reaches
the agent through its **Stop** hook, which only fires when a turn ENDS. An agent that is
already idle has no turn left to end, so the notice sat there: measured on 2026-10-12, a
lead idle from 13:58Z never received P1 notices sent at 16:13Z or 16:53Z and was still
asleep at 17:35Z. v1.16.1 typed such a notice in once the pane was quiet. v1.20.0 keeps
that as `human-pane-typing idle` and does not type into your pane at all by default: a
quiet pane was often a human reading it.

## tmux, in the team session only

Mouse: click to focus, drag a border to resize, wheel to scroll. `Ctrl-b` then
arrows = move · `Ctrl`/`Alt`-arrows = resize · `z` = zoom · `T` = re-tile ·
`N` = the team's notices in a popup · `q` = pane numbers · `d` = detach (the team
keeps running).

`prefix I` is deliberately **not** the notices key: `config/wolfmux/tmux.conf` sources
your own `~/.tmux.conf` first, so a wolfmux binding would quietly win over yours, and
`I` belongs to tmux-plugins/tpm on a machine that has it.

## Checking which model and account a pane really uses

| Pane | Type | Expect |
|------|------|--------|
| Fable lead | `/status` | Claude subscription login, no API key, no custom base URL |
| Astra lead | `/status` | signed in with ChatGPT, model `gpt-6-astra` |
| GLM worker | `/status` | base URL `https://api.z.ai/api/anthropic`, auth `apiKeyHelper` (or `ANTHROPIC_AUTH_TOKEN` in env mode), model `glm-5.3` / `glm-5.3-flash` |
| other provider worker | `/status` | that provider's base URL and model (Kimi auth may be `ANTHROPIC_API_KEY` in env mode); `WOLFMUX_DRY_RUN=1 claude-<provider>` prints the exact values |
