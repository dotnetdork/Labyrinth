#!/usr/bin/env bats
# labyrinth.sh --complete WORD...: the hidden entry that tab completion calls
# (docs/Conventions.md section 3.1, Tab completion), and the bash completion
# file in core/completion that calls it.

load lab_helper

setup() {
  lab_setup
  hosts ring1
  profile observe.toggle
  mkdir -p "$LAB/phases/lockout/modules" "$ETC/profiles"
  cp -R "$REPO/tests/fixtures/modules/recorder" "$LAB/phases/lockout/modules/inventory"
  mkdir -p "$ROOT/state"
}

# comp WORD...: the candidates for the last WORD, with the test's data root
# and configuration folder on the line.
comp() { run bash "$LAB/labyrinth.sh" --complete --root "$ROOT" --config "$ETC" "$@" < /dev/null; }

# bare WORD...: the same without a data root on the line.
bare() { run bash "$LAB/labyrinth.sh" --complete "$@" < /dev/null; }

# run_dir ID: a run on this host.
run_dir() { mkdir -p "$ROOT/state/runs/$1"; : > "$ROOT/state/runs/$1/manifest.jsonl"; }

# has CANDIDATE: the candidate is one of the output lines.
has() { grep -qxF -- "$1" <<< "$output"; }

# snapshot: every path of the test trees with its size and time, then every
# file's SHA-256: equal before and after means nothing was written.
snapshot() {
  find "$LAB" "$ROOT" "$ETC" -printf '%p %y %s %T@\n' | LC_ALL=C sort
  find "$LAB" "$ROOT" "$ETC" -type f -exec sha256sum {} + | LC_ALL=C sort
}

@test "a lone dash offers the actions and options, short and long" {
  bare -
  [ "$status" -eq 0 ]
  for c in -r --run -k --keep -u --undo -V --version -h --help -P --profile --history --show --probe \
      --new-seed --seed-check --manual --root --config --only --skip; do
    has "$c" || { echo "missing $c"; return 1; }
  done
  # Options that fit only after an action are not offered before it.
  ! has --all
  ! has --no-revert
  ! has -y
}

@test "two dashes offer the long names that begin with the rest" {
  bare --h
  [ "$status" -eq 0 ]
  [ "$output" = $'--history\n--help' ]
  bare --RU
  [ "$output" = '--run' ]
  bare -r --no-r
  [ "$output" = '--no-revert' ]
}

@test "the options offered fit the action on the line" {
  bare -u 4f2a --
  has --all
  has --yes
  ! has --only
  ! has --new-seed
  ! has --undo
  bare -r lockout --
  has --no-revert
  has --only
  has --skip
  has --profile
  has --break-glass
  has --confirm-group
  has --approve
  ! has --all
  bare lockout --only lockout.inventory --
  has --profile
  ! has --skip
  ! has --only
  ! has --history
}

@test "an option already on the line is not offered again" {
  bare --root /x --
  ! has --root
  has --config
}

@test "-k, -u and --show may be left without an ID, so an option can follow" {
  bare -k --r
  [ "$output" = '--root' ]
}

@test "nothing, or a phase prefix, at the start offers the phases and the actions" {
  bare ''
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = lockout ]
  [ "${lines[1]}" = observe ]
  [ "${lines[2]}" = deceive ]
  [ "${lines[3]}" = sustain ]
  has --run
  has --keep
  has --manual
  ! has --root
  ! has --all
  bare ob
  [ "$output" = observe ]
  bare OB
  [ "$output" = observe ]
}

