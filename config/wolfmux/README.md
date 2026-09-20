# Wolfmux — a local multi-model AI development team in tmux

One lead (Fable **or** Astra) plus any number of GLM workers, every agent visible in
its own tmux pane, all inference on subscriptions — no API keys, no metered proxy.

```
                     LEAD  (pick one)
          claude-fable            codex-astra
          Claude Code             Codex CLI
          Fable 5.1               GPT-6 Astra
          Claude subscription     ChatGPT/Codex subscription
                 └──────────┬──────────┘
        teamctl  = tmux panes · models · worktrees · lifecycle
        bd       = tasks · dependencies · messages   (Beads)
                            │
      ┌─────────────────────┼─────────────────────┐
  claude-glm           claude-glm           claude-glm-flash
  backend · GLM-5.3    frontend · GLM-5.3   qa · GLM-5.3 Flash
      └──────────── Z.ai GLM Coding Plan ─────────┘
```

`teamctl` never stores a task or a message, and Beads never touches tmux. The only
glue is a three-line Beads hook that calls `teamctl nudge <role>` when a bead needs
someone, which types one fixed line into that agent's pane. Bodies stay in Beads.

## One-time setup

```bash
# Z.ai Coding Plan key -> macOS Keychain (you are prompted; nothing is echoed or logged)
security add-generic-password -U -s zai-coding-plan -a "$USER" -l "Z.ai Coding Plan API key" -w

teamctl doctor        # must show no "!! WARNING !!" lines
```

## Starting with Fable

```bash
cd ~/code/your-project
teamctl start fable
```

## Starting with Astra

```bash
teamctl start astra
```

Same session, same workers, same commands; only the lead's launcher differs.
The first start in a repository offers to initialize Beads in stealth mode
(`bd init --stealth --skip-hooks --skip-agents`): no commit, no tracked files, no
git hooks, no AGENTS.md/CLAUDE.md changes. Use `--init-beads` to skip the question,
or run your own `bd init` flavour first.

`Ctrl-b d` detaches; the team keeps running. `teamctl attach` comes back.

## Spawning workers

```bash
teamctl spawn backend glm53      # GLM-5.3: substantial implementation
teamctl spawn frontend glm53
teamctl spawn qa flash           # GLM-5.3 Flash: simple / repetitive / QA
teamctl spawn fe-review astra    # any model can join any team: fable · opus · sonnet · haiku · astra
teamctl spawn x claude:<model-id>   # …or codex:<model-id>, for a model that has no key
```

Each worker gets its own branch `ai/<role>-<timestamp>`, its own worktree under
`~/.wolfmux/worktrees/<project>/`, its own pane titled `<role> · <model>`, and
`TEAM_ROLE` / `BEADS_ACTOR` set to its role. Panes re-tile automatically
(lead top-left). A worker reads its Beads inbox as soon as it boots, so assign
work first, then spawn. Options: `--base <ref>`, `--no-kickoff`.

## One manager, permissions, spawning

The lead is the only manager. `start`, `stop`, `restart`, `destroy`, `policy`,
`approve` and `deny` work for the lead and for you at your own terminal; a worker
that tries them is refused (exit 77).

```bash
teamctl policy                                  # show this project's policy
teamctl policy worker-spawn on|off              # may workers run `teamctl spawn`?  default off
teamctl policy worker-permissions skip|lead|ask # default skip
teamctl policy lead-permissions skip|ask        # default skip
teamctl start fable --worker-permissions lead --worker-spawn on    # or set them at start
```

| Permission mode | Meaning |
|-----------------|---------|
| `skip` | the CLI's bypass mode (`--dangerously-skip-permissions`, Codex: `--dangerously-bypass-approvals-and-sandbox`). Nothing is asked. Deny rules and explicit ask rules (`teamctl destroy`) still apply. |
| `lead` | workers only. Every request a worker would have shown is sent to the lead: `teamctl approvals`, then `teamctl approve A7` or `teamctl deny A7 "reason"`. No answer in 10 minutes → the prompt appears in the worker's pane. |
| `ask` | the normal prompt in that agent's own pane. |

Permission changes apply when an agent is started or restarted
(`teamctl restart <role> --continue` keeps its conversation). `worker-spawn` applies at
once. Defaults for new projects live in `~/.config/wolfmux/config`.

When worker spawning is on and a worker spawns someone, the new agent is a normal team
member (own pane, branch, worktree), reports to the lead, shows up in `teamctl status`
under SPAWNED BY, and the lead's pane gets `[wolfmux] Team change: …`.

Inside workers, Claude Code's own agent-teams feature is switched off. With it on, any
subagent a worker names becomes a teammate that treats the *worker* as its team lead and
asks *it* for permission — a second manager outside the team's view. Your own sessions
and the lead keep the feature exactly as you configured it.

