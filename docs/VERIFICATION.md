# Verification

No model call was made to test this system. Real CLIs were only started as far as
their first screen; everything else used stub agents or a localhost mock.

## Re-run it

```bash
tests/smoke.sh                 # ~2 minutes, 48 checks, isolated from any running team
tests/credential-routing.sh    # manual; needs claude logged in; see the header for side effects
teamctl doctor
```

`smoke.sh` tests the checkout it lives in. It uses its own tmux server
(`wolfmux-test-<pid>`), its own state directory, a throwaway repository whose path
contains a space, and `tests/stub-agent` in place of every CLI. It was run while a
real team was live on the same machine; the real team was unaffected.

## smoke.sh — 48 of 48 pass (2026-09-20)

| Area | Checks |
|------|--------|
| start | session running and lead registered · repository left clean by the stealth Beads init (no commit, no tracked file) |
| spawn | two workers running · own branch each · worktrees outside the repository · `--base` recorded · `TEAM_ROLE` / `BEADS_ACTOR` / model set inside the pane · no provider or agent-session variable leaks into a pane · kickoff prompt present by default and absent with `--no-kickoff` · lead is pane 0 · pane titles are `<role> · <model>` |
| validation | duplicate role refused · `lead` and malformed roles refused · flag without a value reports usage with exit 64 |
| one manager | default policy is skip / skip / spawning off · lead and workers start in their CLI's bypass mode · agent teams switched off inside workers, lead's settings left alone · a worker cannot spawn while the toggle is off (exit 77) · a worker cannot stop, restart, destroy, approve, deny or change policy · with the toggle on a worker can spawn, the record says who spawned whom, and the lead is told |
| approvals | lead mode starts a worker without bypass and with the hook · a request is filed and the lead is told · status shows it pending · a worker cannot approve its own request · approve → the CLI receives `allow` · deny → the CLI receives `deny` with the reason · no answer → no decision, so the normal prompt appears · ask mode has neither flag nor hook |
| notifications | fixed line typed into the pane · debounced inside the window · hostile bead id (`x;rm -rf ~`) dropped, never typed |
| Beads | a message to a role notifies its pane · body stored intact (`"quotes"`, `$HOME`, backticks) and never typed into the pane · a worker reads the shared database from its external worktree |
| git | `diff` commits / stat / patch · uncommitted leftovers visible · main checkout untouched by worker commits · `worktrees` lists everyone |
| lifecycle | stop keeps the record · restart reuses worktree and branch · destroy refuses without confirmation when non-interactive · destroy `--yes` works · dirty worktree with an unmerged commit is **kept** · clean worktree removed and merged branch deleted · session gone |

## Live checks with the real CLIs

| Check | Result |
|-------|--------|
| `teamctl start fable` in a throwaway repo | real Claude Code TUI in the lead pane, stopped at its folder-trust prompt; process flags: `--model claude-fable-5-1[1m] --append-system-prompt <protocol> --name team/lead` |
| `teamctl start astra` in the same repo | real Codex TUI, at its folder-trust prompt; flags: `forced_login_method="chatgpt"`, `model_provider="openai"`, `model="gpt-6-astra"`, `developer_instructions=…`; no `OPENAI_*` / `CODEX_API_KEY` in the process environment |
| 2×2 layout | lead (0,1) · backend (110,1) · frontend (0,30) · qa (110,30) on a 220×60 window |
| real `claude-glm` with no Keychain item | pane shows the exact `security add-generic-password …` command, state `exited(78)`, pane kept |
| worker → lead | `Done:` message with `--body-file` notified the lead; closing the task notified the lead again; report body intact in the lead's inbox |
| worker → worker | backend messaged frontend directly; frontend's pane was notified |
| `claude-fable` with hostile environment (Z.ai base URL, a token, the guard placeholder) | `claude-fable auth status` → `authMethod: claude.ai`, `subscriptionType: max` |
| `WOLFMUX_DRY_RUN=1` with injected `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `CODEX_API_KEY` | each launcher lists them as scrubbed and shows an empty provider environment |
| fresh login shell | no `ANTHROPIC_*`, `OPENAI_*`, `CODEX_API_KEY`, `ZAI*` or `CLAUDE_CODE_USE_*` variable; plain `claude` still resolves to the original binary |
| secrets scan of every created file | no matches |
| Codex rules | `codex execpolicy check`: `teamctl …` → allow, `bd …` → allow, `teamctl destroy` → prompt, unrelated commands → no match |

## Probes of the real Claude Code CLI (no prompt sent, endpoint = localhost mock)

| Probe | Observation |
|-------|-------------|
| session with the owner's global settings (agent teams = 1) | Claude Code created `~/.claude/teams/session-<id>/`: the session is a team lead, and named subagents become its teammates |
| same session plus the per-worker settings `teamctl` generates (`env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "0"`, `teammateMode = "in-process"`) | **no team directory created**: the override passed through `--settings` beats the global value |
| `--dangerously-skip-permissions` through the worker environment | footer `bypass permissions on`, prompt ready, no blocking dialog |
| banner of a key-authenticated session | reads `API Usage Billing` — Claude Code's label for any key-based login, here the Z.ai Coding Plan key |

## Beads evaluation (sandboxed `HOME`)

| Question | Finding |
|----------|---------|
| Can several agents write concurrently without a database server? | 16 parallel `bd create` + 8 parallel `bd list` in embedded mode: all succeeded, count exact, 16 unique ids, 20 s total (writers queue on a file lock with backoff) |
| Is claiming atomic? | three simultaneous `--claim` on one task: one winner, two clean "already claimed by" errors |
| Do external worktrees share the database? | yes, through git's common directory; no stray `.beads` appears in the worktree |
| What does `bd init` touch by default? | it **commits** `.beads/*` and a `.gitignore` to the current branch. `--stealth --skip-hooks --skip-agents` makes no commit, adds no tracked file and leaves global git config alone |
| Do event hooks exist and what do they receive? | `.beads/hooks/on_create`, `on_update`, `on_close`; argv `<id> <event>`, the bead as JSON on stdin, the caller's environment. Comments fire none |
| Are message beads listed by default? | no — `bd list` hides them unless `--type message` or `--include-infra` is given. Every inbox command in this project carries `--include-infra` |

## install.sh / uninstall.sh (fake `HOME`)

Second install run changed nothing · existing `allow` entries not duplicated and
`deny` preserved · install then uninstall left `~/.zshrc` byte-identical · exactly
the added permission rules removed · uninstall refused while a team was running.

## Not verified

- **A real request to Z.ai.** No key was available during the build and inference
  was avoided on purpose. Helper mode sends the key as both `x-api-key` and
  `Authorization`; if Z.ai rejects that, `WOLFMUX_GLM_AUTH_MODE=env` is the
  documented path.
- Model ids sent by background features of an *interactive* session (titles,
  suggestions). The `-p` runs showed only `glm-5.3`; the alias mapping covers the
  rest by configuration, not by observation.
- Behaviour with more than about eight concurrent agents.
