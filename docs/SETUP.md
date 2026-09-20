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
| copies files | `bin/*` → `~/bin/`, `config/wolfmux/*` → `~/.config/wolfmux/` (a differing existing file is backed up first; `config` and `glm-worker-settings.json` are never overwritten) |
| two symlinks | `~/bin/claude-glm-flash` → `claude-glm`; `~/bin/codex` → ChatGPT.app's CLI, only when no `codex` is on PATH |
| `~/.zshrc` | appends one marked block that adds `~/bin` to the **end** of `PATH`, so nothing in it can shadow an existing tool |
| `~/.claude/settings.json` | merges the rules in `claude/permissions.json`: allow `teamctl`, `bd`, read-only `git` and read-only tmux on the team server; **ask** before `teamctl destroy` |
| `~/.codex/rules/wolfmux.rules` | a separate execpolicy file: `teamctl` and `bd` may run outside the Codex sandbox, `teamctl destroy` prompts. `default.rules` is not touched |

Every edited file gets `<file>.backup-YYYYMMDD-HHMMSS`. Running it again changes
nothing. Skip parts with `--no-path`, `--no-claude-permissions`, `--no-codex-rules`.
It never creates `~/.tmux.conf`, never edits CLAUDE.md or AGENTS.md, and never
reads, asks for or writes a credential.

## 3. The Z.ai key

Run this yourself; you are prompted twice, nothing is echoed, nothing reaches shell
history:

```bash
security add-generic-password -U -s zai-coding-plan -a "$USER" -l "Z.ai Coding Plan API key" -w
```

Never put the key in `~/.zshrc`, `~/.claude/settings.json`, a `.env`, or a chat.
Replace it later with the same command (`-U` updates). Remove it with
`security delete-generic-password -s zai-coding-plan`.

## 4. Verify

Open a new terminal (for the `PATH` change), then:

```bash
teamctl doctor                  # expect no "!! WARNING !!" and no FAIL lines
WOLFMUX_DRY_RUN=1 claude-glm    # shows endpoint, model, auth mode; starts nothing
~/Documents/wolfmux/tests/smoke.sh   # 31 checks, isolated, no model calls (~1 minute)
```

Account-side switches no local tool can see — check them once:

- claude.ai → Settings → Usage: keep **extra usage** off.
- ChatGPT → Settings → Codex usage: do not buy or auto-refill credits.
- z.ai → Billing: a **zero cash balance** makes pay-as-you-go impossible even if a
  call ever fell outside the plan.

## 5. First team

```bash
cd ~/code/your-project        # any git repository with at least one commit
teamctl start fable           # offers the stealth Beads init on first use
```

If GLM workers report an authentication error, set `WOLFMUX_GLM_AUTH_MODE=env` in
`~/.config/wolfmux/config` and `teamctl restart <role>`
([why](SECURITY.md#how-the-zai-key-reaches-a-worker)).

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
security delete-generic-password -s zai-coding-plan     # optional
```

`uninstall.sh` refuses to run while a team is up, removes only what `install.sh`
created, restores `~/.zshrc` byte-for-byte, removes exactly the permission rules it
added, and leaves Claude Code, Codex, Beads, your Keychain and your repositories
alone.
