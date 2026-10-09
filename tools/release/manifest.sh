#!/usr/bin/env bash
# manifest.sh: write release.sha256, the release list, into a copy of
# Labyrinth and print its SHA-256 (design 07, section 5).
#
# Usage: tools/release/manifest.sh [folder]   (default: this copy)
#
# Run it on the copy that will be deployed, after it is unpacked and
# before it is copied to the hosts, and keep the SHA-256 it prints in the
# team's offline record. Copy the folder to the hosts byte for byte:
# changing line ends, as a git checkout on Windows may, changes the hashes.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${1:-$here/../..}"
root="$(cd "$root" && pwd -P)"
# shellcheck source=core/safety/release.sh
source "$here/../../core/safety/release.sh"
sum="$(lab_release_write "$root")"
lab_release_check "$root" || { echo "manifest.sh: the new list does not check: $LAB_RELEASE_PROBLEM" >&2; exit 1; }
printf 'Wrote %s/release.sha256\n' "$root"
printf 'Release: %s\n' "$sum"
