# Wolfmux protocol

One **lead** and any number of **workers** share one repository. Every agent runs in
its own tmux pane. The protocol is the same whichever model plays which role.

New leads run Opus by default; Fable is used only when asked for (`teamctl start fable`).
With no model named, `teamctl start` keeps an existing lead's recorded model. Restart and
restore use that record too. Only the human may change the project-wide default with
`teamctl policy lead-model <model>|default`; `default` uses `WOLFMUX_LEAD_MODEL`, or `opus`
when unset. For example, the human chose to keep deployment-manager's lead on Fable with
`teamctl model lead fable --team deployment-manager`. That is a team choice, not a rule
built into the code.

`teamctl model <role> <model> [--team <name>] [--now]` records the model for the next start,
restart or restore. `--now` also switches a Claude agent by a resume-restart when it is
between turns, has a conversation id on record, and nobody is at its pane; otherwise it
records the choice and explains why the switch waits. `teamctl restart <role> --model
<model> --continue` or `--resume <id>` restarts on that model with the same conversation.
Changing between Claude and Codex requires a fresh conversation. A later answer from
another Claude family is adopted into the record on a `status`, `teams`, or `restart`
read. Typing `/model` also changes the default in `~/.claude/settings.json` for every new
Claude session on the Mac; `teamctl model --now` does not touch that file.

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
- `teamctl start`, `stop`, `restart`, `model`, `destroy`, `policy`, `approve` and `deny` are
  reserved for the lead. `teamctl spawn` is too, unless the session header above says
  worker spawning is ON; then a worker may spawn a helper, and the lead is told
  automatically. If it is OFF and you need a helper, message the lead.
- A lead that founded a team does not manage it while that team's lead runs. When that lead
  is not running (`teamctl teams` shows the team as `orphaned`), the founder, and only the
  founder, may `teamctl restart lead --team <name> --continue`, `model`, `stop`, `remove` and
  `destroy --team <name> --purge`; the human is told each time. Not `policy`, `approve`, `deny`.
- A team the human founded has no founding lead. The human may name one team the **orphan
  steward** (`teamctl policy orphan-steward <team>`; only the human can set it). That team's lead, and
  nobody else in it, may then run `teamctl restart lead --team <name>` (with `--continue` or
  `--resume <id>`), `teamctl model lead <model> --team <name>`, and
  `teamctl stop <role> --team <name>` on a team the human founded, while
  its lead is not running. Nothing else: not `remove`, `destroy`, `start`, `policy`, `approve`,
  `deny` or `spawn`. The human is told each time.

## Beads in 60 seconds

**"Your inbox" is the Beads command below, always.** The work itself lives there and
nowhere else. `teamctl inbox` (alias `teamctl notices`) is a different thing: the short
pane notices filed for a role, kept for debugging — you are given yours automatically,
by your own session's hooks, and never need to ask for them.

