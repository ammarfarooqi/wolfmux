# Architecture Decision Records

Lightweight ADRs (Michael Nygard's format). 0001–0012 were made during the initial
build; superseded decisions will link to their replacement.

| ADR | Title | Status | Date |
|-----|-------|--------|------|
| [0001](0001-subscription-only-launchers.md) | Subscription-only inference through per-process launchers | accepted | 2026-09-20 |
| [0002](0002-beads-for-tasks-and-messages.md) | Beads for tasks and messages; teamctl limited to processes | accepted | 2026-09-20 |
| [0003](0003-beads-embedded-stealth.md) | Beads in embedded mode with a stealth init | accepted | 2026-09-20 |
| [0004](0004-dedicated-tmux-server.md) | A dedicated tmux server and config instead of ~/.tmux.conf | accepted | 2026-09-20 |
| [0005](0005-state-outside-the-repository.md) | teamctl state and worktrees outside the repository | accepted | 2026-09-20 |
| [0006](0006-notifications-via-beads-hooks.md) | Pane notifications through Beads hooks and one fixed line | accepted | 2026-09-20 |
| [0007](0007-zai-key-delivery-and-login-guard.md) | Z.ai key through apiKeyHelper, with a login guard | accepted | 2026-09-20 |
| [0008](0008-agents-as-pane-processes.md) | Agents run as the pane's process, started without a shell | accepted | 2026-09-20 |
| [0009](0009-protocol-injected-at-launch.md) | The team protocol is injected at launch, not written into instruction files | accepted | 2026-09-20 |
| [0010](0010-reuse-bundled-codex-cli.md) | Reuse the Codex CLI bundled with ChatGPT.app | accepted | 2026-09-20 |
| [0011](0011-glm-worker-settings-overlay.md) | A settings overlay for GLM workers, with claude-mem off | accepted | 2026-09-20 |
| [0012](0012-bash-modules-and-a-swappable-registry.md) | Bash 3.2 modules and a registry behind one interface | accepted | 2026-09-20 |
| [0013](0013-one-manager-policy.md) | One manager — policy for permissions and spawning, native agent teams off in workers | accepted | 2026-09-20 |
| [0014](0014-rename-to-wolfmux.md) | Rename to Wolfmux, with a migration instead of a reinstall | accepted | 2026-09-20 |
| [0015](0015-notifications-through-the-attached-terminal.md) | Notifications lead back to the team: through the attached terminal, else through Wolfmux.app | accepted | 2026-09-20 |
| [0016](0016-worktree-guard.md) | A guard that keeps each teammate in its own worktree and on its own branch | accepted | 2026-09-20 |
| [0017](0017-any-model-for-any-agent.md) | Any model can join any team | accepted | 2026-09-20 |
| [0018](0018-several-teams-per-project.md) | Several named teams in one project | accepted | 2026-09-20 |
| [0019](0019-deleting-a-team-and-founding-one.md) | Deleting a whole team, and a lead founding a new one | accepted | 2026-09-20 |
| [0020](0020-providers-beyond-the-three-subscriptions.md) | Providers beyond the three subscriptions: one table, one launcher, metered off until the owner says on | accepted | 2026-09-20 |
| [0021](0021-branch-names-from-a-template.md) | Worker branch names come from a template, and only branches teamctl created are deleted | accepted | 2026-09-23 |
| [0022](0022-a-worker-in-another-repository.md) | A worker's worktree can live in another repository, with isolation still on | accepted | 2026-09-23 |
| [0023](0023-founder-recovers-an-orphaned-team.md) | A founder recovers or cleans up a team whose lead is not running | accepted | 2026-09-23 |
| [0024](0024-doctor-probe-and-key-sources.md) | `teamctl doctor --probe`: an unbilled key check, and which console each Kimi key comes from | accepted | 2026-09-23 |
| [0025](0025-context-use-and-worktree-handover.md) | Context use in status, and a fresh conversation in a built worktree | accepted | 2026-09-23 |
| [0026](0026-tab-completion.md) | Tab completion: one backend inside teamctl and thin shims, and compinit is never switched on for the user | accepted | 2026-10-04 |
| [0027](0027-every-agent-resumes-its-own-conversation.md) | Every agent resumes its own conversation, by id | accepted | 2026-10-04 |
| [0028](0028-notices-are-filed-not-typed.md) | A notice is filed, not typed into the human's conversation | accepted, amended by [0029](0029-the-lead-pane-is-typed-into-when-it-is-quiet.md) | 2026-10-10 |
| [0029](0029-the-lead-pane-is-typed-into-when-it-is-quiet.md) | The lead's pane is typed into when it is quiet, not never | accepted | 2026-10-12 |
| [0030](0030-one-lead-keeps-a-private-memory.md) | One lead per project keeps a private memory, switched on by the owner alone | accepted | 2026-10-23 |
| [0031](0031-idle-lead-wake-waiter.md) | An idle lead wakes itself, through a waiter hook, when nobody is using its pane | accepted | 2026-11-04 |
| [0032](0032-mail-through-the-clis-hooks.md) | Mail reaches an agent through its CLI's hooks, with the body, in the middle of a turn | accepted | 2026-11-13 |
| [0033](0033-shared-team-notes-context-watch-and-checkpoints.md) | Shared team notes at session start, a context watch, and checkpoints | accepted | 2026-11-13 |
| [0034](0034-what-a-worker-starts-with.md) | What a worker's conversation starts with is a policy (`worker-context`) | accepted, amended by [0037](0037-what-a-trimmed-agent-starts-with.md) | 2026-11-13 |
| [0035](0035-a-store-of-our-own.md) | A store of our own: native SQLite by default, Beads kept as the second | accepted | 2026-11-13 |
| [0036](0036-long-output-stays-out-of-the-context.md) | A long command output stays out of the context window | accepted | 2026-11-16 |
| [0037](0037-what-a-trimmed-agent-starts-with.md) | A trimmed agent also starts without unusable tools, connectors and named instruction files; the lead may opt in | accepted | 2026-11-16 |
