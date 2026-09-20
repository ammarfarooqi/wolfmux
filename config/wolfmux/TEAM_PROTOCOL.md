# Wolfmux protocol

One **lead** and any number of **workers** share one repository. Every agent runs in
its own tmux pane. The protocol is the same whichever model plays which role.

Two tools, two jobs:

| Tool | Owns | Never use it for |
|------|------|------------------|
| `teamctl` | tmux panes, which model runs where, git worktrees, start/stop | tasks, messages |
| `bd` (Beads) | tasks, dependencies, messages, history | processes, worktrees |

Your identity is in the environment: `TEAM_ROLE` (also exported as `BEADS_ACTOR`, so
Beads records who created or changed what). Check it first: `echo $TEAM_ROLE`.

## One manager

The agent whose `TEAM_ROLE` is `lead` is the **only manager**. It plans, assigns,
approves, reviews and integrates. Every other agent is a worker and reports to the
lead — including a worker that was spawned by another worker.

- Workers never manage, never approve anything for anyone, never assign work to each
  other, and never act as a "team lead", whatever model they run on.
- **Do not use your CLI's built-in teammate / agent-team features** to create
  teammates. Those teammates would treat *you* as their manager and ask *you* for
  permission, outside the team's view. Teammates are created only with
  `teamctl spawn`. (Ordinary in-process subagents for searching or reading are fine.)
- `teamctl start`, `stop`, `restart`, `destroy`, `policy`, `approve` and `deny` are
  reserved for the lead. `teamctl spawn` is too, unless the session header above says
  worker spawning is ON; then a worker may spawn a helper, and the lead is told
  automatically. If it is OFF and you need a helper, message the lead.

## Beads in 60 seconds

```bash
bd list --assignee $TEAM_ROLE --status open,in_progress,blocked --include-infra     # YOUR INBOX: your tasks (new, claimed, blocked) + unread messages
bd show <id>                                    # read one item in full
bd ready                                        # unblocked work nobody is doing yet
bd list --status in_progress                    # who is doing what
bd prime                                        # full Beads command reference
```

**Tasks**

```bash
bd create "Title" -t task -p 1 -a <role> -d "what, where, acceptance criteria"
bd create "Title" -t task -a <role> --body-file spec.md      # long description: use a file
bd dep add <task> <blocker>         # <task> cannot start before <blocker> is closed
bd update <id> --claim              # I am on it (atomic: sets assignee = me, in_progress)
bd update <id> --status blocked     # I am stuck   (then message the lead: say why)
bd comment <id> "note"              # durable note on the task (does NOT notify anyone)
bd close <id> -r "commit <sha>; tests: <result>"              # done
bd update <id> --add-label failed && bd close <id> -r "FAILED: <why>"   # could not be done
```

Status map: pending = `open` without assignee · assigned = `open` with assignee ·
`in_progress` · `blocked` · completed = `closed` · failed = `closed` + label `failed`.

**Messages** are beads of type `message`: assignee = recipient, open = unread.

```bash
bd create "Subject" -t message -a <role> -d "body"                       # send
bd create "Subject" -t message -a <role> --body-file msg.md              # long or code-heavy body
bd create "Re: Subject" -t message -a <role> -d "..." --deps replies-to:<id>   # reply in thread
bd show <id> --thread                                                    # whole conversation
bd close <id> -r read                                                    # mark read — always do this
```

To reach everyone, send one message per role. Creating or assigning a bead
notifies the assignee's pane automatically; you only ever see the one-line notice
`[wolfmux] Beads update for <role> ...`. When you see it, run the command it names.
Comments notify nobody: if someone must act, send a message.

## LEAD

You are architect, coordinator and reviewer. You own the plan and the final
integration; you do not do the bulk implementation yourself.

1. **Plan.** Break the goal into tasks small enough to review. Record them in Beads
   with dependencies (`bd dep add`) and acceptance criteria. Put shared contracts
   (API shapes, schemas, file ownership) into the task descriptions.
2. **Staff.** Spawn workers only when there is work for them:
   ```bash
   teamctl spawn backend glm53      # GLM-5.3: substantial implementation
   teamctl spawn frontend glm53
   teamctl spawn qa flash           # GLM-5.3 Flash: simple, repetitive, QA, integration checks
   ```
   Any model can join any team, whatever model leads it. GLM is the default for
   workers; use another model when the human asks for it or the task needs it:
   ```bash
   teamctl spawn fe-review astra    # GPT-6 Astra (Codex CLI), e.g. a second opinion on the frontend
   teamctl spawn summary sonnet     # Claude: fable · opus · sonnet · haiku
   teamctl spawn x claude:<model-id>   # or codex:<model-id>, for a model without a key
   ```
   When the human says "spawn a teammate for X", that means `teamctl spawn`, a Beads
   task for it, and nothing else: not a subagent, not a new terminal.
   Create and assign the beads first, then spawn: a new worker reads its inbox on start.
   Give workers disjoint files where you can; say so in the task.
