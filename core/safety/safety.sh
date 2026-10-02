# shellcheck shell=bash
# core/safety/safety.sh: the safety gates and run lock (design 01,
# sections 7 and 8). Sourced through core/lib.sh. The parts that differ by
# operating system (administrator check, revert timer) are in system.sh.

# Characters for generated passwords: letters and digits without the ones
# that are easy to misread (0 O 1 l I), so the offline record is copied right.
readonly LAB_PW_ALPHABET='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'

# lab_breakglass_file: where the break-glass confirmation is kept. It is
# asked once per host and kept until end-of-event cleanup.
lab_breakglass_file() { printf '%s/breakglass' "$LAB_STATE_DIR"; }

# lab_breakglass_recorded: print the confirmed break-glass account if one is
# recorded and is still a breakglass account in the protected set.
lab_breakglass_recorded() {
  local f line account
  f="$(lab_breakglass_file)"
  [[ -f "$f" ]] || return 1
  IFS= read -r line < "$f" || return 1
  account="${line#*$'\t'}"
  [[ "$(lab_protected_class "$account" || true)" == breakglass ]] || return 1
  printf '%s' "$account"
}

# lab_breakglass_record ACCOUNT: record that the operator confirmed ACCOUNT
# works at this host's console. ACCOUNT must be a breakglass account.
lab_breakglass_record() {
  local account="$1" f
  if [[ "$(lab_protected_class "$account" || true)" != breakglass ]]; then
    printf 'break-glass: %s is not a breakglass account in the protected set\n' "$account" >&2
    return 1
  fi
  f="$(lab_breakglass_file)"
  mkdir -p "${f%/*}"
  printf '%s\t%s\n' "$(lab_now)" "$account" > "$f"
}

# lab_lock_acquire [WAIT_SECONDS]: take the host's run lock, so two runs
# never change the same host at once. A lock whose holder is gone is taken
# over. Returns 1 if the lock is still held after WAIT_SECONDS.
lab_lock_acquire() {
  local wait="${1:-0}" lock="$LAB_STATE_DIR/lock" waited=0 pid
  mkdir -p "$LAB_STATE_DIR"
  while ! mkdir "$lock" 2> /dev/null; do
    pid="$(cat "$lock/pid" 2> /dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2> /dev/null; then
      rm -f -- "$lock/pid"
      rmdir -- "$lock" 2> /dev/null || true
      continue
    fi
    if (( waited >= wait )); then
      printf 'another Labyrinth run (pid %s) holds %s\n' "${pid:-unknown}" "$lock" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  printf '%s\n' "$$" > "$lock/pid"
}

# lab_lock_release: release the run lock if this process holds it.
lab_lock_release() {
  local lock="$LAB_STATE_DIR/lock"
  [[ "$(cat "$lock/pid" 2> /dev/null || true)" == "$$" ]] || return 0
  rm -f -- "$lock/pid"
  rmdir -- "$lock" 2> /dev/null || true
}

# lab_random_password [LENGTH]: print a random password from /dev/urandom
# with at least one upper-case letter, lower-case letter and digit. Show it
# once to the operator; never write it to a file or a log (design 01, section 8).
lab_random_password() {
  local len="${1:-20}" pw b
  local -a bytes
  (( len >= 12 && len <= 128 )) || { printf 'password length must be 12 to 128\n' >&2; return 1; }
  while :; do
    pw=''
    while (( ${#pw} < len )); do
      IFS=' ' read -r -a bytes <<< "$(od -An -v -w64 -N64 -tu1 /dev/urandom)"
      for b in "${bytes[@]}"; do
        # 224 is the largest multiple of 56 below 256: rejecting the rest
        # keeps every character equally likely.
        (( b < 224 )) || continue
        pw+="${LAB_PW_ALPHABET:b % 56:1}"
        (( ${#pw} < len )) || break
      done
    done
    if [[ "$pw" =~ [[:upper:]] && "$pw" =~ [[:lower:]] && "$pw" =~ [[:digit:]] ]]; then
      break
    fi
  done
  printf '%s' "$pw"
}
