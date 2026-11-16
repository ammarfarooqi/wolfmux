# ADR-0036: A long command output stays out of the context window

**Date**: 2026-11-16
**Status**: accepted
**Deciders**: the memory-management lead, from the v1.25.0 research (wolfmux-618, proposal 3)

## Context

Measured on 2026-11-16: Bash output is 33% of everything a worker adds to its context and 40% of
what the lead adds; a tenth of the steps make 36% of the growth. Claude Code never clears an old
tool result, so a test log read once is sent again with every later request until a compaction.

Claude Code 2.1.325 lets a `PostToolUse` hook replace a result (`updatedToolOutput`). Six probes
against the real CLI (`tests/research/results/offload-probes.md`) showed where that stops:

- For Bash the replacement must be the result OBJECT (`stdout`, `stderr`, `interrupted`, ...); a
  string is refused and the original kept.
- A command that exits non-zero fires `PostToolUseFailure` only, and its answer cannot replace
  anything. The CLI cuts that result to its first ~10,000 characters and saves nothing: the FAIL
  lines at the end of a failing suite never reached the model.
- Above 30,000 characters a successful result is saved by the CLI, with a 2 KB head preview.
- A `PreToolUse` hook's `updatedInput` may rewrite the command, and the exit code still arrives.

## Decision

1. **Rewrite the command (PreToolUse, Claude family).** `teamctl _offload-pre`, its own hook entry
   next to the worktree guard, puts one prefix on the first line of every Bash command: stdout and
   stderr go to `$STATE_DIR/run/<role>/out/<n>.log` and an EXIT trap (TERM and INT too) prints the
   result, whole when it is at most `WOLFMUX_OFFLOAD_MIN` characters (4000), else shortened: the
   first and last 40 lines, the lines between that match `FAIL|[Ee]rror|panic|not ok` (at most 60),
   the counts, the exit code and the path with "search it with grep; do not cat it". The command
   runs once, unchanged, in the same shell: cd, export and its exit status stay as they were. No
   permission decision is made; a call another hook denies stays denied.
2. **Never wrapped**: `run_in_background`, a command with the word `exec` (it would replace the
   shell and its trap), a command with the word `trap` (its own EXIT trap, or `trap - EXIT`,
   replaced ours: the output stayed in a log the model was never told about), a command already
   wrapped. When the prefix cannot set itself up (helper
   missing, log not writable) it does nothing; when the helper fails at the end, the log is printed
   whole.
3. **Safety net (PostToolUse)**: a long exit-0 result the rewrite did not cover is replaced by the
   shortened form, as the result object; above 30k the CLI's own saved file is the full text. The
   hot path learns the size with the `read` builtin (at most `WOLFMUX_OFFLOAD_MIN` characters), so
   a short result costs no fork; only when the read does not hit the end is the module loaded.
4. **Backstop**: `bashOutputMaxChars` and `BASH_MAX_OUTPUT_LENGTH` at 16000 for every agent with the
   feature on.
5. **Codex family**: no hook can rewrite its results, so `teamctl run -- <command>` does the same
   with the same code; the protocol tells agents so.
6. **Switch**: policy `output-offload` (on by default, lead and workers alike) and
   `WOLFMUX_OFFLOAD=off`. Off: not one hook entry of this feature is written. Logs are pruned to the
   newest 200 per role.

## Consequences

- A failing test's last lines and its failure lines in the middle now reach the model, where
  before they were cut away; the full log stays one `grep` away.
- Proven under both shells the CLI uses: `tests/offload.sh` runs its plain-against-wrapped corpus
  (output, exit code, cwd, exports) under `/bin/bash` (a worker's) and `/bin/zsh` started as the
  CLI starts it (the user's shell on a Mac, so a lead's), plus the long-output and TERM checks.
  No shape differed under zsh, so none is excluded for it.
- stderr is merged into stdout in the order written (it was stdout first, then stderr).
- Cost per Bash call, measured on the owner's Mac: PreToolUse 6 ms (3 ms with the feature off; jq
  alone 3 ms). PostToolUse for a short result unchanged (no fork); a long one 34 ms.
- A command that `exec`s, sets or resets a trap (any command with the word `trap`, `grep trap`
  too), or runs in the background, is covered only by the safety net and the backstop.
- An agent can still `cat` the log; the protocol says not to, and the shortened form says so.
- The prefix is visible in the CLI's own record of the call only as the hook's rewrite; the
  transcript keeps the agent's command (probe 6).
