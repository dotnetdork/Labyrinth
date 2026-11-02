#!/usr/bin/env bats
# labyrinth.sh --only and --skip: preview or run chosen modules of a phase
# (docs/Conventions.md section 3.1, Partial runs).

load lab_helper

setup() {
  lab_setup
  hosts ring1
  profile observe.recorder observe.toggle observe.dependent
}

# lab ARG...: run labyrinth.sh with the test's root and configuration
lab() { run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" "$@" < /dev/null; }

# lockout_modules: a lockout phase with an inventory (a read-only module,
# copied from the recorder) and a firewall that requires it (copied from the
# dependent), and a profile that lists both.
lockout_modules() {
  local m="$LAB/phases/lockout/modules"
  mkdir -p "$m"
  cp -R "$REPO/tests/fixtures/modules/recorder" "$m/inventory"
  cp -R "$REPO/tests/fixtures/modules/dependent" "$m/firewall"
  sed -i 's/^id: .*/id: lockout.inventory/; s/^phase: .*/phase: lockout/' "$m/inventory/module.yml"
  sed -i 's/^id: .*/id: lockout.firewall/; s/^phase: .*/phase: lockout/; s/^requires: .*/requires: [lockout.inventory]/' "$m/firewall/module.yml"
  profile lockout.inventory lockout.firewall
}

# run_lockout ARG...: run the lockout phase, answering the prompts
run_lockout() {
  answers root ring1 no
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" -r "$@" lockout < "$ANSWERS"
}

# no_run_made: nothing was written for a run
no_run_made() { [ ! -d "$ROOT/state/runs" ] || [ -z "$(ls -A "$ROOT/state/runs")" ]; }

@test "--only runs just the named module" {
  answers root ring1 no
  apply --only observe.toggle
  [ "$status" -eq 0 ]
  [ -f "$LAB/toggle.conf" ]
  [ ! -e "$LAB/dependent.conf" ]
  [ ! -e "$ROOT/state/recorder/marker" ]
  [[ "$output" == *"Checking 1 module of profile test."* ]]
  [[ "$output" == *$'\n'"Partial run: only these observe modules (--only):"$'\n'"  observe.toggle"$'\n'* ]]
  [[ "$output" == *"Summary: 1 module: 1 OK."* ]]
  [[ "$output" == *"Partial run: 1 of 3 modules of the phase (--only)."* ]]
  [[ "$output" != *"Recording sample"* ]]
}

@test "--skip runs the rest" {
  answers root ring1 no
  apply --skip observe.toggle
  [ "$status" -eq 0 ]
  [ ! -e "$LAB/toggle.conf" ]
  grep -qx 'dry=0' "$ROOT/state/recorder/marker"
  [ -f "$LAB/dependent.conf" ]
  [[ "$output" == *"Partial run: all observe modules but these (--skip):"$'\n'"  observe.toggle"* ]]
  [[ "$output" == *"Partial run: 2 of 3 modules of the phase (--skip)."* ]]
  [[ "$output" != *"Toggle setting sample"* ]]
}

@test "a preview takes --only and --skip too, and changes nothing" {
  plan --only observe.toggle
  [ "$status" -eq 10 ]
  [[ "$output" == *"Checking 1 module of profile test."* ]]
  [[ "$output" == *"Toggle setting sample (observe.toggle)"* ]]
  [[ "$output" != *"Recording sample"* ]]
  [[ "$output" == *"Partial run: 1 of 3 modules of the phase (--only)."* ]]
  [[ "$output" == *"Nothing on this host was changed."* ]]
  [ ! -e "$LAB/toggle.conf" ]
  plan --skip observe.toggle,observe.dependent
  [ "$status" -eq 0 ]
  [[ "$output" == *"Recording sample (observe.recorder)"* ]]
  [[ "$output" != *"Toggle setting sample"* ]]
}

@test "an ID that is not a module of the phase in the profile is a usage error with a suggestion" {
  apply --only observe.togle
  [ "$status" -eq 40 ]
  [[ "$output" == *"--only: 'observe.togle' is not a module of the observe phase in profile test (did you mean 'observe.toggle'?)"* ]]
  [[ "$output" == *"Try '$SELF -r -h'."* ]]
  no_run_made
  plan --skip observe.nothing
  [ "$status" -eq 40 ]
  [[ "$output" == *"--skip: 'observe.nothing' is not a module of the observe phase in profile test"* ]]
}

@test "a list that is not module IDs of the phase is a usage error" {
  lab observe --only toggle
  [ "$status" -eq 40 ]
  [[ "$output" == *"--only: not a module ID: 'toggle'"* ]]
  lab observe --only observe.toggle,
  [ "$status" -eq 40 ]
  [[ "$output" == *"the list has an empty item"* ]]
  lab observe --skip lockout.inventory
  [ "$status" -eq 40 ]
  [[ "$output" == *"'lockout.inventory' is not a module of the observe phase"* ]]
}

@test "--only and --skip together, or with another action, are usage errors" {
  lab observe --only observe.toggle --skip observe.recorder
  [ "$status" -eq 40 ]
  [[ "$output" == *"--only and --skip cannot be used together"* ]]
  lab -k 4f2a --only observe.toggle
  [ "$status" -eq 40 ]
  [[ "$output" == *"--only is only for a preview or -r, not -k"* ]]
  lab --skip observe.toggle
  [ "$status" -eq 40 ]
  [[ "$output" == *"no phase or action given"* ]]
}

@test "a skipped dependency blocks its dependent, and nothing is changed" {
  answers root ring1 no
  apply --only observe.dependent
  [ "$status" -eq 20 ]
  [[ "$output" == *"BLOCKED  Dependent sample (observe.dependent)"* ]]
  [[ "$output" == *"Problem:   needs observe.recorder, which this run left out"* ]]
  [[ "$output" == *"Fix:       $SELF -r observe --only observe.recorder,observe.dependent --root $ROOT --config $ETC"* ]]
  [[ "$output" == *"Summary: 1 module: 1 BLOCKED."* ]]
  [[ "$output" == *"Nothing on this host was changed."* ]]
  [[ "$output" == *"apply finished: exit 20 (blocked)"* ]]
  [[ "$output" != *"Type the group name"* ]]
  [ ! -e "$LAB/dependent.conf" ]
  no_run_made
}

@test "the fix for --skip leaves the other skipped modules out" {
  apply --skip observe.recorder,observe.toggle
  [ "$status" -eq 20 ]
  [[ "$output" == *"Fix:       $SELF -r observe --skip observe.toggle --root $ROOT --config $ETC"* ]]
  apply --skip observe.recorder
  [ "$status" -eq 20 ]
  [[ "$output" == *"Fix:       $SELF -r observe --root $ROOT --config $ETC"* ]]
}

@test "a preview blocks the same way, and names the command without -r" {
  plan --only observe.dependent
  [ "$status" -eq 20 ]
  [[ "$output" == *"needs observe.recorder, which this run left out"* ]]
  [[ "$output" == *"Fix:       $SELF observe --only observe.recorder,observe.dependent"* ]]
  [[ "$output" == *"plan finished: exit 20 (blocked)"* ]]
}

@test "naming the dependency with the dependent runs both" {
  answers root ring1 no
  apply --only observe.recorder,observe.dependent
  [ "$status" -eq 0 ]
  [ -f "$LAB/dependent.conf" ]
  grep -qx 'dry=0' "$ROOT/state/recorder/marker"
  [ ! -e "$LAB/toggle.conf" ]
}

@test "only the modules of this run count: an earlier run of the dependency does not help" {
  answers root ring1 no
  apply --only observe.recorder
  [ "$status" -eq 0 ]
  answers ring1 no
  apply --only observe.dependent
  [ "$status" -eq 20 ]
  [[ "$output" == *"needs observe.recorder, which this run left out"* ]]
  [ ! -e "$LAB/dependent.conf" ]
}

@test "the revert timer and the keep question work as in a full run, and the run is recorded as partial" {
  local id
  answers root ring1 no
  apply --only observe.toggle
  [ "$status" -eq 0 ]
  [[ "$output" == *"Type keep to keep the changes"* ]]
  [[ "$output" == *"The revert timer undoes this run"* ]]
  [[ "$output" == *"Not kept. To keep later:"* ]]
  [[ "$(manifest)" == *'"action":"run_start"'*'"note":"phase observe, profile test, group ring1, partial --only observe.toggle"'* ]]
  id="$(run_id)"
  lab --show "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n'"  Group:     ring1"$'\n'"  Partial:   --only observe.toggle"$'\n'* ]]
  [[ "$output" == *"  State:     armed: undo at "* ]]
  lab -u "$id"
  [ "$status" -eq 0 ]
  [ ! -e "$LAB/toggle.conf" ]
  answers ring1 keep
  apply --skip observe.recorder,observe.dependent
  [ "$status" -eq 0 ]
  [[ "$output" == *"Type keep to keep the changes"* ]]
  [[ "$(manifest)" == *'"action":"run_kept"'* ]]
  [ -f "$LAB/toggle.conf" ]
}

@test "a full run is not partial: no header, no summary line, no note" {
  answers root ring1 no
  apply
  [ "$status" -eq 0 ]
  [[ "$output" != *"Partial run"* ]]
  [[ "$(manifest)" != *"partial"* ]]
  lab --show "$(run_id)"
  [[ "$output" != *"Partial:"* ]]
}

@test "a run that leaves out lockout.inventory is refused when the host has no dependency map" {
  lockout_modules
  run_lockout --skip lockout.inventory
  [ "$status" -eq 20 ]
  [[ "$output" == *"BLOCKED  "*"(lockout.inventory)"* ]]
  [[ "$output" == *"Problem:   this host has no dependency map yet, and the firewall would have"* ]]
  [[ "$output" == *"nothing to keep open"* ]]
  [[ "$output" == *"Fix:       run lockout.inventory first, or leave it in"* ]]
  [[ "$output" == *"Nothing on this host was changed."* ]]
  [[ "$output" != *"Type the group name"* ]]
  [ ! -e "$LAB/dependent.conf" ]
  no_run_made
  run_lockout --only lockout.firewall
  [ "$status" -eq 20 ]
  [[ "$output" == *"this host has no dependency map yet"* ]]
  [ ! -e "$LAB/dependent.conf" ]
  no_run_made
}

@test "a run may leave out lockout.inventory when the host has a dependency map from an earlier run" {
  lockout_modules
  mkdir -p "$ROOT/state/inventory"
  printf '10.0.0.5 tcp 53\n' > "$ROOT/state/inventory/deps"
  run_lockout --skip lockout.inventory
  [ "$status" -eq 0 ]
  [[ "$output" != *"BLOCKED"* ]]
  [ -f "$LAB/dependent.conf" ]
  [ ! -e "$ROOT/state/recorder/marker" ]
  [[ "$output" == *"Partial run: 1 of 2 modules of the phase (--skip)."* ]]
}

@test "a preview may always leave out lockout.inventory" {
  lockout_modules
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" lockout --skip lockout.inventory < /dev/null
  [ "$status" -eq 10 ]
  [[ "$output" != *"BLOCKED"* ]]
  [[ "$output" == *"Dependent sample (lockout.firewall)"* ]]
}

@test "leaving out a module that is not the inventory is still refused when a map exists" {
  lockout_modules
  mkdir -p "$ROOT/state/inventory" "$LAB/phases/lockout/modules/other"
  : > "$ROOT/state/inventory/deps"
  sed -i 's/^requires: .*/requires: [lockout.inventory, lockout.other]/' "$LAB/phases/lockout/modules/firewall/module.yml"
  cp -R "$REPO/tests/fixtures/modules/toggle/." "$LAB/phases/lockout/modules/other/"
  sed -i 's/^id: .*/id: lockout.other/; s/^phase: .*/phase: lockout/' "$LAB/phases/lockout/modules/other/module.yml"
  profile lockout.inventory lockout.other lockout.firewall
  run_lockout --skip lockout.inventory,lockout.other
  [ "$status" -eq 20 ]
  [[ "$output" == *"needs lockout.other, which this run left out"* ]]
  [[ "$output" == *"Fix:       $SELF -r lockout --skip lockout.inventory --root $ROOT --config $ETC"* ]]
  [ ! -e "$LAB/dependent.conf" ]
}

@test "help for --only and --skip prints a page and runs nothing" {
  run bash "$LAB/labyrinth.sh" --only observe.toggle -h < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == "Usage: $LAB/labyrinth.sh [-r] PHASE --only LIST"* ]]
  run bash "$LAB/labyrinth.sh" -h skip < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == "Usage: $LAB/labyrinth.sh [-r] PHASE --skip LIST"* ]]
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" -r observe --skip observe.toggle --bogus -h < /dev/null
  [ "$status" -eq 0 ]
  no_run_made
}
