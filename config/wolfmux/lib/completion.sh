#!/bin/bash
# completion.sh — tab completion for teamctl: one backend, thin shims.
#
#   teamctl _complete -- <word>...   (internal; the shims call it)
#
# The words are everything typed after teamctl, the last one being the word under
# the cursor (possibly empty). It prints candidates, one per line, as
# "candidate<TAB>short description" (the description is optional), and exits 0.
# The zsh and bash shims in config/wolfmux/completion/ call it and offer the
# result; file completion (--repo) is handed back to the shell with one line,
# __files__.
#
# It is silent and harmless by construction: no lock, nothing written to the
# state directory, no tmux session created, nothing on stderr, exit 0 with no
# output for what belongs to a project (roles, teams, approvals, branches) outside a
# git repository or when a team does not exist. It never dies.
# The knowledge (commands, options, values) lives here and nowhere else, so the
# shims cannot drift from it; tests/docs.sh guards the drift on the other side,
# against the option parsers.

# complete_emit <prefix> <candidate> [description] — print one candidate when it
# matches the prefix. The only output path: everything goes through here.
complete_emit() {
  local prefix="$1" candidate="$2" description="${3:-}"
  case "$candidate" in "$prefix"*) ;; *) return ;; esac
  if [ -n "$description" ]; then
    printf '%s\t%s\n' "$candidate" "$description"
  else
    printf '%s\n' "$candidate"
  fi
}

# complete_project — point PROJECT_STATE / PROJECT_TREES at the current repository,
# silently. Failure means "not in a project": what belongs to one is then not offered.
complete_project() {
  [ -n "$GIT_BIN" ] || return 1
  ROOT="$(resolve_root 2>/dev/null)" || return 1
  PROJECT_KEY="$(project_key "$ROOT")"
  PROJECT_STATE="$WOLFMUX_DATA/state/$PROJECT_KEY"
  PROJECT_TREES="$WOLFMUX_DATA/worktrees/$PROJECT_KEY"
}

# complete_team — the team the completion line is about: the one --team names, else
# the caller's own (an agent completing inside its pane), else the only team there
# is. With several teams and none named there is no single answer: empty.
complete_team() {
  if [ -n "$COMPLETE_TEAM" ]; then
    printf '%s\n' "$COMPLETE_TEAM"
    return 0
  fi
  local own teams count
  own="$(caller_team 2>/dev/null || true)"
  if [ -n "$own" ]; then
    printf '%s\n' "$own"
    return 0
  fi
  teams="$(team_list 2>/dev/null)"
  count="$(printf '%s' "$teams" | wc -w | tr -d ' ')"
  case "$count" in
    0) printf '%s\n' "$WOLFMUX_DEFAULT_TEAM" ;;
    1) printf '%s\n' "${teams% }" ;;
  esac
}

# complete_roles <prefix> [workers-only] — the roles of the team the line is about.
# workers-only is for remove and spawn --from-worktree, which never take the lead.
complete_roles() {
  [ "${COMPLETE_IN_PROJECT:-0}" = 1 ] || return 0
  local prefix="$1" workers_only="${2:-}" team role kind label
  team="$(complete_team)"
  [ -n "$team" ] || return 0
  valid_team_name "$team" || return 0
  team_paths "$team"
  [ -d "$STATE_DIR/agents" ] || return 0
  for role in $(reg_list 2>/dev/null); do
    kind="$(reg_field "$role" kind 2>/dev/null || true)"
    if [ "$kind" = "lead" ] && [ "$workers_only" = "workers-only" ]; then continue; fi
    label="$(agent_label "$role" 2>/dev/null || true)"
    complete_emit "$prefix" "$role" "$label"
  done
}

# complete_models <prefix> — the model keys, with the label from the model table.
complete_models() {
  local prefix="$1" key
  for key in $WOLFMUX_MODEL_KEYS; do
    model_info "$key" 2>/dev/null || continue
    complete_emit "$prefix" "$key" "$MODEL_LABEL"
  done
}

