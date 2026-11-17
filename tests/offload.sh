#!/bin/bash
# offload.sh: tests for lib/offload.sh: a long command output stays out of the agent's context.
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

# hook_json <command> [run_in_background]: the CLI's PreToolUse JSON for a Bash call
hook_json() {
  jq -cn --arg c "$1" --arg bg "${2:-false}" \
    '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: ({command: $c, timeout: 120000, description: "d"} + (if $bg == "true" then {run_in_background: true} else {} end))}'
}

# rewritten <command>: the command the CLI would run after the hook (the original when the hook says nothing)
rewritten() {
  local out
  out="$(hook_json "$1" | "$REPO/bin/teamctl" _offload-pre)"
  if [ -n "$out" ]; then printf '%s' "$out" | jq -j '.hookSpecificOutput.updatedInput.command'; else printf '%s' "$1"; fi
}

# run_as_cli <dir> <command>: runs it as Claude Code does; leaves out, rc, cwd, env in <dir>
# CLI_SH picks the shell: /bin/bash (a worker's) or /bin/zsh (the user's shell on a Mac, so a
# lead's), started as the CLI starts it: zsh with the setopts the CLI puts in front of the eval.
CLI_SH=/bin/bash
run_as_cli() {
  local dir="$1"
  mkdir -p "$dir"
  case "$CLI_SH" in
    *zsh) (cd "$WORK" && /bin/zsh -c '\builtin setopt NO_EXTENDED_GLOB NO_BARE_GLOB_QUAL NO_BRACE_CCL NO_MAGIC_EQUAL_SUBST NO_EQUALS 2>/dev/null || true && eval "$1" </dev/null; __rc=$?; pwd -P >|"$2/cwd"; printf "%s" "${FOO-unset}" >|"$2/env"; exit $__rc' _ "$2" "$dir" >"$dir/out" 2>&1) ;;
    *) (cd "$WORK" && /bin/bash -c 'eval "$1" </dev/null; __rc=$?; pwd -P >"$2/cwd"; printf "%s" "${FOO-unset}" >"$2/env"; exit $__rc' _ "$2" "$dir" >"$dir/out" 2>&1) ;;
  esac
  printf '%s' "$?" >"$dir/rc"
}

# same_file <a> <b>: equal, or both absent (the shell ended before it could write them)
same_file() { if [ -e "$1" ] || [ -e "$2" ]; then cmp -s "$1" "$2"; fi; }

