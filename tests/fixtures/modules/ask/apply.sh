#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=/dev/null
source "$LAB_ROOT/core/lib.sh"
lab_manifest_record approved_items "$LAB_APPROVED"
: > "$LAB_ROOT/APPROVED_ITEMS"
for item in item-a item-b item-c; do
  rc=0
  lab_approved "$item" "$(printf '%s' "$item" | lab_item_fingerprint)" || rc=$?
  if [[ "$rc" == 0 ]]; then printf '%s\n' "$item" >> "$LAB_ROOT/APPROVED_ITEMS"; fi
done
