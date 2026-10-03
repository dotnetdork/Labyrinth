#!/usr/bin/env bats
# labyrinth.sh console output (docs/Conventions.md section 3.2): status
# words, indented module output, the two-line header, the end of a run and
# the recaps. Output.Tests.ps1 checks the same for labyrinth.ps1.

load lab_helper

setup() {
  lab_setup
  hosts ring1
}

# line_of TEXT: the number of the first output line containing TEXT.
line_of() { grep -nF -- "$1" <<< "$output" | head -n 1 | cut -d: -f1; }

@test "plan starts each module's result with its status word, padded to 9 characters" {
  profile observe.clean observe.sample observe.blocked observe.crash observe.winonly observe.badyml
  plan
  [ "$status" -eq 40 ]
  grep -qx 'OK       \[observe.clean\] check: nothing to do' <<< "$output"
  grep -qx 'CHANGE   \[observe.sample\] check: change needed; plan follows' <<< "$output"
  grep -qx 'BLOCKED  \[observe.blocked\] check: blocked by a safety gate' <<< "$output"
  grep -qx 'ERROR    \[observe.crash\] check: error (exit 3)' <<< "$output"
  grep -qx 'WARN     \[observe.winonly\] skipped: no Linux entry points' <<< "$output"
  grep -qx 'ERROR    \[observe.badyml\] error: invalid module.yml' <<< "$output"
}

@test "a module.yml error is printed indented under its ERROR line" {
  profile observe.badyml
  plan
  [ "$status" -eq 40 ]
  n="$(line_of '[observe.badyml] error: invalid module.yml')"
  [[ "${lines[n]}" =~ ^\ {11}[^\ ].*unknown\ key\ color$ ]]
}

@test "module output, both streams, is indented 11 spaces under its result line" {
  profile observe.clean observe.sample
  printf '#!/usr/bin/env bash\necho on-stdout\necho on-stderr >&2\nexit 0\n' \
    > "$LAB/phases/observe/modules/clean/check.sh"
  plan
  [ "$status" -eq 10 ]
  n="$(line_of '[observe.clean] check: nothing to do')"
  [ "${lines[n]}" = '           on-stdout' ]
  [ "${lines[n+1]}" = '           on-stderr' ]
  n="$(line_of '[observe.sample] check: change needed')"
  [ "${lines[n]}" = '           sample: a change is needed' ]
}

@test "the plan header is two lines that say nothing is recorded" {
  profile observe.sample
  plan
  [[ "${lines[0]}" =~ ^labyrinth\ [^\ ]+:\ plan\ observe,\ profile\ test$ ]]
  [[ "${lines[1]}" =~ ^run\ [0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}\ \(plan\ mode:\ nothing\ is\ recorded\)$ ]]
  [ "${#lines[0]}" -le 78 ] && [ "${#lines[1]}" -le 78 ]
  [ ! -e "$ROOT" ]
}