n=0
# same <description> <command>: plain and wrapped agree on output, exit code, cwd and exports
same() {
  set -- "${CLI_SH##*/}: $1" "$2"
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
check "never wrapped: a command with trap in it (its trap would replace ours)" "[ -z \"\$(hook_json 'trap \"echo x\" EXIT; echo y' | $REPO/bin/teamctl _offload-pre)\" ]"
check "wrapped: a word that only contains trap (bootstrap.sh)" "[ -n \"\$(hook_json './bootstrap.sh' | $REPO/bin/teamctl _offload-pre)\" ]"
check "wrapped: a word that only contains exec (execute.sh)" "[ -n \"\$(hook_json './execute.sh' | $REPO/bin/teamctl _offload-pre)\" ]"
check "never wrapped twice" "c=\$(rewritten 'echo hi'); [ -z \"\$(hook_json \"\$c\" | $REPO/bin/teamctl _offload-pre)\" ]"
check "never wrapped: another tool" "[ -z \"\$(jq -cn '{tool_name:\"Read\",tool_input:{file_path:\"/x\"}}' | $REPO/bin/teamctl _offload-pre)\" ]"
check "WOLFMUX_OFFLOAD=off: no rewrite" "[ -z \"\$(hook_json 'echo hi' | WOLFMUX_OFFLOAD=off $REPO/bin/teamctl _offload-pre)\" ]"
check "no run directory: no rewrite" "[ -z \"\$(hook_json 'echo hi' | WOLFMUX_RUN_DIR= $REPO/bin/teamctl _offload-pre)\" ]"
check "bad JSON on stdin: no rewrite, exit 0" "out=\$(printf 'nope' | $REPO/bin/teamctl _offload-pre); [ \$? = 0 ] && [ -z \"\$out\" ]"

corpus() {
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
same "the command's own EXIT trap" 'trap "echo cleanup" EXIT; echo REAL-OUTPUT-LINE; false'
same "the command resets the EXIT trap (trap - EXIT)" 'trap - EXIT; echo after-reset; cd /tmp; export FOO=r; exit 2'
same "a glob that matches nothing" 'ls ./no-such-file-*.xyz; echo "rc=$?"'
same "an error then more output (zsh: no set -e)" 'cd /no/such/dir; echo still-here'
same "a long-ish loop with both streams" 'for i in 1 2 3; do echo "out $i"; echo "err $i" >&2; done'
same "the command's own TERM trap" 'trap "echo term" TERM; echo with-term-trap; cd /tmp; export FOO=t'
}
for CLI_SH in /bin/bash /bin/zsh; do
  echo "== equivalence corpus under $CLI_SH: plain and wrapped agree"
  /bin/rm -f "$WOLFMUX_RUN_DIR"/out/*.log
  first=$((n + 1))
  corpus
  check "${CLI_SH##*/}: short output: no path line and no log left behind" "! grep -q 'wolfmux' $WORK/w$first/out && [ -z \"\$(ls $WOLFMUX_RUN_DIR/out | grep '\\.log$')\" ]"
done
CLI_SH=/bin/bash

echo "== a syntax error: the shell quotes the user's line, not a 700-character wrapper"
syn="$(rewritten 'echo (bad')"
syn_n=$((n + 1)); n=$((n + 1))
run_as_cli "$WORK/syn" "$syn"
run_as_cli "$WORK/synp" 'echo (bad'
check "syntax error (bash): the message does not carry the wrapper's code" "! grep -q 'exec 7>&1' $WORK/syn/out && ! grep -q '__wm_fin' $WORK/syn/out"
check "syntax error (bash): the whole message is short (under 600 characters)" "[ \$(wc -c <$WORK/syn/out) -lt 600 ]"
check "syntax error (bash): the message still shows the user's command" "grep -q 'echo (bad' $WORK/syn/out"
check "syntax error (bash): same exit code as unwrapped ($(cat $WORK/synp/rc))" "[ \"\$(cat $WORK/syn/rc)\" = \"\$(cat $WORK/synp/rc)\" ]"
# The length of the line is the length of its paths plus a constant, so the check is on its shape, not on a
# number that a long checkout path would break.
only_sources() {
  case "$1" in "[ -r '"*"/offload-wrap.sh' ] && . '"*"/offload-wrap.sh' '"*"'; "*) ;; *) return 1 ;; esac
  case "$1" in *trap* | *__wm_fin*) return 1 ;; esac
}
check "the line put in front of a command only sources offload-wrap.sh: no trap and no function for a syntax error to quote" 'only_sources "$syn"'
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
CLI_SH=/bin/zsh
run_as_cli "$WORK/zl" "$(rewritten "$long_cmd")"
zlog="$(sed -n 's/^\[wolfmux\] full text: \(.*\) (search it with grep; do not cat it)$/\1/p' "$WORK/zl/out")"
CLI_SH=/bin/bash
check "zsh: the runner is zsh" "[ -n \"\$(CLI_SH=/bin/zsh; run_as_cli $WORK/zv 'echo \$ZSH_VERSION'; cat $WORK/zv/out)\" ]"
check "zsh: 5 MB log shortened, exit code 1, the middle failure and the last line shown" "[ \"\$(cat $WORK/zl/rc)\" = 1 ] && [ \$(wc -c <$WORK/zl/out) -lt 12000 ] && grep -qx '300001: not ok 17 - the middle failure' $WORK/zl/out && [ \"\$(tail -1 $WORK/zl/out)\" = 'FAIL tests/x.sh' ]"
check "zsh: the log holds the full text, byte for byte" "[ -n \"$zlog\" ] && cmp -s $WORK/pl/out \"$zlog\""
WOLFMUX_OFFLOAD_MIN=10 run_as_cli "$WORK/min" "$(rewritten 'seq 1 100')"
check "WOLFMUX_OFFLOAD_MIN changes the limit" "grep -q 'long output shortened: 100 lines' $WORK/min/out"
many='for i in $(seq 1 200); do echo "Error $i"; done; seq 1 2000'
run_as_cli "$WORK/wm" "$(rewritten "$many")"
check "matching lines are capped at $WOLFMUX_OFFLOAD_MATCHES and say so" "grep -q 'the first $WOLFMUX_OFFLOAD_MATCHES follow' $WORK/wm/out && [ \$(grep -c '^[0-9]*: Error' $WORK/wm/out) = $WOLFMUX_OFFLOAD_MATCHES ]"
check "one very long line is cut in what is shown" "run_as_cli $WORK/one \"\$(rewritten 'printf \"%090000d\\n\" 0')\"; [ \$(wc -c <$WORK/one/out) -lt 2000 ]"

