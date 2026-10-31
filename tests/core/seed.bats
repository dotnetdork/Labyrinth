#!/usr/bin/env bats
# Unit tests for the event seed (core/seed/seed.sh, design 16). The expected
# values are in seed-vectors.txt, which Seed.Tests.ps1 reads too.

setup() {
  LAB_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export LAB_ROOT
  export LAB_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export LAB_LOG_DIR="$BATS_TEST_TMPDIR/logs"
  export LAB_BACKUP_DIR="$BATS_TEST_TMPDIR/backup"
  export LAB_CONFIG_DIR="$BATS_TEST_TMPDIR/etc"
  # shellcheck source=/dev/null
  source "$LAB_ROOT/core/lib.sh"
  VECTORS="$BATS_TEST_DIRNAME/seed-vectors.txt"
}

# vectors KIND: the fields of each line of that kind in seed-vectors.txt.
vectors() { awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print }' "$VECTORS"; }

@test "hmac: the RFC 4231 test cases give their published results" {
  local key msg want n=0
  while read -r key msg want; do
    [ "$(lab_hmac_sha256 "$key" "$msg")" = "$want" ]
    n=$((n + 1))
  done < <(vectors hmac)
  [ "$n" -eq 6 ]
}

@test "hmac: upper-case hex gives the same result" {
  [ "$(lab_hmac_sha256 0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B 4869205468657265)" \
    = b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7 ]
}

@test "seed: each known seed passes its check, in any case and with or without dashes" {
  local s n=0
  while read -r s; do
    [ "$(lab_seed_normalize "$s")" = "${s//-/}" ]
    [ "$(lab_seed_normalize "${s,,}")" = "${s//-/}" ]
    [ "$(lab_seed_normalize "${s//-/}")" = "${s//-/}" ]
    [ "$(lab_seed_normalize "  ${s//-/ } ")" = "${s//-/}" ]
    n=$((n + 1))
  done < <(vectors seed)
  [ "$n" -eq 3 ]
}

@test "seed: the same seed gives the published values for each label" {
  local s label want n=0
  while read -r s label want; do
    [ "$(lab_seed_hmac "$(lab_seed_normalize "$s")" "$label")" = "$want" ]
    n=$((n + 1))
  done < <(vectors label)
  [ "$n" -eq 3 ]
  while read -r s label lo hi want; do
    [ "$(lab_seed_value "$(lab_seed_normalize "$s")" "$label" "$lo" "$hi")" = "$want" ]
    n=$((n + 1))
  done < <(vectors value)
  [ "$n" -eq 15 ]
}

@test "seed: a different seed or label gives a different value" {
  local a b
  a="$(lab_seed_normalize K7QM-2XRP-9D4V-HT3N-B8WC-6FJZ-QM2E-L92G)"
  b="$(lab_seed_normalize 2345-6789-ABCD-EFGH-JKLM-NPQR-STUV-JLNP)"
  [ "$(lab_seed_hmac "$a" decoy-port:1)" != "$(lab_seed_hmac "$b" decoy-port:1)" ]
  [ "$(lab_seed_hmac "$a" decoy-port:1)" != "$(lab_seed_hmac "$a" decoy-port:2)" ]
}

@test "seed: a typo anywhere fails the check group, and the message never repeats the seed" {
  local good='K7QM2XRP9D4VHT3NB8WC6FJZQM2EL92G' i c bad
  for ((i = 0; i < 32; i++)); do
    c="${good:i:1}"
    if [[ "$c" == 2 ]]; then c=3; else c=2; fi
    bad="${good:0:i}$c${good:i+1}"
    run lab_seed_normalize "$bad"
    [ "$status" -eq 1 ]
    [[ "$output" == *'check group does not match'* ]]
    [[ "$output" != *"$bad"* && "$output" != *"${bad:0:8}"* ]]
  done
}

@test "seed: two neighbouring characters swapped fail the check group" {
  run lab_seed_normalize K7QM-X2RP-9D4V-HT3N-B8WC-6FJZ-QM2E-L92G
  [ "$status" -eq 1 ]
  [[ "$output" == *'check group'* ]]
}

@test "seed: the wrong length, a lookalike or an empty seed is refused with a reason" {
  run lab_seed_normalize K7QM-2XRP-9D4V-HT3N-B8WC-6FJZ-QM2E
  [ "$status" -eq 1 ]
  [[ "$output" == *'has 28'* ]]
  run lab_seed_normalize K7QM-2XRP-9D4V-HT3N-B8WC-6FJZ-QM2E-L92GA
  [ "$status" -eq 1 ]
  [[ "$output" == *'has 33'* ]]
  for c in 0 1 I O '#' '='; do
    run lab_seed_normalize "K7QM-2XRP-9D4V-HT3N-B8WC-6FJZ-QM2E-L92$c"
    [ "$status" -eq 1 ]
    [[ "$output" == *'other character'* ]]
  done
  run lab_seed_normalize ''
  [ "$status" -eq 1 ]
  [[ "$output" == *'no seed'* ]]
}

@test "new: a seed is 8 groups of 4 from the alphabet, passes its own check and is never repeated" {
  local s i seen=' '
  for i in $(seq 1 20); do
    s="$(lab_seed_new)"
    [[ "$s" =~ ^[2-9A-HJ-NP-Z]{4}(-[2-9A-HJ-NP-Z]{4}){7}$ ]]
    lab_seed_normalize "$s" > /dev/null
    [[ "$seen" != *" $s "* ]]
    seen+="$s "
  done
}

@test "new: every letter of the alphabet turns up, so no letter is left out" {
  local all='' i
  for i in $(seq 1 30); do all+="$(lab_seed_new)"; done
  all="${all//-/}"
  for ((i = 0; i < 32; i++)); do
    [[ "$all" == *"${LAB_SEED_ALPHABET:i:1}"* ]]
  done
}

@test "value: stays in range, and a range of one number gives that number" {
  local s v i
  s="$(lab_seed_normalize K7QM-2XRP-9D4V-HT3N-B8WC-6FJZ-QM2E-L92G)"
  for i in 1 2 3 4 5 6 7 8; do
    v="$(lab_seed_value "$s" "decoy-port:$i" 20000 20009)"
    (( v >= 20000 && v <= 20009 ))
  done
  [ "$(lab_seed_value "$s" decoy-user:1 7 7)" -eq 7 ]
}

@test "value: an empty or too large range is refused" {
  local s
  s="$(lab_seed_normalize K7QM-2XRP-9D4V-HT3N-B8WC-6FJZ-QM2E-L92G)"
  run lab_seed_value "$s" decoy-port:1 10 9
  [ "$status" -eq 1 ]
  run lab_seed_value "$s" decoy-port:1 0 2147483648
  [ "$status" -eq 1 ]
}
