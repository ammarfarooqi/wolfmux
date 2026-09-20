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
`tests/smoke.sh` (31 checks at the time), `tests/credential-routing.sh`, and this documentation.

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

## 13. The rename (v1.2)

The owner called "ai-team" a bad name. "Wolfpack" was picked, then dropped when a search
found 1,137 GitHub repositories with that name; **Wolfmux** had none (and was free on
npm, PyPI and Homebrew). Candidate names were checked with `gh api search/repositories`
before they were offered again.

The rename itself was mechanical (`AI_TEAM_` → `WOLFMUX_`, `ai-team` → `wolfmux`, two
`git mv`). The work was in not breaking the machine it ran on: a lead was live on the old
tmux socket and a stopped worker had a worktree under `~/.ai-team`. See
[ADR-0014](adr/0014-rename-to-wolfmux.md). What was added:

- `teamctl` follows a team on the old socket until its last session ends;
- Beads hooks carrying the old marker count as ours and are rewritten;
- `migrate-from-ai-team.sh` (with `--dry-run`) moves state and worktrees, rewrites the one
  stored path, runs `git worktree repair`, renames the marked `~/.zshrc` block and the
  two tmux permission rules in place, and parks the old config in backups;
- `install.sh` refuses to install next to an unmigrated v1.1.

Two ideas were written and then removed as unneeded: accepting the old login-guard value
(no v1.1 GLM worker was alive to carry it) and reading the old tmux session option (a
project with stored state never consults it).

`tests/migration.sh` rehearses the whole move in a throwaway `HOME`: it installs v1.1
from git history, runs a team with it, migrates, and ends with `uninstall.sh` (21 checks).
`tests/smoke.sh` grew from 48 to 55 checks. Only then was the real machine migrated.

## 14. The wolf, diagrams, and a notification that opened the wrong app (v1.3)

Asked for: a wolf when a team is opened, a wolf that always marks the manager, and
presentable diagrams. One pixel drawing (`tools/wolf-art.py`) became the terminal art,
the logo and the wolf in the README image. The splash is a tmux popup on
`client-attached`; checking it needed a trick, because `capture-pane` cannot see popups
and a logged pty shows tmux drawing text cell by cell: the team client was attached
*inside an outer tmux server*, whose `capture-pane` then shows exactly what a person
sees. The manager's mark is a conditional in `pane-border-format` and
`pane-border-style`, plus the Claude session name.

The diagrams are SVG on their own dark ground, so GitHub's two themes cannot break them.
Three are hand-written; the three sequence diagrams come from one renderer
(`tools/flow-diagrams.py`) so they cannot drift apart. Each was rendered with a headless
Chromium and looked at before it was committed.

While this was being built the owner reported that clicking a "task complete"
notification opened Script Editor. Cause: the ECC plugin's notifier falls back to
`osascript` inside tmux. Fix: [ADR-0015](adr/0015-notifications-through-the-attached-terminal.md).
`tests/smoke.sh` grew from 55 to 71 checks.

## 15. Finished panes, arrangement, and the pack (v1.4)

The owner quit every agent and ran `teamctl start fable` again: it attached to a window of
`Pane is dead` lines. `remain-on-exit` had kept the panes (on purpose, so the last output
stays readable), the session still existed, and `start` only asked whether a session
existed. It now asks what is alive (see ARCHITECTURE, "Arrangement and coming back").
Because that session was the last one on the pre-rename socket, the socket choice had to
become re-evaluable, otherwise the fresh team would have been started under the old name.

Same report: the arrangement. tmux's `tiled` gave the third pane the full width and moved
everything whenever a worker came or went. Default is now `lead-left`; `teamctl layout`
switches. And the teammates got their own mark, 🐶, next to the lead's 🐺 (there is only
one wolf emoji). Tests were written first and seen failing (9 red), then made to pass.

Last, the long yellow `"glm-5.3" isn't described by this version's model catalog` notice in
every worker pane. The notice itself names three ways out; each was tried on the real CLI
against the localhost mock. Declaring the window Claude Code already assumes
(`CLAUDE_CODE_MAX_CONTEXT_TOKENS=200000`) removes it without changing behaviour, so that is
what `claude-glm` does. The variable stays on the scrub list — a Fable child must never
inherit a GLM window — so a different number goes through `WOLFMUX_GLM_CONTEXT`.
`tests/smoke.sh` 71 → 85.

## 16. The notification opened Script Editor again (v1.5)

ADR-0015's first version handled the attached team and fell back to `osascript` for the
detached one, "because there is nowhere to go back to". The owner's very next
notification was the detached case. The assumption was wrong twice: a team working in the
background is the normal case, and there *is* somewhere to go — a new terminal window.
macOS opens the owner of a notification on click, which is why Script Editor kept
appearing; so Wolfmux now ships an owner of its own, built by `install.sh` with
`osacompile`, with the wolf as its icon. One application, two meanings of "launched":
a message is waiting → post it; nothing is waiting → that was a click, open the team.

