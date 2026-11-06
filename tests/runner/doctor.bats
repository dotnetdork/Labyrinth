#!/usr/bin/env bats
# labyrinth.sh --doctor: a read-only check that this host is ready for a run
# (docs/Conventions.md section 3.1). One line per check, OK, WARN or FAIL,
# and a Fix line under a WARN or FAIL; any FAIL exits 20 with a Next line
# for the first one. The host-specific parts are the test doubles
# (tests/fixtures/doubles.sh): NOT_ADMIN, UNTRUSTED_TREE, NO_TIMER,
# NO_TIMESYNC, TIMESYNC_UNKNOWN, TIMER_LOST and a CLOCK file.

load lab_helper

setup() {
  lab_setup
  hosts ring1
  profile observe.toggle
  printf 'web http 127.0.0.1 80 -\n' > "$ETC/services"
  sign
}

# sign: write release.sha256 for the test copy, as at release time. Call it
# again after changing a file of the copy.
sign() { bash "$REPO/tools/release/manifest.sh" "$LAB" > /dev/null; }

lab() { run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" "$@" < /dev/null; }

# rows: the check lines of the last output, in ROWS.
rows() { mapfile -t ROWS < <(grep -E '^(OK|WARN|FAIL) ' <<< "$output"); }

# fix_of N: the Fix text under check line N.
fix_of() {
  local line
  line="$(grep -A1 -xF -- "${ROWS[$1]}" <<< "$output" | sed -n '2p')"
  [[ "$line" == '      Fix: '* ]] || { echo "row $1 has no Fix line"; return 1; }
  printf '%s' "${line#      Fix: }"
}

# fails_only N TEXT [WORD6]: check line N is the only FAIL and holds TEXT,
# every other line is OK (line 6, the tools, is WORD6 when the host's
# profile is not known), and Next repeats the fix under line N.
fails_only() {
  local i word fix
  [ "$status" -eq 20 ]
  rows
  [ "${#ROWS[@]}" -eq 8 ] || { echo "$output"; return 1; }
  for i in 0 1 2 3 4 5 6 7; do
    word=OK
    if [ "$i" -eq "$1" ]; then word=FAIL; fi
    if [ "$i" -eq 6 ] && [ "$1" -ne 6 ]; then word="${3:-OK}"; fi
    [[ "${ROWS[i]}" == "$(printf '%-6s' "$word")"* ]] || { echo "row $i: ${ROWS[i]}"; return 1; }
  done
  [[ "${ROWS[$1]}" == *"$2"* ]] || { echo "row $1: ${ROWS[$1]}"; return 1; }
  fix="$(fix_of "$1")"
  [ "$(grep '^Next: ' <<< "$output")" = "Next: $fix" ]
}

# snapshot: every path of the test trees with its size and time, then every
# file's SHA-256: equal before and after means nothing was written.
snapshot() {
  find "$LAB" "$ROOT" "$ETC" -printf '%p %y %s %T@\n' | LC_ALL=C sort
  find "$LAB" "$ROOT" "$ETC" -type f -exec sha256sum {} + | LC_ALL=C sort
}

# armed_run: apply, leave the revert timer armed, and print the run ID.
armed_run() {
  # Without a service list the run has no probe step to answer for.
  rm -f "$ETC/services"
  answers root ring1 no
  apply
  [ "$status" -eq 0 ]
  printf 'web http 127.0.0.1 80 -\n' > "$ETC/services"
  run_id
}

@test "a clean host passes every check, ends with Ready for a run., and exits 0" {
  lab --doctor
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'OK    release matches release.sha256' ]
  [ "${lines[1]}" = 'OK    code and data folders writable only by root' ]
  [ "${lines[2]}" = 'OK    configuration files read and filled in' ]
  [ "${lines[3]}" = "OK    this host is $HOST in hosts, profile test" ]
  [ "${lines[4]}" = 'OK    revert timer can be armed (systemd)' ]
  [ "${lines[5]}" = 'OK    clock is set and time sync is running (fake-timesyncd)' ]
  [ "${lines[6]}" = 'OK    tools for the test profile: present' ]
  [ "${lines[7]}" = 'OK    no stale revert timer' ]
  [ "${lines[8]}" = '' ]
  [ "${lines[9]}" = 'Ready for a run.' ]
  [ "${#lines[@]}" -eq 10 ]
  [[ "$output" != *FAIL* && "$output" != *WARN* && "$output" != *Next:* ]]
}

@test "it works without a data root: it makes none" {
  lab --doctor
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT" ]
}

# ---- 1. the release

