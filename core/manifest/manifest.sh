# shellcheck shell=bash
# core/manifest/manifest.sh: the run manifest (docs/Conventions.md section 7).
# Sourced through core/lib.sh.
#
# The manifest of a run is $LAB_STATE_DIR/runs/<run>/manifest.jsonl: one JSON
# object per line, all values strings, with the fields
#   ts run host module seq action target backup prev note
# Every change is recorded BEFORE it is made, so a run cut off at any point
# can still be rolled back: undoing a recorded change that never happened
# is harmless. Rollback replays a module's entries newest first.
#
# Never record a secret. `prev` holds a previous value only when that value
# is not secret; anything secret is restored from a backup file instead.

# lab_manifest_file [RUN]: path of a run's manifest.
lab_manifest_file() { printf '%s/runs/%s/manifest.jsonl' "$LAB_STATE_DIR" "${1:-$LAB_RUN_ID}"; }

# lab_manifest_next_seq: the sequence number the next entry will get.
lab_manifest_next_seq() {
  local f n=0
  f="$(lab_manifest_file)"
  [[ -f "$f" ]] && n="$(wc -l < "$f")"
  printf '%d' "$((n + 1))"
}

# lab_manifest_record ACTION TARGET [BACKUP] [PREV] [NOTE]: append an entry
# for LAB_MODULE_ID. Refused in plan mode.
lab_manifest_record() {
  local action="$1" target="${2:-}" backup="${3:-}" prev="${4:-}" note="${5:-}" f line
  if [[ "${LAB_DRY_RUN:-1}" != 0 ]]; then
    printf 'manifest: refused in plan mode (%s %s)\n' "$action" "$target" >&2
    return 1
  fi
  [[ "$action" =~ ^[a-z0-9_]+$ ]] || { printf 'manifest: bad action name: %s\n' "$action" >&2; return 1; }
  # Control characters are kept: lab_json_str escapes them, and refusing
  # them would let an attacker's file name or cron line stop a quarantine.
  f="$(lab_manifest_file)"
  mkdir -p "${f%/*}"
  line="{\"ts\":$(lab_json_str "$(lab_now)"),\"run\":$(lab_json_str "$LAB_RUN_ID")"
  line+=",\"host\":$(lab_json_str "$(lab_host)"),\"module\":$(lab_json_str "${LAB_MODULE_ID:-}")"
  line+=",\"seq\":$(lab_json_str "$(lab_manifest_next_seq)"),\"action\":$(lab_json_str "$action")"
  line+=",\"target\":$(lab_json_str "$target"),\"backup\":$(lab_json_str "$backup")"
  line+=",\"prev\":$(lab_json_str "$prev"),\"note\":$(lab_json_str "$note")}"
  printf '%s\n' "$line" >> "$f"
}

# lab_json_unescape STRING: undo lab_json_str's escaping.
lab_json_unescape() {
  local s="$1" out='' c i hex
  if [[ "$s" != *\\* ]]; then
    printf '%s' "$s"
    return 0
  fi
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    if [[ "$c" != \\ ]]; then
      out+="$c"
      continue
    fi
    i=$((i + 1))
    c="${s:i:1}"
    case "$c" in
      n) out+=$'\n' ;;
      r) out+=$'\r' ;;
      t) out+=$'\t' ;;
      u)
        hex="${s:i+1:4}"
        [[ "$hex" =~ ^[0-9a-fA-F]{4}$ ]] || return 1
        printf -v c '%b' "\\u$hex"
        out+="$c"
        i=$((i + 4))
        ;;
      *) out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# lab_json_get LINE KEY: print the value of KEY in a flat JSON object whose
# values are all strings, as written by the core.
lab_json_get() {
  local re='"'"$2"'":"(([^"\\]|\\.)*)"'
  [[ "$1" =~ $re ]] || return 1
  lab_json_unescape "${BASH_REMATCH[1]}"
}

