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
# With no such terminal attached there is nowhere to go back to: osascript it is,
# and the text says how to open the team.
#
# Rule for this file: a notification may never fail or delay an agent.

WOLFMUX_NOTIFY_MAX=100
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

# cmd_notify — internal (`teamctl _notify`): Stop hook, JSON on stdin
cmd_notify() {
  local input role body tty sent=0 osascript="${WOLFMUX_OSASCRIPT:-/usr/bin/osascript}"
  input="$(/bin/cat 2>/dev/null || true)"
  [ -n "$JQ_BIN" ] || return 0
  role="${TEAM_ROLE:-agent}"
  body="$role: $(notify_text "$input")"
  if [ "$role" = "$WOLFMUX_LEAD_ROLE" ]; then body="$WOLFMUX_LEAD_MARK $body"; else body="$WOLFMUX_WORKER_MARK $body"; fi

  while IFS= read -r tty; do
    # One short write, so it cannot land inside one of tmux's own sequences.
    if { printf '\033]9;%s\007' "$body" >"$tty"; } 2>/dev/null; then sent=1; fi
  done < <(notify_client_ttys)
  if [ "$sent" -eq 0 ] && [ -x "$osascript" ]; then
    # Passed as arguments, never pasted into the script text: nothing to escape.
    "$osascript" -e 'on run argv' -e 'display notification (item 1 of argv) with title "Wolfmux" subtitle (item 2 of argv)' -e 'end run' \
      "$body" "open it with: teamctl attach" >/dev/null 2>&1 || true
  fi
  return 0
}
