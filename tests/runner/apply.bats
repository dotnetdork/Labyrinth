#!/usr/bin/env bats
# Tests for labyrinth.sh apply, keep, rollback and probe (design 00,
# section 5; design 01, sections 7 to 9; docs/Conventions.md section 3.1).
# The host-specific parts (root check, revert timer, probes) are test
# doubles (tests/fixtures/doubles.sh); real-system tests are separate.

load lab_helper

setup() {
  lab_setup
  hosts ring1
  profile observe.toggle
  answers root ring1 keep
}

@test "a full apply: gates pass, the change is made, verified, recorded and kept" {
  apply
  [ "$status" -eq 0 ]
  grep -qx 'setting=on' "$LAB/toggle.conf"
  [[ "$output" == *"[observe.toggle] applied and verified"* ]]
  [[ "$output" == *"kept: the revert timer"* ]]
  m="$(manifest)"
  for a in run_start breakglass_verified apply_start file_created run_kept; do
    [[ "$m" == *"\"action\":\"$a\""* ]] || { echo "missing $a"; return 1; }
  done
  grep -q '^arm ' "$LAB/timer.log"
  grep -q '^cancel ' "$LAB/timer.log"
}

@test "apply writes JSON-lines logs with the contract fields" {
  apply
  [ "$status" -eq 0 ]
  log="$(cat "$ROOT"/logs/run/*.jsonl)"
  [[ "$log" == *'"module":"observe.toggle","entry":"apply","level":"info","event":"toggled"'* ]]
  [[ "$log" == *"\"run\":\"$(run_id)\""* ]]
  [[ "$log" == *"\"host\":\"$HOST\""* ]]
}

@test "a module is not applied when the run manifest cannot be written" {
  [ "$(id -u)" -ne 0 ] || skip 'root can write a read-only file'
  # Arming the timer comes just before apply_start is recorded: make the
  # manifest read-only there.
  printf '%s\n' 'lab_timer_arm() { chmod a-w "$LAB_STATE_DIR/runs/$2/manifest.jsonl"; }' >> "$LAB/core/lib.sh"
  apply
  [ "$status" -eq 40 ]
  [[ "$output" == *"the run manifest cannot be written, so it is not applied"* ]]
  [ ! -e "$LAB/toggle.conf" ]
}

@test "apply needs root" {
  touch "$LAB/NOT_ADMIN"
  apply
  [ "$status" -eq 20 ]
  [ ! -e "$LAB/toggle.conf" ]
}

@test "apply needs this host in the hosts file, and never touches the manual group" {
  rm "$ETC/hosts"
  apply
  [ "$status" -eq 20 ]
  hosts manual
  apply
  [ "$status" -eq 20 ]
  [[ "$output" == *"manual group"* ]]
  [ ! -e "$LAB/toggle.conf" ]
}

@test "a --profile that differs from the hosts file is an error" {
  apply --profile other
  [ "$status" -eq 40 ]
}

@test "an empty protected set refuses to start" {
  : > "$ETC/protected-accounts"
  apply
  [ "$status" -eq 20 ]
  [ ! -e "$LAB/toggle.conf" ]
  [ ! -e "$ROOT/state/runs" ]
}

@test "no break-glass confirmation: nothing is changed" {
  answers
  apply
  [ "$status" -eq 20 ]
  [ ! -e "$LAB/toggle.conf" ]
  [ ! -e "$ROOT/state/runs" ]
}

@test "the break-glass account must be a breakglass account" {
  answers scoring1 ring1 keep
  apply
  [ "$status" -eq 20 ]
  [ ! -e "$LAB/toggle.conf" ]
}

@test "break-glass is asked once per host" {
  apply
  [ "$status" -eq 0 ]
  printf 'setting=off\n' > "$LAB/toggle.conf"
  answers ring1 keep
  apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"break-glass: confirmed earlier for root"* ]]
  grep -qx 'setting=on' "$LAB/toggle.conf"
}

@test "a wrong group name: the plan is not confirmed and nothing is changed" {
  answers root ring2
  apply
  [ "$status" -eq 20 ]
  [ ! -e "$LAB/toggle.conf" ]
}

