# Wolfmux — a local multi-model AI development team in tmux

One lead plus any number of teammates, every agent visible in its own tmux pane. The
default seats run on the three subscriptions (Claude, ChatGPT/Codex, Z.ai), with no API
keys anywhere. Other Anthropic-compatible providers (Kimi, MiniMax, Qwen, and the metered
Moonshot platform and DeepSeek) are one Keychain key each away and stay off until you add
it. The usual cast is below (Fable
**or** Astra leads, GLM workers implement), but any model key can sit in either seat, and a
project can have several teams.

```
                     LEAD  (pick one)
          claude-fable            codex-astra
          Claude Code             Codex CLI
          Fable 5.1               GPT-6 Astra
          Claude subscription     ChatGPT/Codex subscription
                 └──────────┬──────────┘
        teamctl  = tmux panes · models · worktrees · lifecycle
        bd       = tasks · dependencies · messages   (Beads)
                            │
      ┌─────────────────────┼─────────────────────┐
  claude-glm           claude-glm           claude-glm-flash
  backend · GLM-5.3    frontend · GLM-5.3   qa · GLM-5.3 Flash
      └──────────── Z.ai GLM Coding Plan ─────────┘
```

`teamctl` never stores a task or a message, and Beads never touches tmux. The only
glue is a three-line Beads hook that calls `teamctl nudge <role>` when a bead needs
someone, which types one fixed line into that agent's pane. Bodies stay in Beads.

## One-time setup

```bash
# Z.ai Coding Plan key -> macOS Keychain (you are prompted; nothing is echoed or logged)
security add-generic-password -U -s zai-coding-plan -a "$USER" -l "Z.ai Coding Plan API key" -w

# optional, one per provider you actually want:
security add-generic-password -U -s wolfmux-kimi     -a "$USER" -l "Kimi for Coding API key"      -w
security add-generic-password -U -s wolfmux-moonshot -a "$USER" -l "Moonshot platform API key"    -w
security add-generic-password -U -s wolfmux-deepseek -a "$USER" -l "DeepSeek API key"             -w
security add-generic-password -U -s wolfmux-minimax  -a "$USER" -l "MiniMax Coding Plan API key"  -w
security add-generic-password -U -s wolfmux-qwen     -a "$USER" -l "Alibaba Model Studio API key" -w

teamctl doctor        # must show no "!! WARNING !!" lines; says which providers are set up
teamctl doctor --probe   # optional: asks each endpoint whether it accepts the key you stored (nothing is billed)
```

## Starting with Fable

```bash
cd ~/code/your-project
teamctl start fable
```

## Starting with Astra

```bash
teamctl start astra
```

Same session, same workers, same commands; only the lead's launcher differs.
The first start in a repository offers to initialize Beads in stealth mode
(`bd init --stealth --skip-hooks --skip-agents`): no commit, no tracked files, no
git hooks, no AGENTS.md/CLAUDE.md changes. Use `--init-beads` to skip the question,
or run your own `bd init` flavour first.

`Ctrl-b d` detaches; the team keeps running. `teamctl attach` comes back.

## Spawning workers

```bash
teamctl spawn backend glm53      # GLM-5.3: substantial implementation
teamctl spawn frontend glm53
teamctl spawn qa flash           # GLM-5.3 Flash: simple / repetitive / QA
teamctl spawn fe-review astra    # any model can join any team: fable · opus · sonnet · haiku · astra
teamctl spawn docs2 kimi         # another provider's plan, same isolation (key in the Keychain first)
teamctl spawn x claude:<model-id>   # …or codex:<model-id>, for a model that has no key
```

Each worker gets its own branch `ai/<role>-<timestamp>`, its own worktree under
`~/.wolfmux/worktrees/<project>/`, its own pane titled `🐶 <role> · <model>`, and
`TEAM_ROLE` / `BEADS_ACTOR` set to its role (in a named team: branch
`ai/<team>/<role>-<timestamp>`, Beads name `<team>.<role>`). The lead stays the large pane
on the left; teammates stack on the right. A worker reads its Beads inbox as soon as it
boots, so assign work first, then spawn. Options: `--base <ref>`, `--branch <name>`,
`--ticket <KEY>`, `--repo <path>`, `--no-kickoff`, and
`--from-worktree <role>`: a fresh conversation in a stopped worker's built worktree, on a
new branch (its branch and commits stay; node_modules and build output survive). The lead
reads each agent's CONTEXT in `teamctl status` (tokens, and the share of a known
window — Fable 5.1, Opus 5 and Sonnet 5 are 1,000,000 tokens, Haiku 4.5 is 200,000;
anything else shows tokens alone) to choose
between `restart` (keep the conversation) and a fresh worker.

**Branch names.** That shape is a template, and a team can set its own when the repository
enforces one (a ticket key, a prefix), so no teammate ever has to commit past a hook:

```bash
teamctl policy branch-template 'feature-{ticket}-{role}-{ts}'   # this team, from now on
teamctl start fable --ticket AFD-1844            # the team's default ticket key
teamctl spawn sam glm53 --ticket AFD-1844        # feature-AFD-1844-sam-20260923-112233
teamctl spawn sam glm53 --branch my-exact-name   # or name the branch yourself
teamctl policy branch-template default           # back to the built-in shape
```

