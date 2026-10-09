#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=/dev/null
source "$LAB_ROOT/core/lib.sh"
lab_backup_file "$LAB_ROOT/keeper.conf"
printf "setting=on\n" > "$LAB_ROOT/keeper.conf"
if [[ -e "$LAB_ROOT/FAIL_APPLY" ]]; then echo "keeper: apply forced to fail"; exit 40; fi
lab_log_info keeper_on "setting=on"
echo "keeper: setting=on"