@test "plan ends with Summary, Next and the exit code with its meaning" {
  profile observe.clean observe.sample
  plan
  [ "$status" -eq 10 ]
  local last=$(( ${#lines[@]} - 1 ))
  [ "${lines[last-3]}" = 'Summary: 1 OK, 1 CHANGE' ]
  # Too long for one line with the test's paths, so the command has its own.
  [ "${lines[last-2]}" = 'Next:' ]
  [ "${lines[last-1]}" = "  labyrinth.sh apply observe --profile test --root $ROOT --config $ETC" ]
  [ "${lines[last]}" = 'plan finished: exit 10 (change needed)' ]
}

@test "the Next line fits what plan found" {
  profile observe.clean
  plan
  [ "$status" -eq 0 ]
  [[ "$output" != *'Next:'* ]]
  [[ "$output" == *'plan finished: exit 0 (nothing to do)'* ]]
  profile observe.blocked
  plan
  [[ "$output" == *'Next: clear what blocked it above'* ]]
  [[ "$output" == *'plan finished: exit 20 (blocked)'* ]]
  profile observe.manual
  plan
  [ "$status" -eq 10 ]
  [[ "$output" == *'Next: a person carries out the manual steps above; apply changes nothing.'* ]]
}

@test "plan shows a manual-only module as WARN and counts it as WARN" {
  profile observe.clean observe.manual
  plan
  [ "$status" -eq 10 ]
  grep -qx 'WARN     \[observe.manual\] check: manual steps needed; plan follows' <<< "$output"
  [[ "$output" == *'Summary: 1 OK, 1 WARN'* ]]
  [[ "$output" != *CHANGE* ]]
}

@test "apply: a two-line header, a CHANGE line before each change and OK after it" {
  profile observe.toggle
  answers root ring1 keep
  apply
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^labyrinth\ [^\ ]+:\ APPLY\ observe,\ profile\ test$ ]]
  [[ "${lines[1]}" =~ ^run\ [0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}\ on\ host\ .+,\ group\ ring1$ ]]
  a="$(line_of 'CHANGE   [observe.toggle] applying')"
  b="$(line_of 'OK       [observe.toggle] applied and verified')"
  [ -n "$a" ] && [ -n "$b" ] && (( a < b ))
  [[ "$output" == *'Summary: 1 OK'* ]]
  [[ "$output" != *'Next:'* ]]
  [ "${lines[${#lines[@]}-1]}" = 'apply finished: exit 0 (done)' ]
}

@test "apply: a failed verify is FAIL, the module is rolled back and the run stops" {
  profile observe.toggle
  touch "$LAB/FAIL_VERIFY"
  answers root ring1
  apply
  [ "$status" -eq 30 ]
  grep -qx 'FAIL     \[observe.toggle\] verify failed (exit 30); rolling back' <<< "$output"
  grep -qx 'OK       \[observe.toggle\] rolled back' <<< "$output"
  [[ "$output" == *'Summary: 1 FAIL'* ]]
  [[ "$output" == *'Next: keep the earlier changes or undo them'* ]]
  [[ "$output" == *'apply finished: exit 30 (a check failed, and that change was undone)'* ]]
}

@test "apply: the recap comes after break-glass and before the group prompt" {
  profile observe.toggle observe.blocked observe.manual
  answers root ring1 keep
  apply
  a="$(line_of 'break-glass: root confirmed')"
  b="$(line_of 'About to apply on host')"
  c="$(line_of 'Type the group name (ring1)')"
  (( a < b && b <= c ))
  [[ "$output" == *'  will change  observe.toggle'* ]]
  [[ "$output" == *'  blocked      observe.blocked'* ]]
  [[ "$output" == *'  manual       observe.manual'* ]]
}

@test "apply: before the keep prompt, the time the revert timer rolls the run back" {
  profile observe.toggle
  answers root ring1 no
  apply
  [ "$status" -eq 0 ]
  id="$(run_id)"
  due="$(cat "$ROOT/state/runs/$id/timer-due")"
  a="$(line_of "The revert timer rolls this run back at ${due:11:5} UTC.")"
  b="$(line_of 'Type keep to keep')"
  [ -n "$a" ] && (( a <= b ))
  [[ "$output" == *"Next: check you can log in from a NEW session, then 'labyrinth.sh keep ${id: -4}'."* ]]
}

@test "fixed output lines are at most 78 columns" {
  profile observe.clean observe.sample observe.manual
  plan
  local l
  for l in "${lines[@]}"; do
    # Module output, and a command line, whose paths can be any length.
    [[ "$l" == '           '* || "$l" == '  labyrinth.sh '* ]] && continue
    [ "${#l}" -le 78 ] || { echo "too long: $l"; return 1; }
  done
}

@test "probe: a header, a status line per service, Summary, Next and finished" {
  printf 'web http web.test 80 -\nmail smtp mail.test 25 -\n' > "$ETC/services"
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" probe
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^labyrinth\ [^\ ]+:\ probe\ the\ scored\ services$ ]]
  [ "${lines[1]}" = 'OK       [web] pass: fake probe' ]
  [ "${lines[3]}" = 'Summary: 2 OK' ]
  [ "${lines[4]}" = 'probe finished: exit 0 (no service failed)' ]
  printf 'web.test fail\nmail.test fail\n' > "$LAB/probe-state"
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" probe
  [ "$status" -eq 30 ]
  [ "${lines[1]}" = 'FAIL     [web] fail: fake probe' ]
  [ "${lines[3]}" = 'Summary: 2 FAIL' ]
  [ "${lines[4]}" = "Next: bring the failed services back, then run 'labyrinth.sh probe' again." ]
  [ "${lines[5]}" = 'probe finished: exit 30 (2 services failed)' ]
}

@test "the Next line after several errors says errors" {
  profile observe.crash observe.badyml
  plan
  [ "$status" -eq 40 ]
  [[ "$output" == *'Next: fix the errors above, then run the same command again.'* ]]
  profile observe.crash
  plan
  [[ "$output" == *'Next: fix the error above, then run the same command again.'* ]]
}

@test "a phase with no modules in the profile is a WARN naming the phase" {
  profile
  plan
  [ "$status" -eq 0 ]
  grep -qx 'WARN     \[observe\] no modules for this phase in profile test' <<< "$output"
}

@test "rollback ends with the exit code and its meaning" {
  profile observe.toggle
  answers root ring1 no
  apply
  id="$(run_id)"
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" rollback "$id"
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = 'rollback finished: exit 0 (rolled back)' ]
}
