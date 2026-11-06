# shellcheck shell=bash
# ---- Test doubles, appended to core/lib.sh in the throwaway test tree only ----
# They replace the host-specific parts of the core, so runner tests need no
# root, no systemd and no network:
#   - the administrator check passes unless $LAB_ROOT/NOT_ADMIN exists;
#   - the ownership checks (lab_tree_trusted, and lab_path_trusted for the
#     installer) pass unless $LAB_ROOT/UNTRUSTED exists; lab_tree_trusted
#     alone also fails when $LAB_ROOT/UNTRUSTED_TREE exists;
#   - every account has console session 1 unless $LAB_ROOT/NO_CONSOLE exists;
#   - the revert timer is recorded in $LAB_ROOT/timer.log instead of armed,
#     and its warning in $LAB_ROOT/warn.log;
#   - a probe fails if its host is listed as "<host> fail" in
#     $LAB_ROOT/probe-state, and passes otherwise.
#   - the terminal is two files, $LAB_ROOT/tty.out and tty.in (below);
#   - a notice to every terminal is appended to $LAB_ROOT/notice.log, unless
#     $LAB_ROOT/NO_WALL exists (no wall command);
#   - --doctor: no revert timer can be armed if $LAB_ROOT/NO_TIMER exists; no
#     time sync runs if NO_TIMESYNC exists, and it cannot be told if
#     TIMESYNC_UNKNOWN exists; the clock reads the time in $LAB_ROOT/CLOCK.

lab_is_admin() { [[ ! -e "$LAB_ROOT/NOT_ADMIN" ]]; }

lab_tree_trusted() {
  [[ -e "$LAB_ROOT/UNTRUSTED" || -e "$LAB_ROOT/UNTRUSTED_TREE" ]] || return 0
  printf '%s\n' "$LAB_ROOT"
  return 1
}

lab_path_trusted() {
  [[ -e "$LAB_ROOT/UNTRUSTED" ]] || return 0
  printf '%s\n' "$LAB_ROOT"
  return 1
}

lab_console_session() {
  [[ ! -e "$LAB_ROOT/NO_CONSOLE" ]] || return 1
  printf '1\n'
}

lab_timer_arm() {
  local secs="$1" run="$2"
  shift 2
  mkdir -p "$LAB_STATE_DIR/runs/$run"
  printf '%s\n' "$*" > "$LAB_STATE_DIR/runs/$run/timer"
  lab_timer_due_write "$run" "$secs"
  printf 'arm %s %s\n' "$run" "$secs" >> "$LAB_ROOT/timer.log"
}

lab_timer_live() {
  [[ -f "$LAB_STATE_DIR/runs/$1/timer" && ! -e "$LAB_ROOT/TIMER_LOST" ]]
}

lab_timer_cancel() {
  [[ -f "$LAB_STATE_DIR/runs/$1/timer" ]] || return 0
  rm -f -- "$LAB_STATE_DIR/runs/$1/timer" "$LAB_STATE_DIR/runs/$1/timer-due"
  printf 'cancel %s\n' "$1" >> "$LAB_ROOT/timer.log"
  lab_warn_cancel "$1"
}

# The warning before the undo: arming it is recorded in $LAB_ROOT/warn.log
# ("arm RUN SECONDS COMMAND...") and the command is kept in runs/<run>/warn.
# It fails when $LAB_ROOT/WARN_FAIL exists.
lab_warn_arm() {
  local secs="$1" run="$2"
  shift 2
  [[ ! -e "$LAB_ROOT/WARN_FAIL" ]] || return 1
  if (( $(lab_warn_lead "$secs") < 1 )); then lab_warn_cancel "$run"; return 0; fi
  printf '%s\n' "$*" > "$LAB_STATE_DIR/runs/$run/warn"
  printf 'arm %s %s %s\n' "$run" "$secs" "$*" >> "$LAB_ROOT/warn.log"
}

lab_warn_cancel() {
  [[ -f "$LAB_STATE_DIR/runs/$1/warn" ]] || return 0
  rm -f -- "$LAB_STATE_DIR/runs/$1/warn"
  printf 'cancel %s\n' "$1" >> "$LAB_ROOT/warn.log"
}

lab_timer_ready() {
  [[ ! -e "$LAB_ROOT/NO_TIMER" ]] && return 0
  printf 'systemd is not running
' >&2
  return 1
}

lab_clock_sync() {
  [[ ! -e "$LAB_ROOT/TIMESYNC_UNKNOWN" ]] || return 2
  [[ ! -e "$LAB_ROOT/NO_TIMESYNC" ]] || return 1
  printf 'fake-timesyncd
'
}

lab_now() {
  if [[ -f "$LAB_ROOT/CLOCK" ]]; then cat "$LAB_ROOT/CLOCK"; else date -u +%Y-%m-%dT%H:%M:%SZ; fi
}

lab_notify_all() {
  [[ ! -e "$LAB_ROOT/NO_WALL" ]] || return 1
  printf '%s\n' "$1" >> "$LAB_ROOT/notice.log"
}

lab_probe_service() {
  if grep -qx "$2 fail" "$LAB_ROOT/probe-state" 2> /dev/null; then
    printf 'fail fake probe\n'
  else
    printf 'pass fake probe\n'
  fi
}

# The terminal: writes go to $LAB_ROOT/tty.out and each read takes the next
# line of $LAB_ROOT/tty.in, failing when there is none; there is no terminal
# at all if $LAB_ROOT/NO_TTY exists.
lab_tty_ok() { [[ ! -e "$LAB_ROOT/NO_TTY" ]]; }
lab_tty_write() { printf '%s' "$1" >> "$LAB_ROOT/tty.out"; }
lab_tty_cols() { printf '80\n'; }
lab_tty_read() {
  local pos=0
  if [[ -f "$LAB_ROOT/tty.pos" ]]; then pos="$(cat "$LAB_ROOT/tty.pos")"; fi
  pos=$((pos + 1))
  echo "$pos" > "$LAB_ROOT/tty.pos"
  if [[ ! -e "$LAB_ROOT/tty.in" ]] || (( $(wc -l < "$LAB_ROOT/tty.in") < pos )); then return 1; fi
  sed -n "${pos}p" "$LAB_ROOT/tty.in"
}
