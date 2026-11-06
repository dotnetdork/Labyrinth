# shellcheck shell=bash
# Labyrinth tab completion for bash.
#
# install.sh copies this file to bash-completion's folder as 'laby' and as
# 'labyrinth' (docs/Conventions.md section 3.3, The command). It holds no
# logic: it hands the words typed after the command to the hidden entry
# 'laby --complete WORD...', which only reads and prints one candidate per
# line (docs/Conventions.md section 3.1), and offers what comes back. Tab
# never asks for a password: run as a normal user, the entry gives no run IDs.

_laby_complete() {
  local cmd
  COMPREPLY=()
  # The command is found on the PATH by its name, never run from a path
  # typed on the line.
  cmd="$(type -P -- "${COMP_WORDS[0]##*/}" 2> /dev/null)" || return 0
  [[ -n "$cmd" ]] || return 0
  # The candidates are in a useful order (run IDs newest first): keep it.
  compopt -o nosort 2> /dev/null || true
  mapfile -t COMPREPLY < <("$cmd" --complete "${COMP_WORDS[@]:1:COMP_CWORD}" 2> /dev/null < /dev/null)
}

# Each installed file completes its own name; any other name (the file read
# by hand) completes both.
case "${BASH_SOURCE[0]##*/}" in
  laby) complete -F _laby_complete laby ;;
  labyrinth) complete -F _laby_complete labyrinth ;;
  *) complete -F _laby_complete laby labyrinth ;;
esac
