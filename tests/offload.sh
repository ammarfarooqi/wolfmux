#!/bin/bash
# offload.sh — tests for lib/offload.sh: a long command output stays out of the agent's context.
# No tmux, no CLI: every command runs under real /bin/bash the way Claude Code runs it (eval of
# the command text, stdin from /dev/null, then pwd), once plain and once as the PreToolUse hook
# rewrites it, and the two are compared.
#
#   tests/offload.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-offload.XXXXXX")"
trap '/bin/rm -rf "$WORK"' EXIT
export WOLFMUX_HOME="$REPO/config/wolfmux"
export WOLFMUX_RUN_DIR="$WORK/run"
mkdir -p "$WOLFMUX_RUN_DIR"
unset TEAM_ROLE BEADS_ACTOR WOLFMUX_OFFLOAD WOLFMUX_OFFLOAD_MIN FOO
. "$WOLFMUX_HOME/lib/offload.sh"

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

# hook_json <command> [run_in_background] — the CLI's PreToolUse JSON for a Bash call
hook_json() {
  jq -cn --arg c "$1" --arg bg "${2:-false}" \
    '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: ({command: $c, timeout: 120000, description: "d"} + (if $bg == "true" then {run_in_background: true} else {} end))}'
}

# rewritten <command> — the command the CLI would run after the hook (the original when the hook says nothing)
rewritten() {
  local out
  out="$(hook_json "$1" | "$REPO/bin/teamctl" _offload-pre)"
  if [ -n "$out" ]; then printf '%s' "$out" | jq -j '.hookSpecificOutput.updatedInput.command'; else printf '%s' "$1"; fi
}

# run_as_cli <dir> <command> — runs it as Claude Code does; leaves out, rc, cwd, env in <dir>
run_as_cli() {
  local dir="$1"
  mkdir -p "$dir"
  (cd "$WORK" && /bin/bash -c 'eval "$1" </dev/null; __rc=$?; pwd -P >"$2/cwd"; printf "%s" "${FOO-unset}" >"$2/env"; exit $__rc' _ "$2" "$dir" >"$dir/out" 2>&1)
  printf '%s' "$?" >"$dir/rc"
}

# same_file <a> <b> — equal, or both absent (the shell ended before it could write them)
same_file() { if [ -e "$1" ] || [ -e "$2" ]; then cmp -s "$1" "$2"; fi; }

n=0
# same <description> <command> — plain and wrapped agree on output, exit code, cwd and exports
same() {
  n=$((n + 1))
  run_as_cli "$WORK/p$n" "$2"
  run_as_cli "$WORK/w$n" "$(rewritten "$2")"
  check "$1: same exit code ($(cat "$WORK/p$n/rc"))" "[ \"\$(cat $WORK/p$n/rc)\" = \"\$(cat $WORK/w$n/rc)\" ]"
  check "$1: same output" "cmp -s $WORK/p$n/out $WORK/w$n/out"
  check "$1: same cwd and exports afterwards" "same_file $WORK/p$n/cwd $WORK/w$n/cwd && same_file $WORK/p$n/env $WORK/w$n/env"
}

echo "== the rewrite"
check "a Bash call is rewritten, its other fields kept" "hook_json 'echo hi' | $REPO/bin/teamctl _offload-pre | jq -e '.hookSpecificOutput.updatedInput | (.timeout == 120000) and (.description == \"d\") and (.command | endswith(\"echo hi\"))'"
check "the rewrite asks no permission (no permissionDecision)" "hook_json 'echo hi' | $REPO/bin/teamctl _offload-pre | jq -e '.hookSpecificOutput.permissionDecision == null'"
check "the rewrite is one prefix on the command's first line" "[ \"\$(rewritten 'echo hi' | wc -l | tr -d ' ')\" = 0 ]"
check "never wrapped: run_in_background" "[ -z \"\$(hook_json 'sleep 1' true | $REPO/bin/teamctl _offload-pre)\" ]"
check "never wrapped: a command with exec in it" "[ -z \"\$(hook_json 'exec echo hi' | $REPO/bin/teamctl _offload-pre)\" ]"
check "wrapped: a word that only contains exec (execute.sh)" "[ -n \"\$(hook_json './execute.sh' | $REPO/bin/teamctl _offload-pre)\" ]"
check "never wrapped twice" "c=\$(rewritten 'echo hi'); [ -z \"\$(hook_json \"\$c\" | $REPO/bin/teamctl _offload-pre)\" ]"
check "never wrapped: another tool" "[ -z \"\$(jq -cn '{tool_name:\"Read\",tool_input:{file_path:\"/x\"}}' | $REPO/bin/teamctl _offload-pre)\" ]"
check "WOLFMUX_OFFLOAD=off: no rewrite" "[ -z \"\$(hook_json 'echo hi' | WOLFMUX_OFFLOAD=off $REPO/bin/teamctl _offload-pre)\" ]"
check "no run directory: no rewrite" "[ -z \"\$(hook_json 'echo hi' | WOLFMUX_RUN_DIR= $REPO/bin/teamctl _offload-pre)\" ]"
check "bad JSON on stdin: no rewrite, exit 0" "out=\$(printf 'nope' | $REPO/bin/teamctl _offload-pre); [ \$? = 0 ] && [ -z \"\$out\" ]"

