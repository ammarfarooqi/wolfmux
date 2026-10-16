#!/bin/bash
# human-inbox-keys.sh — the messages popup (prefix N) reads keys, not a terminal's chatter.
#
# The bug this guards (v1.20.1): on Ammar's iTerm2 the popup closed the moment it opened
# ("no it doesnt open just flickers"). The cause: tmux 3.7c does not expand formats in
# display-popup's shell-command, so the binding ran `"#{?@wolfmux_teamctl,…}"` as a
# program, `command not found`, and -E closed the popup at once. The bindings now go
# through run-shell and `teamctl _popup`. Under it, a second weakness: the popup read its
# input one byte at a time, so a byte of a terminal's report or reply (iTerm2 gets focus
# reports and extended keys) could be taken for q, Esc, r or a, and an end of input
# closed it without a word.
#
# What has to hold, and each of these is a check below:
#   · prefix N and prefix O on a real tmux server with this repository's tmux.conf open
#     their popups and keep them open (no display-popup with a format in its command)
#   · the parser cuts input into whole sequences: focus in/out, key releases, CSI-u and
#     modifyOtherKeys keys, a DA reply, an OSC reply ending in ESC \, a DCS reply, arrows in
#     both forms, a lone Esc
#   · only q / Esc (plain, CSI-u or modifyOtherKeys) close; none of the replies marks
#     anything read, closes, or opens; r, a and Enter count only on their own
#   · in a real terminal (a pty): bytes already waiting when the popup starts are dropped,
#     replies typed at it do nothing, a CSI-u q closes it, a lone Esc closes it
#   · input that ends says "closed: input ended" and waits; so does a teamctl that dies
#     before the list is drawn
#   · every popup writes its log, keeps it under 200 lines, and a log that cannot be
#     written changes nothing
#
# Nothing here touches Beads or a tmux server of yours: bd is a fake on PATH, the state
# directory is a throwaway one, the terminal is a pty of python3's own, and the one tmux
# server is its own (socket wolfmux-test-hikeys-<pid>), started with HOME pointed at an
# empty directory so your ~/.tmux.conf (and anything it runs) is never read.
#
#   tests/human-inbox-keys.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-hikeys.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
export WOLFMUX_HOME="$REPO/config/wolfmux"
export WOLFMUX_BIN_DIR="$REPO/bin"
export WOLFMUX_DATA="$WORK/data"
export WOLFMUX_TMUX_SOCKET="wolfmux-test-hikeys-$$"
export WOLFMUX_HI_HOLD=2
unset WOLFMUX_ROOT TEAM_ROLE BEADS_ACTOR TMUX TMUX_PANE WOLFMUX_TEAM WOLFMUX_TEAM_ARG WOLFMUX_HUMAN
tmx() { tmux -L "$WOLFMUX_TMUX_SOCKET" "$@"; }

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
  tmx kill-server >/dev/null 2>&1
  /bin/rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$WOLFMUX_TMUX_SOCKET"
  [ -n "${KEEP:-}" ] && echo "kept $WORK" || /bin/rm -rf "$WORK"
}
trap cleanup EXIT

PROJECT="$WORK/demo project" # the space is deliberate
/bin/mkdir -p "$PROJECT"
(cd "$PROJECT" && git init -q -b main && echo hi >README.md && git add -A &&
  git -c user.name=t -c user.email=t@example.invalid commit -qm init) || exit 1
KEY="$(cd "$PROJECT" && bash -c '. "$WOLFMUX_HOME/lib/provider-env.sh"; . "$WOLFMUX_HOME/lib/common.sh"; project_key "$(resolve_root)"')"
STATE="$WOLFMUX_DATA/state/$KEY"
/bin/mkdir -p "$STATE"
LOG="$STATE/human-inbox-popup.log"
US="$(printf '\037')"

FAKE_BIN="$WORK/fake-bin"
BD_LOG="$WORK/bd-calls"
/bin/mkdir -p "$FAKE_BIN"
printf '%s\n' '#!/bin/bash' 'printf "%s|%s\n" "${BEADS_ACTOR:-}" "$*" >>"$FAKE_BD_LOG"' \
  'case "$1" in list) printf "%s\n" "[{\"id\":\"m-1\",\"title\":\"One\",\"status\":\"open\",\"issue_type\":\"message\",\"assignee\":\"human\",\"created_by\":\"comms\",\"created_at\":\"2026-10-16T01:00:00Z\"},{\"id\":\"m-2\",\"title\":\"Two\",\"status\":\"open\",\"issue_type\":\"message\",\"assignee\":\"human\",\"created_by\":\"comms\",\"created_at\":\"2026-10-16T02:00:00Z\"}]" ;; show) echo "SHOW $2" ;; esac' \
  >"$FAKE_BIN/bd"
