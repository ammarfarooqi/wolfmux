# Verification

No model call was made to test this system. Real CLIs were only started as far as
their first screen; everything else used stub agents or a localhost mock.

## Re-run it

```bash
tests/smoke.sh                 # 2 to 4 minutes, 181 checks, isolated from any running team
tests/disk.sh                  # ~1 minute, 82 checks, its own tmux server and state
tests/providers.sh             # the provider table, 116 checks
tests/docs.sh                  # ~2 seconds, 28 checks, starts nothing
tests/migration.sh             # ~30 seconds, 24 checks, in a throwaway HOME
tests/permissions.sh           # ~5 seconds, 13 checks, in a throwaway HOME
tests/credential-routing.sh    # manual; needs claude logged in; see the header for side effects
teamctl doctor
```

`smoke.sh` tests the checkout it lives in. It uses its own tmux server
(`wolfmux-test-<pid>`, `wolfmux-test-old-<pid>`), its own state directory, a throwaway repository whose path
contains a space, and `tests/stub-agent` in place of every CLI. It was run while a
real team was live on the same machine; the real team was unaffected.

## smoke.sh: 181 of 181 pass (v1.12.0)

| Area | Checks |
|------|--------|
| launchers | `codex-astra` starts Codex by its real path, never through a symlink · `claude-opus`, `-sonnet`, `-haiku` are the subscription launcher pinned to their model, each pin configurable · `claude-glm` declares a 200k context window · `1m` uses the suffix instead, a number is declared, nonsense falls back with a warning · a context value from outside is scrubbed, never inherited |
| start | session running and lead registered · repository left clean by the stealth Beads init (no commit, no tracked file) |
| spawn | two workers running · own branch each · worktrees outside the repository · `--base` recorded · `TEAM_ROLE` / `BEADS_ACTOR` / model set inside the pane · no provider or agent-session variable leaks into a pane · kickoff prompt present by default and absent with `--no-kickoff` · lead is pane 0 · pane titles are `<role> · <model>` |
| validation | duplicate role refused · `lead` and malformed roles refused · a capital letter is refused under `C`, `en_AU.UTF-8` and `en_US.UTF-8` alike · a role an older version let through can still be listed and stopped · a role name can never leave the registry directory · flag without a value reports usage with exit 64 |
| any model | a Codex teammate in a team led by another model · a Claude-subscription teammate (sonnet) beside GLM workers, with the guard · `claude:<id>` and `codex:<id>` reach the CLI · a Codex teammate gets the notify program · nonsense (`gpt`, `claude:`, `claude:bad;id`, `glm:glm-9`, `codex:a b`) is refused before anything is created |
| teams | asking for another lead model while a team runs never hijacks it and prints how to start a second · a named team gets its own tmux session and lead · with several teams a command must say which (exit 64, lists them) · the same role can exist in two teams; `--team` before or after the command; branches `ai/<team>/…`, the record agrees · status draws every team as a tree (TEAM, 🐺, 🐶) · `--json` lists the teams, with `--team` it keeps the single-team shape · `teamctl teams` · Beads names `<team>.<role>`, the first team keeps plain roles · an agent is told who its lead is in its own team's terms, the protocol's examples rewritten · a nudge finds the right team by name · a lead manages its own team only (exit 77) · notifications name the team and a click opens that team · bad team names refused · Beads messages reach the lead of the right team · destroy ends one team and leaves the other |
| deleting a team | a worker may not delete a team (exit 77) · work that exists nowhere else is listed and, without an answer, nothing at all is touched: the team keeps running · the report says how much space the team takes · `--purge --force`: session, worktrees, `ai/` branches, records and transcripts are gone · nothing else is touched: other teams, their branches, the checkout, other transcripts · with nothing at risk it still wants a yes when nobody can be asked · deleting the first team leaves the named teams' state alone · `teamctl teams` shows DISK |
| teams together | teams talk through Beads in both directions · every agent is told that other teams exist and how to reach them · a lead can found a fresh team and hand over (`--handover`), the founder is recorded, the new lead's first words name the bead · you are told when an agent founds a team · a lead cannot take over a team that has a lead, a worker cannot found one (exit 77) · `lead-teams off` keeps founding teams to you |
| teams, approvals | a permission request in a named team is filed with, and announced to, its own lead, never the first team's · another team's lead cannot decide it (exit 77), its own lead can, and the worker's CLI receives allow · the waiting time is also read from the config file, not only from the environment |
| lanes | words are not commands: prose in quotes and heredocs never triggers the guard, a quoted path still does · MCP tools are held to the same lanes · every worker has the guard, the lead does not · a worker may change files in its own worktree (absolute, relative, new) and in temporary directories · not the lead's checkout, a teammate's worktree, `~/.zshrc`, or anything reached with `..` · it may read the lead's checkout, never a teammate's worktree or teamctl's state · ordinary shell work passes (tests, commits, `git checkout -- file`, `git push -u origin HEAD`, copying `.env` from the lead's checkout, `teamctl`, `bd`, rebase) · reaching into another worktree or writing into the lead's checkout is refused, in either spelling of the path · switching, creating or deleting branches, `git worktree`, `tmux`, pushes to main are refused · the lead is not guarded and an agent the guard cannot place is allowed · `worker-isolation off` removes it at the next start |
| clearing up | a running agent is never removed · `destroy --worktrees` names what it kept and both ways out · without `--force` work is never discarded and the refusal lists the commit and the files · a worker cannot remove anyone (exit 77) · `--force` needs a yes when nobody can be asked · `remove --force --yes` takes worktree, branch and record, the main checkout is untouched · a damaged record can never delete a directory outside the worktrees or a branch that is not `ai/*` · all or nothing: one worker that holds work stops the whole command · an unknown role is an error |
| one manager | default policy is skip / skip / spawning off / isolation on · lead and workers start in their CLI's bypass mode · agent teams switched off inside workers, lead's settings left alone · a worker cannot spawn while the toggle is off (exit 77) · a worker cannot stop, restart, destroy, approve, deny or change policy · with the toggle on a worker can spawn, the record says who spawned whom, and the lead is told |
| approvals | lead mode starts a worker without bypass and with the hook · a request is filed and the lead is told · status shows it pending · a worker cannot approve its own request · approve → the CLI receives `allow` · deny → the CLI receives `deny` with the reason · no answer → no decision, so the normal prompt appears · ask mode has neither flag nor hook |
| notifications | fixed line typed into the pane · debounced inside the window · hostile bead id (`x;rm -rf ~`) dropped, never typed |
| Beads | a message to a role notifies its pane · body stored intact (`"quotes"`, `$HOME`, backticks) and never typed into the pane · a worker reads the shared database from its external worktree |
| git | `diff` commits / stat / patch · uncommitted leftovers visible · main checkout untouched by worker commits · `worktrees` lists everyone |
| the wolf | the session has the `client-attached` popup hook · the splash draws wolf, wordmark and team line · no colour codes outside a terminal · it works outside any project · only the manager pane has the mark and the amber border · the manager pane opens with the wolf · status line and tab title carry it · `WOLFMUX_SPLASH=off` removes the popup and the default restores it · a Claude lead is named `🐺 team/lead`, workers are not |
| arrangement | by default the lead is the large pane on the left and workers share one column on the right · `lead-top` puts the lead across the top · `tiled` is available, the choice is remembered, an unknown name is refused (exit 64) · the arrangement survives a spawn and a stop |
| closing and coming back | a lead that exited comes back in place and the worker keeps its pane · asking for the other lead model brings it back as that model · when every agent has exited, `start` opens a fresh session with one pane and marks workers stopped · `--continue` reaches the lead's CLI · a stopped worker returns with `restart` into the arrangement · with no tmux session left (a reboot), `restart lead [--continue]` starts the team again as the model that led it, in a named team too, and a worker's refusal names the exact two commands, with `--team` and `--continue` · **a pre-rename team whose agents have all exited is replaced by a fresh one on the new socket** |
| desktop notifications | every Claude agent gets the `Stop` hook, the plugin notifier is silenced and the user's own disabled hook is kept · OSC 9 to the attached terminal with the first line, markdown dropped · the lead is marked · **an OSC 52 and a clear-screen sequence inside a message never reach the terminal** (exactly two control bytes come out: ours) · long messages are cut · no terminal attached → `osascript` with the text as an argument, never a failure · nobody attached → the message is handed to Wolfmux.app, not to `osascript`, and the project is remembered · the app fetches its message exactly once, so its next start is a click · a message it never fetched is not posted late · a click opens a terminal on the team (script with the project and `teamctl attach`) · `WOLFMUX_NOTIFY=lead` keeps workers quiet |
| rename | an explicitly chosen socket is never redirected · teamctl follows a team on the old socket · new panes join it · destroy ends it · the next team starts on the new socket · a Beads hook written under the old name is replaced · a hook that is not ours is left alone |
| lifecycle | stop keeps the record · restart reuses worktree and branch · destroy refuses without confirmation when non-interactive · destroy `--yes` works · dirty worktree with an unmerged commit is **kept** · clean worktree removed and merged branch deleted · session gone |

