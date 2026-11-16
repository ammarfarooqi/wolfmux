# Hand-over: wolfmux-g6k Part B (one context number, a compaction that cannot thrash)

For the worker who builds it. Written 2026-11-16 by `research`, who measured it and built Part A but did not
start Part B. Nothing of Part B is in the code yet. The task text is `teamctl show wolfmux-g6k` (Part B, rows 1
to 6); the design it accepts is proposal 1 in `tests/research/results/v1.25-research.md`.

Branch: `ai/memory-management/research-20261116-111031`, v1.24.0 (origin/main 1eced6e) merged, Part A on top.

## What is measured (do not measure it again)

| Fact | Number | Source |
|---|---|---|
| The CLI compacts at about its window minus 33,000 | 165-171k of 200k (Opus); 66-89k of 100k (Haiku); the docs say about 967k of 1M | port worker's transcript; run 4; code.claude.com/docs/en/model-config.md |
| After a compaction the next request is F + kept | kept (`postTokens`) 19-47k; next request 123-147k (port), 62-85k (run 4) | `compact_boundary` rows |
| Too little room thrashes | run 4: window 100k, F 54k: 10 compactions in 5 min, 231 s standing still, then the CLI stopped | `results/runs.jsonl`, report 1.4 |
| The same task with no compaction | 4 commits in 94 s, peak 97,365 tokens | run 3 |
| F for a trimmed worker on this machine | 54,289 in a pane (run 2: v1.25.0 trim + the zh exclude); 81,024 before Part A | report 1.1 |
| F for the lead | 115,652 (full), 70,017 (trimmed) | report 1.1 |
| The watch today | divides by `model_context_window` (1,000,000 for Haiku, 200,000 fallback): it said 6% while the CLI compacted | run 4, `run/w1/memory/ctx` |

Facts about the transcript (Claude Code 2.1.325) that the code will need:

- A compaction is one row `{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto",
  "preTokens":N,"postTokens":N,"durationMs":N}}`. K is `postTokens` of the last one.
- F is the usage of the first assistant row: `input_tokens + cache_creation_input_tokens +
  cache_read_input_tokens` (the sum `models_transcript_tail` already uses for the last row).
- **SessionStart with source `compact` fires after every compaction** (run 4: 20 hook runs for 10 compactions,
  two hooks each). That is where a compaction can be counted.
- **The CLI's thrash stop fires no hook at all.** It is an assistant row with `isApiErrorMessage: true`, model
  `<synthetic>`, text starting "Autocompact is thrashing: the context refilled to the limit within 3 turns of
  the previous compact, 3 times in a row", followed by `turn_duration`. No Stop hook ran in that whole
  conversation. So "the CLI's thrash message" cannot be caught by the agent's own hooks: either the count at
  SessionStart:compact catches it first (two compactions within 10 requests comes before "3 times in a row"),
  or something outside reads the transcript tail (`teamctl status`, the mail watchdog). Do the count first.
- The CLI accepts `CLAUDE_CODE_AUTO_COMPACT_WINDOW` from 100000 to 1000000 and caps it at the model's window.
  It is read when the process starts. **It cannot be changed in a running conversation from outside**, so
  "the window is set from what was measured" means: computed at spawn and at restart from what was stored.

## Not known. Find out first, each is one cheap check.

1. **Does a PostToolUse hook inside an in-process subagent say so?** Two of my research subagents got the
   watch's "commit and checkpoint" text, so the hook fires there. I did not look at its input. Probe (print
   mode, Haiku, no pane): a PostToolUse hook that appends stdin to a file, and a prompt that makes the model run
   one Bash command through the Agent tool and one itself. Compare the two inputs: `agent_id`, `agent_type`,
   `transcript_path`. If nothing tells them apart, compare `transcript_path` with the agent's own session id
   (`reg_field <role> session_id`) or skip when the path contains `/subagents/`.
