#!/bin/bash
# restore.sh — `teamctl restore`: after a reboot or a crash, every team that was running comes
# back in one step (v1.21.0).
#
# What it replaces. On 2026-10-15 the Mac crashed at about 13:33Z and every lead died with the
# tmux server. After the reboot each one was brought back by hand: `teamctl restart lead --team X
# --resume "<stored id>"` team by team, `--continue` for the Codex lead (it has no stored id), a
# `teamctl nudge` because a restarted lead's prompt comes up empty, and then one iTerm tab per
# team, attached by hand. Ammar: "my main pain point is that after restart i have to reattach the
# team with each tmux tab by running commands."
#
# Three parts:
#   1. The running set. The status-bar segment (dash_badge_line) hands the pane list it already
#      holds to restore_snapshot_tick, which writes ~/.wolfmux/state/running.json at most once a
#      minute: every team whose lead pane runs, and the sessions the attached clients show, in
#      the order those clients were created (the order of the terminal tabs).
#   2. The plan. Every team of the last snapshot whose lead is not running now, unless its lead
#      was ended on purpose after that snapshot (lead-end.json, lib/finish.sh: stop, finish,
#      destroy) or the team is gone. A team that was already orphaned when the snapshot was
#      taken is not in it, and stays down. Leads only: the lanes are each lead's to restart.
#   3. The act. One lead at a time, through `teamctl restart lead` (so the model, the
#      permissions and the steward's ledger are restart's own, never decided here), each one
#      started only when the machine has room, each told by Beads and by one nudge; then one
#      iTerm2 tab per team.
#
# Which snapshot is "the last one". The tmux server dies with a reboot, and the first status bar
# drawn on the NEW server would overwrite the old server's last view with a nearly empty one —
# the moment you attach the first team by hand. So every snapshot names the server it was taken
# on ("<pid> <start time>"), and the first write on another server moves the old file aside to
# running.prev.json instead of overwriting it. Restore reads the old server's last view (the
# file whose server is not the one running now) plus the current server's own.

RESTORE_SNAPSHOT_EVERY="${WOLFMUX_RESTORE_SNAPSHOT_EVERY:-60}" # seconds between two snapshots
RESTORE_UP_MAX="${WOLFMUX_RESTORE_UP_MAX:-90}"                 # a lead counts as up after this long
RESTORE_POLL="${WOLFMUX_RESTORE_POLL:-2}"                      # seconds between two looks
RESTORE_MIN_FREE="${WOLFMUX_RESTORE_MIN_FREE:-25}"             # % of memory free before a start
RESTORE_MAX_LOAD="${WOLFMUX_RESTORE_MAX_LOAD:-20}"             # one-minute load before a start
RESTORE_WAIT_STEP="${WOLFMUX_RESTORE_WAIT_STEP:-15}"           # seconds between two looks while busy
RESTORE_WAIT_MAX="${WOLFMUX_RESTORE_WAIT_MAX:-600}"            # then restore gives up and says so
RESTORE_LIMIT_WAIT="${WOLFMUX_RESTORE_LIMIT_WAIT:-20}"         # time a nudged lead gets to answer
# Whole numbers only, checked here with the shell alone: this file is sourced by every teamctl
# call, the status bar's included, so nothing at this level may start a process.
case "$RESTORE_SNAPSHOT_EVERY" in "" | *[!0-9]* | 0?*) RESTORE_SNAPSHOT_EVERY=60 ;; esac
case "$RESTORE_UP_MAX" in "" | *[!0-9]* | 0?*) RESTORE_UP_MAX=90 ;; esac
case "$RESTORE_POLL" in "" | *[!0-9]* | 0 | 0?*) RESTORE_POLL=2 ;; esac
case "$RESTORE_MIN_FREE" in "" | *[!0-9]* | 0?*) RESTORE_MIN_FREE=25 ;; esac
case "$RESTORE_MAX_LOAD" in "" | *[!0-9]* | 0?*) RESTORE_MAX_LOAD=20 ;; esac
case "$RESTORE_WAIT_STEP" in "" | *[!0-9]* | 0 | 0?*) RESTORE_WAIT_STEP=15 ;; esac
case "$RESTORE_WAIT_MAX" in "" | *[!0-9]* | 0?*) RESTORE_WAIT_MAX=600 ;; esac
case "$RESTORE_LIMIT_WAIT" in "" | *[!0-9]* | 0?*) RESTORE_LIMIT_WAIT=20 ;; esac
RESTORE_MEMORY_PRESSURE="${WOLFMUX_MEMORY_PRESSURE:-/usr/bin/memory_pressure}"
RESTORE_US=$'\037' # the unit separator: an empty field survives `read`, a tab would not

restore_snapshot_file() { printf '%s/state/running.json\n' "$WOLFMUX_DATA"; }
restore_previous_file() { printf '%s/state/running.prev.json\n' "$WOLFMUX_DATA"; }
restore_log_file() { printf '%s/state/restore.log\n' "$WOLFMUX_DATA"; }
# Where Claude Code keeps one record per running CLI (<pid>.json, with its sessionId)
restore_sessions_dir() { printf '%s\n' "${WOLFMUX_CLAUDE_SESSIONS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions}"; }

# --- 1. the running set ----------------------------------------------------------------
# _restore_tmux <args> — the server the status bar is drawn on: the socket it was handed
# (DASH_SOCKET, lib/dashboard.sh says why it is never guessed), else tmx.
_restore_tmux() {
  if [ -n "${DASH_SOCKET:-}" ]; then "$TMUX_BIN" -S "$DASH_SOCKET" "$@"; else tmx "$@"; fi
}