@test "a phase typed already means no second phase is offered" {
  bare observe ''
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "after -r, the phases, before or after it" {
  bare -r ''
  [ "$status" -eq 0 ]
  [ "$output" = $'lockout\nobserve\ndeceive\nsustain' ]
  bare -r s
  [ "$output" = sustain ]
  bare --run ''
  [ "$output" = $'lockout\nobserve\ndeceive\nsustain' ]
  bare -rP test ''
  [ "$output" = $'lockout\nobserve\ndeceive\nsustain' ]
  bare lockout -r ''
  [ -z "$output" ]
}

@test "no phase is offered after an action that takes an ID" {
  bare -k 4f2a ''
  [ -z "$output" ]
  bare --history ''
  [ -z "$output" ]
}

@test "after -P, the profile names from the configuration folder and the release" {
  printf 'observe.toggle\n' > "$ETC/profiles/event.profile"
  printf 'observe.toggle\n' > "$ETC/profiles/test.profile"
  comp -P ''
  [ "$status" -eq 0 ]
  [ "$output" = $'event\ntest' ]
  comp --profile e
  [ "$output" = event ]
  comp -r -P T
  [ "$output" = test ]
  comp -rP ''
  [ "$output" = $'event\ntest' ]
  comp -P nomatch
  [ -z "$output" ]
}

@test "after -k, -u and --show, the run IDs, newest first, as their last 4 characters" {
  run_dir 20261001T000000Z-aaaa
  run_dir 20261003T090000Z-9b1c
  run_dir 20261002T140301Z-4f2a
  # A folder with no manifest is a plan's leftover, not a run.
  mkdir -p "$ROOT/state/runs/20261004T000000Z-dead"
  for w in -k --keep -u --undo --show; do
    comp "$w" ''
    [ "$status" -eq 0 ]
    [ "$output" = $'9b1c\n4f2a\naaaa' ] || { echo "$w: $output"; return 1; }
  done
}

@test "a run whose last 4 characters another run shares is offered whole" {
  run_dir 20261001T000000Z-4f2a
  run_dir 20261002T140301Z-4f2a
  run_dir 20261003T090000Z-9b1c
  comp -k ''
  [ "$output" = $'9b1c\n20261002T140301Z-4f2a\n20261001T000000Z-4f2a' ]
}

@test "text typed after -k matches whole IDs, and the 4 characters of an unshared run" {
  run_dir 20261002T140301Z-4f2a
  run_dir 20261003T090000Z-9b1c
  comp -k 20261002
  [ "$output" = 20261002T140301Z-4f2a ]
  comp -u 9b
  [ "$output" = 9b1c ]
  comp -u zz
  [ -z "$output" ]
}

@test "a run ID already given is not completed again" {
  run_dir 20261003T090000Z-9b1c
  comp -k 9b1c ''
  [ -z "$output" ]
}

@test "after -h, the topics: actions, options, phases, basics and module IDs" {
  bare -h ''
  [ "$status" -eq 0 ]
  for c in run keep undo history show probe new-seed seed-check version manual all profile root config \
      break-glass confirm-group approve yes no-revert only skip basics lockout observe deceive sustain \
      observe.toggle lockout.inventory; do
    has "$c" || { echo "missing $c"; return 1; }
  done
  ! has help
  bare --help und
  [ "$output" = undo ]
  bare -h lockout.
  [ "$output" = lockout.inventory ]
  # A topic is already there, or an action is: nothing more.
  bare -h undo ''
  [ -z "$output" ]
  bare -u -h ''
  [ -z "$output" ]
}

@test "after --only and --skip, the module IDs of the phase on the line" {
  bare lockout --only ''
  [ "$status" -eq 0 ]
  [ "$output" = lockout.inventory ]
  bare -r observe --skip observe.t
  [ "$output" = observe.toggle ]
  bare --only ''
  has lockout.inventory
  has observe.toggle
  bare observe --only lockout.
  [ -z "$output" ]
}

@test "a comma list is completed one ID at a time and the candidates carry the list" {
  bare observe --only observe.toggle,
  [ "$status" -eq 0 ]
  has observe.toggle,observe.sample
  ! has observe.toggle,observe.toggle
  ! has observe.toggle
  bare observe --skip observe.toggle,observe.sa
  [ "$output" = observe.toggle,observe.sample ]
}

@test "nothing is offered after a lone --, or for a value that has an equals sign" {
  bare -- ''
  [ -z "$output" ]
  bare -r -- ''
  [ -z "$output" ]
  bare --root=/x
  [ -z "$output" ]
  bare --profile=te
  [ -z "$output" ]
}

@test "values that are free text offer nothing" {
  for w in --root --config --break-glass --confirm-group --approve; do
    bare "$w" ''
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "--root and --config on the line say where profiles and runs are read" {
  local other="$BATS_TEST_TMPDIR/other"
  mkdir -p "$other/state/runs/20261005T000000Z-c0de" "$other/etc/profiles"
  : > "$other/state/runs/20261005T000000Z-c0de/manifest.jsonl"
  printf 'observe.toggle\n' > "$other/etc/profiles/elsewhere.profile"
  bare --root "$other" -k ''
  [ "$output" = c0de ]
  bare --root "$other" -P ''
  [ "$output" = $'elsewhere\ntest' ]
  bare --config "$other/etc" -P ''
  [ "$output" = $'elsewhere\ntest' ]
}

@test "nothing is written, locked or logged" {
  run_dir 20261003T090000Z-9b1c
  local before after
  before="$(snapshot)"
  for w in '' - -- -r -k -u -P --only -h; do comp "$w" ''; [ "$status" -eq 0 ]; done
  comp -k ''
  comp -r -P ''
  comp --only observe.toggle,
  after="$(snapshot)"
  [ "$before" = "$after" ]
  [ ! -e "$ROOT/state/lock" ]
  [ ! -d "$ROOT/logs" ] || [ -z "$(ls -A "$ROOT/logs")" ]
}

@test "it prints only candidates: nothing on the error stream, and only plain text" {
  run_dir 20261003T090000Z-9b1c
  mkdir -p "$ROOT/state/runs/$(printf '20261003T090000Z-\033[31m')"
  mkdir -p "$LAB/phases/observe/modules/$(printf 'bad\033[31mname')"
  : > "$LAB/phases/observe/modules/$(printf 'bad\033[31mname')/module.yml"
  local out err
  out="$(bash "$LAB/labyrinth.sh" --complete --root "$ROOT" -k '' 2> "$BATS_TEST_TMPDIR/err" < /dev/null)"
  err="$(cat "$BATS_TEST_TMPDIR/err")"
  [ -z "$err" ]
  [ "$out" = 9b1c ]
  out="$(bash "$LAB/labyrinth.sh" --complete -h '' 2> "$BATS_TEST_TMPDIR/err" < /dev/null)"
  [ -z "$(cat "$BATS_TEST_TMPDIR/err")" ]
  if grep -q $'\033' <<< "$out"; then return 1; fi
  if grep -qv '^[A-Za-z0-9._,:-]*$' <<< "$out"; then return 1; fi
}

@test "a data root that is missing or cannot be read gives no run IDs, and no error" {
  local out err
  out="$(bash "$LAB/labyrinth.sh" --complete --root "$BATS_TEST_TMPDIR/no-such-root" -k '' 2> "$BATS_TEST_TMPDIR/err" < /dev/null)" || return 1
  err="$(cat "$BATS_TEST_TMPDIR/err")"
  [ -z "$out" ]
  [ -z "$err" ]
  if [ "$(id -u)" -ne 0 ]; then
    run_dir 20261003T090000Z-9b1c
    chmod 000 "$ROOT/state"
    out="$(bash "$LAB/labyrinth.sh" --complete --root "$ROOT" -u '' 2> "$BATS_TEST_TMPDIR/err" < /dev/null)" || { chmod 700 "$ROOT/state"; return 1; }
    err="$(cat "$BATS_TEST_TMPDIR/err")"
    chmod 700 "$ROOT/state"
    [ -z "$out" ]
    [ -z "$err" ]
  fi
}

@test "an unreadable data root does not stop the other candidates" {
  bare --root "$BATS_TEST_TMPDIR/no-such-root" -r ''
  [ "$output" = $'lockout\nobserve\ndeceive\nsustain' ]
  bare --root "$BATS_TEST_TMPDIR/no-such-root" -P ''
  [ "$output" = test ]
}

@test "it runs with no release check and loads none of the core" {
  # A changed core file stops every other command (exit 20).
  bash "$REPO/tools/release/manifest.sh" "$LAB" > /dev/null
  printf 'touch "%s/ran"\n' "$BATS_TEST_TMPDIR" >> "$LAB/core/lib.sh"
  bare -r ''
  [ "$status" -eq 0 ]
  [ "$output" = $'lockout\nobserve\ndeceive\nsustain' ]
  run bash "$LAB/labyrinth.sh" -V
  [ "$status" -eq 20 ]
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
  # No core file is needed to answer.
  rm -rf "$LAB/core"
  bare -r ''
  [ "$status" -eq 0 ]
  [ "$output" = $'lockout\nobserve\ndeceive\nsustain' ]
}

@test "it is not an option: help does not list it, and it is not offered" {
  run bash "$LAB/labyrinth.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" != *complete* ]]
  [ "$(wc -l <<< "$output")" -le 24 ]
  bare -
  ! has --complete
  run bash "$LAB/labyrinth.sh" lockout --complete
  [ "$status" -eq 40 ]
}

