# Verification

No model call was made to test this system. Real CLIs were only started as far as
their first screen; everything else used stub agents or a localhost mock.

## Re-run it

```bash
tests/smoke.sh                 # 5 to 7 minutes, 348 checks, isolated from any running team
                               # (how many PASS depends on the launch: one skip per signal it
                               #  leaves ignored — see smoke.sh below)
tests/disk.sh                  # ~2 minutes, 93 checks, its own tmux server and state
tests/nudge-typing.sh          # ~2 minutes, 61 checks, its own tmux server and its own pty client: a notice never lands in a half-typed line
tests/inbox.sh                 # ~4 minutes, 107 checks, its own tmux server and its own pty client: nothing is typed into the human's conversation while he is working in it
tests/providers.sh             # the provider table and the config allowlist, 141 checks
tests/docs.sh                  # ~3 seconds, 36 checks, starts nothing
tests/dashboard.sh             # ~90 seconds, 115 checks, its own tmux server and state: the machine-wide view and the status segment
tests/migration.sh             # ~40 seconds, 36 checks, in a throwaway HOME
tests/permissions.sh           # ~5 seconds, 13 checks, in a throwaway HOME
tests/credential-routing.sh    # manual; needs claude logged in; see the header for side effects
teamctl doctor
```

**950 checks across the nine countable suites, smoke counted once in its clean shape, and
950 passing, 0 failing** (v1.16.1). Every figure measured under the heavy lock, in ONE
acquisition, with `SIGHUP` and `SIGINT` reset to their defaults by a parent that then
`exec`s, and **all nine at `ded20f1`** — `smoke` 348, `disk` 93, `nudge-typing` 61,
`inbox` 107, `providers` 141, `docs` 36, `dashboard` 115, `migration` 36,
`permissions` 13.

All nine figures come from ONE commit and one acquisition, where v1.16.0 needed two of
each. The tree being shipped is one commit later than `ded20f1`, and the difference is
only the sha you are reading: `ded20f1` wrote these documents with a placeholder where its
own sha had to go, which no commit can contain, and the next commit replaced that
placeholder in this file and in `docs/BUILD-LOG.md`. No shell file, library or test
differs — `git diff --name-only ded20f1 HEAD` is the whole check, and it names two
Markdown files. `smoke.sh` reads `README.md` in two checks that assert a pattern is
**absent** from it (`tests/smoke.sh:174` and `:177`, the two inbox-command checks);
`README.md` is not one of those two files and its shipping content is what was measured. No
suite reads this file or `docs/BUILD-LOG.md` — zero references to either.

Three suites changed in this release and are the ones to look at first: `inbox` (102 to
107) and `nudge-typing` (56 to 61) gained the idle-agent checks that v1.16.0 did not have
in any suite, and `providers` (134 to 141) gained the first checks `wolfmux_load_config`
has ever had. Each new block was run against v1.16.0's tree before the fix and failed
there: 6 of the 61, 10 of the 107 and 3 of the 141 — the failure lists are in
`docs/BUILD-LOG.md`.

The total counts the clean smoke run once: the detached runs are further measurements of the
same suite, not further suites. `tests/credential-routing.sh` is outside the total — it has
no check count and is manual.

**How many skips to expect is a rule, not a number:** one per signal the launch leaves
ignored. A detached launch can leave {HUP, INT, QUIT} ignored — `nohup` accounts for HUP,
and a bare `&` is enough to lose INT and QUIT — and an inherited `SIG_IGN` cannot be undone
from inside the process, so a check that sends itself such a signal cannot hold. A harness
can reset the dispositions in a parent that then `exec`s the suite; this release's gate
wrapper resets HUP and INT both. Every figure here names the shape it was measured in, so a
different skip count means a different launch rather than a different tree.

