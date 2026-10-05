#!/usr/bin/env bats
# Unit tests for the new-password helpers (core/secret/secret.sh,
# design 05, section 2.3).

setup() {
  LAB_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export LAB_ROOT
  export LAB_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export LAB_LOG_DIR="$BATS_TEST_TMPDIR/logs"
  export LAB_BACKUP_DIR="$BATS_TEST_TMPDIR/backup"
  export LAB_CONFIG_DIR="$BATS_TEST_TMPDIR/etc"
  # shellcheck source=/dev/null
  source "$LAB_ROOT/core/lib.sh"
  TTY_OUT="$BATS_TEST_TMPDIR/tty.out"
  TTY_IN="$BATS_TEST_TMPDIR/tty.in"
  : > "$TTY_OUT"
}

# A stand-in terminal: writes go to TTY_OUT, and each read takes the next
# line of TTY_IN, failing when there is none.
fake_tty() {
  echo 0 > "$TTY_IN.pos"
  lab_tty_ok() { true; }
  lab_tty_write() { printf '%s' "$1" >> "$TTY_OUT"; }
  # Read in a command substitution, so the position is kept in a file.
  lab_tty_read() {
    local pos
    pos=$(( $(cat "$TTY_IN.pos") + 1 ))
    echo "$pos" > "$TTY_IN.pos"
    if [[ "$(wc -l < "$TTY_IN")" -lt "$pos" ]]; then return 1; fi
    sed -n "${pos}p" "$TTY_IN"
  }
}

@test "new: 20 characters by default, from the set, starting with a letter, one of each kind" {
  local pw i seen=' '
  for i in $(seq 1 50); do
    pw="$(lab_secret_new)"
    [ "${#pw}" -eq 20 ]
    [[ "$pw" =~ ^[A-HJ-NP-Za-km-z][A-HJ-NP-Za-km-z2-9_.+=-]+$ ]]
    [[ "$pw" =~ [A-Z] && "$pw" =~ [a-z] && "$pw" =~ [2-9] && "$pw" == *[-_.+=]* ]]
    [[ "$seen" != *" $pw "* ]]
    seen+="$pw "
  done
  [ "$(lab_secret_new 14 | tr -d '\n' | wc -c)" -eq 14 ]
  [ "$(lab_secret_new 64 | tr -d '\n' | wc -c)" -eq 64 ]
}

@test "new: a length outside 14 to 64 is refused" {
  local len
  for len in 13 65 0 abc -20; do
    run lab_secret_new "$len"
    [ "$status" -eq 40 ] || { echo "accepted: $len"; return 1; }
  done
}

@test "show: on the terminal only, asked again until 'recorded', then cleared" {
  fake_tty
  printf 'done\n  Recorded \n' > "$TTY_IN"
  run lab_secret_show testuser 'Ab3-secretvalue'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q '^      Ab3-secretvalue$' "$TTY_OUT"
  [ "$(grep -o "Type 'recorded'" "$TTY_OUT" | wc -l)" -eq 2 ]
  # Up over the 7 lines shown (one wrong answer), then clear to the end.
  [[ "$(cat "$TTY_OUT")" == *$'\r\033[7A\033[J' ]]
}

@test "show: fails when the terminal goes before the answer, and is blocked without one" {
  fake_tty
  : > "$TTY_IN"
  run lab_secret_show testuser 'Ab3-secretvalue'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  lab_tty_ok() { false; }
  : > "$TTY_OUT"
  run lab_secret_show testuser 'Ab3-secretvalue'
  [ "$status" -eq 20 ]
  [ ! -s "$TTY_OUT" ]
  [[ "$output" != *Ab3-secretvalue* ]]
  run lab_secret_can_show
  [ "$status" -ne 0 ]
}

@test "can show: false for a run with no controlling terminal" {
  command -v setsid > /dev/null || skip 'no setsid here'
  run setsid bash -c 'source "$LAB_ROOT/core/lib.sh"; lab_secret_can_show' < /dev/null
  [ "$status" -ne 0 ]
}
