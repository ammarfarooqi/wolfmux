#!/bin/bash
# tmuxctl.sh — every tmux interaction lives here.
#
# Teams run on a dedicated tmux server (socket name "wolfmux") with its own config
# file, so your default tmux server and ~/.tmux.conf are never touched. Panes are
# found by the pane option @ai_role, which survives respawns and layout changes;
# tmux is the source of truth for "is this agent's process alive".

tmx() { "$TMUX_BIN" -L "$WOLFMUX_TMUX_SOCKET" "$@"; }

# tm_adopt_legacy_server — zero-downtime rename: while the new server has no session
# and the pre-rename server still has one, keep talking to that one. Off when the
# socket was chosen explicitly, unless WOLFMUX_ADOPT_LEGACY=1 says otherwise (tests).
# Safe to call again: after the last pre-rename session ends, it switches back.
tm_adopt_legacy_server() {
  [ "${WOLFMUX_ADOPT_LEGACY:-0}" = "1" ] && [ -n "$TMUX_BIN" ] || return 0
  if ! "$TMUX_BIN" -L "$WOLFMUX_OWN_SOCKET" has-session 2>/dev/null &&
    "$TMUX_BIN" -L "$WOLFMUX_LEGACY_SOCKET" has-session 2>/dev/null; then
    WOLFMUX_TMUX_SOCKET="$WOLFMUX_LEGACY_SOCKET"
  else
    WOLFMUX_TMUX_SOCKET="$WOLFMUX_OWN_SOCKET"
  fi
}

# tmx_boot — like tmx, for the one call that may have to START the server. The
# server keeps the environment of whoever starts it and hands it to every pane,
# so agent-session and provider variables are removed first.
#
# So is an agent's identity (WOLFMUX_AGENT_IDENTITY_VARS). A server that a lead starts (a
# founder's `teamctl start`) would otherwise hand TEAM_ROLE=lead to every pane and every
# run-shell, #() and popup child it runs: a pane you split for yourself would claim to be that
# lead, and a run-shell child even carries the lead's old TMUX_PANE (measured on tmux 3.7c).
# The pane proof (lib/common.sh identity_in_own_pane) refuses such a claim, so you would be
# refused in your own pane. Agents lose nothing: _run-agent sets their identity itself.
WOLFMUX_AGENT_IDENTITY_VARS="TEAM_ROLE BEADS_ACTOR WOLFMUX_TEAM WOLFMUX_SESSION WOLFMUX_WORKTREE WOLFMUX_BRANCH WOLFMUX_REPO WOLFMUX_MODEL TMUX_PANE"
tmx_boot() {
  local unset_args=() name
  for name in $WOLFMUX_CLAUDE_SESSION_VARS $WOLFMUX_AGENT_IDENTITY_VARS \
    $(wolfmux_list_set_vars "$WOLFMUX_CLAUDE_PROVIDER_VARS" "$WOLFMUX_CLAUDE_PROVIDER_PREFIXES") \
    $(wolfmux_list_set_vars "$WOLFMUX_CODEX_PROVIDER_VARS" "$WOLFMUX_CODEX_PROVIDER_PREFIXES"); do
    unset_args+=(-u "$name")
  done
  if [ "${CLAUDE_CODE_OAUTH_TOKEN:-}" = "$WOLFMUX_GLM_GUARD_TOKEN" ]; then
    unset_args+=(-u CLAUDE_CODE_OAUTH_TOKEN)
  fi
  env "${unset_args[@]}" "$TMUX_BIN" -L "$WOLFMUX_TMUX_SOCKET" -f "$WOLFMUX_HOME/tmux.conf" "$@"
}

# tm_version_at_least <major> <minor> — "tmux 3.7c" and "tmux next-3.8" both parse
tm_version_at_least() {
  local numbers major minor
  numbers="$("$TMUX_BIN" -V 2>/dev/null | sed -E 's/^[^0-9]*([0-9]+)\.([0-9]+).*$/\1 \2/')"
  major="${numbers%% *}"
  minor="${numbers##* }"
  case "$major$minor" in "" | *[!0-9]*) return 1 ;; esac
  [ "$major" -gt "$1" ] || { [ "$major" -eq "$1" ] && [ "$minor" -ge "$2" ]; }
}

