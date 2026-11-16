#!/bin/bash
# notify.sh — "an agent finished" as a desktop notification that leads back to the team.
#
# Claude Code runs `teamctl _notify` as a Stop hook in every Claude-based agent.
# Why teamctl does this itself: inside tmux the usual notifiers (the ECC plugin's
# among them) fall back to `osascript`, and macOS files those notifications under
# Script Editor — clicking one opens Script Editor. Here the message goes to the
# terminal that is attached to the team, as OSC 9 written to that client's tty.
# The notification then belongs to the terminal (iTerm2, kitty, Ghostty, WezTerm),
# and a click brings the tab with the team to the front.
# With no such terminal attached — the normal case for a team left to work in the
# background — Wolfmux.app posts it (built by install.sh from notifier/). macOS opens
# the application that owns a notification when you click it, and Wolfmux.app answers
# a click by opening a terminal attached to the team (`teamctl _open-team`).
# Only without that application does it come down to osascript and Script Editor.
#
# Rule for this file: a notification may never fail or delay an agent.

WOLFMUX_NOTIFY_MAX=100
WOLFMUX_NOTIFY_PENDING_SECONDS=20 # a message Wolfmux.app never fetched is not posted late
# The ECC plugin's documented switch for its own Stop notifier; see notify_silence_value.
WOLFMUX_ECC_NOTIFY_HOOK="stop:desktop-notify"

# notify_scope — all | lead | off
notify_scope() {
  case "${WOLFMUX_NOTIFY:-all}" in
    off | lead) printf '%s\n' "$WOLFMUX_NOTIFY" ;;
    *) printf 'all\n' ;;
  esac
}

# notify_wanted <kind> — does an agent of this kind get the Stop hook?
notify_wanted() {
  case "$(notify_scope)" in
    all) return 0 ;;
    lead) [ "$1" = "lead" ] ;;
    *) return 1 ;;
  esac
}

# notify_silence_value — ECC_DISABLED_HOOKS for a team agent: whatever the user already
# disables (environment first, then their settings.json) plus the plugin's notifier,
# which inside tmux would be a second, Script Editor-owned notification.
notify_silence_value() {
  local current="${ECC_DISABLED_HOOKS:-}" settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
  if [ -z "$current" ] && [ -r "$settings" ] && [ -n "$JQ_BIN" ]; then
    current="$("$JQ_BIN" -r '.env.ECC_DISABLED_HOOKS // ""' "$settings" 2>/dev/null || true)"
  fi
  case ",$current," in
    *",$WOLFMUX_ECC_NOTIFY_HOOK,"*) printf '%s\n' "$current" ;;
    ",,") printf '%s\n' "$WOLFMUX_ECC_NOTIFY_HOOK" ;;
    *) printf '%s,%s\n' "$current" "$WOLFMUX_ECC_NOTIFY_HOOK" ;;
  esac
}

# notify_text <hook-json> — first non-empty line of the agent's last message: control
# characters removed (it is about to be written into an escape sequence), light
# markdown dropped, shortened.
notify_text() {
  printf '%s' "$1" | "$JQ_BIN" -r --argjson max "$WOLFMUX_NOTIFY_MAX" '
    (.last_assistant_message // "" | tostring) | split("\n")
    | map(gsub("[[:cntrl:]]"; " ") | gsub("[*`]"; "") | gsub("^[#> -]+"; "") | gsub("^\\s+|\\s+$"; ""))
    | map(select(length > 0)) | (.[0] // "finished")
    | if length > $max then .[0:$max] + "…" else . end' 2>/dev/null || printf 'finished\n'
}

# notify_osc9_capable <client_termtype> — terminals that turn OSC 9 into a notification
notify_osc9_capable() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    iterm2* | kitty* | ghostty* | wezterm*) return 0 ;;
  esac
  return 1
}

# notify_client_ttys — tty of every capable terminal attached to the caller's team session
notify_client_ttys() {
  local session tty termtype
  if [ -n "${WOLFMUX_NOTIFY_TTY:-}" ]; then # test seam
    printf '%s\n' "$WOLFMUX_NOTIFY_TTY"
    return 0
  fi
  [ -n "${TMUX_PANE:-}" ] && [ -n "$TMUX_BIN" ] || return 0
  session="$(tmx display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null || true)"
  [ -n "$session" ] || return 0
  tmx list-clients -t "=$session" -F '#{client_tty}|#{client_termtype}' 2>/dev/null |
    while IFS='|' read -r tty termtype; do
      if notify_osc9_capable "$termtype" && [ -w "$tty" ]; then printf '%s\n' "$tty"; fi
    done
}

