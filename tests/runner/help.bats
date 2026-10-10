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
    # Basics is one screen. The command in hints and the manual's path do
    # not count toward the width (docs/Conventions.md section 3.2).
    case "$t" in basics) max=24 ;; *) max=18 ;; esac
    [ "$(wc -l <<< "$output")" -le "$max" ] || { echo "help $t: over $max lines"; return 1; }
    [ "$(sed -e "s|$SELF|labyrinth.sh|g" -e "s|$LAB|/opt/labyrinth|g" <<< "$output" \
        | awk '{ if (length > w) w = length } END { print w + 0 }')" -le 78 ] \
      || { echo "help $t: a line is over 78 columns"; return 1; }
    [ "$(grep -c '^Exit: ' <<< "$output")" -eq 1 ] || { echo "help $t: Exit lines"; return 1; }
    [ "$(grep -c '^Example: ' <<< "$output")" -eq 1 ] || { echo "help $t: Example lines"; return 1; }
    [[ "$(head -n 1 <<< "$output")" == "Usage: $SELF "* ]] || { echo "help $t: no Usage line"; return 1; }
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

@test "hints print the command the way it was started, with sudo under sudo" {
  run bash "$LAB/labyrinth.sh" help < /dev/null
  [[ "$(head -n 1 <<< "$output")" == "Usage: $LAB/labyrinth.sh "* ]]
  run env SUDO_USER=someone bash "$LAB/labyrinth.sh" help < /dev/null
  [[ "$(head -n 1 <<< "$output")" == "Usage: sudo $LAB/labyrinth.sh "* ]]
  cd "$LAB"
  run bash labyrinth.sh help < /dev/null
  [[ "$(head -n 1 <<< "$output")" == 'Usage: ./labyrinth.sh '* ]]
  run bash ./labyrinth.sh bogus < /dev/null
  [[ "$output" == *"Try './labyrinth.sh help' for more information."* ]]
}

@test "the general help says where the options are and names a manual that exists" {
  help help
  grep -qF "Options: '$SELF help <command>' lists them; so does <command> -h." <<< "$output"
  [ "$(grep '^Manual: ' <<< "$output")" = "Manual: the Linux parts of $LAB/docs/manual/labyrinth.md" ]
  [[ "$output" != *'once installed'* ]]
}

@test "help runs names every state, and the commands say who must run them" {
  help help runs
  for s in armed kept 'rolled back' 'rolled back with errors' 'not kept, no timer' 'armed: timer lost'; do
    [[ "$output" == *"$s"* ]] || { echo "help runs: no '$s'"; return 1; }
  done
  for t in plan apply keep rollback runs probe; do
    help help "$t"
    grep -q 'needs root\|Needs root' <<< "$output" || { echo "help $t: no root note"; return 1; }
  done
}

@test "help apply and help basics mention the break-glass prompt; exits name the 20 causes" {
  help help apply
  [[ "$output" == *break-glass* ]]
  grep -q '^Blocked: not root, another run, host not in hosts, or a safety gate\.$' <<< "$output"
  help help basics
  [[ "$output" == *break-glass* ]]
  help help keep
  grep -q '^Blocked: not root, a file another account can change, or too late$' <<< "$output"
  help help rollback
  grep -q '^Blocked: not root, or a file another account can change\.$' <<< "$output"
}

@test "the option heading says Options, and the version names the runner" {
  local t
  for t in plan apply keep rollback runs probe; do
    help help "$t"
    grep -qx 'Options:' <<< "$output" || { echo "help $t: no Options heading"; return 1; }
    [[ "$output" != *'Where:'* ]] || { echo "help $t: Where heading"; return 1; }
  done
  run bash "$LAB/labyrinth.sh" version < /dev/null
  [[ "${lines[0]}" == "labyrinth "*" (labyrinth.sh, for Linux)" ]]
  [[ "${lines[1]}" == 'Release: '* ]]
}

@test "everyday words and flags point to the command or option meant" {
  local w want
  for w in undo:rollback revert:rollback status:runs list:runs check:probe test:probe; do
    run bash "$LAB/labyrinth.sh" "${w%%:*}" < /dev/null
    [ "$status" -eq 40 ]
    [[ "$output" == *"unknown command '${w%%:*}' (did you mean '${w#*:}'?)"* ]] || { echo "$w"; return 1; }
  done
  run bash "$LAB/labyrinth.sh" help undo < /dev/null
  [[ "$output" == *"no help for 'undo' (did you mean 'rollback'?)"* ]]
  run bash "$LAB/labyrinth.sh" apply observe --dry-run < /dev/null
  [ "$status" -eq 40 ]
  [[ "$output" == *"unknown option '--dry-run' (did you mean the command 'plan'?)"* ]]
  for w in --yes --force; do
    run bash "$LAB/labyrinth.sh" apply observe "$w" < /dev/null
    [[ "$output" == *"unknown option '$w' (did you mean '--confirm-group'?)"* ]] || { echo "$w"; return 1; }
  done
}

@test "a short word gets a suggestion only when it is one letter off" {
  run bash "$LAB/labyrinth.sh" plan observe --foo < /dev/null
  [ "$status" -eq 40 ]
  [[ "$output" == *"unknown option '--foo'"* ]]
  [[ "$output" != *'did you mean'* ]]
  run bash "$LAB/labyrinth.sh" plan observe --ROT < /dev/null
  [[ "$output" == *"did you mean '--root'"* ]]
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
  [[ "$(sed -n 2p <<< "$output")" == *"$SELF help basics"* ]]
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
  grep -qF "  1. $SELF help basics " <<< "$output"
  grep -qF "  2. $SELF plan lockout " <<< "$output"
}