# The bash completion file, called the way bash-completion calls it.

# bash_complete LINE: the completion of LINE in a bash that has the file
# loaded, with a laby on the PATH that is this test's runner. Words are split
# on spaces; a trailing space means the next word is empty.
bash_complete() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '%s\n' '#!/bin/bash' "exec bash \"$LAB/labyrinth.sh\" \"\$@\"" > "$BATS_TEST_TMPDIR/bin/laby"
  chmod +x "$BATS_TEST_TMPDIR/bin/laby"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" LINE="$1" ROOT="$ROOT" ETC="$ETC" REPO="$REPO" bash -c '
    source "$REPO/core/completion/laby.sh"
    read -r -a COMP_WORDS <<< "$LINE"
    if [[ "$LINE" == *" " ]]; then COMP_WORDS+=(""); fi
    COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 ))
    _laby_complete
    printf "%s\n" "${COMPREPLY[@]}"
  '
}

@test "the bash completion file offers what --complete prints" {
  run_dir 20261003T090000Z-9b1c
  bash_complete 'laby -r '
  [ "$status" -eq 0 ]
  [ "$output" = $'lockout\nobserve\ndeceive\nsustain' ]
  bash_complete 'laby --h'
  [ "$output" = $'--history\n--help' ]
  bash_complete "laby --root $ROOT -k "
  [ "$output" = 9b1c ]
}

@test "the bash completion file registers laby and labyrinth, each file for its own name" {
  run bash -c 'source "$1"; complete -p laby labyrinth' _ "$REPO/core/completion/laby.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-F _laby_complete laby"* ]]
  [[ "$output" == *"-F _laby_complete labyrinth"* ]]
  mkdir -p "$BATS_TEST_TMPDIR/cdir"
  cp "$REPO/core/completion/laby.sh" "$BATS_TEST_TMPDIR/cdir/laby"
  run bash -c 'source "$1"; complete -p laby labyrinth' _ "$BATS_TEST_TMPDIR/cdir/laby"
  [[ "$output" == *"-F _laby_complete laby"* ]]
  [[ "$output" == *"no completion specification"* ]]
}

@test "the bash completion file runs nothing that is not on the PATH" {
  run env PATH="/usr/bin:/bin" LINE='x' REPO="$REPO" bash -c '
    source "$REPO/core/completion/laby.sh"
    COMP_WORDS=(./laby -r ""); COMP_CWORD=2
    _laby_complete
    printf "%s\n" "${#COMPREPLY[@]}"
  '
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]
}
