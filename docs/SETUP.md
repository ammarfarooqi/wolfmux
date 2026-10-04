# Setup

About 10 minutes on a machine that already has the three subscriptions signed in.

## 1. Prerequisites

| Need | Check | Notes |
|------|-------|-------|
| macOS | `sw_vers` | built and tested on macOS 26.6 (arm64); uses the login Keychain and `/bin/bash` 3.2 |
| tmux, git, jq | `tmux -V; git --version; jq --version` | tested with tmux 3.7c, git 2.50, jq 1.7.1 |
| Claude Code, signed in with a Claude subscription | `claude auth status` → `"authMethod": "claude.ai"` | tested with 2.1.278 |
| Codex CLI, signed in with ChatGPT | `codex login status` → `Logged in using ChatGPT` | the copy inside ChatGPT.app is enough; the installer links it as `~/bin/codex` when no `codex` is on PATH |
| Beads | `bd version` | tested with 1.3.0; see below |
| Z.ai GLM Coding Plan + an API key | [z.ai/manage-apikey](https://z.ai/manage-apikey/apikey-list) | the key goes into the Keychain in step 3 |
| other providers (optional) | see step 3 | Kimi, Moonshot, DeepSeek, MiniMax, Qwen: add a key only for the ones you want |

### Installing Beads without Homebrew

Verified release binary into a user-owned directory:

```bash
V=1.3.0; A="beads_${V}_darwin_arm64.tar.gz"
base="https://github.com/gastownhall/beads/releases/download/v${V}"
cd "$(mktemp -d)" && curl -fsSLO "$base/$A" && curl -fsSLO "$base/checksums.txt"
[ "$(grep " $A\$" checksums.txt | cut -d' ' -f1)" = "$(shasum -a 256 "$A" | cut -d' ' -f1)" ] && echo CHECKSUM OK
tar -xzf "$A" && install -m 0755 bd ~/.local/bin/bd
bd metrics off        # Beads sends anonymous command names by default; this turns it off
```

## 2. Install

```bash
git clone <this repo> ~/Documents/wolfmux
cd ~/Documents/wolfmux
./install.sh
```

What it does, and nothing else:

| Action | Detail |
|--------|--------|
| copies files | `bin/*` → `~/bin/` (`teamctl`, `claude-fable`, `codex-astra`, `claude-glm`), `config/wolfmux/*` → `~/.config/wolfmux/` (a differing existing file is backed up first; `glm-worker-settings.json` is never overwritten; `config` is left alone once it holds one active line, and while it is still all comments it is replaced by the current template, so new settings show up in it) |
| nine symlinks | `~/bin/claude-glm-flash` and the provider names `~/bin/claude-kimi`, `claude-moonshot`, `claude-deepseek`, `claude-minimax`, `claude-qwen` → `claude-glm`, which picks the provider from the name it was started as; `~/bin/claude-opus`, `claude-sonnet`, `claude-haiku` → `claude-fable`, which picks the model the same way |
| `~/bin/codex` | only when no `codex` is on PATH: a small `sh` wrapper (one `exec` line) that starts ChatGPT.app's bundled CLI by its real path. Not a symlink: Codex looks for its helper programs next to the path it was started as, and through a symlink it could not run commands ("Code Mode is unavailable"). A symlink left by an earlier version is replaced |
| builds `Wolfmux.app` | `~/.config/wolfmux/Wolfmux.app`, compiled with `osacompile` from `config/wolfmux/notifier/`, given the wolf icon and signed ad hoc. It owns the notifications of a team that is not open in a terminal which can show them itself (iTerm2, kitty, Ghostty, WezTerm), so that clicking one opens the team instead of Script Editor. Rebuilt only when its source changes. No network, no login item, nothing in `/Applications` |
| `~/.zshrc` | appends one marked block that adds `~/bin` to the **end** of `PATH`, so nothing in it can shadow an existing tool, and sources the tab-completion shim for `teamctl` (registered only when a completion system is loaded) |
| `~/.claude/settings.json` | merges the rules in `claude/permissions.json`: allow `teamctl`, `bd`, `git status` and `git worktree list`; **ask** before `teamctl destroy`. Rules under `retired` (`git diff/log/show *`, tmux on the team server) are taken out again: a rule is a prefix match, and those also allowed `git log --output=<file>` and `tmux … \; run-shell …` in every Claude Code session |
| `~/.codex/rules/wolfmux.rules` | a separate execpolicy file: `teamctl` and `bd` may run outside the Codex sandbox, `teamctl destroy` prompts. `default.rules` is not touched |

Every edited file gets `<file>.backup-YYYYMMDD-HHMMSS`. Running it again changes
nothing; an install from before tab completion gets the two completion lines added
to the existing `~/.zshrc` block, after a backup, exactly once. Skip parts with
`--no-path`, `--no-completion` (only the completion lines), `--no-claude-permissions`,
`--no-codex-rules`, `--no-notifier-app`.
It never creates `~/.tmux.conf`, never edits CLAUDE.md or AGENTS.md, and never
reads, asks for or writes a credential.

## 3. The keys

Run these yourself; you are prompted for each value, nothing is echoed, nothing
reaches shell history. One Keychain service per provider, so a key can never be
pointed at another provider's endpoint:

```bash
# Z.ai GLM Coding Plan: required (the default worker model)
security add-generic-password -U -s zai-coding-plan -a "$USER" -l "Z.ai Coding Plan API key" -w

# the other providers: one line each, only for the ones you want
security add-generic-password -U -s wolfmux-kimi     -a "$USER" -l "Kimi for Coding API key"      -w
security add-generic-password -U -s wolfmux-moonshot -a "$USER" -l "Moonshot platform API key"    -w
security add-generic-password -U -s wolfmux-deepseek -a "$USER" -l "DeepSeek API key"             -w
security add-generic-password -U -s wolfmux-minimax  -a "$USER" -l "MiniMax Coding Plan API key"  -w
security add-generic-password -U -s wolfmux-qwen     -a "$USER" -l "Alibaba Model Studio API key" -w
```

| Provider | Get the key at | Pays with |
|----------|----------------|-----------|
| Z.ai | [z.ai/manage-apikey](https://z.ai/manage-apikey/apikey-list) | GLM Coding Plan (subscription) |
| Kimi | [Kimi Code console](https://www.kimi.com/code/console): a membership key, starts `sk-kim` ([docs](https://www.kimi.com/code/docs/en/third-party-tools/claude-code)) | Kimi for Coding subscription |
| Moonshot | [Kimi API platform](https://platform.kimi.ai/console/api-keys) ([docs](https://platform.kimi.ai/docs/guide/claude-code-kimi)) | platform API, billed per request |
| DeepSeek | [DeepSeek Claude Code guide](https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code/) | API, billed per request |
| MiniMax | [MiniMax coding plan docs](https://platform.minimax.io/docs/coding-plan/claude-code) | MiniMax Coding Plan (subscription) |
| Qwen | [Model Studio Claude Code guide](https://www.alibabacloud.com/help/en/model-studio/claude-code): a Coding Plan key, starts `sk-sp-` | Model Studio coding plan (subscription) |

Moonshot and DeepSeek are the two metered providers: their workers refuse to start
until you set `WOLFMUX_METERED=on` in `~/.config/wolfmux/config` yourself. No agent
can do that for you.

The two Kimi keys are not interchangeable. Both consoles say "Kimi" and both keys start with
`sk-`, but a key from the Kimi Code console (a membership key, starts `sk-kim`) works only with the
`kimi` provider, and a key from platform.kimi.ai works only with `moonshot`. Store each in its
own slot (`wolfmux-kimi`, `wolfmux-moonshot`). If you are unsure which you have, step 4's
`teamctl doctor --probe` says.

Never put a key in `~/.zshrc`, `~/.claude/settings.json`, a `.env`, or a chat.
Replace one later with the same command (`-U` updates). Remove one with
`security delete-generic-password -s <service>`.

## 4. Verify

Open a new terminal (for the `PATH` change), then:

```bash
teamctl doctor                  # expect no "!! WARNING !!" and no FAIL lines
teamctl doctor --probe          # optional, reads your keys: asks each endpoint whether it accepts its key (nothing is billed)
WOLFMUX_DRY_RUN=1 claude-glm    # shows endpoint, model, auth mode; starts nothing
WOLFMUX_DRY_RUN=1 claude-kimi   # any provider name works; shows billing and the metered gate too
~/Documents/wolfmux/tests/smoke.sh   # the whole lifecycle with stub agents: isolated, no model calls, 2 to 4 minutes
```

macOS asks two things, once each: to allow notifications from **Wolfmux**, the first time
an agent finishes while its team is not open in front of you; and to let Wolfmux control
your terminal, the first time you click one (that is how a click opens the team). Allow
both.

Account-side switches no local tool can see — check them once:

- claude.ai → Settings → Usage: keep **extra usage** off.
- ChatGPT → Settings → Codex usage: do not buy or auto-refill credits.
- z.ai → Billing: a **zero cash balance** makes pay-as-you-go impossible even if a
  call ever fell outside the plan.
- Moonshot / DeepSeek, if you switched `WOLFMUX_METERED` on: they bill per request
  for as long as the balance you loaded lasts. That switch is yours; an agent that
  asks for it should be refused.

## 5. First team

```bash
cd ~/code/your-project        # any git repository with at least one commit
teamctl start fable           # offers the stealth Beads init on first use; any model key can lead
teamctl spawn backend glm53   # then see the README's command list, or: teamctl help
```

If a worker reports 401 or an authentication error, run `teamctl doctor --probe` first: a rejected
key (the wrong kind, the wrong slot, or expired) is the usual cause, and `env` mode cannot fix
that. `WOLFMUX_<P>_AUTH_MODE=env` in `~/.config/wolfmux/config` (then `teamctl restart <role>`) is
the last resort for an endpoint that refuses helper-mode headers
([why](SECURITY.md#how-the-zai-key-reaches-a-worker)); what it costs is under
[auth modes](../README.md#auth-modes).

## Coming from "ai-team" (v1.1 and earlier)

This tool's first name was "ai-team". `install.sh` refuses to run next to that
installation; move it instead:

```bash
cd ~/Documents/wolfmux
./migrate-from-ai-team.sh --dry-run    # prints every step, changes nothing
./migrate-from-ai-team.sh              # under a minute
```

| Moves | To |
|-------|----|
| `~/.ai-team` (state, worktrees, backups) | `~/.wolfmux`; stored paths rewritten, `git worktree repair` run in each project |
| `~/.config/ai-team/config`, `glm-worker-settings.json` | `~/.config/wolfmux/`, settings keys renamed `AI_TEAM_*` → `WOLFMUX_*` |
| the marked block in `~/.zshrc`, two tmux rules in `~/.claude/settings.json` | renamed in place, each file backed up first |
| `~/.codex/rules/ai-team.rules`, the rest of `~/.config/ai-team` | parked in `~/.wolfmux/backups/<stamp>/` |
| each project's `.beads/hooks/on_*` | rewritten to call the new hook |

A team that is running is **not** restarted: it stays on its tmux socket (`ai-team`) and
`teamctl` follows it there until its last session ends. The only refusal is a live worker
inside `~/.ai-team` — `teamctl stop <role>` first (worktree and branch are kept). A lead
that was already running keeps the old names in its instructions until
`teamctl restart lead --continue`. Unchanged: the `teamctl` command, `ai/<role>`
branches, the Keychain item. Shell variables you export yourself need the new prefix.

## Updating

| What | How |
|------|-----|
| this tool | `git pull && tests/smoke.sh && ./install.sh` |
| Claude Code | `claude update` — launchers resolve `claude` at run time |
| Codex | update the ChatGPT desktop app. A standalone install (`curl -fsSL https://chatgpt.com/codex/install.sh \| sh`) lands in `~/.local/bin`, which precedes `~/bin`, so it takes over automatically |
| Beads | `bd export --all > backup.jsonl`, replace `~/.local/bin/bd` with a verified release, then follow the Beads upgrade guide |
| after any update | `teamctl doctor` |

Never run `codex login --with-api-key`, never export `ANTHROPIC_API_KEY` or
`OPENAI_API_KEY` globally, never paste a Z.ai block into `~/.claude/settings.json`.

## Uninstalling

```bash
teamctl destroy --worktrees     # in each project that has a team
./uninstall.sh                  # add --purge to also remove an empty ~/.wolfmux
security delete-generic-password -s zai-coding-plan     # optional, and the same for
security delete-generic-password -s wolfmux-kimi        # every provider key you added
```

`uninstall.sh` refuses to run while a team is up, removes only what `install.sh`
created, restores `~/.zshrc` byte-for-byte, removes exactly the permission rules it
added, and leaves Claude Code, Codex, Beads, your Keychain and your repositories
alone.