tests/smoke.sh's check "a crash is never silent ... (issue #6)" does not fail under nohup
since v1.14.2: it SKIPS, with the reason printed ("SIGHUP arrives ignored — launched under
nohup?"), because nohup leaves SIGHUP set to ignore and an inherited SIG_IGN cannot be
undone from inside the process. Four launch shapes were measured, and the rule held in each:
row 2 of the four-shape table at the end of this file was measured at `9d9f84b`, the other
three at `083fe9f`. The splits are quoted there, each beside the dispositions it was measured
under, rather than restated here — and nothing is wrong in any of the four.

`smoke.sh` tests the checkout it lives in. It uses its own tmux server
(`wolfmux-test-<pid>`, `wolfmux-test-old-<pid>`), its own state directory, a throwaway repository whose path
contains a space, and `tests/stub-agent` in place of every CLI. It was run while a
real team was live on the same machine; the real team was unaffected.

## smoke.sh: 348 checks, 0 failures (v1.16.1) — how many pass depends on the launch (issue #17)

Measured at `083fe9f`, base `e431740`, launched through a parent that resets both
`SIGHUP` and `SIGINT` to `DEFAULT` (HUP default, INT default), where all
348 checks hold — including the ones a detached run cannot reach.

The shape is quoted with the figure because the split moves with it and the total does not.
A check that sends itself a signal and expects to be killed by it cannot hold when the
launch already set that signal to be ignored, since an inherited `SIG_IGN` cannot be undone
from inside the process; it skips with its reason printed rather than reporting a bare,
unexplained FAIL. The four shapes are measured and named by their **dispositions**,
which is the cause — a command is only a proxy for it. Worth being exact about one proxy,
because it is easy to get backwards: a lane's real launch is `nohup … &` from a
non-interactive shell, which leaves HUP **and** INT ignored and is therefore the two-skip
shape, not the one-skip shape a plain `nohup` gives.

| Area | Checks |
|------|--------|
| launchers | `codex-astra` starts Codex by its real path, never through a symlink · `claude-opus`, `-sonnet`, `-haiku` are the subscription launcher pinned to their model, each pin configurable · `claude-glm` declares a 200k context window · `1m` uses the suffix instead, a number is declared, nonsense falls back with a warning · a context value from outside is scrubbed, never inherited |
| context windows (v1.14.1) | the model table declares its own window for `fable`, `opus` and `sonnet` (1,000,000) and `haiku` (200,000, unchanged) · `glm53`/`flash` take theirs from the glm provider row (`PROVIDER_CONTEXT`), asserted against that row's own value, not a second literal · a pinned id with no `[1m]` suffix and `astra` have no declared window at all — `context_window` is 0, not a guessed 200,000, through the same `agent_context` path `status` actually uses · the CONTEXT column and `status --json`'s `context` string show the tokens with no percentage when the window is unknown · a real 232,010-token conversation (the exact request measured on a live Opus 5 agent) renders `232k 23%` on opus's 1M window, not the old fallback's 116% · a real 150,000-token conversation renders `150k 75%` on haiku's unchanged 200k window |
| start | session running and lead registered · repository left clean by the stealth Beads init (no commit, no tracked file) |
| spawn | two workers running · own branch each · worktrees outside the repository · `--base` recorded · `TEAM_ROLE` / `BEADS_ACTOR` / model set inside the pane · no provider or agent-session variable leaks into a pane · kickoff prompt present by default and absent with `--no-kickoff` · lead is pane 0 · pane titles are `<role> · <model>` |
| validation | duplicate role refused · `lead` and malformed roles refused · a capital letter is refused under `C`, `en_AU.UTF-8` and `en_US.UTF-8` alike · a role an older version let through can still be listed and stopped · a role name can never leave the registry directory · flag without a value reports usage with exit 64 |
| any model | a Codex teammate in a team led by another model · a Claude-subscription teammate (sonnet) beside GLM workers, with the guard · `claude:<id>` and `codex:<id>` reach the CLI · a Codex teammate gets the notify program · nonsense (`gpt`, `claude:`, `claude:bad;id`, `glm:glm-9`, `codex:a b`) is refused before anything is created |
| teams | asking for another lead model while a team runs never hijacks it and prints how to start a second · a named team gets its own tmux session and lead · with several teams a command must say which (exit 64, lists them) · the same role can exist in two teams; `--team` before or after the command; branches `ai/<team>/…`, the record agrees · status draws every team as a tree (TEAM, 🐺, 🐶) · `--json` lists the teams, with `--team` it keeps the single-team shape · `teamctl teams` · Beads names `<team>.<role>`, the first team keeps plain roles · an agent is told who its lead is in its own team's terms, the protocol's examples rewritten · a nudge finds the right team by name · a lead manages its own team only (exit 77) · notifications name the team and a click opens that team · bad team names refused · Beads messages reach the lead of the right team · destroy ends one team and leaves the other |
| deleting a team | a worker may not delete a team (exit 77) · work that exists nowhere else is listed and, without an answer, nothing at all is touched: the team keeps running · the report says how much space the team takes · `--purge --force`: session, worktrees, `ai/` branches, records and transcripts are gone · nothing else is touched: other teams, their branches, the checkout, other transcripts · with nothing at risk it still wants a yes when nobody can be asked · deleting the first team leaves the named teams' state alone · `teamctl teams` shows DISK |
| teams together | teams talk through Beads in both directions · every agent is told that other teams exist and how to reach them · a lead can found a fresh team and hand over (`--handover`), the founder is recorded, the new lead's first words name the bead · you are told when an agent founds a team · a lead cannot take over a team that has a lead, a worker cannot found one (exit 77) · `lead-teams off` keeps founding teams to you |
| teams, approvals | a permission request in a named team is filed with, and announced to, its own lead, never the first team's · another team's lead cannot decide it (exit 77), its own lead can, and the worker's CLI receives allow · the waiting time is also read from the config file, not only from the environment |
| lanes | words are not commands: prose in quotes and heredocs never triggers the guard, a quoted path still does · MCP tools are held to the same lanes · every worker has the guard, the lead does not · a worker may change files in its own worktree (absolute, relative, new) and in temporary directories · not the lead's checkout, a teammate's worktree, `~/.zshrc`, or anything reached with `..` · it may read the lead's checkout, never a teammate's worktree or teamctl's state · ordinary shell work passes (tests, commits, `git checkout -- file`, `git push -u origin HEAD`, copying `.env` from the lead's checkout, `teamctl`, `bd`, rebase) · reaching into another worktree or writing into the lead's checkout is refused, in either spelling of the path · switching, creating or deleting branches, `git worktree`, `tmux`, pushes to main are refused · the lead is not guarded and an agent the guard cannot place is allowed · `worker-isolation off` removes it at the next start |
| branch names | the built-in template still produces the names it always did, and the record says teamctl created that branch · `--branch` gives exactly that name and the pane opens on it · `--branch` refuses a name git would not take (64) and one that exists (1), leaving no record, worktree or branch · a template with no `{ts}`, an unknown placeholder, an unclosed brace or nothing at all is refused (64) · a template with `{ticket}` and no ticket key is a usage error naming the flag, and creates nothing · an invalid ticket key is refused before anything is created · template plus `--ticket` gives a conforming name with the stamp kept · `teamctl start --ticket` is the team's default and a spawn's own `--ticket` wins · `teamctl policy` shows the template and `default` puts the built-in shape back · only a branch teamctl created is deleted, whatever it is called, a record from before the field keeps the old `ai/` rule, and a branch teamctl did not make is named and left alone · the guard holds a worker to its own branch whatever it is called |
| a worker in another repository | branch and worktree are created in the sibling repository from a ref of that repository, and the pane opens there · the worktree lives under that repository's own key, and status names it (a `REPO` column only when some teammate has one, `repo` in `--json`) · `--repo` refuses a non-directory, a non-repository and a repository without a commit (64), creating nothing · isolation stays on: the worker's own worktree is writable, the lead's project and the sibling's own checkout are not, and it is told which repository it is in · the teammate still reads the team's own Beads workspace · diff, status and worktrees read that repository · remove without `--force` still refuses and names the commit and the file · `remove --force` takes the worktree and the branch there and leaves every other branch of both repositories · `destroy --purge` does the same |
| clearing up | a running agent is never removed · `destroy --worktrees` names what it kept and both ways out · without `--force` work is never discarded and the refusal lists the commit and the files · a worker cannot remove anyone (exit 77) · `--force` needs a yes when nobody can be asked · `remove --force --yes` takes worktree, branch and record, the main checkout is untouched · a damaged record can never delete a directory outside the worktrees or a branch that is not `ai/*` · all or nothing: one worker that holds work stops the whole command · an unknown role is an error · a worker with thousands of unmerged commits and more changed files than a report shows: the report is cut and says how much it left out, `remove --force` and `destroy --purge --force` finish (never a silent exit 141) · a teamctl ended by a signal names the signal and the command (its own exit handler installed, SIGPIPE gives 141 with that message); a plain failure, Ctrl-C and a closed terminal add nothing — the Ctrl-C and closed-terminal cases are each skipped, with a stated reason, when their signal already arrives ignored (SIGINT under any background launch, SIGHUP under `nohup`: issue #17) |
| one manager | default policy is skip / skip / spawning off / isolation on · lead and workers start in their CLI's bypass mode · agent teams switched off inside workers, lead's settings left alone · a worker cannot spawn while the toggle is off (exit 77) · a worker cannot stop, restart, destroy, approve, deny or change policy · with the toggle on a worker can spawn, the record says who spawned whom, and the lead is told |
| browser-writes (v1.14.3) | defaults to `ask`, `teamctl policy` shows it · at `ask` the settings document is unchanged (no `permissions` key, lead or worker — the default behaves exactly as before this policy existed) · set to `allow`, read back, back to `ask`, read back · an invalid value is refused (exit 64) and the stored value is unchanged · `allow` writes exactly `permissions.allow == ["mcp__claude-in-chrome__*"]` into the lead's settings with `env`/`hooks` untouched · a worker of the same team gets the identical rule, `env`/`hooks` untouched · back to `ask` removes the rule again |
| approvals | lead mode starts a worker without bypass and with the hook · a request is filed and the lead is told · status shows it pending · a worker cannot approve its own request · approve → the CLI receives `allow` · deny → the CLI receives `deny` with the reason · no answer → no decision, so the normal prompt appears · ask mode has neither flag nor hook |
| notifications | fixed line typed into the pane · debounced inside the window · hostile bead id (`x;rm -rf ~`) dropped, never typed |
| the config file's allowlist (`tests/providers.sh`, 141 of 141 pass) | **the first checks `wolfmux_load_config` has ever had, and the reason the second defect of v1.16.1 could sit there for two releases**: an allow-listed key is taken from `~/.config/wolfmux/config` · spaces around the `=` and around the value are stripped · **a key that is NOT on `WOLFMUX_CONFIG_KEYS` is read and DROPPED, with no error and no effect — which is what `WOLFMUX_NUDGE_TYPE=all` did in that file until this release (measured in the owner's own config on 2026-10-12: written, next nudge still reported `detached-lead`, reverted)** · an environment variable that is already set wins over the file · every key on the list is a `WOLFMUX_` name, so nothing else can be exported from that file · no file at all is not an error. Each case runs in its own subshell with its own throwaway `WOLFMUX_HOME`, so none of it reaches the real config file. Three of the seven fail on v1.16.0's tree |
| nothing is typed into the human's conversation while he is working in it (`tests/inbox.sh`, 107 of 107 pass) | **a client attached + a QUIET lead pane + a bead: it IS typed, exit 0, with no human keystroke anywhere — the v1.16.1 fix, and the check v1.16.0 had in no suite; typing marked it delivered so the Stop hook has nothing to say about it, and the human's badge still shows `📨 1` unread, with no banner because the notice reached the agent** · **a client attached + a human WORKING in the lead pane (a half-typed line): exit 3, NOTHING typed into the lead pane, a waiter parked to deliver once it is quiet, the notice in the file as `new`+`undelivered`, the badge showing `📨 1`, `nudge-deferred` in the event log** · an approval-grace override does not make a BEAD notice borrow the grace: nothing is typed · no client attached: the same bead IS typed, exit 0, naming its bead, and it is in the file too · **the Stop hook blocks ONCE: the reason carries the notices and the agent's own Beads command, the lines are marked delivered BEFORE it answers, a second turn ending at once says nothing (cooldown), and with the cooldown cleared it STILL says nothing because they are delivered — then a NEW notice blocks again, so neither guard starves the other** · UserPromptSubmit prints the notices for the model's context and does not repeat a delivered one · **the two states are independent in BOTH directions: `teamctl inbox` clears new-ness without touching delivered-ness, and the agent's hook clears delivered-ness without clearing the human's badge** · a typed notice is marked delivered, so no hook hands it over twice, while the human's count still stands · three events for ONE bead file one line (the badge reads 1, not 3) and a different bead is never collapsed · **a notice survives a waiter that died: the parked notice is gone from the typed path, the file still has it, and the agent is still given it by its Stop hook** · the badge prints NOTHING and exits 0 for: no notices, no session name, a session that does not exist, a root that is not a directory, an invalid team name, and a damaged inbox file · an approval adds the louder `🔔`, and reading clears both · **the badge END TO END: the shipped `status-left`, a real pty client, `refresh-client` — the segment ran and `📨` and `🔔` are in the DRAWN status line, and the first draw is blank (the documented limit)** · who is typed into, every combination of `off`/`workers`/`detached-lead`/`all` × lead/worker × claude/codex, including the Codex exception · a tmux read that cannot be made sense of counts as attached (fails closed) · the file itself: one line per notice, tabs and newlines stripped, long text cut, capped · `prefix N` bound to a popup, `prefix I` left alone, `prefix T` untouched, `status-interval` 5 · the stall notification: exactly ONE banner carrying the count for eleven notices inside the window, none with `WOLFMUX_NOTIFY=off`, none with `WOLFMUX_INBOX_STALL_NOTIFY=off`, and none for a worker · **the eight findings of the adversarial review, each against its own mechanism**: an awk that cannot write its replacement record destroys nothing and hands nothing over (the lost-notice path, measured by the reviewer at 40,000 records in and 11,773 out) · `WOLFMUX_NUDGE_TYPE=off` types NOTHING into an attached lead, approval or not, and still files it · temp files are dotfiles AND non-role names are filtered, so ONE notice counts 1 even with a stale `lead.taken.4242` sibling present · an interleaved create/update pair still files ONE line and two beads read 2 · a Stop hook whose answer fails re-queues its notices instead of eating them, with the human's count untouched · a DECIDED approval is never typed while one still pending after the grace is, expiry counts as decided, and an unreadable store fails towards typing · three teams inside one stall window ring ONCE, not once each · a non-numeric knob falls back to its default instead of silently disabling a hook · **a teamctl path containing a space still runs the badge** (the program field is quoted; proven with the same pty-client harness, since nothing else proves a `#()` job ran) · one hand-over is capped and the rest stay UNDELIVERED for the next turn, in order, with the body saying how many are still waiting · a notice longer than the text cap is still marked delivered when it is typed · a bead title holding backslash escapes still dedupes, matches and re-queues (awk processes escapes in a `-v` assignment, so the text goes through the environment instead) · **a re-queue that cannot write its replacement record FAILS instead of reporting success** (this was the only read-modify-write here with a test for its success path and none for its failure path: an unreadable want file left `want[]` empty, matched nothing, printed every line unchanged and exited 0, so the chain installed a record in which the notices were still delivered) · the event then says the notices were LOST rather than asserting a re-queue that did not happen · a hand-over that cannot rewrite the record writes an `inbox-take-failed` event instead of being silent (F1's chain already made it fail safe; the silence was the finding) · **the settings document carries v1.14.3's `browser-writes` arm and this release's two inbox hooks AT ONCE** — the product neither branch could test alone: at `allow`, the lead's and a worker's documents each hold `env`, the notification hook, both inbox hooks, the worktree guard where it belongs, and `permissions.allow` compared as an EXACT array so an appended second matcher FAILS rather than passing quietly; the delta both ways round (no `permissions` key at the default, and the default document equals the allow document with `.permissions` deleted, which is what proves that arm adds exactly one key); and the drift the delta cannot see (each role's key set and every hook command asserted exactly, with `$TEAMCTL_SELF` normalised, since a quiet change of shape moves both documents together) |
| never into a half-typed line (`tests/nudge-typing.sh`, 61 of 61 pass) | **the new rule itself, three episodes, all with a client attached and the human's eyes ON the lead pane: an IDLE lead pane is typed into with no human keystroke (`nudge` event naming the quiet window); a half-typed line in it is NOT, the notice parks, the human's text is untouched, and the notice arrives by itself once that line is submitted; and a human AT that pane who pressed a key inside `WOLFMUX_NUDGE_LEAD_IDLE` holds it back, with the wide window written into the marker** — the third measured against the real pty client's own `#{client_activity}`, because `send-keys` does not move it and so no test can type as the human · no client attached and the same bead IS typed, exactly as before · the queued-notice and mid-delivery blocks still drive a LEAD pane, with the client detached so it is still a typed path — every one of the original 52 checks kept and passing · **a non-empty input row defers whether or not anybody is attached — a half-typed line survives a detach, so it is left alone, the notice waits, and the human's own line later goes off whole** · **a dim placeholder on a pane with nobody attached is the TUI's own furniture, not typing, so the notice is delivered at once and nothing is parked** · copy mode defers attached or not, and leaving it lets the notice through · **a marker whose waiter died is reaped by the next nudge, which is delivered, and its ghost bead is never typed (`nudge-defer-reaped`)** · with a client attached: a busy input line defers (exit 3, and the message names the check that fired), nothing is typed, the half-typed text stays unsubmitted, a marker is parked · three nudges while busy become exactly ONE generic line once the pane is idle, counted against a measured one-notice baseline, and the human's own line was submitted whole · a client that pressed a key seconds ago defers even with an empty input line, and the notice follows once they stop · **queued fixed notices (three policy changes on a busy lead pane): all arrive, in order, each exactly once, nothing glued, marker cleared** · **a human who keeps typing part-way through a five-notice delivery: nothing is delivered twice and nothing is lost** · a pane that never goes idle: the marker is cleaned up at the cap, nothing was typed, `nudge-defer-expired` in `events.jsonl` · `WOLFMUX_NUDGE_COLLISION_CHECK=0` types blind again · `WOLFMUX_NUDGE_RETRY=0` and nonsense are floored, so a waiter can never spin for ever · the input-line check itself, on plain rows and on rows as `capture-pane -e` really hands them over: **three rows copied verbatim from the live socket, a dim `ESC[2m` placeholder and a non-breaking space read CLEAN**, while typed text next to a dim hint reads dirty |
| Beads | a message to a role notifies its pane · body stored intact (`"quotes"`, `$HOME`, backticks) and never typed into the pane · a worker reads the shared database from its external worktree |
| git | `diff` commits / stat / patch · uncommitted leftovers visible · main checkout untouched by worker commits · `worktrees` lists everyone |
| the wolf | the session has the `client-attached` popup hook · the splash draws wolf, wordmark and team line · no colour codes outside a terminal · it works outside any project · only the manager pane has the mark and the amber border · the manager pane opens with the wolf · status line and tab title carry it · `WOLFMUX_SPLASH=off` removes the popup and the default restores it · a Claude lead is named `🐺 team/lead`, workers are not |
| arrangement | by default the lead is the large pane on the left and workers share one column on the right · `lead-top` puts the lead across the top · `tiled` is available, the choice is remembered, an unknown name is refused (exit 64) · the arrangement survives a spawn and a stop |
| conversations | a fresh agent is started with its own id and it is stored · two agents of one team never share an id · a Codex agent is given none · a plain restart mints a new id and passes `--session-id`, never `--resume` · `restart --continue` reopens THAT agent's stored id, not the newest transcript in the folder · `--resume <id>` wins, is stored, and comes back after another restart · a malformed id is refused and nothing is restarted · a record from before ids keeps `--continue` and warns which folder it is guessing in |
| closing and coming back | a lead that exited comes back in place and the worker keeps its pane · asking for the other lead model brings it back as that model · when every agent has exited, `start` opens a fresh session with one pane and marks workers stopped · `--continue` reaches the lead's CLI on its own conversation id · a stopped worker returns with `restart` into the arrangement · with no tmux session left (a reboot), `restart lead [--continue]` starts the team again as the model that led it, in a named team too, and a worker's refusal names the exact two commands, with `--team` and `--continue` · `--resume <id>` reaches the lead through the `start` that restart falls back to · **a pre-rename team whose agents have all exited is replaced by a fresh one on the new socket** |
| conversations | every Claude-family agent is started with its own id and it is stored; a Codex agent gets none · a plain restart mints a new id · `--continue` reopens the agent's own id · an agent that never said a word starts fresh under the same id · `--resume <id>` wins and is stored; an unknown id, a malformed one, another agent's (any team) and a Codex agent are refused before anything restarts · a pane run again by hand gets a new id · a restart that produces no pane leaves the id as it was, in the record and with the team · two leads in one folder restarted with `--continue` each reopen their own conversation, also after `destroy` and `start --continue` · with a Codex lead in between, the last Claude lead's conversation comes back · a first `start --continue` has none on record and keeps the old behaviour with its warning · `status` shows each lead the context of its own conversation |
| tab completion | `teamctl _complete` offers every public command with a description, the aliases, `--team`, never an internal command · each command's options · roles of the team the line names (workers only for `remove` and `--from-worktree`), teams after `--team` and `--team=`, models with labels, policy keys and their choices, layouts, pending approval ids, branch names, directories for `--repo` · with several teams and none named no roles are offered · outside a git repository commands, options, models and policy keys are still offered and what belongs to a project is empty · it leaves the state directory, the tmux sessions and stderr untouched · the zsh shim registers only when compinit has run and is silent without it; the bash shim completes commands, values and directories, loads with `eval` in macOS bash 3.2, and inserts a hostile branch name quoted · after an option that takes free text nothing is offered · `teamctl completion <zsh\|bash>` prints them |
| desktop notifications | every Claude agent gets the `Stop` hook, the plugin notifier is silenced and the user's own disabled hook is kept · OSC 9 to the attached terminal with the first line, markdown dropped · the lead is marked · **an OSC 52 and a clear-screen sequence inside a message never reach the terminal** (exactly two control bytes come out: ours) · long messages are cut · no terminal attached → `osascript` with the text as an argument, never a failure · nobody attached → the message is handed to Wolfmux.app, not to `osascript`, and the project is remembered · the app fetches its message exactly once, so its next start is a click · a message it never fetched is not posted late · a click opens a terminal on the team (script with the project and `teamctl attach`) · `WOLFMUX_NOTIFY=lead` keeps workers quiet |
| rename | an explicitly chosen socket is never redirected · teamctl follows a team on the old socket · new panes join it · destroy ends it · the next team starts on the new socket · a Beads hook written under the old name is replaced · a hook that is not ours is left alone |
| lifecycle | stop keeps the record · restart reuses worktree and branch · destroy refuses without confirmation when non-interactive · destroy `--yes` works · dirty worktree with an unmerged commit is **kept** · clean worktree removed and merged branch deleted · session gone |

