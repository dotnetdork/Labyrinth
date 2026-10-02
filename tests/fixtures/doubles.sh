# shellcheck shell=bash
# ---- Test doubles, appended to core/lib.sh in the throwaway test tree only ----
# They replace the host-specific parts of the core, so runner tests need no
# root, no systemd and no network:
#   - the administrator check passes unless $LAB_ROOT/NOT_ADMIN exists;
#   - the revert timer is recorded in $LAB_ROOT/timer.log instead of armed;
#   - a probe fails if its host is listed as "<host> fail" in
#     $LAB_ROOT/probe-state, and passes otherwise.

lab_is_admin() { [[ ! -e "$LAB_ROOT/NOT_ADMIN" ]]; }

lab_timer_arm() {
  local secs="$1" run="$2"
  shift 2
  mkdir -p "$LAB_STATE_DIR/runs/$run"
  printf '%s\n' "$*" > "$LAB_STATE_DIR/runs/$run/timer"
  printf 'arm %s %s\n' "$run" "$secs" >> "$LAB_ROOT/timer.log"
}

lab_timer_cancel() {
  [[ -f "$LAB_STATE_DIR/runs/$1/timer" ]] || return 0
  rm -f -- "$LAB_STATE_DIR/runs/$1/timer"
  printf 'cancel %s\n' "$1" >> "$LAB_ROOT/timer.log"
}

lab_probe_service() {
  if grep -qx "$2 fail" "$LAB_ROOT/probe-state" 2> /dev/null; then
    printf 'fail fake probe\n'
  else
    printf 'pass fake probe\n'
  fi
}
