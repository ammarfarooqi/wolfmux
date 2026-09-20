# Usage

The installed user manual is [`config/ai-team/README.md`](../config/ai-team/README.md)
(`~/.config/ai-team/README.md` on the machine). This page walks through one
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
# backend's pane shows:  [ai-team] Beads update for backend (shop-wisp-x1). Run: bd show shop-wisp-x1 ...
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

## teamctl

| Command | Does |
|---------|------|
| `teamctl start <fable\|astra> [--no-attach] [--init-beads\|--skip-beads]` | create the session and the lead pane; attach |
| `teamctl spawn <role> <glm53\|flash\|fable\|astra> [--base <ref>] [--no-kickoff]` | new worker: branch + worktree + pane |
| `teamctl stop <role>` | close a pane; worktree, branch and commits stay |
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
`teamctl send|inbox|broadcast|task` print the `bd` equivalents.

## Beads cheat sheet

```bash
bd list --assignee $TEAM_ROLE --status open --include-infra   # inbox: new tasks + unread messages
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
