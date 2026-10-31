#!/usr/bin/env bats
# labyrinth.sh -h: the shape of the main help and of every topic, the ways to
# ask for one, that help never runs anything, and that the operator manual
# covers every action it lists (docs/Conventions.md sections 3.2 and 3.3).

load lab_helper

setup() { lab_setup; }

# Every topic with a page of its own: the actions, the options and the
# phases. Basics is the one screen that is longer.
ACTIONS='run keep undo history probe version manual'
OPTIONS='profile root config break-glass confirm-group approve all yes no-revert'
PHASES='lockout observe deceive sustain'
TOPICS="$ACTIONS $OPTIONS $PHASES"

# Help writes the name the runner was started by ('laby' or 'labyrinth' when
# started through the installed command). ask shows that name as 'laby', so the
# tests read the same as the
# manual; here starts the runner as ./labyrinth.sh and leaves the output as it
# is, for the limits on lines and columns, which hold with that name.

# ask ARG...: run labyrinth.sh with ARG..., which must print help
ask() {
  run bash "$LAB/labyrinth.sh" "$@" < /dev/null
  output="${output//"$LAB/labyrinth.sh"/laby}"
  mapfile -t lines <<< "$output"
}

# here ARG...: the same, started as ./labyrinth.sh from the runner's folder
here() { cd "$LAB" && run bash ./labyrinth.sh "$@" < /dev/null; }

@test "the main help is one screen: Usage, Actions and Options, the manual last" {
  here -h
  [ "$status" -eq 0 ]
  [ "$(wc -l <<< "$output")" -le 24 ]
  [ "$(awk '{ if (length > w) w = length } END { print w + 0 }' <<< "$output")" -le 78 ]
  [ "$(head -n 1 <<< "$output")" = 'Usage: ./labyrinth.sh PHASE                preview a phase: nothing changes' ]
  ask -h
  [ "$(head -n 1 <<< "$output")" = 'Usage: laby PHASE                preview a phase: nothing changes' ]
  grep -q '^Actions' <<< "$output"
  grep -q '^Options:' <<< "$output"
  [ "$(grep -c '^Exit: ' <<< "$output")" -eq 1 ]
  grep -q 'an action, option, phase or basics' <<< "$output"
  [ "$(tail -n 1 <<< "$output")" = 'Full manual: laby --manual   (Linux also: man laby)' ]
  grep -q "^       laby                      this host's status and next step$" <<< "$output"
}

@test "every topic is short, fits 78 columns, and has one Usage, one Exit, an Example and See also" {
  local t max
  for t in $TOPICS basics; do
    here -h "$t"
    [ "$status" -eq 0 ] || { echo "-h $t: exit $status"; return 1; }
    case "$t" in basics) max=24 ;; *) max=18 ;; esac
    [ "$(wc -l <<< "$output")" -le "$max" ] || { echo "-h $t: over $max lines"; return 1; }
    [ "$(awk '{ if (length > w) w = length } END { print w + 0 }' <<< "$output")" -le 78 ] \
      || { echo "-h $t: a line is over 78 columns"; return 1; }
    [[ "$(head -n 1 <<< "$output")" == 'Usage: ./labyrinth.sh '* ]] || { echo "-h $t: no Usage line"; return 1; }
    [ "$(grep -c '^Exit: ' <<< "$output")" -eq 1 ] || { echo "-h $t: Exit lines"; return 1; }
    [ "$(grep -c '^Example: ' <<< "$output")" -eq 1 ] || { echo "-h $t: Example lines"; return 1; }
    if [[ "$t" != basics ]]; then
      [ "$(grep -c '^See also: ' <<< "$output")" -eq 1 ] || { echo "-h $t: See also lines"; return 1; }
    fi
  done
}

@test "the help names the command the way the runner was started, as hints do" {
  here -h
  [[ "$output" == *'./labyrinth.sh -r PHASE'* ]]
  [ "$(tail -n 1 <<< "$output")" = 'Full manual: ./labyrinth.sh --manual   (Linux also: man laby)' ]
  ! grep -v 'man laby' <<< "$output" | grep -qw laby
  [[ "$output" != *@CMD@* ]]
  here -h run
  [[ "$output" == *'Example: ./labyrinth.sh -r lockout'* ]]
  ! grep -qw laby <<< "$output"
  run env SUDO_USER=someone bash ./labyrinth.sh -h run < /dev/null
  [[ "$output" == *'Example: sudo ./labyrinth.sh -r lockout'* ]]
  run bash "$LAB/labyrinth.sh" -h basics < /dev/null
  [[ "$output" == *"'$LAB/labyrinth.sh lockout'"* ]]
}