# tm_set_splash <session> — the wolf popup a client sees when it attaches. Set again on
# every start/attach, so WOLFMUX_SPLASH=off and sessions from older versions both work.
# The popup starts in the session's directory, which is how `teamctl _splash` finds the team.
tm_set_splash() {
  local session="$1" look="" self
  tmx set-hook -u -t "=$session:" client-attached 2>/dev/null || true
  [ "${WOLFMUX_SPLASH:-on}" != "off" ] || return 0
  tm_version_at_least 3 2 || return 0 # display-popup arrived in tmux 3.2
  if tm_version_at_least 3 3; then look="-b rounded -s 'bg=#0b1020,fg=#d3d9e4' -S 'fg=#f5b942,bg=#0b1020'"; fi
  self="$(printf '%s' "$TEAMCTL_SELF" | sed "s/'/'\\\\''/g")"
  tmx set-hook -t "=$session:" client-attached \
    "display-popup -E $look -w $WOLFMUX_SPLASH_WIDTH -h $WOLFMUX_SPLASH_HEIGHT -d '#{session_path}' \"'$self' _splash\"" 2>/dev/null || true
}

tm_session_exists() { tmx has-session -t "=$1" 2>/dev/null; }

# Session-scoped options need the trailing colon: set-option/show-options parse -t
# as a pane target, where a bare "=name" is not recognised as an exact session match.
tm_session_root() { tmx show-options -t "=$1:" -qv @wolfmux_root 2>/dev/null || true; }

tm_set_session_root() { tmx set-option -t "=$1:" @wolfmux_root "$2"; }

# The team a session belongs to; a pane inherits it, which is how an agent's teamctl
# knows its own team (caller_team).
tm_set_session_team() { tmx set-option -t "=$1:" @wolfmux_team "$2"; }

# tm_new_session <session> <start-dir> <command...> — prints the first pane's id.
# The command is passed as separate arguments, so tmux executes it directly
# (no `sh -c`, no quoting layer).
tm_new_session() {
  local session="$1" dir="$2" cols rows
  shift 2
  cols="$(tput cols 2>/dev/null || true)"
  rows="$(tput lines 2>/dev/null || true)"
  case "$cols" in "" | *[!0-9]*) cols=220 ;; esac
  case "$rows" in "" | *[!0-9]*) rows=60 ;; esac
  [ "$cols" -ge 120 ] || cols=220
  [ "$rows" -ge 30 ] || rows=60
  tmx_boot new-session -d -s "$session" -n "$WOLFMUX_WINDOW" -c "$dir" -x "$cols" -y "$rows" \
    -P -F '#{pane_id}' "$@"
}

# tm_pane_for_role <session> <role> — pane id, or empty
tm_pane_for_role() {
  { tmx list-panes -s -t "=$1" -F '#{pane_id} #{@ai_role}' 2>/dev/null || true; } |
    awk -v role="$2" '$2 == role { print $1; exit }'
}

# tm_split_target <session> — the last pane of the window that holds the team,
# so new agents are appended in spawn order and `tiled` keeps the lead top-left.
tm_split_target() {
  local session="$1" window
  window="$(tmx list-panes -s -t "=$session" -F '#{window_id} #{@ai_role}' 2>/dev/null |
    awk 'NF == 2 { print $1; exit }')"
  [ -n "$window" ] || window="$(tmx list-windows -t "=$session" -F '#{window_id}' 2>/dev/null | head -1)"
  [ -n "$window" ] || return 1
  tmx list-panes -t "$window" -F '#{pane_index} #{pane_id}' | sort -n | tail -1 | awk '{ print $2 }'
}

# tm_split <target-pane> <start-dir> <command...> — prints the new pane's id.
# -d keeps focus where it is (normally the lead). Falls back to a full-span
# split when the target pane is too small to halve.
tm_split() {
  local target="$1" dir="$2" window pane
  shift 2
  window="$(tmx display-message -p -t "$target" '#{window_id}')" || return 1
  # An even grid first: it leaves the most room for one more split. The caller
  # arranges the team afterwards (layout_apply).
  tmx select-layout -t "$window" tiled >/dev/null 2>&1 || true
  pane="$(tmx split-window -d -t "$target" -c "$dir" -P -F '#{pane_id}' "$@" 2>/dev/null)" ||
    pane="$(tmx split-window -d -f -t "$target" -c "$dir" -P -F '#{pane_id}' "$@")" || return 1
  printf '%s\n' "$pane"
}

