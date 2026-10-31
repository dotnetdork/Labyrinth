#!/usr/bin/env bash
# install.sh: the guided installer for Linux (docs/Conventions.md section 3.3;
# design 00 section 5.1 and design 21).
#
#   sudo ./install.sh [-y] [--root DIR]
#
# Run it from the release folder as root. It checks the release against
# release.sha256, prints its plan, asks "Install? [y/N]" (default no), and
# then: creates the data root, copies the code to <root>/bin, adds the
# commands /usr/bin/laby and /usr/bin/labyrinth, installs the manual and
# copies the config/*.example templates into <root>/etc without
# overwriting a file already there. Safe to run again. It refuses, changing
# nothing, while a revert timer is armed.
#
# The options --code-dir, --link-dir and --man-dir exist for the tests only:
# they point the installer at throwaway folders, so a test run never edits the
# real system folders. The same checks apply to whatever folders are given.
#
# Exit: 0 installed, or nothing to change; 20 refused; 40 usage error.
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)"
ME="${0##*/}"
DEFAULT_ROOT=/opt/labyrinth
ROOT="$DEFAULT_ROOT" CODE='' LINKDIR=/usr/bin MANDIR=/usr/local/share/man/man1
YES=0
STAGE='' OLD='' TMPS=()    # what the EXIT trap removes if the install stops partway

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [-y] [--root DIR]

Installs Labyrinth from this release folder. It checks the release, shows
what it will do and asks before it changes anything. Safe to run again.

  -y, --yes     answer yes to the question
  --root DIR    the data root (default /opt/labyrinth); the code goes in
                DIR/bin
  -h, --help    this page

It adds the code, the commands laby and labyrinth in /usr/bin, the manual
(man laby) and the configuration templates in DIR/etc (files already
there are kept). For tests only: --code-dir, --link-dir and --man-dir.
Exit: 0 done, 20 refused, 40 usage error.
Example: sudo ./install.sh
EOF
}

# usage_error WHAT: one line, then the pointer to the help; exit 40.
usage_error() {
  printf '%s: %s\n' "$ME" "$1" >&2
  printf "Try '%s -h'.\n" "$ME" >&2
  exit 40
}

# refuse WHAT [HINT]: the install stops, changing nothing more; exit 20.
refuse() {
  printf '%s: %s\n' "$ME" "$1" >&2
  if [[ -n "${2:-}" ]]; then printf '%s\n' "$2" >&2; fi
  exit 20
}

warn() { printf '%s: warning: %s\n' "$ME" "$1" >&2; }

# new_dir MODE DIR: make DIR (and any missing parents) with MODE. A folder that
# is already there is left exactly as it is: install -d would reset its mode.
new_dir() { [[ -d "$2" ]] || install -d -m "$1" -- "$2"; }

on_exit() {
  local t
  for t in "${TMPS[@]+"${TMPS[@]}"}"; do rm -f -- "$t"; done
  # Only this installer's own staging and swap folders, made next to the code.
  if [[ -n "$STAGE" && -d "$STAGE" ]]; then rm -rf -- "$STAGE"; fi
  if [[ -n "$OLD" && -d "$OLD" && ! -e "$CODE" ]]; then mv -- "$OLD" "$CODE"; fi
}
trap on_exit EXIT
on_error() {
  trap - ERR
  printf '%s: stopped at line %s (%s), exit 40\n' "$ME" "$2" "$3" >&2
  printf '%s\n' 'Some steps may be done. It is safe to run the installer again.' >&2
  exit 40
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

# need_value OPTION COUNT: the option's value must be there.
need_value() { (( $2 >= 2 )) || usage_error "$1 needs a value"; }

while (( $# > 0 )); do
  case "$1" in
    -y | --yes) YES=1; shift ;;
    -h | --help | '-?') usage; exit 0 ;;
    --root | --code-dir | --link-dir | --man-dir)
      need_value "$1" "$#"
      case "$1" in
        --root) ROOT="$2" ;;
        --code-dir) CODE="$2" ;;
        --link-dir) LINKDIR="$2" ;;
        --man-dir) MANDIR="$2" ;;
      esac
      shift 2 ;;
    --root=* | --code-dir=* | --link-dir=* | --man-dir=*)
      case "$1" in
        --root=*) ROOT="${1#*=}" ;;
        --code-dir=*) CODE="${1#*=}" ;;
        --link-dir=*) LINKDIR="${1#*=}" ;;
        --man-dir=*) MANDIR="${1#*=}" ;;
      esac
      shift ;;
    *) usage_error "unknown option '$1'" ;;
  esac