2. **Why a compact window given to `teamctl spawn` or `teamctl task --spawn` is ignored.** Seen: with
   `WOLFMUX_WORKER_COMPACT_WINDOW=100000` only on the spawning command the worker got 1,000,000; set at
   `teamctl start` it got 100,000. My reading, not traced: the settings file is written by
   `teamctl _run-agent` INSIDE the pane (`cmd_run_agent` calls `write_agent_settings`, `lib/agents.sh`
   about line 1084), and a pane has the tmux server's environment, not the spawning command's. If so, the fix
   is to record the value on the agent's registry record at spawn (`reg_set`) and read it there.
3. **Does the statusline command run in a pane nobody is attached to?** It is the CLI's own number for the
   "within 5% of /context" check (see Tests). If it does not run, type `/context` through the lead.
4. **Codex.** `_ctx_of_codex` reads the window from the rollout's `token_count` event. Its docs say it compacts
   at 90% of the window. I measured nothing. Keep Codex on its own window and say so.

## The design, in the order to build it

1. **One constant, one function.** `WOLFMUX_COMPACT_RESERVE=33000` in `lib/policy.sh`, with a comment that it
   is observed on two windows and stated nowhere by the vendor. `context_limit <window>` = window minus the
   reserve. Everything below uses it.
2. **Record what the conversation measured.** In `lib/recall.sh` (the watch): F once per conversation (read
   the head of the transcript, not the tail), K at SessionStart:compact (the last `compact_boundary`), the
   window the agent was started with. `run/<role>/memory/ctx` already holds `{tokens, window, percent, at}`:
   make it `{used, limit, window, first, kept, percent, at}`. Keep a copy that survives the agent
   (`run/<role>/` is deleted with it): a field on its registry record or a file per kind under `$STATE_DIR`,
   so a NEW worker starts from the last F measured for a worker of this team.
3. **The window.** `worker_compact_window` (`lib/policy.sh`) becomes: the override if given (row 2 of the
   task, and unknown 2 above), else `F + K + reserve + room`, with F and K from step 2, K = 45000 until a
   compaction happened, room = `WOLFMUX_CONTEXT_ROOM` (150000), clamped to 100000..min(model window, 1000000).
   With no F on record use a default that errs high (a worker 90,000). The lead gets no window today
   ("its compaction is its own", pinned by a smoke check): leave that, its limit is its model window minus
   the reserve.
