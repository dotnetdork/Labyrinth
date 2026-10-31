# shellcheck shell=bash
# core/seed/seed.sh: the event seed (design 16). Sourced through core/lib.sh.
#
# A seed is 28 random characters and a 4-character check group, written as
# 8 groups of 4, such as 3LES-4LLU-DG9M-GZ3C-DB9D-LL2D-5YVY-4G4N. The
# characters come from a 32-letter alphabet with no lookalikes (no 0, 1,
# I or O), so each is exactly 5 random bits: 140 bits in all. The check group
# is worked out from the other 28 by a public formula, so a typo is caught;
# it adds no secrecy. Case and dashes do not matter on input.
#
# Every value is HMAC-SHA256(key, "purpose:index"), the key being the 28
# random characters, then mapped into the range needed. HMAC is built from
# sha256sum, because openssl is not on every host, and works on hex
# throughout, because a bash string cannot hold a zero byte.
#
# Nothing here logs, records or stores a seed. Hold one in a variable and
# never pass it on a command line: another program's arguments can be read
# by any user on the host.

LAB_SEED_ALPHABET='23456789ABCDEFGHJKLMNPQRSTUVWXYZ'

# lab_hex TEXT: TEXT's bytes as lower-case hex, with nothing between them.
lab_hex() {
  [[ -n "$1" ]] || return 0
  printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'
}

# lab_sha256_hex HEX: the SHA-256 of the bytes HEX spells, as hex.
lab_sha256_hex() {
  local h
  h="$(printf '%b' "$(sed 's/../\\x&/g' <<< "$1")" | sha256sum)" || return 1
  printf '%s\n' "${h%% *}"
}