# tm_respawn <pane> <start-dir> <command...> — restart an agent in its own pane
tm_respawn() {
  local pane="$1" dir="$2"
  shift 2
  tmx respawn-pane -k -t "$pane" -c "$dir" "$@"
}

# tm_tag <pane> <role> <label> — the pane title IS the agent's role
tm_tag() {
  tmx select-pane -t "$1" -T "$2 · $3"
  tmx set-option -p -t "$1" @ai_role "$2"
  tmx set-option -p -t "$1" @ai_label "$3"
}

# tm_team_window <session> — id of the window that holds the agents
tm_team_window() {
  tmx list-panes -s -t "=$1" -F '#{window_id} #{@ai_role}' 2>/dev/null | awk 'NF == 2 { print $1; found = 1; exit } END { exit !found }'
}

# tm_alive_count <session> — panes whose process is still running. A shell you opened
# by hand in the team window counts too: a session with anything alive is never cleared.
tm_alive_count() {
  { tmx list-panes -s -t "=$1" -F '#{pane_dead}' 2>/dev/null || true; } | awk '$1 == "0" { n++ } END { print n + 0 }'
}

# tm_set_main_size <window> <main-pane-width|main-pane-height> <percent> — a percentage
# where tmux takes one, otherwise the same share in cells
tm_set_main_size() {
  local window="$1" option="$2" percent="$3" total
  if tmx set-option -w -t "$window" "$option" "$percent%" 2>/dev/null; then return 0; fi
  case "$option" in
    main-pane-width) total="$(tmx display-message -p -t "$window" '#{window_width}')" ;;
    *) total="$(tmx display-message -p -t "$window" '#{window_height}')" ;;
  esac
  case "$total" in "" | *[!0-9]*) return 1 ;; esac
  tmx set-option -w -t "$window" "$option" "$((total * percent / 100))"
}

# tm_apply_layout <session> <lead-left|lead-top|tiled> — tmux's "main" pane is the first
# one in the window, so the lead is moved there first (it is not after it was re-created).
tm_apply_layout() {
  local session="$1" layout="$2" window lead first
  window="$(tm_team_window "$session")" || return 0
  lead="$(tm_pane_for_role "$session" "$WOLFMUX_LEAD_ROLE")"
  first="$(tmx list-panes -t "$window" -F '#{pane_index} #{pane_id}' | sort -n | awk 'NR == 1 { print $2 }')"
  if [ -n "$lead" ] && [ -n "$first" ] && [ "$lead" != "$first" ]; then
    tmx swap-pane -d -s "$lead" -t "$first" 2>/dev/null || true
  fi
  case "$layout" in
    lead-top)
      tm_set_main_size "$window" main-pane-height "$WOLFMUX_LEAD_HEIGHT_PERCENT" || true
      tmx select-layout -t "$window" main-horizontal >/dev/null 2>&1 || true
      ;;
    tiled) tmx select-layout -t "$window" tiled >/dev/null 2>&1 || true ;;
    *)
      tm_set_main_size "$window" main-pane-width "$WOLFMUX_LEAD_WIDTH_PERCENT" || true
      tmx select-layout -t "$window" main-vertical >/dev/null 2>&1 || true
      ;;
  esac
}

# tm_pane_state <pane> — running | exited:<status> | gone
tm_pane_state() {
  local line dead status
  [ -n "${1:-}" ] || { printf 'gone\n'; return 0; }
  line="$(tmx display-message -p -t "$1" '#{pane_dead} #{pane_dead_status}' 2>/dev/null)" || {
    printf 'gone\n'
    return 0
  }
  dead="${line%% *}"
  status="${line#* }"
  if [ "$dead" = "1" ]; then
    printf 'exited:%s\n' "${status:-?}"
  else
    printf 'running\n'
  fi
}

# tm_type_line <pane> <text> — a short fixed notification, typed literally, then
# submitted. The pause lets TUIs that batch fast input as a paste see Enter as a key.
#
# The primitive, and deliberately dumb: it types whatever it is given, wherever it is
# pointed. Every caller that aims at a RUNNING agent's prompt asks tm_pane_human_busy
# first, or a human's half-typed line and the notice are submitted glued together.
tm_type_line() {
  tmx send-keys -t "$1" -l -- "$2"
  sleep 0.3
  tmx send-keys -t "$1" Enter
}