@test "--breakglass and --confirm answer the gates without typing" {
  answers keep
  apply --breakglass root --confirm ring1
  [ "$status" -eq 0 ]
  grep -qx 'setting=on' "$LAB/toggle.conf"
}

@test "nothing to apply: no gates are asked and nothing is written" {
  profile observe.clean
  answers
  apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to apply"* ]]
  [ ! -e "$ROOT/state/runs" ]
}

@test "a plan with errors applies nothing" {
  profile observe.toggle observe.crash
  apply
  [ "$status" -eq 40 ]
  [ ! -e "$LAB/toggle.conf" ]
}

@test "a forced verify failure rolls the module back, keeping the file's contents and mode" {
  printf 'setting=off\n' > "$LAB/toggle.conf"
  chmod 600 "$LAB/toggle.conf"
  touch "$LAB/FAIL_VERIFY"
  apply
  [ "$status" -eq 30 ]
  [[ "$output" == *"verify failed"* ]]
  [[ "$output" == *"[observe.toggle] rolled back"* ]]
  grep -qx 'setting=off' "$LAB/toggle.conf"
  [ "$(stat -c %a "$LAB/toggle.conf")" = 600 ] || [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]
  [[ "$(manifest)" == *'"action":"rolled_back"'* ]]
}

@test "an apply error after a partial change rolls the module back" {
  touch "$LAB/FAIL_APPLY"
  apply
  [ "$status" -eq 40 ]
  [ ! -e "$LAB/toggle.conf" ]
}

@test "a failure stops the run: later modules are not applied" {
  profile observe.toggle observe.ask
  touch "$LAB/FAIL_VERIFY"
  answers root ring1 item-a
  apply
  [ "$status" -eq 30 ]
  [ ! -e "$LAB/APPROVED_ITEMS" ]
  [[ "$output" == *"The run stopped"* ]]
}

@test "not kept: the revert timer stays armed, and when it fires the run is rolled back" {
  answers root ring1 no
  apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"Not kept"* ]]
  [[ "$output" == *"To keep later: labyrinth.sh keep $(run_id | tail -c 5)"* ]]
  run_dir="$ROOT/state/runs/$(run_id)"
  [ -f "$run_dir/timer" ]
  timer_cmd="$(cat "$run_dir/timer")"
  [[ "$timer_cmd" == *"labyrinth.sh --root $ROOT --config $ETC rollback $(run_id)"* ]]
  id="$(run_id)"
  # The timer firing runs exactly this command.
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" rollback "$id"
  [ "$status" -eq 0 ]
  [ ! -e "$LAB/toggle.conf" ]
  [ ! -f "$run_dir/timer" ]
  grep -q '"action":"run_rolled_back"' "$run_dir/manifest.jsonl"
  # Keeping after the timer fired is too late.
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" keep "$id"
  [ "$status" -eq 20 ]
  [[ "$output" == *"too late"* ]]
}

@test "rollback is safe to run twice" {
  printf 'setting=off\n' > "$LAB/toggle.conf"
  answers root ring1 no
  apply
  id="$(run_id)"
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" rollback "$id"
  [ "$status" -eq 0 ]
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" rollback "$id"
  [ "$status" -eq 0 ]
  grep -qx 'setting=off' "$LAB/toggle.conf"
}

@test "keep later cancels the timer" {
  answers root ring1 no
  apply
  id="$(run_id)"
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" keep "$id"
  [ "$status" -eq 0 ]
  [ ! -f "$ROOT/state/runs/$id/timer" ]
  grep -qx 'setting=on' "$LAB/toggle.conf"
}

@test "keep and rollback reject bad run ids and unknown runs" {
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" keep ../x
  [ "$status" -eq 40 ]
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" rollback 20260101T000000Z-abcd
  [ "$status" -eq 40 ]
}

@test "a scored service that regresses rolls the module back and stops the run" {
  profile observe.breaker
  printf 'mail smtp mail.test 25 -\nweb http web.test 80 -\n' > "$ETC/services"
  printf '198.51.100.0/28\n' > "$ETC/scoring-allowlist"
  apply
  [ "$status" -eq 30 ]
  [[ "$output" == *"scored service regressed: web"* ]]
  [[ "$output" == *"[observe.breaker] rolled back"* ]]
  [ ! -e "$LAB/probe-state" ]
}