echo "== equivalence corpus: plain and wrapped agree"
same "heredoc" 'cat <<EOF
hello $((1 + 2))
EOF'
same "cd and export persist" 'cd /tmp && export FOO=bar; echo moved'
same "exit 3 in the middle" 'echo a; echo b >&2; exit 3; echo never'
same "pipeline whose last stage fails" 'echo x | grep -q y'
same "pipefail pipeline" 'set -o pipefail; false | cat; echo "rc=$?"'
same "set -e in the command" 'set -e; echo before; false; echo never'
same "background job with & and wait" '(sleep 0.2; echo bg) & echo fg; wait; echo done'
same "exec (left alone)" 'exec echo replaced'
same "trailing comment" 'echo hi # a comment'
same "trailing backslash" 'echo a \'
same "unterminated quote: bash's own message" 'echo "abc'
same "a command that reads stdin" 'read x; echo "got[$x] rc=$?"'
same "output with no final newline" 'printf abc'
same "binary-looking output" 'printf "\000\001\377\n"'
same "stderr and stdout interleaved, in the order written" 'echo 1; echo 2 >&2; echo 3; echo 4 >&2'
same "a multi-line command keeps its line numbers in errors" 'echo one
nosuchcommand-xyz
echo three'
same "a command that defines a function and calls it" 'f() { echo "in f $1"; }; f x'
same "a command starting with a comment line" '# comment
echo after'
same "an empty output" 'true'
check "short output: no path line and no log left behind" "! grep -q 'wolfmux' $WORK/w1/out && [ -z \"\$(ls $WOLFMUX_RUN_DIR/out | grep '\\.log$')\" ]"

