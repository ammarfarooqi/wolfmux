# Verification

No model call was made to test this system. Real CLIs were only started as far as
their first screen; everything else used stub agents or a localhost mock.

## Re-run it

```bash
tests/smoke.sh                 # ~3 minutes, 120 checks, isolated from any running team
tests/migration.sh             # ~30 seconds, 21 checks, in a throwaway HOME
tests/credential-routing.sh    # manual; needs claude logged in; see the header for side effects
teamctl doctor
```

`smoke.sh` tests the checkout it lives in. It uses its own tmux server
(`wolfmux-test-<pid>`, `wolfmux-test-old-<pid>`), its own state directory, a throwaway repository whose path
contains a space, and `tests/stub-agent` in place of every CLI. It was run while a
real team was live on the same machine; the real team was unaffected.

## smoke.sh — 120 of 120 pass (2026-09-20)

| Area | Checks |
|------|--------|
| launchers | `codex-astra` starts Codex by its real path, never through a symlink · `claude-opus`, `-sonnet`, `-haiku` are the subscription launcher pinned to their model, each pin configurable · `claude-glm` declares a 200k context window · `1m` uses the suffix instead, a number is declared, nonsense falls back with a warning · a context value from outside is scrubbed, never inherited |
| start | session running and lead registered · repository left clean by the stealth Beads init (no commit, no tracked file) |
| spawn | two workers running · own branch each · worktrees outside the repository · `--base` recorded · `TEAM_ROLE` / `BEADS_ACTOR` / model set inside the pane · no provider or agent-session variable leaks into a pane · kickoff prompt present by default and absent with `--no-kickoff` · lead is pane 0 · pane titles are `<role> · <model>` |
| validation | duplicate role refused · `lead` and malformed roles refused · a capital letter is refused under `C`, `en_AU.UTF-8` and `en_US.UTF-8` alike · a role an older version let through can still be listed and stopped · a role name can never leave the registry directory · flag without a value reports usage with exit 64 |
| any model | a Codex teammate in a team led by another model · a Claude-subscription teammate (sonnet) beside GLM workers, with the guard · `claude:<id>` and `codex:<id>` reach the CLI · a Codex teammate gets the notify program · nonsense (`gpt`, `claude:`, `claude:bad;id`, `glm:glm-9`, `codex:a b`) is refused before anything is created |
| lanes | words are not commands: prose in quotes and heredocs never triggers the guard, a quoted path still does · MCP tools are held to the same lanes · every worker has the guard, the lead does not · a worker may change files in its own worktree (absolute, relative, new) and in temporary directories · not the lead's checkout, a teammate's worktree, `~/.zshrc`, or anything reached with `..` · it may read the lead's checkout, never a teammate's worktree or teamctl's state · ordinary shell work passes (tests, commits, `git checkout -- file`, `git push -u origin HEAD`, copying `.env` from the lead's checkout, `teamctl`, `bd`, rebase) · reaching into another worktree or writing into the lead's checkout is refused, in either spelling of the path · switching, creating or deleting branches, `git worktree`, `tmux`, pushes to main are refused · the lead is not guarded and an agent the guard cannot place is allowed · `worker-isolation off` removes it at the next start |
| clearing up | a running agent is never removed · `destroy --worktrees` names what it kept and both ways out · without `--force` work is never discarded and the refusal lists the commit and the files · a worker cannot remove anyone (exit 77) · `--force` needs a yes when nobody can be asked · `remove --force --yes` takes worktree, branch and record, the main checkout is untouched · a damaged record can never delete a directory outside the worktrees or a branch that is not `ai/*` · all or nothing: one worker that holds work stops the whole command · an unknown role is an error |
| one manager | default policy is skip / skip / spawning off / isolation on · lead and workers start in their CLI's bypass mode · agent teams switched off inside workers, lead's settings left alone · a worker cannot spawn while the toggle is off (exit 77) · a worker cannot stop, restart, destroy, approve, deny or change policy · with the toggle on a worker can spawn, the record says who spawned whom, and the lead is told |
| approvals | lead mode starts a worker without bypass and with the hook · a request is filed and the lead is told · status shows it pending · a worker cannot approve its own request · approve → the CLI receives `allow` · deny → the CLI receives `deny` with the reason · no answer → no decision, so the normal prompt appears · ask mode has neither flag nor hook |
| notifications | fixed line typed into the pane · debounced inside the window · hostile bead id (`x;rm -rf ~`) dropped, never typed |
| Beads | a message to a role notifies its pane · body stored intact (`"quotes"`, `$HOME`, backticks) and never typed into the pane · a worker reads the shared database from its external worktree |
| git | `diff` commits / stat / patch · uncommitted leftovers visible · main checkout untouched by worker commits · `worktrees` lists everyone |
| the wolf | the session has the `client-attached` popup hook · the splash draws wolf, wordmark and team line · no colour codes outside a terminal · it works outside any project · only the manager pane has the mark and the amber border · the manager pane opens with the wolf · status line and tab title carry it · `WOLFMUX_SPLASH=off` removes the popup and the default restores it · a Claude lead is named `🐺 team/lead`, workers are not |
| arrangement | by default the lead is the large pane on the left and workers share one column on the right · `lead-top` puts the lead across the top · `tiled` is available, the choice is remembered, an unknown name is refused (exit 64) · the arrangement survives a spawn and a stop |
| closing and coming back | a lead that exited comes back in place and the worker keeps its pane · asking for the other lead model brings it back as that model · when every agent has exited, `start` opens a fresh session with one pane and marks workers stopped · `--continue` reaches the lead's CLI · a stopped worker returns with `restart` into the arrangement · **a pre-rename team whose agents have all exited is replaced by a fresh one on the new socket** |
| desktop notifications | every Claude agent gets the `Stop` hook, the plugin notifier is silenced and the user's own disabled hook is kept · OSC 9 to the attached terminal with the first line, markdown dropped · the lead is marked · **an OSC 52 and a clear-screen sequence inside a message never reach the terminal** (exactly two control bytes come out: ours) · long messages are cut · no terminal attached → `osascript` with the text as an argument, never a failure · nobody attached → the message is handed to Wolfmux.app, not to `osascript`, and the project is remembered · the app fetches its message exactly once, so its next start is a click · a message it never fetched is not posted late · a click opens a terminal on the team (script with the project and `teamctl attach`) · `WOLFMUX_NOTIFY=lead` keeps workers quiet |
| rename | an explicitly chosen socket is never redirected · teamctl follows a team on the old socket · new panes join it · destroy ends it · the next team starts on the new socket · a Beads hook written under the old name is replaced · a hook that is not ours is left alone |
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

