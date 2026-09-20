#!/bin/bash
# tmuxctl.sh — every tmux interaction lives here.
#
# Teams run on a dedicated tmux server (socket name "wolfmux") with its own config
# file, so your default tmux server and ~/.tmux.conf are never touched. Panes are
# found by the pane option @ai_role, which survives respawns and layout changes;
# tmux is the source of truth for "is this agent's process alive".

tmx() { "$TMUX_BIN" -L "$WOLFMUX_TMUX_SOCKET" "$@"; }

# tmx_boot — like tmx, for the one call that may have to START the server. The
# server keeps the environment of whoever starts it and hands it to every pane,
# so agent-session and provider variables are removed first.
tmx_boot() {
  local unset_args=() name
  for name in $WOLFMUX_CLAUDE_SESSION_VARS \
    $(wolfmux_list_set_vars "$WOLFMUX_CLAUDE_PROVIDER_VARS" "$WOLFMUX_CLAUDE_PROVIDER_PREFIXES") \
    $(wolfmux_list_set_vars "$WOLFMUX_CODEX_PROVIDER_VARS" "$WOLFMUX_CODEX_PROVIDER_PREFIXES"); do
    unset_args+=(-u "$name")
  done
  if [ "${CLAUDE_CODE_OAUTH_TOKEN:-}" = "$WOLFMUX_GLM_GUARD_TOKEN" ]; then
    unset_args+=(-u CLAUDE_CODE_OAUTH_TOKEN)
  fi
  env "${unset_args[@]}" "$TMUX_BIN" -L "$WOLFMUX_TMUX_SOCKET" -f "$WOLFMUX_HOME/tmux.conf" "$@"
}

tm_session_exists() { tmx has-session -t "=$1" 2>/dev/null; }

# Session-scoped options need the trailing colon: set-option/show-options parse -t
# as a pane target, where a bare "=name" is not recognised as an exact session match.
tm_session_root() { tmx show-options -t "=$1:" -qv @wolfmux_root 2>/dev/null || true; }

tm_set_session_root() { tmx set-option -t "=$1:" @wolfmux_root "$2"; }

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
  tmx select-layout -t "$window" tiled >/dev/null 2>&1 || true
  pane="$(tmx split-window -d -t "$target" -c "$dir" -P -F '#{pane_id}' "$@" 2>/dev/null)" ||
    pane="$(tmx split-window -d -f -t "$target" -c "$dir" -P -F '#{pane_id}' "$@")" || return 1
  tmx select-layout -t "$window" tiled >/dev/null 2>&1 || true
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

tm_retile() {
  local window
  window="$(tmx list-panes -s -t "=$1" -F '#{window_id} #{@ai_role}' 2>/dev/null | awk 'NF == 2 { print $1; exit }')"
  [ -n "$window" ] && tmx select-layout -t "$window" tiled >/dev/null 2>&1 || true
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
tm_type_line() {
  tmx send-keys -t "$1" -l -- "$2"
  sleep 0.3
  tmx send-keys -t "$1" Enter
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