Placeholders: `{team}` `{role}` `{ts}` `{ticket}`. `{ts}` is required — it is what keeps two
teammates of one role on two branches — so a template without it is refused, and so is a
template with `{ticket}` when the spawn has no ticket key. teamctl deletes a teammate's
branch only when teamctl created it, whatever it is called.

**Another repository.** `teamctl spawn srv glm53 --repo ../other-repo` creates the worktree
and the branch **there** (base: that repository's `HEAD`, or the `--base` you name, resolved
there), under `~/.wolfmux/worktrees/<that repo>/teams/<team>/`. Isolation stays on: the
teammate may change only its own worktree, and both your project's checkout and that
repository's own checkout are read-only for it. `teamctl status` grows a `REPO` column while
some teammate has one, and `diff`, `worktrees`, `remove` and `destroy` run git where that
teammate's work actually is. It stays an ordinary member of this team, with this project's
Beads inbox.

A provider worker needs that provider's key in the Keychain first (one-time setup above);
`teamctl doctor` says which are set up. `spawn` and `start` refuse a metered key until
`WOLFMUX_METERED=on` (exit 77), and `teamctl status` marks a running metered agent with
`$` after its label.

| Model key | Runs | Pays with |
|-----------|------|-----------|
| `glm53` · `flash` | Claude Code + GLM-5.3 / GLM-5.3 Flash | Z.ai GLM Coding Plan |
| `kimi` | Claude Code + Kimi for Coding | Kimi for Coding subscription; the key is a Kimi Code membership key (starts `sk-kim`), not one from platform.kimi.ai |
| `minimax` | Claude Code + MiniMax M3 | MiniMax Coding Plan |
| `qwen` | Claude Code + Qwen 3.7 Plus | Alibaba Model Studio coding plan; the key starts `sk-sp-` |
| `moonshot` | Claude Code + Kimi K3 API | Moonshot platform API, metered: refused until `WOLFMUX_METERED=on`; the key comes from platform.kimi.ai, not from the Kimi Code console |
| `deepseek` | Claude Code + DeepSeek V4 | DeepSeek API, metered: refused until `WOLFMUX_METERED=on` |
| `fable` · `opus` · `sonnet` · `haiku` | Claude Code + that Claude model | Claude subscription |
| `astra` | Codex CLI + GPT-6 Astra | ChatGPT subscription |
| `claude:<model-id>` · `codex:<model-id>` | any other model of those two subscriptions | the same subscription |
| `kimi:<id>` · `moonshot:<id>` · `deepseek:<id>` · `minimax:<id>` · `qwen:<id>` | any other model id of that provider (GLM is not pinnable) | the same plan, or the same metered account |

The same keys work for `teamctl start <model>`: any of them can lead.

## One manager, permissions, spawning

The lead is the only manager of its team. `start`, `stop`, `restart`, `remove`, `destroy`,
`approve`, `deny` and changing the `policy` work for the lead and for you at your own
terminal; a worker that tries them is refused (exit 77). Everybody may look: `teamctl policy`
without arguments, `status`, `approvals`.

```bash
teamctl policy                                  # show this project's policy
teamctl policy worker-spawn on|off              # may workers run `teamctl spawn`?  default off
teamctl policy worker-permissions skip|lead|ask # default skip
teamctl policy lead-permissions skip|ask        # default skip
teamctl policy worker-isolation on|off          # the worktree guard (below)         default on
teamctl policy lead-teams on|off                # may the lead found further teams?  default on
teamctl policy branch-template '<template>'     # how this team names workers' branches (above)
teamctl policy branch-template default          # …back to ai/{role}-{ts} · ai/{team}/{role}-{ts}
teamctl policy disk-guard refuse|warn|off       # what a spawn does on a full disk    default refuse
teamctl policy disk-min-gb 20                   # free space a spawn asks for (1 GB = 1024 MB)  default 20
teamctl policy link-node-modules on|off         # share the repository's node_modules default off
teamctl start fable --worker-permissions lead --worker-spawn on    # or set them at start
```

| Permission mode | Meaning |
|-----------------|---------|
| `skip` | the CLI's bypass mode (`--dangerously-skip-permissions`, Codex: `--dangerously-bypass-approvals-and-sandbox`). Nothing is asked. Deny rules and explicit ask rules (`teamctl destroy`) still apply. |
| `lead` | workers only. Every request a worker would have shown is sent to the lead: `teamctl approvals`, then `teamctl approve A7` or `teamctl deny A7 "reason"`. No answer in 10 minutes → the prompt appears in the worker's pane. |
| `ask` | the normal prompt in that agent's own pane. |

Permission changes apply when an agent is started or restarted
(`teamctl restart <role> --continue` keeps its conversation). `worker-spawn` applies at
once. Defaults for new projects live in `~/.config/wolfmux/config`.

When worker spawning is on and a worker spawns someone, the new agent is a normal team
member (own pane, branch, worktree), reports to the lead, shows up in `teamctl status`
under SPAWNED BY, and the lead's pane gets `[wolfmux] Team change: …`.

