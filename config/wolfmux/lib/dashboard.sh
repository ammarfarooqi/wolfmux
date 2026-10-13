#!/bin/bash
# dashboard.sh — every team on this machine, across every project: a short segment in the
# status bar and a popup you open with a key.
#
# Read-only, on purpose. It takes no action on any team: no stop, no restart, no delete.
# You look, then you use the commands that act.
#
# It obeys three rules the rest of teamctl already lives by, and they shape all of it:
#
#   1. State comes from tmux, git and the registry. Terminal output is NEVER parsed for
#      state (lib/views.sh says so at the top, and it holds here).
#   2. Nothing in here runs `du`. A du over this machine's lane worktrees is about twelve
#      seconds; this view may be reopened at will and the segment redraws every few
#      seconds. Lane totals are read from the number `teamctl teams` left behind
#      (lib/disk.sh), with the same fifteen-minute staleness rule `teamctl status` uses,
#      and the view SAYS when the number is old instead of refreshing it.
#   3. One `ps` and one `tmux list-panes` for the whole dashboard — never one per agent,
#      and neither of them at all on the segment's path.
#
# What it does NOT claim. There is no honest "idle" or "working" signal to be had:
# `#{pane_activity}` is empty on tmux 3.7c, a whole team shares one window so
# `#{window_activity}` cannot speak for one agent, and an agent waiting and an agent
# working both run `node`. So the segment counts what tmux really knows — running,
# stopped, exited — and the popup shows two measurements under their own names: the CPU and
# memory of the agent's process tree, and when its transcript file was last written.
#
# --- the fast path, and why it exists --------------------------------------------------
# Every other view in teamctl answers for ONE team, where a jq process per field is
# invisible. This one walks every team on the machine: twenty-five teams and seventy-four
# agents here. Measured, the ordinary helpers cost 6.1 s for one draw — reg_list spawns a
# jq per agent record, reg_field one per field, and team_orphaned asks tmux three times per
# team. So a few helpers below answer the SAME question from data already in hand, by
# globbing and bash string matching instead of a process each:
#
#   dash_team_records  bulk read of the registry  (vs reg_list + reg_field)
#   dash_teams         the project's teams        (vs team_list)
#   dash_orphaned      is the lead running        (vs team_orphaned)
#   dash_pane_row      an agent's pane            (vs tm_pane_for_role + tm_pane_state)
#
# Each mirrors its helper's rule exactly, and tests/dashboard.sh asserts that each one
# agrees with the helper it stands in for. If they ever diverge the suite fails, which is
# the point: this is a faster path to the same answer, not a second opinion.

DASH_TAB="$(printf '\t')"
DASH_US="$(printf '\037')" # the unit separator: what dash_team_records splits a record's fields on
DASH_NL="
"

# --- discovery across projects -------------------------------------------------------
# `load_project` answers for the ONE project you are standing in: it resolves the root
# from the current directory's git repository. This view spans every project, so it reads
# the state registry itself and then hands each project to the team helpers.

# dash_projects — the project keys that have a state directory here, one per line. An
# unreadable entry (another user's, a half-written one) is skipped, never fatal.
# A project whose directory cannot be READ is still listed: dash_project_load reports it
# and the view names it. Dropping it here would make it vanish without a word, which is
# the one thing a view of "every team on this machine" must not do.
dash_projects() {
  local dir
  for dir in "$WOLFMUX_DATA"/state/*/; do
    [ -d "$dir" ] || continue
    basename "$dir"
  done 2>/dev/null
}

# dash_project_load <project-key> — points ROOT, PROJECT_KEY, PROJECT_STATE and
# PROJECT_TREES at that project, so the team helpers work on it unchanged.
#
#   0  loaded
#   1  the state directory cannot be read (another user's, a permission change)
#   2  readable, but no meta.json anywhere names a root
#
# The caller tells 1 and 2 apart on purpose: "we cannot read this" and "there is nothing
# here" are different things to report to whoever is looking.
#
# Where ROOT comes from is not obvious: the project-level meta.json belongs to the DEFAULT
# team and is simply absent on a project that only ever had named teams — that was true of
# every project on the machine this was written on. Any team's meta.json names the same
# root, so the first readable one answers.
dash_project_load() {
  local key="$1" meta root=""
  PROJECT_KEY="$key"
  PROJECT_STATE="$WOLFMUX_DATA/state/$key"
  PROJECT_TREES="$WOLFMUX_DATA/worktrees/$key"
  TEAM="" STATE_DIR="" WORKTREES_DIR=""
  ROOT=""
  [ -d "$PROJECT_STATE" ] || return 1
  [ -r "$PROJECT_STATE" ] && [ -x "$PROJECT_STATE" ] || return 1
  for meta in "$PROJECT_STATE/meta.json" "$PROJECT_STATE"/teams/*/meta.json; do
    [ -f "$meta" ] && [ -r "$meta" ] || continue
    root="$("$JQ_BIN" -r '.root // empty' "$meta" 2>/dev/null || true)"
    [ -n "$root" ] && break
  done
  [ -n "$root" ] || return 2
  ROOT="$root"
  return 0
}

