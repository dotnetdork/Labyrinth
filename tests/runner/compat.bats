#!/usr/bin/env bats
# Compatibility suite for labyrinth.sh (docs/Conventions.md section 3.1).
# Every command form here works today and must keep working: operators
# have learned them, and an armed revert timer runs its stored command
# line long after the runner that armed it was replaced. Change the
# runner, never this file, to make a change pass.
#
# Checked here: exit codes, the stored timer line, the prompt order and
# the run header. Wording of help and errors is not checked here.
# Pinned output text that other suites own: "applied and verified",
# "kept: the revert timer", "rolled back", "The run stopped", "Not kept",
# "too late", "nothing approved", "nothing to apply", "checklist"
# (apply.bats); "check: nothing to do", "unknown key color",
# "protected set is not loaded" (labyrinth.bats).

load lab_helper

setup() {
  lab_setup
  hosts ring1
  profile observe.toggle
  answers root ring1 keep
}

lab() { run bash "$LAB/labyrinth.sh" "$@"; }

@test "compat: a bare phase plans, with options before, after or around it" {
  lab --profile test --root "$ROOT" --config "$ETC" observe
  [ "$status" -eq 10 ]
  lab observe --profile test --root "$ROOT" --config "$ETC"
  [ "$status" -eq 10 ]
  lab --profile test observe --root "$ROOT" --config "$ETC"
  [ "$status" -eq 10 ]
  [ ! -e "$ROOT" ]
}

@test "compat: --apply before or after the phase applies" {
  lab --root "$ROOT" --config "$ETC" --apply observe < "$ANSWERS"
  [ "$status" -eq 0 ]
  grep -qx 'setting=on' "$LAB/toggle.conf"
  printf 'setting=off\n' > "$LAB/toggle.conf"
  answers ring1 keep
  lab --root "$ROOT" --config "$ETC" observe --apply < "$ANSWERS"
  [ "$status" -eq 0 ]
  grep -qx 'setting=on' "$LAB/toggle.conf"
}

@test "compat: --breakglass and --confirm answer the gates" {
  answers keep
  lab --root "$ROOT" --config "$ETC" --apply --breakglass root --confirm ring1 observe < "$ANSWERS"
  [ "$status" -eq 0 ]
  grep -qx 'setting=on' "$LAB/toggle.conf"
}

@test "compat: --profile on apply must match the hosts file" {
  lab --root "$ROOT" --config "$ETC" --apply --profile test observe < "$ANSWERS"
  [ "$status" -eq 0 ]
  lab --root "$ROOT" --config "$ETC" --apply --profile other observe < "$ANSWERS"
  [ "$status" -eq 40 ]
}

@test "compat: the stored revert-timer command line runs a rollback" {
  answers root ring1 no
  apply
  [ "$status" -eq 0 ]
  id="$(run_id)"
  run_dir="$ROOT/state/runs/$id"
  line="$(cat "$run_dir/timer")"
  [[ "$line" == *"labyrinth.sh --root $ROOT --config $ETC rollback $id" ]]
  read -ra words <<< "$line"
  [ -x "${words[0]}" ]
  # Run the stored words exactly as the timer would.
  run "${words[@]}"
  [ "$status" -eq 0 ]
  grep -q '"action":"run_rolled_back"' "$run_dir/manifest.jsonl"
  [ ! -e "$LAB/toggle.conf" ]
}

@test "compat: keep <run> and rollback <run> take options before or after" {
  answers root ring1 no
  apply
  id="$(run_id)"
  lab keep "$id" --root "$ROOT" --config "$ETC"
  [ "$status" -eq 0 ]
  printf 'setting=off\n' > "$LAB/toggle.conf"
  answers ring1 no
  apply
  id="$(run_id)"
  lab --root "$ROOT" --config "$ETC" rollback "$id"
  [ "$status" -eq 0 ]
  lab rollback "$id" --root "$ROOT" --config "$ETC"
  [ "$status" -eq 0 ]
  lab --root "$ROOT" --config "$ETC" keep "$id"
  [ "$status" -eq 20 ]
  [[ "$output" == *"too late"* ]]
}

@test "compat: the prompts come in order: break-glass, group, approval, keep" {
  profile observe.ask
  answers root ring1 item-a keep
  apply
  [ "$status" -eq 0 ]
  local prev=-1 at p
  for p in 'Break-glass check:' 'Type the group name (ring1)' 'Type the ids of the items' 'Type keep to keep'; do
    at="$(awk -v s="$p" '{ i = index($0, s); if (i) { print NR * 100000 + i; exit } }' <<< "$output")"
    [ -n "$at" ] || { echo "missing prompt: $p"; return 1; }
    (( at > prev )) || { echo "out of order: $p"; return 1; }
    prev="$at"
  done
}

@test "compat: the run header names the run, and apply's run is the one recorded" {
  plan
  grep -Eq 'run [0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}' <<< "$output"
  apply
  [ "$status" -eq 0 ]
  [ -d "$ROOT/state/runs/$(run_id)" ]
}

@test "compat: --version, -h and --help exit 0" {
  lab --version
  [ "$status" -eq 0 ]
  lab -h
  [ "$status" -eq 0 ]
  lab --help
  [ "$status" -eq 0 ]
}

@test "compat: argument errors exit 40" {
  lab --root "$ROOT" --config "$ETC" nosuchphase
  [ "$status" -eq 40 ]
  lab --root relative/root --config "$ETC" observe
  [ "$status" -eq 40 ]
  lab --profile 'a;b' --root "$ROOT" --config "$ETC" observe
  [ "$status" -eq 40 ]
  lab --root "$ROOT" --config "$ETC" keep ../x
  [ "$status" -eq 40 ]
  lab --root "$ROOT" --config "$ETC" rollback 20260101T000000Z-abcd
  [ "$status" -eq 40 ]
  lab --root "$ROOT" --config "$ETC" probe extra
  [ "$status" -eq 40 ]
  lab --root "$ROOT" --config "$ETC" observe --profile
  [ "$status" -eq 40 ]
  [ ! -e "$LAB/toggle.conf" ]
}

@test "compat: probe exits 0, then 30 when a service fails, and writes nothing" {
  printf 'web http web.test 80 -\n' > "$ETC/services"
  lab probe --root "$ROOT" --config "$ETC"
  [ "$status" -eq 0 ]
  printf 'web.test fail\n' > "$LAB/probe-state"
  lab --root "$ROOT" --config "$ETC" probe
  [ "$status" -eq 30 ]
  [ ! -e "$ROOT" ]
}
