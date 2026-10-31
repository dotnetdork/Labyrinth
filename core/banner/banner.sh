# shellcheck shell=bash
# core/banner/banner.sh: the installer's screen (docs/Conventions.md
# section 3.3): the maze with the version under it, the warning box with the
# release hash to compare by eye with the offline record, and the tree of
# changes. Needs core/safety/release.sh (lab_release_groups) and nothing else
# from the core; printing it changes nothing.
#
# The maze is in maze.txt, drawn with box lines, and in maze-ascii.txt, drawn
# with + - and |, for a terminal that cannot show the box lines. No colour:
# many consoles and logs would show the escape codes instead.

LAB_BANNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LAB_BANNER_URL='https://dotnetdork.github.io/Labyrinth/'
LAB_BANNER_INNER=49   # columns inside the warning box's inner wall

# lab_banner_unicode: can this terminal show the box lines? Yes when the
# locale's character set is UTF-8.
lab_banner_unicode() {
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) return 0 ;;
    *) return 1 ;;
  esac
}

# lab_banner_center TEXT: TEXT centred in the box's inner width.
lab_banner_center() {
  local left=$(( (LAB_BANNER_INNER - ${#1}) / 2 ))
  printf '%*s%s%*s' "$left" '' "$1" $(( LAB_BANNER_INNER - ${#1} - left )) ''
}

# lab_banner_print UNICODE VERSION SHA: the maze, the version line and the
# warning box. UNICODE is 1 for box lines, 0 for plain ASCII. SHA empty
# means the copy has no release.sha256.
lab_banner_print() {
  local uni="$1" ver="$2" sha="$3" line one two
  local tl tr bl br h v itl itr ibl ibr ih
  if (( uni )); then
    tl='╔' tr='╗' bl='╚' br='╝' h='═' v='║' itl='╓' itr='╖' ibl='╙' ibr='╜' ih='─'
    cat -- "$LAB_BANNER_DIR/maze.txt"
  else
    tl='+' tr='+' bl='+' br='+' h='-' v='|' itl='+' itr='+' ibl='+' ibr='+' ih='-'
    cat -- "$LAB_BANNER_DIR/maze-ascii.txt"
  fi | tr -d '\r'
  printf 'VERSION %s (%s)\n\n' "$ver" "$LAB_BANNER_URL"
  local outer inner
  printf -v outer '%*s' $(( LAB_BANNER_INNER + 4 )) ''
  printf -v inner '%*s' "$LAB_BANNER_INNER" ''
  printf '%s%s%s\n' "$tl" "${outer// /$h}" "$tr"
  printf '%s %s%s%s %s\n' "$v" "$itl" "${inner// /$ih}" "$itr" "$v"
  {
    printf '\nWARNING\n\n'
    if [[ -n "$sha" ]]; then
      { read -r one; read -r two; } < <(lab_release_groups "$sha")
      printf "If this SHA-256 doesn't match your\noffline record, it was tampered with.\n\n%s\n%s\n\n" "$one" "$two"
    else
      printf 'This copy has no release.sha256,\nso nothing proves that it is genuine.\n\n'
    fi
  } | while IFS= read -r line; do
    printf '%s %s%s%s %s\n' "$v" "$v" "$(lab_banner_center "$line")" "$v" "$v"
  done
  printf '%s %s%s%s %s\n' "$v" "$ibl" "${inner// /$ih}" "$ibr" "$v"
  printf '%s%s%s\n' "$bl" "${outer// /$h}" "$br"
}

# lab_banner_tree UNICODE ROW...: the tree of changes to this host. Each ROW
# is 'Label|text'; ' -> ' in the text becomes an arrow on a UTF-8 terminal.
lab_banner_tree() {
  local uni="$1" i=0 n mid last row label text
  shift
  n=$#
  if (( uni )); then mid=' ├── ' last=' └── '; else mid=' |-- ' last=' `-- '; fi
  printf 'CHANGES TO THIS HOST\n'
  for row in "$@"; do
    i=$(( i + 1 ))
    label="${row%%|*}" text="${row#*|}"
    if (( uni )); then text="${text// -> / → }"; fi
    if (( i == n )); then printf '%s%-10s%s\n' "$last" "$label" "$text"
    else printf '%s%-10s%s\n' "$mid" "$label" "$text"; fi
  done
}
