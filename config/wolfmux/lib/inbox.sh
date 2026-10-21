#!/bin/bash
# inbox.sh — a notice for an agent, kept in a file instead of typed into a human's
# conversation.
#
# Issue #11. The lead's pane IS the human's conversation: every `[wolfmux] Beads update
# for …` line that teamctl typed into it appeared in the middle of whatever he was
# saying. A notice has two readers with opposite needs, and that is the whole design:
#
#   the HUMAN wants to know that mail arrived, and to read it when he chooses
#   the AGENT needs the text as input, or it never runs the command the notice names
#
# So every notice is appended to a per-role file first, and only then does anything
# else happen with it. The file is the record; the status-bar badge, the popup, the
# Stop hook, the UserPromptSubmit hook and the typed fallback are five ways of reading
# the same lines. A notice is not lost by being read: the bead stays in Beads, and a
# line leaves this file only when a replacement record has been written successfully —
# every read-modify-write here is chained with && for that reason, and the two hooks put
# the agent's letter back if the answer they were marking for then fails.
#
#   $STATE_DIR/inbox/<role>     one notice per line (STATE_DIR is already per project
#                               AND per team, so the file name needs the role only)
#   <epoch>\t<kind>\t<state>\t<text>
#   kind    beads | spawn | approval | policy
#   state   two letters, two INDEPENDENT facts:
#             1st  n = new for the human (not expanded yet)   s = seen
#             2nd  u = not yet given to the agent             d = delivered
#           Delivering to the agent must NOT clear the human's badge, and expanding
#           for the human must NOT hide the line from the agent. Hence two letters
#           rather than one state.
#
# Rule for this file, the same as lib/notify.sh: a notice may never fail or delay a
# caller. Every write is best-effort and every read prints nothing rather than an
# error. One `>>` append of one short line per notice, so concurrent writers cannot
# interleave; the read-modify-write paths take a per-role lock and give up rather
# than wait.

WOLFMUX_INBOX_MAX=200             # lines kept per role, oldest dropped
WOLFMUX_INBOX_TEXT_MAX=400        # one line stays well inside an atomic append
WOLFMUX_INBOX_LOCK_TRIES=10       # ~1 s, then give up: a notice may not delay anybody
WOLFMUX_INBOX_LOCK_STALE=15       # a lock older than this was left by a dead process

# How long after blocking a turn the Stop hook may block again. A loop is impossible
# because the hook also marks what it delivered, but a burst of beads arriving one per
# second must not turn into one blocked turn per second either.
WOLFMUX_INBOX_STOP_COOLDOWN="${WOLFMUX_INBOX_STOP_COOLDOWN:-10}"

# An approval request blocks a WORKER until the lead answers, so it may not get slower
# than it was: grace = type it into an attached lead's pane after all if it has still
# not been read, never = leave it to the badge, always = type it at once.
WOLFMUX_INBOX_APPROVAL_TYPE="${WOLFMUX_INBOX_APPROVAL_TYPE:-grace}"
WOLFMUX_INBOX_APPROVAL_GRACE="${WOLFMUX_INBOX_APPROVAL_GRACE:-20}"

# A notice the lead's agent cannot be told about right now (a client is attached, so
# nothing is typed) raises the desktop notification that lib/notify.sh already sends.
# Its own debounce, long, per role, and NOT WOLFMUX_NUDGE_DEBOUNCE: that one is 3
# seconds because typing one collapsed line into a pane is cheap. A macOS banner with a
# sound is the one channel that interrupts whatever the human is doing, and this machine
# runs 3 projects and 25 teams whose Beads events fire on create, update and close. At 3
# seconds a busy hour is dozens of banners — the same complaint with a different sound.
# The window is shared by every team on the machine (the stamp lives under
# $WOLFMUX_DATA, keyed by role): one per team would have let 25 teams ring 25 times.
WOLFMUX_INBOX_STALL_NOTIFY="${WOLFMUX_INBOX_STALL_NOTIFY:-on}"

# How many notices ONE hook may hand over. WOLFMUX_INBOX_MAX notices of
# WOLFMUX_INBOX_TEXT_MAX each is up to ~80 KB in a single Stop-hook reason, and it needs
# nothing to go wrong: an attached lead, an idle agent, a busy hour, and the first prompt
# gets the lot. The oldest batch goes first and the REST STAY UNDELIVERED, so the next
# turn takes the next batch and nothing is dropped — a cap that marked them delivered
# without showing them would be the lost-notice bug again, in a new place.
WOLFMUX_INBOX_HANDOVER_MAX="${WOLFMUX_INBOX_HANDOVER_MAX:-20}"
WOLFMUX_INBOX_STALL_NOTIFY_DEBOUNCE="${WOLFMUX_INBOX_STALL_NOTIFY_DEBOUNCE:-120}"

# Who is typed into at all. off: nobody, ever. workers: workers only. detached-lead:
# workers, plus the lead while NO client is attached to the team's session — nobody is
# looking then, the agent wakes at once, and the line only goes to scrollback. all: the
# v1.14.0 behaviour, the lead's pane included whoever is watching.
#
# On top of this knob, and whatever it says, sits the policy human-pane-typing (default
# off, v1.20.0): a pane a HUMAN is watching is never typed into — the lead's pane while a
# client is attached to the team, and any pane an attached client is showing. See
# inbox_human_pane. So under the default policy `all` types into the same panes as
# `detached-lead`; the difference between them comes back only with human-pane-typing idle.
WOLFMUX_NUDGE_TYPE="${WOLFMUX_NUDGE_TYPE:-detached-lead}"
case "$WOLFMUX_NUDGE_TYPE" in
  off | workers | detached-lead | all) ;;
  *) WOLFMUX_NUDGE_TYPE="detached-lead" ;;
esac

# The numeric knobs get the same treatment as the word above, and for a sharper reason:
# `[` exits 2 on a non-numeric operand, and every caller here treats a non-zero as its
# benign branch. So WOLFMUX_INBOX_STOP_COOLDOWN=off — a reasonable thing for somebody to
# try, meaning "no cooldown" — made cmd_inbox_stop return without delivering on EVERY
# turn for the life of the team: the agent would never again be told about a bead by its
# Stop hook, silently. A non-numeric grace ran the wait loop zero times and typed an
# approval into an attached pane at once, which is the opposite of what it asks for.
# Anything that is not all digits falls back to the default, exactly as the word does.
for _wm_knob in WOLFMUX_INBOX_STOP_COOLDOWN:10 WOLFMUX_INBOX_APPROVAL_GRACE:20 \
  WOLFMUX_INBOX_HANDOVER_MAX:20 \
  WOLFMUX_INBOX_STALL_NOTIFY_DEBOUNCE:120 WOLFMUX_INBOX_MAX:200 \
  WOLFMUX_INBOX_TEXT_MAX:400 WOLFMUX_INBOX_LOCK_TRIES:10 WOLFMUX_INBOX_LOCK_STALE:15; do
  _wm_name="${_wm_knob%%:*}"
  eval "_wm_val=\"\${$_wm_name}\""
  case "$_wm_val" in
    "" | *[!0-9]*) eval "$_wm_name=\"${_wm_knob#*:}\"" ;;
  esac
done
unset _wm_knob _wm_name _wm_val

# The marks the status bar shows, both settable. U+1F4E8 INCOMING ENVELOPE is the
# default because it is the one "bird carrying letter" mark a terminal can be relied on
# to draw: it is in Emoji_Presentation and East Asian Wide, so iTerm2 gives it two cells
# with no variation selector. U+1F54A DOVE is neither — it needs U+FE0F to show as an
# emoji at all, and tmux counts its width wrong, which pushes the rest of the status
# line about. Set WOLFMUX_INBOX_MARK='🕊️' to have the bird and accept the alignment.
# The approval mark is the second, louder one: an approval is a decision a worker is
# blocked on, not mail.
WOLFMUX_INBOX_MARK="${WOLFMUX_INBOX_MARK:-📨}"
WOLFMUX_INBOX_APPROVAL_MARK="${WOLFMUX_INBOX_APPROVAL_MARK:-🔔}"

# The human's own name in Beads (v1.20.0). Agents write to him with
# `bd create "Subject" -t message -a human -d "..."`; the status-bar number is how many of
# those are still open, and the popup (prefix N, or a click on the number) reads them. A
# name that is not a plain Beads name falls back to the default rather than reach jq,
# awk or a bd argument as something else.
WOLFMUX_HUMAN="${WOLFMUX_HUMAN:-human}"
case "$WOLFMUX_HUMAN" in
  "" | *[!${_WM_LOWER}${_WM_UPPER}${_WM_DIGITS}._-]* | -*) WOLFMUX_HUMAN="human" ;;
esac

inbox_dir() { printf '%s\n' "$STATE_DIR/inbox"; }
inbox_file() { printf '%s\n' "$STATE_DIR/inbox/$1"; }

# inbox_tmp <role> <what> — a scratch path for a read-modify-write of a role's record.
# It MUST start with a dot: inbox_roles' glob arm lists this directory, and a plain
# "<role>.taken.$$" is a sibling of "<role>" holding a COPY of the record, so the badge
# counted the same notices once per temp file lying around (reviewer F3: one notice read
# as 3). Dotfiles are skipped there, and known_role_name is applied as well — either
# alone would have prevented it, and neither was there.
inbox_tmp() { printf '%s\n' "$STATE_DIR/inbox/.tmp.$1.$2.$$"; }

# inbox_tag_session <session> — remember where teamctl is, for the two tmux format
# strings that have to run it (status-left's badge and the prefix-N popup). tmux runs
# them through /bin/sh with the server's PATH, which need not have ~/bin in it.
inbox_tag_session() {
  [ -n "$TMUX_BIN" ] || return 0
  tmx set-option -t "=$1:" @wolfmux_teamctl "$TEAMCTL_SELF" 2>/dev/null || true
  return 0
}

# _inbox_num_or_zero <string> — the number, or 0 when it is not one
_inbox_num_or_zero() {
  case "${1:-}" in "" | *[!0-9]*) printf '0' ;; *) printf '%s' "$1" ;; esac
}

# inbox_text <string> — one safe line: tabs and control characters out (they are the
# record's field separator and would be typed into a pane later), length capped.
inbox_text() {
  local text
  text="$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\010\011\012-\037\177' 2>/dev/null || true)"
  if [ "${#text}" -gt "$WOLFMUX_INBOX_TEXT_MAX" ]; then text="${text:0:$WOLFMUX_INBOX_TEXT_MAX}…"; fi
  printf '%s' "$text"
}

# inbox_lock <role> — 0 when this process may rewrite the role's file. Gives up after
# WOLFMUX_INBOX_LOCK_TRIES rather than hold a caller up; the caller then leaves the
# file alone, which costs at most one notice being offered twice.
inbox_lock() {
  /bin/mkdir -p "$(inbox_dir)" 2>/dev/null || return 1
  _inbox_lock_dir "$(inbox_dir)/.lock.$1"
}

# _inbox_lock_dir <guard> — the mkdir lock itself, shared with the human's index below
_inbox_lock_dir() {
  local guard="$1" tries=0 started
  while [ "$tries" -lt "$WOLFMUX_INBOX_LOCK_TRIES" ]; do
    if /bin/mkdir "$guard" 2>/dev/null; then
      now_epoch >"$guard/ts" 2>/dev/null || true
      return 0
    fi
    started="$(/bin/cat "$guard/ts" 2>/dev/null || printf '0')"
    case "$started" in "" | *[!0-9]*) started=0 ;; esac
    if [ $(($(now_epoch) - started)) -gt "$WOLFMUX_INBOX_LOCK_STALE" ]; then
      /bin/rm -rf "$guard" 2>/dev/null || true
      continue
    fi
    tries=$((tries + 1))
    sleep 0.1
  done
  return 1
}
inbox_unlock() { /bin/rm -rf "$(inbox_dir)/.lock.$1" 2>/dev/null || true; }