echo "== one log over WOLFMUX_OFFLOAD_LOG_MAX keeps its head and tail"
WOLFMUX_OFFLOAD_LOG_MAX=1000000 run_as_cli "$WORK/cap" "$(rewritten "$long_cmd")"
caplog="$(sed -n 's/^\[wolfmux\] full text: \(.*\) (search it with grep; do not cat it)$/\1/p' "$WORK/cap/out")"
check "log cap: exit code kept (1)" "[ \"\$(cat $WORK/cap/rc)\" = 1 ]"
check "log cap: the log is cut to about the cap (under cap + 300 bytes)" "[ -f \"$caplog\" ] && [ \$(wc -c <\"$caplog\") -lt 1000300 ]"
check "log cap: the summary says how many bytes were left out" "grep -q 'over the size cap: [0-9]* bytes in the middle were left out' $WORK/cap/out"
check "log cap: the log says it too, where the cut is" "grep -q '^\[wolfmux\] \.\.\. [0-9]* bytes left out of the log here' \"$caplog\""
check "log cap: left-out bytes + what is kept (minus the marker line) = the full output" "l=\$(sed -n 's/.*over the size cap: \([0-9]*\) bytes.*/\1/p' $WORK/cap/out); m=\$(( \$(grep '^\[wolfmux\] \.\.\. [0-9]* bytes left out' \"$caplog\" | wc -c) + 1 )); [ \$((\$(wc -c <\"$caplog\") - m + l)) = \$(wc -c <$WORK/pl/out) ]"
check "log cap: the head of the log is kept" "[ \"\$(head -1 \"$caplog\")\" = 1 ]"
check "log cap: the last line is kept" "[ \"\$(tail -1 \"$caplog\")\" = 'FAIL tests/x.sh' ]"
check "log cap: the summary is still short" "[ \$(wc -c <$WORK/cap/out) -lt 12000 ]"
WOLFMUX_OFFLOAD_LOG_MAX=1000000 run_as_cli "$WORK/cap2" "$(rewritten 'seq 1 100000')"
check "log cap: a log under the cap is untouched, no mention of it" "! grep -q 'size cap' $WORK/cap2/out"
echo "== fail open"
cnt="$WORK/count"
once='echo x >>'"$cnt"'; echo ran'
: >"$cnt"
mkdir -p "$WORK/fl1"; cp "$WOLFMUX_HOME/lib/offload-wrap.sh" "$WORK/fl1/"
run_as_cli "$WORK/f1" "$(offload_wrap_command "$once" "$WOLFMUX_RUN_DIR/out/f1.log" "$WORK/fl1/offload-show.sh")"
check "helper missing: the command ran once and its output is shown" "[ \$(wc -l <$cnt) = 1 ] && grep -qx ran $WORK/f1/out"
: >"$cnt"
mkdir -p "$WORK/fl2" "$WORK/fl3"
cp "$WOLFMUX_HOME/lib/offload-wrap.sh" "$WORK/fl2/"; cp "$WOLFMUX_HOME/lib/offload-wrap.sh" "$WORK/fl3/"
printf '#!/bin/bash\nexit 1\n' >"$WORK/fl2/offload-show.sh"
run_as_cli "$WORK/f2" "$(offload_wrap_command "$once" "$WOLFMUX_RUN_DIR/out/f2.log" "$WORK/fl2/offload-show.sh")"
check "helper fails: the command ran once and its output is shown" "[ \$(wc -l <$cnt) = 1 ] && grep -qx ran $WORK/f2/out"
: >"$cnt"
printf '#!/bin/bash\nkill -9 $$\n' >"$WORK/fl3/offload-show.sh"
run_as_cli "$WORK/f3" "$(offload_wrap_command "$once" "$WOLFMUX_RUN_DIR/out/f3.log" "$WORK/fl3/offload-show.sh")"
check "helper killed: the command ran once and its output is shown" "[ \$(wc -l <$cnt) = 1 ] && grep -qx ran $WORK/f3/out"
: >"$cnt"
run_as_cli "$WORK/f4" "$(offload_wrap_command "$once; exit 4" "/nonexistent-dir/f4.log" "$WOLFMUX_HOME/lib/offload-show.sh")"
check "log not writable: the command ran once, its output and exit code are kept" "[ \$(wc -l <$cnt) = 1 ] && grep -qx ran $WORK/f4/out && [ \"\$(cat $WORK/f4/rc)\" = 4 ]"

