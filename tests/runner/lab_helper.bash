# Shared setup for the runner tests. Each test gets a throwaway Labyrinth
# tree with the core, the fixture modules from tests/fixtures/modules and
# the test doubles from tests/fixtures/doubles.sh, plus its own run-time
# configuration directory. Nothing outside the test directory is used.

lab_setup() {
  REPO="$BATS_TEST_DIRNAME/../.."
  LAB="$BATS_TEST_TMPDIR/lab"
  ROOT="$BATS_TEST_TMPDIR/root"
  ETC="$BATS_TEST_TMPDIR/etc"
  SELF="$LAB/labyrinth.sh"   # how hints name the runner, as the tests start it
  unset SUDO_USER
  HOST="$(uname -n)"; HOST="${HOST%%.*}"
  mkdir -p "$LAB/phases/observe/modules" "$LAB/profiles" "$ETC"
  cp "$REPO/labyrinth.sh" "$LAB/"
  cp -R "$REPO/core" "$LAB/"
  cp -R "$REPO/tests/fixtures/modules/." "$LAB/phases/observe/modules/"
  cat "$REPO/tests/fixtures/doubles.sh" >> "$LAB/core/lib.sh"
  printf 'root breakglass\nscoring1 scoring\n' > "$ETC/protected-accounts"
}

# profile ID...: write the test profile
profile() { printf '%s\n' "$@" > "$LAB/profiles/test.profile"; }

# hosts GROUP: list this host in the hosts file, with the test profile
hosts() { printf '%s %s test ubuntu\n' "$HOST" "$1" > "$ETC/hosts"; }

plan() { run bash "$LAB/labyrinth.sh" --profile test --root "$ROOT" --config "$ETC" "$@" observe; }

# apply [OPTION...]: apply the observe phase, with stdin from $ANSWERS
apply() {
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" --apply "$@" observe < "${ANSWERS:-/dev/null}"
}

# answers LINE...: the lines the operator types, in order
answers() {
  ANSWERS="$BATS_TEST_TMPDIR/answers"
  printf '%s\n' "$@" > "$ANSWERS"
}

# run_id: the run id from the last output
run_id() { grep -o 'run [0-9]\{8\}T[0-9]\{6\}Z-[0-9a-f]\{4\}' <<< "$output" | head -n 1 | cut -d' ' -f2; }

manifest() { cat "$ROOT/state/runs/$(run_id)/manifest.jsonl"; }