## Messaging (Beads)

```bash
bd create "Subject" -t message -a backend -d "body"            # send; recipient's pane is notified
bd create "Subject" -t message -a backend --body-file msg.md   # long / code-heavy body
bd list --assignee $TEAM_ROLE --status open,in_progress,blocked --include-infra    # inbox: your tasks (new, claimed, blocked) + unread messages
bd show <id>                    # read            bd close <id> -r read       # mark read
bd create "Re: ..." -t message -a frontend -d "..." --deps replies-to:<id>    # reply
bd show <id> --thread           # conversation    bd list --type message --all    # history
```

Broadcast = one message per role. Lead and workers use exactly the same commands,
and workers message each other directly.

## Tasks (Beads)

```bash
bd create "Title" -t task -p 1 -a backend -d "what + acceptance criteria"
bd dep add <task> <blocker>        bd ready        bd list --status in_progress,blocked
bd update <id> --claim             bd update <id> --status blocked
bd close <id> -r "commit <sha>; tests pass"
```

Status map: pending = open/unassigned · assigned = open+assignee · in_progress ·
blocked · completed = closed · failed = closed + label `failed`.

## Monitoring

```bash
teamctl status [--json]     # policy, pending approvals; per role: model, state, pane, permission mode, spawned by, branch, commits ahead, dirty
teamctl panes               # what tmux reports: command, pid, cwd
teamctl capture backend     # last 80 lines of a pane   (-n 200 | --all;  teamctl log backend)
teamctl focus backend       # jump to a pane            teamctl nudge backend   # re-notify
```

Process state comes from tmux, work state from Beads; terminal text is never parsed.

## Several teams in one project

```bash
teamctl start fable --team review    # a second team, named by you; its own session, lead and workers
teamctl status                       # all teams: TEAM, 🐺 lead, 🐶 teammates
teamctl attach --team review         # add --team <name> to any command once there are several
```

With one team you never type `--team`. `teamctl start <model>` while the first team runs
under another model does not open that team; it shows you both commands. All teams share
the project's Beads; agents of a named team are `<team>.<role>` there.

## Deleting a team

```bash
teamctl teams                              # DISK shows what each team takes
teamctl destroy --team review --purge      # shows what would be lost, asks, then deletes the whole team
teamctl destroy --team review --purge --force    # …even with uncommitted or unmerged work
```

A worker costs a checkout of your tracked files plus whatever it installs or builds; the
lead costs nothing. Purge removes the session, every worktree, the team's `ai/…` branches,
records and transcripts; never your checkout, other branches, Beads or other teams.

## The wolf, and notifications

- Arrangement: the lead is the large pane on the left, teammates are stacked on the right,
  and the lead stays put when workers come and go. `teamctl layout lead-top|tiled|lead-left`
  changes it for the project; `Ctrl-b Space` cycles, `Ctrl-b T` puts it back.
- Quit every agent and run `teamctl start` again: you get a new session, not the finished
  panes. Quit only the lead: `teamctl start` brings it back, workers keep running.
  Add `--continue` to resume the lead's last conversation.
- Opening a team (`teamctl start`, `teamctl attach`) shows the wolf in a popup. Any key
  closes it, or 3 seconds. `WOLFMUX_SPLASH=off` in `~/.config/wolfmux/config` removes it.
- The manager is the wolf: `🐺 lead · <model>` in its pane border, an amber border
  whether focused or not, `🐺 team/lead` inside Claude Code. Every teammate is a dog of
  the pack: `🐶 backend · <model>`, `🐶 team/backend`, grey border.
  The status line starts with `🐺 WOLFMUX`; the terminal tab is titled `🐺 <session>`.
- When an agent finishes a turn you get a desktop notification (`🐺 lead: …`,
  `🐶 backend: …`). Click it and you are at the team: if it is open in a tab, that tab
  comes forward (the notification went through that terminal); if it is on no screen,
  a new window opens attached to it (the notification then comes from Wolfmux.app, the
  small application `install.sh` builds; allow its two macOS prompts once).
  `WOLFMUX_NOTIFY=all` (default) · `lead` · `off`.
- Both reach an agent when it starts: after an update run `teamctl restart <role> --continue`.

## Git

```bash
teamctl worktrees
teamctl diff backend --stat        # then: teamctl diff backend | --commits | --names | --working
git cherry-pick <sha>              # the lead integrates, in the project root
```

Completion flow: worker tests → commits → sends a `Done:` message (summary, test
status, commit hash, risks) → closes its task → lead reviews the diff → requests
changes, cherry-picks, rejects, or asks another worker to review. The lead owns
integration. Full rules: `TEAM_PROTOCOL.md` (injected into every agent at launch).

