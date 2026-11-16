#!/bin/bash
# mail.sh — messages and tasks reach an agent through its hooks, with the body, mid-turn.
# The contract is the header of lib/hooks.sh. Every read and write of a task or message in
# this file goes through lib/store.sh's store_* interface: nothing here knows which backend
# (native or Beads) is behind it.
#
# $STATE_DIR/run/<role>/mail/new/  one item not yet shown to that agent (its JSON, plus the
#                                  event that delivered it); mail/seen/ = shown, newest 50.
# teamctl never claims or closes a TASK; a MESSAGE that was shown is marked read for the
# agent, detached, so it does not spend a turn doing that itself.
#
# Delivery: the Beads backend has its own hook (hooks/beads-nudge) that calls `teamctl
# _deliver` (cmd_deliver below) whenever a bead changes. The native backend has no hooks of
# its own, so every command that writes it calls mail_announce itself, after the write.
# Both end up in _mail_deliver_to, the one path to a recipient's spool, attention and notice.

WOLFMUX_MAIL_BODY_MAX="${WOLFMUX_MAIL_BODY_MAX:-6000}"
WOLFMUX_MAIL_HOOK_BUDGET=8000 # hooks.sh caps the whole answer at 9000; leave it room for the rest

# mail_quiet_route <identity> — sets TEAM, STATE_DIR, WORKTREES_DIR, SESSION and MAIL_ROLE for
# an identity that may name another team ("review.backend" is backend of team review). 1 when
# nothing can be notified: a tool is missing, there is no project here, the team name is bad,
# or no session is running. Never dies: this runs from a detached background process started
# by a Beads hook, which must never fail `bd`. Shared by cmd_nudge --quiet (agents.sh) and
# cmd_deliver, so there is exactly one place either resolves an identity to a team.
mail_quiet_route() {
  local identity="$1" team="${WOLFMUX_TEAM_ARG:-$WOLFMUX_DEFAULT_TEAM}" role
  role="$identity"
  case "$identity" in
    *.*)
      identity_split "$identity"
      valid_team_name "$ID_TEAM" || return 1
      team="$ID_TEAM"
      role="$ID_ROLE"
      ;;
  esac
  [ -n "$TMUX_BIN" ] && [ -n "$JQ_BIN" ] && [ -n "$GIT_BIN" ] || return 1
  ROOT="$(resolve_root 2>/dev/null)" || return 1
  PROJECT_KEY="$(project_key "$ROOT")"
  PROJECT_STATE="$WOLFMUX_DATA/state/$PROJECT_KEY"
  PROJECT_TREES="$WOLFMUX_DATA/worktrees/$PROJECT_KEY"
  team_paths "$team"
  [ -d "$STATE_DIR" ] || return 1
  SESSION="$(session_name_for_project)"
  tm_session_exists "$SESSION" || return 1
  MAIL_ROLE="$role"
}

# _mail_spool_write <role> <event> <payload-json> — the bead plus which Beads event delivered
# it, written atomically (temp name, then mv). Prints the file's path.
_mail_spool_write() {
  local role="$1" event="$2" payload="$3" dir file tmp bead
  dir="$(run_dir_ensure "$role")" || return 1
  /bin/mkdir -p "$dir/mail/new" "$dir/mail/seen" 2>/dev/null || return 1
  bead="$(printf '%s' "$payload" | "$JQ_BIN" -r '.id // empty' 2>/dev/null)"
  valid_bead_id "$bead" || bead="x"
  file="$dir/mail/new/$(now_epoch)-$$-$bead.json"
  tmp="$file.tmp.$$"
  printf '%s' "$payload" | "$JQ_BIN" --arg event "$event" '. + {event: $event}' >"$tmp" 2>/dev/null || {
    /bin/rm -f "$tmp"
    return 1
  }
  /bin/mv -f "$tmp" "$file" || return 1
  printf '%s\n' "$file"
}