## What a person sees on attach (captured through an outer tmux, 150×44)

```
── 🐺 lead · GPT-6 Astra ──────────────────────────┬── backend · GLM-5.3 ─────────
[wolfmux] role=lead  model=GPT-6 Astra  launcher╭──────────────────────────────────────────────────╮
                                                │          █▄                          ▄█          │
                                                │         ████████████████████████████████         │
                                                │       ▄██████▀▀▀▀▀█▀██▀██▀██▀█▀▀▀▀▀██████▄       │
                                                │                  W O L F M U X                   │
                                                │             a pack of agents in tmux             │
                                                │     team-demo · lead GPT-6 Astra · 2 workers     │
                                                ╰──────────────────────────────────────────────────╯
 🐺 WOLFMUX  0:team*                                                          team-demo · 15:08
```

(abridged). The border line of the lead was emitted in colour 214 (amber), the workers'
in 244 (grey); the terminal title was set to `🐺 team-demo`. On an 80×24 terminal tmux
shrinks the popup and the splash drops lines to fit instead of scrolling.

## Probes of the real Claude Code CLI (no prompt sent, endpoint = localhost mock)

| Probe | Observation |
|-------|-------------|
| session with the owner's global settings (agent teams = 1) | Claude Code created `~/.claude/teams/session-<id>/`: the session is a team lead, and named subagents become its teammates |
| same session plus the per-worker settings `teamctl` generates (`env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "0"`, `teammateMode = "in-process"`) | **no team directory created**: the override passed through `--settings` beats the global value |
| `--dangerously-skip-permissions` through the worker environment | footer `bypass permissions on`, prompt ready, no blocking dialog |
| `claude -p --model glm-5.3` with the environment a GLM worker had before 1.4 | prints `"glm-5.3" isn't described by this version's model catalog … auto-compact keeps this session within 200k tokens`; the same for `glm-5.3-flash` |
| the same with `CLAUDE_CODE_MAX_CONTEXT_TOKENS=200000`, as `claude-glm` and `claude-glm-flash` now export it | **no notice**. Also silent: the `[1m]` suffix, and `CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1` (not used: it changes behaviour, the declaration does not) |
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

