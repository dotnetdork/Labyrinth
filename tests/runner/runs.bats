#!/usr/bin/env bats
# labyrinth.sh --history, and naming a run by its last 4 characters
# (docs/Conventions.md section 3.1).

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

@test "--history with no runs says so, exits 0 and creates nothing" {
  lab --history
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'no runs on this host' ]
  [ "${lines[1]}" = "Runs are recorded in $ROOT/state/runs" ]
  [ ! -e "$ROOT" ]
}

@test "--history needs root" {
  touch "$LAB/NOT_ADMIN"
  lab --history
  [ "$status" -eq 20 ]
}

@test "--history shows each state, in run ID order, within 78 columns" {
  local a b c
  a="$(armed_run)"
  b="$(armed_run)"; lab -k "$b"; [ "$status" -eq 0 ]
  c="$(armed_run)"; lab -u "$c"; [ "$status" -eq 0 ]
  lab --history
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == 'RUN                   PHASE   START (UTC)      STATE' ]]
  # Runs started in the same second sort by their random suffix, so each
  # run's line is found by its ID.
  [[ "$(grep "^$a " <<< "$output")" == "$a observe "*" armed: undo at "??:??" UTC" ]]
  [[ "$(grep "^$b " <<< "$output")" == "$b observe "*" kept" ]]
  [[ "$(grep "^$c " <<< "$output")" == "$c observe "*" undone" ]]
  [[ "$(grep "^$a " <<< "$output")" == *" ${a:0:4}-${a:4:2}-${a:6:2} ${a:9:2}:${a:11:2} "* ]]
  printf '%s\n' "${lines[@]:1:3}" | LC_ALL=C sort -c
  [[ "$output" == *"like '$SELF -k ${a: -4}'"* ]]
  # A hint may be longer by the length of the command in it.
  [ "$(awk '{ if (length > w) w = length } END { print w }' <<< "${output//$SELF/labyrinth.sh}")" -le 78 ]
}

@test "an armed run shows when its timer was due, or that the time is unknown" {
  local a
  a="$(armed_run)"
  printf '2000-01-01T00:05:00Z\n' > "$ROOT/state/runs/$a/timer-due"
  lab --history
  [[ "$output" == *"armed: was due 00:05 UTC"* ]]
  rm "$ROOT/state/runs/$a/timer-due"
  lab --history
  [[ "$output" == *"armed: undo time unknown"* ]]
}

@test "an armed run whose timer systemd lost says so, and can still be kept" {
  local a
  a="$(armed_run)"
  touch "$LAB/TIMER_LOST"
  lab --history
  [ "$status" -eq 0 ]
  [[ "$(grep "^$a " <<< "$output")" == *" armed: timer lost" ]]
  lab -k "$a"
  [ "$status" -eq 0 ]
  lab --history
  [[ "$(grep "^$a " <<< "$output")" == *" kept" ]]
}

@test "a run named by its last 4 characters, in any case, is kept" {
  local a
  a="$(armed_run)"
  lab -k "$(tr a-f A-F <<< "${a: -4}")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"using run $a"* ]]
  [[ "$output" == *"kept: the revert timer for run $a is cancelled"* ]]
}

@test "a suffix that matches no run, or more than one, is refused" {
  local a twin
  a="$(armed_run)"
  lab -u beef
  [ "$status" -eq 40 ]
  [[ "$output" == *"no run ending in 'beef'"* ]]
  twin="20000101T000000Z-${a: -4}"
  cp -R "$ROOT/state/runs/$a" "$ROOT/state/runs/$twin"
  lab -u "${a: -4}"
  [ "$status" -eq 40 ]
  [[ "$output" == *"ends more than one run"* ]]
  grep -qx 'setting=on' "$LAB/toggle.conf"
}

@test "-k without a run lists the armed runs and keeps none" {
  local a
  a="$(armed_run)"
  streams -k
  [ "$CODE" -eq 40 ]
  [[ "$ERR" == *"$a"*"-k needs a run ID, or its last 4 characters"* ]]
  [[ "$ERR" == *"pick one from the list above"* ]]
  [ -f "$ROOT/state/runs/$a/timer" ]
}

@test "-k without a run: with none armed it is still a usage error; with several, all are listed" {
  streams -k
  [ "$CODE" -eq 40 ]
  [[ "$ERR" == *"-k needs a run ID, or its last 4 characters"* ]]
  [[ "$ERR" == *"No run on this host has an armed revert timer."* ]]
  local a b
  a="$(armed_run)"
  b="$(armed_run)"
  streams -k
  [ "$CODE" -eq 40 ]
  [[ "$ERR" == *"$a"* && "$ERR" == *"$b"* ]]  # in run ID order, not start order
  [ -f "$ROOT/state/runs/$a/timer" ]
  [ -f "$ROOT/state/runs/$b/timer" ]
}

@test "-u without a run lists the runs and changes nothing" {
  local a
  a="$(armed_run)"
  streams -u
  [ "$CODE" -eq 40 ]
  [[ "$ERR" == *"$a"*"-u needs a run ID"* ]]
  grep -qx 'setting=on' "$LAB/toggle.conf"
  [ -f "$ROOT/state/runs/$a/timer" ]
}

@test "a full run ID is accepted in any case" {
  local a
  a="$(armed_run)"
  lab -k "$(tr a-f A-F <<< "$a")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept: the revert timer for run $a is cancelled"* ]]
}

@test "a reference that is neither an ID nor 4 hex characters is a usage error" {
  lab -k 4f2
  [ "$status" -eq 40 ]
  lab -u zzzz
  [ "$status" -eq 40 ]
  [ ! -e "$ROOT" ]
}
