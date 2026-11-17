#!/bin/bash
# stall-wedged.sh <stall.sh>: a wedged `bd` must not hold the stall report (v1.26.0, ADR-0038).
# Loads the modules as teamctl does, stands in a task store whose read sleeps 30 s (Beads' hang,
# issue #6039), and prints "<seconds> <messages sent> <body>" for one stall_tell.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
export WOLFMUX_HOME="$REPO/config/wolfmux"
STALL="${1:-$WOLFMUX_HOME/lib/stall.sh}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-stall-wedged.XXXXXX")"
trap '/bin/rm -rf "$WORK"' EXIT
. "$WOLFMUX_HOME/lib/store.sh" || exit 1
. "$STALL"
STATE_DIR="$WORK/state"
PROJECT_STATE="$WORK/state"
mkdir -p "$STATE_DIR"
JQ_BIN="$(command -v jq)"
WOLFMUX_LEAD_ROLE=lead
store_kind() { printf 'beads\n'; }
store_tasks_json() { sleep 30; }
team_identity() { printf '%s.%s\n' "$1" "$2"; }
event_log() { :; }
memory_store_lead_message() { printf '%s\n' "$4" >"$WORK/sent"; }
STALL_AT="2026-11-17T09:00:00.000Z" STALL_TEXT="API Error: 529 Overloaded" STALL_IDLE=900
TEAM=t
t0=$SECONDS
stall_tell wk
rc=$?
echo "$((SECONDS - t0)) $rc $(grep -c . "$WORK/sent" 2>/dev/null || echo 0)"
cat "$WORK/sent" 2>/dev/null