## Clearing up

```bash
teamctl destroy --worktrees        # end the team; remove workers that hold nothing
teamctl remove qa                  # one stopped worker: worktree, branch, record
teamctl remove research --force    # ...even though it holds work (lists it, asks once)
```

A worker with uncommitted files or unmerged commits is never removed silently: keep its
work with `git merge <branch>`, or discard it with `--force`.

## Stopping

```bash
teamctl stop backend               # close one pane; worktree, branch, commits stay
teamctl restart backend            # same worktree + branch   (--continue resumes its conversation)
teamctl destroy                    # end the tmux session; keeps everything else
teamctl destroy --worktrees        # also removes CLEAN worktrees and FULLY MERGED ai/* branches
```

`destroy` never deletes source files, commits, unmerged branches, dirty worktrees,
credentials or Beads data, and always asks first (`--yes` to skip).

## Diagnostics

```bash
teamctl doctor                                  # launchers, inherited keys, settings overrides, Keychain, logins
WOLFMUX_DRY_RUN=1 claude-glm                    # what a launcher would exec — no secrets, nothing started
```

## Where things live

| What | Where |
|------|-------|
| Launchers + CLI | `~/bin/` — `teamctl`, `claude-fable`, `codex-astra`, `claude-glm`, `claude-glm-flash` → `claude-glm`, `codex` → ChatGPT.app's bundled CLI |
| Code, tmux config, protocol, this file | `~/.config/wolfmux/` (`lib/*.sh`, `hooks/beads-nudge`, `tmux.conf`, `TEAM_PROTOCOL.md`, `config`, `glm-worker-settings.json`) |
| Z.ai credential | macOS login Keychain, service `zai-coding-plan`. Nowhere else. |
| Claude / Codex logins | wherever those CLIs keep them (`/login`, `codex login`); untouched |
| Worktrees | `~/.wolfmux/worktrees/<project>-<hash>/<role>-<timestamp>/` |
| teamctl state (role ↔ model ↔ worktree, event log) | `~/.wolfmux/state/<project>-<hash>/` — nothing is written into your repository |
| Tasks + messages | the project's `.beads/` (embedded Dolt; locally excluded from git in stealth mode) |
| tmux | dedicated server: `tmux -L wolfmux`; your default tmux and `~/.tmux.conf` are untouched. A team started before the rename from "ai-team" stays on `tmux -L ai-team` until it ends; `teamctl` follows it |
| Permissions | `~/.claude/settings.json` (allow `teamctl`, `bd`, `git status`, `git worktree list`; ask on `teamctl destroy`), `~/.codex/rules/wolfmux.rules` |

## How subscription separation works

- **No global variable, no settings entry.** Nothing in `~/.zshrc` or
  `~/.claude/settings.json` points anywhere. Plain `claude` is exactly what it was.
- **Launchers scrub, then exec.** Each launcher removes every provider / credential /
  model override (`ANTHROPIC_*`, `CLAUDE_CODE_USE_*`, `OPENAI_*`, `CODEX_API_KEY`, …)
  and every inherited agent-session variable from *its own process*, then execs the CLI.
- `claude-fable`: no key, no endpoint → the only credential left is your `/login`.
- `codex-astra`: `forced_login_method="chatgpt"`, `model_provider="openai"`,
  `model="gpt-6-astra"` → an API key cannot be used even if one appears later.
- `claude-glm*`: sets `ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic` (the Coding
  Plan endpoint) inside that process only, and maps **every** Claude alias (opus, sonnet,
  fable, haiku, subagents) to `glm-5.3` / `glm-5.3-flash` — the only two ids the plan
  covers. The key reaches Claude Code through `apiKeyHelper` (a Keychain read), so it is
  never in the environment, the agent's subprocesses, transcripts or tmux scrollback.
- **Login guard.** Measured on a localhost mock endpoint: a Claude Code process that
  inherits a custom base URL but no token sends your real claude.ai login to that URL.
  Every GLM worker therefore carries an inert `CLAUDE_CODE_OAUTH_TOKEN` placeholder that
  outranks the stored login, so anything a worker spawns fails closed at Z.ai instead of
  handing it your Claude token. `claude-fable` drops that placeholder again.
- The team tmux server is started with a scrubbed environment, so panes inherit none of it.

