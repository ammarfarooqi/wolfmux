# ADR-0014: Rename to Wolfmux, with a migration instead of a reinstall

**Date**: 2026-09-20
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

The project shipped as "ai-team" (v1.0, v1.1). The owner rejected the name as generic.
The name is not cosmetic here: it is the tmux socket, `~/.config/<name>`, `~/.<name>`
(state and git worktrees), the marked block in `~/.zshrc`, two permission rules, a Codex
rule file, the marker inside every project's Beads hooks, and the prefix of every
environment variable. A lead was running under the old name while the rename was made,
and a stopped worker had a worktree under `~/.ai-team`. "Wolfpack" was the first choice
and was dropped after a GitHub search showed over a thousand repositories with that name.

## Decision

The product is **Wolfmux** (a pack of agents in tmux; no GitHub repository, npm, PyPI or
Homebrew package had the name). Everything the tool owns takes the new name. What the
owner types or stores keeps its name: the `teamctl` command, `TEAM_ROLE`, `ai/<role>`
branches, the pane options `@ai_role` / `@ai_label`, and the Keychain service
`zai-coding-plan`. `migrate-from-ai-team.sh` moves an existing installation in place;
`install.sh` refuses to run next to an unmigrated one. A team that is already running
is not restarted: `teamctl` follows the old tmux socket while it still has a session and
the new one has none, and hooks carrying the old marker count as ours.

## Alternatives Considered

### Alternative 1: Uninstall, reinstall, start over
- **Pros**: no migration code, no compatibility code
- **Cons**: kills the running lead; the stopped worker's worktree and its registry record are stranded under `~/.ai-team`; project hooks silently stop notifying
- **Why not**: losing a live session and a worktree to a rename is the wrong trade

### Alternative 2: Rename the repository only, keep `ai-team` on disk
- **Pros**: zero risk on the machine
- **Cons**: the name the owner dislikes stays in every path, socket and variable they see daily
- **Why not**: it does not deliver the rename

### Alternative 3: Symlinks from the old paths to the new ones
- **Pros**: every old absolute path keeps working, no record rewriting, no `git worktree repair`
- **Cons**: the old name stays in `$HOME` indefinitely and needs its own cleanup step
- **Why not**: only one stored field and git's worktree pointer held old paths; rewriting them is smaller than managing symlinks

### Alternative 4: Rename `teamctl` too
- **Pros**: one name everywhere
- **Cons**: breaks the owner's muscle memory, the agents' protocol text, permission rules and Codex rules for no functional gain
- **Why not**: the command describes what it does; the product name does not have to be in it

## Consequences

### Positive
- one name across socket, directories, variables, markers, repository and documents
- the rename cost no running session and no worktree; rehearsed end to end in a throwaway `HOME` (`tests/migration.sh`, 21 checks) before it touched the machine
- reversible: edited files are backed up, the old config and rule file are parked in `~/.wolfmux/backups/<stamp>/`, v1.1 is one `git checkout` away

### Negative
- a small amount of code exists only for the transition (`tm_adopt_legacy_server`, the legacy hook marker, the second socket in `uninstall.sh`, the guard in `install.sh`, the migration script and its test)
- while a pre-rename team lives, `teamctl doctor` and `teamctl start` report the socket as `ai-team`
- a lead that was already running keeps the old names in its injected instructions until `teamctl restart lead --continue`

### Risks
- a team on the old socket and another on the new one at the same time: only possible when a socket is forced with `WOLFMUX_TMUX_SOCKET`; teamctl then talks to the new one. Mitigation: adoption is per invocation, so ending either team resolves it
- the transition code outliving its purpose — it can be deleted once no machine runs v1.1; `tests/migration.sh` pins the old release by commit and will say so when that commit is gone
