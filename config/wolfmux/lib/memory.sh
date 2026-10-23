#!/bin/bash
# memory.sh — one team's lead keeps a private memory folder (policy team-memory, v1.22.0).
#
# You name ONE team of the project: `teamctl memory enable <team>` (or `teamctl policy team-memory
# <team>`, the same thing). That team's lead, and no other agent:
#   · has ~/.wolfmux/memory/<project-key>/<team>/ as Claude Code's autoMemoryDirectory
#     (write_agent_settings), so the MEMORY.md there is loaded at every start of it,
#   · finds a "## Team memory" block at the end of its system prompt (build_role_prompt): the
#     folder, the privacy rule, the shared project memory folder and the boot line. Never the card
#     or anything else from the folder: a system prompt is not private (memory_prompt_block says why),
#   · is started with a first prompt that runs `<folder>/bin/mem boot` (cmd_run_agent), at every
#     launch: fresh, --continue, --resume and restore alike.
# Everybody else is kept out of it: the worktree guard refuses a worker's tool call that names the
# folder (lib/guard.sh). What that is not: a sandbox. docs/SECURITY.md says where it ends.
#
# Enabling is yours alone (require_operator): which conversation may keep notes that no team sees
# is a decision about your own work. Disabling only narrows, so the memory team's own lead may do it
# too. Neither deletes anything; the folder goes only with `teamctl destroy --purge --memory`, which
# is yours alone too (the pane proof, require_operator), or with `uninstall.sh --purge --purge-memory`.
# `memory check` and `memory path` are yours and that lead's (memory_may_disable): check runs
# `mem check`, which writes and names notes, and path is the folder handed to a script.
#
# The folder's contents (bin/mem, the templates, the schema) are the memory skeleton, installed to
# ~/.config/wolfmux/memory-skeleton/ and copied once by `enable`. teamctl calls only `mem init`,
# `mem boot` and `mem check`, and reads nothing in the folder but file sizes: nothing else crosses
# that line.

MEMORY_INDEX_CAP=25000 # bytes of MEMORY.md that Claude Code's auto memory loads

# memory_team — the team policy team-memory names, empty when it is off. Needs the project loaded.
memory_team() {
  local team
  team="$(policy_get team-memory)"
  [ "$team" = "off" ] || printf '%s\n' "$team"
}

# memory_dir_for <team> — that team's memory folder (whether or not it exists)
memory_dir_for() { printf '%s/memory/%s/%s\n' "$WOLFMUX_DATA" "$PROJECT_KEY" "$1"; }

# memory_lead_dir <role> — prints the folder, status 0, when <role> of the loaded team is the lead of
# the memory team; prints nothing, status 1, for everybody else. The one question every caller asks.
# Two more conditions, so that a memory is never handed to a lead you did not start:
#   · you founded the team (team_founder): after `destroy --purge` or `finish`, another lead may start
#     a team of the same name, and its lead is not the one you gave the memory to;
#   · the folder holds an executable bin/mem: a missing or hand-edited folder is not a memory.
memory_lead_dir() {
  local team dir
  [ "$1" = "$WOLFMUX_LEAD_ROLE" ] || return 1
  team="$(memory_team)"
  [ -n "$team" ] && [ "$team" = "${TEAM:-$WOLFMUX_DEFAULT_TEAM}" ] || return 1
  [ "$(team_founder)" = "operator" ] || return 1
  dir="$(memory_dir_for "$team")"
  [ -x "$dir/bin/mem" ] || return 1
  printf '%s\n' "$dir"
}

# memory_lead_started_with <role> — 0 when <role> is the loaded team's lead and its settings file (written at its last
# start, write_agent_settings) carries autoMemoryDirectory. A running lead keeps the memory it was started with until
# its next restart, whatever the policy says now (memory disable, another team named, a lost x bit on bin/mem): what
# its screen may show follows what it holds, not what memory_lead_dir would give it next time.
memory_lead_started_with() {
  [ "$1" = "$WOLFMUX_LEAD_ROLE" ] || return 1
  [ -n "$("$JQ_BIN" -r '.autoMemoryDirectory // empty' "$STATE_DIR/settings/$1.json" 2>/dev/null || true)" ]
}

