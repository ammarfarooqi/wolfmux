# teamctl.bash — tab completion for teamctl (bash 3.2 and newer; macOS /bin/bash).
#
# Loaded with:   eval "$(teamctl completion bash)"     (in ~/.bashrc, for example)
# Not with `source <(teamctl completion bash)`: bash 3.2 cannot source a process substitution.
#
# All knowledge lives in the backend (teamctl _complete); this shim only feeds it
# COMP_WORDS / COMP_CWORD and hands the answer to COMPREPLY. On __files__ it falls
# back to the shell's own directory completion.
#
# Every candidate is quoted (printf %q) before bash inserts it: a branch name may hold
# $( ) ; & and the like, and a word inserted as it is would run on Enter.

_teamctl_bash() {
  local out line comp rest
  COMPREPLY=()
  local -a words_after
  local i
  for ((i = 1; i <= COMP_CWORD; i++)); do
    words_after+=("${COMP_WORDS[i]}")
  done
  out="$(command teamctl _complete -- "${words_after[@]}" 2>/dev/null)" || out=""
  if [ "$out" = "__files__" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      COMPREPLY+=("$(printf '%q' "$line")")
    done <<EOF
$(compgen -d -- "${COMP_WORDS[COMP_CWORD]}")
EOF
    return 0
  fi
  while IFS=$'\t' read -r comp rest; do
    [ -n "$comp" ] || continue
    COMPREPLY+=("$(printf '%q' "$comp")")
  done <<EOF
$out
EOF
  return 0
}
complete -F _teamctl_bash teamctl
