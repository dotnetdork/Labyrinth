#!/usr/bin/env bats
# Tests for tests/lint/guard.sh (design 08, section 4.5; docs/Conventions.md section 8).

setup() {
  GUARD="$BATS_TEST_DIRNAME/guard.sh"
  FIX="$BATS_TEST_DIRNAME/../fixtures/guard"
}

@test "a clean file passes, and an allow comment naming the right rule is accepted" {
  run bash "$GUARD" "$FIX/clean.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 file(s) clean"* ]]
}

@test "bash findings: network, install, shells and exec" {
  run bash "$GUARD" "$FIX/dirty.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"dirty.sh:2: [network]"* ]]
  [[ "$output" == *"dirty.sh:3: [install]"* ]]
  [[ "$output" == *"dirty.sh:4: [shells]"* ]]
  [[ "$output" == *"dirty.sh:5: [exec]"* ]]
}

@test "an allow comment naming the wrong rule does not hide the finding" {
  run bash "$GUARD" "$FIX/dirty.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"dirty.sh:6: [network]"* ]]
}

@test "PowerShell findings: network, install, blanket and reboot" {
  run bash "$GUARD" "$FIX/dirty.ps1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"dirty.ps1:2: [network]"* ]]
  [[ "$output" == *"dirty.ps1:3: [install]"* ]]
  [[ "$output" == *"dirty.ps1:4: [blanket]"* ]]
  [[ "$output" == *"dirty.ps1:5: [reboot]"* ]]
}

@test "an allow comment without a reason is itself a finding" {
  run bash "$GUARD" "$FIX/malformed.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"malformed.sh:2: [guard] malformed lab-guard comment"* ]]
}

@test "a missing path is a usage error" {
  run bash "$GUARD" "$FIX/does-not-exist.sh"
  [ "$status" -eq 2 ]
}

@test "an option is a usage error" {
  run bash "$GUARD" -x
  [ "$status" -eq 2 ]
}

@test "the repository's own code is clean" {
  run bash "$GUARD"
  [ "$status" -eq 0 ]
}