# project_memory_dir — Claude Code's own memory of this repository, which every session in it shares:
# <transcripts>/<the root, every character but a letter or digit turned into "-">/memory/
# (transcripts_dir; /Users/x/Documents/fpro/fanpro-studio-fe is -Users-x-Documents-fpro-fanpro-studio-fe,
# measured against the real folder on 2026-10-23)
project_memory_dir() {
  local dir
  dir="$(transcripts_dir "$ROOT" 2>/dev/null)" || return 1
  printf '%s/memory/\n' "$dir"
}

# memory_team_state <team> — that team's state directory, without moving STATE_DIR
memory_team_state() {
  if [ "$1" = "$WOLFMUX_DEFAULT_TEAM" ]; then printf '%s\n' "$PROJECT_STATE"; else printf '%s/teams/%s\n' "$PROJECT_STATE" "$1"; fi
}

# memory_bytes <file> — its size in bytes, 0 when there is none
memory_bytes() {
  if [ -f "$1" ]; then /usr/bin/wc -c <"$1" | /usr/bin/tr -d ' '; else printf '0\n'; fi
}

# memory_boot_text <dir> — the first prompt of the memory team's lead, at every launch
memory_boot_text() {
  printf 'Team memory is on. Run %s/bin/mem boot, read what it prints, re-create the crons it lists, then read your Beads inboxes.' "$1"
}

# memory_prompt_block <dir> — the "## Team memory" block at the end of that lead's system prompt: where the
# folder is, the rules, the shared folder, and the boot line. Nothing from the folder itself, not even the card.
# A system prompt is not private: it rides --append-system-prompt, so `ps -axww -o command=` shows it to every
# process of your user, and `teamctl _prompt lead --team <team>` prints it to any caller. The card is read by
# `mem boot`, in the lead's own conversation (the boot prompt, cmd_run_agent), and nowhere else.
memory_prompt_block() {
  local dir="$1" shared
  shared="$(project_memory_dir || printf '(unknown)')"
  printf '## Team memory\n\n'
  printf 'Team memory is ON for team %s, and you are its lead. Your memory folder: %s\n\n' "${TEAM:-$WOLFMUX_DEFAULT_TEAM}" "$dir"
  printf -- '- It is private to you. Only you read and write it; no other agent may, and the worktree guard refuses a worker that tries.\n'
  printf -- '- Never copy its contents into Beads, Jira, Slack, repositories or reports. A report about it carries structure and counts only (how many notes, which folders, how many bytes), never what a note says.\n'
  printf -- '- The shared memory of this repository, which every session here can read, is %s. Read it when you need it; it is not private, so nothing of yours goes there.\n\n' "$shared"
  printf 'Run `%s/bin/mem boot` before anything else, and again after every compaction. The card wins over a re-sent handover on HOW to work; the handover is a task.\n' "$dir"
}

# memory_log <action> <team> <previous> [<event detail>] — one line in the project's team-memory.jsonl and one in
# the event log, BEFORE the policy moves: a change of who keeps private notes that nobody can look up is
# not made (the steward's record works the same way, lib/policy.sh). With an event detail (adopt), the event
# is that action, not a policy change.
memory_log() {
  local file="$PROJECT_STATE/team-memory.jsonl" by
  by="${EVENT_BY:-$(caller_identity 2>/dev/null || printf operator)}"
  /bin/mkdir -p "$PROJECT_STATE" 2>/dev/null || true
  if ! {
    "$JQ_BIN" -cn --arg ts "$(now_iso)" --arg by "$by" --arg action "$1" --arg team "$2" --arg previous "$3" \
      '{ts: $ts, by: $by, action: $action, team: $team, previous: $previous}' >>"$file"
  } 2>/dev/null; then
    die "the team-memory record cannot be written ($(short_path "$file")); the policy was not changed."
  fi
  if [ -n "${4:-}" ]; then
    EVENT_BY="$by" event_log "$1" "" "$4" || true
  else
    EVENT_BY="$by" event_log policy "" "team-memory=$2 (was $3; $1)" || true
  fi
}