# inbox_add <role> <kind> <text> — the one write every notice goes through, before
# anything is decided about typing. Always 0: a notice may never fail a caller.
#
# One logical Beads change fires several hooks (create + update), and each would file the
# same line, so the count the human sees would read 3 for one bead. An identical record
# within WOLFMUX_NUDGE_DEBOUNCE seconds is therefore not filed again — the same rule, and
# the same reason, as the nudge debounce. Two different beads give different text, so
# nothing real is ever collapsed away.
inbox_add() {
  local role="$1" kind="$2" text file lines last
  text="$(inbox_text "$3")"
  [ -n "$role" ] && [ -n "$text" ] || return 0
  case "$kind" in beads | spawn | approval | policy) ;; *) kind="beads" ;; esac
  /bin/mkdir -p "$(inbox_dir)" 2>/dev/null || return 0
  file="$(inbox_file "$role")"
  # One logical Beads change fires create AND update, so the same notice arrives twice
  # within a second or two and the badge would read 2 for one bead. Comparing against
  # the LAST line only was not enough: two beads for the same role interleave as
  # A-create, B-create, A-update, and then A-update's predecessor is B, the comparison
  # misses, and A is filed twice (reviewer F6). So the whole debounce window is scanned
  # for an identical kind+text. WOLFMUX_INBOX_MAX is 200, so the tail is cheap.
  if [ -f "$file" ]; then
    # tail is PIPED in, never interpolated: a notice's text is arbitrary (it comes from a
    # bead title) and must not pass through the shell again. The text reaches awk through
    # the ENVIRONMENT rather than -v for a second reason: awk processes escape sequences
    # in a -v assignment, so a title containing a literal \n or \t arrived at awk as a
    # real newline or tab and the comparison silently failed — measured. That would file
    # the same notice twice, or leave a typed notice undelivered for a hook to hand over
    # again. ENVIRON is taken verbatim. Every text comparison in this file does this.
    if tail -n 40 "$file" 2>/dev/null | WM_TEXT="$text" LC_ALL=C /usr/bin/awk -F'\t' \
      -v kind="$kind" -v now="$(now_epoch)" \
      -v window="${WOLFMUX_NUDGE_DEBOUNCE:-3}" '
        BEGIN { text = ENVIRON["WM_TEXT"] }
        NF >= 4 && $2 == kind && $4 == text && (now - $1) < window && (now - $1) >= 0 {
          found = 1
          exit
        }
        END { exit(found ? 0 : 1) }' 2>/dev/null; then
      return 0
    fi
  fi
  # ONE append of ONE line: two notifiers writing at the same moment cannot interleave.
  printf '%s\t%s\tnu\t%s\n' "$(now_epoch)" "$kind" "$text" >>"$file" 2>/dev/null || return 0
  # Cap the file. Only when it has really grown, and only under the lock; failing to
  # trim is harmless, so nothing is reported.
  lines="$(wc -l <"$file" 2>/dev/null || printf '0')"
  lines="$(printf '%s' "$lines" | tr -d ' ')"
  case "$lines" in "" | *[!0-9]*) return 0 ;; esac
  if [ "$lines" -gt $((WOLFMUX_INBOX_MAX + 50)) ] && inbox_lock "$role"; then
    tail -n "$WOLFMUX_INBOX_MAX" "$file" >"$(inbox_tmp "$role" trim)" 2>/dev/null &&
      /bin/mv -f "$(inbox_tmp "$role" trim)" "$file" 2>/dev/null
    /bin/rm -f "$(inbox_tmp "$role" trim)" 2>/dev/null || true
    inbox_unlock "$role"
  fi
  return 0
}

