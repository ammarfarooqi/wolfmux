# offload-wrap.sh <log>: SOURCED (`. offload-wrap.sh <log>`) by the short line lib/offload.sh puts
# in front of an agent's Bash command, in the agent's own shell (bash or zsh), so that the line
# the shell quotes in a syntax error message stays short (v1.26.0, ADR-0036). Plain sh syntax.
#
# It sends the shell's stdout and stderr to <log> (one file, so the order is the order written)
# and keeps the originals on fds 7 and 8. An EXIT trap puts them back and prints the result
# (lib/offload-show.sh); TERM and INT do the same, then exit 143/130. Nothing here runs the
# command; when it cannot set itself up (log not writable) it does nothing and the command runs
# as it would have.
__wm_src="${BASH_SOURCE:-$0}" # bash: the sourced file; zsh: $0 is the sourced file
__wm_show="${__wm_src%/*}/offload-show.sh"
__wm_fin() {
  trap - EXIT TERM INT
  exec 1>&7 2>&8 7>&- 8>&-
  /bin/bash "$__wm_show" "$__wm_log" "$1" || /bin/cat "$__wm_log"
}
__wm_log="$1"
if [ -r "$__wm_show" ] && exec 7>&1 8>&2 >"$__wm_log" 2>&1; then
  trap '__wm_rc=$?; __wm_fin $__wm_rc; exit $__wm_rc' EXIT
  trap '__wm_fin 143; exit 143' TERM
  trap '__wm_fin 130; exit 130' INT
fi
