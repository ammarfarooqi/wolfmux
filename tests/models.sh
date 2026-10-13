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
  printf '{"type":"result","subtype":"success","is_error":false,"result":"ok","modelUsage":{"%s":{"inputTokens":2,"contextWindow":1000000}}}\n' "$id"
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
Y_FILE="$(ls -d "$WOLFMUX_DATA"/state/*/agents/y.json)"
jq 'del(.model_id, .model_source) | .label = "Opus 5"' "$Y_FILE" >"$Y_FILE.new" && /bin/mv "$Y_FILE.new" "$Y_FILE"
check "an old record is unknown, never assumed current: status says Opus ?, doctor and the status bar say unknown" \
  '[ "$(field y label)" = "Opus ?" ] && [ -z "$(field y model_id)" ] &&
   doctor | grep -q "y (opus): which model it runs is unknown (started before this release, nothing in its transcript yet). teamctl restart y --continue records it" &&
   teamctl _model-badge "$ROOT_REAL" default | grep -q "1 unknown"'
Y_SESSION="$(field y session_id)"
Y_DIR="$WOLFMUX_CLAUDE_PROJECTS/$(cd "$(field y workdir)" && pwd -P | sed 's|[^A-Za-z0-9]|-|g')"
/bin/mkdir -p "$Y_DIR"
printf '%s\n' '{"type":"user","message":{"content":"hi"}}' '{"type":"assistant","message":{"model":"claude-opus-5","content":[]}}' >"$Y_DIR/$Y_SESSION.jsonl"
check "what its transcript shows was served is used when the record has nothing: y runs claude-opus-5, and is behind" \
  'doctor | grep -q "y runs claude-opus-5 (from its transcript); claude-opus-6 is newer. Nothing restarts by itself: teamctl restart y --continue" &&
   teamctl models --json | jq -e "[.agents[] | select(.role == \"y\")][0] | .running_id == \"claude-opus-5\" and .known_from == \"transcript\" and .verdict == \"behind\""'

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
