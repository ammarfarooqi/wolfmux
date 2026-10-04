#!/bin/bash
# migration.sh — rehearsal of migrate-from-ai-team.sh in a throwaway HOME.
#
# Installs v1.1 (the last release under the old name) from git history, runs a
# real team with it (stub agents, its own tmux sockets), migrates, and checks that
# the running lead survives and that state, worktrees, hooks and the three edited
# files end up right. Finishes with uninstall.sh to prove the round trip is clean.
# Nothing outside the temporary directory is read or written. No model is called.
#
#   tests/migration.sh
# No pipefail: checks end in `grep -q`, which closes the pipe early by design.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
OLD_RELEASE="deff83a" # v1.1.0, the last commit that installs as "ai-team"
REAL_TMUX_DIR="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/wolfmux-migration.XXXXXX")" && pwd -P)"
OLD_SOCKET="wolfmux-mig-old-$$"
NEW_SOCKET="wolfmux-mig-new-$$"

export HOME="$WORK/home"
export PATH="$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" # no bd: Beads is not under test
export WOLFMUX_LEGACY_SOCKET="$OLD_SOCKET"
export WOLFMUX_TMUX_SOCKET="$NEW_SOCKET" # everything the new code starts or asks stays on test sockets
unset TMUX TMUX_PANE TEAM_ROLE BEADS_ACTOR WOLFMUX_ROOT AI_TEAM_ROOT
unset WOLFMUX_TEAM WOLFMUX_TEAM_ARG WOLFMUX_SESSION WOLFMUX_WORKTREE WOLFMUX_BRANCH WOLFMUX_MODEL WOLFMUX_EXTRA_SETTINGS # an agent running this test carries its own team

