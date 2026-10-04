# teamctl.bash — tab completion for teamctl (bash 3.2 and newer; macOS /bin/bash).
#
# Sourced by the wolfmux block in your ~/.zshrc, or directly:
#   source <(teamctl completion bash)
#
# All knowledge lives in the backend (teamctl _complete); this shim only feeds it
# COMP_WORDS / COMP_CWORD and hands the answer to COMPREPLY. On __files__ it falls
# back to the shell's own directory completion.

_teamctl_bash() {
  local out line comp rest
  COMPREPLY=()
  local -a words_after
  local i
  for ((i = 1; i <= COMP_CWORD; i++)); do
    words_after+=("${COMP_WORDS[i]}")
  done
  out="$(teamctl _complete -- "${words_after[@]}" 2>/dev/null)" || out=""
  if [ "$out" = "__files__" ]; then
    while IFS= read -r line; do
      COMPREPLY+=("$line")
    done <<EOF
$(compgen -d -- "${COMP_WORDS[COMP_CWORD]}")
EOF
    return 0
  fi
  while IFS=$'\t' read -r comp rest; do
    [ -n "$comp" ] || continue
    COMPREPLY+=("$comp")
  done <<EOF
$out
EOF
  return 0
}
complete -F _teamctl_bash teamctl