## disk.sh: 93 of 93 pass (v1.16.1)

Its own tmux server (`wolfmux-disk-test-<pid>`), its own state directory, a throwaway
repository whose path contains a space, stub agents, and build trees of a few megabytes of
`/dev/urandom` instead of real installs (`/dev/zero` compresses to nothing on APFS and would
have made the freed-kilobyte checks meaningless). Half the checks ask `lib/disk.sh` its
questions directly, with teamctl's libraries loaded under `set -euo pipefail` — `bin/teamctl`'s
own line, so an arithmetic or `set -e` abort inside a library cannot pass unseen; the other
half go through the commands in a live throwaway team.

| Area | Checks |
|------|--------|
| the allowlist and the numbers | a dry run reports the **exact** kilobytes of the allowlisted directories (compared with `du -sk`) and deletes nothing · it names what it would take · `caches` leaves `node_modules` out of both the number and the deletion · `human_size` turns KB into MB and GB at the right places · applying `caches` deletes the caches and keeps `node_modules` · applying `all` takes both and leaves sources and git state untouched · nothing is left behind |
| what is never deleted | a `dist` that git tracks survives, and is not counted as freed, while `node_modules` still goes · a worktree with an uncommitted change to a tracked file is refused with the reason, and untouched · a worktree with an untracked file that is not build output is refused, the file is named, and it is untouched · a path outside this project's worktree directory is refused · your own checkout is refused · the worktree directory itself is refused · a worktree whose `.git` file is gone is refused (git has to be the one that answers) · `…/..`, `…/../..` and `/` are refused, because `pwd -P` resolves first · **a named team's lane is never confined for the first team**, nor is the `teams/` directory itself · a `node_modules` that is a symlink out: the link goes, never its target · the refusal names the team and never trails off when no worktree directory resolved |
| interruption | a leftover `.wolfmux-removing-*` is counted, named `cleanup-trash`, cleared by the next run, left alone by `--dry-run`, and never makes the lane permanently unclean |
| the remembered lane size | a fresh number is used · garbage, a one-field line, an empty file and negative values are not · a stale number is dropped · **a stamp in the future is dropped** (a clock that went back used to pin status for ever) · **a leading zero in either field is dropped silently, with nothing on stderr** (it used to reach the arithmetic and print `08: value too great for base`), while a plain `0` is kept · a command that freed something corrects the number instead of measuring again, and never below zero |
| what counts as a person's work | an untracked `dist`, `build` or `target` that git neither tracks nor ignores counts as work, and is listed · `node_modules`, the build caches and our own trash never do · a `node_modules` **symlink** does not either, which is the case a `node_modules/` ignore line misses · a changed tracked file always counts, and so does any other untracked file |
| a number that is not base ten | `policy disk-min-gb` refuses `08`, `010`, `09`, `twenty`, `-5`, `1e3` and `10001` with exit 64 · a leading zero in the environment falls back to the default · so does one already in `meta.json`, which `teamctl policy` would no longer accept, while a plain `8` there is used · and the one arithmetic site forces base ten anyway, so even `08` cannot abort a spawn |
| the commands | `stop` takes the build caches, keeps `node_modules` and says how much it freed · `stop` on a lane with unfinished work keeps its build output and says why · `prune --dry-run` prints a total, deletes nothing, leaves the trash alone, leaves a running lane out and says so, names the lane it skipped and why · **the printed sizes are checked as values, not as a shape**: the running and the skipped lane each show their real size, and the "still held" total is the swept lane's leftovers **plus the whole of both** (the first version of that line counted neither, and a shape assertion let it pass) · a worker may run `--dry-run` but gets exit 77 for the real thing · `--keep-node-modules` takes the caches only · `prune` takes `node_modules` from the parked lane, clears the trash, reports the total, never touches the running lane or the skipped one, and leaves the sources and git state intact · **`prune` refuses the whole sweep, dry run included, when a record says running and the session shows no pane for it, and touches nothing** · a hand-edited record pointing outside is skipped and that directory is untouched · `remove` sweeps the build output of a lane that is going (so cleanup trash never makes it ask for `--force`), takes the whole worktree and reports the sweep plus the lane's whole size as freed · **a `remove` that refuses changes nothing**: a lane holding one file a person wrote is refused with the linked `node_modules` and the caches still there, and the count and the listed lines agree · `remove` also asks about a lane holding an untracked `dist/deploy.sh`, and that file survives · `destroy --worktrees` takes each lane's build output first and still keeps the lane that holds real work |
| a lane in ANOTHER repository (`spawn --repo`) | a second throwaway repository, its own path with a space in it. The lane really lies under **that** repository's worktree directory, not this project's · `stop` clears its caches and keeps its `node_modules` · `prune` takes both, in that repository, names it on the line, and in the same run leaves this project's running lane alone · neither checkout is touched · rule 4 refuses that repository's root, its worktree directory, and a parent traversal, and its root `node_modules` survives · the same lane measured against **this** project's prefix is refused · a file that repository tracks survives under a name on the list (rule 2 through its git) · `--link-node-modules` links to **that** repository's `node_modules` and not this project's, and cleaning takes the link and never the target · `remove` takes the worktree in that repository, says which one, and reports what it freed |
| after a reboot | with the tmux server gone and every record still saying `running` — the state the machine was left in three times on 2026-10-09 — `prune` cleans the lane, does **not** read the stale records as a disagreement, and exits 0 |
| the guard | `status` shows free disk and what the guard is set to · `status` never measures and says so, `teams` measures, and `status` then shows the number · `status --json` carries `disk.free_kb` and the three new policy keys · under the threshold a spawn is refused with **exit 75**, names the number and `teamctl prune --dry-run`, and creates no branch and no record · `disk-guard warn` lets the same spawn through with a warning · `off` asks nothing at all · `disk-min-gb 0` switches the limit off without switching the guard off |
| shared `node_modules` | `--link-node-modules` links the lane to the project's copy and says that an install in any lane changes them all · without the flag and with the policy off there is no link · `policy link-node-modules on` does it for every spawn · the linked `node_modules` really is what git calls untracked under a `node_modules/` ignore line (the case below) · **`remove` takes such a lane off the books without `--force`** and never the project's copy · cleaning a linked lane removes the link and never the project's copy |