chmod +x "$FAKE_BIN/bd"
export PATH="$FAKE_BIN:$PATH" FAKE_BD_LOG="$BD_LOG"
: >"$BD_LOG"

# --- 1. the parser and what each unit does -----------------------------------------------
echo "== the key parser: input -> what the popup does with it"
# act <printf %b bytes> — parse one group and act on it, with bd and the screen stubbed;
# prints: <tokens> | <what it did> | close=<0|1> | marked=<ids or ->
cat >"$WORK/act.sh" <<'EOF'
set +eu
. "$WOLFMUX_HOME/lib/provider-env.sh"; . "$WOLFMUX_HOME/lib/common.sh"; . "$WOLFMUX_HOME/lib/inbox.sh"
MARKED="-" OPENED="-"
_hi_close() { MARKED="$*"; return 0; }
_hi_draw() { :; }
_hi_take() { return 1; } # the y/n question gets no answer: input ended
_hi_open() { OPENED="${HI_ID[HI_SEL]}"; HI_DID="opened"; }
HI_LOG="" HI_N=3 HI_SEL=1 HI_TOP=0 HI_ID=(m-1 m-2 m-3) HI_STATUS=""
hex="$(printf '%b' "$1" | od -An -v -tx1)"
_hi_parse $hex
close=0
_hi_act || close=1
printf '%s | %s | close=%s | marked=%s | opened=%s | sel=%s\n' "${HI_TOK[*]}" "$HI_DID" "$close" "$MARKED" "$OPENED" "$((HI_SEL + 1))"
EOF
act() { bash "$WORK/act.sh" "$1" 2>&1; }
# each row: <input> <expected, a grep -E pattern over act's line>
while IFS='	' read -r input expect; do
  [ -n "$input" ] || continue
  got="$(act "$input")"
  check "$(printf '%-30s -> %s' "$input" "$got")" 'printf "%s\n" "$got" | grep -Eq -- "$expect"'
