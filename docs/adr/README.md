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
| [0015](0015-notifications-through-the-attached-terminal.md) | Notifications go through the terminal attached to the team | accepted | 2026-09-20 |
