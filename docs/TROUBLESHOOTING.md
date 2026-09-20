# Troubleshooting

Start with `teamctl doctor`, then `teamctl status`, then `teamctl capture <role>`.

| Symptom | Cause | Fix |
|---------|-------|-----|
| teammates appear in extra terminal panes and ask a *worker* for approval ("Waiting for team lead approval") | the worker used Claude Code's own agent-teams feature (your settings enable it), which makes the spawning session a team lead | fixed since 1.1: teamctl switches that feature off inside workers. Restart workers started with an older version: `teamctl restart <role>` |
| a worker's banner says `API Usage Billing` | Claude Code's label for any key-based login | expected for GLM workers: the key is the Z.ai Coding Plan key, the endpoint is Z.ai's. Check `/status` in the pane |
| a worker stalls on a permission prompt | it runs in `ask` mode, or a lead-mode request timed out | `teamctl status` shows its PERM column. `teamctl policy worker-permissions skip` (or `lead`), then `teamctl restart <role> --continue` |
| `'teamctl …' is reserved for the lead` (exit 77) | a worker tried a manager command, or tried to spawn while `worker-spawn` is off | intended. The worker should message the lead; you can allow spawning with `teamctl policy worker-spawn on` |
| `teamctl: command not found` | the `~/bin` PATH block is not loaded yet | open a new terminal; check for the `>>> ai-team >>>` block in `~/.zshrc` |
| worker pane says `no Keychain item for service 'zai-coding-plan'`, state `exited(78)` | the Z.ai key was never stored | run the `security add-generic-password …` command the pane shows, then `teamctl restart <role>` |
| GLM worker answers with 401 / authentication errors | the endpoint rejected helper-mode headers, or the key is wrong | set `AI_TEAM_GLM_AUTH_MODE=env` in `~/.config/ai-team/config`, `teamctl restart <role>`; if it persists, re-store the key (the same command, `-U` overwrites) |
| GLM worker reports `1113 Insufficient Balance` | the call fell outside the Coding Plan (wrong endpoint or a non-plan model id) | `AI_TEAM_DRY_RUN=1 claude-glm` must show `https://api.z.ai/api/anthropic` and a `glm-5.3*` model; check the plan is active on the account that issued the key |
| a new worker sits on "Do you trust this folder?" | first time this repository is opened with that CLI | answer it once in the lead pane; Claude Code keys trust on the main checkout, so worker worktrees inherit it |
| a worker never reacts to a message | its CLI was showing a dialog, or the hook is missing | `teamctl nudge <role>`; `teamctl doctor` must say the pane-notification hooks are installed (`teamctl start` reinstalls them) |
| inbox looks empty although a message was sent | message beads are hidden by default | add `--include-infra`: `bd list --assignee <role> --status open --include-infra` |
| `could not create a tmux pane … window too small` | the terminal cannot be split further | enlarge the terminal (or `teamctl attach` first), retry; `Ctrl-b T` re-tiles |
| `another teamctl operation holds the project lock` | a `teamctl` command was killed mid-operation | wait 30 s (dead holders are reclaimed automatically) or `rmdir ~/.ai-team/state/<project>/.lock` |
| `teamctl attach` says you are inside another tmux server | nesting tmux servers is blocked on purpose | open a new terminal tab and run `teamctl attach` there |
| `role 'x' already exists (stopped)` | the role has a record and a worktree from earlier | `teamctl restart x`, or choose another role name |
| `bd: database is locked` for a long time | many agents writing at once in embedded mode | they queue and normally finish within seconds; for heavy swarms move the project to Beads server mode (`bd init --server`, needs the `dolt` CLI) |
| `bd init` rejects the project name | Beads wants a prefix of letters, digits, hyphens | let `teamctl start` do the init (it derives a valid prefix), or pass `--prefix` yourself |
| `teamctl doctor` warns about `CLAUDE_CONFIG_DIR` / `CODEX_HOME` | the CLI reads settings and login from a relocated directory | unset the variable, or confirm that relocated directory is the one you mean |
| `teamctl doctor` warns about `env` or `apiKeyHelper` in a settings file | that file would redirect **every** Claude session, including the Fable lead | remove the entry; provider configuration belongs only inside the launchers |
| Codex asks for approval on every `teamctl` / `bd` command | the rule file is missing | `./install.sh` (or copy `codex/ai-team.rules.template` to `~/.codex/rules/ai-team.rules` with `__HOME__` replaced), restart Codex |
| `uninstall.sh` refuses to run | a team is still up | `teamctl destroy` in that project first |
| stale `ai-team-test-*` sockets in `/tmp/tmux-<uid>/` | tmux leaves socket files behind | harmless; `smoke.sh` removes its own |

## Useful one-liners

```bash
tmux -L ai-team ls                                   # every team session on this machine
tmux -L ai-team kill-server                          # stop all teams at once
tail -20 ~/.ai-team/state/*/events.jsonl | jq -c .   # lifecycle log: start, spawn, stop, restart, nudge, destroy
jq . ~/.ai-team/state/<project>/agents/<role>.json   # what teamctl knows about one agent
git worktree list && git branch --list 'ai/*'        # what git knows
bd list --status in_progress,blocked                 # what Beads knows
```
