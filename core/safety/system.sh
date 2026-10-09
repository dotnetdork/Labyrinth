# shellcheck shell=bash
# core/safety/system.sh: the operating-system side of the safety code for
# Linux: the administrator and ownership checks and the dead-man revert
# timer (design 01, section 8). Sourced through core/lib.sh.
#
# The timer of a run is a transient systemd timer named
# lab-revert-<run>-<n>. Each re-arm starts a new one, with a new <n>, and
# only then stops the last, so a failed re-arm leaves the earlier timer
# armed. The armed timer's name is kept in $LAB_STATE_DIR/runs/<run>/timer,
# and the time it fires in timer-due (UTC, YYYY-MM-DDTHH:MM:SSZ), which is
# advisory: it is shown to the operator, and nothing fails without it.

lab_is_admin() { [[ "$(id -u)" == 0 ]]; }

# lab_tree_trusted PATH...: can only root change each PATH? Root runs the
# code, configuration and manifest under them, the revert timer's rollback
# included, so an account that could write there could run its own code as
# root (design 07, section 5). Each existing PATH, and everything in it,
# must be owned by root and not writable by group or others (a symbolic
# link need only be owned by root). Every folder above it must be owned by
# root and not writable by group or others, unless it is sticky, like
# /tmp. A PATH not made yet is checked from its nearest folder. Prints the
# first path that fails and returns 1; returns 0 if none does.
lab_tree_trusted() {
  local p d bad st uid mode
  for p in "$@"; do
    [[ -n "$p" ]] || continue
    d="$(readlink -m -- "$p")" || { printf '%s\n' "$p"; return 1; }
    if [[ -e "$d" ]]; then
      bad="$(find "$d" \( ! -user 0 -o \( ! -type l -perm /022 \) \) -print -quit 2> /dev/null)" \
        || { printf '%s\n' "$d"; return 1; }
      if [[ -n "$bad" ]]; then printf '%s\n' "$bad"; return 1; fi
    fi
    while [[ "$d" != / ]]; do
      d="$(dirname -- "$d")"
      [[ -e "$d" ]] || continue
      st="$(stat -L -c '%u %a' -- "$d" 2> /dev/null)" || { printf '%s\n' "$d"; return 1; }
      read -r uid mode <<< "$st"
      if [[ "$uid" != 0 ]] || { (( (8#$mode & 8#022) != 0 )) && (( (8#$mode & 8#1000) == 0 )); }; then
        printf '%s\n' "$d"; return 1
      fi
    done
  done
  return 0
}

# lab_timer_arm SECONDS RUN COMMAND [ARG...]: (re)arm the run's revert timer
# to run COMMAND (an absolute path) after SECONDS, unless cancelled.
lab_timer_arm() {
  local secs="$1" run="$2" dir n=1 unit old=''
  shift 2
  if ! command -v systemd-run > /dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
    printf 'revert timer: systemd is not available on this host, so no timer can be armed\n' >&2
    return 1
  fi
  dir="$LAB_STATE_DIR/runs/$run"
  mkdir -p "$dir" || return 1
  if [[ -f "$dir/timer-count" ]]; then
    n=$(( $(cat "$dir/timer-count") + 1 ))
  fi
  if [[ -f "$dir/timer" ]]; then old="$(cat "$dir/timer")"; fi
  unit="lab-revert-$run-$n"
  systemd-run --quiet --unit="$unit" --on-active="${secs}s" --timer-property=AccuracySec=1s "$@" || return 1
  printf '%s\n' "$n" > "$dir/timer-count"
  printf '%s\n' "$unit" > "$dir/timer"
  lab_timer_due_write "$run" "$secs"
  # Only now is the earlier timer stopped; it may already have fired.
  if [[ -n "$old" ]]; then
    systemctl stop "$old.timer" 2> /dev/null || true
  fi
}

# lab_timer_cancel RUN: stop the run's revert timer, if one is armed.
# Returns 1, keeping the state files, if the timer is still active after
# being stopped, because the run would still be rolled back.
lab_timer_cancel() {
  local dir="$LAB_STATE_DIR/runs/$1" unit
  [[ -f "$dir/timer" ]] || return 0
  unit="$(cat "$dir/timer")"
  # The timer may already have fired or been stopped by hand.
  systemctl stop "$unit.timer" 2> /dev/null || true
  if systemctl is-active --quiet "$unit.timer" 2> /dev/null; then
    printf 'revert timer: %s.timer is still active after being stopped\n' "$unit" >&2
    return 1
  fi
  rm -f -- "$dir/timer" "$dir/timer-due"
}

# lab_timer_due_write RUN SECONDS: record that the run's revert timer fires
# in SECONDS. Advisory: a failure is ignored.
lab_timer_due_write() {
  local due
  due="$(date -u -d "@$(( $(date +%s) + $2 ))" +%Y-%m-%dT%H:%M:%SZ 2> /dev/null)" || return 0
  printf '%s\n' "$due" 2> /dev/null > "$LAB_STATE_DIR/runs/$1/timer-due" || true
}

# lab_timer_due RUN: print when the run's revert timer fires; 1 if unknown.
lab_timer_due() {
  local f="$LAB_STATE_DIR/runs/$1/timer-due" due=''
  [[ -s "$f" ]] || return 1
  IFS= read -r due < "$f" || [[ -n "$due" ]] || return 1
  [[ "$due" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  printf '%s\n' "$due"
}

# lab_timer_armed RUN: is a revert timer armed for the run?
lab_timer_armed() { [[ -f "$LAB_STATE_DIR/runs/$1/timer" ]]; }
