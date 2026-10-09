#!/usr/bin/env bats
# Tests for keep_on_verify in labyrinth.sh: a module that only takes access
# away is kept once it verifies and no scored service got worse, so the
# revert timer, and rollback without --all, leave it alone
# (docs/Conventions.md section 3.1). The host-specific parts are test
# doubles (tests/fixtures/doubles.sh).

load lab_helper

setup() {
  lab_setup
  hosts ring1
  profile observe.keeper
  printf 'web http web.test 80 -\n' > "$ETC/services"
}

rollback() { run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" rollback "$@"; }

@test "a module kept once verified is recorded, and a run with only such changes is kept without asking" {
  answers root ring1
  apply
  [ "$status" -eq 0 ]
  grep -qx 'setting=on' "$LAB/keeper.conf"
  [[ "$output" == *"Did:       kept: it verified and no scored service got worse"* ]]
  [[ "$output" == *"All changes are applied, verified and kept."* ]]
  [[ "$output" != *"Type keep to keep"* ]]
  m="$(manifest)"
  [[ "$m" == *'"module":"observe.keeper"'*'"action":"module_kept"'* ]]
  [[ "$m" == *'"action":"run_kept"'* ]]
  [ ! -f "$ROOT/state/runs/$(run_id)/timer" ]
}

@test "the recap says which changes are kept once they verify" {
  answers root ring1
  apply
  [[ "$output" == *"A change that only takes access away is kept once it verifies"* ]]
}

@test "the revert timer undoes the other changes and leaves a kept module in place" {
  profile observe.toggle observe.keeper
  answers root ring1 no
  apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"Type keep to keep"* ]]
  id="$(run_id)"
  # The command the timer runs.
  rollback "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Kept once verified, so left in place (add --all to undo these too):"* ]]
  [[ "$output" == *"  Keeper setting sample (observe.keeper)"* ]]
  [ ! -e "$LAB/toggle.conf" ]
  grep -qx 'setting=on' "$LAB/keeper.conf"
  grep -q "rolled back run $id" "$LAB/notice.log"
}

@test "rollback --all undoes kept modules too" {
  answers root ring1
  apply
  id="$(run_id)"
  rollback "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing else needs undoing."* ]]
  grep -qx 'setting=on' "$LAB/keeper.conf"
  [ ! -e "$LAB/notice.log" ]
  rollback "$id" --all
  [ "$status" -eq 0 ]
  [ ! -e "$LAB/keeper.conf" ]
  grep -q "rolled back run $id" "$LAB/notice.log"
}

@test "with no service list, nothing is kept early and the timer still covers it" {
  rm "$ETC/services"
  answers root ring1 no
  apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"Note:      not kept yet: with no service list"* ]]
  [[ "$output" == *"Type keep to keep"* ]]
  [[ "$(manifest)" != *'"action":"module_kept"'* ]]
  rollback "$(run_id)"
  [ ! -e "$LAB/keeper.conf" ]
}

@test "a module whose verify fails is rolled back, never kept" {
  touch "$LAB/FAIL_VERIFY"
  answers root ring1
  apply
  [ "$status" -eq 30 ]
  [ ! -e "$LAB/keeper.conf" ]
  [[ "$(manifest)" != *'"action":"module_kept"'* ]]
}

@test "a module that breaks a scored service is rolled back, never kept" {
  printf '%s\n' 'printf "web.test fail\n" > "$LAB_ROOT/probe-state"' >> "$LAB/phases/observe/modules/keeper/apply.sh"
  answers root ring1
  apply
  [ "$status" -eq 30 ]
  [ ! -e "$LAB/keeper.conf" ]
  [[ "$(manifest)" != *'"action":"module_kept"'* ]]
}

@test "keep_on_verify is refused on a module that changes nothing" {
  sed -i 's/^risk: reversible/risk: read-only/' "$LAB/phases/observe/modules/keeper/module.yml"
  plan
  [ "$status" -eq 40 ]
  [[ "$output" == *"keep_on_verify is only for a module that changes something"* ]]
}

@test "keep_on_verify must be true or false" {
  sed -i 's/^keep_on_verify: true/keep_on_verify: yes/' "$LAB/phases/observe/modules/keeper/module.yml"
  plan
  [ "$status" -eq 40 ]
  [[ "$output" == *"keep_on_verify must be true or false"* ]]
}

@test "help explains rollback --all and a kept module" {
  run bash "$LAB/labyrinth.sh" help rollback
  [[ "$output" == *"--all                  also undo changes kept once they verified"* ]]
  run bash "$LAB/labyrinth.sh" help observe.keeper
  [[ "$output" == *"Kept once it verifies and no scored service got worse"* ]]
}