# _restore_head <file> — sets RS_EPOCH and RS_SERVER from a snapshot's first line, read with the
# shell's own `read`: the freshness check runs on every redraw of the status bar, so it starts
# no process. The snapshot is one line of JSON that starts {"epoch":N, on purpose.
_restore_head() {
  local line=""
  RS_EPOCH="" RS_SERVER=""
  [ -f "$1" ] || return 1
  IFS= read -r line <"$1" 2>/dev/null || [ -n "$line" ] || return 1
  case "$line" in '{"epoch":'*) ;; *) return 1 ;; esac
  RS_EPOCH="${line#\{\"epoch\":}"
  RS_EPOCH="${RS_EPOCH%%,*}"
  case "$RS_EPOCH" in "" | *[!0-9]* | 0?*) RS_EPOCH="" ;; esac
  case "$line" in
    *'"server":"'*)
      RS_SERVER="${line#*\"server\":\"}"
      RS_SERVER="${RS_SERVER%%\"*}"
      ;;
  esac
  return 0
}

# _restore_fresh <file> <now> — written less than RESTORE_SNAPSHOT_EVERY seconds ago. A stamp
# from the future (the clock was set back) is not fresh: it would be for ever.
_restore_fresh() {
  _restore_head "$1" && [ -n "$RS_EPOCH" ] && [ "$RS_EPOCH" -le "$2" ] && [ $(($2 - RS_EPOCH)) -lt "$RESTORE_SNAPSHOT_EVERY" ]
}

# restore_snapshot_tick <panes> — called by the status-bar segment with the pane list it already
# holds (dash_panes). Fresh: returns after one `date` and one `read`. Otherwise, once a minute:
# one tmux call (list-clients), one jq, a temp file and a mv. No bd, no ps, no du. Never fails
# and never prints: a status bar must not break because a snapshot could not be written.
restore_snapshot_tick() {
  local file now lock
  [ -n "$TMUX_BIN" ] && [ -n "$JQ_BIN" ] || return 0
  file="$WOLFMUX_DATA/state/running.json"
  now="$(now_epoch)"
  case "$now" in "" | *[!0-9]*) return 0 ;; esac
  _restore_fresh "$file" "$now" && return 0
  [ -d "$WOLFMUX_DATA/state" ] || return 0
  # Every attached client draws its own status bar, so two redraws can reach this together. The
  # lock is a directory (mkdir is atomic); one that a killed redraw left behind is taken after a
  # minute.
  lock="$file.lock"
  if ! /bin/mkdir "$lock" 2>/dev/null; then
    [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] || return 0
    /bin/rmdir "$lock" 2>/dev/null || true
    /bin/mkdir "$lock" 2>/dev/null || return 0
  fi
  _restore_snapshot_write "${1:-}" "$file" "$now" >/dev/null 2>&1 || true
  /bin/rmdir "$lock" 2>/dev/null || true
  return 0
}