# dash_has_records <state-dir> — does that team hold any agent record? A glob, no process.
dash_has_records() {
  local file
  for file in "$1"/agents/*.json; do
    [ -f "$file" ] && return 0
  done
  return 1
}

# dash_meta_session <state-dir> — the tmux session named in that team's meta.json, read
# WITHOUT starting a process.
#
# meta_get is the general reader and every other caller uses it; it spawns jq, which costs
# about 14 ms. The status segment asks this for every team that holds no records, and five
# of those measured 70 ms of the segment's 120 ms — more than half the budget, to read
# seven bytes. So the one field is read here in bash. Nothing but this module may: it is a
# fallback for a hot path, not a second implementation of the registry.
dash_meta_session() {
  local file="$1/meta.json" line value
  [ -f "$file" ] && [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *'"session"'*:*)
        value="${line#*: \"}"
        value="${value%%\"*}"
        [ "$value" != "$line" ] || return 0
        case "$value" in *'"'*) return 0 ;; esac
        printf '%s\n' "$value"
        return 0
        ;;
    esac
  done <"$file"
  return 0
}

# dash_teams <session-list> — the teams of the loaded project: the default team first, then
# the named ones, and a team counts when it holds agent records or has a session running.
# That is team_list's rule and team_list's order; team_list asks reg_list (a jq per record)
# and tmux (a call per team) for it, and this answers from globbing and the pane snapshot.
dash_teams() {
  local sessions="$1" name dir session
  for name in "$WOLFMUX_DEFAULT_TEAM" $(for dir in "$PROJECT_STATE"/teams/*/; do [ -d "$dir" ] && basename "$dir"; done 2>/dev/null); do
    valid_team_name "$name" || continue
    team_paths "$name"
    if dash_has_records "$STATE_DIR"; then
      printf '%s\n' "$name"
      continue
    fi
    # No records: only a live session makes it a team you can still see. The stored name
    # answers without a process; a team that never stored one falls back to the helper,
    # which is cheap exactly when meta.json is missing.
    session="$(dash_meta_session "$STATE_DIR")"
    [ -n "$session" ] || session="$(session_name_for_project)"
    if dash_has_session "$sessions" "$session"; then printf '%s\n' "$name"; fi
  done
}

# --- the machine ---------------------------------------------------------------------
# dash_load — the one-minute load average, empty when the kernel will not say
dash_load() {
  if [ -r /proc/loadavg ]; then
    awk '{ printf "%.2f\n", $1 }' /proc/loadavg 2>/dev/null
    return 0
  fi
  sysctl -n vm.loadavg 2>/dev/null | awk '{ gsub(/[{}]/, ""); if ($1 != "") printf "%.2f\n", $1 + 0 }'
}

# dash_mem_free_kb — memory a process could still get, in kilobytes, empty when unknown.
# macOS: vm_stat's free plus inactive pages — inactive memory is available, the kernel
# hands it back on demand — times the page size it prints itself. Never `top`, which
# samples for about a second and would spend the segment's whole budget on its own.
dash_mem_free_kb() {
  if [ -r /proc/meminfo ]; then
    awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null
    return 0
  fi
  vm_stat 2>/dev/null | awk '
    /page size of/ { for (i = 1; i <= NF; i++) if ($i + 0 >= 4096) { size = $i + 0; break } }
    /^Pages free:/ { free = $3 + 0 }
    /^Pages inactive:/ { inactive = $3 + 0 }
    END { if (size > 0) printf "%d\n", (free + inactive) * size / 1024 }'
}

# dash_short_gb <kilobytes> — "108G", "900M": short enough to sit in a status bar
dash_short_gb() {
  case "${1:-x}" in "" | *[!0-9]*) printf -- '-\n'; return 0 ;; esac
  awk -v kb="$1" 'BEGIN { if (kb >= 1048576) printf "%dG\n", kb / 1048576 + 0.5; else printf "%dM\n", kb / 1024 + 0.5 }'
}

# dash_tenth_gb <kilobytes> — "9.2G", "900M", "-": the popup's own GB formatting (one tenth
# of a gigabyte), for the one status-bar field where a tenth decides something. `held 9G` and
# `held 9.2G` read the same at a glance; `held 900M` and `held 9.2G` do not, and whether to
# run prune is the decision this field exists for.
dash_tenth_gb() {
  case "${1:-x}" in "" | *[!0-9]*) printf -- '-\n'; return 0 ;; esac
  awk -v kb="$1" 'BEGIN { if (kb >= 1048576) printf "%.1fG\n", kb / 1048576; else printf "%dM\n", kb / 1024 + 0.5 }'
}

# dash_age_span <seconds> — "41s", "12m", "3h", "4d": an age in one word
dash_age_span() {
  case "${1:-x}" in "" | *[!0-9]*) printf -- '-\n'; return 0 ;; esac
  awk -v s="$1" 'BEGIN {
    if (s < 60) printf "%ds\n", s;
    else if (s < 3600) printf "%dm\n", s / 60;
    else if (s < 86400) printf "%dh\n", s / 3600;
    else printf "%dd\n", s / 86400
  }'
}

# dash_context_label <tokens> <window> — what the CONTEXT column shows. THREE cases, not
# two:
#
#   a known share          "142k 71%"   the window is known
#   a count with no share  "142k"       the window genuinely cannot be known — a pinned
#                                       claude:<id> without [1m], astra, anything
#                                       unrecognised. From v1.14.1 model_context_window
#                                       may legitimately say nothing.
#   no reading at all      "-"          no transcript yet
#
# The house rule: show what is known, say nothing where it is not, never a number that
# looks precise and is not. A percentage of a guessed window is worse than no percentage,
# so the share is DROPPED rather than invented — never 0%, never 100%.
#
# ctx_display does every bit of the formatting and decides the share; nothing here divides
# by anything. When the window is unknown this keeps ctx_display's first field, which is
# also right for a future ctx_display that already omits the share.
dash_context_label() {
  local out
  [ -n "${1:-}" ] || {
    printf -- '-\n'
    return 0
  }
  out="$(ctx_display "$1" "${2:-}")"
  case "${2:-0}" in "" | 0 | *[!0-9]*) out="${out%% *}" ;; esac
  printf '%s\n' "$out"
}