Launcher knobs are read from `~/.config/wolfmux/config` (a pane's environment comes from
the tmux server, not from the shell you typed `teamctl spawn` in):
`WOLFMUX_GLM_AUTH_MODE=env` switches workers to Z.ai's documented `ANTHROPIC_AUTH_TOKEN`
variable — use it if workers report an authentication error in the default helper mode;
`WOLFMUX_GLM_CONTEXT=1m` opts into the 1M window (uses quota faster); by default the
launcher declares a 200k window, which is what keeps Claude Code from printing its
"isn't described by this version's model catalog" notice in worker panes.
`~/.config/wolfmux/glm-worker-settings.json` is a Claude Code settings overlay applied to
GLM workers only. It ships with `claude-mem` turned off there: that plugin runs a
long-lived summarizer daemon which inherits the environment of whichever session starts
it, and one started from a GLM worker would route your normal sessions' memory traffic
to Z.ai. Delete the file to make workers identical to your normal sessions.

What no local tool can prove: account-side switches. Keep claude.ai "extra usage" off,
do not buy Codex credits, and keep the Z.ai cash balance at zero.

## Verify provider and model inside each CLI

| Pane | Type | Expect |
|------|------|--------|
| Fable lead | `/status` | Login method: Claude subscription · no API key · no custom base URL · model Fable 5.1 |
| Astra lead | `/status` | Signed in with ChatGPT · model `gpt-6-astra` |
| GLM worker | `/status` | Base URL `https://api.z.ai/api/anthropic` · auth: apiKeyHelper (or ANTHROPIC_AUTH_TOKEN in env mode) · model `glm-5.3` / `glm-5.3-flash` |

## Updating safely

```bash
claude update                 # native installer; launchers resolve `claude` at run time
# Codex: update the ChatGPT desktop app (its bundled CLI is what ~/bin/codex points to).
#        A standalone install (curl -fsSL https://chatgpt.com/codex/install.sh | sh) lands in
#        ~/.local/bin, which precedes ~/bin, so it takes over automatically.
bd export --all > beads-backup.jsonl   # then replace ~/.local/bin/bd with a verified release; see Beads upgrade guide
teamctl doctor                # after any update
```

Never run `codex login --with-api-key`, never export `ANTHROPIC_API_KEY` /
`OPENAI_API_KEY` globally, never paste a Z.ai block into `~/.claude/settings.json`.

## tmux keys (team server only)

Mouse: click = focus, drag border = resize, wheel = scroll. `Ctrl-b` then: arrows =
move · `Ctrl`-arrows / `Alt`-arrows = resize · `z` = zoom · `T` = re-tile · `q` = pane
numbers · `d` = detach · `"` `%` `c` = new pane/window in the current directory.

## Uninstall (the CLIs stay untouched)

```bash
teamctl destroy --worktrees                      # in each project that has a team
rm ~/bin/teamctl ~/bin/claude-fable ~/bin/codex-astra ~/bin/claude-glm ~/bin/claude-glm-flash ~/bin/codex
rm -r ~/.config/wolfmux ~/.wolfmux
rm ~/.codex/rules/wolfmux.rules
security delete-generic-password -s zai-coding-plan
# ~/.zshrc: delete the block between ">>> wolfmux >>>" and "<<< wolfmux <<<"
# ~/.claude/settings.json: delete the teamctl / bd / git / tmux allow lines and the "ask" entry
#   (or restore ~/.claude/settings.json.backup-<timestamp>)
# Beads itself (optional): rm ~/.local/bin/bd; per project: rm -r .beads and its .git/info/exclude lines
```

## Manual cleanup

```bash
tmux -L wolfmux ls                          # sessions on the team server
tmux -L wolfmux kill-server                 # stop every team at once
git worktree list && git worktree prune     # in a project
git branch --list 'ai/*'                    # leftover worker branches (delete merged ones: git branch -d)
ls ~/.wolfmux/state ~/.wolfmux/worktrees    # per-project state and worktrees
```

## Limits worth knowing

- A worker's banner reads `API Usage Billing`. That is Claude Code's label for any
  session authenticated with a key instead of a claude.ai login. For a GLM worker the
  key is your Z.ai Coding Plan key and the endpoint is Z.ai's; nothing is billed by
  Anthropic. `/status` in the pane shows the base URL.
- The manager check is cooperative: every agent is your macOS user, so it stops
  mistakes and role confusion, not a deliberately hostile process.

- Notifications are typed into a pane. If an agent is mid-turn its CLI queues the line;
  if a CLI is showing a modal dialog (first-run folder trust), answer the dialog first.
- Beads runs in embedded mode (no daemon): writes are serialized by a file lock.
  16 parallel writers were tested clean, but each waits its turn. Heavy swarms should
  switch the project to Beads server mode (`bd init --server`, needs the `dolt` CLI).
- Comments on beads notify nobody; send a message when someone must act.
- Workers share your `~/.claude` (plugins, hooks, skills, permissions). That is
  deliberate, and it means hooks you add there also run inside GLM workers.
