#!/usr/bin/env bats
# Errors that stop labyrinth.sh say what failed, then how to recover, on
# one prefixed line and one fix line (docs/Conventions.md section 3.2).
# Hints.Tests.ps1 checks the same for labyrinth.ps1.

load lab_helper

setup() {
  lab_setup
  profile observe.clean
}

lab() { run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" "$@" < /dev/null; }

@test "a command that needs root says how to get it" {
  touch "$LAB/NOT_ADMIN"
  for words in runs "keep 4f2a" "rollback 4f2a" "apply observe"; do
    # shellcheck disable=SC2086 # the words are split on purpose
    lab $words
    [ "$status" -eq 20 ] || { echo "$words: $status"; return 1; }
    [[ "$output" == *'needs root'* ]]
    [[ "${lines[1]}" == 'Run it again as root, for example with sudo.' ]]
  done
}

@test "a --config that is missing, or is a file, says which, and what to give" {
  run bash "$LAB/labyrinth.sh" plan observe --profile test --root "$ROOT" --config "$ETC/missing"
  [ "$status" -eq 40 ]
  [ "${lines[0]}" = "labyrinth: the --config folder does not exist: $ETC/missing" ]
  [[ "${lines[1]}" == *'leave out --config'* ]]
  run bash "$LAB/labyrinth.sh" plan observe --profile test --root "$ROOT" --config "$ETC/protected-accounts"
  [ "$status" -eq 40 ]
  [ "${lines[0]}" = "labyrinth: the --config path is a file, not a folder: $ETC/protected-accounts" ]
}

@test "an unknown profile lists the profiles there are" {
  lab plan observe --profile nosuch
  [ "$status" -eq 40 ]
  [ "${lines[0]}" = 'labyrinth: no profile named nosuch' ]
  [[ "${lines[1]}" == 'Profiles here: '*test* ]]
}

@test "a malformed hosts file is one prefixed line with the file and line" {
  printf 'garbage\n' > "$ETC/hosts"
  lab plan observe --profile test
  [ "$status" -eq 40 ]
  [ "${lines[0]}" = "labyrinth: the hosts file is malformed: $ETC/hosts:1: expected: host group profile platform" ]
  [[ "${lines[1]}" == 'Each line is: host group profile platform.'* ]]
}

@test "a missing or empty protected set says which, and what to put in it" {
  rm "$ETC/protected-accounts"
  lab plan observe --profile test
  [ "$status" -eq 20 ]
  [ "${lines[0]}" = "labyrinth: the protected set is not loaded, so Labyrinth refuses to run: there is no $ETC/protected-accounts" ]
  [[ "${lines[1]}" == 'List the accounts Labyrinth must never change'* ]]
  : > "$ETC/protected-accounts"
  lab plan observe --profile test
  [ "$status" -eq 20 ]
  [[ "${lines[0]}" == *"$ETC/protected-accounts lists no accounts" ]]
}

@test "a bad event.conf or service list names the line" {
  printf 'bad line\n' > "$ETC/event.conf"
  lab plan observe --profile test
  [ "$status" -eq 40 ]
  [ "${lines[0]}" = "labyrinth: event.conf is malformed: $ETC/event.conf:1: expected KEY=value" ]
  [ "${lines[1]}" = 'Correct that line, then run the same command again.' ]
  rm "$ETC/event.conf"
  lab probe
  [ "$status" -eq 20 ]
  [ "${lines[0]}" = "labyrinth: no service list at $ETC/services" ]
  [[ "${lines[1]}" == 'List the scored services in that file'* ]]
  printf 'web\n' > "$ETC/services"
  lab probe
  [ "$status" -eq 40 ]
  [[ "${lines[0]}" == "labyrinth: the service list is malformed: $ETC/services:1: "* ]]
  [ "${#lines[@]}" -eq 2 ]
}

@test "a host listed for another platform says where to run" {
  printf '%s ring1 test windows\n' "$HOST" > "$ETC/hosts"
  lab plan observe
  [ "$status" -eq 20 ]
  [ "${lines[1]}" = "Run the Labyrinth runner for windows there, or correct this host's line in the hosts file." ]
}
