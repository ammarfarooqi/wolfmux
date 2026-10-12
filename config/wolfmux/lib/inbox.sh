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
  local guard tries=0 started
  guard="$(inbox_dir)/.lock.$1"
  /bin/mkdir -p "$(inbox_dir)" 2>/dev/null || return 1
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

_inbox_badge_text() {
  local session="${1:-}" root="${2:-}" team="${3:-}" role total=0 count approval=0
  [ -n "$session" ] || return 0
  [ -n "$TMUX_BIN" ] && [ -n "$JQ_BIN" ] || return 0
  if [ -z "$root" ] || [ -z "$team" ]; then
    root="$(tmx show-options -t "=$session:" -qv @wolfmux_root 2>/dev/null)" || return 0
    team="$(tmx show-options -t "=$session:" -qv @wolfmux_team 2>/dev/null)" || return 0
  fi
  [ -n "$root" ] && [ -d "$root" ] || return 0
  valid_team_name "$team" || return 0
  PROJECT_KEY="$(project_key "$root")" || return 0
  PROJECT_STATE="$WOLFMUX_DATA/state/$PROJECT_KEY"
  PROJECT_TREES="$WOLFMUX_DATA/worktrees/$PROJECT_KEY"
  team_paths "$team"
  [ -d "$(inbox_dir)" ] || return 0
  for role in $(inbox_roles); do
    count="$(inbox_count_new "$role")"
    case "$count" in "" | *[!0-9]*) count=0 ;; esac
    total=$((total + count))
    if inbox_has_new_approval "$role"; then approval=1; fi
  done
  [ "$total" -gt 0 ] || return 0
  if [ "$approval" -eq 1 ]; then
    printf '%s %s %s\n' "$WOLFMUX_INBOX_MARK" "$total" "$WOLFMUX_INBOX_APPROVAL_MARK"
  else
    printf '%s %s\n' "$WOLFMUX_INBOX_MARK" "$total"
  fi
}

# --- the hooks ----------------------------------------------------------------
# A hook runs inside the agent's own process tree, with the environment cmd_run_agent
# exported (TEAM_ROLE, WOLFMUX_TEAM, WOLFMUX_ROOT) and the agent's working directory.
# Both hooks below must therefore be silent and quick on every path that is not a
# delivery, and neither may ever exit non-zero: a hook that fails is shown to the agent.

# _inbox_hook_ready — sets up the team paths for a hook, or 1 when there is nothing to
# do. Never dies: load_project would, and an agent must not see a teamctl error.
_inbox_hook_ready() {
  INBOX_ROLE="${TEAM_ROLE:-}"
  [ -n "$INBOX_ROLE" ] || return 1
  known_role_name "$INBOX_ROLE" || return 1
  [ -n "$TMUX_BIN" ] && [ -n "$JQ_BIN" ] && [ -n "$GIT_BIN" ] || return 1
  ROOT="$(resolve_root 2>/dev/null)" || return 1
  PROJECT_KEY="$(project_key "$ROOT")" || return 1
  PROJECT_STATE="$WOLFMUX_DATA/state/$PROJECT_KEY"
  PROJECT_TREES="$WOLFMUX_DATA/worktrees/$PROJECT_KEY"
  team_paths "${WOLFMUX_TEAM:-$WOLFMUX_DEFAULT_TEAM}"
  [ -d "$STATE_DIR" ] || return 1
  INBOX_IDENTITY="$(team_identity "$TEAM" "$INBOX_ROLE")"
  return 0
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
# the agent carries straight on and reads its beads — no keystroke anywhere, nothing in
# the human's conversation.
#
# A loop is impossible for two reasons, and both are needed: the lines are marked
# delivered BEFORE the answer is printed, so the same notice can never block twice; and
# no turn is blocked again inside WOLFMUX_INBOX_STOP_COOLDOWN, so a burst of beads
# arriving one a second cannot block one turn per second either.
cmd_inbox_stop() {
  local notices stamp last
  /bin/cat >/dev/null 2>&1 || true # the hook's JSON on stdin; nothing here needs it
  _inbox_hook_ready || return 0
  [ "$(inbox_count_undelivered "$INBOX_ROLE")" != "0" ] || return 0
  stamp="$(inbox_dir)/.stop.$INBOX_ROLE"
  last="$(/bin/cat "$stamp" 2>/dev/null || printf '0')"
  case "$last" in "" | *[!0-9]*) last=0 ;; esac
  [ $(($(now_epoch) - last)) -ge "$WOLFMUX_INBOX_STOP_COOLDOWN" ] || return 0
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

# cmd_inbox_prompt — internal (`teamctl _inbox-prompt`): a Claude Code UserPromptSubmit
# hook. Claude Code adds such a hook's stdout to the model's context, so the notices
# reach the agent alongside whatever the human just said, and are marked delivered.
# No cooldown: this one only ever runs because a human pressed Enter.
cmd_inbox_prompt() {
  local notices
  /bin/cat >/dev/null 2>&1 || true
  _inbox_hook_ready || return 0
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
