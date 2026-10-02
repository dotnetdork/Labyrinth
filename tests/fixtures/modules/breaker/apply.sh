#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=/dev/null
source "$LAB_ROOT/core/lib.sh"
lab_backup_file "$LAB_ROOT/probe-state"
printf "web.test fail\n" > "$LAB_ROOT/probe-state"