# complete_policy_values <prefix> <key> — a fixed-choice key's choices; a free-text
# key such as branch-template gets nothing.
complete_policy_values() {
  local prefix="$1" key="$2" choices choice
  case " $POLICY_KEYS " in *" $key "*) ;; *) return 0 ;; esac
  choices="$(policy_choices "$key" 2>/dev/null || true)"
  case "$choices" in
    "") return 0 ;; # an unknown key: nothing to offer
  esac
  # A fixed-choice key's choices are letters and pipes only; free text such as the
  # branch-template prose gets nothing. Anything left after stripping those is prose.
  [ -z "$(printf '%s' "$choices" | tr -d 'a-z0-9|')" ] || return 0
  for choice in $(printf '%s' "$choices" | tr '|' ' '); do
    complete_emit "$prefix" "$choice"
  done
}

# complete_approvals <prefix> — the ids of the PENDING approval requests of the team
# the line is about (state files, read-only).
complete_approvals() {
  [ "${COMPLETE_IN_PROJECT:-0}" = 1 ] || return 0
  local prefix="$1" team file id role tool
  team="$(complete_team)"
  [ -n "$team" ] || return 0
  valid_team_name "$team" || return 0
  team_paths "$team"
  for file in "$STATE_DIR"/approvals/A*.json; do
    [ -f "$file" ] || continue
    [ "$("$JQ_BIN" -r '.status' "$file" 2>/dev/null)" = "pending" ] || continue
    id="$(basename "$file" .json)"
    role="$("$JQ_BIN" -r '.role // empty' "$file" 2>/dev/null)"
    tool="$("$JQ_BIN" -r '.tool // empty' "$file" 2>/dev/null)"
    complete_emit "$prefix" "$id" "${role:+$role: }$tool"
  done
}

# complete_branches <prefix> — local branch names of this repository.
complete_branches() {
  [ "${COMPLETE_IN_PROJECT:-0}" = 1 ] || return 0
  local prefix="$1" branch
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    complete_emit "$prefix" "$branch"
  done <<EOF
$("$GIT_BIN" -C "$ROOT" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)
EOF
}