**Measured, not assumed.** One real lane `node_modules` on the owner's machine: 69,336
files, 802 MB, `du -sk` 0.62 s warm. All 36 lane worktrees on that machine: 12.4 s. That is
why `teamctl status` reads a cached number and `teamctl teams` is the command that measures.

**Also measured, by the reviewer, read-only on the same machine.** 38 lane worktrees holding
25 GB, of which about 4 GB sat in a directory on the allowlist. The other ~21 GB is files
git tracks: in one project `public/` alone is 530 MB and 3,097 tracked files, copied into
every lane, about 0.65 GB per lane before an agent installs anything. `prune` now prints
that floor. For the issue's 27-lane case, `prune` would have returned roughly 27 × 2.9 GB;
the ~18 GB of tracked files needs `teamctl remove`.

**What the review could not break.** Driven directly at the project root, `$WORKTREES_DIR/../..`,
`/`, an empty path, an emptied `WORKTREES_DIR`, a worktree with its `.git` file deleted, a
`GIT_DIR` exported to point at another repository, a `node_modules` symlinked to the project
root, a symlink inside `node_modules` pointing out, two `teamctl prune` runs at once, and
`remove --force` / `destroy --worktrees` on a linked lane: every confinement attempt was
refused, the root's `node_modules` survived every one, and the concurrent runs serialised on
the project lock. Rule 4 refused even the one case (`GIT_DIR`) where rules 2 and 3 could be
made to answer about the wrong repository.

