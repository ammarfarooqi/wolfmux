# Wolfmux

![Wolfmux: the wolf, and a terminal with one lead and three workers in tiled tmux panes](docs/diagrams/hero.svg)

A local, multi-model AI development team on one Mac. One **lead** agent plans,
delegates and reviews; any number of **worker** agents implement in parallel. Every
agent is a real CLI in its own visible tmux pane, on its own git branch and worktree.
The lead is the wolf — 🐺 in its pane border, an amber frame, the large pane on the left —
and every teammate is a dog of the pack (🐶), so you can always tell the manager from the rest.

**Inference runs on subscriptions: the Claude, ChatGPT and coding-plan keys you
already have. Two providers are pay-as-you-go APIs (Moonshot's platform, DeepSeek);
they refuse to run until you store their key and set `WOLFMUX_METERED=on` yourself.
No metered proxy, ever.**

![Architecture: teamctl is the control plane, Beads the data plane, one hook connects them](docs/diagrams/architecture.svg)

## What you get

| | |
|---|---|
| **Any model in any seat** | Fable, Opus, Sonnet, Haiku, GPT-6 Astra, GLM-5.3 and GLM-5.3 Flash, plus the provider keys `kimi`, `moonshot`, `deepseek`, `minimax`, `qwen`, as lead or as teammate, mixed freely in one team ([models](#models)) |
| **Several teams per project** | the first is called `default`, every further one is named by you; each has its own session, lead and teammates; `teamctl status` shows them as a tree. Teams message each other through Beads, and a lead can found a fresh team and hand work over to it, and recover or delete it if its lead dies ([diagram](docs/diagrams/teams.svg)) |
| **One worktree per teammate** | its own branch and checkout, outside your project. A guard refuses a teammate's tool calls that change your checkout, read another teammate's worktree, switch or delete branches, push to main or drive tmux (Claude Code teammates; Codex has no such hook) |
| **You always find the manager** | the 🐺 lead is the amber pane on the left, 🐶 teammates are stacked on the right. A desktop notification tells you when an agent finishes, and clicking it opens the team |
| **Nothing is lost by accident** | `stop` and `destroy` keep worktrees, branches and commits. `remove` refuses while a teammate holds uncommitted or unmerged work, and lists it. `destroy --purge` shows each worktree's size, that same list and the total it frees, and asks before it deletes |
| **Subscriptions by default** | every launcher first removes inherited API keys and endpoint overrides from its own process, then starts its CLI; a provider's endpoint and model mapping exist only inside the launcher it belongs to, for that process only; every provider key lives in the Keychain, one service per provider; the two metered providers refuse to run until the owner sets `WOLFMUX_METERED=on` (`teamctl doctor` reports on all of it) |

## Quick start

```bash
git clone <this repo> ~/Documents/wolfmux && cd ~/Documents/wolfmux
./install.sh                                  # idempotent; backs up what it edits
security add-generic-password -U -s zai-coding-plan -a "$USER" -l "Z.ai Coding Plan API key" -w
teamctl doctor                                # no "!! WARNING !!" lines = ready

cd ~/code/your-project
teamctl start fable                           # or: teamctl start astra
teamctl spawn backend glm53
teamctl spawn qa flash
teamctl start fable --team review             # a further team in the same project, named by you; teamctl status shows them all
teamctl spawn fe-review astra                 # any model can join any team (fable · opus · sonnet · haiku · astra · claude:<id> · codex:<id>)
teamctl spawn review kimi                     # …and the provider keys: kimi · moonshot · deepseek · minimax · qwen
```

Then talk to the lead. It creates tasks and messages in Beads, spawns workers,
reviews their diffs with `teamctl diff <role>` and integrates what it approves.

## Commands

One command, `teamctl`, run inside your project. `teamctl help` prints this list;
[docs/USAGE.md](docs/USAGE.md) walks through a full session. With several teams in one
project, add `--team <name>` to any command (before or after it); with one team you never
need it. Tasks and messages are not teamctl's: they are Beads
([`bd` cheat sheet](docs/USAGE.md#beads-cheat-sheet)).

**Teams**

| Command | Does |
|---------|------|
| `teamctl start <model> [--team <name>] [--no-attach] [--continue] [--resume <session-id>]` | start a team with that model as its 🐺 lead, and open it. `--team` names a further team in the same project; `--continue` resumes the lead's **own** conversation (the id stored with it), `--resume` reopens the one you name; after the lead quit, the same command brings it back |
| `teamctl start … [--ticket <KEY>] [--init-beads\|--skip-beads] [--lead-permissions skip\|ask] [--worker-permissions skip\|lead\|ask] [--worker-spawn on\|off]` | `--ticket` is the team's default ticket key, used by a branch template that asks for one; `--init-beads` or `--skip-beads` answers the first start's question about Beads; the other three set the team's policy, at any start |
| `teamctl start <model> --team <new> --handover <bead-id>` | found a fresh team whose lead starts by reading that bead. A lead may run this too; you are notified. While that lead runs, the founder does not manage the team; once it is not running the founder may `restart`, `stop`, `remove` or `destroy` it, and `start <model> --team <it> --continue`; you are told each time |
| `teamctl status [--json]` (alias `workers`) | every team as a tree (one team with `--team`, or from inside a pane): 🐺 lead, 🐶 teammates, model, running or stopped, branch, commits ahead, uncommitted files, and CONTEXT: what each agent's conversation holds (tokens, and the share of the window when the model's window is known, from the transcript of its own conversation; a model whose window is not known shows the tokens with no percentage, never a guessed share). A team without a running lead says it is orphaned and who may act on it; `--json` has `founder`, `orphaned`, `session_id`, `context_tokens`, `context_window` and `requests` |
| `teamctl teams [--json]` | the short list: state (`running`, or `orphaned` when its lead is not running), lead, number of agents, the disk its teammates' worktrees take, and who founded it. Under the table, each orphaned team says who may act on it: you, and the lead that founded it |
| `teamctl attach` (alias `open`) | open the team in this terminal (`Ctrl-b d` leaves it running) |
| `teamctl dashboard [--json] [--once] [--interval <seconds>] [--full]` | EVERY team on this machine, across every project, in one read-only view, and `prefix O` opens it as a popup (`q` closes it). Per agent: state, the CPU and memory of its whole process tree, context use, when its transcript was last written, branch. Per team: totals, state, lead, and the cached lane disk. At the foot: the machine's load, free memory and free disk. `--once` prints it and exits, `--interval` sets the redraw (default 5 s), `--full` also reads context and the transcript time for agents that are not running (slower), and `--socket <path>` asks that tmux server rather than the default one (the key binding hands its own over; the socket is never guessed). It never runs `du`: lane totals are the number `teamctl teams` left behind, and the view says so when that number is stale |
| `teamctl focus <role>` | jump to one pane |
| `teamctl layout [lead-left\|lead-top\|tiled]` | how the panes are arranged; `lead-left` is the default |

**Teammates**

| Command | Does |
|---------|------|
| `teamctl spawn <role> <model> [--base <ref>] [--branch <name>] [--ticket <KEY>] [--repo <path> \| --from-worktree <role>] [--no-kickoff] [--resume <session-id>] [--link-node-modules]` | a new 🐶 teammate with its own pane, branch and worktree. Any model, whoever leads. Refused when free disk is under `disk-min-gb` (policy `disk-guard`). `--branch` names the branch exactly; `--ticket` supplies the key a [branch template](#branch-names-and-other-repositories) asks for; `--repo` puts the worktree and the branch in **another** git repository, with the guard still on. `--from-worktree <role>` gives the fresh teammate the stopped worker's built worktree, on a new branch (its branch and commits stay), so node_modules and build output survive and no install or build is repeated. The worktree must be clean; the work is refused and listed otherwise (`--repo` does not combine with it: the worktree stays in its own repository). Only the lead, or you, may hand a worktree over; a worker is refused (exit 77) even with worker-spawn on. `--resume <session-id>` puts it into an existing conversation instead of a new one, and sends no kickoff. `--link-node-modules` points a brand-new lane's `node_modules` at its repository's copy instead of installing 2+ GB of its own — one directory for every lane, so an install in any lane changes them all |
| `teamctl stop <role>` | close its pane; worktree, branch and commits stay. Its build caches (`.next`, `dist`, …) are deleted, `node_modules` is kept, so `restart` stays cheap |
| `teamctl restart <role> [--continue] [--resume <session-id>]` | start it again in the same worktree; `--continue` keeps its own conversation, `--resume` reopens the one you name (`teamctl status --json` prints each agent's `session_id`). When the team's tmux session is gone (a reboot), `restart lead` starts the team again |
| `teamctl remove <role>… [--force] [--yes]` | take a stopped teammate off the books: worktree, branch, record, and the gigabytes they held. Refuses while it holds work that exists nowhere else, and lists it; `--force` discards it after one question |
| `teamctl nudge <role>\|--all [--id <bead-id>] [--quiet]` | re-send the one-line notification into a pane. The Beads hook does this by itself. A pane somebody is typing in is left alone: the notice waits for it to go idle (`deferred: …`, exit 3). Your own lead pane is not typed into at all while you are watching the team: the notice is filed instead (`filed: …`, exit 4) |
| `teamctl inbox [<role>] [--all] [--json] [--keep]` (alias: `notices`) | the pane notices filed for a role, newest last. Default: the lead of this team. Reading them clears the `📨` count in the status bar; it does not change whether the agent has had them. `--all`: every role of the team. `--keep`: leave them marked new. `prefix N` opens this in a popup. This is the short notices, NOT an agent's Beads inbox — the work itself is always `bd list --assignee <role> …` |

**Reviewing work**

| Command | Does |
|---------|------|
| `teamctl diff <role> [--stat\|--names\|--commits\|--working]` | a teammate's changes since its base |
| `teamctl worktrees` | branch, commits ahead and uncommitted files per teammate |
| `teamctl capture <role> [-n\|--lines <count>] [--all]` | recent terminal output of a pane, for diagnosing a stuck agent |
| `teamctl log <role>` | its full scrollback |
| `teamctl panes` | what tmux reports per pane: command, pid, directory |

**Policy and approvals**

| Command | Does |
|---------|------|
| `teamctl policy [<key> <value>]` | show or set, per team: `lead-permissions` skip\|ask · `worker-permissions` skip\|lead\|ask · `browser-writes` ask\|allow (DEFAULT ask; allow writes an explicit `permissions.allow` rule for `mcp__claude-in-chrome__*` into every agent's settings, lead and workers alike) · `worker-spawn` on\|off · `worker-isolation` on\|off (the worktree guard) · `lead-teams` on\|off (may the lead found teams) · `branch-template` (how this team names its workers' branches) · `disk-guard` refuse\|warn\|off · `disk-min-gb` a whole number of GB (0 = no limit) · `link-node-modules` on\|off |
| `teamctl approvals [--all]` | teammates' permission requests waiting for the lead (`worker-permissions lead`) |
| `teamctl approve <id>…\|--all` | allow them |
| `teamctl deny <id> "<reason>"` | refuse one, with the reason the teammate is shown |

**Disk**

A lane worktree is cheap to make and expensive to keep: on one project here each one
carried 2.3 GB of `node_modules`, 0.9 GB of `.next` and half a gigabyte of copied assets,
nothing ever removed any of it, 27 parked lanes reached 65 GB, and the machine filled its
disk and rebooted with every team's work in flight. So teamctl cleans up after its own
worktrees.

| Command | Does |
|---------|------|
| `teamctl prune [--team <name>] [--dry-run] [--keep-node-modules]` | take the build output of every **parked** lane of the team: `node_modules`, `.next`, `dist`, `.turbo`, `build`, `coverage`, `.cache`, `.parcel-cache`, `.vite`, `.svelte-kit`, `.nuxt`, `target`. One line per lane and a total in GB. A **running** lane is never touched, nor is anything git tracks, nor a lane that holds other uncommitted or untracked files — that one is skipped and named. `--dry-run` reports and deletes nothing (anyone may run it; the real thing is the lead's). `--keep-node-modules` takes the build caches only |
| `teamctl stop <role>` | the build caches of that lane; `node_modules` stays |
| `teamctl remove <role>` · `teamctl destroy --worktrees` | all of it: the worktree is going away anyway |
| `teamctl status` | free disk, what this team's lanes take, and the spawn guard |
| `teamctl teams` | **measures** the lanes (a `du` per lane, seconds on a busy machine). `teamctl status` reads the number this leaves behind and never measures, so it stays instant |

Most of a lane is not build output: measured on one machine, of 25 GB across 38 lane
worktrees only about 4 GB sat in a directory on that list — the rest is the checkout itself,
copied into every lane. `prune`'s "still held" line is that floor plus the whole of every
lane it skipped or left running, and says that `teamctl remove <role>` is what gives back
the part git tracks. `stop` deliberately keeps `node_modules`, so a lane parked for a week
keeps it for the week unless somebody prunes ([a known gap](docs/ROADMAP.md)).

`teamctl remove` refuses a lane that holds commits or files somebody wrote, and build output
is not that: a `node_modules` (the `--link-node-modules` symlink included), the build caches
and wolfmux's own cleanup trash are swept without a question. `build`, `dist` and `target`
are the exception — when git neither tracks nor ignores one of them, remove asks, because a
handwritten `dist/deploy.sh` lives exactly there.

What is never deleted: a source file, a commit, git state, anything git tracks (a project
that commits its `dist` keeps it), a worktree with uncommitted changes, your own checkout.
A lane that lost its `node_modules` needs one `npm install` before its tools run again;
nothing else of it changes. Each directory is renamed inside its own worktree before it is
deleted, so a cleanup killed halfway leaves a `.wolfmux-removing-*` directory that the next
run clears, never a half-deleted `node_modules` that looks installed.

**Ending, deleting, checking**

| Command | Does |
|---------|------|
| `teamctl destroy [--worktrees] [--yes]` | end the team. Every worktree is kept; `--worktrees` also removes teammates that hold nothing, and takes the build output of all of them first |
| `teamctl destroy --purge [--force] [--keep-transcripts] [--yes]` | delete the whole team and give its disk space back: shows sizes and any uncommitted or unmerged work, asks, then removes the session, worktrees, the branches teamctl created, records and its teammates' Claude Code transcripts. `--force` deletes that work too. Never touched: your checkout, other branches, Beads, other teams, the lead's own conversations |
| `teamctl doctor [--probe]` | billing and credential isolation report: launchers, inherited keys, settings overrides, Keychain, logins. `--probe` also asks each provider whose key is set up whether its endpoint accepts it: one incomplete request each, nothing billed, only the HTTP status shown |
| `teamctl version` · `teamctl help` | |

`start`, `stop`, `restart`, `remove`, `destroy`, `approve`, `deny` and changing the `policy`
are for you and for the team's lead; a teammate that tries them is refused (exit 77).

### Tab completion

After `./install.sh`, a new zsh terminal completes `teamctl`: the commands with short
descriptions, the options of each command, and the values teamctl knows - roles,
teams, models, policy keys and their choices, layouts, pending approval ids, local
branch names.

```bash
teamctl <Tab>                 # the commands (teamctl re<Tab> offers remove and restart)
teamctl restart <Tab>         # the roles of your team (remove offers workers only)
teamctl spawn x <Tab>         # the models, with their labels
teamctl --team <Tab>          # the teams of this project
teamctl policy <Tab>          # the policy keys; teamctl policy worker-spawn <Tab> the choices
```

The knowledge lives in one backend inside teamctl (`teamctl _complete`); the zsh and
bash shims in `~/.config/wolfmux/completion/` are thin and only present what it
answers ([ADR-0026](docs/adr/0026-tab-completion.md)). The zsh shim registers only
when a completion system is loaded (compinit): it never switches one on by itself.
To try it without install.sh: `source <(teamctl completion zsh)`. In bash:
`eval "$(teamctl completion bash)"` (bash 3.2 cannot source a process substitution). Tab offers nothing? See
[TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md#tab-completion).

### Branch names and other repositories

A teammate's branch is named by the team's **branch template**. The default reproduces the
names wolfmux has always used, `ai/<role>-<timestamp>` and `ai/<team>/<role>-<timestamp>`,
so nothing changes unless you change it:

```bash
teamctl policy branch-template 'feature-{ticket}-{role}-{ts}'   # this team, from now on
teamctl start fable --ticket AFD-1844                           # the team's default ticket key
teamctl spawn sam glm53 --ticket AFD-1844                       # feature-AFD-1844-sam-20260923-112233
teamctl spawn sam glm53 --branch feature-AFD-1844-sam           # or name the branch yourself
teamctl policy branch-template default                          # back to the built-in shape
```

Placeholders: `{team}` `{role}` `{ts}` `{ticket}`. `{ts}` is the timestamp and is required —
it is what keeps two teammates of the same role on two branches. A template with `{ticket}`
and a spawn with no ticket key is refused rather than guessed at (exit 64). Set this when
your repository's hooks require a shape, so teammates never have to commit with a skip
switch. `WOLFMUX_BRANCH_TEMPLATE` in `~/.config/wolfmux/config` is the default for every team.

teamctl deletes a teammate's branch (`teamctl remove`, `teamctl destroy --purge`) **only when
teamctl created it**, whatever it is called. A branch you made yourself is named and left alone.

A teammate can also work in a **different repository**:

```bash
teamctl spawn srv glm53 --repo ../fanpro-studio-server
```

Its worktree and branch are created there, from that repository's `HEAD` (or its `--base`),
under `~/.wolfmux/worktrees/<that repo>/teams/<team>/`. Worker isolation stays on and holds
that teammate to that worktree: both your project's checkout and the other repository's own
checkout are read-only for it. `teamctl status` (a `REPO` column, and `repo` in `--json`),
`diff`, `worktrees`, `remove` and `destroy` all run git in that repository, so what wolfmux
created there is also what wolfmux cleans up there.

### Models

For `teamctl start` and `teamctl spawn`:

| Key | Runs | Pays with |
|-----|------|-----------|
| `glm53` · `flash` | Claude Code + GLM-5.3 / GLM-5.3 Flash | Z.ai GLM Coding Plan |
| `kimi` | Claude Code + Kimi for Coding | Kimi for Coding subscription; the key is a Kimi Code membership key (Kimi Code console, starts `sk-kim`) |
| `minimax` | Claude Code + MiniMax M3 | MiniMax Coding Plan |
| `qwen` | Claude Code + Qwen 3.7 Plus | Alibaba Model Studio coding plan; the key starts `sk-sp-` |
| `moonshot` | Claude Code + Kimi K3 API | Moonshot platform API: metered, refuses to run until the owner sets `WOLFMUX_METERED=on`; the key comes from platform.kimi.ai |
| `deepseek` | Claude Code + DeepSeek V4 | DeepSeek API: metered, refuses to run until the owner sets `WOLFMUX_METERED=on` |
| `fable` · `opus` · `sonnet` · `haiku` | Claude Code + that Claude model | Claude subscription |
| `astra` | Codex CLI + GPT-6 Astra | ChatGPT subscription |
| `claude:<model-id>` · `codex:<model-id>` | any other model of those two subscriptions | the same subscription |
| `kimi:<id>` · `moonshot:<id>` · `deepseek:<id>` · `minimax:<id>` · `qwen:<id>` | any other model id of that provider (GLM is not pinnable: its plan covers exactly its two) | the same plan, or the same metered account |

The provider facts (endpoint, model ids, context window, billing) live in one table,
`config/wolfmux/lib/providers.sh`; `teamctl`, the launchers, `doctor` and this page all
read it ([ADR-0020](docs/adr/0020-providers-beyond-the-three-subscriptions.md)). Each
provider's key lives in its own Keychain service (`wolfmux-kimi`, …; Z.ai keeps
`zai-coding-plan`); `WOLFMUX_<PROVIDER>_MODEL` / `_FAST_MODEL` pin a model id when a
vendor changes it. `teamctl status` marks a metered agent with `$` after its label.

The two Kimi keys are not interchangeable, and both say "Kimi" and start with `sk-`. A
**Kimi Code membership key** (from the Kimi Code console,
[kimi.com/code/console](https://www.kimi.com/code/console), starts `sk-kim`) belongs to `kimi`.
A key created at [platform.kimi.ai](https://platform.kimi.ai/console/api-keys) belongs to
`moonshot`. Put one in the other's slot and the endpoint answers 401 while everything on your
side looks right. `teamctl doctor --probe` finds that in a minute: it sends one incomplete
request per key you stored (nothing is generated, nothing is billed), shows only the HTTP
status, and says `the key in 'wolfmux-kimi' is rejected by <endpoint>`. It also warns when a
`kimi` key does not start with `sk-kim` or a `qwen` key with `sk-sp-`. Plain `teamctl doctor`
stays offline and never reads a key.

### Auth modes

A provider worker gets its key one of two ways (`WOLFMUX_<PROVIDER>_AUTH_MODE` in
`~/.config/wolfmux/config`):

- `helper` (the default): Claude Code is given a command that reads the Keychain on demand, so the
  key is never in an environment. Every provider worker also carries an inert
  `CLAUDE_CODE_OAUTH_TOKEN` (the login guard), so Claude Code prints
  `Both CLAUDE_CODE_OAUTH_TOKEN and apiKeyHelper set: auth may not work as expected`. That warning is
  expected and harmless (the helper's key is what is sent). It is not the cause of a 401 next to it.
- `env`: the vendor's own variable (`ANTHROPIC_API_KEY` for Kimi Code, `ANTHROPIC_AUTH_TOKEN` for the
  others). A last resort, for an endpoint that refuses helper-mode headers. It cannot fix a wrong key.
  With `ANTHROPIC_API_KEY` set, Claude Code's own documentation says it asks whether to use the key
  ("Do you want to use this API key?", default No) and remembers the answer, so an unattended worker
  waits at that prompt until a human answers it in the pane. Claude Code documents no setting that
  pre-approves the key, and Wolfmux does not edit your `~/.claude.json` to answer for you, so there
  is nothing to switch on.

A 401 means the key first: run `teamctl doctor --probe` before changing the mode.

Behind the keys are launchers you can also run by hand: `claude-fable`, `claude-opus`,
`claude-sonnet`, `claude-haiku`, `codex-astra`, `claude-glm`, `claude-glm-flash`,
`claude-kimi`, `claude-moonshot`, `claude-deepseek`, `claude-minimax`, `claude-qwen`.
Each one first removes every inherited API key and endpoint override from its own
process; `claude-glm` then sets that provider's endpoint and model ids, for that
process only. Plain `claude` and `codex` keep their login, endpoint and model:
nothing global points anywhere.

## What is in this repository

| Path | What |
|------|------|
| `bin/` | `teamctl` and the three launchers (`claude-glm-flash`, `claude-opus`, `claude-sonnet`, `claude-haiku` and the provider names `claude-kimi`, `claude-moonshot`, `claude-deepseek`, `claude-minimax`, `claude-qwen` are symlinks the installer creates) |
| `config/wolfmux/notifier/` | source and icon of `Wolfmux.app`, the application `install.sh` builds so that clicking a notification opens the team |
| `config/wolfmux/` | everything installed to `~/.config/wolfmux/`: `lib/*.sh`, the Beads hook, the team tmux config, the agent protocol, the user manual, launcher settings |
| `claude/permissions.json` | the narrow allow/ask rules merged into `~/.claude/settings.json` |
| `codex/wolfmux.rules.template` | Codex execpolicy rules so an Astra lead can run `teamctl` and `bd` |
| `install.sh`, `uninstall.sh` | reversible installation |
| `migrate-from-ai-team.sh` | one-time move from v1.1 and earlier, when this was called "ai-team" ([why](docs/adr/0014-rename-to-wolfmux.md)) |
| `tests/` | `smoke.sh` (348 isolated lifecycle checks, no model calls), `disk.sh` (93 checks: the worktree cleanup, the spawn guard and every safety rule that keeps them off your work), `nudge-typing.sh` (56 checks: a notice never lands in a half-typed line), `inbox.sh` (102 checks: nothing is typed into the human's conversation, and the agent still learns about the bead), `providers.sh` (the provider table: every provider's facts, keys and settings), `docs.sh` (does the documentation name every command, option, policy key, model and setting the code has), `permissions.sh` (what the installer does to `~/.claude/settings.json`, in a throwaway `HOME`), `migration.sh` (the move from v1.1, same), `credential-routing.sh` (evidence for the billing/credential design). Counts measured at `9d9f84b` on v1.15.0; `smoke.sh`'s is its clean shape, and `docs.sh` guards none of these numbers (see `docs/ROADMAP.md`) |
| `tools/` | `wolf-art.py` (the one pixel drawing behind the terminal wolf, the logo and the hero) and `flow-diagrams.py` (the sequence diagrams); only needed to change the artwork |
| `docs/` | the documentation below, and `docs/diagrams/` |

## Documentation

| Read this | To learn |
|-----------|----------|
| [docs/GOALS.md](docs/GOALS.md) | what this is for, the hard constraints, the non-goals |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | components, process and environment model, data flows, file layout |
| [docs/diagrams/](docs/diagrams/README.md) | every diagram on one page: architecture, several teams, billing isolation, how work travels, approvals, notifications |
| [docs/SETUP.md](docs/SETUP.md) | installing on a machine, what gets touched, updating, uninstalling |
| [docs/USAGE.md](docs/USAGE.md) | a full working session, command reference, the Beads cheat sheet |
| [docs/SECURITY.md](docs/SECURITY.md) | how subscription-only billing and credential isolation are enforced, with evidence |
| [docs/VERIFICATION.md](docs/VERIFICATION.md) | what was tested, how, and the results |
| [docs/BUILD-LOG.md](docs/BUILD-LOG.md) | the steps this system was built in, including what went wrong |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | symptoms and fixes |
| [docs/ROADMAP.md](docs/ROADMAP.md) | known limits and what a V2 could be |
| [docs/adr/](docs/adr/README.md) | the architecture decisions, each with alternatives and consequences |
| [config/wolfmux/TEAM_PROTOCOL.md](config/wolfmux/TEAM_PROTOCOL.md) | the rules every agent receives at launch |

## Requirements

macOS (uses the login Keychain and `/bin/bash` 3.2), `tmux`, `git`, `jq`,
[Claude Code](https://code.claude.com/docs/en/setup) signed in with a Claude
subscription, the Codex CLI signed in with ChatGPT (the copy bundled in ChatGPT.app
works), [Beads](https://github.com/gastownhall/beads) (`bd`), and a Z.ai GLM Coding
Plan. The other providers (Kimi, Moonshot, DeepSeek, MiniMax, Qwen) are optional:
add a key when you want their workers ([SETUP.md](docs/SETUP.md#3-the-keys)). No
Node, Docker, database server or daemon.

## Changing it

The repository is the source of truth. Edit here, run `tests/smoke.sh` and
`tests/docs.sh`, then `./install.sh` to copy the change into place. `tests/docs.sh` reads
the code for what exists and fails, naming what is missing where, until `teamctl help`,
this page and [docs/USAGE.md](docs/USAGE.md) show every command, alias and option, those
three and the user manual name every policy key and model, and every setting is in the
config template and explained.