# complete_first_word <prefix> — the public commands (with their aliases workers,
# open and log), plus --team, help and version. Never an internal command: those
# start with _ and none of them is listed here.
complete_first_word() {
  local prefix="$1"
  complete_emit "$prefix" start "<model>: start this project's team and its lead pane"
  complete_emit "$prefix" spawn "<role> <model>: add a teammate in its own worktree"
  complete_emit "$prefix" stop "<role>: close a pane; worktree, branch and record stay"
  complete_emit "$prefix" remove "<role>...: take stopped workers off the books"
  complete_emit "$prefix" restart "<role>: run an agent again, fresh or with --continue"
  complete_emit "$prefix" model "<role> <model>: what an agent starts on next; --now switches it when safe"
  complete_emit "$prefix" destroy "end the team; --purge deletes it from disk"
  complete_emit "$prefix" prune "take the build output of every parked lane of the team"
  complete_emit "$prefix" reclaim "take every finished parked lane off the books: worktree, branch, record"
  complete_emit "$prefix" finish "the team is done: take every finished lane, then the team itself"
  complete_emit "$prefix" restore "bring back running teams and their tabs after a reboot"
  complete_emit "$prefix" keep "<role>: never sweep or reclaim that lane automatically"
  complete_emit "$prefix" bar "the status-bar line, and --explain names every field of it"
  complete_emit "$prefix" heavy "<command>...: run it holding the machine's heavy lock"
  complete_emit "$prefix" nudge "<role>: one fixed notification line in a pane"
  complete_emit "$prefix" inbox "<role>: the pane notices filed for an agent (alias: notices)"
  complete_emit "$prefix" notices "alias of inbox"
  complete_emit "$prefix" policy "show or set what the team may do (permissions, spawning, isolation)"
  complete_emit "$prefix" memory "team memory: status, enable <team>, disable, adopt <team>, path, check"
  complete_emit "$prefix" layout "how the panes are arranged (lead-left, lead-top, tiled)"
  complete_emit "$prefix" approvals "workers' permission requests waiting for the lead"
  complete_emit "$prefix" approve "<id>: allow a worker's permission request"
  complete_emit "$prefix" deny "<id>: refuse it, with a reason the worker reads"
  complete_emit "$prefix" status "process + worktree state per role (alias: workers)"
  complete_emit "$prefix" workers "alias of status"
  complete_emit "$prefix" teams "the short list of this project's teams"
  complete_emit "$prefix" dashboard "every team on this machine, across every project (prefix O opens it)"
  complete_emit "$prefix" panes "what tmux reports per pane"
  complete_emit "$prefix" capture "<role>: recent terminal output"
  complete_emit "$prefix" log "<role>: full scrollback (capture --all under another name)"
  complete_emit "$prefix" focus "<role>: focus a pane"
  complete_emit "$prefix" attach "attach your terminal to the team (alias: open)"
  complete_emit "$prefix" open "alias of attach"
  complete_emit "$prefix" worktrees "list the team's worktrees"
  complete_emit "$prefix" diff "<role>: a worker's branch against its base"
  complete_emit "$prefix" doctor "provider and billing isolation report; --probe checks a key"
  complete_emit "$prefix" models "what fable, opus, sonnet, haiku mean today, and who runs an older one"
  complete_emit "$prefix" completion "<zsh|bash>: print the tab-completion script of that shell"
  complete_emit "$prefix" store "show, or switch, which backend holds tasks, mail and shared team notes"
  complete_emit "$prefix" send "<role>|--all \"<subject>\": message an agent"
  complete_emit "$prefix" mail "[<role>]: unread mail and open tasks, with their bodies"
  complete_emit "$prefix" task "<role> \"<title>\": assign work"
  complete_emit "$prefix" claim "[<id>]: claim your only open task, or the one you name"
  complete_emit "$prefix" done "[<id>] \"<summary>\": close a task and report it"
  complete_emit "$prefix" blocked "[<id>] \"<why>\": mark a task blocked"
  complete_emit "$prefix" tasks "[<role>|--all]: a list of tasks"
  complete_emit "$prefix" show "<id>: one task or message, with its thread"
  complete_emit "$prefix" note "<id> \"<text>\": a durable note on a task"
  complete_emit "$prefix" reopen "<id> \"<why>\": (lead) send a closed task back"
  complete_emit "$prefix" close "<id> -r \"<reason>\": (lead) close or reject a task"
  complete_emit "$prefix" ledger "open work, recent reports, decisions: what the lead gets back after a compaction"
  complete_emit "$prefix" decide "\"<text>\": (lead) record a decision that outlives a compaction"
  complete_emit "$prefix" checkpoint "\"<text>\": save where you left off"
  complete_emit "$prefix" rotate "<role>: a fresh conversation with a hand-over"
  complete_emit "$prefix" run "-- <command>: a long output to a log, you get the short form"
  complete_emit "$prefix" remember "\"<fact>\": add to the shared team notes"
  complete_emit "$prefix" memories "[<query>]: search the shared team notes"
  complete_emit "$prefix" forget "<key>: remove one shared team note"
  complete_emit "$prefix" --team "<name>: act on another team of this project"
  complete_emit "$prefix" help "the full help"
  complete_emit "$prefix" version "the version line"
}