# Glyphs a TUI draws its input box out of. A Claude Code input row reads
# "│ > half typed                 │", so they say nothing about what was typed.
WOLFMUX_BOX_GLYPHS='│ ┃ ║ ┊ ┋ ┆ ┇ ╎ ╏ ─ ━ ═ ╭ ╮ ╯ ╰ ┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼ ╔ ╗ ╚ ╝ ╠ ╣ █ ▌ ▐ ▏ ▕'
# One of these at the start of the input line is the prompt, not something typed.
WOLFMUX_PROMPT_MARKERS='> ❯ › $ % #'
_TM_ESC=$'\033'
# Claude Code writes a NON-BREAKING space after its ❯. [[:space:]] matches it in a
# UTF-8 locale and not in C, so it is stripped by name instead of by luck: left in, it
# would make every Claude Code input row read as typed-in.
_TM_NBSP=$'\302\240'

# tm_visible_text <row> — the row's text with every escape sequence removed AND every
# DIM run (ESC[2m until a reset) removed with it. What comes back is only what somebody
# could have typed.
#
# A TUI draws the placeholder in its input box dim; a human's own typing is not dim.
# That is the whole discriminator, and it is measured, not assumed. Against a real
# Claude Code in a throwaway tmux socket, 2026-10-09:
#
#   empty input box : "❯<NBSP> ESC[2m Try \"fix typecheck errors\""  -> clean
#   after typing    : "❯<NBSP> i said install bun if requir"        -> DIRTY, no SGR
#
# So the dim strip cannot eat text somebody typed, and a hint is not read as a
# half-typed line. Reading a hint as typing is what made an idle agent look busy for as
# long as its hint showed, and silently stopped its nudges.
#
# (An earlier version of this comment cited pane %18 as seen "with ZERO clients on its
# session". %18 had a client attached; %790 was the zero-client pane. The probe above
# replaces that evidence.)
#
# Byte semantics on purpose (LC_ALL=C): only single-byte characters are compared, and
# every byte of a multibyte character is >= 0x80, so none of them can match by accident.
# A row with no escapes in it comes back unchanged, which is the plain-text fallback.
tm_visible_text() {
  local LC_ALL=C row="$1" out="" dim=0 i=0 n c params
  n="${#row}"
  while [ "$i" -lt "$n" ]; do
    c="${row:$i:1}"
    if [ "$c" != "$_TM_ESC" ]; then
      if [ "$dim" -eq 0 ]; then out="$out$c"; fi
      i=$((i + 1))
      continue
    fi
    i=$((i + 1))
    if [ "${row:$i:1}" != "[" ]; then continue; fi # not a CSI: drop the ESC and move on
    i=$((i + 1))
    params=""
    while [ "$i" -lt "$n" ]; do # a CSI runs to its final byte
      c="${row:$i:1}"
      i=$((i + 1))
      case "$c" in [0-9\;]) params="$params$c" ;; *) break ;; esac
    done
    # Only SGR ("m") changes how the text looks. 2 turns dim on; 0, 22 and a bare
    # ESC[m turn it off. Any other parameter leaves dim as it was.
    if [ "$c" = "m" ]; then
      case ";$params;" in
        *";2;"*) dim=1 ;;
        *";0;"* | *";22;"* | ";;") dim=0 ;;
      esac
    fi
  done
  printf '%s' "$out"
}

# tm_input_line_dirty <row> — 0 when the pane's input row holds more than an empty
# prompt. Escapes and dim runs go first, then box glyphs and whitespace, then ONE
# leading prompt marker; anything still left is somebody's half-typed text.
tm_input_line_dirty() {
  local text glyph marker
  text="$(tm_visible_text "$1")"
  for glyph in $WOLFMUX_BOX_GLYPHS; do text="${text//$glyph/}"; done
  text="${text//$_TM_NBSP/}"
  text="${text//[[:space:]]/}"
  for marker in $WOLFMUX_PROMPT_MARKERS; do
    case "$text" in "$marker"*)
      text="${text#"$marker"}"
      break
      ;;
    esac
  done
  [ -n "$text" ]
}

