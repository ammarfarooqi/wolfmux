# Usage

The installed user manual is [`config/wolfmux/README.md`](../config/wolfmux/README.md)
(`~/.config/wolfmux/README.md` on the machine). This page walks through one
complete session and lists every command.

## A complete session

```bash
cd ~/code/shop
teamctl start fable              # or: teamctl start astra
```

You are now attached to a tmux session with one pane, `lead · Fable 5.1`. Tell the
lead what you want, for example *"Add password reset. Backend and frontend in
parallel, QA afterwards."* The lead then works like this (you can type the same
commands yourself at any time):

```bash
# 1. plan: tasks with owners, acceptance criteria and dependencies
bd create "Reset API: POST /reset, POST /reset/confirm" -t task -p 1 -a backend --body-file api-spec.md
bd create "Reset screens" -t task -p 1 -a frontend -d "Two screens, contract in the API task"
bd create "E2E: reset flow" -t task -p 2 -a qa -d "Happy path + expired token"
bd dep add <qa-task> <api-task>
bd dep add <qa-task> <ui-task>

# 2. staff: one pane, branch and worktree each
teamctl spawn backend glm53
teamctl spawn frontend glm53
teamctl spawn qa flash
```

Each worker boots, reads its inbox, claims its task and starts. They coordinate
directly:

```bash
# in the frontend pane
bd create "Need expires_at in the confirm response" -t message -a backend -d "ISO-8601, UTC"
# backend's pane shows:  [wolfmux] Beads update for backend (shop-wisp-x1). Run: bd show shop-wisp-x1 ...
```

When a worker finishes it commits, reports and closes:

```bash
git commit -am "feat: password reset API"
bd create "Done: Reset API" -t message -a lead --body-file report.md   # summary, tests, commit, risks
bd close <api-task> -r "commit 4f2a9c1; 38 tests pass"
```

The lead is notified, reviews and integrates:

```bash
teamctl status                       # who is running, commits ahead, dirty files
teamctl diff backend --stat          # then: teamctl diff backend
git cherry-pick 4f2a9c1              # in the project root — only the lead does this
bd create "Changes requested: rate-limit /reset" -t message -a backend -d "…"   # or this
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
teamctl start fable --team review         # a second one, named by you, in its own tmux session
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
| `teamctl keep <role>` | nothing — that is the point. The lane is never swept automatically, and `prune` honours it too |
| `teamctl destroy` (no `--worktrees`) | the build output of every lane, because ending the session parks all of them |
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
  TEAM nudge-fix            running      lead Opus 5       agents 1    lanes 4.2 GB
      🐺 lead             Opus 5         running  cpu 2.4    mem 0.5G    ctx 490k 24%   wrote 2s     -
  TEAM onboarding           running      lead Fable 5.1    agents 25   lanes not measured (teamctl teams measures it)
      🐶 walk2            Opus 5         running  cpu 0.0    mem 0.4G    ctx 192k 19%   wrote 14m    ai/onboarding/walk2-…

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

That is `restart`, `stop`, `remove` and `destroy` in every form, and `teamctl start <model>
--team review --continue`; never `policy`, `approve` or `deny`. It holds only while the
team's lead is not running (its pane exited or is gone, or there is no tmux session at all);
while that lead runs, the founder is refused (exit 77) and told so. Every time the founder
acts you get a notification, and the event log records it with the founder's Beads name
(`by`). Another team's lead and any worker stay refused. A team you started yourself has no
founder but you. A restart without a session keeps the founder, the handover and the
creation time in the lead's record, so the founder keeps its authority after one.

## teamctl

| Command | Does |
|---------|------|
| `teamctl start <model> [--team <name>] [--no-attach] [--continue] [--resume <session-id>] [--ticket <KEY>] [--init-beads\|--skip-beads] [--lead-permissions …] [--worker-permissions …] [--worker-spawn …]` | create the session and the lead pane; attach. `--ticket` sets the team's default ticket key ([branch names](#branch-names-that-fit-your-repository)). Any model can lead (table below). `--team` names a further team; `--continue` resumes the lead's own conversation (the id stored with it), `--resume` reopens the one you name ([which conversation comes back](#finding-the-manager-and-being-told-when-someone-finishes)). With a team already there: see [closing and coming back](#finding-the-manager-and-being-told-when-someone-finishes) |
| `teamctl start <model> --team <new> --handover <bead-id>` | found a fresh team whose lead starts by reading that bead ([teams working together](#teams-working-together)) |
| `teamctl policy [<key> <value>]` | show or change, per team: `lead-permissions` (skip\|ask), `worker-permissions` (skip\|lead\|ask), `browser-writes` (ask\|allow, DEFAULT ask: allow writes an explicit `permissions.allow` rule for `mcp__claude-in-chrome__*` into every agent's settings — lead and workers alike — so a Chrome write resolves before Claude Code's auto-mode classifier runs on it), `worker-spawn` (on\|off), `worker-isolation` (on\|off: the worktree guard), `lead-teams` (on\|off: may the lead found teams), `branch-template` (how workers' branches are named: [branch names](#branch-names-that-fit-your-repository)), `disk-guard` (refuse\|warn\|off), `disk-min-gb` (a whole number of GB, 0 = no limit), `link-node-modules` (on\|off), `auto-prune` (on\|off, DEFAULT on: sweep a lane's build output as soon as the lane is parked — `teamctl keep <role>` protects one lane) |
| `teamctl approvals [--all]`, `teamctl approve <id>…\|--all`, `teamctl deny <id> "<reason>"` | the lead decides workers' permission requests (`worker-permissions lead`) |
| `teamctl spawn <role> <model> [--base <ref>] [--branch <name>] [--ticket <KEY>] [--repo <path> \| --from-worktree <role>] [--no-kickoff] [--resume <session-id>] [--link-node-modules]` | new worker: branch + worktree + pane. Any model, whoever leads (table below). Refused when free disk is under `disk-min-gb`. `--branch` / `--ticket`: [branch names](#branch-names-that-fit-your-repository) · `--repo`: [a worker in another repository](#a-worker-in-another-repository). `--from-worktree <role>` starts the fresh worker in a stopped worker's built worktree, on a new branch (the old branch and commits stay): node_modules and build output survive, so install and build are not repeated — **if that lane was protected before it was parked**, because from v1.17.0 `teamctl stop` sweeps a lane's build output. `teamctl keep <role>` before stopping it, and the flag travels with the worktree. Refuses a running worker, and a worktree with uncommitted changes (lists them) (`--repo` does not combine with it: the worktree stays in its own repository). Only the lead, or you, may hand a worktree over; a worker is refused (exit 77) even with worker-spawn on. `--resume <session-id>` puts it into an existing conversation instead of a new one (and sends no kickoff). `--link-node-modules`: a brand-new lane shares its repository's `node_modules` instead of installing its own ([disk](#disk-what-a-lane-costs-and-how-it-is-given-back)) |
| `teamctl stop <role>` | close a pane; worktree, branch and commits stay. Its build output goes, `node_modules` included (policy `auto-prune`, on by default; `off` keeps `node_modules` as before v1.17.0) |
| `teamctl remove <role>... [--force] [--yes]` | take a stopped worker off the books: worktree, branch, record and the gigabytes they held. Refuses when the worker holds uncommitted files or commits your branch does not have, and lists them; `--force` discards them after one question |
| `teamctl prune [--team <name>] [--all-teams] [--dry-run] [--keep-node-modules]` | the build output of every parked lane of the team, with a total in GB. Running lanes untouched; `--dry-run` deletes nothing; `--keep-node-modules` takes the build caches only; `--all-teams` does every team of every project on this machine and is yours alone to run — a lead is refused with exit 77 ([disk](#disk-what-a-lane-costs-and-how-it-is-given-back)) |
| `teamctl keep [<role> [on\|off]]` | never sweep that lane's build output automatically — for a checkout that is expensive to rebuild. `prune` honours it too; with no role it lists what is protected ([disk](#disk-what-a-lane-costs-and-how-it-is-given-back)) |
| `teamctl bar [--explain]` | the one line tmux shows in `status-right`; `--explain` is the legend naming every field of it ([the segment in the status bar](#the-segment-in-the-status-bar)) |
| `teamctl heavy [--timeout <seconds>] [--quiet] <command>...` | run a heavy thing — a test gate, a measurement, a long build — holding the machine's heavy lock, so nothing else heavy runs beside it and no lane is swept while it does. Returns the **command's** exit status, not the wrapper's, and says what it waited for. `--timeout`: give up after that many seconds (exit 75) rather than wait; `--quiet`: say nothing about waiting. One voice about the lock: `lockf`'s own "already locked" line is silenced, the command's own output is not. An exit 75 that is the command's own is reported as the command's, not as the lock timing out. Prefer it to `lockf` by hand ([disk](#disk-what-a-lane-costs-and-how-it-is-given-back)) |
| `teamctl restart <role> [--continue] [--resume <session-id>]` | same worktree and branch; `--continue` resumes that agent's own conversation, `--resume` the one you name. Without either it starts a new one |
| `teamctl nudge <role>\|--all [--id <bead>] [--quiet]` | re-send the one-line notification. `--quiet`: nobody to notify is not an error (what the Beads hook passes). A pane somebody is typing in is never typed into: the notice waits for that pane to go idle and arrives by itself (`deferred: …`, exit 3). Notices that pile up while it waits arrive as one line. Your own lead pane holds a notice back for longer than a worker's: with a client attached it has to have had no keystroke for `WOLFMUX_NUDGE_LEAD_IDLE` (300 s) first. `filed: …` with exit 4 now means only that nothing is ever typed into that pane (`WOLFMUX_NUDGE_TYPE=off` or `workers`) |
| `teamctl inbox [<role>] [--all] [--json] [--keep]` (alias `notices`) | the pane notices filed for a role, oldest first. Default: the lead of this team. Reading them clears the `📨` count in the status bar; it does not change whether the agent has had them, and the agent having had them does not clear your count. `--all`: every role of the team. `--json`: one object per notice. `--keep`: print them and leave them marked new. `prefix N` opens the same thing in a popup ([quiet notices](#quiet-notices-nothing-is-typed-into-your-conversation)) |
| `teamctl status [--json]` (alias `workers`) | team by team: role, model, running / exited(N) / stopped, pane, branch, commits ahead, dirty files, CONTEXT (tokens in use, and the share of the window when the model's window is known — tokens alone otherwise, never a guessed share — read from the transcript of the agent's own conversation; `-` when there is none), plus free disk and what the team's lanes take |
| `teamctl teams [--json]` | the short list per team: state (`running` or `orphaned`), lead, number of agents, the disk its teammates' worktrees take, who founded it, session. This is the command that measures that disk. `--json` and `status --json` carry `founder` and `orphaned`; an orphaned team says who may act on it ([when the lead of a founded team is gone](#when-the-lead-of-a-founded-team-is-gone)) |
| `teamctl dashboard [--json] [--once] [--interval <seconds>] [--full]` | every team on this machine, across every project, read-only; `prefix O` opens it as a popup and `q` closes it. See [The dashboard](#the-dashboard-every-team-on-the-machine). `--once` prints it and exits, `--interval` sets the redraw (default 5 s), `--full` also reads context and the transcript time for agents that are not running, `--socket <path>` asks that tmux server instead of the default |
| `teamctl panes` | tmux's view: command, pid, cwd |
| `teamctl capture <role> [-n\|--lines N] [--all]`, `teamctl log <role>` | recent / full terminal output — for diagnosing a stuck agent, never for task state |
| `teamctl focus <role>`, `teamctl attach` (alias `open`) | move your terminal |
| `teamctl layout [lead-left\|lead-top\|tiled]` | how the panes are arranged, for this team; `lead-left` is the default |
| `teamctl worktrees` | branch, commits ahead, dirty count per worker |
| `teamctl diff <role> [--stat\|--names\|--commits\|--working]` | the worker's changes since its base |
| `teamctl completion <zsh\|bash>` | print the tab-completion script of that shell, so `source <(teamctl completion zsh)` works (bash: `eval "$(teamctl completion bash)"`); `./install.sh` wires it into `~/.zshrc`, and `teamctl <Tab>` then offers commands, options and values (roles, teams, models, policy keys, layouts, approvals, branches) |
| `teamctl destroy [--worktrees] [--yes]` | end the session; never deletes dirty worktrees, unmerged branches, source, credentials or Beads data |
| `teamctl destroy --purge [--force] [--keep-transcripts] [--yes]` | delete the whole team and free its disk space: reports first, asks, then removes session, worktrees, the branches teamctl created, records and its teammates' Claude Code transcripts ([deleting a team](#deleting-a-team-and-what-a-team-costs)) |
| `teamctl doctor [--probe]` | launcher, credential, settings and login checks; `--probe` also asks each provider whose key is set up whether its endpoint accepts it |

Roles are lowercase letters, digits and `-` (max 32). `lead` is reserved.
`start`, `stop`, `restart`, `remove`, `destroy`, `approve`, `deny` and changing the `policy`
are reserved for the lead of that team and for you; `spawn` too unless `worker-spawn` is on.
A worker gets exit 77. `--team <name>` goes with any command, before or after it.
`teamctl send|inbox|broadcast|task` print the `bd` equivalents.

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

A Fable team can take on an Astra teammate for one review (`teamctl spawn fe-review astra`),
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

## Beads cheat sheet

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
<fable|astra>` deals with both: if only the lead had exited it comes back in its place and the
workers are not touched; if everyone had exited, the old window is cleared and a new session
starts. Workers from before are listed as stopped, with their worktrees — `teamctl restart
<role> --continue` brings one back with its conversation. `teamctl start … --continue` does
the same for the lead. After a reboot no tmux session is left at all: `teamctl restart lead
--continue` (with `--team <name>` for a named team) starts the team again in the lead's last
conversation, then `restart` each teammate. To end a team on purpose: `teamctl destroy`.