# dash_mtime <path> — the file's modification time as an epoch, empty when there is none
dash_mtime() {
  [ -n "${1:-}" ] && [ -f "$1" ] || return 0
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || true
}

# --- processes: ONE ps for the whole view ---------------------------------------------
# dash_ps_snapshot — "pid ppid %cpu rss" for every process, taken once. A ps per agent is
# what makes a dashboard slow, and with seventy agents it is the whole cost.
dash_ps_snapshot() { ps -A -o pid=,ppid=,%cpu=,rss= 2>/dev/null || true; }

# dash_tree_usage <snapshot> <pid> — "<cpu-percent> <rss-kilobytes>" summed over that pid
# and every process below it.
#
# The tree, not the pid: an agent's CLI is a CHILD of its pane's shell, so the pane's own
# process accounts for almost nothing and the shell alone would report every agent asleep.
# seen[] guards against a cycle in a snapshot taken while the process table changed.
dash_tree_usage() {
  local snapshot="$1" pid="${2:-}"
  if [ -z "$pid" ] || [ -z "$snapshot" ]; then
    printf -- '- -\n'
    return 0
  fi
  printf '%s\n' "$snapshot" | awk -v root="$pid" '
    { cpu[$1] = $3; rss[$1] = $4; kids[$2] = kids[$2] " " $1 }
    END {
      queue[++tail] = root
      while (head < tail) {
        p = queue[++head]
        if (seen[p]++) continue
        if (p in cpu) { c += cpu[p]; m += rss[p] }
        n = split(kids[p], kid, " ")
        for (i = 1; i <= n; i++) if (kid[i] != "") queue[++tail] = kid[i]
      }
      printf "%.1f %d\n", c, m
    }'
}

# --- tmux: ONE list-panes for the whole view ------------------------------------------
# DASH_SOCKET — the tmux socket to ask, when something told us which one. Empty means fall
# back to tmx, which targets $WOLFMUX_TMUX_SOCKET.
#
# This exists because of a real trap. `tmx` targets $WOLFMUX_TMUX_SOCKET, default "wolfmux".
# A #() status job inherits the tmux SERVER's environment, and nothing in it says which
# socket the job is being drawn on — so a badge drawn on any other socket would silently
# report the state of the default one. On the live server the default happens to be right,
# which is the same kind of luck as a bare `teamctl` on PATH, and this badge is silent on
# error so it would never say otherwise. So the socket is handed IN rather than assumed:
# So it is handed in from tmux.conf, which knows which server it is drawing: #{socket_path}
# to the badge, and `dashboard --socket "#{socket_path}"` to the popup. Never read out of
# the environment — see dash_socket_set for the trap that costs.
# (Found by the quiet-nudges lane in their own badge; same class of bug, same fix.)
DASH_SOCKET=""

# dash_socket_set <path> — adopt that socket, if it really is one. Anything else is ignored
# and the fallback stands: a view that asked a socket that is not there would report an
# empty machine, which is worse than asking the default.
#
# The socket is only ever handed in — from tmux.conf, which knows which server it is
# drawing, via #{socket_path}. It is NEVER inferred from the environment. $TMUX looks
# tempting and is wrong: run `teamctl dashboard` from your own tmux session and $TMUX names
# YOUR socket, which is a real socket, so every check on it passes and the view then lists
# panes from your personal server, finds nothing tagged @ai_role, and reports every team as
# having zero agents alive while the teams are running perfectly well on the wolfmux socket.
# Teams still appear, because they come from the state directories, so the view looks
# plausible and is wrong. With nothing handed in, `tmx` targets $WOLFMUX_TMUX_SOCKET, which
# is the right answer for the command line.
dash_socket_set() {
  [ -n "${1:-}" ] && [ -S "$1" ] || return 0
  DASH_SOCKET="$1"
}

# dash_panes — "session|role|pane|dead|pid" for every pane of the team server, newline
# terminated. One call covers every project: every team shares one socket.
dash_panes() {
  [ -n "$TMUX_BIN" ] || return 0
  if [ -n "$DASH_SOCKET" ]; then
    "$TMUX_BIN" -S "$DASH_SOCKET" list-panes -a -F '#{session_name}|#{@ai_role}|#{pane_id}|#{pane_dead}|#{pane_pid}' 2>/dev/null || true
    return 0
  fi
  tmx list-panes -a -F '#{session_name}|#{@ai_role}|#{pane_id}|#{pane_dead}|#{pane_pid}' 2>/dev/null || true
}

# dash_pane_row <panes> <session> <role> — "pane|dead|pid" for that agent, empty when it
# has no pane. Bash string matching, no process: this is asked once per agent, and three
# awk calls per agent is two hundred processes on this machine. The search starts at a line
# boundary so one role can never match inside a longer one.
dash_pane_row() {
  local key="$DASH_NL$2|$3|" rest
  rest="$DASH_NL$1"
  case "$rest" in *"$key"*) ;; *) return 0 ;; esac
  rest="${rest#*"$key"}"
  printf '%s\n' "${rest%%"$DASH_NL"*}"
}

# dash_sessions <panes> — the session names that have at least one pane, one per line
dash_sessions() {
  printf '%s\n' "$1" | awk -F'|' 'NF > 0 && $1 != "" && !seen[$1]++ { print $1 }'
}

