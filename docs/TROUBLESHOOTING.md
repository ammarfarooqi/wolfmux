# Troubleshooting

Start with `teamctl doctor`, then `teamctl status`, then `teamctl capture <role>`.

| Symptom | Cause | Fix |
|---------|-------|-----|
| teammates appear in extra terminal panes and ask a *worker* for approval ("Waiting for team lead approval") | the worker used Claude Code's own agent-teams feature (your settings enable it), which makes the spawning session a team lead | fixed since 1.1: teamctl switches that feature off inside workers. Restart workers started with an older version: `teamctl restart <role>` |
| a GLM worker starts with `Both CLAUDE_CODE_OAUTH_TOKEN and apiKeyHelper set · auth may not work as expected` | that variable is the login guard: an inert value that keeps a GLM worker (and anything it starts) from ever falling back to your claude.ai login | expected and harmless: `apiKeyHelper` takes precedence, so the Z.ai key is what gets sent. Do not unset either ([why](SECURITY.md)) |
| clicking a "task complete" notification opens **Script Editor** | the notification was sent with `osascript` — by an agent started before 1.3, or because no terminal was attached to the team | `teamctl restart <role> --continue` gives the agent Wolfmux's notifier, which goes through iTerm2 so a click opens the team's tab. With the team detached there is no tab to open: `teamctl attach` |
| no notification at all when an agent finishes | `WOLFMUX_NOTIFY` is `off` or `lead`; or iTerm2 is not allowed to notify; or that tab is the one in front (iTerm2 stays quiet then) | check `~/.config/wolfmux/config`; macOS Settings → Notifications → iTerm2; iTerm2 → Settings → Profiles → Terminal → "Notification Center Alerts" |
| `teamctl start` showed a window full of `Pane is dead` | before 1.4: every agent had been quit, tmux kept the finished panes, and `start` attached to them | fixed in 1.4: `start` clears a session in which every agent has exited and opens a new one; a lead that exited alone is brought back in place. Older install: `teamctl destroy`, then `teamctl start` |
| the panes are arranged badly for your screen | default is the lead on the left at 55 % | `teamctl layout lead-top` or `teamctl layout tiled`; `Ctrl-b Space` cycles; drag a border with the mouse; `Ctrl-b z` zooms one pane |
| the wolf popup is in the way | it shows on every attach | any key closes it; `WOLFMUX_SPLASH=off` in `~/.config/wolfmux/config` removes it from the next attach on |
| 🐺 shows as a box or misaligns a border | the terminal font has no emoji fallback, or counts its width differently | use a terminal with emoji support (iTerm2, Terminal.app, kitty, Ghostty, WezTerm all do) |
| a worker shows a long yellow `"glm-5.3" isn't described by this version's model catalog …` | Claude Code does not know GLM's model ids and announces the 200k window it assumes | fixed in 1.4: `claude-glm` declares that window (`CLAUDE_CODE_MAX_CONTEXT_TOKENS=200000`), which removes the notice and changes nothing else. Restart the worker: `teamctl restart <role> --continue`. Another window: `WOLFMUX_GLM_CONTEXT=<tokens>` or `1m` |
| a worker's banner says `API Usage Billing` | Claude Code's label for any key-based login | expected for GLM workers: the key is the Z.ai Coding Plan key, the endpoint is Z.ai's. Check `/status` in the pane |
| a worker stalls on a permission prompt | it runs in `ask` mode, or a lead-mode request timed out | `teamctl status` shows its PERM column. `teamctl policy worker-permissions skip` (or `lead`), then `teamctl restart <role> --continue` |
| `'teamctl …' is reserved for the lead` (exit 77) | a worker tried a manager command, or tried to spawn while `worker-spawn` is off | intended. The worker should message the lead; you can allow spawning with `teamctl policy worker-spawn on` |
| `teamctl: command not found` | the `~/bin` PATH block is not loaded yet | open a new terminal; check for the `>>> wolfmux >>>` block in `~/.zshrc` |
| worker pane says `no Keychain item for service 'zai-coding-plan'`, state `exited(78)` | the Z.ai key was never stored | run the `security add-generic-password …` command the pane shows, then `teamctl restart <role>` |
| GLM worker answers with 401 / authentication errors | the endpoint rejected helper-mode headers, or the key is wrong | set `WOLFMUX_GLM_AUTH_MODE=env` in `~/.config/wolfmux/config`, `teamctl restart <role>`; if it persists, re-store the key (the same command, `-U` overwrites) |
| GLM worker reports `1113 Insufficient Balance` | the call fell outside the Coding Plan (wrong endpoint or a non-plan model id) | `WOLFMUX_DRY_RUN=1 claude-glm` must show `https://api.z.ai/api/anthropic` and a `glm-5.3*` model; check the plan is active on the account that issued the key |
| a new worker sits on "Do you trust this folder?" | first time this repository is opened with that CLI | answer it once in the lead pane; Claude Code keys trust on the main checkout, so worker worktrees inherit it |
| a worker never reacts to a message | its CLI was showing a dialog, or the hook is missing | `teamctl nudge <role>`; `teamctl doctor` must say the pane-notification hooks are installed (`teamctl start` reinstalls them) |
| inbox looks empty although a message was sent | message beads are hidden by default | add `--include-infra`: `bd list --assignee <role> --status open --include-infra` |
| `could not create a tmux pane … window too small` | the terminal cannot be split further | enlarge the terminal (or `teamctl attach` first), retry; `Ctrl-b T` re-tiles |
| `another teamctl operation holds the project lock` | a `teamctl` command was killed mid-operation | wait 30 s (dead holders are reclaimed automatically) or `rmdir ~/.wolfmux/state/<project>/.lock` |
| `teamctl attach` says you are inside another tmux server | nesting tmux servers is blocked on purpose | open a new terminal tab and run `teamctl attach` there |
| `role 'x' already exists (stopped)` | the role has a record and a worktree from earlier | `teamctl restart x`, or choose another role name |
| `bd: database is locked` for a long time | many agents writing at once in embedded mode | they queue and normally finish within seconds; for heavy swarms move the project to Beads server mode (`bd init --server`, needs the `dolt` CLI) |
| `bd init` rejects the project name | Beads wants a prefix of letters, digits, hyphens | let `teamctl start` do the init (it derives a valid prefix), or pass `--prefix` yourself |
| `teamctl doctor` warns about `CLAUDE_CONFIG_DIR` / `CODEX_HOME` | the CLI reads settings and login from a relocated directory | unset the variable, or confirm that relocated directory is the one you mean |
| `teamctl doctor` warns about `env` or `apiKeyHelper` in a settings file | that file would redirect **every** Claude session, including the Fable lead | remove the entry; provider configuration belongs only inside the launchers |
| Codex asks for approval on every `teamctl` / `bd` command | the rule file is missing | `./install.sh` (or copy `codex/wolfmux.rules.template` to `~/.codex/rules/wolfmux.rules` with `__HOME__` replaced), restart Codex |
| `uninstall.sh` refuses to run | a team is still up | `teamctl destroy` in that project first |
| `install.sh` says an installation under the old name is present | v1.1 or earlier ("ai-team") is installed | `./migrate-from-ai-team.sh` — it moves state and worktrees, then installs ([details](SETUP.md#coming-from-ai-team-v11-and-earlier)) |
| `teamctl doctor` shows `socket: ai-team` | a team started before the rename is still running | nothing to do: teamctl follows it; the next team after it ends uses `wolfmux` |
| stale `wolfmux-test-*` sockets in `/tmp/tmux-<uid>/` | tmux leaves socket files behind | harmless; `smoke.sh` removes its own |

## Useful one-liners

```bash
tmux -L wolfmux ls                                   # every team session on this machine
tmux -L wolfmux kill-server                          # stop all teams at once
tail -20 ~/.wolfmux/state/*/events.jsonl | jq -c .   # lifecycle log: start, spawn, stop, restart, nudge, destroy
jq . ~/.wolfmux/state/<project>/agents/<role>.json   # what teamctl knows about one agent
git worktree list && git branch --list 'ai/*'        # what git knows
bd list --status in_progress,blocked                 # what Beads knows
```