@test "an action, its long name and its topic word print the same page" {
  local a want
  ask -h run; want="$output"
  for a in '-r -h' '--run --help' '-h run' '--help RUN' '-h Run'; do
    # shellcheck disable=SC2086 # the words are split on purpose
    ask $a
    [ "$status" -eq 0 ] && [ "$output" = "$want" ] || { echo "$a"; return 1; }
  done
  ask -h undo; want="$output"
  for a in '-u -h' '--undo --help' '-u 4f2a -h' '-h -u'; do
    # shellcheck disable=SC2086
    ask $a
    [ "$status" -eq 0 ] && [ "$output" = "$want" ] || { echo "$a"; return 1; }
  done
  ask -h keep; want="$output"
  for a in '-k -h' '--keep --help' '-k=4f2a -h'; do
    # shellcheck disable=SC2086
    ask $a
    [ "$status" -eq 0 ] && [ "$output" = "$want" ] || { echo "$a"; return 1; }
  done
  ask -h history; want="$output"
  for a in '--history -h' '--history --help'; do
    # shellcheck disable=SC2086
    ask $a
    [ "$status" -eq 0 ] && [ "$output" = "$want" ] || { echo "$a"; return 1; }
  done
  ask -h observe; want="$output"
  for a in 'observe -h' 'observe --help' 'OBSERVE -h'; do
    # shellcheck disable=SC2086
    ask $a
    [ "$status" -eq 0 ] && [ "$output" = "$want" ] || { echo "$a"; return 1; }
  done
}

@test "-h, --help, /? and -? print the main help; typing nothing is the status, not the help" {
  local a want
  ask -h; want="$output"
  for a in --help /? '-?'; do
    ask "$a"
    [ "$status" -eq 0 ] && [ "$output" = "$want" ] || { echo "$a"; return 1; }
  done
  ask --root "$ROOT" --config "$ETC"
  [ "$status" -eq 0 ]
  [ "$output" != "$want" ]
  [[ "${lines[0]}" == 'labyrinth '*': status of host '* ]]
}

@test "help wins over everything else on the line, even a mistake" {
  local want
  ask -h observe; want="$output"
  ask observe bogus -h
  [ "$status" -eq 0 ] && [ "$output" = "$want" ]
  ask -u 4f2a -k 4f2a --bogus -h
  [ "$status" -eq 0 ]
  [[ "$(head -n 1 <<< "$output")" == 'Usage: laby -u ID'* ]]
  ask --root relative --profile 'a;b' -h
  [ "$status" -eq 0 ]
  [[ "$(head -n 1 <<< "$output")" == 'Usage: laby [-r] PHASE -P NAME' ]]
}

@test "help runs nothing: no data root, no configuration read, no root needed" {
  local f
  rm -rf "$ETC"
  touch "$LAB/NOT_ADMIN"
  for f in -h '-h run' '-r -h' '-u -h' '--history --help' '-h basics' '-h bogus' '-h observe.sample' \
      '--manual -h' '-h yes' '-h no-revert' '-y -h' '--no-revert -h'; do
    # shellcheck disable=SC2086 # the words are split on purpose
    ask --root "$ROOT" --config "$ETC" $f
    [ "$status" -eq 0 ] || { echo "$f: exit $status"; return 1; }
    [ ! -e "$ROOT" ] || { echo "$f: made $ROOT"; return 1; }
  done
}

@test "an unknown topic is one line, the main help, and exit 0" {
  ask -h bogus
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "No help for 'bogus'. Here is the main help." ]
  [ "${lines[1]}" = 'Usage: laby PHASE                preview a phase: nothing changes' ]
  ask -h obsrve
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "No help for 'obsrve' (did you mean 'observe'?). Here is the main help." ]
  ask -h basic
  [[ "${lines[0]}" == *"did you mean 'basics'"* ]]
}

@test "the old command words are no help topics" {
  for w in plan apply rollback; do
    ask -h "$w"
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "No help for '$w'"* ]] || { echo "$w"; return 1; }
    [[ "${lines[0]}" != *'did you mean'* ]] || { echo "$w: hint"; return 1; }
  done
}

@test "a usage error points to the help of what was typed, the way the runner was started" {
  run bash "$LAB/labyrinth.sh" obsrve < /dev/null
  [ "$status" -eq 40 ]
  [[ "$output" == *"Try '$LAB/labyrinth.sh -h'."* ]]
  run env SUDO_USER=someone bash "$LAB/labyrinth.sh" obsrve < /dev/null
  [[ "$output" == *"Try 'sudo $LAB/labyrinth.sh -h'."* ]]
  cd "$LAB"
  run bash ./labyrinth.sh bogus < /dev/null
  [[ "$output" == *"Try './labyrinth.sh -h'."* ]]
  run bash ./labyrinth.sh -u 4f2a --bogus < /dev/null
  [[ "$output" == *"Try './labyrinth.sh -u -h'."* ]]
}

@test "both operator manuals have a section for every action help lists" {
  local p c
  for p in linux windows; do
    run bash "$REPO/tools/manual/split.sh" "$p"
    [ "$status" -eq 0 ]
    for c in status preview run keep undo history probe version manual help; do
      grep -Eq "^## $c( |\$)" <<< "$output" || { echo "$p manual: no section for $c"; return 1; }
    done
  done
}

