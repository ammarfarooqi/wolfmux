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
| `teamctl policy [<key> <value>]` | show or change, per team: `lead-permissions` (skip\|ask), `worker-permissions` (skip\|lead\|ask), `worker-spawn` (on\|off), `worker-isolation` (on\|off: the worktree guard), `lead-teams` (on\|off: may the lead found teams), `branch-template` (how workers' branches are named: [branch names](#branch-names-that-fit-your-repository)) |
| `teamctl approvals [--all]`, `teamctl approve <id>…\|--all`, `teamctl deny <id> "<reason>"` | the lead decides workers' permission requests (`worker-permissions lead`) |
| `teamctl spawn <role> <model> [--base <ref>] [--branch <name>] [--ticket <KEY>] [--repo <path> \| --from-worktree <role>] [--no-kickoff] [--resume <session-id>]` | new worker: branch + worktree + pane. Any model, whoever leads (table below). `--branch` / `--ticket`: [branch names](#branch-names-that-fit-your-repository) · `--repo`: [a worker in another repository](#a-worker-in-another-repository). `--from-worktree <role>` starts the fresh worker in a stopped worker's built worktree, on a new branch (the old branch and commits stay): node_modules and build output survive, so install and build are not repeated. Refuses a running worker, and a worktree with uncommitted changes (lists them) (`--repo` does not combine with it: the worktree stays in its own repository). Only the lead, or you, may hand a worktree over; a worker is refused (exit 77) even with worker-spawn on. `--resume <session-id>` puts it into an existing conversation instead of a new one (and sends no kickoff) |
| `teamctl stop <role>` | close a pane; worktree, branch and commits stay |
| `teamctl stop <role>` | close a pane; worktree, branch and commits stay |
| `teamctl remove <role>... [--force] [--yes]` | take a stopped worker off the books: worktree, branch and record. Refuses when the worker holds uncommitted files or commits your branch does not have, and lists them; `--force` discards them after one question |
| `teamctl restart <role> [--continue] [--resume <session-id>]` | same worktree and branch; `--continue` resumes that agent's own conversation, `--resume` the one you name. Without either it starts a new one |
| `teamctl nudge <role>\|--all [--id <bead>] [--quiet]` | re-send the one-line notification. `--quiet`: nobody to notify is not an error (what the Beads hook passes). A pane somebody is typing in is never typed into: the notice waits for that pane to go idle and arrives by itself (`deferred: …`, exit 3). Notices that pile up while it waits arrive as one line |
| `teamctl status [--json]` (alias `workers`) | team by team: role, model, running / exited(N) / stopped, pane, branch, commits ahead, dirty files, CONTEXT (tokens in use and share of the window, read from the transcript of the agent's own conversation; `-` when there is none) |
| `teamctl teams [--json]` | the short list per team: state (`running` or `orphaned`), lead, number of agents, the disk its teammates' worktrees take, who founded it, session. `--json` and `status --json` carry `founder` and `orphaned`; an orphaned team says who may act on it ([when the lead of a founded team is gone](#when-the-lead-of-a-founded-team-is-gone)) |
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

## tmux, in the team session only

Mouse: click to focus, drag a border to resize, wheel to scroll. `Ctrl-b` then
arrows = move · `Ctrl`/`Alt`-arrows = resize · `z` = zoom · `T` = re-tile ·
`q` = pane numbers · `d` = detach (the team keeps running).

## Checking which model and account a pane really uses

| Pane | Type | Expect |
|------|------|--------|
| Fable lead | `/status` | Claude subscription login, no API key, no custom base URL |
| Astra lead | `/status` | signed in with ChatGPT, model `gpt-6-astra` |
| GLM worker | `/status` | base URL `https://api.z.ai/api/anthropic`, auth `apiKeyHelper` (or `ANTHROPIC_AUTH_TOKEN` in env mode), model `glm-5.3` / `glm-5.3-flash` |
| other provider worker | `/status` | that provider's base URL and model (Kimi auth may be `ANTHROPIC_API_KEY` in env mode); `WOLFMUX_DRY_RUN=1 claude-<provider>` prints the exact values |
