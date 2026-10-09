# teamctl.zsh — tab completion for teamctl (zsh).
#
# Sourced by the wolfmux block in your ~/.zshrc, or directly:
#   source <(teamctl completion zsh)
#
# It never runs compinit itself: switching the whole shell's completion system on
# is your decision. With no completion system loaded, compdef does not exist,
# nothing is registered, and sourcing it is silent.

_teamctl() {
  local -a lines matches
  local line comp desc out
  # The backend knows everything: commands, options, and the values it can name
  # (roles, teams, models, policy keys, layouts, approvals, branches). It filters
  # by the word under the cursor, so the shim only presents.
  out="$(command teamctl _complete -- "${words[@]:1:$((CURRENT-1))}" 2>/dev/null)" || out=""
  if [[ "$out" == "__files__" ]]; then
    _files -/ # --repo takes a directory
    return
  fi
  matches=()
  for line in ${(f)out}; do
    [[ -n "$line" ]] || continue
    if [[ "$line" == *$'\t'* ]]; then
      comp="${line%%$'\t'*}"
      desc="${line#*$'\t'}"
      matches+=("$comp:$desc")
    else
      matches+=("$line")
    fi
  done
  _describe -t teamctl-command command matches
}

# Register with the completion system only when one is loaded (compinit defines
# compdef). Before that, this file defines the completer and does nothing else.
if (( $+functions[compdef] )); then
  compdef _teamctl teamctl
fi
