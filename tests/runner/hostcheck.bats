#!/usr/bin/env bats
# The host checks of labyrinth.sh (docs/Conventions.md section 3.1): plan,
# apply and probe refuse a host listed for another platform or as an
# appliance; keep and rollback skip the checks, so a stored revert-timer
# command still works after the configuration changes.

load lab_helper

setup() {
  lab_setup
  profile observe.toggle
  printf 'web http web.test 80 -\n' > "$ETC/services"
}

# listed PLATFORM: list this host, in group ring1, for PLATFORM
listed() { printf '%s ring1 test %s\n' "$HOST" "$1" > "$ETC/hosts"; }

lab() { run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" "$@" < /dev/null; }

@test "plan, apply and probe refuse a host listed for Windows" {
  listed windows
  for words in "plan observe" "apply observe" probe; do
    # shellcheck disable=SC2086 # the words are split on purpose
    lab $words
    [ "$status" -eq 20 ] || { echo "$words: $status"; return 1; }
    [[ "$output" == *"is listed as windows in $ETC/hosts, not a platform this runner serves"* ]]
  done
  [ ! -e "$ROOT" ]
  [ ! -e "$LAB/toggle.conf" ]
}

@test "plan, apply and probe never act on an appliance" {
  listed appliance
  for words in "plan observe" "apply observe" probe; do
    # shellcheck disable=SC2086 # the words are split on purpose
    lab $words
    [ "$status" -eq 20 ] || { echo "$words: $status"; return 1; }
    [[ "$output" == *"is an appliance"*"never changes it (design 16)"* ]]
  done
  [ ! -e "$ROOT" ]
}

@test "both Linux platforms are served, and an unlisted host may still plan" {
  listed rhel-family
  lab plan observe
  [ "$status" -eq 10 ]
  listed ubuntu
  lab plan observe
  [ "$status" -eq 10 ]
  rm "$ETC/hosts"
  lab --profile test plan observe
  [ "$status" -eq 10 ]
}

@test "keep still works after this host's line changes platform" {
  listed ubuntu
  answers root ring1 no
  apply
  [ "$status" -eq 0 ]
  id="$(run_id)"
  listed windows
  lab keep "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept: the revert timer for run $id is cancelled"* ]]
}

@test "the stored rollback still works after the --config folder is gone" {
  listed ubuntu
  answers root ring1 no
  apply
  [ "$status" -eq 0 ]
  id="$(run_id)"
  rm -rf "$ETC"
  lab rollback "$id"
  [ "$status" -eq 0 ]
  [ ! -e "$LAB/toggle.conf" ]
}