## migration.sh — 21 of 21 pass (2026-09-20)

A throwaway `HOME` gets v1.1 installed from git history, a team started with it (lead +
one worker, stub agents, its own tmux sockets), then `migrate-from-ai-team.sh`.

| Area | Checks |
|------|--------|
| refusals | new `install.sh` will not install next to v1.1 · migration refuses while a worker runs inside `~/.ai-team` and changes nothing · `--dry-run` changes nothing |
| state | old directories gone, old config parked in backups · a user setting arrives under its new key · program files are the new version · no stored record points into `~/.ai-team` · a second run finds nothing to do |
| the live team | **the running lead is not restarted** (same pid, pane alive) · new `teamctl` sees lead running and the worker stopped with its worktree |
| git | git lists the worktree at its new path, nothing prunable · uncommitted work in it survived · the worker restarts in the moved worktree |
| edited files | `~/.zshrc`: one block, only its two marker lines changed · `settings.json`: tmux rules renamed, every other rule and key kept · Codex rules: new file in place, old one parked · Beads hooks point at the new location |
| round trip | `uninstall.sh` refuses while the pre-rename team is up · after destroy, uninstall leaves `~/.zshrc` byte-identical to the original and `settings.json` equal in content |

## Observed in the owner's real team (2026-09-20, after the migration)

| Observation | Meaning |
|-------------|---------|
| the lead (Fable, started under v1.1) kept its pid through the migration; `teamctl status` from 1.2.0 shows it running on socket `ai-team` | adoption of the old socket works on a real team |
| two seconds after the move the lead ran `teamctl restart research`; the GLM-5.3 worker came up in `~/.wolfmux/worktrees/…`, read its Beads inbox and answered | **first real Z.ai request: helper mode (`apiKeyHelper` + login guard) authenticates against the Coding Plan endpoint**; registry rewrite and `git worktree repair` hold under real use |
| the worker's first screen warns `Both CLAUDE_CODE_OAUTH_TOKEN and apiKeyHelper set` | expected: that variable is the inert login guard ([ADR-0007](adr/0007-zai-key-delivery-and-login-guard.md)); `apiKeyHelper` wins and the request succeeded |

## One real Codex turn (2026-09-20, ChatGPT login, `codex-astra exec`)

| Question | Observation |
|----------|-------------|
| does Codex find its command runner when started by `codex-astra`? | yes: no "Code Mode is unavailable" warning (it appeared on every turn while `~/bin/codex` was a symlink) |
| can it run a command? | `/bin/zsh -lc 'echo wolfmux-ok'` succeeded |
| does Codex's `notify` program reach `teamctl _notify --codex`? | yes: `ESC ] 9 ; 🐺 lead: wolfmux-ok BEL` was written to the test tty |

## Wolfmux.app on the owner's machine (2026-09-20)

| Step | Observation |
|------|-------------|
| `teamctl _notify` with no terminal attached | `pending` written, Wolfmux.app launched, message fetched within 3 s, application exited |
| Wolfmux.app started with nothing pending (what macOS does on a click) | `open-team.command` written for the project; a new iTerm2 shell appeared in the project directory once the "control iTerm" prompt was answered |
| not observable from a script | whether the banner was shown (it needs the one-time "allow notifications" answer) and the click itself; both are macOS behaviour, the second is the very behaviour that used to open Script Editor |

## Not verified

- `WOLFMUX_GLM_AUTH_MODE=env` against the real endpoint (helper mode worked, so the
  fallback was never needed).
- Model ids sent by background features of an *interactive* session (titles,
  suggestions). The `-p` runs showed only `glm-5.3`; the alias mapping covers the
  rest by configuration, not by observation.
- Behaviour with more than about eight concurrent agents.
