#!/usr/bin/env bats
# labyrinth.sh with no action: the status of this host and the next step;
# and --manual, the full manual (docs/Conventions.md section 3.1). The
# host-specific parts are test doubles (tests/fixtures/doubles.sh).

load lab_helper

setup() {
  lab_setup
  hosts ring1
  profile observe.toggle
}

# status_of [ARG...]: the status, with the test's data root and configuration
status_of() { run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" "$@" < /dev/null; }

# fake_run PHASE N [ACTION NOTE]: a run of PHASE, with a manifest that ends
# with ACTION (run_kept by default), as -r would leave it.
fake_run() {
  local id="20261002T14030${2}Z-000${2}" dir
  dir="$ROOT/state/runs/$id"
  mkdir -p "$dir"
  printf '{"ts":"2026-10-02T14:03:0%sZ","run":"%s","module":"","action":"run_start","target":"%s","note":"phase %s, profile test, group ring1"}\n' \
    "$2" "$id" "$HOST" "$1" > "$dir/manifest.jsonl"
  printf '{"ts":"2026-10-02T14:04:0%sZ","run":"%s","module":"","action":"%s","target":"","note":"%s"}\n' \
    "$2" "$id" "${3:-run_kept}" "${4:-}" >> "$dir/manifest.jsonl"
}

@test "a new host: its group, no runs, no timer, and the first phase to preview" {
  status_of
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "labyrinth $(bash "$LAB/labyrinth.sh" -V | head -n 1 | cut -d' ' -f2): status of host $HOST" ]
  [ "${lines[1]}" = 'Group:    ring1, profile test' ]
  [ "${lines[2]}" = 'lockout   not run' ]
  [ "${lines[3]}" = 'observe   not run' ]
  [ "${lines[4]}" = 'deceive   not run' ]
  [ "${lines[5]}" = 'sustain   not run' ]
  [ "${lines[6]}" = 'Timer:    none armed' ]
  [ "${lines[7]}" = "Next: preview lockout: '$LAB/labyrinth.sh lockout --root $ROOT --config $ETC'" ]
  [ "${#lines[@]}" -eq 8 ]
}

@test "the status only reads: it creates nothing and takes no lock" {
  status_of
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT" ]
}

@test "with no hosts file, or this host not in it, the next step is to list it" {
  rm "$ETC/hosts"
  status_of
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "Group:    unknown: there is no $ETC/hosts yet" ]
  [ "${lines[-1]}" = "Next: list this host in $ETC/hosts, then run '$LAB/labyrinth.sh --root $ROOT --config $ETC' again." ]
  printf 'otherhost ring1 test ubuntu\n' > "$ETC/hosts"
  status_of
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "Group:    unknown: this host is not in $ETC/hosts" ]
  [[ "${lines[-1]}" == "Next: list this host in $ETC/hosts"* ]]
}

@test "a malformed hosts file is named, and still exits 0" {
  printf 'not a host line\n' > "$ETC/hosts"
  status_of
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "Group:    unknown: $ETC/hosts is malformed" ]
  [ "${lines[-1]}" = "Next: correct $ETC/hosts, then run '$LAB/labyrinth.sh --root $ROOT --config $ETC' again." ]
}

@test "a host in the manual group is configured by hand" {
  hosts manual
  status_of
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = 'Group:    manual, profile test' ]
  [ "${lines[-1]}" = 'Next: none: this host is in the manual group; configure it by hand, from its runbook.' ]
}

@test "an armed timer comes first: its run, when it fires, and the keep command" {
  answers root ring1 no
  apply
  [ "$status" -eq 0 ]
  id="$(run_id)"
  status_of
  [ "$status" -eq 0 ]
  [[ "${lines[3]}" == "observe   armed: undo at "*" UTC (run ${id: -4}, ${id:0:4}-${id:4:2}-${id:6:2} ${id:9:2}:${id:11:2} UTC)" ]]
  [[ "$output" == *"Timer:    run ${id: -4} is undone at "* ]]
  [ "${lines[-1]}" = "Next: check you can log in from a NEW session, then '$LAB/labyrinth.sh -k ${id: -4} --root $ROOT --config $ETC'." ]
}