# tm_client_idle <session> — seconds since the newest client attached to this session
# last sent INPUT. The exit status says why there is no number, because the two reasons
# need opposite treatment:
#
#   0  a number was printed
#   1  the read worked and listed nobody: no client is attached to that session
#   2  the tmux read itself FAILED, so we know nothing — the caller must read that as
#      busy, or a broken tmux read would quietly turn the human checks off
#
# Verified on tmux 3.7c, this machine: #{client_activity} moves on real keystrokes
# only. It does not move when the pane prints output (clients on the live wolfmux
# socket read 19 hours idle while their agents keep writing), and it does not move
# for send-keys from outside. A detached session lists no client at all, which is why
# the keystroke check needs a client by construction and the input-line check does not.
tm_client_idle() {
  local newest="" act clients
  clients="$(tmx list-clients -t "$1" -F '#{client_activity}' 2>/dev/null)" || return 2
  while read -r act; do
    case "$act" in "" | *[!0-9]*) continue ;; esac
    if [ -z "$newest" ] || [ "$act" -gt "$newest" ]; then newest="$act"; fi
  done <<EOF
$clients
EOF
  [ -n "$newest" ] || return 1
  printf '%s\n' $(($(now_epoch) - newest))
}

# tm_pane_watched <pane-id> — 0 when an attached client is SHOWING this pane right now:
# the active pane of the current window of the session that client is on. Any client of
# this server counts, whichever session it is attached to, because a human who switched
# sessions with prefix s is looking at a pane of another team. tmux reports exactly that
# pane as a client's #{pane_id} (measured on tmux 3.7c, 2026-10-15).
#
# Fails CLOSED, like inbox_clients_attached: a tmux read that fails, or no pane id to ask
# about, counts as watched. The cost of being wrong that way is a notice that is filed
# rather than typed; the other way it is a line in front of the human.
tm_pane_watched() {
  local shown
  [ -n "${1:-}" ] || return 0
  shown="$(tmx list-clients -F '#{pane_id}' 2>/dev/null)" || return 0
  case "
$shown
" in
    *"
$1
"*) return 0 ;;
  esac
  return 1
}

# Why a notice is typed in at all, rather than shown with display-message or a popup:
# the notice is FOR THE AGENT in that pane, not for the human. The agent reads it as
# input and runs the inbox command it names. The status line and a popup put text in
# front of a human only, so an agent would never see it, and the lead's pane — the one a
# human sits at, which is exactly where issue #9 happens — would stop being notified
# altogether. Typing is the only channel that reaches the agent. Do not "simplify" this
# into a popup: detect-and-defer is the shape the channel forces.

TM_BUSY_REASON="" # which check said busy; the deferral message names it