**Staying in lane** (`worker-isolation`). Every teammate works in its own worktree on its
own branch, and a guard refuses the tool calls that reach outside: changing your checkout,
reading another teammate's worktree or teamctl's state, switching or deleting branches,
pushing to main, driving tmux. The refusal tells the worker to ask its lead. Reading your
checkout stays allowed. It is a guard against mistakes, not a sandbox, and it exists for
Claude Code teammates only: Codex has no such hook.

Inside workers, Claude Code's own agent-teams feature is switched off. With it on, any
subagent a worker names becomes a teammate that treats the *worker* as its team lead and
asks *it* for permission — a second manager outside the team's view. Your own sessions
and the lead keep the feature exactly as you configured it.

## Messaging (Beads)

```bash
bd create "Subject" -t message -a backend -d "body"            # send; recipient's pane is notified
bd create "Subject" -t message -a backend --body-file msg.md   # long / code-heavy body
bd list --assignee $BEADS_ACTOR --status open,in_progress,blocked --include-infra   # inbox: your tasks (new, claimed, blocked) + unread messages; $BEADS_ACTOR is your role, or <team>.<role> in a named team
bd show <id>                    # read            bd close <id> -r read       # mark read
bd create "Re: ..." -t message -a frontend -d "..." --deps replies-to:<id>    # reply
bd show <id> --thread           # conversation    bd list --type message --all    # history
```

Broadcast = one message per role. Lead and workers use exactly the same commands,
and workers message each other directly.

## Tasks (Beads)

```bash
bd create "Title" -t task -p 1 -a backend -d "what + acceptance criteria"
bd dep add <task> <blocker>        bd ready        bd list --status in_progress,blocked
bd update <id> --claim             bd update <id> --status blocked
bd close <id> -r "commit <sha>; tests pass"
```

Status map: pending = open/unassigned · assigned = open+assignee · in_progress ·
blocked · completed = closed · failed = closed + label `failed`.

## Monitoring

```bash
teamctl status [--json]     # policy, pending approvals; per role: model, state, pane, permission mode, spawned by, branch, commits ahead, dirty
teamctl panes               # what tmux reports: command, pid, cwd
teamctl capture backend     # last 80 lines of a pane   (-n 200 | --all;  teamctl log backend)
teamctl focus backend       # jump to a pane            teamctl nudge backend   # re-notify
```

Process state comes from tmux, work state from Beads; terminal text is never parsed.

## Several teams in one project

```bash
teamctl start fable --team review    # a second team, named by you; its own session, lead and workers
teamctl status                       # all teams: TEAM, 🐺 lead, 🐶 teammates
teamctl attach --team review         # add --team <name> to any command once there are several
```

With one team you never type `--team`. `teamctl start <model>` while the first team runs
under another model does not open that team; it shows you both commands. All teams share
the project's Beads; agents of a named team are `<team>.<role>` there, so teams can message
each other (`-a review.lead`; a plain `-a lead` is the first team's).

A lead can found a fresh team and hand work over, without you relaying anything:

```bash
bd create "Handover: payments" -t message -a next.lead --body-file handover.md    # → its id
teamctl start fable --team next --no-attach --handover <that-id>
```

The new lead starts by reading that bead and you get a notification. While that lead runs
the founder does not manage the new team; it can never take over a team that already has a
lead, and a worker can never found one. `teamctl policy lead-teams off` keeps founding teams
to yourself, for that team (`WOLFMUX_LEAD_TEAMS=off` for every team). Like all of the policy
it is cooperative: a lead can change its own team's policy.

When the lead of a founded team is not running (a session restart, a reboot, a lead that is
finished), `teamctl teams` marks the team `orphaned` and says who may act on it: you, and its
founder. The founder may then bring it back or clean it up without you:
`teamctl restart lead --team <name> --continue`, `teamctl stop`, `teamctl remove` and
`teamctl destroy --team <name> --purge`, or `teamctl start <model> --team <name> --continue`.
You are told each time, and the event log records it with the founder's Beads name. It never
includes `policy`, `approve` or `deny`, and it ends the moment that team's lead runs again.

## Deleting a team

```bash
teamctl teams                              # DISK shows what each team takes
teamctl destroy --team review --purge      # shows what would be lost, asks, then deletes the whole team
teamctl destroy --team review --purge --force    # …even with uncommitted or unmerged work
```

A worker costs a checkout of your tracked files plus whatever it installs or builds; the
lead costs nothing. Purge removes the session, every worktree, the branches teamctl created,
records and its teammates' Claude Code transcripts; never your checkout, other branches,
Beads, other teams, or the lead's own conversations (they live in your checkout's folder).

## The wolf, and notifications

- Arrangement: the lead is the large pane on the left, teammates are stacked on the right,
  and the lead stays put when workers come and go. `teamctl layout lead-top|tiled|lead-left`
  changes it for the project; `Ctrl-b Space` cycles, `Ctrl-b T` puts it back.
- Quit every agent and run `teamctl start` again: you get a new session, not the finished
  panes. Quit only the lead: `teamctl start` brings it back, workers keep running.
  Add `--continue` to resume the lead's own conversation, or `--resume <session-id>` to name one.
- Opening a team (`teamctl start`, `teamctl attach`) shows the wolf in a popup. Any key
  closes it, or 3 seconds. `WOLFMUX_SPLASH=off` in `~/.config/wolfmux/config` removes it.
