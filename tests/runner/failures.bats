#!/usr/bin/env bats
# Tests for how labyrinth.sh reports failures that used to be hidden
# (docs/Conventions.md section 4): the ERR trap, and the manifest writes
# that are checked by hand because errexit is off where they run.
# Failures are injected by appending a stand-in to the throwaway core.

load lab_helper

setup() {
  lab_setup
  hosts ring1
  profile observe.toggle
  answers root ring1 keep
}

# stand_in TEXT: append a function to the throwaway core
stand_in() { printf '%s\n' "$1" >> "$LAB/core/lib.sh"; }

# read_only_after_cancel: the timer is cancelled, then the manifest can no
# longer be written.
read_only_after_cancel() {
  stand_in 'lab_timer_cancel() { rm -f "$LAB_STATE_DIR/runs/$1/timer" "$LAB_STATE_DIR/runs/$1/timer-due"; chmod a-w "$LAB_STATE_DIR/runs/$1/manifest.jsonl"; }'
}

@test "an internal error after a change says the run stopped and keeps the timer" {
  stand_in 'lab_lock_release() { return 3; }'
  apply
  [ "$status" -eq 40 ]
  [[ "$output" == *"labyrinth: internal error at "* ]]
  [[ "$output" == *"The run stopped. Earlier changes stay until the revert timer undoes them."* ]]
  [[ "$output" =~ The\ revert\ timer\ rolls\ this\ run\ back\ at\ [0-9]{2}:[0-9]{2}\ UTC ]]
  id="$(run_id)"
  # Undo comes first, and the safe choice is named.
  [[ "$output" == *"To undo them now: labyrinth.sh rollback ${id: -4}"$'\n'"To keep them now: labyrinth.sh keep ${id: -4}"$'\n''If in doubt, undo them.'* ]]
  [ -f "$ROOT/state/runs/$(run_id)/timer" ]
  grep -qx 'setting=on' "$LAB/toggle.conf"
}

@test "an internal error before any change says nothing was changed, once" {
  stand_in 'lab_host() { return 7; }'
  apply
  [ "$status" -eq 40 ]
  [ "$(grep -c 'internal error' <<< "$output")" -eq 1 ]
  [[ "$output" == *"Nothing was changed."* ]]
  [ ! -e "$LAB/toggle.conf" ]
  [ ! -e "$ROOT/state/runs" ]
}

@test "the expected failures are not reported as internal errors" {
  touch "$LAB/FAIL_VERIFY"
  apply
  [ "$status" -eq 30 ]
  [[ "$output" != *"internal error"* ]]
  rm "$LAB/FAIL_VERIFY"
  touch "$LAB/FAIL_APPLY"
  # Break-glass is asked only on the first apply.
  answers ring1 keep
  apply
  [ "$status" -eq 40 ]
  [[ "$output" != *"internal error"* ]]
  rm "$LAB/FAIL_APPLY"
  plan
  [ "$status" -eq 10 ]
  [[ "$output" != *"internal error"* ]]
  answers ring1 no
  apply
  [ "$status" -eq 0 ]
  id="$(run_id)"
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" rollback "$id"
  [ "$status" -eq 0 ]
  [[ "$output" != *"internal error"* ]]
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" keep "$id"
  [ "$status" -eq 20 ]
  [[ "$output" != *"internal error"* ]]
  hosts manual
  apply
  [ "$status" -eq 20 ]
  [[ "$output" != *"internal error"* ]]
}

@test "keep that cannot cancel the timer says when it fires and how to retry" {
  answers root ring1 no
  apply
  id="$(run_id)"
  stand_in 'lab_timer_cancel() { return 1; }'
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" keep "$id"
  [ "$status" -eq 40 ]
  [[ "$output" =~ still\ rolls\ it\ back\ at\ [0-9]{2}:[0-9]{2}\ UTC ]]
  [[ "$output" == *"Retry: labyrinth.sh keep ${id: -4}"* ]]
}

@test "keep that cancels the timer but cannot record it says so and exits 40" {
  [ "$(id -u)" -ne 0 ] || skip 'root can write a read-only file'
  answers root ring1 no
  apply
  id="$(run_id)"
  read_only_after_cancel
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" keep "$id"
  [ "$status" -eq 40 ]
  [[ "$output" == *"could not be recorded"*"Its revert timer is cancelled, so the changes stay."* ]]
  [[ "$output" != *"kept: the revert timer"* ]]
  [[ "$output" != *"internal error"* ]]
}

@test "a rollback that cannot be recorded still rolls back and exits 40" {
  [ "$(id -u)" -ne 0 ] || skip 'root can write a read-only file'
  answers root ring1 no
  apply
  id="$(run_id)"
  read_only_after_cancel
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" rollback "$id"
  [ "$status" -eq 40 ]
  [[ "$output" == *"rolled back, but the manifest cannot be written to record it"* ]]
  [ ! -e "$LAB/toggle.conf" ]
}
