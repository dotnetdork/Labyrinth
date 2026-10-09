#!/usr/bin/env bats
# Unit tests for the Linux core library (core/): configuration readers,
# logger, manifest, safety helpers and probes. System tools the probes use
# (curl, dig) are replaced by stubs on PATH.

setup() {
  LAB_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export LAB_ROOT
  export LAB_CONFIG_DIR="$BATS_TEST_TMPDIR/etc"
  export LAB_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export LAB_LOG_DIR="$BATS_TEST_TMPDIR/logs"
  export LAB_BACKUP_DIR="$BATS_TEST_TMPDIR/backup"
  export LAB_RUN_ID='20261002T120000Z-abcd'
  export LAB_MODULE_ID='observe.unit'
  export LAB_DRY_RUN=0
  mkdir -p "$LAB_CONFIG_DIR" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/files"
  # shellcheck source=/dev/null
  source "$LAB_ROOT/core/lib.sh"
}

# stub NAME BODY: put a fake command on PATH
stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BATS_TEST_TMPDIR/bin/$1"
  chmod +x "$BATS_TEST_TMPDIR/bin/$1"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "config: comments, blank lines and whitespace are ignored" {
  printf '# c\n\n  root   breakglass   # reason\nDefault Account builtin\r\n' > "$LAB_CONFIG_DIR/protected-accounts"
  lab_protected_load
  [ "$(lab_protected_class root)" = breakglass ]
  [ "$(lab_protected_class 'Default Account')" = builtin ]
  run lab_protected_class nobody
  [ "$status" -eq 1 ]
}

@test "config: a protected set that is missing, empty or malformed" {
  run lab_protected_load
  [ "$status" -eq 2 ]
  printf '# only a comment\n' > "$LAB_CONFIG_DIR/protected-accounts"
  run lab_protected_load
  [ "$status" -eq 2 ]
  printf 'root wizard\n' > "$LAB_CONFIG_DIR/protected-accounts"
  run lab_protected_load
  [ "$status" -eq 1 ]
  [[ "$output" == *"protected-accounts:1: unknown class wizard"* ]]
  printf 'root breakglass\nroot scoring\n' > "$LAB_CONFIG_DIR/protected-accounts"
  run lab_protected_load
  [ "$status" -eq 1 ]
}

@test "config: addresses and CIDRs are checked" {
  for a in 192.0.2.1 198.51.100.0/28 0.0.0.0/0 2001:db8::1 2001:db8::/32 ::1; do
    lab_addr_valid "$a" || { echo "rejected $a"; return 1; }
  done
  for a in 256.1.1.1 1.2.3 1.2.3.4/33 example.test 2001:db8::/129 '1.2.3.4 ' ''; do
    ! lab_addr_valid "$a" || { echo "accepted $a"; return 1; }
  done
  printf '198.51.100.0/28\nnot-an-address\n' > "$LAB_CONFIG_DIR/scoring-allowlist"
  run lab_addrs_load scoring-allowlist
  [ "$status" -eq 1 ]
  [[ "$output" == *"scoring-allowlist:2"* ]]
}

@test "config: the service list" {
  printf 'web http www.example.test 80 Welcome\ndns1 dns ns1.example.test 53 www.example.test=192.0.2.20\n' > "$LAB_CONFIG_DIR/services"
  lab_services_load
  [ "${#LAB_SVC_NAME[@]}" -eq 2 ]
  [ "${LAB_SVC_EXPECT[1]}" = 'www.example.test=192.0.2.20' ]
  for bad in 'web gopher h 70 -' 'web http h 70000 -' 'web http h 80' 'd dns h 53 -' 'web http h 80 -\nweb http h 81 -'; do
    printf '%b\n' "$bad" >"$LAB_CONFIG_DIR/services"
    run lab_services_load
    [ "$status" -eq 1 ] || { echo "accepted: $bad"; return 1; }
  done
}

