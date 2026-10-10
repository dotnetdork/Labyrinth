# shellcheck shell=bash
# core/safety/system.sh: the operating-system side of the safety code for
# Linux: the administrator and ownership checks and the dead-man revert
# timer (design 01, section 8). Sourced through core/lib.sh.
#
# The timer of a run is a systemd timer and service named
# lab-revert-<run>-<n>, written to /etc/systemd/system and enabled, so it
# survives a restart and fires at once if its time passed while the host
# was off. Each re-arm starts a new one, with a new <n>, and only then
# removes the last, so a failed re-arm leaves the earlier timer armed. The armed timer's name is kept in $LAB_STATE_DIR/runs/<run>/timer,
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

# lab_console_session ACCOUNT: print the ID of a session ACCOUNT has at
# this host's own console (a seat or a local terminal, not a remote
# login). Returns 1 if there is none, and 2 if this host cannot tell. This
# supports the operator's break-glass answer; it does not prove the
# password works.
lab_console_session() {
  local account="$1" sessions id user props k v remote seat tty
  if lab_have loginctl && sessions="$(loginctl list-sessions --no-legend 2> /dev/null)"; then
    while read -r id _ user _; do
      [[ -n "$id" && "$user" == "$account" ]] || continue
      props="$(loginctl show-session "$id" -p Remote -p Seat -p TTY 2> /dev/null)" || continue
      remote='' seat='' tty=''
      while IFS='=' read -r k v; do
        case "$k" in
          Remote) remote="$v" ;;
          Seat) seat="$v" ;;
          TTY) tty="$v" ;;
        esac
      done <<< "$props"
      if [[ "$remote" == no ]] && [[ -n "$seat" || "$tty" == tty* ]]; then
        printf '%s\n' "$id"
        return 0
      fi
    done <<< "$sessions"
    return 1
  fi
  if lab_have who; then
    while read -r user tty _; do
      if [[ "$user" == "$account" ]] && [[ "$tty" == tty* || "$tty" == console || "$tty" == :* ]]; then
        printf '%s\n' "$tty"
        return 0
      fi
    done < <(who 2> /dev/null)
    return 1
  fi
  return 2
}