- The manager is the wolf: `🐺 lead · <model>` in its pane border, an amber border
  whether focused or not, `🐺 team/lead` inside Claude Code. Every teammate is a dog of
  the pack: `🐶 backend · <model>`, `🐶 team/backend`, grey border.
  The status line starts with `🐺 WOLFMUX`; the terminal tab is titled `🐺 <session>`.
- When an agent finishes a turn you get a desktop notification (`🐺 lead: …`,
  `🐶 backend: …`). Click it and you are at the team: if it is open in a tab, that tab
  comes forward (the notification went through that terminal); if it is on no screen,
  a new window opens attached to it (the notification then comes from Wolfmux.app, the
  small application `install.sh` builds; allow its two macOS prompts once).
  `WOLFMUX_NOTIFY=all` (default) · `lead` · `off`.
- Both reach an agent when it starts: after an update run `teamctl restart <role> --continue`.

## Git

```bash
teamctl worktrees
teamctl diff backend --stat        # then: teamctl diff backend | --commits | --names | --working
git cherry-pick <sha>              # the lead integrates, in the project root
```

Completion flow: worker tests → commits → sends a `Done:` message (summary, test
status, commit hash, risks) → closes its task → lead reviews the diff → requests
changes, cherry-picks, rejects, or asks another worker to review. The lead owns
integration. Full rules: `TEAM_PROTOCOL.md` (injected into every agent at launch).

## Tab completion

```bash
source <(teamctl completion zsh)       # zsh, without install.sh
eval "$(teamctl completion bash)"      # bash (3.2 cannot source a process substitution)
```

`./install.sh` puts the shims in `~/.config/wolfmux/completion/` and sources the zsh
one from the wolfmux block in `~/.zshrc`. The backend is `teamctl _complete` inside
teamctl; Tab completes commands, options, and the values teamctl knows: roles,
teams, models, policy keys and choices, layouts, pending approvals, branches. The
zsh shim registers only when a completion system is already loaded (compinit);
it never switches one on itself. A shell without compinit:
`autoload -Uz compinit && compinit` above the wolfmux block.

## Clearing up

```bash
teamctl destroy --worktrees        # end the team; remove workers that hold nothing
teamctl remove qa                  # one stopped worker: worktree, branch, record
teamctl remove research --force    # ...even though it holds work (lists it, asks once)
```

A worker with uncommitted files or unmerged commits is never removed silently: keep its
work with `git merge <branch>`, or discard it with `--force`.

## Stopping

```bash
teamctl stop backend               # close one pane; worktree, branch, commits stay
teamctl restart backend            # same worktree + branch   (--continue resumes its own conversation,
                                   #                           --resume <session-id> reopens the one you name)
teamctl destroy                    # end the tmux session; keeps everything else
teamctl destroy --worktrees        # also removes CLEAN worktrees and FULLY MERGED branches teamctl created
```

`destroy` never deletes source files, commits, unmerged branches, dirty worktrees,
credentials or Beads data, and always asks first (`--yes` to skip).

## Disk

A worker's worktree carries whatever it installs and builds inside: on one project here
2.3 GB of `node_modules`, 0.9 GB of `.next` and half a gigabyte of copied assets per lane.
Nothing used to remove it, 27 parked lanes reached 65 GB and the machine filled its disk.
Now teamctl cleans up after its own worktrees.

```bash
teamctl status                     # free disk, and what this team's lanes take
teamctl teams                      # measures it per team (a du per lane: seconds)
teamctl prune --dry-run            # what every PARKED lane holds; deletes nothing
teamctl prune                      # take it: node_modules and all build output
teamctl prune --keep-node-modules  # build caches only, so a restart stays cheap
teamctl prune --team review        # one named team
```

`teamctl stop` takes a lane's build caches (`.next`, `dist`, `.turbo`, `build`, `coverage`,
`.cache`, `.parcel-cache`, `.vite`, `.svelte-kit`, `.nuxt`, `target`) and keeps
`node_modules`, so `teamctl restart` stays cheap. `teamctl remove` and
`teamctl destroy --worktrees` take all of it; the worktree is going away anyway. A `remove`
that refuses, because the lane holds commits or files somebody wrote, changes nothing:
"nothing was removed" means the build output is still there too. Build output is not
"files somebody wrote" — a `node_modules` (the `--link-node-modules` symlink included), the
build caches and wolfmux's own cleanup trash go without a question — except for `build`,
`dist` and `target`: when git neither tracks nor ignores one of those, remove asks, because
a handwritten `dist/deploy.sh` lives exactly there.

Never deleted: a source file, a commit, git state, anything git tracks (a project that
commits its `dist` keeps it), a running lane, your own checkout, or a worktree holding
uncommitted changes or untracked files that are not build output — that one is skipped and
the reason is printed. A lane that lost its `node_modules` needs one `npm install` before
its tools run again; nothing else of it changes.

`teamctl spawn` refuses a new lane when free disk is under `disk-min-gb` (default 20 GB) and
names `teamctl prune --dry-run` as the next step; `teamctl policy disk-guard warn` makes it
a warning, `off` removes the check. `teamctl spawn <role> <model> --link-node-modules` (or
`teamctl policy link-node-modules on`) points a new lane's `node_modules` at the project
root's copy instead of installing 2+ GB again — one directory for every lane, so an
`npm install` in any lane changes the dependencies of all of them.