@test "release: a changed core file is the one FAIL, nothing else runs, and Next names the fix" {
  echo '# changed' >> "$LAB/core/lib.sh"
  lab --doctor
  [ "$status" -eq 20 ]
  [ "${lines[0]}" = 'FAIL  release: core/lib.sh differs from the release' ]
  [[ "${lines[1]}" == '      Fix: Copy Labyrinth here again'* ]]
  [ "${lines[2]}" = '      The other checks were not run.' ]
  [ "${lines[3]}" = '' ]
  [ "${lines[4]}" = "Next: ${lines[1]#      Fix: }" ]
  [ "${#lines[@]}" -eq 5 ]
}

@test "release: a file planted in a module folder is a FAIL too" {
  echo 'x' > "$LAB/phases/observe/modules/toggle/extra.sh"
  lab --doctor
  [ "$status" -eq 20 ]
  [ "${lines[0]}" = 'FAIL  release: phases/observe/modules/toggle/extra.sh is not in the release' ]
}

@test "release: help still refuses a changed release, as it does for every command" {
  echo '# changed' >> "$LAB/core/lib.sh"
  lab --doctor -h
  [ "$status" -eq 20 ]
  [[ "$output" == *'will not run'* ]]
  [[ "$output" != *'FAIL'* ]]
}

@test "release: with no release.sha256 it is a WARN, which does not fail the check" {
  rm "$LAB/release.sha256"
  lab --doctor
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "WARN  no release.sha256: Labyrinth's files were not checked" ]]
  [[ "${lines[1]}" == '      Fix: '* ]]
  [ "${lines[-1]}" = 'Ready for a run.' ]
  [[ "$output" != *FAIL* ]]
}

# ---- 2. who can change the folders

@test "folders: a folder another account can change is the one FAIL" {
  touch "$LAB/UNTRUSTED_TREE"
  lab --doctor
  fails_only 1 'can be changed by an account other than root'
  [[ "${ROWS[1]}" == "FAIL  $LAB can be changed"* ]]
}

# ---- 3. the configuration files

@test "config: a missing services file is the one FAIL" {
  rm "$ETC/services"
  lab --doctor
  fails_only 2 'services: missing'
  [ "$(fix_of 2)" = "copy the team's services to $ETC/services" ]
}

@test "config: a malformed line names the file and the line" {
  printf 'web http 127.0.0.1 80 -\nweb2 http 127.0.0.1\n' > "$ETC/services"
  lab --doctor
  fails_only 2 'services: line 2: expected: name proto host[/path] port expect'
  [ "$(fix_of 2)" = "edit $ETC/services" ]
}

@test "config: an empty protected-accounts file is a FAIL" {
  : > "$ETC/protected-accounts"
  lab --doctor
  fails_only 2 'protected-accounts: lists nothing'
}

@test "config: a missing protected-accounts file is a FAIL" {
  rm "$ETC/protected-accounts"
  lab --doctor
  fails_only 2 'protected-accounts: missing'
}

@test "config: a value still copied from a template is a FAIL" {
  printf 'web http www.example.test 80 -\n' > "$ETC/services"
  lab --doctor
  fails_only 2 'services: line 1: www.example.test is an example value'
  printf 'web http 127.0.0.1 80 -\n' > "$ETC/services"
  printf 'SIEM_ADDRESS=192.0.2.10\n' > "$ETC/event.conf"
  lab --doctor
  fails_only 2 'event.conf: SIEM_ADDRESS is an example value'
  rm "$ETC/event.conf"
  printf '10.1.1.1\n198.51.100.0/28\n' > "$ETC/never-ban"
  lab --doctor
  fails_only 2 'never-ban: line 2: 198.51.100.0/28 is an example value'
}

@test "config: a setting out of range is a FAIL" {
  printf 'REVERT_MINUTES=99\n' > "$ETC/event.conf"
  lab --doctor
  fails_only 2 'event.conf: REVERT_MINUTES must be a whole number from 1 to 60'
}

@test "config: a malformed optional file is a FAIL, and a missing one is fine" {
  printf 'not-an-address\n' > "$ETC/scoring-allowlist"
  lab --doctor
  fails_only 2 'scoring-allowlist: line 1: not an address or CIDR'
  rm "$ETC/scoring-allowlist"
  printf 'bad line\n' > "$ETC/pre-approved"
  lab --doctor
  fails_only 2 'pre-approved: line 1: expected: module-id category item-id'
  rm "$ETC/pre-approved"
  lab --doctor
  [ "$status" -eq 0 ]
}