# inbox_roles — roles of the loaded team that have an inbox file, in the registry's
# order (lead first), then any file whose agent is gone but whose notices remain.
inbox_roles() {
  local role file seen=""
  [ -d "$(inbox_dir)" ] || return 0
  for role in $(reg_list 2>/dev/null || true); do
    [ -f "$(inbox_file "$role")" ] || continue
    printf '%s\n' "$role"
    seen="$seen $role"
  done
  for file in "$(inbox_dir)"/*; do
    [ -f "$file" ] || continue
    role="$(basename "$file")"
    case "$role" in .*) continue ;; esac
    known_role_name "$role" || continue
    case " $seen " in *" $role "*) continue ;; esac
    printf '%s\n' "$role"
  done
}

# --- counting (the badge) ------------------------------------------------------
# inbox_count_new <role> — notices the human has not expanded. Prints 0 on anything
# unexpected, because a badge may never break a status bar.
inbox_count_new() {
  local file
  file="$(inbox_file "$1")"
  [ -f "$file" ] || {
    printf '0\n'
    return 0
  }
  LC_ALL=C /usr/bin/awk -F'\t' 'NF >= 4 && substr($3, 1, 1) == "n" { n++ } END { print n + 0 }' "$file" 2>/dev/null ||
    printf '0\n'
}

# inbox_has_new_approval <role> — 0 when one of the new notices is a decision waiting
inbox_has_new_approval() {
  local file
  file="$(inbox_file "$1")"
  [ -f "$file" ] || return 1
  LC_ALL=C /usr/bin/awk -F'\t' '
    NF >= 4 && $2 == "approval" && substr($3, 1, 1) == "n" { found = 1; exit }
    END { exit found ? 0 : 1 }' "$file" 2>/dev/null
}

# inbox_is_new <role> <text> — is THIS record still unexpanded? The grace waiter used to
# ask inbox_has_new_approval, which answers "does this role have ANY new approval", and
# cmd_inbox marks seen for every role it prints — so with --all (prefix N, the key the
# feature advertises) a human glancing at a WORKER's line cancelled the typing of an
# approval they had never seen, and a blocked worker then waited on the human's
# attention, which is the one thing the grace exists to avoid (reviewer F5).
inbox_is_new() {
  local file
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  file="$(inbox_file "$1")"
  [ -f "$file" ] || return 1
  WM_WANT="$2" LC_ALL=C /usr/bin/awk -F'\t' '
    BEGIN { want = ENVIRON["WM_WANT"] }
    NF >= 4 && $4 == want && substr($3, 1, 1) == "n" { found = 1; exit }
    END { exit(found ? 0 : 1) }' "$file" 2>/dev/null
}

# inbox_count_lines <role> — usable records in the file, however damaged the rest is
inbox_count_lines() {
  local file
  file="$(inbox_file "$1")"
  [ -f "$file" ] || {
    printf '0\n'
    return 0
  }
  LC_ALL=C /usr/bin/awk -F'\t' 'NF >= 4 { n++ } END { print n + 0 }' "$file" 2>/dev/null ||
    printf '0\n'
}

inbox_count_undelivered() {
  local file
  file="$(inbox_file "$1")"
  [ -f "$file" ] || {
    printf '0\n'
    return 0
  }
  LC_ALL=C /usr/bin/awk -F'\t' 'NF >= 4 && substr($3, 2, 1) == "u" { n++ } END { print n + 0 }' "$file" 2>/dev/null ||
    printf '0\n'
}

# --- the two independent state changes ----------------------------------------
# _inbox_restate <role> <field 1|2> <letter> — rewrite one letter of the state column
# on every line, leaving the other letter exactly as it was. Without the lock the file
# is left alone: a missed mark re-offers a notice, a half-written file loses it.
_inbox_restate() {
  local role="$1" where="$2" letter="$3" file
  file="$(inbox_file "$role")"
  [ -f "$file" ] || return 0
  inbox_lock "$role" || return 1
  LC_ALL=C /usr/bin/awk -F'\t' -v OFS='\t' -v where="$where" -v letter="$letter" '
    NF < 4 { print; next }
    {
      state = $3
      if (length(state) < 2) state = (where == 1 ? letter "u" : "n" letter)
      else if (where == 1) state = letter substr(state, 2, 1)
      else state = substr(state, 1, 1) letter
      $3 = state
      print
    }' "$file" >"$(inbox_tmp "$role" new)" 2>/dev/null && /bin/mv -f "$(inbox_tmp "$role" new)" "$file" 2>/dev/null
  /bin/rm -f "$(inbox_tmp "$role" new)" 2>/dev/null || true
  inbox_unlock "$role"
  return 0
}

# inbox_mark_seen <role> — the human expanded them. The agent's column is untouched.
inbox_mark_seen() { _inbox_restate "$1" 1 s; }

# inbox_mark_typed <role> <text> — this exact line has just been typed into the role's
# pane, so the agent HAS it: mark that one record delivered and nothing else. Without
# this every typed notice would be handed over a second time by the Stop hook, and
# "nothing is delivered twice" is a property this project asserts.
#
# Matched on the text rather than on all undelivered lines, because the queued path types
# one fixed notice at a time and may stop part-way: the lines it has not reached must
# stay undelivered so a hook can still carry them if the marker expires.
# inbox_requeue <role> <texts> — put the agent letter back to 'u' for these exact
# records. The hooks mark delivered BEFORE they answer, which is what makes "the Stop
# hook cannot loop" true and is deliberate. The cost is that a failure AFTER the mark
# would lose those notices for good: nothing re-queues them, and the next hook sees
# nothing undelivered (reviewer F7). So when the answer itself fails, the letters go
# back and the next turn hands them over again. Text matching, so a notice that arrived
# in between keeps its own state.
#
# RETURNS 0 only when the replacement record was installed; non-zero otherwise. That is
# load-bearing, not tidy: this is the recovery path, and it used to return 0 whether it
# had put the letters back or not, so a caller logged "N notice(s) re-queued" over a
# requeue that had requeued nothing (reviewer N1). Both hooks branch on it now.
#
# The want list reaches awk through the ENVIRONMENT, like every other text comparison in
# this file, and for one more reason than they have. It used to go through a temp file
# whose PATH was passed with -v — and -v escape-processes the path as well as the value,
# so a single backslash in $WOLFMUX_DATA or $HOME made awk open a file with a real tab in
# its name. Worse, `getline line < wantfile` returning -1 is NOT an awk error: an
# unreadable want file (that mangled path, a removed file, a truncated write on a full
# disk) left want[] empty, matched nothing, printed every line unchanged and exited 0, so
# the && chain completed and installed a record in which the notices were still 'd'. The
# one path built to stop notices being lost could lose them and record that it saved
# them. With ENVIRON there is no want file, no -v and no getline to fail silently; the
# list is bounded by WOLFMUX_INBOX_HANDOVER_MAX × WOLFMUX_INBOX_TEXT_MAX, about 8 KB.
inbox_requeue() {
  local role="$1" texts="$2" file rc=0
  [ -n "$role" ] && [ -n "$texts" ] || return 0
  file="$(inbox_file "$role")"
  [ -f "$file" ] || return 1
  inbox_lock "$role" || return 1
  WM_WANT="$texts" LC_ALL=C /usr/bin/awk -F'\t' -v OFS='\t' '
      BEGIN {
        n = split(ENVIRON["WM_WANT"], lines, "\n")
        for (i = 1; i <= n; i++) if (lines[i] != "") { want[lines[i]] = 1; nwant++ }
        # An empty want list can only mean the list did not arrive. Stop, so the chain
        # cannot install a no-op record and call it a requeue. Counted rather than
        # length(want): length() of an array is not in every awk this ships to.
        if (nwant == 0) exit 1
      }
      NF >= 4 && substr($3, 2, 1) == "d" && ($4 in want) { $3 = substr($3, 1, 1) "u" }
      { print }' "$file" >"$(inbox_tmp "$role" requeue)" 2>/dev/null &&
    /bin/mv -f "$(inbox_tmp "$role" requeue)" "$file" 2>/dev/null || rc=1
  /bin/rm -f "$(inbox_tmp "$role" requeue)" 2>/dev/null || true
  inbox_unlock "$role"
  return "$rc"
}

inbox_mark_typed() {
  local role="$1" text file
  # Normalised the same way inbox_add normalised it before storing, because the four call
  # sites pass the RAW string. It matched only because every notice today is a short fixed
  # line; the first one over WOLFMUX_INBOX_TEXT_MAX, or carrying a control character,
  # would stop being marked delivered and would then be handed over a second time by the
  # Stop hook — the same defect as the typed notice that was never marked at all.
  text="$(inbox_text "$2")"
  [ -n "$role" ] && [ -n "$text" ] || return 0
  file="$(inbox_file "$role")"
  [ -f "$file" ] || return 0
  inbox_lock "$role" || return 0
  WM_WANT="$text" LC_ALL=C /usr/bin/awk -F'\t' -v OFS='\t' '
    BEGIN { want = ENVIRON["WM_WANT"] }
    NF >= 4 && $4 == want && substr($3, 2, 1) == "u" { $3 = substr($3, 1, 1) "d" }
    { print }' "$file" >"$(inbox_tmp "$role" typed)" 2>/dev/null && /bin/mv -f "$(inbox_tmp "$role" typed)" "$file" 2>/dev/null
  /bin/rm -f "$(inbox_tmp "$role" typed)" 2>/dev/null || true
  inbox_unlock "$role"
  return 0
}

# inbox_take_undelivered <role> — print the text of every line the agent has not been
# given, oldest first, AND mark exactly those lines delivered. One critical section, so
# two hooks firing together cannot both hand over the same notice. The human's column is
# untouched: the badge stays until he expands it himself.
# Prints nothing when there is nothing, or when the lock could not be taken.
# Every step is chained with &&, and that is load-bearing rather than tidy: awk writes
# the replacement record incrementally, so `[ -f ]` is true as soon as it has written its
# FIRST line. A move guarded only by that test renames a half-written file over the
# record and destroys every line awk had not reached — measured by the reviewer at 40,000
# records in and 11,773 out when awk was killed mid-run (ENOSPC is the realistic cause on
# this machine, and `mv` is a rename, so it succeeds even when the write that killed awk
# was a disk-full write). Nothing is printed to the agent unless the record was replaced,
# either, so a successful awk whose move failed cannot hand over notices that are still
# marked undelivered. _inbox_restate and inbox_mark_typed have always chained this way;
# this function was the one sibling that did not.
#
# The output path reaches awk through the ENVIRONMENT, not -v. -v escape-processes the
# path as much as a value, so one backslash in $WOLFMUX_DATA or $HOME made awk unable to
# open `out` (reviewer N2). The chain above contained that completely — no mv, no cat,
# record intact, every letter still 'u' — so this was never a lost notice. What it was
# was SILENT: awk's stderr goes to /dev/null, so both hooks stopped delivering for the
# life of that install while the badge (which passes no paths) kept counting up, and the
# human watched a rising number whose notices never reached the agent. The path is off -v
# now, and a failed chain writes an event so it can never be silent again.
inbox_take_undelivered() {
  local role="$1" file
  file="$(inbox_file "$role")"
  [ -f "$file" ] || return 0
  inbox_lock "$role" || return 0
  WM_OUT="$(inbox_tmp "$role" taken)" LC_ALL=C /usr/bin/awk -F'\t' -v OFS='\t' \
    -v cap="$WOLFMUX_INBOX_HANDOVER_MAX" '
    BEGIN { out = ENVIRON["WM_OUT"] }
    NF < 4 { print > out; next }
    substr($3, 2, 1) == "u" && taken < cap {
      print $4
      $3 = substr($3, 1, 1) "d"
      taken++
    }
    { print > out }' "$file" >"$(inbox_tmp "$role" texts)" 2>/dev/null &&
    /bin/mv -f "$(inbox_tmp "$role" taken)" "$file" 2>/dev/null &&
    [ -f "$(inbox_tmp "$role" texts)" ] &&
    /bin/cat "$(inbox_tmp "$role" texts)" 2>/dev/null ||
    event_log inbox-take-failed "$role" "could not rewrite the record; nothing handed over" 2>/dev/null || true
  /bin/rm -f "$(inbox_tmp "$role" texts)" "$(inbox_tmp "$role" taken)" 2>/dev/null || true
  inbox_unlock "$role"
  return 0
}

# --- who may be typed into ----------------------------------------------------
# inbox_clients_attached <session> — 0 when somebody is watching this team. Fails
# CLOSED: a tmux read we cannot make sense of counts as attached, because the cost of
# being wrong that way is a notice that waits, and the other way is a line in the
# middle of the human's sentence.
inbox_clients_attached() {
  local clients
  if [ -n "${WOLFMUX_INBOX_CLIENTS:-}" ]; then # test seam: 1 attached, 0 not
    [ "$WOLFMUX_INBOX_CLIENTS" != "0" ]
    return
  fi
  [ -n "$TMUX_BIN" ] || return 0
  clients="$(tmx list-clients -t "=$1" -F x 2>/dev/null)" || return 0
  [ -n "$clients" ]
}

# inbox_type_allowed <role> — 0 when a notice for this role may still be TYPED into its
# pane. WOLFMUX_NUDGE_TYPE decides, with one exception that is not a preference: a
# Codex-family pane has no hooks, so typing is the only channel that reaches that agent
# at all, lead or worker. WOLFMUX_NUDGE_TYPE=off silences even that.
inbox_type_allowed() {
  local role="$1"
  case "$WOLFMUX_NUDGE_TYPE" in
    off) return 1 ;;
    all) return 0 ;;
  esac
  [ "$(reg_field "$role" family 2>/dev/null || true)" = "codex" ] && return 0
  [ "$role" = "$WOLFMUX_LEAD_ROLE" ] || return 0 # workers keep the idle typed fallback
  [ "$WOLFMUX_NUDGE_TYPE" = "detached-lead" ] || return 1
  # The lead's pane is the human's conversation only while a human is in front of it.
  # ${SESSION:-} rather than $SESSION: every caller sets it, and a notice path may not be
  # the thing that ends a command under `set -u` if one ever does not.
  ! inbox_clients_attached "${SESSION:-}"
}

# inbox_type_when_idle <role> — 0 when inbox_type_allowed said no for ONE reason and one
# reason only: this is the LEAD under the default detached-lead rule and somebody is
# attached to the team. Such a notice may still be typed, but ONLY into a pane that is
# quiet — no keystroke for WOLFMUX_NUDGE_LEAD_IDLE seconds, nothing on the input line,
# no copy mode. The caller does that part (tm_pane_human_busy); this only says the
# suppression is about a watching human rather than about the knob.
#
# Why it exists (issue #12): v1.15.0 answered "a client is attached" with filing only,
# and filing reaches the agent through its Stop hook, which fires on a TURN BOUNDARY. An
# agent that is already idle has no further boundary, so a notice filed for an idle lead
# with a client attached was never handed over at all — measured in production on
# 2026-10-12: a lead idle from 13:58Z never received P1 notices sent at 16:13Z or 16:53Z.
# "Not while the human is working in that pane" is the requirement; "never" was not.
#
# off and workers are NOT this case: those say nothing is ever typed into that pane,
# idle or not, and a knob called off that still types is worse than no knob.
inbox_type_when_idle() {
  [ "$WOLFMUX_NUDGE_TYPE" = "detached-lead" ] || return 1
  [ "$1" = "$WOLFMUX_LEAD_ROLE" ] || return 1
  return 0
}

# inbox_human_pane <role> <pane> — 0 when this pane is in front of a human right now, so
# under human-pane-typing off NOTHING is typed into it. Two cases, and either is enough:
#   a. it is the LEAD's pane and a client is attached to the team's session. That pane is
#      the human's conversation, whether he is looking at it this second or not.
#   b. an attached client is showing it: the active pane of the window on his screen, in
#      any session of this server. A worker's pane he is reading counts too.
# Both reads fail CLOSED (inbox_clients_attached, tm_pane_watched): when tmux cannot tell
# us, the answer is "a human is there". INBOX_HUMAN_REASON says which case it was.
#
# Why "never" and not "once it is quiet" (the v1.16.1 rule, still there as idle): Ammar,
# 2026-10-15, "i still see beads messages in my terminal". Quiet for 300 s is a human
# reading, or thinking, or away for a coffee; any of those, and a line arrives in his
# conversation. The price is issue #12 again for that one pane: an IDLE lead that a human
# is attached to is not woken by a notice. Its own loop wakes it (the communication lead
# runs one every 20 minutes), or the human does, and the Stop and UserPromptSubmit hooks
# hand the notices over then. That trade is the human's to make, hence a policy.
inbox_human_pane() {
  local role="$1" pane="$2"
  INBOX_HUMAN_REASON=""
  if [ "$role" = "$WOLFMUX_LEAD_ROLE" ] && inbox_clients_attached "${SESSION:-}"; then
    INBOX_HUMAN_REASON="a client is attached to the team and this is the lead's pane"
    return 0
  fi
  if [ -n "${WOLFMUX_INBOX_WATCHED+x}" ]; then # test seam: the panes on screen, or "error"
    case " $WOLFMUX_INBOX_WATCHED " in
      *" error "* | *" $pane "*)
        INBOX_HUMAN_REASON="an attached client is showing this pane"
        return 0
        ;;
    esac
    return 1
  fi
  [ -n "$TMUX_BIN" ] || {
    INBOX_HUMAN_REASON="tmux cannot be asked who is watching"
    return 0
  }
  if tm_pane_watched "$pane"; then
    INBOX_HUMAN_REASON="an attached client is showing this pane"
    return 0
  fi
  return 1
}

# inbox_human_typing_off — 0 under the default: a pane a human is watching is not typed into
inbox_human_typing_off() { [ "$(policy_get human-pane-typing 2>/dev/null || true)" != "idle" ]; }

# inbox_keep_off_human_pane <role> <pane> — the one question every typed path asks: 0 when
# this notice must NOT be typed into that pane now (the policy is off and a human is there)
inbox_keep_off_human_pane() {
  inbox_human_typing_off || return 1
  inbox_human_pane "$1" "$2"
}

# inbox_stall_notify <role> <kind> — the third human-facing channel, and the only
# active one: a notice for the LEAD that could not be typed (a client is attached) may
# be sitting in front of an agent that will never be asked anything, so no Stop hook
# fires. lib/notify.sh already puts a notification on the attached terminal, and a
# click on it opens the team; nothing of it reaches the conversation.
#
# Raised the moment we decline to type, not after a timer: nothing can tell us whether
# the agent's turn will ever end, so "it cannot reach the agent now" is the honest
# trigger. If the agent was mid-turn its Stop hook delivers the notice as well, and the
# human has still been told once that mail arrived.
#
# It COLLAPSES rather than repeats. One banner per WOLFMUX_INBOX_STALL_NOTIFY_DEBOUNCE
# (120 s) per role, and the banner carries the count the inbox file holds, not the one
# notice that happened to trigger it: "lead: 4 notices waiting", never four banners.
# Inside the window the notice still lands in the file and the badge count still rises,
# so nothing is lost — only the banner is suppressed. Subject to WOLFMUX_NOTIFY as
# well: with notifications off this stays quiet and leaves it to the badge.
inbox_stall_notify() {
  local role="$1" kind="$2" stamp last team body count what
  [ "$WOLFMUX_INBOX_STALL_NOTIFY" = "on" ] || return 0
  [ "$role" = "$WOLFMUX_LEAD_ROLE" ] || return 0
  notify_wanted lead || return 0
  # The stamp is MACHINE-WIDE, not per team, and that is the whole point of the knob.
  # $STATE_DIR/inbox is per project AND per team, so a stamp kept there gave every team
  # its own 120-second window: 25 teams on record is up to 25 banners a window, about
  # twelve a minute, each with a sound. That is the complaint this release is named
  # after, arriving through the one channel we deliberately kept loud (reviewer F8).
  # Keyed by role, under $WOLFMUX_DATA, so every team shares one window.
  stamp="$WOLFMUX_DATA/.stall.$role"
  /bin/mkdir -p "$WOLFMUX_DATA" 2>/dev/null || return 0
  # Read and write under one lock: two notifiers arriving together both used to pass the
  # window and both rang. mkdir is the atomic test-and-set, as elsewhere in this file.
  /bin/mkdir "$stamp.lock" 2>/dev/null || return 0
  last="$(/bin/cat "$stamp" 2>/dev/null || printf '0')"
  case "$last" in "" | *[!0-9]*) last=0 ;; esac
  if [ $(($(now_epoch) - last)) -lt "$WOLFMUX_INBOX_STALL_NOTIFY_DEBOUNCE" ]; then
    /bin/rmdir "$stamp.lock" 2>/dev/null || true
    return 0
  fi
  now_epoch >"$stamp" 2>/dev/null || true
  /bin/rmdir "$stamp.lock" 2>/dev/null || true
  team="${TEAM:-$WOLFMUX_DEFAULT_TEAM}"
  count="$(inbox_count_new "$role")"
  case "$count" in "" | *[!0-9]*) count=1 ;; esac
  [ "$count" -ge 1 ] || count=1
  if [ "$count" -eq 1 ]; then what="1 notice waiting"; else what="$count notices waiting"; fi
  case "$kind" in
    approval) body="$WOLFMUX_LEAD_MARK $team/$role: $what, one is a permission request (teamctl approvals)" ;;
    *) body="$WOLFMUX_LEAD_MARK $team/$role: $what (teamctl inbox)" ;;
  esac
  notify_deliver "$body" >/dev/null 2>&1 || true
  event_log inbox-stall-notify "$role" "$kind ($what)" 2>/dev/null || true
  return 0
}

# --- the badge ----------------------------------------------------------------
# cmd_inbox_badge — internal (`teamctl _inbox-badge <session-name> [<root>] [<team>]`),
# called by status-left every status-interval. It prints ONE short line and NOTHING on
# any error whatsoever: a badge may never break a status bar, and a status bar that
# shouts an error every 5 seconds is worse than no badge.
#
# tmux passes the session name; the root and the team are read back off the session
# options teamctl set when it started the team (@wolfmux_root, @wolfmux_team), so the
# badge needs no working directory of its own. Passing them as arguments skips that
# lookup (tests, and anybody scripting it).
cmd_inbox_badge() {
  # Its own subshell with errexit off, and stderr thrown away: whatever goes wrong in
  # there, this prints nothing and exits 0. _inbox_badge_text writes only at its very
  # end, so a failure part-way cannot leave half a badge on the status line.
  (
    set +e
    _inbox_badge_text "$@"
  ) 2>/dev/null || true
  return 0
}

#
# v1.20.0: the number is the human's UNREAD BEADS MESSAGES in this project (open messages
# assigned to WOLFMUX_HUMAN), counted from the index the Beads hook keeps — never from bd,
# which this redraw every 5 seconds per client cannot afford. Pane notices are no longer
# counted: they are the agents' business, and `teamctl inbox` still shows them. The bell
# is a permission request of this team still pending, read from the approval files
# themselves, so it goes when the request is decided and not when somebody happens to
# open a list.
_inbox_badge_text() {
  local session="${1:-}" root="${2:-}" team="${3:-}" total approval=0
  [ -n "$session" ] || return 0
  if [ -z "$root" ] || [ -z "$team" ]; then
    [ -n "$TMUX_BIN" ] || return 0
    root="$(tmx show-options -t "=$session:" -qv @wolfmux_root 2>/dev/null)" || return 0
    team="$(tmx show-options -t "=$session:" -qv @wolfmux_team 2>/dev/null)" || return 0
  fi
  [ -n "$root" ] && [ -d "$root" ] || return 0
  valid_team_name "$team" || return 0
  PROJECT_KEY="$(project_key "$root")" || return 0
  PROJECT_STATE="$WOLFMUX_DATA/state/$PROJECT_KEY"
  PROJECT_TREES="$WOLFMUX_DATA/worktrees/$PROJECT_KEY"
  team_paths "$team"
  total="$(human_inbox_count)"
  case "$total" in "" | *[!0-9]*) total=0 ;; esac
  if _inbox_approval_pending; then approval=1; fi
  if [ "$total" -gt 0 ] && [ "$approval" -eq 1 ]; then
    printf '%s %s %s\n' "$WOLFMUX_INBOX_MARK" "$total" "$WOLFMUX_INBOX_APPROVAL_MARK"
  elif [ "$total" -gt 0 ]; then
    printf '%s %s\n' "$WOLFMUX_INBOX_MARK" "$total"
  elif [ "$approval" -eq 1 ]; then
    printf '%s\n' "$WOLFMUX_INBOX_APPROVAL_MARK"
  fi
  return 0
}

# _inbox_approval_pending — 0 when this team has a permission request nobody has decided.
# One grep over the request files, not a jq per file: decided requests stay on disk for
# `teamctl approvals --all`, so the directory only grows, and this runs every 5 seconds.
_inbox_approval_pending() {
  local dir
  dir="$(approvals_dir)"
  [ -d "$dir" ] || return 1
  LC_ALL=C /usr/bin/grep -lqE '"status"[[:space:]]*:[[:space:]]*"pending"' "$dir"/A*.json 2>/dev/null
}

# --- the hooks ----------------------------------------------------------------
# A hook runs inside the agent's own process tree, with the environment cmd_run_agent
# exported (TEAM_ROLE, WOLFMUX_TEAM, WOLFMUX_ROOT) and the agent's working directory.
# Both hooks below must therefore be silent and quick on every path that is not a
# delivery, and neither may ever exit non-zero: a hook that fails is shown to the agent.

# _inbox_hook_ready — sets up the team paths for a hook, or 1 when there is nothing to
# do. Never dies: load_project would, and an agent must not see a teamctl error.
#
# The pane proof (identity_in_own_pane, lib/common.sh): the hook hands notices only to a
# process that runs inside this role's own pane of this team's session. A chat that merely
# inherited the agent's environment (a background chat of Claude's daemon, 2026-10-19) is
# given nothing, nothing is taken from the inbox for it and nothing is blocked; one
# identity-refused line goes to the event log, at most once a minute. INBOX_NOT_HERE then
# says why, and cmd_inbox_prompt tells that chat who it is not. No fallback that looks the
# pane up by role: that is how an inherited environment found the real agent's pane.
# Sets INBOX_PANE and SESSION (this agent's own pane and its team's session) when it says 0.
_inbox_hook_ready() {
  local session="" ready=1
  INBOX_ROLE="${TEAM_ROLE:-}" INBOX_NOT_HERE="" INBOX_PROVEN="" INBOX_PANE="" SESSION=""
  [ -n "$INBOX_ROLE" ] || return 1
  known_role_name "$INBOX_ROLE" || return 1
  INBOX_IDENTITY="$(team_identity "${WOLFMUX_TEAM:-$WOLFMUX_DEFAULT_TEAM}" "$INBOX_ROLE")"
  STATE_DIR=""
  if [ -n "$TMUX_BIN" ] && [ -n "$JQ_BIN" ] && [ -n "$GIT_BIN" ] && ROOT="$(resolve_root 2>/dev/null)" &&
    PROJECT_KEY="$(project_key "$ROOT")"; then
    PROJECT_STATE="$WOLFMUX_DATA/state/$PROJECT_KEY"
    PROJECT_TREES="$WOLFMUX_DATA/worktrees/$PROJECT_KEY"
    team_paths "${WOLFMUX_TEAM:-$WOLFMUX_DEFAULT_TEAM}"
    if [ -d "$STATE_DIR" ]; then
      session="$(session_name_for_project 2>/dev/null || true)"
    else
      ready=0
    fi
  else
    ready=0
  fi
  if ! identity_in_own_pane "$INBOX_ROLE" "$session"; then
    INBOX_NOT_HERE="$IDENTITY_WHY"
    identity_refused_log "$INBOX_ROLE" "$IDENTITY_WHY"
    return 1
  fi
  INBOX_PROVEN=1 # this is the agent; whether there is anything to do is the next question
  [ "$ready" -eq 1 ] || return 1
  INBOX_PANE="$TMUX_PANE" SESSION="$IDENTITY_SESSION"
  return 0
}

# inbox_not_you — what a chat that failed the pane proof is told, on every prompt and not
# once: after a compaction it may have forgotten. A UserPromptSubmit hook's stdout reaches
# the model, not the human, so this is said to the chat alone.
inbox_not_you() {
  printf "[wolfmux] This chat is not running in %s's %s pane, so it is NOT %s. Do not send Beads or run teamctl as that role, and ignore wolfmux notices. BEADS_ACTOR in this chat's environment is inherited, not yours.\n" \
    "${WOLFMUX_TEAM:-$WOLFMUX_DEFAULT_TEAM}" "$INBOX_ROLE" "$INBOX_IDENTITY"
}

# inbox_hook_body <identity> <notices> — what the agent is told. The notices are the
# lines teamctl itself wrote; the last line is always the agent's own inbox command, so
# a notice that lost its bead id still leads to the work.
# inbox_hook_body <identity> <notices> [<still-waiting>] — what the agent is told. A
# third argument says how many notices this hand-over could not carry, so a capped batch
# does not look like the whole of it.
inbox_hook_body() {
  printf '%s\n%s\n' "[wolfmux] You have team notices:" "$2"
  if [ -n "${3:-}" ] && [ "$3" != "0" ]; then
    printf '%s more waiting; they come with your next turn, or see them all now: teamctl inbox\n' "$3"
  fi
  printf 'Read it now: bd list --assignee %s --status open,in_progress,blocked --include-infra\n' "$1"
}

# cmd_inbox_stop — internal (`teamctl _inbox-stop`): a Claude Code Stop hook, added as a
# SECOND entry in the Stop array next to lib/notify.sh's. When the role's inbox holds
# notices the agent has not been given, it answers {"decision":"block","reason":…}, and
# the agent carries straight on and reads its beads — no keystroke anywhere. The reason
# IS printed in that pane's terminal, though, which is the v1.20.0 part below.
#
# A loop is impossible for two reasons, and both are needed: the lines are marked
# delivered BEFORE the answer is printed, so the same notice can never block twice; and
# no turn is blocked again inside WOLFMUX_INBOX_STOP_COOLDOWN, so a burst of beads
# arriving one a second cannot block one turn per second either.
#
# v1.20.0: in a pane a human is watching it says NOTHING (policy human-pane-typing off,
# the default). Claude Code prints a Stop hook's reason in the terminal, labelled "Stop
# hook error", and Ammar saw exactly that in the pane he watches: "i am still seeing such
# messages" (2026-10-15). Its docs give Stop no channel the human does not see (the
# reason is shown, additionalContext is shown as "Stop hook feedback", suppressOutput
# changes neither), while a UserPromptSubmit hook's output reaches the model alone. So
# the notices stay undelivered, and cmd_inbox_prompt hands them over with the next
# prompt: the human's, or the agent's own loop, whose tick arrives as a prompt too.
cmd_inbox_stop() {
  local notices stamp last
  /bin/cat >/dev/null 2>&1 || true # the hook's JSON on stdin; nothing here needs it
  _inbox_hook_ready || return 0
  [ "$(inbox_count_undelivered "$INBOX_ROLE")" != "0" ] || return 0
  stamp="$(inbox_dir)/.stop.$INBOX_ROLE"
  last="$(/bin/cat "$stamp" 2>/dev/null || printf '0')"
  case "$last" in "" | *[!0-9]*) last=0 ;; esac
  [ $(($(now_epoch) - last)) -ge "$WOLFMUX_INBOX_STOP_COOLDOWN" ] || return 0
  # Asked here, after the two cheap answers, so tmux is read only when there is something
  # to hand over. Nothing is taken and the cooldown stamp is left alone: a pane nobody
  # watches any more gets today's answer at the very next turn end.
  if _inbox_stop_watched; then
    event_log inbox-stop-silent "$INBOX_ROLE" "$(inbox_count_undelivered "$INBOX_ROLE") notice(s) left for the next prompt (human-pane-typing=off: $INBOX_HUMAN_REASON)" 2>/dev/null || true
    return 0
  fi
  notices="$(inbox_take_undelivered "$INBOX_ROLE")"
  [ -n "$notices" ] || return 0
  now_epoch >"$stamp" 2>/dev/null || true
  if "$JQ_BIN" -n --arg reason "$(inbox_hook_body "$INBOX_IDENTITY" "$notices" "$(inbox_count_undelivered "$INBOX_ROLE")")" \
    '{decision: "block", reason: $reason}' 2>/dev/null; then
    event_log inbox-stop "$INBOX_ROLE" "blocked once with $(printf '%s\n' "$notices" | wc -l | tr -d ' ') notice(s)" 2>/dev/null || true
  else
    # The one path that reaches the agent failed after the lines were marked delivered.
    # Put them back, or they are lost for good: the next hook would see nothing to hand
    # over. The cooldown stamp stays, so this cannot become a loop either.
    if inbox_requeue "$INBOX_ROLE" "$notices"; then
      event_log inbox-stop-failed "$INBOX_ROLE" "jq failed; $(printf '%s\n' "$notices" | wc -l | tr -d ' ') notice(s) re-queued" 2>/dev/null || true
    else
      # Say what actually happened. Claiming a requeue that did not happen is how these
      # notices would be lost with a log line asserting they were saved (reviewer N1).
      event_log inbox-stop-failed "$INBOX_ROLE" "jq failed AND the re-queue failed; $(printf '%s\n' "$notices" | wc -l | tr -d ' ') notice(s) LOST" 2>/dev/null || true
    fi
  fi
  return 0
}

# _inbox_stop_watched — 0 when the Stop hook must keep quiet: the policy is off and a human
# is watching this agent's pane (inbox_keep_off_human_pane, the question every typed path
# asks). Fails CLOSED like that question: a pane or a session we cannot find reads as
# watched, and the notices wait for the next prompt rather than land on a human's screen.
#
# The pane and the session are the ones _inbox_hook_ready proved: this agent's own.
_inbox_stop_watched() {
  inbox_human_typing_off || return 1 # idle: today's answer, and no tmux read for it
  inbox_keep_off_human_pane "$INBOX_ROLE" "$INBOX_PANE"
}

# cmd_inbox_prompt — internal (`teamctl _inbox-prompt`): a Claude Code UserPromptSubmit
# hook. Claude Code adds such a hook's stdout to the model's context, so the notices
# reach the agent alongside whatever the human just said, and are marked delivered.
# No cooldown: this one only ever runs once per prompt (a human pressed Enter, or a /loop
# or scheduled wake-up fired, which Claude Code delivers as a prompt). Nothing of it is
# shown to the human, which is why the Stop hook leaves a watched pane's notices to it.
cmd_inbox_prompt() {
  local notices
  /bin/cat >/dev/null 2>&1 || true
  if ! _inbox_hook_ready; then
    if [ -n "$INBOX_NOT_HERE" ]; then inbox_not_you || true; fi
    return 0
  fi
  [ "$(inbox_count_undelivered "$INBOX_ROLE")" != "0" ] || return 0
  notices="$(inbox_take_undelivered "$INBOX_ROLE")"
  [ -n "$notices" ] || return 0
  if inbox_hook_body "$INBOX_IDENTITY" "$notices" "$(inbox_count_undelivered "$INBOX_ROLE")"; then
    event_log inbox-prompt "$INBOX_ROLE" "handed over $(printf '%s\n' "$notices" | wc -l | tr -d ' ') notice(s)" 2>/dev/null || true
  else
    if inbox_requeue "$INBOX_ROLE" "$notices"; then
      event_log inbox-prompt-failed "$INBOX_ROLE" "stdout failed; $(printf '%s\n' "$notices" | wc -l | tr -d ' ') notice(s) re-queued" 2>/dev/null || true
    else
      event_log inbox-prompt-failed "$INBOX_ROLE" "stdout failed AND the re-queue failed; $(printf '%s\n' "$notices" | wc -l | tr -d ' ') notice(s) LOST" 2>/dev/null || true
    fi
  fi
  return 0
}

# --- teamctl inbox ------------------------------------------------------------
# cmd_inbox — what the human reads, newest LAST, and what prefix N opens in a popup.
# Reading marks the notices not-new, which is what clears the badge; it does NOT touch
# whether the agent has had them, so a notice you read is still delivered to the agent,
# and one the agent has had still shows in your badge until you look.
cmd_inbox() {
  local role="" all=0 json=0 keep=0 roles shown=0 when kind state text seen stamp
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --all) all=1 ;;
      --json) json=1 ;;
      --keep) keep=1 ;;
      -*) die_usage "unknown option for inbox: $1" ;;
      *) role="$1" ;;
    esac
    shift
  done
  require_tools
  load_project
  if [ "$all" -eq 1 ]; then
    [ -z "$role" ] || die_usage "inbox: --all takes no role"
    roles="$(inbox_roles)"
  else
    [ -n "$role" ] || role="$WOLFMUX_LEAD_ROLE"
    known_role_name "$role" || die_usage "invalid role name: $role"
    roles="$role"
  fi
  if [ "$json" -eq 1 ]; then
    # The records go to jq as raw lines and jq builds the JSON: assembling it in awk
    # meant escaping the text by hand, and a role whose file held no usable line left a
    # stray comma that made the whole document invalid.
    for role in $roles; do
      [ -f "$(inbox_file "$role")" ] || continue
      LC_ALL=C /usr/bin/awk -F'\t' -v OFS='\t' -v role="$role" \
        'NF >= 4 { print role, $1, $2, $3, $4 }' "$(inbox_file "$role")" 2>/dev/null || true
    done | "$JQ_BIN" -R -s 'split("\n") | map(select(length > 0) | split("\t"))
      | map({role: .[0], epoch: ((.[1] | tonumber?) // 0), kind: .[2],
             new: (.[3][0:1] == "n"), delivered: (.[3][1:2] == "d"), text: (.[4] // "")})' 2>/dev/null ||
      printf '[]\n'
    shown=1
  else
    for role in $roles; do
      [ -f "$(inbox_file "$role")" ] || continue
      # A file that holds no usable record is not a role with notices: say nothing
      # rather than print an empty heading into the popup.
      [ "$(inbox_count_lines "$role")" != "0" ] || continue
      say ""
      say "$role  ($(inbox_count_new "$role") new, $(inbox_count_undelivered "$role") not yet given to the agent)"
      # A read loop rather than awk: this machine's awk has no strftime (it is the one
      # true awk, not gawk), and a human-facing list of at most 200 lines can afford a
      # `date` per line. An epoch we cannot format is printed as it stands.
      while IFS=$'\t' read -r when kind state text; do
        [ -n "$text" ] || continue
        if [ "${state:0:1}" = "n" ]; then seen="NEW"; else seen="read"; fi
        if [ "${state:1:1}" = "d" ]; then seen="$seen/agent"; fi
        stamp="$(date -r "$when" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$when")"
        printf '  %s  %-8s  %-10s  %s\n' "$stamp" "$kind" "$seen" "$text" 2>/dev/null || true
      done <"$(inbox_file "$role")"
      shown=1
    done
    if [ "$shown" -eq 0 ]; then
      say "no notices for ${roles% *}. (Tasks and messages are Beads: bd list --assignee \$BEADS_ACTOR --status open,in_progress,blocked --include-infra)"
    else
      say ""
      say "Tasks and messages themselves are Beads: bd show <id> · bd list --assignee <role> --status open,in_progress,blocked --include-infra"
    fi
  fi
  [ "$keep" -eq 1 ] && return 0
  for role in $roles; do inbox_mark_seen "$role" || true; done
  return 0
}

# --- the human's Beads messages (v1.20.0) -------------------------------------
# What the status-bar number counts and what prefix N opens. One small index per PROJECT
# (all its teams share one Beads, and there is one human), kept by the Beads hook and read
# by the badge, so the status line never runs bd:
#
#   $WOLFMUX_DATA/state/<project>/human-inbox
#   <id> US <sender> US <subject> US <created, epoch>        newest first, US = \037
#
# The unit separator, not a tab: `read` with a whitespace IFS collapses an empty field (a
# message with no sender) and shifts the rest one place left. Every write replaces the
# whole file, temp file then mv, under a mkdir lock, so a reader sees the old list or the
# new one and never half of either. The index is a cache: the popup puts it right with ONE
# targeted bd call every time it opens, so a hook that did not run costs a stale number
# until then, not a wrong one for ever.
_HI_US=$'\037'

human_inbox_file() { printf '%s\n' "$PROJECT_STATE/human-inbox"; }
human_inbox_lock() { [ -d "$PROJECT_STATE" ] && _inbox_lock_dir "$PROJECT_STATE/.human-inbox.lock"; }
human_inbox_unlock() { /bin/rm -rf "$PROJECT_STATE/.human-inbox.lock" 2>/dev/null || true; }

# A bead as one index row. Control characters, the separator among them, become spaces;
# a time jq cannot read becomes 0, which the popup shows as an unknown age.
_HUMAN_ROW_JQ='def row: [(.id // ""), (.created_by // ""), ((.title // "") | tostring | .[0:300]),
    ((.created_at // "") | tostring | sub("\\.[0-9]+"; "") | (try fromdateiso8601 catch 0) | floor)]
  | map(tostring | gsub("[[:cntrl:]]"; " ")) | join("\u001f");'

# human_inbox_count — rows in the index; 0 on anything unexpected (it feeds the badge)
human_inbox_count() {
  local file
  file="$(human_inbox_file)"
  [ -f "$file" ] || {
    printf '0\n'
    return 0
  }
  LC_ALL=C /usr/bin/awk -F"$_HI_US" 'NF >= 4 && $1 != "" { n++ } END { print n + 0 }' "$file" 2>/dev/null ||
    printf '0\n'
}

# _human_inbox_write <rows> — the one writer: <rows> become the whole index, newest first
_human_inbox_write() {
  local file tmp rc=0
  file="$(human_inbox_file)"
  tmp="$PROJECT_STATE/.human-inbox.tmp.$$"
  { [ -z "$1" ] || printf '%s\n' "$1"; } |
    LC_ALL=C /usr/bin/awk -F"$_HI_US" 'NF >= 4 && $1 != ""' |
    LC_ALL=C sort -t "$_HI_US" -k4,4nr >"$tmp" 2>/dev/null &&
    /bin/mv -f "$tmp" "$file" 2>/dev/null || rc=1
  /bin/rm -f "$tmp" 2>/dev/null || true
  return "$rc"
}

# human_inbox_edit <row> <id>... — drop the rows of these ids, then add <row> if it is not
# empty. 1 when the lock could not be had or the write failed; the file is then untouched.
human_inbox_edit() {
  local row="$1" file kept rc=0
  shift
  file="$(human_inbox_file)"
  # Only rows to drop, and the file holds none of them: no lock, no write. The common case
  # is a message between two agents being closed, which is none of the human's business.
  if [ -z "$row" ] && [ "$#" -eq 1 ] && ! /usr/bin/grep -qF "$1" "$file" 2>/dev/null; then return 0; fi
  human_inbox_lock || return 1
  if [ -f "$file" ]; then
    kept="$(WM_IDS=" $* " LC_ALL=C /usr/bin/awk -F"$_HI_US" \
      'NF >= 4 && index(ENVIRON["WM_IDS"], " " $1 " ") == 0' "$file" 2>/dev/null)" || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    _human_inbox_write "$(printf '%s\n%s' "${kept:-}" "$row")" || rc=1
  fi
  human_inbox_unlock
  return "$rc"
}

# human_inbox_reconcile — put the index right from Beads with ONE targeted call. 1 when bd
# is missing, fails, or answers with something that is not a list; the index is then left
# as it was, because an error must not read as "no messages".
human_inbox_reconcile() {
  local json rows rc=0
  [ -n "$BD_BIN" ] && [ -n "$JQ_BIN" ] || return 1
  json="$(cd "$ROOT" && "$BD_BIN" list --assignee "$WOLFMUX_HUMAN" --type message --status open --limit 0 --json 2>/dev/null)" || return 1
  rows="$(printf '%s' "$json" | "$JQ_BIN" -r "$_HUMAN_ROW_JQ"' if type == "array" then .[] | row else error("not a list") end' 2>/dev/null)" || return 1
  human_inbox_lock || return 1
  _human_inbox_write "$rows" || rc=1
  human_inbox_unlock
  return "$rc"
}

# cmd_human_inbox_hook — internal (`teamctl _human-inbox-hook`), run in the background by
# hooks/beads-nudge for every message bead it sees, with the bead's JSON on stdin. An open
# message for the human is added (or refreshed); anything else with that id — closed, or
# handed to somebody else — is dropped. Silent and always 0: it runs under a bd command.
cmd_human_inbox_hook() {
  local payload
  payload="$(/bin/cat 2>/dev/null)" || payload=""
  (
    set +e
    _human_inbox_hook "$payload"
  ) >/dev/null 2>&1 || true
  return 0
}

_human_inbox_hook() {
  local payload="$1" fields id assignee type status row
  [ -n "$payload" ] && [ -n "$JQ_BIN" ] || return 0
  ROOT="$(resolve_root 2>/dev/null)" || return 0
  PROJECT_KEY="$(project_key "$ROOT")" || return 0
  PROJECT_STATE="$WOLFMUX_DATA/state/$PROJECT_KEY"
  [ -d "$PROJECT_STATE" ] || return 0 # not a project wolfmux runs a team in
  fields="$(printf '%s' "$payload" | "$JQ_BIN" -r \
    '[.id // "", .assignee // "", .issue_type // "", .status // ""] | map(tostring) | join("\u001f")' 2>/dev/null)" || return 0
  IFS="$_HI_US" read -r id assignee type status <<EOF
$fields
EOF
  valid_bead_id "$id" || return 0
  [ "$type" = "message" ] || return 0
  if [ "$assignee" = "$WOLFMUX_HUMAN" ] && [ "$status" = "open" ]; then
    row="$(printf '%s' "$payload" | "$JQ_BIN" -r "$_HUMAN_ROW_JQ"' row' 2>/dev/null)" || return 0
    [ -n "$row" ] || return 0
    human_inbox_edit "$row" "$id"
  else
    human_inbox_edit "" "$id"
  fi
}

# --- the popup -----------------------------------------------------------------
# cmd_popup — internal (`teamctl _popup <socket> <client> <dir> <height> <command>...`):
# opens `teamctl <command>...` in a popup on one client of one server. What prefix N,
# prefix O and a click on the 📨 number run, through `run-shell -b` (tmux.conf, "popups"):
# tmux 3.7c does not expand formats in display-popup's shell-command, so a binding that
# put them there ran `"#{?@wolfmux_teamctl,…}"` as a program and closed at once (v1.20.1).
# run-shell expands them; this passes the values on as tmux argv, so neither a shell nor
# a format stands between them and the command.
#   <dir>     the popup's working directory; "" leaves it to tmux
#   <height>  of the popup, 70% or a number of lines; the width is always 90%
# teamctl takes --team off the command line before any command sees it; it is put back on
# the popup's command here.
cmd_popup() {
  local socket="${1:-}" client="${2:-}" dir="${3:-}" height="${4:-}" args
  [ "$#" -ge 5 ] && [ -n "$socket" ] || die_usage "usage: teamctl _popup <socket> <client> <dir> <height> <command>..."
  case "$height" in "" | *[!0-9%]*) die_usage "_popup: the height is a number or a percentage, not '$height'" ;; esac
  shift 4
  [ -n "$TMUX_BIN" ] || die "tmux not found (run: teamctl doctor)"
  args=(display-popup -E -w 90% -h "$height")
  [ -z "$client" ] || args+=(-c "$client")
  [ -z "$dir" ] || args+=(-d "$dir")
  args+=("$TEAMCTL_SELF")
  [ -z "${WOLFMUX_TEAM_ARG:-}" ] || args+=(--team "$WOLFMUX_TEAM_ARG")
  exec "$TMUX_BIN" -S "$socket" "${args[@]}" "$@"
}

# cmd_human_inbox — internal (`teamctl _human-inbox`): what prefix N and a click on the
# status-bar number open. It draws the index at once, then makes its ONE bd call, rewrites
# the index and draws again. Plain bash and tput: this machine has no fzf.
#   up/down (or k/j) or a digit   select          Enter   the message, in less
#   r   mark the selected one read                a       mark them all read, after y/n
#   q or Esc   close
# A mark-read runs as the human (BEADS_ACTOR=$WOLFMUX_HUMAN): bd refuses to close a bead
# assigned to somebody other than the actor. --print skips the screen and the keys and
# prints the refreshed list, for scripts and tests.
#
# v1.20.1. On Ammar's iTerm2 the popup closed the moment it opened ("it just flickers"),
# while it stayed open on a nested tmux client, and nothing said why. What differs is the
# client terminal: iTerm2 gets focus reports and extended keys, and a terminal's reports
# and replies can reach the program in a popup. The popup was reading one byte at a time,
# so any of those bytes could be taken for q, Esc, r or a. Three things answer it:
#   · the log, $PROJECT_STATE/human-inbox-popup.log: each popup's start, every group of
#     input bytes in hex with what it was taken as, and why it closed (_hi_log)
#   · input is read as whole groups and whole escape sequences (_hi_take, _hi_parse): a
#     focus report, a key release or a terminal's reply is ignored as a whole
#   · a close that is not q or Esc says why on screen and waits for a key (_hi_end), even
#     one before the list is drawn: -E closes a popup the instant its command exits
cmd_human_inbox() {
  local print=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --print) print=1 ;;
      *) die_usage "unknown option for _human-inbox: $1" ;;
    esac
    shift
  done
  if [ "$print" -eq 0 ]; then
    # Until the project is known the log is the machine's; a die in load_project is logged
    # and shown there (_hi_on_exit).
    HI_T0="$SECONDS" HI_ENDED="" HI_LOG=""
    [ ! -d "$WOLFMUX_DATA/state" ] || HI_LOG="$WOLFMUX_DATA/state/human-inbox-popup.log"
    trap '_hi_on_exit main' EXIT
  fi
  require_tools
  load_project any
  if [ "$print" -eq 1 ]; then
    human_inbox_reconcile || warn "could not refresh from Beads; this is the list as last seen"
    (
      set +eu
      _hi_load
      _hi_print_plain
    )
    return 0
  fi
  HI_LOG=""
  [ ! -d "$PROJECT_STATE" ] || HI_LOG="$PROJECT_STATE/human-inbox-popup.log"
  (
    # A subshell does not inherit the trap; its own catches a crash inside the loop.
    trap '_hi_on_exit ui' EXIT
    set +eu
    _hi_ui
  ) || true
  HI_ENDED=1
  trap 'teamctl_on_exit' EXIT
  return 0
}

# _hi_on_exit main|ui — the popup's EXIT trap. An end that _hi_end did not already explain
# (a die before the list was drawn, a crash in the loop) is explained here, and held. A
# hangup or a TERM is tmux closing the popup: there is nobody left to tell. main also does
# teamctl's own exit work, which this trap replaced.
_hi_on_exit() {
  local rc=$?
  set +eu
  if [ -z "$HI_ENDED" ]; then
    case "$rc" in
      129 | 143) _hi_end "signal $((rc - 128))" quiet ;;
      130) _hi_end "key Ctrl-C" key ;;
      *) _hi_end "teamctl stopped (exit $rc)" error ;;
    esac
  fi
  if [ "$1" = main ]; then
    (exit "$rc")
    teamctl_on_exit
  fi
}

# _hi_load — the index into HI_ID HI_FROM HI_SUBJ HI_AT, HI_N rows
_hi_load() {
  local file id from subj at
  HI_ID=() HI_FROM=() HI_SUBJ=() HI_AT=() HI_N=0
  file="$(human_inbox_file)"
  [ -f "$file" ] || return 0
  while IFS="$_HI_US" read -r id from subj at; do
    [ -n "$id" ] || continue
    HI_ID[HI_N]="$id" HI_FROM[HI_N]="$from" HI_SUBJ[HI_N]="$subj" HI_AT[HI_N]="$at"
    HI_N=$((HI_N + 1))
  done <"$file"
}

# _hi_age <epoch> <now> — 5m, 2h, 3d; "now" under a minute; "?" when unknown
_hi_age() {
  local d
  case "$1" in "" | 0 | *[!0-9]*)
    printf '?'
    return 0
    ;;
  esac
  d=$(($2 - $1))
  if [ "$d" -lt 60 ]; then
    printf 'now'
  elif [ "$d" -lt 3600 ]; then
    printf '%dm' $((d / 60))
  elif [ "$d" -lt 86400 ]; then
    printf '%dh' $((d / 3600))
  else
    printf '%dd' $((d / 86400))
  fi
}

# _hi_fit <text> <width> — cut to <width> characters and pad to it. By characters, not
# bytes: printf's %-*s counts bytes, so a subject with an accent would push the age column.
_hi_fit() {
  local text="$1" width="$2"
  if [ "${#text}" -gt "$width" ]; then text="${text:0:$((width - 1))}…"; fi
  printf '%s%*s' "$text" $((width - ${#text})) ''
}

_hi_print_plain() {
  local i=0 now
  now="$(now_epoch)"
  if [ "$HI_N" -eq 0 ]; then
    say "no unread messages for $WOLFMUX_HUMAN"
    return 0
  fi
  while [ "$i" -lt "$HI_N" ]; do
    printf '%3d  %s  %s  %s  %s\n' $((i + 1)) "${HI_ID[i]}" "${HI_FROM[i]}" "${HI_SUBJ[i]}" \
      "$(_hi_age "${HI_AT[i]}" "$now")" 2>/dev/null || true
    i=$((i + 1))
  done
}

# _hi_size — the popup's size into HI_LINES and HI_COLS. stty asks the terminal on stdin;
# tput inside $( ) has a pipe for stdout and said 80x24 whatever the popup's size (a
# 120-column popup drew 80 columns, seen in the v1.20.1 log). tput is the fallback.
_hi_size() {
  local s
  s="$(/bin/stty size 2>/dev/null)" || s=""
  # shellcheck disable=SC2086
  set -- $s
  if [ "$#" -eq 2 ] && [ "$1" -gt 0 ] 2>/dev/null && [ "$2" -gt 0 ] 2>/dev/null; then
    HI_LINES="$1" HI_COLS="$2"
    return 0
  fi
  HI_COLS="$(tput cols 2>/dev/null)" HI_LINES="$(tput lines 2>/dev/null)"
}

_hi_draw() {
  local cols lines rows width i now
  _hi_size
  cols="$HI_COLS" lines="$HI_LINES"
  case "$cols" in "" | *[!0-9]*) cols=80 ;; esac
  case "$lines" in "" | *[!0-9]*) lines=24 ;; esac
  rows=$((lines - 6))
  [ "$rows" -ge 1 ] || rows=1
  [ "$HI_SEL" -lt "$HI_N" ] || HI_SEL=$((HI_N - 1))
  [ "$HI_SEL" -ge 0 ] || HI_SEL=0
  [ "$HI_SEL" -ge "$HI_TOP" ] || HI_TOP="$HI_SEL"
  [ "$HI_SEL" -lt $((HI_TOP + rows)) ] || HI_TOP=$((HI_SEL - rows + 1))
  # number 3, sender 20, age 4, and the gaps between them; the subject gets the rest
  width=$((cols - 36))
  [ "$width" -ge 10 ] || width=10
  now="$(now_epoch)"
  printf '%s' "$HI_CLEAR"
  printf ' %s%s messages for %s%s  (%s unread)\n\n' "$HI_BOLD" "$WOLFMUX_INBOX_MARK" "$WOLFMUX_HUMAN" "$HI_OFF" "$HI_N"
  [ "$HI_N" -gt 0 ] || printf '   No unread messages.\n'
  i="$HI_TOP"
  while [ "$i" -lt "$HI_N" ] && [ "$i" -lt $((HI_TOP + rows)) ]; do
    [ "$i" -ne "$HI_SEL" ] || printf '%s' "$HI_REV"
    printf '%3d  %s  %s  %4s' $((i + 1)) "$(_hi_fit "${HI_FROM[i]:-?}" 20)" "$(_hi_fit "${HI_SUBJ[i]}" "$width")" \
      "$(_hi_age "${HI_AT[i]}" "$now")"
    printf '%s\n' "$HI_OFF"
    i=$((i + 1))
  done
  printf '\n %s↑↓ or 1-9 select · Enter open · r mark read · a mark all read · q close%s\n' "$HI_DIM" "$HI_OFF"
  [ -z "$HI_STATUS" ] || printf ' %s' "$HI_STATUS"
}

# _hi_close <id>... — mark read in Beads, as the human; bd's first line on failure
_hi_close() {
  local out
  if out="$(cd "$ROOT" && BEADS_ACTOR="$WOLFMUX_HUMAN" "$BD_BIN" close "$@" -r read 2>&1)"; then
    human_inbox_edit "" "$@" || true
    _hi_load
    return 0
  fi
  HI_STATUS="bd close failed: $(printf '%s\n' "$out" | head -1)"
  return 1
}

# --- the popup's log (v1.20.1) -------------------------------------------------------------
# One line per event, so the next "it flickers" comes with its cause:
#   2026-10-16T05:40:01Z [4242] start: v1.20.1 team=communication-management TERM=tmux-256color tty=/dev/ttys012 size=122x38 stdin-tty=yes stdout-tty=yes
#   2026-10-16T05:40:01Z [4242] in 1b 5b 49 = focus in -> dropped at start
#   2026-10-16T05:40:03Z [4242] in 1b 5b 42 = down -> select 2
#   2026-10-16T05:40:03Z [4242] in 1b 5b 3f 36 32 3b 34 63 = terminal reply CSI ?62;4c -> ignored
#   2026-10-16T05:40:04Z [4242] in 71 = q -> close
#   2026-10-16T05:40:04Z [4242] exit: key q (after 3s)
# The number in brackets tells one popup's lines from another's. Kept to its last 150 lines
# once it passes 200. Writing it can never stop the popup: every failure is swallowed, the
# failure to open the file included (2>/dev/null comes first so that it covers the >>).
_hi_log() {
  [ -n "${HI_LOG:-}" ] || return 0
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$$" "$*" 2>/dev/null >>"$HI_LOG" || true
}

_hi_log_trim() {
  local n
  [ -n "${HI_LOG:-}" ] && [ -f "$HI_LOG" ] || return 0
  n="$(/usr/bin/wc -l <"$HI_LOG" 2>/dev/null)" || return 0
  n="${n//[!0-9]/}"
  [ -n "$n" ] && [ "$n" -gt 200 ] || return 0
  /usr/bin/tail -n 150 "$HI_LOG" 2>/dev/null >"$HI_LOG.tmp.$$" && /bin/mv -f "$HI_LOG.tmp.$$" "$HI_LOG" 2>/dev/null
  /bin/rm -f "$HI_LOG.tmp.$$" 2>/dev/null
  return 0
}

# _hi_log_in <what it did> — the group just read, what it was taken as, what came of it
_hi_log_in() {
  local w s=""
  for w in "${HI_WHY[@]}"; do s="${s:+$s, }$w"; done
  _hi_log "in $HI_HEX = ${s:-nothing} -> $1"
}

# --- the popup's input (v1.20.1) -----------------------------------------------------------
# Input is read in GROUPS: the bytes that arrive together (a terminal tty in non-canonical
# mode with VMIN 1 and VTIME 1 hands over the first byte and whatever follows it within
# 0.1 s). A key is one group; a terminal's reply or report is one group too, so it can be
# recognised and dropped whole. Bytes travel as two-digit hex, which bash can hold whatever
# they are: a NUL, a newline or half a sequence included.
#
# Not a terminal (a pipe: the tests' printf 'jrq' | …) there is no "arrived together" to go
# by, so a group is one byte, which is how a pipe was read before.

_hi_tty_raw() {
  HI_STTY=""
  [ "$HI_TTY" -eq 1 ] || return 0
  if HI_STTY="$(/bin/stty -g 2>/dev/null)" && /bin/stty -icanon -echo -isig -ixon min 1 time 1 2>/dev/null; then
    return 0
  fi
  _hi_log "stty failed: reading the terminal one byte at a time"
  HI_STTY="" HI_TTY=0
}

_hi_tty_restore() {
  [ -z "${HI_STTY:-}" ] || /bin/stty "$HI_STTY" 2>/dev/null
  tput cnorm 2>/dev/null
  return 0
}

# _hi_dd <bytes> — one read(2) of at most <bytes> from stdin, as hex, into HI_HEX
_hi_dd() {
  local h
  h="$(/bin/dd bs="$1" count=1 2>/dev/null | /usr/bin/od -An -v -tx1 2>/dev/null)"
  # shellcheck disable=SC2086 # split into the hex words on purpose
  set -- $h
  HI_HEX="$*"
}

# _hi_read wait|more|drain — one group into HI_HEX. wait: until a byte comes (nothing then
# means input has ended). more: what comes within 0.3 s, maybe nothing. drain: what is
# already there, without waiting. 1 when nothing was read.
_hi_read() {
  local all="" n=0
  HI_HEX=""
  if [ "$HI_TTY" -eq 1 ]; then
    case "$1" in
      wait) _hi_dd 1024 ;;
      more)
        /bin/stty min 0 time 3 2>/dev/null
        _hi_dd 1024
        /bin/stty min 1 time 1 2>/dev/null
        ;;
      drain)
        /bin/stty min 0 time 0 2>/dev/null
        while [ "$n" -lt 64 ]; do
          _hi_dd 1024
          [ -n "$HI_HEX" ] || break
          all="${all:+$all }$HI_HEX"
          n=$((n + 1))
        done
        /bin/stty min 1 time 1 2>/dev/null
        HI_HEX="$all"
        ;;
    esac
  elif [ "$1" != drain ]; then
    _hi_dd 1
  fi
  [ -n "$HI_HEX" ]
}

# _hi_take — the next group, whole. A group that stops inside an escape sequence, or on a
# lone Esc, gets up to three more reads of 0.3 s each before it is taken as it is: tmux
# writes a sequence it forwards in one go, but a slow link may not. Parsed: HI_TOK, HI_WHY.
# 1 when input has ended.
_hi_take() {
  local all tries=0
  _hi_read wait || return 1
  all="$HI_HEX"
  # shellcheck disable=SC2086
  _hi_parse $all
  while [ "$HI_PARTIAL" -eq 1 ] && [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    _hi_read more || break
    all="$all $HI_HEX"
    # shellcheck disable=SC2086
    _hi_parse $all
  done
  HI_HEX="$all"
  return 0
}

# _hi_drain <when> — drop what is already waiting, and log it: bytes that arrived before
# the list was on screen were not typed at it.
_hi_drain() {
  _hi_read drain || return 0
  # shellcheck disable=SC2086
  _hi_parse $HI_HEX
  _hi_log_in "dropped $1"
}

# The printable ASCII characters, 32 to 126, for turning a byte into its character without
# a subshell.
_HI_ASCII=" !\"#\$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_\`abcdefghijklmnopqrstuvwxyz{|}~"

# _hi_unit <token> <description> — one unit of the group parsed
_hi_unit() {
  HI_TOK[${#HI_TOK[@]}]="$1"
  HI_WHY[${#HI_WHY[@]}]="$2"
}

# _hi_parse <hex byte>... — the key parser. Cuts one group into units, a whole escape
# sequence being one unit, and gives each a token (HI_TOK) and a description for the log
# (HI_WHY). The tokens:
#   up down enter esc ctrl-c char:<c> ignore
# Escape sequences are read to their end: CSI to its final byte (0x40-0x7E), SS3 as
# ESC O and one byte, OSC, DCS, APC, PM and SOS to BEL or ESC \. Of those, arrows (any
# form, any modifier), CSI-u keys (ESC[113u) and xterm modifyOtherKeys keys (ESC[27;1;113~)
# are keys; focus reports, key releases, mouse reports and every reply a terminal sends are
# not. HI_PARTIAL=1 when the group ends inside a sequence or on a lone ESC: the caller
# reads on and asks again, and takes the best guess given here if nothing more comes.
_hi_parse() {
  local n=$# i=0 j c d p e kind
  local -a b
  HI_TOK=() HI_WHY=() HI_PARTIAL=0
  for c in "$@"; do b[${#b[@]}]=$((16#$c)); done
  while [ "$i" -lt "$n" ]; do
    c="${b[i]}"
    if [ "$c" -ne 27 ]; then
      i=$((i + 1))
      if [ "$c" -eq 13 ] || [ "$c" -eq 10 ]; then
        _hi_unit enter Enter
      elif [ "$c" -eq 3 ]; then
        _hi_unit ctrl-c Ctrl-C
      elif [ "$c" -ge 32 ] && [ "$c" -le 126 ]; then
        p="${_HI_ASCII:$((c - 32)):1}"
        _hi_unit "char:$p" "$p"
      elif [ "$c" -eq 127 ] || [ "$c" -eq 8 ]; then
        _hi_unit ignore Backspace
      elif [ "$c" -lt 32 ]; then
        _hi_unit ignore "control byte $c"
      else
        # a UTF-8 character: its lead byte and continuation bytes are one unit
        while [ "$i" -lt "$n" ] && [ "${b[i]}" -ge 128 ] && [ "${b[i]}" -lt 192 ]; do i=$((i + 1)); done
        _hi_unit ignore "non-ASCII"
      fi
      continue
    fi
    if [ $((i + 1)) -ge "$n" ]; then
      HI_PARTIAL=1
      _hi_unit esc Esc
      i=$((i + 1))
      continue
    fi
    d="${b[i + 1]}"
    case "$d" in
      91) # CSI: parameter bytes, intermediate bytes, one final byte
        p="" j=$((i + 2))
        while [ "$j" -lt "$n" ] && [ "${b[j]}" -ge 48 ] && [ "${b[j]}" -le 63 ]; do
          p="$p${_HI_ASCII:$((b[j] - 32)):1}"
          j=$((j + 1))
        done
        while [ "$j" -lt "$n" ] && [ "${b[j]}" -ge 32 ] && [ "${b[j]}" -le 47 ]; do
          p="$p${_HI_ASCII:$((b[j] - 32)):1}"
          j=$((j + 1))
        done
        if [ "$j" -ge "$n" ]; then
          HI_PARTIAL=1
          _hi_unit ignore "incomplete CSI $p"
          i="$n"
        elif [ "${b[j]}" -ge 64 ] && [ "${b[j]}" -le 126 ]; then
          _hi_csi "$p" "${_HI_ASCII:$((b[j] - 32)):1}"
          i=$((j + 1))
        else
          _hi_unit ignore "broken CSI $p"
          i="$j"
        fi
        ;;
      79) # SS3: ESC O and one byte
        if [ $((i + 2)) -ge "$n" ]; then
          HI_PARTIAL=1
          _hi_unit ignore "incomplete SS3"
          i="$n"
        else
          case "${b[i + 2]}" in
            65) _hi_unit up "SS3 up" ;;
            66) _hi_unit down "SS3 down" ;;
            77) _hi_unit enter "SS3 Enter" ;;
            *) _hi_unit ignore "SS3 key" ;;
          esac
          i=$((i + 3))
        fi
        ;;
      93 | 80 | 95 | 94 | 88) # OSC ] DCS P APC _ PM ^ SOS X: a string, to BEL or ST (ESC \)
        case "$d" in 93) kind=OSC ;; 80) kind=DCS ;; 95) kind=APC ;; 94) kind=PM ;; *) kind=SOS ;; esac
        j=$((i + 2)) e=""
        while [ "$j" -lt "$n" ]; do
          if [ "${b[j]}" -eq 7 ]; then
            e=$((j + 1))
            break
          fi
          if [ "${b[j]}" -eq 27 ]; then
            if [ $((j + 1)) -ge "$n" ]; then break; fi # ESC \ cut in two: read on
            if [ "${b[j + 1]}" -eq 92 ]; then e=$((j + 2)); else e="$j"; fi
            break
          fi
          j=$((j + 1))
        done
        if [ -z "$e" ]; then
          HI_PARTIAL=1
          _hi_unit ignore "incomplete $kind string"
          i="$n"
        else
          _hi_unit ignore "$kind string (a terminal's reply)"
          i="$e"
        fi
        ;;
      27) # ESC ESC: the first one is an Esc key of its own
        _hi_unit esc Esc
        i=$((i + 1))
        ;;
      *)
        _hi_unit ignore "Alt+key"
        i=$((i + 2))
        ;;
    esac
  done
}

# _hi_csi <parameter and intermediate bytes> <final byte> — one whole CSI sequence
_hi_csi() {
  local p="$1" f="$2" code mods ev rest
  case "$p" in
    '<'*)
      _hi_unit ignore "mouse report"
      return
      ;;
    '?'* | '>'* | '='*)
      # a private parameter: device attributes (c), mode and status reports (y, n),
      # keyboard-protocol flags (u). Every one is a terminal answering, never a key.
      _hi_unit ignore "terminal reply CSI $p$f"
      return
      ;;
  esac
  case "$f" in
    I | O)
      if [ -z "$p" ]; then
        if [ "$f" = I ]; then _hi_unit ignore "focus in"; else _hi_unit ignore "focus out"; fi
        return
      fi
      ;;
    A | B)
      case "$p" in
        "" | 1 | "1;"*)
          if [ "$f" = A ]; then _hi_unit up up; else _hi_unit down down; fi
          return
          ;;
      esac
      ;;
    u)
      # CSI-u: code[:alternates] ; modifiers[:event] ; text
      code="${p%%;*}" rest=""
      case "$p" in *";"*) rest="${p#*;}" ;; esac
      mods="${rest%%;*}" ev=1
      case "$mods" in *:*)
        ev="${mods#*:}"
        mods="${mods%%:*}"
        ;;
      esac
      _hi_csi_key "${code%%:*}" "${mods:-1}" "$ev" "CSI-u"
      return
      ;;
    '~')
      case "$p" in
        "27;"*";"*)
          # xterm modifyOtherKeys: 27 ; modifiers ; code
          rest="${p#27;}"
          mods="${rest%%;*}" code="${rest#*;}"
          _hi_csi_key "${code%%;*}" "$mods" 1 "modifyOtherKeys"
          return
          ;;
      esac
      _hi_unit ignore "function key CSI $p~"
      return
      ;;
  esac
  _hi_unit ignore "CSI $p$f"
}

# _hi_csi_key <code> <modifiers> <event> <form> — a key that came as CSI-u or
# modifyOtherKeys. A release (event 3) is not a key press. Shift, Caps Lock and Num Lock
# do not make another key of it; any other modifier does, and that key is not ours, save
# Ctrl-C.
_hi_csi_key() {
  local code="$1" mods="$2" ev="$3" form="$4" m c
  for c in "$code" "$mods" "$ev"; do
    case "$c" in "" | *[!0-9]* | ?????????*)
      _hi_unit ignore "$form, unreadable"
      return
      ;;
    esac
  done
  if [ "$ev" -eq 3 ]; then
    _hi_unit ignore "$form key release"
    return
  fi
  m=$(((mods - 1) & ~(1 | 64 | 128)))
  if [ "$code" -eq 99 ] && [ "$m" -eq 4 ]; then
    _hi_unit ctrl-c "$form Ctrl-C"
    return
  fi
  if [ "$m" -ne 0 ]; then
    _hi_unit ignore "$form key $code with modifiers $mods"
    return
  fi
  case "$code" in
    13) _hi_unit enter "$form Enter" ;;
    27) _hi_unit esc "$form Esc" ;;
    *)
      if [ "$code" -ge 32 ] && [ "$code" -le 126 ]; then
        # Shift on a letter: the capital
        if [ $(((mods - 1) & 1)) -eq 1 ] && [ "$code" -ge 97 ] && [ "$code" -le 122 ]; then code=$((code - 32)); fi
        c="${_HI_ASCII:$((code - 32)):1}"
        _hi_unit "char:$c" "$form $c"
      else
        _hi_unit ignore "$form key $code"
      fi
      ;;
  esac
}

# --- the popup's keys --------------------------------------------------------------------
# _hi_act — what the group just parsed does. Moving counts wherever it is in a group. q and
# Esc close only when the group holds nothing else, and r, a and Enter count only as the
# ONE unit of their group: a letter that arrives glued to other bytes is far likelier part
# of something a terminal sent than a key somebody pressed. HI_DID says what came of it;
# 1 when the popup is to close (HI_CLOSE: key, or eof when input ended at the y/n question).
_hi_act() {
  local m=${#HI_TOK[@]} t closers=0 moved=0 alone=0
  HI_DID="ignored"
  [ "$m" -gt 0 ] || return 0
  for t in "${HI_TOK[@]}"; do
    case "$t" in
      esc | ctrl-c | char:q | char:Q) closers=$((closers + 1)) ;;
      enter | char:r | char:R | char:a | char:A) alone=1 ;;
    esac
  done
  if [ "$closers" -eq "$m" ]; then
    HI_DID="close" HI_CLOSE=key HI_CLOSE_KEY="${HI_WHY[0]}"
    return 1
  fi
  if [ "$m" -eq 1 ]; then
    case "${HI_TOK[0]}" in
      char:r | char:R)
        _hi_mark_one
        return 0
        ;;
      char:a | char:A)
        _hi_mark_all
        return
        ;;
      enter)
        _hi_open
        return 0
        ;;
    esac
  fi
  for t in "${HI_TOK[@]}"; do
    case "$t" in
      up | char:k) HI_SEL=$((HI_SEL - 1)) moved=1 ;;
      down | char:j) HI_SEL=$((HI_SEL + 1)) moved=1 ;;
      char:[1-9]) if [ "${t#char:}" -le "$HI_N" ]; then HI_SEL=$((${t#char:} - 1)) moved=1; fi ;;
    esac
  done
  [ "$HI_SEL" -lt "$HI_N" ] || HI_SEL=$((HI_N - 1))
  [ "$HI_SEL" -ge 0 ] || HI_SEL=0
  if [ "$moved" -eq 1 ]; then
    HI_DID="select $((HI_SEL + 1))"
  elif [ "$closers" -gt 0 ] || [ "$alone" -eq 1 ]; then
    HI_DID="ignored (q, Esc, r, a and Enter count only on their own)"
  fi
  return 0
}

_hi_mark_one() {
  local id
  [ "$HI_N" -gt 0 ] || {
    HI_DID="nothing to mark"
    return 0
  }
  id="${HI_ID[HI_SEL]}"
  if _hi_close "$id"; then
    HI_STATUS="marked read" HI_DID="marked $id read"
  else
    HI_DID="$HI_STATUS"
  fi
}

# _hi_mark_all — asks y/n. Groups with nothing but ignored units in them (a focus report)
# are no answer; the first group with anything else is, and only a lone y is a yes.
_hi_mark_all() {
  local t real
  [ "$HI_N" -gt 0 ] || {
    HI_DID="nothing to mark"
    return 0
  }
  _hi_log_in "asks y/n"
  HI_LOGGED=1
  HI_STATUS="Mark all $HI_N read? [y/n] "
  _hi_draw
  HI_STATUS=""
  while :; do
    if ! _hi_take; then
      HI_CLOSE=eof
      _hi_log "input ended at the y/n question"
      return 1
    fi
    real=0
    for t in "${HI_TOK[@]}"; do [ "$t" = ignore ] || real=1; done
    [ "$real" -eq 0 ] || break
    _hi_log_in "ignored (still asking y/n)"
  done
  if [ "${#HI_TOK[@]}" -eq 1 ] && { [ "${HI_TOK[0]}" = char:y ] || [ "${HI_TOK[0]}" = char:Y ]; }; then
    if _hi_close "${HI_ID[@]}"; then
      HI_STATUS="marked all read"
      _hi_log_in "marked all read"
    else
      _hi_log_in "$HI_STATUS"
    fi
  else
    _hi_log_in "no: nothing marked"
  fi
  return 0
}

_hi_open() {
  [ "$HI_N" -gt 0 ] || return 0
  if [ -z "$BD_BIN" ]; then
    HI_STATUS="bd is not installed" HI_DID="bd is not installed"
    return 0
  fi
  HI_DID="opened ${HI_ID[HI_SEL]}"
  # less wants the terminal as it was, and gives it back that way
  [ -z "${HI_STTY:-}" ] || /bin/stty "$HI_STTY" 2>/dev/null
  tput cnorm 2>/dev/null
  (cd "$ROOT" && "$BD_BIN" show "${HI_ID[HI_SEL]}" 2>&1) | less -R
  tput civis 2>/dev/null
  [ -z "${HI_STTY:-}" ] || /bin/stty -icanon -echo -isig -ixon min 1 time 1 2>/dev/null
  return 0
}

# _hi_end <reason> key|quiet|eof|error — the one way the popup ends. A key (q, Esc) or a
# signal (tmux closing it) ends it at once. Anything else is not something the human did,
# so it says why on screen and holds (_hi_hold), and a popup that "flickers" becomes one
# that says what happened.
_hi_end() {
  HI_ENDED=1
  _hi_log "exit: $1 (after $((SECONDS - ${HI_T0:-$SECONDS}))s)"
  case "$2" in
    key | quiet) ;;
    *) [ ! -t 1 ] || _hi_hold "$1" "$2" ;;
  esac
  _hi_tty_restore
}

# _hi_hold <reason> <kind> — the reason, then up to WOLFMUX_HI_HOLD (10) seconds for a key.
# Input that has ended is not read again (every read would return at once): it waits.
_hi_hold() {
  local hold="${WOLFMUX_HI_HOLD:-10}" end saved t key=0
  case "$hold" in "" | *[!0-9]*) hold=10 ;; esac
  [ "$hold" -le 25 ] || hold=25
  printf '\n %sclosed: %s%s\n %sthis closes in %ss, or press a key%s' \
    "${HI_BOLD:-}" "$1" "${HI_OFF:-}" "${HI_DIM:-}" "$hold" "${HI_OFF:-}" 2>/dev/null
  end=$((SECONDS + hold))
  if [ "$2" != eof ] && [ -t 0 ] && saved="$(/bin/stty -g 2>/dev/null)"; then
    while [ "$SECONDS" -lt "$end" ]; do
      /bin/stty -icanon -echo -isig min 0 time $(((end - SECONDS) * 10)) 2>/dev/null
      _hi_dd 1024
      [ -n "$HI_HEX" ] || break
      # shellcheck disable=SC2086
      _hi_parse $HI_HEX
      for t in "${HI_TOK[@]}"; do [ "$t" = ignore ] || key=1; done
      [ "$key" -eq 0 ] || break
    done
    /bin/stty "$saved" 2>/dev/null
  fi
  [ "$key" -eq 1 ] || [ "$SECONDS" -ge "$end" ] || sleep $((end - SECONDS))
}

_hi_ui() {
  local in_tty=no out_tty=no
  # The subject is cut by characters, which bash counts only under a UTF-8 locale; a
  # popup gets the tmux server's environment, which may have none.
  [ -n "${LC_ALL:-}${LC_CTYPE:-}${LANG:-}" ] || export LC_CTYPE=en_US.UTF-8
  HI_CLEAR="$(tput clear 2>/dev/null)" HI_BOLD="$(tput bold 2>/dev/null)" HI_REV="$(tput rev 2>/dev/null)"
  HI_DIM="$(tput dim 2>/dev/null)" HI_OFF="$(tput sgr0 2>/dev/null)"
  HI_SEL=0 HI_TOP=0 HI_STATUS="refreshing from Beads…" HI_TTY=0 HI_CLOSE="" HI_CLOSE_KEY=""
  [ ! -t 0 ] || HI_TTY=1 in_tty=yes
  [ ! -t 1 ] || out_tty=yes # here, not inside a $( ), where stdout is always a pipe
  _hi_size
  _hi_log_trim
  _hi_log "start: v$WOLFMUX_VERSION team=${TEAM:-} TERM=${TERM:-} tty=$(tty 2>/dev/null) size=${HI_COLS}x${HI_LINES}" \
    "stdin-tty=$in_tty stdout-tty=$out_tty"
  _hi_tty_raw
  _hi_drain "at start"
  tput civis 2>/dev/null
  _hi_load
  _hi_draw
  if human_inbox_reconcile; then
    HI_STATUS=""
  else
    HI_STATUS="could not refresh from Beads; this is the list as last seen"
    _hi_log "refresh from Beads failed"
  fi
  _hi_load
  _hi_draw
  _hi_drain "after drawing"
  while :; do
    if ! _hi_take; then
      _hi_end "input ended" eof
      return 0
    fi
    HI_STATUS="" HI_LOGGED=0
    if ! _hi_act; then
      [ "$HI_LOGGED" -eq 1 ] || _hi_log_in "$HI_DID"
      if [ "$HI_CLOSE" = key ]; then _hi_end "key $HI_CLOSE_KEY" key; else _hi_end "input ended" eof; fi
      return 0
    fi
    [ "$HI_LOGGED" -eq 1 ] || _hi_log_in "$HI_DID"
    _hi_draw
  done
}
