#!/usr/bin/env bats
# labyrinth.sh help: the shape of every topic, the ways to ask for it, and
# that the operator manual covers every command it lists
# (docs/Conventions.md sections 3.1 and 3.2).

load lab_helper

setup() { lab_setup; }

TOPICS='plan apply keep rollback runs probe help version'

# help ARG...: run labyrinth.sh with ARG..., which must print help
help() { run bash "$LAB/labyrinth.sh" "$@" < /dev/null; }

@test "every topic is short, fits 78 columns, and has one Exit and one Example line" {
  local t max
  for t in '' $TOPICS basics; do
    help help $t
    [ "$status" -eq 0 ] || { echo "help $t: exit $status"; return 1; }
    # The general page also names the manual; basics is one screen.
    case "$t" in '') max=16 ;; basics) max=24 ;; *) max=15 ;; esac
    [ "$(wc -l <<< "$output")" -le "$max" ] || { echo "help $t: over $max lines"; return 1; }
    [ "$(awk '{ if (length > w) w = length } END { print w + 0 }' <<< "$output")" -le 78 ] \
      || { echo "help $t: a line is over 78 columns"; return 1; }
    [ "$(grep -c '^Exit: ' <<< "$output")" -eq 1 ] || { echo "help $t: Exit lines"; return 1; }
    [ "$(grep -c '^Example: ' <<< "$output")" -eq 1 ] || { echo "help $t: Example lines"; return 1; }
    [[ "$(head -n 1 <<< "$output")" == 'Usage: labyrinth.sh '* ]] || { echo "help $t: no Usage line"; return 1; }
  done
}

@test "help X, X --help and X -h print the same" {
  local t want
  for t in $TOPICS; do
    help help "$t"; want="$output"
    help "$t" --help; [ "$status" -eq 0 ] && [ "$output" = "$want" ] || { echo "$t --help"; return 1; }
    help "$t" -h; [ "$status" -eq 0 ] && [ "$output" = "$want" ] || { echo "$t -h"; return 1; }
  done
  help help; want="$output"
  for a in --help -h '-?' HELP; do
    help "$a"; [ "$status" -eq 0 ] && [ "$output" = "$want" ] || { echo "$a"; return 1; }
  done
}

@test "the general help lists every command, and each has a topic" {
  help help
  local listed
  listed="$(awk '/^  [a-z]+ /{ print $1 }' <<< "$output" | tr '\n' ' ')"
  [ "$listed" = "$TOPICS " ]
}

@test "both operator manuals have a section for every command help lists" {
  local p c listed
  help help
  listed="$(awk '/^  [a-z]+ /{ print $1 }' <<< "$output")"
  for p in linux windows; do
    run bash "$REPO/tools/manual/split.sh" "$p"
    [ "$status" -eq 0 ]
    for c in $listed; do
      grep -Eq "^## $c( |\$)" <<< "$output" || { echo "$p manual: no section for $c"; return 1; }
    done
  done
}

@test "help for an unknown command is a usage error with a suggestion" {
  run bash "$LAB/labyrinth.sh" help aply < /dev/null
  [ "$status" -eq 40 ]
  [[ "$output" == *"did you mean 'apply'"* ]]
  run bash "$LAB/labyrinth.sh" help basic < /dev/null
  [ "$status" -eq 40 ]
  [[ "$output" == *"did you mean 'basics'"* ]]
}

@test "the general help points a beginner to help basics and names the manual" {
  help help
  [[ "$(sed -n 2p <<< "$output")" == *"labyrinth.sh help basics"* ]]
  grep -q '^Manual: ' <<< "$output"
}

@test "help on a module ID prints its title, its risk in words, then its about.txt" {
  help help observe.sample
  [ "$status" -eq 0 ]
  [ "$(head -n 1 <<< "$output")" = 'No-op sample (observe.sample)' ]
  grep -qx 'Risk: only looks; it never changes anything.' <<< "$output"
  grep -qx 'Runs on: ubuntu, rhel-family, windows.' <<< "$output"
  grep -qx "What it changes: nothing. Its plan describes a change it never makes." <<< "$output"
  help help OBSERVE.SAMPLE --help
  [ "$status" -eq 0 ]
  [ "$(head -n 1 <<< "$output")" = 'No-op sample (observe.sample)' ]
}

@test "help on a module without about.txt says so; any module ID works, in a profile or not" {
  help help observe.toggle
  [ "$status" -eq 0 ]
  grep -qx 'Risk: changes this host; each change is saved first and can be undone.' <<< "$output"
  grep -q '^This module has no about.txt yet' <<< "$output"
}

@test "help on an unknown or invalid module is an error that says why" {
  run bash "$LAB/labyrinth.sh" help observe.sampel < /dev/null
  [ "$status" -eq 40 ]
  [[ "$output" == *"no module 'observe.sampel' (did you mean 'observe.sample'?)"* ]]
  run bash "$LAB/labyrinth.sh" help observe.badyml < /dev/null
  [ "$status" -eq 40 ]
  [[ "$output" == *"the module.yml of observe.badyml is not valid: unknown key color"* ]]
}

@test "no command prints three steps to start with, and exits 40" {
  run bash "$LAB/labyrinth.sh" < /dev/null
  [ "$status" -eq 40 ]
  grep -qx 'Start here:' <<< "$output"
  grep -q '^  1\. labyrinth.sh help basics ' <<< "$output"
  grep -q '^  2\. labyrinth.sh plan lockout ' <<< "$output"
}
