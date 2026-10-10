#!/usr/bin/env bats
# Real-system tests for the Linux core: real systemd timers, run as root.
# They run only where LAB_REALSYSTEM=1, which CI sets on its disposable
# runners; never on a developer's own machine (docs/Conventions.md section 9).

setup() {
  [ "${LAB_REALSYSTEM:-}" = 1 ] || skip 'real-system tests run only on CI runners or lab VMs'
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  W="$BATS_TEST_TMPDIR"
}

# Files made by root would stop bats from removing its test directory.
teardown() {
  if [ "${LAB_REALSYSTEM:-}" = 1 ]; then
    sudo -n rm -rf -- "$W/root" "$W/state" "$W/lab"
    if [ -s "$W/base" ]; then sudo -n rm -rf -- "$(cat "$W/base")"; fi
  fi
}

@test "realsystem: an armed revert timer fires, and a cancelled one does not" {
  sudo -n env LAB_ROOT="$REPO" LAB_STATE_DIR="$W/state" W="$W" bash -c '
    set -Eeuo pipefail
    source "$LAB_ROOT/core/lib.sh"
    lab_timer_arm 2 20261002T000000Z-aaaa /usr/bin/touch "$W/fired-a"
    lab_timer_arm 2 20261002T000000Z-bbbb /usr/bin/touch "$W/fired-b"
    lab_timer_cancel 20261002T000000Z-bbbb'
  sleep 8
  [ -e "$W/fired-a" ]
  [ ! -e "$W/fired-b" ]
  sudo -n env LAB_ROOT="$REPO" LAB_STATE_DIR="$W/state" bash -c '
    set -Eeuo pipefail
    source "$LAB_ROOT/core/lib.sh"
    lab_timer_cancel 20261002T000000Z-aaaa'
  run compgen -G '/etc/systemd/system/lab-revert-20261002T000000Z-*'
  [ "$status" -ne 0 ]
}

@test "realsystem: the revert timer is enabled and persistent, so it outlives a restart" {
  sudo -n env LAB_ROOT="$REPO" LAB_STATE_DIR="$W/state" W="$W" bash -c '
    set -Eeuo pipefail
    source "$LAB_ROOT/core/lib.sh"
    u=lab-revert-20261002T000000Z-cccc-1
    lab_timer_arm 300 20261002T000000Z-cccc /usr/bin/touch "$W/fired-c"
    systemctl is-enabled --quiet "$u.timer"
    systemctl is-active --quiet "$u.timer"
    [ "$(systemctl show -p Persistent --value "$u.timer")" = yes ]
    lab_timer_cancel 20261002T000000Z-cccc
    [ ! -e "/etc/systemd/system/$u.timer" ]
    [ ! -e "/etc/systemd/system/$u.service" ]
    ! systemctl is-enabled --quiet "$u.timer" 2> /dev/null'
  [ ! -e "$W/fired-c" ]
}

@test "realsystem: an apply that is not kept is rolled back by the timer" {
  # Labyrinth runs as root only from folders root alone can change, so the
  # copy is made by root in a folder of its own, outside the test folder.
  B="$(sudo -n mktemp -d /var/tmp/lab-real.XXXXXX)"
  printf '%s\n' "$B" > "$W/base"
  LAB="$B/lab" ETC="$B/etc" ROOT="$B/root"
  sudo -n env REPO="$REPO" LAB="$LAB" ETC="$ETC" H="${HOSTNAME%%.*}" bash -c '
    set -Eeuo pipefail
    umask 022
    mkdir -p "$LAB/phases/observe/modules" "$LAB/profiles" "$ETC"
    cp "$REPO/labyrinth.sh" "$LAB/"
    cp -R "$REPO/core" "$LAB/"
    cp -R "$REPO/tests/fixtures/modules/toggle" "$LAB/phases/observe/modules/"
    printf "observe.toggle\n" > "$LAB/profiles/test.profile"
    printf "root breakglass\n" > "$ETC/protected-accounts"
    printf "%s ring0 test ubuntu\n" "$H" > "$ETC/hosts"
    printf "REVERT_MINUTES=1\n" > "$ETC/event.conf"
    printf "setting=off\n" > "$LAB/toggle.conf"
    chown -R root:root "$LAB" "$ETC"
    chmod -R go-w "$LAB" "$ETC"'
  run sudo -n bash -c 'printf "root\nring0\nno\n" | bash "$1" --root "$2" --config "$3" --apply observe' _ "$LAB/labyrinth.sh" "$ROOT" "$ETC"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  sudo -n grep -qx 'setting=on' "$LAB/toggle.conf"
  # The run's state is root-only, so the manifest is read through sudo. The
  # run is rolled back once its last manifest entry is written.
  rolled_back() {
    sudo -n bash -c 'grep -q "\"action\":\"run_rolled_back\"" "$1"/state/runs/*/manifest.jsonl' _ "$ROOT"
  }
  for _ in $(seq 1 30); do
    if rolled_back; then break; fi
    sleep 5
  done
  rolled_back
  sudo -n grep -qx 'setting=off' "$LAB/toggle.conf"
  # The rollback the timer ran deleted the timer's unit files.
  run compgen -G '/etc/systemd/system/lab-revert-*'
  [ "$status" -ne 0 ]
}

@test "realsystem: apply refuses code that another account can change" {
  LAB="$W/lab" ETC="$W/etc" ROOT="$W/root"
  mkdir -p "$LAB/phases/observe/modules" "$LAB/profiles" "$ETC"
  cp "$REPO/labyrinth.sh" "$LAB/"
  cp -R "$REPO/core" "$LAB/"
  cp -R "$REPO/tests/fixtures/modules/toggle" "$LAB/phases/observe/modules/"
  printf 'observe.toggle\n' > "$LAB/profiles/test.profile"
  printf 'root breakglass\n' > "$ETC/protected-accounts"
  printf '%s ring0 test ubuntu\n' "${HOSTNAME%%.*}" > "$ETC/hosts"
  printf 'setting=off\n' > "$LAB/toggle.conf"
  run sudo -n bash -c 'printf "root\nring0\nno\n" | bash "$1" --root "$2" --config "$3" --apply observe' _ "$LAB/labyrinth.sh" "$ROOT" "$ETC"
  [ "$status" -eq 20 ]
  [[ "$output" == *"can be changed by an account other than root"* ]]
  grep -qx 'setting=off' "$LAB/toggle.conf"
}