# ---- 4. this host and its profile

@test "host: a host that is not in hosts is the one FAIL, and the tools are not checked" {
  printf 'someone-else ring1 test ubuntu\n' > "$ETC/hosts"
  lab --doctor
  fails_only 3 "this host ($HOST) is not in hosts" WARN
  [[ "${ROWS[6]}" == "WARN  tools: not checked because this host's profile is not known" ]]
  [ "$(fix_of 3)" = "add a line for $HOST to $ETC/hosts" ]
}

@test "host: a missing hosts file is a FAIL" {
  rm "$ETC/hosts"
  lab --doctor
  fails_only 3 'hosts: missing' WARN
}

@test "host: a malformed hosts line names the line" {
  printf '%s ring1 test ubuntu\nbroken\n' "$HOST" > "$ETC/hosts"
  lab --doctor
  fails_only 3 'hosts: line 2: expected: host group profile platform' WARN
}

@test "host: a host on two lines is a FAIL" {
  printf '%s ring1 test ubuntu\n%s ring2 test ubuntu\n' "$HOST" "$HOST" > "$ETC/hosts"
  lab --doctor
  fails_only 3 "this host ($HOST) is on 2 lines of hosts" WARN
}

@test "host: a profile that does not exist is a FAIL" {
  printf '%s ring1 nope ubuntu\n' "$HOST" > "$ETC/hosts"
  lab --doctor
  fails_only 3 'the profile nope does not exist' WARN
}

@test "host: a profile line that is not a module ID is a FAIL" {
  printf 'nonsense\n' > "$LAB/profiles/test.profile"
  sign
  lab --doctor
  fails_only 3 'profile test: line 1 is not a module ID' WARN
}

@test "host: a platform this runner does not serve is a FAIL" {
  printf '%s ring1 test windows\n' "$HOST" > "$ETC/hosts"
  lab --doctor
  fails_only 3 "this runner does not serve this host's platform, windows" WARN
  printf '%s ring1 test appliance\n' "$HOST" > "$ETC/hosts"
  lab --doctor
  fails_only 3 'is an appliance: Labyrinth never changes it' WARN
}

@test "host: a profile in the configuration folder is found, as a run finds it" {
  mkdir -p "$ETC/profiles"
  printf 'observe.toggle\n' > "$ETC/profiles/mine.profile"
  printf '%s ring1 mine ubuntu\n' "$HOST" > "$ETC/hosts"
  lab --doctor
  [ "$status" -eq 0 ]
  [ "${lines[3]}" = "OK    this host is $HOST in hosts, profile mine" ]
}

# ---- 5. the revert timer

@test "timer: a host where no revert timer can be armed is the one FAIL, with the reason" {
  touch "$LAB/NO_TIMER"
  lab --doctor
  fails_only 4 'revert timer cannot be armed: systemd is not running'
}

# ---- 6. the clock

@test "clock: a date before this release is the one FAIL" {
  printf '2020-01-01T00:00:00Z\n' > "$LAB/CLOCK"
  lab --doctor
  fails_only 5 'clock: the date is 2020-01-01, earlier than this release'
}

@test "clock: no time sync is a WARN, which does not fail the check" {
  touch "$LAB/NO_TIMESYNC"
  lab --doctor
  [ "$status" -eq 0 ]
  [ "${lines[5]}" = 'WARN  clock: no time sync running' ]
  [[ "${lines[6]}" == '      Fix: '* ]]
  [ "${lines[-1]}" = 'Ready for a run.' ]
  rm "$LAB/NO_TIMESYNC"
  touch "$LAB/TIMESYNC_UNKNOWN"
  lab --doctor
  [ "$status" -eq 0 ]
  [ "${lines[5]}" = 'WARN  clock: cannot tell whether time sync is running' ]
}

# ---- 7. the tools

@test "tools: a tool a module needs that is missing is the one FAIL, named with its module" {
  printf '\ntools: [no-such-tool-xyz]\n' >> "$LAB/phases/observe/modules/toggle/module.yml"
  sign
  lab --doctor
  fails_only 6 'tools for the test profile: observe.toggle is missing no-such-tool-xyz'
  [ "$(fix_of 6)" = 'make these tools available on this host: no-such-tool-xyz' ]
}

@test "tools: a tool that is present passes, and tools_windows is not looked at on Linux" {
  printf '\ntools: [bash]\ntools_windows: [no-such-tool-xyz]\n' >> "$LAB/phases/observe/modules/toggle/module.yml"
  sign
  lab --doctor
  [ "$status" -eq 0 ]
  [ "${lines[6]}" = 'OK    tools for the test profile: present' ]
}

