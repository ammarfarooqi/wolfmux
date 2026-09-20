# ai-team

A local, multi-model AI development team on one Mac. One **lead** agent plans,
delegates and reviews; any number of **worker** agents implement in parallel. Every
agent is a real CLI in its own visible tmux pane, on its own git branch and worktree.

**All inference runs on subscriptions. There is no API key, no metered proxy, and no
pay-as-you-go path anywhere in this system.**

```
                     LEAD  (pick one per session)
          claude-fable            codex-astra
          Claude Code             Codex CLI
          Fable 5.1               GPT-6 Astra
          Claude subscription     ChatGPT / Codex subscription
                 └──────────┬──────────┘
        teamctl  = tmux panes · models · worktrees · lifecycle
        bd       = tasks · dependencies · messages          (Beads)
                            │
      ┌─────────────────────┼─────────────────────┐
  claude-glm           claude-glm           claude-glm-flash
  backend · GLM-5.3    frontend · GLM-5.3   qa · GLM-5.3 Flash
      └──────────── Z.ai GLM Coding Plan ─────────┘
```

## Quick start

```bash
git clone <this repo> ~/Documents/ai-team && cd ~/Documents/ai-team
./install.sh                                  # idempotent; backs up what it edits
security add-generic-password -U -s zai-coding-plan -a "$USER" -l "Z.ai Coding Plan API key" -w
teamctl doctor                                # no "!! WARNING !!" lines = ready

cd ~/code/your-project
teamctl start fable                           # or: teamctl start astra
teamctl spawn backend glm53
teamctl spawn qa flash
```

Then talk to the lead. It creates tasks and messages in Beads, spawns workers,
reviews their diffs with `teamctl diff <role>` and integrates what it approves.

## What is in this repository

| Path | What |
|------|------|
| `bin/` | `teamctl` and the three launchers (`claude-glm-flash` is a symlink the installer creates) |
| `config/ai-team/` | everything installed to `~/.config/ai-team/`: `lib/*.sh`, the Beads hook, the team tmux config, the agent protocol, the user manual, launcher settings |
| `claude/permissions.json` | the narrow allow/ask rules merged into `~/.claude/settings.json` |
| `codex/ai-team.rules.template` | Codex execpolicy rules so an Astra lead can run `teamctl` and `bd` |
| `install.sh`, `uninstall.sh` | reversible installation |
| `tests/` | `smoke.sh` (31 isolated lifecycle checks, no model calls), `credential-routing.sh` (evidence for the billing/credential design) |
| `docs/` | the documentation below |

## Documentation

| Read this | To learn |
|-----------|----------|
| [docs/GOALS.md](docs/GOALS.md) | what this is for, the hard constraints, the non-goals |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | components, process and environment model, data flows, file layout |
| [docs/SETUP.md](docs/SETUP.md) | installing on a machine, what gets touched, updating, uninstalling |
| [docs/USAGE.md](docs/USAGE.md) | a full working session, command reference, the Beads cheat sheet |
| [docs/SECURITY.md](docs/SECURITY.md) | how subscription-only billing and credential isolation are enforced, with evidence |
| [docs/VERIFICATION.md](docs/VERIFICATION.md) | what was tested, how, and the results |
| [docs/BUILD-LOG.md](docs/BUILD-LOG.md) | the steps this system was built in, including what went wrong |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | symptoms and fixes |
| [docs/ROADMAP.md](docs/ROADMAP.md) | known limits and what a V2 could be |
| [docs/adr/](docs/adr/README.md) | the architecture decisions, each with alternatives and consequences |
| [config/ai-team/TEAM_PROTOCOL.md](config/ai-team/TEAM_PROTOCOL.md) | the rules every agent receives at launch |

## Requirements

macOS (uses the login Keychain and `/bin/bash` 3.2), `tmux`, `git`, `jq`,
[Claude Code](https://code.claude.com/docs/en/setup) signed in with a Claude
subscription, the Codex CLI signed in with ChatGPT (the copy bundled in ChatGPT.app
works), [Beads](https://github.com/gastownhall/beads) (`bd`), and a Z.ai GLM Coding
Plan. No Node, Docker, database server or daemon.

## Changing it

The repository is the source of truth. Edit here, run `tests/smoke.sh`, then
`./install.sh` to copy the change into place.
