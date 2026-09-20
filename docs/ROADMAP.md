# Limits and roadmap

## Known limits of V1

| Limit | Detail |
|-------|--------|
| Notifications are keystrokes | A notice is typed into a pane. A CLI that is mid-turn queues it; a CLI showing a modal dialog may swallow it. Nothing is lost — the bead stays open in the recipient's inbox — but the agent has to look. |
| Embedded Beads is single-writer | Writers queue on a file lock. Fine for a handful of agents making occasional `bd` calls; a large swarm should use Beads server mode. |
| Comments are silent | Beads fires no hook for `bd comment`. When someone must act, send a message. |
| Same-user trust | Agents are not sandboxed from each other or from the account ([SECURITY.md](SECURITY.md#trust-model)). |
| Workers share `~/.claude` | Plugins, hooks, skills and permissions are common to every Claude-based agent. Deliberate, but a plugin that starts a persistent process from a worker inherits the worker's provider — the reason `claude-mem` is switched off in GLM workers. |
| Z.ai live path unverified at build time | No request was sent to Z.ai during the build ([VERIFICATION.md](VERIFICATION.md#not-verified)). |
| Interactive background model ids unobserved | Alias mapping covers them by configuration; only `-p` traffic was observed. |
| Codex lead permissions are coarse | The rule file allows every `teamctl` and `bd` invocation outside the sandbox (with a prompt on `destroy`). |
| macOS only | Keychain, `/bin/bash` 3.2 paths, `security`, `shasum`. |
| Rare duplicate notification | Two hooks racing over a stale debounce guard can both notify once. |

## What a V2 could be

The original plan was "V1 on files, V2 on SQLite". Adopting Beads made that moot:
tasks and messages already live in a versioned database, and `teamctl`'s own
registry is a few small JSON files behind one module. Candidates that would solve
real problems, in the order they are likely to matter:

1. **Beads server mode, opt-in per project** — when lock waits become noticeable.
   `teamctl start` would own starting and stopping the Dolt server; the design
   constraint "no daemon" would have to be relaxed knowingly.
2. **Delivery confirmation** — have the notice carry a token the agent acknowledges
   with `bd`, so the lead can see which notifications were actually read.
3. **A reviewer role preset** — `teamctl spawn reviewer astra` already works; a
   protocol section and a task template for "second opinion" reviews would make it
   routine.
4. **Per-role settings overlays** — the GLM overlay mechanism generalised to any
   role (for example a QA worker with a narrower tool allow-list).
5. **Linux support** — a secret-service backend instead of the macOS Keychain.
6. **Finer Codex rules** — allow read-only `teamctl` subcommands silently, prompt
   on the mutating ones.

Not planned: an MCP server, a web UI, a daemon, any metered provider.