notify_dir() { printf '%s\n' "$WOLFMUX_DATA/notify"; }
notify_app() { printf '%s\n' "${WOLFMUX_NOTIFIER_APP:-$WOLFMUX_HOME/Wolfmux.app}"; }

# notify_remember_project — a click has to know which team to open
notify_remember_project() {
  local root
  root="$(resolve_root 2>/dev/null || true)"
  [ -n "$root" ] || return 0
  /bin/mkdir -p "$(notify_dir)" 2>/dev/null || return 0
  printf '%s\n%s\n' "$root" "${WOLFMUX_TEAM:-$WOLFMUX_DEFAULT_TEAM}" >"$(notify_dir)/last" 2>/dev/null || true
}

# notify_through_app <body> — hand the message to Wolfmux.app; false when there is none
notify_through_app() {
  local app dir opener="${WOLFMUX_OPEN_BIN:-/usr/bin/open}"
  app="$(notify_app)"
  dir="$(notify_dir)"
  [ -d "$app" ] && [ -x "$opener" ] || return 1
  /bin/mkdir -p "$dir" 2>/dev/null || return 1
  printf '%s\n%s\n' "$1" "click to open the team" >"$dir/pending.$$" 2>/dev/null || return 1
  /bin/mv -f "$dir/pending.$$" "$dir/pending" || return 1
  "$opener" -g "$app" >/dev/null 2>&1
}

# cmd_notify_pending — internal (`teamctl _notify-pending`): Wolfmux.app asks whether it
# was started to post something. Prints "body\nsubtitle" once, then nothing: the next
# start of the application is therefore a click.
cmd_notify_pending() {
  local file claimed now written
  file="$(notify_dir)/pending"
  [ -f "$file" ] || return 0
  claimed="$file.claimed.$$"
  /bin/mv -f "$file" "$claimed" 2>/dev/null || return 0
  now="$(date +%s)"
  written="$(/usr/bin/stat -f %m "$claimed" 2>/dev/null || printf '%s' "$now")"
  if [ $((now - written)) -le "$WOLFMUX_NOTIFY_PENDING_SECONDS" ]; then /bin/cat "$claimed"; fi
  /bin/rm -f "$claimed"
}

# open_team_terminal — iterm | terminal | <Application name>: WOLFMUX_TERMINAL, else the
# terminal the team was last attached from, else iTerm2 when installed, else Terminal
open_team_terminal() {
  local choice="${WOLFMUX_TERMINAL:-}"
  [ -n "$choice" ] || choice="$(meta_get last_terminal 2>/dev/null || true)"
  case "$choice" in
    iterm | iTerm.app | iTerm2) printf 'iterm\n' ;;
    terminal | Apple_Terminal) printf 'terminal\n' ;;
    ghostty | Ghostty) printf 'Ghostty\n' ;;
    WezTerm | wezterm) printf 'WezTerm\n' ;;
    kitty) printf 'kitty\n' ;;
    *) if [ -d /Applications/iTerm.app ]; then printf 'iterm\n'; else printf 'terminal\n'; fi ;;
  esac
}

# cmd_open_team — internal (`teamctl _open-team`): what a click on a notification does
cmd_open_team() {
  local dir root team terminal script osascript="${WOLFMUX_OSASCRIPT:-/usr/bin/osascript}" opener="${WOLFMUX_OPEN_BIN:-/usr/bin/open}"
  dir="$(notify_dir)"
  root="$(sed -n '1p' "$dir/last" 2>/dev/null || true)"
  team="$(sed -n '2p' "$dir/last" 2>/dev/null || true)"
  [ -n "$root" ] && [ -d "$root" ] || return 0
  valid_team_name "$team" || team="$WOLFMUX_DEFAULT_TEAM"
  WOLFMUX_TEAM_ARG="$team"
  export WOLFMUX_ROOT="$root"
  require_tools
  load_project
  SESSION="$(session_name_for_project)"
  terminal="$(open_team_terminal)"

  # Already on a screen somewhere: bring that application forward, open nothing new.
  if tm_session_exists "$SESSION" && [ -n "$(tmx list-clients -t "=$SESSION" -F x 2>/dev/null || true)" ]; then
    case "$terminal" in
      iterm) "$opener" -a iTerm >/dev/null 2>&1 || true ;;
      terminal) "$opener" -a Terminal >/dev/null 2>&1 || true ;;
      *) "$opener" -a "$terminal" >/dev/null 2>&1 || true ;;
    esac
    return 0
  fi

  script="$dir/open-team.command"
  {
    printf '#!/bin/zsh -l\n# written by teamctl _open-team; safe to delete\n'
    printf 'cd -- %q || exit 1\n' "$root"
    printf '%q --team %q attach || %q status\n' "$TEAMCTL_SELF" "$TEAM" "$TEAMCTL_SELF"
    printf 'exec /bin/zsh -l\n'
  } >"$script"
  /bin/chmod 755 "$script"
  case "$terminal" in
    iterm)
      "$osascript" -e 'on run argv' -e 'tell application "iTerm2"' -e 'activate' \
        -e 'create window with default profile command (item 1 of argv)' -e 'end tell' -e 'end run' \
        "$(printf '%q' "$script")" >/dev/null 2>&1 || true
      ;;
    terminal)
      "$osascript" -e 'on run argv' -e 'tell application "Terminal"' -e 'activate' \
        -e 'do script (item 1 of argv)' -e 'end tell' -e 'end run' "$(printf '%q' "$script")" >/dev/null 2>&1 || true
      ;;
    *) "$opener" -a "$terminal" >/dev/null 2>&1 || true ;; # no scripting interface we rely on: at least bring it forward
  esac
  return 0
}

