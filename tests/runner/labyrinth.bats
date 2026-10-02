#!/usr/bin/env bats
# Tests for labyrinth.sh in plan mode (design 00, sections 4 and 5).
# Each test builds a throwaway Labyrinth tree (see lab_helper.bash).

load lab_helper

setup() { lab_setup; }

@test "the no-op sample module: check says a change is needed, plan runs, exit 10" {
  profile observe.sample
  plan
  [ "$status" -eq 10 ]
  [[ "$output" == *"sample: would change nothing"* ]]
}

@test "plan mode never runs apply" {
  profile observe.sample
  plan
  [ ! -e "$LAB/APPLIED" ]
}

@test "plan mode creates nothing under the data root" {
  profile observe.sample observe.envdump
  plan
  [ ! -e "$ROOT" ]
}

@test "nothing to do exits 0" {
  profile observe.clean
  plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"[observe.clean] check: nothing to do"* ]]
}

@test "a safety-gate block exits 20" {
  profile observe.blocked
  plan
  [ "$status" -eq 20 ]
}

@test "an exit code outside the contract becomes 40" {
  profile observe.crash
  plan
  [ "$status" -eq 40 ]
  [[ "$output" == *"error (exit 3)"* ]]
}

@test "a change with no plan entry point is an error" {
  profile observe.noplan
  plan
  [ "$status" -eq 40 ]
}

@test "a module with no Linux entry points is skipped" {
  profile observe.winonly
  plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped: no Linux entry points"* ]]
}

@test "entry points get the contract environment, in plan mode" {
  profile observe.envdump
  mkdir -p "$ROOT/etc"
  cp "$ETC/protected-accounts" "$ROOT/etc/"
  run bash "$LAB/labyrinth.sh" --profile test --root "$ROOT" observe
  [ "$status" -eq 0 ]
  [[ "$output" == *"LAB_ROOT=$LAB"* ]]
  [[ "$output" == *"LAB_CONFIG_DIR=$ROOT/etc"* ]]
  [[ "$output" == *"LAB_STATE_DIR=$ROOT/state"* ]]
  [[ "$output" == *"LAB_LOG_DIR=$ROOT/logs"* ]]
  [[ "$output" == *"LAB_BACKUP_DIR=$ROOT/backup"* ]]
  [[ "$output" == *"LAB_MODULE_ID=observe.envdump"* ]]
  [[ "$output" == *"LAB_DRY_RUN=1"* ]]
  [[ "$output" =~ LAB_RUN_ID=[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4} ]]
}

@test "an unknown module.yml key is rejected" {
  profile observe.badyml
  plan
  [ "$status" -eq 40 ]
  [[ "$output" == *"unknown key color"* ]]
}

# yml PLATFORMS [EXTRA_LINE]: rewrite the clean fixture's module.yml
yml() {
  printf 'id: observe.clean\nphase: observe\npriority: P2\nplatforms: %s\nrisk: read-only\ntouches_scored: false\n%s\n' \
    "$1" "${2:-}" > "$LAB/phases/observe/modules/clean/module.yml"
}

@test "module.yml outside the flat subset is rejected" {
  profile observe.clean
  local -a cases=('[]|' '[ ]|' 'ubuntu|' '[ubuntu|' '[ubuntu, bogus]|'
    '[ubuntu]|requires: &anchor' '[ubuntu]|outputs: |' '[ubuntu]|  nested: true' '[ubuntu]|risk: reversible')
  local c
  for c in "${cases[@]}"; do
    yml "${c%%|*}" "${c#*|}"
    plan
    [ "$status" -eq 40 ] || { echo "accepted: $c"; return 1; }
    [[ "$output" == *"invalid module.yml"* ]]
  done
}