done
for v in ROOT LINKDIR MANDIR; do
  [[ "${!v}" == /* ]] || usage_error "the folder must be a full path, not '${!v}'"
done
[[ -z "$CODE" || "$CODE" == /* ]] || usage_error "the folder must be a full path, not '$CODE'"
ROOT="$(readlink -m -- "$ROOT")"
CODE_GIVEN="${CODE:-$ROOT/bin}"   # as given, so a link there can be refused below
CODE="$(readlink -m -- "$CODE_GIVEN")"
LINKDIR="$(readlink -m -- "$LINKDIR")"
MANDIR="$(readlink -m -- "$MANDIR")"

# 1. The release. Checked before any of its files is run.
for t in sha256sum readlink stat; do
  command -v "$t" > /dev/null 2>&1 || refuse "$t is not on this host, so the release cannot be installed"
done
[[ -f "$HERE/labyrinth.sh" && -f "$HERE/core/lib.sh" ]] \
  || refuse "$HERE is not a Labyrinth release folder" 'Run install.sh from the folder you unpacked.'
# shellcheck source=core/safety/release.sh
source "$HERE/core/safety/release.sh"
RELEASE=0                  # 0 checked, 1 no release list, 2 a file differs
lab_release_check "$HERE" || RELEASE=$?
if (( RELEASE == 2 )); then
  refuse "$LAB_RELEASE_PROBLEM, so this is not the release" \
    "Copy Labyrinth here again from the team's copy, as manual section 11 says."
fi
REL_HASH="$LAB_RELEASE_HASH"
# shellcheck source=core/banner/banner.sh
source "$HERE/core/banner/banner.sh"
export LAB_ROOT="$HERE"
# shellcheck source=core/lib.sh
source "$HERE/core/lib.sh"

lab_is_admin || refuse 'the installer must run as root' "Run it again as: sudo ./$ME"

# What the release holds: every file the release list covers, and the list.
mapfile -t FILES < <(lab_release_files "$HERE")
for f in "${FILES[@]+"${FILES[@]}"}"; do
  [[ "$f" =~ ^[A-Za-z0-9._/-]+$ && -f "$HERE/$f" && ! -L "$HERE/$f" ]] \
    || refuse "$f is not a plain file with a plain name, so the release cannot be installed"
done
if (( RELEASE == 0 )); then FILES+=(release.sha256); fi

# 2. Checks before anything changes.
real_here="$(readlink -f -- "$HERE")"
case "$real_here/" in
  "$CODE"/* ) refuse 'this is the installed copy of Labyrinth' 'Run install.sh from the release folder you unpacked, not from the installed code.' ;;
esac
case "$CODE/" in
  "$real_here"/* ) refuse "the code folder $CODE is inside the release folder" 'Choose a code folder outside it.' ;;
esac
if [[ -L "${CODE_GIVEN%/}" ]]; then refuse "${CODE_GIVEN%/} is a link, not a folder"; fi
if [[ -e "$CODE" ]]; then
  [[ -d "$CODE" ]] || refuse "$CODE exists and is not a folder"
  if [[ ! -f "$CODE/labyrinth.sh" && -n "$(ls -A -- "$CODE")" ]]; then
    refuse "$CODE is not empty and is not a Labyrinth folder, so it will not be replaced" \
      'Move what is in it away, or give another folder with --root.'
  fi
fi

# A revert timer that is armed would run code that this install replaces.
LAB_STATE_DIR="$ROOT/state"
ARMED=()
shopt -s nullglob
for d in "$LAB_STATE_DIR"/runs/*/; do
  run="${d%/}"; run="${run##*/}"
  if lab_timer_armed "$run"; then
    if due="$(lab_timer_due "$run")"; then
      ARMED+=("  run $run: its revert timer fires at $due (UTC)")
    else
      ARMED+=("  run $run: its revert timer is armed (fire time unknown)")
    fi
  fi
done
shopt -u nullglob
if (( ${#ARMED[@]} > 0 )); then
  printf '%s: not installing, because a revert timer is armed:\n' "$ME" >&2
  printf '%s\n' "${ARMED[@]}" >&2
  printf '%s\n' "Keep the run ('sudo laby -k ID') or undo it ('sudo laby -u ID') first, then run the installer again." >&2
  exit 20
fi

# Only root may change the data root, the code folder, the link folder or
# any folder above them: root runs this code, and so does the revert timer.
if bad="$(lab_path_trusted "$ROOT" "$CODE" "$LINKDIR")"; then :; else
  refuse "$bad can be changed by an account other than root, so nothing was installed" \
    'Make it owned by root and not writable by group or others, then run the installer again.'
fi
# An existing data root, and everything in it, too: the runner checks it the
# same way and would refuse every run.
if [[ -e "$ROOT" ]]; then
  if bad="$(lab_tree_trusted "$ROOT")"; then :; else
    refuse "$bad can be changed by an account other than root, so nothing was installed" \
      'Check it, make it owned by root and not writable by group or others, then run the installer again.'
  fi
fi

# Root's PATH: a folder others can write to lets them run their own code as root.
IFS=: read -r -a path_dirs <<< "$PATH"
unsafe=()
for d in "${path_dirs[@]+"${path_dirs[@]}"}"; do
  if [[ -z "$d" || "$d" != /* ]]; then unsafe+=("'${d:-(empty)}'"); continue; fi
  [[ -d "$d" ]] || continue
  lab_dir_trusted "$d" || unsafe+=("$d")
done
if (( ${#unsafe[@]} > 0 )); then
  warn "root's PATH holds folders that others can change: ${unsafe[*]}"
  printf '%s\n' 'Whoever can write there can run their own code as root. Remove them from the PATH.' >&2
fi

# The commands. LINK_STATE[name] is free, ours or taken; LINK_WHY says why.
declare -A LINK_STATE=() LINK_WHY=()
WANT="$CODE/labyrinth.sh"
for name in laby labyrinth; do
  path="$LINKDIR/$name"
  LINK_STATE[$name]=free LINK_WHY[$name]=''
  if [[ -L "$path" ]]; then
    real="$(readlink -f -- "$path" 2> /dev/null || true)"
    if [[ "$real" == "$WANT" ]]; then
      LINK_STATE[$name]=ours
    else
      LINK_STATE[$name]=taken LINK_WHY[$name]="$path points to ${real:-nothing}"
    fi
  elif [[ -e "$path" ]]; then
    LINK_STATE[$name]=taken LINK_WHY[$name]="$path already exists"
  else
    found="$(type -P -- "$name" 2> /dev/null || true)"
    if [[ -n "$found" && "$(readlink -f -- "$found")" != "$WANT" ]]; then
      LINK_STATE[$name]=taken LINK_WHY[$name]="a command named $name is already at $found"
    fi
  fi
done
if [[ "${LINK_STATE[labyrinth]}" == taken ]]; then
  refuse "the command name labyrinth is taken: ${LINK_WHY[labyrinth]}" \
    'Nothing was installed. Remove or rename that command, then run the installer again.'
fi

# 3. What is already there, and so what the install will do.
CODE_STATE=new
if [[ -e "$CODE" ]]; then
  CODE_STATE=replace
  if (( RELEASE == 0 )); then
    have="$(lab_release_check "$CODE" > /dev/null 2>&1 && printf '%s' "$LAB_RELEASE_HASH" || true)"
    if [[ "$have" == "$REL_HASH" ]]; then CODE_STATE=same; fi
  fi
fi

ROOT_NEW=1
if [[ -d "$ROOT" ]]; then ROOT_NEW=0; fi
SUBS_MISSING=0
for sub in etc state logs backup; do
  if [[ ! -d "$ROOT/$sub" ]]; then SUBS_MISSING=1; fi
done

TEMPLATES=() KEPT=0
shopt -s nullglob
for f in "$HERE"/config/*.example; do
  base="${f##*/}"; base="${base%.example}"
  if [[ -e "$ROOT/etc/$base" || -L "$ROOT/etc/$base" ]]; then KEPT=$((KEPT + 1)); else TEMPLATES+=("$base"); fi
done
shopt -u nullglob

# The manual is installed only when the release holds the built man page, and
# gzip is there to pack it; a plain git checkout has no built manual.
# Another program's man page is never replaced: labyrinth.1.gz must be
# Labyrinth's own (its title line names LABYRINTH), and laby.1.gz must be
# missing or already the link to it. laby.1.gz is also left out when the
# command laby is.
MAN_STATE=skip MAN_WHY='' MAN_LABY=1 MAN_LABY_WHY='' man_top=''
if [[ -f "$MANDIR/labyrinth.1.gz" ]] && command -v gzip > /dev/null 2>&1; then
  man_top="$(gzip -dc -- "$MANDIR/labyrinth.1.gz" 2> /dev/null | head -n 20 || true)"
fi
if [[ ! -f "$HERE/manual/labyrinth.1" ]]; then
  MAN_WHY='this copy has no built manual (manual/labyrinth.1)'
elif ! command -v gzip > /dev/null 2>&1; then
  MAN_WHY='gzip is not on this host'
elif [[ -L "$MANDIR/labyrinth.1.gz" ]] || { [[ -e "$MANDIR/labyrinth.1.gz" ]] \
    && ! grep -qE '^\.TH "?LABYRINTH"? ' <<< "$man_top"; }; then
  MAN_WHY="$MANDIR/labyrinth.1.gz belongs to another program"
else
  MAN_STATE=new
  if [[ "${LINK_STATE[laby]}" == taken ]]; then
    MAN_LABY=0 MAN_LABY_WHY='the command laby is left out'
  elif [[ -e "$MANDIR/laby.1.gz" || -L "$MANDIR/laby.1.gz" ]] \
      && [[ "$(readlink -- "$MANDIR/laby.1.gz" 2> /dev/null || true)" != labyrinth.1.gz ]]; then
    MAN_LABY=0 MAN_LABY_WHY="$MANDIR/laby.1.gz belongs to another program"
  fi
  if [[ -f "$MANDIR/labyrinth.1.gz" ]] \
      && { (( ! MAN_LABY )) || [[ "$(readlink -- "$MANDIR/laby.1.gz" 2> /dev/null || true)" == labyrinth.1.gz ]]; } \
      && gzip -dc -- "$MANDIR/labyrinth.1.gz" 2> /dev/null | cmp -s - "$HERE/manual/labyrinth.1"; then
    MAN_STATE=same
  fi
fi
# The man folder is written to as root, so only root may change it either.
if [[ "$MAN_STATE" == new ]]; then
  if bad="$(lab_path_trusted "$MANDIR")"; then :; else
    refuse "$bad can be changed by an account other than root, so nothing was installed" \
      'Make it owned by root and not writable by group or others, then run the installer again.'
  fi
fi

TODO=0
[[ "$CODE_STATE" == same ]] || TODO=1
(( ROOT_NEW == 0 && SUBS_MISSING == 0 )) || TODO=1
(( ${#TEMPLATES[@]} == 0 )) || TODO=1
[[ "$MAN_STATE" != new ]] || TODO=1
for name in laby labyrinth; do
  [[ "${LINK_STATE[$name]}" != free ]] || TODO=1
done

# 4. The screen, before the question: the release hash to compare by eye
# with the offline record, then what changes on this host.
if [[ "${LINK_STATE[laby]}" == taken ]]; then
  warn "the command laby is left out: ${LINK_WHY[laby]}"
fi
if [[ "$MAN_STATE" == new ]] && (( ! MAN_LABY )); then
  warn "man laby is left out: $MAN_LABY_WHY"
fi
UNI=0
if lab_banner_unicode; then UNI=1; fi
version="$(sed -n "s/^readonly LAB_VERSION='\([^']*\)'.*/\1/p" "$HERE/labyrinth.sh")"
sha=''
if (( RELEASE == 0 )); then sha="$REL_HASH"; fi
lab_banner_print "$UNI" "${version:-unknown}" "$sha"
printf '\n'
rows=()
case "$CODE_STATE" in
  new) rows+=("Program|$CODE (new)") ;;
  replace)
    # The version being replaced, when it differs from this one.
    old="$(sed -n "s/^readonly LAB_VERSION='\([^']*\)'.*/\1/p" "$CODE/labyrinth.sh" 2> /dev/null || true)"
    if [[ -n "$old" && -n "$version" && "$old" != "$version" ]]; then
      rows+=("Program|$CODE (replaced: $old -> $version)")
    else
      rows+=("Program|$CODE (replaced)")
    fi ;;
  same) rows+=("Program|$CODE (unchanged)") ;;
esac
if (( ROOT_NEW )); then rows+=("Data|$ROOT (new, root only)"); else rows+=("Data|$ROOT (kept)"); fi
state=new
if [[ "${LINK_STATE[labyrinth]}" == ours && "${LINK_STATE[laby]}" != free ]]; then state=unchanged; fi
if [[ "${LINK_STATE[laby]}" == taken ]]; then
  rows+=("Commands|labyrinth in $LINKDIR ($state; laby is taken)")
else
  rows+=("Commands|laby, labyrinth in $LINKDIR ($state)")
fi
man_cmd=laby
if (( ! MAN_LABY )); then man_cmd=labyrinth; fi
case "$MAN_STATE" in
  skip) rows+=("Manual|skipped: $MAN_WHY") ;;
  same) rows+=("Manual|man $man_cmd (unchanged)") ;;
  new) rows+=("Manual|man $man_cmd (new)") ;;