## disk.sh: 82 of 82 pass (v1.12.0)

Its own tmux server (`wolfmux-disk-test-<pid>`), its own state directory, a throwaway
repository whose path contains a space, stub agents, and build trees of a few megabytes of
`/dev/urandom` instead of real installs (`/dev/zero` compresses to nothing on APFS and would
have made the freed-kilobyte checks meaningless). Half the checks ask `lib/disk.sh` its
questions directly, with teamctl's libraries loaded under `set -euo pipefail` — `bin/teamctl`'s
own line, so an arithmetic or `set -e` abort inside a library cannot pass unseen; the other
half go through the commands in a live throwaway team.

| Area | Checks |
|------|--------|
| the allowlist and the numbers | a dry run reports the **exact** kilobytes of the allowlisted directories (compared with `du -sk`) and deletes nothing · it names what it would take · `caches` leaves `node_modules` out of both the number and the deletion · `human_size` turns KB into MB and GB at the right places · applying `caches` deletes the caches and keeps `node_modules` · applying `all` takes both and leaves sources and git state untouched · nothing is left behind |
| what is never deleted | a `dist` that git tracks survives, and is not counted as freed, while `node_modules` still goes · a worktree with an uncommitted change to a tracked file is refused with the reason, and untouched · a worktree with an untracked file that is not build output is refused, the file is named, and it is untouched · a path outside this project's worktree directory is refused · your own checkout is refused · the worktree directory itself is refused · a worktree whose `.git` file is gone is refused (git has to be the one that answers) · `…/..`, `…/../..` and `/` are refused, because `pwd -P` resolves first · **a named team's lane is never confined for the first team**, nor is the `teams/` directory itself · a `node_modules` that is a symlink out: the link goes, never its target · the refusal names the team and never trails off when no worktree directory resolved |
| interruption | a leftover `.wolfmux-removing-*` is counted, named `cleanup-trash`, cleared by the next run, left alone by `--dry-run`, and never makes the lane permanently unclean |
| the remembered lane size | a fresh number is used · garbage, a one-field line, an empty file and negative values are not · a stale number is dropped · **a stamp in the future is dropped** (a clock that went back used to pin status for ever) · **a leading zero in either field is dropped silently, with nothing on stderr** (it used to reach the arithmetic and print `08: value too great for base`), while a plain `0` is kept · a command that freed something corrects the number instead of measuring again, and never below zero |
| what counts as a person's work | an untracked `dist`, `build` or `target` that git neither tracks nor ignores counts as work, and is listed · `node_modules`, the build caches and our own trash never do · a `node_modules` **symlink** does not either, which is the case a `node_modules/` ignore line misses · a changed tracked file always counts, and so does any other untracked file |
| a number that is not base ten | `policy disk-min-gb` refuses `08`, `010`, `09`, `twenty`, `-5`, `1e3` and `10001` with exit 64 · a leading zero in the environment falls back to the default · so does one already in `meta.json`, which `teamctl policy` would no longer accept, while a plain `8` there is used · and the one arithmetic site forces base ten anyway, so even `08` cannot abort a spawn |
| the commands | `stop` takes the build caches, keeps `node_modules` and says how much it freed · `stop` on a lane with unfinished work keeps its build output and says why · `prune --dry-run` prints a total, deletes nothing, leaves the trash alone, leaves a running lane out and says so, names the lane it skipped and why · **the printed sizes are checked as values, not as a shape**: the running and the skipped lane each show their real size, and the "still held" total is the swept lane's leftovers **plus the whole of both** (the first version of that line counted neither, and a shape assertion let it pass) · a worker may run `--dry-run` but gets exit 77 for the real thing · `--keep-node-modules` takes the caches only · `prune` takes `node_modules` from the parked lane, clears the trash, reports the total, never touches the running lane or the skipped one, and leaves the sources and git state intact · **`prune` refuses the whole sweep, dry run included, when a record says running and the session shows no pane for it, and touches nothing** · a hand-edited record pointing outside is skipped and that directory is untouched · `remove` sweeps the build output of a lane that is going (so cleanup trash never makes it ask for `--force`), takes the whole worktree and reports the sweep plus the lane's whole size as freed · **a `remove` that refuses changes nothing**: a lane holding one file a person wrote is refused with the linked `node_modules` and the caches still there, and the count and the listed lines agree · `remove` also asks about a lane holding an untracked `dist/deploy.sh`, and that file survives · `destroy --worktrees` takes each lane's build output first and still keeps the lane that holds real work |
| after a reboot | with the tmux server gone and every record still saying `running` — the state the machine was left in three times on 2026-10-09 — `prune` cleans the lane, does **not** read the stale records as a disagreement, and exits 0 |
| the guard | `status` shows free disk and what the guard is set to · `status` never measures and says so, `teams` measures, and `status` then shows the number · `status --json` carries `disk.free_kb` and the three new policy keys · under the threshold a spawn is refused with **exit 75**, names the number and `teamctl prune --dry-run`, and creates no branch and no record · `disk-guard warn` lets the same spawn through with a warning · `off` asks nothing at all · `disk-min-gb 0` switches the limit off without switching the guard off |
| shared `node_modules` | `--link-node-modules` links the lane to the project's copy and says that an install in any lane changes them all · without the flag and with the policy off there is no link · `policy link-node-modules on` does it for every spawn · the linked `node_modules` really is what git calls untracked under a `node_modules/` ignore line (the case below) · **`remove` takes such a lane off the books without `--force`** and never the project's copy · cleaning a linked lane removes the link and never the project's copy |

