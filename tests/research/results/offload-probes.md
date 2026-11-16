# Offload probes (v1.25.0 stage A, wolfmux-ik5), 2026-11-16

Claude Code 2.1.325, `claude -p --model haiku --settings <scratch> --allowedTools Bash --output-format stream-json`,
run by `tests/research/offload-probe/probe.sh`; hook: `tests/research/offload-probe/hook.sh`. Each directory
`offload-<n>-*` holds the settings, what the hook received (`input-*.json`), the stream and the answer.
"Model got" is the `tool_result` block in the stream, i.e. what went to the model.

| # | Hook | Command | Event that fired | Model got |
|---|---|---|---|---|
| 1 | PostToolUse, `updatedToolOutput` = a string | `echo PROBE-ORIGINAL-4410` | PostToolUse | the ORIGINAL. Transcript: `hook_error_during_execution`: "updatedToolOutput that does not match Bash's output shape; using original output ... expected object, received string" |
| 2 | PostToolUse, `updatedToolOutput` = `{stdout, stderr, interrupted, isImage, noOutputExpected}` | same | PostToolUse | the REPLACEMENT only (`stdout` + newline + `stderr`) |
| 3 | PostToolUse + PostToolUseFailure, object | `echo OUT; echo ERR >&2; exit 3` | PostToolUseFailure ONLY (`tool_response: null`, `error: "Exit code 3\nOUT\nERR"`) | the ORIGINAL; the replacement is ignored without any error row |
| 4 | PostToolUse, no answer | `seq 1 60000` (340.7 KB) | PostToolUse; `tool_response.stdout` = first 30,000 chars, plus `persistedOutputPath`, `persistedOutputSize` | `<persisted-output>` block: path of the full file + first 2 KB (head only) |
| 5 | PostToolUse + PostToolUseFailure, object | `seq 1 60000; echo PROBE-FAIL-MARKER >&2; exit 1` | PostToolUseFailure ONLY, `error` = 10,040 chars | the first ~10,000 chars; the stderr line PROBE-FAIL-MARKER is NOT in what the model got, and no file is saved |
| 6 | PreToolUse, `updatedInput: {command: "..."}`, no permissionDecision | `echo PROBE-ORIGINAL-4410` | PreToolUse | the REWRITTEN command ran: "Exit code 4\nPROBE-REWRITTEN-5512\nPROBE-REWRITTEN-ERR"; the transcript keeps the model's original command |

Conclusions:
- `updatedToolOutput` works for Bash only as the Bash result OBJECT, and only for a command that exits 0.
- A command that exits non-zero (a failing test run, the case that matters most) fires `PostToolUseFailure`,
  whose answer cannot replace anything. Its result is cut by the CLI at about 10,000 characters, head only:
  the failure lines at the end of a long log never reach the model and are not saved anywhere.
- Above 30,000 characters a successful result is already persisted by the CLI, preview = first 2 KB.
- A `PreToolUse` `updatedInput` rewrite of the command is honoured and keeps the exit code: the only hook
  route that also covers failing commands.

## Proof of the feature (probes 7 to 10, `tests/research/offload-probe/probe2.sh`)

The real hooks of this checkout (`teamctl _offload-pre`, `teamctl _hook PostToolUse` with the safety net, the
backstop settings), same CLI and model. The run logs themselves are not kept here.

| # | Command | Model got | Answer |
|---|---|---|---|
| 7 | `seq 1 30000; echo "not ok 9 - PROBE-MIDDLE-FAIL"; seq 30001 60000; echo "PROBE-FAIL-MARKER at the end" >&2; exit 1` | "Exit code 1", the shortened form (60002 lines, 348952 characters, exit code 1, the log path), `30001: not ok 9 - PROBE-MIDDLE-FAIL`, the last 40 lines ending in the marker | exit code 1, last line the marker, both FAIL lines |
| 8 | `echo PROBE-OUT-1; echo PROBE-ERR-2 >&2; exit 3` | "Exit code 3\nPROBE-OUT-1\nPROBE-ERR-2", identical to probe 3 without the feature; no log left | exit code 3 |
| 9 | `touch <marker>; echo touched`, with a second PreToolUse entry that denies (as the guard does) | "PreToolUse:Bash hook error: probe guard: refused" | never ran: the marker file does not exist |
| 10 | `exec seq 1 5000` (not rewritten: exec) | the safety net's shortened form, as the Bash result object (5000 lines, 23893 characters, path) | |

No settings warning from the CLI for `bashOutputMaxChars` or the env entries (stderr.txt).