esac
n="${#TEMPLATES[@]}"
if (( KEPT > 0 )); then config="$n copied, $KEPT kept"
elif (( n == 1 )); then config='1 template'
else config="$n templates"; fi
rows+=("Config|$config -> $ROOT/etc")
lab_banner_tree "$UNI" "${rows[@]}"

if (( TODO == 0 )); then
  printf '\n'
  lab_banner_list "$UNI" 'ALREADY INSTALLED' 'This release is already in place. Nothing to change.'
  exit 0
fi

# 5. The question. Default no. Without a terminal and without -y, refuse.
printf '\n'
if (( ! YES )); then
  if ! lab_tty_ok; then
    printf '%s: no terminal to ask on, so nothing was installed\n' "$ME" >&2
    printf '%s\n' 'Run it from a terminal, or add -y to answer yes.' >&2
    exit 40
  fi
  lab_tty_write '  Install? [y/N] '
  answer=''
  answer="$(lab_tty_read)" || answer=''
  case "${answer,,}" in
    y | yes) ;;
    *) printf '\n  Nothing was changed.\n'; exit 0 ;;
  esac
fi

# 6. The install.
umask 022

# The data root: root-only inside. A folder that is already there is left as it is.
new_dir 755 "$ROOT"
for sub in etc state logs backup; do
  new_dir 700 "$ROOT/$sub"