@test "config: event.conf defaults and range checks" {
  lab_event_load
  [ "${LAB_EVENT[REVERT_MINUTES]}" -eq 5 ]
  printf 'REVERT_MINUTES=7\nSIEM_ADDRESS=192.0.2.10\n' > "$LAB_CONFIG_DIR/event.conf"
  lab_event_load
  [ "${LAB_EVENT[REVERT_MINUTES]}" -eq 7 ]
  [ "${LAB_EVENT[SIEM_ADDRESS]}" = 192.0.2.10 ]
  printf 'REVERT_MINUTES=0\n' > "$LAB_CONFIG_DIR/event.conf"
  run lab_event_load
  [ "$status" -eq 1 ]
  printf 'revert_minutes=5\n' > "$LAB_CONFIG_DIR/event.conf"
  run lab_event_load
  [ "$status" -eq 1 ]
}

@test "config: hosts lookup is case-insensitive" {
  printf 'WEB01 ring1 linux-web ubuntu\nedge01 manual appliance appliance\n' > "$LAB_CONFIG_DIR/hosts"
  lab_host_lookup web01
  [ "$LAB_HOST_GROUP" = ring1 ]
  [ "$LAB_HOST_PROFILE" = linux-web ]
  run lab_host_lookup db01
  [ "$status" -eq 2 ]
  printf 'web01 ring1 linux-web beos\n' > "$LAB_CONFIG_DIR/hosts"
  run lab_host_lookup web01
  [ "$status" -eq 1 ]
}

@test "json: escaping round-trips through the manifest reader" {
  s=$'quote " back \\ tab \t nl \n bell \a end'
  line="{\"k\":$(lab_json_str "$s")}"
  [[ "$line" == *'\u0007'* ]]
  [ "$(lab_json_get "$line" k)" = "$s" ]
}

