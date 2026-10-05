# shellcheck shell=bash
# core/quarantine/quarantine.sh: quarantine, never delete (design 17,
# section 5.1). Sourced through core/lib.sh.
#
# Each function takes an item and the reason the module gives for it, records
# the step in the run manifest, then disables the item and moves it aside to
# <backup>/quarantine/<run>/<seq>/. The helper does not judge an item: the
# module decides its class (design 17, section 4). lab_quarantine_restore
# undoes the current module's entries, newest first.
#
# Return codes: 0 done (or the item is already gone), 20 refused, 40 error.
# The reason goes to standard error.

_lab_q_err() { printf 'quarantine: %s\n' "$1" >&2; }

_lab_q_dir() { printf '%s/quarantine/%s' "$LAB_BACKUP_DIR" "${1:-$LAB_RUN_ID}"; }

_lab_q_changing() {
  if [[ "${LAB_DRY_RUN:-1}" != 0 ]]; then
    _lab_q_err "$1 is refused in plan mode"
    return 20
  fi
}

# _lab_q_path_ok PATH: absolute, no '..', and outside Labyrinth's own tree.
_lab_q_path_ok() {
  local p="$1" d
  if [[ "$p" != /* || "$p" == */../* || "$p" == */.. ]]; then
    _lab_q_err "path must be absolute, without '..': $p"
    return 20
  fi
  for d in "${LAB_ROOT:-}" "${LAB_STATE_DIR:-}" "${LAB_BACKUP_DIR:-}" "${LAB_LOG_DIR:-}" "${LAB_CONFIG_DIR:-}"; do
    if [[ -n "$d" && ( "$p" == "$d" || "$p" == "$d"/* ) ]]; then
      _lab_q_err "refusing a path inside Labyrinth's own tree: $p"
      return 20
    fi
  done
}

_lab_q_sha() {
  local s
  s="$(sha256sum -- "$1")" || return 1
  printf '%s\n' "${s%% *}"
}

# _lab_q_meta PATH: "uid:gid mode sha256", or "uid:gid link target" for a
# symbolic link.
_lab_q_meta() {
  local own
  own="$(stat -c '%u:%g %a' -- "$1")" || return 1
  if [[ -L "$1" ]]; then
    printf '%s link %s\n' "${own% *}" "$(readlink -- "$1")"
  else
    printf '%s %s\n' "$own" "$(_lab_q_sha "$1")"
  fi
}

# lab_quarantine_file PATH REASON: move a file (or a symbolic link) aside.
lab_quarantine_file() {
  local path="${1:-}" reason="${2:-}" dest meta
  _lab_q_changing "quarantine of $path" || return
  _lab_q_path_ok "$path" || return
  [[ -e "$path" || -L "$path" ]] || return 0
  if [[ -d "$path" && ! -L "$path" ]]; then
    _lab_q_err "refusing a folder (list it for a person): $path"
    return 20
  fi
  dest="$(_lab_q_dir)/$(lab_manifest_next_seq)$path"
  meta="$(_lab_q_meta "$path")" || { _lab_q_err "cannot read $path"; return 40; }
  lab_manifest_record quarantine_file "$path" "$dest" "$meta" "$reason" || return 40
  mkdir -p -- "$(dirname -- "$dest")" || return 40
  mv -- "$path" "$dest" || { _lab_q_err "could not move $path to $dest"; return 40; }
  lab_log_info quarantine_file "quarantined $path: $reason" || true
}

_lab_q_restore_file() {
  local target="$1" backup="$2" prev="$3" seq="$4" run="$5" own mode rest aside
  if [[ ! -e "$backup" && ! -L "$backup" ]]; then
    [[ -e "$target" || -L "$target" ]] && return 0
    _lab_q_err "quarantined copy missing: $backup"
    return 40
  fi
  own="${prev%% *}"
  rest="${prev#* }"
  mode="${rest%% *}"
  if [[ "$mode" != link && "$(_lab_q_sha "$backup")" != "${rest#* }" ]]; then
    _lab_q_err "the quarantined copy of $target has changed; restore it by hand from $backup"
    return 40
  fi
  if [[ -e "$target" || -L "$target" ]]; then
    aside="$(_lab_q_dir "$run")/aside-$seq$target"
    mkdir -p -- "$(dirname -- "$aside")" && mv -- "$target" "$aside" || return 40
  fi
  mkdir -p -- "$(dirname -- "$target")" && mv -- "$backup" "$target" || return 40
  chown -h -- "$own" "$target" || return 40
  [[ "$mode" == link ]] || chmod -- "$mode" "$target" || return 40
  if lab_have restorecon; then
    restorecon -- "$target" 2> /dev/null || true
  fi
}

_lab_q_marker() { printf '# labyrinth-quarantine %s-%s: ' "$1" "$2"; }

# _lab_q_rewrite FILE FROM TO: replace every line equal to FROM with TO, in
# place, so the file keeps its owner, mode and inode.
_lab_q_rewrite() {
  local file="$1" from="$2" to="$3" tmp line
  tmp="$(mktemp "$LAB_STATE_DIR/cron.XXXXXX")" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$from" ]]; then
      printf '%s\n' "$to"
    else
      printf '%s\n' "$line"
    fi
  done < "$file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  cat -- "$tmp" > "$file" || { rm -f -- "$tmp"; return 1; }
  rm -f -- "$tmp"
  # cron rereads a per-user crontab when its spool folder changes.
  case "$file" in
    */spool/cron/*) touch -- "$(dirname -- "$file")" ;;
  esac
}

# _lab_q_cron_done FILE LINE: is LINE already commented out by a marker?
_lab_q_cron_done() {
  local l
  while IFS= read -r l || [[ -n "$l" ]]; do
    [[ "$l" == '# labyrinth-quarantine '*': '"$2" ]] && return 0
  done < "$1"
  return 1
}

# lab_quarantine_cron FILE LINE REASON: comment out LINE with a marker.
lab_quarantine_cron() {
  local file="${1:-}" line="${2:-}" reason="${3:-}" seq marker
  _lab_q_changing "quarantine of a cron line in $file" || return
  _lab_q_path_ok "$file" || return
  if [[ ! -f "$file" || -L "$file" || -z "$line" ]]; then
    _lab_q_err "not a crontab, or no line given: $file"
    return 20
  fi
  if ! grep -qxF -- "$line" "$file"; then
    _lab_q_cron_done "$file" "$line" && return 0
    _lab_q_err "the line is not in $file"
    return 20
  fi
  mkdir -p -- "$LAB_STATE_DIR"
  seq="$(lab_manifest_next_seq)"
  marker="$(_lab_q_marker "$LAB_RUN_ID" "$seq")"
  lab_manifest_record quarantine_cron "$file" '' "$line" "$reason" || return 40
  _lab_q_rewrite "$file" "$line" "$marker$line" || { _lab_q_err "could not edit $file"; return 40; }
  lab_log_info quarantine_cron "commented out a line in $file: $reason" || true
}

_lab_q_restore_cron() {
  local file="$1" line="$2" seq="$3" run="$4" marker
  [[ -f "$file" ]] || { _lab_q_err "crontab missing: $file"; return 40; }
  marker="$(_lab_q_marker "$run" "$seq")"
  grep -qxF -- "$marker$line" "$file" || return 0
  mkdir -p -- "$LAB_STATE_DIR"
  _lab_q_rewrite "$file" "$marker$line" "$line" || return 40
}

# lab_quarantine_unit UNIT REASON: disable and stop a systemd unit, then
# quarantine its unit file. Only a unit file under /etc is quarantined.
lab_quarantine_unit() {
  local unit="${1:-}" reason="${2:-}" frag enabled active
  _lab_q_changing "quarantine of $unit" || return
  lab_have systemctl || { _lab_q_err 'systemctl is not on this host'; return 20; }
  [[ "$unit" =~ ^[A-Za-z0-9@:._-]+$ ]] || { _lab_q_err "not a unit name: $unit"; return 40; }
  frag="$(systemctl show -p FragmentPath "$unit" 2> /dev/null)" || frag=''
  frag="${frag#FragmentPath=}"
  if [[ -z "$frag" ]]; then
    [[ "$(systemctl show -p LoadState "$unit" 2> /dev/null)" == 'LoadState=not-found' ]] && return 0
    _lab_q_err "$unit has no unit file"
    return 20
  fi
  if [[ "${frag#"${LAB_SYSROOT:-}"}" != /etc/* ]]; then
    _lab_q_err "$unit's file is not under /etc ($frag); a package's unit is only disabled after approval"
    return 20
  fi
  enabled="$(systemctl is-enabled "$unit" 2> /dev/null)" || true
  active="$(systemctl is-active "$unit" 2> /dev/null)" || true
  lab_manifest_record quarantine_unit "$unit" "$frag" "enabled=${enabled:-unknown} active=${active:-unknown}" "$reason" || return 40
  systemctl disable "$unit" > /dev/null 2>&1 || { _lab_q_err "could not disable $unit"; return 40; }
  systemctl stop "$unit" > /dev/null 2>&1 || { _lab_q_err "could not stop $unit"; return 40; }
  lab_quarantine_file "$frag" "$reason" || return
  systemctl daemon-reload || return 40
}

_lab_q_restore_unit() {
  local unit="$1" prev="$2"
  systemctl daemon-reload || return 40
  if [[ "$prev" == *'enabled=enabled'* ]]; then
    systemctl enable "$unit" > /dev/null 2>&1 || return 40
  fi
  if [[ "$prev" == *'active=active'* ]]; then
    systemctl start "$unit" || return 40
  fi
}

# _lab_q_ancestor PID: is PID this shell or one of its parents?
_lab_q_ancestor() {
  local p="$BASHPID" stat
  while [[ -n "$p" && "$p" != 0 ]]; do
    [[ "$p" == "$1" ]] && return 0
    [[ "$p" == 1 ]] && break
    stat="$(cat "/proc/$p/stat" 2> /dev/null)" || break
    stat="${stat##*) }"
    p="$(printf '%s' "$stat" | { read -r _ ppid _ && printf '%s' "$ppid"; })"
  done
  [[ "$$" == "$1" ]]
}

# lab_quarantine_process PID REASON: end a process an item started. This
# cannot be restored; restoring the item restarts it if it is a running unit.
lab_quarantine_process() {
  local pid="${1:-}" reason="${2:-}" cmd
  _lab_q_changing "ending process $pid" || return
  [[ "$pid" =~ ^[0-9]+$ ]] || { _lab_q_err "not a process id: $pid"; return 40; }
  if [[ "$pid" == 1 ]] || _lab_q_ancestor "$pid"; then
    _lab_q_err "refusing to end process $pid"
    return 20
  fi
  [[ -d "/proc/$pid" ]] || return 0
  cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2> /dev/null)" || cmd=''
  lab_manifest_record quarantine_process "$pid" '' "${cmd% }" "$reason" || return 40
  kill -TERM "$pid" 2> /dev/null || return 0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -d "/proc/$pid" ]] || break
    sleep 0.3
  done
  if [[ -d "/proc/$pid" ]]; then
    kill -KILL "$pid" 2> /dev/null || true
  fi
  lab_log_info quarantine_process "ended process $pid (${cmd% }): $reason" || true
}

# lab_quarantine_restore: undo the current module's quarantine entries in
# the current run, newest first. Safe to run repeatedly.
lab_quarantine_restore() {
  local f line action target backup prev seq rc=0 r
  f="$(lab_manifest_file)"
  [[ -f "$f" ]] || return 0
  while IFS= read -r line; do
    [[ "$(lab_json_get "$line" module)" == "${LAB_MODULE_ID:-}" ]] || continue
    action="$(lab_json_get "$line" action)"
    target="$(lab_json_get "$line" target)"
    backup="$(lab_json_get "$line" backup)"
    prev="$(lab_json_get "$line" prev)"
    seq="$(lab_json_get "$line" seq)"
    r=0
    case "$action" in
      quarantine_file) _lab_q_restore_file "$target" "$backup" "$prev" "$seq" "$LAB_RUN_ID" || r=$? ;;
      quarantine_cron) _lab_q_restore_cron "$target" "$prev" "$seq" "$LAB_RUN_ID" || r=$? ;;
      quarantine_unit) _lab_q_restore_unit "$target" "$prev" || r=$? ;;
      *) continue ;;
    esac
    if [[ "$r" != 0 ]]; then
      _lab_q_err "could not restore $target ($action)"
      rc=40
    fi
  done < <(tac -- "$f")
  return "$rc"
}