# _mail_deliver_to <role> <event> <payload-json> <identity> — the one path to a recipient
# (ADR-0032, v1.24.0: one delivery system). For a Claude-family agent whose pane runs, the item
# is spooled first (mail/new), so whichever hook hands the notice over can carry its body, and
# attention is flagged for the mid-turn channel (PostToolUse). Then, for every agent, exactly
# one notice through v1.23.0's _nudge_one: one inbox_add line (badge, popup, desktop
# notification, wake waiter) and, only where its gates allow, the typed line. Nothing in this
# file types into a pane any more: the wake line of the first hook-mail design and its watchdog are gone, because the
# Stop and prompt hooks, the lead's wake waiter and the gated typing already cover an idle and
# a busy agent. A Codex-family agent gets exactly what v1.23.0 gave it: no spool, the notice.
# Shared by cmd_deliver (the Beads hook) and mail_announce (the native store's own delivery).
# Must never fail or delay whoever called it: every exit here is 0.
_mail_deliver_to() {
  local role="$1" event="$2" payload="$3" identity="$4" bead pane
  known_role_name "$role" && reg_exists "$role" || return 0
  bead="$(printf '%s' "$payload" | "$JQ_BIN" -r '.id // empty' 2>/dev/null)"
  if [ "$(reg_field "$role" family)" != "codex" ]; then
    pane="$(tm_pane_for_role "$SESSION" "$role")"
    if [ -n "$pane" ] && [ "$(tm_pane_state "$pane")" = "running" ] &&
      _mail_spool_write "$role" "$event" "$payload" >/dev/null; then
      agent_attention "$role"
    fi
  fi
  _nudge_one "$role" "$bead" >/dev/null 2>&1 || true
  event_log deliver "$role" "$bead"
  return 0
}

# cmd_deliver <identity> --event <create|update|close> — internal (`teamctl _deliver`); the
# item's JSON on stdin. Called detached from hooks/beads-nudge, so it must never fail and
# never delay the process that ran it: every exit here is 0. Beads mode only: the native
# store has no hook of its own and calls mail_announce directly instead.
cmd_deliver() {
  local identity="${1:-}" event="" payload
  [ -n "$identity" ] || return 0
  shift
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--event" ] && [ "$#" -ge 2 ]; then
      event="$2"
      shift
    fi
    shift
  done
  case " create update close " in *" $event "*) ;; *) return 0 ;; esac
  payload="$(/bin/cat 2>/dev/null || true)"
  printf '%s' "$payload" | "$JQ_BIN" -e 'type == "object"' >/dev/null 2>&1 || return 0
  mail_quiet_route "$identity" || return 0
  _mail_deliver_to "$MAIL_ROLE" "$event" "$payload" "$identity"
}

# mail_announce <event: create|update|close> <item-json> <actor-identity> — the native
# store's own delivery, called by every teamctl command that just wrote it. Applies the same
# rule hooks/beads-nudge applies for Beads: the assignee when someone else put or changed
# something on its plate, the team's lead when a worker blocks or closes a task, never the
# actor itself. A no-op for the Beads backend: its own hook already delivers, and calling
# this there too would notify twice.
mail_announce() {
  local event="$1" item="$2" actor="$3" assignee type status lead target
  [ "$(store_kind)" = "native" ] || return 0
  [ -n "$item" ] || return 0
  assignee="$(printf '%s' "$item" | "$JQ_BIN" -r '.assignee // ""' 2>/dev/null)"
  type="$(printf '%s' "$item" | "$JQ_BIN" -r '.issue_type // "task"' 2>/dev/null)"
  status="$(printf '%s' "$item" | "$JQ_BIN" -r '.status // ""' 2>/dev/null)"
  # The human's unread-message index (badge, popup): on Beads, hooks/beads-nudge feeds it
  # every message bead; here, every message this store writes. Never fails the caller.
  if [ "$type" = "message" ]; then
    (
      set +e
      _human_inbox_hook "$item"
    ) >/dev/null 2>&1 || true
  fi
  case "$actor" in
    *.*) lead="${actor%%.*}.$WOLFMUX_LEAD_ROLE" ;;
    *) lead="$WOLFMUX_LEAD_ROLE" ;;
  esac
  target=""
  case "$event" in
    create | update)
      if [ -n "$assignee" ] && [ "$assignee" != "$actor" ] && [ "$status" != "closed" ]; then
        target="$assignee"
      elif [ "$type" != "message" ] && [ "$status" = "blocked" ] && [ -n "$actor" ] && [ "$actor" != "$lead" ]; then
        target="$lead"
      fi
      ;;
    close)
      if [ "$type" != "message" ] && [ -n "$actor" ] && [ "$actor" != "$lead" ]; then
        target="$lead"
      fi
      ;;
  esac
  [ -n "$target" ] || return 0
  mail_quiet_route "$target" || return 0
  _mail_deliver_to "$MAIL_ROLE" "$event" "$item" "$target"
}

