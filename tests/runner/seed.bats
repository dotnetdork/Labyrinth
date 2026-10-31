#!/usr/bin/env bats
# labyrinth.sh --new-seed and --seed-check (design 16, section 4.1;
# docs/Conventions.md section 3.1). The terminal is a test double
# (tests/fixtures/doubles.sh): what the program writes there goes to
# $LAB/tty.out, and each line it reads is the next line of $LAB/tty.in.
# Seed.Tests.ps1 checks the same for labyrinth.ps1.

load lab_helper

setup() {
  lab_setup
  GOOD='K7QM-2XRP-9D4V-HT3N-B8WC-6FJZ-QM2E-L92G'
  OTHER='2345-6789-ABCD-EFGH-JKLM-NPQR-STUV-JLNP'
  TYPO='L7QM-2XRP-9D4V-HT3N-B8WC-6FJZ-QM2E-L92G'
}

# streams ARG...: run labyrinth.sh with stdout ($OUT) and stderr ($ERR) apart.
streams() {
  CODE=0
  OUT="$(bash "$LAB/labyrinth.sh" --root "$ROOT" --config "$ETC" "$@" 2> "$BATS_TEST_TMPDIR/err" < /dev/null)" || CODE=$?
  ERR="$(cat "$BATS_TEST_TMPDIR/err")"
}

# typed LINE...: the lines the operator types at the terminal, in order
typed() { printf '%s\n' "$@" > "$LAB/tty.in"; }

# stored KEY: the value of KEY in seed.conf, or nothing
stored() { sed -n "s/^$1=//p" "$ETC/seed.conf" 2> /dev/null || true; }

@test "--new-seed needs root, and saves nothing without it" {
  touch "$LAB/NOT_ADMIN"
  typed recorded
  streams --new-seed
  [ "$CODE" -eq 20 ]
  [[ "$ERR" == *'--new-seed needs root'* ]]
  [[ "$ERR" == *'Run it again as root'* ]]
  [ ! -e "$ETC/seed.conf" ]
  [ ! -e "$LAB/tty.out" ]
}

@test "--new-seed needs a terminal, and saves nothing without one" {
  touch "$LAB/NO_TTY"
  streams --new-seed
  [ "$CODE" -eq 20 ]
  [[ "$ERR" == *'--new-seed needs a terminal to show the seed on'* ]]
  [ ! -e "$ETC/seed.conf" ]
  [ ! -e "$LAB/tty.out" ]
}

