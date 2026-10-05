#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=/dev/null
source "$LAB_ROOT/core/lib.sh"
# rotate.pw stands in for a password store: it holds a hash of the password.
if ! lab_secret_can_show; then
  echo "problem: no terminal to show the new password on, so nothing changed"
  exit 20
fi
lab_backup_file "$LAB_ROOT/rotate.pw"
pw="$(lab_secret_new)"
printf '%s' "$pw" | sha256sum | cut -c1-64 > "$LAB_ROOT/rotate.pw"
lab_log_info rotated "new password for testuser"
rc=0
lab_secret_show testuser "$pw" || rc=$?
if (( rc != 0 )); then
  lab_restore_files
  echo "problem: the new password was not recorded, so the old one was put back"
  exit 40
fi
echo "did: new password for testuser, shown once"
