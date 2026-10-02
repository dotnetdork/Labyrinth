# shellcheck shell=bash
# core/safety/system.sh: the operating-system side of the safety code for
# Linux: the administrator check and the dead-man revert timer (design 01,
# section 8). Sourced through core/lib.sh.
#
# The timer of a run is a transient systemd timer named
# lab-revert-<run>-<n>. Each re-arm starts a new one, with a new <n>, after
# stopping the last, and its name is kept in $LAB_STATE_DIR/runs/<run>/timer.

lab_is_admin() { [[ "$(id -u)" == 0 ]]; }

# lab_timer_arm SECONDS RUN COMMAND [ARG...]: (re)arm the run's revert timer
# to run COMMAND (an absolute path) after SECONDS, unless cancelled.
lab_timer_arm() {
  local secs="$1" run="$2" dir n=1 unit
  shift 2
  if ! command -v systemd-run > /dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
    printf 'revert timer: systemd is not available on this host, so no timer can be armed\n' >&2
    return 1
  fi
  dir="$LAB_STATE_DIR/runs/$run"
  mkdir -p "$dir"
  lab_timer_cancel "$run"
  if [[ -f "$dir/timer-count" ]]; then
    n=$(( $(cat "$dir/timer-count") + 1 ))
  fi
  unit="lab-revert-$run-$n"
  systemd-run --quiet --unit="$unit" --on-active="${secs}s" --timer-property=AccuracySec=1s "$@" || return 1
  printf '%s\n' "$n" > "$dir/timer-count"
  printf '%s\n' "$unit" > "$dir/timer"
}

# lab_timer_cancel RUN: stop the run's revert timer, if one is armed.
lab_timer_cancel() {
  local f="$LAB_STATE_DIR/runs/$1/timer" unit
  [[ -f "$f" ]] || return 0
  unit="$(cat "$f")"
  # The timer may already have fired or been stopped by hand.
  systemctl stop "$unit.timer" 2> /dev/null || true
  rm -f -- "$f"
}

# lab_timer_armed RUN: is a revert timer armed for the run?
lab_timer_armed() { [[ -f "$LAB_STATE_DIR/runs/$1/timer" ]]; }