Found on the way: a lead had spawned `Riley-pr-reviewer`. Role names are lowercase by
contract, but `[a-z]` follows the locale's collation and matches capitals under
`en_AU.UTF-8`. Alphabets are now spelled out. `tests/smoke.sh`: 85 → 92.

## 17. Clearing up, and staying in lane (v1.6)

Two more reports. `teamctl destroy` "did not work": it had worked as designed (it keeps
worktrees), but there was no way to discard a worker that still held work, and the one
line that said so was easy to miss. Now there is `teamctl remove <role> [--force]`, and
`destroy` names what it kept, why, and the command for either way out.

And the question whether a teammate is really tied to its worktree. Honest answer until
then: by instruction only. Now a `PreToolUse` guard refuses tool calls that leave the
lane ([ADR-0016](adr/0016-worktree-guard.md)). Writing it surfaced two traps worth
keeping: a path has several spellings (`/var/…` and `/private/var/…`, doubled slashes), so
the shell check replaces every spelling with a token before matching; and bash 3.2
misreads escaped quotes inside `"$( … )"`, which split a jq program at its commas
(brace expansion) in the tests. `tests/smoke.sh`: 92 → 109.

## 18. Astra could not run a command; any model for any teammate (v1.7)

The owner started an Astra-led team and asked it to spawn a teammate. Codex answered
"Code Mode is unavailable … codex-code-mode-host: host executable was not found", tried to
drive Terminal through computer use, was refused, and gave up. Cause: `~/bin/codex` was a
symlink into ChatGPT.app, and Codex looks for its helper programs next to the path it was
*started as*. It had never been caught because the build only took the Codex TUI as far as
its first screen. Fix: a wrapper instead of the symlink, and `codex-astra` resolves
symlinks before it execs. This time it was checked with one real turn on the ChatGPT
login: the command ran, no warning, and Codex's `notify` program delivered
`🐺 lead: wolfmux-ok` — so Codex agents notify now as well.

Same report: staff any team with any model ([ADR-0017](adr/0017-any-model-for-any-agent.md)).

The security review of the guard and of `remove` arrived in between. Its critical finding
(a hand-edited record could make `remove` delete any directory) had been found and fixed an
hour earlier; its others were new and right: prose in commit messages and Beads texts
tripped the shell patterns, a destructive verb anywhere in a command that merely mentioned
the lead's checkout was refused, MCP tools were not matched at all, and `remove a b` was
not all-or-nothing. All fixed, each with a check. `tests/smoke.sh`: 109 → 120.

## 19. Several teams per project (v1.8)

The owner had an Astra team up, ran `teamctl start fable` for a second team, and landed in
the Astra session. A project had one team by construction. Now it has teams
([ADR-0018](adr/0018-several-teams-per-project.md)): the first stays where it was, named
ones live under `teams/<name>/`, each with its own session, lead and workers, and
`teamctl status` draws them as a tree. The change stayed small because nearly everything
already hung off `STATE_DIR` and the session name; the real work was identity, since all
teams share one Beads database (`<team>.<role>`), and saying no: `start` with another model
refuses instead of attaching.

This was written while a second Claude session was fixing other things in the same
repository. Both worked in their own git worktrees on their own branches; this one rebased
on `main` before merging and installed only from `main`.

`tests/smoke.sh`: 120 → 139 (15 for teams, 4 from the other session's audit fixes, merged here).

## 20. Deleting a team; teams that talk and found teams

Asked: what does a team cost on disk, and can one command give it back? Measured on the
owner's project first (a worker = one 99 MB checkout, more only if it installs or builds;
the lead nothing; records KBs; transcripts 17 MB), then built `destroy --purge`
([ADR-0019](adr/0019-deleting-a-team-and-founding-one.md)): report, ask, delete. A test
bug worth remembering: the check computed the transcript folder from the worktree's path
*after* the purge had deleted the worktree, got the parent folder, and "failed" on a
directory that was rightly still there.

Asked in the same breath: do teams talk, and can a lead found a team and hand over? The
first already worked through the shared Beads (now tested in both directions, and every
agent is told how). The second did not: `start` was reserved for the human. A lead may now
found a team that does not exist yet, with `--handover <bead-id>` as the new lead's first
words; you are notified; `lead-teams off` switches it off.

`tests/smoke.sh` gained 14 checks for this.

## Footprint on the machine

| Created | `~/bin/*`, `~/.config/wolfmux/`, `~/.wolfmux/`, `~/.local/bin/bd`, `~/.codex/rules/wolfmux.rules`; Beads' own `~/.beads`, `~/.dolt`, `~/.config/bd` |
|---------|------|
| Modified (backed up) | `~/.zshrc` (one block), `~/.claude/settings.json` (9 allow rules, 1 ask rule) |
| Deliberately not created or touched | `~/.tmux.conf`, `~/.zprofile`, any CLAUDE.md / AGENTS.md, `~/.codex/config.toml`, `~/.codex/rules/default.rules`, git config, any project's `.gitignore` |
