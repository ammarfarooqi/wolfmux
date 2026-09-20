#!/bin/bash
# migrate-from-ai-team.sh — one-time move from this project's first name ("ai-team",
# v1.1 and earlier) to Wolfmux. Idempotent: run it again and it changes nothing.
#
# Safe while a team started under the old name is still up. Its tmux server keeps
# the old socket name and the new teamctl follows it there until its last session
# ends. The only thing refused is a live agent working inside ~/.ai-team.
#
#   ./migrate-from-ai-team.sh [--dry-run]
#
# What it does, in this order, after checking that every step can succeed:
#   1. carries ~/.config/ai-team/{config,glm-worker-settings.json} over to ~/.config/wolfmux
#   2. renames the marked block in ~/.zshrc and the two tmux rules in ~/.claude/settings.json
#   3. moves ~/.ai-team to ~/.wolfmux, fixes stored paths, runs `git worktree repair`
#   4. runs ./install.sh (new program files, ~/.codex/rules/wolfmux.rules)
#   5. rewrites each project's Beads hooks (.beads/hooks/on_*) to the new location
#   6. parks ~/.config/ai-team and ~/.codex/rules/ai-team.rules in ~/.wolfmux/backups/<stamp>/
# Edited files get <file>.backup-<stamp>. No repository content is committed or deleted,
# no credential is read, and the Keychain item (zai-coding-plan) keeps its name.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd -P)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OLD_NAME="ai-team"
OLD_CONF="$HOME/.config/$OLD_NAME"
OLD_DATA="$HOME/.$OLD_NAME"
OLD_RULES="$HOME/.codex/rules/$OLD_NAME.rules"
OLD_SOCKET="${WOLFMUX_LEGACY_SOCKET:-$OLD_NAME}" # overridable for tests/migration.sh
OLD_TMUX_RULES='Bash(tmux -L ai-team list-panes *)|Bash(tmux -L ai-team capture-pane *)'
NEW_CONF="$HOME/.config/wolfmux"
NEW_DATA="$HOME/.wolfmux"
PARK="$NEW_DATA/backups/$STAMP"
ZSHRC="$HOME/.zshrc"
SETTINGS="$HOME/.claude/settings.json"
DRY=0

case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  -h | --help)
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "migrate-from-ai-team.sh: unknown option: $1" >&2
    exit 64
    ;;
esac

say() { printf '%s\n' "$*"; }
note() { if [ "$DRY" -eq 1 ]; then printf '  (dry run) %s\n' "$*"; else printf '  %s\n' "$*"; fi; }
die() {
  printf 'migrate-from-ai-team.sh: %s\n' "$*" >&2
  exit 1
}
# run <command...> — the single switch between doing and describing
run() {
  if [ "$DRY" -eq 1 ]; then return 0; fi
  "$@"
}
backup() {
  run /bin/cp -p "$1" "$1.backup-$STAMP"
  note "backup: $1.backup-$STAMP"
}

has_old_zsh_block() { [ -f "$ZSHRC" ] && grep -q "^# >>> $OLD_NAME >>>" "$ZSHRC"; }
has_new_zsh_block() { [ -f "$ZSHRC" ] && grep -q '^# >>> wolfmux >>>' "$ZSHRC"; }
has_old_claude_rules() {
  [ -f "$SETTINGS" ] && jq -e --arg old "$OLD_TMUX_RULES" \
    '[(.permissions.allow // [])[] | select(. as $r | ($old | split("|")) | index($r))] | length > 0' "$SETTINGS" >/dev/null 2>&1
}

# ---------------------------------------------------------------- anything to do?
if [ ! -e "$OLD_CONF" ] && [ ! -e "$OLD_DATA" ] && [ ! -e "$OLD_RULES" ] && ! has_old_zsh_block && ! has_old_claude_rules; then
  say "Nothing to migrate: no trace of an $OLD_NAME installation for $USER."
  exit 0
fi
[ "$DRY" -eq 0 ] || say "DRY RUN — nothing below is changed."

# ---------------------------------------------------------------- preflight (no changes yet)
say "== preflight"
for tool in jq git; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
[ -x "$REPO/install.sh" ] || die "install.sh not found next to this script"

# a live agent inside the old data directory would keep using paths that are about to move
if command -v tmux >/dev/null 2>&1; then
  busy="$(tmux -L "$OLD_SOCKET" list-panes -a -F '#{pane_dead}|#{@ai_role}|#{pane_current_path}' 2>/dev/null |
    awk -F'|' -v prefix="$OLD_DATA/" '$1 == "0" && index($3, prefix) == 1 { print "    " $2 "  (" $3 ")" }' || true)"
  if [ -n "$busy" ]; then
    printf 'migrate-from-ai-team.sh: these agents are running inside %s:\n%s\n' "$OLD_DATA" "$busy" >&2
    die "stop them first (teamctl stop <role> — worktrees and branches are kept), then run this again"
  fi
  if tmux -L "$OLD_SOCKET" has-session 2>/dev/null; then
    note "a team is running on the old tmux socket: it keeps running; teamctl will follow it there"
  fi
