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
# Both end up in _mail_deliver_to, the one path to a recipient's spool/attention/wake.

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

# _mail_wake_after — WOLFMUX_MAIL_WAKE_AFTER, a plain number 1..3600; nonsense falls back to 90.
_mail_wake_after() {
  local v="${WOLFMUX_MAIL_WAKE_AFTER:-90}"
  case "$v" in '' | *[!0-9]*) v=90 ;; esac
  if [ "$v" -lt 1 ] || [ "$v" -gt 3600 ]; then v=90; fi
  printf '%s\n' "$v"
}

# _mail_type <role> <pane> <text> — the only thing ever typed for mail: one fixed line, built
# from a validated identity, never a bead's own text. Serialized and debounced exactly like
# _nudge_one, so a burst of mail for the same agent still types one line.
_mail_type() {
  local role="$1" pane="$2" text="$3"
  [ -n "$pane" ] && [ "$(tm_pane_state "$pane")" = "running" ] || return 1
  nudge_begin "$role" || return 1
  if [ $(($(now_epoch) - $(nudge_last "$role"))) -lt "$WOLFMUX_NUDGE_DEBOUNCE" ]; then
    nudge_end "$role"
    return 1
  fi
  nudge_mark "$role"
  tm_type_line "$pane" "$text"
  nudge_end "$role"
}

# _mail_watchdog <role> <identity> <spool> <wake-after> — a busy state can be stale (an
# interrupted turn fires no Stop hook). Sleeps first, so it must run detached in the background;
# the caller forks it. If the mail was delivered in the meantime, or the agent is genuinely
# still mid-turn, it says nothing.
_mail_watchdog() {
  local role="$1" identity="$2" spool="$3" wake="$4" pane quiet
  /bin/sleep "$wake" 2>/dev/null
  [ -f "$spool" ] || return 0
  if [ "$(agent_turn_state "$role")" = "busy" ]; then
    quiet="$(agent_quiet_seconds "$role")"
    case "$quiet" in '' | *[!0-9]*) quiet=0 ;; esac
    [ "$quiet" -ge "$wake" ] || return 0
  fi
  pane="$(tm_pane_for_role "$SESSION" "$role")"
  _mail_type "$role" "$pane" "[wolfmux] New mail for $identity: it is shown with this line. If nothing is shown, run: teamctl mail"
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

# _mail_deliver_to <role> <event> <payload-json> <identity> — the one path to a recipient:
# spool it, flag attention, and wake the pane if it is idle (or watch for it to go idle if
# busy); a role with no running pane, or a Codex family agent (no hooks yet), gets the old
# typed nudge instead. Shared by cmd_deliver (the Beads hook) and mail_announce (the native
# store's own delivery). Must never fail or delay whoever called it: every exit here is 0.
_mail_deliver_to() {
  local role="$1" event="$2" payload="$3" identity="$4" bead family pane spool
  known_role_name "$role" && reg_exists "$role" || return 0
  bead="$(printf '%s' "$payload" | "$JQ_BIN" -r '.id // empty' 2>/dev/null)"
  family="$(reg_field "$role" family)"
  pane="$(tm_pane_for_role "$SESSION" "$role")"
  if [ "$family" = "codex" ] || [ -z "$pane" ] || [ "$(tm_pane_state "$pane")" != "running" ]; then
    _nudge_one "$role" "$bead" >/dev/null 2>&1 || true
  elif spool="$(_mail_spool_write "$role" "$event" "$payload")"; then
    agent_attention "$role"
    if [ "$(agent_turn_state "$role")" = "busy" ]; then
      (_mail_watchdog "$role" "$identity" "$spool" "$(_mail_wake_after)") >/dev/null 2>&1 &
    else
      _mail_type "$role" "$pane" "[wolfmux] New mail for $identity: it is shown with this line. If nothing is shown, run: teamctl mail"
    fi
  fi
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

# _mail_mark_shown <file> <seen-dir> <identity> — moves a shown spool file into seen/, prunes
# seen/ to the newest 50, and for a message marks it read for this agent, detached (so the
# agent does not spend a turn doing that itself, and a hook never blocks on the store).
_mail_mark_shown() {
  local file="$1" seen="$2" identity="$3" dest type id
  dest="$seen/$(basename "$file")"
  /bin/mv -f "$file" "$dest" 2>/dev/null || return 0
  type="$("$JQ_BIN" -r '.issue_type // "task"' "$dest" 2>/dev/null)"
  id="$("$JQ_BIN" -r '.id // empty' "$dest" 2>/dev/null)"
  if [ "$type" = "message" ] && valid_bead_id "$id" && [ -n "$identity" ]; then
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
_mail_hook_drain() {
  local dir="$HOOK_RUN/mail" identity="${BEADS_ACTOR:-$HOOK_ROLE}" base file json block budget=0 shown=0 more=0
  [ -d "$dir/new" ] || return 0
  for base in $(/bin/ls -1 "$dir/new" 2>/dev/null | /usr/bin/sort); do
    file="$dir/new/$base"
    [ -f "$file" ] || continue
    json="$(/bin/cat "$file" 2>/dev/null)"
    block="$(_mail_render_bead "$json" 2>/dev/null)"
    if [ "$shown" -gt 0 ] && [ $((budget + ${#block})) -gt "$WOLFMUX_MAIL_HOOK_BUDGET" ]; then
      more=1
      break
    fi
    hook_context "$block"
    budget=$((budget + ${#block}))
    shown=$((shown + 1))
    _mail_mark_shown "$file" "$dir/seen" "$identity"
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
    PostToolUse | UserPromptSubmit | Stop) _mail_hook_drain ;;
    *) ;; # PreCompact: nothing
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