# _mail_sanitize_body <text> <bead-id> — strips control characters (and so neutralises escape
# sequences, which start with one), caps length, and makes sure a bead's own words can never be
# mistaken for a line wolfmux itself is saying.
_mail_sanitize_body() {
  local text="$1" id="$2" cut=0 line out=""
  text="$(printf '%s' "$text" | LC_ALL=C /usr/bin/tr -d '\000-\010\013-\037\177')"
  if [ "${#text}" -gt "$WOLFMUX_MAIL_BODY_MAX" ]; then
    text="$(printf '%s' "$text" | _hook_cap "$WOLFMUX_MAIL_BODY_MAX")"
    cut=1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "[wolfmux"*) line="> $line" ;; esac
    if [ -n "$out" ]; then
      out="$out
$line"
    else
      out="$line"
    fi
  done <<MAILBODY
$text
MAILBODY
  if [ "$cut" -eq 1 ]; then
    out="$out
… (cut: teamctl show $id has the rest)"
  fi
  printf '%s' "$out"
}

# _mail_render_bead <bead-json> — one rendered block: a labelled heading (ours, never claimed
# as the agent's own instruction) then the bead's own text, quoted as it is, then one line on
# what to do about it. Shared by every hook event and by `teamctl mail`.
_mail_render_bead() {
  local json="$1" id type from title prio status event desc heading hint body out blocked_by
  id="$(printf '%s' "$json" | "$JQ_BIN" -r '.id // "?"' 2>/dev/null)"
  type="$(printf '%s' "$json" | "$JQ_BIN" -r '.issue_type // "task"' 2>/dev/null)"
  from="$(printf '%s' "$json" | "$JQ_BIN" -r '.created_by // ""' 2>/dev/null)"
  [ -n "$from" ] || from="?"
  title="$(_hook_title "$(printf '%s' "$json" | "$JQ_BIN" -r '.title // ""' 2>/dev/null)")"
  prio="$(printf '%s' "$json" | "$JQ_BIN" -r '.priority // 3' 2>/dev/null)"
  status="$(printf '%s' "$json" | "$JQ_BIN" -r '.status // "open"' 2>/dev/null)"
  event="$(printf '%s' "$json" | "$JQ_BIN" -r '.event // ""' 2>/dev/null)"
  desc="$(printf '%s' "$json" | "$JQ_BIN" -r '.description // ""' 2>/dev/null)"
  blocked_by="$(printf '%s' "$json" | "$JQ_BIN" -r '[.blocked_by[]?] | join(", ")' 2>/dev/null)"
  if [ "$event" = "close" ] && [ "$type" != "message" ]; then
    local who role
    who="$from"
    role="$(printf '%s' "$json" | "$JQ_BIN" -r '.assignee // "?"' 2>/dev/null)"
    printf '[wolfmux mail] %s closed %s: %s. Review: teamctl diff %s --stat' "$who" "$id" "$title" "$role"
    return 0
  fi
  if [ "$type" = "message" ]; then
    heading="[wolfmux mail] MESSAGE $id from $from: $title"
    hint="Marked read. Reply: teamctl send $from \"Re: $title\" \"<text>\""
  else
    # Waiting on an unclosed blocker shows that instead of its own status, so it is never
    # mistaken for ready work (teamctl claim refuses it too, for the same reason).
    [ -z "$blocked_by" ] || status="waiting"
    if [ "$event" = "update" ]; then
      heading="[wolfmux mail] TASK UPDATED $id from $from, priority P$prio, $status: $title"
    else
      heading="[wolfmux mail] TASK $id from $from, priority P$prio, $status: $title"
    fi
    hint=""
    if [ -n "$blocked_by" ]; then
      hint="Waiting on unclosed blockers: $blocked_by"
    elif [ "$status" = "open" ]; then
      hint="This is your task. Claim it before you start: teamctl claim $id"
    fi
  fi
  body="$(_mail_sanitize_body "$desc" "$id")"
  out="$heading"
  [ -z "$body" ] || out="$out
$body"
  [ -z "$hint" ] || out="$out
$hint"
  printf '%s' "$out"
}