## Live checks with the real CLIs

| Check | Result |
|-------|--------|
| `teamctl start fable` in a throwaway repo | real Claude Code TUI in the lead pane, stopped at its folder-trust prompt; process flags: `--model claude-fable-5-1[1m] --append-system-prompt <protocol> --name team/lead` |
| `teamctl start astra` in the same repo | real Codex TUI, at its folder-trust prompt; flags: `forced_login_method="chatgpt"`, `model_provider="openai"`, `model="gpt-6-astra"`, `developer_instructions=…`; no `OPENAI_*` / `CODEX_API_KEY` in the process environment |
| 2×2 layout | lead (0,1) · backend (110,1) · frontend (0,30) · qa (110,30) on a 220×60 window |
| real `claude-glm` with no Keychain item | pane shows the exact `security add-generic-password …` command, state `exited(78)`, pane kept |
| worker → lead | `Done:` message with `--body-file` notified the lead; closing the task notified the lead again; report body intact in the lead's inbox |
| worker → worker | backend messaged frontend directly; frontend's pane was notified |
| `claude-fable` with hostile environment (Z.ai base URL, a token, the guard placeholder) | `claude-fable auth status` → `authMethod: claude.ai`, `subscriptionType: max` |
| `WOLFMUX_DRY_RUN=1` with injected `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `CODEX_API_KEY` | each launcher lists them as scrubbed and shows an empty provider environment |
| conversation ids, Claude Code 2.1.289 (2026-10-04; repeat with a new CLI version) | `--resume <id>` with no transcript of that id: `No conversation found with session ID`, exit, no model call · `--session-id <id>` whose transcript exists: `Session ID … is already in use`, exit · `--session-id not-a-uuid`: `Invalid session ID` · `--resume <id>` from another folder than the transcript's: found and continued. A resumed conversation keeps its id: by the CLI's own help it is `--fork-session` that makes a new one (read, not measured: measuring it costs a model call). `tests/stub-agent` refuses the same two things, and the transcript is where teamctl looks: `~/.claude/projects/<folder with every other character as ->/<id>.jsonl` ([ADR-0027](adr/0027-every-agent-resumes-its-own-conversation.md)) |
| fresh login shell | no `ANTHROPIC_*`, `OPENAI_*`, `CODEX_API_KEY`, `ZAI*` or `CLAUDE_CODE_USE_*` variable; plain `claude` still resolves to the original binary |
| secrets scan of every created file | no matches |
| Codex rules | `codex execpolicy check`: `teamctl …` → allow, `bd …` → allow, `teamctl destroy` → prompt, unrelated commands → no match |

## What a person sees on attach (captured through an outer tmux, 150×44)

```
── 🐺 lead · GPT-6 Astra ──────────────────────────┬── backend · GLM-5.3 ─────────
[wolfmux] role=lead  model=GPT-6 Astra  launcher╭──────────────────────────────────────────────────╮
                                                │          █▄                          ▄█          │
                                                │         ████████████████████████████████         │
                                                │       ▄██████▀▀▀▀▀█▀██▀██▀██▀█▀▀▀▀▀██████▄       │
                                                │                  W O L F M U X                   │
                                                │             a pack of agents in tmux             │
                                                │     team-demo · lead GPT-6 Astra · 2 workers     │
                                                ╰──────────────────────────────────────────────────╯
 🐺 WOLFMUX  0:team*                                                          team-demo · 15:08
