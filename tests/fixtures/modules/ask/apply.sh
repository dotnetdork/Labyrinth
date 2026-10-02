#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=/dev/null
source "$LAB_ROOT/core/lib.sh"
lab_manifest_record approved_items "$LAB_APPROVED"
printf "%s\n" "$LAB_APPROVED" > "$LAB_ROOT/APPROVED_ITEMS"