echo "== a long output"
long_cmd='seq 1 300000; echo "not ok 17 - the middle failure"; seq 300001 750000; echo "FAIL tests/x.sh" >&2; exit 1'
run_as_cli "$WORK/pl" "$long_cmd"
run_as_cli "$WORK/wl" "$(rewritten "$long_cmd")"
log="$(sed -n 's/^\[wolfmux\] full text: \(.*\) (search it with grep; do not cat it)$/\1/p' "$WORK/wl/out")"
check "5 MB log: the plain output is about 5 MB" "[ \$(wc -c <$WORK/pl/out) -gt 5000000 ]"
check "5 MB log: exit code kept (1)" "[ \"\$(cat $WORK/wl/rc)\" = 1 ]"
check "5 MB log: the model sees a short form (< 12,000 characters)" "[ \$(wc -c <$WORK/wl/out) -lt 12000 ]"
check "5 MB log: line and character counts" "grep -q '^\[wolfmux\] long output shortened: 750002 lines, [0-9]* characters, exit code 1\.' $WORK/wl/out"
check "5 MB log: the path, with 'search it with grep; do not cat it'" "[ -n \"$log\" ] && [ -f \"$log\" ]"
check "5 MB log: the log holds the full text, byte for byte" "cmp -s $WORK/pl/out \"$log\""
check "5 MB log: the failing line in the cut middle is shown, with its line number" "grep -qx '300001: not ok 17 - the middle failure' $WORK/wl/out"
check "5 MB log: the first 40 lines" "[ \"\$(sed -n '3p' $WORK/wl/out)\" = 1 ] && grep -qx 40 $WORK/wl/out"
check "5 MB log: the last 40 lines, ending with the FAIL line" "[ \"\$(tail -1 $WORK/wl/out)\" = 'FAIL tests/x.sh' ] && grep -qx 750000 $WORK/wl/out"
check "5 MB log: under the limit is not cut, just over it is" "s=\$(printf '%04000d' 0); run_as_cli $WORK/edge \"\$(rewritten \"printf %s \$s\")\"; [ \"\$(cat $WORK/edge/out)\" = \"\$s\" ] && run_as_cli $WORK/edge2 \"\$(rewritten \"printf %s \${s}1\")\" && grep -q 'long output shortened' $WORK/edge2/out"
WOLFMUX_OFFLOAD_MIN=10 run_as_cli "$WORK/min" "$(rewritten 'seq 1 100')"
check "WOLFMUX_OFFLOAD_MIN changes the limit" "grep -q 'long output shortened: 100 lines' $WORK/min/out"
many='for i in $(seq 1 200); do echo "Error $i"; done; seq 1 2000'
run_as_cli "$WORK/wm" "$(rewritten "$many")"
check "matching lines are capped at $WOLFMUX_OFFLOAD_MATCHES and say so" "grep -q 'the first $WOLFMUX_OFFLOAD_MATCHES follow' $WORK/wm/out && [ \$(grep -c '^[0-9]*: Error' $WORK/wm/out) = $WOLFMUX_OFFLOAD_MATCHES ]"
check "one very long line is cut in what is shown" "run_as_cli $WORK/one \"\$(rewritten 'printf \"%090000d\\n\" 0')\"; [ \$(wc -c <$WORK/one/out) -lt 2000 ]"

echo "== fail open"
cnt="$WORK/count"
once='echo x >>'"$cnt"'; echo ran'
: >"$cnt"
run_as_cli "$WORK/f1" "$(offload_wrap_command "$once" "$WOLFMUX_RUN_DIR/out/f1.log" "$WORK/missing-show.sh")"
check "helper missing: the command ran once and its output is shown" "[ \$(wc -l <$cnt) = 1 ] && grep -qx ran $WORK/f1/out"
: >"$cnt"
printf '#!/bin/bash\nexit 1\n' >"$WORK/broken-show.sh"
run_as_cli "$WORK/f2" "$(offload_wrap_command "$once" "$WOLFMUX_RUN_DIR/out/f2.log" "$WORK/broken-show.sh")"
check "helper fails: the command ran once and its output is shown" "[ \$(wc -l <$cnt) = 1 ] && grep -qx ran $WORK/f2/out"
: >"$cnt"
printf '#!/bin/bash\nkill -9 $$\n' >"$WORK/killed-show.sh"
run_as_cli "$WORK/f3" "$(offload_wrap_command "$once" "$WOLFMUX_RUN_DIR/out/f3.log" "$WORK/killed-show.sh")"
check "helper killed: the command ran once and its output is shown" "[ \$(wc -l <$cnt) = 1 ] && grep -qx ran $WORK/f3/out"
: >"$cnt"
run_as_cli "$WORK/f4" "$(offload_wrap_command "$once; exit 4" "/nonexistent-dir/f4.log" "$WOLFMUX_HOME/lib/offload-show.sh")"
check "log not writable: the command ran once, its output and exit code are kept" "[ \$(wc -l <$cnt) = 1 ] && grep -qx ran $WORK/f4/out && [ \"\$(cat $WORK/f4/rc)\" = 4 ]"

echo "== a command the CLI ends at its timeout"
killcmd="$(rewritten 'seq 1 20000; echo started; sleep 30; echo never')"
/bin/bash -c 'eval "$1" </dev/null' _ "$killcmd" >"$WORK/kill.out" 2>&1 &
kpid=$!
i=0
while [ "$i" -lt 50 ] && ! grep -q started "$(ls -t "$WOLFMUX_RUN_DIR"/out/*.log 2>/dev/null | head -1)" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
# as a timeout does: the shell and what it runs, all at once
kill -TERM "$kpid" 2>/dev/null
pkill -TERM -P "$kpid" 2>/dev/null
wait "$kpid"
krc=$?
check "TERM: the summary of what was logged so far is printed, with the path" "grep -q 'long output shortened: 2000[0-9] lines' $WORK/kill.out && grep -q 'search it with grep' $WORK/kill.out && grep -qx started $WORK/kill.out"
check "TERM: exit code 143" "[ $krc = 143 ]"
check "TERM: what came after is not there" "! grep -q never $WORK/kill.out"