# memory_may_disable — you, or the lead of the memory team itself (proven in its own pane)
memory_may_disable() {
  is_operator && return 0
  [ "$CALLER_ROLE" = "$WOLFMUX_LEAD_ROLE" ] && [ "${CALLER_TEAM:-$WOLFMUX_DEFAULT_TEAM}" = "$(memory_team)" ]
}

# memory_copy_skeleton <skeleton> <dir> — a new folder: directories 700, files 600, bin/mem 700. Built
# beside its place and moved in, so a copy that fails leaves no half folder that `enable` would keep.
memory_copy_skeleton() {
  local skel="$1" dir="$2" tmp path
  /bin/mkdir -p "$(dirname "$dir")" || return 1
  /bin/chmod 700 "$WOLFMUX_DATA/memory" "$(dirname "$dir")" 2>/dev/null || true
  tmp="$dir.new.$$"
  /bin/rm -rf "$tmp"
  /bin/mkdir -m 700 "$tmp" || return 1
  while IFS= read -r path; do
    [ "$path" = "." ] || /bin/mkdir -m 700 "$tmp/$path" || return 1
  done < <(cd "$skel" && /usr/bin/find . -type d | /usr/bin/sed 's|^\./||')
  while IFS= read -r path; do
    /usr/bin/install -m 600 "$skel/$path" "$tmp/$path" || return 1
  done < <(cd "$skel" && /usr/bin/find . -type f | /usr/bin/sed 's|^\./||')
  if [ -f "$tmp/bin/mem" ]; then /bin/chmod 700 "$tmp/bin/mem"; fi
  /bin/mv "$tmp" "$dir"
}

memory_enable() {
  local team="$1" skel="$WOLFMUX_HOME/memory-skeleton" dir previous teams id founder
  require_operator "memory enable" "a private memory folder for one team's lead of this project (policy team-memory)" \
    "nothing to set: teamctl memory status says whether it is on. If your team needs it, tell the human"
  valid_team_name "$team" || die_usage "$(team_name_error "$team")"
  teams="$(team_list | tr '\n' ' ')" # in a variable: no pipe for a grep -q to close under pipefail
  case " $teams " in
    *" $team "*) ;;
    *) die_usage "team-memory: '$team' is not a team of this project (teams: ${teams% })" ;;
  esac
  # A memory is handed only to a lead you started (memory_lead_dir), and a team keeps its founder through every
  # restart, restore and model change (lead_restore): on a team an agent founded it would never reach the lead.
  founder="$( (team_paths "$team" && team_founder) 2>/dev/null || true)"
  if [ -n "$founder" ] && [ "$founder" != "operator" ]; then
    die "team $team was founded by $founder, not by you, and a team memory is only ever handed to the lead of a team you founded: its lead would never get it, at any restart. Make the team yours first: teamctl memory adopt $team   then again: teamctl memory enable $team   (nothing was changed)"
  fi
  dir="$(memory_dir_for "$team")"
  if [ -d "$dir" ]; then
    say "folder:      $(short_path "$dir")   (kept as it is: an existing folder is never overwritten)"
  else
    [ -x "$skel/bin/mem" ] || die "the memory skeleton is not installed ($(short_path "$skel")/bin/mem is missing). Run install.sh from the Wolfmux repository, then again: teamctl memory enable $team"
    memory_copy_skeleton "$skel" "$dir" || die "could not create $(short_path "$dir"); the policy was not changed."
    say "folder:      $(short_path "$dir")   (new, from $(short_path "$skel"); only you can read it: mode 700)"
  fi
  [ -x "$dir/bin/mem" ] || die "$(short_path "$dir")/bin/mem is missing or not executable; the policy was not changed."
  MEM_ROOT="$dir" "$dir/bin/mem" init >/dev/null || die "'mem init' failed in $(short_path "$dir"); the policy was not changed."
  previous="$(policy_get team-memory)"
  memory_log enable "$team" "$previous"
  project_policy_put policy_team_memory "$team"
  say "policy:      team-memory = $team   (for the whole project; was $previous)"
  if [ "$previous" != "off" ] && [ "$previous" != "$team" ]; then
    say "             team $previous has no memory from its lead's next restart; its folder is kept: $(short_path "$(memory_dir_for "$previous")")"
  fi
  id="$("$JQ_BIN" -r '.session_id // empty' "$(memory_team_state "$team")/agents/$WOLFMUX_LEAD_ROLE.json" 2>/dev/null || true)"
  say "next:        it reaches the lead of $team at its next restart: teamctl restart lead --team $team $([ -n "$id" ] && printf -- '--resume %s' "$id" || printf -- '--continue')"
}

