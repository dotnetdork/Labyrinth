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
  grep -qx '  Did:       applied and verified' <<< "$output"
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
  [[ "$output" == *"not applied: the run manifest cannot be written"* ]]
  [ ! -e "$LAB/toggle.conf" ]
}

@test "apply needs root" {
  touch "$LAB/NOT_ADMIN"
  apply
  [ "$status" -eq 20 ]
  [ ! -e "$LAB/toggle.conf" ]
}

@test "apply, keep and rollback refuse code or data another account can change" {
  answers root ring1 no
  apply
  [ "$status" -eq 0 ]
  id="$(run_id)"
  touch "$LAB/UNTRUSTED"
  rm "$LAB/toggle.conf"
  apply
  [ "$status" -eq 20 ]
  [[ "$output" == *"$LAB can be changed by an account other than root"* ]]
  [ ! -e "$LAB/toggle.conf" ]
  printf 'setting=on\n' > "$LAB/toggle.conf"
  for cmd in keep rollback; do
    run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" "$cmd" "$id"
    [ "$status" -eq 20 ] || { echo "$cmd: $status"; return 1; }
  done
  # Nothing was rolled back, and the timer is still armed.
  grep -qx 'setting=on' "$LAB/toggle.conf"
  [ -f "$ROOT/state/runs/$id/timer" ]
}

@test "an entry point gets no standard input, so it cannot take the operator's answers" {
  printf '%s\n' '#!/usr/bin/env bash' \
    'if IFS= read -r l; then printf "%s\n" "$l" > "$LAB_ROOT/STDIN_SEEN"; fi' \
    'echo "toggle: would set setting=on in toggle.conf"' 'exit 10' > "$LAB/phases/observe/modules/toggle/plan.sh"
  apply
  [ "$status" -eq 0 ]
  [ ! -e "$LAB/STDIN_SEEN" ]
  grep -qx 'setting=on' "$LAB/toggle.conf"
}

@test "the host comes from the system, not from HOSTNAME" {
  HOSTNAME=not-this-host apply
  [ "$status" -eq 0 ]
  grep -qx 'setting=on' "$LAB/toggle.conf"
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
  [[ "$output" == *"Break-glass account root: confirmed earlier, so not asked again."* ]]
  grep -qx 'setting=on' "$LAB/toggle.conf"
}

@test "break-glass: the console session found is recorded; with none, a warning and the run goes on" {
  apply
  [ "$status" -eq 0 ]
  [[ "$(manifest)" == *'"action":"breakglass_verified","target":"root"'*'"note":"console session 1"'* ]]
  rm "$ROOT/state/breakglass"
  touch "$LAB/NO_CONSOLE"
  printf 'setting=off\n' > "$LAB/toggle.conf"
  apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: no session for root was found at this host's console"* ]]
  [[ "$(manifest)" == *'"note":"no console session found"'* ]]
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
  [[ "$output" == *"its verify script failed"* ]]
  grep -qx '  Did:       rolled back' <<< "$output"
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
  [[ "$output" == *"a scored service stopped working after the change: web"* ]]
  grep -qx '  Found:     web: fail (fake probe); it passed before' <<< "$output"
  grep -qx '  Did:       rolled back' <<< "$output"
  [ ! -e "$LAB/probe-state" ]
}

@test "a module that touches scored services is blocked without the scoring allowlist" {
  profile observe.breaker observe.toggle
  printf 'web http web.test 80 -\n' > "$ETC/services"
  apply
  [ "$status" -eq 20 ]
  grep -qx 'BLOCKED  Service breaker sample (observe.breaker)' <<< "$output"
  [ ! -e "$LAB/probe-state" ]
  grep -qx 'setting=on' "$LAB/toggle.conf"
}

