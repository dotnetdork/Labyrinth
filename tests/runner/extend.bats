#!/usr/bin/env bats
# labyrinth.sh --extend ID: it adds one timer length (REVERT_MINUTES) to the
# time left on a run's revert timer, only for a run whose timer is armed,
# and records each extension (docs/Conventions.md section 3.1). The revert
# timer itself is a test double (tests/fixtures/doubles.sh), which writes
# the time it would fire to timer-due and each arming to $LAB/timer.log.

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

# fire_in RUN SECONDS: make the run's timer fire SECONDS from now.
fire_in() { date -u -d "+$2 seconds" +%Y-%m-%dT%H:%M:%SZ > "$ROOT/state/runs/$1/timer-due"; }

# left RUN: the whole seconds until the run's timer-due.
left() { echo $(( $(date -u -d "$(cat "$ROOT/state/runs/$1/timer-due")" +%s) - $(date +%s) )); }

# arms: how many times a timer was armed, in $LAB/timer.log.
arms() { grep -c '^arm ' "$LAB/timer.log"; }

@test "extending adds one timer length to the time left, and a second extension adds another" {
  local a n
  a="$(armed_run)"
  fire_in "$a" 120
  lab --extend "$a"
  [ "$status" -eq 0 ]
  [[ "$output" =~ Timer:\ \ now\ fires\ ([0-9]{2}:[0-9]{2})\ UTC\ \(in\ 7\ minutes\) ]]
  [ "${BASH_REMATCH[1]}" = "$(cut -c12-16 "$ROOT/state/runs/$a/timer-due")" ]
  n="$(left "$a")"
  [ "$n" -ge 415 ] && [ "$n" -le 425 ]
  # The timer was armed again for the time left plus 5 minutes.
  [[ "$(tail -n 1 "$LAB/timer.log")" =~ ^arm\ $a\ 4[0-2][0-9]$ ]]
  lab --extend "$a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(in 12 minutes)"* ]]
  n="$(left "$a")"
  [ "$n" -ge 715 ] && [ "$n" -le 725 ]
  [[ "$(tail -n 1 "$LAB/timer.log")" =~ ^arm\ $a\ 7[0-2][0-9]$ ]]
}

@test "the timer length is REVERT_MINUTES from event.conf" {
  local a
  a="$(armed_run)"
  printf 'REVERT_MINUTES=3\n' > "$ETC/event.conf"
  fire_in "$a" 60
  lab --extend "$a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(in 4 minutes)"* ]]
  [[ "$(tail -n 1 "$LAB/timer.log")" =~ ^arm\ $a\ 2[34][0-9]$ ]]
}

@test "a timer past due, or with no known time, is set one timer length from now" {
  local a
  a="$(armed_run)"
  printf '2000-01-01T00:05:00Z\n' > "$ROOT/state/runs/$a/timer-due"
  lab --extend "$a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(in 5 minutes)"* ]]
  rm "$ROOT/state/runs/$a/timer-due"
  lab --extend "$a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(in 5 minutes)"* ]]
}

@test "it prints the new time and the keep command, written the way the runner was started" {
  local a
  a="$(armed_run)"
  lab --extend "${a: -4}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"using run $a"* ]]
  [[ "$output" == *$'\nTimer:  now fires '* ]]
  [[ "$output" == *$'\nNext:   '"$SELF -k ${a: -4}"* ]]
  run env SUDO_USER=someone bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" --extend "$a" < /dev/null
  [[ "$output" == *"Next:   sudo $SELF -k ${a: -4}"* ]]
  # Not kept, not undone: the changes and the timer stay.
  grep -qx 'setting=on' "$LAB/toggle.conf"
  [ -f "$ROOT/state/runs/$a/timer" ]
}

@test "the timer is armed again with the command that undoes the run" {
  local a
  a="$(armed_run)"
  lab --extend "$a"
  [ "$status" -eq 0 ]
  [[ "$(cat "$ROOT/state/runs/$a/timer")" == *"labyrinth.sh --root "*" --config "*" -u $a" ]]
}

