# ADR-0030: One lead per project keeps a private memory, switched on by the owner alone

**Date**: 2026-10-23
**Status**: accepted
**Deciders**: the repository owner (who asked for it), `comms-memory.lead` (the plan), the v1.22.0 author

## Context

The communication-management lead is a long-lived conversation. Each restart, compaction or handover
loses how it was told to work, and the brief it is re-sent is a task, not a way of working. Claude Code
can load an auto memory from a folder (`autoMemoryDirectory`): measured on Claude Code 2.1.308, a session
started with the setting loaded a marker from a private `MEMORY.md`, and the control run did not. That
memory has to stay private to that one lead: what it holds is the human's working relationship with it,
and every agent of every team runs as the same macOS user, in the same project folder.

Two traps were found while planning. The comms lead's record has `kickoff 0` and no handover, so a fresh
restart gave it no first prompt and it sat idle. And `start --continue` / `restart --continue` with no
stored conversation id falls back to `claude --continue`, which opens the NEWEST conversation in the
folder all leads of a project share: the memory would be read into somebody else's conversation.

## Decision

A project-level policy `team-memory <team>|off`, default off, names ONE team. Only the owner turns it
on (`teamctl memory enable <team>`, `require_operator`; an agent gets exit 77); the owner or that team's
own lead may turn it off. Its lead, and nobody else, gets `~/.wolfmux/memory/<project-key>/<team>/`
(mode 700, copied once from `~/.config/wolfmux/memory-skeleton/`) as `autoMemoryDirectory`, a short "Team
memory" block at the end of its system prompt (`--append-system-prompt`, no new hook: the folder, the
rules, and "Run `<dir>/bin/mem boot` before anything else, and again after every compaction": the lead
is told to run it again after every compaction, and nothing enforces that in v1.22.0), and a
first prompt at EVERY launch: `Team memory is on. Run <dir>/bin/mem boot, read what it prints, re-create
the crons it lists, then read your Beads inboxes.` "That lead" means: the lead of the named team, while
the owner founded that team (`team_founder` is the operator) and the folder's `bin/mem` can run. A team
another lead founds under the same name after a `destroy --purge` or a `finish` gets nothing. No
restart, restore or model change moves a team's founder (`lead_restore` carries it on), so `enable`
refuses a team an agent founded rather than promise a memory its lead would never get; `teamctl memory
adopt <team>`, the owner's alone (`require_operator`), makes the owner that team's founder first (the
lead's `spawned_by` and `meta.json`'s `founder`), logged in `team-memory.jsonl` and the team's event log,
and the founding agent loses what a founder may do while the lead is down. While the policy is on,
`--continue` is refused for EVERY lead of the project that has no stored conversation id (round 3: all
leads share one transcripts folder, so any of them could open the memory lead's newest conversation).
Workers are refused the folder, and the folder of the leads' conversations, by the worktree guard.
`teamctl memory check`, `teamctl memory path` and `teamctl capture` of that lead's pane are the owner's
(and, for `check` and `path`, that lead's); capture stays the owner's for as long as the running lead's
settings carry `autoMemoryDirectory`, whatever the policy says by then.
Nothing deletes the folder except `destroy --purge --memory`, which is the owner's alone by the pane
proof (`require_operator`), and `uninstall.sh --purge --purge-memory`.

## Why the card is not in the prompt

The first version put `core/card.md` (cut at 4,000 bytes) into the prompt block. Review round 2 found
that a prompt is not private: `ps -axww -o command=` shows every agent's whole `--append-system-prompt`
text to every process of the user, and `teamctl _prompt lead --team <team>` prints the prompt to any
caller. So the block holds no note, only where the folder is and how to treat it, and the card is read
by `mem boot` inside that lead's own conversation, at every launch (the first prompt) and after every
compaction (the lead is told to; nothing enforces it in v1.22.0). The
boot also prints the card into that lead's pane, which is why capturing the pane is the owner's alone.
Five read channels were closed in the same round: the prompt (`ps`, `_prompt`), `teamctl capture` of
that lead's pane, the leads' transcripts in `~/.claude/projects/<project path>/` (every lead's
conversation is a `*.jsonl` file in that one shared folder), `teamctl memory check` / `path`, and an
agent's `destroy --purge --memory` behind a fake terminal.

## The boot prompt: which CLI forms take a first prompt

The boot prompt rides as the CLI's positional prompt, the last argument, as the worker kickoff already
does. The forms the memory lead can be launched with:

- fresh: `claude --session-id <id> "<boot>"` — the same form as every worker's kickoff since v1.9;
- resumed: `claude --resume <id> "<boot>"` — documented in the CLI reference as
  `claude -r "<session>" "query"` ("Resume session by ID or name"), and the CLI's own usage line is
  `claude [options] [command] [prompt]` (Claude Code 2.1.309);
- a stored id with no transcript yet: `claude --session-id <id> "<boot>"` again;
- `claude --continue "<boot>"` is never used for this lead: that launch is refused (above). The CLI
  reference documents `-c` with a query only for print mode (`claude -c -p "query"`).

A live interactive measurement through a bare pty (Python `pty`, Claude Code 2.1.309, Haiku, a scratch
folder) did not reach a first turn within 90 seconds for either form, so it neither confirmed nor refuted
them; the print-mode part of the same probe answered. The positional form therefore rests on the CLI's
documentation and on the fresh form already in daily use. No `teamctl nudge` fallback was built. A
resumed Codex lead is given no first prompt (`codex resume --last "<text>"` could read the text as a
session id) and the pane says so.

## Alternatives Considered

### Alternative 1: a SessionStart hook that prints the card
- **Pros**: no first prompt needed; runs on `/clear` too.
- **Cons**: a new hook in that lead's settings, a second channel beside the prompt, and a hook's output
  is context, not an instruction to act on (`mem boot` also re-creates crons).
- **Why not**: the prompt block plus the boot prompt does the same with nothing new to run.

### Alternative 2: any lead may enable its own memory
- **Pros**: no owner step.
- **Cons**: which conversation may keep notes no team can see is a decision about the owner's own work;
  a lead that wants it has every reason to grant it to itself.
- **Why not**: owner-only enable, as for `orphan-steward` and `lead-model`. Disable only narrows what
  is kept, so the lead itself may do it, and the owner is told.

### Alternative 3: `teamctl nudge` typed into the pane after launch
- **Pros**: works whatever the CLI's argument parsing does.
- **Cons**: typed text in a pane the human may be watching is what ADR-0028 removed; it races the CLI's
  own start screen.
- **Why not**: the positional prompt is documented; the nudge stays the fallback if a CLI ever drops it.

## Consequences

### Positive
- A restarted comms lead wakes up, runs `mem boot`, and works from its card instead of idling.
- `--continue` can no longer mix two leads' conversations while team memory is on: since review round 3
  every lead of the project needs a stored conversation id for it, not only the memory team's.
- Other teams' leads get no setting, no block and no prompt.

### Negative
- The guard changes for EVERY worker of the project, not only the memory team's: one awk pass
  (`GUARD_SCAN`, review round 4) unquotes every Bash word and spells `~`, `~<name>`, `$HOME` and
  `${HOME}` out as the home folder before any check (so `~/.wolfmux/state` is caught too), the
  `.wolfmux/memory` text rule applies to every worker, paths are compared without
  regard to letter case, and a worker's tree walk of `~`, `~/.wolfmux`, `~/.claude` or `/` (`grep -r`,
  `rg`, `find`, `ls -R`, `du`, `tar`, a Grep of the whole `~/.claude`) is refused with "search a
  narrower folder". The memory folder and the leads' transcripts are under the same home for all of
  them, so a rule for one team only would leave the others' workers a way in. A Bash check costs about
  20 ms (one jq and one awk, no fork per word). The cost is bounded by size, not by the clock: a command
  over 64 KB is refused before awk starts, the lexer counts characters, words and paths against a step
  budget, and a 5 s clock is only a backstop, because Claude Code runs a call whose hook times out.
- A change of the policy reaches a running lead only at its next restart; a change of `core/card.md`
  reaches it at its next `mem boot` (every launch; after a compaction only if the lead runs it, as it is
  told to: nothing enforces that in v1.22.0).
- One team per project.
- Built for a Claude lead. A Codex lead has no `autoMemoryDirectory` (its `MEMORY.md` is not loaded), and
  a resumed one (`codex resume --last`) opens the newest conversation of the shared folder and gets no
  first prompt. `teamctl memory status` warns when the memory team's lead runs Codex.

### Risks
- The guard reads text. Since review round 3 it resolves `..` and `./` words, follows a literal `cd`
  or `pushd`, checks the text handed to `sh -c` / `bash -c` / `eval` / a heredoc fed to a shell as a
  command, and refuses wildcards that can match a private folder. Since round 4 it reads the command
  in one pass as the shell does: quotes and `\` removed inside words, a pipe of `echo` or a heredoc into
  a shell, `ssh` and `watch` text, the pattern of a search tool never taken for a path, symlinks under
  the worktree followed, Claude Code's `sessions/`, `history.jsonl` and temporary folder closed. Since
  round 5 the hook matcher is `.*` (Monitor, PowerShell and any other tool are read), workers run the
  Bash tool in bash and zsh glob groups are read as groups anyway, a quoted word with a blank is a path
  when it holds a `/`, a word is also read with its run-time parts deleted (`mem${x}ory`), a link is
  followed where a path ends too, and the link-making forms with run-time words are refused. What it
  still does not see: a `cd` to a folder known only at run time (`d=~/.wolfmux; cd $d && cat memory/…`,
  which `tests/memory.sh` pins), a program known only at run time (`c=claude; $c -r <id>`), `CDPATH`, a
  path built at run time, code in another language that builds the path (`python3 -c "…"`), a script the
  command runs, and tree walkers it does not know (`cp -R`, `rsync`, `zip -r`). Every
  owner-only gate is a pane proof that a process can drop by unsetting `TEAM_ROLE` and `TMUX_PANE`; the
  worker guard refuses the obvious forms (`env -u`, `env -i`, `unset`, an `X=` prefix). Leads of other
  teams are not guarded at all, and a team with `worker-isolation off` has no guard. docs/SECURITY.md
  lists every layer and where it ends.
- `teamctl memory check` writes (it rebuilds `MEMORY.md` and the card) and prints ask ids and names, and
  `teamctl memory path` hands out the path for `$(teamctl memory path)`, which the guard cannot read: both
  are the owner's and that lead's only (exit 77 for anyone else). `teamctl memory status` stays open and
  prints sizes, counts and the policy; the folder's path and the lead's conversation id only to the owner
  and that lead (since round 3). Every view that prints conversation ids (`teamctl status`, plain and
  `--json`, `model --now`, `restore`, also when the orphan steward runs it) prints the memory lead's as
  `hidden` to anyone else; the records under `~/.wolfmux/state` still hold it (closed to workers, not to
  leads). The id is no secret: `ps -axww` and `~/.claude/sessions/<pid>.json` show it to every process
  on the Mac, so `hidden` is a courtesy. The control for workers is the guard's refusal of
  `claude --resume`; leads are not guarded.
- `destroy --purge --memory` is protected by the pane proof, not by the typed team name: a process can
  get a terminal from a piped `script -q /dev/null` and type the name itself.
- The boot prompt with `--resume` is documented, not yet observed on a live pane: the first real
  restart of the memory lead is that observation.
