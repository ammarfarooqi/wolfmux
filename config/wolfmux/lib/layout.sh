#!/bin/bash
# layout.sh — how the panes of a team are arranged.
#
#   lead-left   the lead is the large pane on the left, workers are stacked on the right (default)
#   lead-top    the lead lies across the top, workers sit side by side below it
#   tiled       tmux's even grid; the lead is just the first tile
#
# The lead never moves when workers come and go, and it is always the biggest pane:
# it is the one you talk to. Remembered per team (`teamctl layout <name>`), default
# from WOLFMUX_LAYOUT. Inside the team `Ctrl-b Space` cycles tmux's own arrangements and
# `Ctrl-b T` re-applies the last one.

WOLFMUX_LAYOUTS="lead-left lead-top tiled"
WOLFMUX_LEAD_WIDTH_PERCENT=55  # lead-left: the lead's share of the window width
WOLFMUX_LEAD_HEIGHT_PERCENT=60 # lead-top: the lead's share of the window height

layout_valid() {
  case " $WOLFMUX_LAYOUTS " in *" $1 "*) return 0 ;; esac
  return 1
}

# layout_current — the project's choice, else the configured default, else lead-left
layout_current() {
  local layout
  layout="$(meta_get layout 2>/dev/null || true)"
  [ -n "$layout" ] || layout="${WOLFMUX_LAYOUT:-}"
  if layout_valid "$layout"; then printf '%s\n' "$layout"; else printf 'lead-left\n'; fi
}

# layout_apply — arrange the running team; silent and harmless when there is none.
# Needs SESSION and the project variables (load_project).
layout_apply() {
  tm_session_exists "$SESSION" || return 0
  tm_apply_layout "$SESSION" "$(layout_current)" || true
}

cmd_layout() {
  local layout="${1:-}"
  require_tools
  load_project
  SESSION="$(session_name_for_project)"
  if [ -z "$layout" ]; then
    say "layout: $(layout_current)   (choices: $WOLFMUX_LAYOUTS)"
    say "inside the team: Ctrl-b Space cycles tmux's arrangements · Ctrl-b T re-applies the last one · Ctrl-b z zooms a pane"
    return 0
  fi
  layout_valid "$layout" || die_usage "unknown layout '$layout' (choices: $WOLFMUX_LAYOUTS)"
  ensure_state_dirs
  meta_put layout "$layout"
  layout_apply
  say "layout: $layout"
}