@test "a module that touches scored services is blocked without the scoring allowlist" {
  profile observe.breaker observe.toggle
  printf 'web http web.test 80 -\n' > "$ETC/services"
  apply
  [ "$status" -eq 20 ]
  [[ "$output" == *"[observe.breaker] blocked"* ]]
  [ ! -e "$LAB/probe-state" ]
  grep -qx 'setting=on' "$LAB/toggle.conf"
}

@test "a malformed scoring allowlist is an ERROR with its reason, not an internal error" {
  profile observe.breaker
  printf 'web http web.test 80 -\n' > "$ETC/services"
  printf 'not-an-address\n' > "$ETC/scoring-allowlist"
  apply
  [ "$status" -eq 40 ]
  n="$(grep -nxF 'ERROR    [observe.breaker] error: the scoring allowlist is malformed' <<< "$output" | cut -d: -f1)"
  [ -n "$n" ]
  [[ "${lines[n]}" =~ ^\ {11}.*not\ an\ address\ or\ CIDR:\ not-an-address$ ]]
  [[ "$output" != *'internal error'* ]]
  [[ "$output" == *'apply finished: exit 40 (error)'* ]]
}

@test "an approval module changes only what a person approves" {
  profile observe.ask
  answers root ring1 'item-a' keep
  apply
  [ "$status" -eq 0 ]
  grep -qx 'item-a' "$LAB/APPROVED_ITEMS"
  answers ring1 '' keep
  rm "$LAB/APPROVED_ITEMS"
  apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing approved"* ]]
  [ ! -e "$LAB/APPROVED_ITEMS" ]
}

@test "a manual-only module is never applied" {
  profile observe.manual
  apply
  [[ "$output" == *"checklist"* ]]
  [[ "$output" == *"nothing to apply"* ]]
}

@test "a run lock held by a live process blocks apply" {
  mkdir -p "$ROOT/state/lock"
  printf '%s\n' "$$" > "$ROOT/state/lock/pid"
  apply
  [ "$status" -eq 20 ]
  [ ! -e "$LAB/toggle.conf" ]
}

@test "a stale run lock is taken over" {
  mkdir -p "$ROOT/state/lock"
  printf '999999\n' > "$ROOT/state/lock/pid"
  apply
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT/state/lock" ]
}

@test "probe reports every service and exits 30 when one fails" {
  printf 'web http web.test 80 -\nmail smtp mail.test 25 -\n' > "$ETC/services"
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" probe
  [ "$status" -eq 0 ]
  [[ "$output" == *"web pass"* ]]
  printf 'mail.test fail\n' > "$LAB/probe-state"
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" probe
  [ "$status" -eq 30 ]
  [[ "$output" == *"mail fail"* ]]
  [ ! -e "$ROOT" ]
}

@test "an armed revert timer records when it fires" {
  answers root ring1 no
  apply
  [ "$status" -eq 0 ]
  grep -Eqx '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' "$ROOT/state/runs/$(run_id)/timer-due"
}

@test "keep that cannot cancel the revert timer keeps nothing and exits 40" {
  answers root ring1 no
  apply
  id="$(run_id)"
  printf '%s\n' 'lab_timer_cancel() { return 1; }' >> "$LAB/core/lib.sh"
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" keep "$id"
  [ "$status" -eq 40 ]
  [[ "$output" == *"could not be cancelled"* ]]
  [[ "$output" != *"kept: the revert timer"* ]]
  [ -f "$ROOT/state/runs/$id/timer" ]
  run grep -q '"action":"run_kept"' "$ROOT/state/runs/$id/manifest.jsonl"
  [ "$status" -ne 0 ]
}

@test "rollback still finishes when the revert timer cannot be removed" {
  answers root ring1 no
  apply
  id="$(run_id)"
  printf '%s\n' 'lab_timer_cancel() { return 1; }' >> "$LAB/core/lib.sh"
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" rollback "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not be removed"* ]]
  [ ! -e "$LAB/toggle.conf" ]
  grep -q '"action":"run_rolled_back"' "$ROOT/state/runs/$id/manifest.jsonl"
}
