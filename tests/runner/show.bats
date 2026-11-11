#!/usr/bin/env bats
# labyrinth.sh --show ID: what one run changed, read from its manifest
# (docs/Conventions.md sections 3.1 and 7).

load lab_helper

setup() {
  lab_setup
  hosts ring1
  profile observe.toggle
}

lab() { run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" "$@" < /dev/null; }

# armed_run: apply, leave the revert timer armed, and print the run ID.
# Break-glass is asked only on the first apply.
armed_run() {
  rm -f "$LAB/toggle.conf"
  if [ -d "$ROOT/state/runs" ]; then answers ring1 no; else answers root ring1 no; fi
  apply
  [ "$status" -eq 0 ]
  run_id
}

# streams ARG...: run labyrinth.sh with stdout ($OUT) and stderr ($ERR) apart.
streams() {
  CODE=0
  OUT="$(bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" "$@" 2> "$BATS_TEST_TMPDIR/err" < /dev/null)" || CODE=$?
  ERR="$(cat "$BATS_TEST_TMPDIR/err")"
}

# narrow TEXT: every line is at most 78 columns, except a line that names a
# path under the test's folders (a path comes last and may run over).
narrow() {
  local l
  while IFS= read -r l; do
    [[ "$l" == *"$BATS_TEST_TMPDIR"* ]] && continue
    [ "${#l}" -le 78 ] || { echo "over 78 columns: $l"; return 1; }
  done <<< "$1"
}

@test "--show lists a run's header, its module and each change with its backup" {
  local a
  a="$(armed_run)"
  lab --show "$a"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Run $a" ]
  [[ "$output" == *$'\n'"  Phase:     observe"$'\n'* ]]
  [[ "$output" == *$'\n'"  Profile:   test"$'\n'* ]]
  [[ "$output" == *$'\n'"  Host:      $HOST"$'\n'* ]]
  [[ "$output" == *$'\n'"  Group:     ring1"$'\n'* ]]
  [[ "$output" =~ $'\n'"  Started:   "[0-9]{4}-[0-9]{2}-[0-9]{2}" "[0-9:]{8}" UTC"$'\n'"  Ended:     "[0-9]{4} ]]
  [[ "$output" == *$'\n'"  State:     armed: undo at "* ]]
  [[ "$output" == *$'\n\n'"Module: Toggle setting sample (observe.toggle)"$'\n'"  Status:    applied"$'\n'"  Change:    file_created $LAB/toggle.conf"$'\n'* ]]
  # The first run changed a file that did not exist: nothing to back up.
  printf 'before\n' > "$LAB/toggle.conf"
  answers ring1 no
  apply
  [ "$status" -eq 0 ]
  a="$(run_id)"
  lab --show "$a"
  [[ "$output" == *"  Change:    file $LAB/toggle.conf"$'\n'"  Before:    $(id -u):$(id -g) "*$'\n'"  Backup:    $ROOT/backup/$a/observe.toggle/"*"-toggle.conf"* ]]
  narrow "$output"
}

@test "--show ends with the run log's path, and names a run by its last 4 characters" {
  local a
  a="$(armed_run)"
  lab --show "${a: -4}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"using run $a"* ]]
  [ "${lines[-1]}" = "Log: $ROOT/state/runs/$a/output.log" ]
  [ -f "$ROOT/state/runs/$a/output.log" ]
}

@test "--show for a run that was undone says so and still lists its changes" {
  local a
  a="$(armed_run)"
  lab -u "$a"
  [ "$status" -eq 0 ]
  lab --show "$a"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n'"  State:     undone"$'\n'* ]]
  [[ "$output" == *"  Status:    undone"$'\n'"  Change:    file_created $LAB/toggle.conf"* ]]
  narrow "$output"
}

