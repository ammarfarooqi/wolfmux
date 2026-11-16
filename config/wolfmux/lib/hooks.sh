#!/bin/bash
# hooks.sh — one entry point for what an agent's CLI tells teamctl about its turn.
#
# Claude Code (and every provider that runs through it) calls `teamctl _hook <Event>` for
# SessionStart, UserPromptSubmit, PostToolUse, PreCompact and Stop: `write_agent_settings`
# wires all five into every agent's settings file. This module owns the call: it reads the
# event, lets the feature modules add to it, and answers the CLI in the shape that event
# expects. The feature modules never print to the CLI themselves.
#
# Why hooks: a notice typed into a pane reaches an agent only at the end of its turn, and
# then costs it three or four model round trips to read (bd show, bd list, bd close). A hook
# answer is put into the conversation by the CLI itself, at the next tool call, with the text
# already in it (ADR-0032).
#
# The contract for a feature module (lib/mail.sh, lib/recall.sh, lib/tasks.sh):
#
#   <module>_hook <Event>          defined by the module, called here when it exists.
#                                  Called in the order of WOLFMUX_HOOK_MODULES.
#   inside it, read:
#     HOOK_EVENT                   SessionStart | UserPromptSubmit | PostToolUse | PreCompact | Stop
#     HOOK_ROLE                    the agent's role (TEAM_ROLE)
#     HOOK_RUN                     the agent's run directory (see below); it exists
#     HOOK_INPUT                   the CLI's JSON for this event, as one string ("{}" when unreadable)
#     HOOK_SOURCE                  SessionStart only: startup | resume | clear | compact
#     HOOK_TRANSCRIPT              path of the conversation's transcript, "" when the CLI named none
#     hook_input '<jq filter>'     one value out of HOOK_INPUT ("" when absent)
#   and answer with:
#     hook_context "<text>"        text the agent sees. SessionStart, UserPromptSubmit, PostToolUse:
#                                  added to the conversation. Stop: the agent does NOT stop, it goes
#                                  on with this text (so only call it at Stop for something that
#                                  must be acted on now). PreCompact: printed as plain text, which
#                                  the CLI takes as instructions for the summary it is about to write.
#     hook_load_project            sets ROOT, TEAM, STATE_DIR, SESSION as `load_project` does, for a
#                                  module that has to look beyond the agent's own run directory.
#                                  Costs a tmux call: only on the path that needs it.
#   A module's failure never fails the hook: its function runs in `|| true`.
#
# The run directory, one per agent: $STATE_DIR/run/<role>/  (exported as WOLFMUX_RUN_DIR)
#   calls        how many tool calls this conversation made; its mtime is the agent's last sign of life
#   state        "busy" (a turn is running) or "idle" (the CLI waits at its prompt)
#   attention    exists = something wants to be said at the next tool call (whoever queues it creates it)
#   mail/        owned by lib/mail.sh
#   memory/      owned by lib/recall.sh
#
# The hot path lives in bin/teamctl, above the module loader: PostToolUse with nothing queued
# costs one bash start, no module and no fork.

WOLFMUX_HOOK_EVENTS="SessionStart UserPromptSubmit PostToolUse PreCompact Stop"
WOLFMUX_HOOK_MODULES="recall mail tasks" # the order their text appears in
WOLFMUX_HOOK_TIMEOUT=20                  # seconds the CLI waits for one hook
# Every Nth tool call the hot path lets PostToolUse through although nothing is queued, so a
# module can look at something that changes with the work itself (context use). bin/teamctl
# carries the same number: it cannot read this file without loading it.
WOLFMUX_HOOK_EVERY=10
# Said to the CLI when it is about to summarize a conversation (PreCompact).
WOLFMUX_HOOK_COMPACT_NOTE="Keep in the summary, word for word where you can: the id and title of the Beads task in progress, the branch, what is finished and committed, what is unfinished, the next step, and every instruction that arrived in a [wolfmux mail] block."
# What one hook answer may add to a conversation. A CLI truncates silently above its own limit.
WOLFMUX_HOOK_MAX_CHARS=9000

