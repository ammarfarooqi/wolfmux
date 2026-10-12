# Build log

How this system was built on 2026-09-20, in order, including what went wrong.
Decisions are explained in [adr/](adr/README.md).

## 0. Audit — nothing modified

| Found | Consequence |
|-------|-------------|
| macOS 26.6 arm64, zsh 5.9, `/bin/bash` 3.2.57 | everything is written for bash 3.2 |
| tmux 3.7c, git 2.50, jq 1.7.1, sqlite3 present | no dependency had to be installed |
| Homebrew prefix owned by a different account; the owner's `~/.zshrc` says to install user tools into `~/.local/bin` | Beads went to `~/.local/bin`, not Homebrew |
| interactive aliases `rm/mv/cp/ln -i`, `cat` = bat | scripted commands use absolute binaries (`/bin/cp`, `/bin/cat`) |
| Claude Code 2.1.278, native install, signed in with a Max subscription, no API key | nothing to change |
| no `codex` on PATH, but a Codex CLI inside ChatGPT.app (0.155.0-alpha.9.2), signed in with ChatGPT, `model = "gpt-6-astra"` already in its config | reuse it; no second install |
| no `~/bin`, no `~/.tmux.conf`, no `~/.zprofile`; no provider variable anywhere; no MCP servers | clean start |
| no Keychain item `zai-coding-plan` | the owner adds it; never pasted into chat |

Vendor documentation was read before writing anything: Z.ai's Claude Code guide and
FAQ (endpoint, the two covered model ids, the 1M suffix), Claude Code's model,
authentication, environment-variable and permissions references, and the Codex
authentication, rules and environment-variable pages.

## 1. Scope change

