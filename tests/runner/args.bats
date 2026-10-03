#!/usr/bin/env bats
# labyrinth.sh command-line parsing, from the cases shared with
# Args.Tests.ps1 (tests/runner/args-cases.txt; docs/Conventions.md 3.1).

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
    text="${text//@SELF@/labyrinth.sh}"
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

@test "a usage error prints two lines, both on stderr" {
  streams obsrve
  [ "$CODE" -eq 40 ]
  [ -z "$OUT" ]
  [ "$(wc -l <<< "$ERR")" -eq 2 ]
}

@test "nothing is created by a usage error, help or the version" {
  for a in obsrve help -V; do streams --root "$ROOT" "$a"; done
  [ ! -e "$ROOT" ]
}

@test "a warning about an unused option never comes before an error" {
  streams --break-glass root --root relative observe
  [ "$CODE" -eq 40 ]
  [[ "$ERR" == *'full path'* ]]
  [[ "$ERR" != *warning* ]]
}

@test "a warning about an unused option never comes before a run-time error" {
  streams plan observe --break-glass root --root "$ROOT" --config "$ETC/missing"
  [ "$CODE" -eq 40 ]
  [[ "$ERR" == *'does not exist'* ]]
  [[ "$ERR" != *warning* ]]
  streams keep 4f2a --profile test --root "$ROOT" --config "$ETC"
  [ "$CODE" -eq 40 ]
  [[ "$ERR" == *"no run ending in '4f2a'"* ]]
  [[ "$ERR" != *warning* ]]
}

@test "rollback with no run, not as root, says who can list the runs" {
  touch "$LAB/NOT_ADMIN"
  streams rollback --root "$ROOT" --config "$ETC"
  [ "$CODE" -eq 40 ]
  [[ "$ERR" == *"as root, 'labyrinth.sh runs' lists them"* ]]
}