memory_disable() {
  local previous by
  caller_resolve
  if ! memory_may_disable; then
    die "'teamctl memory disable' is yours and the memory team's lead's. You are '$(team_identity "${CALLER_TEAM:-$WOLFMUX_DEFAULT_TEAM}" "$CALLER_ROLE")'; team memory is $(policy_get team-memory) for this project. Nothing to do for you: tell that lead or the human." 77
  fi
  previous="$(policy_get team-memory)"
  if [ "$previous" = "off" ]; then
    say "team-memory is already off for this project."
    return 0
  fi
  memory_log disable off "$previous"
  project_policy_put policy_team_memory off
  say "policy:      team-memory = off   (for the whole project; was $previous)"
  say "folder:      kept, nothing deleted: $(short_path "$(memory_dir_for "$previous")")"
  say "             it reaches the lead of $previous at its next restart. Delete the folder: teamctl destroy --team $previous --purge --memory"
  # The lead turned its own memory off: you are told, as you are of a founder's acts (founder_announce).
  if ! caller_is_you; then
    by="$(caller_identity)"
    (WOLFMUX_TEAM="$previous" notify_deliver "$WOLFMUX_LEAD_MARK $by switched team memory off for team '$previous' (the folder is kept)." >/dev/null 2>&1) || true
  fi
}

# memory_lead_sessions <conversation id> — how many processes on this machine carry that id in their
# command line (claude --resume <id>, --session-id <id>): more than one is two sessions in one memory
memory_lead_sessions() {
  "$WOLFMUX_PS_BIN" -axo pid=,command= 2>/dev/null | MEMORY_SID="$1" /usr/bin/awk 'index($0, ENVIRON["MEMORY_SID"]) { n++ } END { print n + 0 }'
}

