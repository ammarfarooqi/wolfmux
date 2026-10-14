#!/bin/bash
# models.sh — what fable, opus, sonnet and haiku mean (WOLFMUX_MODEL_POLICY, lib/models.sh):
# the newest model resolved at spawn, a pin that wins, one probe a day and not one per spawn,
# a visible fallback, labels derived from the id, the id on record, and the drift check.
#
# No model is called. Claude Code is a stand-in (below) that answers the probe from a file per
# alias and is otherwise tests/stub-agent. Everything runs in a throwaway HOME, data directory,
# git repository and tmux server (socket wolfmux-test-models-<pid>), set up and removed by this
# one script. Needs tmux, git and jq.
#
#   tests/models.sh
# No pipefail: checks end in `grep -q`, which closes the pipe early by design.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-models.XXXXXX")"
export HOME="$WORK/home"
/bin/mkdir -p "$HOME"
export WOLFMUX_HOME="$REPO/config/wolfmux"
export WOLFMUX_BIN_DIR="$REPO/bin"
export WOLFMUX_DATA="$WORK/data"
export WOLFMUX_TMUX_SOCKET="wolfmux-test-models-$$" WOLFMUX_LEGACY_SOCKET="wolfmux-test-models-old-$$"
export WOLFMUX_CLAUDE_PROJECTS="$WORK/claude-projects" WOLFMUX_CODEX_SESSIONS="$WORK/codex-sessions"
FAKE="$WORK/fake"
export FAKE
/bin/mkdir -p "$FAKE/answers" "$WOLFMUX_CLAUDE_PROJECTS"
# The stand-in for Claude Code behind every subscription key. `-p` is the probe: it logs which
# alias it was asked about and answers with the id in answers/<alias> (FAIL: a broken answer;
# no file: nothing at all). Anything else is an agent being started: tests/stub-agent.
/bin/cat >"$FAKE/claude" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-p" ]; then
  model="" prev=""
  for arg in "$@"; do
    if [ "$prev" = "--model" ]; then model="$arg"; fi
    prev="$arg"
  done
  printf '%s\n' "$model" >>"$FAKE/probes.log"
  [ -f "$FAKE/answers/$model" ] || exit 1
  id="$(cat "$FAKE/answers/$model")"
  if [ "$id" = "FAIL" ]; then
    echo "Error: something went wrong" >&2
    exit 3
  fi
  window=1000000 # the window that answer declares: answers/<alias>.window, else 1M
  [ ! -f "$FAKE/answers/$model.window" ] || window="$(cat "$FAKE/answers/$model.window")"
  printf '{"type":"result","subtype":"success","is_error":false,"result":"ok","modelUsage":{"%s":{"inputTokens":2,"contextWindow":%s}}}\n' "$id" "$window"
  exit 0
fi
echo "FAKE sonnet_pin=${WOLFMUX_SONNET_MODEL:-none}"
exec "$STUB_AGENT" "$@"
EOF
/bin/chmod 755 "$FAKE/claude"
export STUB_AGENT="$REPO/tests/stub-agent"
export WOLFMUX_LAUNCHER_FABLE="$FAKE/claude" WOLFMUX_LAUNCHER_OPUS="$FAKE/claude"
export WOLFMUX_LAUNCHER_SONNET="$FAKE/claude" WOLFMUX_LAUNCHER_HAIKU="$FAKE/claude"
export WOLFMUX_LAUNCHER_ASTRA="$REPO/tests/stub-agent" WOLFMUX_LAUNCHER_CLAUDE="$REPO/tests/stub-agent"
# Run from an agent's pane, the environment carries that agent's identity and its own pins.
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR WOLFMUX_NOTIFY WOLFMUX_SPLASH WOLFMUX_METERED TMUX TMUX_PANE
unset WOLFMUX_TEAM WOLFMUX_TEAM_ARG WOLFMUX_SESSION WOLFMUX_WORKTREE WOLFMUX_BRANCH WOLFMUX_MODEL WOLFMUX_EXTRA_SETTINGS
unset WOLFMUX_FABLE_MODEL WOLFMUX_OPUS_MODEL WOLFMUX_SONNET_MODEL WOLFMUX_HAIKU_MODEL WOLFMUX_MODEL_POLICY CLAUDE_CONFIG_DIR
export WOLFMUX_NOTIFY=off WOLFMUX_SPLASH=off
teamctl() { "$REPO/bin/teamctl" "$@"; }

