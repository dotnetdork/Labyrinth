#!/usr/bin/env bash
# Test fixture: the recording pass (design 00, section 4). In a preview
# (LAB_DRY_RUN=1) it writes nothing; in a run (0) it writes a marker under the
# state folder, noting the toggle.conf it saw, or fails when FAIL_RECORD exists.
# With CHECK_TEN present its preview exits 10, as a module that has work to do.
set -Eeuo pipefail
if [[ "$LAB_DRY_RUN" != 0 ]]; then
  if [[ -e "$LAB_ROOT/CHECK_TEN" ]]; then echo 'will do: write the marker'; exit 10; fi
  echo 'found: would write the marker'
  exit 0
fi
if [[ -e "$LAB_ROOT/FAIL_RECORD" ]]; then
  echo 'problem: the marker could not be written'
  exit 40
fi
mkdir -p "$LAB_STATE_DIR/recorder"
seen=none
if [[ -f "$LAB_ROOT/toggle.conf" ]]; then seen="$(cat "$LAB_ROOT/toggle.conf")"; fi
printf 'dry=%s\ntoggle=%s\n' "$LAB_DRY_RUN" "$seen" > "$LAB_STATE_DIR/recorder/marker"
echo 'found: wrote the marker'
exit 0