@test "tools: every missing tool of every module is reported" {
  printf '\ntools: [no-such-tool-xyz, bash, no-such-tool-abc]\n' >> "$LAB/phases/observe/modules/toggle/module.yml"
  printf 'observe.toggle\nobserve.sample\n' > "$LAB/profiles/test.profile"
  printf '\ntools: [no-such-tool-xyz]\n' >> "$LAB/phases/observe/modules/sample/module.yml"
  sign
  lab --doctor
  fails_only 6 'observe.toggle is missing no-such-tool-xyz, no-such-tool-abc; observe.sample is missing no-such-tool-xyz'
}

@test "tools: a module.yml with a tools field that is not a list is a FAIL" {
  printf '\ntools: bash\n' >> "$LAB/phases/observe/modules/toggle/module.yml"
  sign
  lab --doctor
  fails_only 6 'observe.toggle has a module.yml that is not valid'
}

@test "tools: a tool name that begins with a dash is not valid" {
  printf '\ntools: [-x]\n' >> "$LAB/phases/observe/modules/toggle/module.yml"
  sign
  lab --doctor
  fails_only 6 'observe.toggle has a module.yml that is not valid'
}

@test "tools: the shipped inventory module lists ss, and a shell function is not a tool" {
  grep -qx 'tools: \[ss\]' "$REPO/phases/lockout/modules/inventory/module.yml"
  grep -qx 'tools_windows: \[Get-NetTCPConnection\]' "$REPO/phases/lockout/modules/inventory/module.yml"
  printf '\ntools: [warn]\n' >> "$LAB/phases/observe/modules/toggle/module.yml"
  sign
  lab --doctor
  fails_only 6 'observe.toggle is missing warn'
}

# ---- 8. a stale revert timer

@test "stale: an armed timer whose time passed is the one FAIL, with the way to keep or undo" {
  local a
  a="$(armed_run)"
  lab --doctor
  [ "$status" -eq 0 ]
  [ "${lines[7]}" = 'OK    no stale revert timer' ]
  printf '2000-01-01T00:05:00Z\n' > "$ROOT/state/runs/$a/timer-due"
  lab --doctor
  fails_only 7 "stale revert timer: run ${a: -4} (armed: was due 00:05 UTC)"
  [[ "$(fix_of 7)" == *"-k ${a: -4} --root $ROOT --config $ETC"* ]]
  [[ "$(fix_of 7)" == *"-u ${a: -4} --root $ROOT --config $ETC"* ]]
}

@test "stale: a timer that systemd lost is a FAIL" {
  local a
  a="$(armed_run)"
  touch "$LAB/TIMER_LOST"
  lab --doctor
  fails_only 7 "stale revert timer: run ${a: -4} (armed: timer lost)"
}

@test "stale: a kept run is not stale" {
  local a
  a="$(armed_run)"
  printf '2000-01-01T00:05:00Z\n' > "$ROOT/state/runs/$a/timer-due"
  lab -k "$a"
  [ "$status" -eq 0 ]
  lab --doctor
  [ "$status" -eq 0 ]
  [ "${lines[7]}" = 'OK    no stale revert timer' ]
}

# ---- exit codes and the Next line

@test "with two failures, Next names the fix of the first" {
  touch "$LAB/UNTRUSTED_TREE" "$LAB/NO_TIMER"
  lab --doctor
  [ "$status" -eq 20 ]
  rows
  [ "${#ROWS[@]}" -eq 8 ]
  [[ "${ROWS[1]}" == FAIL* && "${ROWS[4]}" == FAIL* ]]
  [ "$(grep -c '^Next: ' <<< "$output")" -eq 1 ]
  [ "$(grep '^Next: ' <<< "$output")" = "Next: $(fix_of 1)" ]
  [ "${lines[-1]}" = "Next: $(fix_of 1)" ]
}

@test "a WARN alone never fails it: exit 0 and Ready for a run." {
  touch "$LAB/NO_TIMESYNC"
  rm "$LAB/release.sha256"
  lab --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *'WARN  no release.sha256'* && "$output" == *'WARN  clock'* ]]
  [ "${lines[-1]}" = 'Ready for a run.' ]
  [[ "$output" != *Next:* ]]
}

@test "not root: it is refused with 20, and no check runs" {
  touch "$LAB/NOT_ADMIN"
  lab --doctor
  [ "$status" -eq 20 ]
  [ "${lines[0]}" = 'labyrinth: --doctor needs root' ]
  [[ "$output" != *'OK  '* ]]
}

