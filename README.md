# Wolfmux

![Wolfmux: the wolf, and a terminal with one lead and three workers in tiled tmux panes](docs/diagrams/hero.svg)

A local, multi-model AI development team on one Mac. One **lead** agent plans,
delegates and reviews; any number of **worker** agents implement in parallel. Every
agent is a real CLI in its own visible tmux pane, on its own git branch and worktree.
The lead is the wolf — 🐺 in its pane border, an amber frame, the large pane on the left —
and every teammate is a dog of the pack (🐶), so you can always tell the manager from the rest.

**All inference runs on subscriptions. There is no API key, no metered proxy, and no
pay-as-you-go path anywhere in this system.**

![Architecture: teamctl is the control plane, Beads the data plane, one hook connects them](docs/diagrams/architecture.svg)

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
teamctl spawn fe-review astra                 # any model can join any team (fable · opus · sonnet · haiku · astra · claude:<id> · codex:<id>)
```

Then talk to the lead. It creates tasks and messages in Beads, spawns workers,
reviews their diffs with `teamctl diff <role>` and integrates what it approves.

## What is in this repository

| Path | What |
|------|------|
| `bin/` | `teamctl` and the three launchers (`claude-glm-flash` is a symlink the installer creates) |
| `config/wolfmux/notifier/` | source and icon of `Wolfmux.app`, the application `install.sh` builds so that clicking a notification opens the team |
| `config/wolfmux/` | everything installed to `~/.config/wolfmux/`: `lib/*.sh`, the Beads hook, the team tmux config, the agent protocol, the user manual, launcher settings |
| `claude/permissions.json` | the narrow allow/ask rules merged into `~/.claude/settings.json` |
| `codex/wolfmux.rules.template` | Codex execpolicy rules so an Astra lead can run `teamctl` and `bd` |
| `install.sh`, `uninstall.sh` | reversible installation |
| `migrate-from-ai-team.sh` | one-time move from v1.1 and earlier, when this was called "ai-team" ([why](docs/adr/0014-rename-to-wolfmux.md)) |
| `tests/` | `smoke.sh` (124 isolated lifecycle checks, no model calls), `migration.sh` (the move from v1.1, rehearsed in a throwaway `HOME`), `credential-routing.sh` (evidence for the billing/credential design), `permissions.sh` (what install and uninstall do to `~/.claude/settings.json`, in a throwaway `HOME`) |
| `tools/` | `wolf-art.py` (the one pixel drawing behind the terminal wolf, the logo and the hero) and `flow-diagrams.py` (the sequence diagrams); only needed to change the artwork |
| `docs/` | the documentation below, and `docs/diagrams/` |

## Documentation

| Read this | To learn |
|-----------|----------|
| [docs/GOALS.md](docs/GOALS.md) | what this is for, the hard constraints, the non-goals |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | components, process and environment model, data flows, file layout |
| [docs/diagrams/](docs/diagrams/README.md) | every diagram on one page: architecture, billing isolation, how work travels, approvals, notifications |
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
Plan. No Node, Docker, database server or daemon.

## Changing it

The repository is the source of truth. Edit here, run `tests/smoke.sh`, then
`./install.sh` to copy the change into place.