```

(abridged). The border line of the lead was emitted in colour 214 (amber), the workers'
in 244 (grey); the terminal title was set to `🐺 team-demo`. On an 80×24 terminal tmux
shrinks the popup and the splash drops lines to fit instead of scrolling.

## Probes of the real Claude Code CLI (no prompt sent, endpoint = localhost mock)

| Probe | Observation |
|-------|-------------|
| session with the owner's global settings (agent teams = 1) | Claude Code created `~/.claude/teams/session-<id>/`: the session is a team lead, and named subagents become its teammates |
| same session plus the per-worker settings `teamctl` generates (`env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "0"`, `teammateMode = "in-process"`) | **no team directory created**: the override passed through `--settings` beats the global value |
| `--dangerously-skip-permissions` through the worker environment | footer `bypass permissions on`, prompt ready, no blocking dialog |
| `claude -p --model glm-5.3` with the environment a GLM worker had before 1.4 | prints `"glm-5.3" isn't described by this version's model catalog … auto-compact keeps this session within 200k tokens`; the same for `glm-5.3-flash` |
| the same with `CLAUDE_CODE_MAX_CONTEXT_TOKENS=200000`, as `claude-glm` and `claude-glm-flash` now export it | **no notice**. Also silent: the `[1m]` suffix, and `CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1` (not used: it changes behaviour, the declaration does not) |
| banner of a key-authenticated session | reads `API Usage Billing` — Claude Code's label for any key-based login, here the Z.ai Coding Plan key |

## Beads evaluation (sandboxed `HOME`)

| Question | Finding |
|----------|---------|
| Can several agents write concurrently without a database server? | 16 parallel `bd create` + 8 parallel `bd list` in embedded mode: all succeeded, count exact, 16 unique ids, 20 s total (writers queue on a file lock with backoff) |
| Is claiming atomic? | three simultaneous `--claim` on one task: one winner, two clean "already claimed by" errors |
| Do external worktrees share the database? | yes, through git's common directory; no stray `.beads` appears in the worktree |
| What does `bd init` touch by default? | it **commits** `.beads/*` and a `.gitignore` to the current branch. `--stealth --skip-hooks --skip-agents` makes no commit, adds no tracked file and leaves global git config alone |
| Do event hooks exist and what do they receive? | `.beads/hooks/on_create`, `on_update`, `on_close`; argv `<id> <event>`, the bead as JSON on stdin, the caller's environment. Comments fire none |
| Are message beads listed by default? | no — `bd list` hides them unless `--type message` or `--include-infra` is given. Every inbox command in this project carries `--include-infra` |

## install.sh / uninstall.sh (fake `HOME`)

Second install run changed nothing · existing `allow` entries not duplicated and
`deny` preserved · install then uninstall left `~/.zshrc` byte-identical · exactly
the added permission rules removed · uninstall refused while a team was running.

## permissions.sh — 13 of 13 pass (v1.16.1)

`install.sh` and `uninstall.sh` against `~/.claude/settings.json` in a throwaway `HOME`
(no team, no CLI, nothing of yours read). Written first, when it had 9 checks: 4 of the 9
failed before the change.

| Area | Checks |
|------|--------|
| a fresh install | `teamctl` and `bd` allowed, `teamctl destroy` asks · no rule that can write a file or run a command through its arguments · `claude/permissions.json` names what it retired and adds none of it |
| over a settings file an earlier version wrote | the five retired rules are taken out · the installer names each one and the backup still holds them · your own rules, `deny` and every other key untouched · a second run changes nothing |
| uninstall | an option it does not know is refused (exit 64) before anything is touched · current and retired rules both removed · your own rules stay |
| uninstall `--purge` | a worktree of a named team keeps `~/.wolfmux`, and says so · the empty `teams/` folder a named team leaves behind is not a worktree (it used to keep `~/.wolfmux` for ever) · with no `worktrees/` folder at all it still finishes and removes `~/.wolfmux` |

Not covered: a rule of yours that is spelled exactly like a retired one cannot be told apart
from ours and is taken out as well; the installer names it and the backup holds it.

## migration.sh: 36 of 36 pass (v1.16.1)

A throwaway `HOME` gets v1.1 installed from git history, a team started with it (lead +
one worker, stub agents, its own tmux sockets), then `migrate-from-ai-team.sh`.

| Area | Checks |
|------|--------|
| refusals | new `install.sh` will not install next to v1.1 · migration refuses while a worker runs inside `~/.ai-team` and changes nothing · `--dry-run` changes nothing |
| state | old directories gone, old config parked in backups · a user setting arrives under its new key · program files are the new version · no stored record points into `~/.ai-team` · a second run finds nothing to do |
| the live team | **the running lead is not restarted** (same pid, pane alive) · new `teamctl` sees lead running and the worker stopped with its worktree |
| git | git lists the worktree at its new path, nothing prunable · uncommitted work in it survived · the worker restarts in the moved worktree |
| edited files | `~/.zshrc`: one block, only its two marker lines changed · `settings.json`: no rule under the old name, the five retired rules gone, your own rule and every other key kept · Codex rules: new file in place, old one parked · Beads hooks point at the new location |
| round trip | `uninstall.sh` refuses while the pre-rename team is up · after destroy, uninstall leaves `~/.zshrc` byte-identical to the original and `settings.json` equal in content |

## Observed in the owner's real team (2026-09-20, after the migration)

| Observation | Meaning |
|-------------|---------|
| the lead (Fable, started under v1.1) kept its pid through the migration; `teamctl status` from 1.2.0 shows it running on socket `ai-team` | adoption of the old socket works on a real team |
| two seconds after the move the lead ran `teamctl restart research`; the GLM-5.3 worker came up in `~/.wolfmux/worktrees/…`, read its Beads inbox and answered | **first real Z.ai request: helper mode (`apiKeyHelper` + login guard) authenticates against the Coding Plan endpoint**; registry rewrite and `git worktree repair` hold under real use |
| the worker's first screen warns `Both CLAUDE_CODE_OAUTH_TOKEN and apiKeyHelper set` | expected: that variable is the inert login guard ([ADR-0007](adr/0007-zai-key-delivery-and-login-guard.md)); `apiKeyHelper` wins and the request succeeded |

## One real Codex turn (2026-09-20, ChatGPT login, `codex-astra exec`)

| Question | Observation |
|----------|-------------|
| does Codex find its command runner when started by `codex-astra`? | yes: no "Code Mode is unavailable" warning (it appeared on every turn while `~/bin/codex` was a symlink) |
| can it run a command? | `/bin/zsh -lc 'echo wolfmux-ok'` succeeded |
| does Codex's `notify` program reach `teamctl _notify --codex`? | yes: `ESC ] 9 ; 🐺 lead: wolfmux-ok BEL` was written to the test tty |

## Wolfmux.app on the owner's machine (2026-09-20)

| Step | Observation |
|------|-------------|
| `teamctl _notify` with no terminal attached | `pending` written, Wolfmux.app launched, message fetched within 3 s, application exited |
| Wolfmux.app started with nothing pending (what macOS does on a click) | `open-team.command` written for the project; a new iTerm2 shell appeared in the project directory once the "control iTerm" prompt was answered |
| not observable from a script | whether the banner was shown (it needs the one-time "allow notifications" answer) and the click itself; both are macOS behaviour, the second is the very behaviour that used to open Script Editor |

## docs.sh: 36 of 36 pass (v1.16.1)

`tests/docs.sh` reads the code for what exists and the documents for whether it is named.
Nothing is started; it takes about two seconds.

| Area | What is checked |
|------|-----------------|
| commands | every public command `bin/teamctl` dispatches (not the internal `_…` ones, the pointers to Beads, `version`, `help`), and every alias, is in `teamctl help`, README.md and docs/USAGE.md; every command is in the user manual |
| options | every option a command's argument loop accepts stands next to that command in `teamctl help`, README.md and docs/USAGE.md (spellings on one `case` label count as one) |
| policy keys, models | every key of `POLICY_KEYS` and of `model_info` is in all four, as a word of its own |
| settings | every key of `WOLFMUX_CONFIG_KEYS` is in the config template, and explained in the user manual or under `docs/` |
| launchers, installer | every launcher in `bin/` or linked by `install.sh` is in README.md, the user manual and docs/SETUP.md; every option of every top-level script (`install.sh`, `uninstall.sh`, `migrate-from-ai-team.sh`) is in docs/SETUP.md |
| indexes, links | README.md links every `docs/*.md`; the ADR index lists every record; the diagrams page shows every SVG; every relative link leads to a file, and its `#anchor` to a heading that exists |

A file that git ignores (`.gitignore`, `.git/info/exclude`) is not part of the
documentation and is left alone: the check's first run in the owner's checkout failed on
a private audit note that lives there unversioned, which the worktree it was written in
did not have.

Its first run on the tree before it (2026-09-20) failed 13 of 28: README.md named 5 of 22
commands, neither alias and no options; `teamctl help` lacked `lead-teams`,
`--keep-transcripts`, `--quiet` and `--lines`; the user manual lacked two policy keys and
ten settings; docs/SETUP.md still described two symlinks and knew nothing of `Wolfmux.app`,
the `codex` wrapper or `--no-notifier-app`.

Does it notice drift? Thirteen mutations, each on a copy of the repository, each caught: a
command dropped from the README · a new command nobody documented · a new option · an
option renamed in the README only · a new policy key · a new setting · a link to a heading
that does not exist · a linked document deleted · a new document the README does not link ·
a policy key that survives only inside the flag `--worker-spawn` · a model key that
survives only inside `codex-astra` · the one option of `uninstall.sh` dropped from SETUP.md
· a link to a `# comment` inside a code block. The last four came out of the review of the
check itself: its first version matched substrings, never saw `uninstall.sh --purge`
(that script did not parse its option as a `case` label; it does now, and refuses an option
it does not know with exit 64 instead of ignoring it), and took comments in fenced
examples for headings.

## dashboard.sh: 115 of 115 pass (v1.16.1)

Measured at `083fe9f`, base `e431740`. This suite starts its own tmux
server and never uses `nohup`, so it has no signal-skip split and its launch shape does
not move the figure.

The machine-wide view (`teamctl dashboard`, `prefix O`) and the status-bar segment
(`teamctl _overview-badge`). Its own tmux server (`wolfmux-dash-test-<pid>`), its own state
directory, two throwaway repositories — one whose path contains a space — and
`tests/stub-agent` in place of every CLI. It was run while real teams were live on the same
machine; they were unaffected, because the view is read-only and the suite's own socket and
state are separate.

| Area | Checks |
|------|--------|
| an empty machine | no state directory at all is valid JSON with no projects, not an error · the text view draws and says 0 teams · the segment prints `0t 0run 0stop` |
| the machine-wide walk | the project and its root appear · the team appears with `session_running` · all three agents appear, **lead first** · each one's state · a worker reports its own branch and the lead reports none · cpu and memory are measured per agent from the process tree · the footer carries load, memory and free disk · a SECOND project in another repository appears, and the same two projects appear whichever project you run it from · the segment counts the teams and agents of both |
| **equivalence: every fast path agrees with the helper it stands in for** | `dash_teams` lists exactly what `team_list` lists, in the same order · `dash_team_records` yields exactly the roles `reg_list` yields, in the same order, and the same field VALUES `reg_field` reads · `dash_pane_row` finds the pane `tm_pane_for_role` finds and agrees with `tm_pane_state` · it gives nothing for a role with no pane and **never matches one role inside a longer one** (`lead` inside `sublead`) · `dash_orphaned` agrees with `team_orphaned`, both while the lead runs and after it is stopped · `dash_meta_session` reads the session `meta_get` reads |
| the lane total is read, never measured | with nothing measured the view says so and names `teamctl teams` · a fresh number is shown as a size, through `human_size` like every other view · a number older than the cache window is shown as `STALE` **with its age**, and still names what refreshes it · a garbled cache file falls back to not-measured instead of failing (the leading-zero shape that once broke `teamctl status`) · a missing file is the normal case |
| the context column: three cases | a known window gives a count and a share · an unknown window, a zero window and a non-numeric window each give the count and **no share — never 0%** · no reading at all is a dash, not a zero · no `%` is ever printed for an unknown window · a team whose agent has an unknown window still renders |
| when the transcript was last written | the context reader reports the file it opened (`CTX_FILE`), so there is no second piece of code working out where a transcript lives · the dashboard reports that file's mtime to the second · the column reaches the view for a running agent · an agent with no transcript reports nothing rather than a zero · the **Codex** rollout path reports its file too |
| the budget | the segment never runs `du` · the segment never runs `ps` · the popup never runs `du` either (all three with `du` and `ps` shadowed on `PATH` by spies that would leave a marker) · the popup takes ONE `ps` for the whole view · the **process tree**, not the pane's own process, is what is summed · a tree with a cycle in it still terminates · a pid that is not in the snapshot is zero, and no pid at all is no reading rather than a zero |
| the segment is silent on any error | a failing segment prints nothing and still exits 0 · one that somehow prints several lines is cut to one · **no control character ever reaches the status bar**, and neither the escape introducer nor the bell survives · an over-long line is bounded · without tmux it says nothing rather than claiming `0run` · a state directory that is not there is not an error, and the stopped count never goes negative when records and panes disagree |
| a stopped agent, an orphaned team | a stopped worker is on record with no pane and reports no cpu reading rather than a zero · by default a stopped agent is not read from disk and the view says so · `--full` reads every agent and drops that note · the segment counts it stopped, not running · with its lead stopped the team is `orphaned`, as `teamctl teams` says |
| one bad project never takes it down | an unreadable state directory (`chmod 000`) does not stop the view and is **named rather than silently dropped** · a project with nothing on record is reported apart from it, as a start that never became a team · a half-written `meta.json` does not stop the view · the segment survives all of it |
| options, and read-only | `--interval` takes a number and refuses nonsense, zero and a missing value (exit 64) · an unknown option is a usage error naming the command · tab completion offers `dashboard` and every option its parser accepts · **the view changes nothing**: the whole JSON of every project is identical before and after drawing the popup and the segment |
| the key | `prefix O` is bound to the popup, `status-right` carries the segment, and the other lane's `status-left` and `status-interval` are untouched |

### How `tmux.conf` resolves `teamctl`, and how that was verified

Both entries — `bind O` and the `status-right` segment — resolve `teamctl` through one
shared spelling, agreed with the quiet-nudges lane and approved by the lead:

```
#{?@wolfmux_teamctl,#{@wolfmux_teamctl},teamctl}
```

`teamctl` sets `@wolfmux_teamctl` to its own absolute path at team start, and the
conditional falls back to a bare `teamctl` when it is unset, which is exactly the previous
behaviour. So the file is correct on its own, in either merge order, and on a session
started by an older `teamctl`. This module declares no `set -g @wolfmux_teamctl` of its own;
the quiet-nudges region owns that line.

Three checks in `tests/dashboard.sh` measure this against a real tmux server with a real pty
client: with the option unset the bare `teamctl` on `PATH` runs; with it set that absolute
path runs and `PATH` is not used; and a nested `#{...}` really is expanded inside `#()`.

The method matters, because the obvious ones all give false negatives. Reading the result
back through a format (`#{T:status-right}`, `#{E:status-left}`) returns **empty even in a run
that demonstrably rendered**, and with no client attached tmux never runs the `#()` job at
all — so a plain absolute-path *control* fails too, which is what makes the false negative
convincing. Two things work: have the command **touch a marker file** (what the tests do, and
what proves execution rather than rendering), or attach a real pty client, wait, force a
refresh, and grep a captured typescript for a **literal marker** placed around the segment
(what the lead used to prove the output also draws).

**One consequence, documented rather than fixed:** tmux draws the status line *before* the
`#()` job has produced anything, so the first rendered draw of the segment is **empty** and
the next one carries its output. After a client attaches, or a server restarts, the segment
is blank for up to `status-interval` seconds. It is inherent to how tmux runs `#()`. No
document here claims the segment appears immediately.

### The socket is handed in, never assumed

`tmx` targets `$WOLFMUX_TMUX_SOCKET`, default `wolfmux`. A `#()` status job inherits the tmux
**server's** environment, and nothing in it says which socket the job is being drawn on — so
a badge that asked tmux itself would silently report the *default* socket's state instead of
the one it is drawn on. On the live server the default happens to be the right answer, which
is the same kind of luck as a bare `teamctl` on `PATH`, and this segment is silent on error,
so it would never say otherwise. Found by the quiet-nudges lane in their own badge; same
class of bug, same fix.

So `tmux.conf` passes `#{socket_path}` to the segment, and the popup reads the socket out of
`$TMUX` (which tmux sets inside a pane or a `display-popup`). A path that is not a socket is
ignored and the previous behaviour stands, because a view that asked a socket which is not
there would report an empty machine — worse than asking the default.

Measured, and the difference is the proof: against a second tmux server carrying none of the
suite's agents the segment reports `0run`; against the default, in the same run, it still
reports this suite's own running agents. Were the argument ignored the two answers would be
identical. Also checked: a non-socket path and a path that does not exist both fall back
without failing and without the segment speaking out of turn.

### Measured, on the machine it was written on

Taken with 2 projects, 20 teams, 75 agents on record and 12 of them running, under a system
load between 2 and 13.

| | Measured | Note |
|---|---|---|
| the segment, own work | **18 ms** | 20 runs averaged; 82 ms per invocation in all, of which **64 ms is `teamctl`'s own startup** — sourcing the eighteen library files the source list held when this was measured (nineteen on this base, so the share is now marginally higher), a cost every `teamctl` command pays, including the other lane's `_inbox-badge` |
| the popup, full walk | **1.42 – 1.95 s** | budget was 2 s |
| the popup, first version | 6.17 s | before the bulk reads: `reg_list` spawns a `jq` per record, `reg_field` one per field, `team_orphaned` asks tmux three times per team — about 600 processes |

The 6.17 s is why the fast-path helpers exist, and the equivalence group above is what keeps
them honest. The order the savings came in: bulk record read 6.17 → 2.54 s; fork-free pane
lookup, team enumeration and orphan test, plus reading per-agent transcripts only for
RUNNING agents, 2.54 → 1.5 s.

### The signal-skip rule: a rule, not a number

An earlier draft of this document described the check "a crash is never silent … (issue
#6)" as a **failure** of unknown cause, and recorded a pass count that assumed it. That
description was correct when it was written and is no longer true: the cause was found and
fixed upstream, so this section now records the rule that replaced it.

`nohup` leaves `SIGHUP` ignored in the child, and an inherited `SIG_IGN` cannot be undone
from inside the process. A background job started from a non-interactive shell inherits
`SIGINT` and `SIGQUIT` as `SIG_IGN` the same way — a bare `&` alone is enough. The check
cannot test a signal the launch has already made untestable, so rather than fail it now
**skips, and prints its reason**: v1.14.2 did this for `SIGHUP` and v1.14.4 for `SIGINT`.

So the skip count is a **rule, not a figure**:

> One skip per signal the launch leaves ignored.

A detached launch can leave `{HUP, INT, QUIT}` ignored and skip up to three. Launched
through a parent that resets the signals, nothing is skipped. Two consequences worth
stating, because both have cost this project time:

- **A pass count without its launch shape is not a fact.** The same tree, the same sha and
  the same checks report a different pass/skip split under a different launch. A figure
  quoted without its shape becomes false without any count changing — which is how a
  stale `327 of 327` survived three releases in this file.
- **Launched wrong, checks skip for reasons that have nothing to do with the code under
  test.** To reproduce the clean-shape figures above, launch the suite through a parent
  that resets both signals:

```bash
perl -e '$SIG{HUP}="DEFAULT"; $SIG{INT}="DEFAULT"; exec @ARGV' bash tests/smoke.sh
```

Base `e431740` (v1.15.0).
Each shape is named by its **dispositions**, which are the cause; the command is only the
way to reproduce them. The total is 348 in every shape — only the pass/skip split moves:

| Dispositions | How to reproduce it | smoke.sh |
|---|---|---|
| HUP default, INT default | a parent that resets both, then `exec` | **348 passed, 0 failed, 0 skipped** |
| HUP ignored, INT default | a real `nohup` run | 347 passed, 0 failed, 1 skipped (SIGHUP) |
| HUP default, INT **ignored** | a bare `… &` from a non-interactive shell | 347 passed, 0 failed, 1 skipped (SIGINT) |
| HUP ignored, INT ignored | `nohup … &` — **a lane's real launch** | 346 passed, 0 failed, 2 skipped |

Row 1 was re-measured for v1.16.1 at `ded20f1`, in one acquisition of the heavy lock, and
is the figure the total at the top of this file uses. Rows 3 and 4 are v1.16.0's measurements
at `083fe9f` and row 2 is v1.15.0's at `9d9f84b`: **v1.16.1 did not re-measure the three
detached shapes.** They are carried because this release changes no signal handler and no
check that sends itself a signal — its diff is `_nudge_one`'s ordering, one tmux helper's
argument list, two marker accessors, the config allowlist and documents — and because what
those three rows assert is a RULE, one skip per signal the launch leaves ignored, which row 1
cannot contradict. A reader who wants them at this release's sha has to run them; nothing
here claims they were. Zero FAIL lines in every run quoted.

Rows 2 and 3 are the point of the table. They skip the SAME NUMBER of checks for
DIFFERENT signals, and row 3 is the one that proves the two skip paths are **independent**:
with HUP left at its default the SIGHUP check PASSES while the SIGINT check skips, so
v1.14.4's SIGINT arm is not riding on v1.14.2's SIGHUP arm. Across the four shapes the skip
count is exactly the number of signals the launch left ignored — 0, 1, 1, 2 — which is the
rule, measured rather than argued. Together the four cover every combination of the two
dispositions.

Measured in the same acquisition, clean shape, at `ded20f1`: `tests/inbox.sh` 107
passed, 0 failed; `tests/nudge-typing.sh` 61 passed, 0 failed; `tests/providers.sh` 141
passed, 0 failed, 0 skipped; `tests/docs.sh` 36 passed, 0 failed; `tests/dashboard.sh` 115
passed, 0 failed, 0 skipped; `tests/disk.sh` 93 passed, 0 failed; `tests/migration.sh` 36
passed, 0 failed; `tests/permissions.sh` 13 passed, 0 failed.

**What the suite total at the top of this file is, and is not.** Nothing in the repository
runs the suites as a set — there is no runner, no build file and no CI (see
[ROADMAP.md](ROADMAP.md#known-limits-of-v1)). So that 950 is a **hand-assembled sum of one
measured acquisition** (v1.16.0's 933 was a sum of two), each figure carrying the commit and
launch shape it was measured in, not a figure any tool produces. It is therefore correct for
that commit and that launch shape and for nothing else, and **nothing checks it
afterwards**: the moment a suite grows, the sum goes stale silently and looks exactly as
right as it did before. That is why every count in this document still carries its own suite
name, sha and shape — those are the facts, and the total is a convenience derived from them.

Read a bare total here as a claim about the one acquisition those nine figures came from,
never as a property of the repository.

### Not verified in this suite

- **A live Codex agent.** The `wrote` column reads the mtime of the file `agent_context`
  opened, and for the Codex family that is the rollout under `WOLFMUX_CODEX_SESSIONS`. No
  Codex agent was running on this machine, so that path is verified against a rollout
  **built by the test**, not against a live Codex session. The Claude path was verified both
  ways: by the test, and live — a running agent's transcript showed `wrote 2s` and the
  number tracked its turns.
- **The unknown-window case against the real v1.14.1 code.** v1.14.1 is the commit that
  makes `model_context_window` able to return nothing. This branch was written on v1.14.0,
  so the three context cases are exercised against `dash_context_label` directly and
  through a stubbed `agent_context`, not against the shipped 1.14.1 behaviour.
- **More than about 25 teams or 75 agents on one machine**, which is what was here.

## Not verified

- `WOLFMUX_GLM_AUTH_MODE=env` against the real endpoint (helper mode worked, so the
  fallback was never needed).
- Model ids sent by background features of an *interactive* session (titles,
  suggestions). The `-p` runs showed only `glm-5.3`; the alias mapping covers the
  rest by configuration, not by observation.
- Behaviour with more than about eight concurrent agents.
- **shellcheck is not installed on this machine**, so no shell file in this release was
  linted. `bash -n` was run on every file that changed and the suites exercise them, but
  nothing here stands in for shellcheck and this document does not imply it ran.
- **A real human's keystrokes against `WOLFMUX_NUDGE_LEAD_IDLE`.** The keystroke check
  reads an attached client's `#{client_activity}`, which `tmux send-keys` does not move,
  so no test can type as the human. `tests/nudge-typing.sh` compares the window against
  the real pty client's own activity timestamp instead — the same comparison the code
  makes — and the half-typed-line arm of the same rule is driven directly. What is NOT
  measured is a person at a keyboard: whether 300 s is the right number for how long
  somebody reads the lead's answer before a notice may go in is a judgement, and
  `docs/ROADMAP.md` carries it as one.
- **v1.16.1's fix in the owner's own running teams.** It was measured only in the suites'
  throwaway tmux servers. The production evidence quoted here (a lead idle from 13:58Z,
  P1 notices at 16:13Z and 16:53Z never delivered) is evidence of the BUG on the installed
  v1.16.0, not of the fix: this release is not installed, by instruction.