@test "usage errors exit 40: an extra word, a second action, an option it does not use" {
  lab --doctor extra
  [ "$status" -eq 40 ]
  lab --doctor -k 4f2a
  [ "$status" -eq 40 ]
  lab --doctor --all
  [ "$status" -eq 40 ]
  lab --doctor --only observe.toggle
  [ "$status" -eq 40 ]
}

@test "an option the check does not use only warns" {
  lab --doctor --profile test
  [ "$status" -eq 0 ]
  [[ "$output" == *'labyrinth: warning: --profile is not used by --doctor'* ]]
  [ "${lines[-1]}" = 'Ready for a run.' ]
}

@test "a configuration folder that does not exist is a FAIL, not an error" {
  lab --doctor
  [ "$status" -eq 0 ]
  run bash "$LAB/labyrinth.sh" --doctor --root "$ROOT" --config "$BATS_TEST_TMPDIR/nowhere" < /dev/null
  [ "$status" -eq 20 ]
  [[ "$output" == *"FAIL  the configuration folder $BATS_TEST_TMPDIR/nowhere does not exist"* ]]
}

# ---- read-only

@test "nothing changes: the files, sizes, times and hashes are the same after a clean run" {
  local before after
  mkdir -p "$ROOT"
  before="$(snapshot)"
  lab --doctor
  [ "$status" -eq 0 ]
  after="$(snapshot)"
  [ "$before" = "$after" ]
}

@test "nothing changes when checks fail or warn, or with a run on the host" {
  local before after a arms
  a="$(armed_run)"
  printf '2000-01-01T00:05:00Z\n' > "$ROOT/state/runs/$a/timer-due"
  touch "$LAB/UNTRUSTED_TREE" "$LAB/NO_TIMER" "$LAB/NO_TIMESYNC"
  arms="$(wc -l < "$LAB/timer.log")"
  printf 'bad line\n' > "$ETC/never-ban"
  before="$(snapshot)"
  lab --doctor
  [ "$status" -eq 20 ]
  after="$(snapshot)"
  [ "$before" = "$after" ]
  # The revert timer double records every arming and cancelling: none was added.
  [ "$(wc -l < "$LAB/timer.log")" -eq "$arms" ]
}

@test "nothing changes on a changed release, or when asking for help, or when not root" {
  local before after
  mkdir -p "$ROOT"
  echo '# changed' >> "$LAB/core/lib.sh"
  before="$(snapshot)"
  lab --doctor
  [ "$status" -eq 20 ]
  lab --doctor -h
  after="$(snapshot)"
  [ "$before" = "$after" ]
  sign
  touch "$LAB/NOT_ADMIN"
  before="$(snapshot)"
  lab --doctor
  [ "$status" -eq 20 ]
  after="$(snapshot)"
  [ "$before" = "$after" ]
}

@test "it takes no lock and makes no run, log or folder" {
  mkdir -p "$ROOT/state"
  lab --doctor
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT/state/runs" ]
  [ ! -e "$ROOT/logs" ]
  [ -z "$(ls -A "$ROOT/state")" ]
}

# ---- help and completion

@test "-h doctor describes it, and the main help lists it" {
  run bash "$LAB/labyrinth.sh" -h doctor < /dev/null
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == 'Usage: '*' --doctor [--root DIR] [--config DIR]' ]]
  [[ "$output" == *'Exit: 0 ready, 20 a check failed or not root, 40 error.'* ]]
  run bash "$LAB/labyrinth.sh" -h < /dev/null
  [[ "$output" == *'--doctor            check that this host is ready for a run'* ]]
  [ "${#lines[@]}" -le 24 ]
}

@test "tab completion offers --doctor, and after it only the options that fit" {
  run bash "$LAB/labyrinth.sh" --complete - < /dev/null
  grep -qxF -- --doctor <<< "$output"
  run bash "$LAB/labyrinth.sh" --complete --doctor -- < /dev/null
  ! grep -qxF -- --doctor <<< "$output"
  ! grep -qxF -- --run <<< "$output"
  ! grep -qxF -- --all <<< "$output"
  grep -qxF -- --root <<< "$output"
  run bash "$LAB/labyrinth.sh" --complete --doctor '' < /dev/null
  [ -z "$output" ]
}

@test "a near miss of the action gets the real form" {
  lab doctor
  [ "$status" -eq 40 ]
  [[ "$output" == *"'doctor' is not a phase. Did you mean '$LAB/labyrinth.sh --doctor'?"* ]]
}