**Measured, not assumed.** One real lane `node_modules` on the owner's machine: 69,336
files, 802 MB, `du -sk` 0.62 s warm. All 36 lane worktrees on that machine: 12.4 s. That is
why `teamctl status` reads a cached number and `teamctl teams` is the command that measures.

**Also measured, by the reviewer, read-only on the same machine.** 38 lane worktrees holding
25 GB, of which about 4 GB sat in a directory on the allowlist. The other ~21 GB is files
git tracks: in one project `public/` alone is 530 MB and 3,097 tracked files, copied into
every lane, about 0.65 GB per lane before an agent installs anything. `prune` now prints
that floor. For the issue's 27-lane case, `prune` would have returned roughly 27 × 2.9 GB;
the ~18 GB of tracked files needs `teamctl remove`.

**What the review could not break.** Driven directly at the project root, `$WORKTREES_DIR/../..`,
`/`, an empty path, an emptied `WORKTREES_DIR`, a worktree with its `.git` file deleted, a
`GIT_DIR` exported to point at another repository, a `node_modules` symlinked to the project
root, a symlink inside `node_modules` pointing out, two `teamctl prune` runs at once, and
`remove --force` / `destroy --worktrees` on a linked lane: every confinement attempt was
refused, the root's `node_modules` survived every one, and the concurrent runs serialised on
the project lock. Rule 4 refused even the one case (`GIT_DIR`) where rules 2 and 3 could be
made to answer about the wrong repository.

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