# _mail_prune_seen <dir> — keeps only the newest 50 shown files
_mail_prune_seen() {
  local dir="$1" old
  [ -d "$dir" ] || return 0
  /bin/ls -1t "$dir" 2>/dev/null | /usr/bin/tail -n +51 | while IFS= read -r old; do
    /bin/rm -f "$dir/$old"
  done
}

# _mail_mark_shown <file> <seen-dir> <identity> — moves a spool file about to be shown into
# seen/, prunes seen/ to the newest 50, and for a message marks it read for this agent, detached
# (so the agent does not spend a turn doing that itself, and a hook never blocks on the store).
# Native store only: on Beads a hook makes no bd call at all (v1.20.0, tests/beads-hotpath.sh),
# so there the message stays open until the agent or `teamctl mail` closes it, as in v1.23.0.
# 1 when the move failed: another reader (`teamctl mail`, the Stop hook) took the file first, or
# seen/ is not writable. The caller then does NOT show the item: the move is the claim, so two
# readers racing for one file show it once, never twice.
_mail_mark_shown() {
  local file="$1" seen="$2" identity="$3" dest type id
  dest="$seen/$(basename "$file")"
  /bin/mv -f "$file" "$dest" 2>/dev/null || return 1
  [ -f "$dest" ] || return 1
  type="$("$JQ_BIN" -r '.issue_type // "task"' "$dest" 2>/dev/null)"
  id="$("$JQ_BIN" -r '.id // empty' "$dest" 2>/dev/null)"
  if [ "$type" = "message" ] && valid_bead_id "$id" && [ -n "$identity" ] && [ "$(store_kind)" = "native" ]; then
    (store_msg_read "$identity" "$id" >/dev/null 2>&1 &)
  fi
  _mail_prune_seen "$seen"
}

# inbox_read <identity> — this agent's open work as JSON: tasks first by priority, then unread
# messages by time. 1 when the store is unreachable or answers something that is not JSON;
# the caller decides what that means (a hook says nothing, `teamctl mail` reports it).
inbox_read() {
  local identity="$1" json
  [ -n "$JQ_BIN" ] || return 1
  json="$(store_inbox_json "$identity" 2>/dev/null)" || return 1
  printf '%s' "$json" | "$JQ_BIN" -e 'type == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$json"
}

