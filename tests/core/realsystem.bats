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
  if [ "${LAB_REALSYSTEM:-}" = 1 ]; then sudo -n rm -rf -- "$W/root" "$W/state" "$W/lab"; fi
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
}

@test "realsystem: an apply that is not kept is rolled back by the timer" {
  LAB="$W/lab" ETC="$W/etc" ROOT="$W/root"
  mkdir -p "$LAB/phases/observe/modules" "$LAB/profiles" "$ETC"
  cp "$REPO/labyrinth.sh" "$LAB/"
  cp -R "$REPO/core" "$LAB/"
  cp -R "$REPO/tests/fixtures/modules/toggle" "$LAB/phases/observe/modules/"
  printf 'observe.toggle\n' > "$LAB/profiles/test.profile"
  printf 'root breakglass\n' > "$ETC/protected-accounts"
  printf '%s ring0 test ubuntu\n' "${HOSTNAME%%.*}" > "$ETC/hosts"
  printf 'REVERT_MINUTES=1\n' > "$ETC/event.conf"
  printf 'setting=off\n' > "$LAB/toggle.conf"
  run sudo -n bash -c 'printf "root\nring0\nno\n" | bash "$1" --root "$2" --config "$3" --apply observe' _ "$LAB/labyrinth.sh" "$ROOT" "$ETC"
  [ "$status" -eq 0 ]
  grep -qx 'setting=on' "$LAB/toggle.conf"
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
  grep -qx 'setting=off' "$LAB/toggle.conf"
}