@test "the latest run of each phase is shown; after every phase, the next step is --probe" {
  fake_run lockout 1
  fake_run observe 2
  fake_run deceive 3
  fake_run sustain 4
  fake_run observe 5 run_rolled_back 'exit 0'
  status_of
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = 'lockout   kept (run 0001, 2026-10-02 14:03 UTC)' ]
  [ "${lines[3]}" = 'observe   undone (run 0005, 2026-10-02 14:03 UTC)' ]
  # The undone phase is the next one to preview.
  [ "${lines[-1]}" = "Next: preview observe: '$LAB/labyrinth.sh observe --root $ROOT --config $ETC'" ]
  fake_run observe 6
  status_of
  [ "${lines[3]}" = 'observe   kept (run 0006, 2026-10-02 14:03 UTC)' ]
  [ "${lines[-1]}" = "Next: test the scored services: '$LAB/labyrinth.sh --probe --root $ROOT --config $ETC'" ]
}

@test "a --no-revert run shows as 'no revert'" {
  fake_run lockout 1 run_no_revert 'no revert timer: --no-revert'
  status_of
  [ "${lines[2]}" = 'lockout   no revert (run 0001, 2026-10-02 14:03 UTC)' ]
  [ "${lines[-1]}" = "Next: preview observe: '$LAB/labyrinth.sh observe --root $ROOT --config $ETC'" ]
}

@test "not as root: the usage lines and how to run it as root, still exit 0" {
  touch "$LAB/NOT_ADMIN"
  status_of
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Usage: $LAB/labyrinth.sh PHASE                preview a phase: nothing changes" ]
  [[ "$output" == *'The status of this host needs root: sudo '* ]]
  [[ "$output" == *"'$LAB/labyrinth.sh -h' lists every action."* ]]
  [[ "$output" != *'Group:'* ]]
  [ ! -e "$ROOT" ]
}

@test "an option only a preview or -r uses makes the line a preview, not the status" {
  status_of -P test
  [ "$status" -eq 40 ]
  [[ "$output" == *'no phase or action given'* ]]
}

# The manual. Stand-ins for man and less record how they were called.
stub_tools() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/man" << EOF
#!/bin/bash
printf 'man %s\n' "\$*" >> '$BATS_TEST_TMPDIR/tools.log'
if [[ "\$1" == -w ]]; then [[ -e '$BATS_TEST_TMPDIR/INSTALLED' ]]; exit; fi
if [[ "\$1" == -l && -e '$BATS_TEST_TMPDIR/MAN_L' ]]; then printf 'man -l page\n'; exit 0; fi
if [[ "\$1" == -l ]]; then exit 1; fi
printf 'installed page\n'
EOF
  cat > "$BATS_TEST_TMPDIR/bin/less" << EOF
#!/bin/bash
printf 'less\n' >> '$BATS_TEST_TMPDIR/tools.log'
cat
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/man" "$BATS_TEST_TMPDIR/bin/less"
}

manual() { PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash "$LAB/labyrinth.sh" --manual "$@" < /dev/null; }

@test "--manual opens this copy's man page with man -l, else pages it through less" {
  stub_tools
  # Another program can own the name 'laby': its page is never asked for.
  touch "$BATS_TEST_TMPDIR/INSTALLED"
  mkdir -p "$LAB/manual"
  printf '.TH LABY 1\n.SH NAME\nMANUALMARKER\n' > "$LAB/manual/labyrinth.1"
  touch "$BATS_TEST_TMPDIR/MAN_L"
  manual
  [ "$status" -eq 0 ]
  [ "$output" = 'man -l page' ]
  grep -q "^man -l .*/manual/labyrinth.1$" "$BATS_TEST_TMPDIR/tools.log"
  [[ "$(cat "$BATS_TEST_TMPDIR/tools.log")" != *'man laby'* && "$(cat "$BATS_TEST_TMPDIR/tools.log")" != *'man -w'* ]]
  rm "$BATS_TEST_TMPDIR/MAN_L" "$BATS_TEST_TMPDIR/tools.log"
  manual
  [ "$status" -eq 0 ]
  [[ "$output" == *MANUALMARKER* ]]
  grep -qx 'less' "$BATS_TEST_TMPDIR/tools.log"
}