@test "a malformed scoring allowlist is an ERROR with its reason, not an internal error" {
  profile observe.breaker
  printf 'web http web.test 80 -\n' > "$ETC/services"
  printf 'not-an-address\n' > "$ETC/scoring-allowlist"
  apply
  [ "$status" -eq 40 ]
  grep -qx 'ERROR    Service breaker sample (observe.breaker)' <<< "$output"
  grep -qx '  Problem:   the scoring allowlist is malformed' <<< "$output"
  grep -qx '  Found:     scoring-allowlist:1: not an address or CIDR: not-an-address' <<< "$output"
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

fp() { printf '%s' "$1" | sha256sum | cut -c1-12; }

@test "approval: the plan lists each item with its fingerprint and category" {
  profile observe.ask
  plan
  [ "$status" -eq 10 ]
  grep -qx "  Item:      item-a@$(fp item-a) (sample): first sample item" <<< "$output"
  grep -qx "  Item:      item-c@$(fp item-c) (other): an item of another category" <<< "$output"
}

@test "approval: category: approves every item of it; an id not in the plan is ignored" {
  profile observe.ask
  answers root ring1 'category:sample nope item-a' keep
  apply
  [ "$status" -eq 0 ]
  [ "$(cat "$LAB/APPROVED_ITEMS")" = "$(printf 'item-a\nitem-b')" ]
  [[ "$output" == *'Not in its plan, so ignored: nope'* ]]
  grep -qx '  Approved:  item-a, item-b' <<< "$output"
  grep -q "\"note\":\"risk approval, approved item-a@$(fp item-a) item-b@$(fp item-b)\"" <<< "$(manifest)"
}

@test "approval: an answer that is not ids and categories blocks the module" {
  profile observe.ask
  answers root ring1 'item-a;reboot' keep
  apply
  [ "$status" -eq 20 ]
  grep -qx '  Problem:   not an item id or a category: item-a;reboot' <<< "$output"
  [ ! -e "$LAB/APPROVED_ITEMS" ]
}

@test "approval: --approve answers without the prompt; a changed item is refused" {
  profile observe.ask
  answers no
  apply --break-glass root --confirm-group ring1 \
    --approve "observe.ask:item-a@$(fp item-a),observe.ask:item-b@000000000000,observe.ask:item-z@$(fp item-a),observe.other:item-a@$(fp item-a)"
  [ "$status" -eq 0 ]
  [[ "$output" != *'Type the ids'* ]]
  [ "$(cat "$LAB/APPROVED_ITEMS")" = item-a ]
  grep -qx "Not in this run's plan, so ignored: observe.ask:item-z@$(fp item-a)" <<< "$output"
  grep -qx "Not in this run's plan, so ignored: observe.other:item-a@$(fp item-a)" <<< "$output"
  grep -qx '  Found:     item-b changed since the plan, so it is left alone' <<< "$output"
  grep -q '"action":"approval_refused","target":"item-b"' <<< "$(manifest)"
  # Approvals are never stored in the revert timer's command line.
  local timer
  timer="$(cat "$ROOT/state/runs/$(run_id)/timer")"
  [[ "$timer" == *" rollback $(run_id)"* ]]
  [[ "$timer" != *approve* ]]
}

@test "approval: a pre-approval rule approves an item without asking; the prompt asks for the rest" {
  profile observe.ask
  # 'other' is not in the module's pre_approvable list; lockout.elsewhere is
  # for other hosts.
  printf '# rules\nobserve.ask sample item-a\nobserve.ask other *\nlockout.elsewhere sample item-a\n' > "$ETC/pre-approved"
  plan
  [ "$status" -eq 10 ]
  grep -qx '  Note:      pre-approved, so applied without asking: item-a' <<< "$output"
  grep -qx 'Pre-approval ignored: observe.ask does not let category other be pre-approved: observe.ask other \*' <<< "$output"
  [[ "$output" != *lockout.elsewhere* ]]
  answers root ring1 item-b keep
  apply
  [ "$status" -eq 0 ]
  [ "$(cat "$LAB/APPROVED_ITEMS")" = "$(printf 'item-a\nitem-b')" ]
  grep -qx '  Approved:  item-a (pre-approved)' <<< "$output"
  grep -qx '  Approved:  item-a (pre-approved), item-b' <<< "$output"
  grep -q "\"note\":\"risk approval, approved item-a@$(fp item-a) item-b@$(fp item-b), pre-approved item-a@$(fp item-a)\"" <<< "$(manifest)"
}

@test "approval: when every item is pre-approved, nothing is asked" {
  profile observe.ask
  sed -i '/item-c/d' "$LAB/phases/observe/modules/ask/plan.sh"
  printf 'observe.ask sample *\n' > "$ETC/pre-approved"
  answers root ring1 keep
  apply
  [ "$status" -eq 0 ]
  [[ "$output" != *'Type the ids'* ]]
  [ "$(cat "$LAB/APPROVED_ITEMS")" = "$(printf 'item-a\nitem-b')" ]
  grep -qx '  Approved:  item-a (pre-approved), item-b (pre-approved)' <<< "$output"
}

@test "approval: pre-approval rules and --approve entries add up" {
  profile observe.ask
  printf 'observe.ask sample item-b\n' > "$ETC/pre-approved"
  answers no
  apply --break-glass root --confirm-group ring1 --approve "observe.ask:item-c@$(fp item-c)"
  [ "$status" -eq 0 ]
  [[ "$output" != *'Type the ids'* ]]
  [ "$(cat "$LAB/APPROVED_ITEMS")" = "$(printf 'item-b\nitem-c')" ]
}

@test "approval: a malformed pre-approved file is an error, and a module.yml may not misuse pre_approvable" {
  profile observe.ask
  printf 'observe.ask sample\n' > "$ETC/pre-approved"
  plan
  [ "$status" -eq 40 ]
  [[ "$output" == *'pre-approved is malformed'*':1: expected: module-id category item-id (or * for every item)'* ]]
  rm "$ETC/pre-approved"
  profile observe.toggle
  printf 'pre_approvable: [sample]\n' >> "$LAB/phases/observe/modules/toggle/module.yml"
  plan
  [ "$status" -eq 40 ]
  [[ "$output" == *'pre_approvable is only for approval modules'* ]]
}

@test "approval: an approval plan with a malformed item line is an ERROR" {
  profile observe.ask
  printf '#!/usr/bin/env bash\nprintf "item\\tBad Id\\tsample\\t%%s\\tx\\n" 2a2c17aaaf66\nexit 10\n' \
    > "$LAB/phases/observe/modules/ask/plan.sh"
  plan
  [ "$status" -eq 40 ]
  grep -q '  Problem:   its plan listed an item wrongly' <<< "$output"
  answers root ring1 item-a keep
  apply
  [ "$status" -eq 40 ]
  [ ! -e "$LAB/APPROVED_ITEMS" ]
}

@test "secret: a new password is shown only on the terminal and stored nowhere in the data root" {
  profile observe.rotate
  printf 'old\n' > "$LAB/rotate.pw"
  printf 'recorded\n' > "$LAB/tty.in"
  apply
  [ "$status" -eq 0 ]
  pw="$(sed -n 's/^      //p' "$LAB/tty.out")"
  [[ "$pw" =~ ^[A-Za-z0-9_.+=-]{20}$ ]]
  [[ "$output" != *"$pw"* ]]
  run grep -rqF -- "$pw" "$ROOT"
  [ "$status" -eq 1 ]
  grep -qx '[0-9a-f]\{64\}' "$LAB/rotate.pw"
}

@test "secret: without a terminal, the password is not changed" {
  profile observe.rotate
  printf 'old\n' > "$LAB/rotate.pw"
  touch "$LAB/NO_TTY"
  apply
  [ "$status" -eq 20 ]
  [[ "$output" == *"no terminal to show the new password on"* ]]
  grep -qx 'old' "$LAB/rotate.pw"
}

@test "secret: a password nobody recorded is put back" {
  profile observe.rotate
  printf 'old\n' > "$LAB/rotate.pw"
  apply
  [ "$status" -eq 40 ]
  [[ "$output" == *"was not recorded"* ]]
  grep -qx 'old' "$LAB/rotate.pw"
  pw="$(sed -n 's/^      //p' "$LAB/tty.out")"
  run grep -rqF -- "$pw" "$ROOT"
  [ "$status" -eq 1 ]
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

@test "rollback stops a live run that holds the lock, and its children, before undoing it" {
  printf 'setting=off\n' > "$LAB/toggle.conf"
  answers root ring1 no
  apply
  id="$(run_id)"
  bash -c 'sleep 300; :' &
  local holder=$!
  mkdir -p "$ROOT/state/lock"
  printf '%s\n' "$holder" > "$ROOT/state/lock/pid"
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" rollback "$id"
  wait "$holder" 2> /dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *"stopping the Labyrinth run (pid $holder)"* ]]
  [[ "$output" != *"without the run lock"* ]]
  ! kill -0 "$holder" 2> /dev/null || return 1
  grep -qx 'setting=off' "$LAB/toggle.conf"
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
  [[ "$output" == *"[web] pass"* ]]
  printf 'mail.test fail\n' > "$LAB/probe-state"
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" probe
  [ "$status" -eq 30 ]
  [[ "$output" == *"[mail] fail"* ]]
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
