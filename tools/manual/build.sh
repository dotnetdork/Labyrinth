#!/usr/bin/env bash
# build.sh: build every manual from docs/manual/labyrinth.md.
#
# Usage: tools/manual/build.sh [output-folder]   (default: build/manual)
#
# Writes:
#   Labyrinth-Manual-Linux.pdf     Labyrinth-Manual-Windows.pdf
#   labyrinth.1                    (Linux man page: man ./labyrinth.1)
#   about_Labyrinth.help.txt       (Windows help topic: Get-Help about_Labyrinth)
#
# Needs pandoc 3 and a Chrome or Chromium browser (CHROME, default
# google-chrome). It runs in CI only: Labyrinth never installs anything,
# and contributors are not asked to install these tools.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${1:-build/manual}"
chrome="${CHROME:-google-chrome}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for platform in linux windows; do
  name="${platform^}"
  bash "$here/split.sh" "$platform" > "$work/$platform.md"
  # The PDF opens with a list of its sections, so a reader can find one fast.
  pandoc "$work/$platform.md" --from markdown --standalone --embed-resources \
    --toc --toc-depth=1 --metadata toc-title=Contents \
    --lua-filter "$here/links.lua" --css "$here/manual.css" \
    --metadata title="Labyrinth Operator Manual for $name" \
    --output "$work/$platform.html"
  "$chrome" --headless --disable-gpu --no-pdf-header-footer --log-level=3 \
    --print-to-pdf="$out/Labyrinth-Manual-$name.pdf" "file://$work/$platform.html"
  [[ -s "$out/Labyrinth-Manual-$name.pdf" ]] || { echo "build.sh: no PDF for $name" >&2; exit 1; }
done

pandoc "$work/linux.md" --from markdown --to man --standalone \
  --lua-filter "$here/links.lua" \
  --metadata title=LABYRINTH --metadata section=1 \
  --metadata header='Labyrinth Operator Manual' --metadata footer=Labyrinth \
  --output "$out/labyrinth.1"
# Older pandoc writes code in fonts C and V, which groff's terminal devices
# do not have; use the standard constant-width fonts instead.
sed -i 's/\\f\[C\]/\\f[CR]/g; s/\\f\[V\]/\\f[CR]/g; s/\\f\[VB\]/\\f[CB]/g; s/\\f\[VI\]/\\f[CI]/g; s/\\f\[VBI\]/\\f[CBI]/g' "$out/labyrinth.1"

{
  printf 'TOPIC\n    about_Labyrinth\n\nSHORT DESCRIPTION\n'
  printf '    How to run Labyrinth on Windows: commands, options, safety checks,\n'
  printf '    exit codes and what to do when something goes wrong.\n\nLONG DESCRIPTION\n'
  pandoc "$work/windows.md" --from markdown --to plain --columns=74 \
    --lua-filter "$here/links.lua" | sed 's/^/    /; s/[[:space:]]*$//'
} > "$out/about_Labyrinth.help.txt"

ls -l "$out"