@test "--show for a run with a failed module says what failed and that it was undone" {
  local a
  touch "$LAB/FAIL_VERIFY"
  answers root ring1 keep
  apply
  [ "$status" -eq 30 ]
  a="$(run_id)"
  lab --show "$a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Module: Toggle setting sample (observe.toggle)"$'\n'"  Status:    failed (verify exit 30), then undone"$'\n'* ]]
  [[ "$output" == *"  Change:    file_created $LAB/toggle.conf"* ]]
  narrow "$output"
}

@test "--show for a module whose apply failed names the exit code" {
  local a
  touch "$LAB/FAIL_APPLY"
  answers root ring1 keep
  apply
  [ "$status" -eq 40 ]
  a="$(run_id)"
  lab --show "$a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"  Status:    failed (apply exit 40), then undone"* ]]
}

@test "--show for a module kept once verified says so" {
  local a
  profile observe.keeper
  printf 'web http web.test 80 -
' > "$ETC/services"
  answers root ring1
  apply
  [ "$status" -eq 0 ]
  a="$(run_id)"
  lab --show "$a"
  [[ "$output" == *"  Status:    kept once verified"* ]]
}

@test "--show never prints a secret: not a new password, nor a file a module backed up" {
  local a pw
  profile observe.rotate
  printf 'old-secret-value\n' > "$LAB/rotate.pw"
  printf 'recorded\n' > "$LAB/tty.in"
  answers root ring1 no
  apply
  [ "$status" -eq 0 ]
  a="$(run_id)"
  pw="$(sed -n 's/^      //p' "$LAB/tty.out")"
  [[ "$pw" =~ ^[A-Za-z0-9_.+=-]{20}$ ]]
  lab --show "$a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"  Change:    file $LAB/rotate.pw"* ]]
  [[ "$output" != *"$pw"* ]]
  [[ "$output" != *old-secret-value* ]]
  [[ "$output" != *"$(printf '%s' "$pw" | sha256sum | cut -c1-20)"* ]]
  narrow "$output"
}

@test "--show changes nothing: not the manifest, not the log, not the data root" {
  local a before after
  a="$(armed_run)"
  before="$(cd "$ROOT" && find . -type f -exec cksum {} + | sort)"
  lab --show "$a"
  [ "$status" -eq 0 ]
  after="$(cd "$ROOT" && find . -type f -exec cksum {} + | sort)"
  [ "$before" = "$after" ]
}

@test "--show with no runs asks for an ID and says there are none" {
  streams --show
  [ "$CODE" -eq 40 ]
  [[ "$ERR" == *"--show needs a run ID, or its last 4 characters"* ]]
  [[ "$ERR" == *"There are no runs on this host."* ]]
  [ -z "$OUT" ]
  [ ! -e "$ROOT" ]
}

@test "--show without an ID lists the runs and shows none" {
  local a
  a="$(armed_run)"
  streams --show
  [ "$CODE" -eq 40 ]
  [[ "$ERR" == *"$a"*"--show needs a run ID, or its last 4 characters"* ]]
  [[ "$ERR" == *"Pick one from the list above."* ]]
  [ -z "$OUT" ]
}

@test "--show needs root, and a run that does not exist points to --history" {
  local a
  a="$(armed_run)"
  lab --show 'beef'
  [ "$status" -eq 40 ]
  [[ "$output" == *"no run ending in 'beef'"* ]]
  [[ "$output" == *"--history"* ]]
  touch "$LAB/NOT_ADMIN"
  lab --show "$a"
  [ "$status" -eq 20 ]
  [[ "$output" == *"--show needs root"* ]]
}

@test "--show is refused with the options it does not use" {
  lab --show 4f2a --all
  [ "$status" -eq 40 ]
  [[ "$output" == *"is only for -u, not --show"* ]]
  lab --show 4f2a -y
  [ "$status" -eq 40 ]
  lab --show 4f2a --history
  [ "$status" -eq 40 ]
  [[ "$output" == *"two actions on one line"* ]]
}
