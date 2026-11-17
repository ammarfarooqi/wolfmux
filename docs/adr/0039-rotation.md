# ADR-0039: Rotation: a nearly full worker gets a fresh conversation, with a hand-over wolfmux writes

**Date**: 2026-11-17
**Status**: accepted. Built: `teamctl rotate`, the hand-over, policy `worker-rotation`, `restart --continue` waking an agent with a task in progress.
**Deciders**: the owner, the memory-management team's lead (scope), its rotate and rotate2 workers (code, tests, the real-CLI run)

## Context

Measured with Claude Code 2.1.325 (`tests/research/results/v1.25-research.md`, 1.4 and 1.5; ADR-0038):

- A worker whose conversation is nearly full compacts: the CLI keeps 19k to 47k tokens and stands still
  20 to 190 s each time. Or it waits until the lead restarts it by hand. v1.25.0 only reports both.
- "Restart the worker" had never been tested with uncommitted work in the tree. In the one measured restart
  (1.5) the new conversation found its place in 2 requests, 9.6 s and 117k input tokens, but only because
  that task demanded a step log in NOTES.md.
- The checkpoint the agent is asked to write (`teamctl checkpoint`) was not written in any measured run.
- `teamctl restart <role> --continue` left an idle agent idle until somebody messaged it.

## Decision

1. **`teamctl rotate <role> [--reason <text>] [--now]`** (`lib/rotate.sh`). The lead may rotate any worker
   of its team; a worker may rotate only itself, through the pane proof (exit 77 otherwise). The lead role
   is refused in this release (restart it), and so is a Codex agent.
   - **wolfmux writes the hand-over**, nobody is asked: `run/<role>/memory/handover.md`, beside
     `checkpoint.md`, at most `WOLFMUX_HANDOVER_CHARS` (12,000) characters. Parts, in order, each with its
     own cap so none can push another out: a. the role's task in progress (id, title, body, notes; native
     store or Beads), 3,200; b. the agent's own checkpoint text, without the automatic sections, 1,500;
     c. the commits since the base, `git status --short`, `git diff --stat` staged and unstaged, 2,800;
     d. the last five answers of the main conversation (text blocks only: no tool call, no thinking, no
     subagent), each cut at 1,500, newest last, 3,200 in all; e. the paths (old transcript, `run/<role>/out/`,
     the hand-over); f. the reason and who asked; e and f together 900.
   - Then `cmd_restart` gives the same role a fresh conversation in the same worktree, on the same branch,
     with the same model and settings; the compact window is worked out again as at a start. The old id is
     kept in the record (`rotated_from`) and in `memory/rotated`; `teamctl restart <role> --resume <id>`
     reopens it.
   - The new conversation's SessionStart (source `startup`) carries the hand-over first, before the notes
     and the mail briefing, with one line: a fresh conversation for the same task, the work in the tree is
     yours, do not start over. Once: a `handover.pending` file is removed when it is shown, so a later
     compaction, resume or second start does not show it again.
   - The task stays in progress and assigned. Nothing in the tree is stashed, reset or cleaned.
   - **Timing**: by default it waits until the agent's turn has ended (its Stop hook writes `idle` to
     `run/<role>/state`), at most `WOLFMUX_ROTATE_WAIT` (120) seconds, so the restart does not land in the
     middle of a write. When that runs out it refuses, says so and names `--now`. `--now` does not wait.
   - One rotation at a time per role: `run/<role>/rotate.lock`, a directory (`mkdir` is atomic). It is
     removed after a subshell, not by an EXIT trap, because another module replaces the EXIT trap.
   - The lead gets one notice per rotation (role, reason, who asked, old and new figure, the hand-over
     path), not when the lead ran the command itself. The new figure is the team's measured first request
     and the new limit, not a reading of the new conversation (it has made no request yet).
2. **Policy `worker-rotation off|ask|auto`, default `auto`.** At a worker's Stop (`rotate_at_stop`, from
   `recall_hook`): at or past its rotate threshold (`WOLFMUX_CONTEXT_ROTATE`, a share of the limit,
   ADR-0038), or after the thrash event (two compactions within `WOLFMUX_THRASH_CALLS` tool calls),
   - **auto**: it is rotated at that turn end. The agent is not asked.
   - **ask**: the lead gets one message with the exact command, `teamctl rotate <role>`.
   - **off**: v1.25.0's behaviour.
   The hook does only file tests and one jq; it takes the lock and starts `teamctl _rotate-auto` detached
   (as `memory_store_lead_message` is started), which asks the policy, the family and the task store. It
   fires at most once per conversation (`memory/rotate-fired`). A conversation a rotation started that is
   itself past the threshold at a Stop is NOT rotated again: the lead gets v1.25.0's context message
   instead, because a loop of rotations would be worse than the problem. Never in a subagent (input with
   `agent_id`), never for the lead, never for Codex, never while the role has no task in progress. The
   v1.25.0 notices (80%, thrash) now name `teamctl rotate` instead of `teamctl restart`.
3. **`teamctl restart <role> --continue` wakes an agent with a task in progress**: one notice through the
   inbox (`inbox_add`, the path every notice takes): "continue task <id>".
4. **Protocol**, worker section, two lines: a task of more than one step keeps a short step log in the
   task (`teamctl note`); after a rotation, read the hand-over and continue, do not start over.

## What was measured

Stub checks (`tests/rotate.sh`, 32, native store and Beads with a `bd` stub): caps (a 50,000-character
task body leaves the git part, the answers, the paths and the reason in place, whole file at most 12,000),
the order of the parts, own checkpoint text only, five answers without thinking or tool calls, the refusals
(lead role, a worker rotating another, the wait running out, the lock), `--now`, the default wait that ends
when the agent goes idle, a fresh id with the old one kept, the same worktree and the uncommitted file
untouched, the task still in progress, one notice to the lead, delivery once, policy off, ask and auto,
`agent_id` input, under the threshold, no task, no second automatic rotation, the lock at Stop, the thrash
event, `restart --continue` filing "continue task <id>" and not for an agent without a task. On main
(7883db6) the same file gives 10 passed and 19 failed of the first 29: the 10 are the refusals and no-ops.

The real CLI: see "The real-CLI run" below.

## The real-CLI run

REAL_CLI_RUN

## Consequences

- A worker past its rotate threshold no longer compacts its way to the end: its next turn end gives it a
  fresh conversation of about its first request plus the hand-over (at most 12,000 characters, about 3k
  tokens), where a compaction kept 19k to 47k and stood still.
- Records gain `rotated_from`; run directories gain `memory/handover.md`, `memory/handover.pending`,
  `memory/rotated`, `memory/rotate-fired`, `rotate.lock`, `rotate.log`.
- A rotation at a Stop restarts the pane right after the turn ended. A turn that ended only to wait for a
  long background command loses the wait (the command's output is in the tree or in `run/<role>/out/`).

## Not covered

- The lead is not rotated. A lead's conversation holds the team's plan, and a hand-over for it was not
  designed.
- Codex agents are not rotated: where Codex compacts was not measured (ADR-0038), and its resume path differs.
- The hand-over cannot carry what was only in the conversation and not in an answer, a note, a commit or
  the tree. The step log in the task (protocol) is what covers that.
- The wait reads the Stop hook's `idle`; an agent stuck in a dialog or a hung tool never gets there, so
  only `--now` rotates it.
- One real-CLI run, Haiku, a toy task. Not measured on Opus or Fable, not measured under `ask`.