for sh in /bin/bash /bin/zsh; do
echo "== a command the CLI ends at its timeout ($sh)"
/bin/rm -f "$WOLFMUX_RUN_DIR"/out/*.log
killcmd="$(rewritten 'seq 1 20000; echo started; sleep 30; echo never')"
"$sh" -c 'eval "$1" </dev/null' _ "$killcmd" >"$WORK/kill.out" 2>&1 &
kpid=$!
i=0
while [ "$i" -lt 50 ] && ! grep -q started "$(ls -t "$WOLFMUX_RUN_DIR"/out/*.log 2>/dev/null | head -1)" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
# as a timeout does: the shell and what it runs, all at once
kill -TERM "$kpid" 2>/dev/null
pkill -TERM -P "$kpid" 2>/dev/null
wait "$kpid"
krc=$?
check "${sh##*/}: TERM: the summary of what was logged so far is printed, with the path" "grep -q 'long output shortened: 2000[0-9] lines' $WORK/kill.out && grep -q 'search it with grep' $WORK/kill.out && grep -qx started $WORK/kill.out"
check "${sh##*/}: TERM: exit code 143" "[ $krc = 143 ]"
check "${sh##*/}: TERM: what came after is not there" "! grep -q never $WORK/kill.out"
done

echo "== two Bash calls at the same time (the CLI runs independent calls in parallel)"
# log_of <rewritten command>: the log path the prefix writes to
log_of() { printf '%s' "$1" | sed -n "s/.*offload-wrap.sh' '\([^']*\)'; .*/\1/p"; }
: >"$WORK/par.paths"
for round in 1 2 3 4 5; do
  for i in 1 2 3 4 5 6 7 8; do
    (hook_json "echo r$round-$i" | "$REPO/bin/teamctl" _offload-pre >"$WORK/par.$round.$i") &
  done
  wait
  for i in 1 2 3 4 5 6 7 8; do log_of "$(jq -j '.hookSpecificOutput.updatedInput.command' "$WORK/par.$round.$i")" >>"$WORK/par.paths"; echo >>"$WORK/par.paths"; done
