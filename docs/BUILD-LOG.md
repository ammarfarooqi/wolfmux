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

## 26. "A notice landed in the middle of my sentence" (v1.13)

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
defer. `tests/smoke.sh`: 327 → 327. `tests/docs.sh`: 36 → 36. v1.13.0.

Merged with main at integration, which had meanwhile reached v1.12.0 (tab completion, the
doctor probe, per-agent conversations). Five files conflicted and all five were resolved
by keeping both sides: the version line (1.13.0, since 1.11.x and 1.12.0 were taken), the
test tables in README and VERIFICATION, one `teamctl nudge` / `restart` / `status` /
`teams` row block in USAGE, and this log's numbering. Resolving it turned up one thing
round 3 had missed: VERIFICATION still asserted the OLD rule, that a non-empty input row
with nobody attached is not a human and the notice is delivered. Round 3 reversed exactly
that, so the sentence was the opposite of the code. Corrected here. Third time a claim in
these docs was found to outlive the code it described, and all three were found by
somebody re-reading rather than by a test.

## Footprint on the machine

| Created | `~/bin/*`, `~/.config/wolfmux/`, `~/.wolfmux/`, `~/.local/bin/bd`, `~/.codex/rules/wolfmux.rules`; Beads' own `~/.beads`, `~/.dolt`, `~/.config/bd` |
|---------|------|
| Modified (backed up) | `~/.zshrc` (one block), `~/.claude/settings.json` (4 allow rules, 1 ask rule; 9 before v1.8) |
| Deliberately not created or touched | `~/.tmux.conf`, `~/.zprofile`, any CLAUDE.md / AGENTS.md, `~/.codex/config.toml`, `~/.codex/rules/default.rules`, git config, any project's `.gitignore` |
