#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=/dev/null
source "$LAB_ROOT/core/lib.sh"
lab_backup_file "$LAB_ROOT/dependent.conf"
printf "setting=on\n" > "$LAB_ROOT/dependent.conf"
if [[ -e "$LAB_ROOT/FAIL_APPLY" ]]; then echo "dependent: apply forced to fail"; exit 40; fi
lab_log_info toggled "setting=on"
echo "dependent: setting=on"