4. **One figure.** `agent_context` (`lib/agents.sh`) is the one place status and the dashboard get
   `CTX_TOKENS` and `CTX_WINDOW` from. Add `CTX_LIMIT`; `ctx_display` (`lib/views.sh:122`) and
   `dash_context_label` (`lib/dashboard.sh:452`) print used / limit. The watch's percent is `used * 100 /
   limit`, and `WOLFMUX_CONTEXT_WARN` / `_ROTATE` are shares of the limit. The window an agent runs with must
   be readable by a view: the settings file of the agent has it (`.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW`), or
   put it on the registry record when the settings are written.
5. **The watch stays out of subagents** (unknown 1).
6. **Thrash.** At SessionStart:compact append the call counter (`run/<role>/calls`) and the time to
   `run/<role>/memory/compactions`. Two entries within 10 calls of each other: one message to the lead
   (`memory_store_lead_message`, as `_memory_tell_lead` does), once per conversation, with used, limit, F, K,
   the window and the two times. The task says "within 10 requests"; the counter counts tool calls, which is
   what a hook can read for free. Say that in the ADR. Rotation is proposal 4 and NOT in this task.
7. ADR (next free number after 0037; 0036 is the offload ADR, 0037 is Part A), `docs/USAGE.md`,
   `docs/ARCHITECTURE.md` section on context.

## Files

`lib/recall.sh` (watch, thresholds, SessionStart, the lead message), `lib/policy.sh` (`worker_compact_window`,
the constant), `lib/agents.sh` (`write_agent_settings` about line 960, `agent_context` about 1850,
`_ctx_of_transcript`, `cmd_spawn`), `lib/models.sh` (`models_transcript_tail`: reads the tail only),
`lib/views.sh`, `lib/dashboard.sh`, `lib/common.sh` (`model_context_window`), `lib/provider-env.sh` (the
config allow list), `bin/teamctl` (the PostToolUse hot path counts calls above the module loader).
Do not edit `lib/memory.sh` or `tests/memory.sh`.

## Tests

Stub suites that pin what you will change, so expect to update them and keep their counts:
- `tests/smoke.sh:430` and `:434` (the compact window a worker is told; `off`; the accepted range), `:890`
  (the lead has no window), and the exact `.policy == {...}` object at `:497`.
- `tests/stub-agent:92` prints `STUB compact=` from the settings file.
- `tests/recall.sh` (31 checks: the watch, thresholds, checkpoints) and `tests/dashboard.sh` (136 checks, the
  CONTEXT column) and `tests/models.sh`.
- `tests/docs.sh`: every policy key must be named in `teamctl help`, README.md, docs/USAGE.md and the manual
  (`config/wolfmux/README.md`); every key of `WOLFMUX_CONFIG_KEYS` must be in the config template and explained
  under docs/ or in the manual. A new setting fails this suite until all of them name it.
- `tests/inbox.sh` "settings drift" checks list the exact keys of a settings file.

Real CLI, at most 6 pane runs (the lead presses the keys of the trust dialog, once per project path):
- `tests/research/iso.sh <scratch> <command>` runs a command in an isolated wolfmux. `<scratch>/bin` holds
  symlinks (`teamctl`, `claude-fable`, `claude-haiku`, `claude-sonnet`, `claude-opus`, the last four to
  `bin/claude-fable`), `<scratch>/proj` is the project. `ISO_DATA=<name>` gives each run its own data
  directory; keep ONE project path. Act as the operator (no `TEAM_ROLE`): `ISO_AS=lead` is refused by the pane
  proof. A setting under test goes into `ISO_ENV="NAME=value"` ON `teamctl start`.
- The project of runs 3 and 4 is `tests/research/fixtures/calc/` (copy it, `git init`, one commit); the task
  text is `tests/research/fixtures/task-four-helpers.md`. Spawn with
  `teamctl task w1 "<title>" --body-file <task> --spawn haiku`.
- Read the result with `tests/research/transcript-profile.py`, `timeline.py`, `latency.py` on the worker's
  transcript (`~/.claude/projects/<path with non-alphanumerics as dashes>/*.jsonl`; a long path is shortened
  with a hash, list the directory).
- End with `teamctl destroy --worktrees --yes`. The guard refuses raw `tmux -L`; `teamctl capture <role>`
  reads a pane.
- The three checks of the task: (a) run 4 again: with the new default the window is about 54k + 45k + 33k +
  150k = 282k and the task peaks at 97k, so it passes with no compaction. That proves little. Also run it with
  `WOLFMUX_CONTEXT_ROOM` small enough that one compaction happens (room 0 gives a 132k window, limit 99k), and
  show that the warning arrived first and that it did not thrash. (b) "the warning arrives before the CLI
  compacts": the watch looks every tenth tool call, so a 20k read between two looks can jump the threshold.
  If it does, look when the transcript grew by more than a set amount, not only every tenth call. (c) status
  against the CLI: a `statusLine` command in the scratch project's `.claude/settings.json` that writes its
  stdin to a file gives `context_window.current_usage`; note that its `used_percentage` is of the FULL model
  window, not of the compact window, so compare tokens, not percent.

## Traps I fell into

- The Bash tool runs zsh: `$var` is not split into words, and a heredoc inside a heredoc ends at the first
  `EOF`. Use distinct markers.
- A project `.claude/settings.json` left in the scratch repo silently applied to every later probe there.
- Probes of the "before" state vary by 17k tokens with whether the claude.ai connectors had connected.
- Running two long suites at once works (own sockets), but smoke takes 11 minutes; start it in the background.
- `teamctl policy` output and `status --json` are compared literally in smoke; a new key changes both.
- The owner's rule files re-enter your context when you touch a file type (path-scoped rules). Normal.