memory_status() {
  local team dir index card files kb settings session pane state started id sessions folders="" path founder family
  team="$(memory_team)"
  if [ -z "$team" ]; then
    say "team-memory:  off   (policy, for the whole project: no lead has a private memory folder)"
    for path in "$WOLFMUX_DATA/memory/$PROJECT_KEY"/*/; do
      [ -d "$path" ] && folders="$folders $(basename "$path")"
    done
    [ -z "$folders" ] || say "kept folders:$folders   (under $(short_path "$WOLFMUX_DATA/memory/$PROJECT_KEY")/; nothing reads them while it is off)"
    say "turn it on:   teamctl memory enable <team>   (yours alone, from your own terminal)"
    return 0
  fi
  dir="$(memory_dir_for "$team")"
  say "team-memory:  $team   (policy, for the whole project: its lead keeps a private memory folder)"
  if [ ! -d "$dir" ]; then
    say "folder:       $(short_path "$dir")   MISSING: teamctl memory enable $team creates it"
  else
    files="$(/usr/bin/find "$dir" -type f 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    kb="$(disk_kb "$dir")"
    say "folder:       $(short_path "$dir")   $files files, $(human_size "$kb")"
    index="$(memory_bytes "$dir/MEMORY.md")"
    say "index:        MEMORY.md $index of $MEMORY_INDEX_CAP bytes$([ "$index" -le "$MEMORY_INDEX_CAP" ] || printf '   OVER THE CAP: Claude Code loads only the start of it')"
    card="$(memory_bytes "$dir/core/card.md")"
    say "card:         core/card.md $card bytes   (mem boot reads it in the lead's conversation; it is never in a prompt)"
    [ -x "$dir/bin/mem" ] || warn "$(short_path "$dir")/bin/mem is missing or not executable: the lead gets no memory until it is back (teamctl memory enable $team)"
  fi
  founder="$( (team_paths "$team" && team_founder) 2>/dev/null || true)"
  if [ -n "$founder" ] && [ "$founder" != "operator" ]; then
    warn "team $team was founded by $founder, not by you: its lead gets no memory, and no restart or restore changes a team's founder. Make the team yours: teamctl memory adopt $team   (yours alone)"
  fi
  family="$("$JQ_BIN" -r '.family // empty' "$(memory_team_state "$team")/agents/$WOLFMUX_LEAD_ROLE.json" 2>/dev/null || true)"
  if [ "$family" = "codex" ]; then
    warn "the lead of $team runs Codex: Codex has no autoMemoryDirectory, so MEMORY.md is not loaded for it, and a resumed Codex lead (resume --last) opens the newest conversation of the folder every lead shares. Team memory is built for a Claude lead: teamctl model lead opus --team $team"
  fi
  settings="$(memory_team_state "$team")/settings/$WOLFMUX_LEAD_ROLE.json"
  session="$( (team_paths "$team" && session_name_for_project) 2>/dev/null || true)"
  pane="$(tm_pane_for_role "$session" "$WOLFMUX_LEAD_ROLE" 2>/dev/null || true)"
  state="$(tm_pane_state "$pane")"
  if [ "$state" != "running" ]; then
    say "lead:         not running   (it gets the memory at its next start)"
  else
    started="$(/usr/bin/stat -f %m "$settings" 2>/dev/null || printf 0)"
    if [ "$("$JQ_BIN" -r '.autoMemoryDirectory // empty' "$settings" 2>/dev/null || true)" = "$dir" ]; then
      say "lead:         running, started $(date -r "$started" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '?') WITH the setting"
    else
      say "lead:         running, started WITHOUT the setting (before team memory was turned on): it gets it at its next restart"
    fi
  fi
  id="$("$JQ_BIN" -r '.session_id // empty' "$(memory_team_state "$team")/agents/$WOLFMUX_LEAD_ROLE.json" 2>/dev/null || true)"
  if [ -n "$id" ]; then
    sessions="$(memory_lead_sessions "$id")"
    if [ "$sessions" -gt 1 ]; then
      warn "$sessions lead sessions of team $team are alive (processes with conversation $id): two sessions write over each other's memory. Keep one."
    fi
  fi
  say "note:         enable and disable reach a running lead only at its next restart (a card edit, at its next mem boot): teamctl restart lead --team $team $([ -n "$id" ] && printf -- '--resume %s' "$id" || printf -- '--continue')"
}

# memory_require_owner <subcommand> — check and path are yours and the memory team's lead's, as disable is:
# `mem check` writes (it rebuilds MEMORY.md and the card) and prints the names of notes, and the path is
# what a script would hand to cat. The lead must also be the one that HAS the memory (memory_lead_dir: a
# lead of the same team name that another lead started has none). Exit 77 for anybody else; status says
# what anyone may know.
memory_require_owner() {
  caller_resolve
  is_operator && return 0
  if memory_may_disable && (team_paths "${CALLER_TEAM:-$WOLFMUX_DEFAULT_TEAM}" && memory_lead_dir "$CALLER_ROLE") >/dev/null 2>&1; then
    return 0
  fi
  die "'teamctl memory $1' is yours and the memory team's lead's. You are '$(team_identity "${CALLER_TEAM:-$WOLFMUX_DEFAULT_TEAM}" "$CALLER_ROLE")'. What anyone may see: teamctl memory status (sizes and counts, never what a note says)." 77
}

memory_path() {
  local team
  memory_require_owner path
  team="$(memory_team)"
  [ -n "$team" ] || exit 1
  say "$(memory_dir_for "$team")"
}

memory_check() {
  local team dir
  memory_require_owner check
  team="$(memory_team)"
  [ -n "$team" ] || die "team-memory is off for this project: nothing to check (teamctl memory status)"
  dir="$(memory_dir_for "$team")"
  [ -x "$dir/bin/mem" ] || die "$(short_path "$dir")/bin/mem is missing: teamctl memory enable $team"
  MEM_ROOT="$dir" "$dir/bin/mem" check
}

# memory_unpinned_reason <memory team> <folder> — why a lead may not --continue without a conversation id while
# team memory is on: the one sentence memory_require_pinned and _run-agent both say
memory_unpinned_reason() {
  printf "team memory is on for this project (team '%s' keeps it), and the lead of team '%s' has no stored conversation id: --continue would open the newest conversation in %s, which may be another lead's, and a lead's private memory (mem boot prints its card into that lead's own conversation) would be read into another one." \
    "$1" "${TEAM:-$WOLFMUX_DEFAULT_TEAM}" "$(short_path "$2")"
}

# memory_require_pinned <role> <resume 0|1> <pinned id> <stored id> <family> — while team memory is on for the project,
# `start --continue` and `restart --continue` of EVERY Claude lead of it need a conversation id, stored or named, as
# restore does. Every lead of the project works in its root, so they share one transcripts folder, and the CLI's own
# --continue opens the NEWEST conversation in it: the memory team's lead could be handed another lead's conversation,
# and any other lead the memory lead's, where mem boot printed the card. Refused before anything is changed. With the
# policy off, nothing here refuses (_run-agent warns and guesses, as before team memory). Codex resumes with
# `resume --last` whatever is said here; memory_status warns about a Codex memory lead.
memory_require_pinned() {
  local team
  [ "$1" = "$WOLFMUX_LEAD_ROLE" ] && [ "$2" -eq 1 ] && [ -z "$3" ] && [ -z "$4" ] && [ "$5" != "codex" ] || return 0
  team="$(memory_team)"
  [ -n "$team" ] || return 0
  die "$(memory_unpinned_reason "$team" "$ROOT") Name the conversation: teamctl restart $1 --team ${TEAM:-$WOLFMUX_DEFAULT_TEAM} --resume <session-id> (teamctl status --json shows the ids), or start it fresh$([ "$team" = "${TEAM:-$WOLFMUX_DEFAULT_TEAM}" ] && printf ': its memory brings it back up to date (mem boot)')."
}

# memory_adopt <team> — `teamctl memory adopt <team>`: the team becomes yours, as if you had founded it, so that its
# lead may be given team memory (memory_enable refuses a team an agent founded). The lead's record (spawned_by) and
# meta.json (founder, kept for when that record is gone) both say operator from now on; every later start, restart
# and restore carries that on (lead_restore). The founding agent loses what a founder may do while the lead is down
# (FOUNDER_COMMANDS). Logged in team-memory.jsonl and the team's event log, and you are told. Yours alone.
memory_adopt() {
  local team="$1" teams founder
  require_operator "memory adopt" "who founded a team of this project (a founder acts on it while its lead is down, and only a team you founded may keep team memory)" \
    "nothing to adopt: a team's founder is the human's to change. If your team needs it, tell the human"
  valid_team_name "$team" || die_usage "$(team_name_error "$team")"
  teams="$(team_list | tr '\n' ' ')"
  case " $teams " in
    *" $team "*) ;;
    *) die_usage "memory adopt: '$team' is not a team of this project (teams: ${teams% })" ;;
  esac
  team_paths "$team"
  founder="$(team_founder)"
  if [ "$founder" = "operator" ]; then
    say "team $team is already yours (you founded it): nothing to adopt."
    return 0
  fi
  memory_log adopt "$team" "$founder" "team $team adopted by the human: founder $founder -> operator"
  lock_acquire
  if reg_exists "$WOLFMUX_LEAD_ROLE"; then reg_set "$WOLFMUX_LEAD_ROLE" spawned_by operator; fi
  meta_put founder operator
  lock_release
  say "founder:     team $team is yours now (was $founder): $founder no longer acts on it as its founder."
  say "next:        teamctl memory enable $team   gives its lead team memory, at its next restart"
  (WOLFMUX_TEAM="$team" notify_deliver "$WOLFMUX_LEAD_MARK you adopted team '$team', which $founder founded: it is yours now." >/dev/null 2>&1) || true
}

# memory_policy_set <value> — `teamctl policy team-memory <team>|off`, the same as enable and disable
memory_policy_set() {
  if [ "$1" = "off" ]; then memory_disable; else memory_enable "$1"; fi
}

# memory_purge_confirm <team> — `teamctl destroy --purge --memory`: the folder goes only after the
# team's name is typed at a terminal. No --yes for this one. This catches a slip of yours; it is not
# what keeps an agent out (a terminal can be faked): cmd_destroy's require_operator is.
memory_purge_confirm() {
  local dir answer
  dir="$(memory_dir_for "$1")"
  [ -d "$dir" ] || return 0
  say ""
  say "--memory: ALSO DELETE the lead's private memory folder $(short_path "$dir") ($(human_size "$(disk_kb "$dir")"))."
  say "          Nothing else holds what it says. Type the team's name to delete it."
  [ -t 0 ] || die "--memory needs the team's name typed at a terminal; nothing was deleted."
  printf "team name (%s): " "$1" >&2
  read -r answer || answer=""
  [ "$answer" = "$1" ] || die "the name did not match; nothing was deleted (team '$1' and its memory are untouched)."
}

# memory_purge <team> — the deleting, after memory_purge_confirm. The policy goes off with it when it
# named this team: a team started later under the same name starts without a memory nobody made.
memory_purge() {
  local dir
  dir="$(memory_dir_for "$1")"
  case "$dir" in "$WOLFMUX_DATA/memory/$PROJECT_KEY/"?*) ;; *) die "refusing to delete $dir: not a memory folder of this project" ;; esac
  if [ -d "$dir" ]; then
    /bin/rm -rf "$dir"
    say "memory folder deleted: $(short_path "$dir")"
  fi
  /bin/rmdir "$WOLFMUX_DATA/memory/$PROJECT_KEY" 2>/dev/null || true
  if [ "$(policy_get team-memory)" = "$1" ]; then
    memory_log purge off "$1"
    project_policy_put policy_team_memory off
    say "policy: team-memory = off   (it named the deleted team)"
  fi
}

# teamctl memory [status|enable <team>|disable|adopt <team>|path|check]
cmd_memory() {
  local sub="${1:-status}"
  [ "$#" -eq 0 ] || shift
  require_tools
  load_project any
  case "$sub" in
    status)
      [ "$#" -eq 0 ] || die_usage "usage: teamctl memory status"
      memory_status
      ;;
    enable)
      [ "$#" -eq 1 ] || die_usage "usage: teamctl memory enable <team>   (yours alone)"
      memory_enable "$1"
      ;;
    disable)
      [ "$#" -eq 0 ] || die_usage "usage: teamctl memory disable   (it turns off whichever team has it)"
      memory_disable
      ;;
    adopt)
      [ "$#" -eq 1 ] || die_usage "usage: teamctl memory adopt <team>   (yours alone)"
      memory_adopt "$1"
      ;;
    path)
      [ "$#" -eq 0 ] || die_usage "usage: teamctl memory path"
      memory_path
      ;;
    check)
      [ "$#" -eq 0 ] || die_usage "usage: teamctl memory check"
      memory_check
      ;;
    *) die_usage "usage: teamctl memory [status | enable <team> | disable | adopt <team> | path | check]" ;;
  esac
}