# _hook_cap <max-chars> — stdin to stdout, capped to the WHOLE text's length. `cut -c1-N`
# caps each LINE to N characters, not the text: many short lines then sail straight through
# a check that already measured the text as too long. A bash substring under a UTF-8 locale
# counts characters, so this cannot split a multi-byte one into invalid output either.
_hook_cap() {
  local max="$1" text
  text="$(/bin/cat)"
  if [ "${#text}" -gt "$max" ]; then
    printf '%s' "${text:0:$max}"
  else
    printf '%s' "$text"
  fi
}

# _hook_tail_cap <max-chars> — the same, but keeps the END of the text rather than the
# start: for a checkpoint shown back to an agent, the newest part is what matters.
_hook_tail_cap() {
  local max="$1" text
  text="$(/bin/cat)"
  if [ "${#text}" -gt "$max" ]; then
    printf '%s' "${text: -$max}"
  else
    printf '%s' "$text"
  fi
}

# _hook_title <text> — a task or message title is data: wherever it goes into a `[wolfmux]`
# line (a hook's own context, a typed notice), it is never more than one line and never more
# than 200 characters, so it cannot be mistaken for several lines of wolfmux's own text or
# run the line on past what the pane shows.
_hook_title() {
  printf '%s' "$1" | LC_ALL=C tr '\n\r\t' ' ' | LC_ALL=C tr -d '\000-\010\013-\037\177' | _hook_cap 200
}

# run_dir <role> — the agent's run directory in the loaded team
run_dir() { printf '%s/run/%s\n' "$STATE_DIR" "$1"; }

# run_dir_ensure <role> — creates it, prints it
run_dir_ensure() {
  local dir
  dir="$(run_dir "$1")"
  /bin/mkdir -p "$dir/mail" "$dir/memory"
  printf '%s\n' "$dir"
}

# agent_attention <role> — ask for the agent's next tool call to come through the full hook
agent_attention() {
  local dir
  dir="$(run_dir_ensure "$1")" || return 0
  : >"$dir/attention" 2>/dev/null || true
}

hook_input() { printf '%s' "$HOOK_INPUT" | "$JQ_BIN" -r "($1) // empty" 2>/dev/null || true; }

hook_context() {
  [ -n "${1:-}" ] || return 0
  if [ -n "$HOOK_CONTEXT" ]; then HOOK_CONTEXT="$HOOK_CONTEXT

$1"; else HOOK_CONTEXT="$1"; fi
}

hook_load_project() {
  [ -z "${HOOK_PROJECT_LOADED:-}" ] || return 0
  load_project
  SESSION="$(session_name_for_project)"
  HOOK_PROJECT_LOADED=1
}

# _hook_state <busy|idle> — one small write; a failure is not worth a word
_hook_state() { printf '%s\n' "$1" >"$HOOK_RUN/state" 2>/dev/null || true; }

# _hook_emit — the answer in the shape the event expects. Nothing to say: no output at all.
_hook_emit() {
  local text="$HOOK_CONTEXT"
  [ -n "$text" ] || return 0
  if [ "${#text}" -gt "$WOLFMUX_HOOK_MAX_CHARS" ]; then
    text="$(printf '%s' "$text" | _hook_cap "$WOLFMUX_HOOK_MAX_CHARS")
[wolfmux] cut here: the rest is in your inbox (teamctl mail)."
  fi
  case "$HOOK_EVENT" in
    SessionStart | UserPromptSubmit | PostToolUse)
      "$JQ_BIN" -cn --arg event "$HOOK_EVENT" --arg text "$text" \
        '{hookSpecificOutput: {hookEventName: $event, additionalContext: $text}}'
      ;;
    # additionalContext, not a block: v1.22.1's reason (lib/inbox.sh cmd_inbox_stop)
    Stop) "$JQ_BIN" -cn --arg text "$text" '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $text}}' ;;
    PreCompact) printf '%s\n' "$text" ;;
  esac
}