@test "a kept run is refused, and nothing is armed" {
  local a before
  a="$(armed_run)"
  lab -k "$a"
  [ "$status" -eq 0 ]
  before="$(arms)"
  lab --extend "$a"
  [ "$status" -eq 20 ]
  [[ "$output" == *"run $a was already kept, so it has no revert timer to extend"* ]]
  [ "$(arms)" -eq "$before" ]
  [ ! -f "$ROOT/state/runs/$a/timer" ]
  [[ "$(cat "$ROOT/state/runs/$a/manifest.jsonl")" != *timer_extended* ]]
}

@test "an undone run is refused, like -k" {
  local a before
  a="$(armed_run)"
  lab -u "$a"
  [ "$status" -eq 0 ]
  before="$(arms)"
  lab --extend "$a"
  [ "$status" -eq 20 ]
  [[ "$output" == *"too late: run $a was already undone"* ]]
  [ "$(arms)" -eq "$before" ]
  [[ "$(cat "$ROOT/state/runs/$a/manifest.jsonl")" != *timer_extended* ]]
}

@test "a run made with --no-revert is refused, and the message gives the undo command" {
  local a
  answers root ring1
  apply --no-revert
  [ "$status" -eq 0 ]
  a="$(run_id)"
  lab --extend "$a"
  [ "$status" -eq 20 ]
  [[ "$output" == *"run $a has no revert timer (--no-revert), so there is nothing to extend"* ]]
  [[ "$output" == *"To undo it: $SELF -u ${a: -4}"* ]]
  [ ! -e "$LAB/timer.log" ]
  [[ "$(cat "$ROOT/state/runs/$a/manifest.jsonl")" != *timer_extended* ]]
}

@test "a run with no armed timer at all is refused" {
  local a
  a="$(armed_run)"
  rm "$ROOT/state/runs/$a/timer"
  lab --extend "$a"
  [ "$status" -eq 20 ]
  [[ "$output" == *"run $a has no armed revert timer to extend"* ]]
}

@test "a run whose timer systemd lost gets a new timer" {
  local a
  a="$(armed_run)"
  touch "$LAB/TIMER_LOST"
  lab --extend "$a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(in 5 minutes)"* || "$output" == *"(in 10 minutes)"* ]]
}

@test "a time after the ID is a usage error and arms nothing" {
  local a before
  a="$(armed_run)"
  before="$(arms)"
  lab --extend "$a" 10
  [ "$status" -eq 40 ]
  [[ "$output" == *"$LAB/labyrinth.sh: --extend takes no time: each call adds one timer length"* ]]
  [[ "$output" == *"To add more, run it again: $SELF --extend $a"* ]]
  [[ "$output" == *"Try '$SELF --extend -h'."* ]]
  lab --extend "${a: -4}" 10m
  [ "$status" -eq 40 ]
  [ "$(arms)" -eq "$before" ]
}

@test "--extend without an ID lists the armed runs and extends none" {
  local a before
  a="$(armed_run)"
  before="$(arms)"
  CODE=0
  OUT="$(bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" --extend 2> "$BATS_TEST_TMPDIR/err" < /dev/null)" || CODE=$?
  ERR="$(cat "$BATS_TEST_TMPDIR/err")"
  [ "$CODE" -eq 40 ]
  [[ "$ERR" == *"$a"*"--extend needs a run ID, or its last 4 characters"* ]]
  [[ "$ERR" == *"pick one from the list above"* ]]
  [ "$(arms)" -eq "$before" ]
}

@test "--extend without an ID and no armed run is still a usage error" {
  lab --extend
  [ "$status" -eq 40 ]
  [[ "$output" == *"--extend needs a run ID, or its last 4 characters"* ]]
  [[ "$output" == *"No run on this host has an armed revert timer."* ]]
}

@test "--extend needs root, and a run that does not exist is an error" {
  local a
  a="$(armed_run)"
  touch "$LAB/NOT_ADMIN"
  lab --extend "$a"
  [ "$status" -eq 20 ]
  [[ "$output" == *"--extend needs root"* ]]
  rm "$LAB/NOT_ADMIN"
  lab --extend beef
  [ "$status" -eq 40 ]
  [[ "$output" == *"no run ending in 'beef'"* ]]
}