echo "== pruning"
mkdir -p "$WORK/prune/out"
for i in $(seq 1 230); do : >"$WORK/prune/out/$i.log"; done
offload_prune "$WORK/prune/out"
check "old logs are pruned to the newest $WOLFMUX_OFFLOAD_KEEP" "[ \$(ls $WORK/prune/out | grep -c '\\.log$') = $WOLFMUX_OFFLOAD_KEEP ]"
printf '219\n' >"$WORK/prune/out/next"
for i in $(seq 1 30); do : >"$WORK/prune/out/x$i.log"; done
offload_next_log "$WORK/prune" >/dev/null
check "every 20th log prunes on its own" "[ \$(ls $WORK/prune/out | grep -c '^[0-9]*\\.log$') -le $WOLFMUX_OFFLOAD_KEEP ] && [ \"\$(cat $WORK/prune/out/next)\" = 220 ]"

echo "== the agent's settings (write_agent_settings)"
cat >"$WORK/settings.sh" <<'HARNESS'
# settings_for <kind> <isolation> <offload-policy> — prints write_agent_settings' JSON, modules loaded as teamctl does
set +eu
REPO="$1"; T_KIND="$2"; T_ISO="$3"; T_OFF="$4"
export WOLFMUX_HOME="$REPO/config/wolfmux"
for module in provider-env common registry tmuxctl worktree disk reclaim finish beads policy approvals agents views dashboard restore doctor brand notify inbox layout guard memory completion hooks store mail recall tasks offload; do . "$WOLFMUX_HOME/lib/$module.sh"; done
JQ_BIN="$(command -v jq)"; TEAMCTL_SELF=/x/teamctl; STATE_DIR="$(mktemp -d)"
reg_field() { case "$2" in kind) echo "$T_KIND" ;; model) echo sonnet ;; permissions) echo skip ;; *) echo "" ;; esac; }
policy_get() { case "$1" in worker-isolation) echo "$T_ISO" ;; output-offload) echo "$T_OFF" ;; worker-context) echo full ;; *) policy_default "$1" ;; esac; }
worker_compact_window() { :; }; notify_wanted() { return 1; }
cat "$(write_agent_settings w1)"
HARNESS
settings() { bash "$WORK/settings.sh" "$REPO" "$@" 2>/dev/null; }
check "worker: the guard AND the offload hook, each its own PreToolUse entry" "settings worker on on | jq -e '[.hooks.PreToolUse[] | .matcher + \" \" + .hooks[0].command] == [\".* \\\"/x/teamctl\\\" _guard\", \"Bash \\\"/x/teamctl\\\" _offload-pre\"]'"
check "lead (no guard): the offload hook alone" "settings lead off on | jq -e '[.hooks.PreToolUse[].matcher] == [\"Bash\"]'"
check "the backstop: bashOutputMaxChars and BASH_MAX_OUTPUT_LENGTH above the offload limit" "settings worker on on | jq -e '.bashOutputMaxChars == 16000 and .env.BASH_MAX_OUTPUT_LENGTH == \"16000\" and .bashOutputMaxChars > $WOLFMUX_OFFLOAD_MIN'"
check "policy output-offload off: not one entry of it, the guard kept" "settings worker on off | jq -e '([.hooks.PreToolUse[].matcher] == [\".*\"]) and .bashOutputMaxChars == null and .env.BASH_MAX_OUTPUT_LENGTH == null'"
check "WOLFMUX_OFFLOAD=off: not one entry of it" "WOLFMUX_OFFLOAD=off settings lead off on | jq -e '.hooks.PreToolUse == null and .bashOutputMaxChars == null'"
check "policy: output-offload is a key, on by default, on|off" "bash -c '. $WOLFMUX_HOME/lib/common.sh 2>/dev/null; . $WOLFMUX_HOME/lib/policy.sh; [ \"\$(policy_default output-offload)\" = on ] && policy_valid output-offload off && ! policy_valid output-offload maybe'"

echo
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