# lab_timer_arm SECONDS RUN COMMAND [ARG...]: (re)arm the run's revert timer
# to run COMMAND (an absolute path) after SECONDS, unless cancelled.
lab_timer_arm() {
  local secs="$1" run="$2" dir n=1 unit old='' udir="${LAB_SYSTEMD_DIR:-/etc/systemd/system}"
  local cmd='' a q due bs=\\ dq=\" pc=% dl=\$
  shift 2
  if ! command -v systemctl > /dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
    printf 'revert timer: systemd is not available on this host, so no timer can be armed\n' >&2
    return 1
  fi
  for a in "$@"; do
    if [[ "$a" == *$'\n'* ]]; then
      printf 'revert timer: the command has a line break, which a unit file cannot hold\n' >&2
      return 1
    fi
    # Quoted for ExecStart=: backslash and quote escaped, and % and $
    # doubled so systemd does not expand them.
    q=${a//"$bs"/$bs$bs}; q=${q//"$dq"/$bs$dq}; q=${q//"$pc"/$pc$pc}; q=${q//"$dl"/$dl$dl}
    cmd+="${cmd:+ }\"$q\""
  done
  dir="$LAB_STATE_DIR/runs/$run"
  mkdir -p "$dir" || return 1
  if [[ -f "$dir/timer-count" ]]; then
    n=$(( $(cat "$dir/timer-count") + 1 ))
  fi
  if [[ -f "$dir/timer" ]]; then old="$(cat "$dir/timer")"; fi
  unit="lab-revert-$run-$n"
  # Local time, which is how systemd reads a calendar time with no zone.
  due="$(date -d "@$(( $(date +%s) + secs ))" '+%Y-%m-%d %H:%M:%S')" || return 1
  if ! printf '%s\n' '[Unit]' "Description=Labyrinth revert timer for run $run" '' \
        '[Service]' "ExecStart=$cmd" > "$udir/$unit.service" \
      || ! printf '%s\n' '[Unit]' "Description=Labyrinth revert timer for run $run" '' \
        '[Timer]' "OnCalendar=$due" 'Persistent=true' "OnActiveSec=${secs}s" 'AccuracySec=1s' '' \
        '[Install]' 'WantedBy=timers.target' > "$udir/$unit.timer" \
      || ! systemctl daemon-reload \
      || ! systemctl enable --quiet "$unit.timer" \
      || ! systemctl start "$unit.timer"; then
    lab_timer_remove "$unit" > /dev/null 2>&1 || true
    return 1
  fi
  printf '%s\n' "$n" > "$dir/timer-count"
  printf '%s\n' "$unit" > "$dir/timer"
  lab_timer_due_write "$run" "$secs"
  # Only now is the earlier timer removed; it may already have fired.
  if [[ -n "$old" ]]; then
    lab_timer_remove "$old" || true
  fi
}

# lab_timer_remove UNIT: stop and disable a revert timer and delete its two
# unit files, which Labyrinth wrote; they are the only files it deletes
# outside its own paths (docs/Conventions.md, section 3.1). The service is
# never stopped: when the timer has fired, it is the rollback calling this.
# Returns 1, leaving the files, if the timer is still active after being
# stopped, and 1 if a file could not be deleted.
lab_timer_remove() {
  local unit="$1" udir="${LAB_SYSTEMD_DIR:-/etc/systemd/system}"
  # The timer may already have fired or been stopped by hand.
  systemctl stop "$unit.timer" 2> /dev/null || true
  if systemctl is-active --quiet "$unit.timer" 2> /dev/null; then
    printf 'revert timer: %s.timer is still active after being stopped\n' "$unit" >&2
    return 1
  fi
  systemctl disable --quiet "$unit.timer" 2> /dev/null || true
  rm -f -- "$udir/$unit.timer" "$udir/$unit.service" 2> /dev/null || true
  systemctl daemon-reload 2> /dev/null || true
  if [[ -e "$udir/$unit.timer" || -e "$udir/$unit.service" ]]; then
    printf 'revert timer: could not delete the unit files of %s in %s\n' "$unit" "$udir" >&2
    return 1
  fi
}

# lab_timer_cancel RUN: remove the run's revert timer, if one is armed.
# Returns 1, keeping the state files, if the timer could not be removed,
# because the run might still be rolled back.
lab_timer_cancel() {
  local dir="$LAB_STATE_DIR/runs/$1" unit
  [[ -f "$dir/timer" ]] || return 0
  unit="$(cat "$dir/timer")"
  lab_timer_remove "$unit" || return 1
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

# lab_timer_live RUN: is the armed timer still waiting in systemd? Its unit
# files may have been deleted or damaged while its state file stays.
# Returns 1 when systemd no longer has it, and 2 when this cannot be told.
lab_timer_live() {
  local f="$LAB_STATE_DIR/runs/$1/timer" unit=''
  [[ -f "$f" ]] || return 1
  IFS= read -r unit < "$f" || [[ -n "$unit" ]] || return 2
  command -v systemctl > /dev/null 2>&1 || return 2
  systemctl is-active --quiet "$unit.timer" 2> /dev/null && return 0
  # Firing makes the timer inactive while its rollback runs.
  systemctl is-active --quiet "$unit.service" 2> /dev/null && return 0
  return 1
}

# lab_notify_all MESSAGE: write MESSAGE to every terminal logged in on this
# host, so the team learns that a run was rolled back even when no one is
# watching the revert timer. Best effort: returns 1 when wall is missing or
# fails, and the caller goes on.
lab_notify_all() {
  command -v wall > /dev/null 2>&1 || return 1
  printf '%s\n' "$1" | wall > /dev/null 2>&1
}