# complete_options <command> <prefix> — the options of one command, exactly the ones
# its parser accepts (--resume included although its parser lands in parallel: the
# task that adds it owns the parser, this list owns completion). --team is valid
# everywhere, so it is offered for every command.
complete_options() {
  local cmd="$1" prefix="$2" options="" option
  case "$cmd" in
    start) options="--no-attach --continue --handover --ticket --init-beads --skip-beads --lead-permissions --worker-permissions --worker-spawn --resume" ;;
    spawn) options="--base --from-worktree --branch --ticket --repo --no-kickoff --resume --link-node-modules" ;;
    restart) options="--continue --resume --model" ;;
    model) options="--now" ;;
    remove) options="--force --yes" ;;
    destroy) options="--worktrees --purge --force --keep-transcripts --memory --yes" ;;
    prune) options="--dry-run --keep-node-modules --all-teams" ;;
    reclaim) options="--dry-run --all-teams" ;;
    finish) options="--dry-run" ;;
    restore) options="--dry-run --yes --no-tabs" ;;
    bar) options="--explain" ;;
    heavy) options="--timeout --quiet" ;;
    nudge) options="--quiet --all --id" ;;
    inbox | notices) options="--all --json --keep" ;;
    capture) options="--lines --all" ;;
    diff) options="--stat --names --commits --working" ;;
    status | teams) options="--json" ;;
    dashboard) options="--json --once --interval --full --socket" ;;
    approvals) options="--all" ;;
    doctor) options="--probe" ;;
    models) options="--json --refresh" ;;
    send) options="--all --body-file --re" ;;
    mail) options="--peek --json" ;;
    checkpoint) options="--body-file --show" ;;
    rotate) options="--reason --now" ;;
    task) options="--after --body-file --spawn" ;;
    done) options="--tests --body-file --allow-dirty" ;;
    tasks) options="--all --status --json" ;;
    show) options="--json --report" ;;
    close) options="--failed" ;;
    remember) options="--key" ;;
    decide) options="--list --drop" ;;
    memories) options="--json" ;;
  esac
  for option in $options; do
    case "$option" in
      --lead-permissions) complete_emit "$prefix" "$option" "skip|ask" ;;
      --worker-permissions) complete_emit "$prefix" "$option" "skip|lead|ask" ;;
      --worker-spawn) complete_emit "$prefix" "$option" "on|off" ;;
      --base) complete_emit "$prefix" "$option" "<ref>: the base to branch from" ;;
      --branch) complete_emit "$prefix" "$option" "<name>: that exact branch name" ;;
      --from-worktree) complete_emit "$prefix" "$option" "<role>: reuse a stopped worker's built worktree" ;;
      --repo) complete_emit "$prefix" "$option" "<path>: work in another git repository" ;;
      --ticket) complete_emit "$prefix" "$option" "<KEY>: the ticket key for the branch name" ;;
      --handover) complete_emit "$prefix" "$option" "<bead-id>: the new lead starts by reading it" ;;
      --id) complete_emit "$prefix" "$option" "<bead-id>: the bead this is about" ;;
      --lines) complete_emit "$prefix" "$option" "<count>: how many lines" ;;
      --resume) complete_emit "$prefix" "$option" "<session-id>: reopen the conversation you name" ;;
      --link-node-modules) complete_emit "$prefix" "$option" "share the repository's node_modules instead of installing one" ;;
      --dry-run) complete_emit "$prefix" "$option" "report what it would free, delete nothing" ;;
      --keep-node-modules) complete_emit "$prefix" "$option" "take the build caches only" ;;
      --all-teams) complete_emit "$prefix" "$option" "every team of every project on this machine (yours alone to run)" ;;
      --explain) complete_emit "$prefix" "$option" "a legend naming every field of the status bar" ;;
      # --quiet is deliberately not described here: nudge and heavy both take it and it means
      # a different thing in each, and this case block is shared by every command.
      --timeout) complete_emit "$prefix" "$option" "<seconds>: give up waiting for the heavy lock (exit 75)" ;;
      --memory) complete_emit "$prefix" "$option" "with --purge: also the lead's memory folder (yours alone; you type the team's name)" ;;
      --body-file) complete_emit "$prefix" "$option" "<file>: read the body from it (- for stdin)" ;;
      --re) complete_emit "$prefix" "$option" "<bead-id>: this message replies to it" ;;
      --after) complete_emit "$prefix" "$option" "<bead-id>: this task waits on it" ;;
      --spawn) complete_emit "$prefix" "$option" "<model>: spawn the role if it is not already running" ;;
      --tests) complete_emit "$prefix" "$option" "\"<command: result>\"" ;;
      --status) complete_emit "$prefix" "$option" "<list>: statuses to include" ;;
      --key) complete_emit "$prefix" "$option" "<slug>: this note's key (shared team notes)" ;;
      --show) complete_emit "$prefix" "$option" "[<role>]: print a role's stored checkpoint" ;;
      --now) complete_emit "$prefix" "$option" "do not wait for the turn to end" ;;
      *) complete_emit "$prefix" "$option" ;;
    esac
  done
  complete_emit "$prefix" --team "<name>: act on another team of this project"
}

