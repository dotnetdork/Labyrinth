#!/usr/bin/env bats
# Unit tests for the approval helpers (core/approval/approval.sh,
# docs/Conventions.md section 3.1, "Approval items").

setup() {
  LAB_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export LAB_ROOT
  export LAB_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export LAB_LOG_DIR="$BATS_TEST_TMPDIR/logs"
  export LAB_BACKUP_DIR="$BATS_TEST_TMPDIR/backup"
  export LAB_CONFIG_DIR="$BATS_TEST_TMPDIR/etc"
  export LAB_RUN_ID='20261005T120000Z-abcd'
  export LAB_MODULE_ID='lockout.persistence'
  export LAB_DRY_RUN=0
  # shellcheck source=/dev/null
  source "$LAB_ROOT/core/lib.sh"
}

@test "fingerprint: the first 12 hex digits of the SHA-256 of the state" {
  [ "$(printf 'item-a' | lab_item_fingerprint)" = 2a2c17aaaf66 ]
  [ "$(printf '' | lab_item_fingerprint)" = e3b0c44298fc ]
}

@test "item: one tab-separated line; a malformed field is refused" {
  [ "$(lab_item cron-1 cron 2a2c17aaaf66 $'runs\tfrom /tmp')" = $'item\tcron-1\tcron\t2a2c17aaaf66\truns from /tmp' ]
  local bad
  for bad in 'Cron-1 cron 2a2c17aaaf66' 'cron_1 cron 2a2c17aaaf66' 'cron-1 Cron 2a2c17aaaf66' 'cron-1 cron 2A2C17AAAF66' 'cron-1 cron 2a2c17'; do
    # shellcheck disable=SC2086 # the fields are split on purpose
    run lab_item $bad reason
    [ "$status" -eq 40 ] || { echo "accepted: $bad"; return 1; }
    [ -z "${output##*malformed item*}" ]
  done
}

@test "approved: only an item a person approved, at the fingerprint of the plan" {
  LAB_APPROVED="cron-1@2a2c17aaaf66 unit-2@f09f429ea5f1"
  lab_approved cron-1 2a2c17aaaf66
  run lab_approved cron-3 2a2c17aaaf66
  [ "$status" -eq 1 ]
  run lab_approved cron 2a2c17aaaf66
  [ "$status" -eq 1 ]
  LAB_APPROVED=''
  run lab_approved cron-1 2a2c17aaaf66
  [ "$status" -eq 1 ]
  [ ! -e "$(lab_manifest_file)" ]
}

@test "approved: an item changed since the plan is refused and recorded" {
  LAB_APPROVED="cron-1@2a2c17aaaf66"
  run lab_approved cron-1 5821d4d89f00
  [ "$status" -eq 2 ]
  [[ "$output" == *"cron-1 changed since the plan, so it was left alone"* ]]
  local m
  m="$(cat "$(lab_manifest_file)")"
  [[ "$m" == *'"action":"approval_refused","target":"cron-1"'* ]]
  [[ "$m" == *'"prev":"2a2c17aaaf66","note":"changed since the plan; now 5821d4d89f00"'* ]]
}