# _mail_hook_drain — PostToolUse, UserPromptSubmit, Stop: whatever is waiting in mail/new/,
# oldest first. Nothing queued: return at once, no store call either way. More than fits in
# about 8000 characters: show what fits, leave the rest in new/ for the next tool call.
# --- one delivery system (v1.24.0, ADR-0032) -------------------------------------------
# The inbox line (lib/inbox.sh) and the spooled body are one item. Whichever channel hands it
# over marks it handed over for the other: the inbox hooks (Stop, UserPromptSubmit, the wake
# waiter) attach the body and move it to mail/seen (mail_bodies_for); the mid-turn drain shows
# the body and flips the inbox line to delivered (inbox_mark_item_delivered).

# _mail_notice_ids <notices> — the item ids the notice lines name: "(<id>)", as _nudge_text writes them
_mail_notice_ids() {
  printf '%s\n' "$1" | LC_ALL=C /usr/bin/sed -n 's/^.*[(]\([A-Za-z0-9][A-Za-z0-9._-]*\)[)].*$/\1/p'
}

# _mail_spool_id <file-name> — the item id of a spool file "<epoch>-<pid>-<id>.json" (an id may hold "-")
_mail_spool_id() {
  local id="${1##*/}"
  id="${id#*-}"
  id="${id#*-}"
  printf '%s\n' "${id%.json}"
}

