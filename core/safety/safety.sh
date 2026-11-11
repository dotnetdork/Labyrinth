# shellcheck shell=bash
# core/safety/safety.sh: the safety gates and run lock (design 03,
# sections 7 and 8). Sourced through core/lib.sh. The parts that differ by
# operating system (administrator check, revert timer) are in system.sh.

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
# over, and so is one whose process ID now belongs to another process (the
# lock records when its holder started). Returns 1 if the lock is still held
# after WAIT_SECONDS.
lab_lock_acquire() {
  local wait="${1:-0}" lock="$LAB_STATE_DIR/lock" waited=0 pid rc
  mkdir -p "$LAB_STATE_DIR"
  while ! mkdir "$lock" 2> /dev/null; do
    pid=''
    if _lab_lock_read; then
      pid="$LAB_LOCK_PID"
      rc=0
      _lab_lock_holder_live || rc=$?
      if (( rc == 1 )); then
        rm -f -- "$lock/pid"
        rmdir -- "$lock" 2> /dev/null || true
        continue
      fi
    fi
    if (( waited >= wait )); then
      printf 'labyrinth: another Labyrinth run (pid %s) holds %s\n' "${pid:-unknown}" "$lock" >&2
      printf 'Wait for it to finish. If no Labyrinth run is going, delete %s, then run the same command again.\n' "$lock" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  printf '%s %s\n' "$$" "$(_lab_proc_start "$$" || true)" > "$lock/pid"
}

# _lab_proc_start PID: print when the process started, in clock ticks since
# the host started (/proc/PID/stat, field 22). Returns 1 when it is gone.
_lab_proc_start() {
  local stat
  local -a f
  stat="$(cat "/proc/$1/stat" 2> /dev/null)" || return 1
  # The fields after the command name, which may itself hold spaces.
  stat="${stat##*) }"
  read -r -a f <<< "$stat"
  [[ "${f[19]:-}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${f[19]}"
}

# _lab_lock_read: read the lock's pid file, "PID START", into LAB_LOCK_PID
# and LAB_LOCK_START. START is empty for a lock that does not record it.
# Returns 1 when there is no pid file or it does not hold a process ID.
_lab_lock_read() {
  local f="$LAB_STATE_DIR/lock/pid" line=''
  LAB_LOCK_PID='' LAB_LOCK_START=''
  [[ -f "$f" ]] || return 1
  IFS= read -r line < "$f" || [[ -n "$line" ]] || return 1
  line="${line%"${line##*[![:space:]]}"}"
  [[ "$line" =~ ^([0-9]+)(\ ([0-9]+))?$ ]] || return 1
  LAB_LOCK_PID="${BASH_REMATCH[1]}"
  LAB_LOCK_START="${BASH_REMATCH[3]:-}"
}

# _lab_lock_holder_live: is the process _lab_lock_read found still the one
# that took the lock? Returns 0 when it is; 1 when it is gone, or a process
# with its ID started at another time, so the ID was reused; and 2 when a
# process with that ID is alive but the lock records no start time, so this
# cannot be told.
_lab_lock_holder_live() {
  local now
  kill -0 "$LAB_LOCK_PID" 2> /dev/null || return 1
  [[ -n "$LAB_LOCK_START" ]] || return 2
  now="$(_lab_proc_start "$LAB_LOCK_PID")" || return 1
  [[ "$now" == "$LAB_LOCK_START" ]] || return 1
  return 0
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
# is still changing the host. Only the process that took the lock is ever
# stopped: a process that merely has the recorded ID, started at another
# time, is left alone, and so is one the lock records no start time for.
# Returns 1 if the holder is still alive.
lab_lock_stop_holder() {
  local wait="${1:-30}" pid n kids rc=0
  _lab_lock_read || return 0
  pid="$LAB_LOCK_PID"
  [[ "$pid" != "$$" ]] || return 0
  _lab_lock_holder_live || rc=$?
  (( rc != 1 )) || return 0
  if (( rc == 2 )); then
    printf 'not stopping pid %s, which the lock names: the lock does not record when its holder started, so this may be another program\n' "$pid" >&2
    return 1
  fi
  printf 'stopping the Labyrinth run (pid %s) that holds the lock\n' "$pid" >&2
  kids="$(_lab_descendants "$pid")"
  # shellcheck disable=SC2086 # one PID per word
  kill -TERM $kids "$pid" 2> /dev/null || true
  for ((n = 0; n < wait; n++)); do
    kill -0 "$pid" 2> /dev/null || return 0
    sleep 1
  done
  # Checked again: the ID may have passed to another process meanwhile.
  _lab_lock_holder_live || return 0
  kids="$(_lab_descendants "$pid")"
  # shellcheck disable=SC2086 # one PID per word
  kill -KILL $kids "$pid" 2> /dev/null || true
  sleep 1
  ! kill -0 "$pid" 2> /dev/null
}

# lab_lock_release: release the run lock if this process holds it.
lab_lock_release() {
  local lock="$LAB_STATE_DIR/lock"
  _lab_lock_read || return 0
  [[ "$LAB_LOCK_PID" == "$$" ]] || return 0
  rm -f -- "$lock/pid"
  rmdir -- "$lock" 2> /dev/null || true
}
