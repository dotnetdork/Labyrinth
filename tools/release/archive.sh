#!/usr/bin/env bash
# archive.sh: build the release archives for a tag (design 21, section 5.2).
#
# Usage: tools/release/archive.sh TAG [OUTDIR]   (OUTDIR defaults to build/release)
#
# Stages the files the release list covers (design 21, section 5.1) and the
# built manual in a folder named labyrinth-TAG, writes release.sha256 into it
# with tools/release/manifest.sh, and writes labyrinth-TAG.tar.gz (Linux) and
# labyrinth-TAG.zip (Windows) into OUTDIR, each with labyrinth-TAG as its top
# folder. It then prints the SHA-256 of each archive, as sha256sum prints it,
# and the manifest's own line, 'Release: <sha256>'.
#
# The archives hold the same bytes every time they are built from the same
# commit: files are owned by root, sorted by name, dated with the tagged
# commit (or the epoch if TAG is not a tag here), and no one but the owner
# can write to them. Needs bash, GNU tar, gzip, zip and sha256sum, and
# tools/manual/build.sh (pandoc and Chrome) to build the manual; set
# LAB_ARCHIVE_MANUAL_BUILDER to another script that takes an output folder
# and writes labyrinth.1 and about_Labyrinth.help.txt there, to use a
# stand-in (the tests do).
set -Eeuo pipefail

usage() { echo "usage: $0 TAG [OUTDIR]" >&2; exit 2; }

(( $# >= 1 && $# <= 2 )) || usage
tag="$1"
[[ "$tag" =~ ^v?[0-9A-Za-z._-]+$ && "$tag" != *..* ]] || { echo "archive.sh: TAG '$tag' is not a plain tag name" >&2; exit 2; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd -P)"
builder="${LAB_ARCHIVE_MANUAL_BUILDER:-$repo/tools/manual/build.sh}"
outdir="${2:-$repo/build/release}"
mkdir -p "$outdir"
outdir="$(cd "$outdir" && pwd -P)"
name="labyrinth-$tag"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stage="$work/$name"
mkdir -p "$stage"

# The files and folders the release list covers; keep in step with
# LAB_RELEASE_FILES and LAB_RELEASE_DIRS in core/safety/release.sh.
for f in labyrinth.sh labyrinth.ps1 install.sh install.ps1 laby.cmd labyrinth.cmd; do
  if [[ -f "$repo/$f" ]]; then cp -- "$repo/$f" "$stage/$f"; fi
done
for d in core phases platform profiles vendor config; do
  if [[ -d "$repo/$d" ]]; then cp -R -- "$repo/$d" "$stage/$d"; fi
done

# The built manual: the man page and the help topic go in the manual folder.
mkdir -p "$work/manual-out" "$stage/manual"
bash "$builder" "$work/manual-out" > /dev/null
for f in labyrinth.1 about_Labyrinth.help.txt; do
  [[ -s "$work/manual-out/$f" ]] || { echo "archive.sh: the manual build wrote no $f" >&2; exit 1; }
  cp -- "$work/manual-out/$f" "$stage/manual/$f"
done

# Only the owner may write; everyone may read and enter folders.
chmod -R u+rwX,go+rX,go-w "$stage"

manifest_out="$(bash "$here/manifest.sh" "$stage")"
release_line="$(printf '%s\n' "$manifest_out" | grep '^Release: ')"

# Date everything with the tagged commit, so the same commit gives the same
# archives; without a tag here, use the epoch.
stamp=0
if ct="$(git -C "$repo" log -1 --format=%ct "refs/tags/$tag^{commit}" -- 2> /dev/null)" && [[ "$ct" =~ ^[0-9]+$ ]]; then
  stamp="$ct"
fi
find "$stage" -exec touch -h -d "@$stamp" {} +

(
  cd "$work"
  tar --owner=0 --group=0 --numeric-owner --sort=name --mtime="@$stamp" \
    -cf - "$name" | gzip -n -9 > "$outdir/$name.tar.gz"
  rm -f -- "$outdir/$name.zip"
  zip -X -r -q "$outdir/$name.zip" "$name"
)

(
  cd "$outdir"
  sha256sum "$name.tar.gz" "$name.zip"
)
printf '%s\n' "$release_line"