## Diagnostics

```bash
teamctl doctor                                  # launchers, inherited keys, settings overrides, Keychain, logins
teamctl doctor --probe                          # the same, plus one incomplete request per stored provider key: is it accepted?
WOLFMUX_DRY_RUN=1 claude-glm                    # what a launcher would exec — no secrets, nothing started
WOLFMUX_DRY_RUN=1 claude-kimi                   # any provider name works; shows billing and the metered gate too
```

## Where things live

| What | Where |
|------|-------|
| Launchers + CLI | `~/bin/`: `teamctl`, `claude-fable`, `codex-astra`, `claude-glm`; symlinks `claude-glm-flash`, `claude-kimi`, `claude-moonshot`, `claude-deepseek`, `claude-minimax`, `claude-qwen` → `claude-glm` (it picks the provider from the name it was started as) and `claude-opus`, `claude-sonnet`, `claude-haiku` → `claude-fable` (the model the same way); `codex`, a small `sh` wrapper (one `exec` line) that starts ChatGPT.app's bundled CLI by its real path (only when no other `codex` is installed) |
| Code, tmux config, protocol, this file | `~/.config/wolfmux/` (`lib/*.sh`, `hooks/beads-nudge`, `tmux.conf`, `TEAM_PROTOCOL.md`, `config`, `glm-worker-settings.json`) |
| Notifications | `~/.config/wolfmux/Wolfmux.app` (built by `install.sh`; owns the notifications of a team that is not open in a terminal which can show them itself — iTerm2, kitty, Ghostty, WezTerm — so a click opens the team) and `~/.wolfmux/notify/` (the message in transit, the last project, the script a click runs) |
| Provider credentials | macOS login Keychain, one service each: `zai-coding-plan` (Z.ai), `wolfmux-kimi`, `wolfmux-moonshot`, `wolfmux-deepseek`, `wolfmux-minimax`, `wolfmux-qwen`. Nowhere else. |
| Claude / Codex logins | wherever those CLIs keep them (`/login`, `codex login`); untouched |
| Worktrees | `~/.wolfmux/worktrees/<project>-<hash>/<role>-<timestamp>/`; a named team's under `…/<project>-<hash>/teams/<team>/` |
| teamctl state (role ↔ model ↔ worktree, policy, approvals, event log) | `~/.wolfmux/state/<project>-<hash>/`; a named team's under `…/teams/<team>/` — nothing is written into your repository |
| Agents' conversations | Claude Code's own `~/.claude/projects/<the worktree's path, every character that is not a letter or digit turned into ->/`; `teamctl destroy --purge` removes those of the teammates it deletes. A lead's conversations are in your checkout's folder there and stay; Codex keeps its own sessions |
| Tasks + messages | the project's `.beads/` (embedded Dolt; locally excluded from git in stealth mode) |
| tmux | dedicated server: `tmux -L wolfmux`; your default tmux and `~/.tmux.conf` are untouched. A team started before the rename from "ai-team" stays on `tmux -L ai-team` until it ends; `teamctl` follows it |
| Permissions | `~/.claude/settings.json` (allow `teamctl`, `bd`, `git status`, `git worktree list`; ask on `teamctl destroy`), `~/.codex/rules/wolfmux.rules` |

## Settings

`~/.config/wolfmux/config`, plain `KEY=value` lines; every key is in the file, commented
out, with its values. `install.sh` leaves the file alone once it holds one active line;
while it is still all comments it is replaced by the current template, so that new settings
show up (the old copy goes to `~/.wolfmux/backups/<stamp>/`). An environment variable of
the same name wins for a launcher you start by hand.