# lab_copy_private PATH: make a copy Labyrinth keeps under its data root
# changeable only by the account Labyrinth runs as (root): mode 600, unless
# it is a symbolic link, then that account as owner. Everything under the
# data root must be so, or Labyrinth refuses to run (lab_tree_trusted). The
# mode goes first, so a set-user-ID file never becomes root's.
lab_copy_private() {
  [[ -L "$1" ]] || chmod -- 600 "$1" || return 1
  chown -h -- "$(id -u):$(id -g)" "$1"
}

# lab_backup_file PATH: before changing PATH, copy it to the run's backup
# folder and record it, so rollback can put it back. If PATH does not exist
# yet, record that the module creates it. Returns 1, recording nothing, when
# the copy cannot be made: the caller must then leave PATH alone. The copy
# is made under a temporary name and renamed, so a backup the manifest lists
# is always a whole one. The copy is private to root (lab_copy_private); the
# file's own owner and mode go in the entry's prev field, "uid:gid mode".
lab_backup_file() {
  local path="$1" dir dest seq meta
  [[ "$path" == /* ]] || { printf 'backup: path must be absolute: %s\n' "$path" >&2; return 1; }
  if [[ -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then
    printf 'backup: not a regular file: %s\n' "$path" >&2
    return 1
  fi
  if [[ -f "$path" ]]; then
    dir="$LAB_BACKUP_DIR/$LAB_RUN_ID/$LAB_MODULE_ID"
    if ! mkdir -p "$dir"; then
      printf 'backup: cannot create %s; %s was not backed up\n' "$dir" "$path" >&2
      return 1
    fi
    seq="$(lab_manifest_next_seq)" || return 1
    dest="$dir/$seq-${path##*/}"
    if ! meta="$(stat -c '%u:%g %a' -- "$path")"; then
      printf 'backup: cannot read the owner and mode of %s; it was not backed up\n' "$path" >&2
      return 1
    fi
    if ! (umask 077 && cp --preserve=timestamps -- "$path" "$dest.part") \
        || ! lab_copy_private "$dest.part" || ! mv -- "$dest.part" "$dest"; then
      rm -f -- "$dest.part"
      printf 'backup: could not copy %s to %s; it was not backed up\n' "$path" "$dest" >&2
      return 1
    fi
    lab_manifest_record file "$path" "$dest" "$meta" || return 1
  else
    lab_manifest_record file_created "$path" || return 1
  fi
}

# lab_restore_one BACKUP TARGET [META]: put a backed-up file back, keeping
# the target's identity (inode, SELinux label) when it still exists. META is
# the file's owner and mode, "uid:gid mode", as lab_backup_file recorded
# them; without it they are taken from the backup itself, as entries written
# before the backup became private need. Returns 1 on the first step that
# fails, saying what state the target is left in.
lab_restore_one() {
  local backup="$1" target="$2" meta="${3:-}" own='' mode=''
  if [[ "$meta" =~ ^([0-9]+:[0-9]+)\ ([0-7]{1,4})$ ]]; then
    own="${BASH_REMATCH[1]}"
    mode="${BASH_REMATCH[2]}"
  fi
  [[ -f "$backup" ]] || { printf 'restore: backup missing: %s\n' "$backup" >&2; return 1; }
  if [[ -L "$target" || ( -e "$target" && ! -f "$target" ) ]]; then
    printf 'restore: %s is no longer a regular file; restore it by hand from %s\n' "$target" "$backup" >&2
    return 1
  fi
  if [[ -f "$target" ]]; then
    # Written into the existing file, so a failure part way leaves it short.
    if ! cat -- "$backup" > "$target"; then
      printf 'restore: could not write %s, which may now be incomplete; restore it by hand from %s\n' "$target" "$backup" >&2
      return 1
    fi
  elif ! (umask 077 && cp --preserve=timestamps -- "$backup" "$target"); then
    printf 'restore: could not copy %s back to %s\n' "$backup" "$target" >&2
    return 1
  fi
  # The owner first: changing it can clear the set-user-ID bits of the mode.
  if [[ -n "$own" ]]; then
    if ! chown -- "$own" "$target" || ! chmod -- "$mode" "$target"; then
      printf 'restore: %s has its content back, but its owner (%s) or mode (%s) could not be set\n' "$target" "$own" "$mode" >&2
      return 1
    fi
  elif ! chown --reference="$backup" -- "$target" || ! chmod --reference="$backup" -- "$target"; then
    printf 'restore: %s has its content back, but its mode or owner could not be set; compare it with %s\n' "$target" "$backup" >&2
    return 1
  fi
  if command -v restorecon > /dev/null 2>&1; then
    restorecon -- "$target" 2> /dev/null || true
  fi
}

# lab_restore_files: undo every file entry LAB_MODULE_ID recorded in
# LAB_RUN_ID, newest first. A file the module created is moved into the
# backup folder, never deleted, and made private to root there; its owner
# and mode go in the log. Safe to run repeatedly.
lab_restore_files() {
  local f line module action target backup prev seq aside was rc=0
  f="$(lab_manifest_file)"
  [[ -f "$f" ]] || return 0
  while IFS= read -r line; do
    module="$(lab_json_get "$line" module)" || continue
    [[ "$module" == "$LAB_MODULE_ID" ]] || continue
    action="$(lab_json_get "$line" action)"
    target="$(lab_json_get "$line" target)"
    case "$action" in
      file)
        backup="$(lab_json_get "$line" backup)"
        prev="$(lab_json_get "$line" prev)" || prev=''
        lab_restore_one "$backup" "$target" "$prev" || rc=1
        ;;
      file_created)
        if [[ -e "$target" || -L "$target" ]]; then
          seq="$(lab_json_get "$line" seq)"
          aside="$LAB_BACKUP_DIR/$LAB_RUN_ID/$LAB_MODULE_ID/rolled-back-$seq-${target##*/}"
          was="$(stat -c '%u:%g %a' -- "$target" 2> /dev/null)" || was='unknown'
          mkdir -p "${aside%/*}"
          if mv -- "$target" "$aside" && lab_copy_private "$aside"; then
            lab_log_info rolled_back_file "moved $target, which the module created, to $aside (owner and mode were $was)" 2> /dev/null || true
          else
            printf 'restore: could not move %s into the backup folder as %s, private to root\n' "$target" "$aside" >&2
            rc=1
          fi
        fi
        ;;
    esac
  done < <(tac -- "$f")
  return "$rc"
}