# cmd_hook <Event> — internal (`teamctl _hook`): the CLI's JSON on stdin
cmd_hook() {
  local module
  HOOK_EVENT="${1:-}"
  case " $WOLFMUX_HOOK_EVENTS " in *" $HOOK_EVENT "*) ;; *) return 0 ;; esac
  # Rule for this file, as for notify.sh: a hook may never fail or delay an agent.
  [ -n "$JQ_BIN" ] || return 0
  HOOK_ROLE="${TEAM_ROLE:-}"
  HOOK_RUN="${WOLFMUX_RUN_DIR:-}"
  HOOK_CONTEXT="" HOOK_PROJECT_LOADED=""
  HOOK_INPUT="$(/bin/cat 2>/dev/null || true)"
  # One jq call checks the input and reads agent_id. Claude Code runs an agent's hooks for the
  # tool calls of its in-process subagents (the Agent tool) too: their input carries agent_id
  # and agent_type, with the MAIN conversation's session_id and transcript_path. Whatever a
  # turn hook says there reaches the subagent, not the agent, and is then marked handed over
  # (v1.24.0 lost a lead's mail that way). So such a call says nothing and touches nothing:
  # the attention file stays, and the agent's own next tool call takes the full path (v1.24.1).
  local agent_id
  if agent_id="$(printf '%s' "$HOOK_INPUT" | "$JQ_BIN" -er 'if type == "object" then (.agent_id // "" | tostring) else error end' 2>/dev/null)"; then
    [ -z "$agent_id" ] || return 0
  else
    HOOK_INPUT="{}"
  fi
  # Not an agent of a team (a hook file reused by hand): nothing to do. The "finished"
  # notification is lib/notify.sh's own Stop hook (_notify), not this one (v1.24.0).
  if ! known_role_name "$HOOK_ROLE" || [ -z "$HOOK_RUN" ] || ! /bin/mkdir -p "$HOOK_RUN/mail" "$HOOK_RUN/memory" 2>/dev/null; then
    return 0
  fi
  HOOK_SOURCE="$(hook_input .source)"
  HOOK_TRANSCRIPT="$(hook_input .transcript_path)"
  store_ensure_project 2>/dev/null || true # cheap (no tmux call): mail/tasks/memory read or write the store below
  case "$HOOK_EVENT" in
    SessionStart)
      # A new conversation counts its own tool calls; one that is resumed or compacted goes on.
      if [ "$HOOK_SOURCE" = "startup" ] || [ "$HOOK_SOURCE" = "clear" ]; then printf '0\n' >"$HOOK_RUN/calls" 2>/dev/null || true; fi
      _hook_state idle
      ;;
    UserPromptSubmit) _hook_state busy ;;
    PreCompact)
      # What a summary drops first is what a teammate needs most: who it is and what it was doing.
      hook_context "$WOLFMUX_HOOK_COMPACT_NOTE"
      ;;
  esac
  # Whatever was queued is this call's to say; a module that could not say all of it asks again.
  /bin/rm -f "$HOOK_RUN/attention" 2>/dev/null || true
  for module in $WOLFMUX_HOOK_MODULES; do
    if declare -F "${module}_hook" >/dev/null 2>&1; then
      "${module}_hook" "$HOOK_EVENT" || true
    fi
  done
  if [ "$HOOK_EVENT" = "Stop" ]; then
    # v1.20.0's rule, kept (D1): in a pane a human is watching, and in a Claude lead's pane
    # while a client is attached, a Stop hook says NOTHING, because Claude Code prints its
    # text in that pane (lib/inbox.sh _inbox_stop_watched). Asked only when there is
    # something to say, so a quiet turn end reads no tmux state at all.
    if [ -n "$HOOK_CONTEXT" ] && { ! _inbox_hook_ready || _inbox_stop_watched; }; then
      HOOK_CONTEXT=""
    fi
    if [ -n "$HOOK_CONTEXT" ]; then _hook_state busy; else _hook_state idle; fi
  fi
  _hook_emit
  return 0
}
