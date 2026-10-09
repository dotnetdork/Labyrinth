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
  [[ "${lines[1]}" == *'leave out --config to use <root>/etc'* ]]
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
  [ "${lines[0]}" = "labyrinth: the protected set is not loaded, so nothing runs: there is no $ETC/protected-accounts" ]
  [[ "${lines[1]}" == 'List, one "account class" per line, the accounts'* ]]
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
  [[ "${lines[1]}" == 'List the scored services there'* ]]
  printf 'web\n' > "$ETC/services"
  lab probe
  [ "$status" -eq 40 ]
  [[ "${lines[0]}" == "labyrinth: the service list is malformed: $ETC/services:1: "* ]]
  [ "${#lines[@]}" -eq 2 ]
}

@test "an empty service list counts as none, and plan finds a malformed one" {
  printf '# filled in later\n' > "$ETC/services"
  lab probe
  [ "$status" -eq 20 ]
  [ "${lines[0]}" = "labyrinth: $ETC/services lists no service" ]
  [[ "${lines[1]}" == 'List the scored services there'* ]]
  printf 'web\n' > "$ETC/services"
  lab plan observe --profile test
  [ "$status" -eq 40 ]
  [[ "${lines[0]}" == "labyrinth: the service list is malformed: $ETC/services:1: "* ]]
  [ "${lines[1]}" = 'Correct that line, then run the same command again.' ]
}

@test "a missing configuration folder is named, not taken for empty files" {
  run bash "$LAB/labyrinth.sh" plan observe --profile test --root "$ROOT"
  [ "$status" -eq 40 ]
  [ "${lines[0]}" = "labyrinth: the configuration folder does not exist: $ROOT/etc" ]
  [[ "${lines[1]}" == *'--root'*'--config'* ]]
}

@test "a configuration file that cannot be read says it needs root" {
  [[ "$(id -u)" != 0 ]] || skip 'root reads every file'
  chmod 000 "$ETC/protected-accounts"
  lab plan observe --profile test
  chmod 600 "$ETC/protected-accounts"
  [ "$status" -eq 20 ]
  [ "${lines[0]}" = "labyrinth: needs root to read $ETC/protected-accounts" ]
  [ "${lines[1]}" = 'Run it again as root, for example with sudo.' ]
}

@test "help on a module with a bad module.yml names the line and keeps the message whole" {
  printf 'bad line\n' >> "$LAB/phases/observe/modules/clean/module.yml"
  run bash "$LAB/labyrinth.sh" help observe.clean
  [ "$status" -eq 40 ]
  [ "${lines[0]}" = 'labyrinth: the module.yml of observe.clean is not valid: not a key: value line' ]
  [[ "${lines[1]}" =~ ^Report\ the\ module\ to\ its\ author,\ or\ correct\ .*/module\.yml:[0-9]+$ ]]
}

@test "a profile that differs from the hosts file says to leave it out" {
  hosts ring1
  lab apply observe --profile other
  [ "$status" -eq 40 ]
  [ "${lines[0]}" = 'labyrinth: the hosts file gives this host profile test, not other' ]
  [ "${lines[1]}" = "Leave out --profile, or change this host's line in $ETC/hosts." ]
}

@test "a host listed for another platform says where to run" {
  printf '%s ring1 test windows\n' "$HOST" > "$ETC/hosts"
  lab plan observe
  [ "$status" -eq 20 ]
  [ "${lines[0]}" = "labyrinth: this runner does not serve this host's platform, windows" ]
  [ "${lines[1]}" = "Use the runner for windows, or correct this host's line in $ETC/hosts" ]
}