**Which conversation comes back.** Every Claude-family agent is given its own conversation id
when it starts, and `--continue` reopens exactly that one. So with several teams in one
project each lead comes back in its own conversation, not in whichever was written to last.
`teamctl status --json` prints the stored id per agent (`.agents[].session_id`), and
`--resume <session-id>` pins a different one; it is stored, and it wins over `--continue`.
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
| you, passively | `📨 3` on the left of the status line: notices nobody has expanded yet. `🔔` as well when one of them is a permission request waiting for your decision. Nothing at all at zero | no |
| you, on demand | `prefix N`, or `teamctl inbox` / `teamctl inbox --all`. Reading them clears the count | no |

The badge and `prefix N` come from `config/wolfmux/tmux.conf`, which a running tmux server has
already read. To put them on a server that is already up — teams running in it and all —
`tmux -L wolfmux source-file ~/.config/wolfmux/tmux.conf`. That applies the status line and the
key bindings at once, needs no server restart and **no team restart**; restarting a team for
this would regenerate every agent's settings document for nothing. Every setting in that file
is a `set -g` overwrite, so re-sourcing is safe to repeat, and it re-reads your own
`~/.tmux.conf` as well.
| you, when an agent is stuck | one desktop notification, at most one per role every two minutes, carrying the count: "team/lead: 4 notices waiting". A click opens the team | no |
| the agent | its own session hands them over when its turn ends, or when you next prompt it. In its transcript that is a `[wolfmux] You have team notices:` block | no |
| the agent, typed | a worker's idle pane is still typed into, as before. Your lead pane is typed into only while it is **quiet**: no keystroke in it for `WOLFMUX_NUDGE_LEAD_IDLE` (5 minutes), nothing half-typed on its input line, not in copy mode. Otherwise the notice waits and goes in by itself once that pane is quiet | never while you are working in it |

