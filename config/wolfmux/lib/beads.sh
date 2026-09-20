#!/bin/bash
# beads.sh — the thin seam between teamctl and Beads (bd).
#
# Beads owns tasks and messages. teamctl never reads or writes a bead. The only
# glue is (1) making sure a Beads workspace exists before a team starts and
# (2) two tiny event hooks that turn "a bead needs <role>" into a tmux pane
# notification through `teamctl nudge`.

WOLFMUX_HOOK_MARKER="wolfmux-hook v1"
WOLFMUX_LEGACY_HOOK_MARKER="ai-team-hook" # written before the rename; safe to replace
WOLFMUX_BEADS_HOOKS="on_create on_update on_close"

# The least intrusive documented init: no git commit, no tracked files (uses
# .git/info/exclude), no git hooks, no AGENTS.md / Claude / Codex file changes.
WOLFMUX_BD_INIT_ARGS="init --stealth --skip-hooks --skip-agents --non-interactive"

# beads_prefix — an issue prefix Beads accepts (letters, digits, hyphens, starting
# with a letter), derived from the directory name. bd's own default is the raw
# directory name, which it rejects for names such as "My Project" or "2024-app".
beads_prefix() {
  local name
  name="$(sanitize_name "$(basename "$ROOT")" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | cut -c1-24)"
  name="${name%-}"
  case "$name" in
    [a-z]*) ;;
    *) name="p-$name" ;;
  esac
  printf '%s\n' "${name%-}"
}

# beads_dir — path of the workspace that bd resolves from $ROOT, or empty
beads_dir() {
  [ -n "$BD_BIN" ] || return 1
  (cd "$ROOT" && "$BD_BIN" where 2>/dev/null | head -1) | grep -E '^/' || return 1
}

# beads_ensure <ask|yes|skip>
beads_ensure() {
  local mode="$1" dir prefix
  [ "$mode" = "skip" ] && return 0
  [ -n "$BD_BIN" ] || die "Beads (bd) is not installed; the team uses it for tasks and messages. See: teamctl doctor"
  if dir="$(beads_dir)"; then
    beads_install_hooks "$dir"
    return 0
  fi
  info "Beads is not initialized in $(short_path "$ROOT")."
  info "Least intrusive setup (no commit, no tracked files, no git hooks, no AGENTS.md changes):"
  prefix="$(beads_prefix)"
  info "    cd \"$(short_path "$ROOT")\" && bd $WOLFMUX_BD_INIT_ARGS --prefix $prefix"
  if [ "$mode" = "yes" ] || confirm "Run that now?"; then
    # shellcheck disable=SC2086
    (cd "$ROOT" && "$BD_BIN" $WOLFMUX_BD_INIT_ARGS --prefix "$prefix" >&2) || die "bd init failed"
    dir="$(beads_dir)" || die "bd init finished but no workspace was found"
    beads_install_hooks "$dir"
    return 0
  fi
  die "initialize Beads first (command above, or your own 'bd init' flavour), or pass --init-beads / --skip-beads."
}

_beads_hook_body() {
  /bin/cat <<EOF
#!/bin/bash
# $WOLFMUX_HOOK_MARKER — tmux pane notifications for wolfmux (installed by teamctl; safe to delete)
hook="\${WOLFMUX_HOME:-\$HOME/.config/wolfmux}/hooks/beads-nudge"
[ -x "\$hook" ] || exit 0
exec "\$hook" "\$@"
EOF
}

# cmd_refresh_hooks — internal (`teamctl _refresh-hooks`): rewrite this project's hooks,
# e.g. after the rename, when the old ones point at a directory that no longer exists
cmd_refresh_hooks() {
  local dir
  require_tools
  load_project
  if ! dir="$(beads_dir)"; then
    # bd missing or unwilling: the default location is still ours to fix
    if [ -d "$ROOT/.beads/hooks" ]; then
      dir="$ROOT/.beads"
    else
      info "no Beads workspace in $(short_path "$ROOT"); nothing to refresh"
      return 0
    fi
  fi
  beads_install_hooks "$dir"
  say "Beads hooks: $(beads_hooks_status "$dir")  ($(short_path "$dir")/hooks)"
}

# beads_install_hooks <beads-dir> — never overwrites a hook it did not write
beads_install_hooks() {
  local dir="$1/hooks" name path
  /bin/mkdir -p "$dir"
  for name in $WOLFMUX_BEADS_HOOKS; do
    path="$dir/$name"
    if [ -e "$path" ] && ! grep -qE "$WOLFMUX_HOOK_MARKER|$WOLFMUX_LEGACY_HOOK_MARKER" "$path" 2>/dev/null; then
      warn "$(short_path "$path") exists and is not ours; left untouched. Pane notifications for '$name' are off until it calls: ~/.config/wolfmux/hooks/beads-nudge \"\$@\""
      continue
    fi
    _beads_hook_body >"$path"
    /bin/chmod 755 "$path"
  done
}

# beads_hooks_status <beads-dir> — installed | partial | missing
beads_hooks_status() {
  local dir="$1/hooks" name ours=0 total=0
  for name in $WOLFMUX_BEADS_HOOKS; do
    total=$((total + 1))
    grep -q "$WOLFMUX_HOOK_MARKER" "$dir/$name" 2>/dev/null && ours=$((ours + 1))
  done
  if [ "$ours" -eq "$total" ]; then
    printf 'installed\n'
  elif [ "$ours" -eq 0 ]; then
    printf 'missing\n'
  else
    printf 'partial\n'
  fi
}