fi

# state, worktrees and backups are merged child by child when ~/.wolfmux already exists
if [ -d "$OLD_DATA" ] && [ -d "$NEW_DATA" ]; then
  for group in state worktrees backups; do
    [ -d "$OLD_DATA/$group" ] || continue
    for child in "$OLD_DATA/$group"/*; do
      [ -e "$child" ] || continue
      [ ! -e "$NEW_DATA/$group/$(basename "$child")" ] ||
        die "both $child and $NEW_DATA/$group/$(basename "$child") exist; merge them by hand, then run this again"
    done
  done
fi
note "ok"

# ---------------------------------------------------------------- 1. your settings
say "== 1. settings you may have edited"
run /bin/mkdir -p "$NEW_CONF"
run /bin/chmod 700 "$NEW_CONF"
if [ -f "$OLD_CONF/config" ] && [ ! -e "$NEW_CONF/config" ]; then
  if grep -qvE '^[[:space:]]*(#|$)' "$OLD_CONF/config"; then
    if [ "$DRY" -eq 0 ]; then
      sed -e 's/AI_TEAM_/WOLFMUX_/g' -e "s/$OLD_NAME/wolfmux/g" "$OLD_CONF/config" >"$NEW_CONF/config"
      /bin/chmod 644 "$NEW_CONF/config"
    fi
    note "carried over with renamed keys: $NEW_CONF/config"
  else
    note "config holds no setting of yours: the new default will be installed"
  fi
fi
if [ -f "$OLD_CONF/glm-worker-settings.json" ] && [ ! -e "$NEW_CONF/glm-worker-settings.json" ]; then
  run /bin/cp -p "$OLD_CONF/glm-worker-settings.json" "$NEW_CONF/glm-worker-settings.json"
  note "carried over: $NEW_CONF/glm-worker-settings.json"
fi

# ---------------------------------------------------------------- 2. marked edits in your own files
say "== 2. ~/.zshrc and ~/.claude/settings.json"
if has_old_zsh_block; then
  backup "$ZSHRC"
  if [ "$DRY" -eq 0 ]; then
    if has_new_zsh_block; then
      # both blocks: drop the old one and the blank separator line in front of it
      awk -v name="$OLD_NAME" '
        $0 ~ "^# >>> " name " >>>" { skipping = 1; holding = 0; next }
        skipping && $0 ~ "^# <<< " name " <<<" { skipping = 0; next }
        skipping { next }
        { if (holding) print held; if ($0 == "") { held = $0; holding = 1 } else { holding = 0; print } }
        END { if (holding) print held }
      ' "$ZSHRC" >"$ZSHRC.tmp.$$"
    else
      sed -e "s/^# >>> $OLD_NAME >>>/# >>> wolfmux >>>/" -e "s/^# <<< $OLD_NAME <<</# <<< wolfmux <<</" "$ZSHRC" >"$ZSHRC.tmp.$$"
    fi
    /bin/mv -f "$ZSHRC.tmp.$$" "$ZSHRC"
  fi
  note "renamed the marked PATH block in ~/.zshrc (content unchanged)"
else
  note "~/.zshrc: no old block"
fi
if has_old_claude_rules; then
  backup "$SETTINGS"
  if [ "$DRY" -eq 0 ]; then
    jq --arg old_name "$OLD_NAME" '
      .permissions.allow = (reduce ((.permissions.allow // [])[]
          | if test("^Bash\\(tmux -L " + $old_name + " (list-panes|capture-pane) \\*\\)$")
            then sub("-L " + $old_name + " "; "-L wolfmux ") else . end) as $rule
        ([]; if index($rule) then . else . + [$rule] end))' "$SETTINGS" >"$SETTINGS.tmp.$$"
    /bin/mv -f "$SETTINGS.tmp.$$" "$SETTINGS"
    /bin/chmod 600 "$SETTINGS"
  fi
  note "renamed the two read-only tmux rules in ~/.claude/settings.json"
else
  note "~/.claude/settings.json: no old rule"
fi

# ---------------------------------------------------------------- 3. state and worktrees
say "== 3. $OLD_DATA -> $NEW_DATA"
move_data() {
  local group child
  if [ ! -d "$NEW_DATA" ]; then
    /bin/mv "$OLD_DATA" "$NEW_DATA"
    return 0
  fi
  for group in state worktrees backups; do
    [ -d "$OLD_DATA/$group" ] || continue
    /bin/mkdir -p "$NEW_DATA/$group"
    for child in "$OLD_DATA/$group"/*; do
      [ -e "$child" ] || continue
      /bin/mv "$child" "$NEW_DATA/$group/"
    done
  done
  # Whatever is left (Finder's .DS_Store, a file that is not ours) is parked, not deleted,
  # so the old directory is gone for good and a second run has nothing to do.
  /usr/bin/find "$OLD_DATA" -depth -type d -empty -delete 2>/dev/null || true
  if [ -e "$OLD_DATA" ]; then
    /bin/mkdir -p "$PARK"
    /bin/mv "$OLD_DATA" "$PARK/data-$OLD_NAME-leftover"
    note "parked what was left of $OLD_DATA: $PARK/data-$OLD_NAME-leftover"
  fi
}
if [ -d "$OLD_DATA" ]; then
  run move_data
  run /bin/chmod 700 "$NEW_DATA"
  note "moved"
else
  note "no $OLD_DATA"
fi

# stored absolute paths (a worker's worktree) follow the move
rewrite_records() {
  local file tmp
  for file in "$NEW_DATA"/state/*/agents/*.json "$NEW_DATA"/state/*/meta.json; do
    [ -f "$file" ] || continue
    tmp="$file.tmp.$$"
    jq --arg old "$OLD_DATA/" --arg new "$NEW_DATA/" \
      'walk(if type == "string" and startswith($old) then $new + ltrimstr($old) else . end)' "$file" >"$tmp"
    if /usr/bin/cmp -s "$tmp" "$file"; then
      /bin/rm -f "$tmp"
    else
      /bin/mv -f "$tmp" "$file"
      note "updated paths: ${file#"$NEW_DATA"/}"
    fi
  done
}
run rewrite_records