passed=0
failed=0
check() { # <description> <command string>
  if eval "$2" >/dev/null 2>&1; then
    passed=$((passed + 1))
    printf '  pass  %s\n' "$1"
  else
    failed=$((failed + 1))
    printf '  FAIL  %s\n' "$1"
  fi
}
cleanup() {
  tmux -L "$WOLFMUX_TMUX_SOCKET" kill-server >/dev/null 2>&1
  /bin/rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$WOLFMUX_TMUX_SOCKET"
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT

probes() { grep -cx "$1" "$FAKE/probes.log" 2>/dev/null || true; } # how often <alias> was probed
field() { teamctl status --json | jq -r --arg r "$1" --arg f "$2" '.agents[] | select(.role == $r) | .[$f] // ""'; }
record() { cat "$(ls -d "$WOLFMUX_DATA"/state/*/agents/"$1".json)"; }
transcript_of() { # <role>: the file of that agent's own conversation (its folder is made)
  local dir
  dir="$WOLFMUX_CLAUDE_PROJECTS/$(cd "$(field "$1" workdir)" && pwd -P | sed 's|[^A-Za-z0-9]|-|g')"
  /bin/mkdir -p "$dir"
  printf '%s/%s.jsonl\n' "$dir" "$(field "$1" session_id)"
}
answer() { # <model id> <tokens> <timestamp>: one answer, as Claude Code writes it into a transcript
  printf '{"type":"assistant","timestamp":"%s","message":{"model":"%s","usage":{"input_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[]}}\n' "$3" "$1" "$2"
}
# old_record <role>: its record as teamctl wrote it before v1.18.0: the alias, and no id, no
# source, no window and no time for an id.
old_record() {
  local file
  file="$(ls -d "$WOLFMUX_DATA"/state/*/agents/"$1".json)"
  jq '.model_id = "" | del(.model_source, .model_context, .model_at)' "$file" >"$file.new" && /bin/mv "$file.new" "$file"
}
ALIAS_KEY='^(fable|opus|sonnet|haiku)$'
# What each view says about every running agent on an alias: role|id|label|provenance[|context]
status_says() {
  teamctl status --json | jq -r --arg k "$ALIAS_KEY" '[.agents[] | select(.state == "running" and (.model | test($k))) |
    [.role, (.model_id // "-"), .label, (.known_from // "-"), .context] | join("|")] | sort | .[]'
}
dashboard_says() {
  teamctl dashboard --json --once | jq -r --arg k "$ALIAS_KEY" '[.projects[].teams[].agents[] | select(.state == "running" and (.model | test($k))) |
    [.role, (.model_id // "-"), .label, (.known_from // "-"), .context] | join("|")] | sort | .[]'
}
models_says() {
  teamctl models --json | jq -r '[.agents[] | [.role, (.running_id // "-"), .label, .known_from] | join("|")] | sort | .[]'
}
pane_says() { # <role> <text>: the agent's pane shows that line (the stub prints how it was started)
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    teamctl capture "$1" --all 2>/dev/null | grep -qF -- "$2" && return 0
    sleep 0.3
  done
  return 1
}

PROJECT="$WORK/demo project" # the space is deliberate
/bin/mkdir -p "$PROJECT"
cd "$PROJECT" || exit 1
git init -q -b main
echo "hello" >README.md
git add -A
git -c user.name=models -c user.email=models@example.invalid commit -qm "initial commit"
# What tmux hands the status bar (#{@wolfmux_root}): the root as teamctl resolved it, symlinks
# and all ($TMPDIR is under /var, which is /private/var).
ROOT_REAL="$(pwd -P)"

echo "== the launcher run by hand (dry run: nothing is started)"
/bin/mkdir -p "$WORK/linkbin"
/bin/ln -s "$REPO/bin/claude-fable" "$WORK/linkbin/claude-opus"
dry() { env -u WOLFMUX_EXTRA_SETTINGS WOLFMUX_DRY_RUN=1 "$@" 2>&1 | grep "would exec"; }
check "launcher: no pin means Claude Code's own alias (its newest model); policy pinned means the built-in id; a pin beats both" \
  'dry "$WORK/linkbin/claude-opus" | grep -q -- "--model opus$" && dry "$REPO/bin/claude-fable" | grep -q -- "--model fable$" &&
   dry env WOLFMUX_MODEL_POLICY=pinned "$WORK/linkbin/claude-opus" | grep -q -- "--model claude-opus-5-5$" &&
   dry env WOLFMUX_MODEL_POLICY=pinned WOLFMUX_OPUS_MODEL=claude-opus-9 "$WORK/linkbin/claude-opus" | grep -q -- "--model claude-opus-9$"'

printf '#!/bin/bash\necho "ARGS $*"\necho "PIN ${WOLFMUX_OPUS_MODEL:-none}"\n' >"$FAKE/envdump"
/bin/chmod 755 "$FAKE/envdump"
check "launcher: a pin is used, then not handed on to the agent's own shell (its teamctl reads the config as it is now)" \
  'out="$(env -u WOLFMUX_EXTRA_SETTINGS WOLFMUX_CLAUDE_BIN="$FAKE/envdump" WOLFMUX_OPUS_MODEL=claude-opus-9 "$WORK/linkbin/claude-opus" 2>&1)";
   printf "%s" "$out" | grep -q -- "--model claude-opus-9" && printf "%s" "$out" | grep -qx "PIN none"'

echo "== a fresh machine, policy latest (the default)"
teamctl start astra --no-attach --skip-beads >/dev/null 2>&1
echo "claude-opus-5-5" >"$FAKE/answers/opus"
SPAWN_X="$(teamctl spawn x opus --no-kickoff 2>&1)"
check "spawn x opus: Claude Code is asked once what opus means, and x is started on that id (claude-opus-5-5)" \
  '[ "$(probes opus)" = 1 ] && [ "$(record x | jq -r .model_id)" = "claude-opus-5-5" ] && pane_says x "STUB modelarg=claude-opus-5-5"'
check "labels come from the id: Opus 5.5 in status, on the pane border and in the spawn report" \
  '[ "$(field x label)" = "Opus 5.5" ] && [ "$(field x model_id)" = "claude-opus-5-5" ] &&
   [ "$(tmux -L "$WOLFMUX_TMUX_SOCKET" show-options -p -v -t "$(field x pane)" @ai_label)" = "Opus 5.5" ] &&
   printf "%s" "$SPAWN_X" | grep -q "(Opus 5.5 via claude-opus)" && printf "%s" "$SPAWN_X" | grep -q "^model: *claude-opus-5-5 *(Claude Code, asked today"'
teamctl spawn y opus --no-kickoff >/dev/null 2>&1
check "no network call at every spawn: a second opus spawn the same day reuses today's answer" \
  '[ "$(probes opus)" = 1 ] && [ "$(record y | jq -r .model_id)" = "claude-opus-5-5" ] && record y | jq -e ".model_source | startswith(\"Claude Code, asked today\")"'
teamctl start opus --team second --no-attach --skip-beads >/dev/null 2>&1
check "teamctl start opus: a lead is resolved, recorded and labelled the same way, from today's answer" \
  '[ "$(probes opus)" = 1 ] && [ "$(teamctl status --json --team second | jq -r ".agents[] | select(.role == \"lead\") | .model_id")" = "claude-opus-5-5" ] &&
   [ "$(teamctl teams --json | jq -r ".[] | select(.team == \"second\") | .lead")" = "Opus 5.5" ]'
teamctl destroy --team second --yes >/dev/null 2>&1
echo "claude-sonnet-6" >"$FAKE/answers/sonnet"
echo "640000" >"$FAKE/answers/sonnet.window" # a window of its own, so a share of it cannot be mistaken for another model's
teamctl spawn s1 sonnet --no-kickoff >/dev/null 2>&1
check "latest follows Claude Code's answer, not a table: a sonnet answered as claude-sonnet-6 is started on it, as Sonnet 6" \
  '[ "$(probes sonnet)" = 1 ] && [ "$(record s1 | jq -r .model_id)" = "claude-sonnet-6" ] && [ "$(field s1 label)" = "Sonnet 6" ] && pane_says s1 "STUB modelarg=claude-sonnet-6"'

echo "== a pin, and policy pinned"
PINNED_HOME="$WORK/wolfmux-home-pinned" # the program folder, with a config of its own
/bin/mkdir -p "$PINNED_HOME"
for entry in "$REPO"/config/wolfmux/*; do [ "$(basename "$entry")" = "config" ] || /bin/ln -s "$entry" "$PINNED_HOME/"; done
printf 'WOLFMUX_HAIKU_MODEL=claude-haiku-4-5-20251001\n' >"$PINNED_HOME/config"
echo "claude-haiku-5-5" >"$FAKE/answers/haiku"
SPAWN_H="$(WOLFMUX_HOME="$PINNED_HOME" "$REPO/bin/teamctl" spawn h1 haiku --no-kickoff 2>&1)"
check "a pin in the config still wins under latest: never probed, started on the pinned id, and the record says why" \
  '[ "$(probes haiku)" = 0 ] && [ "$(record h1 | jq -r .model_id)" = "claude-haiku-4-5-20251001" ] && pane_says h1 "STUB modelarg=claude-haiku-4-5-20251001" &&
   record h1 | jq -e ".model_source == \"config pin (WOLFMUX_HAIKU_MODEL)\"" && [ "$(field h1 label)" = "Haiku 4.5" ]'
WOLFMUX_MODEL_POLICY=pinned teamctl spawn s2 sonnet --no-kickoff >/dev/null 2>&1
check "policy pinned: the built-in id, even with today's answer cached, and nothing is asked" \
  '[ "$(probes sonnet)" = 1 ] && [ "$(record s2 | jq -r .model_id)" = "claude-sonnet-5-5" ] && record s2 | jq -e ".model_source == \"built-in (policy pinned)\""'
check "a pin that comes from the environment, not the config file, is named as such" \
  'WOLFMUX_SONNET_MODEL=claude-sonnet-9 teamctl models | grep -Eq "^  sonnet +claude-sonnet-9 +Sonnet 9 +environment pin \(WOLFMUX_SONNET_MODEL is set in this environment, not in the config file\)"'
# The tmux server took the config's values in when the team started; a pane must not carry them.
tmux -L "$WOLFMUX_TMUX_SOCKET" set-environment -g WOLFMUX_SONNET_MODEL claude-sonnet-9
teamctl spawn s3 sonnet --no-kickoff >/dev/null 2>&1
tmux -L "$WOLFMUX_TMUX_SOCKET" set-environment -g -u WOLFMUX_SONNET_MODEL
check "an agent's pane does not inherit a pin frozen into the tmux server: it runs its record's id, and its shell has no pin" \
  '[ "$(record s3 | jq -r .model_id)" = "claude-sonnet-6" ] && pane_says s3 "STUB modelarg=claude-sonnet-6" && pane_says s3 "FAKE sonnet_pin=none"'

echo "== a probe that fails"
echo "FAIL" >"$FAKE/answers/fable"
SPAWN_F1="$(teamctl spawn f1 fable --no-kickoff 2>&1)"
SPAWN_F2="$(teamctl spawn f2 fable --no-kickoff 2>&1)"
check "a failed probe falls back to the built-in id and WARNS at every spawn; it is not retried at every spawn" \
  '[ "$(probes fable)" = 1 ] && [ "$(record f1 | jq -r .model_id)" = "claude-fable-5-1" ] && [ "$(record f2 | jq -r .model_id)" = "claude-fable-5-1" ] &&
   printf "%s" "$SPAWN_F1" | grep -q "fable: could not confirm the newest model (fallback: asking Claude Code failed .*something went wrong). Using the built-in id claude-fable-5-1" &&
   printf "%s" "$SPAWN_F2" | grep -q "fable: could not confirm the newest model"'

echo "== teamctl models"
MODELS_OUT="$(teamctl models 2>&1)"
check "teamctl models: alias, resolved id, label and where it came from, and the agents running on each" \
  'printf "%s" "$MODELS_OUT" | grep -Eq "^  opus +claude-opus-5-5 +Opus 5.5 +Claude Code, asked today" &&
   printf "%s" "$MODELS_OUT" | grep -Eq "^  sonnet +claude-sonnet-6 +Sonnet 6 +Claude Code, asked today" &&
   printf "%s" "$MODELS_OUT" | grep -Eq "^  fable +claude-fable-5-1 +Fable 5.1 +fallback: asking Claude Code failed" &&
   printf "%s" "$MODELS_OUT" | grep -Eq "^  default +x +opus +claude-opus-5-5 +Opus 5.5 +record +no$" &&
   teamctl models --json | jq -e ".policy == \"latest\" and (.aliases | length == 4) and ([.agents[] | select(.role == \"x\")][0].running_id == \"claude-opus-5-5\")"'
check "teamctl models refuses an option it does not know, by name" \
  'out="$(teamctl models --bogus 2>&1)"; [ $? -eq 64 ] && printf "%s" "$out" | grep -q "unknown option for models: --bogus"'

echo "== a newer model appears: the drift check"
echo "claude-opus-6" >"$FAKE/answers/opus"
X_PANE="$(field x pane)"
teamctl models --refresh >/dev/null 2>&1
DOCTOR_HOME="$WORK/doctor-home"
/bin/mkdir -p "$DOCTOR_HOME/.claude" "$WORK/stubbin"
printf '#!/bin/bash\necho "{}"\n' >"$WORK/stubbin/claude"
/bin/chmod 755 "$WORK/stubbin/claude"
doctor() { env HOME="$DOCTOR_HOME" WOLFMUX_CLAUDE_BIN="$WORK/stubbin/claude" WOLFMUX_CODEX_BIN="$WORK/stubbin/claude" "$REPO/bin/teamctl" doctor 2>&1 </dev/null; }
DOCTOR_OUT="$(doctor)"
check "doctor: names each agent on an older model than the newest known, with the restart that moves it" \
  '[ "$(probes opus)" = 2 ] && printf "%s" "$DOCTOR_OUT" | grep -q "x runs claude-opus-5-5 (from its record); claude-opus-6 is newer. Nothing restarts by itself: teamctl restart x --continue" &&
   printf "%s" "$DOCTOR_OUT" | grep -q "opus -> claude-opus-6 (Opus 6), Claude Code, asked today"'
# Behind: x and y (opus 5.5 < 6), s2 (sonnet 5.5 < 6) and h1 (its pin, haiku 4.5 < the 5.5 the
# refresh just saw). Not: s1 (sonnet 6), f1 and f2 (fable 5.1, nothing newer known), the astra lead.
check "doctor: a config pin behind the newest known is a warning that names the line to delete (it never moves by itself)" \
  'env WOLFMUX_HOME="$PINNED_HOME" HOME="$DOCTOR_HOME" WOLFMUX_CLAUDE_BIN="$WORK/stubbin/claude" WOLFMUX_CODEX_BIN="$WORK/stubbin/claude" "$REPO/bin/teamctl" doctor 2>&1 </dev/null |
   grep -qF "haiku -> claude-haiku-4-5-20251001 (Haiku 4.5), config pin (WOLFMUX_HAIKU_MODEL); claude-haiku-5-5 is newer. A pin is a pin: delete that line from $PINNED_HOME/config"'
check "the status bar says it too, for this team, from records and the cache alone" \
  '[ "$(teamctl _model-badge "$ROOT_REAL" default)" = "models: 4 older - teamctl models" ]'
check "nothing restarted itself: x is in the same pane, on the id it started with" \
  '[ "$(field x pane)" = "$X_PANE" ] && [ "$(record x | jq -r .model_id)" = "claude-opus-5-5" ]'
teamctl restart x >/dev/null 2>&1
check "teamctl restart x moves it: the record, the label and the started CLI all say claude-opus-6" \
  '[ "$(record x | jq -r .model_id)" = "claude-opus-6" ] && [ "$(field x label)" = "Opus 6" ] && pane_says x "STUB modelarg=claude-opus-6"'

echo "== a record from before this release"
# As teamctl wrote it before v1.18.0: the alias and a label from the old table, and no id, no
# source and no window. (v1.18.0's own fixture left the window in, which is how this suite
# missed that such an agent had lost its context share.)
old_record y
Y_FILE="$(ls -d "$WOLFMUX_DATA"/state/*/agents/y.json)"
jq '.label = "Opus 5"' "$Y_FILE" >"$Y_FILE.new" && /bin/mv "$Y_FILE.new" "$Y_FILE"
check "an old record is unknown, never assumed current: status says Opus ?, doctor and the status bar say unknown" \
  '[ "$(field y label)" = "Opus ?" ] && [ -z "$(field y model_id)" ] &&
   doctor | grep -q "y (opus): which model it runs is unknown (started before this release, nothing in its transcript yet). teamctl restart y --continue records it" &&
   teamctl _model-badge "$ROOT_REAL" default | grep -q "1 unknown"'
{
  printf '%s\n' '{"type":"user","message":{"content":"hi"}}'
  answer claude-opus-5 411000 2020-01-01T00:00:00.000Z
} >"$(transcript_of y)"
check "what its transcript shows was served is used when the record has nothing: y runs claude-opus-5, and is behind" \
  'doctor | grep -q "y runs claude-opus-5 (from its transcript); claude-opus-6 is newer. Nothing restarts by itself: teamctl restart y --continue" &&
   teamctl models --json | jq -e "[.agents[] | select(.role == \"y\")][0] | .running_id == \"claude-opus-5\" and .known_from == \"transcript\" and .verdict == \"behind\""'

echo "== one answer to 'which model does this agent run', in every view"
check "status looks where models looks: y is Opus 5 (claude-opus-5) from its transcript, marked * because its record does not vouch for it" \
  '[ "$(field y label)" = "Opus 5" ] && [ "$(field y model_id)" = "claude-opus-5" ] && [ "$(field y known_from)" = "transcript" ] && [ -z "$(field y recorded_id)" ] &&
   teamctl status | grep -Eq "y +Opus 5\* +running" && teamctl status | grep -q "^  \* = "'
check "the window comes with the id: 411k of the 1M Claude Code declared for claude-opus-5 is 41%, in json and in the table" \
  'teamctl status --json | jq -e "[.agents[] | select(.role == \"y\")][0] | .context_tokens == 411000 and .context_window == 1000000 and .context == \"411k 41%\"" &&
   teamctl status | grep -Eq "y +Opus 5\* .*411k +41%"'
# The no-guess rule, kept: a share is printed only of a window Claude Code declared for exactly
# the model the agent runs. f1: nothing says which model. f2: the model is known, its window is not.
old_record f1
old_record f2
printf '%s\n' '{"type":"assistant","timestamp":"2020-01-01T00:00:00.000Z","message":{"usage":{"input_tokens":150000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' >"$(transcript_of f1)"
answer claude-fable-4-2 150000 2020-01-01T00:00:00.000Z >"$(transcript_of f2)"
check "no guess when the model is unknown: f1 (no id on record, no model in its transcript) is Fable ?, 150k, and no share of what fable means today" \
  'teamctl status --json | jq -e "[.agents[] | select(.role == \"f1\")][0] | .label == \"Fable ?\" and .model_id == null and .known_from == \"unknown\" and .context_tokens == 150000 and .context_window == 0 and .context == \"150k\""'
check "no guess when the model is known and its window is not: f2 is Fable 4.2*, 150k, and no share of another model's window" \
  'teamctl status --json | jq -e "[.agents[] | select(.role == \"f2\")][0] | .label == \"Fable 4.2\" and .model_id == \"claude-fable-4-2\" and .context_tokens == 150000 and .context_window == 0 and .context == \"150k\"" &&
   teamctl status | grep -Eq "f2 +Fable 4.2\* .* 150k +[~/]"'
# sonnet moves on to claude-sonnet-7. s3 still runs claude-sonnet-6, known from its transcript
# alone; the window Claude Code declared for that id (640k, at s1's spawn) is still this machine's.
old_record s3
answer claude-sonnet-6 320000 2020-01-01T00:00:00.000Z >"$(transcript_of s3)"
echo "claude-sonnet-7" >"$FAKE/answers/sonnet"
/bin/rm -f "$FAKE/answers/sonnet.window"
teamctl models --refresh >/dev/null 2>&1
check "a window this machine was told is kept after the alias moves on: sonnet means claude-sonnet-7 now, s3 still shows 320k as 50% of claude-sonnet-6's 640k" \
  'teamctl models | grep -Eq "^  sonnet +claude-sonnet-7 " &&
   teamctl status --json | jq -e "[.agents[] | select(.role == \"s3\")][0] | .model_id == \"claude-sonnet-6\" and .context_window == 640000 and .context == \"320k 50%\""'
# x was restarted on claude-opus-6 above; an answer written after that came from another model.
answer claude-opus-5-5 90000 2099-01-01T00:00:00.000Z >"$(transcript_of x)"
check "what was served outranks what was asked for: x's record says claude-opus-6, a later answer came from claude-opus-5-5, so status and models both say Opus 5.5, marked, and behind" \
  '[ "$(field x label)" = "Opus 5.5" ] && [ "$(field x model_id)" = "claude-opus-5-5" ] && [ "$(field x recorded_id)" = "claude-opus-6" ] && [ "$(field x known_from)" = "transcript" ] &&
   teamctl status | grep -Eq "x +Opus 5.5\* +running" &&
   teamctl models --json | jq -e "[.agents[] | select(.role == \"x\")][0] | .running_id == \"claude-opus-5-5\" and .known_from == \"transcript\" and .verdict == \"behind\""'
answer claude-sonnet-6 1000 2099-01-01T00:00:00.000Z >"$(transcript_of s1)"
check "a record its transcript agrees with is vouched for: s1 is Sonnet 6 with no mark, known from its record, in status and in models" \
  '[ "$(field s1 label)" = "Sonnet 6" ] && [ "$(field s1 known_from)" = "record" ] && teamctl status | grep -Eq "s1 +Sonnet 6 +running" &&
   teamctl models --json | jq -e "[.agents[] | select(.role == \"s1\")][0] | .running_id == \"claude-sonnet-6\" and .known_from == \"record\""'
# s2's record is one v1.18.0 wrote: an id, and no time for it. Nothing proves that id newer than
# the last answer, so the answer keeps the last word (as it had in v1.18.0's teamctl models).
S2_FILE="$(ls -d "$WOLFMUX_DATA"/state/*/agents/s2.json)"
jq 'del(.model_at)' "$S2_FILE" >"$S2_FILE.new" && /bin/mv "$S2_FILE.new" "$S2_FILE"
answer claude-sonnet-5 1000 2020-01-01T00:00:00.000Z >"$(transcript_of s2)"
check "a record with an id and no time for it cannot outrank the transcript: s2 (record claude-sonnet-5-5, last answer claude-sonnet-5) is Sonnet 5*" \
  '[ "$(field s2 label)" = "Sonnet 5" ] && [ "$(field s2 recorded_id)" = "claude-sonnet-5-5" ] && [ "$(field s2 known_from)" = "transcript" ] && teamctl status | grep -Eq "s2 +Sonnet 5\* +running"'
# The rule under all of the above: two views must not answer the same question differently.
# Eight agents run on an alias here (x y s1 s2 s3 h1 f1 f2), and all three provenances occur.
check "status and models never answer differently: the same id, label and provenance for every running agent on an alias" \
  'a="$(status_says | cut -d"|" -f1-4)" && b="$(models_says)" && [ -n "$a" ] && [ "$a" = "$b" ] && [ "$(printf "%s\n" "$a" | wc -l | tr -d " ")" = 8 ] &&
   printf "%s\n" "$a" | grep -q "|transcript$" && printf "%s\n" "$a" | grep -q "|record$" && printf "%s\n" "$a" | grep -q "|unknown$"'
check "the dashboard is the same answer a third time: id, label, provenance and context for every running agent, and the same mark in its table" \
  'a="$(status_says)" && b="$(dashboard_says)" && [ "$(printf "%s\n" "$a" | wc -l | tr -d " ")" = 8 ] && [ "$a" = "$b" ] &&
   printf "%s\n" "$b" | grep -qx "y|claude-opus-5|Opus 5|transcript|411k 41%" &&
   teamctl dashboard --once | grep -Eq "y +Opus 5\* +running" && teamctl dashboard --once | grep -q "\* = "'
teamctl start opus --team second --no-attach --skip-beads >/dev/null 2>&1
# Its pane first: a pane that starts fresh and finds a transcript under its conversation id
# takes a new id ("already in use"), and the answer written below would be nobody's.
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  teamctl capture lead --team second --all 2>/dev/null | grep -qF "STUB modelarg=" && break
  sleep 0.3
done
L_FILE="$(ls -d "$WOLFMUX_DATA"/state/*/teams/second/agents/lead.json)"
jq '.model_id = "" | del(.model_source, .model_context, .model_at)' "$L_FILE" >"$L_FILE.new" && /bin/mv "$L_FILE.new" "$L_FILE"
L_DIR="$WOLFMUX_CLAUDE_PROJECTS/$(pwd -P | sed 's|[^A-Za-z0-9]|-|g')" # a lead works in the project itself
/bin/mkdir -p "$L_DIR"
answer claude-opus-5 1000 2020-01-01T00:00:00.000Z >"$L_DIR/$(jq -r .session_id "$L_FILE").jsonl"
check "teamctl teams asks the same question of each lead: Opus 5*, the mark explained, the id and its provenance in json" \
  'teamctl teams | grep -Eq "^second +running +Opus 5\* " && teamctl teams | grep -q "^\* = " &&
   teamctl teams --json | jq -e ".[] | select(.team == \"second\") | .lead == \"Opus 5\" and .lead_model_id == \"claude-opus-5\" and .lead_known_from == \"transcript\""'
teamctl destroy --team second --yes >/dev/null 2>&1
# The move v1.18.0 recommends. A conversation that is continued still ends with the old model's
# answer, so the transcript alone would go on saying Opus 5 and "behind" until y answers again.
teamctl restart y --continue >/dev/null 2>&1
check "a restart is the newer word until the agent answers again: y's record says claude-opus-6, its last answer predates that, and nothing calls it Opus 5 or behind any more" \
  '[ "$(record y | jq -r .model_id)" = "claude-opus-6" ] && [ "$(field y label)" = "Opus 6" ] && [ "$(field y known_from)" = "record" ] && teamctl status | grep -Eq "y +Opus 6 +running" &&
   teamctl models --json | jq -e "[.agents[] | select(.role == \"y\")][0] | .running_id == \"claude-opus-6\" and .known_from == \"record\" and .verdict == \"current\""'

echo "== the policy in the config file"
# A key that is not on WOLFMUX_CONFIG_KEYS is read out of the config file and dropped without
# a word (lib/provider-env.sh): this is the check that the policy is not one of those.
POLICY_HOME="$WORK/wolfmux-home-policy"
/bin/mkdir -p "$POLICY_HOME"
for entry in "$REPO"/config/wolfmux/*; do [ "$(basename "$entry")" = "config" ] || /bin/ln -s "$entry" "$POLICY_HOME/"; done
printf 'WOLFMUX_MODEL_POLICY=pinned\n' >"$POLICY_HOME/config"
check "WOLFMUX_MODEL_POLICY=pinned in the config file takes effect: the built-in ids, nothing asked" \
  'out="$(WOLFMUX_HOME="$POLICY_HOME" "$REPO/bin/teamctl" models 2>&1)" && printf "%s" "$out" | grep -q "^policy:  pinned " &&
   printf "%s" "$out" | grep -Eq "^  opus +claude-opus-5-5 +Opus 5.5 +built-in \(policy pinned\)"'

echo
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
