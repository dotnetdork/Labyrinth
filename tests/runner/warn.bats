#!/usr/bin/env bats
# The warning before the revert timer undoes a run: every run that arms the
# timer arms a warning with it, --extend moves it, -k and -u remove it, and
# the hidden entry 'labyrinth.sh --warn' the warning's own timer runs tells
# whoever is logged in (docs/Conventions.md section 3.1). The timer, the
# warning's arming and the notice are test doubles (tests/fixtures/doubles.sh),
# which record each arming of the warning in $LAB/warn.log and each notice in
# $LAB/notice.log. Warn.Tests.ps1 checks the same for labyrinth.ps1.

load lab_helper

setup() {
  lab_setup
  hosts ring1
  profile observe.toggle
}

lab() { run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" "$@" < /dev/null; }

# armed_run: apply, leave the revert timer armed, and print the run ID.
armed_run() {
  rm -f "$LAB/toggle.conf"
  if [ -d "$ROOT/state/runs" ]; then answers ring1 no; else answers root ring1 no; fi
  apply
  [ "$status" -eq 0 ]
  run_id
}

# fire_in RUN SECONDS: make the run's timer fire SECONDS from now.
fire_in() { date -u -d "+$2 seconds" +%Y-%m-%dT%H:%M:%SZ > "$ROOT/state/runs/$1/timer-due"; }

# warn RUN [NAME]: what the warning's timer runs
warn() { run bash "$LAB/labyrinth.sh" --warn "$1" "$ROOT" "$ETC" "${2:-sudo laby}" < /dev/null; }

# arms: how many times the warning was armed, in $LAB/warn.log.
arms() { grep -c '^arm ' "$LAB/warn.log"; }

@test "an apply arms the warning with the timer, for the same time, running the hidden entry" {
  local a
  a="$(armed_run)"
  [ "$(arms)" -eq 1 ]
  [[ "$(grep '^arm ' "$LAB/warn.log")" =~ ^arm\ $a\ 300\ .*labyrinth.sh\ --warn\ $a\ .*$ROOT\ .*$ETC\ sudo\ .*labyrinth.sh$ ]]
  [ -f "$ROOT/state/runs/$a/warn" ]
}

@test "the warning names the installed command when the run was started through it" {
  local a bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  ln -s "$LAB/labyrinth.sh" "$bin/laby"
  answers root ring1 no
  run env PATH="$bin:$PATH" laby --root "$ROOT" --config "$ETC" -r observe < "$ANSWERS"
  [ "$status" -eq 0 ]
  a="$(run_id)"
  [[ "$(grep '^arm ' "$LAB/warn.log")" == *" --warn $a "*" sudo laby" ]]
}

@test "a timer shorter than two minutes still gets a warning, at the halfway point" {
  local a
  printf 'REVERT_MINUTES=1\n' > "$ETC/event.conf"
  a="$(armed_run)"
  [[ "$(grep '^arm ' "$LAB/warn.log")" == "arm $a 60 "* ]]
  [ -f "$ROOT/state/runs/$a/warn" ]
}

@test "extending moves the warning with the timer" {
  local a before
  a="$(armed_run)"
  fire_in "$a" 120
  before="$(arms)"
  lab --extend "$a"
  [ "$status" -eq 0 ]
  [ "$(arms)" -eq $((before + 1)) ]
  [[ "$(grep '^arm ' "$LAB/warn.log" | tail -n 1)" =~ ^arm\ $a\ 4[0-2][0-9]\ .*--warn\ $a\  ]]
  [ -f "$ROOT/state/runs/$a/warn" ]
}

@test "keeping a run removes the warning" {
  local a
  a="$(armed_run)"
  lab -k "$a"
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT/state/runs/$a/warn" ]
  [ "$(tail -n 1 "$LAB/warn.log")" = "cancel $a" ]
}

@test "undoing a run, as the timer does, removes the warning" {
  local a
  a="$(armed_run)"
  lab -u "$a"
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT/state/runs/$a/warn" ]
  [ "$(tail -n 1 "$LAB/warn.log")" = "cancel $a" ]
}

@test "a warning that cannot be armed never stops the run, and the timer is still armed" {
  local a
  touch "$LAB/WARN_FAIL"
  answers root ring1 no
  apply
  [ "$status" -eq 0 ]
  a="$(run_id)"
  [[ "$output" == *"Note:      the warning before the undo was not set up; the timer is armed"* ]]
  [ -f "$ROOT/state/runs/$a/timer" ]
  [ ! -e "$ROOT/state/runs/$a/warn" ]
  grep -qx 'setting=on' "$LAB/toggle.conf"
  lab --extend "$a"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nNote:   the warning before the undo was not set up; the timer is armed'* ]]
  [[ "$output" == *$'\nNext:   '* ]]
}

@test "the warning names the run, the host, the time, and the keep and extend commands" {
  local a at
  a="$(armed_run)"
  fire_in "$a" 60
  at="$(cut -c12-16 "$ROOT/state/runs/$a/timer-due")"
  warn "$a" 'sudo laby'
  [ "$status" -eq 0 ]
  grep -qx "Labyrinth undoes run ${a: -4} on $HOST at $at UTC (in 1 minute)." "$LAB/notice.log"
  grep -qx "To keep it:      sudo laby -k ${a: -4} --root $ROOT --config $ETC" "$LAB/notice.log"
  grep -qx "To get 5 more:   sudo laby --extend ${a: -4} --root $ROOT --config $ETC" "$LAB/notice.log"
  # It changes nothing: the changes and the timer stay.
  grep -qx 'setting=on' "$LAB/toggle.conf"
  [ -f "$ROOT/state/runs/$a/timer" ]
  [[ "$(cat "$ROOT/state/runs/$a/manifest.jsonl")" != *timer_warned* ]]
}

@test "the extend command in the warning gives the timer length from event.conf" {
  local a
  printf 'REVERT_MINUTES=10\n' > "$ETC/event.conf"
  a="$(armed_run)"
  fire_in "$a" 60
  warn "$a"
  [ "$status" -eq 0 ]
  grep -qx "To get 10 more:  sudo laby --extend ${a: -4} --root $ROOT --config $ETC" "$LAB/notice.log"
}

@test "a short timer's warning says how many seconds are left" {
  local a
  a="$(armed_run)"
  fire_in "$a" 45
  warn "$a"
  [ "$status" -eq 0 ]
  grep -Eqx "Labyrinth undoes run ${a: -4} on $HOST at [0-9:]{5} UTC \(in (4[0-5]) seconds\)\." "$LAB/notice.log"
}

@test "the warning is recorded in the run log and the log of runs" {
  local a
  a="$(armed_run)"
  fire_in "$a" 60
  warn "$a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warned the sessions logged in that the revert timer undoes run $a in "* ]]
  grep -q ": warn run $a$" "$ROOT/state/runs/$a/output.log"
  grep -q 'warned the sessions logged in' "$ROOT/state/runs/$a/output.log"
  grep -q '"event":"timer_warned"' "$ROOT"/logs/run/*.jsonl
}

@test "a missing wall does not fail the warning, and the log says it was not sent" {
  local a
  a="$(armed_run)"
  fire_in "$a" 60
  touch "$LAB/NO_WALL"
  warn "$a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not warn the sessions logged in"* ]]
  [ ! -e "$LAB/notice.log" ]
  grep -q 'revert timer warning not sent' "$ROOT"/logs/run/*.jsonl
}

@test "no warning is sent for a run that is kept or undone, or whose timer is not near" {
  local a
  a="$(armed_run)"
  # Not due within a minute and a half: an earlier timer's warning, or a restart.
  fire_in "$a" 200
  warn "$a"
  [ "$status" -eq 0 ]
  [ ! -e "$LAB/notice.log" ]
  # Past due: the host was off past the warning, and the undo is on its way.
  printf '2000-01-01T00:05:00Z\n' > "$ROOT/state/runs/$a/timer-due"
  warn "$a"
  [ "$status" -eq 0 ]
  [ ! -e "$LAB/notice.log" ]
  # Kept: no timer.
  fire_in "$a" 60
  lab -k "$a"
  [ "$status" -eq 0 ]
  warn "$a"
  [ "$status" -eq 0 ]
  [ ! -e "$LAB/notice.log" ]
}

@test "the hidden entry needs root and a well-formed run, root and config folder" {
  local a
  a="$(armed_run)"
  fire_in "$a" 60
  touch "$LAB/NOT_ADMIN"
  warn "$a"
  [ "$status" -eq 20 ]
  rm "$LAB/NOT_ADMIN"
  run bash "$LAB/labyrinth.sh" --warn nonsense "$ROOT" "$ETC" 'sudo laby' < /dev/null
  [ "$status" -eq 40 ]
  run bash "$LAB/labyrinth.sh" --warn "$a" relative "$ETC" 'sudo laby' < /dev/null
  [ "$status" -eq 40 ]
  [ ! -e "$LAB/notice.log" ]
}

@test "the warning is not an action: help and completion do not offer it" {
  run bash "$LAB/labyrinth.sh" --complete --w
  [ "$status" -eq 0 ]
  [[ "$output" != *warn* ]]
  run bash "$LAB/labyrinth.sh" -h
  [[ "$output" != *--warn* ]]
}
