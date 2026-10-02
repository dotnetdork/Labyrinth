#!/usr/bin/env bash
set -Eeuo pipefail
for v in LAB_ROOT LAB_CONFIG_DIR LAB_STATE_DIR LAB_LOG_DIR LAB_BACKUP_DIR LAB_RUN_ID LAB_MODULE_ID LAB_DRY_RUN; do
  printf "%s=%s\n" "$v" "${!v}"
done
exit 0