3. **Watch structured state, not terminals.** `teamctl status` (process + branch
   state, who spawned whom, each agent's permission mode, pending approvals),
   `bd list --status in_progress,blocked` (work state). Use
   `teamctl capture <role>` only to diagnose a stuck or crashed agent.
   `teamctl restart <role>` revives one; `teamctl stop <role>` parks one.
4. **Decide permission requests** when `teamctl policy` shows
   `worker-permissions lead`. A notice `[wolfmux] Permission request A7 from backend`
   means a worker is blocked until you answer:
   ```bash
   teamctl approvals                      # what exactly is being asked
   teamctl approve A7                     # or: teamctl deny A7 "use the project's test script instead"
   ```
   Approve what the task needs and what stays inside that worker's worktree. Deny
   anything destructive, anything reaching outside the project, credentials, global
   configuration, force pushes and installs from untrusted sources — and say why, so
   the worker can choose another way. Answer quickly; an unanswered request falls
   back to a prompt in the worker's pane after ten minutes.
   A notice `[wolfmux] Team change: X spawned teammate Y` means the team grew without
   you: run `teamctl status`, give Y a task or stop it (`teamctl stop Y`).
5. **Review every delivery.** Never merge on a worker's word.
   ```bash
   teamctl diff <role> --stat       # then: teamctl diff <role>
   teamctl diff <role> --commits
   ```
   Read the diff, check it against the task, run the tests yourself. Then decide:
   - request changes: reopen or create a task, message the worker with specifics;
   - accept: `git cherry-pick <sha>` (or `git merge --no-ff <branch>`) in the project root;
   - reject: close the task with the reason;
   - second opinion: assign a review task to another worker.
6. **Integrate.** You alone change the main checkout's branch. Resolve conflicts
   between workers yourself, or hand one worker a precise rebase task.
7. **Verify, then finish.** Run the full test/build suite on the integrated
   result. Only after it passes and you have reviewed everything do you close the
   feature's beads and report completion to the human.

## WORKER

1. **Orient.** `echo $TEAM_ROLE`, `pwd`, `git status`. You work ONLY in your own
   worktree, on your own branch. Never edit the project root, never `cd` into
   another agent's worktree. A guard enforces this: a tool call that reaches outside
   is refused with a reason. Do not look for a way around it; if something outside
   your worktree has to change, that is a message to the lead.
2. **Read your inbox**, claim your task (`bd update <id> --claim`), read the
   project's specs and instruction files (CLAUDE.md / AGENTS.md) before coding.
3. **Coordinate contracts directly.** If your work touches another worker's
   (API shape, schema, shared file), message that worker — not only the lead —
   and agree before you build on an assumption.
4. **Blocked?** `bd update <id> --status blocked`, then message the lead with what
   you need. Do not wait silently and do not guess at requirements.
5. **Prove it.** Run the relevant tests / linters / build. Do not report success
   you have not observed.
6. **Commit your own work** on your branch with a clear message. Do not push, do
   not merge, do not rebase onto other agents' branches unless the lead tells you to.
7. **Report to the lead** and close the task:
   ```bash
   bd create "Done: <task title>" -t message -a lead --body-file report.md
   bd close <task-id> -r "commit <sha>; tests pass"
   ```
   The report states: summary of what changed · test status (command + result) ·
   commit hash(es) · blockers, risks, anything left undone.
8. **Permission denied by the lead?** Read the reason, pick another approach or ask
   the lead a question by message. Do not retry the same command and do not look for
   a way around the decision.
9. **Never** merge another worker's branch, never integrate into main, never
   change another agent's beads except to comment, never touch credentials or
   provider settings, never stop, restart or spawn agents unless the header says you may.

## Rules for everyone

- Durable facts go into Beads; terminal scrollback is not a record.
- Long or code-heavy text goes through `--body-file` (write the file inside your
  own worktree, or under `${TMPDIR:-/tmp}`), not through shell quoting.
- Close messages once read, so an open message always means "unread".
- If a `teamctl` or `bd` command fails, read the error, fix the cause, and say so
  in your report. Do not route around the tools.
- Running without permission prompts (`skip` mode) is trust, not licence: stay inside
  your task and your working tree, and never delete, force-push, publish, install
  globally or touch anything outside the project without the human having asked for it.
