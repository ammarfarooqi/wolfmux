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
| **Several teams per project** | the first is called `default`, every further one is named by you; each has its own session, lead and teammates; `teamctl status` shows them as a tree. Teams message each other through Beads, and a lead can found a fresh team and hand work over to it ([diagram](docs/diagrams/teams.svg)) |
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
| `teamctl start <model> [--team <name>] [--no-attach] [--continue]` | start a team with that model as its 🐺 lead, and open it. `--team` names a further team in the same project; `--continue` resumes the lead's last conversation; after the lead quit, the same command brings it back |
| `teamctl start … [--init-beads\|--skip-beads] [--lead-permissions skip\|ask] [--worker-permissions skip\|lead\|ask] [--worker-spawn on\|off]` | `--init-beads` or `--skip-beads` answers the first start's question about Beads; the other three set the team's policy, at any start |
| `teamctl start <model> --team <new> --handover <bead-id>` | found a fresh team whose lead starts by reading that bead. A lead may run this too; you are notified |
| `teamctl status [--json]` (alias `workers`) | every team as a tree (one team with `--team`, or from inside a pane): 🐺 lead, 🐶 teammates, model, running or stopped, branch, commits ahead, uncommitted files |
| `teamctl teams` | the short list: state, lead, number of agents, and the disk its teammates' worktrees take |
| `teamctl attach` (alias `open`) | open the team in this terminal (`Ctrl-b d` leaves it running) |
| `teamctl focus <role>` | jump to one pane |
| `teamctl layout [lead-left\|lead-top\|tiled]` | how the panes are arranged; `lead-left` is the default |

**Teammates**

| Command | Does |
|---------|------|
| `teamctl spawn <role> <model> [--base <ref>] [--no-kickoff] [--link-node-modules]` | a new 🐶 teammate with its own pane, branch and worktree. Any model, whoever leads. Refused when free disk is under `disk-min-gb` (policy `disk-guard`). `--link-node-modules` points the lane's `node_modules` at the project root's copy instead of installing 2+ GB of its own — one directory for every lane, so an install in any lane changes them all |
| `teamctl stop <role>` | close its pane; worktree, branch and commits stay. Its build caches (`.next`, `dist`, …) are deleted, `node_modules` is kept, so `restart` stays cheap |
| `teamctl restart <role> [--continue]` | start it again in the same worktree; `--continue` keeps its conversation. When the team's tmux session is gone (a reboot), `restart lead` starts the team again |
| `teamctl remove <role>… [--force] [--yes]` | take a stopped teammate off the books: worktree, branch, record, and the gigabytes they held. Refuses while it holds work that exists nowhere else, and lists it; `--force` discards it after one question |
| `teamctl nudge <role>\|--all [--id <bead-id>] [--quiet]` | re-send the one-line notification into a pane. The Beads hook does this by itself |

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
| `teamctl policy [<key> <value>]` | show or set, per team: `lead-permissions` skip\|ask · `worker-permissions` skip\|lead\|ask · `worker-spawn` on\|off · `worker-isolation` on\|off (the worktree guard) · `lead-teams` on\|off (may the lead found teams) · `disk-guard` refuse\|warn\|off · `disk-min-gb` a whole number of GB (0 = no limit) · `link-node-modules` on\|off |
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
| `teamctl destroy --purge [--force] [--keep-transcripts] [--yes]` | delete the whole team and give its disk space back: shows sizes and any uncommitted or unmerged work, asks, then removes the session, worktrees, `ai/…` branches, records and its teammates' Claude Code transcripts. `--force` deletes that work too. Never touched: your checkout, other branches, Beads, other teams, the lead's own conversations |
| `teamctl doctor` | billing and credential isolation report: launchers, inherited keys, settings overrides, Keychain, logins |
| `teamctl version` · `teamctl help` | |

`start`, `stop`, `restart`, `remove`, `destroy`, `approve`, `deny` and changing the `policy`
are for you and for the team's lead; a teammate that tries them is refused (exit 77).

### Models

For `teamctl start` and `teamctl spawn`:

| Key | Runs | Pays with |
|-----|------|-----------|
| `glm53` · `flash` | Claude Code + GLM-5.3 / GLM-5.3 Flash | Z.ai GLM Coding Plan |
| `kimi` | Claude Code + Kimi for Coding | Kimi for Coding subscription |
| `minimax` | Claude Code + MiniMax M3 | MiniMax Coding Plan |
| `qwen` | Claude Code + Qwen 3.7 Plus | Alibaba Model Studio coding plan |
| `moonshot` | Claude Code + Kimi K3 API | Moonshot platform API: metered, refuses to run until the owner sets `WOLFMUX_METERED=on` |
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
| `tests/` | `smoke.sh` (181 isolated lifecycle checks, no model calls), `disk.sh` (the worktree cleanup, the spawn guard and every safety rule that keeps them off your work), `providers.sh` (the provider table: every provider's facts, keys and settings), `docs.sh` (does the documentation name every command, option, policy key, model and setting the code has), `permissions.sh` (what the installer does to `~/.claude/settings.json`, in a throwaway `HOME`), `migration.sh` (the move from v1.1, same), `credential-routing.sh` (evidence for the billing/credential design) |
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
