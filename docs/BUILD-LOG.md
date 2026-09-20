# Build log

How this system was built on 2026-09-20, in order, including what went wrong.
Decisions are explained in [adr/](adr/README.md).

## 0. Audit — nothing modified

| Found | Consequence |
|-------|-------------|
| macOS 26.6 arm64, zsh 5.9, `/bin/bash` 3.2.57 | everything is written for bash 3.2 |
| tmux 3.7c, git 2.50, jq 1.7.1, sqlite3 present | no dependency had to be installed |
| Homebrew prefix owned by a different account; the owner's `~/.zshrc` says to install user tools into `~/.local/bin` | Beads went to `~/.local/bin`, not Homebrew |
| interactive aliases `rm/mv/cp/ln -i`, `cat` = bat | scripted commands use absolute binaries (`/bin/cp`, `/bin/cat`) |
| Claude Code 2.1.278, native install, signed in with a Max subscription, no API key | nothing to change |
| no `codex` on PATH, but a Codex CLI inside ChatGPT.app (0.155.0-alpha.9.2), signed in with ChatGPT, `model = "gpt-6-astra"` already in its config | reuse it; no second install |
| no `~/bin`, no `~/.tmux.conf`, no `~/.zprofile`; no provider variable anywhere; no MCP servers | clean start |
| no Keychain item `zai-coding-plan` | the owner adds it; never pasted into chat |

Vendor documentation was read before writing anything: Z.ai's Claude Code guide and
FAQ (endpoint, the two covered model ids, the 1M suffix), Claude Code's model,
authentication, environment-variable and permissions references, and the Codex
authentication, rules and environment-variable pages.

## 1. Scope change

Partway through, the owner replaced the planned filesystem task/message store with
**Beads** and limited `teamctl` to tmux, models, worktrees and lifecycle. Nothing
had been written yet, so there was no rework. Beads 1.3.0 was then evaluated in a
sandboxed `HOME` before adoption (results in
[VERIFICATION.md](VERIFICATION.md#beads-evaluation-sandboxed-home)).

## 2. Beads install

Official release tarball, SHA-256 verified against `checksums.txt`, installed to
`~/.local/bin/bd`. Beads' anonymous usage metrics were turned off (`bd metrics off`).

## 3. `~/bin` and PATH

`~/.zshrc` backed up, then one marked block appended that adds `~/bin` to the end
of `PATH`.

## 4. Launchers

`claude-fable`, `codex-astra`, `claude-glm` (+ `claude-glm-flash` symlink), sharing
`lib/provider-env.sh`. Verified with hostile variables injected; `claude-glm`
exits 78 with the exact Keychain command when the key is missing.

## 5. tmux

A team-only config validated on a throwaway tmux server: options effective,
direct-exec panes with `-e` work, `prefix T` was unbound.

## 6. teamctl

Registry, tmux, worktree, Beads-glue, lifecycle, views and doctor modules; the agent
protocol; the user manual.

## 7. Bugs found by testing, and their fixes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `doctor` stopped after the Z.ai section | `grep` returning 1 inside a `$(…)` under `pipefail` | `|| true` inside the substitutions; helpers made total |
| `start` failed: `MODEL_LABEL: unbound variable` | `model_info` ran inside a command substitution, so its variables never reached the caller | call it in the current shell |
| `start` failed: `no such session: =team-…` and left a half-made session | `set-option -t "=name"` is parsed as a pane target; the exact-match form needs a trailing colon | `=name:` for session options; `start` now rolls back on any failure after session creation |
| message beads missing from the inbox | `bd list` hides message beads by default | `--include-infra` in every inbox command, the notification text and the protocol |
| `bd init` refused in a directory named with spaces | Beads derives its prefix from the raw directory name | `teamctl` derives a valid prefix itself |
| `teamctl spawn … | head -1` exited non-zero after finishing its work | `printf` to a closed pipe under `set -e` | `say` tolerates a closed pipe |
| unassigned beads shifted fields in the hook | tab is whitespace for `IFS`, so empty fields collapsed | unit-separator join |

## 8. Permissions

Claude Code: allow rules for `teamctl`, `bd`, read-only git and read-only team-tmux,
plus an *ask* rule for `teamctl destroy`, merged into `~/.claude/settings.json`
after a backup. Codex: a separate `~/.codex/rules/wolfmux.rules`, validated with
`codex execpolicy check`. Codex needs this because its sandbox blocks the tmux
socket and writes outside the workspace.

## 9. Review

Independent code and security reviews ran in parallel; findings and dispositions
are in [SECURITY.md](SECURITY.md#review-record-2026-09-20).

## 10. The credential experiment

The security review recommended helper-only key delivery. Checking that against a
localhost mock showed something neither review had: a process that inherits only
the custom base URL presents the real claude.ai login to it. The result is the
login guard ([ADR-0007](adr/0007-zai-key-delivery-and-login-guard.md)), the
`config` file for persistent launcher settings, and the GLM worker settings
overlay that keeps `claude-mem`'s daemon from starting under a Z.ai environment.

## 11. Packaging

This repository: sources, `install.sh` / `uninstall.sh` (tested in a fake `HOME`),
`tests/smoke.sh` (31 checks), `tests/credential-routing.sh`, and this documentation.

## 12. First real use — three problems, one root cause (v1.1)

The owner ran a real team and reported: teammates were asking a GLM session for approval
and treating it as the manager; agents stalled on permission prompts; and a worker had
been able to create teammates on its own.

Root cause of the first and third: the owner's Claude Code settings enable the
experimental agent-teams feature (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`,
`teammateMode: iterm2`), which workers inherited. With it on, any subagent a session
names becomes a teammate whose team lead and permission approver is that session
(documented behaviour). Fix and additions are in
[ADR-0013](adr/0013-one-manager-policy.md): manager-only commands, a per-project policy
(`lead-permissions`, `worker-permissions`, `worker-spawn`), agent teams switched off
inside workers, a `PermissionRequest` hook that lets the lead approve or deny, and lead
notices for spawns and policy changes. The smoke suite grew from 31 to 48 checks, and the
override was confirmed against the real CLI.

## Footprint on the machine

| Created | `~/bin/*`, `~/.config/wolfmux/`, `~/.wolfmux/`, `~/.local/bin/bd`, `~/.codex/rules/wolfmux.rules`; Beads' own `~/.beads`, `~/.dolt`, `~/.config/bd` |
|---------|------|
| Modified (backed up) | `~/.zshrc` (one block), `~/.claude/settings.json` (9 allow rules, 1 ask rule) |
| Deliberately not created or touched | `~/.tmux.conf`, `~/.zprofile`, any CLAUDE.md / AGENTS.md, `~/.codex/config.toml`, `~/.codex/rules/default.rules`, git config, any project's `.gitignore` |