@test "an event.conf that is malformed is an error and arms nothing" {
  local a before
  a="$(armed_run)"
  before="$(arms)"
  printf 'REVERT_MINUTES=soon\n' > "$ETC/event.conf"
  lab --extend "$a"
  [ "$status" -eq 40 ]
  [[ "$output" == *"event.conf is malformed"* ]]
  [ "$(arms)" -eq "$before" ]
}

@test "a failed re-arm leaves the earlier timer as it was, exits 40 and records nothing" {
  local a timer due
  a="$(armed_run)"
  fire_in "$a" 120
  timer="$(cat "$ROOT/state/runs/$a/timer")"
  due="$(cat "$ROOT/state/runs/$a/timer-due")"
  printf '%s\n' 'lab_timer_arm() { return 1; }' >> "$LAB/core/lib.sh"
  lab --extend "$a"
  [ "$status" -eq 40 ]
  [[ "$output" == *"the revert timer for run $a could not be extended"* ]]
  [[ "$output" == *"The earlier timer is unchanged and still undoes the run at "* ]]
  [[ "$output" == *"Retry: $SELF --extend ${a: -4}"* ]]
  [ "$(cat "$ROOT/state/runs/$a/timer")" = "$timer" ]
  [ "$(cat "$ROOT/state/runs/$a/timer-due")" = "$due" ]
  [[ "$(cat "$ROOT/state/runs/$a/manifest.jsonl")" != *timer_extended* ]]
}

@test "each extension is in the run log, the manifest and the event log" {
  local a m
  a="$(armed_run)"
  lab --extend "$a"
  [ "$status" -eq 0 ]
  lab --extend "$a"
  [ "$status" -eq 0 ]
  m="$(cat "$ROOT/state/runs/$a/manifest.jsonl")"
  [ "$(grep -c '"action":"timer_extended"' <<< "$m")" -eq 2 ]
  [[ "$m" == *'"action":"timer_extended"'*'"note":"added 5 minutes; now fires 20'* ]]
  # The run log: a first line for each extension, and what it printed.
  [ "$(grep -c ': extend run '"$a" "$ROOT/state/runs/$a/output.log")" -eq 2 ]
  [ "$(grep -c '^Timer:  now fires ' "$ROOT/state/runs/$a/output.log")" -eq 2 ]
  [[ "$output" == *"Log: $ROOT/state/runs/$a/output.log"* ]]
  [ "$(cat "$ROOT"/logs/run/*.jsonl | grep -c '"event":"timer_extended"')" -eq 2 ]
}

@test "--history, the status and --show give the new fire time" {
  local a due at
  a="$(armed_run)"
  fire_in "$a" 120
  lab --extend "$a"
  [ "$status" -eq 0 ]
  due="$(cat "$ROOT/state/runs/$a/timer-due")"
  at="${due:11:5}"
  lab --history
  [[ "$(grep "^$a " <<< "$output")" == *" armed: undo at $at UTC" ]]
  lab
  [[ "$output" == *"Timer:    run ${a: -4} is undone at $at UTC, in 7 minutes"* ]]
  lab --show "$a"
  [[ "$output" == *"State:     armed: undo at $at UTC"* ]]
}

@test "extending a run does not touch another run's timer" {
  local a b
  a="$(armed_run)"
  b="$(armed_run)"
  fire_in "$a" 120
  fire_in "$b" 120
  lab --extend "$a"
  [ "$status" -eq 0 ]
  [ "$(left "$b")" -le 120 ]
  [ "$(left "$a")" -ge 415 ]
}

@test "a revert timer that fires after an extension still undoes the run, and extending it then is too late" {
  local a
  a="$(armed_run)"
  lab --extend "$a"
  [ "$status" -eq 0 ]
  # The command the timer runs.
  lab -u "$a"
  [ "$status" -eq 0 ]
  [ ! -e "$LAB/toggle.conf" ]
  lab --extend "$a"
  [ "$status" -eq 20 ]
}