# tm_pane_human_busy <pane> [idle-seconds] — 0 when a human may be typing in this pane
# right now, so nothing may be typed into it. A few tmux reads, no sleeps, no output of
# its own. Sets TM_BUSY_REASON.
#
# Busy when ANY of these holds:
#   c. the pane is in copy mode or scrollback, where keys drive the mode, not the
#      prompt. Checked whether or not anybody is watching.
#   a. a human is AT this pane (active pane of the active window of an attached
#      session) and pressed a key within <idle-seconds> seconds, which defaults to
#      WOLFMUX_NUDGE_HUMAN_IDLE. The LEAD's pane asks for a wider window
#      (WOLFMUX_NUDGE_LEAD_IDLE), because that pane is the human's own conversation:
#      five seconds without a keystroke there means he is reading, not that he left.
#   b. the input line already holds something. Also checked whether or not anybody is
#      attached: a half-typed line survives a detach.
#
# Only (a) needs a client, and it needs one by construction: the only evidence that a
# key was pressed is an attached client's #{client_activity}. (b) and (c) run whether or
# not anybody is attached.
#
# (b) used to need a client too, on the reasoning that with nobody attached nobody can
# be typing. That is false, and it reopened issue #9: type a line, do not submit it,
# then detach (or just walk away from `teamctl attach`), and the notice was typed over
# the half-typed line and submitted with it. Reproduced in review round 2.
#
# What tells a TUI's own furniture apart from somebody's typing is DIM, not the client
# list: tm_visible_text strips dim runs, a placeholder is dim, typed text carries no SGR
# at all (measured — see tm_visible_text). So (b) can run unconditionally without
# bringing back the regression it was gated for, which was an idle agent whose hint made
# it read busy for as long as the hint showed. The price is the other direction: a
# placeholder drawn in a PLAIN colour rather than dim now reads as typing on a detached
# pane too, so that agent's nudges wait out the cap and are dropped. Nobody has seen
# such a placeholder (every Claude Code one measured was ESC[2m; Codex is unmeasured),
# and WOLFMUX_NUDGE_COLLISION_CHECK=0 is the way out. ROADMAP names it as a known limit.
#
# A false "busy" only delays the notice, so everything from the point where we look at
# the row fails CLOSED: a capture that fails, a cursor row we cannot make sense of, and
# a client list we cannot read all count as busy. The one exception is the first
# display-message: if that fails there is no session and no pane to fail closed for.
# Every delay is bounded by the caller's deferral limit.
tm_pane_human_busy() {
  local pane="$1" window="${2:-}" fields rest in_mode pane_active win_active cy sess idle idle_rc row
  TM_BUSY_REASON=""
  [ -n "$pane" ] || return 1
  [ "${WOLFMUX_NUDGE_COLLISION_CHECK:-1}" = "1" ] || return 1
  # A window that is empty or not a number falls back to the default, like every other
  # numeric knob in this project: a caller's bad arithmetic must not turn check (a) off.
  case "$window" in "" | *[!0-9]*) window="${WOLFMUX_NUDGE_HUMAN_IDLE:-5}" ;; esac
  # Without this read we know neither the session nor whether anybody is attached to
  # it, so there is no client to fail closed for.
  fields="$(tmx display-message -p -t "$pane" \
    '#{pane_in_mode}|#{pane_active}|#{window_active}|#{cursor_y}|#{session_name}' 2>/dev/null)" || return 1
  in_mode="${fields%%|*}" rest="${fields#*|}"
  pane_active="${rest%%|*}" rest="${rest#*|}"
  win_active="${rest%%|*}" rest="${rest#*|}"
  cy="${rest%%|*}" sess="${rest#*|}"
  # (c) copy mode / scrollback: keys would go to the mode, attached or not
  if [ "$in_mode" = "1" ]; then
    TM_BUSY_REASON="copy mode"
    return 0
  fi
  # Without a session name there is no client list to ask about, and no row either.
  [ -n "$sess" ] || return 1
  # `cmd || var=$?` keeps errexit out of this: the list is allowed to come back empty.
  idle=""
  idle_rc=0
  idle="$(tm_client_idle "$sess" 2>/dev/null)" || idle_rc=$?
  if [ "$idle_rc" -ge 2 ]; then
    # The tmux read failed, so we cannot tell whether somebody is sitting there.
    TM_BUSY_REASON="the client list could not be read"
    return 0
  fi
  case "$idle" in "" | *[!0-9]*) idle="" ;; esac # rc 1: nobody is attached
  # (a) the human's eyes and hands are on this pane. Needs a client: no client, no
  # keystroke to read. Checks (b) and (c) still apply to a detached pane.
  if [ -n "$idle" ] && [ "$pane_active" = "1" ] && [ "$win_active" = "1" ] &&
    [ "$idle" -lt "$window" ]; then
    TM_BUSY_REASON="a keystroke ${idle}s ago"
    return 0
  fi
  # (b) something is already on the input line. From here a read that fails is busy.
  TM_BUSY_REASON="the input line is not empty"
  case "$cy" in "" | *[!0-9]*) return 0 ;; esac
  row="$(tmx capture-pane -p -J -e -t "$pane" -S "$cy" -E "$cy" 2>/dev/null)" || return 0
  tm_input_line_dirty "$row" && return 0
  TM_BUSY_REASON=""
  return 1
}

# tm_capture <pane> <lines|all>
tm_capture() {
  if [ "$2" = "all" ]; then
    tmx capture-pane -p -J -t "$1" -S - -E -
  else
    tmx capture-pane -p -J -t "$1" -S "-$2"
  fi
}

tm_inside_team_server() {
  case "${TMUX:-}" in
    */"$WOLFMUX_TMUX_SOCKET",*) return 0 ;;
    *) return 1 ;;
  esac
}