@test "a well-formed module.yml with spaces in its lists is accepted" {
  profile observe.clean
  printf '# comment\n\nid: observe.clean\nphase: observe\npriority: P2\nplatforms: [ ubuntu , windows ]\nrisk: read-only\ntouches_scored: false\nrequires: []\n' \
    > "$LAB/phases/observe/modules/clean/module.yml"
  plan
  [ "$status" -eq 0 ]
}

@test "a module.yml id that does not match its folder is rejected" {
  profile observe.badid
  plan
  [ "$status" -eq 40 ]
}

@test "a module in the profile that does not exist is an error" {
  profile observe.missing
  plan
  [ "$status" -eq 40 ]
}

@test "only the requested phase runs, in profile order, and the highest code wins" {
  profile lockout.other observe.clean observe.sample observe.blocked
  plan
  [ "$status" -eq 20 ]
  [[ "$output" != *"lockout.other"* ]]
  clean_line="$(grep -n 'observe.clean' <<< "$output" | head -n1 | cut -d: -f1)"
  sample_line="$(grep -n 'observe.sample' <<< "$output" | head -n1 | cut -d: -f1)"
  [ "$clean_line" -lt "$sample_line" ]
}

@test "a run-time profile replaces the shipped one" {
  profile observe.sample
  mkdir -p "$BATS_TEST_TMPDIR/etc/profiles"
  printf 'observe.clean\n' > "$BATS_TEST_TMPDIR/etc/profiles/test.profile"
  run bash "$LAB/labyrinth.sh" --profile test --root "$ROOT" --config "$BATS_TEST_TMPDIR/etc" observe
  [ "$status" -eq 0 ]
  [[ "$output" != *"observe.sample"* ]]
}

@test "a profile line that is not a module id is rejected" {
  profile 'not a module'
  plan
  [ "$status" -eq 40 ]
}

@test "plan mode refuses to run without the protected set" {
  profile observe.clean
  rm "$ETC/protected-accounts"
  plan
  [ "$status" -eq 20 ]
  [[ "$output" == *"protected set is not loaded"* ]]
  : > "$ETC/protected-accounts"
  plan
  [ "$status" -eq 20 ]
}

@test "a malformed protected set is an error" {
  profile observe.clean
  printf 'root superuser
' > "$ETC/protected-accounts"
  plan
  [ "$status" -eq 40 ]
}

@test "modules run by priority, then in profile order" {
  profile observe.sample observe.clean
  sed -i 's/^priority: P2/priority: P0/' "$LAB/phases/observe/modules/clean/module.yml"
  plan
  clean_line="$(grep -n 'observe.clean' <<< "$output" | head -n1 | cut -d: -f1)"
  sample_line="$(grep -n 'observe.sample' <<< "$output" | head -n1 | cut -d: -f1)"
  [ "$clean_line" -lt "$sample_line" ]
}

@test "the profile comes from the hosts file when --profile is not given" {
  profile observe.clean
  hosts ring1
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" observe
  [ "$status" -eq 0 ]
  [[ "$output" == *"profile test"* ]]
}

@test "a reversible module without rollback.sh is invalid" {
  profile observe.norollback
  plan
  [ "$status" -eq 40 ]
  [[ "$output" == *"missing rollback.sh"* ]]
}

@test "argument errors exit 40" {
  profile observe.sample
  run bash "$LAB/labyrinth.sh" observe
  [ "$status" -eq 40 ]
  run bash "$LAB/labyrinth.sh" --profile test nope
  [ "$status" -eq 40 ]
  run bash "$LAB/labyrinth.sh" --profile 'a;b' observe
  [ "$status" -eq 40 ]
  run bash "$LAB/labyrinth.sh" --profile test --root relative observe
  [ "$status" -eq 40 ]
  run bash "$LAB/labyrinth.sh" --profile nosuch observe
  [ "$status" -eq 40 ]
}

@test "--version and --help exit 0" {
  run bash "$LAB/labyrinth.sh" --version
  [ "$status" -eq 0 ]
  run bash "$LAB/labyrinth.sh" --help
  [ "$status" -eq 0 ]
}
