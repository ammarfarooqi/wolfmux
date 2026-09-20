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
teamctl destroy --worktrees          # later: drops clean worktrees and fully merged ai/* branches
```

## Several teams in one project

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
| naming | lowercase letters, digits, `-`; `--team <name>` may stand before or after the command |
| which team a command means | inside a pane: the agent's own team. At your terminal: the only team there is; with several, the command lists them and asks (`status` and `teams` show all) |
| `teamctl start <model>` without `--team` | the first team. If that is running under another model it is not opened for you; you are shown `teamctl attach` and `teamctl start <model> --team <name>` |
| roles | per team: two teams can each have a `backend`. Branches are `ai/<team>/<role>-…`, worktrees live under `…/teams/<team>/` |
| Beads | all teams share the project's Beads. The first team's agents are `lead`, `backend`, …; a named team's are `review.lead`, `review.backend`. Hand work across teams with `-a review.lead` |
| management | a lead manages its own team only; you manage all |

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
the session, every worktree, the team's `ai/…` branches, its records, the transcripts
(`--keep-transcripts` keeps those). Never touched: your checkout, other branches, Beads,
other teams.

## Teams working together

All teams of a project share its Beads, so they can talk: `-a review.lead` reaches the lead
of team review, a plain `-a lead` the first team's. A lead can also found a team and hand
work over, without you relaying anything:

```bash
bd create "Handover: payments" -t message -a next.lead --body-file handover.md    # → id shop-41
teamctl start fable --team next --no-attach --handover shop-41
```

The new lead starts by reading that bead, you get a notification, and the founder does not
manage the new team. `teamctl policy lead-teams off` keeps founding teams to yourself. A
lead can never take over a team that already has a lead; a worker can never found one.

## teamctl

| Command | Does |
|---------|------|
| `teamctl start <fable\|astra> [--no-attach] [--init-beads\|--skip-beads] [--lead-permissions …] [--worker-permissions …] [--worker-spawn …]` | create the session and the lead pane; attach |
| `teamctl policy [<key> <value>]` | show or change `lead-permissions` (skip\|ask), `worker-permissions` (skip\|lead\|ask), `worker-spawn` (on\|off) |
| `teamctl approvals [--all]`, `teamctl approve <id>…\|--all`, `teamctl deny <id> "<reason>"` | the lead decides workers' permission requests (`worker-permissions lead`) |
| `teamctl spawn <role> <model> [--base <ref>] [--no-kickoff]` | new worker: branch + worktree + pane. Any model, whoever leads (table below) |
| `teamctl stop <role>` | close a pane; worktree, branch and commits stay |
| `teamctl remove <role>... [--force] [--yes]` | take a stopped worker off the books: worktree, branch and record. Refuses when the worker holds uncommitted files or commits your branch does not have, and lists them; `--force` discards them after one question |
| `teamctl restart <role> [--continue]` | same worktree and branch; `--continue` resumes the CLI's last conversation |
| `teamctl nudge <role>\|--all [--id <bead>]` | re-send the one-line notification |
| `teamctl status [--json]` (alias `workers`) | role, model, running / exited(N) / stopped, pane, branch, commits ahead, dirty files |
| `teamctl panes` | tmux's view: command, pid, cwd |
| `teamctl capture <role> [-n N\|--all]`, `teamctl log <role>` | recent / full terminal output — for diagnosing a stuck agent, never for task state |
| `teamctl focus <role>`, `teamctl attach` (alias `open`) | move your terminal |
| `teamctl worktrees` | branch, commits ahead, dirty count per worker |
| `teamctl diff <role> [--stat\|--names\|--commits\|--working]` | the worker's changes since its base |
| `teamctl destroy [--worktrees] [--yes]` | end the session; never deletes dirty worktrees, unmerged branches, source, credentials or Beads data |
| `teamctl doctor` | launcher, credential, settings and login checks |

Roles are lowercase letters, digits and `-` (max 32). `lead` is reserved.
`start`, `stop`, `restart`, `destroy`, `policy`, `approve` and `deny` are reserved for
the lead and for you; `spawn` too unless `worker-spawn` is on. A worker gets exit 77.
`teamctl send|inbox|broadcast|task` print the `bd` equivalents.

### Models

| Model key | Runs | Pays with |
|-----------|------|-----------|
| `glm53` · `flash` | Claude Code + GLM-5.3 / GLM-5.3 Flash | Z.ai GLM Coding Plan — the default for workers |
| `fable` · `opus` · `sonnet` · `haiku` | Claude Code + that Claude model | Claude subscription |
| `astra` | Codex CLI + GPT-6 Astra | ChatGPT / Codex subscription |
| `claude:<model-id>` · `codex:<model-id>` | any other model of those two subscriptions | the same subscription |

A Fable team can take on an Astra teammate for one review (`teamctl spawn fe-review astra`),
an Astra team a Sonnet one (`teamctl spawn summary sonnet`); tell the lead, or run it
yourself. Every teammate gets its own worktree and branch and the same Beads inbox. What
differs by CLI: Claude-based teammates have the worktree guard and the lead-approval mode;
Codex-based ones have neither (Codex has no such hooks) but do send notifications.

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
| the lead large on the left, teammates stacked on the right | the default arrangement. `teamctl layout lead-top` or `tiled` changes it for this project (`WOLFMUX_LAYOUT` for all); inside the team `Ctrl-b Space` cycles tmux's own arrangements and `Ctrl-b T` puts the last one back |
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
the same for the lead. To end a team on purpose: `teamctl destroy`.

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