done

# The code: built next to its final place, checked, then swapped in whole, so
# no file of the old copy is left to fail the release check.
if [[ "$CODE_STATE" != same ]]; then
  new_dir 755 "$(dirname -- "$CODE")"
  STAGE="$(mktemp -d "$CODE.new.XXXXXX")"
  for f in "${FILES[@]}"; do
    new_dir 755 "$STAGE/$(dirname -- "$f")"
    cp --preserve=mode -- "$HERE/$f" "$STAGE/$f"
  done
  chmod 755 -- "$STAGE"
  chmod -R u+rwX,go+rX,go-w -- "$STAGE"
  # A release unpacked without Unix modes (copied from Windows, say) has lost
  # the execute bit, and the release list does not cover modes: set it on
  # the files that are run by name.
  for f in labyrinth.sh install.sh; do
    if [[ -f "$STAGE/$f" ]]; then chmod 755 -- "$STAGE/$f"; fi
  done
  if (( RELEASE == 0 )); then
    lab_release_check "$STAGE" || refuse "the copy made in $STAGE does not match the release: $LAB_RELEASE_PROBLEM"
  fi
  if [[ -e "$CODE" ]]; then
    OLD="$CODE.old.$$"
    mv -- "$CODE" "$OLD"
  fi
  mv -- "$STAGE" "$CODE"
  STAGE=''
  if [[ -n "$OLD" ]]; then
    # The old copy of Labyrinth's own code, now replaced.
    rm -rf -- "$OLD"
    OLD=''
  fi