# git keeps the worktree's location in <repo>/.git/worktrees/<name>/gitdir
repair_worktrees() {
  local meta root key tree trees
  for meta in "$NEW_DATA"/state/*/meta.json; do
    [ -f "$meta" ] || continue
    root="$(jq -r '.root // empty' "$meta")"
    key="$(basename "$(dirname "$meta")")"
    [ -n "$root" ] && [ -d "$root" ] || continue
    trees=()
    for tree in "$NEW_DATA/worktrees/$key"/*; do
      [ -f "$tree/.git" ] && trees+=("$tree")
    done
    [ "${#trees[@]}" -gt 0 ] || continue
    if git -C "$root" worktree repair "${trees[@]}" >/dev/null 2>&1; then
      note "git worktree repair: ${#trees[@]} worktree(s) of $root"
    else
      note "WARNING: git worktree repair failed in $root — run it there by hand: git worktree repair ${trees[*]}"
    fi
  done
}
run repair_worktrees

# ---------------------------------------------------------------- 4. program files
say "== 4. install.sh"
if [ "$DRY" -eq 0 ]; then
  WOLFMUX_MIGRATING=1 "$REPO/install.sh" | sed 's/^/  | /'
else
  note "would run: $REPO/install.sh"
fi

# ---------------------------------------------------------------- 5. Beads hooks
say "== 5. Beads hooks in your projects"
refresh_hooks() {
  local meta root
  for meta in "$NEW_DATA"/state/*/meta.json; do
    [ -f "$meta" ] || continue
    root="$(jq -r '.root // empty' "$meta")"
    [ -n "$root" ] && [ -d "$root" ] || continue
    if grep -qs "$OLD_NAME-hook" "$root"/.beads/hooks/on_* 2>/dev/null; then
      (cd "$root" && WOLFMUX_ROOT="$root" "$HOME/bin/teamctl" _refresh-hooks 2>&1 | sed 's/^/  | /') ||
        note "WARNING: could not refresh hooks in $root (the next 'teamctl start' there does it)"
    fi
  done
}
run refresh_hooks
note "done"

# ---------------------------------------------------------------- 6. park what is left of the old name
say "== 6. leftovers"
if [ -d "$OLD_CONF" ]; then
  run /bin/mkdir -p "$PARK"
  run /bin/mv "$OLD_CONF" "$PARK/config-$OLD_NAME"
  note "parked: $OLD_CONF -> $PARK/config-$OLD_NAME"
fi
if [ -f "$OLD_RULES" ]; then
  run /bin/mkdir -p "$PARK"
  run /bin/mv "$OLD_RULES" "$PARK/$OLD_NAME.rules"
  note "parked: $OLD_RULES -> $PARK/$OLD_NAME.rules"
fi

/bin/cat <<EOF

== next
1. Open a new terminal (or: exec zsh), then:   teamctl doctor
2. In each project with a team:                teamctl status
3. A lead that was already running keeps its old instructions until you run:
     teamctl restart lead --continue
EOF
