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

# lab_backup_file PATH: before changing PATH, copy it to the run's backup
# folder and record it, so rollback can put it back. If PATH does not exist
# yet, record that the module creates it.
lab_backup_file() {
  local path="$1" dir dest
  [[ "$path" == /* ]] || { printf 'backup: path must be absolute: %s\n' "$path" >&2; return 1; }
  if [[ -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then
    printf 'backup: not a regular file: %s\n' "$path" >&2
    return 1
  fi
  if [[ -f "$path" ]]; then
    dir="$LAB_BACKUP_DIR/$LAB_RUN_ID/$LAB_MODULE_ID"
    mkdir -p "$dir"
    dest="$dir/$(lab_manifest_next_seq)-${path##*/}"
    cp -p -- "$path" "$dest"
    lab_manifest_record file "$path" "$dest"
  else
    lab_manifest_record file_created "$path"
  fi
}

# lab_restore_one BACKUP TARGET: put a backed-up file back, keeping the
# target's identity (inode, SELinux label) when it still exists.
lab_restore_one() {
  local backup="$1" target="$2"
  [[ -f "$backup" ]] || { printf 'restore: backup missing: %s\n' "$backup" >&2; return 1; }
  if [[ -L "$target" || ( -e "$target" && ! -f "$target" ) ]]; then
    printf 'restore: %s is no longer a regular file; restore it by hand from %s\n' "$target" "$backup" >&2
    return 1
  fi
  if [[ -f "$target" ]]; then
    cat -- "$backup" > "$target"
    chmod --reference="$backup" -- "$target"
    chown --reference="$backup" -- "$target"
  else
    cp -p -- "$backup" "$target"
  fi
  if command -v restorecon > /dev/null 2>&1; then
    restorecon -- "$target" 2> /dev/null || true
  fi
}

# lab_restore_files: undo every file entry LAB_MODULE_ID recorded in
# LAB_RUN_ID, newest first. A file the module created is moved into the
# backup folder, never deleted. Safe to run repeatedly.
lab_restore_files() {
  local f line module action target backup seq aside rc=0
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
        lab_restore_one "$backup" "$target" || rc=1
        ;;
      file_created)
        if [[ -e "$target" || -L "$target" ]]; then
          seq="$(lab_json_get "$line" seq)"
          aside="$LAB_BACKUP_DIR/$LAB_RUN_ID/$LAB_MODULE_ID/rolled-back-$seq-${target##*/}"
          mkdir -p "${aside%/*}"
          mv -- "$target" "$aside" || rc=1
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