# lab_manifest_applied RUN: print, oldest first, the modules the run applied
# and has not rolled back since.
lab_manifest_applied() {
  local f line module action m
  local -a mods=() keep
  f="$(lab_manifest_file "$1")"
  [[ -f "$f" ]] || return 0
  while IFS= read -r line; do
    action="$(lab_json_get "$line" action)" || continue
    module="$(lab_json_get "$line" module)"
    case "$action" in
      apply_start)
        lab_in_list "$module" "${mods[*]-}" || mods+=("$module")
        ;;
      rolled_back)
        keep=()
        for m in "${mods[@]+"${mods[@]}"}"; do
          [[ "$m" == "$module" ]] || keep+=("$m")
        done
        mods=("${keep[@]+"${keep[@]}"}")
        ;;
    esac
  done < "$f"
  for m in "${mods[@]+"${mods[@]}"}"; do
    printf '%s\n' "$m"
  done
}

# lab_manifest_kept RUN: print, oldest first, the modules of the run that
# were kept once verified (module_kept) and not applied again or rolled back
# since. rollback leaves them alone unless given --all (Conventions 3.1).
lab_manifest_kept() {
  local f line module action m
  local -a mods=() rest
  f="$(lab_manifest_file "$1")"
  [[ -f "$f" ]] || return 0
  while IFS= read -r line; do
    action="$(lab_json_get "$line" action)" || continue
    module="$(lab_json_get "$line" module)"
    case "$action" in
      module_kept)
        lab_in_list "$module" "${mods[*]-}" || mods+=("$module")
        ;;
      apply_start | rolled_back)
        rest=()
        for m in "${mods[@]+"${mods[@]}"}"; do
          [[ "$m" == "$module" ]] || rest+=("$m")
        done
        mods=("${rest[@]+"${rest[@]}"}")
        ;;
    esac
  done < "$f"
  for m in "${mods[@]+"${mods[@]}"}"; do
    printf '%s\n' "$m"
  done
}