# complete_value <option> <prefix> — what the option before the cursor expects.
complete_value() {
  local option="$1" prefix="$2"
  case "$option" in
    --team | -T) complete_teams "$prefix" "" ;;
    --base | --branch) complete_branches "$prefix" ;;
    --repo) printf '__files__\n' ;;
    --from-worktree) complete_roles "$prefix" workers-only ;;
    --lead-permissions) complete_policy_choices "$prefix" skip ask ;;
    --worker-permissions) complete_policy_choices "$prefix" skip lead ask ;;
    --worker-spawn) complete_policy_choices "$prefix" on off ;;
    *) ;; # free text (a ticket key, a bead id, a session id, a line count): nothing
  esac
}

complete_policy_choices() {
  local prefix="$1"
  shift
  local choice
  for choice in "$@"; do
    complete_emit "$prefix" "$choice"
  done
}

# complete_teams <prefix> <reprint-prefix> — the team names of this project. The
# second argument is printed in front of each name: empty for "--team <Tab>", the
# typed "--team=" so the shell can match the word in place.
complete_teams() {
  [ "${COMPLETE_IN_PROJECT:-0}" = 1 ] || return 0
  local prefix="$1" reprint="$2" team
  while IFS= read -r team; do
    [ -n "$team" ] || continue
    case "$team" in "$prefix"*) ;; *) continue ;; esac
    if [ -n "$reprint" ]; then
      printf '%s\n' "$reprint$team" # --team=<name>: the word on the line is matched in place
    else
      complete_emit "$prefix" "$team"
    fi
  done <<EOF
$(team_list 2>/dev/null)
EOF
}

# --- the dispatcher -----------------------------------------------------------------