Partway through, the owner replaced the planned filesystem task/message store with
**Beads** and limited `teamctl` to tmux, models, worktrees and lifecycle. Nothing
had been written yet, so there was no rework. Beads 1.3.0 was then evaluated in a
sandboxed `HOME` before adoption (results in
[VERIFICATION.md](VERIFICATION.md#beads-evaluation-sandboxed-home)).

## 2. Beads install

Official release tarball, SHA-256 verified against `checksums.txt`, installed to
`~/.local/bin/bd`. Beads' anonymous usage metrics were turned off (`bd metrics off`).

## 3. `~/bin` and PATH

`~/.zshrc` backed up, then one marked block appended that adds `~/bin` to the end
of `PATH`.

## 4. Launchers

`claude-fable`, `codex-astra`, `claude-glm` (+ `claude-glm-flash` symlink), sharing
`lib/provider-env.sh`. Verified with hostile variables injected; `claude-glm`
exits 78 with the exact Keychain command when the key is missing.

## 5. tmux

A team-only config validated on a throwaway tmux server: options effective,
direct-exec panes with `-e` work, `prefix T` was unbound.

## 6. teamctl

Registry, tmux, worktree, Beads-glue, lifecycle, views and doctor modules; the agent
protocol; the user manual.

## 7. Bugs found by testing, and their fixes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `doctor` stopped after the Z.ai section | `grep` returning 1 inside a `$(…)` under `pipefail` | `|| true` inside the substitutions; helpers made total |
| `start` failed: `MODEL_LABEL: unbound variable` | `model_info` ran inside a command substitution, so its variables never reached the caller | call it in the current shell |
| `start` failed: `no such session: =team-…` and left a half-made session | `set-option -t "=name"` is parsed as a pane target; the exact-match form needs a trailing colon | `=name:` for session options; `start` now rolls back on any failure after session creation |
| message beads missing from the inbox | `bd list` hides message beads by default | `--include-infra` in every inbox command, the notification text and the protocol |
| `bd init` refused in a directory named with spaces | Beads derives its prefix from the raw directory name | `teamctl` derives a valid prefix itself |
| `teamctl spawn … | head -1` exited non-zero after finishing its work | `printf` to a closed pipe under `set -e` | `say` tolerates a closed pipe |
| unassigned beads shifted fields in the hook | tab is whitespace for `IFS`, so empty fields collapsed | unit-separator join |

## 8. Permissions

Claude Code: allow rules for `teamctl`, `bd`, read-only git and read-only team-tmux,
plus an *ask* rule for `teamctl destroy`, merged into `~/.claude/settings.json`
after a backup. Codex: a separate `~/.codex/rules/wolfmux.rules`, validated with
`codex execpolicy check`. Codex needs this because its sandbox blocks the tmux
socket and writes outside the workspace.

## 9. Review

Independent code and security reviews ran in parallel; findings and dispositions
are in [SECURITY.md](SECURITY.md#review-record-2026-09-20).

## 10. The credential experiment

The security review recommended helper-only key delivery. Checking that against a
localhost mock showed something neither review had: a process that inherits only
the custom base URL presents the real claude.ai login to it. The result is the
login guard ([ADR-0007](adr/0007-zai-key-delivery-and-login-guard.md)), the
`config` file for persistent launcher settings, and the GLM worker settings
overlay that keeps `claude-mem`'s daemon from starting under a Z.ai environment.

## 11. Packaging

This repository: sources, `install.sh` / `uninstall.sh` (tested in a fake `HOME`),
`tests/smoke.sh` (31 checks at the time), `tests/credential-routing.sh`, and this documentation.

## 12. First real use — three problems, one root cause (v1.1)

The owner ran a real team and reported: teammates were asking a GLM session for approval
and treating it as the manager; agents stalled on permission prompts; and a worker had
been able to create teammates on its own.

Root cause of the first and third: the owner's Claude Code settings enable the
experimental agent-teams feature (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`,
`teammateMode: iterm2`), which workers inherited. With it on, any subagent a session
names becomes a teammate whose team lead and permission approver is that session
(documented behaviour). Fix and additions are in
[ADR-0013](adr/0013-one-manager-policy.md): manager-only commands, a per-project policy
(`lead-permissions`, `worker-permissions`, `worker-spawn`), agent teams switched off
inside workers, a `PermissionRequest` hook that lets the lead approve or deny, and lead
notices for spawns and policy changes. The smoke suite grew from 31 to 48 checks, and the
override was confirmed against the real CLI.

## 13. The rename (v1.2)

The owner called "ai-team" a bad name. "Wolfpack" was picked, then dropped when a search
found 1,137 GitHub repositories with that name; **Wolfmux** had none (and was free on
npm, PyPI and Homebrew). Candidate names were checked with `gh api search/repositories`
before they were offered again.

The rename itself was mechanical (`AI_TEAM_` → `WOLFMUX_`, `ai-team` → `wolfmux`, two
`git mv`). The work was in not breaking the machine it ran on: a lead was live on the old
tmux socket and a stopped worker had a worktree under `~/.ai-team`. See
[ADR-0014](adr/0014-rename-to-wolfmux.md). What was added:

- `teamctl` follows a team on the old socket until its last session ends;
- Beads hooks carrying the old marker count as ours and are rewritten;
- `migrate-from-ai-team.sh` (with `--dry-run`) moves state and worktrees, rewrites the one
  stored path, runs `git worktree repair`, renames the marked `~/.zshrc` block and the
  two tmux permission rules in place, and parks the old config in backups;
- `install.sh` refuses to install next to an unmigrated v1.1.

Two ideas were written and then removed as unneeded: accepting the old login-guard value
(no v1.1 GLM worker was alive to carry it) and reading the old tmux session option (a
project with stored state never consults it).

`tests/migration.sh` rehearses the whole move in a throwaway `HOME`: it installs v1.1
from git history, runs a team with it, migrates, and ends with `uninstall.sh` (21 checks).
`tests/smoke.sh` grew from 48 to 55 checks. Only then was the real machine migrated.

## 14. The wolf, diagrams, and a notification that opened the wrong app (v1.3)

Asked for: a wolf when a team is opened, a wolf that always marks the manager, and
presentable diagrams. One pixel drawing (`tools/wolf-art.py`) became the terminal art,
the logo and the wolf in the README image. The splash is a tmux popup on
`client-attached`; checking it needed a trick, because `capture-pane` cannot see popups
and a logged pty shows tmux drawing text cell by cell: the team client was attached
*inside an outer tmux server*, whose `capture-pane` then shows exactly what a person
sees. The manager's mark is a conditional in `pane-border-format` and
`pane-border-style`, plus the Claude session name.

The diagrams are SVG on their own dark ground, so GitHub's two themes cannot break them.
Three are hand-written; the three sequence diagrams come from one renderer
(`tools/flow-diagrams.py`) so they cannot drift apart. Each was rendered with a headless
Chromium and looked at before it was committed.

While this was being built the owner reported that clicking a "task complete"
notification opened Script Editor. Cause: the ECC plugin's notifier falls back to
`osascript` inside tmux. Fix: [ADR-0015](adr/0015-notifications-through-the-attached-terminal.md).
`tests/smoke.sh` grew from 55 to 71 checks.

## 15. Finished panes, arrangement, and the pack (v1.4)

The owner quit every agent and ran `teamctl start fable` again: it attached to a window of
`Pane is dead` lines. `remain-on-exit` had kept the panes (on purpose, so the last output
stays readable), the session still existed, and `start` only asked whether a session
existed. It now asks what is alive (see ARCHITECTURE, "Arrangement and coming back").
Because that session was the last one on the pre-rename socket, the socket choice had to
become re-evaluable, otherwise the fresh team would have been started under the old name.

Same report: the arrangement. tmux's `tiled` gave the third pane the full width and moved
everything whenever a worker came or went. Default is now `lead-left`; `teamctl layout`
switches. And the teammates got their own mark, 🐶, next to the lead's 🐺 (there is only
one wolf emoji). Tests were written first and seen failing (9 red), then made to pass.

Last, the long yellow `"glm-5.3" isn't described by this version's model catalog` notice in
every worker pane. The notice itself names three ways out; each was tried on the real CLI
against the localhost mock. Declaring the window Claude Code already assumes
(`CLAUDE_CODE_MAX_CONTEXT_TOKENS=200000`) removes it without changing behaviour, so that is
what `claude-glm` does. The variable stays on the scrub list — a Fable child must never
inherit a GLM window — so a different number goes through `WOLFMUX_GLM_CONTEXT`.
`tests/smoke.sh` 71 → 85.

## 16. The notification opened Script Editor again (v1.5)

ADR-0015's first version handled the attached team and fell back to `osascript` for the
detached one, "because there is nowhere to go back to". The owner's very next
notification was the detached case. The assumption was wrong twice: a team working in the
background is the normal case, and there *is* somewhere to go — a new terminal window.
macOS opens the owner of a notification on click, which is why Script Editor kept
appearing; so Wolfmux now ships an owner of its own, built by `install.sh` with
`osacompile`, with the wolf as its icon. One application, two meanings of "launched":
a message is waiting → post it; nothing is waiting → that was a click, open the team.

Found on the way: a lead had spawned `Riley-pr-reviewer`. Role names are lowercase by
contract, but `[a-z]` follows the locale's collation and matches capitals under
`en_AU.UTF-8`. Alphabets are now spelled out. `tests/smoke.sh`: 85 → 92.

## 17. Clearing up, and staying in lane (v1.6)

Two more reports. `teamctl destroy` "did not work": it had worked as designed (it keeps
worktrees), but there was no way to discard a worker that still held work, and the one
line that said so was easy to miss. Now there is `teamctl remove <role> [--force]`, and
`destroy` names what it kept, why, and the command for either way out.

And the question whether a teammate is really tied to its worktree. Honest answer until
then: by instruction only. Now a `PreToolUse` guard refuses tool calls that leave the
lane ([ADR-0016](adr/0016-worktree-guard.md)). Writing it surfaced two traps worth
keeping: a path has several spellings (`/var/…` and `/private/var/…`, doubled slashes), so
the shell check replaces every spelling with a token before matching; and bash 3.2
misreads escaped quotes inside `"$( … )"`, which split a jq program at its commas
(brace expansion) in the tests. `tests/smoke.sh`: 92 → 109.

## 18. Astra could not run a command; any model for any teammate (v1.7)

The owner started an Astra-led team and asked it to spawn a teammate. Codex answered
"Code Mode is unavailable … codex-code-mode-host: host executable was not found", tried to
drive Terminal through computer use, was refused, and gave up. Cause: `~/bin/codex` was a
symlink into ChatGPT.app, and Codex looks for its helper programs next to the path it was
*started as*. It had never been caught because the build only took the Codex TUI as far as
its first screen. Fix: a wrapper instead of the symlink, and `codex-astra` resolves
symlinks before it execs. This time it was checked with one real turn on the ChatGPT
login: the command ran, no warning, and Codex's `notify` program delivered
`🐺 lead: wolfmux-ok` — so Codex agents notify now as well.

Same report: staff any team with any model ([ADR-0017](adr/0017-any-model-for-any-agent.md)).

The security review of the guard and of `remove` arrived in between. Its critical finding
(a hand-edited record could make `remove` delete any directory) had been found and fixed an
hour earlier; its others were new and right: prose in commit messages and Beads texts
tripped the shell patterns, a destructive verb anywhere in a command that merely mentioned
the lead's checkout was refused, MCP tools were not matched at all, and `remove a b` was
not all-or-nothing. All fixed, each with a check. `tests/smoke.sh`: 109 → 120.

## 19. Several teams per project (v1.8)

The owner had an Astra team up, ran `teamctl start fable` for a second team, and landed in
the Astra session. A project had one team by construction. Now it has teams
([ADR-0018](adr/0018-several-teams-per-project.md)): the first stays where it was, named
ones live under `teams/<name>/`, each with its own session, lead and workers, and
`teamctl status` draws them as a tree. The change stayed small because nearly everything
already hung off `STATE_DIR` and the session name; the real work was identity, since all
teams share one Beads database (`<team>.<role>`), and saying no: `start` with another model
refuses instead of attaching.

This was written while a second Claude session was fixing other things in the same
repository. Both worked in their own git worktrees on their own branches; this one rebased
on `main` before merging and installed only from `main`.

`tests/smoke.sh`: 120 → 139 (15 for teams, 4 from the other session's audit fixes, merged here).
## 20. Deleting a team; teams that talk and found teams

Asked: what does a team cost on disk, and can one command give it back? Measured on the
owner's project first (a worker = one 99 MB checkout, more only if it installs or builds;
the lead nothing; records KBs; transcripts 17 MB), then built `destroy --purge`
([ADR-0019](adr/0019-deleting-a-team-and-founding-one.md)): report, ask, delete. A test
bug worth remembering: the check computed the transcript folder from the worktree's path
*after* the purge had deleted the worktree, got the parent folder, and "failed" on a
directory that was rightly still there.

Asked in the same breath: do teams talk, and can a lead found a team and hand over? The
first already worked through the shared Beads (now tested in both directions, and every
agent is told how). The second did not: `start` was reserved for the human. A lead may now
found a team that does not exist yet, with `--handover <bead-id>` as the new lead's first
words; you are notified; `lead-teams off` switches it off.

`tests/smoke.sh` gained 14 checks for this.

## 21. An audit, and three things it was right about (v1.8, v1.8.1)

A full audit of the repository (ten readers, each finding checked by a second one that tried
to refute it) came back with a long list. The first three were small, certain and cheap:

- **`teamctl doctor` died on the one case it exists for.** `"$keys` followed directly by a
  dash: macOS bash 3.2 is not multibyte-aware, and under a UTF-8 locale it read the first
  byte of the dash as part of the variable name. With `set -u` that is "unbound variable",
  and it only happened when a settings file held a provider override. The same class as the
  role-name bug of entry 16. Now `${keys}`, and a check that no variable in any script is
  followed directly by a non-ASCII character.
- **A restarted worker said "ready" and waited.** `bd update --claim` sets `in_progress`;
  every inbox command printed or taught listed `--status open` only, so the task a worker was
  in the middle of was the one it could not see. Now `--status open,in_progress,blocked`
  everywhere (kickoff, both notices, help, protocol, manuals, the Codex rule file), and the
  kickoff says to continue, with `git status` and `teamctl diff <role> --commits`: commands
  every permission mode allows.
- **The "narrow" allow rules were not narrow.** They go into the global
  `~/.claude/settings.json`, and a rule is a prefix match: `git log *` also allowed
  `git log --output=<file>`, and the tmux rules allowed `… \; run-shell …`, in every Claude
  Code session on the machine. Five rules moved to `retired` in `claude/permissions.json`;
  `install.sh` never adds them and takes them out of an existing file (backup, each one
  named), `uninstall.sh` removes them too.

The review of the fix found that the first version of it contradicted itself (the kickoff
recommended `git log` in the same commit that retired its rule) and that the new doctor check
read the real `HOME`, Keychain and CLIs; both fixed before merging.
Rebasing onto the teams work of entries 19 and 20 showed one more: the kickoff addressed the inbox by
plain role, so a teammate of a *named* team was sent to an inbox that is not its own
(`backend` instead of `review.backend`); no check had covered it because every named-team
spawn in the suite used `--no-kickoff`. Now it names the Beads identity.

The three fixes went into `main` with v1.8 (entry 19 counts their four smoke checks); what the
review found, and the kickoff address, is v1.8.1. The second review asked whether the throwaway `HOME` really keeps doctor away from
the Keychain. It does (macOS resolves the user's keychain search list from `HOME`), and the
suite now says so with a check instead of a comment; the help and the manuals address the
inbox by `$BEADS_ACTOR` as well. `tests/smoke.sh`: 153 → 156 (three checks on top of entry 20). `tests/permissions.sh`: new, 9. `tests/migration.sh`: 21, one
expectation changed (the retired rules are gone after a migration).
## 22. "Why are the available commands not in the README?" (v1.9)

Because every feature had been written up where it was built (USAGE.md, the manual, an ADR)
and nothing checked the front page. The README showed five commands out of twenty-two;
docs/SETUP.md still said "55 checks" and "two symlinks"; `teamctl help` did not know
`lead-teams`, though the command accepted it.

The fix for the symptom: a command list, a model table and a feature overview in the README,
the reference table in USAGE.md brought up to date, settings and the worktree guard in the
manual, what the installer really builds in SETUP.md, and a diagram for the one headline
feature that had none (`docs/diagrams/teams.svg`). Writing that diagram surfaced a limit
that was documented nowhere: leads of several teams all work in the same checkout.

The fix for the cause: `tests/docs.sh`. It reads the code for what exists (the dispatch in
`bin/teamctl`, the `case` labels of each command's argument loop, `POLICY_KEYS`,
`model_info`, `WOLFMUX_CONFIG_KEYS`, the installer's links and options) and fails, naming
what is missing where, until the README, USAGE.md, the manual and `teamctl help` say it.
It also found two options no command reference showed (`capture --lines` appeared nowhere,
`nudge --quiet` only in the description of the Beads hook) and one that `teamctl help` did
not show (`destroy --keep-transcripts`). The check was
itself checked with thirteen mutations ([VERIFICATION.md](VERIFICATION.md)).

Then every sentence that had been added was checked against the code by a second reader.
About 350 claims held, 3 were false, 26 imprecise, and behind three of them the code was
wrong, not the sentence:

- A permission request of a teammate in a **named** team was filed with the first team and
  announced to the first team's lead: the hook built the state path without the team, the
  one place that never went through `team_paths`. "A lead manages its own team only" was
  not true for approvals. The suite had only ever tried lead mode in the first team.
- `WOLFMUX_APPROVAL_TIMEOUT` in the config file had no effect. `approvals.sh` read it while
  being sourced, and the config file is loaded after the modules. (The migration test
  even checked that this setting is carried over, into a file where it did nothing.)
- After any named team had existed, `uninstall.sh --purge` kept `~/.wolfmux` for ever: the
  empty `teams/` folder counted as a worktree.

Each got a failing check first (smoke on the unfixed copy: 156 passed, 3 failed). Also from that
reading: `uninstall.sh` ignored an option it did not know (`--purg` uninstalled without
purging; now exit 64, like its siblings), `install.sh --help` printed a line of code, and
three comments described an older program.

The security review of those fixes found one more, in the fix: the rewritten check in
`uninstall.sh` assigned `held="$(find … | head -1)"`. As a plain assignment its status
reaches `set -e`, and `find` fails when `~/.wolfmux/worktrees` does not exist, so
`--purge` died without a word in exactly the tidy state it is meant for. The old form, the
same pipeline inside `[ -n "$(…)" ]`, could not: a substitution used as a word loses its
status. Now `-print -quit`, no pipe, `|| true`; a check covers the missing folder.

`tests/smoke.sh`: 156 → 159. `tests/permissions.sh`: 9 → 13. `tests/docs.sh`: new, 28.
v1.9.0.

## 23. "Add Kimi, DeepSeek and the others" (v1.10)

The owner asked on 2026-09-20, and every vendor involved sells an Anthropic-compatible
endpoint, so the GLM launcher's isolation was the pattern to extend
([ADR-0020](adr/0020-providers-beyond-the-three-subscriptions.md)). One table
(`config/wolfmux/lib/providers.sh`) now knows every provider: vendor, endpoint, Keychain
service, billing, model ids, context window, auth variable. One launcher serves them all:
`claude-glm` reads the provider from the name it is started under (`claude-kimi`,
`claude-moonshot`, `claude-deepseek`, `claude-minimax`, `claude-qwen`; symlinks, the
pattern of `claude-opus`). The scrub, the per-process endpoint, the login guard, the
settings overlay and the dry run apply to every provider unchanged; the User-Agent is
never touched.

New is billing. Kimi, MiniMax and Qwen are plans like Z.ai's; the Moonshot platform and
DeepSeek bill per request. A metered provider starts only when its key is stored AND the
owner has set `WOLFMUX_METERED=on` in the config file: `teamctl spawn` and `start` refuse
with exit 77, the launcher with exit 78, and `teamctl status` marks a metered agent with
`$`. The switch is deliberately out of every agent's reach.

Deliberately out entirely: the metered aggregators (OpenRouter, LiteLLM, Fireworks,
Novita, SiliconFlow, forbidden by [GOALS.md](GOALS.md)), a third CLI family (Gemini CLI,
Grok Build, Mistral Vibe), a base-URL setting, and the China-region endpoints. The first
group stays forbidden; each of the others is one more table row later.

`tests/providers.sh`: new, 116 checks. `tests/smoke.sh`: 159 → 177. `tests/docs.sh`: 28 → 28.
`tests/migration.sh`: 21 → 24. v1.10.0.

v1.10.1, the same night: the machine lost its tmux server, and `teamctl restart lead --continue`
answered `no team session. Start one first: teamctl start fable`. That line drops the team and
`--continue`, so following it opened a new conversation and the old one looked lost. Now a
`restart` of the lead without a session starts the team again, as the model that led it, and
`--continue` goes with it; a worker's refusal names the exact two commands. `tests/smoke.sh`: 177 → 181.

v1.10.2 (issue #6): `destroy --purge --force` and `remove --force` ended with exit 141, no message
and nothing deleted, when a worker had more than ten unmerged commits: `git log | head -10`
under `pipefail`. git now limits its own output, the reports say how much they left out, and a
teamctl ended by a signal says so and names the command. `tests/smoke.sh`: 181 → 184.

## 24. Five issues from a day of real use (v1.11)

The issues came from a long day on another project: seven short-lived workers in one repository,
work across three repositories, a hook that wants a ticket key in every branch name, a founded
team whose lead died, and an hour lost to a Kimi key of the wrong kind. Four teammates took one
issue each (#3 and #4 together); the lead merged them and settled where they met.

- **#2, a founded team with no lead.** Its founder may now restart, stop, remove and destroy it,
  but only while that team's lead is not running; you are told each time, and `teamctl teams`
  marks the team `orphaned`. A restart keeps the lead record's founder and handover, or the
  founder would lose that right after one restart ([ADR-0023](adr/0023-founder-recovers-an-orphaned-team.md)).
- **#1, a rejected key that doctor called ok.** `teamctl doctor --probe` asks each endpoint once,
  with a request no vendor bills (POST `/v1/messages` with an empty body; the key is checked
  first, measured at all six), and names the console a key comes from. The key reaches curl on
  its stdin only ([ADR-0024](adr/0024-doctor-probe-and-key-sources.md)).
- **#3, branch names.** A team template (`teamctl policy branch-template`), `--ticket` and
  `--branch`; teamctl deletes only the branches it created ([ADR-0021](adr/0021-branch-names-from-a-template.md)).
- **#4, a sibling repository.** `teamctl spawn <role> <model> --repo <path>`: worktree and branch
  there, the guard still on, that repository's own checkout read-only too ([ADR-0022](adr/0022-a-worker-in-another-repository.md)).
- **#5, cold starts.** A CONTEXT column in `status`, and `spawn --from-worktree` for a fresh
  conversation in a built worktree ([ADR-0025](adr/0025-context-use-and-worktree-handover.md)).

Where two of them met, the lead decided: a worktree handed over stays in its own repository
(so `--from-worktree` and `--repo` do not combine), and its new branch follows the team's
template like any other. Left out on purpose: a warm idle worker, isolation per worker.

`tests/smoke.sh`: 184 → 250. `tests/providers.sh`: 116 → 134. `tests/docs.sh`: 28 → 32. v1.11.0.

## 25. Four leads, one conversation (v1.12)

On 2026-09-24 four teams shared one project folder, all four leads were restarted with `--continue`,
and all four came back in the same conversation (issue #7). `--continue` meant `claude --continue`,
the newest transcript **of the folder**, and every lead of a project works in the same folder, next to
the owner's own sessions. The owner's fix (PR #8) gives every Claude-family agent its own conversation
id at start and resumes that one; `--resume <session-id>` pins one by hand.

That fix was tested with the stub agent, which accepts anything. Asked directly, the real CLI refuses
two things, and both were on ordinary paths: it will not resume an id that has no transcript, and it
will not start a new conversation under an id that has one. So `teamctl destroy` in the evening and
`teamctl start fable --continue` in the morning, the most ordinary way back, gave a lead that exited
at once: the record was gone, a new id was minted, and the CLI was asked to resume it. Now the lead's
id is kept with the team, an agent that never spoke starts fresh under its id, a team with no id on
record keeps the old `--continue` (with its warning), and `tests/stub-agent` refuses what the CLI
refuses, so the suite can see these paths ([ADR-0027](adr/0027-every-agent-resumes-its-own-conversation.md)).
The same fault sat in `teamctl status`: CONTEXT was read from the newest transcript of the folder, so
every lead showed the same number. It reads the agent's own conversation now.

**"teamctl plus Tab brings nothing."** Tab completion came in the same release: one backend inside
teamctl (`teamctl _complete`, which knows the commands, their options, and the roles, teams, models,
policy keys, layouts, approvals and branches) and two thin shims for zsh and bash, so nothing is
written down twice and `tests/docs.sh` can hold the list against the option parsers. The installer
adds two lines to its block in `~/.zshrc`, and upgrades a block from before; it never switches
`compinit` on for you ([ADR-0026](adr/0026-tab-completion.md)). A teammate built it; the lead stopped
it at 255k tokens of context, before it had committed, and finished the last checks at integration:
outside a git repository it had offered nothing at all, which is where the owner pressed Tab.

`tests/smoke.sh`: 250 → 327. `tests/docs.sh`: 32 → 36. `tests/migration.sh`: 24 → 36. v1.12.0.

## 26. "A notice landed in the middle of my sentence" (v1.14)

GitHub issue #9, reported on 2026-10-09 from the owner's own lead pane:

```
i said install bun if requir[wolfmux] Beads update ... include-infraed
```

`tm_type_line` typed its notice with `send-keys -l` and pressed Enter, without ever
asking what was already on that pane's input line. Half-typed text and the notice went
off as one message, several times a day.

Two parts now. **Detect**: `tm_pane_human_busy` calls a pane busy when somebody is at it
and pressed a key within 5 s, or its input line is not empty, or it is in copy mode.
The keyboard question is answered by tmux's `#{client_activity}`, which was measured
first: on the live socket, clients that had not been touched for 19 hours read as idle
while their agents kept printing, a detached session lists no client, and `send-keys`
from outside does not move it either. So it tracks input, not output, which is exactly
the question. **Defer and collapse**: a busy pane is not typed into. The notice goes
into a per-role marker and one detached waiter looks again every 3 s for up to 10
minutes; the first idle look delivers. Beads nudges that pile up collapse into one
generic line, because that line names the whole inbox anyway; spawn, approval and
policy notices name their own event, so they queue. On expiry the marker is dropped
with `nudge-defer-expired` in the event log: nothing is lost, the bead is still in the
inbox. The per-role lock is deliberately not held across the wait, and `tm_type_line`
stays the dumb primitive it was.

Four knobs, shaped like `WOLFMUX_NUDGE_DEBOUNCE`: `WOLFMUX_NUDGE_HUMAN_IDLE` (5),
`WOLFMUX_NUDGE_RETRY` (3), `WOLFMUX_NUDGE_DEFER_MAX` (600) and
`WOLFMUX_NUDGE_COLLISION_CHECK=0`, which brings the old blind typing back. `teamctl
nudge` reports `deferred: …` and exits 3.

The first read of the machine's 13 live panes was done without `capture-pane -e`, and
that hid the thing that mattered. Read again WITH it, the `❯` is followed by a
non-breaking space, and the text beside it is dim (`ESC[2m`): it is Claude Code's own
placeholder, not anybody's typing. One pane read as `❯ close sprint 7, sprint 8 oct 9 to
15` and was written up here as "the bug caught in the act"; it was a placeholder, on a
pane with a client attached, and that claim was wrong. A pane showing the same kind of
hint with ZERO clients on its session held it for 15 minutes.

So the check has two gates it did not have at first. The input-line question only
applies when a client is attached to the pane's session: with nobody attached nobody can
be typing, and without that gate an idle agent would have been "busy" for as long as its
CLI showed a hint, every nudge to it waiting out the expiry and being dropped. And dim
runs are removed before the row is judged, because a TUI draws its placeholder dim and a
human's typing is not dim. A read that fails counts as busy when a client is attached and
as free when none is.

Three more things the first round got wrong, all found by review. A marker whose waiter
had died was never reaped, so that role was never nudged again: both call sites now reap
under the per-role lock, and the waiter ignores HUP/INT/TERM (macOS has no setsid) so a
closed terminal does not kill it. The queued fixed notices were typed in a loop with no
further checks: the pane is now asked again before every line and each line leaves the
marker as it is typed, so a stop part-way neither glues onto a human's text nor re-sends
what already went out. Measured with a watcher typing from the moment a notice appeared,
that cut the glued lines from 5 of 5 to 2 of 5 and kept the other 3 for later. **That
watcher typed with `send-keys`, which does not move `#{client_activity}`, so the keystroke
check could never fire for it and the figure bounds the input-line check alone** — a real
person also trips the keystroke check, and review round 2's more aggressive send-keys
watcher glued 6 of 6 for the same reason. Keystrokes pushed through an attached client's
own stdin would measure the real thing; that harness does not exist yet. What both runs
confirm is the part that matters: no notice delivered twice, none lost. The 300 ms
inside tm_type_line itself stays open; closing it needs tmux to report a key arriving
mid-line, and there is no such channel.

Review round 2 then reproduced the original bug on a **detached** session, so the gate
above went. "With nobody attached, nobody can be typing" is simply false: you can type a
line, not submit it, and detach. Two of this machine's sessions were detached at the time.
The input-line check now runs always and dim does all the discriminating, which the
reviewer measured against a real Claude Code in a throwaway socket: an empty input box
reads `❯<NBSP> ESC[2m Try "fix typecheck errors"` and comes back clean, a typed-in box
reads `❯<NBSP> i said install bun if requir` with no escape sequences at all and comes
back dirty. Only the keystroke check still needs a client, by construction. The round-1
reasoning for the gate is not lost — it was about an idle agent's own hint, and the dim
strip handles that. The remaining hole is a placeholder drawn in a plain colour rather
than dim, now on detached panes too, which ROADMAP names. Also in this round: a failed
`list-clients` is told apart from "nobody attached" and read as busy, so no broken tmux
read can quietly turn the checks off; `teamctl nudge` prints the marker's own cap rather
than the global one; `nudge_pending_shift_line` steps past an empty queued line instead of
eating it and stopping the delivery loop; and `nudge_pending_open`'s comment admits
notify_lead's no-lock path (benign — mkdir is atomic — but it skips the reap). And the
earlier claim that the dim hint was seen "with ZERO clients on its session" named the
wrong pane for the second time: %18 had a client, %790 was the zero-client one. The probe
above replaces that evidence.

A minor version, not a patch: the notice is no longer guaranteed to be immediate, and
`teamctl nudge` has an exit code it did not have.

`tests/nudge-typing.sh`: new, 52 checks (24 in round 1; then the dim placeholder as a
fixture row and on a live detached pane, the reaped marker, the queued fixed notices, a
human who starts typing part-way through a delivery, a half-typed line on a detached
session, and the client-list exit codes). One assertion was flipped rather than added: a
non-empty input row on a detached session used to be asserted as delivered, and now has to
defer. `tests/smoke.sh`: 327 → 327. `tests/docs.sh`: 36 → 36. v1.14.0.

Merged with main at integration, which had meanwhile reached v1.12.0 (tab completion, the
doctor probe, per-agent conversations). Five files conflicted and all five were resolved
by keeping both sides: the version line (1.14.0: the disk cleanup took that number first and the two ship as one release), the
test tables in README and VERIFICATION, one `teamctl nudge` / `restart` / `status` /
`teams` row block in USAGE, and this log's numbering. Resolving it turned up one thing
round 3 had missed: VERIFICATION still asserted the OLD rule, that a non-empty input row
with nobody attached is not a human and the notice is delivered. Round 3 reversed exactly
that, so the sentence was the opposite of the code. Corrected here. Third time a claim in
these docs was found to outlive the code it described, and all three were found by
somebody re-reading rather than by a test.

## 27. wolfmux cleans up after its own lane worktrees (v1.14)

The day wolfmux filled the disk: wolfmux had filled the machine's disk. `~/.wolfmux` had grown to
102 GB — every lane worktree keeping its own `node_modules` (2.3 GB), `.next` (0.9 GB) and
copied `public` (0.5 GB), one project with 27 lanes alive, and nothing ever pruned, not on
`stop`, not after a week parked, not on `remove`. The Mac rebooted three times, every team
died mid-task, and the recovery was a human deleting `node_modules` by hand at 100% disk
(issue #11). The tool makes those worktrees, so the tool now cleans them up.

The whole of it is one new module, `lib/disk.sh`: one allowlist of regenerable directory
names and four rules that hold for every deletion — only a name on that list, never a path
git tracks in that worktree, never a worktree with uncommitted or untracked work of its
own, and only inside `~/.wolfmux/worktrees/<project>/…` with every path resolved by
`pwd -P`. `stop` takes the build caches and keeps `node_modules` (a restart has to stay
cheap); `remove` and `destroy --worktrees` take everything; the new `teamctl prune
[--dry-run] [--keep-node-modules]` sweeps every parked lane and prints a per-lane line and
a total. `destroy --worktrees` gained the most: it used to call a worktree with an
untracked `node_modules` dirty and keep all of it for ever.

Two things were measured rather than guessed. A `du` over one real `node_modules` (69,336
files, 802 MB) takes 0.62 s warm, and over the 36 lane worktrees on this machine 12.4 s —
far too slow for `teamctl status`, so status reads a cached number that the commands which
change the lanes leave in `state/<project>/disk-kb`, and `teamctl teams` is what measures.
And an interrupted cleanup: each directory is renamed inside its own worktree before it is
deleted, so a kill halfway through leaves a `.wolfmux-removing-*` the next run clears, never
a `node_modules` that is half there and looks installed.

Also new: `teamctl spawn` checks free disk first and refuses under `disk-min-gb` (default
20 GB — about seven more lanes' worth of room, with several gigabytes left for macOS
itself), naming `teamctl prune --dry-run` as the next step; `disk-guard` can make that a
warning or switch it off; and `spawn --link-node-modules` (or `policy link-node-modules on`)
points a new lane's `node_modules` at the project root's copy instead of installing 2+ GB
again. That one is off by default on purpose: it is ONE directory for every lane, so an
install in any lane changes the dependencies of all of them.

`tests/disk.sh`: new, 48 checks. `tests/smoke.sh`: 181 → 181 (the policy-defaults check now
names the three new keys). `tests/docs.sh`: 28 → 28.

Review found two blockers in it, both one line, neither a wrong-deletion path (a reviewer
drove the code at the project root, `../..`, `/`, an empty path, a deleted `.git`, an
exported `GIT_DIR`, symlinked `node_modules` and two concurrent prunes, and could not make
it delete anything it must not). First: `policy_valid` accepted `08`, `test -le` read it as
base ten and shell arithmetic read it as octal, so one typo made every `teamctl spawn` in
that team die with a raw bash error — and `010` was quieter, printing `010` while enforcing
8 GB. A leading zero is now refused, and the one arithmetic site uses `10#` as well.
Second: a `--link-node-modules` symlink is untracked when `.gitignore` says `node_modules/`
with the trailing slash, which is the common form, so `wt_dirty_count` called the lane dirty
and `remove` pointed at `--force` — the discard-work door — for a lane the new flag had
made; the same happened to a lane holding interrupted-cleanup trash. The first fix ran the
allowlist pass before the dirty check, the way `destroy --worktrees` already did — which
worked, but meant a `remove` typed on the wrong role printed "nothing was removed" after
that lane had already lost its `node_modules`. So the question changed instead of the order:
a new `disk_work_dirty_count` counts every uncommitted entry EXCEPT an untracked one that is
only build output, `remove` decides refuse-or-remove from that, and the sweep happens per
lane once that lane is actually going. A command that refuses now leaves the lane exactly as
it found it, "nothing was removed" is true, and the `du`-before reporting is unchanged.
`wt_dirty_count` keeps its old meaning for the `status` and `worktrees` tables, which answer
a different question.

Four more from the same review: `prune` no longer decides a lane is parked from the tmux
lookup alone (it also reads the record's state and pane id, and refuses the whole sweep when
the two disagree while the session is up — a wrong "parked" takes `node_modules` out from
under a running build); the cached size now rejects a stamp in the future, which used to
stay "fresh" for ever after a clock jump; `disk_confined` no longer treats another team's
lane as the first team's, so the sentence in this file and in ARCHITECTURE is true for the
default team too; and `tests/disk.sh` runs the libraries under `set -euo pipefail`, which is
`bin/teamctl`'s own line and is why a green suite had missed an arithmetic abort.

What the review also measured, and what is now in ROADMAP as a known gap: of 25 GB across
the 38 lane worktrees on this machine, only about 4 GB was on the allowlist. The rest is
files git tracks — one project copies 530 MB of `public/` into every lane, about 0.65 GB per
lane before anything is installed — so `prune` now prints that floor and says that
`teamctl remove <role>` is the only thing which gives it back. And nothing yet drains a lane
that has been parked for days: `stop` leaves `node_modules` on purpose.

A re-review then found four small things, all fixed. The "still held" line left out the two
kinds of lane that hold the most: `prune`'s running and skipped branches returned before the
floor was added, so three lanes actually holding 1,240 KB reported 12 KB — in the 27-lane
case the difference between "18 GB is stuck in tracked files" and a number near zero. It now
adds the whole remaining size of every lane it skipped or left running, and says so. A
leading zero in `state/<project>/disk-kb` printed `08: value too great for base` from a block
whose whole job is to fall back silently; each field is now validated on its own, no leading
zero, with `10#` on the arithmetic as well. `disk_work_dirty_list` gained the `|| true` its
sibling has. And three test gaps closed: the post-reboot `prune` path — no session, records
still claiming `running`, which is the exact state this machine was left in three times and
the single most important thing `disk_lane_running` decides; a check that claimed to cover a
stored record but only set the environment variable; and the floor and skipped-size checks,
which asserted a shape (`[0-9.]+ (KB|MB|GB)`) and are why the still-held bug passed a green
suite — they compare values now.

One narrowing came with it. `disk_work_dirty_count` had widened `remove` past the two cases
that motivated it: a lane holding an untracked, unignored `dist/deploy.sh` that somebody
wrote by hand was removed without the "still holds work" question. `build`, `dist` and
`target` are now work when git neither tracks nor ignores them (WOLFMUX_WORK_LIKE_DIRS);
`node_modules`, the caches and our own trash stay not-work, which is what fixed the
`.gitignore`-with-a-trailing-slash leak and was the point of the change. `prune` is
unchanged there and still sweeps such a lane — it has no question to ask — which ROADMAP
records as the one inconsistency.

`tests/disk.sh`: 48 → 93.

Version 1.14.0. Main was already 1.12.0 when this branch was written, and a new command plus
three policy keys is a minor bump on its own merits. The nudge-typing fix (entry 26, PR #10)
was briefly numbered 1.13.0 while the two branches were in flight; both landed in the same
release, so 1.14.0 is the one number for the pair.

Merging v1.12.0 in found one thing four reviews had not: `destroy --purge` did not delete
`state/<project>/disk-kb`, so a named team's state directory was never empty and its
`rmdir` quietly did nothing. Main's new founder test asserts that directory is gone, and it
failed. The purge removes the file now, and `_purge_report` counts it. Rule 4 also had to
learn about `spawn --repo`, which main added: a lane's worktree is checked against its own
repository's worktree directory (`worker_trees_dir`), not blindly against this project's, so
a cross-repository lane is cleaned instead of skipped. And `--link-node-modules` links the
lane to its own repository's `node_modules`, which is only ever a brand-new worktree:
`--from-worktree` hands over one that already has the dependencies it installed, and that
handover is not asked to clear the free-disk bar either, because it installs nothing.

A lane in another repository is the highest-stakes path here — a deletion inside a worktree
of a repository that is not the project — so it got its own fixture: a second throwaway
repository, with its own `node_modules` and its own path with a space in it. `stop`, `prune`,
`remove` and `--link-node-modules` are all exercised against it, in the same sweeps as this
project's own lanes, and rule 4 is asked the hostile questions there too (that repository's
root, its worktree directory, a parent traversal, and the lane measured against the wrong
prefix — all refused, its `node_modules` intact). Writing it found one more inherited bug:
`teamctl remove` read the teammate's repository out of the registry *after* deleting the
record, so the `in <repository>` it meant to print was always empty. The value is read while
the record still exists now.

## 28. CONTEXT divides by a 200k guess (v1.14.1)

`model_context_window()` in `common.sh` had one real rule and one accident wearing a rule's
clothes: a provider row declares its own window (`PROVIDER_CONTEXT`), a model id ending in
`[1m]` means 1M — and everything else, with no exception, was counted as 200,000. That
"everything else" covered `fable`, `opus` and `sonnet` too, because nothing in the model
table had ever said what their windows actually are. Opus 5's id is `claude-opus-5`; it does
not end in `[1m]`; it was counted as 200k. `teamctl status` showed agents at 106%, 114% of a
window they were nowhere near — the token side was right (one team checked an agent against
its own transcript: `input_tokens` + both caches summed to exactly what status showed, and
that request had succeeded, which a 200k-window model could not have accepted), so the
denominator was what was wrong. Haiku's id does not end in `[1m]` either, and it was *also*
counted as 200k — which happens to be its real window. One of our four Claude models made
the fallback look correct, and that is the whole reason nobody caught the other three until
an Opus agent went far enough past 200k for the lie to become visible to a human watching
`teamctl status`.

Two numbers must never be read as the same kind of fact here. The four Claude keys —
`fable`, `opus`, `sonnet`, `haiku` — are **measured**, not just taken from a table: every
Claude transcript on the machine (9,239 files) was scanned for the largest prompt each model
id actually *accepted* (`input_tokens` + both caches, on a request that succeeded), which is
a hard lower bound on that model's real window. Opus 5 997,197; Fable 5.1 993,042; Sonnet 5
566,379; Haiku 4.5 199,238 — never once above 200,000 in 9,239 transcripts, which is the
measurement that clears haiku of the bug entirely. Anthropic's own model table says 1M for
all three of the first group, and the measurements agree everywhere they can reach it; for
sonnet the measurement only proves "at least 566k" — its 1,000,000 comes from the table, not
from anything seen on this machine, and the table below says so rather than implying the
measurement reached further than it did. A provider row's window (`PROVIDER_CONTEXT`: glm,
kimi, moonshot, deepseek, minimax, qwen) is a different kind of number again — **declared**
by us in `lib/providers.sh`, because it is what we tell that provider's CLI to serve, not
something read off a transcript. Kimi k3 was measured at 301,248 against the 1,048,576 we
configure there, which proves nothing about whether 1,048,576 is correct; it only shows that
nobody has filled it that far yet. GLM is declared the same way (`PROVIDER_CONTEXT="200000"`
in the glm provider row) and has no measurement to compare it against at all — no GLM model
appeared anywhere in the 9,239-transcript scan, so "declared, not measured" is not a hedge
for GLM, it is the only kind of fact there is. `glm53` and `flash` in the model table take
their window FROM that row (`wolfmux_provider_info glm` at lookup time) rather than
repeating the number: a second literal in `common.sh` that happened to agree with the
provider table today would have been the same bug, one step quieter, the day the two drifted.

| key | measured (this machine, 9,239 transcripts) | window set | source |
|---|---|---|---|
| `opus` | 997,197 | 1,000,000 | measured + table agree |
| `fable` | 993,042 | 1,000,000 | measured + table agree |
| `sonnet` | 566,379 | 1,000,000 | table (measurement proves only ≥566k) |
| `haiku` | 199,238 | 200,000 | unchanged — this is the one the old fallback got right |

The fix gives the model table its own field, `MODEL_CONTEXT`, set per key next to the label
it belongs to — one place to change when a model's window changes, same shape as the
provider table's `PROVIDER_CONTEXT`. `model_context_window()` now returns the provider's
number, the model table's number, or 1M for an `[1m]`-suffixed pinned id, in that order —
and for everything else (a pinned `claude:<id>` / `codex:<id>` without the suffix, `astra`,
anything it does not recognise) it prints nothing and returns 1. It never falls back to a
number again. The one other place that fallback had a second, independent home was
`agents.sh`'s `agent_context`: `[ -n "$CTX_WINDOW" ] || CTX_WINDOW="${computed:-200000}"` —
the same `:-200000` shape, reachable even when `model_context_window` itself did the right
thing. `CTX_WINDOW` now stays empty when the window is unknown, which is the only way a
fix to the function alone could not have been silently undone one call site later.

A first version of this gave `glm53` and `flash` their own `MODEL_CONTEXT="200000"` literal
— the number they already got by accident, now written down on purpose, which was still
wrong: it put the same fact in two places (`providers.sh`'s `PROVIDER_CONTEXT="200000"` for
the glm row, and this new literal), with nothing to keep them in step. Review caught it
before it shipped. Those two arms now call `wolfmux_provider_info glm` and take
`MODEL_CONTEXT` from that row's `PROVIDER_CONTEXT` at lookup time, because `glm53` and
`flash` are not themselves provider-table keys (`model_context_window`'s own provider
branch resolves on `${key%%:*}`, and that is `glm53`, not `glm`, so it never fires for
them) — one source of truth for a number two code paths both need.

`ctx_display()` in `views.sh` decides what an unknown window looks like: when the window is
0 or empty there is nothing to be a share of, so it prints the tokens alone (`213k`), never
`213k 0%` — a wrong percentage reads as more confident than no percentage, and 0% is still a
percentage. `status --json` keeps `context_tokens` and reports `context_window: 0`; it was
already built to render `0` for an empty value, so the one change needed there was not
feeding it a guessed `200000` any more.

A first pass at the tests proved only the JSON field, with every planted record pointed at a
`workdir` that does not exist (`context_tokens` null, so no percentage was ever rendered for
any of them) — exactly the shape that would keep passing if a 200k denominator came back
tomorrow and nobody noticed, because nothing had asserted the one number a human actually
reads. `tests/smoke.sh` gained six checks in the end, covering both the direct lookup and the
`agent_context` path `status` actually calls: the model table's own number for each of the
four keys; that `glm53`/`flash` take theirs from the glm provider row rather than a second
literal, asserted against that row's own `PROVIDER_CONTEXT` so the check follows a future
change to it instead of failing on one; that a pinned id with no `[1m]` suffix and `astra`
both report `context_window: 0`; that the CONTEXT column and the `context` field of
`status --json` show tokens with no `%` sign when the window is unknown; and, with a real
transcript this time, that 232,010 tokens — the exact request another team measured on a
live Opus 5 agent — renders `232k 23%` on opus's 1,000,000-token window (`116%` under the old
200k fallback), with a 150,000/200,000 haiku conversation rendering `150k 75%` alongside it
so the one model whose window did not change is pinned by a rendered percentage too, not only
by a JSON field. `tests/smoke.sh`: 327 → 333. `tests/docs.sh`: 36 → 36 (no new command,
option, policy key or model key — the four keys already existed, only their declared window
changed, and GLM's was made to read from one place instead of two). v1.14.1.

## 29. The crash check lies when the suite is launched under nohup (v1.14.2)

`tests/smoke.sh`'s check for issue #6 (a crash is never silent) was five assertions
chained behind one description, sharing one pass/fail outcome: the exit handler's trap
line is installed, SIGPIPE gives 141 with a message naming the signal and the command, a
plain failure is silent and exits 3, Ctrl-C is silent and exits 130, and a closed terminal
exits 129 and adds no "stopped unexpectedly" line. Two teams lost about an hour to this on
the same day, because `check()` discards all output and prints only the description on a
FAIL: the one line told them a crash check had failed, nothing about how far it got.
`wolfmux-ux`'s lane supplied the counter-example that killed the first hypothesis (a race
in `lock_release`) and pointed at the real cause: the lane had launched the suite under
`nohup`.

Under `nohup`, SIGHUP is set to be ignored before the shell starts, and a child process
inherits that disposition — it cannot be killed by SIGHUP, so the fifth assertion's own
child survives, prints `finished`, exits 0 instead of 129, and the chained check reports
one opaque FAIL. Measured, same machine, same tree:

| launch | plain | INT (Ctrl-C) | HUP (closed terminal) |
|---|---|---|---|
| run directly | `rc=3 len=0` | `rc=130 len=0` | `rc=129 len=53` (`Hangup: 1 …`) |
| under `nohup` | `rc=3 len=0` | `rc=130 len=0` | `rc=0 len=8` (`finished`) |

An inherited `SIG_IGN` cannot be undone by a `trap` inside the process — that is what
"inherited" means — so the fix does not try to reset it. It detects it instead, but not
with `trap -p HUP`: newer bash marks a signal that arrived already ignored with a phantom
trap of its own, and `trap -p HUP` prints `trap -- '' SIGHUP` for that case there — but
this machine's `/bin/bash` is 3.2.57, the one macOS ships, and 3.2 prints nothing for
`trap -p HUP` either way, ignored or not (confirmed directly: `nohup bash -c 'trap -p
HUP'` prints nothing on this box, while `nohup bash -c 'bash -c "kill -HUP \$\$;
echo survived rc=\$?"'` does print `survived rc=0`, so the signal itself is neutered even
though the trap table says nothing about it). Predicting the outcome from `trap -p` is
exactly the kind of fact this bash cannot give up, so the fifth assertion reads its own
probe's result instead of guessing ahead of it: rc 129 with no "stopped unexpectedly" line
is a pass; rc 0 with `finished` printed is the known-neutered shape, and is skipped, with
the reason printed (`SKIP ... (SIGHUP arrives ignored — launched under nohup?)`); anything
else is a genuine FAIL, so a real regression in the handler still has somewhere to show up
under nohup instead of being swallowed by the skip.

The other four assertions are unchanged in substance, only split into their own `check()`
calls so a failure now names which one broke. Proved deliberately: `teamctl_on_exit` in
`common.sh` was edited to also exclude 141 from the "stopped unexpectedly" branch
(`[ "$rc" -ne 141 ]` added alongside 130 and 129); against that regressed tree the SIGPIPE
assertion's own check — "SIGPIPE gives 141 and the message names the signal and the
command" — failed on its own (`PIPE rc=141 out=[]`, no message), while the trap-install,
plain-failure and Ctrl-C assertions stayed green, confirming they test something that
regression did not touch. Reverted before committing; `git diff` on `common.sh` is empty
of that change.

`tests/providers.sh` already had a `skip()`/`skipped` idiom (used when the owner's own
`WOLFMUX_METERED` gate cannot be held closed for a check); `smoke.sh` had none, so it
gained the same shape rather than a second one: `skipped=0`, `skip() { skipped=$((skipped
+ 1)); printf '  SKIP  %s\n        (%s)\n' "$1" "$2"; }`, and the final line now reads
`result: $passed passed, $failed failed, $skipped skipped`. `tests/smoke.sh`: 333 → 337
(the one check became five), 336 pass + 1 skip under `nohup`. v1.14.2.

## 30. `--dangerously-skip-permissions` does not switch off the auto-mode classifier (v1.14.3)

Bypass mode auto-approves ordinary permission checks, but it runs apart from Claude Code's
auto-mode classifier and overrides only `safetyCheck`-class classifier decisions; a decision
such as "External System Writes" still denies the call while the permission is still being
decided as `ask`. This hit the project-management lead's Jira "Complete sprint" click twice;
a restart of the agent was tried as a workaround and did not fix it, which is itself evidence
the behavior is not version drift — the relevant code is byte-identical between Claude Code
2.1.295 and 2.1.296. The classifier never runs once a `permissions.allow` rule resolves the
call before it is asked.

New team policy key `browser-writes`, `ask` (default) or `allow`, following the exact shape
of the existing keys (`policy.sh`: `POLICY_KEYS`, `policy_default`, `policy_valid`,
`policy_choices`, the `teamctl policy` listing). `allow` adds one line to the jq merge
`write_agent_settings` (`agents.sh`) already builds per agent — `permissions.allow:
["mcp__claude-in-chrome__*"]` — applied to every agent of the team, lead and workers alike;
`ask` leaves the settings document byte-identical to before this key existed (a test: no
`permissions` key at all). Default is `ask`, not `allow` for every skip-mode agent, because
the rule also removes the External System Writes check for every Chrome write that team's
agents make from then on — a deliberate, team-scoped trade, not a blanket exemption.

A second team's review of the same function caught a trap before merge: the new arm and the
existing role-level `PermissionRequest` hook arm (`$mode == "lead"`) have near-identical
purposes and sit in the same jq chain with different guards — a careless future edit could
treat them as duplicates and hoist one out of its guard or drop it, and either failure reads
fine in a diff. Fix: the jq argument is named `$browser_allow` (nothing in the name reads as
"permission"), with a comment at its arm saying what it is *not*. The test suite was
widened from 2 checks to the full 4-row cross-product (role × worker-permissions mode ×
team policy) with an exact array comparison, never `contains` or a regex — row 3 (a
lead-mode worker in a default-policy team: hook present, no `permissions` key at all) is the
one a hurried merge breaks and the one nothing in the suite covered before this.

Building that cross-product surfaced two bugs of its own, confirming the review's point that
four checks catch what two cannot:

- **A no-op wait reads a file before the restart that was supposed to change it finishes
  writing it.** The settings document is rewritten by the respawned pane's own process,
  asynchronously from `teamctl restart` returning; the first version of the wait helper
  polled only "does the file have a `permissions` key", which rows 1 and 2 never change
  (they toggle `worker-permissions`, which changes the `PermissionRequest` hook, not the
  permissions key) — so the wait returned immediately, before the restart had actually
  rewritten the file, and the check could have passed by reading stale content. Fixed by a
  generic `wait_for <file> <jq-filter>` that polls the exact condition each check needs,
  never a blanket "settled".
- **`/bin/bash` 3.2.57 (this machine's shell, which the whole project is written for) mis-parses
  a comma-bearing jq object-construction shorthand three quoting levels deep inside an
  `eval`'d check string.** `jq -c "{env, hooks}" "$(bw_settings lead)"`, embedded inside
  `"$(...)"` inside a single-quoted `check()` argument, silently split into two separate jq
  invocations despite the quoting — `jq -c env FILE` (which, by accident, calls jq's own
  builtin `env` filter and prints the whole process environment) and `jq -c ' hooks' FILE`
  (a compile error, "hooks/0 is not defined", empty output) — never the single `{env,
  hooks}` filter actually written. A single-key filter with no comma, such as `{allow:
  [...]}`, is unaffected. This is the second `/bin/bash` 3.2 trap this repo has hit in one
  day, after issue #17's `trap -p HUP` not reporting a signal that arrived already ignored:
  the pattern is the same both times — a fact 3.2 cannot give up through its ordinary
  introspection (`trap -p`) or, here, through ordinary quoting rules once `eval` and nested
  command substitution are stacked deep enough. Fixed by never writing a comma-bearing
  `{a, b}` jq filter inline inside an `eval`'d string again: a plain, never-`eval`'d helper
  function (`env_hooks() { jq -c '{env, hooks}' "$1"; }`) holds the filter instead, and the
  check calls the function.

`tests/smoke.sh`: 337 → 347 (defaults, the round-trip, the invalid-value refusal, the two
allow-shape checks, and the 4-row cross-product), 346 pass + 1 skip under `nohup`
(unrelated, issue #17). `tests/docs.sh`: 36 → 36 (no new command, option or category — one
new policy key named everywhere the existing ones already are). v1.14.3.

## 31. The sibling check asserted a disposition the launch had already removed (v1.14.4)

v1.14.2 fixed the closed-terminal check and left its Ctrl-C sibling, two lines above it,
asserting the same kind of fact: that the test's own child can be killed by a signal it
sends itself. It can't, in the shape the fix was written for. A background job started from
a non-interactive shell inherits SIGINT and SIGQUIT as `SIG_IGN`, and `nohup` is not
required for that — a plain `&` is enough — so the Ctrl-C check reports a bare FAIL under
exactly the launches v1.14.2 taught the SIGHUP check to explain. Measured with
`signal.getsignal` in each shape rather than inferred: plain foreground HUP default / INT
handled / QUIT default; `nohup … &` all three ignored; plain `… &` INT and QUIT ignored,
HUP still default.

The fix is the SIGHUP arm's shape, one signal over: read the probe's own result and branch
on it — pass on 130 with no output, skip with the reason when the child survived and printed
`finished` instead, FAIL otherwise. No new detection mechanism was added, because the one
v1.14.2 had already rejected (`trap -p HUP`) fails here for the same reason: this `/bin/bash`
(3.2.57) prints nothing for a signal that arrived already ignored.

What generalises past this fix is the expectation, which is now written as a rule in
`VERIFICATION.md` rather than as a skip count: **one skip per signal the launch leaves
ignored**, over the set {HUP, INT, QUIT}, with `nohup` accounting for HUP and a bare `&`
accounting for INT and QUIT. A count would have been falsified by this very commit; the rule
survives it, and survives the next signal anyone adds to that family (whose arm has to be
written the same way — the comment at the HUP arm says so). The same reason puts the launch
shape next to every measured figure in that document: the total check count does not move
here, but the split between passed and skipped does, so a figure quoted without its shape is
a figure the reader cannot reproduce.

A check that is reliably wrong is worse than a missing check: it is read as a defect in the
system under test, and the cost lands on whoever next runs the suite in good faith, not on
whoever wrote the check. Both arms of this family now report what they observed instead of
what they assumed.

`tests/smoke.sh`: 347 → 347 (one `check` became one if/elif/else that reports pass, skip or
FAIL — no assertion gained or lost). v1.14.4.

## 32. "These messages should be hidden" (v1.15.0)

An adversarial review of the finished branch found one more class of bug than the design
review had, and it is worth recording which kind: not a wrong decision, but a PROXY
standing in for the state it was supposed to represent. `WOLFMUX_NUDGE_TYPE=off` asked
`inbox_type_allowed`, which the approval override never passed through, so the one knob
whose whole job is silence still typed. The approval grace asked whether the human had
read the notice when the question was whether the worker was still blocked. Both read
correctly and both were wrong. The fix in each case was to ask the state itself.

The other finding worth keeping is that `inbox_take_undelivered` moved its awk output over
the record unguarded while its two siblings in the same file chained with `&&` — so the
one function that could destroy notices was the one that looked most like the two that
could not. Consistency inside a file is evidence, and a sibling that breaks it is where to
look first.


Entry 26 stopped a notice landing *in* a half-typed line. This is the complaint
underneath it, GitHub issue #11, in the owner's own words on 2026-10-10:

> regarding wolfmux there is another issue, i dont want to keep seeing these updates in
> the mid of my convos these messages should be hidden and there could be some idication
> here that message received or something and expand like a bird carrying letter emoji

A notice typed into the lead's pane perfectly is still an interruption, because that
pane **is** the conversation. So typing stopped being *the* channel and became one of
five. Every notice is now appended to `$STATE_DIR/inbox/<role>` before anything else is
decided about it, and read from there by the status-bar count, the `prefix N` popup, one
desktop notification, the agent's Stop hook, and — where it is still right — typing.

**The state column is two letters, and that was the design decision.** A notice has two
readers who want opposite things: the human wants to know mail arrived and to read it
when he chooses; the agent needs the text as input or it never runs the command. The
first draft had one state and it was wrong in both directions — handing the notice to the
agent cleared the human's badge, and the human reading it hid the notice from the agent.
`nu`/`nd`/`su`/`sd` keeps them independent, and `tests/inbox.sh` asserts both directions.

**The hole a reviewer found, and the two things that close it.** A Stop hook fires when a
turn ends and `UserPromptSubmit` when somebody submits. **Neither fires for an agent
sitting idle.** A bead landing for an idle lead with the human away would have waited
until a human typed — which had already been rejected once, in round 2 of the v1.14.0
review, for a popup proposal. The fix reuses v1.14.0's own measured fact: a detached
session lists no client at all, so "is anybody watching" is one cheap tmux read. With
nobody watching, the lead's pane is typed into exactly as before — nobody is looking, the
line only goes to scrollback, and the agent wakes at once. With somebody watching, the
badge carries it and the hooks deliver it. What is left is named rather than hidden: a
client attached, the human looking at another pane, the lead idle. The mitigation is one
desktop notification through the notifier that already existed (`notify_deliver`), so
nothing new was built and nothing reaches the conversation.

**That notification nearly became the same complaint with a different sound.** The first
version debounced it with `WOLFMUX_NUDGE_DEBOUNCE`, which is 3 seconds — sized for typing
one cheap line into a pane. A macOS banner is not cheap: it interrupts whatever you are
doing, and this machine runs three projects and twenty-five teams whose Beads events fire
on create, update and close. At 3 seconds a busy hour is dozens of banners. It now has
its own knob at 120 seconds per role and **collapses**: one banner carrying the count out
of the file ("default/lead: 4 notices waiting"), never one per bead. Ten beads inside two
minutes raise exactly one, and `tests/inbox.sh` checks that number.

**Two things measurement decided rather than preference.** The emoji: the owner asked for
"a bird carrying letter", and U+1F54A DOVE is neither `Emoji_Presentation` nor East Asian
Wide — it needs U+FE0F to draw as an emoji at all and tmux miscounts its width, which
pushes the rest of the status line about. U+1F4E8 INCOMING ENVELOPE is both, so it gets
two cells with no variation selector; `WOLFMUX_INBOX_MARK` is there for anybody who wants
the bird and will accept the alignment. And the key: the brief said `prefix I`, and
`tmux -L wolfmux list-keys` said `I` was already `run-shell …/tpm/bindings/install_plugins`.
`config/wolfmux/tmux.conf` sources the user's own `~/.tmux.conf` **first**, so every
wolfmux binding comes later and wins inside the wolfmux server: binding `I` would have
taken TPM's key away in silence. `prefix N` instead, and the general fact is now a row in
TROUBLESHOOTING.

**Approvals were the one thing allowed to stay loud.** A permission request holds a
*worker* until the lead answers, which is why its deferral cap is 60 s and not 600. A
detached lead is typed into at once as before; an attached lead gets the louder `🔔` mark
immediately, and if the request is still unread 20 s later it is typed in after all,
through the same busy-and-park machinery as everything else. An approval is the one notice
that can still put a line in the human's conversation, and a blocked worker is the reason.

**A Codex lead is deliberately noisier than a Claude lead.** Codex has no hooks, so for an
`astra` lead typing is the only channel that reaches the agent at all; silence there would
mean it never learned about a bead. That row is in the ARCHITECTURE table so the next
reader does not "fix" the inconsistency.

Three things found by writing the tests rather than by reasoning: this machine's `awk` is
the one true awk and has no `strftime`, so the listing formats its timestamps with
`date -r` in a read loop; `grep -c pattern file || printf 0` prints `00` on no match,
which made an assertion pass for the wrong reason; and `notify_deliver` writes OSC 9 with
no newline, so several banners land on one line and have to be counted as occurrences.

**One class of error cost four messages, and none of it was in the code.** Three readings of
the same two test comments disagreed. The first said the function they name had been deleted:
it had grepped names out of removed lines, which conflates a call with a definition, and its
grep had silently searched one of the three directories it named. The second said the function
still exists, so the comments must be true: it had read a definition and inferred a caller.
The third traced `teamctl nudge lead` through `cmd_nudge` to `_nudge_one` and found the tests
never reach that function at all, which is why both comments were wrong and why neither of the
first two reasons was the reason. Only the trace settled it. The lesson generalises past this
file: a comment that names the COMMAND a test runs cannot go stale this way, while one that
names a function further down the chain will, the next time anybody edits the chain. The
pattern was named by the team that had just been wrong about it in the opposite direction.

`tests/inbox.sh`: a new suite, 102 checks. `tests/nudge-typing.sh`: 52 → 56, with 36 lines
added and none deleted, so no existing check was removed or re-aimed. `tests/smoke.sh`:
347 → 348 (one check added for the inbox hooks surviving `WOLFMUX_NOTIFY=lead`), 347 pass +
1 skip under `nohup`. 818 checks across the eight suites, smoke counted once in its clean
shape, 818 passing. Measured at `9d9f84b`, base v1.14.4 (`529936e`): the smoke pair in a
clean launch with SIGHUP and SIGINT reset to their defaults, the rest in an earlier
acquisition on the same commit, after the first smoke pair was voided by an inherited SIGINT
disposition — a detached launch can leave {HUP, INT, QUIT} ignored, and an inherited
`SIG_IGN` cannot be undone from inside the process. The void run's own arithmetic confirms
nothing was dropped: 347 passed + 1 failed = 348, the same total the corrected run measured.
v1.15.0.
## 33. "I need a team overview and status button" (v1.16)

The owner, on 2026-10-10: *"also i need team overview and status button here to see the
total number of teams and everything working and how much resources they consuming like
dashboard kinda thing"*. Several teams were running at once across more than one
repository, and `teamctl status` and `teamctl teams` each answer for ONE project — the one
you are standing in.

New module `config/wolfmux/lib/dashboard.sh`, one command `teamctl dashboard`, one internal
`teamctl _overview-badge` for the status bar, and `prefix O` to open the popup. Read-only:
it takes no action on any team. Full description in
[ARCHITECTURE.md](ARCHITECTURE.md#the-dashboard-one-view-of-the-whole-machine).

### What the measurements changed about the design

Three numbers did most of the designing, and each one is in the code as a comment because
the next reader will otherwise undo it:

**A `du` over this machine's lane worktrees is about twelve seconds.** That is already why
`teamctl status` never measures. A view that redraws can afford it even less, so lane
totals are the number `teamctl teams` left behind, under the same fifteen-minute rule, and
the view shows a stale number *as stale* with its age rather than refreshing it.

**The first popup took 6.17 s, against a 2 s budget.** The cause was not the work, it was
the process count: `reg_list` spawns a `jq` per agent record to sort them, `reg_field` one
per field, and `team_orphaned` asks tmux three times per team. Seven fields across 74
agents is about 600 processes. Every one of those helpers is correct and right for the view
it was written for — one team, where a process per field is invisible. So four of them got
a bulk equivalent in `dash_team_records`, `dash_teams`, `dash_orphaned` and
`dash_pane_row`, and `tests/dashboard.sh` asserts each one still agrees with the helper it
stands in for. 6.17 → 2.54 s on the bulk record read; 2.54 → 1.5 s on fork-free pane and
team lookups plus reading per-agent transcripts only for agents that are RUNNING.

**The segment costs 18 ms of work, inside 82 ms per invocation.** The other 64 ms is
`teamctl`'s own startup — sourcing the eighteen library files held when measured, nineteen on this base — which every `teamctl` command
pays and which this feature did not add. Worth knowing before anyone optimises the badge
again: there is almost nothing left in it to win.

### The things it deliberately does not say

The request was to see "everything working", and the honest answer is that nothing on this
machine can tell a waiting agent from a working one. `#{pane_activity}` came back **empty**
from the live tmux (3.7c), a whole team shares one window so `#{window_activity}` cannot
speak for one agent, and both states run `node`. `lib/views.sh` forbids parsing pane output
for state. So there is no "idle" column. Instead there are two measurements under their own
names: `cpu`/`mem`, the agent's whole process tree — a process reading, not a claim about
what the agent is doing — and `wrote`, the mtime of the very transcript file the context
reader opened, which is a file timestamp and nothing more. It moves on every turn an agent
takes, which is what makes it the useful column.

The same principle settled the context column, and independently settled an argument in the
v1.14.1 branch: **show what is known, say nothing where it is not, never a number that
looks precise and is not.** Where a model's context window genuinely cannot be known the
column shows the token count and no percentage, rather than a share of a guessed 200k.

### Two things that were wrong before the tests caught them

`skipped_projects` was always empty. The loop that built the output was the left side of a
pipeline, so everything it assigned — including that list — stayed in the subshell and
never reached the JSON. A project whose state could not be read therefore vanished without
a word, which is the one thing a view of "every team on this machine" must not do. It is
collected into a variable now, and an unreadable project and an empty one are reported
*separately*, because "I cannot read this" and "there is nothing here" are different things
to tell whoever is looking.

The project root is read from the first readable `meta.json` **including a team's**. The
project-level one belongs to the default team and is simply absent on a project that only
ever had named teams — which was true of every project on this machine, so the first
version found no root anywhere and skipped all three.

### Changes outside the new module

Kept as small as possible, since two other branches were in flight on the same files:

- `lib/agents.sh`: four lines. `agent_context` and both context readers now record the file
  they opened in `CTX_FILE`, so the `wrote` column reuses that lookup instead of a second
  piece of code working out where a transcript lives.
- `lib/common.sh`: line 5 only, `WOLFMUX_VERSION` to 1.16.0.
- `bin/teamctl`: the module in the source list, two dispatch cases, one usage block.
- `lib/completion.sh`: the subcommand and its options.
- `config/wolfmux/tmux.conf`: `status-right`, `status-right-length` and `bind O`.
  `status-left` and `status-interval` belong to the quiet-nudges branch and are untouched.

This release is the one that puts a SECOND `#()` job on the status line — v1.15.0's `📨`
inbox badge on `status-left`, this one's overview badge on `status-right` — so the cost is
worth stating where somebody reading this entry will meet it. The segment was measured at
82 ms per invocation, of which **64 ms is `teamctl`'s own startup** (sourcing the eighteen library files
held when measured; this base has nineteen, so the share is a floor) and 18 ms is the segment's own work. At `status-interval 5` that is two
`teamctl` invocations every 5 s per attached client, about 164 ms per 5 s per client, or
roughly 3% of one core. Nothing here is optimised for it: the cost is `teamctl`'s startup
rather than either badge's work, so the lever is a startup path that does not source all
nineteen libraries to answer a one-line read. Recorded as a limit with a named lever in
[ROADMAP.md](ROADMAP.md#known-limits-of-v1).

`tests/dashboard.sh`: 115 checks, all passing. Also in the same acquisition:
`tests/smoke.sh` 348 passed / 0 failed / 0 skipped and `tests/docs.sh` 36 passed /
0 failed. No suite total is given: nothing runs the suites as a set, so the six suites
not run here would have to be added from their own records to produce one. Measured at
`083fe9f`, base `e431740` (v1.15.0), clean
launch shape (`HUP` and `INT` reset) — see `docs/VERIFICATION.md` for why the shape is
part of the figure.

Version 1.16.0. The chain is 1.14.1 (the CONTEXT fix) → 1.15.0 (quiet nudges) → 1.16.0,
and this builds on 1.15.0.

## 34. The quiet lead was quiet about everything (v1.16.1)

Two defects, one evening, both found by measurement rather than by reading.

### The first: a filed notice never reached an idle lead

`communication-management.lead` measured it on 2026-10-12 in the owner's own teams.
`dashboard-wiring`'s lead sat idle from 13:58Z. P1 notices were sent to it at 16:13Z and
at 16:53Z. At 17:35Z it was still asleep and had received neither. Comms' own inbox showed
six notices as "NEW, not yet given to the agent". Nothing was lost — every bead was in
Beads and every line was in the inbox file — but nothing handed them over either.

The cause is an ORDER, and it is three lines of `_nudge_one`:

```
inbox_add ...                  the notice is FILED first  <- this is why nothing is lost
if ! inbox_type_allowed; then
    event_log inbox-filed
    return 4                   <- RETURNED HERE for an attached lead
nudge_begin ...                never reached
if tm_pane_human_busy; then ... _nudge_defer_start        never reached
tm_type_line                   never reached
```

v1.14.0's guarantee was "never glued onto a half-typed line, but **eventually typed**": a
waiter parked the notice and delivered it when the pane went idle. v1.15.0 put the
suppression check AHEAD of that waiter, so for an attached lead the guarantee silently
became "never typed at all". The only channel left was the agent's own `Stop` hook, which
fires on a TURN BOUNDARY — and an idle agent has no further boundary. `UserPromptSubmit`
needs a human keystroke. ADR-0028's own Context section had already written down the fact
that makes this fail ("Neither fires for an agent that is simply sitting idle") and its
Risks section named the case; the decision went ahead anyway, and the risk then happened.

The fix is the order back, plus one number. `off` and `workers` still stop at the file:
nothing is ever typed into that pane, because a knob called `off` that still types is
worse than no knob. The attached lead goes down v1.14.0's path instead, with the keystroke
window widened from `WOLFMUX_NUDGE_HUMAN_IDLE` (5 s) to `WOLFMUX_NUDGE_LEAD_IDLE` (300 s),
because that pane is the human's own conversation and five seconds of silence in it is a
pause for thought rather than an empty chair. Quiet pane: typed at once. Busy pane: parked,
and the one waiter delivers when it goes quiet. The owner's requirement — "i dont want to
keep seeing these updates in the mid of my convos these messages should be hidden" — is
what the 300 s is for, and ROADMAP now carries the other direction of that number as the
open judgement it is.

Nothing new was built. `tm_pane_human_busy` takes the window as an optional argument;
`nudge_pending_put_idle` / `nudge_pending_idle` store it in the marker, RAISE-only, so a
notice parked for the human's own pane is never delivered later under a worker's
five-second rule (the mirror image of the cap, which lowers only); the debounce, the
collapse, the reap, the heartbeat, `inbox_mark_typed` and `trap '' HUP INT TERM` are
untouched. `_notify_type_or_park` — the spawn, policy and approval lines — was deliberately
NOT changed: it is reached only when typing was already allowed, or through the approval
grace, so its 5 s window is still right, and widening it would be a separate decision on a
separate path. ADR-0029.

**Why 933 passing checks did not catch it: no suite had an IDLE agent in it.** Every
notice test drove a pane that was busy, or a pane with nobody attached. The two suites now
have both directions, with a real pty client attached and the human's eyes on the lead
pane: an idle lead pane IS typed into with no human keystroke anywhere, a half-typed line
in it is NOT and the notice arrives by itself once that line is submitted, and a human AT
that pane who pressed a key inside the window holds it back. Run against v1.16.0's tree
first, the new checks fail where they should:

```
tests/nudge-typing.sh, at f6e3698, 55 passed / 6 failed
  FAIL  a client attached + an IDLE lead pane + a bead: it IS typed, with no human keystroke
  FAIL  a client attached + an idle lead pane: the event log says the pane was quiet, not that it was filed
  FAIL  a client attached + a half-typed line in the lead pane: nothing typed, the notice is parked
  FAIL  a client attached + the pane then goes quiet: the parked notice arrives by itself
  FAIL  a client attached + the human AT the lead pane inside WOLFMUX_NUDGE_LEAD_IDLE: nothing is typed
  FAIL  a client attached + the human at the lead pane: it waits in the marker, which carries the wide window

tests/inbox.sh, at f6e3698, 96 passed / 10 failed
  (the five "attached + a quiet lead pane" checks, the five "attached + a human in the
   lead pane" checks, and the type-matrix check that calls the new predicate)
```

The third episode is measured against the real client's own `#{client_activity}` rather
than a faked keystroke, because `tmux send-keys` does not move that timestamp and so no
test can type as the human. That limit is named in `docs/VERIFICATION.md`.

### The second: the knobs could not be set at all

While working around the first defect, comms wrote `WOLFMUX_NUDGE_TYPE=all` into
`~/.config/wolfmux/config`, watched the next nudge still report `detached-lead`, and
reverted it. `WOLFMUX_CONFIG_KEYS` in `lib/provider-env.sh` is the allowlist
`wolfmux_load_config` parses that file against, and it held no `WOLFMUX_NUDGE_*` or
`WOLFMUX_INBOX_*` key: the line was read and dropped, with no error and no effect. The
knobs arrived in v1.14.0 and v1.15.0 and nobody added them. That file is the only place a
knob CAN live and still reach an agent's pane, because a pane's environment comes from the
tmux server rather than from the shell `teamctl` was typed in.

Six keys added — the ones the user documents already present as knobs somebody may set —
and the installed template, which had no notice section at all, now has one.
`git log -S WOLFMUX_CONFIG_KEYS` shows only the list's creation and the rename, so no
nudge key had been deliberately left off. The timing knobs beside them stay off on
purpose, with the reason in the comment above the list.

Nothing had ever tested `wolfmux_load_config` — which is exactly why this could sit there
for two releases. It has seven checks now, three of which fail on v1.16.0:

```
tests/providers.sh, at f6e3698, 138 passed / 3 failed
  FAIL  config: an allow-listed key is taken from the file
  FAIL  config: spaces around the = and the value are stripped
  FAIL  config: the approval knob is on the list too
```

### Kept small

- `lib/agents.sh`: the new knob with its numeric floor, `_nudge_one`'s ordering, and the
  marker's window read in `_nudge_defer_wait`. `_notify_type_or_park` untouched.
- `lib/inbox.sh`: one new predicate, `inbox_type_when_idle`.
- `lib/tmuxctl.sh`: one optional argument on `tm_pane_human_busy`, floored like every
  other numeric knob, so a caller's bad arithmetic cannot turn check (a) off.
- `lib/registry.sh`: `nudge_pending_put_idle` / `nudge_pending_idle`, mirroring the cap.
- `lib/provider-env.sh`: six names on the allowlist, and why the rest are not.
- `lib/common.sh`: line 5 only, `WOLFMUX_VERSION` to 1.16.1.

Two commits, one per defect, so a reviewer can take either without the other.

Gates, all under the heavy lock in ONE acquisition with `HUP` and `INT` reset to their
defaults by a parent that then `exec`s, at `PENDING_SHA`, base `f6e3698` (v1.16.0):
`inbox` 107 / 0, `nudge-typing` 61 / 0, `providers` 141 / 0 / 0, `smoke` 348 / 0 / 0,
`docs` 36 / 0, `disk` 93 / 0, `dashboard` 115 / 0 / 0, `migration` 36 / 0,
`permissions` 13 / 0 — 950 passing, 0 failing. `bash -n` on every changed file.
**shellcheck is not installed on this machine, so nothing in this release was linted with
it**, and no figure here stands in for that.

Version 1.16.1, a patch on 1.16.0.

## Footprint on the machine

| Created | `~/bin/*`, `~/.config/wolfmux/`, `~/.wolfmux/`, `~/.local/bin/bd`, `~/.codex/rules/wolfmux.rules`; Beads' own `~/.beads`, `~/.dolt`, `~/.config/bd` |
|---------|------|
| Modified (backed up) | `~/.zshrc` (one block), `~/.claude/settings.json` (4 allow rules, 1 ask rule; 9 before v1.8) |
| Deliberately not created or touched | `~/.tmux.conf`, `~/.zprofile`, any CLAUDE.md / AGENTS.md, `~/.codex/config.toml`, `~/.codex/rules/default.rules`, git config, any project's `.gitignore` |
