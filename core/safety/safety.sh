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

# _lab_descendants PID: print the process IDs below PID, children first.
_lab_descendants() {
  local p stat ppid
  for p in /proc/[0-9]*; do
    stat="$(cat "$p/stat" 2> /dev/null)" || continue
    stat="${stat##*) }"
    read -r _ ppid _ <<< "$stat"
    if [[ "$ppid" == "$1" ]]; then
      _lab_descendants "${p#/proc/}"
      printf '%s\n' "${p#/proc/}"
    fi
  done
}

# lab_lock_stop_holder [WAIT_SECONDS]: stop the live run that holds the lock
# and the entry points it started: TERM, then KILL after WAIT_SECONDS. The
# revert timer's rollback uses it, so it never undoes a run while that run
# is still changing the host. Returns 1 if the holder is still alive.
lab_lock_stop_holder() {
  local wait="${1:-30}" pid n kids
  pid="$(cat "$LAB_STATE_DIR/lock/pid" 2> /dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ && "$pid" != "$$" ]] || return 0
  kill -0 "$pid" 2> /dev/null || return 0
  printf 'stopping the Labyrinth run (pid %s) that holds the lock\n' "$pid" >&2
  kids="$(_lab_descendants "$pid")"
  # shellcheck disable=SC2086 # one PID per word
  kill -TERM $kids "$pid" 2> /dev/null || true
  for ((n = 0; n < wait; n++)); do
    kill -0 "$pid" 2> /dev/null || return 0
    sleep 1
  done
  kids="$(_lab_descendants "$pid")"
  # shellcheck disable=SC2086 # one PID per word
  kill -KILL $kids "$pid" 2> /dev/null || true
  sleep 1
  ! kill -0 "$pid" 2> /dev/null
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
  local len="${1:-20}" n="${#LAB_PW_ALPHABET}" limit pw b
  local -a bytes
  # The largest multiple of the alphabet size up to 256: bytes from it up
  # are rejected, so every character is equally likely.
  limit=$((256 - 256 % n))
  (( len >= 12 && len <= 128 )) || { printf 'password length must be 12 to 128\n' >&2; return 1; }
  while :; do
    pw=''
    while (( ${#pw} < len )); do
      IFS=' ' read -r -a bytes <<< "$(od -An -v -w64 -N64 -tu1 /dev/urandom)"
      for b in "${bytes[@]}"; do
        (( b < limit )) || continue
        pw+="${LAB_PW_ALPHABET:b % n:1}"
        (( ${#pw} < len )) || break
      done
    done
    if [[ "$pw" =~ [[:upper:]] && "$pw" =~ [[:lower:]] && "$pw" =~ [[:digit:]] ]]; then
      break
    fi
  done
  printf '%s' "$pw"
}