## permissions.sh — 13 of 13 pass (2026-09-20)

`install.sh` and `uninstall.sh` against `~/.claude/settings.json` in a throwaway `HOME`
(no team, no CLI, nothing of yours read). Written first: 4 of the 9 failed before the change.

| Area | Checks |
|------|--------|
| a fresh install | `teamctl` and `bd` allowed, `teamctl destroy` asks · no rule that can write a file or run a command through its arguments · `claude/permissions.json` names what it retired and adds none of it |
| over a settings file an earlier version wrote | the five retired rules are taken out · the installer names each one and the backup still holds them · your own rules, `deny` and every other key untouched · a second run changes nothing |
| uninstall | an option it does not know is refused (exit 64) before anything is touched · current and retired rules both removed · your own rules stay |
| uninstall `--purge` | a worktree of a named team keeps `~/.wolfmux`, and says so · the empty `teams/` folder a named team leaves behind is not a worktree (it used to keep `~/.wolfmux` for ever) · with no `worktrees/` folder at all it still finishes and removes `~/.wolfmux` |

Not covered: a rule of yours that is spelled exactly like a retired one cannot be told apart
from ours and is taken out as well; the installer names it and the backup holds it.

## migration.sh: 24 of 24 pass (v1.10)

A throwaway `HOME` gets v1.1 installed from git history, a team started with it (lead +
one worker, stub agents, its own tmux sockets), then `migrate-from-ai-team.sh`.

