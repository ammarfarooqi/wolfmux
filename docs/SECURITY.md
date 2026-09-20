# Billing isolation and security model

The non-negotiable requirement is **subscription-only inference**. This page states
what enforces it, what was measured, and what cannot be proven from the machine.

![Three launchers: what each removes from its own process, what it pins, and which subscription pays](diagrams/billing-isolation.svg)

## The three rules

1. **Nothing global.** No provider variable in a shell profile, no provider entry in
   `~/.claude/settings.json`. `teamctl doctor` checks both and fails loudly. Plain
   `claude` therefore behaves exactly as it did before this was installed.
2. **Every launcher scrubs, then execs.** Whatever environment a launcher inherits
   — your shell, an agent's shell, a tmux server — it removes every variable that can
   redirect, re-authenticate or re-bill the CLI before starting it. The list is one
   file (`lib/provider-env.sh`): explicit names plus prefix sweeps (`ANTHROPIC_`,
   `CLAUDE_CODE_USE_`, `OPENAI_`) so a variable added by a future CLI release is
   still removed.
3. **Provider configuration lives only inside the process that needs it.** The
   Z.ai endpoint and model mapping are exported inside `claude-glm` and nowhere else.

## Per launcher

| Launcher | Credential that remains | Enforcement |
|----------|-------------------------|-------------|
| `claude-fable` | the claude.ai `/login` | nothing else survives the scrub. `teamctl doctor` asks Claude Code itself: `claude-fable auth status --json` must report `authMethod: claude.ai` |
| `codex-astra` | the ChatGPT login | `-c forced_login_method="chatgpt"` makes Codex refuse API-key auth even if a key is stored later; `-c model_provider="openai"` neutralises a redirected provider in `config.toml` |
| `claude-glm*` | the Z.ai Coding Plan key | endpoint `https://api.z.ai/api/anthropic` (the Coding Plan endpoint, not Z.ai's general API); **every** alias Claude Code can resolve — opus, sonnet, fable, haiku, subagents, the main model — is mapped to `glm-5.3` or `glm-5.3-flash`, the only two ids the plan covers |

## How the Z.ai key reaches a worker

The key is read from the macOS Keychain (service `zai-coding-plan`), never from a
file or a profile.

- **`helper` (default).** The launcher passes
  `--settings '{"apiKeyHelper": "/usr/bin/security find-generic-password -s zai-coding-plan -w"}'`.
  Claude Code runs that command when it needs the key. The key is never in the
  environment, so nothing the agent spawns can see it, and it cannot end up in a
  transcript or in tmux scrollback through an `env` dump. Only the command line —
  which contains no secret — is visible in `ps`.
- **`env` (fallback).** `WOLFMUX_GLM_AUTH_MODE=env` in `~/.config/wolfmux/config`
  exports `ANTHROPIC_AUTH_TOKEN`, which is Z.ai's documented method. Use it if the
  endpoint ever rejects helper mode (Claude Code sends a helper's value as both
  `x-api-key` and `Authorization: Bearer`). The trade-off: the key is then visible
  to the worker's subprocesses.

### The login guard — found by measurement

Claude Code's documented credential precedence is: cloud-provider credentials →
`ANTHROPIC_AUTH_TOKEN` → `ANTHROPIC_API_KEY` → `apiKeyHelper` →
`CLAUDE_CODE_OAUTH_TOKEN` → profile credentials → the `/login` subscription.

`tests/credential-routing.sh` points Claude Code at a localhost mock that records
only the *kind* of credential received and rejects every request. Results:

| Scenario | `Authorization` received | Model id |
|----------|--------------------------|----------|
| helper mode + guard (the default launch) | the Z.ai key | `glm-5.3` |
| env mode + guard | the Z.ai key | `glm-5.3` |
| **only `ANTHROPIC_BASE_URL` inherited** (no token, no helper) | **the real claude.ai login** | `glm-5.3` |
| the same, with the guard | an inert placeholder | `glm-5.3` |

Row three is the hazard: a process that inherits the Z.ai base URL without a
credential falls through to the stored login and would present the Claude
subscription token to a third party. A helper passed by command-line flag is
exactly such a case for anything the worker spawns (a nested `claude -p`, an
agent-teams teammate, a background session).

So every GLM worker exports `CLAUDE_CODE_OAUTH_TOKEN` set to a non-secret
placeholder. It ranks above the stored login and below both real delivery modes:
the worker itself still authenticates with the Z.ai key (rows one and two), while
anything it spawns fails closed with a 401. `claude-fable` removes the placeholder
again, and a genuine `CLAUDE_CODE_OAUTH_TOKEN` of yours is left alone.

## GLM worker settings overlay

`~/.config/wolfmux/glm-worker-settings.json` is merged into GLM workers' settings
only. It ships with the `claude-mem` plugin disabled there: that plugin runs a
long-lived summarizer that inherits the environment of whichever session starts
it, and one started from a GLM worker would route memory traffic from your normal
Claude sessions to Z.ai. Delete the file to make workers identical to your normal
sessions. The general rule: a plugin that spawns a persistent process from a
worker inherits the worker's provider.

## What `teamctl doctor` checks

Launchers present and executable · provider variables inherited by the current
shell (names only) · `env` overrides and `apiKeyHelper` in the user and project
Claude settings — these apply *inside* Claude Code and would defeat the scrub, so
they are reported loudly · provider exports in shell profiles · which credential
`claude-fable` would really use · `codex login status` and whether `auth.json`
stores an API key · the Keychain item (existence only) · Z.ai strings anywhere
outside the launchers · key delivery mode, guard and overlay · `CLAUDE_CONFIG_DIR`
/ `CODEX_HOME` relocations · Beads install, telemetry state and hooks.

It prints names and paths, never values. Exit `0` clean, `2` billing/routing
warnings, `1` a missing requirement.

## What cannot be proven locally

Account-side switches are invisible to any local tool. `doctor` prints them as
reminders rather than pretending:

- **claude.ai → Usage → extra usage**: if on, overage beyond the plan is metered.
- **ChatGPT → Codex usage**: purchased credits are consumed after plan limits.
- **z.ai → Billing**: keep the cash balance at zero. Z.ai's FAQ says calls outside
  the plan's two models or endpoint can draw on a balance.

Wording used throughout: *"Configured for subscription authentication; verify
account status in the CLI."*

## Permission modes are a policy, not a sandbox

The default policy runs the lead and the workers in their CLI's bypass mode, because
that is what the owner asked for: no agent stalls on a prompt. In that mode an agent can
run any command as the macOS user. What still applies: Claude Code `deny` rules in every
mode, explicit `ask` rules (the installer adds one for `teamctl destroy`), `teamctl`'s
own confirmation before `destroy`, and the protocol's conduct rules. What limits the
blast radius in practice: each worker sits in its own worktree on its own branch, and
only the lead integrates.

For a stricter team without losing flow: `teamctl policy worker-permissions lead` routes
every worker request to the lead; `ask` hands them back to a human. Both are per
project and take effect on the next (re)start of an agent.

The manager check (`caller_role`) is cooperative. It reads the pane a command runs in,
so a confused agent cannot stop, approve or spawn by accident; an agent that deliberately
unset its environment or called `tmux` directly could get around it, because all agents
share one user account.

## Trust model

Every agent runs as your macOS user. That has consequences worth stating plainly:

- Any agent can run `security find-generic-password -s zai-coding-plan -w`. The
  Keychain protects the key from files, history and other users, not from
  processes you launch yourself. The key's blast radius is the Coding Plan quota.
- `teamctl nudge` validates the role and bead id (letters, digits, `-`, and `._` for
  ids; alphabets spelled out, because `[a-z]` follows the locale) and types only a fixed
  template, so bead content cannot inject keystrokes through it.
- **Teammates are kept apart by a guard, not by a wall.** Each worker has its own
  worktree and branch, and a `PreToolUse` hook (`teamctl _guard`,
  [ADR-0016](adr/0016-worktree-guard.md)) refuses tool calls that change files outside
  that worktree, read a teammate's worktree or teamctl's state, write into the lead's
  checkout, switch, move or delete branches, touch `git worktree`, push to main, or run
  `tmux`. File tools are checked exactly; shell commands by pattern, so a script or a
  path built at run time can get past it. It stops mistakes and drift, not an agent
  that sets out to break it. `teamctl policy worker-isolation off` removes it.
- Teams of different projects share nothing but your user account: separate tmux
  sessions, separate state and worktree directories (keyed by the repository's path),
  separate Beads databases inside each project.
- The Beads hook passes values as separate arguments, never through `eval` or
  `sh -c`. The one `eval` in the code base interpolates one of four literals.
- `rm -rf` is only ever applied to lock and guard directories under
  `~/.wolfmux/state/<project>/`, a path derived from the repository root.

Optional hardening (not applied, because it changes every Claude session on the
machine): deny rules for `Bash(tmux -L wolfmux send-keys*)`,
`Bash(tmux -L wolfmux kill-*)` and `Bash(security *)`.

## Review record (2026-09-20)

| Source | Finding | Disposition |
|--------|---------|-------------|
| code review | a value-taking flag given last (`--base`, `--id`, `-n`) exited silently | fixed; covered by `smoke.sh` |
| code review | a project lock whose holder died before writing its pid was unrecoverable | fixed (reclaimed after 2 s) |
| code review | lead record not rolled back when the tmux session could not be created | fixed |
| code review | `status` / `worktrees` could abort if `destroy` ran concurrently | fixed |
| security review | `CLAUDE_CONFIG_DIR` / `CODEX_HOME` unchecked | `doctor` now follows and reports them; not scrubbed, because a deliberately relocated login must keep working |
| security review | "refuse env mode for team workers" | not adopted: measurement showed the opposite risk (the login fall-through) is the serious one; both modes now carry the guard |
| security review | dead `not_match` clause in the Codex rule file | removed |
| security review | stale-guard takeover race in the nudge debounce | accepted: worst case is one duplicate notification |
| audit | the global allow rules `git diff/log/show *` and `tmux -L wolfmux list-panes/capture-pane *` allowed more than they read: a rule is a prefix match, so `git log --output=<file>` wrote any file and `tmux … \; run-shell …` ran any command, in every Claude Code session on the machine | removed and listed under `retired` in `claude/permissions.json`; `install.sh` takes them out of an existing settings file, `uninstall.sh` removes them too; covered by `tests/permissions.sh` |
| audit | `teamctl doctor` died with `unbound variable` under a UTF-8 locale exactly when a settings file held a provider override (`$keys` followed by a dash: bash 3.2 reads the first byte as part of the name) | fixed; covered by `smoke.sh`, which also refuses any variable followed directly by a non-ASCII character |
