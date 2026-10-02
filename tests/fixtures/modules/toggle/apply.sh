#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=/dev/null
source "$LAB_ROOT/core/lib.sh"
lab_backup_file "$LAB_ROOT/toggle.conf"
printf "setting=on\n" > "$LAB_ROOT/toggle.conf"
if [[ -e "$LAB_ROOT/FAIL_APPLY" ]]; then echo "toggle: apply forced to fail"; exit 40; fi
lab_log_info toggled "setting=on"
echo "toggle: setting=on"