# _restore_snapshot_write <panes> <file> <now> — the write itself, under the lock
_restore_snapshot_write() {
  local panes="$1" file="$2" now="$3" clients server key name dir session row team dirs="" files=() tmp
  _restore_fresh "$file" "$now" && return 0 # another redraw wrote it while this one waited
  clients="$(_restore_tmux list-clients -F '#{pid} #{start_time}|#{client_created}|#{client_session}' 2>/dev/null || true)"
  server="${clients%%|*}"
  # The status bar is only drawn for an attached client, so there is one. Without it nothing
  # says which server this is, and a snapshot that names no server could not be told apart from
  # the last view of a server that is gone: write nothing.
  [ -n "$server" ] || return 0
  for key in "$WOLFMUX_DATA"/state/*/; do
    [ -d "$key" ] && [ -r "$key" ] || continue
    name="${key%/}"
    name="${name##*/}"
    for dir in "$key" "$key"teams/*/; do
      dir="${dir%/}"
      [ -f "$dir/agents/$WOLFMUX_LEAD_ROLE.json" ] && [ -f "$dir/meta.json" ] || continue
      session="$(dash_meta_session "$dir")"
      [ -n "$session" ] || continue
      row="$(dash_pane_row "$panes" "$session" "$WOLFMUX_LEAD_ROLE")"
      ! dash_orphaned "$row" || continue
      if [ "$dir" = "${key%/}" ]; then team="$WOLFMUX_DEFAULT_TEAM"; else team="${dir##*/}"; fi
      dirs="$dirs$name$RESTORE_US$team$RESTORE_US$dir$DASH_NL"
      files+=("$dir/meta.json" "$dir/agents/$WOLFMUX_LEAD_ROLE.json")
    done
  done
  tmp="$file.$$"
  # One jq for every team: input_filename says which record each file is.
  if ! "$JQ_BIN" -cn --argjson epoch "$now" --arg server "$server" --arg clients "$clients" \
    --arg dirs "$dirs" --arg lead "$WOLFMUX_LEAD_ROLE" '
    (reduce inputs as $r ({}; .[input_filename] = $r)) as $f
    | [$dirs | split("\n")[] | select(. != "") | split("\u001f") | {key: .[0], team: .[1], dir: .[2]}
       | ($f[.dir + "/meta.json"] // {}) as $m | ($f[.dir + "/agents/" + $lead + ".json"] // {}) as $l
       | {key, team, root: ($m.root // ""), session: ($m.session // ""),
          model: ($l.model // ""), family: ($l.family // ""), label: ($l.label // ""),
          session_id: ($l.session_id // ""),
          founder: ([$l.spawned_by, $m.founder] | map(select(type == "string" and . != "")) | .[0] // "operator")}] as $teams
    | {epoch: $epoch, ts: ($epoch | todate), server: $server, teams: $teams,
       tabs: ([$clients | split("\n")[] | select(. != "") | split("|")
               | {created: ((.[1] // "0") | tonumber? // 0), session: (.[2] // "")}]
              | sort_by(.created)
              | reduce .[] as $c ([]; if any(.[]; .session == $c.session) then . else . + [$c] end)
              | map(. as $c | ($teams | map(select(.session == $c.session)) | .[0]) as $t
                    | select($t != null) | {session: $c.session, created: $c.created, key: $t.key, team: $t.team}))}
    ' ${files[@]+"${files[@]}"} </dev/null >"$tmp" 2>/dev/null; then
    /bin/rm -f "$tmp"
    return 1
  fi
  # The last view of a server that is gone is the one restore needs: kept, never overwritten.
  if _restore_head "$file" && [ -n "$RS_SERVER" ] && [ "$RS_SERVER" != "$server" ]; then
    /bin/mv -f "$file" "$(restore_previous_file)" 2>/dev/null || true
  fi
  /bin/mv -f "$tmp" "$file" || {
    /bin/rm -f "$tmp"
    return 1
  }
}

# --- 2. the plan ----------------------------------------------------------------------
# restore_current_server — "<pid> <start time>" of the team server running now; empty when none
restore_current_server() {
  [ -n "$TMUX_BIN" ] || return 0
  tmx display-message -p '#{pid} #{start_time}' 2>/dev/null || true
}

# restore_snapshot_lines — what the snapshots say, one line each, fields split by RESTORE_US:
#   T key team root seen session model family label session_id founder   a team seen running
#   B key team                                                          a tab, in tab order
# Sets RS_FILES (the snapshots read, for the plan's header) and RS_WHEN (the time of the newest
# view of a server that is gone: "the reboot at <time>"). Returns 1 when there is no snapshot.
restore_snapshot_lines() {
  local main prev current files=()
  main="$(restore_snapshot_file)"
  prev="$(restore_previous_file)"
  current="$(restore_current_server)"
  RS_FILES="" RS_WHEN=""
  if _restore_head "$main" && { [ -z "$current" ] || [ "$RS_SERVER" != "$current" ]; }; then
    # No server, or not the one that wrote it: running.json is the last view of a server that is gone.
    files=("$main")
  else
    [ -f "$prev" ] && files+=("$prev")
    [ -f "$main" ] && files+=("$main")
  fi
  [ "${#files[@]}" -gt 0 ] || return 1
  RS_FILES="${files[*]}"
  RS_WHEN="$("$JQ_BIN" -r -s --arg current "$current" \
    'map(select(.server != $current)) | map(.ts // empty) | max // empty' "${files[@]}" 2>/dev/null || true)"
  # Oldest first, so a team seen in both keeps the newer time; tabs from the gone server first.
  "$JQ_BIN" -r -s '
    ([.[] | .ts as $ts | .teams[]? | . + {seen: $ts}]
     | reduce .[] as $t ({}; .[$t.key + "/" + $t.team] = $t) | to_entries | map(.value) | sort_by(.seen, .key, .team)
     | .[] | ["T", .key, .team, .root, .seen, .session, .model, .family, .label, .session_id, .founder]),
    ([.[] | .tabs[]?] | reduce .[] as $b ([]; if any(.[]; .key == $b.key and .team == $b.team) then . else . + [$b] end)
     | .[] | ["B", .key, .team])
    | map(tostring) | join("\u001f")' "${files[@]}" 2>/dev/null
}

# restore_project <key> <root> <team> — point the team helpers at that team of that project
restore_project() {
  PROJECT_KEY="$1"
  PROJECT_STATE="$WOLFMUX_DATA/state/$1"
  PROJECT_TREES="$WOLFMUX_DATA/worktrees/$1"
  ROOT="$2"
  team_paths "$3"
}

# restore_who — who is asking. RESTORE_AS: operator | steward | "" (nobody restore may serve);
# RESTORE_BY: how the logs name them; RESTORE_STEWARD_KEY / _TEAM: the steward's project and team.
#
# You may restore everything. The lead of the orphan-steward team may restore the leads of teams
# YOU founded, in its own project, and nothing else: that is the v1.20.0 steward rule, and the
# restart restore runs for it is checked by that rule again (steward_may_act). Nobody else.
restore_who() {
  local role root team steward
  RESTORE_AS="" RESTORE_BY="operator" RESTORE_STEWARD_KEY="" RESTORE_STEWARD_TEAM=""
  role="$(caller_role)"
  if [ -z "$role" ]; then
    RESTORE_AS="operator"
    return 0
  fi
  RESTORE_BY="$(caller_identity 2>/dev/null || printf '%s' "$role")"
  [ "$role" = "$WOLFMUX_LEAD_ROLE" ] || return 0
  root="$(resolve_root 2>/dev/null)" || return 0
  PROJECT_KEY="$(project_key "$root")"
  PROJECT_STATE="$WOLFMUX_DATA/state/$PROJECT_KEY"
  steward="$(orphan_steward)"
  team="$(caller_team)"
  [ -n "$steward" ] && [ "$steward" = "${team:-$WOLFMUX_DEFAULT_TEAM}" ] || return 0
  RESTORE_AS="steward"
  RESTORE_STEWARD_KEY="$PROJECT_KEY"
  RESTORE_STEWARD_TEAM="$steward"
}

# _restore_end_ts — when the lead's last session was ended on purpose (lead-end.json), or nothing
_restore_end_ts() {
  [ -f "$(team_end_file)" ] || return 0
  "$JQ_BIN" -r '.ts // empty' "$(team_end_file)" 2>/dev/null || true
}

# restore_verdict <seen> — what to do with the loaded team. Sets RV (restore | up | ended | gone |
# notyours), RV_WHY (the reason a skip prints), RV_HOW (resume | continue), RV_SID, RV_FAMILY,
# RV_NOTE (what the report must say about how it comes back).
restore_verdict() {
  local seen="$1" end founder
  RV="" RV_WHY="" RV_HOW="" RV_SID="" RV_FAMILY="" RV_NOTE=""
  if [ ! -d "$ROOT" ]; then
    RV="gone" RV_WHY="its folder is gone ($(short_path "$ROOT"))"
    return 0
  fi
  if [ ! -f "$STATE_DIR/agents/$WOLFMUX_LEAD_ROLE.json" ]; then
    RV="gone" RV_WHY="no longer on record (finished, destroyed or purged)"
    return 0
  fi
  if team_lead_running; then
    RV="up" RV_WHY="its lead is running"
    return 0
  fi
  end="$(_restore_end_ts)"
  # ISO times in UTC compare as strings. The same second counts as after: the snapshot saw the lead
  # running, so a stop written in that second came after it.
  if [ -n "$end" ] && [ -n "$seen" ] && [[ ! "$end" < "$seen" ]]; then
    RV="ended" RV_WHY="$(team_end_words) (after the snapshot: on purpose)"
    return 0
  fi
  if [ "$RESTORE_AS" = "steward" ]; then
    founder="$(team_founder)"
    if [ "$PROJECT_KEY" != "$RESTORE_STEWARD_KEY" ]; then
      RV="notyours" RV_WHY="another project: the orphan steward acts in its own project only"
      return 0
    fi
    if [ "$founder" != "operator" ]; then
      RV="notyours" RV_WHY="founded by $founder: its founder or the human restores it"
      return 0
    fi
  fi
  RV="restore"
  RV_FAMILY="$(reg_field "$WOLFMUX_LEAD_ROLE" family 2>/dev/null || true)"
  RV_SID="$(reg_field "$WOLFMUX_LEAD_ROLE" session_id 2>/dev/null || true)"
  if [ "$RV_FAMILY" = "codex" ]; then
    RV_HOW="continue" RV_SID="" RV_NOTE="Codex: --continue (it has no stored id)"
  elif [ -z "$RV_SID" ]; then
    RV_HOW="continue" RV_NOTE="no stored conversation id: --continue resumes the newest one in its folder, which may be another lead's"
  elif [ -z "$(session_transcript "$RV_SID" "$(reg_field "$WOLFMUX_LEAD_ROLE" workdir 2>/dev/null || true)")" ]; then
    RV_HOW="continue" RV_NOTE="conversation $RV_SID has no transcript here: it starts fresh under the same id"
  else
    RV_HOW="resume"
  fi
}

# restore_args — the restart's arguments for the loaded verdict
restore_args() {
  if [ "$RV_HOW" = "resume" ]; then printf '%s\n' "--resume" "$RV_SID"; else printf '%s\n' "--continue"; fi
}

# --- 3. the act -----------------------------------------------------------------------
# restore_teamctl — what restore runs restart and nudge with. The binary running now; tests
# point WOLFMUX_RESTORE_TEAMCTL at a stand-in that writes down what it was asked.
restore_teamctl() { printf '%s\n' "${WOLFMUX_RESTORE_TEAMCTL:-$TEAMCTL_SELF}"; }

# _restore_in <root> <team> <teamctl args...> — teamctl, in that project and that team. stdin is
# closed: restart must never wait on a question, and must not eat the answer typed to restore.
_restore_in() {
  local root="$1" team="$2"
  shift 2
  (cd "$root" 2>/dev/null || cd /; WOLFMUX_ROOT="$root" "$(restore_teamctl)" --team "$team" "$@" </dev/null)
}

# restore_free_pct — "System-wide memory free percentage: 64%" from memory_pressure; empty if unknown
restore_free_pct() {
  [ -x "$RESTORE_MEMORY_PRESSURE" ] || return 0
  "$RESTORE_MEMORY_PRESSURE" 2>/dev/null | sed -n 's/.*free percentage: *\([0-9][0-9]*\)%.*/\1/p' | tail -n 1
}

# restore_load — the one-minute load average ("17.24"); WOLFMUX_RESTORE_LOAD stands in for it in tests
restore_load() {
  if [ -n "${WOLFMUX_RESTORE_LOAD:-}" ]; then printf '%s\n' "$WOLFMUX_RESTORE_LOAD"; else dash_load; fi
}

# _restore_over <load> <max> — is that load over the max? Whole part first, then any fraction.
_restore_over() {
  local whole="${1%%.*}" frac=""
  case "$1" in *.*) frac="${1#*.}" ;; esac
  case "$whole" in "" | *[!0-9]*) return 1 ;; esac
  [ "$((10#$whole))" -gt "$2" ] && return 0
  [ "$((10#$whole))" -eq "$2" ] && case "$frac" in *[1-9]*) return 0 ;; esac
  return 1
}

# restore_room — wait until the machine has room for one more lead: memory free at least
# RESTORE_MIN_FREE %, load at most RESTORE_MAX_LOAD. Says why it waits. Returns 1 with
# RESTORE_BUSY set after RESTORE_WAIT_MAX seconds. A reading nobody can take does not hold a
# start back: there is nothing to wait for.
restore_room() {
  local waited=0 free load why
  RESTORE_BUSY=""
  while :; do
    free="$(restore_free_pct)"
    load="$(restore_load)"
    why=""
    case "$free" in "" | *[!0-9]*) ;; *) [ "$free" -ge "$RESTORE_MIN_FREE" ] || why="memory free ${free}% (under ${RESTORE_MIN_FREE}%)" ;; esac
    if [ -n "$load" ] && _restore_over "$load" "$RESTORE_MAX_LOAD"; then why="${why:+$why, }load $load (over $RESTORE_MAX_LOAD)"; fi
    [ -n "$why" ] || return 0
    if [ "$waited" -ge "$RESTORE_WAIT_MAX" ]; then
      RESTORE_BUSY="$why, still after ${waited}s"
      return 1
    fi
    say "    waiting: $why; looking again in ${RESTORE_WAIT_STEP}s (gives up after ${RESTORE_WAIT_MAX}s)"
    sleep "$RESTORE_WAIT_STEP"
    waited=$((waited + RESTORE_WAIT_STEP))
  done
}

# _restore_session_record <sid> <session> <marker> — the Claude Code record of a CLI started
# after the marker and still alive, for that conversation (or, with no id, in that tmux session).
# Prints its sessionId. A record left by a CLI that died in the crash is older than the marker,
# and its pid is gone or someone else's: neither passes.
_restore_session_record() {
  local sid="$1" session="$2" marker="$3" dir f pid found
  dir="$(restore_sessions_dir)"
  [ -d "$dir" ] || return 1
  for f in "$dir"/*.json; do
    [ "$f" -nt "$marker" ] || continue
    pid="${f##*/}"
    pid="${pid%.json}"
    case "$pid" in "" | *[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null || continue
    # Parse JSON rather than its spacing, and keep each pathname intact.
    found="$("$JQ_BIN" -er --arg sid "$sid" --arg session "$session:" '
      select(if $sid != "" then .sessionId == $sid
             else (.tmux // "" | startswith($session)) end)
      | .sessionId | strings | select(. != "")' "$f" 2>/dev/null)" || continue
    printf '%s\n' "$found"
    return 0
  done
  return 1
}

# restore_wait_up <family> <sid> <marker> — wait for the loaded team's lead to be up.
#   0  up: the Claude session record names that conversation (RU_SID: the one it runs)
#   1  RESTORE_UP_MAX passed with the pane running: counted as up, and said so
#   2  its pane exited, or there is none
# No screen is read for any of it (lib/views.sh: terminal output is never parsed for state).
restore_wait_up() {
  local family="$1" sid="$2" marker="$3" waited=0 session pane state found
  RU_SID="$sid"
  session="$(session_name_for_project)"
  while :; do
    pane="$(tm_pane_for_role "$session" "$WOLFMUX_LEAD_ROLE" 2>/dev/null || true)"
    state="$(tm_pane_state "$pane")"
    [ "$state" = "running" ] || return 2
    if [ "$family" != "codex" ]; then
      if found="$(_restore_session_record "$sid" "$session" "$marker")"; then
        [ -z "$found" ] || RU_SID="$found"
        return 0
      fi
    fi
    [ "$waited" -lt "$RESTORE_UP_MAX" ] || return 1
    sleep "$RESTORE_POLL"
    waited=$((waited + RESTORE_POLL))
  done
}

# restore_tell <root> <team> <title> <body> — one Beads message to the team's lead, and one nudge.
# Prints the bead id, or nothing when Beads could not take it (the nudge is sent either way).
restore_tell() {
  local root="$1" team="$2" title="$3" body="$4" who bead=""
  who="$(team_identity "$team" "$WOLFMUX_LEAD_ROLE")"
  if [ -n "$BD_BIN" ]; then
    bead="$( (cd "$root" 2>/dev/null && BEADS_ACTOR="${BEADS_ACTOR:-$WOLFMUX_HUMAN}" "$BD_BIN" create "$title" -t message -a "$who" -d "$body" --silent </dev/null 2>/dev/null) | tail -n 1 || true)"
    valid_bead_id "$bead" 2>/dev/null || bead=""
  fi
  if [ -n "$bead" ]; then
    _restore_in "$root" "$team" nudge "$WOLFMUX_LEAD_ROLE" --id "$bead" >/dev/null 2>&1 || true
  else
    _restore_in "$root" "$team" nudge "$WOLFMUX_LEAD_ROLE" >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$bead"
}

# restore_limit_text <transcript> <since> — the usage-limit error the CLI wrote after <since>
# ("You've reached your Fable limit…", "You've hit your session limit…"), or nothing. Read from
# the transcript's tail, never from the screen.
restore_limit_text() {
  [ -n "${1:-}" ] && [ -r "$1" ] || return 0
  tail -n 80 "$1" 2>/dev/null | "$JQ_BIN" -R -r --arg since "$2" '
    fromjson? | objects | select(.isApiErrorMessage == true and ((.timestamp // "") >= $since))
    | [.message.content[]? | objects | .text? | strings] | join(" ")
    | select(test("limit"; "i"))' 2>/dev/null | tail -n 1
}

# restore_log <key> <team> <what> <result> — one line in the machine-wide record of restores
restore_log() {
  { "$JQ_BIN" -cn --arg ts "$(now_iso)" --arg by "$RESTORE_BY" --arg key "$1" --arg team "$2" \
    --arg what "$3" --arg result "$4" '{ts: $ts, by: $by, project: $key, team: $team, what: $what, result: $result}' \
    >>"$(restore_log_file)"; } 2>/dev/null || true
}

# _restore_cmd_text <root> <team> — the attach a tab runs, as you would type it
_restore_cmd_text() {
  local self="teamctl"
  [ "$(command -v teamctl 2>/dev/null || true)" = "$TEAMCTL_SELF" ] || self="$TEAMCTL_SELF"
  printf 'cd %q && %q --team %q attach\n' "$1" "$self" "$2"
}

# _restore_as_string <text> — an AppleScript string literal
_restore_as_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# restore_tabs_applescript <command>... — the AppleScript that opens one iTerm2 window with one
# tab per command, in the order given, each typing its command into a login shell. Only builds the
# text, so tests can read it without anything being opened.
restore_tabs_applescript() {
  local first=1 cmd
  printf 'tell application "iTerm2"\n'
  printf '  activate\n'
  for cmd in "$@"; do
    if [ "$first" -eq 1 ]; then
      printf '  set w to (create window with default profile)\n'
      printf '  tell current session of w to write text %s\n' "$(_restore_as_string "$cmd")"
      first=0
    else
      printf '  tell w to set t to (create tab with default profile)\n'
      printf '  tell current session of t to write text %s\n' "$(_restore_as_string "$cmd")"
    fi
  done
  printf 'end tell\n'
}

# restore_open_tabs <command>... — run that script. 0 opened; 1 iTerm2 is not running or osascript
# failed (RESTORE_TABS_WHY says which), and nothing was opened by us.
restore_open_tabs() {
  local osascript="${WOLFMUX_OSASCRIPT:-/usr/bin/osascript}" running out
  RESTORE_TABS_WHY=""
  if [ ! -x "$osascript" ]; then
    RESTORE_TABS_WHY="osascript is not there"
    return 1
  fi
  running="$("$osascript" -e 'application "iTerm2" is running' 2>/dev/null || true)"
  if [ "$running" != "true" ]; then
    RESTORE_TABS_WHY="iTerm2 is not running"
    return 1
  fi
  if ! out="$(restore_tabs_applescript "$@" | "$osascript" - 2>&1)"; then
    RESTORE_TABS_WHY="osascript failed (${out:-no message}; is Automation allowed for your terminal in System Settings, Privacy & Security?)"
    return 1
  fi
  return 0
}

# _restore_tab_order — ORDER: the indices of the pool (P_KEY, P_TEAM, P_ROOT) in the order their
# tabs had before (B_KEY, B_TEAM: the snapshot's clients, oldest first), then the rest in pool order.
_restore_tab_order() {
  local i j used=","
  ORDER=()
  for ((i = 0; i < ${#B_TEAM[@]}; i++)); do
    for ((j = 0; j < ${#P_TEAM[@]}; j++)); do
      case "$used" in *",$j,"*) continue ;; esac
      [ "${P_KEY[$j]}" = "${B_KEY[$i]}" ] && [ "${P_TEAM[$j]}" = "${B_TEAM[$i]}" ] || continue
      ORDER+=("$j")
      used="$used$j,"
    done
  done
  for ((j = 0; j < ${#P_TEAM[@]}; j++)); do
    case "$used" in *",$j,"*) continue ;; esac
    ORDER+=("$j")
  done
}

# --- teamctl restore [--dry-run] [--yes] [--no-tabs] ------------------------------------
cmd_restore() {
  local dry=0 yes=0 tabs=1 snap kind key team root seen session model family label sid founder
  local n i j answer tag marker rc out bead busy=0 policy limit transcript since clients names
  local -a T_KEY=() T_TEAM=() T_ROOT=() T_SEEN=() T_HOW=() T_SID=() T_FAMILY=() T_NOTE=() T_LABEL=()
  local -a U_KEY=() U_TEAM=() U_ROOT=() R_KEY=() R_TEAM=() R_ROOT=() R_SID=() R_FAMILY=() R_SINCE=() R_LABEL=()
  local -a B_KEY=() B_TEAM=() P_KEY=() P_TEAM=() P_ROOT=() ORDER=()
  local -a SKIPS=() FAILS=() LIMITS=() MOVED=() NOTES=() TAB_CMDS=() ATTACHED=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run | -n) dry=1 ;;
      --yes | -y) yes=1 ;;
      --no-tabs) tabs=0 ;;
      *) die_usage "usage: teamctl restore [--dry-run] [--yes] [--no-tabs]" ;;
    esac
    shift
  done
  require_tools
  restore_who
  if [ "$dry" -eq 0 ] && [ -z "$RESTORE_AS" ]; then
    die "'teamctl restore' restarts the leads of every team on this machine, so it is the human's to run, from their own terminal (and, for the teams the human founded, the orphan steward's: teamctl policy orphan-steward). You are '$RESTORE_BY'. What is yours: teamctl restore --dry-run shows the plan; to bring a team back, ask your lead or the human." 77
  fi

  # --- the plan
  snap="$(mktemp "${TMPDIR:-/tmp}/wolfmux-restore.XXXXXX")" || die "cannot write a temporary file in ${TMPDIR:-/tmp}"
  if ! restore_snapshot_lines >"$snap" 2>/dev/null; then
    /bin/rm -f "$snap"
    say "$WOLFMUX_LEAD_MARK nothing to restore: there is no snapshot of the running teams yet ($(short_path "$(restore_snapshot_file)"))."
    say "  The status bar writes one once a minute while a team is attached. One team by hand: teamctl restart lead --team <name> --continue"
    return 0
  fi
  while IFS="$RESTORE_US" read -r kind key team root seen session model family label sid founder; do
    case "$kind" in
      T)
        valid_team_name "$team" || continue
        restore_project "$key" "$root" "$team"
        restore_verdict "$seen"
        case "$RV" in
          restore)
            T_KEY+=("$key") T_TEAM+=("$team") T_ROOT+=("$root") T_SEEN+=("$seen") T_HOW+=("$RV_HOW")
            T_SID+=("$RV_SID") T_FAMILY+=("$RV_FAMILY") T_NOTE+=("$RV_NOTE") T_LABEL+=("${label:-$model}")
            ;;
          up) U_KEY+=("$key") U_TEAM+=("$team") U_ROOT+=("$root") ;;
          *) SKIPS+=("$team ($(short_path "$root")): $RV_WHY") ;;
        esac
        ;;
      B) B_KEY+=("$key") B_TEAM+=("$team") ;;
    esac
  done <"$snap"
  /bin/rm -f "$snap"
  n="${#T_TEAM[@]}"

  say "$WOLFMUX_LEAD_MARK restore: the teams that were running${RS_WHEN:+ when the last server was last seen ($(_finish_when "$RS_WHEN"))}"
  if [ "$n" -eq 0 ]; then
    say "  nothing to restore: every team of the snapshot is running, or was ended on purpose, or is gone."
  else
    say "  will restore $n team(s), one at a time:"
    for ((i = 0; i < n; i++)); do
      if [ "${T_HOW[$i]}" = "resume" ]; then tag="--resume ${T_SID[$i]}"; else tag="--continue"; fi
      say "    ${T_TEAM[$i]}  ($(short_path "${T_ROOT[$i]}"), ${T_LABEL[$i]:-?})  teamctl restart lead --team ${T_TEAM[$i]} $tag"
      [ -z "${T_NOTE[$i]}" ] || say "      note: ${T_NOTE[$i]}"
    done
  fi
  if [ "${#U_TEAM[@]}" -gt 0 ]; then say "  already up: ${U_TEAM[*]}"; fi
  for ((i = 0; i < ${#SKIPS[@]}; i++)); do say "  skip ${SKIPS[$i]}"; done
  P_KEY=(${T_KEY[@]+"${T_KEY[@]}"} ${U_KEY[@]+"${U_KEY[@]}"})
  P_TEAM=(${T_TEAM[@]+"${T_TEAM[@]}"} ${U_TEAM[@]+"${U_TEAM[@]}"})
  P_ROOT=(${T_ROOT[@]+"${T_ROOT[@]}"} ${U_ROOT[@]+"${U_ROOT[@]}"})
  _restore_tab_order
  names=""
  for j in ${ORDER[@]+"${ORDER[@]}"}; do names="${names:+$names, }${P_TEAM[$j]}"; done
  if [ "$tabs" -eq 0 ]; then
    say "  tabs: none (--no-tabs)"
  elif [ -n "$names" ]; then
    say "  then one iTerm2 tab each, in this order, unless a terminal already shows it: $names"
  fi
  if [ "$dry" -eq 1 ]; then
    say ""
    say "dry run: nothing was restarted. Run it: teamctl restore   (--yes: without asking · --no-tabs: no iTerm2 tabs)"
    [ -n "$RESTORE_AS" ] || say "  (anyone may look; restoring is the human's, and the orphan steward's for the teams the human founded)"
    return 0
  fi
  if [ "$n" -gt 0 ] && [ "$yes" -eq 0 ]; then
    printf 'Press Enter to restore %s team(s); anything else aborts: ' "$n" >&2
    answer="x"
    IFS= read -r answer || answer="x"
    if [ -n "$answer" ]; then
      say "aborted: nothing was restarted."
      return 1
    fi
  fi

  # --- the leads, one at a time
  for ((i = 0; i < n; i++)); do
    key="${T_KEY[$i]}" team="${T_TEAM[$i]}" root="${T_ROOT[$i]}"
    restore_project "$key" "$root" "$team"
    say ""
    say "  [$((i + 1))/$n] $team ($(short_path "$root"))"
    # A second run, or a run after a crash halfway through: whatever is up now is left alone.
    if team_lead_running; then
      say "    already up"
      U_KEY+=("$key") U_TEAM+=("$team") U_ROOT+=("$root")
      continue
    fi
    if [ "$busy" -eq 1 ]; then
      FAILS+=("$team: not started, the machine stayed busy")
      restore_log "$key" "$team" "restart" "not started: busy"
      continue
    fi
    if ! restore_room; then
      say "    gave up waiting: $RESTORE_BUSY"
      busy=1
      FAILS+=("$team: not started, the machine stayed busy ($RESTORE_BUSY)")
      restore_log "$key" "$team" "restart" "not started: busy"
      continue
    fi
    if [ "${T_HOW[$i]}" = "resume" ]; then
      set -- --resume "${T_SID[$i]}"
      tag="resume ${T_SID[$i]}"
    else
      set -- --continue
      tag="continue"
    fi
    # The session record a new CLI writes has to be NEWER than this marker, and the test is to the second.
    marker="$(mktemp "${TMPDIR:-/tmp}/wolfmux-restore.XXXXXX" 2>/dev/null)" || marker=""
    sleep 1
    since="$(now_iso)"
    EVENT_BY="$RESTORE_BY" event_log restore "$WOLFMUX_LEAD_ROLE" "$tag" 2>/dev/null || true
    rc=0
    out="$(_restore_in "$root" "$team" restart "$WOLFMUX_LEAD_ROLE" "$@" 2>&1)" || rc=$?
    [ -z "$out" ] || printf '%s\n' "$out" | sed -e '/^$/d' -e 's/^/    /'
    if [ "$rc" -ne 0 ]; then
      [ -z "$marker" ] || /bin/rm -f "$marker"
      FAILS+=("$team: restart failed (exit $rc)")
      restore_log "$key" "$team" "restart $tag" "failed: exit $rc"
      continue
    fi
    rc=0
    restore_wait_up "${T_FAMILY[$i]}" "${T_SID[$i]}" "${marker:-/dev/null}" || rc=$?
    [ -z "$marker" ] || /bin/rm -f "$marker"
    case "$rc" in
      0) say "    up: conversation ${RU_SID:-?} is running" ;;
      1)
        if [ "${T_FAMILY[$i]}" = "codex" ]; then
          say "    up: its pane runs (${RESTORE_UP_MAX}s passed; Codex keeps no session record to look at)"
        else
          say "    up: its pane runs (${RESTORE_UP_MAX}s passed, and no session record named the conversation)"
        fi
        ;;
      *)
        FAILS+=("$team: its pane exited right after the restart (what it said: teamctl capture lead --team $team --all)")
        restore_log "$key" "$team" "restart $tag" "failed: the pane exited"
        continue
        ;;
    esac
    restore_log "$key" "$team" "restart $tag" "up"
    bead="$(restore_tell "$root" "$team" "Restored after the reboot at $(_finish_when "${T_SEEN[$i]}"): continue your work" \
      "teamctl restore brought your pane back at $(_finish_when "$since") ($tag): the machine restarted, and your team was last seen running at $(_finish_when "${T_SEEN[$i]}"). Read your inbox (bd list --assignee $(team_identity "$team" "$WOLFMUX_LEAD_ROLE") --status open,in_progress,blocked --include-infra), look at your workers (teamctl status), and continue your work.")"
    say "    told: ${bead:+Beads message $bead and }one nudge"
    R_KEY+=("$key") R_TEAM+=("$team") R_ROOT+=("$root") R_SID+=("${RU_SID:-}") R_FAMILY+=("${T_FAMILY[$i]}")
    R_SINCE+=("$since") R_LABEL+=("${T_LABEL[$i]}")
    [ -z "${T_NOTE[$i]}" ] || NOTES+=("$team: ${T_NOTE[$i]}")
  done

  # --- a used-up model limit. It shows only once the lead asks its model something, which the
  # nudge makes it do; so the transcripts are read last, after the last lead had time to answer.
  if [ "${#R_TEAM[@]}" -gt 0 ] && [ "$RESTORE_LIMIT_WAIT" -gt 0 ]; then sleep "$RESTORE_LIMIT_WAIT"; fi
  for ((i = 0; i < ${#R_TEAM[@]}; i++)); do
    [ "${R_FAMILY[$i]}" != "codex" ] && [ -n "${R_SID[$i]}" ] || continue
    restore_project "${R_KEY[$i]}" "${R_ROOT[$i]}" "${R_TEAM[$i]}"
    transcript="$(session_transcript "${R_SID[$i]}" "$(reg_field "$WOLFMUX_LEAD_ROLE" workdir 2>/dev/null || true)")"
    limit="$(restore_limit_text "$transcript" "${R_SINCE[$i]}")"
    [ -n "$limit" ] || continue
    policy="$(policy_get restore-on-limit)"
    if [ "$policy" = "report" ]; then
      LIMITS+=("${R_TEAM[$i]}: $limit")
      restore_log "${R_KEY[$i]}" "${R_TEAM[$i]}" "limit" "reported: $limit"
      continue
    fi
    # restore-on-limit <model>: how a lead moves to another model is restart's (--model), never restore's.
    say ""
    say "  ${R_TEAM[$i]}: $limit"
    say "    restarting its lead on $policy (policy restore-on-limit)"
    if [ "$busy" -eq 1 ] || ! restore_room; then
      busy=1
      LIMITS+=("${R_TEAM[$i]}: $limit (not moved to $policy: the machine stayed busy, $RESTORE_BUSY)")
      restore_log "${R_KEY[$i]}" "${R_TEAM[$i]}" "restart --model $policy" "not started: busy"
      continue
    fi
    marker="$(mktemp "${TMPDIR:-/tmp}/wolfmux-restore.XXXXXX" 2>/dev/null)" || marker=""
    sleep 1
    rc=0
    out="$(_restore_in "${R_ROOT[$i]}" "${R_TEAM[$i]}" restart "$WOLFMUX_LEAD_ROLE" --model "$policy" --resume "${R_SID[$i]}" 2>&1)" || rc=$?
    [ -z "$out" ] || printf '%s\n' "$out" | sed -e '/^$/d' -e 's/^/    /'
    if [ "$rc" -ne 0 ]; then
      [ -z "$marker" ] || /bin/rm -f "$marker"
      LIMITS+=("${R_TEAM[$i]}: $limit (the move to $policy failed: exit $rc)")
      restore_log "${R_KEY[$i]}" "${R_TEAM[$i]}" "restart --model $policy" "failed: exit $rc"
      continue
    fi
    rc=0
    restore_wait_up "$(reg_field "$WOLFMUX_LEAD_ROLE" family 2>/dev/null || true)" "${R_SID[$i]}" "${marker:-/dev/null}" || rc=$?
    [ -z "$marker" ] || /bin/rm -f "$marker"
    if [ "$rc" -eq 2 ]; then
      LIMITS+=("${R_TEAM[$i]}: $limit (the move to $policy failed: its pane exited)")
      restore_log "${R_KEY[$i]}" "${R_TEAM[$i]}" "restart --model $policy" "failed: the pane exited"
      continue
    fi
    [ "$rc" -eq 0 ] || say "    up: its pane runs (${RESTORE_UP_MAX}s passed after the model change)"
    EVENT_BY="$RESTORE_BY" event_log restore "$WOLFMUX_LEAD_ROLE" "model $policy after: $limit" 2>/dev/null || true
    restore_log "${R_KEY[$i]}" "${R_TEAM[$i]}" "restart --model $policy" "done"
    restore_tell "${R_ROOT[$i]}" "${R_TEAM[$i]}" "Moved to $policy: the ${R_LABEL[$i]:-model} limit was reached" \
      "teamctl restore restarted your pane on $policy, because your transcript said: $limit. Policy restore-on-limit asks for that. Continue your work." >/dev/null
    MOVED+=("${R_TEAM[$i]}: to $policy")
  done

  # --- tabs: every team brought back now, and every team of the snapshot that is up, unless a
  # terminal already shows it. In the order the tabs had, then the rest in restore order.
  if [ "$tabs" -eq 1 ]; then
    P_KEY=(${R_KEY[@]+"${R_KEY[@]}"} ${U_KEY[@]+"${U_KEY[@]}"})
    P_TEAM=(${R_TEAM[@]+"${R_TEAM[@]}"} ${U_TEAM[@]+"${U_TEAM[@]}"})
    P_ROOT=(${R_ROOT[@]+"${R_ROOT[@]}"} ${U_ROOT[@]+"${U_ROOT[@]}"})
    _restore_tab_order
    clients="$(tmx list-clients -F '#{client_session}' 2>/dev/null || true)"
    for j in ${ORDER[@]+"${ORDER[@]}"}; do
      restore_project "${P_KEY[$j]}" "${P_ROOT[$j]}" "${P_TEAM[$j]}"
      if dash_has_session "$clients" "$(session_name_for_project)"; then
        ATTACHED+=("${P_TEAM[$j]}")
        continue
      fi
      TAB_CMDS+=("$(_restore_cmd_text "${P_ROOT[$j]}" "${P_TEAM[$j]}")")
    done
  fi

  # --- what happened
  say ""
  say "$WOLFMUX_LEAD_MARK restore: ${#R_TEAM[@]} of $n team(s) brought back"
  for ((i = 0; i < ${#R_TEAM[@]}; i++)); do say "  restored ${R_TEAM[$i]}"; done
  for ((i = 0; i < ${#NOTES[@]}; i++)); do say "  note ${NOTES[$i]}"; done
  for ((i = 0; i < ${#MOVED[@]}; i++)); do say "  moved ${MOVED[$i]}"; done
  if [ "${#LIMITS[@]}" -gt 0 ]; then
    say "  blocked on a model limit (see each team's result):"
    for ((i = 0; i < ${#LIMITS[@]}; i++)); do say "    ${LIMITS[$i]}"; done
  fi
  for ((i = 0; i < ${#FAILS[@]}; i++)); do say "  NOT restored ${FAILS[$i]}"; done
  if [ "$busy" -eq 1 ]; then say "  run teamctl restore again once the machine is quieter: it skips every lead that is up."; fi
  if [ "$tabs" -eq 0 ]; then
    say "  tabs: none opened (--no-tabs). Attach a team from its project: teamctl --team <name> attach"
  elif [ "${#TAB_CMDS[@]}" -gt 0 ]; then
    if restore_open_tabs "${TAB_CMDS[@]}"; then
      say "  tabs: ${#TAB_CMDS[@]} opened in a new iTerm2 window, in the order they had"
    else
      say "  tabs: none opened ($RESTORE_TABS_WHY). Attach each team in a terminal tab of its own:"
      for ((i = 0; i < ${#TAB_CMDS[@]}; i++)); do say "    ${TAB_CMDS[$i]}"; done
    fi
  fi
  if [ "${#ATTACHED[@]}" -gt 0 ]; then say "  already on a screen: ${ATTACHED[*]}"; fi
  [ "${#FAILS[@]}" -eq 0 ]
}