```bash
bd list --assignee $TEAM_ROLE --status open,in_progress,blocked --include-infra     # YOUR INBOX: your tasks (new, claimed, blocked) + unread messages
bd show <id>                                    # read one item in full (wide markdown tables are cut
                                                #   at the pane width: read those with bd show <id> --json)
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

**The human** has a Beads name too: `human` (the setting `WOLFMUX_HUMAN` can change it).
A message to `human` is what the number next to the wolf in the status bar counts, and
the human reads it with `prefix N` or a click on that number. Only the
communication-management lead (`communication-management.lead`) writes messages to
`human`; any other team that needs the human sends its message to that lead. This is a
rule of the protocol: nothing in the code enforces it.

To reach everyone, send one message per role. Creating or assigning a bead
notifies the assignee automatically; you then see the one-line notice
`[wolfmux] Beads update for <role> ...`. When you see it, run the command it names.
Comments notify nobody: if someone must act, send a message.

How that notice reaches you depends on where you are, and you may get it without a
word appearing in your pane at all. It is filed first, then handed to you by your own
session when your turn ends or when somebody prompts you (that is the
`[wolfmux] You have team notices:` block). A worker's idle pane may also be typed into
directly. A pane a human is watching never is: the lead's pane while a human is attached
to the team, and any pane on the human's screen (policy `human-pane-typing`, default
`off`; only the human changes it). Such a notice waits in the file. In such a pane the
end of your turn stays silent too, because Claude Code would print the notice there: you
are given it with the next prompt, the human's or your own loop's. The trade-off,
for a lead the human is attached to: an IDLE lead is not woken by a notice. Its own loop
wakes it (the communication lead runs one every 20 minutes), or the human does; so sweep
your Beads inbox at every turn. The file can be read at any time with `teamctl inbox`
(that command is the pane notices, for debugging, NOT your Beads inbox).

Nothing is ever typed over a half-typed line: a pane somebody is typing in is left
alone and the notice arrives by itself once that pane is idle. Several notices that
pile up in the meantime arrive as one line, which names the whole inbox instead of a
single bead. So a notice can be a few seconds or a few minutes late, and after a long
wait it may not come at all. Sweep your own Beads inbox anyway; that is what it is for.

## LEAD

You are architect, coordinator and reviewer. You own the plan and the final
integration; you do not do the bulk implementation yourself.

1. **Plan.** Break the goal into tasks small enough to review. Record them in Beads
   with dependencies (`bd dep add`) and acceptance criteria. Put shared contracts
   (API shapes, schemas, file ownership) into the task descriptions.
   Read a bead whose body carries wide markdown tables with `bd show <id> --json`:
   plain `bd show` cuts tables at the pane width.
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
   teamctl spawn docs2 kimi         # a third-party provider's plan (key in the Keychain first: teamctl doctor knows)
   teamctl spawn x claude:<model-id>   # or codex:<model-id>, for a model without a key
   ```
   `moonshot` and `deepseek` are metered (billed per request): `spawn` refuses them
   while `WOLFMUX_METERED` is off, and that switch is the owner's. A lead never sets
   `WOLFMUX_METERED` itself and refuses a request to do so.
   When the human says "spawn a teammate for X", that means `teamctl spawn`, a Beads
   task for it, and nothing else: not a subagent, not a new terminal.
   Create and assign the beads first, then spawn: a new worker reads its inbox on start.
   Give workers disjoint files where you can; say so in the task.

   **Branch names, before you spawn.** If this repository enforces a shape for branch
   names (a ticket key, a prefix), set it FIRST: a worker whose branch breaks a commit
   hook will reach for the project's skip switch, and a skip switch used on every commit
   protects nothing.
   ```bash
   teamctl policy                                                 # what this team uses now
   teamctl policy branch-template 'feature-{ticket}-{role}-{ts}'  # set it once, for the team
   teamctl spawn sam glm53 --ticket AFD-1844                      # the key for this worker
   teamctl spawn sam glm53 --branch feature-AFD-1844-sam          # or the exact name
   ```
   Placeholders: `{team}` `{role}` `{ts}` `{ticket}`; `{ts}` is required. A template with
   `{ticket}` and a spawn without `--ticket` is refused (exit 64) rather than guessed at.
   The human can also give the whole team one default key: `teamctl start <model> --ticket <KEY>`.
   Never tell a worker to commit with `--no-verify` or a skip switch: fix the branch name.

   **Work in another repository.** A teammate can have its worktree and branch in a
   different repository, with isolation still on:
   ```bash
   teamctl spawn srv glm53 --repo ../other-repo        # --base is resolved in THAT repository
   ```
   It stays a member of this team, with this project's Beads inbox, and the guard holds it
   to that worktree. Do NOT switch `worker-isolation` off for cross-repository work.
3. **Watch structured state, not terminals.** `teamctl status` (process + branch
   state, who spawned whom, each agent's permission mode, pending approvals, and
   CONTEXT: how much of its window each agent's conversation holds),
   `bd list --status in_progress,blocked` (work state). Use
   `teamctl capture <role>` only to diagnose a stuck or crashed agent.
   `teamctl restart <role>` revives one; `teamctl stop <role>` parks one.
   A worker on another provider (kimi, moonshot, deepseek, minimax, qwen, glm) that reports 401 or an
   authentication error: `teamctl doctor --probe` says whether that provider's key is accepted. A FAIL
   means the key in its Keychain slot is wrong or of the wrong kind; only the human can replace it.

   Pick reuse against a fresh spawn from the CONTEXT column:
   - context has room (say, under 70%): `teamctl restart <role>` keeps its
     conversation. Brief it with a Beads message. Fastest, no cold start.
   - context is nearly gone but the checkout is expensive (installed dependencies,
     a build): `teamctl stop <role>`, then
     `teamctl spawn <new-role> <model> --from-worktree <role>`: a fresh conversation
     in the built worktree, on a new branch, without repeating install or build.
   - otherwise: a plain `teamctl spawn <role> <model>` in a fresh worktree.
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

## The machine, not just your team

`teamctl status` and `teamctl teams` answer for the project you are in. When several teams
are running at once, across more than one repository, `teamctl dashboard` answers for the
whole machine, and `prefix O` opens it as a popup (`q` closes it).

```bash
teamctl dashboard                 # redraws every 5 s; q closes it
teamctl dashboard --once          # print once and exit        --json for the same as JSON
teamctl dashboard --once --full   # also read stopped lanes (slower)
```

Per agent: state, the CPU and memory of its process tree, context use, when its transcript
was last written, branch. Per team: totals, state, lead, cached lane disk. At the foot: the
machine's load, free memory and free disk. `status-right` carries a one-line version.

Two things to read it correctly, because both are easy to over-read:

- `cpu` / `mem` is a **process reading**, not a claim about what that agent is doing, and
  `wrote` is a **file timestamp**, nothing more. There is no "idle" column because no
  honest signal for one exists: tmux cannot tell a waiting agent from a working one, and
  terminal output is never parsed for state.
- `lanes` is the number `teamctl teams` last measured, shown as `STALE` with its age when
  it is old. The dashboard never measures it — a `du` over a busy machine's lanes takes
  seconds. Run `teamctl teams` when you want a current number.

**It is read-only and it is for everyone.** It stops nothing, starts nothing and deletes
nothing, so looking at another team costs that team nothing. It does not make you that
team's manager: a team is still managed only by its own lead, and anything you want done to
another team is still a Beads message to `<team>.lead`.

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