Two things are tracked per notice, and they are independent: whether **you** have
expanded it (that is the count in the status bar) and whether the **agent** has been
given it. Reading your notices never hides them from the agent, and an agent reading
them never clears your count.

Two cases still put a line in your conversation on purpose:

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
`workers`, `detached-lead` (the default — workers, plus the lead's pane whenever it is
quiet) and `all` (the pre-1.15.0 behaviour, which types in whatever you are doing).
`WOLFMUX_NUDGE_LEAD_IDLE` is how quiet the lead's pane has to be first: 300 seconds, and
only the keystroke check uses it — a half-typed line or copy mode is busy at any setting.
`WOLFMUX_INBOX_STALL_NOTIFY=off` drops the desktop notification, and `WOLFMUX_NOTIFY=off`
already does.

These six — `WOLFMUX_NUDGE_TYPE`, `WOLFMUX_NUDGE_LEAD_IDLE`,
`WOLFMUX_NUDGE_COLLISION_CHECK`, `WOLFMUX_INBOX_APPROVAL_TYPE`,
`WOLFMUX_INBOX_APPROVAL_GRACE` and `WOLFMUX_INBOX_STALL_NOTIFY` — go in
`~/.config/wolfmux/config` as `KEY=value` lines, which is where a knob has to live to
reach an agent's pane: a pane's environment comes from the tmux server, not from the
shell you typed `teamctl` in. Before v1.16.1 none of them was on that file's allowlist,
so writing one there was read and dropped, with no error and no effect.

**v1.16.0 and earlier left one case broken, and v1.16.1 is the fix.** A client attached
and the lead idle meant the notice was filed and nothing else, and a filed notice reaches
the agent through its **Stop** hook, which only fires when a turn ENDS. An agent that is
already idle has no turn left to end, so the notice sat there: measured on 2026-10-12, a
lead idle from 13:58Z never received P1 notices sent at 16:13Z or 16:53Z and was still
asleep at 17:35Z. Now such a notice is typed in once the pane is quiet, so an idle lead
wakes up by itself — and a lead you are in the middle of talking to still does not.

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
