# shellcheck shell=bash
# core/safety/system.sh: the operating-system side of the safety code for
# Linux: the administrator check and the dead-man revert timer (design 03,
# section 8). The ownership checks are in core/safety/trust.sh. Sourced
# through core/lib.sh.
#
# The timer of a run is a systemd timer and service named
# lab-revert-<run>-<n>, written to /etc/systemd/system and enabled, so it
# survives a restart and fires at once if its time passed while the host
# was off. Each re-arm starts a new one, with a new <n>, and only then
# removes the last, so a failed re-arm leaves the earlier timer armed. The armed timer's name is kept in $LAB_STATE_DIR/runs/<run>/timer,
# and the time it fires in timer-due (UTC, YYYY-MM-DDTHH:MM:SSZ), which is
# advisory: it is shown to the operator, and nothing fails without it.
#
# The warning that logged-in sessions get shortly before the undo is a
# second pair, lab-warn-<run>-<n>, armed and removed with the timer; its
# name is kept in runs/<run>/warn. It is best effort: it never blocks the
# timer.

lab_is_admin() { [[ "$(id -u)" == 0 ]]; }

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

# lab_unit_exec ARG...: print ARG... as the value of ExecStart= in a unit
# file. Returns 1, printing nothing, if an ARG has a line break.
lab_unit_exec() {
  local cmd='' a q bs=\\ dq=\" pc=% dl=\$
  for a in "$@"; do
    if [[ "$a" == *$'\n'* ]]; then
      printf 'revert timer: the command has a line break, which a unit file cannot hold\n' >&2
      return 1
    fi
    # Quoted for ExecStart=: backslash and quote escaped, and % and $
    # doubled so systemd does not expand them. The replacements are quoted:
    # bash 5.2 and later treat an unquoted backslash there as an escape.
    q=${a//"$bs"/"$bs$bs"}; q=${q//"$dq"/"$bs$dq"}; q=${q//"$pc"/"$pc$pc"}; q=${q//"$dl"/"$dl$dl"}
    cmd+="${cmd:+ }\"$q\""
  done
  printf '%s' "$cmd"
}

# lab_timer_arm SECONDS RUN COMMAND [ARG...]: (re)arm the run's revert timer
# to run COMMAND (an absolute path) after SECONDS, unless cancelled.
lab_timer_arm() {
  local secs="$1" run="$2" dir n=1 unit old='' udir="${LAB_SYSTEMD_DIR:-/etc/systemd/system}"
  local cmd='' due
  shift 2
  if ! command -v systemctl > /dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
    printf 'revert timer: systemd is not available on this host, so no timer can be armed\n' >&2
    return 1
  fi
  cmd="$(lab_unit_exec "$@")" || return 1
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
  # Only now is the earlier timer removed; it may already have fired. One
  # that cannot be removed would still undo the run at its own, earlier
  # time, so its name is kept for the next arm, -k and -u to try again.
  _lab_timer_sweep "$run" || true
  if [[ -n "$old" ]] && ! lab_timer_remove "$old"; then
    printf '%s\n' "$old" >> "$dir/timer-old" || true
    printf 'revert timer: the earlier timer %s could not be removed and may still undo run %s at its earlier time\n' "$old" "$run" >&2
  fi
}

# _lab_timer_sweep RUN: remove the earlier revert timers of the run that
# could not be removed when it was re-armed; their names are kept, one per
# line, in $LAB_STATE_DIR/runs/<run>/timer-old. Returns 1, keeping the names
# of those still there, if any could not be removed.
_lab_timer_sweep() {
  local f="$LAB_STATE_DIR/runs/$1/timer-old" unit left=''
  [[ -f "$f" ]] || return 0
  while IFS= read -r unit || [[ -n "$unit" ]]; do
    [[ "$unit" =~ ^lab-revert-[A-Za-z0-9-]+$ ]] || continue
    lab_timer_remove "$unit" || left+="$unit"$'\n'
  done < "$f"
  if [[ -z "$left" ]]; then
    rm -f -- "$f"
    return 0
  fi
  printf '%s' "$left" > "$f" || true
  return 1
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

# lab_timer_cancel RUN: remove the run's revert timer, if one is armed, and
# first any earlier one a re-arm could not remove. Returns 1, keeping the
# state files, if a timer could not be removed, because the run might still
# be rolled back.
lab_timer_cancel() {
  local dir="$LAB_STATE_DIR/runs/$1" unit
  _lab_timer_sweep "$1" || return 1
  [[ -f "$dir/timer" ]] || return 0
  unit="$(cat "$dir/timer")"
  lab_timer_remove "$unit" || return 1
  rm -f -- "$dir/timer" "$dir/timer-due"
  # The warning goes with it. Best effort: one left behind sees that the
  # run has no timer and sends nothing.
  lab_warn_cancel "$1" > /dev/null 2>&1 || true
}

# lab_warn_lead SECONDS: print how many seconds before the undo the warning
# is sent for a timer of SECONDS: 60, or half the time when the timer is
# shorter than two minutes (docs/Conventions.md, section 3.1). 0 means the
# timer is too short to warn.
lab_warn_lead() {
  if (( $1 >= 120 )); then printf '60\n'; else printf '%s\n' "$(( $1 / 2 ))"; fi
}

# lab_warn_arm SECONDS RUN COMMAND [ARG...]: (re)arm the run's warning, to
# run COMMAND (an absolute path) lab_warn_lead seconds before its revert
# timer, which is SECONDS from now, fires. Called right after lab_timer_arm,
# whose count it shares: the units are lab-warn-<run>-<n>, and the armed
# one's name is kept in $LAB_STATE_DIR/runs/<run>/warn. As for the timer,
# the new one is made before the earlier one is removed. Best effort for the
# caller: on failure the earlier warning is removed too, as it would name
# the wrong time, and 1 is returned.
lab_warn_arm() {
  local secs="$1" run="$2" dir lead n unit old='' udir="${LAB_SYSTEMD_DIR:-/etc/systemd/system}"
  local cmd='' due
  shift 2
  dir="$LAB_STATE_DIR/runs/$run"
  lead="$(lab_warn_lead "$secs")"
  if (( lead < 1 )); then lab_warn_cancel "$run" || true; return 0; fi
  [[ -f "$dir/timer-count" ]] || return 1
  n="$(cat "$dir/timer-count")"
  if [[ -f "$dir/warn" ]]; then old="$(cat "$dir/warn")"; fi
  secs=$(( secs - lead ))
  unit="lab-warn-$run-$n"
  cmd="$(lab_unit_exec "$@")" || { lab_warn_cancel "$run" || true; return 1; }
  due="$(date -d "@$(( $(date +%s) + secs ))" '+%Y-%m-%d %H:%M:%S')" || { lab_warn_cancel "$run" || true; return 1; }
  if ! printf '%s\n' '[Unit]' "Description=Labyrinth revert warning for run $run" '' \
        '[Service]' "ExecStart=$cmd" > "$udir/$unit.service" \
      || ! printf '%s\n' '[Unit]' "Description=Labyrinth revert warning for run $run" '' \
        '[Timer]' "OnCalendar=$due" 'Persistent=true' "OnActiveSec=${secs}s" 'AccuracySec=1s' '' \
        '[Install]' 'WantedBy=timers.target' > "$udir/$unit.timer" \
      || ! systemctl daemon-reload \
      || ! systemctl enable --quiet "$unit.timer" \
      || ! systemctl start "$unit.timer"; then
    lab_timer_remove "$unit" > /dev/null 2>&1 || true
    lab_warn_cancel "$run" || true
    return 1
  fi
  printf '%s\n' "$unit" > "$dir/warn" || { lab_timer_remove "$unit" > /dev/null 2>&1 || true; return 1; }
  if [[ -n "$old" && "$old" != "$unit" ]]; then
    lab_timer_remove "$old" > /dev/null 2>&1 || true
  fi
}

# lab_warn_cancel RUN: remove the run's warning, if one is armed. Returns 1,
# keeping the state file, if its units could not be removed.
lab_warn_cancel() {
  local f="$LAB_STATE_DIR/runs/$1/warn" unit=''
  [[ -f "$f" ]] || return 0
  IFS= read -r unit < "$f" || [[ -n "$unit" ]] || return 1
  [[ "$unit" =~ ^lab-warn-[A-Za-z0-9-]+$ ]] || { rm -f -- "$f"; return 0; }
  lab_timer_remove "$unit" || return 1
  rm -f -- "$f"
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

# lab_timer_left RUN: print the whole seconds until the run's revert timer
# fires, 0 when that time has passed; 1 if the time is unknown. --extend
# adds one timer length to this and re-arms (lab_timer_arm) for the total.
lab_timer_left() {
  local due at now
  due="$(lab_timer_due "$1")" || return 1
  at="$(date -u -d "$due" +%s 2> /dev/null)" || return 1
  now="$(date +%s)"
  if (( at > now )); then printf '%s\n' "$(( at - now ))"; else printf '0\n'; fi
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

# lab_timer_ready: could a revert timer be armed now? It only looks: it
# arms nothing. Needs systemctl, a running systemd, a folder root can write
# the unit files to, and a systemd that answers. Returns 1 with the reason
# on stderr when not (--doctor).
lab_timer_ready() {
  local udir="${LAB_SYSTEMD_DIR:-/etc/systemd/system}"
  if ! command -v systemctl > /dev/null 2>&1; then
    printf 'systemctl is not on this host
' >&2; return 1
  fi
  if [[ ! -d /run/systemd/system ]]; then
    printf 'systemd is not running
' >&2; return 1
  fi
  if [[ ! -d "$udir" || ! -w "$udir" ]]; then
    printf '%s is not a folder root can write to
' "$udir" >&2; return 1
  fi
  if ! systemctl list-timers --no-pager > /dev/null 2>&1; then
    printf 'systemd does not answer
' >&2; return 1
  fi
}

# lab_clock_sync: is a time-sync service running on this host? Prints its
# name and returns 0; returns 1 when none is running, and 2 when this host
# has no way to tell. It reads only the local service list, never the
# network (--doctor).
lab_clock_sync() {
  local u known=0
  if command -v systemctl > /dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    known=1
    for u in systemd-timesyncd chronyd chrony ntpd ntp ntpsec; do
      if systemctl is-active --quiet "$u" 2> /dev/null; then printf '%s
' "$u"; return 0; fi
    done
  fi
  if command -v pgrep > /dev/null 2>&1; then
    known=1
    # The process names systemd-timesyncd and others are cut to 15 characters.
    for u in systemd-timesyn chronyd ntpd; do
      if pgrep -x "$u" > /dev/null 2>&1; then printf '%s
' "$u"; return 0; fi
    done
  fi
  if (( known )); then return 1; fi
  return 2
}

# lab_notify_all MESSAGE: write MESSAGE to every terminal logged in on this
# host, so the team learns that a run was rolled back even when no one is
# watching the revert timer. Best effort: returns 1 when wall is missing or
# fails, and the caller goes on.
lab_notify_all() {
  command -v wall > /dev/null 2>&1 || return 1
  printf '%s\n' "$1" | wall > /dev/null 2>&1
}
