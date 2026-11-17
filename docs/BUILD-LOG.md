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
defaults by a parent that then `exec`s, at `19e6d4c`, base `f6e3698` (v1.16.0):
`inbox` 107 / 0, `nudge-typing` 61 / 0, `providers` 141 / 0 / 0, `smoke` 348 / 0 / 0,
`docs` 36 / 0, `disk` 93 / 0, `dashboard` 115 / 0 / 0, `migration` 36 / 0,
`permissions` 13 / 0 — 950 passing, 0 failing. `bash -n` on every changed file.
**shellcheck is not installed on this machine, so nothing in this release was linted with
it**, and no figure here stands in for that.

Version 1.16.1, a patch on 1.16.0.

## 35. "Why is the space hoarding not built in?" (v1.17.0, stage 1)

Ammar, 2026-10-13 03:3xZ: *"why this is not an inbuilt thing that once the work is complete
the team has to destroy the worktree to reclaim space why the space hoarding"*.

The honest answer is that v1.16.1 had the cleanup and not the reclaiming. `teamctl prune`
worked, every rule in `lib/disk.sh` held, 93 checks covered it — and the machine filled up
anyway, because `prune` had to be *asked*. Measured at 03:12Z: **90.3 GB** under
`~/.wolfmux/worktrees`, **50.9 GB** of it build output. A command nobody runs reclaims
nothing. `docs/ROADMAP.md` had carried this as a known gap since v1.11 and described the
fix as "draining by age"; the fix is simpler than that — do it when the lane is parked,
because that is the moment the build output stops being useful.

Stage 1 is the three parts that cannot lose work. Removing a lane's tracked files can, so
it is stage 2 and it has its own gates.

### 1. Parking a lane sweeps it

`teamctl stop` took the build caches and kept `node_modules`, deliberately, so that
`teamctl restart` would be cheap. That trade was wrong at this scale: restart is rare,
parking is not, and 50.9 GB was the price. Now `disk_park_sweep` takes the whole allowlist
at the moment a lane is parked, by the two paths that park one:

- `cmd_stop` — one lane;
- `cmd_destroy` **without** `--worktrees` — every lane, in bulk, which is the path that
  parked 11 orphaned teams' worth of lanes on this machine. `--worktrees` already swept.