| Setting | Default | Means |
|---------|---------|-------|
| `WOLFMUX_LEAD_PERMISSIONS` · `WOLFMUX_WORKER_PERMISSIONS` | `skip` | permission mode of every team that has not set its own (`teamctl policy`) |
| `WOLFMUX_BRANCH_TEMPLATE` | unset | how workers' branches are named in every team that has not set its own (`teamctl policy branch-template`); unset = `ai/{role}-{ts}` and `ai/{team}/{role}-{ts}` |
| `WOLFMUX_WORKER_SPAWN` | `off` | may workers spawn teammates (same rule: a team's own policy wins) |
| `WOLFMUX_WORKER_ISOLATION` | `on` | the worktree guard |
| `WOLFMUX_LEAD_TEAMS` | `on` | may a lead found further teams |
| `WOLFMUX_APPROVAL_TIMEOUT` | `600` | seconds a worker waits for the lead's decision before its own prompt appears |
| `WOLFMUX_DISK_GUARD` | `refuse` | what `teamctl spawn` does when free disk is under the limit below: `refuse`, `warn`, `off` |
| `WOLFMUX_DISK_MIN_GB` | `20` | that limit, in whole gigabytes, where 1 GB is 1024 MB (a gibibyte — the unit teamctl prints sizes in). A lane costs about 3 GB once it has installed and built; `0` switches the check off; no leading zero (write `8`, not `08`) |
| `WOLFMUX_LINK_NODE_MODULES` | `off` | `on` links every new lane's `node_modules` to the copy in the repository that lane belongs to (`teamctl spawn --repo` can make that another one). One directory for all of them: an install in any lane changes them all |
| `WOLFMUX_LAYOUT` | `lead-left` | pane arrangement: `lead-left`, `lead-top`, `tiled` (`teamctl layout` per team) |
| `WOLFMUX_SPLASH` | on | `off` removes the wolf popup when a team opens |
| `WOLFMUX_NOTIFY` | `all` | whose finished turns notify you: `all`, `lead`, `off`. A team founded by a lead is announced in every case |
| `WOLFMUX_TERMINAL` | the one you last attached from, else iTerm2 when installed, else Terminal | `iterm` or `terminal`: what a click on a notification opens |
| `WOLFMUX_GLM_AUTH_MODE` | `helper` | `env` hands the Z.ai key over as `ANTHROPIC_AUTH_TOKEN` instead: a last resort that cannot fix a wrong key ([Auth modes](#auth-modes-and-the-key-probe)) |
| `WOLFMUX_GLM_CONTEXT` | 200000 tokens | `1m`, or a number: the context window GLM workers declare |
| `WOLFMUX_METERED` | `off` | `on` lets the metered providers start. Which those are, and what that can cost: [Metered providers](#metered-providers) |
| `WOLFMUX_KIMI_AUTH_MODE` · `WOLFMUX_MOONSHOT_AUTH_MODE` · `WOLFMUX_DEEPSEEK_AUTH_MODE` · `WOLFMUX_MINIMAX_AUTH_MODE` · `WOLFMUX_QWEN_AUTH_MODE` | `helper` | per provider, the same two modes as `WOLFMUX_GLM_AUTH_MODE`; `env` exports the vendor's documented variable (`ANTHROPIC_API_KEY` for Kimi, `ANTHROPIC_AUTH_TOKEN` for the others); a last resort, and Kimi's makes Claude Code ask "use this API key?" in the pane ([Auth modes](#auth-modes-and-the-key-probe)) |
| `WOLFMUX_KIMI_CONTEXT` · `WOLFMUX_MOONSHOT_CONTEXT` · `WOLFMUX_DEEPSEEK_CONTEXT` · `WOLFMUX_MINIMAX_CONTEXT` · `WOLFMUX_QWEN_CONTEXT` | the table value | a number: the context window that provider's workers declare to Claude Code |
| `WOLFMUX_KIMI_MODEL` · `WOLFMUX_MOONSHOT_MODEL` · `WOLFMUX_DEEPSEEK_MODEL` · `WOLFMUX_MINIMAX_MODEL` · `WOLFMUX_QWEN_MODEL` · `WOLFMUX_KIMI_FAST_MODEL` · `WOLFMUX_MOONSHOT_FAST_MODEL` · `WOLFMUX_DEEPSEEK_FAST_MODEL` · `WOLFMUX_MINIMAX_FAST_MODEL` · `WOLFMUX_QWEN_FAST_MODEL` | the ids in `lib/providers.sh` | model pins per provider, for when a vendor changes its ids. GLM is not pinnable |
| `WOLFMUX_FABLE_MODEL` · `WOLFMUX_OPUS_MODEL` · `WOLFMUX_SONNET_MODEL` · `WOLFMUX_HAIKU_MODEL` · `WOLFMUX_ASTRA_MODEL` | the current ids | which model id each key means |

## How subscription separation works

- **No global variable, no settings entry.** Nothing in `~/.zshrc` or
  `~/.claude/settings.json` points anywhere. Plain `claude` is exactly what it was.
- **Launchers scrub, then exec.** Each launcher removes every provider / credential /
  model override (`ANTHROPIC_*`, `CLAUDE_CODE_USE_*`, `OPENAI_*`, `CODEX_API_KEY`, …)
  and every inherited agent-session variable from *its own process*, then execs the CLI.
- `claude-fable`: no key, no endpoint → the only credential left is your `/login`.
- `codex-astra`: `forced_login_method="chatgpt"`, `model_provider="openai"`,
  `model="gpt-6-astra"` → an API key cannot be used even if one appears later.
- `claude-glm` and every name it is linked as (`claude-glm-flash`,
  `claude-kimi`, `claude-moonshot`, `claude-deepseek`, `claude-minimax`,
  `claude-qwen`): reads provider, endpoint, key, billing and model ids from one
  table (`lib/providers.sh`), sets `ANTHROPIC_BASE_URL` to that provider's endpoint
  inside its own process only, and maps **every** Claude alias (opus, sonnet, fable,
  haiku, subagents) to that provider's main and background model ids (GLM's plan
  covers exactly `glm-5.3` / `glm-5.3-flash`). The key reaches Claude Code through
  `apiKeyHelper` (a Keychain read), so it is never in the environment, the agent's
  subprocesses, transcripts or tmux scrollback. The User-Agent is never touched
  (Kimi Code's terms forbid altering it).
- **Login guard.** Measured on a localhost mock endpoint: a Claude Code process that
  inherits a custom base URL but no token sends your real claude.ai login to that URL.
  Every provider worker therefore carries an inert `CLAUDE_CODE_OAUTH_TOKEN` placeholder that
  outranks the stored login, so anything a worker spawns fails closed at that provider's endpoint instead of
  handing it your Claude token. `claude-fable` drops that placeholder again.
- The team tmux server is started with a scrubbed environment, so panes inherit none of it.

Launcher knobs are read from `~/.config/wolfmux/config` (a pane's environment comes from
the tmux server, not from the shell you typed `teamctl spawn` in):
`WOLFMUX_GLM_AUTH_MODE=env` switches workers to Z.ai's documented `ANTHROPIC_AUTH_TOKEN`
variable, a last resort that cannot fix a wrong key ([below](#auth-modes-and-the-key-probe));
`WOLFMUX_GLM_CONTEXT=1m` opts into the 1M window (uses quota faster); by default the
launcher declares a 200k window, which is what keeps Claude Code from printing its
"isn't described by this version's model catalog" notice in worker panes.
The other providers take the same knobs under their own names
(`WOLFMUX_KIMI_AUTH_MODE=env`, `WOLFMUX_KIMI_CONTEXT=400000`), plus model pins
(`WOLFMUX_KIMI_MODEL`, `WOLFMUX_KIMI_FAST_MODEL`) for when a vendor changes its ids;
the config template lists every name with a one-line explanation.
`~/.config/wolfmux/glm-worker-settings.json` is a Claude Code settings overlay applied to
every third-party provider worker. It ships with `claude-mem` turned off there: that plugin runs a
long-lived summarizer daemon which inherits the environment of whichever session starts
it, and one started from a provider worker would route your normal sessions' memory traffic
to that provider. Delete the file to make workers identical to your normal sessions.

What no local tool can prove: account-side switches. Keep claude.ai "extra usage" off,
do not buy Codex credits, and keep the Z.ai cash balance at zero.

## Auth modes and the key probe

A provider worker gets its key one of two ways (`WOLFMUX_<PROVIDER>_AUTH_MODE`):

- `helper` (default): Claude Code is given a Keychain-reading command, so the key is never in an
  environment. Every provider worker also carries the inert login guard
  (`CLAUDE_CODE_OAUTH_TOKEN`), so Claude Code prints `Both CLAUDE_CODE_OAUTH_TOKEN and apiKeyHelper set`.
  That warning is expected and harmless, and it is not the cause of a 401 next to it.
- `env`: the vendor's own variable, a last resort for an endpoint that refuses helper-mode headers.
  It cannot fix a wrong key. With `ANTHROPIC_API_KEY` (Kimi Code) Claude Code asks "Do you want to use
  this API key?" (default No) and remembers the answer, so an unattended worker waits at that prompt.
  Claude Code documents no setting that pre-approves the key, and Wolfmux never edits your
  `~/.claude.json`, so the prompt stays.

`teamctl doctor --probe` answers "is the key accepted?" for every provider whose Keychain item exists.
Per provider it sends ONE request over https: `POST <endpoint>/v1/messages` with an empty body. That asks
for no completion, so nothing is generated or billed (the metered providers too), and it is not a model
listing because `GET /v1/models` does not check the key (Z.ai answers it without one, Moonshot and Qwen
have no such route). 200, 400, 422 and 429 mean accepted (the raw status is printed beside it), 401 and
403 are a FAIL naming the Keychain slot and the console the key comes from, anything else is a warning.
The key goes to curl on its stdin only, never into an argument, an environment, a file or the screen,
and no redirect is followed. A `kimi` key that does not start with `sk-kim`, or a `qwen` key without
`sk-sp-`, gets a warning of its own. Plain `teamctl doctor` stays offline and never reads a key value.

## Metered providers

Two of the provider table entries bill per request instead of by subscription: the
Moonshot platform (`moonshot`, Kimi K3 API) and DeepSeek (`deepseek`). Two switches
must be on at once, and both are yours, the owner's: the key in the Keychain
(`security add-generic-password -U -s wolfmux-moonshot ...`, one-time setup above),
and this line in `~/.config/wolfmux/config`:

```bash
WOLFMUX_METERED=on
```

While either is missing, `teamctl spawn` and `teamctl start` refuse with exit 77 and
the launcher with exit 78, each naming the missing switch. A dry run still prints
(`WOLFMUX_DRY_RUN=1 claude-moonshot`), with `metered gate: closed`.

Switched on, a metered worker bills its vendor per request for as long as the balance
you loaded lasts. There is no local cap: no spending limit, no quota, nothing in
wolfmux that stops a long run. The switch lives in your config file, changed by you
at your terminal; an agent that offers to flip it for you should be refused.

## Verify provider and model inside each CLI

| Pane | Type | Expect |
|------|------|--------|
| Fable lead | `/status` | Login method: Claude subscription · no API key · no custom base URL · model Fable 5.1 |
| Astra lead | `/status` | Signed in with ChatGPT · model `gpt-6-astra` |
| GLM worker | `/status` | Base URL `https://api.z.ai/api/anthropic` · auth: apiKeyHelper (or ANTHROPIC_AUTH_TOKEN in env mode) · model `glm-5.3` / `glm-5.3-flash` |
| provider worker | `/status` | that provider's base URL and model (Kimi auth may be `ANTHROPIC_API_KEY` in env mode); `WOLFMUX_DRY_RUN=1 claude-<provider>` prints the exact values |

## Updating safely

```bash
claude update                 # native installer; launchers resolve `claude` at run time
# Codex: update the ChatGPT desktop app (its bundled CLI is what ~/bin/codex starts).
#        A standalone install (curl -fsSL https://chatgpt.com/codex/install.sh | sh) lands in
#        ~/.local/bin, which precedes ~/bin, so it takes over automatically.
bd export --all > beads-backup.jsonl   # then replace ~/.local/bin/bd with a verified release; see Beads upgrade guide
teamctl doctor                # after any update
```

Never run `codex login --with-api-key`, never export `ANTHROPIC_API_KEY` /
`OPENAI_API_KEY` globally, never paste a Z.ai block into `~/.claude/settings.json`.

## tmux keys (team server only)

Mouse: click = focus, drag border = resize, wheel = scroll. `Ctrl-b` then: arrows =
move · `Ctrl`-arrows / `Alt`-arrows = resize · `z` = zoom · `T` = re-tile · `q` = pane
numbers · `d` = detach · `"` `%` `c` = new pane/window in the current directory.

## Uninstall (the CLIs stay untouched)

From the repository, `./uninstall.sh` removes what `install.sh` created and restores what it
edited; it keeps `~/.wolfmux` (`--purge` removes it once no worktree is left in it), the
Keychain item and Beads. By hand:

```bash
teamctl destroy --worktrees                      # in each project that has a team
rm ~/bin/teamctl ~/bin/claude-fable ~/bin/claude-opus ~/bin/claude-sonnet ~/bin/claude-haiku \
   ~/bin/codex-astra ~/bin/claude-glm ~/bin/claude-glm-flash \
   ~/bin/claude-kimi ~/bin/claude-moonshot ~/bin/claude-deepseek ~/bin/claude-minimax ~/bin/claude-qwen
grep -q wolfmux-codex-wrapper ~/bin/codex && rm ~/bin/codex      # only the wrapper install.sh wrote
rm -r ~/.config/wolfmux ~/.wolfmux               # includes Wolfmux.app
rm ~/.codex/rules/wolfmux.rules
security delete-generic-password -s zai-coding-plan
# the same for every provider key you added: -s wolfmux-kimi, -s wolfmux-moonshot, -s wolfmux-deepseek, -s wolfmux-minimax, -s wolfmux-qwen
# ~/.zshrc: delete the block between ">>> wolfmux >>>" and "<<< wolfmux <<<"
# ~/.claude/settings.json: delete the teamctl / bd / git / tmux allow lines and the "ask" entry
#   (or restore ~/.claude/settings.json.backup-<timestamp>)
# Beads itself (optional): rm ~/.local/bin/bd; per project: rm -r .beads and its .git/info/exclude lines
```

## Manual cleanup

```bash
tmux -L wolfmux ls                          # sessions on the team server
tmux -L wolfmux kill-server                 # stop every team at once
git worktree list && git worktree prune     # in a project
git branch --list 'ai/*'                    # leftover worker branches, default template (delete merged ones: git branch -d)
ls ~/.wolfmux/state ~/.wolfmux/worktrees    # per-project state and worktrees
```

## Limits worth knowing

- A worker's banner reads `API Usage Billing`. That is Claude Code's label for any
  session authenticated with a key instead of a claude.ai login. For a GLM worker the
  key is your Z.ai Coding Plan key and the endpoint is Z.ai's; nothing is billed by
  Anthropic. `/status` in the pane shows the base URL.
- The manager check is cooperative: every agent is your macOS user, so it stops
  mistakes and role confusion, not a deliberately hostile process.
- With several teams, every lead works in your checkout on the branch that is checked out
  there. Teammates are apart in worktrees; leads are not. Let one lead integrate at a time.
- Each Claude-family agent is given its own conversation id when it starts, and `--continue`
  reopens that id, so two leads in one folder come back in their own conversations. The
  stored id is in `teamctl status --json` (`.agents[].session_id`), the lead's is kept with
  the team across `teamctl destroy`, and `teamctl restart <role> --resume <session-id>` pins a
  different one (an id without a transcript is refused). An agent that never said a word has
  nothing to resume: `--continue` starts its conversation fresh under the same id. An agent
  with no id on record (from before 1.12, or a first `start --continue`) falls back to the
  newest conversation in the folder, which with two leads there may be the other one's, and
  warns in one line. Codex-based agents take no id: they resume their own last conversation,
  and in a shared folder that stays ambiguous.
- Codex-based agents (`astra`, `codex:<id>`) have no worktree guard and no lead-approval
  mode: Codex offers no hook for either. They do send notifications.

- Notifications are typed into a pane. If an agent is mid-turn its CLI queues the line;
  if a CLI is showing a modal dialog (first-run folder trust), answer the dialog first.
- Beads runs in embedded mode (no daemon): writes are serialized by a file lock.
  16 parallel writers were tested clean, but each waits its turn. Heavy swarms should
  switch the project to Beads server mode (`bd init --server`, needs the `dolt` CLI).
- Comments on beads notify nobody; send a message when someone must act.
- Workers share your `~/.claude` (plugins, hooks, skills, permissions). That is
  deliberate, and it means hooks you add there also run inside GLM workers.