done
check "5 rounds of 8 hooks started together: 40 distinct log paths" "[ \"\$(grep -c . $WORK/par.paths)\" = 40 ] && [ \"\$(sort -u $WORK/par.paths | grep -c .)\" = 40 ]"
# the race made certain: the second hook reads the counter before the first one wrote it back
next_before="$(cat "$WOLFMUX_RUN_DIR/out/next")"
cmd_a="$(rewritten 'seq 1 3000 | sed s/^/A/; echo A-end; exit 3')"
printf '%s\n' "$next_before" >"$WOLFMUX_RUN_DIR/out/next"
cmd_b="$(rewritten 'echo B-only; exit 4')"
check "two hooks that read the same counter still get different logs" "[ -n \"\$(log_of \"\$cmd_a\")\" ] && [ \"\$(log_of \"\$cmd_a\")\" != \"\$(log_of \"\$cmd_b\")\" ]"
run_as_cli "$WORK/para" "$cmd_a" &
run_as_cli "$WORK/parb" "$cmd_b" &
wait
check "two wrapped commands at the same moment: each shows only its own output" "grep -q 'long output shortened: 3001 lines' $WORK/para/out && [ \"\$(tail -1 $WORK/para/out)\" = A-end ] && ! grep -q B-only $WORK/para/out && [ \"\$(cat $WORK/parb/out)\" = B-only ]"
check "two wrapped commands at the same moment: each its own exit code (3 and 4)" "[ \"\$(cat $WORK/para/rc)\" = 3 ] && [ \"\$(cat $WORK/parb/rc)\" = 4 ]"

echo "== pruning"
mkdir -p "$WORK/prune/out"
for i in $(seq 1 115); do : >"$WORK/prune/out/$i.log"; done
for i in $(seq 116 230); do : >"$WORK/prune/out/$i-4242.log"; done
offload_prune "$WORK/prune/out"
check "old logs are pruned to the newest $WOLFMUX_OFFLOAD_KEEP (<n>.log and <n>-<pid>.log alike)" "[ \$(ls $WORK/prune/out | grep -c '\\.log$') = $WOLFMUX_OFFLOAD_KEEP ] && [ -e $WORK/prune/out/230-4242.log ]"
printf '219\n' >"$WORK/prune/out/next"
for i in $(seq 1 30); do : >"$WORK/prune/out/x$i.log"; done
offload_next_log "$WORK/prune" >/dev/null
check "every 20th log prunes on its own" "[ \$(ls $WORK/prune/out | grep -cE '^[0-9]+(-[0-9]+)?\\.log$') -le $WOLFMUX_OFFLOAD_KEEP ] && [ \"\$(cat $WORK/prune/out/next)\" = 220 ]"

echo "== the agent's settings (write_agent_settings)"
cat >"$WORK/settings.sh" <<'HARNESS'
# settings_for <kind> <isolation> <offload-policy>: prints write_agent_settings' JSON, modules loaded as teamctl does
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

echo "== teamctl run -- (Codex family)"
"$REPO/bin/teamctl" run -- sh -c 'echo a; echo b >&2; echo c; exit 5' >"$WORK/r1.out" 2>"$WORK/r1.err"
r1=$?
check "run: the command's exit code (5)" "[ $r1 = 5 ]"
check "run: short output whole, stderr in the order written, no path line" "[ \"\$(cat $WORK/r1.out)\" = \"\$(printf 'a\nb\nc')\" ]"
check "run: stdin reaches the command" "[ \"\$(printf 'in\n' | $REPO/bin/teamctl run -- bash -c 'read l; echo \"[\$l]\"')\" = '[in]' ]"
"$REPO/bin/teamctl" run -- sh -c 'seq 1 3000; echo "panic: middle"; seq 3001 6000; echo "FAIL end" >&2; exit 1' >"$WORK/r2.out"
r2=$?
check "run: long output shortened, exit code kept (1)" "[ $r2 = 1 ] && grep -q '^\[wolfmux\] long output shortened: 6002 lines' $WORK/r2.out"
check "run: the middle failure and the last line are shown" "grep -qx '3001: panic: middle' $WORK/r2.out && [ \"\$(tail -1 $WORK/r2.out)\" = 'FAIL end' ]"
check "run: WOLFMUX_OFFLOAD=off runs it plainly" "[ \"\$(WOLFMUX_OFFLOAD=off $REPO/bin/teamctl run -- seq 1 5000 | wc -l | tr -d ' ')\" = 5000 ]"
check "run: without a command, a usage error" "! $REPO/bin/teamctl run -- 2>/dev/null"