passed=0
failed=0
check() { # <description> <command string>
  if eval "$2" >/dev/null 2>&1; then
    passed=$((passed + 1))
    printf '  pass  %s\n' "$1"
  else
    failed=$((failed + 1))
    printf '  FAIL  %s\n' "$1"
  fi
}
cleanup() {
  local socket
  for socket in "$OLD_SOCKET" "$NEW_SOCKET"; do
    tmux -L "$socket" kill-server >/dev/null 2>&1
    /bin/rm -f "$REAL_TMUX_DIR/$socket"
  done
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT

git -C "$REPO" cat-file -e "$OLD_RELEASE^{commit}" 2>/dev/null || {
  echo "migration.sh: commit $OLD_RELEASE (v1.1.0) is not in this clone's history" >&2
  exit 1
}

# --- a machine as v1.1 left it ---------------------------------------------------
/bin/mkdir -p "$HOME/.codex" "$HOME/.claude" "$WORK/v1.1"
printf 'export EDITOR=vi\n' >"$HOME/.zshrc"
printf '{"permissions":{"allow":["Bash(ls *)"]},"tui":"fullscreen"}\n' >"$HOME/.claude/settings.json"
/bin/cp "$HOME/.zshrc" "$WORK/zshrc.original"
jq -S . "$HOME/.claude/settings.json" >"$WORK/settings.original"
git -C "$REPO" archive "$OLD_RELEASE" | tar -x -C "$WORK/v1.1"
"$WORK/v1.1/install.sh" >/dev/null 2>&1 || {
  echo "migration.sh: could not install v1.1 into the throwaway HOME" >&2
  exit 1
}
printf '\nAI_TEAM_APPROVAL_TIMEOUT=42\n' >>"$HOME/.config/ai-team/config" # a setting of the user's own

PROJECT="$WORK/code/demo"
/bin/mkdir -p "$PROJECT"
cd "$PROJECT" || exit 1
git init -q -b main
echo "hello" >README.md
git add -A
git -c user.name=t -c user.email=t@example.invalid commit -qm "initial commit"

old_teamctl() {
  AI_TEAM_TMUX_SOCKET="$OLD_SOCKET" AI_TEAM_LAUNCHER_ASTRA="$WORK/v1.1/tests/stub-agent" \
    AI_TEAM_LAUNCHER_GLM53="$WORK/v1.1/tests/stub-agent" "$HOME/bin/teamctl" "$@"
}
new_teamctl() {
  WOLFMUX_TMUX_SOCKET="$NEW_SOCKET" WOLFMUX_ADOPT_LEGACY=1 WOLFMUX_LAUNCHER_ASTRA="$REPO/tests/stub-agent" \
    WOLFMUX_LAUNCHER_GLM53="$REPO/tests/stub-agent" "$HOME/bin/teamctl" "$@"
}
old_teamctl start astra --no-attach --skip-beads >/dev/null 2>&1
old_teamctl spawn research glm53 --no-kickoff >/dev/null 2>&1
sleep 2
/bin/mkdir -p "$PROJECT/.beads/hooks"
for name in on_create on_update on_close; do
  printf '#!/bin/bash\n# ai-team-hook v1 — tmux pane notifications\nhook="$HOME/.config/ai-team/hooks/beads-nudge"\n[ -x "$hook" ] || exit 0\nexec "$hook" "$@"\n' >"$PROJECT/.beads/hooks/$name"
done
OLD_TREE="$(old_teamctl status --json | jq -r '.agents[] | select(.role == "research") | .workdir')"
echo "draft" >"$OLD_TREE/notes.txt" # uncommitted work that must survive the move
LEAD_PID="$(tmux -L "$OLD_SOCKET" list-panes -a -F '#{@ai_role} #{pane_pid}' | awk '$1 == "lead" { print $2 }')"

echo "== before"
check "v1.1 team is up: lead + one worker inside ~/.ai-team" '[ -n "$LEAD_PID" ] && [ "${OLD_TREE#"$HOME/.ai-team/worktrees/"}" != "$OLD_TREE" ]'
check "new install.sh refuses to install next to the old installation" '! "$REPO/install.sh" && [ ! -e "$HOME/.config/wolfmux" ]'
check "migration refuses while a worker runs inside ~/.ai-team, and changes nothing" '! "$REPO/migrate-from-ai-team.sh" && [ -d "$HOME/.ai-team" ] && [ ! -e "$HOME/.wolfmux" ] && [ ! -e "$HOME/.config/wolfmux" ]'
old_teamctl stop research >/dev/null 2>&1
check "--dry-run changes nothing" '"$REPO/migrate-from-ai-team.sh" --dry-run && [ -d "$HOME/.ai-team" ] && [ ! -e "$HOME/.wolfmux" ] && [ ! -e "$HOME/.config/wolfmux" ] && grep -q ">>> ai-team >>>" "$HOME/.zshrc"'

# The third-party providers come from the provider table: one launcher link each, except glm
# (claude-glm is the file itself). A script of the user's own under one of those names is theirs.
PROVIDER_LAUNCHERS="$( . "$REPO/config/wolfmux/lib/provider-env.sh"; for provider in $WOLFMUX_PROVIDERS; do [ "$provider" = glm ] || printf 'claude-%s ' "$provider"; done)"
OWN_LAUNCHER="claude-minimax"
/bin/mkdir -p "$HOME/bin"
printf '#!/bin/sh\necho mine\n' >"$HOME/bin/$OWN_LAUNCHER"
/bin/chmod 755 "$HOME/bin/$OWN_LAUNCHER"

echo "== migrate"
/bin/cp "$HOME/.zshrc" "$WORK/zshrc.before"
"$REPO/migrate-from-ai-team.sh" >"$WORK/migrate.log" 2>&1
MIGRATE_STATUS=$?
check "migration exits 0" '[ "$MIGRATE_STATUS" -eq 0 ]'
NEW_TREE="$HOME/.wolfmux/worktrees/${OLD_TREE#"$HOME/.ai-team/worktrees/"}"
check "old directories are gone, the old config is parked in backups" '[ ! -e "$HOME/.ai-team" ] && [ ! -e "$HOME/.config/ai-team" ] && ls "$HOME"/.wolfmux/backups/*/config-ai-team/lib/common.sh'
check "the user setting came along under its new key" 'grep -qx "WOLFMUX_APPROVAL_TIMEOUT=42" "$HOME/.config/wolfmux/config" && ! grep -q "AI_TEAM" "$HOME/.config/wolfmux/config"'
check "program files are the new version" '[ "$("$HOME/bin/teamctl" version)" = "teamctl $(sed -n "s/^WOLFMUX_VERSION=\"\(.*\)\"/\1/p" "$REPO/config/wolfmux/lib/common.sh")" ]'
check "provider launchers: one link to claude-glm per provider; a launcher script of the user's own is kept" '[ -n "$PROVIDER_LAUNCHERS" ] && for name in $PROVIDER_LAUNCHERS; do [ "$name" = "$OWN_LAUNCHER" ] && continue; [ "$(readlink "$HOME/bin/$name")" = "claude-glm" ] || exit 1; done && [ ! -L "$HOME/bin/$OWN_LAUNCHER" ] && [ "$("$HOME/bin/$OWN_LAUNCHER")" = mine ]'
check "provider launchers: installed teamctl knows the providers (help lists them, the table is installed)" '[ -f "$HOME/.config/wolfmux/lib/providers.sh" ] && "$HOME/bin/teamctl" help | grep -q "kimi:<model-id>"'
check "the running lead was not restarted" '[ "$(tmux -L "$OLD_SOCKET" list-panes -a -F "#{@ai_role} #{pane_pid} #{pane_dead}" | awk "\$1 == \"lead\" { print \$2, \$3 }")" = "$LEAD_PID 0" ]'
check "new teamctl sees that team: lead running, research stopped, worktree present" 'new_teamctl status --json | jq -e --arg tree "$NEW_TREE" ".session_running and ([.agents[] | select(.role == \"lead\")][0].state == \"running\") and ([.agents[] | select(.role == \"research\")][0] | .state == \"stopped\" and .workdir == \$tree)"'
check "git knows the worktree at its new path, nothing prunable" 'git -C "$PROJECT" worktree list --porcelain | grep -qx "worktree $NEW_TREE" && ! git -C "$PROJECT" worktree list --porcelain | grep -q "^prunable"'
check "uncommitted work in the worktree survived" '[ "$(/bin/cat "$NEW_TREE/notes.txt")" = "draft" ] && git -C "$NEW_TREE" status --porcelain | grep -q notes.txt'
check "the worker restarts in the moved worktree" 'new_teamctl restart research && sleep 2 && new_teamctl capture research -n 8 | grep -q "STUB cwd=$NEW_TREE"'
check "Beads hooks point at the new location" '[ "$(grep -l "wolfmux-hook v1" "$PROJECT"/.beads/hooks/on_* | wc -l | tr -d " ")" = 3 ] && ! grep -q "ai-team" "$PROJECT"/.beads/hooks/on_*'
check "~/.zshrc: one block; its two marker lines changed, and the block gained the two tab-completion lines and nothing else" '[ "$(grep -c ">>> wolfmux >>>" "$HOME/.zshrc")" = 1 ] && [ "$(grep -c "completion/teamctl.zsh" "$HOME/.zshrc")" = 1 ] && sed -e "s/^# >>> ai-team >>>/# >>> wolfmux >>>/" -e "s/^# <<< ai-team <<</# <<< wolfmux <<</" "$WORK/zshrc.before" >"$WORK/zshrc.expected" && sed -e "/completion\/teamctl.zsh/d" -e "/Tab completion for teamctl/d" "$HOME/.zshrc" | /usr/bin/cmp -s - "$WORK/zshrc.expected"'
# v1.1 added rules that allowed more than they read (git diff/log/show *, tmux list-panes/capture-pane *).
# The migration renames the tmux ones, then install.sh retires all five: what is left is your own
# rule plus the four current ones.
check "settings.json: no rule under the old name, the retired rules are gone, everything else kept" 'jq -e "(.permissions.allow | index(\"Bash(ls *)\")) and (.permissions.allow | index(\"Bash(teamctl *)\")) and (.tui == \"fullscreen\") and ([.permissions.allow[] | select(test(\"ai-team|tmux -L|git (diff|log|show) \"))] | length == 0) and (.permissions.allow | length == 5)" "$HOME/.claude/settings.json"'
check "Codex rules: new file in place, old one parked" '[ -f "$HOME/.codex/rules/wolfmux.rules" ] && [ ! -e "$HOME/.codex/rules/ai-team.rules" ] && ls "$HOME"/.wolfmux/backups/*/ai-team.rules'
check "no stored record still points into ~/.ai-team" '! grep -rIl --exclude="events.jsonl" -e "/\.ai-team/" "$HOME/.wolfmux/state"'
check "running it again finds nothing to do" '"$REPO/migrate-from-ai-team.sh" | grep -q "Nothing to migrate"'

echo "== round trip"
check "uninstall refuses while the pre-rename team is still up" '! "$REPO/uninstall.sh"'
new_teamctl destroy --worktrees --yes >/dev/null 2>&1
check "after destroy, uninstall restores ~/.zshrc byte for byte and settings.json in content" '"$REPO/uninstall.sh" && /usr/bin/cmp -s "$HOME/.zshrc" "$WORK/zshrc.original" && [ "$(jq -S . "$HOME/.claude/settings.json")" = "$(/bin/cat "$WORK/settings.original")" ]'
# uninstall has run in the check above
check "uninstall took the provider links away, and kept the launcher script that is the user's own" 'for name in $PROVIDER_LAUNCHERS; do [ "$name" = "$OWN_LAUNCHER" ] && continue; [ ! -e "$HOME/bin/$name" ] && [ ! -L "$HOME/bin/$name" ] || exit 1; done && [ "$("$HOME/bin/$OWN_LAUNCHER")" = mine ] && [ ! -e "$HOME/bin/claude-glm" ] && [ ! -e "$HOME/bin/claude-glm-flash" ] && [ ! -e "$HOME/bin/teamctl" ]'

echo "== tab completion (installer)"
# A fresh install ships the shims and the two lines in ~/.zshrc. A block from before
# completion existed (a block without the source line) is upgraded in place, after a
# backup, and running the installer again changes nothing. --no-completion skips only
# the completion lines, --no-path skips ~/.zshrc entirely, and uninstall takes the
# files away with the block.
zshrc_backups() { /bin/ls "$HOME"/.zshrc.backup-* 2>/dev/null | wc -l | tr -d ' '; }
strip_completion_lines() {
  sed -e '/completion\/teamctl.zsh/d' -e '/Tab completion for teamctl/d' "$HOME/.zshrc" >"$HOME/.zshrc.stripped"
  /bin/mv -f "$HOME/.zshrc.stripped" "$HOME/.zshrc"
}
check "completion: a fresh install ships the shims and sources them in ~/.zshrc" '"$REPO/install.sh" --no-claude-permissions --no-codex-rules --no-notifier-app >/dev/null 2>&1 && [ -f "$HOME/.config/wolfmux/completion/teamctl.zsh" ] && [ -f "$HOME/.config/wolfmux/completion/teamctl.bash" ] && [ "$(grep -c "completion/teamctl.zsh" "$HOME/.zshrc")" = 1 ]'
check "completion: the installed teamctl serves completions from the installed files" 'PATH="$HOME/bin:$PATH" "$HOME/bin/teamctl" _complete -- "" | grep -q "^start	" && PATH="$HOME/bin:$PATH" "$HOME/bin/teamctl" completion zsh | grep -q "_teamctl" && PATH="$HOME/bin:$PATH" "$HOME/bin/teamctl" completion bash | grep -q "_teamctl_bash"'
strip_completion_lines
/bin/cp "$HOME/.zshrc" "$WORK/zshrc.pre-upgrade"
has_backup_of() { local b; for b in "$HOME"/.zshrc.backup-*; do [ -f "$b" ] && /usr/bin/cmp -s "$b" "$1" && return 0; done; return 1; } # the stamp has seconds: counting files would miss two installs in one second
check "completion: a block without the completion line is upgraded in place, exactly once, and a backup holds the file as it was" '"$REPO/install.sh" --no-claude-permissions --no-codex-rules --no-notifier-app >/dev/null 2>&1; [ "$(grep -c "completion/teamctl.zsh" "$HOME/.zshrc")" = 1 ] && [ "$(grep -c "Tab completion for teamctl" "$HOME/.zshrc")" = 1 ] && has_backup_of "$WORK/zshrc.pre-upgrade"'
check "completion: the upgrade touched nothing but the two lines" 'strip_completion_lines; /bin/cp "$HOME/.zshrc" "$WORK/zshrc.without"; "$REPO/install.sh" --no-claude-permissions --no-codex-rules --no-notifier-app >/dev/null 2>&1; [ "$(grep -c "completion/teamctl.zsh" "$HOME/.zshrc")" = 1 ] && sed -e "/completion\/teamctl.zsh/d" -e "/Tab completion for teamctl/d" "$HOME/.zshrc" | /usr/bin/cmp -s - "$WORK/zshrc.without"'
check "completion: running the installer again changes nothing" 'hash_before="$(shasum -a 256 "$HOME/.zshrc")"; backups="$(zshrc_backups)"; "$REPO/install.sh" --no-claude-permissions --no-codex-rules --no-notifier-app >/dev/null 2>&1; [ "$(shasum -a 256 "$HOME/.zshrc")" = "$hash_before" ] && [ "$(zshrc_backups)" = "$backups" ]'
strip_completion_lines
check "completion: --no-completion skips only the completion lines" '"$REPO/install.sh" --no-completion --no-claude-permissions --no-codex-rules --no-notifier-app >/dev/null 2>&1 && ! grep -q "completion/teamctl.zsh" "$HOME/.zshrc" && grep -q ">>> wolfmux >>>" "$HOME/.zshrc"'
check "completion: a plain install re-adds what --no-completion skipped (the upgrade stays idempotent)" '"$REPO/install.sh" --no-claude-permissions --no-codex-rules --no-notifier-app >/dev/null 2>&1 && [ "$(grep -c "completion/teamctl.zsh" "$HOME/.zshrc")" = 1 ]'
strip_completion_lines
check "completion: --no-path leaves ~/.zshrc untouched" 'hash_before="$(shasum -a 256 "$HOME/.zshrc")"; "$REPO/install.sh" --no-path --no-completion --no-claude-permissions --no-codex-rules --no-notifier-app >/dev/null 2>&1; [ "$(shasum -a 256 "$HOME/.zshrc")" = "$hash_before" ]'
# A ~/.zshrc that is a symlink into a dotfiles folder, readable by its owner only: it is written through, not replaced.
/bin/mkdir -p "$HOME/dotfiles" && /bin/mv "$HOME/.zshrc" "$HOME/dotfiles/zshrc" && /bin/ln -s "$HOME/dotfiles/zshrc" "$HOME/.zshrc" && /bin/chmod 600 "$HOME/dotfiles/zshrc"
strip_through() { sed -e '/completion\/teamctl.zsh/d' -e '/Tab completion for teamctl/d' "$HOME/dotfiles/zshrc" >"$WORK/zshrc.stripped" && /bin/cat "$WORK/zshrc.stripped" >"$HOME/dotfiles/zshrc"; }
strip_through
check "completion: a symlinked ~/.zshrc stays a symlink, its target gets the lines and keeps its mode (0600)" '"$REPO/install.sh" --no-claude-permissions --no-codex-rules --no-notifier-app >/dev/null 2>&1; [ -L "$HOME/.zshrc" ] && [ "$(grep -c "completion/teamctl.zsh" "$HOME/dotfiles/zshrc")" = 1 ] && [ "$(stat -f %Lp "$HOME/dotfiles/zshrc")" = 600 ]'
/bin/cp "$HOME/dotfiles/zshrc" "$WORK/zshrc.whole"
printf '\n# >>> wolfmux >>> (a block somebody cut the end off)\n[[ -d "$HOME/bin" ]] && path+=("$HOME/bin")\n' >"$HOME/dotfiles/zshrc"
check "completion: a block without its closing marker is left alone, and the installer says so instead of claiming it added the lines" 'before="$(shasum -a 256 "$HOME/dotfiles/zshrc")"; out="$("$REPO/install.sh" --no-claude-permissions --no-codex-rules --no-notifier-app 2>&1)"; [ "$(shasum -a 256 "$HOME/dotfiles/zshrc")" = "$before" ] && printf "%s" "$out" | grep -q "closing marker" && ! printf "%s" "$out" | grep -q "added tab completion"'
/bin/cat "$WORK/zshrc.whole" >"$HOME/dotfiles/zshrc"
check "completion: uninstall writes through a symlinked ~/.zshrc as well (still a symlink, mode kept)" '"$REPO/uninstall.sh" >/dev/null 2>&1; [ -L "$HOME/.zshrc" ] && [ "$(stat -f %Lp "$HOME/dotfiles/zshrc")" = 600 ] && ! grep -q ">>> wolfmux >>>" "$HOME/dotfiles/zshrc"'
"$REPO/install.sh" --no-claude-permissions --no-codex-rules --no-notifier-app >/dev/null 2>&1
check "completion: uninstall takes the completion files away with the block" '"$REPO/uninstall.sh" >/dev/null 2>&1 && [ ! -e "$HOME/.config/wolfmux" ] && ! grep -q ">>> wolfmux >>>" "$HOME/.zshrc" && ! grep -q "completion/teamctl.zsh" "$HOME/.zshrc"'

echo
echo "result: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || {
  echo "--- migrate.log"
  /bin/cat "$WORK/migrate.log"
}
[ "$failed" -eq 0 ]
