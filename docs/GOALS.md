# Goals, constraints and non-goals

## The goal

Run a small AI development team locally, the way one would run a human one:

- a **lead** that acts as architect, coordinator and reviewer — either
  Claude Code + Fable 5.1 or Codex CLI + GPT-6 Astra, interchangeably;
- **workers** that implement — Claude Code driving GLM-5.3 (substantial work) or
  GLM-5.3 Flash (simple, repetitive, QA and integration work);
- everything **visible at once** in tmux panes, similar to Claude's Agent Teams;
- the lead can spawn workers on demand, assign roles, message them, inspect their
  status and terminal output, stop and restart them, receive completion reports,
  inspect their branches, review their diffs and integrate approved work;
- workers can talk to each other directly.

## Hard constraints

These are requirements, not preferences. Each one maps to a mechanism described in
[SECURITY.md](SECURITY.md) or [ARCHITECTURE.md](ARCHITECTURE.md).

1. **Metered inference is never reached by accident.** The subscriptions are the
   default: Claude, ChatGPT/Codex, and the coding plans of Z.ai, Kimi, MiniMax and
   Alibaba. Two providers in the table (Moonshot's platform, DeepSeek) are
   pay-as-you-go APIs: they refuse to run until the owner has stored their key and
   set `WOLFMUX_METERED=on` (`teamctl` and the launcher both refuse without it).
   Never Anthropic API billing, OpenAI API billing, OpenRouter, LiteLLM or any
   metered proxy, whatever that switch says ([ADR-0020](adr/0020-providers-beyond-the-three-subscriptions.md)).
2. **Normal `claude` is never redirected.** No global environment variable and no
   settings entry may point Claude Code at Z.ai. Z.ai configuration exists only
   inside the GLM launcher's own process.
3. **Credentials are never exposed** — not in source files, shell history, git,
   logs, the repository, or chat. The Z.ai key lives in the macOS Keychain.
4. **Existing configuration is inspected and preserved.** Claude, Codex, shell,
   git, tmux, MCP, skills, hooks, CLAUDE.md and AGENTS.md are not overwritten.
   Anything edited is backed up first as `<file>.backup-YYYYMMDD-HHMMSS`.
5. **Agents never share a working tree.** One branch and one git worktree per
   worker, stored outside the project directory.
6. **State is structured, not scraped.** Task state never comes from parsing
   terminal output. tmux is only the UI, the process manager and the transport
   for a one-line notification.
7. **Model-neutral orchestration.** The same commands, protocol and workers
   regardless of which model leads.
8. **Reversible and removable.** Everything can be uninstalled without touching
   the CLIs themselves.
9. **No heavy infrastructure.** No Node, Docker, cloud service, remote server,
   database server or daemon for orchestration.

## Goals added along the way

The brief above is the one the first version was built to. Using it added these, each
with its decision record:

| Goal | Record |
|------|--------|
| any model in any seat: a Fable team takes an Astra teammate for one review, an Astra team a Sonnet one; `opus`, `sonnet`, `haiku`, `claude:<id>`, `codex:<id>` next to the original keys | [ADR-0017](adr/0017-any-model-for-any-agent.md) |
| several teams in one project, named by the owner, shown as a tree (team → 🐺 lead → 🐶 teammates) | [ADR-0018](adr/0018-several-teams-per-project.md) |
| teams message each other; a lead founds a fresh team and hands work over; one command deletes a whole team and frees its disk space, after showing what would be lost | [ADR-0019](adr/0019-deleting-a-team-and-founding-one.md) |
| more providers beside Z.ai (Kimi, Moonshot, DeepSeek, MiniMax, Qwen) through the same one launcher: one table of facts, one Keychain service per provider, metered ones off until the owner switches them on | [ADR-0020](adr/0020-providers-beyond-the-three-subscriptions.md) |
| a teammate stays in its own worktree and on its own branch (a guard, on top of constraint 5) | [ADR-0016](adr/0016-worktree-guard.md) |
| the manager is always recognisable, and you are told when an agent finishes: click the notification, land in the team | [ADR-0015](adr/0015-notifications-through-the-attached-terminal.md) |

## The mid-build scope change

The original brief specified a custom filesystem task and message store inside
`teamctl`, to be migrated to SQLite later. During the build the owner replaced that
with **[Beads](https://github.com/gastownhall/beads)** and narrowed `teamctl`'s
responsibility to **tmux processes, models, worktrees and lifecycle**. Consequences:

- `teamctl send`, `inbox`, `broadcast`, `task …` and `message-history` do not
  exist. Typing them prints the equivalent `bd` commands.
- The planned SQLite migration is moot: Beads brings its own versioned database.
- See [ADR-0002](adr/0002-beads-for-tasks-and-messages.md).

## Non-goals

- A web UI, a service, an MCP server, Redis, Docker.
- Unattended operation. A human can see and interrupt every agent.
- Sandboxing agents from the user account. Every agent runs as the macOS user;
  the permission prompts of each CLI remain the safety boundary
  ([SECURITY.md](SECURITY.md#trust-model)).
- Cross-machine teams. Beads can sync across machines; this setup does not use it.

## What "done" means

- `teamctl doctor` reports no warnings.
- `tests/smoke.sh` passes, and `tests/docs.sh`: what the code offers (commands, options,
  policy keys, models, settings, launchers) is named where a reader looks for it; which
  document has to name what is listed in [VERIFICATION.md](VERIFICATION.md).
- A lead of either kind can run the whole flow in
  [USAGE.md](USAGE.md#a-complete-session) using only `teamctl`, `bd` and `git`.