echo "== the safety net: PostToolUse on a result the rewrite did not cover"
post() { WOLFMUX_OFFLOAD_SAFETY=on "$REPO/bin/teamctl" _hook PostToolUse; }
post_json() { jq -cn --arg c "$1" --arg out "$2" --arg p "${3:-}" '{hook_event_name: "PostToolUse", tool_name: "Bash", tool_input: {command: $c},
  tool_response: ({stdout: $out, stderr: "", interrupted: false, isImage: false, noOutputExpected: false} + (if $p != "" then {persistedOutputPath: $p, persistedOutputSize: 1} else {} end))}'; }
seq 1 3000 >"$WORK/big.txt"
check "short result: no answer" "[ -z \"\$(post_json 'echo hi' hi | post)\" ]"
check "long result: replaced by the Bash result OBJECT with the shortened form" "post_json 'cat x' \"\$(cat $WORK/big.txt)\" | post | jq -e '.hookSpecificOutput.updatedToolOutput | (.stdout | startswith(\"[wolfmux] long output shortened: 3000 lines\")) and .stderr == \"\" and .interrupted == false'"
check "above 30k the CLI's persisted file is the full text" "seq 1 60000 >$WORK/persisted.txt; post_json 'seq' \"\$(head -c 30000 $WORK/persisted.txt)\" $WORK/persisted.txt | post | jq -e '(.hookSpecificOutput.updatedToolOutput | has(\"persistedOutputPath\") | not) and (.hookSpecificOutput.updatedToolOutput.stdout | contains(\"60000 lines\"))'"
check "a command that only names offload-wrap.sh (grep -c . <path>) IS wrapped by PreToolUse" "[ -n \"\$(hook_json \"grep -c . $WOLFMUX_HOME/lib/offload-wrap.sh\" | $REPO/bin/teamctl _offload-pre)\" ]"
check "a long result of a command that only names offload-wrap.sh IS shortened by PostToolUse" "post_json \"grep -c . $WOLFMUX_HOME/lib/offload-wrap.sh\" \"\$(cat $WORK/big.txt)\" | post | jq -e '.hookSpecificOutput.updatedToolOutput.stdout | startswith(\"[wolfmux] long output shortened\")'"
check "a wrapped command's result is not shortened twice" "[ -z \"\$(post_json \"\$(rewritten 'cat x')\" \"\$(cat $WORK/big.txt)\" | post)\" ]"
check "safety net off (not in the settings): no answer, nothing read" "[ -z \"\$(post_json 'cat x' \"\$(cat $WORK/big.txt)\" | $REPO/bin/teamctl _hook PostToolUse)\" ]"

echo "== the safety net never stands in the way of mail, and costs nothing for another tool"
# A stand-in jq first on the PATH writes down every start; a stand-in WOLFMUX_HOME whose
# lib/offload.sh writes down every load (and then loads the real one).
mkdir -p "$WORK/fakebin" "$WORK/home/lib"
printf '#!/bin/bash\necho jq >>%s/jq.starts\nexec %s "$@"\n' "$WORK" "$(command -v jq)" >"$WORK/fakebin/jq"
chmod +x "$WORK/fakebin/jq"
printf 'echo loaded >>%s/loads\n. %s/lib/offload.sh\n' "$WORK" "$WOLFMUX_HOME" >"$WORK/home/lib/offload.sh"
big20k="$(head -c 20000 "$WORK/big.txt")"
read_json="$(jq -cn --arg c "$big20k" '{session_id: "s", cwd: "/w", hook_event_name: "PostToolUse", tool_name: "Read", tool_input: {file_path: "/w/big.txt"},
  tool_response: {type: "text", file: {filePath: "/w/big.txt", content: $c}}}')"