@test "--manual falls back to the Markdown source, and says so when there is no manual" {
  stub_tools
  manual
  [ "$status" -eq 40 ]
  [[ "$output" == *"this copy has no manual: there is no "*"/manual/labyrinth.1"* ]]
  mkdir -p "$LAB/docs/manual"
  printf '# Labyrinth manual\nSOURCEMARKER @CMD@\n<!-- linux -->\nLINUXONLY\n<!-- end -->\n<!-- windows -->\nWINDOWSONLY\n<!-- end -->\n' \
    > "$LAB/docs/manual/labyrinth.md"
  manual
  [ "$status" -eq 0 ]
  [[ "$output" == *SOURCEMARKER* ]]
  # A checkout has the splitter: the Linux text, not the template.
  mkdir -p "$LAB/tools/manual"
  cp "$REPO/tools/manual/split.sh" "$LAB/tools/manual/"
  manual
  [ "$status" -eq 0 ]
  [[ "$output" == *'SOURCEMARKER sudo ./labyrinth.sh'* ]]
  [[ "$output" == *LINUXONLY* ]]
  [[ "$output" != *WINDOWSONLY* && "$output" != *'<!--'* ]]
}

@test "--manual needs no root and creates nothing" {
  stub_tools
  mkdir -p "$LAB/manual"
  printf '.TH LABY 1\n.SH NAME\nMANUALMARKER\n' > "$LAB/manual/labyrinth.1"
  touch "$LAB/NOT_ADMIN"
  manual --root "$ROOT" --config "$ETC"
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT" ]
}

@test "--no-revert: no timer, no keep question, recorded, and undone only by -u" {
  answers root ring1
  apply --no-revert
  [ "$status" -eq 0 ]
  id="$(run_id)"
  grep -qx 'setting=on' "$LAB/toggle.conf"
  [[ "$(cat "$LAB/timer.log" 2> /dev/null)" != *arm* ]]
  [ ! -e "$ROOT/state/runs/$id/timer" ]
  [[ "$output" == *'No revert timer (--no-revert): the changes stay until you undo them.'* ]]
  [[ "$output" != *'Type keep to keep'* ]]
  [[ "$output" == *"so they stay. To undo them: $LAB/labyrinth.sh -u ${id: -4}"* ]]
  [[ "$output" == *'Revert timer: none (--no-revert).'* ]]
  [[ "$(manifest)" == *'"action":"run_no_revert"'* ]]
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" --history < /dev/null
  [[ "$output" == *"$id observe"*'no revert'* ]]
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" -k "$id" < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to keep: run $id has no revert timer (--no-revert), so its changes stay"* ]]
  [[ "$(manifest)" != *'"action":"run_kept"'* ]]
  run bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" -u "$id" < /dev/null
  [ "$status" -eq 0 ]
  [ ! -e "$LAB/toggle.conf" ]
}

@test "--no-revert keeps nothing early: there is no timer to keep it from" {
  profile observe.keeper
  printf 'web http web.test 80 -\n' > "$ETC/services"
  answers root ring1
  apply --no-revert
  [ "$status" -eq 0 ]
  [[ "$(manifest)" != *'"action":"module_kept"'* ]]
  [[ "$(manifest)" != *'"action":"run_kept"'* ]]
  [[ "$output" != *'is kept once it verifies'* ]]
}

@test "-h with --no-revert is help: nothing runs" {
  answers root ring1
  apply --no-revert -h
  [ "$status" -eq 0 ]
  [ ! -e "$LAB/toggle.conf" ]
  [ ! -e "$ROOT" ]
}
