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
  local t
  for t in '' $TOPICS; do
    help help $t
    [ "$status" -eq 0 ] || { echo "help $t: exit $status"; return 1; }
    [ "$(wc -l <<< "$output")" -le 15 ] || { echo "help $t: over 15 lines"; return 1; }
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
}
