#!/usr/bin/env bats
# labyrinth.sh console output (docs/Conventions.md section 3.2): status
# words with plain names, labelled lines, the header, the end of a run, the
# recaps and the run log. Output.Tests.ps1 checks the same for labyrinth.ps1.

load lab_helper

setup() {
  lab_setup
  hosts ring1
}

# line_of TEXT: one more than the index in lines of the first line
# containing TEXT, so that ${lines[n]} is the line after it. lines has no
# blank lines, so grep -n on $output would not match it.
line_of() {
  local i
  for ((i = 0; i < ${#lines[@]}; i++)); do
    if [[ "${lines[i]}" == *"$1"* ]]; then echo "$((i + 1))"; return 0; fi
  done
}

# last_line_of TEXT: like line_of, for the last line containing TEXT.
last_line_of() {
  local i
  for ((i = ${#lines[@]} - 1; i >= 0; i--)); do
    if [[ "${lines[i]}" == *"$1"* ]]; then echo "$((i + 1))"; return 0; fi
  done
}

# The labels a detail line may start with (docs/Conventions.md section 3.2).
LABELS='Found|Will do|Did|Why|Risk|Problem|Cause|Fix|Undo|Note|Log|Script|It said|Before|More'

@test "plan starts each module's result with its status word, then its name and ID" {
  profile observe.clean observe.sample observe.blocked observe.crash observe.winonly observe.badyml
  plan
  [ "$status" -eq 40 ]
  grep -qx 'OK       Nothing-to-do sample (observe.clean)' <<< "$output"
  grep -qx 'CHANGE   No-op sample (observe.sample)' <<< "$output"
  grep -qx 'BLOCKED  Blocked sample (observe.blocked)' <<< "$output"
  grep -qx 'ERROR    Crashing sample (observe.crash)' <<< "$output"
  grep -qx 'WARN     Windows-only sample (observe.winonly)' <<< "$output"
  # A module.yml that does not load has no name to show.
  grep -qx 'ERROR    observe.badyml' <<< "$output"
}

@test "a module.yml error is a Found line under the ERROR line" {
  profile observe.badyml
  plan
  [ "$status" -eq 40 ]
  n="$(line_of 'ERROR    observe.badyml')"
  [ "${lines[n]}" = '  Problem:   invalid module.yml, so the module cannot be loaded' ]
  [[ "${lines[n+1]}" =~ ^\ \ Found:\ {5}module\.yml:[0-9]+:\ unknown\ key\ color$ ]]
}

@test "module output, both streams, is shown as Note lines under its result line" {
  profile observe.clean observe.sample
  printf '#!/usr/bin/env bash\necho on-stdout\necho on-stderr >&2\nexit 0\n' \
    > "$LAB/phases/observe/modules/clean/check.sh"
  plan
  [ "$status" -eq 10 ]
  n="$(line_of 'OK       Nothing-to-do sample (observe.clean)')"
  [ "${lines[n]}" = '  Note:      on-stdout' ]
  [ "${lines[n+1]}" = '  Note:      on-stderr' ]
  n="$(line_of 'CHANGE   No-op sample (observe.sample)')"
  [ "${lines[n]}" = '  Note:      sample: a change is needed' ]
}

@test "a module's 'key: text' lines become labelled lines; others are Notes" {
  profile observe.sample
  printf '%s\n' '#!/usr/bin/env bash' "echo 'found: password logins are on'" "echo 'Will do: turn them off'" \
    "echo '  WHY: a stolen password stops working'" "echo 'risk: none'" "echo 'colour: blue'" 'echo' 'exit 10' \
    > "$LAB/phases/observe/modules/sample/check.sh"
  plan
  [ "$status" -eq 10 ]
  n="$(line_of 'CHANGE   No-op sample (observe.sample)')"
  [ "${lines[n]}" = '  Found:     password logins are on' ]
  [ "${lines[n+1]}" = '  Will do:   turn them off' ]
  [ "${lines[n+2]}" = '  Why:       a stolen password stops working' ]
  [ "${lines[n+3]}" = '  Risk:      none' ]
  [ "${lines[n+4]}" = '  Note:      colour: blue' ]
  # The module gave a Risk line, so the runner adds none of its own.
  [ "$(grep -c '^  Risk:' <<< "$output")" -eq 1 ]
}

@test "a CHANGE without a Risk line gets the risk in plain words" {
  profile observe.toggle
  plan
  n="$(line_of 'CHANGE   Toggle setting sample (observe.toggle)')"
  grep -qx '  Risk:      changes this host; each change is saved first and can be undone' <<< "$output"
}

@test "a failed entry point without a 'problem:' line gets the runner's Problem, Script and It said" {
  profile observe.crash
  printf '%s\n' '#!/usr/bin/env bash' 'for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo "line $i"; done' 'exit 3' \
    > "$LAB/phases/observe/modules/crash/check.sh"
  plan
  [ "$status" -eq 40 ]
  grep -qx '  Problem:   its check script failed with exit code 3 and gave no reason' <<< "$output"
  grep -qx "  Script:    $LAB/phases/observe/modules/crash/check.sh" <<< "$output"
  # Only the last 10 lines.
  [ "$(grep -c '^  It said:   line ' <<< "$output")" -eq 10 ]
  grep -qx '  It said:   line 3' <<< "$output"
  ! grep -qx '  It said:   line 2' <<< "$output"
  [ "$(tail -n 1 <<< "$(grep '^  ' <<< "$output")")" = "  More:      $SELF help observe.crash" ]
}

@test "a failed entry point that ends with 'problem:' is shown as it said it" {
  profile observe.crash
  printf '%s\n' '#!/usr/bin/env bash' "echo 'found: no firewall tool'" "echo 'problem: neither ufw nor firewalld is installed'" 'exit 40' \
    > "$LAB/phases/observe/modules/crash/check.sh"
  plan
  [ "$status" -eq 40 ]
  grep -qx '  Found:     no firewall tool' <<< "$output"
  grep -qx '  Problem:   neither ufw nor firewalld is installed' <<< "$output"
  [[ "$output" != *'gave no reason'* && "$output" != *'It said:'* ]]
}

@test "every detail line starts with a label, and every WARN, BLOCKED or ERROR block ends with More" {
  profile observe.clean observe.sample observe.blocked observe.crash observe.winonly observe.manual observe.toggle
  plan
  [ "$status" -eq 40 ]
  local l word='' prev=''
  while IFS= read -r l; do
    if [[ "$l" == '  '* ]]; then
      [[ "$l" =~ ^\ \ ($LABELS):\ +[^\ ] ]] || { echo "no label: $l"; return 1; }
    fi
    # A block ends at the next status line or at a line that is not a detail.
    if [[ "$l" != '  '* ]]; then
      if [[ "$word" =~ ^(WARN|BLOCKED|ERROR)$ ]]; then
        [[ "$prev" == "  More:      $SELF help observe."* ]] || { echo "no More after: $word"; return 1; }
      fi
      word="${l%% *}"
    fi
    prev="$l"
  done <<< "$output"
}

@test "plan says it changes nothing, then names the host and how many modules it checks" {
  profile observe.clean observe.sample
  plan
  [ "${lines[2]}" = "This is a plan: Labyrinth only looks, and nothing on $HOST changes." ]
  [ "${lines[3]}" = "Host $HOST is in group ring1." ]
  [ "${lines[4]}" = 'Checking 2 modules of profile test, most urgent first.' ]
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
  hosts ring1
  profile observe.clean observe.sample
  plan
  [ "$status" -eq 10 ]
  local last=$(( ${#lines[@]} - 1 ))
  [ "${lines[last-4]}" = 'Summary: 2 modules: 1 OK, 1 CHANGE.' ]
  [ "${lines[last-3]}" = 'Nothing on this host was changed.' ]
  # Too long for one line with the test's paths, so the command has its own.
  [ "${lines[last-2]}" = 'Next:' ]
  [ "${lines[last-1]}" = "  $SELF apply observe --profile test --root $ROOT --config $ETC" ]
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

@test "plan's Next line never names an apply that would be refused" {
  profile observe.sample
  plan
  [ "$status" -eq 10 ]
  [[ "$output" == *'Next: list this host in the hosts file, with its group and profile;'* ]]
  [[ "$output" != *'labyrinth.sh apply observe'* ]]
  printf '%s ring1 other ubuntu\n' "$HOST" > "$ETC/hosts"
  printf 'observe.sample\n' > "$LAB/profiles/other.profile"
  plan
  [ "$status" -eq 10 ]
  [[ "$output" == *"Next: apply uses this host's profile in the hosts file, other."* ]]
  [[ "$output" != *'labyrinth.sh apply observe'* ]]
}

@test "plan shows a manual-only module as WARN and counts it as WARN" {
  profile observe.clean observe.manual
  plan
  [ "$status" -eq 10 ]
  grep -qx 'WARN     Manual steps sample (observe.manual)' <<< "$output"
  grep -qx '  Found:     this needs a person; Labyrinth will not change it' <<< "$output"
  [[ "$output" == *'Summary: 2 modules: 1 OK, 1 WARN.'* ]]
  [[ "$output" != *CHANGE* ]]
}

@test "apply: a two-line header, a CHANGE line before each change and OK after it" {
  profile observe.toggle
  answers root ring1 keep
  apply
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^labyrinth\ [^\ ]+:\ APPLY\ observe,\ profile\ test$ ]]
  [[ "${lines[1]}" =~ ^run\ [0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}\ on\ host\ .+,\ group\ ring1$ ]]
  [ "${lines[2]}" = 'First Labyrinth plans; nothing changes until you confirm.' ]
  # The plan's CHANGE line comes first; the last one starts the change.
  a="$(last_line_of 'CHANGE   Toggle setting sample (observe.toggle)')"
  b="$(line_of 'OK       Toggle setting sample (observe.toggle)')"
  [ -n "$a" ] && [ -n "$b" ] && (( a < b ))
  (( a > $(line_of 'Type the group name') ))
  [ "${lines[b]}" = '  Did:       applied and verified' ]
  [[ "$output" == *'Summary: 1 module: 1 OK.'* ]]
  [[ "$output" != *'Next:'* ]]
  [ "${lines[${#lines[@]}-1]}" = 'apply finished: exit 0 (done)' ]
}

@test "apply: a failed verify is FAIL, the module is rolled back and the run stops" {
  profile observe.toggle
  touch "$LAB/FAIL_VERIFY"
  answers root ring1
  apply
  [ "$status" -eq 30 ]
  n="$(line_of 'FAIL     Toggle setting sample (observe.toggle)')"
  [ "${lines[n]}" = '  Problem:   its verify script failed with exit code 30 and gave no reason' ]
  [ "${lines[n+1]}" = "  Script:    $LAB/phases/observe/modules/toggle/verify.sh" ]
  grep -qx '  Did:       rolled back' <<< "$output"
  grep -qx "  Log:       $ROOT/state/runs/$(run_id)/output.log" <<< "$output"
  grep -qxF "  More:      $SELF help observe.toggle" <<< "$output"
  [[ "$output" == *'Summary: 1 module: 1 FAIL.'* ]]
  [[ "$output" == *'Next: undo the earlier changes, or keep them, with the commands above.'* ]]
  [[ "$output" == *'apply finished: exit 30 (a check failed and that change was undone; earlier ones stay)'* ]]
}

@test "apply: the recap comes after break-glass and before the group prompt" {
  profile observe.toggle observe.blocked observe.manual
  answers root ring1 keep
  apply
  a="$(line_of 'Break-glass account root: confirmed.')"
  b="$(line_of 'About to apply on host')"
  c="$(line_of 'Type the group name (ring1)')"
  (( a < b && b <= c ))
  grep -qx '  Will change: Toggle setting sample (observe.toggle)' <<< "$output"
  grep -qx '  Blocked:     Blocked sample (observe.blocked)' <<< "$output"
  grep -qx '  Manual:      Manual steps sample (observe.manual)' <<< "$output"
  [ "${lines[c-2]}" = 'To go ahead, type the group name. Anything else stops here; nothing changes.' ]
  [[ "$output" != *'connected over SSH'* ]]
}

@test "apply: over SSH, the recap warns when a change may interrupt a service" {
  sed -i 's/^risk: .*/risk: service-affecting/' "$LAB/phases/observe/modules/toggle/module.yml"
  profile observe.toggle
  answers root ring1 keep
  SSH_CONNECTION='192.0.2.9 50000 192.0.2.1 22' apply
  [ "$status" -eq 0 ]
  a="$(line_of 'You are connected over SSH, and a change may interrupt a service.')"
  [ -n "$a" ] && (( a < $(line_of 'Type the group name') ))
  [[ "$output" == *'Keep a second session open until you have checked you can log in.'* ]]
}

@test "apply: before the keep prompt, the time the revert timer rolls the run back" {
  profile observe.toggle
  answers root ring1 no
  apply
  [ "$status" -eq 0 ]
  id="$(run_id)"
  due="$(cat "$ROOT/state/runs/$id/timer-due")"
  a="$(line_of "The revert timer rolls this run back at ${due:11:5} UTC, ")"
  b="$(line_of 'Type keep to keep')"
  [ -n "$a" ] && (( a <= b ))
  [[ "$output" == *"Next: check you can log in from a NEW session, then '$SELF keep ${id: -4}'."* ]]
}

@test "every prompt fits 78 columns, with what it asks for on the lines above" {
  profile observe.ask observe.toggle
  answers root ring1 item-a keep
  apply
  [ "$status" -eq 0 ]
  # The run log holds each prompt with the answer typed after it.
  local log="$ROOT/state/runs/$(run_id)/output.log" n=0 l
  while IFS= read -r l; do
    case "$l" in
      *': root' | *': ring1' | *': item-a' | *': keep')
        n=$((n + 1))
        l="${l% *}"
        (( ${#l} <= 78 )) || { echo "prompt too long: $l"; return 1; } ;;
    esac
  done < "$log"
  [ "$n" -ge 4 ]
  grep -qx 'Break-glass account name: root' "$log"
  grep -qx 'Items to approve (Enter for none): item-a' "$log"
  grep -qx 'Type keep to keep the changes, or press Enter to leave them to the timer: keep' "$log"
}

@test "a declined confirmation records no break-glass answer, so the next apply asks again" {
  profile observe.toggle
  answers root wrong
  apply
  [ "$status" -eq 20 ]
  [[ "$output" == *'Break-glass account root: confirmed.'* ]]
  [ ! -e "$ROOT/state/breakglass" ]
  answers root ring1 keep
  apply
  [ "$status" -eq 0 ]
  [[ "$output" == *'Break-glass check:'* ]]
  [ -f "$ROOT/state/breakglass" ]
}

@test "output lines are at most 78 columns, unless they end with a path" {
  profile observe.clean observe.sample observe.manual observe.blocked observe.crash observe.toggle
  plan
  local l
  for l in "${lines[@]}"; do
    (( ${#l} <= 78 )) || [[ "${l##* }" == /* ]] || { echo "too long: $l"; return 1; }
  done
  touch "$LAB/FAIL_VERIFY"
  profile observe.toggle observe.manual observe.blocked
  # The prompts end without a newline, so they are answered by options here.
  apply --break-glass root --confirm-group ring1
  for l in "${lines[@]}"; do
    (( ${#l} <= 78 )) || [[ "${l##* }" == /* ]] || { echo "too long: $l"; return 1; }
  done
}

@test "apply writes the run log, readable by root only, with every module line" {
  profile observe.toggle
  answers root ring1 keep
  apply
  [ "$status" -eq 0 ]
  local log="$ROOT/state/runs/$(run_id)/output.log"
  [ "$(stat -c %a "$log")" = 600 ]
  grep -q "labyrinth [^ ]*: apply observe, run $(run_id)" "$log"
  grep -qx 'observe.toggle check| toggle: setting is not on' "$log"
  grep -qx 'observe.toggle apply| toggle: setting=on' "$log"
  grep -Eqx '[0-9]{2}:[0-9]{2}:[0-9]{2} observe.toggle verify exited 0' "$log"
  grep -qx 'OK       Toggle setting sample (observe.toggle)' "$log"
  grep -q '^Type the group name (ring1) to apply this plan: ring1$' "$log"
  grep -qx "kept: the revert timer for run $(run_id) is cancelled" "$log"
  [ "${lines[${#lines[@]}-2]}" = "Log: $log" ] || [[ "$output" == *"Log: $log"* ]]
}

@test "the run log keeps at most 500 lines from one entry point" {
  profile observe.toggle
  printf '%s\n' 'for i in $(seq 1 600); do echo "out $i"; done' >> "$LAB/phases/observe/modules/toggle/apply.sh"
  answers root ring1 keep
  apply
  [ "$status" -eq 0 ]
  local log="$ROOT/state/runs/$(run_id)/output.log"
  [ "$(grep -c '^observe.toggle apply| ' "$log")" -eq 500 ]
  grep -qx 'observe.toggle apply: 101 more lines not logged' "$log"
}

@test "plan and a stopped apply: plan writes no log; the stopped run is marked for 'runs'" {
  profile observe.toggle
  plan
  [ ! -e "$ROOT" ]
  touch "$LAB/FAIL_VERIFY"
  answers root ring1
  apply
  [ "$status" -eq 30 ]
  id="$(run_id)"
  [ -e "$ROOT/state/runs/$id/problems" ]
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" runs
  [ "$status" -eq 0 ]
  grep -qx "  ${id: -4}  $ROOT/state/runs/$id/output.log" <<< "$output"
}

@test "a rollback by the revert timer adds to the run log" {
  profile observe.toggle
  answers root ring1 no
  apply
  id="$(run_id)"
  # The stored timer command, as systemd would run it.
  read -r -a cmd < "$ROOT/state/runs/$id/timer"
  run "${cmd[@]}"
  [ "$status" -eq 0 ]
  local log="$ROOT/state/runs/$id/output.log"
  grep -q "labyrinth [^ ]*: rollback run $id" "$log"
  grep -qx '  Did:       rolled back' "$log"
  grep -qx 'rollback finished: exit 0 (rolled back)' "$log"
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
  [ "${lines[4]}" = "Next: bring the failed services back, then run '$SELF probe' again." ]
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
  grep -qx 'WARN     Phase observe' <<< "$output"
  grep -qx '  Found:     profile test lists no observe modules: nothing to check' <<< "$output"
}

@test "rollback ends with the exit code and its meaning" {
  profile observe.toggle
  answers root ring1 no
  apply
  id="$(run_id)"
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" rollback "$id"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "labyrinth $(sed -n "s/^readonly LAB_VERSION='\(.*\)'$/\1/p" "$LAB/labyrinth.sh"): rollback run $id" ]
  grep -qx 'OK       Toggle setting sample (observe.toggle)' <<< "$output"
  [ "${lines[${#lines[@]}-3]}" = 'Summary: 1 module: 1 OK.' ]
  [ "${lines[${#lines[@]}-2]}" = "Log: $ROOT/state/runs/$id/output.log" ]
  [ "${lines[${#lines[@]}-1]}" = 'rollback finished: exit 0 (rolled back)' ]
}