# dash_has_session <session-list> <name> — is that session in the list? A shell pattern
# match, not grep: this is asked once per team, and twenty-five greps are twenty-five
# processes for a question bash can answer without leaving the shell.
dash_has_session() {
  [ -n "${2:-}" ] || return 1
  case "$DASH_NL$1$DASH_NL" in *"$DASH_NL$2$DASH_NL"*) return 0 ;; esac
  return 1
}

# dash_orphaned <lead-pane-row> — team_orphaned's answer for a team we already know exists
# (dash_teams only yields teams that hold records or have a session): it is orphaned when
# its lead is not running. team_orphaned asks tmux three times per team to find that out;
# the row is already in hand here.
dash_orphaned() {
  local row="${1:-}"
  [ -n "$row" ] || return 0
  case "$row" in *"|1|"*) return 0 ;; esac # the lead's pane exited
  return 1
}

# --- the lane total: cached, never measured ------------------------------------------
# dash_disk_label — this team's lane total. The cached number while it is fresh (exactly
# the rule teamctl status uses: disk_team_kb_cached), and otherwise a word saying WHY there
# is none, because a stale number shown as current is worse than no number at all.
# disk_team_kb_cached answers fresh-or-not and cannot tell stale from absent, so the raw
# stamp is read here for that one sentence.
dash_disk_label() {
  local kb raw stamp value
  kb="$(disk_team_kb_cached)"
  if [ -n "$kb" ]; then
    human_size "$kb"
    return 0
  fi
  raw="$(/bin/cat "$(disk_cache_file)" 2>/dev/null || true)"
  stamp="${raw%% *}"
  value="${raw##* }"
  case "${stamp:-x}" in "" | *[!0-9]*) stamp="" ;; esac
  case "${value:-x}" in "" | *[!0-9]*) stamp="" ;; esac
  if [ -z "$stamp" ]; then
    printf 'not measured (teamctl teams measures it)\n'
    return 0
  fi
  printf '%s, STALE %s old (teamctl teams refreshes it)\n' "$(human_size "$value")" \
    "$(dash_age_span "$(($(now_epoch) - 10#$stamp))")"
}

# --- one team's records: ONE read, not one per field ---------------------------------
# dash_team_records — one line per agent of the loaded team, its fields split by $DASH_US:
# role, kind, model, label, workdir, session_id, family, branch, spawned_by, model_id,
# model_context, model_at.
#
# The unit separator, not a tab. A tab is whitespace to `read`, so two in a row (an empty
# field) collapse into one and every field after it moves up one place. A Codex agent has no
# session_id and a record from before v1.18.0 has no model_id: with tabs the first read its
# family as its conversation id and its branch as its family, and lost its context.
#
# In the registry's OWN order: lead first, then created_at, then role — exactly reg_list's
# sort key. reg_list spawns a jq per record to produce that order and reg_field one per
# field; seven fields across seventy-four agents measured about six hundred processes and
# 6.1 seconds, for a view budgeted at two. The registry still defines the format and is
# still the only thing that writes it; this reads it in a single pass.
dash_team_records() {
  [ -d "$STATE_DIR/agents" ] || return 0
  "$JQ_BIN" -r -s '
    map(select(type == "object" and .role != null))
    | sort_by([(if .kind == "lead" then 0 else 1 end), (.created_at // ""), .role])
    | .[]
    | [.role, (.kind // ""), (.model // ""), (.label // ""), (.workdir // ""),
       (.session_id // ""), (.family // ""), (.branch // ""), (.spawned_by // ""),
       (.model_id // ""), (.model_context // ""), (.model_at // "")]
    | map(tostring) | join("\u001f")' "$STATE_DIR"/agents/*.json 2>/dev/null || true
}

# --- one team -------------------------------------------------------------------------
# dash_team_json <panes> <ps-snapshot> <full 0|1> — the loaded team as an object.
#
# The two per-agent FILE reads — context and the transcript's mtime — are the expensive
# part, so by default they are taken only for an agent that is actually RUNNING. A stopped
# lane still shows its state and branch, and `--full` fills in the rest. That is the
# budget rule: a fast dashboard people open beats a complete one they do not.
dash_team_json() {
  local panes="$1" snapshot="$2" full="$3" live=0 orphaned=0 rows="" lead_label="" lead_mark="" founder=""
  local role kind model label workdir session_id family branch spawned_by recorded_id recorded_window recorded_at
  local row pane dead pid state cpu rss usage cctx active lead_row=""
  SESSION="$(dash_meta_session "$STATE_DIR")"
  [ -n "$SESSION" ] || SESSION="$(session_name_for_project)"
  if dash_has_session "$(dash_sessions "$panes")" "$SESSION"; then live=1; fi
  while IFS="$DASH_US" read -r role kind model label workdir session_id family branch spawned_by recorded_id recorded_window recorded_at; do
    [ -n "$role" ] || continue
    row="$(dash_pane_row "$panes" "$SESSION" "$role")"
    # "pane|dead|pid", picked apart without a process: cut would be two more forks per agent.
    pane="${row%%|*}"
    dead="${row#*|}"
    pid="${dead#*|}"
    dead="${dead%%|*}"
    if [ -z "$row" ]; then
      state="stopped"
      pane="" pid=""
    elif [ "$dead" = "1" ]; then
      state="exited"
    else
      state="running"
    fi
    usage="$(dash_tree_usage "$snapshot" "$pid")"
    cpu="${usage%% *}"
    rss="${usage##* }"
    cctx="-"
    active=""
    # Which model it runs is models_running's answer (lib/models.sh), the one status and teamctl
    # models give: MR_ID, MR_HOW, MR_LABEL and MR_MARK. An agent that is not on fable, opus,
    # sonnet or haiku has no such answer, and keeps its record's label and id.
    MR_ID="$recorded_id" MR_HOW="" MR_LABEL="" MR_MARK=""
    if [ "$full" = "1" ] || [ "$state" = "running" ]; then
      CTX_FILE=""
      agent_context "$workdir" "$model" "$family" "$session_id" "$recorded_window" "$recorded_id" "$recorded_at" || true
      cctx="$(dash_context_label "$CTX_TOKENS" "$CTX_WINDOW")"
      # The transcript's own mtime: the very file the context reader just opened, and it
      # moves on every turn the agent takes. A file timestamp, not a claim about what the
      # agent is doing.
      active="$(dash_mtime "${CTX_FILE:-}")"
    elif models_is_alias "$model"; then
      # Its transcript is not opened (the budget rule above): what its record says, and "Opus ?"
      # where the record says nothing. Never the label an old table once gave it.
      models_running "$model" "$recorded_id" "$recorded_window" "$recorded_at" "" ""
    fi
    if [ -n "$MR_LABEL" ]; then label="$MR_LABEL"; fi
    if [ "$kind" = "lead" ]; then
      branch="-"
      lead_label="$label"
      lead_mark="$MR_MARK"
      lead_row="$row"
      founder="$spawned_by"
    fi
    rows="$rows$role$DASH_TAB$kind$DASH_TAB$model$DASH_TAB$label$DASH_TAB$state$DASH_TAB${pane:--}$DASH_TAB${branch:--}$DASH_TAB$workdir$DASH_TAB$cctx$DASH_TAB$cpu$DASH_TAB$rss$DASH_TAB$active$DASH_TAB$MR_MARK$DASH_TAB$MR_ID$DASH_TAB$MR_HOW$DASH_NL"
  done <<EOF
$(dash_team_records)
EOF
  if dash_orphaned "$lead_row"; then orphaned=1; fi
  printf '%s' "$rows" | "$JQ_BIN" -R -s \
    --arg team "$TEAM" --arg session "$SESSION" --arg live "$live" --arg orphaned "$orphaned" \
    --arg lead "$lead_label" --arg lead_mark "$lead_mark" --arg founder "${founder:-operator}" --arg disk "$(dash_disk_label)" \
    --arg full "$full" '
    {team: $team, session: $session, session_running: ($live == "1"),
     state: (if $orphaned == "1" then "orphaned" else (if $live == "1" then "running" else "not running" end) end),
     lead: $lead, lead_mark: $lead_mark, founder: $founder, lanes_disk: $disk,
     agents: (split("\n") | map(select(length > 0) | split("\t")) | map({
       role: .[0], kind: .[1], model: .[2], label: .[3], label_mark: (.[12] // ""),
       model_id: (if (.[13] // "") == "" then null else .[13] end),
       known_from: (if (.[14] // "") == "" then null else .[14] end),
       state: .[4], pane: .[5],
       branch: .[6], workdir: .[7], context: .[8],
       detail: ($full == "1" or .[4] == "running"),
       cpu_percent: (.[9] | tonumber? // null), rss_kb: (.[10] | tonumber? // null),
       transcript_written_at: (.[11] | tonumber? // null)}))}'
}

# --- the whole machine ----------------------------------------------------------------
# dash_collect [--full] — one JSON document: every project, every team, every agent, and
# the machine. Both the text view and --json render from this, so the two cannot drift.
dash_collect() {
  local full=0 panes snapshot sessions key team out="" skipped="" empty="" rc
  if [ "${1:-}" = "--full" ]; then full=1; fi
  panes="$(dash_panes)"
  snapshot="$(dash_ps_snapshot)"
  sessions="$(dash_sessions "$panes")"
  # Collected into a variable, not piped: the loop that builds this used to be the left
  # side of a pipeline, and everything it assigned — the skipped list — stayed behind in
  # that subshell and never reached the output.
  for key in $(dash_projects); do
    rc=0
    dash_project_load "$key" || rc=$?
    if [ "$rc" -ne 0 ]; then
      # Unreadable is one thing; readable with nothing in it is another. A project with no
      # root and no records is an abandoned `teamctl start` that never became a team; one
      # that holds records is state we cannot read, and that is worth a different word.
      if [ "$rc" -eq 1 ] || dash_project_has_any_record "$WOLFMUX_DATA/state/$key"; then
        skipped="$skipped $key"
      else
        empty="$empty $key"
      fi
      continue
    fi
    out="$out$(
      for team in $(dash_teams "$sessions"); do
        team_paths "$team"
        dash_team_json "$panes" "$snapshot" "$full"
      done | "$JQ_BIN" -s --arg key "$key" --arg root "$(short_path "$ROOT")" \
        '{project: $key, root: $root, teams: .}'
    )$DASH_NL"
  done
  printf '%s' "$out" | "$JQ_BIN" -s --arg load "$(dash_load)" --arg mem "$(dash_mem_free_kb)" \
    --arg disk "$(disk_free_kb)" --arg skipped "${skipped# }" --arg empty "${empty# }" \
    --arg full "$full" --arg at "$(now_iso)" '
    {at: $at, full: ($full == "1"), projects: .,
     machine: {load: ($load | tonumber? // null),
               memory_free_kb: ($mem | tonumber? // null),
               disk_free_kb: ($disk | tonumber? // null)},
     unreadable_projects: (if $skipped == "" then [] else ($skipped | split(" ")) end),
     empty_projects: (if $empty == "" then [] else ($empty | split(" ")) end)}'
}

# dash_project_has_any_record <project-state-dir> — does any team of it hold an agent
# record? Globbing only; used to tell an unreadable project from an abandoned one.
dash_project_has_any_record() {
  local dir
  for dir in "$1" "$1"/teams/*/; do
    [ -d "$dir" ] || continue
    dash_has_records "${dir%/}" && return 0
  done
  return 1
}

# --- the text view --------------------------------------------------------------------
# dash_render <json> — the popup's own drawing: one project at a time, each team a small
# tree under it, the machine at the foot.
dash_render() {
  local doc="$1"
  printf '%s %s   %s\n' "$WOLFMUX_LEAD_MARK" "WOLFMUX DASHBOARD" \
    "$(printf '%s' "$doc" | "$JQ_BIN" -r '.at')"
  printf '%s\n' "$doc" | "$JQ_BIN" -r '
    (.projects | length) as $p | ([.projects[].teams[]] | length) as $t |
    ([.projects[].teams[].agents[]] | length) as $a |
    ([.projects[].teams[].agents[] | select(.state == "running")] | length) as $run |
    ([.projects[].teams[].agents[] | select(.state == "stopped")] | length) as $stop |
    ([.projects[].teams[].agents[] | select(.state == "exited")] | length) as $exit |
    ([.projects[].teams[] | select(.state == "orphaned")] | length) as $orph |
    " \($p) project\(if $p == 1 then "" else "s" end) · \($t) team\(if $t == 1 then "" else "s" end) (\($orph) orphaned) · \($a) agents: \($run) running · \($stop) stopped · \($exit) exited"'
  printf '%s\n' "$doc" | "$JQ_BIN" -r --arg wolf "$WOLFMUX_LEAD_MARK" --arg dog "$WOLFMUX_WORKER_MARK" '
    def pad($n): (. + (" " * 44))[0:$n];
    def gb: if . == null then "-" else "\((. / 1048576 * 10 | round) / 10)G" end;
    def ago($now): if . == null then "-" else ($now - .) as $s |
      if $s < 0 then "-" elif $s < 60 then "\($s)s" elif $s < 3600 then "\(($s / 60) | floor)m"
      elif $s < 86400 then "\(($s / 3600) | floor)h" else "\(($s / 86400) | floor)d" end end;
    (.at | fromdate) as $now |
    .projects[] |
    "",
    "PROJECT \(.project)   \(.root)",
    (if (.teams | length) == 0 then "  no teams on record" else empty end),
    (.teams[] |
      "  TEAM \(.team | pad(20)) \(.state | pad(12)) lead \((if .lead == "" then "-" else .lead + (.lead_mark // "") end) | pad(12)) agents \((.agents | length) | tostring | pad(4)) lanes \(.lanes_disk)",
      (if (.agents | length) == 0 then "      no agents on record" else empty end),
      (.agents[] |
        "      \(if .kind == "lead" then $wolf else $dog end) \(.role | pad(16)) \((.label + (.label_mark // "")) | pad(14)) \(.state | pad(8))" +
        " cpu \((if .cpu_percent == null then "-" else (.cpu_percent | tostring) end) | pad(6))" +
        " mem \((.rss_kb | gb) | pad(7))" +
        " ctx \(.context | pad(10))" +
        " wrote \((.transcript_written_at | ago($now)) | pad(6)) \(.branch)"))'
  printf '\n'
  printf '%s\n' "$doc" | "$JQ_BIN" -r --arg legend "$MODELS_MARK_LEGEND" '
    def gb: if . == null then "-" else "\((. / 1048576 * 10 | round) / 10) GB" end;
    "MACHINE  load \(.machine.load // "-") · memory \(.machine.memory_free_kb | gb) free · disk \(.machine.disk_free_kb | gb) free",
    (if ([.projects[].teams[].agents[] | select(.label_mark == "*")] | length) > 0 then "  \($legend)" else empty end),
    (if (.unreadable_projects | length) > 0 then "  skipped, state could not be read: \(.unreadable_projects | join(", "))" else empty end),
    (if (.empty_projects | length) > 0 then "  skipped, nothing on record (a start that never became a team): \(.empty_projects | join(", "))" else empty end),
    (if .full then empty else "  ctx and wrote are read for RUNNING agents only. All of them: teamctl dashboard --full" end)'
  say '  cpu and mem are that agent'"'"'s whole process tree: a process reading, not a claim about what the agent is doing.'
  say '  wrote = when the agent'"'"'s own transcript file was last written. A file timestamp, nothing more.'
  say '  lane totals are the number teamctl teams left behind; nothing here runs du (about 12 s over this machine'"'"'s lanes).'
  say '  read-only: this view changes nothing.'
}

# teamctl dashboard [--json] [--once] [--interval <seconds>] [--full]
cmd_dashboard() {
  local json=0 once=0 interval=5 full="" socket="" doc key
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      --once) once=1 ;;
      --full) full="--full" ;;
      --interval)
        [ "$#" -ge 2 ] || die_usage "--interval needs a number of seconds"
        interval="$2"
        shift
        ;;
      --interval=*) interval="${1#--interval=}" ;;
      --socket)
        [ "$#" -ge 2 ] || die_usage "--socket needs a path"
        socket="$2"
        shift
        ;;
      --socket=*) socket="${1#--socket=}" ;;
      *) die_usage "usage: teamctl dashboard [--json] [--once] [--interval <seconds>] [--full] [--socket <path>]" ;;
    esac
    shift
  done
  case "${interval:-x}" in "" | *[!0-9]* | 0) die_usage "--interval expects a number of seconds, 1 or more" ;; esac
  require_tools
  # Handed in by tmux.conf's key binding, which knows which server it is drawing. Never
  # inferred: see dash_socket_set for why reading $TMUX is wrong. Nothing handed in means
  # tmx and $WOLFMUX_TMUX_SOCKET, which is right for the command line.
  dash_socket_set "$socket"
  if [ "$json" -eq 1 ]; then
    dash_collect $full
    return 0
  fi
  if [ "$once" -eq 1 ]; then
    dash_render "$(dash_collect $full)"
    return 0
  fi
  # The popup: draw, then wait for the interval OR for a key. q closes it, anything else
  # redraws at once. Not a terminal (a pipe, a test) and one draw is all there is to do.
  while :; do
    doc="$(dash_collect $full)"
    printf '\033[H\033[2J'
    dash_render "$doc"
    printf '\n  q quits · any other key redraws now\n'
    [ -t 0 ] || break
    if read -r -t "$interval" -n 1 key 2>/dev/null; then
      case "$key" in q | Q) break ;; esac
    fi
  done
}

# --- the status-bar segment -----------------------------------------------------------
# dash_badge_line — the segment's text. Cheap on purpose: one tmux call, file globbing and
# three machine readings. It opens no transcript, runs no ps and runs no du, which is what
# keeps it inside the budget a thing redrawn every few seconds has to live in. Measured on
# the machine this was written on: 18 ms of work.
dash_badge_line() {
  local panes sessions key dir name teams=0 run=0 stopped=0 exited=0 line dead have
  # No tmux, no truth about what is running, and "0run" would be a lie: say nothing.
  [ -n "$TMUX_BIN" ] || return 1
  panes="$(dash_panes)"
  sessions="$(dash_sessions "$panes")"
  for key in "$WOLFMUX_DATA"/state/*/; do
    [ -d "$key" ] && [ -r "$key" ] || continue
    for dir in "$key" "$key"teams/*/; do
      [ -d "$dir" ] && [ -r "$dir" ] || continue
      if ! dash_has_records "${dir%/}"; then
        # A session with no records left is a team that was destroyed and whose window is
        # still open: it counts, because you can still see it on screen.
        dash_has_session "$sessions" "$(dash_meta_session "${dir%/}")" || continue
      fi
      teams=$((teams + 1))
    done
  done
  # A pane with no @ai_role is not an agent: a split somebody opened themselves.
  while IFS='|' read -r line name dir dead have; do
    [ -n "$name" ] || continue
    if [ "$dead" = "1" ]; then exited=$((exited + 1)); else run=$((run + 1)); fi
  done <<EOF
$panes
EOF
  # On record and with no pane: the lanes you can bring back (teamctl restart).
  have="$(dash_badge_record_count)"
  stopped=$((have - run - exited))
  [ "$stopped" -ge 0 ] || stopped=0
  # Labelled fields, and the label in front of the number. v1.16.1 printed
  # "21t 18run 92stop ld3.56 mem7G dsk66G", which is unreadable: four of the seven numbers
  # carry their unit as a suffix nobody can parse at a glance, two of the labels are
  # abbreviations, and "92stop" reads as one token. The names are spelled out instead, with
  # `held` added — the gigabytes sitting in parked lanes, which is the number that tells you
  # there is something to reclaim, and the one thing the old line could not say at all.
  #
  # The budget is 72 characters (cmd_overview_badge cuts there) and the alphabet is
  # A-Za-z0-9, space, and . : / + - (it strips everything else, SILENTLY, so a middle dot or
  # a pipe between fields would vanish without a trace). Every character below is inside
  # that set deliberately: no separator was added, because the labels already separate.
  # Measured on this machine: "teams 21 run 13 idle 93 load 3.56 mem 8G disk 76G held 9.2G"
  # is 60 characters, and with "exit 2" in it 67.
  line="teams $teams run $run idle $stopped"
  [ "$exited" -eq 0 ] || line="$line exit $exited"
  printf '%s load %s mem %s disk %s held %s\n' "$line" "$(dash_load)" \
    "$(dash_short_gb "$(dash_mem_free_kb)")" "$(dash_short_gb "$(disk_free_kb)")" \
    "$(dash_tenth_gb "$(dash_badge_held_kb)")"
}

# dash_parked_kb <state-dir> — sets DASH_PARKED_KB to that team's remembered PARKED lane
# total, or to "" when there is no readable number. It SETS a variable instead of printing
# one, because `$(...)` would be a subshell per team on the one path in this file that
# redraws every few seconds; this way the whole sweep over 25 teams costs no process at all.
#
# disk_parked_kb (lib/disk.sh) is the general reader and every other caller uses it; it
# spawns /bin/cat. Same rule as dash_meta_session above: a fallback for a hot path, not a
# second opinion — tests/dashboard.sh asserts that this agrees with disk_parked_kb, and if
# the two ever diverge the suite fails.
dash_parked_kb() {
  local file="$1/disk-parked-kb" stamp="" kb=""
  DASH_PARKED_KB=""
  [ -f "$file" ] && [ -r "$file" ] || return 0
  read -r stamp kb <"$file" 2>/dev/null || true
  # Both fields, each on its own, no leading zero: "08" would be read as octal by the
  # arithmetic below and abort the badge, which must never print a broken line.
  case "${stamp:-x}" in "" | *[!0-9]* | 0?*) return 0 ;; esac
  case "${kb:-x}" in "" | *[!0-9]* | 0?*) return 0 ;; esac
  DASH_PARKED_KB="$kb"
}

# dash_badge_held_kb — what the parked lanes of every team on this machine hold, in
# kilobytes; empty when no team has ever been measured, so the field shows "-" rather than a
# zero that would read as "nothing to reclaim".
#
# Read from the numbers `teamctl teams` left behind, never measured: rule 2 at the top of this
# file. A stale one is used on purpose, and that is the difference from the free-disk and
# memory fields beside it — a PARKED lane is a lane in which nothing is running, so its size
# does not change by itself, and yesterday's measurement of it is still the measurement.
# What it cannot know is a lane parked since (too low) or a lane removed since (too high);
# `teamctl bar --explain` says exactly that, and `teamctl teams` makes it current.
dash_badge_held_kb() {
  local key dir total=0 found=0
  for key in "$WOLFMUX_DATA"/state/*/; do
    [ -d "$key" ] && [ -r "$key" ] || continue
    for dir in "$key" "$key"teams/*/; do
      [ -d "$dir" ] || continue
      dash_parked_kb "${dir%/}"
      [ -n "$DASH_PARKED_KB" ] || continue
      total=$((total + DASH_PARKED_KB))
      found=1
    done
  done
  [ "$found" -eq 1 ] || return 0
  printf '%s\n' "$total"
}

# dash_badge_record_count — how many agents are on record anywhere on this machine. A file
# count: no jq, and no process per agent.
dash_badge_record_count() {
  local key dir name total=0
  for key in "$WOLFMUX_DATA"/state/*/; do
    [ -d "$key" ] && [ -r "$key" ] || continue
    for dir in "$key" "$key"teams/*/; do
      [ -d "$dir" ] || continue
      for name in "$dir"agents/*.json; do
        [ -f "$name" ] || continue
        total=$((total + 1))
      done
    done
  done
  printf '%s\n' "$total"
}

# teamctl _overview-badge — the one short line tmux puts in status-right.
#
# A badge may NEVER break a status bar, so this prints nothing at all on any failure: one
# line only, printable characters only, bounded length. tmux shows whatever it is given,
# for as long as it is given it, so a half-written line or an error message would sit in
# the status bar of every attached client until the server is restarted.
# Takes the socket it is being drawn on as its one argument (tmux.conf passes
# #{socket_path}); an older tmux.conf passes nothing and the fallback stands.
cmd_overview_badge() {
  local out
  dash_socket_set "${1:-}"
  out="$( (dash_badge_line) 2>/dev/null | head -n 1 | LC_ALL=C tr -dc 'A-Za-z0-9 .:/+-' | cut -c1-72)" || return 0
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
}

# teamctl bar [--explain] — the status-bar line on demand, and what each field of it means.
#
# A legend is what a status bar needs and the one thing it cannot carry: seven numbers in
# seventy-two characters have room for their labels and nothing else. The ask was "a legend
# or a hover"; a terminal has no hover, so it is a command. `--explain` is the whole point
# of it — a bare `teamctl bar` is the line itself, useful when the bar is off screen.
#
# It prints the line through the badge's own filter, not dash_badge_line raw, so what you
# read here is character for character what tmux is being given.
cmd_bar() {
  local explain=0 line
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --explain) explain=1 ;;
      *) die_usage "usage: teamctl bar [--explain]" ;;
    esac
    shift
  done
  require_tools
  line="$(cmd_overview_badge)"
  if [ -n "$line" ]; then
    say "$line"
  else
    say "(the status bar is empty: there is no tmux server to ask, so nothing about what is running could be true)"
  fi
  [ "$explain" -eq 1 ] || {
    say ""
    say "what each field means: teamctl bar --explain"
    return 0
  }
  say ""
  say "$WOLFMUX_LEAD_MARK the status bar, field by field   (tmux draws it in status-right, every few seconds)"
  say ""
  say "  teams N   teams on this machine, across every project: on record, or with a window still open"
  say "  run   N   agent panes alive right now"
  say "  idle  N   agents on record with no pane: parked, and restartable (teamctl restart <role>)"
  say "  exit  N   panes whose agent exited. Only there when there are any, so no number is good news"
  say "  load  N   the one-minute load average of the machine"
  say "  mem   N   memory a process could still get (free plus inactive; the kernel hands inactive back)"
  say "  disk  N   free space on the disk that holds ~/.wolfmux"
  say "  held  N   what the PARKED lanes of every team hold: the space teamctl prune and teamctl remove"
  say "            give back. A dash means no team has been measured yet."
  say ""
  say "  run, idle and exit come from tmux, which is the only thing that knows. There is no"
  say "  'working' or 'waiting' field because no honest signal for one exists: an agent waiting"
  say "  for you and an agent thinking both run node, and tmux cannot tell them apart."
  say ""
  say "  held is read from what 'teamctl teams' last measured, and NEVER measured here: a du over"
  say "  this machine's lanes is about twelve seconds and this line redraws every few seconds. A"
  say "  parked lane is one in which nothing runs, so its size does not change and an old"
  say "  measurement of it is still true; what it cannot know is a lane parked or removed since."
  say "  Make it current: teamctl teams   ·   see where it is: teamctl prune --all-teams --dry-run"
  say ""
  say "  take the space: teamctl prune [--all-teams] [--dry-run]  ·  the whole picture: teamctl dashboard (prefix O)"
}