# _mail_spooled <run-dir> <id> — the spool file of exactly that item, "" when there is none
_mail_spooled() {
  local f
  for f in "$1"/mail/new/*-"$2".json; do
    [ -f "$f" ] || continue
    [ "$(_mail_spool_id "$f")" = "$2" ] || continue
    printf '%s\n' "$f"
    return 0
  done
  return 1
}

# mail_notices_uncovered <role> <notices> — how many of these notice lines have no spooled body
# (a notice of another kind, an item spooled for nobody, a Codex agent): 0 means the bodies
# answer every line and the agent needs no command at all.
mail_notices_uncovered() {
  local dir="$STATE_DIR/run/$1" n=0 line id
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id="$(_mail_notice_ids "$line" | /usr/bin/head -1)"
    if [ -z "$id" ] || ! _mail_spooled "$dir" "$id" >/dev/null; then n=$((n + 1)); fi
  done <<EOF
$2
EOF
  printf '%s\n' "$n"
}

# mail_bodies_for <role> <identity> <notices> — prints the body of every spooled item these
# notices name, within WOLFMUX_MAIL_HOOK_BUDGET, and moves each one printed to mail/seen. One
# that does not fit stays spooled, with attention flagged: the next tool call shows it.
mail_bodies_for() {
  local role="$1" identity="$2" dir="$STATE_DIR/run/$1" id file block budget=0 shown=0
  [ -n "$JQ_BIN" ] && [ -d "$dir/mail/new" ] || return 0
  for id in $(_mail_notice_ids "$3"); do
    file="$(_mail_spooled "$dir" "$id")" || continue
    block="$(_mail_render_bead "$(/bin/cat "$file" 2>/dev/null)" 2>/dev/null)" || continue
    [ -n "$block" ] || continue
    if [ "$shown" -gt 0 ] && [ $((budget + ${#block})) -gt "$WOLFMUX_MAIL_HOOK_BUDGET" ]; then
      agent_attention "$role"
      break
    fi
    # moved first, printed only once moved: the move is the claim (_mail_mark_shown)
    _mail_mark_shown "$file" "$dir/mail/seen" "$identity" || continue
    printf '%s\n\n' "$block"
    budget=$((budget + ${#block}))
    shown=$((shown + 1))
  done
  return 0
}

_mail_hook_drain() {
  # The inbox file is $STATE_DIR/inbox/<role>, and the run directory is $STATE_DIR/run/<role>:
  # the team's state directory without a tmux call (hook_load_project would make one).
  if [ -z "${STATE_DIR:-}" ]; then
    STATE_DIR="${HOOK_RUN%/}"
    STATE_DIR="${STATE_DIR%/*}"
    STATE_DIR="${STATE_DIR%/*}"
  fi
  local dir="$HOOK_RUN/mail" identity="${BEADS_ACTOR:-$HOOK_ROLE}" base file json block budget=0 shown=0 more=0 queued
  [ -d "$dir/new" ] || return 0
  # v1.21.1's pane proof, as the Stop and prompt hooks ask it (_inbox_hook_ready): only the agent
  # in its own pane is handed its mail. A chat that merely inherited this environment gets nothing,
  # and the mail stays spooled with its inbox line undelivered. Asked only when there is mail: the
  # proof costs tmux calls, and a tool call with nothing queued never gets this far (bin/teamctl).
  queued="$(/bin/ls -1 "$dir/new" 2>/dev/null | /usr/bin/head -1)"
  [ -n "$queued" ] || return 0
  if ! _inbox_hook_ready; then
    # Not handed over, so still queued: the attention that cmd_hook cleared is set again, or the
    # agent's own next tool call would take the hot path and leave its mail waiting.
    : >"$HOOK_RUN/attention" 2>/dev/null || true
    return 0
  fi
  for base in $(/bin/ls -1 "$dir/new" 2>/dev/null | /usr/bin/sort); do
    file="$dir/new/$base"
    [ -f "$file" ] || continue
    json="$(/bin/cat "$file" 2>/dev/null)"
    block="$(_mail_render_bead "$json" 2>/dev/null)"
    if [ "$shown" -gt 0 ] && [ $((budget + ${#block})) -gt "$WOLFMUX_MAIL_HOOK_BUDGET" ]; then
      more=1
      break
    fi
    # Moved first, shown only once moved: the move is the claim (_mail_mark_shown). One that
    # could not be moved stays queued, and attention is set again so the next call retries it.
    if ! _mail_mark_shown "$file" "$dir/seen" "$identity"; then
      [ ! -f "$file" ] || more=1
      continue
    fi
    hook_context "$block"
    budget=$((budget + ${#block}))
    shown=$((shown + 1))
    # handed over here: the inbox line that announced it is delivered too, so the Stop and
    # prompt hooks do not hand the same item over a second time
    inbox_mark_item_delivered "$HOOK_ROLE" "$(_mail_spool_id "$base")"
  done
  [ "$more" -eq 0 ] || agent_attention "$HOOK_ROLE"
}

# _mail_hook_session_start — the store is the truth here, not the spool: a task assigned
# before the worker existed was never spooled. One read, rendered as the agent's briefing;
# whatever already sat in mail/new/ is already in that briefing, so it moves to seen/ too.
# The store unreachable or failing: say nothing, leave the spool alone.
_mail_hook_session_start() {
  local identity="${BEADS_ACTOR:-$HOOK_ROLE}" rows count heading json block budget=0 shown=0 base
  rows="$(inbox_read "$identity")" || return 0
  count="$(printf '%s' "$rows" | "$JQ_BIN" -r 'length' 2>/dev/null)"
  case "$count" in '' | *[!0-9]*) count=0 ;; esac
  case "$HOOK_SOURCE" in
    compact | resume) heading="[wolfmux mail] your inbox as it stands now, $identity:" ;;
    *) heading="[wolfmux mail] your assignment, $identity:" ;;
  esac
  if [ "$count" -eq 0 ]; then
    hook_context "$heading nothing is assigned yet. Wait for mail, or run: teamctl mail"
  else
    hook_context "$heading"
    while IFS= read -r json; do
      [ -n "$json" ] || continue
      block="$(_mail_render_bead "$json" 2>/dev/null)"
      [ "$shown" -eq 0 ] || [ $((budget + ${#block})) -le "$WOLFMUX_MAIL_HOOK_BUDGET" ] || break
      hook_context "$block"
      budget=$((budget + ${#block}))
      shown=$((shown + 1))
    done < <(printf '%s' "$rows" | "$JQ_BIN" -c '.[]' 2>/dev/null)
  fi
  for base in $(/bin/ls -1 "$HOOK_RUN/mail/new" 2>/dev/null); do
    [ -f "$HOOK_RUN/mail/new/$base" ] || continue
    _mail_mark_shown "$HOOK_RUN/mail/new/$base" "$HOOK_RUN/mail/seen" "$identity"
  done
}

# mail_hook <Event> — the contract is lib/hooks.sh's header.
mail_hook() {
  case "$1" in
    SessionStart) _mail_hook_session_start ;;
    PostToolUse) _mail_hook_drain ;;
    # Stop and UserPromptSubmit: lib/inbox.sh's own hooks hand mail over, body included
    # (mail_bodies_for); a second hand-over here would show it twice. PreCompact: nothing.
    *) ;;
  esac
}

# _mail_send_target <role>|<team>.<role> — sets MAIL_SEND_TEAM and MAIL_SEND_ROLE, or dies
# (exit 64) naming the roles that do exist.
_mail_send_target() {
  local word="$1" team role known
  case "$word" in
    *.*)
      identity_split "$word"
      valid_team_name "$ID_TEAM" || die_usage "$(team_name_error "$ID_TEAM")"
      team="$ID_TEAM"
      role="$ID_ROLE"
      ;;
    *)
      team="$TEAM"
      role="$word"
      ;;
  esac
  known_role_name "$role" || die_usage "invalid role '$word'"
  team_paths "$team"
  if ! reg_exists "$role"; then
    known="$(reg_list | tr '\n' ' ')"
    die_usage "no such agent '$word'; roles of this team: ${known:-none}"
  fi
  MAIL_SEND_TEAM="$team" MAIL_SEND_ROLE="$role"
}

# _mail_send_one <team> <role> <subject> <body> <re-bead> <sender-identity> — creates the
# message, prints its new id. In Beads mode the hook does the delivery; in native mode this
# announces it itself, after the write.
_mail_send_one() {
  local team="$1" role="$2" subject="$3" body="$4" re="$5" sender="$6" identity id
  identity="$(team_identity "$team" "$role")"
  id="$(store_msg_create "$sender" "$identity" "$subject" "$body" "$re")" || return 1
  mail_announce create "$(store_item_json "$id")" "$sender"
  printf '%s\n' "$id"
}

# teamctl send <role>|<team>.<role>|--all "<subject>" ["<body>"] [--body-file <file>|-] [--re <bead-id>]
cmd_send() {
  local all=0 bodyfile="" re="" target="" subject="" body="" ids="" id r self
  local positional=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --all) all=1 ;;
      --body-file)
        [ "$#" -ge 2 ] || die_usage "--body-file needs a path"
        bodyfile="$2"
        shift
        ;;
      --re)
        [ "$#" -ge 2 ] || die_usage "--re needs a bead id"
        re="$2"
        shift
        ;;
      -*) die_usage "unknown option for send: $1" ;;
      *) positional+=("$1") ;;
    esac
    shift
  done
  local usage_msg='usage: teamctl send <role>|<team>.<role>|--all "<subject>" ["<body>"] [--body-file <file>|-] [--re <bead-id>]'
  if [ "$all" -eq 1 ]; then
    subject="${positional[0]:-}"
    body="${positional[1]:-}"
  else
    target="${positional[0]:-}"
    subject="${positional[1]:-}"
    body="${positional[2]:-}"
    [ -n "$target" ] || die_usage "$usage_msg"
  fi
  [ -n "$subject" ] || die_usage "$usage_msg"
  if [ -n "$bodyfile" ]; then
    if [ "$bodyfile" = "-" ]; then
      body="$(/bin/cat)"
    else
      [ -r "$bodyfile" ] || die_usage "cannot read --body-file $bodyfile"
      body="$(/bin/cat "$bodyfile")"
    fi
  fi
  [ -z "$re" ] || valid_bead_id "$re" || die_usage "invalid --re bead id '$re'"
  require_tools
  load_project
  store_backend_ready
  self="${BEADS_ACTOR:-${TEAM_ROLE:-}}"
  if [ "$all" -eq 1 ]; then
    for r in $(reg_list); do
      [ "$r" != "${TEAM_ROLE:-}" ] || continue
      id="$(_mail_send_one "$TEAM" "$r" "$subject" "$body" "$re" "$self")" || die "could not create a message for '$r'"
      ids="$ids $id"
    done
    say "${ids# }"
  else
    _mail_send_target "$target"
    id="$(_mail_send_one "$MAIL_SEND_TEAM" "$MAIL_SEND_ROLE" "$subject" "$body" "$re" "$self")" || die "could not create the message"
    say "$id"
  fi
}

# teamctl mail [<role>] [--peek] [--json]
cmd_mail() {
  local role="" peek=0 asjson=0 identity="" caller="" simple="" own=0 rows count line block
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --peek) peek=1 ;;
      --json) asjson=1 ;;
      -*) die_usage "unknown option for inbox: $1" ;;
      *) role="$1" ;;
    esac
    shift
  done
  require_tools
  load_project
  caller="${BEADS_ACTOR:-}"
  if [ -n "$role" ]; then
    case "$role" in
      *.*)
        identity_split "$role"
        valid_team_name "$ID_TEAM" || die_usage "$(team_name_error "$ID_TEAM")"
        known_role_name "$ID_ROLE" || die_usage "invalid role '$role'"
        identity="$(team_identity "$ID_TEAM" "$ID_ROLE")"
        simple="$ID_ROLE"
        ;;
      *)
        known_role_name "$role" || die_usage "invalid role '$role'"
        identity="$(team_identity "$TEAM" "$role")"
        simple="$role"
        ;;
    esac
  else
    [ -n "$caller" ] || die_usage "missing <role> (no agent identity in this shell)"
    identity="$caller"
    identity_split "$identity"
    simple="$ID_ROLE"
  fi
  [ -z "$caller" ] || [ "$identity" != "$caller" ] || own=1
  rows="$(inbox_read "$identity")" || die "could not read the store for '$identity'"
  count="$(printf '%s' "$rows" | "$JQ_BIN" -r 'length' 2>/dev/null)"
  case "$count" in '' | *[!0-9]*) count=0 ;; esac
  if [ "$asjson" -eq 1 ]; then
    printf '%s\n' "$rows"
  elif [ "$count" -eq 0 ]; then
    say "inbox empty"
  else
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      block="$(_mail_render_bead "$line")"
      say "$block"
      say ""
    done < <(printf '%s' "$rows" | "$JQ_BIN" -c '.[]')
  fi
  [ "$own" -eq 1 ] && [ "$peek" -eq 0 ] || return 0
  _mail_inbox_mark_read "$identity" "$simple" "$rows"
}

# _mail_inbox_mark_read <identity> <role> <rows-json> — every message row shown is marked
# read (detached, one store call), and the caller's own mail/new/ is emptied into seen/.
_mail_inbox_mark_read() {
  local identity="$1" role="$2" rows="$3" mids seen new base
  mids="$(printf '%s' "$rows" | "$JQ_BIN" -r '[.[] | select((.issue_type // "task") == "message") | .id] | join(" ")' 2>/dev/null)"
  if [ -n "$mids" ]; then
    # shellcheck disable=SC2086
    (store_msg_read "$identity" $mids >/dev/null 2>&1 &)
  fi
  seen="$(run_dir_ensure "$role")/mail/seen"
  new="$(run_dir "$role")/mail/new"
  for base in $(/bin/ls -1 "$new" 2>/dev/null); do
    [ -f "$new/$base" ] || continue
    /bin/mv -f "$new/$base" "$seen/$base" 2>/dev/null || true
  done
  _mail_prune_seen "$seen"
}