fi

# The configuration templates: a file that is already there is never touched.
for base in "${TEMPLATES[@]+"${TEMPLATES[@]}"}"; do
  install -m 600 -- "$HERE/config/$base.example" "$ROOT/etc/$base"
done

# The manual: labyrinth.1.gz, and laby.1.gz pointing to it.
if [[ "$MAN_STATE" == new ]]; then
  new_dir 755 "$MANDIR"
  tmp="$(mktemp "$MANDIR/.labyrinth.1.gz.XXXXXX")"
  TMPS+=("$tmp")
  gzip -9n -c -- "$HERE/manual/labyrinth.1" > "$tmp"
  chmod 644 -- "$tmp"
  mv -f -- "$tmp" "$MANDIR/labyrinth.1.gz"
  if (( MAN_LABY )); then ln -sfn labyrinth.1.gz "$MANDIR/laby.1.gz"; fi
  if command -v mandb > /dev/null 2>&1; then
    mandb -q "$(dirname -- "$MANDIR")" > /dev/null 2>&1 || warn 'mandb failed, so man may not find the manual yet'
  fi
fi

# The commands, last: they appear only once the code they point to is in place.
new_dir 755 "$LINKDIR"
for name in laby labyrinth; do
  if [[ "${LINK_STATE[$name]}" == free ]]; then
    tmp="$LINKDIR/.$name.new.$$"
    TMPS+=("$tmp")
    ln -s -- "$WANT" "$tmp"
    mv -fT -- "$tmp" "$LINKDIR/$name"
  fi
done

# 7. Check the result: only root can change what was installed.
if bad="$(lab_tree_trusted "$CODE")"; then :; else
  refuse "$bad can be changed by an account other than root" \
    'The install is in place, but Labyrinth will refuse to run until that is fixed.'
fi

items=("Fill in $ROOT/etc: hosts and protected-accounts"$'\n''hold placeholder names (manual, section 10)')
cmd=laby
if [[ "${LINK_STATE[laby]}" == taken ]]; then
  items+=('laby is taken here, so the command is labyrinth')
  cmd=labyrinth
fi
if [[ "$ROOT" != "$DEFAULT_ROOT" ]]; then
  items+=("Next: sudo $cmd --root $ROOT")
else
  items+=("Next: sudo $cmd")
fi
# After the question, a blank line; with -y one is already there.
if (( ! YES )); then printf '\n'; fi
lab_banner_list "$UNI" INSTALLED "${items[@]}"