@test "log: lines carry the contract fields, and plan mode writes nothing" {
  LAB_ENTRY=apply lab_log_info rule_added 'allowed "tcp/443"'
  line="$(cat "$LAB_LOG_DIR"/run/*.jsonl)"
  [[ "$line" =~ ^\{\"ts\":\"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\",\"host\":\".+\",\"run\":\"20261002T120000Z-abcd\",\"module\":\"observe.unit\",\"entry\":\"apply\",\"level\":\"info\",\"event\":\"rule_added\",\"msg\":\"allowed\ \\\"tcp/443\\\"\"\}$ ]]
  rm -r "$LAB_LOG_DIR"
  LAB_DRY_RUN=1 lab_log_info x 'not written'
  [ ! -e "$LAB_LOG_DIR" ]
  run lab_log_to nosuch info x y
  [ "$status" -eq 1 ]
}

@test "manifest: refused in plan mode" {
  LAB_DRY_RUN=1 run lab_manifest_record file /etc/x
  [ "$status" -eq 1 ]
  [ ! -e "$LAB_STATE_DIR" ]
}

@test "manifest: backup, change and restore, newest first" {
  f="$BATS_TEST_TMPDIR/files/a.conf"
  printf 'one\n' > "$f"
  lab_backup_file "$f"
  printf 'two\n' > "$f"
  lab_backup_file "$f"
  printf 'three\n' > "$f"
  new="$BATS_TEST_TMPDIR/files/new.conf"
  lab_backup_file "$new"
  printf 'created\n' > "$new"
  [ "$(wc -l < "$(lab_manifest_file)")" -eq 3 ]
  lab_restore_files
  [ "$(cat "$f")" = one ]
  [ ! -e "$new" ]
  ls "$LAB_BACKUP_DIR/$LAB_RUN_ID/observe.unit/" | grep -q 'rolled-back-3-new.conf'
  lab_restore_files
  [ "$(cat "$f")" = one ]
}

@test "manifest: only the module's own entries are restored" {
  f="$BATS_TEST_TMPDIR/files/b.conf"
  printf 'orig\n' > "$f"
  LAB_MODULE_ID=observe.other lab_backup_file "$f"
  printf 'changed\n' > "$f"
  lab_restore_files
  [ "$(cat "$f")" = changed ]
}

@test "manifest: relative paths, directories and symlinks are refused" {
  run lab_backup_file relative.conf
  [ "$status" -eq 1 ]
  run lab_backup_file "$BATS_TEST_TMPDIR/files"
  [ "$status" -eq 1 ]
  if ln -s "$BATS_TEST_TMPDIR/files/x" "$BATS_TEST_TMPDIR/files/link" 2> /dev/null && [ -L "$BATS_TEST_TMPDIR/files/link" ]; then
    run lab_backup_file "$BATS_TEST_TMPDIR/files/link"
    [ "$status" -eq 1 ]
  fi
}

@test "manifest: applied modules, minus the ones rolled back" {
  LAB_MODULE_ID=observe.a lab_manifest_record apply_start
  LAB_MODULE_ID=observe.b lab_manifest_record apply_start
  LAB_MODULE_ID=observe.c lab_manifest_record apply_start
  LAB_MODULE_ID=observe.b lab_manifest_record rolled_back
  [ "$(lab_manifest_applied "$LAB_RUN_ID" | tr '\n' ' ')" = 'observe.a observe.c ' ]
}

@test "safety: break-glass must be a breakglass account and is remembered" {
  printf 'root breakglass\nscorer scoring\n' > "$LAB_CONFIG_DIR/protected-accounts"
  lab_protected_load
  run lab_breakglass_record scorer
  [ "$status" -eq 1 ]
  run lab_breakglass_recorded
  [ "$status" -ne 0 ]
  lab_breakglass_record root
  [ "$(lab_breakglass_recorded)" = root ]
  printf 'root scoring\n' > "$LAB_CONFIG_DIR/protected-accounts"
  lab_protected_load
  run lab_breakglass_recorded
  [ "$status" -ne 0 ]
}

@test "safety: generated passwords" {
  a="$(lab_random_password)"
  b="$(lab_random_password 32)"
  [ "${#a}" -eq 20 ]
  [ "${#b}" -eq 32 ]
  [ "$a" != "$(lab_random_password)" ]
  [[ "$a" =~ ^[A-HJ-NP-Za-km-z2-9]+$ ]]
  [[ "$a" =~ [[:upper:]] && "$a" =~ [[:lower:]] && "$a" =~ [[:digit:]] ]]
  run lab_random_password 8
  [ "$status" -eq 1 ]
}

@test "safety: every character of the alphabet can appear in a password" {
  local all='' c i
  # 5120 characters: the chance that one of 57 never appears is about 1e-37.
  for i in $(seq 1 40); do all+="$(lab_random_password 128)"; done
  for ((i = 0; i < ${#LAB_PW_ALPHABET}; i++)); do
    c="${LAB_PW_ALPHABET:i:1}"
    [[ "$all" == *"$c"* ]] || { printf 'never generated: %s\n' "$c"; return 1; }
  done
}

@test "safety: the run lock" {
  lab_lock_acquire
  [ "$(cat "$LAB_STATE_DIR/lock/pid")" = "$$" ]
  run lab_lock_acquire
  [ "$status" -eq 1 ]
  lab_lock_release
  [ ! -e "$LAB_STATE_DIR/lock" ]
}

@test "safety: only what root alone can change is trusted to run as root" {
  [ "$(id -u)" -ne 0 ] || skip "as root, the test folder is root's too"
  sh="$(readlink -f "$(command -v sh)")"
  # Root's own files, an empty path and a path not made yet under /.
  lab_tree_trusted "$sh" '' /lab-not-made/etc
  d="$(readlink -m "$BATS_TEST_TMPDIR/files")"
  run lab_tree_trusted "$sh" "$d"
  [ "$status" -eq 1 ]
  [ "$output" = "$d" ]
  # A path not made yet is checked from its nearest folder.
  run lab_tree_trusted "$d/new/etc"
  [ "$status" -eq 1 ]
  [ "$output" = "$d" ]
}

@test "safety: a console session is told apart from a remote login" {
  stub loginctl '
case "$1" in
  list-sessions) printf "  4 0 root      \n  7 1000 ops seat0 tty2\n  9 1000 ops      \n" ;;
  show-session)
    case "$2" in
      4) printf "Remote=yes\nSeat=\nTTY=pts/0\n" ;;
      7) printf "Remote=no\nSeat=seat0\nTTY=tty2\n" ;;
      9) printf "Remote=yes\nSeat=\nTTY=pts/1\n" ;;
    esac ;;
esac'
  run lab_console_session ops
  [ "$status" -eq 0 ]
  [ "$output" = 7 ]
  run lab_console_session root
  [ "$status" -eq 1 ]
  run lab_console_session nobody
  [ "$status" -eq 1 ]
}

@test "safety: without loginctl, who tells a console session apart" {
  stub loginctl 'exit 1'
  stub who 'printf "ops      pts/0        2026-10-08 10:00 (198.51.100.7)\nroot     tty1         2026-10-08 09:00\n"'
  run lab_console_session root
  [ "$status" -eq 0 ]
  [ "$output" = tty1 ]
  run lab_console_session ops
  [ "$status" -eq 1 ]
}

@test "timer: arm and cancel call systemd with a fresh unit each time" {
  [ -d /run/systemd/system ] || skip 'no systemd on this machine'
  stub systemd-run 'printf "%s\n" "$*" >> "$LAB_STATE_DIR/calls"'
  # A stopped timer is no longer active.
  stub systemctl 'printf "systemctl %s\n" "$*" >> "$LAB_STATE_DIR/calls"; [[ "$1" != is-active ]]'
  mkdir -p "$LAB_STATE_DIR"
  lab_timer_arm 300 "$LAB_RUN_ID" /bin/bash /x/labyrinth.sh rollback "$LAB_RUN_ID"
  lab_timer_armed "$LAB_RUN_ID"
  lab_timer_arm 300 "$LAB_RUN_ID" /bin/bash /x/labyrinth.sh rollback "$LAB_RUN_ID"
  lab_timer_cancel "$LAB_RUN_ID"
  run lab_timer_armed "$LAB_RUN_ID"
  [ "$status" -ne 0 ]
  calls="$(cat "$LAB_STATE_DIR/calls")"
  [[ "$calls" == *"--unit=lab-revert-$LAB_RUN_ID-1 --on-active=300s"*"/bin/bash /x/labyrinth.sh rollback"* ]]
  [[ "$calls" == *"systemctl stop lab-revert-$LAB_RUN_ID-1.timer"* ]]
  [[ "$calls" == *"--unit=lab-revert-$LAB_RUN_ID-2"* ]]
  [[ "$calls" == *"systemctl stop lab-revert-$LAB_RUN_ID-2.timer"* ]]
}

@test "timer: a failed re-arm leaves the earlier timer armed" {
  [ -d /run/systemd/system ] || skip 'no systemd on this machine'
  # The second unit, lab-revert-<run>-2, cannot be started.
  stub systemd-run 'printf "%s\n" "$*" >> "$LAB_STATE_DIR/calls"; [[ "$*" != *"$LAB_RUN_ID-2 "* ]]'
  stub systemctl 'printf "systemctl %s\n" "$*" >> "$LAB_STATE_DIR/calls"'
  mkdir -p "$LAB_STATE_DIR"
  lab_timer_arm 300 "$LAB_RUN_ID" /bin/bash /x/labyrinth.sh rollback "$LAB_RUN_ID"
  run lab_timer_arm 300 "$LAB_RUN_ID" /bin/bash /x/labyrinth.sh rollback "$LAB_RUN_ID"
  [ "$status" -eq 1 ]
  [ "$(cat "$LAB_STATE_DIR/runs/$LAB_RUN_ID/timer")" = "lab-revert-$LAB_RUN_ID-1" ]
  run grep -q '^systemctl stop' "$LAB_STATE_DIR/calls"
  [ "$status" -ne 0 ]
}

@test "timer: arming records when the timer fires, and cancelling removes it" {
  [ -d /run/systemd/system ] || skip 'no systemd on this machine'
  stub systemd-run ':'
  stub systemctl '[[ "$1" != is-active ]]'
  mkdir -p "$LAB_STATE_DIR"
  before="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  lab_timer_arm 300 "$LAB_RUN_ID" /bin/true
  due="$(lab_timer_due "$LAB_RUN_ID")"
  [[ "$due" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  [[ "$due" > "$before" ]]
  lab_timer_cancel "$LAB_RUN_ID"
  [ ! -e "$LAB_STATE_DIR/runs/$LAB_RUN_ID/timer-due" ]
  run lab_timer_due "$LAB_RUN_ID"
  [ "$status" -eq 1 ]
}

@test "timer: a timer still active after being stopped is not cancelled" {
  [ -d /run/systemd/system ] || skip 'no systemd on this machine'
  stub systemd-run ':'
  stub systemctl ':'
  mkdir -p "$LAB_STATE_DIR"
  lab_timer_arm 300 "$LAB_RUN_ID" /bin/true
  run lab_timer_cancel "$LAB_RUN_ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"still active"* ]]
  lab_timer_armed "$LAB_RUN_ID"
  lab_timer_due "$LAB_RUN_ID"
}

@test "timer: a missing or malformed timer-due means the time is unknown" {
  mkdir -p "$LAB_STATE_DIR/runs/$LAB_RUN_ID"
  run lab_timer_due "$LAB_RUN_ID"
  [ "$status" -eq 1 ]
  printf 'soon\n' > "$LAB_STATE_DIR/runs/$LAB_RUN_ID/timer-due"
  run lab_timer_due "$LAB_RUN_ID"
  [ "$status" -eq 1 ]
}

@test "probe: http through curl checks status and content" {
  stub curl 'printf "<h1>Welcome</h1>\n200"'
  [[ "$(lab_probe_service http www.example.test 80 Welcome 5)" == 'pass status 200' ]]
  [[ "$(lab_probe_service http www.example.test 80 Missing 5)" == fail* ]]
  stub curl 'printf "oops\n503"'
  [[ "$(lab_probe_service https www.example.test 443 - 5)" == 'fail status 503' ]]
  stub curl 'echo "curl: (7) Failed to connect" >&2; exit 7'
  [[ "$(lab_probe_service http www.example.test 80 - 5)" == fail* ]]
}

@test "probe: dns through dig matches the expected answer" {
  stub dig 'printf "www.example.test.\n192.0.2.20\n"'
  [[ "$(lab_probe_service dns ns1.example.test 53 www.example.test=192.0.2.20 5)" == pass* ]]
  [[ "$(lab_probe_service dns ns1.example.test 53 www.example.test=192.0.2.99 5)" == fail* ]]
}

@test "probe: a closed port fails" {
  command -v timeout > /dev/null || skip 'no timeout command'
  [[ "$(lab_probe_service tcp 127.0.0.1 1 - 2)" == 'fail no connection' ]]
  [[ "$(lab_probe_service smtp 127.0.0.1 1 - 2)" == 'fail no banner' ]]
}

@test "probe: regressions are pass before and fail after only" {
  before=$'web pass status 200\nmail pass banner\ndns unknown no tool\nftp fail no banner'
  after=$'web fail status 503\nmail pass banner\ndns fail x\nftp fail no banner'
  [ "$(lab_probe_regressions "$before" "$after")" = web ]
}

@test "probe: lab_probe_all reports every listed service" {
  printf 'a tcp 127.0.0.1 1 -\nb tcp 127.0.0.1 1 -\n' > "$LAB_CONFIG_DIR/services"
  lab_event_load
  out="$(lab_probe_all)"
  [ "$(wc -l <<< "$out")" -eq 2 ]
  [[ "$out" == "a "* ]]
  rm "$LAB_CONFIG_DIR/services"
  run lab_probe_all
  [ "$status" -eq 2 ]
}