@test "--new-seed needs the configuration folder" {
  typed recorded
  CODE=0
  OUT="$(bash "$LAB/labyrinth.sh" --new-seed --root "$ROOT" --config "$BATS_TEST_TMPDIR/missing" 2> "$BATS_TEST_TMPDIR/err" < /dev/null)" || CODE=$?
  ERR="$(cat "$BATS_TEST_TMPDIR/err")"
  [ "$CODE" -eq 40 ]
  [[ "$ERR" == *"the configuration folder does not exist: $BATS_TEST_TMPDIR/missing"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/missing" ]
}

@test "--new-seed saves a valid seed with mode 600 and shows it only on the terminal" {
  local seed
  typed recorded
  streams --new-seed
  [ "$CODE" -eq 0 ]
  seed="$(stored DECOY_SEED)"
  [[ "$seed" =~ ^([2-9A-HJ-NP-Z]{4}-){7}[2-9A-HJ-NP-Z]{4}$ ]]
  [ "$(stat -c %a "$ETC/seed.conf")" = 600 ]
  [[ "$OUT" == "Saved this host's decoy seed in $ETC/seed.conf."$'\n'"Post it in the team chat with this host's name: $HOST." ]]
  [[ "$OUT$ERR" != *"$seed"* ]]
  [[ "$OUT$ERR" != *"${seed//-/}"* ]]
  [[ "$(cat "$LAB/tty.out")" == *"Decoy seed for $HOST, shown once:"* ]]
  [[ "$(cat "$LAB/tty.out")" == *"      $seed"* ]]
  [[ "$(cat "$LAB/tty.out")" == *"Type 'recorded' once it is in the offline record and the team chat: "* ]]
  # It needs no hosts file: it is not a preview or a run.
  [ ! -e "$ETC/hosts" ]
  [ ! -e "$ROOT" ]
}

@test "a seed --new-seed made passes --seed-check" {
  local seed
  typed recorded
  streams --new-seed
  [ "$CODE" -eq 0 ]
  seed="$(stored DECOY_SEED)"
  rm -f "$LAB/tty.pos" "$LAB/tty.out"
  typed "$seed"
  streams --seed-check
  [ "$CODE" -eq 0 ]
  [ "$OUT" = 'Valid seed: the check group matches.' ]
}

@test "--new-seed keeps the other keys in seed.conf" {
  printf 'TEAM_SEED=%s\n' "$OTHER" > "$ETC/seed.conf"
  typed recorded
  streams --new-seed
  [ "$CODE" -eq 0 ]
  [ "$(stored TEAM_SEED)" = "$OTHER" ]
  [[ "$(stored DECOY_SEED)" =~ ^([2-9A-HJ-NP-Z]{4}-){7}[2-9A-HJ-NP-Z]{4}$ ]]
  [ "$(stat -c %a "$ETC/seed.conf")" = 600 ]
}

@test "--new-seed asks before replacing a seed, and keeps the old one unless you say yes" {
  local a
  for a in n '' no maybe; do
    rm -f "$LAB/tty.pos" "$LAB/tty.out"
    printf 'DECOY_SEED=%s\n' "$GOOD" > "$ETC/seed.conf"
    typed "$a" recorded
    streams --new-seed
    [ "$CODE" -eq 0 ] || { echo "answer '$a': exit $CODE"; return 1; }
    [ "$OUT" = 'Nothing was changed.' ]
    [ "$(stored DECOY_SEED)" = "$GOOD" ]
    [[ "$(cat "$LAB/tty.out")" == *'This host already has a decoy seed. Replace it? The decoys made from the'* ]]
    [[ "$(cat "$LAB/tty.out")" == *'old one must be made again. [y/N] ' ]]
    [[ "$(cat "$LAB/tty.out")" != *'Decoy seed for'* ]]
  done
}

@test "--new-seed replaces the seed when you answer yes" {
  local a
  for a in y YES yes; do
    rm -f "$LAB/tty.pos" "$LAB/tty.out"
    printf 'DECOY_SEED=%s\n' "$GOOD" > "$ETC/seed.conf"
    typed "$a" recorded
    streams --new-seed
    [ "$CODE" -eq 0 ] || { echo "answer '$a': exit $CODE"; return 1; }
    [ "$(stored DECOY_SEED)" != "$GOOD" ]
    [[ "$(stored DECOY_SEED)" =~ ^([2-9A-HJ-NP-Z]{4}-){7}[2-9A-HJ-NP-Z]{4}$ ]]
    [ "$(grep -c '^DECOY_SEED=' "$ETC/seed.conf")" -eq 1 ]
  done
}

@test "--new-seed -y replaces the seed without asking" {
  printf 'DECOY_SEED=%s\n' "$GOOD" > "$ETC/seed.conf"
  typed recorded
  streams --new-seed -y
  [ "$CODE" -eq 0 ]
  [ "$(stored DECOY_SEED)" != "$GOOD" ]
  [[ "$(cat "$LAB/tty.out")" != *'Replace it?'* ]]
  # -y with no seed to replace changes nothing about the question.
  rm -f "$ETC/seed.conf" "$LAB/tty.pos" "$LAB/tty.out"
  typed recorded
  streams --yes --new-seed
  [ "$CODE" -eq 0 ]
  [[ "$(stored DECOY_SEED)" =~ ^([2-9A-HJ-NP-Z]{4}-){7}[2-9A-HJ-NP-Z]{4}$ ]]
}

@test "--new-seed asks again for 'recorded' until it is typed" {
  typed no recorded
  streams --new-seed
  [ "$CODE" -eq 0 ]
  [[ "$(stored DECOY_SEED)" =~ ^([2-9A-HJ-NP-Z]{4}-){7}[2-9A-HJ-NP-Z]{4}$ ]]
}

@test "a terminal that goes before 'recorded' leaves no new seed" {
  printf 'TEAM_SEED=%s\n' "$OTHER" > "$ETC/seed.conf"
  rm -f "$LAB/tty.in"
  streams --new-seed
  [ "$CODE" -eq 20 ]
  [[ "$ERR" == *'the seed was not recorded, so it was not saved'* ]]
  [ -z "$(stored DECOY_SEED)" ]
  [ "$(stored TEAM_SEED)" = "$OTHER" ]
  [[ "$OUT$ERR" != *'Saved'* ]]
}

@test "a terminal that goes before 'recorded' puts the old seed back" {
  printf 'DECOY_SEED=%s\nTEAM_SEED=%s\n' "$GOOD" "$OTHER" > "$ETC/seed.conf"
  streams --new-seed -y
  [ "$CODE" -eq 20 ]
  [[ "$ERR" == *'the seed was not recorded, so it was not saved'* ]]
  [ "$(stored DECOY_SEED)" = "$GOOD" ]
  [ "$(stored TEAM_SEED)" = "$OTHER" ]
  # Answering yes, then losing the terminal, restores it too.
  rm -f "$LAB/tty.pos"
  typed y
  streams --new-seed
  [ "$CODE" -eq 20 ]
  [ "$(stored DECOY_SEED)" = "$GOOD" ]
}

@test "a seed.conf that is not valid is an error that names the file and never the seed" {
  printf 'DECOY_SEED=%s\n' "$TYPO" > "$ETC/seed.conf"
  typed y recorded
  streams --new-seed
  [ "$CODE" -eq 40 ]
  [[ "$ERR" == *"$ETC/seed.conf"* ]]
  [[ "$OUT$ERR" != *"$TYPO"* ]]
  [ "$(stored DECOY_SEED)" = "$TYPO" ]
  printf 'not a key line\n' > "$ETC/seed.conf"
  streams --new-seed
  [ "$CODE" -eq 40 ]
  [[ "$ERR" == *"$ETC/seed.conf"* ]]
}

@test "--new-seed takes no word, and -y is refused with other actions" {
  streams --new-seed extra
  [ "$CODE" -eq 40 ]
  [[ "$ERR" == *"unexpected word 'extra' after '--new-seed'"* ]]
  streams --seed-check -y
  [ "$CODE" -eq 40 ]
  [[ "$ERR" == *'-y is only for -u ID --all or --new-seed, not --seed-check'* ]]
}

@test "--seed-check says a valid seed is valid, in any case and with or without dashes" {
  local s
  for s in "$GOOD" "${GOOD,,}" "${GOOD//-/}" "${GOOD//-/ }"; do
    rm -f "$LAB/tty.pos" "$LAB/tty.out"
    typed "$s"
    streams --seed-check
    [ "$CODE" -eq 0 ] || { echo "'$s': exit $CODE"; return 1; }
    [ "$OUT" = 'Valid seed: the check group matches.' ]
    [ "$(cat "$LAB/tty.out")" = 'Seed to check: ' ]
  done
}

@test "--seed-check refuses a typo, exits 30, and never repeats what was typed" {
  typed "$TYPO"
  streams --seed-check
  [ "$CODE" -eq 30 ]
  [[ "$OUT" == *'the check group does not match'* ]]
  [[ "$OUT" == *'Check it against the offline record and type it again.'* ]]
  [[ "$OUT$ERR" != *"$TYPO"* ]]
  [[ "$OUT$ERR" != *"${TYPO//-/}"* ]]
  rm -f "$LAB/tty.pos"
  typed 'K7QM-2XRP'
  streams --seed-check
  [ "$CODE" -eq 30 ]
  [[ "$OUT$ERR" != *'K7QM-2XRP'* ]]
  rm -f "$LAB/tty.pos"
  typed ''
  streams --seed-check
  [ "$CODE" -eq 30 ]
}

@test "--seed-check needs a terminal, and does not read the seed from standard input" {
  touch "$LAB/NO_TTY"
  streams --seed-check
  [ "$CODE" -eq 20 ]
  [[ "$ERR" == *'--seed-check needs a terminal to type the seed at'* ]]
  rm -f "$LAB/NO_TTY" "$LAB/tty.in"
  CODE=0
  OUT="$(printf '%s\n' "$GOOD" | bash "$LAB/labyrinth.sh" --seed-check 2> "$BATS_TEST_TMPDIR/err")" || CODE=$?
  [ "$CODE" -eq 20 ]
  [[ "$OUT" != *'Valid'* ]]
}

@test "--seed-check needs no root, no configuration folder and no data root" {
  touch "$LAB/NOT_ADMIN"
  rm -rf "$ETC"
  typed "$GOOD"
  CODE=0
  OUT="$(bash "$LAB/labyrinth.sh" --seed-check --root "$ROOT" --config "$ETC" 2> "$BATS_TEST_TMPDIR/err" < /dev/null)" || CODE=$?
  [ "$CODE" -eq 0 ]
  [ "$OUT" = 'Valid seed: the check group matches.' ]
  [ ! -e "$ROOT" ]
  [ ! -e "$ETC" ]
}