| Area | Checks |
|------|--------|
| refusals | new `install.sh` will not install next to v1.1 · migration refuses while a worker runs inside `~/.ai-team` and changes nothing · `--dry-run` changes nothing |
| state | old directories gone, old config parked in backups · a user setting arrives under its new key · program files are the new version · no stored record points into `~/.ai-team` · a second run finds nothing to do |
| the live team | **the running lead is not restarted** (same pid, pane alive) · new `teamctl` sees lead running and the worker stopped with its worktree |
| git | git lists the worktree at its new path, nothing prunable · uncommitted work in it survived · the worker restarts in the moved worktree |
| edited files | `~/.zshrc`: one block, only its two marker lines changed · `settings.json`: no rule under the old name, the five retired rules gone, your own rule and every other key kept · Codex rules: new file in place, old one parked · Beads hooks point at the new location |
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

## docs.sh: 28 of 28 pass (v1.12.0)

`tests/docs.sh` reads the code for what exists and the documents for whether it is named.
Nothing is started; it takes about two seconds.

| Area | What is checked |
|------|-----------------|
| commands | every public command `bin/teamctl` dispatches (not the internal `_…` ones, the pointers to Beads, `version`, `help`), and every alias, is in `teamctl help`, README.md and docs/USAGE.md; every command is in the user manual |
| options | every option a command's argument loop accepts stands next to that command in `teamctl help`, README.md and docs/USAGE.md (spellings on one `case` label count as one) |
| policy keys, models | every key of `POLICY_KEYS` and of `model_info` is in all four, as a word of its own |
| settings | every key of `WOLFMUX_CONFIG_KEYS` is in the config template, and explained in the user manual or under `docs/` |
| launchers, installer | every launcher in `bin/` or linked by `install.sh` is in README.md, the user manual and docs/SETUP.md; every option of every top-level script (`install.sh`, `uninstall.sh`, `migrate-from-ai-team.sh`) is in docs/SETUP.md |
| indexes, links | README.md links every `docs/*.md`; the ADR index lists every record; the diagrams page shows every SVG; every relative link leads to a file, and its `#anchor` to a heading that exists |

A file that git ignores (`.gitignore`, `.git/info/exclude`) is not part of the
documentation and is left alone: the check's first run in the owner's checkout failed on
a private audit note that lives there unversioned, which the worktree it was written in
did not have.

Its first run on the tree before it (2026-09-20) failed 13 of 28: README.md named 5 of 22
commands, neither alias and no options; `teamctl help` lacked `lead-teams`,
`--keep-transcripts`, `--quiet` and `--lines`; the user manual lacked two policy keys and
ten settings; docs/SETUP.md still described two symlinks and knew nothing of `Wolfmux.app`,
the `codex` wrapper or `--no-notifier-app`.

Does it notice drift? Thirteen mutations, each on a copy of the repository, each caught: a
command dropped from the README · a new command nobody documented · a new option · an
option renamed in the README only · a new policy key · a new setting · a link to a heading
that does not exist · a linked document deleted · a new document the README does not link ·
a policy key that survives only inside the flag `--worker-spawn` · a model key that
survives only inside `codex-astra` · the one option of `uninstall.sh` dropped from SETUP.md
· a link to a `# comment` inside a code block. The last four came out of the review of the
check itself: its first version matched substrings, never saw `uninstall.sh --purge`
(that script did not parse its option as a `case` label; it does now, and refuses an option
it does not know with exit 64 instead of ignoring it), and took comments in fenced
examples for headings.

## Not verified

- `WOLFMUX_GLM_AUTH_MODE=env` against the real endpoint (helper mode worked, so the
  fallback was never needed).
- Model ids sent by background features of an *interactive* session (titles,
  suggestions). The `-p` runs showed only `glm-5.3`; the alias mapping covers the
  rest by configuration, not by observation.
- Behaviour with more than about eight concurrent agents.