# cmd_complete — teamctl _complete -- <word>... (internal)
cmd_complete() {
  # A completion that goes wrong must cost nothing: no set -e death, no unbound
  # variable, no broken pipe held against us, no crash report from the EXIT trap.
  set +euo pipefail
  trap - EXIT
  [ "${1:-}" = "--" ] && shift
  # Commands, options, models, policy keys and layouts need no project: they are offered
  # anywhere. Roles, teams, approvals and branches belong to one: outside a git repository
  # those are empty, and that is all that differs (exit 0, nothing on stderr either way).
  COMPLETE_IN_PROJECT=1
  complete_project 2>/dev/null || COMPLETE_IN_PROJECT=0
  local -a words=("$@")
  local count=${#words[@]}
  [ "$count" -gt 0 ] || exit 0
  local cur="${words[$((count - 1))]}"
  local prev=""
  [ "$count" -ge 2 ] && prev="${words[$((count - 2))]}"
  local COMPLETE_TEAM="" cmd="" w i
  local -a pos=()
  # Walk everything before the cursor: which team the line names, which command it
  # is, which positional arguments stand already. --team <name> may stand anywhere,
  # as on the real command line.
  i=0
  while [ "$i" -lt $((count - 1)) ]; do
    w="${words[$i]}"
    case "$w" in
      --team | -T)
        if [ $((i + 1)) -lt $((count - 1)) ]; then
          COMPLETE_TEAM="${words[$((i + 1))]}"
          i=$((i + 1))
        fi
        ;;
      --team=*) COMPLETE_TEAM="${w#--team=}" ;;
      --base | --branch | --repo | --from-worktree | --handover | --ticket | --id | --lines | -n | --lead-permissions | --worker-permissions | --worker-spawn | --resume | --timeout | --model)
        # The option's value may stand after it, or be the word under the cursor.
        [ $((i + 1)) -lt $((count - 1)) ] && i=$((i + 1))
        ;;
      -*) ;;
      *)
        if [ -z "$cmd" ]; then
          cmd="$w"
        else
          pos+=("$w") # the command itself is not a positional argument
        fi
        ;;
    esac
    i=$((i + 1))
  done
  # A value option directly before the cursor: complete its value, whatever else.
  case "$cur" in
    --team=*)
      complete_teams "${cur#--team=}" "--team="
      exit 0
      ;;
  esac
  case "$prev" in
    --model)
      case "$cur" in
        -*) ;;
        *)
          complete_models "$cur"
          exit 0
          ;;
      esac
      ;;
    --team | -T | --base | --branch | --repo | --from-worktree | --lead-permissions | --worker-permissions | --worker-spawn)
      case "$cur" in
        -*) ;;
        *)
          complete_value "$prev" "$cur"
          exit 0
          ;;
      esac
      ;;
  esac
  # An option that takes free text (a conversation id, a bead id, a ticket key, a line count): nothing
  # can be offered for it, and above all not the roles or models of the position it stands in.
  case "$prev" in
    --resume | --id | --handover | --ticket | --lines | -n | --timeout)
      case "$cur" in
        -*) ;;
        *) exit 0 ;;
      esac
      ;;
  esac
  case "$cur" in
    -*)
      complete_options "$cmd" "$cur"
      exit 0
      ;;
    *)
      if [ -z "$cmd" ]; then
        complete_first_word "$cur"
        exit 0
      fi
      local position=${#pos[@]}
      case "$cmd" in
        start)
          [ "$position" -eq 0 ] && complete_models "$cur"
          ;;
        spawn)
          case "$position" in
            0) ;; # a NEW role: no candidate can know it
            1) complete_models "$cur" ;;
          esac
          ;;
        stop | restart | rotate | capture | log | focus | diff | nudge | inbox | notices)
          [ "$position" -eq 0 ] && complete_roles "$cur"
          ;;
        model)
          case "$position" in
            0) complete_roles "$cur" ;;
            1) complete_models "$cur" ;;
          esac
          ;;
        remove)
          complete_roles "$cur" workers-only
          ;;
        keep)
          case "$position" in
            0) complete_roles "$cur" workers-only ;;
            1) complete_policy_choices "$cur" on off ;;
          esac
          ;;
        approve)
          complete_approvals "$cur"
          ;;
        deny)
          [ "$position" -eq 0 ] && complete_approvals "$cur"
          ;;
        policy)
          case "$position" in
            0)
              local key
              for key in $POLICY_KEYS; do
                complete_emit "$cur" "$key"
              done
              ;;
            1)
              if [ "${pos[0]}" = "lead-model" ]; then
                complete_models "$cur"
                complete_emit "$cur" default
              else
                complete_policy_values "$cur" "${pos[0]}"
              fi
              ;;
          esac
          ;;
        layout)
          if [ "$position" -eq 0 ]; then
            local l
            for l in $WOLFMUX_LAYOUTS; do
              complete_emit "$cur" "$l"
            done
          fi
          ;;
        completion)
          [ "$position" -eq 0 ] && complete_policy_choices "$cur" zsh bash
          ;;
        memory)
          case "$position" in
            0) complete_policy_choices "$cur" status enable disable adopt path check ;;
            1) case "${pos[0]}" in enable | adopt) complete_teams "$cur" "" ;; esac ;;
          esac
          ;;
      esac
      ;;
  esac
  exit 0
}

# cmd_completion — teamctl completion <zsh|bash>: print the shim of that shell, so
# `source <(teamctl completion zsh)` works without install.sh having wired ~/.zshrc; in bash it is
# `eval "$(teamctl completion bash)"` (bash 3.2 cannot source a process substitution).
cmd_completion() {
  local shell="${1:-}" file
  case "$shell" in
    zsh | bash) ;;
    *) die_usage "usage: teamctl completion <zsh|bash>" ;;
  esac
  file="$WOLFMUX_HOME/completion/teamctl.$shell"
  [ -r "$file" ] || die "no completion script for $shell at $(short_path "$file") (install.sh puts it there)"
  /bin/cat "$file" 2>/dev/null || true # a reader that went away early is not an error, and not a crash to report
}
