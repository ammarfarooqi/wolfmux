# Limits and roadmap

## Known limits of V1

| Limit | Detail |
|-------|--------|
| Notifications are still keystrokes for a Codex agent | A Claude Code agent gets the full message through its CLI's hooks (ADR-0028); Codex has no such hook, so a notice there is still typed into a pane, which a mid-turn CLI queues and a modal dialog may swallow. Nothing is lost — the task or message stays open in the recipient's inbox — but the agent has to look. |
| Embedded Beads is single-writer | Only on a project kept on the Beads backend: writers queue on a file lock. A new project is on the native sqlite store by default (ADR-0031), which does not have this limit; a large swarm still on Beads should migrate (`teamctl store native --migrate`) or use Beads server mode. |
| Comments are silent | On either backend, a comment notifies nobody. When someone must act, send a message. |
| Same-user trust | Agents are not sandboxed from each other or from the account ([SECURITY.md](SECURITY.md#trust-model)). |
| Workers share the rest of `~/.claude` under `trim` | `worker-context` (default `trim`) already switches off every plugin; `lean` drops the rest of `~/.claude` too (rules, settings), at the cost of nothing from your own setup reaching the worker. `full` restores the pre-1.13 behaviour: every plugin's hooks run on every tool call of every worker, which is what `claude-mem` being switched off in GLM workers was working around. |
| The worktree guard is pattern matching for shell commands | Exact for file tools; a script or a path built at run time gets past it ([ADR-0016](adr/0016-worktree-guard.md)). Per-worktree git hooks (`reference-transaction`) would close the branch side, at the cost of touching the repository's configuration. Codex workers have no guard. |
| Codex-based agents have fewer guard rails | No `PreToolUse` or `PermissionRequest` hook in Codex: no worktree guard, no lead-approval mode (they fall back to their own prompts or to bypass). Notifications do work, through Codex's `notify` program. |
| Interactive background model ids unobserved | Alias mapping covers them by configuration; only `-p` traffic was observed. |
| Leads of several teams share your checkout | Every lead works in the project root on the branch checked out there; only teammates get worktrees. Two leads that integrate at the same moment get in each other's way. A worktree for a named team's lead would end that, at the price of a lead that no longer sees your uncommitted files. |
| Codex lead permissions are coarse | The rule file allows every `teamctl` and `bd` invocation outside the sandbox (with a prompt on `destroy`). |
| macOS only | Keychain, `/bin/bash` 3.2 paths, `security`, `shasum`. |
| Rare duplicate notification | Two hooks racing over a stale debounce guard can both notify once. |

## What a V2 could be

The original plan was "V1 on files, V2 on SQLite". v1.13 did exactly that for tasks,
messages and memory (`lib/store.sh`, ADR-0031): a native sqlite file is now the
default, and Beads is kept as the second backend rather than the only one.
`teamctl`'s own registry is still a few small JSON files behind one module.
Candidates that would solve real problems, in the order they are likely to matter:

1. **Beads server mode, opt-in per project still on that backend** — when lock waits
   are noticeable there and migrating to the native store is not wanted.
   `teamctl start` would own starting and stopping the Dolt server; the design
   constraint "no daemon" would have to be relaxed knowingly.
2. **Delivery confirmation** — have the notice carry a token the agent acknowledges,
   so the lead can see which notifications were actually read.
3. **A reviewer role preset** — `teamctl spawn reviewer astra` already works; a
   protocol section and a task template for "second opinion" reviews would make it
   routine.
4. **Per-role settings overlays**: the provider overlay mechanism generalised to any
   role (for example a QA worker with a narrower tool allow-list).
5. **Linux support** — a secret-service backend instead of the macOS Keychain.
6. **Finer Codex rules** — allow read-only `teamctl` subcommands silently, prompt
   on the mutating ones.

Not planned: an MCP server, a web UI, a daemon, and the metered aggregators and
proxies (OpenRouter, LiteLLM, Fireworks, Novita, SiliconFlow: forbidden by
[GOALS.md](GOALS.md#hard-constraints), before and after v1.10). The direct metered
providers (the Moonshot platform, DeepSeek) exist since v1.10, gated behind
`WOLFMUX_METERED`, off until the owner sets it.