# lab_hmac_sha256 KEYHEX MSGHEX: HMAC-SHA256 (RFC 2104) of the message bytes
# under the key bytes, both given as hex; prints the result as hex.
lab_hmac_sha256() {
  local key="${1,,}" msg="${2,,}" ipad='' opad='' i b inner
  if (( ${#key} > 128 )); then key="$(lab_sha256_hex "$key")" || return 1; fi
  while (( ${#key} < 128 )); do key+='00'; done
  for ((i = 0; i < 128; i += 2)); do
    b=$((16#${key:i:2}))
    printf -v ipad '%s%02x' "$ipad" $((b ^ 0x36))
    printf -v opad '%s%02x' "$opad" $((b ^ 0x5c))
  done
  inner="$(lab_sha256_hex "$ipad$msg")" || return 1
  lab_sha256_hex "$opad$inner"
}

# lab_seed_check BODY: the check group for the 28 random characters BODY:
# the first 20 bits of SHA-256("labyrinth-seed-check:" BODY), as 4 letters
# of the alphabet.
lab_seed_check() {
  local h v
  h="$(lab_sha256_hex "$(lab_hex "labyrinth-seed-check:$1")")" || return 1
  v=$((16#${h:0:5}))
  printf '%s%s%s%s\n' "${LAB_SEED_ALPHABET:$(((v >> 15) & 31)):1}" \
    "${LAB_SEED_ALPHABET:$(((v >> 10) & 31)):1}" \
    "${LAB_SEED_ALPHABET:$(((v >> 5) & 31)):1}" "${LAB_SEED_ALPHABET:$((v & 31)):1}"
}

# lab_seed_format SEED: the 32 characters of SEED as 8 groups of 4.
lab_seed_format() {
  local s="$1" out='' i
  for ((i = 0; i < 32; i += 4)); do out+="${out:+-}${s:i:4}"; done
  printf '%s\n' "$out"
}

# lab_seed_new: a new seed from /dev/urandom, as 8 groups of 4. Each random
# byte gives its low 5 bits; 256 is 8 x 32, so every letter is equally
# likely.
lab_seed_new() {
  local body='' b bytes check
  bytes="$(od -An -N28 -tu1 /dev/urandom)" || return 40
  for b in $bytes; do body+="${LAB_SEED_ALPHABET:$((b & 31)):1}"; done
  (( ${#body} == 28 )) || return 40
  check="$(lab_seed_check "$body")" || return 40
  lab_seed_format "$body$check"
}

# lab_seed_normalize TEXT: TEXT as a seed of 32 characters, upper case, with
# no dashes or spaces. Fails with a message on standard error when TEXT is
# not a seed or its check group does not match. The message never repeats
# TEXT.
lab_seed_normalize() {
  local s="${1^^}" bad
  s="${s//[- ]/}"
  s="${s//$'\t'/}"
  s="${s//$'\r'/}"
  if [[ -z "$s" ]]; then
    printf 'seed: no seed given\n' >&2
    return 1
  fi
  bad="${s//[$LAB_SEED_ALPHABET]/}"
  if [[ -n "$bad" ]]; then
    printf 'seed: a seed uses only 2-9 and the letters A-Z without I and O; this one has %s other character(s)\n' "${#bad}" >&2
    return 1
  fi
  if (( ${#s} != 32 )); then
    printf 'seed: a seed has 32 characters (8 groups of 4); this one has %s\n' "${#s}" >&2
    return 1
  fi
  if [[ "$(lab_seed_check "${s:0:28}")" != "${s:28:4}" ]]; then
    printf 'seed: the check group does not match, so the seed has a typo\n' >&2
    return 1
  fi
  printf '%s\n' "$s"
}

# lab_seed_hmac SEED LABEL: HMAC-SHA256 of LABEL (such as decoy-port:1)
# under SEED's 28 random characters, as hex. SEED must be normalized.
lab_seed_hmac() {
  lab_hmac_sha256 "$(lab_hex "${1:0:28}")" "$(lab_hex "$2")"
}

# lab_seed_value SEED LABEL MIN MAX: a whole number from MIN to MAX (at most
# 2^31 values), the same for the same seed and label on every host. It reads
# the HMAC 32 bits at a time and throws away a block at or above the largest
# multiple of the range's size, so every number is equally likely. If all 8
# blocks are thrown away, it goes on with the HMAC of "LABEL#1", "LABEL#2"
# and so on.
lab_seed_value() {
  local seed="$1" label="$2" min="$3" max="$4" n limit h i v round=0
  n=$((max - min + 1))
  if (( n < 1 || n > 2147483648 )); then
    printf 'seed: the range %s to %s is empty or too large\n' "$min" "$max" >&2
    return 1
  fi
  limit=$(((4294967296 / n) * n))
  while :; do
    if (( round == 0 )); then h="$(lab_seed_hmac "$seed" "$label")" || return 1
    else h="$(lab_seed_hmac "$seed" "$label#$round")" || return 1; fi
    for ((i = 0; i < 64; i += 8)); do
      v=$((16#${h:i:8}))
      if (( v < limit )); then
        printf '%s\n' $((min + v % n))
        return 0
      fi
    done
    round=$((round + 1))
  done
}

# The seed file, <root>/etc/seed.conf: KEY=value lines, root-only, written
# by Labyrinth and never copied between hosts. DECOY_SEED is this host's own
# seed for its decoys; TEAM_SEED (design 04) is the same on every host. It is
# kept apart from event.conf, which is copied between hosts, so copying that
# can never copy a seed.
lab_seed_file() { printf '%s/seed.conf\n' "$LAB_CONFIG_DIR"; }

# lab_seed_read KEY: the seed stored under KEY, normalized, or nothing when
# there is none. Fails when the file cannot be read, has a line that is not
# KEY=value, or the stored seed is not valid.
lab_seed_read() {
  local file i line val=''
  file="$(lab_seed_file)"
  [[ -e "$file" ]] || return 0
  lab_config_lines "$file" || return 1
  for ((i = 0; i < ${#LAB_CFG_LINES[@]}; i++)); do
    line="${LAB_CFG_LINES[i]}"
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] \
      || { lab_cfg_error "$file" "${LAB_CFG_NOS[i]}" 'expected KEY=value'; return 1; }
    if [[ "${BASH_REMATCH[1]}" == "$1" ]]; then val="$(lab_trim "${BASH_REMATCH[2]}")"; fi
  done
  LAB_CFG_LINES=()
  [[ -n "$val" ]] || return 0
  lab_seed_normalize "$val" 2> /dev/null \
    || { printf '%s: %s is not a valid seed\n' "$file" "$1" >&2; return 1; }
}

# lab_seed_store KEY [SEED]: write SEED under KEY in the seed file, keeping
# the file's other keys; with no SEED, remove KEY. The file is written whole
# to a new file in the same folder, made root-only, then moved into place.
lab_seed_store() {
  local key="$1" seed="${2:-}" file tmp i line
  file="$(lab_seed_file)"
  if [[ -e "$file" ]]; then lab_config_lines "$file" || return 1; else LAB_CFG_LINES=(); fi
  tmp="$(umask 077 && mktemp "$file.XXXXXX")" || return 1
  {
    printf '# Seeds for this host only (design 16). Written by Labyrinth: never copy\n'
    printf '# this file to another host, and never commit it.\n'
    for ((i = 0; i < ${#LAB_CFG_LINES[@]}; i++)); do
      line="${LAB_CFG_LINES[i]}"
      if [[ "$line" != "$key="* ]]; then printf '%s\n' "$line"; fi
    done
    if [[ -n "$seed" ]]; then printf '%s=%s\n' "$key" "$(lab_seed_format "$seed")"; fi
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  LAB_CFG_LINES=()
  if ! chmod 600 -- "$tmp" || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# lab_seed_show LABEL SEED: show SEED once on the terminal, wait until the
# operator types 'recorded', then clear it from the screen, as a new password
# is shown (lab_secret_show). LABEL is the host's name. Returns 20 when there
# is no terminal, and 1 when the terminal goes before the answer: the caller
# must then undo what it saved, because nobody recorded the seed.
lab_seed_show() {
  local label="$1" seed="$2" answer lines=6
  if ! lab_tty_ok; then
    printf 'seed: no terminal to show the seed on\n' >&2
    return 20
  fi
  lab_tty_write $'\n'"  Decoy seed for $label, shown once:"$'\n\n'"      $seed"$'\n\n'
  while :; do
    lab_tty_write "  Type 'recorded' once it is in the offline record and the team chat: "
    if ! answer="$(lab_tty_read)"; then
      lab_tty_write $'\n'
      return 1
    fi
    answer="$(lab_trim "$answer")"
    if [[ "${answer,,}" == recorded ]]; then break; fi
    lines=$((lines + 1))
  done
  # Back up over the lines shown and clear to the end of the screen.
  lab_tty_write $'\r\033['"$lines"$'A\033[J'
}
