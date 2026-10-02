#!/usr/bin/env bash
# split.sh: print one platform's manual from the single source.
#
# Usage: tools/manual/split.sh linux|windows [source]
#   source defaults to docs/manual/labyrinth.md.
#   Exit 0: printed. Exit 1: the source is malformed. Exit 2: usage error.
#
# Text between a line "<!-- linux -->" (or "<!-- windows -->") and a line
# "<!-- end -->" is kept for that platform only; the marker lines are dropped.
# The words @CMD@, @ROOT@, @ADMIN@ and @MANUAL@ are replaced for the platform.
# A comment block, from a line "<!--" to a line "-->", is dropped.
set -Eeuo pipefail

usage() { echo "usage: $0 linux|windows [source]" >&2; exit 2; }

(( $# >= 1 && $# <= 2 )) || usage
platform="$1"
src="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/docs/manual/labyrinth.md}"
[[ -f "$src" ]] || { echo "split.sh: $src not found" >&2; exit 2; }

case "$platform" in
  linux)
    cmd='sudo ./labyrinth.sh'; root='/opt/labyrinth'
    admin='root'; manual='for Linux' ;;
  windows)
    cmd='.\labyrinth.ps1'; root='C:\ProgramData\Labyrinth'
    admin='an Administrator'; manual='for Windows' ;;
  *) usage ;;
esac

# Values are passed through the environment, so awk does not treat their
# backslashes as escapes.
CMD="$cmd" ROOT="$root" ADMIN="$admin" MANUAL="$manual" \
awk -v want="$platform" -v src="$src" '
  function fail(msg) { printf "split.sh: %s:%d: %s\n", src, NR, msg > "/dev/stderr"; bad = 1; exit 1 }
  function swap(s, word, value,   i, out) {
    out = ""
    while ((i = index(s, word)) > 0) {
      out = out substr(s, 1, i - 1) value
      s = substr(s, i + length(word))
    }
    return out s
  }
  {
    sub(/\r$/, "")
    # A comment block, "<!--" to "-->" on lines of their own, is for authors.
    if (note) { if ($0 == "-->") note = 0; next }
    if ($0 == "<!--") { note = 1; next }
    if ($0 ~ /^<!-- (linux|windows) -->$/) {
      if (block != "") fail("a " block " block is not closed before this one")
      block = $0; sub(/^<!-- /, "", block); sub(/ -->$/, "", block)
      opened = NR; next
    }
    if ($0 == "<!-- end -->") {
      if (block == "") fail("end marker without a block")
      block = ""; next
    }
    if ($0 ~ /^<!-- *(linux|windows|end) *-->/ || $0 ~ /^<!-- *(Linux|Windows|End|LINUX|WINDOWS|END) *-->/) {
      fail("marker must be exactly <!-- linux -->, <!-- windows --> or <!-- end -->")
    }
    if (block != "" && block != want) next
    line = $0
    line = swap(line, "@CMD@", ENVIRON["CMD"])
    line = swap(line, "@ROOT@", ENVIRON["ROOT"])
    line = swap(line, "@ADMIN@", ENVIRON["ADMIN"])
    line = swap(line, "@MANUAL@", ENVIRON["MANUAL"])
    print line
  }
  END {
    if (bad) exit 1
    if (block != "") { printf "split.sh: %s:%d: the %s block is not closed\n", src, opened, block > "/dev/stderr"; exit 1 }
  }
' "$src"
