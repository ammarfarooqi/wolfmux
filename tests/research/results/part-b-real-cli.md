# Part B on the real CLI (wolfmux-cj3): what four pane runs showed (of the six allowed)

Measured 2026-11-16 by `ctx2` with Claude Code 2.1.325, Haiku 5.5 lead and worker, `tests/research/iso.sh`
(socket `wolfmux-ctx2`, one project path `scratchpad/rc/proj`: the calc fixture of runs 3 and 4 of the
research, plus a project `.claude/settings.json` with a `statusLine` command that keeps its stdin and a
probe hook on SessionStart and PreCompact that writes the hook's `CLAUDE_CODE_AUTO_COMPACT_WINDOW`
and how many `compact_boundary` rows the transcript holds at that moment).

Task texts: run 1 `tests/research/fixtures/task-four-helpers.md`; runs 2 to 4 the same with two history
files of about 104 KB each (about 23k tokens each) that must be read in full first (`task-big.md`, below).

## The runs

| Run | Settings on `teamctl start` | Window (limit) | First request F | Peak | Compactions | What the lead got |
|---|---|---|---|---|---|---|
| 1 | room 0, min room 0, F 54000 | 132000 (99k), then 141000 (108k) after the lead restarted w1 and F was measured | 62277, 62950 | 86833, 83929 | 0 | nothing (none due) |
| 2 | room 0, min room 0, F 63000 | 141000 (108k) | 62382 | 137124 | 2, 4 tool calls apart (pre 109628 post 63390; pre 165158 post 17894) | ONE "compacted twice within 4 tool calls" message; it restarted w1 with `WOLFMUX_WORKER_COMPACT_WINDOW=180000` |
| 2b | the lead's restart: window 180000 (147k) | | 62780 | 131209 | 1 (pre 160446 post 45718) | the 80% message ("118k/147k 80%") BEFORE that compaction; it restarted w1 again; the third conversation finished the task (peak 79923, no compaction) |
| 3 | room 0, min room 0, F 63000, K floor 20000 (a thrash on purpose, with the fix e029b1e) | 116000 (83k) | 62418 | 136388 | 2, 2 tool calls apart (pre 109439 post 63366; pre 138832 post 18123) | ONE message, now with the second compaction's numbers: "before the second: 138832 tokens of a limit of 83000 ... first request 62418; kept by this compaction: 18123 ... room about 2459" (83000 - 62418 - 18123 = 2459: right). It restarted w1 with 200000 |
| 4 | defaults (only `WOLFMUX_STALL_AFTER=60` for the stall below) | 318000 (285k): 90000 + 45000 + 33000 + 150000, nothing measured yet | 62428 | 203229 | 0 | nothing; t1 closed in about 3 minutes, 73 requests |

## What is now confirmed

- **`CLAUDE_CODE_AUTO_COMPACT_WINDOW` from the settings file is in a hook's environment**: the probe hook
  printed 132000, 141000 and 180000, the windows of the three starts. The watch can rely on it.
- **The `compact_boundary` row is NOT in the transcript when SessionStart:compact fires.** The probe counted
  0 rows at the first SessionStart:compact of two conversations, and at the second only the first one
  (its postTokens 63390). The row follows within a second. v1.25.0 as built by `ctx` therefore recorded the
  previous compaction's K, and its thrash message said "before the second: 109628, kept 63390, first
  request not measured, room unknown" where the truth was 165158, 17894, 62382 and about 27.7k.
  Fixed (e029b1e): the hook counts the rows; when the new one is not there yet a background job waits for
  it (up to `WOLFMUX_COMPACT_WAIT`, 30 s), then records K, measures F if no look did, and sends the thrash
  message with the second compaction's numbers. Stub check in `tests/recall.sh`, red before the fix.
- **The statusLine command runs in a pane nobody is attached to** (115 records in run 2).
- **Check (c): status against the CLI's own number.** At 1794834216 `teamctl status --json` gave w1
  `context_tokens` 79923 and the newest statusLine record of the same conversation `current_usage`
  2 + 254 + 79667 = 79923: equal. The CLI's `used_percentage` was 8 (of its 1M model window); status
  said `80k/147k 54%`. The lead: 133159 against a statusLine record 216 s older, 132831.
- **Thrash, real**: two compactions 4 tool calls apart gave the lead exactly one message (run 2, m1), and
  the lead acted on it. A third compaction in the same conversation sent nothing more.

## A stalled agent, staged faithfully (run 4)

Worker w2 got a stand-in task (claim it, write a file, end the turn and wait) and sat idle with t2 in
progress. At 13:09:28Z the two rows this machine's transcripts hold from the real 529 of this morning
(`isApiErrorMessage: true`, model `<synthetic>`, "API Error: 529 Overloaded. This is a server-side issue
...", then `turn_duration`, from 2026-11-16T07:37:50.822Z) were appended to w2's transcript, rewritten only
in `sessionId`, `parentUuid` and `timestamp`. Nothing else was touched: the lead (a real Haiku 5.5) was
idle with its wake waiter armed since 13:08:39.

- 13:10:55 event `stall w2 by lead`: the idle lead's wake waiter looked (87 s after the rows: 60 s of
  quiet plus at most one 60 s look interval) and filed ONE message, m1 "w2: stalled on an error since
  2026-11-16T13:09:28.000Z" with the error's first line, "idle for 1 min, with task t2 in progress", and
  `teamctl restart w2 --continue` then `teamctl send w2 "go on with t2"`. The same loop handed it over.
- 13:11:43 the lead ran `teamctl restart w2 --continue` and sent w2 a message (m4). No second stall
  message was sent (one stamp, `state/stall/w2.20261116130928000`).

The lead's tenth-call looker and the status looker are covered by stub checks only.

## Check (b): the warning and a big read

Run 2 shows the case the watch cannot cover: the worker read both history files in ONE request (two
parallel Read calls). The request before was 63332 tokens (59% of 108k), the next one would have been
about 110k: the CLI compacted at once (preTokens 109628). No look of the watch had happened yet (it looks
on the tenth call, or on every call within 10 points of a threshold once a look has set the `near` file),
and no look could have helped: the hook only sees the usage of the last ANSWER, which does not include a
tool result that has not been sent yet. A jump of 43 points in one request is warned by nothing; the
PreCompact hook still writes the checkpoint section before the compaction. In run 2b the warning did come
first: "118k/147k 80%" reached the lead before the compaction at 12:58:18.

## task-big.md

```
Implement the four helpers that docs/spec.md specifies (mul, div, mod, pow) in lib/calc.sh.

- First read docs/history-1.md and then docs/history-2.md, each IN FULL with the Read tool (no offset, no limit,
  no grep, no head or tail): the reviewer checks that you saw their last lines. Write the checksum word of each
  file's last line into NOTES.md.
- docs/spec.md is the only source of truth for the helpers: read it in full before you start, the special cases
  are in it.
- One function per commit, in the order of the document, each with its checks in tests/run.sh.
- Before every commit run `bash tests/run.sh` and read its complete output (do not cut it).
- Keep a short log of each step in NOTES.md (what you added, the last line of the suite) and commit it with the step.
- When all four are in: teamctl done, naming the test command and its result.
```

The history files: 1300 lines each of nine random words from a fixed list and a number, Python
`random.seed(7)`, ending "END OF HISTORY n: the checksum word is amber|cobalt".