Four refusals come before the deletion, each leaving the lane whole: the `auto-prune`
policy (`off` restores v1.16.1's stop exactly), the lane's own `keep_build` flag, a lane
still running, and a **heavy run on the machine**. The last one is the only new mechanism:
a build runs in whatever shell started it, not in the lane's pane, so `stop` cannot see it,
and taking `node_modules` from under a running build is the one way this could do damage.
The signal is the lock this machine's own gates already hold,
`lockf ~/.wolfmux/machine-heavy.lock <command>`.

**The trap in that lock, and it is a real one.** The file is KEPT between runs when the
holder passes `-k`, so its existence proves nothing — `[ -e ]` would have stopped every
sweep for ever, and a test asserting "the file is there, so it is busy" would have passed.
The only thing that answers is trying to take the lock for an instant
(`lockf -k -s -n -t 0 … true`): 0 means free, 69 (`EX_UNAVAILABLE`, with `-n` and no file)
means nothing has ever registered a heavy run and is also free, 75 (`EX_TEMPFAIL`) means
held, and anything else means we cannot tell — which counts as busy, the same rule
`disk_lane_running` already follows for a lane it cannot place. No `lockf` on the machine at
all is NOT "cannot tell": the convention cannot exist there, so nothing can be holding it,
and the alternative would be an automatic sweep that silently never runs — the exact failure
this release exists to end.

**And then the convention itself turned out to be broken, which was found by using it.**
While this lane's own suites waited their turn on that lock, a `-t 0` probe of the path
answered *free* with the lane's own holder still running. `lsof` said why: the holder had
inode **240542083** open while the path resolved to **240709857**. `lockf`'s DEFAULT is to
delete the file when its command ends — only `-k` keeps it — and BSD locks live on the inode,
not the path. So one holder on this machine that omitted `-k` unlinked the file on exit, and
from that moment the path and the locked inode were two different objects: a holder still
running kept a lock nobody could see, and every later holder and probe took a fresh inode and
believed it was alone. Mutual exclusion was gone for every lane at once, silently, and the
only reason it surfaced is that something finally *read* the lock instead of only taking it.

Two consequences, and the honest one is the second:

1. The probe is now `-k -s -n -t 0`, which makes it READ-ONLY: `-n` stops it creating a file
   when none exists (69 is then "free"), and `-k` stops it deleting one. Looking at the lock
   leaves the lock exactly as it was, so this guard is not itself a participant in the race.
   `tests/disk.sh` asserts both halves, inode included.
2. **That does not fix the hole, and nothing in this repository can.** No single-process
   probe recovers a lock whose file has been unlinked under it. The fix is that *every*
   holder on the machine passes `-k`, which is what `lockf`'s own manual recommends and what
   README.md, docs/USAGE.md and the user manual now say in a box each. Until that is true
   everywhere, what this guard buys is exact and worth stating plainly: it stops the sweep
   whenever the convention is held correctly, and it never stops it wrongly.

Every sweep is appended to `~/.wolfmux/state/reclaimed.jsonl` (asked for by name): time,
project, team, lane, kilobytes, trigger, directory names, who. Machine-wide and not per
team, because "where did that space go" is asked long after the team is gone.

`teamctl keep <role>` protects one expensive checkout. A verb, not a flag on `spawn`, and
that was a choice: whether a checkout is worth protecting — a 40-minute install, a
downloaded model, a seeded database — is learnt AFTER it is built, and a spawn flag cannot
be taken back. `teamctl keep` with no role lists what is protected, and
`teamctl status --json` carries `keep_build`, so a flag nobody can see cannot hoard
quietly.

### 2. `teamctl prune --all-teams`, for the operator only

A lead cannot prune another team (exit 77; rule 4 of `lib/disk.sh` refuses the paths
anyway), which is right and stays. From a plain terminal there was no way to see the whole
machine: `prune --dry-run` answers for one team, `teamctl teams` for one project, and 21
teams is 21 commands and no total.

**Where the task description and the code had to differ, and why.** The task said to lean on
`is_manager`, "which already returns 0 for an empty caller role". It does — and it also
returns 0 for the lead of the team it is standing in, which is exactly the caller this
option has to refuse. So `is_operator` / `require_operator` were added beside it (one line
and a `die`, the same cooperative `caller_role` check, no new concept). The refusal names no
lead to appeal to, unlike `require_manager`: a command that reaches every team is not
something any lead can grant, so sending a refused agent to its lead would send it to the
one person who cannot say yes.

One more difference from the one-team form, deliberate: a team whose lanes cannot all be
placed is reported and skipped **whole**, and the run continues. The one-team form still
dies. There, the doubt is about the lanes you asked about and stopping is the answer; here,
one unplaceable team must not leave the other twenty unswept, and skipping it touches
nothing of it.

### 3. A status bar a person can read

Ammar's words: the line is unreadable. It was
`21t 18run 92stop ld3.56 mem7G dsk66G` — four units as suffixes, two abbreviated labels,
and `92stop` reading as one token. Now:

```
teams 20 run 12 idle 63 load 2.92 mem 8G disk 109G held 9.2G
```

60 characters, 67 with `exit N` in it, against a 72-character cut. **Every character is
inside `cmd_overview_badge`'s own alphabet (`A-Za-z0-9`, space, `. : / + -`) and no
separator was added at all** — the labels separate. That filter strips anything else
SILENTLY, so a middle dot or a pipe between fields would have vanished without a trace and
the line would have reached tmux with its numbers run together. `tests/dashboard.sh` asserts
it on the real line now: the badge is re-filtered and must come back unchanged.

`held` is the new field and the one the old line could not say: what the PARKED lanes of
every team hold. It is read from what `teamctl teams` left behind, never measured —
rule 2 of `lib/dashboard.sh`, a `du` over this machine's lanes is about twelve seconds and
this redraws every few seconds. `disk_team_kb_measure` now writes a second file,
`disk-parked-kb`, beside `disk-kb` (a second FILE, not a second column, so an old version
still parses a new file and a new version an old one), and `teamctl prune` corrects it by
what it took — correct by construction, because parked lanes are the only ones prune
sweeps. The park sweep does NOT correct it: the lane it swept was running when the number
was measured, so it was never in it, and subtracting would make the number smaller than the
truth. It waits for the next measurement.

A stale `held` is used on purpose, which is the one place this departs from the
file's own "never show an old number as current" rule, and the reason is in the thing being
measured: a parked lane is a lane in which nothing is running, so its size does not change
by itself. `teamctl bar --explain` says exactly that, and says what the number cannot know
(a lane parked or removed since). `dash_parked_kb` reads the file with the shell's own
`read` and SETS a variable rather than printing one, so the sweep over 25 teams costs no
process at all; `tests/dashboard.sh` asserts it agrees with `disk_parked_kb` on a good file
and on every malformed one, which is this module's standing rule for a fast path.

`teamctl bar --explain` is the legend. The ask was "a legend or a hover"; a terminal has no
hover, and seven numbers in seventy-two characters have room for their labels and nothing
else.

### Failing first, measured both ways

Every figure below was taken on this machine on 2026-10-13, with the new suites run against
a **pristine `adbc2db`** (`git archive`, the merge base this branch was rebased onto — still
`teamctl 1.16.1`, confirmed by its own version line) and then against this one. The baseline
was re-measured rather than carried, and the lock was taken for every run.

| Run | `dashboard` | `disk` |
|-----|-------------|--------|
| A — `adbc2db` code, `adbc2db` tests (baseline, re-measured) | 115 / 0 / 0 | 93 / 0 |
| B — `adbc2db` code, **the shipped tests** | 108 / **27** / 0 | 107 / **68** / 0 |
| C — this tree, the shipped tests | 135 / 0 / 0 | 175 / 0 / 0 |

B is the evidence, and it was re-measured at the final sha every time the file it describes
changed — four times in all, because three defects were found after the first pass and each
fix changed a suite. Only the last set is above. The superseded ones (`disk` 110/42, then
107/48, then a truncated 104/44) are recorded here as retracted rather than deleted.

Counted per check rather than by the total, which is the only way to tell evidence from
noise:

| | new checks | fail on `adbc2db` | also pass there | EXISTING checks failing in B |
|-|-----------|-------------------|-----------------|------------------------------|
| `dashboard` | 20 | **17** | 3 | 10 |
| `disk` | 82 | **68** | 14 | 0 |

Both rows close arithmetically against A and C, which is the point of counting them this
way: `disk` 93 + 82 = 175 and every one of B's 68 failures is a new check; `dashboard`
115 + 20 = 135 and B's 27 = 17 new + the 10 existing badge-format checks rewritten because
the format changed deliberately. A row that did not close would mean a check had been
silently lost.

The 17 that also pass on v1.16.1 are reported rather than counted as proof, because a check
that passes on the old tree proves nothing about this one. They divide into two honest kinds:
invariants that hold either way (the lane is a real worktree; its sources, commits and git
state are untouched; nothing is left half-deleted; one team's `--dry-run` is open to anyone;
`auto-prune off` IS v1.16.1's behaviour, which is the point of that path), and negative
assertions that sit beside a discriminating positive one (nothing in the ledger claims a
protected lane was swept).

**Six checks were moved out of that second group during the work, and that is the part worth
keeping.** They had passed on v1.16.1 because the command or the function *does not exist*
there — `teamctl keep lead`, `teamctl bar --nonsense` and `teamctl policy auto-prune
sometimes` all exit non-zero or 64 on a tree that has never heard of them. An exit code alone
cannot tell "the feature refused this correctly" from "there is no feature". Each now asserts
the reason or the usage line, or asserts that the valid values are ACCEPTED as well as that
an invalid one is refused, and all six fail on v1.16.1 afterwards. The same trap caught two
of the heavy-lock probe's own checks, where `! lib_eval "disk_heavy_run_in_progress"` was
satisfied by the function being absent; they ask `type` first now.

### What the measurement pass found, which reading the diff did not

Four defects were found by running the suites rather than by review, and three of them share
one shape: **the operation reported success for something it had not done.** That is the
same shape as the `-k`-less lock that excluded nothing, and as `flock` and `timeout`, which
are not installed on this machine and say so by doing nothing.

| | what it did | how it was found |
|-|-------------|------------------|
| `heavy --timeout ""` | ran the command with **no timeout at all**, silently: the guard asked whether the value was non-empty rather than whether the flag was given, so an empty value skipped the case that already rejected `""` | its own check could not see it — the check asserted only exit 64, and on the old tree an unknown command `heavy` also exits 64 |
| `tests/disk.sh` | **ended at check 140 of 175** with no summary line, twice, from two different causes: a bare `exit 1` in a check body, then a variable read after a short-circuited `&&` chain, which under `set -u` aborts the shell | the missing `result:` line, not a red check — a truncated run is indistinguishable from a short clean one |
| `destroy --purge` | printed "team 'child' is gone" and **left the team's records on disk**: the purge deletes per-team state files by name so the final `rmdir` can empty the directory, and `disk-parked-kb` was never added to that line | `tests/smoke.sh`, a suite this release does not touch, with pristine `adbc2db` as the control |
| `docs/SETUP.md` | did not name `install.sh`'s `--no-claude-commands` | `tests/docs.sh` — and pristine `adbc2db` fails the same check, so this one is not ours |

Three fixes are structural rather than careful, because being careful is what failed:

- `check` now evaluates every body in a **subshell**, so a failing check cannot end its
  suite — covering both causes, and every check nobody has written yet.
- The purge's file list is **derived** from `lib/disk.sh` (every `printf '%s/<name>'
  "$STATE_DIR"`) and each name must appear in `lib/agents.sh`'s purge line, so the next
  cache file is covered the day it is added. The check asserts the derivation found at least
  two names, so a derived list that matches nothing fails instead of passing trivially.
- The measurement harness reports a suite with **no summary line as TRUNCATED**, with the
  last check it printed, rather than its pass count. Without that, the second truncation
  would have shipped as a clean run.

A comment immediately above the purge line already described this exact failure happening
once, with `disk-kb`. It was read, used as the model for the new cache file's format, and not
followed to its conclusion. A comment saying "this went wrong once" is a warning about a
**class**, and the only safe way to read one is to ask what else is now in that class.

### Changed

- `lib/disk.sh`: the heavy-lock probe, the keep flag, the ledger, `disk_park_sweep`,
  `cmd_keep`, the parked cache, and `cmd_prune` split into `prune_team` / `prune_footer` /
  `prune_all_teams` so that one team and the whole machine run the same sweep.
- `lib/policy.sh`: the `auto-prune` key, and `is_operator` / `require_operator`.
- `lib/agents.sh`: `cmd_stop`'s sweep, the new loop in `cmd_destroy`, and `disk-parked-kb`
  added to the purge's by-name file list — without it, `destroy --purge` stopped emptying
  the team's state directory and so stopped deleting it.
- `tests/disk.sh`, `tests/dashboard.sh`: `check` evaluates its body in a subshell.
- `lib/dashboard.sh`: the badge line, `dash_parked_kb`, `dash_badge_held_kb`,
  `dash_tenth_gb`, `cmd_bar`.
- `lib/views.sh`: `keep_build` per agent, `auto_prune` and `disk.parked_kb` in
  `status --json`, auto-prune in the `status` disk line.
- `lib/completion.sh`, `bin/teamctl`: the two new commands and the two new options.
- `lib/provider-env.sh`: `WOLFMUX_AUTO_PRUNE` on the allowlist, in the same commit as the
  knob — the v1.16.0 lesson, and `tests/disk.sh` round-trips it through a real config file.
- `lib/common.sh`: line 5 only, `WOLFMUX_VERSION` to 1.17.0.

### Every suite at the shipped head

One pass, one sha, **`982d76b`**, rebased onto `adbc2db`. The lock was taken for the whole
pass, in one acquisition, by a plain `lockf -k -s` and deliberately **not** by this release's
own `teamctl heavy`: gating the measurement of a change with the code being changed makes
the instrument depend on the thing under test, and nothing in the pass could then tell you.

| suite | at `982d76b` | | suite | at `982d76b` |
|-------|--------------|-|-------|--------------|
| `smoke` | 349 / **2** / 0 | | `migration` | 36 / 0 |
| `disk` | 175 / 0 / 0 | | `permissions` | 13 / 0 |
| `dashboard` | 135 / 0 / 0 | | `commands` | 16 / 0 |
| `docs` | 36 / 0 | | `providers` | 141 / 0 / 0 |
| `inbox` | 107 / 0 | | `nudge-typing` | 61 / 0 |

**1069 passing, 2 failing, 0 skipped across the ten countable suites.** Every figure comes
from the suite's own summary line; a suite that printed none would be reported as TRUNCATED
and none was.

`smoke`'s two failures are **not this branch's**, and the control is the same suite on a
pristine `adbc2db`, which fails the same two by name — `beads: a worker reaches the shared
database from its worktree` and `rename: a Beads hook written under the old name is
replaced`. Pristine is 346 / 2, this tree is 349 / 2: three checks added, no new failure.
Both are **non-hermetic checks**: they read the LIVE shared Beads database rather than a
throwaway one, so their result depends on what is in it at the time. They failed in three
runs here and passed in two of the lead's, and the branch is identical across all five.

**The mechanism is not established.** The leading hypothesis, with the three facts behind it
and nothing more: the check immediately before the failing one passes, running the same
`bd list --assignee backend` query from the project root and finding the bead the suite just
created; the failing check runs that same query after `cd` into the worker's worktree and
asserts `length == 1`; and in the live database that a worktree path resolves to there were
**0** open beads assigned to the role name `backend` when measured. That fits `bd` resolving
to the live database rather than the suite's own from inside a worktree — which would make
the check assert the number of open beads belonging to an unrelated role, and pass only when
that number happens to be 1. Three facts are not a proof, and this is filed as its own task
rather than fixed here.

What is NOT the explanation, so nobody reaches for either again: not this machine's Beads
install (the install is the same in runs that pass and runs that fail), and not concurrent
Beads writes by the agent running the suite (a run with no `bd` activity of its own at all
failed identically).

`tests/credential-routing.sh` has **no counted checks by design** — it prints four sections
for a person to compare against its own `expected` block, so it has no summary line and no
pass count exists to quote. All four matched when read.

Two documents were edited after that pass, which two suites read without naming them:
`tests/docs.sh` reads everything under `docs/` through its globs, and `tests/smoke.sh:174`
and `:177` `grep -rn` over `$REPO/docs` to assert two patterns are ABSENT from it. So `docs`
was **re-run at the final sha**, and both of smoke's patterns were re-checked against the
shipping content; neither appears. The glob and the `-r` are the lesson, not the filename.

**shellcheck is still not installed on this machine, so nothing here was linted with it**;
`bash -n` was run on every changed file and no figure above stands in for a lint.

## 36. A finished lane takes itself off the books (the reclaim work, stage 2)

Stage 1 gave back what a build makes again. The checkout itself is the bigger half of a
lane — **33.3 GB of the 52.6 GB** left under `~/.wolfmux/worktrees` after a full sweep,
measured 2026-10-13 — and only `teamctl remove <role>` gave that back, by hand. Stage 2
removes a parked lane by itself once it is finished. It is the one stage that can delete
work, so it is built the other way round from a cleanup: a lane goes only when every gate
says yes, and **a gate that cannot be answered says no**.

The module is `lib/reclaim.sh`, the suite is `tests/reclaim.sh`, and the header of the
module is the specification. This section is what the header does not say: what the brief
got wrong, what measuring changed, and what is left.

### Four things the brief had wrong, each found by measuring

**1. Plain `git cherry` does not see a squash of several commits.** The brief said to use
`git cherry` instead of a containment test, because a squash-merged branch looks unmerged to
`git branch --contains`. That is half the gap. `git cherry` compares commit by commit, so
three commits squashed into one read as three commits that are nowhere: on git 2.50.1,
`git cherry main <branch>` printed three `+` lines, and only a ONE-commit squash matched.
The fix keeps git as the judge: one throwaway commit holding the branch's whole diff
(`git commit-tree`, the branch's tree on the merge base), and `git cherry` asked about that.

How much that matters was then measured on the lead's own repository, read-only, 24 lane
branches against `origin/main`, 7 seconds in all:

| What says the branch's content is in main | Branches |
|-------------------------------------------|----------|
| the tip is an ancestor (a containment test sees these) | 4 |
| plain `git cherry` (every commit has an equal) | 1 |
| **only the one-commit question** (a squash of several commits) | **9** |
| nothing (kept, as unmerged or unpushed) | 10 |

So of 14 branches whose content is in main, a containment test plus plain `git cherry` —
the brief as written — would have recognised 5, and kept the other 9 for ever.

**2. A stash is not lost with its worktree.** The lead asked for a gate "the lane's
`git stash list` must be empty", on the premise that a stash goes when the worktree goes.
`refs/stash` lives in the repository's common git directory and is one list for every
worktree: measured, `git stash list` gave the same entries in a lane and in the main
checkout, and after `git worktree remove --force` plus `git branch -D` the lane's entry was
still listed and its commit still there. The gate as asked would have kept every lane of a
repository as soon as anybody held one stash anywhere in it. What shipped counts only the
entries made on the lane's OWN branch, and keeps the lane for those — not because they would
be lost, but because a stash is work the content gate cannot see, and because the entry
would name a branch that no longer exists. Entries made on a detached HEAD belong to no
lane; they keep none and are named once per repository.

**3. "Not pushed" cannot be a gate.** Workers are told not to push and integration is a
cherry-pick, so "the lane must be pushed" would mean nothing is ever reclaimed. Whether the
content is in main decides; whether the tip is on a remote only chooses the word in the
reason (`unpushed at <sha>` when it is on no remote, `unmerged at <sha>` when it is, and
`unpushed` when both are true, because that one exists on this disk only).

**4. The stub had the wrong shape, and so did the time limit.** Both were found by asking
the real `bd` instead of the stub that encoded my guess:

- `bd list --json` prints a bare array. With `--brief` or `--skip-labels` (bd 1.3.0) the same
  list arrives wrapped as `{"issues": [...], "meta": {...}}`. The first parser accepted an
  array only and would have read every wrapped answer as "could not be read". Both shapes
  are read now and the stub gives both.
- The first time limit was 20 seconds. Measured on 2026-10-14 with a load average of 18.8:
  `bd where` 18 s, the same per-lane `bd list` 24 s, 33 s, 4 s and 4 s within five minutes.
  At 20 seconds every lane on this machine would have been kept on a busy afternoon. The
  limit is 45 seconds, and — the bigger change — Beads is asked **once per run for the whole
  project** instead of once per lane: 12 s for 1,377 beads (1.2 MB) under the same load,
  whatever the number of lanes. A question per lane would have made `teamctl stop` in a
  team with ten finished lanes a matter of minutes.

### One gate nobody asked for

The worktree's HEAD has to be the tip of the lane's branch. A detached HEAD, or another
branch checked out in the lane, holds commits that no branch name leads back to once the
worktree is gone — which is how three commits were lost on 2026-10-13 and found again only
as dangling objects. The content gate looks at the recorded branch and would never have
seen them. The reason names that sha: `its worktree is at 6c3143f, which is not the tip of
its branch`.

### What is said before anything is deleted

`<role>: branch <name> was at <full sha>`, on the screen and as a line in
`~/.wolfmux/state/reclaimed.jsonl`, before the branch goes — and not only for a reclaim. The
loss on 2026-10-13 was a `destroy --purge`, so `remove`, `destroy --worktrees` and
`destroy --purge` say it too, and a `--force` removal also says where the worktree's own
HEAD was when that is somewhere else. A team's own event log is deleted with the team, so
the machine-wide ledger is the only record that outlives a purge. The reclaim itself writes
the ledger line first and keeps the lane when it cannot: a removal nobody can look up is
not made. It never passes `--force` to git and never falls back to `rm -rf`.

Writing the line first has one cost, found by reading the code again and not by a test. Git
can still refuse the worktree afterwards (a locked worktree, a populated submodule), and
`git worktree remove` has no dry run, so that refusal cannot be asked for in advance. The
ledger then said `lane-removed` for a lane that was still there. Now the lane stays whole —
worktree, branch and record — the reason is git's own first line (`holding <size>: git
refused to remove its worktree: cannot remove a locked working tree`), and a second ledger
line, `"event": "lane-kept"` with the same `branch` and `tip`, takes the first one back.
Whoever reads the ledger for a tip reads the LAST line about it.

### Three decisions that are easy to undo and were made on purpose

- **The squash question leaves nothing in your repository.** `git commit-tree` writes an
  object. The throwaway commit goes into a scratch object directory
  (`GIT_OBJECT_DIRECTORY`, with the repository's own objects as an alternate) that is deleted
  afterwards; measured, the repository's loose-object count is the same before and after.
  Left in the repository it would have been one unreachable commit per lane per target every
  time a lane was parked, in a repository that already sat above git's automatic-gc
  threshold (6,871 loose objects).
- **The team's lock is never held across a question to Beads or GitHub.** The check runs
  outside the lock; the lock is taken for the removal, the cheap gates are asked again under
  it, and it is released. The lock gives up after 30 seconds and a slow `bd` takes longer.
- **Status asks nothing.** What a kept lane holds and why is written into the lane's record
  by the check and read by `teamctl status`, with its age once it is more than ten minutes
  old. Nothing is triggered from the status bar or the dashboard.

### What it does not do

The rows are in [ROADMAP.md](ROADMAP.md) and are repeated here only as a list: a squash
after main changed the neighbouring line is kept (pinned by a test); a lane parked before
its merge waits for the next park; without `gh`, or in a repository that is not on GitHub,
nothing is reclaimed automatically; files `.gitignore` ignores go with the lane;
`teamctl stop` on a finished worker ends `teamctl restart` for it (`teamctl keep` first);
`teamctl destroy --worktrees` is the older path and asks none of these gates.

One correction to how the knob was described while it was being designed: `auto-prune` does
**not** fall back to its default on a value nobody can read. Both knobs fall back to `off`,
and have since stage 1 (`policy_get`). For `auto-reclaim` the comment next to the code says
why that direction is not a matter of taste.

### Failing first: the new suite against the base

`tests/reclaim.sh` is a new suite, so there is no older count to compare with. The same
file (`cmp` says identical) was run against a pristine `9be145b` — a `git archive` of the
base, which has no `lib/reclaim.sh` — and against this tree, in one pass.

| Run | `reclaim` |
|-----|-----------|
| `9be145b` code, **the shipped suite** | 4 / **118** / 0 |
| this tree at `9243243`, the shipped suite | 122 / 0 / 0 |

The cases the brief named, each by the check that carries it. Every one FAILS on `9be145b`
and passes here:

| The brief's case | The check, by name |
|------------------|--------------------|
| merged and clean: removed | `a lane whose task is closed, whose content is merged, with nothing uncommitted and no PR, passes` and `every lane that passed is gone: its worktree, its branch and its record` |
| an unpushed commit: kept, and status says why with the sha | `a lane with an unpushed, unmerged commit is KEPT, and the reason names the tip` and `status shows a kept lane as holding <size>: <reason>, with the sha for an unpushed one` |
| squash-merged: removed | `a lane whose three commits were SQUASHED into one passes, which plain git cherry cannot see` |
| an open PR: kept | `a lane with an open PR is kept, and the reason names the PR` |
| `gh` cannot answer: kept | `when gh fails, the lane is kept: deleting a worktree under a reviewer has been paid for once` |
| the task bead still open: kept | `a lane whose task is still open is kept, and the reason names the bead` |

The suite has 19 sections. Every one has a failing check on `9be145b`, and 17 of the 19 have
no passing check there at all.

The 4 that pass on `9be145b` are reported and not counted as proof, because a check that
passes on the old tree says nothing about this one. One is an invariant (`every lane is a
real worktree teamctl made, with a real record`). The other three are named `CONTROL:` and
ask git itself, not teamctl: plain `git cherry` reports a squashed lane as missing, a
containment test agrees with it, and a lane's stash is visible from the main checkout. They
are there so that the checks beside them cannot pass for the wrong reason.

### What the measurement passes found

Two passes were needed, and the first one is recorded here as superseded, not deleted.

**Pass 1, at `fc57e8f`: `reclaim` 121 / 1 / 0.** The one failure was in a check written the
same day, for the locked worktree. It asked the gates about the lane while the lane was
still running, and gate 1 keeps a running lane, so the answer was "running" and not the
"yes" the check wanted. The check was wrong and the code was right. It now asks after
`teamctl stop`. That is `9243243`, which changes `tests/reclaim.sh` and one number in
`README.md` and no library.

**Pass 1 also had `dashboard` 134 / 1 / 0 and a TRUNCATED `nudge-typing`.** Neither came
back. In pass 2 both are clean on this tree (135 / 0 / 0 and 61 / 0) and clean on `9be145b`
in the same pass (135 / 0 / 0 and 61 / 0). What that does and does not show:

- This branch changes neither suite, and none of `lib/dashboard.sh`, `lib/notify.sh`,
  `lib/inbox.sh`, `lib/disk.sh`, `lib/common.sh` or the hooks. `git diff --stat 9be145b
  9243243` over those paths prints nothing, every path exists, and the same command over
  `lib/views.sh` prints a line — so the empty answer is not a pattern that matches nothing.
- **The failures were not reproduced on `9be145b`.** "Load, not this branch" rests on that
  diff and on the clean re-run of both trees, not on a failing control. It is a hypothesis.
- Both checks compare two readings taken at two moments. `teamctl bar prints the line the
  status bar is given, character for character` runs `teamctl bar` and `teamctl
  _overview-badge` as two processes, and each reads the machine's load to two decimals and
  counts every team's agents. `mid-delivery: all five are queued, nothing typed yet` asks
  that five notices are all still waiting after five `teamctl policy` calls. Pass 1 started
  at a load average of 21.75. Pass 2 ran at 7 to 13.
- `nudge-typing` printed no summary line in pass 1 because a second check failed after the
  first: `mid-delivery: every queued notice still arrived, none was lost on the way`
  (`tests/nudge-typing.sh:313`) ends its loop with a bare `exit 1`, and that suite's `check`
  evaluates the body in the suite's own shell. So the failing check ended the suite instead
  of printing FAIL. It is one of the bare-`exit` sites already filed, and it is why a run
  with no summary line is reported as TRUNCATED and never by its pass count.

**Pass 1 held the machine-wide lock, and should not have.** It ran under `teamctl heavy`
(`~/.wolfmux/machine-heavy.lock`): 22 minutes waiting for it, then 39 minutes 32 seconds
holding it, for twelve suites that are shell, `bd`, `git` and file work. Another team's
release gates waited behind them. Pass 2 took the team's own lock instead (`lockf -k
~/.wolfmux/wolfmux-ux-heavy.lock`), which nobody outside this team waits for.

### Every suite at the stage 2 head

One pass, one sha, **`9243243`**, twelve suites one after the other under one acquisition of
the team's lock, 22:29:35Z to 23:12:17Z on 2026-10-13. Each suite was launched as
`perl -e '$SIG{HUP}="DEFAULT"; $SIG{INT}="DEFAULT"; exec @ARGV' bash tests/<suite>.sh`, so
that no signal is inherited as ignored.

| suite | at `9243243` | | suite | at `9243243` |
|-------|--------------|-|-------|--------------|
| `reclaim` | 122 / 0 / 0 | | `migration` | 36 / 0 |
| `disk` | 175 / 0 / 0 | | `permissions` | 13 / 0 |
| `dashboard` | 135 / 0 / 0 | | `models` | 22 / 0 |
| `docs` | 36 / 0 | | `commands` | 16 / 0 |
| `providers` | 141 / 0 / 0 | | `nudge-typing` | 61 / 0 |
| `inbox` | 107 / 0 | | `smoke` | 350 / **2** / 0 |

**1214 passing, 2 failing, 0 skipped across the twelve countable suites.** Every figure
comes from the suite's own summary line. A suite that printed none would be reported as
TRUNCATED, and none was in this pass.

`smoke`'s two failures are the two that section 35 describes, by name: `beads: a worker
reaches the shared database from its worktree` and `rename: a Beads hook written under the
old name is replaced`. The control is the same suite on a pristine `9be145b` in the same
pass: 350 / 2 / 0, the same two names. They read the live shared Beads database, and the
mechanism is still the hypothesis written down there. This branch changes one line of
`tests/smoke.sh` and adds no check to it: 352 checks on both trees.

`tests/credential-routing.sh` was **not run**. It is manual, has no check count, and needs a
logged-in `claude`.

Documents were edited after that pass: this section and `docs/VERIFICATION.md`. Two suites
read the documents without naming them, so `tests/docs.sh` was **re-run at the final sha**
(36 / 0), and the two patterns that `tests/smoke.sh:177` and `:180` assert are ABSENT under
`docs/` were searched for by hand in the shipping content. Neither appears, and each pattern
was first shown to match a line that does contain it.

**shellcheck is not installed on this machine, so nothing here was linted with it.**
`bash -n` was run on every changed shell file, and no figure above stands in for a lint.

### What the review found: a park that could fail after it had happened

The lead's review found nothing that fires today and one thing that was waiting.
`bin/teamctl` runs under `set -euo pipefail`. `teamctl stop` and a plain `teamctl destroy`
ask the reclaim check **after** the lane is parked. The check, `reclaim_on_park`, had no
return of its own, and both calls were bare. So the exit status of `teamctl stop` was the
exit status of a disk-cache writer three functions away. Had that ever failed, the command
would have ended with an error after parking the lane and before saying `stopped: <role>`.

The fix was proposed as "`return 0` as the last line, and `|| true` at both calls". Four
things were then measured, in this order, and three of them changed it.

**1. A `return 0` at the end does nothing.** On bash 3.2.57, the bash teamctl runs in:

| Shape | Exit | Says `stopped:` |
|-------|------|-----------------|
| the last command of the function fails, the caller is bare | 7 | no |
| `return 0` after the failing command, the caller is bare | 7 | no |
| the caller says `\|\| true` | 0 | yes |
| the failing command says `\|\| true` itself, then `return 0`, the caller is bare | 0 | yes |

Under `set -e` the shell ends at the failing line, and the `return` after it is never
reached. So each of the three bookkeeping lines says `|| true` for itself.

**2. `|| true` at a call switches `set -e` off inside the whole function**, and inside
everything it calls. That is what bash does with a function on the left of `||`. Every step
of the check was read again for it. None relied on the shell ending: the removal is reached
only through `if` tests, and those already ran without `set -e` for the same reason.

**3. `|| true` cannot catch an `exit`.** `lock_acquire` dies when the team's lock stays held
for 30 seconds, and the check takes that lock. Measured on `e3c43cd`, with a stand-in `gh`
that takes the lock and leaves a live pid in it: `teamctl stop` ended with exit 1 after 37
seconds, printed `another teamctl operation holds the project lock`, and never said
`stopped:`. The lane was parked and whole. So the check runs in a subshell (`e43dea1`): the
subshell takes the `exit`, the error still prints, and `stopped: <role>` follows it.

A subshell hands no variable back, so the flag the check used to set is gone, and
`teamctl stop` picks its closing line from the lane's record (`reg_exists`). That is the
better way round and not the clumsier one. The line says the lane is "off the books", so it
is read from the books, and not from what the check believed before its last step.

**The same class, in `teamctl reclaim` itself.** Its bookkeeping (two lines in
`reclaim_team`, one in `cmd_reclaim`, one in `reclaim_all_teams`) runs after the lanes are
gone. A failure there reported a reclaim that worked as a command that failed, which is how
somebody runs a deletion a second time. Those four lines say `|| true` as well.

**4. The subshell made an old leftover visible, and only the full suite saw it.** On a
`git archive` of `e43dea1` the suite printed 130 passed, 1 failed. The failing check was its
last one, `no scratch file is left behind by any of it`. What Beads answers is kept in a
file for the length of one check, and a check that ends by `exit` never reaches the line
that drops it. That fix did not cause the leftover file. It inherited it: before `e43dea1`
the whole command died at that `exit`, the file stayed behind then too, and it was nobody's
problem. Once the command carries on and says `stopped:`, clearing the file is its job.

So one function, `reclaim_after_park`, is what both commands call (`1ae1552`). It runs the
check in two shells, one inside the other:

- The outer one makes a scratch directory, gives it to the check as its `TMPDIR`, and
  removes it in a trap on EXIT. A line after the check would be skipped by the same `exit`.
  The directory is made in that shell, so the trap removes only what that shell made. Being
  a subshell, it leaves teamctl's own EXIT trap alone, which is what releases the team's
  lock when a command dies.
- The inner one runs the check and takes an `exit` in it. It is a shell of its own for a
  second reason: `lock_acquire` re-arms the EXIT trap of the shell it runs in each time it
  takes the lock. In the outer shell that would throw the cleanup away at the first lane.

Measured with plain bash 3.2.57 in the same shape, a `sleep` standing in for the check:

| What ends the check | The cleanup runs | The caller goes on |
|---------------------|------------------|--------------------|
| `exit 9` in the inner shell | yes | yes |
| the inner shell re-arms its own EXIT trap, then exits | yes | yes |
| a failure (`return 7`) | yes | yes |
| no inner shell, a re-arm, then `exit` | **no** | yes |
| SIGTERM to the parent alone | yes | no (it was killed) |
| SIGINT to the whole group, as Ctrl-C sends it | yes | yes |
| SIGTERM to the whole group | yes | no |

The two signal rows with "no" are the parent dying, which is what a signal is for. The
Ctrl-C row is plain bash and not teamctl: it says the cleanup runs, not what
`teamctl stop` prints.

**Every guard is pinned by a check.** `tests/reclaim.sh` has twelve checks for all of this,
in a copy of teamctl's home where a function leaves a mark and then fails (returns 7; exits
9 after leaving a scratch file and taking the lock once; or does its work and then
returns 7). Each of the twelve guarded lines was then removed, one copy of the code per
line, and the twelve checks were run against every copy:

| What was removed | Checks that fail (of 12) |
|------------------|--------------------------|
| nothing (`1ae1552`) | none |
| `reclaim_after_park`: the outer shell (a brace group instead) | 6 |
| `reclaim_after_park`: `\|\| true` after the outer shell | 1, 2, 7, 11 and 12 |
| `reclaim_after_park`: the trap on EXIT | 3, 8 and 12 |
| `reclaim_after_park`: the scratch directory as the check's `TMPDIR` | 3, 8 and 12 |
| `reclaim_after_park`: the inner shell | 3, 8 and 12 |
| `reclaim_on_park`: any one of its three lines | 5 |
| `reclaim_team`: either of its two lines | 9 and 12 |
| `cmd_reclaim`: its line | 9 |
| `reclaim_all_teams`: its line | 10 |
| the code of `e43dea1` (the subshell at the two call sites) | 3, 6, 8 and 12 |
| the code of `e3c43cd` (the first fix) | 2, 3, 6, 7, 8, 9, 10 and 12 |
| the code of `a157cf4` (before any of it) | all twelve |

The checks, in that order: 1 `stop` when the check fails, 2 `stop` when the check exits,
3 what that check left in the temporary directory is gone, 4 `stop` when the bookkeeping at
the end of the real check fails, 5 `reclaim_on_park` called bare under `set -e`,
6 `reclaim_after_park` leaves its caller's EXIT trap and `TMPDIR` as they were, 7 `stop`
with the team's lock really held (the 30-second wait), 8 that check left nothing behind,
9 `teamctl reclaim` with failing bookkeeping, 10 `teamctl reclaim --all-teams` the same,
11 `destroy` when the check fails, 12 `destroy` when the check exits, with nothing left.

Three things about that table, so that nobody reads more into it than is there:

- Check 4 fails in no single row. Two layers cover it, so it takes `a157cf4` to fail it. It
  is the end-to-end check and is kept as that.
- Checks 8 and 12 ask whether ANYTHING is left in the temporary directory, so they also
  fail when an earlier case left something. That is why the inner-shell row lists them:
  check 3 is the one that tells that row apart. In the `reclaim_team` rows, check 12 fails
  because the `teamctl reclaim` that died left its own Beads answer behind.
- `teamctl reclaim` still has that leftover when it dies in the middle of a run. It has no
  scratch directory of its own. Only the check after a park does.

**A change to control flow cannot be judged by running its own section.** The leftover file
was found by a check at the very end of the suite, far from the code that was changed, and
the section that was being run alone to iterate could not see it. An `exit` path, a
subshell, a trap, an early return: what they break is a released lock, a written ledger, a
leftover file, and those checks look unrelated. Section runs to iterate, the full suite to
conclude.

**Three measurements of this round were wrong before they were right**, and each would have
looked clean:

- The lead's own run of the suite "on the lane's tree" read the worktree itself while the
  first fix was being edited into it. teamctl reads its libraries again at every call and
  bash reads a script as it goes, so that run measured no single commit. It printed
  122 passed, 0 failed, the expected number exactly. It was discarded. The rule since: a
  number about a commit is measured on a `git archive` of that sha, never in a working tree.
- The first run of a table like the one above built nine of its eleven copies as empty
  files: the table inside the script used `|` as its separator, and `|| true` has one in
  it. Each row carried a count of the lines its copy had changed, and that count is what
  gave it away. A copy that did not change exactly the lines it was meant to, or that does
  not parse, is now refused instead of run. That refusal fired twice more the same night.
- `e43dea1` was first judged by its own section, nine of nine. The full suite said 130 of
  131. That is point 4 above.

### Every suite after the review

One sha, **`1ae1552`**, the last commit that changes code. Nothing was measured in a working
tree: every suite ran on a `git archive` of that sha, in the clean launch shape. The one
exception is `migration`, which replays the project's own history and cannot run without
it. On the archive it stops at once with `commit deff83a (v1.1.0) is not in this clone's
history` and prints no summary line, so it is TRUNCATED there, and on the archive of the
base as well. Its figure below is from a clone pinned at the same sha.

| suite | at `1ae1552` | | suite | at `1ae1552` |
|-------|--------------|-|-------|--------------|
| `reclaim` | 134 / 0 / 0 | | `migration` | 36 / 0 |
| `disk` | 175 / 0 / 0 | | `permissions` | 13 / 0 |
| `dashboard` | 135 / 0 / 0 | | `models` | 22 / 0 |
| `docs` | 36 / 0 | | `commands` | 16 / 0 |
| `providers` | 141 / 0 / 0 | | `nudge-typing` | 61 / 0 |
| `inbox` | 107 / 0 | | `smoke` | 350 / **2** / 0 |

**1226 passing, 2 failing, 0 skipped across the twelve countable suites.** Every figure
comes from the suite's own summary line. `reclaim` ran bare, 00:52:30Z to 01:02:07Z on
2026-10-14 (577 seconds, load about 4). The other ten on the archive ran under one
acquisition of the team's own lock, 01:04:50Z to 01:25:37Z. `migration` ran bare at 01:34:37Z.

`reclaim` on a pristine `9be145b` with the same suite file, same pass: 4 / **130** / 0, the
same four as before. The lead ran both arms independently, each from a `git archive`, and
got the same two lines, and found no `wolfmux-reclaim-*` left in the temporary directory
afterwards.

`smoke`'s two failures are the same two, by name, and the control is the same suite on the
archive of `9be145b` in the same pass: 350 / 2 / 0, the same two names.

All twelve were run again, and not only `reclaim`, because `teamctl stop` and
`teamctl destroy` are what changed, and `disk`, `smoke`, `dashboard`, `inbox` and
`nudge-typing` run them.

The documents were edited after that pass. `tests/docs.sh` was **re-run at the final sha**
(36 / 0), from a clone pinned at it, and the two patterns `tests/smoke.sh:177` and `:180`
assert are ABSENT under `docs/` were searched for by hand in the shipping content. Neither
appears, and each pattern was first shown to match a line that does contain it.

## 37. One lead keeps a private memory (v1.22.0, team memory)

Asked for by the owner for the communication-management lead, planned by `comms-memory.lead`, built
in two lanes with disjoint files: this one (teamctl) and `memtool` (the folder's contents, under
`config/wolfmux/memory-skeleton/`). The contract between them: teamctl runs only `mem init` (enable)
and `mem check` (memory check), passes the lead a boot prompt that tells it to run `mem boot` (teamctl
never runs `mem boot` itself), and reads only the size of `core/card.md` (since review round 2). Decision and findings:
[ADR-0030](adr/0030-one-lead-keeps-a-private-memory.md).

| Piece | Where |
|-------|-------|
| policy `team-memory <team>\|off`, project-level, owner-only on, lead-allowed off, logged to `team-memory.jsonl` and `events.jsonl` | `lib/policy.sh`, `lib/memory.sh` |
| `teamctl memory status\|enable\|disable\|adopt\|path\|check` (`adopt` since review round 3) | `lib/memory.sh` |
| the "Team memory" prompt block: the folder, the rules, the boot line; never the card (review round 2) | `build_role_prompt` |
| `autoMemoryDirectory` for that lead only | `write_agent_settings` |
| the boot prompt at every launch | `cmd_run_agent` |
| `--continue` refused with no stored id (for every lead while the policy is on, since review round 3); `destroy --purge --memory` | `cmd_start`, `cmd_restart`, `cmd_run_agent`, `cmd_destroy` |
| guard: the folder for every file tool, searches of a folder that holds it, `.wolfmux/memory` in a command, `~` / `$HOME` / `${HOME}` expanded (also for `~/.wolfmux/state`) | `lib/guard.sh` |
| the skeleton installed to `~/.config/wolfmux/memory-skeleton/`; `uninstall.sh --purge` refused while memory exists, `--purge-memory` | `install.sh`, `uninstall.sh` |

Found on the way: the project memory folder Claude Code shares per repository is named by the
existing `transcripts_dir` rule (every character but a letter or digit becomes `-`), not by `/`
alone: `~/.wolfmux` is `--wolfmux` in such a name. Checked against the real folders under
`~/.claude/projects/`. A live interactive pty probe of `claude --resume <id> "<prompt>"` did not
reach a first turn in 90 s (print mode did), so the boot prompt rests on the CLI reference; see the ADR.

`tests/memory.sh` (new, 51 checks) covers it end to end with a stub agent and a fake skeleton.

**Review round 2.** An adversarial review found the switch, the settings and the prompt wiring right
and five read channels open. All five are closed: (1) the card is out of the prompt, because `ps
-axww -o command=` shows every agent's `--append-system-prompt` to every process and `teamctl _prompt`
prints it to any caller (`mem boot` prints the card inside the lead's conversation instead); (2)
`teamctl capture` of the memory lead's pane is the owner's alone; (3) the worktree guard closes the
leads' transcript folder `~/.claude/projects/<project path>/` (all but its shared `memory/`) to
workers' file tools and Bash text; (4) `teamctl memory check` (it writes and prints names) and
`teamctl memory path` are the owner's and that lead's only; (5) `destroy --purge --memory` needs the
pane proof (`require_operator`), since a piped `script -q /dev/null` fakes a terminal. Also: no owner,
no memory (`team_founder` must be the operator and `bin/mem` must run); the guard compares paths
without regard to letter case, drops `/./`, judges an absolute Glob pattern by its root, refuses tree
walks of `~`, `~/.wolfmux`, `~/.claude` or `/`, and reads the `.wolfmux/memory` rule after the prose is
gone (a commit message passes, a quoted path does not); `uninstall.sh --purge-memory` alone is exit 64;
`memory status` warns about a Codex lead. The suite unsets `BEADS_DIR` and gives the test project a
`.beads` of its own: the caller's `BEADS_DIR` had decided whether `teamctl finish` could take the team.
`tests/memory.sh` has 75 checks.

**Review round 3.** A read-only re-review of round 2 confirmed its eleven fixes and found eleven more.
R1, a regression: `bash -c "…"`, `sh -c`, `zsh -c` and `eval "…"` passed the guard again, because the
prose stripper ran before the memory rules and dropped the quoted command. R2: from a lane under
`~/.wolfmux/worktrees/`, a `..` climb (`cat ../../../../../memory/…`, a Glob with `..`) reached the
folder with no `cd` at all. R3: an agent that unset `TEAM_ROLE` and `TMUX_PANE` was taken for the owner
by every owner-only gate, and a quoted or pathed `tmux` slipped past the tmux rule. R4: Claude Code's
`file-history/`, `todos/` and `paste-cache/` under `~/.claude` were open to workers, and `memory status`
printed the folder's path and the lead's conversation id to anyone. R5: since round 2 the card lives
only in the lead's conversation, so ANOTHER lead's `--continue` without a stored id could open it. R6:
`capture` opened to everyone after `memory disable` while the running lead still held the memory. R7:
`enable` accepted a team an agent founded and promised a memory its lead would never get. R8: a grep or
rg pattern such as `"/Users/"` was taken for a folder and refused. R9: wildcards, `~<name>`, a mid-line
`/.` and a `\` line continuation slipped past. R10: comments and documents said `mem boot` runs after
every compaction (the lead is only told to) and that teamctl calls it (it passes the prompt). R11:
tests the re-review listed as missing. How they closed: the guard items (R1, R2, R3's guard part, R4's
folders, R8, R9) are in `lib/guard.sh` (commit 9bc7c1d, plus `guard_follow`, which follows a literal
`cd` or `pushd`, from the guard lane); the command items in `lib/memory.sh`, `lib/agents.sh` and
`lib/views.sh`: `--continue` without an id is refused for every lead while the policy is on, `capture`
also while the lead's settings carry `autoMemoryDirectory`, `enable` refuses an agent-founded team and
the new owner-only `teamctl memory adopt <team>` makes the owner its founder, and `memory status` gives
the path and the id to the owner and that lead only. SECURITY.md now says plainly that every owner-only
gate is a pane proof a process can drop, which forms the worker guard refuses, that leads are not
guarded, and that `uninstall.sh --purge --purge-memory` checks no identity. Still open, and named
there: a `cd` to a folder known only at run time, `CDPATH`, a `cd` to a wildcard, code in another
language, a script the command runs, and the memory lead's id in its records under `~/.wolfmux/state`,
which the guard closes to workers and not to leads. A follow-up in the same round hides that id
everywhere a view prints it: `teamctl status` (plain and `--json`, the id and the agent-view chat it
continued in), `model --now` and `restore` print `hidden` to anyone but the owner and that lead.

**Review round 4.** A re-review of round 3 found one blocker. A slow guard is no guard: Claude Code runs a
tool call whose hook times out (10 s), and the round-3 guard took 17.6 s on a padded command (a `cat` of
the card, four `cd`s, then `sh -c` with 99 `x/../f` words), because every `..` word cost about 15 forks
and the cheap rules ran last. The fix is one awk pass, `GUARD_SCAN` in `lib/guard.sh`: it reads the
command as the shell does, runs the cheap name rules first, then follows `cd` and the inner commands,
with no fork per word, and refuses ("split this command") over 4,000 words, over 300 paths outside the
worktree or after 2 seconds (round 5 found that this clock never bounded the lexer: see below). Setup is one jq and one awk; symlinks are tested with the builtin `[ -L ]`
and read through in a second pass only when one exists. Timings on the reviewer's harness, before and
after: the padded command 19.7 s → 0.03 s (refused), `prettier --write` on 99 worktree files 9.3 s →
0.03 s, on 101 files refused → allowed (paths inside the worktree no longer count), `git status`
0.29 s → 0.02 s. Of the harness's 498 cases, 107 changed, all as the review asked. False positives
gone: `tmux` counts only as the program (`grep -n "tmux"`, `rg 'tmux'`, `git log -S tmux`, `echo tmux`
pass), and a search pattern is never a path (`grep -rn "../utils" src/`, `rg "../lib"`, `git grep
'../shared'` pass). Bypasses closed: quotes and `\` inside a word (`mem""ory`, `mem\ory`,
`~/.wolfmux/"memory"`, `$'…'`), a `\` line continuation inside a word, `sh -c` with options around `-c`
or `--`, `echo`/`printf`/a heredoc piped into a shell, `bash -`, `source /dev/stdin`, `<( )`, `ssh` and
`watch` text, `grep -r ~ -e x` and `grep -d recurse x ~` (the pattern is chosen after every option), the
`claude --resume` refusal after `timeout`, `nice`, `caffeinate`, `script`, `xargs`, `npx
@anthropic-ai/claude-code` and `$(which claude)`, quoted and un-export identity drops (`unset "X"`,
`declare +x`, `read`, `printf -v`, `env -S`), a symlink in the worktree (`ln -s ~/.wolfmux w`, then
`cat w/memory/…`: the `ln` is refused and an existing folder link is followed by Bash, Read and Glob;
a link at the end of a path was followed only after round 5), and a
worktree named like the start of another (`w1` and `w10`). Claude Code's records widened: `sessions/`,
`session-env/`, `history.jsonl` and its temporary folder `/private/tmp/claude-<uid>` (except the
worker's own scratchpad) are closed, MCP `file://` URLs count as paths, and `fd`, `ag` and `ack` are
tree walkers. SECURITY.md now says the conversation id is no secret (`ps -axww` and
`~/.claude/sessions` show it to every process), that `find /tmp` is refused, and what still passes:
a folder, path or program built at run time (`c=claude; $c -r <id>`), `CDPATH`, code in another
language, a script the command runs and a chain of more than three symlinks (round 5 found the chain
claim stale: a chain is followed as deep as macOS goes, 32 links). `tests/memory.sh` has eight
new checks (all fail on the round-3 guard), including the three timings through `teamctl _guard`.

**Review round 5.** The final review of round 4 (8572a05) found a lexer time hole, a shell mismatch, an
unguarded tool and links at the end of a path. B1: the lexer was unbounded (a 600 KB word took 17.3 s, a
400 KB heredoc 11.1 s, 400 KB of comments 9.3 s); now a command over 64 KB is refused before awk starts
in 0.02 to 0.04 s, the lexer counts characters, words and paths (a step budget, with the clock only as a
backstop), and every 60 KB shape takes 0.02 to 0.53 s (it was up to 7.7 s). M1 (H2): the Bash tool runs
`$SHELL`, which is `/bin/zsh` for every agent on this Mac; workers now launch with `SHELL` and
`CLAUDE_CODE_SHELL` set to `/bin/bash`, and the lexer reads an in-word `(` as a zsh glob group and strips a
leading `=` (`=tmux`). Shell proof (fe9d657): Claude Code 2.1.309 reads `CLAUDE_CODE_SHELL` first;
`claude -p --model haiku` answered `/bin/zsh 5.9` by default and `/bin/bash 3.2.57(1)-release` with the
two variables. M2 (H3): the hook matcher is `.*`; Monitor and PowerShell commands go through the Bash
check, and any other tool has every string value read as a quoted word and its `command`, `cmd` and
`script` fields as shell text. M3 (H4): a quoted word that holds a `/` is a path even with a blank in it
(a commit message that names a private folder by path is refused on purpose). M4 (H5): the last
component of a path is resolved with the link rule too (Read, Grep, Glob, LS, Edit, Write, Bash), and the
`ln` rule covers `gln`, `link`, `cp -s/-l`, run-time words, `xargs`, `find -exec` and
`git update-index --cacheinfo 120000`. S1 to S4 (H6): a word is also read with its run-time parts deleted
(`mem${x}ory`), what `$( )` prints is shell text, and MCP `file:` strings are normalised. H7 (db1cb6e):
a portability audit of the awk program and the bash (no gawk or bash 4 forms) with a check that keeps
it. H8 (6151e70): test honesty. `check()` runs each body in a subshell, because nine checks ended the
whole suite at their first failure, and a masked `$?` was fixed; of the 43 guard checks the 15 of
rounds 4 and 5 fail on 1538605's guard and the 26 older ones pass (they test rules it already has); no
check passed on old code where it should not. Commits: H1 0efa2f2 and e415173, H2 fe9d657 and b0dc1ac,
H3 ad76f41, H4 89fd842, H5 202d022, H6 fafd2e6, H7 db1cb6e, H8 6151e70. Harness flips against the
reviewer's 8572a05 baseline, all allow to deny, 37 of 742: H2 14, H3 3, H4 6, H5 7, H6 8. `tests/memory.sh`
went from 122 to 130 checks, each new one failing on its parent's guard.

## 38. The Stop hook keeps out of a watched pane under idle too (v1.22.1)

**What the owner saw.** On 2026-10-26, from 06:12Z to 06:41Z, in the pane he is attached to:
after almost every turn of the communication-management lead, `Ran 7 stop hooks` and
`Stop hook error: [wolfmux] You have team notices: …`. teamctl 1.22.0, Claude Code 2.1.310.

**Cause.** `_inbox_stop_watched` (lib/inbox.sh) began with `inbox_human_typing_off || return 1`.
The communication-management team has policy `human-pane-typing idle` (set by the owner on
2026-10-21 at 15:33Z; deployment-manager too; every other team is unset, which is `off`). Under
`idle` that line returned before tmux was asked, so `cmd_inbox_stop` answered
`{"decision":"block","reason":…}` in the lead's pane while a client was attached, and Claude Code
prints a Stop block's reason labelled "Stop hook error". That team's event log for the day: 20
`inbox-stop` lines for the lead, 0 `inbox-stop-silent`. The v1.20.0 silence worked under `off`;
`idle` had been left on the v1.16.1 rule on purpose (tests/inbox.sh asserted "policy idle: the
watched lead pane gets the block answer exactly as before").

**Decision.** That is reversed: a pane a human is watching gets nothing from the Stop hook under
either value. `idle` decides typing only (`inbox_keep_off_human_pane` is untouched). Nothing is
lost: under `idle` the nudge path still parks a waiter that types the notice once the attached
lead's pane is quiet (`WOLFMUX_NUDGE_LEAD_IDLE`), and `_inbox-prompt` hands over whatever is
still undelivered at the next prompt. The `inbox-stop-silent` event now names the real value
(`human-pane-typing=idle: …` or `=off: …`).

**The answer where the hook still speaks** (a pane nobody watches) is
`{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":…}}`, not a block. Claude
Code's hooks docs, "Stop decision control": additionalContext "keeps the conversation going
through the same loop protections as `decision: "block"`, namely the `stop_hook_active` input and
the 8-consecutive-continuation cap, but the transcript labels it `Stop hook feedback` and no hook
error notification is shown". The installed 2.1.310 binary holds `Stop hook feedback` 8 times,
`stop_hook_active` 7 times and `Stop hook error` 6 times. Proved live before the code: a settings
file with one Stop hook that printed that shape once (a stamp file) made
`claude -p 'reply with the single word ok' --model haiku --settings <file>` answer `pineapple`,
the word the hook's text asked for. The cooldown, mark-delivered-before-print and the re-queue on
a jq failure stay as they were; the event says "continued once with N notice(s)".

**What the human sees after the install.** Nothing in a pane he watches, under `off` or `idle`.
In a worker pane he scrolls through later: `Stop hook feedback`, not `Stop hook error`. The
install reaches every running session at once, with no restart: each agent's settings document
names the installed `teamctl`, and teamctl reads the installed library on every call.

**Tests.** tests/inbox.sh: the `idle` checks that expected the block in the watched lead pane now
expect silence (exit 0, nothing printed), an undelivered notice, a silent event naming `idle`, no
`.stop.lead`, and the hand-over at the next prompt; the two loop guards (delivered before the
answer, the cooldown; a new notice continues once, never twice) moved to `aux`, a worker pane
nobody shows, under `idle`; the pane-proof unit case says `idle` watches the same panes as `off`.
On 870a2bd's inbox.sh the 9 flipped checks fail and nothing else does. Every Stop answer check
reads `.hookSpecificOutput` and asserts no `decision` key (tests/beads-hotpath.sh too).
Commits: S1 ff06966, S2 c593472, S3 this one.

## 39. An idle lead wakes itself (v1.23.0, issue #34)

**What happened.** On 2026-11-03 tagging.lead sat 16 hours on 4 messages. The owner was
attached to the team in another iTerm2 tab. Under `human-pane-typing off`, `inbox_human_pane`
read the lead's pane as watched whenever any client was attached (its case a), so `_nudge_one`
only filed, the Stop hook stayed silent, and the next prompt was the only way in. An idle lead
has no next prompt. The desktop banner fired 5 times.

**Measured first** (the lead, on a throwaway socket, Claude Code 2.1.318 with haiku): an
`asyncRewake` Stop hook that exits 2 wakes the idle model within about 2 s, even with a dialog
open; the pane shows only `⏺ wolfmux: team notice` (the `rewakeSummary`), the hook's stdout goes
to the model alone; a hook killed at its `timeout` wakes nobody, and `604800` is accepted; a
half-typed draft stays in the input box, unsent; every Stop starts its own copy; `/exit` kills
the hook, `kill -9` of Claude leaves it under PID 1; a pty client that sends no focus reports
reads `focused` from the start. A hook that always exits 2 loops: wake, Stop, wake. On the live
socket (read-only, earlier): `focused` follows iTerm2 tab and app switches, at most one client
has it.

**Decision** ([ADR-0031](adr/0031-idle-lead-wake-waiter.md)):
- `tm_pane_in_use`: shown by a client whose terminal has focus or saw a key within
  `WOLFMUX_WATCH_QUIET` (120 s). One `list-clients` read, fails closed. `inbox_human_pane` asks
  only that, for every role. `WOLFMUX_WATCH_FOCUS_MAX` (0 = no limit) caps focus alone.
- A Claude-family lead with a client attached is still never typed into, and its Stop hook
  stays silent (`inbox_claude_lead_attached`): a Stop hook's text prints in full in the pane.
  A Codex lead and workers use the new gate.
- `teamctl _inbox-wake`, an asyncRewake hook on the lead's Stop and SessionStart (exec'd, so its
  parent is Claude). One waiter per role by a token in `inbox/.wake.<role>`; UserPromptSubmit
  writes `busy`. Every 15 s: token, agent gone (parent pid gone, or PPID 1), pane or team gone,
  lifetime, count, policy, gate. Takes under the nudge lock, prints, exits 2. Exit 2 only with
  notices, or once at `WOLFMUX_WAKE_TIMEOUT - 300` s to re-arm. A failed print re-queues.
- Under `human-pane-typing idle` the typed waiter drops a line a hook already handed over.
- Sender words from the wake record (waiting / turn / off / none / in use), in `teamctl nudge`
  and the event log; a `held:` line under the lead in `teamctl status`, `held` in `--json`.
- Policy `lead-wake unwatched|off`, default `unwatched`, the owner's alone; unreadable reads as
  `unwatched` (the wake types nothing; `off` would make a lead deaf again).

**Tests.** tests/inbox.sh: the gate (focus, keystroke, neither, not shown, read error, empty
pane, the focus cap, one read), the new `inbox_human_pane` (the lead of an attached team is no
longer watched by that alone), the Claude-lead typing and Stop rules, Codex lead typed when not
in use, the held words, the policy, status, the settings of lead and worker, every waiter
outcome on a fake clock (no notices never exits 2 until the re-arm, two waiters, a prompt, off,
pane gone, agent gone, PID 1, a failed print, the typed waiter's skip), and an end-to-end pair of
waiters whose `bin/teamctl` process exits 2. Checks that meant "a pane in use" now show the
lead's pane to the client. Commits: S1 b08e900, S2 9a4ee6d, S3 the Stop rule, S4 this one.
## 40. A store of our own (v1.24.0, the store line)

Three complaints from the same day of real use: a worker inside one long turn did not
read "commit now" for two hours because the typed nudge queues until the turn ends
(2026-10-04); nothing an agent learned reached the next agent, so every worker
rediscovered how the tests are run; and a worker reached 255k tokens of context without
one commit, with no warning along the way. A four-worker team took one ADR each.

- **Mail through the CLI's hooks** (ADR-0032). A message or task now reaches a Claude
  Code agent's conversation directly — `additionalContext` on `SessionStart`,
  `UserPromptSubmit` or `PostToolUse`, or a `Stop` hook that blocks with the text — at
  the agent's next tool call, no `bd show` round trip needed to read it. The hot path
  above the module loader in `bin/teamctl` keeps this cheap: an idle `PostToolUse` with
  nothing queued costs about 3 ms, no module loaded. A role with no running pane, or a
  Codex-family agent (no such hooks), still gets the notice line. (Amended in the merge,
  section 41: the hooks and the notice are one delivery system.)
- **Team memory, the context watch, and checkpoints** (ADR-0033). `teamctl remember` /
  `memories` put what a team has learned in front of every new, resumed or compacted
  conversation. Every tenth tool call the context watch checks how full the conversation
  is; at `WOLFMUX_CONTEXT_WARN` (60%) the agent is told once to commit and write a
  `teamctl checkpoint`, at `WOLFMUX_CONTEXT_ROTATE` (80%) to start nothing new, with the
  lead messaged the command that gives the task a fresh conversation. `teamctl restart
  <role>` is that rotation: same worktree and branch, a new conversation that starts
  from the checkpoint.
- **`worker-context`** (ADR-0034). A freshly spawned worker's first request was measured
  at 111,365 tokens before it had read its task — over half of a 200k window, sent again
  with every request. The policy's three settings (`full`, `trim` the default, `lean`)
  trade how much of the owner's own `~/.claude` a worker's conversation starts with
  against that cost; the lead is never trimmed.
- **A store of our own** (ADR-0035). Every task, message and memory operation still went
  through `bd` even after ADR-0032, and that was now the larger remaining cost: 0.3 to
  0.7 s a call, a single writer (6 concurrent `bd create` calls took 3.7 s between them),
  and Beads' own issue #6039 stalling a hook past 30 s under load. `lib/store.sh` moves
  all three behind one interface with two backends: a native `sqlite3` file per project
  (WAL mode, the default for one with nothing on disk yet) and Beads, kept for a project
  already on it and reachable again with `teamctl store beads`. The same operation on
  the native backend: 4-10 ms. `teamctl store native --migrate` moves a Beads project's
  open tasks, unread messages and memories over without deleting anything from Beads.

Every command an agent used to run as `bd` became a `teamctl` verb that calls the store
interface underneath (`send`, `mail`, `task`, `claim`, `done`, `blocked`, `tasks`,
`show`, `note`, `reopen`, `close`, `checkpoint`, `remember`, `memories`, `forget`), plus
`teamctl store` to see or switch the backend. `broadcast` and `message-history`, which
used to point at the `bd` equivalent, are retired the same way the `moved_to_beads`
commands always were (`removed_command`, naming the real commands instead).

On the store line's own branch, as it stood before the merge: `tests/smoke.sh` 327 → 339,
new `tests/store.sh` (73), `tests/mail.sh` (30), `tests/tasks.sh` (31) and a shared-notes
suite of 31 that the merge renamed `tests/recall.sh`. `tests/docs.sh` ran 21 of 36
until `usage()`, the completion backend, the config template, README.md, docs/USAGE.md and
the user manual caught up. The counts after the merge are in VERIFICATION.md.

## 41. Two lines made one (v1.24.0, the merge)

Two branches had grown from the same v1.12.0 base. v1.23.0, the released line, had answered
the human's complaints: a notice typed into a pane they were using (the typing gates, ADR-0028
and 0029), a lead that was quiet when it should have woken (the wake waiter, ADR-0031), a
private memory for one lead (ADR-0030), the newest model behind each alias, `teamctl finish`,
`restore` and the disk work. The store line, called v1.13 while it was in flight, had answered
the agents' complaints: every task and message cost a `bd` round trip, nothing one agent
learned reached the next, and a worker spent half its window before reading its task
(section 40). Both were right and both had touched the same files, so the merge went in two
steps: the store line was merged onto v1.23.0 as v1.24.0, then every place where two designs
did one job was settled by a decision.

- **D1, v1.23.0's rules for the human's pane stand.** A pane a human is watching, a Claude lead
  attached to, the typing gates and the CONTEXT column's window (the model table, not a guess
  per agent) are v1.23.0's. The store line's hooks plug into them and do not add their own.
- **D2, `inbox` and `notices` keep their meaning.** They read the notices file, as in v1.23.0.
  The command that reads an agent's mail and open tasks is `teamctl mail`. Kickoffs, the native
  handover prompt and the status footer say so.
- **D3, two kinds of memory, two names.** `teamctl memory` is the lead's private folder (ADR-0030).
  What the store line called team memory is "shared team notes": `remember`, `memories`,
  `forget` and `checkpoint`.
- **D5, an existing project stays where it is.** A project that already has agent state and no
  `store` file stays on Beads. A new project is native. `teamctl store native --migrate` moves one.
- **D6, `send` is a real command.** `broadcast` and `message-history` keep their old answer
  (`removed_command`, naming what to use).
- **D7, one delivery system.** An item files one notice line through v1.23.0's inbox, whose
  gates decide whether anything is typed, and a Claude agent gets the body with the hand-over.
  Gone: the typed "New mail for" wake line of the hook design, the mail watchdog,
  `WOLFMUX_MAIL_WAKE_AFTER`, and a hook that closed a bead with `bd`.
- **D8, v1.23.0 code works on either store.** Every place that asked `bd` directly (status
  bar, reclaim, restart, finish, the lead's handover) answers from the store on a native
  project and never runs `bd` there. On Beads the handover prompt is v1.23.0's `bd` text.
- **D10, an alias means the newest model.** `fable` is `claude-fable-5-2`, `opus` is
  `claude-opus-5-5`, `sonnet` is `claude-sonnet-5-5`, `haiku` is `claude-haiku-5-5`.
- **D4, the ADRs were renumbered.** The store line's four records were 0028 to 0031 on its own
  branch; v1.23.0 had already used those numbers, so they are 0032 to 0035 here, with an
  "Amended in v1.24.0" note where D7 changed what they said.
- **D9, the docs are read as one release in a separate pass.** The merge itself resolved only
  the conflicts in them; making them read as one release (this section among them) came after
  the code.

What the merge removed: the wake line typed to wake an idle agent, the watchdog that typed it
after 90 s, `WOLFMUX_MAIL_WAKE_AFTER`, the hook's close of a bead through `bd`, and
`notify_stop` (v1.23.0's `_notify` hook notifies at Stop). The suites that model Beads now pin
`WOLFMUX_STORE=beads`, since a new project is native.

The review before the release. The merged tree (`affd4de`) passed every suite and was still
refused by the reviewer of record, with eleven findings, each reproduced by experiment. The
four that blocked the release: `teamctl done` and `blocked` did not check whose task it was
(and closed with `--force` on Beads); a task shown at SessionStart was handed over again at
the first Stop; on Beads the SessionStart mail read waited on `bd` with no bound; and the human
could not be messaged on a native store. Also fixed: a migration that lost task status and
switched after a failed read, one oversized shared note hiding all the others, a store switch
any agent could run, `bd` commands in refusals shown on a native store, a report sent before
the close, an item printed before it was moved, and a Beads title starting with a dash. Each
fix began with a check that failed. Two things the stub suites could not show were run against
the real Claude Code CLI with Haiku agents on a native store: a message sent mid-turn reached
the worker through the PostToolUse hook 17 s later, and a worker started with
`worker-context lean` was refused both writes outside its worktree. Two low findings are left
for v1.25.0: the lead exemption of `teamctl done` trusts the caller's role without the pane
proof for a process outside any pane, and the SessionStart hook's two bounded `bd` reads can
add up to 10 s of its 20 s. The counts at the release commit are in VERIFICATION.md.

## 42. Mail handed to a subagent (v1.24.1)

Claude Code runs an agent's hooks for the tool calls of its in-process subagents too (the
Agent tool). Their input carries `agent_id` and `agent_type`, with the main conversation's
`session_id` and `transcript_path`; a call of the main conversation has neither key. `cmd_hook`
did not look. So when mail was queued for an agent while one of its subagents was working, the
subagent's next tool call took the PostToolUse hook's full path, the mail went into the
subagent's context, the notice line was marked delivered, a native store marked the message
read, and the attention file was gone. The agent never saw it and no later hook handed it over
again. The context watch had the same fault: a threshold said to a subagent was recorded as
said. Leads use subagents all the time, so this lost a lead's mail. It was new in v1.24.0:
v1.23.0 had no PostToolUse hook.

The fix is one test in `cmd_hook`. The jq call that already checked the input now also reads
`agent_id`, and a non-empty one returns before anything is cleared or any module runs. Nothing
is said, nothing is moved out of `mail/new`, nothing is marked, and the attention file stays,
so the agent's own next call takes the full path and gets the mail. The hot path at the top of
`bin/teamctl` is unchanged: a call with nothing queued still costs one bash start and no fork.
A subagent's call while something is queued pays the full path and gives up, about 75 ms a call
on this machine (4.7 ms on the hot path), until the main conversation's next call takes it.

Every other hook wolfmux registers was looked at against a real run. Only PreToolUse and
PostToolUse fire inside a subagent (`SubagentStart` and `SubagentStop` are their own events,
and wolfmux registers neither). `Stop`, `UserPromptSubmit` and `SessionStart` fire for the main
conversation only, so `_inbox-stop`, `_inbox-prompt`, `_inbox-wake` and `_notify` are not
reached from a subagent. The worktree guard (`_guard`, PreToolUse) does fire there and still
refuses: a subagent of a worker was refused a read of another teammate's worktree with the
guard's own text. A background subagent's result reaches the main conversation as a
`UserPromptSubmit` without `agent_id`, which is the agent's own turn, and is treated as such.

Proof, each check failing on v1.24.0 first: `tests/mail.sh` (a subagent's PostToolUse says
nothing and the mail, its notice and the attention file stay; no turn event with `agent_id`
says anything; the agent's own next call hands it over once) and `tests/recall.sh` (a
subagent's call neither says nor uses up the 65% warning). Then the real CLI, print mode, Haiku,
no pane: a scratch team with a spooled message holding a marker word, the hook run through
`tests/in-pane` so the pane proof stands, and a prompt that runs one Bash command through a
foreground subagent and then one itself. On v1.24.0 the marker was in the subagent's
transcript as a PostToolUse `hook_additional_context` and nowhere in the main one except as
the subagent's own retelling. On v1.24.1 the subagent's transcript holds no marker and the
main conversation's has it as `hook_additional_context`, at the Agent tool's own PostToolUse.

## 43. A long output stays out of the context (v1.25.0, ADR-0036)

Bash output was a third of what a worker added to its context after its first answer (33.4% for
the port worker, 40.4% for the lead; 10% of the steps made 36% of the growth). Claude Code 2.1.325
sends no `clear_tool_uses` edit, so a test log read once is sent again with every later request
until a compaction.

Six probes against the real CLI (`tests/research/results/offload-probes.md`) showed where a hook
can and cannot help. A `PostToolUse` `updatedToolOutput` must be the Bash result object (a string
is refused, the original kept). A command that exits non-zero fires `PostToolUseFailure` only, whose
answer replaces nothing, and the CLI cuts that result to its first ~10,000 characters: the FAIL lines
at the end of a failing suite never reached the model and were saved nowhere. Above 30,000 characters
a successful result is saved by the CLI with a 2 KB head. A `PreToolUse` `updatedInput` rewrite of
the command is honoured and the exit code still arrives.

So the work is done before the command, not after it. `teamctl _offload-pre` (its own PreToolUse
entry, next to the worktree guard) puts one prefix on a Bash command: stdout and stderr go to
`run/<role>/out/<n>-<pid>.log`, and an EXIT trap prints the result whole when it is at most 4000
characters, else the first and last 40 lines, the lines between that match
`FAIL|[Ee]rror|panic|not ok` (at most 60), the counts, the exit code and the path with "search it
with grep; do not cat it". The command runs once, in the same shell: cd, exports and the exit status
stay. A PostToolUse safety net shortens a long exit-0 result the rewrite did not cover, and
`bashOutputMaxChars` and `BASH_MAX_OUTPUT_LENGTH` are lowered to 16000 as a backstop. Codex cannot
rewrite a result, so `teamctl run -- <command>` does the same with the same code. The policy
`output-offload` (on) and `WOLFMUX_OFFLOAD=off` switch it; off writes not one hook entry of it.

Cost per Bash call on the owner's Mac: PreToolUse 6 ms (3 ms off), a short PostToolUse result no
fork, a long Bash result 34 ms. Review found three faults, all fixed with a check that failed first:
two Bash calls at once shared one log (the pid is in the name now); a command with its own `trap`
lost its output to a log nobody was told about (never wrapped, as `exec` and background calls are);
the safety net could keep queued mail back (mail comes first, as in D7).

Proof: `tests/offload.sh` runs a plain-against-wrapped corpus (output, exit code, cwd, exports)
under bash and under zsh started as the CLI starts it. On the real CLI (probes 7 to 10): a 60,002-line
failing command arrived as the shortened form with the middle FAIL line and the last 40 lines; a
short failure came back identical to the one without the feature and left no log; a command another
hook denies stayed denied; an `exec` command got the safety net's form.

Not built: a failure hidden in the cut middle is only as visible as the pattern (an agent can still
`cat` the log); a command with `exec`, `trap` or in the background is covered by the net and the
backstop alone; Codex has no hook, so its agents must call `teamctl run --` themselves.

## 44. A trimmed agent starts smaller (v1.25.0, ADR-0037)

ADR-0034 took the plugins out of a worker. Measured again, a trimmed worker's first request was
still 81,024 tokens and the lead's 115,652, and that part is sent with every request and decides how
much room a compaction leaves. Three things in it were never used by a pane agent: seven tools
(a pane has 15 on the wire, 72,593 characters, `Artifact` alone 37,384), the claude.ai connectors
(36,879 characters of tool names and instructions that arrived during a two-line task), and a
Chinese copy of the owner's rules (9,142 characters, 7,785 tokens). Each has a per-process switch
that needs nothing changed in `~/.claude`.

Under `worker-context trim` and `lean`, a worker's generated settings deny Artifact, AskUserQuestion,
SendFeedback, ScheduleWakeup, Workflow, ReportFindings and ListAgents by bare name and set
`ENABLE_CLAUDEAI_MCP_SERVERS=false`. The policy `context-exclude` takes globs that become
`claudeMdExcludes`; empty by default, because wolfmux does not decide which of the owner's files
matter. `teamctl doctor` names a rules folder that repeats a sibling in a second language and prints
the exact line. The policy `lead-context` (`full` default, `trim`) gives the lead the same three
reductions except that AskUserQuestion stays; its plugins are not touched.

| First request (print mode, Haiku 5.5) | Worker | Lead |
|---|---|---|
| v1.24.0 (`trim`; lead untouched) | 74,171 | 90,006 |
| v1.25.0 `trim` / `lead-context trim` | 51,884 (30% less) | 67,793 |
| plus `context-exclude '**/rules/ecc/zh/**'` | 44,099 (41% less) | 60,008 (33% less) |

In real pane runs with the same settings: worker 81,024 to 54,289, its summed input for the same
task 589,753 to 339,615 (42% less), lead 115,652 to 70,017. The "before" row moves with the
connectors (56,744 in a probe where they had not connected yet); the "after" rows do not.

Not built: the 123 of 209 listed skills that come from account-synced plugins
(`~/.claude/plugins/synced/`) are still listed, no per-process switch was found. `--tools` with a
short allow list would be smaller (23,746) but fails closed on a later CLI's new tool and takes
Agent and Skill from a worker; the deny list fails open. A worker under `trim` cannot use a
connector; `worker-context full` gives them back.

## 45. One context number, a window that cannot thrash, a stalled agent reported (v1.25.0, ADR-0038)

The CLI compacts at about its window minus 33,000 tokens and starts again at the conversation's
first request plus what the compaction kept (19k to 47k). With a worker's window and first request
that left little room: the port worker (200k) compacted 4 times in 11 minutes and stood still 514 s;
a Haiku worker with a 100k window compacted 10 times in 5 minutes (4-5k of room each time), and the
CLI then stopped with "Autocompact is thrashing". The worker sat idle with its task in progress
and nobody was told. Meanwhile `teamctl status` and the watch divided by the model table's window
(or 200,000): a worker told to compact at 100,000 was shown 6%, one at 186k of 400k was told 93%.
A window handed to `spawn` or `task --spawn` never arrived, because the settings file is written in
the pane, which has the tmux server's environment. The watch also fired inside in-process
subagents (their hook input carries the main conversation's transcript).

`context_limit_for` (`lib/policy.sh`) is now the only place a limit is worked out, and every view
prints `142k/167k 85%`: status, dashboard, the watch's notices, the checkpoint. The window of a
worker is `F + K + 33000 + room` (room 150000), never above the model's, never below the same sum
with 30000, and a raised or capped window says why in the pane and the event log. A window asked for
on `spawn`, `task --spawn` or `restart` is written on the record and reaches the pane. The watch
leaves a `near` file within 10 points of the next threshold so the hot path looks every call
(one file test, no fork), and does nothing inside a subagent. Two compactions within 10 tool calls
send the lead one message with the numbers and the restart command.

A stall of over 3 hours after an API 529 went unreported before. `lib/stall.sh` looks, from outside
the agent, for a transcript quiet for `WOLFMUX_STALL_AFTER` (300) seconds that ends on an error row,
and tells the lead once per row: from the lead's idle wake waiter (every 60 s), from its tenth tool
call, and from `teamctl status` (a `stalled` line). Nothing is typed and nothing restarts.

Four pane runs on the real CLI (`tests/research/results/part-b-real-cli.md`): the compact window is
in a hook's environment; status counted the same tokens as the CLI's statusLine (79,923 both); two
compactions 4 tool calls apart gave the lead exactly one message and it acted; the 80% warning
reached the lead before a compaction at 147k; a staged stall (the rows of a real 529) was reported
87 s later and not twice. The runs found a real fault: SessionStart:compact fires before the
`compact_boundary` row is written, so K, F and the thrash message's figures were the previous
compaction's. A background job now reads them when the row appears (fixed, with a check that failed
first).

Not built: no rotation, nothing gives a task a fresh conversation by itself; a tool result that
jumps the conversation over the limit within one request (two parallel 23k reads at 59%) compacts
with no warning, the PreCompact checkpoint is what is left; a stalled lead, an agent stuck any other
way (a hung tool, a dialog), a Codex agent and a team with no lead and nobody calling status are not
seen; Codex keeps the window its rollout states, unreduced. The lead's tenth-call and status
lookers of a stall are covered by stub checks only.

## 46. Two review findings closed, and one run on the release (v1.25.0)

The v1.24.0 review left two findings open, both closed before the release.

The lead's right to close any task with `teamctl done` or `teamctl blocked` was a bare
`TEAM_ROLE=lead`: any process that set that variable outside the lead's pane had it (N1). It now goes
through `is_manager`, the check `require_manager` makes, so a process that claims the lead and does not
run in its pane is refused with exit 77 (`_tasks_lead_exempt`, `lib/tasks.sh`).

A hook run waited on Beads once per read, 5 s each, so a wedged `bd` made SessionStart take 11 s (N2).
One hook run now has one budget for its bounded reads, `WOLFMUX_HOOK_BD_BUDGET` (5 s): `cmd_hook` sets a
deadline once (`lib/hooks.sh`), `_bd_bounded` (`lib/store.sh`) takes what is left of it and starts no
read when nothing is. SessionStart with a wedged `bd` is about 5 s, inside the CLI's 20.

One real-CLI run on the release commit (Haiku 5.5 lead and worker, native store, default `trim`, no
`context-exclude`): a failing command of 12,001 lines (60,922 characters) reached the worker as the
shortened form with exit code 1, the last line, and the failure line 6001 from the cut middle, the full text
in `run/w1/out`. The worker's first request was 62,106 tokens in a pane. Status showed `68k/285k 23%` for
the worker and `122k/967k 12%` for the lead, and the lead got one notice for one `done`.

## 49. Four low findings of the v1.25.0 review (v1.26.0, part C)

1. **The wrapper line** (ADR-0036). The 700 character prefix became a sourced file, `lib/offload-wrap.sh`;
   the line is `[ -r <wrap> ] && . <wrap> <log>; `. bash quotes the first line of a command in a syntax
   error message; the message went from the whole wrapper (742 characters of line) to the user's command
   with a short lead. Under zsh the message never quoted the line. Seen failing before: the new
   "message under 600 characters" check. The fail-open checks now plant a fake lib directory (wrap file
   plus a broken or killed show script) since the show script is found next to the wrap file.
2. **A log size cap** (`WOLFMUX_OFFLOAD_LOG_MAX`, 50 MB). Applied when the command has ended, on the long
   path only. Cost of a wrapped `echo hi` end to end, 50 runs: 15 ms before, 16 to 18 ms after (the extra
   file read of the source); the PreToolUse hook alone 6 to 7 ms before and after. Seen failing before:
   the "bytes left out" checks (a 5 MB log with a 1 MB cap stayed 5 MB).
3. **The stall lookup** is bounded (`_bd_bounded 5`, Beads only); a wedged `bd` gives the report without
   the task. `tests/stall-wedged.sh` stands in a task read that sleeps 30 s: before, 30 s and no
   message; after, 5 s and the message. It runs inside `tests/context.sh`.
4. **A compaction nobody warned of** is said once to the agent and in the thrash message
   (`lib/recall.sh`, 38 added lines). Checks in `tests/recall.sh` (the section "a compaction nobody warned
   of").

## Footprint on the machine

| Created | `~/bin/*`, `~/.config/wolfmux/`, `~/.wolfmux/`, `~/.local/bin/bd`, `~/.codex/rules/wolfmux.rules`; Beads' own `~/.beads`, `~/.dolt`, `~/.config/bd` |
|---------|------|
| Modified (backed up) | `~/.zshrc` (one block), `~/.claude/settings.json` (4 allow rules, 1 ask rule; 9 before v1.8) |
| Deliberately not created or touched | `~/.tmux.conf`, `~/.zprofile`, any CLAUDE.md / AGENTS.md, `~/.codex/config.toml`, `~/.codex/rules/default.rules`, git config, any project's `.gitignore` |