done <<'EOF'
\e[I	^ignore \| ignored \| close=0 \| marked=- \| opened=- \| sel=2$
\e[O	^ignore \| ignored \| close=0 \| marked=-
\e[I\e[O	^ignore ignore \| ignored \| close=0 \| marked=-
\e[78;2u	^char:N \| ignored \| close=0 \| marked=-
\e[27;2;78~	^char:N \| ignored \| close=0 \| marked=-
\e[110;1:3u	^ignore \| ignored \| close=0 \| marked=-
\e[?62;22c	^ignore \| ignored \| close=0 \| marked=- \| opened=- \| sel=2$
\e]11;rgb:1515/1515/1515\e\\	^ignore \| ignored \| close=0 \| marked=- \| opened=-
\e]10;rgb:dcdc/dcdc/dcdc\a	^ignore \| ignored \| close=0 \| marked=-
\eP>|iTerm2 3.7.4\e\\	^ignore \| ignored \| close=0 \| marked=- \| opened=-
\e[?997;1n	^ignore \| ignored \| close=0 \| marked=-
\e[<0;10;5M	^ignore \| ignored \| close=0 \| marked=-
\e[200~	^ignore \| ignored \| close=0 \| marked=-
q	^char:q \| close \| close=1 \| marked=-
Q	^char:Q \| close \| close=1 \| marked=-
\e[113u	^char:q \| close \| close=1 \| marked=-
\e[27;1;113~	^char:q \| close \| close=1 \| marked=-
\e	^esc \| close \| close=1 \| marked=-
\e[27u	^esc \| close \| close=1 \| marked=-
\e\e	^esc esc \| close \| close=1
\r	^enter \| opened \| close=0 \| marked=- \| opened=m-2
\e[13u	^enter \| opened \| close=0 \| marked=- \| opened=m-2
r	^char:r \| marked m-2 read \| close=0 \| marked=m-2
\e[114u	^char:r \| marked m-2 read \| close=0 \| marked=m-2
\e[27;1;114~	^char:r \| marked m-2 read \| close=0 \| marked=m-2
\e[Ir	^ignore char:r \| ignored \(q, Esc, r, a and Enter count only on their own\) \| close=0 \| marked=-
jr	^char:j char:r \| select 3 \| close=0 \| marked=-
qj	^char:q char:j \| select 3 \| close=0
a	^char:a \| .* \| close=1 \| marked=-
\e[97u	^char:a \| .* \| close=1 \| marked=-
\e[A	^up \| select 1 \| close=0
\eOA	^up \| select 1 \| close=0
\e[1;2A	^up \| select 1 \| close=0
\e[B	^down \| select 3 \| close=0
\eOB	^down \| select 3 \| close=0
j	^char:j \| select 3 \| close=0
k	^char:k \| select 1 \| close=0
3	^char:3 \| select 3 \| close=0
9	^char:9 \| ignored \| close=0 \| marked=- \| opened=- \| sel=2$
\e[99;5u	^ctrl-c \| close \| close=1
\e[113;5u	^ignore \| ignored \| close=0
EOF
# A lone a asks y/n; the stub's question gets no answer (input ended), so it closes with
# HI_CLOSE=eof, never by marking. The y/n answers themselves are checked in the pty below.

# --- 2. the popup in a terminal ----------------------------------------------------------
echo "== the popup in a pty: drain, replies, CSI-u q, a lone Esc, the log"
cat >"$WORK/pty.py" <<'EOF'
# pty.py <screen file> <step>... -- <command>...  : run a command on a pty of its own
#   pre:<bytes>   written before the command has started (they wait in the tty's queue)
#   sleep:<s>  send:<bytes>  alive (prints ALIVE yes|no)  wait:<s> (prints EXIT <rc> | TIMEOUT)
import os, sys, time, select, pty, signal
args = sys.argv[1:]
cut = args.index("--")
screen, steps, cmd = args[0], args[1:cut], args[cut + 1:]
def raw(s): return s.encode().decode("unicode_escape").encode("latin-1")
pre = b"".join(raw(s[4:]) for s in steps if s.startswith("pre:"))
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
if pre:
    os.write(fd, pre)
out = open(screen, "ab")
done = None
def pump(secs):
    global done
    end = time.time() + secs
    while time.time() < end:
        if done is None:
            p, st = os.waitpid(pid, os.WNOHANG)
            if p:
                done = os.waitstatus_to_exitcode(st)
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                c = os.read(fd, 65536)
            except OSError:
                c = b""
            if c:
                out.write(c); out.flush()
            elif done is not None:
                return
        elif done is not None:
            return
for s in steps:
    kind, _, arg = s.partition(":")
    if kind == "sleep":
        pump(float(arg))
    elif kind == "send":
        os.write(fd, raw(arg)); pump(0.02)
    elif kind == "alive":
        pump(0.05)
        print("ALIVE", "no" if done is not None else "yes", flush=True)
    elif kind == "wait":
        t0 = time.time()
        pump(float(arg))
        print("EXIT %s" % done if done is not None else "TIMEOUT", flush=True)
if done is None:
    os.kill(pid, signal.SIGKILL)
EOF
popup() { (cd "$PROJECT" && python3 -I "$WORK/pty.py" "$@"); }
TEAMCTL="$REPO/bin/teamctl"

# a. bytes waiting before the popup reads are dropped: a focus report AND a q, which the
#    old popup would have closed on; then the real q closes it
: >"$LOG"
: >"$WORK/screen-a"
out="$(popup "$WORK/screen-a" 'pre:\x1b[Iq' sleep:2.5 alive send:q wait:4 -- "$TEAMCTL" _human-inbox)"
check "drain: a q already waiting when it starts does not close it" 'printf "%s\n" "$out" | grep -qx "ALIVE yes"'
check "drain: the real q afterwards closes it, exit 0" 'printf "%s\n" "$out" | grep -qx "EXIT 0"'
check "drain: the log says what was dropped, whole" 'grep -q "in 1b 5b 49 71 = focus in, q -> dropped at start" "$LOG"'
check "log: the start line carries version, TERM, tty, size and stdin-tty=yes" 'grep -Eq "\] start: v[0-9.]+ team=.* TERM=.* tty=/dev/.* size=[0-9]+x[0-9]+ stdin-tty=yes stdout-tty=yes$" "$LOG"'
check "log: the exit line says it was the key q" 'grep -Eq "\] exit: key q \(after [0-9]+s\)$" "$LOG"'
check "screen: the list was drawn (both messages)" 'grep -aq "One" "$WORK/screen-a" && grep -aq "Two" "$WORK/screen-a"'

# b. replies and reports typed at it, each its own group, do nothing; a CSI-u q closes it
: >"$LOG"
: >"$BD_LOG"
out="$(popup "$WORK/screen-b" sleep:2 'send:\x1b[I' sleep:0.3 'send:\x1b[O' sleep:0.3 'send:\x1b[?62;22c' sleep:0.3 \
  'send:\x1b]11;rgb:1515/1515/1515\x1b\\' sleep:0.3 'send:\x1bP>|iTerm2 3.7.4\x1b\\' sleep:0.3 'send:\x1b[78;2u' sleep:0.3 \
  'send:\x1b[110;1:3u' sleep:0.3 'send:\x1b[I\x72' sleep:0.5 alive 'send:\x1b[113u' wait:4 -- "$TEAMCTL" _human-inbox)"
check "replies: focus, DA, OSC, DCS, a CSI-u N, a release, r glued to a report: still open" 'printf "%s\n" "$out" | grep -qx "ALIVE yes"'
check "replies: none of them marked anything read" '! grep -q "|close" "$BD_LOG"'
check "replies: a CSI-u q (ESC[113u) closes it" 'printf "%s\n" "$out" | grep -qx "EXIT 0" && grep -q "exit: key CSI-u q" "$LOG"'
check "replies: the log names each one" 'grep -q "in 1b 5b 3f 36 32 3b 32 32 63 = terminal reply CSI ?62;22c -> ignored" "$LOG" && grep -q "= OSC string (a terminal.s reply) -> ignored" "$LOG" && grep -q "= DCS string (a terminal.s reply) -> ignored" "$LOG" && grep -q "= CSI-u key release -> ignored" "$LOG"'
check "replies: r glued to a focus report is not a mark-read" 'grep -q "in 1b 5b 49 72 = focus in, r -> ignored (q, Esc, r, a and Enter count only on their own)" "$LOG"'

# c. a lone Esc closes it, at once and without a word; an arrow does not
: >"$LOG"
: >"$WORK/screen-c"
out="$(popup "$WORK/screen-c" sleep:2 'send:\x1b[B' sleep:0.5 'send:\x1bOA' sleep:0.5 alive 'send:\x1b' wait:3 -- "$TEAMCTL" _human-inbox)"
check "Esc: arrows (CSI and SS3) move and keep it open" 'printf "%s\n" "$out" | grep -qx "ALIVE yes" && grep -q "= down -> select 2" "$LOG" && grep -q "= SS3 up -> select 1" "$LOG"'
check "Esc: a lone Esc closes it within 3 s, as a key" 'printf "%s\n" "$out" | grep -qx "EXIT 0" && grep -q "exit: key Esc" "$LOG"'
check "Esc: and says nothing about it (a deliberate close is not held)" '! grep -aq "closed:" "$WORK/screen-c"'

# d. a then y marks all read, in one bd call, as the human; a focus report while it asks
#    is no answer
: >"$LOG"
: >"$BD_LOG"
out="$(popup "$WORK/screen-d" sleep:2 send:a sleep:0.4 'send:\x1b[I' sleep:0.4 send:y sleep:0.6 send:q wait:3 -- "$TEAMCTL" _human-inbox)"
check "a, focus report, y: marks all read in ONE call, as the human" '[ "$(grep -c "|close" "$BD_LOG")" = "1" ] && grep -qx "human|close m-2 m-1 -r read" "$BD_LOG"'
check "a, focus report, y: the log shows the question, the ignored report, the answer" 'grep -q "= a -> asks y/n" "$LOG" && grep -q "= focus in -> ignored (still asking y/n)" "$LOG" && grep -q "= y -> marked all read" "$LOG"'

# e. input that ends: the reason on screen, and it waits (WOLFMUX_HI_HOLD=2 here, 10 by
#    default) instead of flashing away
: >"$LOG"
: >"$WORK/screen-e"
out="$(WOLFMUX_HI_HOLD=3 popup "$WORK/screen-e" sleep:1.5 alive wait:5 -- bash -c 'exec "$0" _human-inbox </dev/null' "$TEAMCTL")"
check "EOF: says 'closed: input ended' on screen" 'grep -aq "closed: input ended" "$WORK/screen-e"'
check "EOF: and is still there to be read after the list was drawn" 'printf "%s\n" "$out" | grep -qx "ALIVE yes"'
check "EOF: then closes by itself" 'printf "%s\n" "$out" | grep -qx "EXIT 0"'
check "EOF: the log says input ended, with stdin-tty=no" 'grep -q "stdin-tty=no" "$LOG" && grep -q "exit: input ended" "$LOG"'

# f. a teamctl that dies before the list is drawn (not a git repository): the error stays
#    on screen, and the machine's log has it
NOREPO="$WORK/not-a-repo"
/bin/mkdir -p "$NOREPO"
: >"$WORK/screen-f"
out="$(cd "$NOREPO" && python3 -I "$WORK/pty.py" "$WORK/screen-f" sleep:1 alive wait:4 -- "$TEAMCTL" _human-inbox)"
check "early death: teamctl's own message and 'closed: teamctl stopped (exit 1)' stay on screen" 'grep -aq "not inside a git repository" "$WORK/screen-f" && grep -aq "closed: teamctl stopped (exit 1)" "$WORK/screen-f"'
check "early death: held, then gone with teamctl's exit code" 'printf "%s\n" "$out" | grep -qx "ALIVE yes" && printf "%s\n" "$out" | grep -qx "EXIT 1"'
check "early death: logged in the machine's log" 'grep -q "exit: teamctl stopped (exit 1)" "$WOLFMUX_DATA/state/human-inbox-popup.log"'

# --- 3. the keys on a real tmux server -------------------------------------------------------
echo "== prefix N and prefix O on a tmux server running this repository's tmux.conf"
check "tmux.conf: no display-popup of its own (a format in its command is never expanded)" '! grep -Eq "^[^#]*display-popup" "$REPO/config/wolfmux/tmux.conf"'
/bin/mkdir -p "$WORK/home"
HOME="$WORK/home" tmx -f "$REPO/config/wolfmux/tmux.conf" new-session -d -s hk -x 120 -y 40 -c "$PROJECT" >/dev/null 2>&1
tmx set-option -t hk @wolfmux_root "$PROJECT" >/dev/null 2>&1 # with its space
tmx set-option -t hk @wolfmux_teamctl "$REPO/bin/teamctl" >/dev/null 2>&1
tmx set-option -t hk @wolfmux_team default >/dev/null 2>&1
check "setup: the throwaway server runs, with the session options teamctl start sets" '[ "$(tmx display-message -p -t hk "#{@wolfmux_team}")" = default ]'
: >"$LOG"
: >"$WORK/screen-t"
popup "$WORK/screen-t" sleep:2 'send:\x02N' sleep:3 send:q sleep:1.5 'send:\x02O' sleep:3.5 send:q sleep:1 'send:\x02d' wait:3 -- \
  env TERM=xterm-256color tmux -L "$WOLFMUX_TMUX_SOCKET" attach -t hk >/dev/null 2>&1
check "prefix N: teamctl _human-inbox ran in the popup, on its terminal, in the project" 'grep -Eq "\] start: v[0-9.]+ team=default .* stdin-tty=yes stdout-tty=yes$" "$LOG"'
check "prefix N: the popup stayed open until q, which closed it" 'grep -Eq "\] exit: key q \(after [2-9]s\)$" "$LOG"'
check "prefix N / O: no 'command not found' on the screen" '! grep -aq "command not found" "$WORK/screen-t"'
check "prefix O: the dashboard popup drew" 'grep -aq "WOLFMUX DASHBOARD" "$WORK/screen-t"'
tmx kill-server >/dev/null 2>&1

# --- 4. the log never gets in the way ------------------------------------------------------
echo "== the log: capped, and never in the way"
: >"$LOG"
i=0
while [ "$i" -lt 250 ]; do
  printf 'old line %s\n' "$i" >>"$LOG"
  i=$((i + 1))
done
(cd "$PROJECT" && printf 'q' | "$TEAMCTL" _human-inbox >/dev/null 2>&1)
n="$(wc -l <"$LOG" | tr -d ' ')"
check "cap: a log past 200 lines is cut to its last 150, then this popup's lines ($n now)" '[ "$n" -le 160 ] && [ "$n" -gt 150 ] && ! grep -q "^old line 99$" "$LOG" && grep -q "^old line 249$" "$LOG"'
/bin/rm -f "$LOG"
/bin/mkdir -p "$LOG" # a directory where the file should be: every write fails
err="$( (cd "$PROJECT" && printf 'q' | "$TEAMCTL" _human-inbox 2>&1 >/dev/null); echo "rc=$?")"
check "unwritable log: the popup still works, exit 0, and says nothing about it" '[ "$err" = "rc=0" ]'
/bin/rm -rf "$LOG"
: >"$BD_LOG"
(cd "$PROJECT" && printf 'jrq' | "$TEAMCTL" _human-inbox >/dev/null 2>&1)
check "pipe input (scripts, tests) is still one key per byte: j r q marks the second one read" 'grep -qx "human|close m-1 -r read" "$BD_LOG"'

echo
echo "passed: $passed  failed: $failed"
[ "$failed" -eq 0 ]
