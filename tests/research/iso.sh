#!/bin/bash
# iso.sh <scratch-dir> <command...> - run one command in the isolated measurement environment:
# this worktree's teamctl and config, a scratch data directory, its own tmux server, and nothing
# of the calling agent's session (TEAM_ROLE, WOLFMUX_*, CLAUDE*, TMUX are dropped).
# The scratch directory holds bin/ (symlinks to this worktree's bin/teamctl and launcher) and proj/.
# ISO_DATA=<name> picks the data directory of one run (default data); the project stays the same,
# because folder trust is recorded per project path and is asked for once.
# ISO_AS=lead makes the command act as that team's lead from outside.
set -u
here="$(cd "$(dirname "$0")/../.." && pwd -P)"
scratch="$1"
shift
for name in $(compgen -e); do
  case "$name" in
    WOLFMUX_* | CLAUDE* | TEAM_ROLE | BEADS_ACTOR | TMUX | TMUX_PANE) unset "$name" ;;
  esac
done
export WOLFMUX_HOME="$here/config/wolfmux" WOLFMUX_BIN_DIR="$scratch/bin" WOLFMUX_DATA="$scratch/${ISO_DATA:-data}"
export WOLFMUX_TMUX_SOCKET="${ISO_SOCKET:-wolfmux-research}"
export PATH="$scratch/bin:$PATH"
if [ -n "${ISO_AS:-}" ]; then export TEAM_ROLE="$ISO_AS" BEADS_ACTOR="$ISO_AS"; fi
# ISO_ENV="NAME=value NAME2=value2": extra settings for this one command (a policy under test).
for pair in ${ISO_ENV:-}; do export "${pair?}"; done
cd "$scratch/proj" || exit 1
exec "$@"
