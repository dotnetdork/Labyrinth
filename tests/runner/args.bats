#!/usr/bin/env bats
# labyrinth.sh command-line parsing, from the cases shared with
# Args.Tests.ps1 (tests/runner/args-cases.txt; docs/Conventions.md 3.3).

load lab_helper

setup() {
  lab_setup
  hosts ring1
  profile observe.toggle
}

# streams ARG...: run labyrinth.sh, keeping stdout ($OUT) and stderr ($ERR)
# apart, and its exit code in $CODE.
streams() {
  CODE=0
  OUT="$(bash "$LAB/labyrinth.sh" "$@" 2> "$BATS_TEST_TMPDIR/err" < /dev/null)" || CODE=$?
  ERR="$(cat "$BATS_TEST_TMPDIR/err")"
}

@test "every shared command-line case gives its exit code and message" {
  local line code stream text args failed=0
  local -a words
  while IFS= read -r line; do
    line="${line%$'\r'}"        # a Windows checkout may add carriage returns
    [[ -n "$line" && "$line" != '#'* ]] || continue
    IFS='|' read -r code stream text args <<< "$line"
    args="${args//@ROOT@/$ROOT}"; args="${args//@ETC@/$ETC}"
    text="${text//@SELF@/$SELF}"
    read -ra words <<< "$args"
    streams "${words[@]+"${words[@]}"}"
    local got="$OUT"
    if [[ "$stream" == err ]]; then got="$ERR"; fi
    if [[ "$CODE" != "$code" || "$got" != *"$text"* ]]; then
      printf 'FAILED [%s]: exit %s (want %s), %s lacks "%s"\nstdout: %s\nstderr: %s\n' \
        "$args" "$CODE" "$code" "$stream" "$text" "$OUT" "$ERR"
      failed=1
    fi
  done < "$BATS_TEST_DIRNAME/args-cases.txt"
  [ "$failed" -eq 0 ]
}

@test "a usage error prints the message, a fix if there is one, and the pointer, all on stderr" {
  streams obsrve
  [ "$CODE" -eq 40 ]
  [ -z "$OUT" ]
  [ "$(wc -l <<< "$ERR")" -eq 3 ]
  streams -x
  [ "$CODE" -eq 40 ]
  [ -z "$OUT" ]
  [ "$(wc -l <<< "$ERR")" -eq 2 ]
  [[ "$ERR" == "$SELF: unknown option '-x'"$'\n'"Try '$SELF -h'." ]]
}

@test "the old command words are plain mistakes, with no hint that maps them" {
  for w in plan apply rollback runs status; do
    streams "$w" observe
    [ "$CODE" -eq 40 ]
    [[ "$ERR" == *"'$w' is not a phase."* ]]
    [[ "$ERR" != *"Did you mean"* ]]
  done
}

@test "the old options are plain mistakes" {
  for o in --apply --profile-name --confirm; do
    streams "$o" x observe
    [ "$CODE" -eq 40 ]
    [[ "$ERR" == *"unknown option '$o'"* ]]
  done
  streams -ProfileName test observe
  [ "$CODE" -eq 40 ]
}

@test "nothing is created by a usage error, help or the version" {
  for a in obsrve -h -V '-?' '/?'; do streams --root "$ROOT" "$a"; done
  streams -h bogus --root "$ROOT"
  streams -u 4f2a --root "$ROOT" --bogus
  [ ! -e "$ROOT" ]
}

@test "-? is help, like -h" {
  streams '-?'
  [ "$CODE" -eq 0 ]
  [[ "$OUT" == *"Usage: laby PHASE"* ]]
}

@test "a warning about an unused option never comes before an error" {
  streams --break-glass root --root relative observe
  [ "$CODE" -eq 40 ]
  [[ "$ERR" == *'full path'* ]]
  [[ "$ERR" != *warning* ]]
}

@test "a warning about an unused option never comes before a run-time error" {
  streams observe --break-glass root --root "$ROOT" --config "$ETC/missing"
  [ "$CODE" -eq 40 ]
  [[ "$ERR" == *'does not exist'* ]]
  [[ "$ERR" != *warning* ]]
  streams -k 4f2a --profile test --root "$ROOT" --config "$ETC"
  [ "$CODE" -eq 40 ]
  [[ "$ERR" == *"no run ending in '4f2a'"* ]]
  [[ "$ERR" != *warning* ]]
}

@test "-u with no run, not as root, says who can list the runs" {
  touch "$LAB/NOT_ADMIN"
  streams -u --root "$ROOT" --config "$ETC"
  [ "$CODE" -eq 40 ]
  [[ "$ERR" == *"As root, '$SELF --history' lists them."* ]]
}

@test "-k with no run, not as root, says who can list the runs" {
  touch "$LAB/NOT_ADMIN"
  streams -k --root "$ROOT" --config "$ETC"
  [ "$CODE" -eq 40 ]
  [[ "$ERR" == *"As root, '$SELF --history' lists them."* ]]
}

@test "the short letters are case-sensitive and the long names are not" {
  streams -P test --root "$ROOT" --config "$ETC" observe
  [ "$CODE" -eq 10 ]
  streams -p test observe
  [ "$CODE" -eq 40 ]
  streams --PROFILE test --Root "$ROOT" --CONFIG "$ETC" observe
  [ "$CODE" -eq 10 ]
  streams -Profile test -root "$ROOT" -config "$ETC" observe
  [ "$CODE" -eq 10 ]
}

@test "-r may come before or after the phase" {
  streams observe -r --root "$ROOT" --config "$ETC"
  [[ "$ERR" != *"unknown"* ]]
  [[ "$ERR" != *"is not a phase"* ]]
  streams -r observe --root "$ROOT" --config "$ETC"
  [[ "$ERR" != *"unknown"* ]]
  [[ "$ERR" != *"is not a phase"* ]]
}

@test "a value may follow an equals sign, a colon or a space" {
  streams -k=4f2a --root "$ROOT" --config "$ETC"
  [[ "$ERR" == *"no run ending in '4f2a'"* ]]
  streams --keep=4f2a --root "$ROOT" --config "$ETC"
  [[ "$ERR" == *"no run ending in '4f2a'"* ]]
  streams -Keep:4f2a --root "$ROOT" --config "$ETC"
  [[ "$ERR" == *"no run ending in '4f2a'"* ]]
  streams --keep 4f2A --root "$ROOT" --config "$ETC"
  [[ "$ERR" == *"no run ending in '4f2A'"* ]]
}