bash_json="$(post_json 'cat big.txt' "$big20k")"
# hot <json> [attention]: one PostToolUse through the hot path as the CLI calls it, counters reset
hot() {
  /bin/rm -f "$WORK/jq.starts" "$WORK/loads" "$WOLFMUX_RUN_DIR/attention"
  printf '1\n' >"$WOLFMUX_RUN_DIR/calls"
  if [ -n "${2:-}" ]; then : >"$WOLFMUX_RUN_DIR/attention"; fi
  printf '%s' "$1" | env PATH="$WORK/fakebin:$PATH" JQ_BIN= WOLFMUX_HOME="$WORK/home" WOLFMUX_OFFLOAD_SAFETY=on "$REPO/bin/teamctl" _hook PostToolUse 2>/dev/null
}
out="$(hot "$bash_json")"
check "control: a 20 KB Bash result loads the module, starts jq and is shortened" "[ -s $WORK/loads ] && [ -s $WORK/jq.starts ] && printf '%s' \"\$out\" | jq -e '.hookSpecificOutput.updatedToolOutput.stdout | startswith(\"[wolfmux] long output shortened\")'"
out="$(hot "$read_json")"
check "a 20 KB Read result with nothing queued: no jq started, no module loaded, no answer" "[ ! -e $WORK/loads ] && [ ! -e $WORK/jq.starts ] && [ -z \"\$out\" ]"
out="$(printf '%s' "$bash_json" | (: >"$WOLFMUX_RUN_DIR/attention"; printf '1\n' >"$WOLFMUX_RUN_DIR/calls"; WOLFMUX_OFFLOAD_SAFETY=on "$REPO/bin/teamctl" _hook PostToolUse 2>/dev/null))"
check "mail queued (attention): a 20 KB Bash result goes to the full hook, the safety net stays out" "! printf '%s' \"\$out\" | grep -q updatedToolOutput"
out="$(printf '%s' "$bash_json" | (/bin/rm -f "$WOLFMUX_RUN_DIR/attention"; printf '9\n' >"$WOLFMUX_RUN_DIR/calls"; WOLFMUX_OFFLOAD_SAFETY=on "$REPO/bin/teamctl" _hook PostToolUse 2>/dev/null))"
check "the tenth call: the full hook looks, the safety net stays out" "! printf '%s' \"\$out\" | grep -q updatedToolOutput"
far_json="$(printf '%s' "$bash_json" | jq -c --arg cwd "/$(printf '%05000d' 0)" '{cwd: $cwd} + .')"
out="$(hot "$far_json")"
check "the tool's name beyond what was read (a 5,000-character cwd first): jq decides, still shortened" "printf '%s' \"\$out\" | jq -e '.hookSpecificOutput.updatedToolOutput.stdout | startswith(\"[wolfmux] long output shortened\")'"
/bin/rm -f "$WOLFMUX_RUN_DIR/attention"

echo "== cost (measured, not checked against a bound)"
ms() { # <n> <command string>: mean milliseconds of one run
  local t0 t1 i
  t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
  for i in $(seq 1 "$1"); do eval "$2" >/dev/null 2>&1; done
  t1=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
  echo $(((t1 - t0) / $1))
}
pre_in="$(hook_json 'npm test')"
short_in="$(post_json 'echo hi' hi)"
long_in="$(post_json 'cat x' "$(cat "$WORK/big.txt")")"
printf '  PreToolUse _offload-pre per Bash call: %s ms (off: %s ms)\n' "$(ms 20 'printf %s "$pre_in" | $REPO/bin/teamctl _offload-pre')" "$(ms 20 'printf %s "$pre_in" | WOLFMUX_OFFLOAD=off $REPO/bin/teamctl _offload-pre')"
printf '  jq alone, the same rewrite: %s ms\n' "$(ms 20 'printf %s "$pre_in" | jq -c .tool_input')"
printf '  PostToolUse hot path, short result: %s ms with the safety net, %s ms without\n' "$(ms 20 'printf %s "$short_in" | post')" "$(ms 20 'printf %s "$short_in" | $REPO/bin/teamctl _hook PostToolUse')"
printf '  PostToolUse, long result (14 KB) shortened: %s ms\n' "$(ms 10 'printf %s "$long_in" | post')"
printf '  PostToolUse hot path, 20 KB Read result: %s ms with the safety net, %s ms without\n' "$(ms 20 'printf %s "$read_json" | post')" "$(ms 20 'printf %s "$read_json" | $REPO/bin/teamctl _hook PostToolUse')"

echo
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