# cmd_notify — internal (`teamctl _notify`): the Stop hook's JSON on stdin, and Codex's `notify`
# program, the same thing under another name. A Claude agent gets it as its own Stop hook entry
# when WOLFMUX_NOTIFY wants it (write_agent_settings); `teamctl _hook Stop` never notifies (v1.24.0).
cmd_notify() {
  local input
  if [ "${1:-}" = "--codex" ]; then
    # Codex: `notify` program, JSON as the last argument, "last-assistant-message"
    input="$(printf '%s' "${2:-}" | "$JQ_BIN" -c '{last_assistant_message: (.["last-assistant-message"] // "")}' 2>/dev/null || true)"
  else
    input="$(/bin/cat 2>/dev/null || true)"
  fi
  notify_send "$input"
  return 0
}

# notify_stop <hook-json> — "this agent finished a turn", when WOLFMUX_NOTIFY wants it from an
# agent of this kind. The lead is the role named lead; everyone else is a worker.
notify_stop() {
  local kind="worker"
  if [ "${TEAM_ROLE:-}" = "$WOLFMUX_LEAD_ROLE" ]; then kind="lead"; fi
  notify_wanted "$kind" || return 0
  notify_send "$1"
  return 0
}

# notify_send <hook-json>
notify_send() {
  local input="$1" role who body
  [ -n "$JQ_BIN" ] || return 0
  # The pane proof, the same as the inbox hooks' (lib/inbox.sh _inbox_hook_ready): a chat that
  # only inherited an agent's environment, such as a background chat of Claude's daemon, is not
  # that agent, and "lead: finished" from it would be a lie on your screen. Nothing is posted.
  _inbox_hook_ready || true
  [ -n "${INBOX_PROVEN:-}" ] || return 0
  role="$TEAM_ROLE"
  # "review/lead" in a named team, plain "lead" in the first one
  who="$role"
  if [ -n "${WOLFMUX_TEAM:-}" ] && [ "$WOLFMUX_TEAM" != "$WOLFMUX_DEFAULT_TEAM" ]; then who="$WOLFMUX_TEAM/$role"; fi
  body="$who: $(notify_text "$input")"
  if [ "$role" = "$WOLFMUX_LEAD_ROLE" ]; then body="$WOLFMUX_LEAD_MARK $body"; else body="$WOLFMUX_WORKER_MARK $body"; fi

  notify_deliver "$body"
  return 0
}

# notify_deliver <body> — the attached terminal, else Wolfmux.app, else osascript
notify_deliver() {
  local body="$1" tty sent=0 osascript="${WOLFMUX_OSASCRIPT:-/usr/bin/osascript}"
  notify_remember_project
  while IFS= read -r tty; do
    # One short write, so it cannot land inside one of tmux's own sequences.
    if { printf '\033]9;%s\007' "$body" >"$tty"; } 2>/dev/null; then sent=1; fi
  done < <(notify_client_ttys)
  if [ "$sent" -eq 0 ] && notify_through_app "$body"; then sent=1; fi
  if [ "$sent" -eq 0 ] && [ -x "$osascript" ]; then
    # Passed as arguments, never pasted into the script text: nothing to escape.
    # Last resort (no Wolfmux.app): this one belongs to Script Editor, and says so.
    "$osascript" -e 'on run argv' -e 'display notification (item 1 of argv) with title "Wolfmux" subtitle (item 2 of argv)' -e 'end run' \
      "$body" "open it with: teamctl attach (run ./install.sh for click-through)" >/dev/null 2>&1 || true
  fi
  return 0
}
