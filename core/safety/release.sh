# shellcheck shell=bash
# core/safety/release.sh: the release check (design 07, section 5).
#
# release.sha256, in Labyrinth's folder, lists the SHA-256 of every file
# Labyrinth runs: one '<sha256>  <path>' line per file, the format of
# sha256sum, with the path relative to the folder. It is made from the
# copy of the release that is deployed (tools/release/manifest.sh). The
# team keeps the SHA-256 of release.sha256 itself in its offline record,
# and the operator compares it with the one Labyrinth prints.
#
# The runner loads this file on its own, before the rest of the core, so a
# changed core file is found before any of it runs. It needs nothing else
# from the core, and loading it changes nothing.
#
# The check cannot defend against an intruder who changes the runner or
# this file as well: they could print whatever hash was expected. The
# manual says how to check the release with the host's own tools instead.

# The files the release list covers: the runners, and every file under
# these folders.
LAB_RELEASE_FILES='labyrinth.sh labyrinth.ps1'
LAB_RELEASE_DIRS='core phases platform profiles vendor'
LAB_RELEASE_HASH=''     # SHA-256 of release.sha256, once it is read
LAB_RELEASE_PROBLEM=''  # why the check failed

# lab_release_sha FILE: print the SHA-256 of FILE.
lab_release_sha() {
  local h
  h="$(sha256sum < "$1")" || return 1
  printf '%s\n' "${h%% *}"
}

# lab_release_files ROOT: print, sorted, the path under ROOT of every
# file the release list covers.
lab_release_files() {
  local f d
  (
    cd -- "$1" || exit 1
    for f in $LAB_RELEASE_FILES; do
      if [[ -e "$f" || -L "$f" ]]; then printf '%s\n' "$f"; fi
    done
    for d in $LAB_RELEASE_DIRS; do
      if [[ -d "$d" ]]; then find "$d" ! -type d -print || exit 1; fi
    done
  ) | LC_ALL=C sort
}

# lab_release_write ROOT: write ROOT/release.sha256 from the files under
# ROOT and print its SHA-256. Run at release time, on the copy that is
# deployed, never by the runner.
lab_release_write() {
  local root="$1" files path h tmp
  files="$(lab_release_files "$root")" || return 1
  tmp="$root/release.sha256.new"
  : > "$tmp" || return 1
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if [[ ! "$path" =~ ^[A-Za-z0-9._/-]+$ || -L "$root/$path" || ! -f "$root/$path" ]]; then
      printf 'release: not a plain file with a plain name: %s\n' "$path" >&2
      rm -f -- "$tmp"; return 1
    fi
    h="$(lab_release_sha "$root/$path")" || { rm -f -- "$tmp"; return 1; }
    printf '%s  %s\n' "$h" "$path" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
  done <<< "$files"
  mv -f -- "$tmp" "$root/release.sha256" || return 1
  lab_release_sha "$root/release.sha256"
}

# lab_release_check ROOT: check every file under ROOT against
# ROOT/release.sha256. Sets LAB_RELEASE_HASH to the list's SHA-256.
# Returns 0 if every file matches and no file is missing or extra, 1 if
# there is no release list, and 2, with LAB_RELEASE_PROBLEM set, if
# anything differs.
lab_release_check() {
  local root="$1" list="$1/release.sha256" n=0 line hash path h files
  local -A listed=()
  LAB_RELEASE_HASH='' LAB_RELEASE_PROBLEM=''
  if [[ ! -e "$list" && ! -L "$list" ]]; then return 1; fi
  if ! command -v sha256sum > /dev/null 2>&1; then
    LAB_RELEASE_PROBLEM='sha256sum is not on this host, so the release cannot be checked'
    return 2
  fi
  if [[ -L "$list" || ! -f "$list" ]]; then
    LAB_RELEASE_PROBLEM='release.sha256 is not a plain file'
    return 2
  fi
  LAB_RELEASE_HASH="$(lab_release_sha "$list")" \
    || { LAB_RELEASE_PROBLEM='release.sha256 cannot be read'; return 2; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    if [[ ! "$line" =~ ^([0-9a-f]{64})\ \ ([A-Za-z0-9._/-]+)$ ]]; then
      LAB_RELEASE_PROBLEM="line $n of release.sha256 is not '<sha256>  <path>'"
      return 2
    fi
    hash="${BASH_REMATCH[1]}" path="${BASH_REMATCH[2]}"
    case "/$path/" in
      */../* | */./* | *//*)
        LAB_RELEASE_PROBLEM="line $n of release.sha256 names a path outside Labyrinth's folder"
        return 2 ;;
    esac
    if [[ -n "${listed[$path]:-}" ]]; then
      LAB_RELEASE_PROBLEM="release.sha256 lists $path twice"
      return 2
    fi
    listed[$path]=1
    if [[ -L "$root/$path" || ! -f "$root/$path" ]]; then
      LAB_RELEASE_PROBLEM="$path is missing, or is not a plain file"
      return 2
    fi
    h="$(lab_release_sha "$root/$path")" \
      || { LAB_RELEASE_PROBLEM="$path cannot be read"; return 2; }
    if [[ "$h" != "$hash" ]]; then
      LAB_RELEASE_PROBLEM="$path differs from the release"
      return 2
    fi
  done < "$list"
  if (( n == 0 )); then
    LAB_RELEASE_PROBLEM='release.sha256 lists no files'
    return 2
  fi
  files="$(lab_release_files "$root")" \
    || { LAB_RELEASE_PROBLEM="the files in $root cannot be listed"; return 2; }
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if [[ ! "$path" =~ ^[A-Za-z0-9._/-]+$ ]] || [[ -z "${listed[$path]:-}" ]]; then
      LAB_RELEASE_PROBLEM="$path is not in the release"
      return 2
    fi
  done <<< "$files"
  return 0
}