@test "the actions that need root say so, and -h history names every state" {
  local t s
  for t in run keep undo history probe; do
    ask -h "$t"
    grep -qi 'needs root' <<< "$output" || { echo "-h $t: no root note"; return 1; }
  done
  ask -h history
  for s in armed kept undone 'undone with errors' 'not kept, no timer' 'armed: timer lost' 'no revert'; do
    [[ "$output" == *"$s"* ]] || { echo "-h history: no '$s'"; return 1; }
  done
}

@test "-h run and -h basics mention the break-glass prompt; exits name the 20 causes" {
  ask -h run
  [[ "$output" == *break-glass* ]]
  grep -q '^Blocked: not root, another run, host not in hosts, or a safety gate\.$' <<< "$output"
  ask -h basics
  [[ "$output" == *break-glass* ]]
  ask -h keep
  grep -q '^Blocked: not root, a file another account can change, or too late$' <<< "$output"
  ask -h undo
  grep -q '^Blocked: not root, or a file another account can change\.$' <<< "$output"
}

@test "-h undo explains --all and -y, and -h keep says an ID is always needed" {
  ask -h undo
  [[ "$output" == *"--all                  also undo changes kept once they verified"* ]]
  [ "$(head -n 1 <<< "$output")" = 'Usage: laby -u ID [--all [-y]] [--root DIR] [--config DIR]' ]
  [[ "$output" == *'-y, --yes'* ]]
  ask -h keep
  [[ "$output" == *'ID is always needed'* ]]
}

@test "-y and --no-revert have their own pages, and -h run names --no-revert" {
  ask -h yes
  [ "$(head -n 1 <<< "$output")" = 'Usage: laby -u ID --all -y' ]
  ask -y -h
  [ "$(head -n 1 <<< "$output")" = 'Usage: laby -u ID --all -y' ]
  ask -h no-revert
  [ "$(head -n 1 <<< "$output")" = 'Usage: laby -r PHASE --no-revert' ]
  ask -h run
  [[ "$output" == *'--no-revert'* ]]
  ask -h manual
  [ "$(head -n 1 <<< "$output")" = 'Usage: laby --manual' ]
}

@test "-V names the runner, and -V -h is its help" {
  run bash "$LAB/labyrinth.sh" -V < /dev/null
  [ "$status" -eq 0 ]
  local want='^Labyrinth version [^ ]+ \( https://dotnetdork\.github\.io/Labyrinth/ \)$'
  [[ "${lines[0]}" =~ $want ]]
  [ "${lines[1]}" = 'Runner:   bash' ]
  [[ "${lines[2]}" == 'SHA-256:  '* ]]
  # Plain ASCII and short: the same on every terminal.
  if LC_ALL=C grep -q '[^ -~]' <<< "$output"; then return 1; fi
  for l in "${lines[@]}"; do [ "${#l}" -le 78 ]; done
  ask -V -h
  [ "$(head -n 1 <<< "$output")" = 'Usage: laby -V' ]
}

@test "the basics tell the first run with the real forms" {
  ask -h basics
  [[ "$output" == *"'laby lockout'"* ]]
  [[ "$output" == *"'laby -r lockout'"* ]]
  [[ "$output" == *"'laby -k ID'"* ]]
  [[ "$output" == *"laby -u ID;"* ]]
  [[ "$output" == *"laby --history."* ]]
  [[ "$output" == *"'laby --probe'"* ]]
}

@test "help on a module ID prints its title, its risk in words, then its about.txt" {
  ask -h observe.sample
  [ "$status" -eq 0 ]
  [ "$(head -n 1 <<< "$output")" = 'No-op sample (observe.sample)' ]
  grep -qx 'Risk: only looks; it never changes anything.' <<< "$output"
  grep -qx 'Runs on: ubuntu, rhel-family, windows.' <<< "$output"
  grep -qx "What it changes: nothing. Its plan describes a change it never makes." <<< "$output"
  ask -h OBSERVE.SAMPLE
  [ "$status" -eq 0 ]
  [ "$(head -n 1 <<< "$output")" = 'No-op sample (observe.sample)' ]
  ask observe.sample --help
  [ "$status" -eq 0 ]
  [ "$(head -n 1 <<< "$output")" = 'No-op sample (observe.sample)' ]
}

@test "help on a module without about.txt says so; any module ID works, in a profile or not" {
  ask -h observe.toggle
  [ "$status" -eq 0 ]
  grep -qx 'Risk: changes this host; each change is saved first and can be undone.' <<< "$output"
  grep -q '^This module has no about.txt yet' <<< "$output"
}

@test "help on an unknown module is a near-miss line and the main help; an invalid one is an error" {
  ask -h observe.sampel
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "No help for 'observe.sampel' (did you mean 'observe.sample'?). Here is the main help." ]
  ask -h observe.badyml
  [ "$status" -eq 40 ]
  [[ "$output" == *"the module.yml of observe.badyml is not valid: unknown key color"* ]]
}
