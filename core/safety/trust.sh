# shellcheck shell=bash
# core/safety/trust.sh: the ownership checks (design 21, section 5): can
# only root change a folder, a tree, or the folders above a path? Sourced
# through core/lib.sh.
#
# The installer also loads this file on its own, with the release check
# (core/safety/release.sh), so it can check its own release folder before
# it loads any other code from it. Like the release check, it needs nothing
# else from the core, and loading it changes nothing.

# lab_dir_trusted DIR: is the folder DIR itself owned by root and not
# writable by group or others, unless it is sticky, like /tmp? Returns 1
# when it is not, or cannot be read. It looks at DIR only, not inside it.
lab_dir_trusted() {
  local st uid mode
  st="$(stat -L -c '%u %a' -- "$1" 2> /dev/null)" || return 1
  read -r uid mode <<< "$st"
  [[ "$uid" == 0 ]] || return 1
  (( (8#$mode & 8#022) == 0 || (8#$mode & 8#1000) != 0 ))
}

# lab_tree_trusted PATH...: can only root change each PATH? Root runs the
# code, configuration and manifest under them, the revert timer's rollback
# included, so an account that could write there could run its own code as
# root (design 21, section 5). Each existing PATH, and everything in it,
# must be owned by root and not writable by group or others (a symbolic
# link need only be owned by root). Every folder above it must be owned by
# root and not writable by group or others, unless it is sticky, like
# /tmp. A PATH not made yet is checked from its nearest folder. Prints the
# first path that fails and returns 1; returns 0 if none does.
lab_tree_trusted() {
  local p d bad
  for p in "$@"; do
    [[ -n "$p" ]] || continue
    d="$(readlink -m -- "$p")" || { printf '%s\n' "$p"; return 1; }
    if [[ -e "$d" ]]; then
      bad="$(find "$d" \( ! -user 0 -o \( ! -type l -perm /022 \) \) -print -quit 2> /dev/null)" \
        || { printf '%s\n' "$d"; return 1; }
      if [[ -n "$bad" ]]; then printf '%s\n' "$bad"; return 1; fi
    fi
    while [[ "$d" != / ]]; do
      d="$(dirname -- "$d")"
      [[ -e "$d" ]] || continue
      lab_dir_trusted "$d" || { printf '%s\n' "$d"; return 1; }
    done
  done
  return 0
}

# lab_path_trusted PATH...: can only root change each PATH's folder chain?
# The installer uses it before it writes anything: each PATH that exists,
# and every folder above it, must be owned by root and not writable by
# group or others, unless it is sticky, like /tmp. Unlike lab_tree_trusted
# it looks at the folders themselves, not at what is inside them, so a
# crowded folder such as /usr/bin is checked in one step. A PATH not made
# yet is checked from its nearest folder. Prints the first path that fails
# and returns 1; returns 0 if none does.
lab_path_trusted() {
  local p d
  for p in "$@"; do
    [[ -n "$p" ]] || continue
    d="$(readlink -m -- "$p")" || { printf '%s\n' "$p"; return 1; }
    while :; do
      if [[ -e "$d" ]] && ! lab_dir_trusted "$d"; then
        printf '%s\n' "$d"; return 1
      fi
      [[ "$d" != / ]] || break
      d="$(dirname -- "$d")"
    done
  done
  return 0
}
