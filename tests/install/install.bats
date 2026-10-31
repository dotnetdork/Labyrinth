#!/usr/bin/env bats
# Tests for install.sh, the guided installer (docs/Conventions.md section 3.3),
# and for the runner started through the installed link.
#
# Each test builds a throwaway release folder and a throwaway "system" (data
# root, link folder, man folder) under the test directory, and points the
# installer at them with its test-only options, so nothing outside the test
# directory is read or changed. The release tree's core gets the test doubles
# of tests/fixtures/doubles.sh appended (the root check, the ownership checks
# and the terminal), as the runner tests do.

load ../runner/lab_helper

setup() {
  :
}

# inst_setup: a release folder (REL) with a valid release.sha256, and an empty
# throwaway system (SYS: ROOT, LINKS, MAN).
inst_setup() {
  REPO="$BATS_TEST_DIRNAME/../.."
  T="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  REL="$T/release"
  SYS="$T/sys"
  ROOT="$SYS/opt/labyrinth"
  LINKS="$SYS/usr/bin"
  MAN="$SYS/usr/local/share/man/man1"
  unset SUDO_USER
  mkdir -p "$REL" "$SYS"
  cp "$REPO/labyrinth.sh" "$REPO/install.sh" "$REL/"
  cp -R "$REPO/core" "$REPO/config" "$REL/"
  cat "$REPO/tests/fixtures/doubles.sh" >> "$REL/core/lib.sh"
  mkdir -p "$REL/manual"
  printf '.TH LABYRINTH 1\nthe manual\n' > "$REL/manual/labyrinth.1"
  printf 'TOPIC\n    about_Labyrinth\n' > "$REL/manual/about_Labyrinth.help.txt"
  seal
}

# seal: write the release list for the release folder as it is now.
seal() { bash "$REPO/tools/release/manifest.sh" "$REL" > /dev/null; }

# install_sh [OPTION...]: run the installer from the release folder.
install_sh() {
  run bash "$REL/install.sh" --root "$ROOT" --link-dir "$LINKS" --man-dir "$MAN" "$@"
}

# answer LINE...: what is typed at the "Install?" question, in order.
answer() { printf '%s\n' "$@" > "$REL/tty.in"; }

# snapshot: every path in the throwaway system with its type, mode and link
# target, then every file's SHA-256: equal before and after means unchanged.
snapshot() {
  (
    cd "$SYS"
    find . -printf '%p %y %m %l\n' | LC_ALL=C sort
    find . -type f -exec sha256sum {} + | LC_ALL=C sort
  )
}

@test "the plan is printed before the question, and answering no changes nothing" {
  inst_setup
  answer n
  install_sh
  [ "$status" -eq 0 ]
  [[ "$output" == *'CHANGES TO THIS HOST'* ]]
  flat="$(tr -s " " <<< "$output")"
  [[ "$flat" == *"Program $ROOT/bin (new)"* ]]
  [[ "$flat" == *"Data $ROOT (new, root only)"* ]]
  [[ "$flat" == *"Commands laby, labyrinth in $LINKS (new)"* ]]
  [[ "$flat" == *"Manual man laby (new)"* ]]
  [[ "$flat" == *"Config 8 templates "*" $ROOT/etc"* ]]
  [[ "$output" == *'Nothing was changed.'* ]]
  grep -q 'Install? \[y/N\]' "$REL/tty.out"
  [ -z "$(ls -A "$SYS")" ]
}

# screen: the installer's screen from the maze's first line to the tree's
# heading, one line per item of SCREEN.
screen() { mapfile -t SCREEN < <(sed -n '/^\(╔ IN\|+ IN\)/,/^  CHANGES TO THIS HOST$/p' <<< "$output"); }

# about: the lines under the version, what Labyrinth is and the notice,
# centred on the maze's 55 columns.
about() {
  [ "${SCREEN[8]}" = '' ]
  [ "${SCREEN[9]}" = ' Rapid first-minute hardening tool for Linux & Windows,' ]
  [ "${SCREEN[10]}" = ' with traps that log every attacker move as a tripwire.' ]
  [ "${SCREEN[11]}" = '' ]
  [ "${SCREEN[12]}" = '       Copyright (c) 2026 Jay Sausa. See LICENSE.' ]
  [ "${SCREEN[13]}" = '' ]
}

@test "on a UTF-8 terminal the screen shows the maze, the version and the hash in a box" {
  inst_setup
  answer n
  LC_ALL=C.UTF-8 install_sh
  [ "$status" -eq 0 ]
  local LC_ALL=C.UTF-8 sum ver i l joined=''
  sum="$(sha256sum < "$REL/release.sha256" | cut -d' ' -f1)"
  ver="$(sed -n "s/^readonly LAB_VERSION='\([^']*\)'.*/\1/p" "$REPO/labyrinth.sh")"
  screen
  # The maze as drawn, then the version and the site, what Labyrinth is and
  # the notice.
  mapfile -t maze < "$REPO/core/banner/maze.txt"
  [ "${#maze[@]}" -eq 7 ]
  for i in "${!maze[@]}"; do [ "${SCREEN[i]}" = "${maze[i]}" ]; done
  [ "${SCREEN[7]}" = "VERSION $ver (https://dotnetdork.github.io/Labyrinth/)" ]
  about
  # The box: 51 wide, indented 2 under the maze, the warning over a rule.
  for ((i = 14; i < 20; i++)); do [ "${#SCREEN[i]}" -eq 53 ]; done
  [ "${SCREEN[14]}" = "  ╓$(printf '%49s' '' | sed 's/ /─/g')╖" ]
  [ "${SCREEN[15]}" = '  ║    WARNING: COMPARE WITH YOUR OFFLINE SHA-256   ║' ]
  [ "${SCREEN[16]}" = "  ╟$(printf '%49s' '' | sed 's/ /─/g')╢" ]
  # The hash: two lines of eight groups of four that join into the SHA-256.
  for i in 17 18; do
    [[ "${SCREEN[i]}" =~ ^'  ║     '([0-9a-f]{4}( [0-9a-f]{4}){7})'     ║'$ ]]
    joined+="${BASH_REMATCH[1]}"
  done
  [ "${joined// /}" = "$sum" ]
  [ "${SCREEN[19]}" = "  ╙$(printf '%49s' '' | sed 's/ /─/g')╜" ]
  [ "${SCREEN[21]}" = '  CHANGES TO THIS HOST' ]
  # No line of the art is wider than 79 columns.
  for l in "${SCREEN[@]}"; do [ "${#l}" -le 79 ]; done
  # The tree, with the arrow.
  [[ "$output" == *"   ├── Program   $ROOT/bin (new)"* ]]
  [[ "$output" == *"   └── Config    8 templates → $ROOT/etc"* ]]
}

@test "without UTF-8 the same screen is drawn in plain ASCII" {
  inst_setup
  answer n
  LC_ALL=C LANG= install_sh
  [ "$status" -eq 0 ]
  screen
  mapfile -t maze < "$REPO/core/banner/maze-ascii.txt"
  for i in "${!maze[@]}"; do [ "${SCREEN[i]}" = "${maze[i]}" ]; done
  about
  [ "${SCREEN[14]}" = "  +$(printf '%49s' '' | tr ' ' -)+" ]
  [ "${SCREEN[15]}" = '  |    WARNING: COMPARE WITH YOUR OFFLINE SHA-256   |' ]
  [ "${SCREEN[16]}" = "  +$(printf '%49s' '' | tr ' ' -)+" ]
  [[ "${SCREEN[17]}" =~ ^'  |     '[0-9a-f]{4}( [0-9a-f]{4}){7}'     |'$ ]]
  [[ "$output" == *"   |-- Program   $ROOT/bin (new)"* ]]
  [[ "$output" == *'   `-- Config    8 templates -> '"$ROOT/etc"* ]]
  if LC_ALL=C grep -q '[^ -~]' <<< "$output"; then return 1; fi
}

@test "the two mazes have the same shape" {
  local LC_ALL=C.UTF-8 i
  inst_setup
  mapfile -t u < "$REPO/core/banner/maze.txt"
  mapfile -t a < "$REPO/core/banner/maze-ascii.txt"
  [ "${#u[@]}" -eq "${#a[@]}" ]
  for i in "${!u[@]}"; do
    [ "${#u[i]}" -eq "${#a[i]}" ]
    [ "${#u[i]}" -eq 55 ]
  done
  [[ "${a[0]}" == '+ IN -'* ]]
  [[ "${a[-1]}" == *'+ OUT +' ]]
}

@test "no answer at all changes nothing either" {
  inst_setup
  : > "$REL/tty.in"
  install_sh
  [ "$status" -eq 0 ]
  [[ "$output" == *'Nothing was changed.'* ]]
  [ -z "$(ls -A "$SYS")" ]
}

@test "any answer but yes is a no" {
  inst_setup
  answer maybe
  install_sh
  [[ "$output" == *'Nothing was changed.'* ]]
  [ -z "$(ls -A "$SYS")" ]
}

@test "without a terminal and without -y, it prints the plan and refuses" {
  inst_setup
  : > "$REL/NO_TTY"
  install_sh
  [ "$status" -eq 40 ]
  [[ "$output" == *'CHANGES TO THIS HOST'* ]]
  [[ "$output" == *'no terminal to ask on'* ]]
  [[ "$output" == *'add -y'* ]]
  [ -z "$(ls -A "$SYS")" ]
}

@test "yes installs the code, the data root, the commands, the manual and the templates" {
  inst_setup
  answer y
  install_sh
  [ "$status" -eq 0 ]
  [[ "$output" == *'  INSTALLED'* ]]
  [[ "$output" == *"Fill in $ROOT/etc: hosts and protected-accounts"* ]]
  [[ "$output" == *'Next: sudo laby'* ]]
  # The code, checked against its own release list as the runner will check it.
  [ -f "$ROOT/bin/labyrinth.sh" ]
  [ -f "$ROOT/bin/release.sha256" ]
  [ -f "$ROOT/bin/install.sh" ]
  [ -f "$ROOT/bin/manual/labyrinth.1" ]
  # shellcheck source=/dev/null
  source "$REPO/core/safety/release.sh"
  lab_release_check "$ROOT/bin"
  [ -z "$(find "$ROOT/bin" -perm /022)" ]
  # The data root and its private folders.
  for d in etc state logs backup; do
    [ "$(stat -c %a "$ROOT/$d")" = 700 ]
  done
  # The commands point at the code, not at the release folder.
  [ "$(readlink "$LINKS/laby")" = "$ROOT/bin/labyrinth.sh" ]
  [ "$(readlink "$LINKS/labyrinth")" = "$ROOT/bin/labyrinth.sh" ]
  # The manual, and the second name pointing to it.
  [ "$(gzip -dc "$MAN/labyrinth.1.gz")" = "$(cat "$REL/manual/labyrinth.1")" ]
  [ "$(readlink "$MAN/laby.1.gz")" = labyrinth.1.gz ]
  # The templates, without the .example ending.
  [ -f "$ROOT/etc/hosts" ]
  [ -f "$ROOT/etc/protected-accounts" ]
  [ ! -e "$ROOT/etc/hosts.example" ]
  cmp "$ROOT/etc/hosts" "$REL/config/hosts.example"
}

@test "-y answers the question for the installer" {
  inst_setup
  : > "$REL/NO_TTY"
  install_sh -y
  [ "$status" -eq 0 ]
  [ -f "$ROOT/bin/labyrinth.sh" ]
  [ -L "$LINKS/laby" ]
}

@test "a second run changes nothing" {
  inst_setup
  install_sh -y
  [ "$status" -eq 0 ]
  before="$(snapshot)"
  install_sh -y
  [ "$status" -eq 0 ]
  [[ "$output" == *'Nothing to change.'* ]]
  [ "$(snapshot)" = "$before" ]
}

@test "installing a new version names the version it replaces" {
  inst_setup
  install_sh -y
  [ "$status" -eq 0 ]
  local old
  old="$(sed -n "s/^readonly LAB_VERSION='\([^']*\)'.*/\1/p" "$REPO/labyrinth.sh")"
  sed -i "s/^readonly LAB_VERSION='[^']*'/readonly LAB_VERSION='9.9.9'/" "$REL/labyrinth.sh"
  seal
  install_sh -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"Program   $ROOT/bin (replaced: $old "*" 9.9.9)"* ]]
  grep -q "^readonly LAB_VERSION='9.9.9'" "$ROOT/bin/labyrinth.sh"
}

@test "configuration files that are already there are kept" {
  inst_setup
  mkdir -p "$ROOT/etc"
  printf 'my own hosts\n' > "$ROOT/etc/hosts"
  install_sh -y
  [ "$status" -eq 0 ]
  [ "$(cat "$ROOT/etc/hosts")" = 'my own hosts' ]
  [ -f "$ROOT/etc/protected-accounts" ]
  [[ "$output" == *'copied, 1 kept'* ]]
}

@test "a reinstall replaces the code completely and never touches state or configuration" {
  inst_setup
  install_sh -y
  printf 'mine\n' > "$ROOT/etc/hosts"
  mkdir -p "$ROOT/state/runs/20261002T140301Z-4f2a"
  printf 'record\n' > "$ROOT/state/runs/20261002T140301Z-4f2a/manifest.jsonl"
  printf 'log\n' > "$ROOT/logs/run.txt"
  # A stray file in the installed code would fail the runner's release check.
  printf 'planted\n' > "$ROOT/bin/core/stray.sh"
  install_sh -y
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT/bin/core/stray.sh" ]
  # shellcheck source=/dev/null
  source "$REPO/core/safety/release.sh"
  lab_release_check "$ROOT/bin"
  [ "$(cat "$ROOT/etc/hosts")" = mine ]
  [ "$(cat "$ROOT/state/runs/20261002T140301Z-4f2a/manifest.jsonl")" = record ]
  [ "$(cat "$ROOT/logs/run.txt")" = log ]
  # Nothing is left beside the code folder.
  [ "$(ls -A "$ROOT" | sort | tr '\n' ' ')" = 'backup bin etc logs state ' ]
}

@test "a laby that something else owns is left out, with a message" {
  inst_setup
  mkdir -p "$LINKS"
  printf 'not ours\n' > "$LINKS/laby"
  install_sh -y
  [ "$status" -eq 0 ]
  [[ "$output" == *'the command laby is left out:'* ]]
  [[ "$(tr -s " " <<< "$output")" == *"Commands labyrinth in $LINKS (new; laby is taken)"* ]]
  [[ "$output" == *"$LINKS/laby already exists"* ]]
  [[ "$output" == *'Next: sudo labyrinth'* ]]
  [ "$(cat "$LINKS/laby")" = 'not ours' ]
  [ ! -L "$LINKS/laby" ]
  [ "$(readlink "$LINKS/labyrinth")" = "$ROOT/bin/labyrinth.sh" ]
  # Its man page name is left out too, so man laby never shows Labyrinth.
  [[ "$output" == *'man laby is left out: the command laby is left out'* ]]
  [ -f "$MAN/labyrinth.1.gz" ]
  [ ! -e "$MAN/laby.1.gz" ]
}

@test "another program's laby man page is never replaced" {
  inst_setup
  mkdir -p "$MAN"
  printf 'not ours
' > "$MAN/laby.1.gz"
  install_sh -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"man laby is left out: $MAN/laby.1.gz belongs to another program"* ]]
  [ "$(cat "$MAN/laby.1.gz")" = 'not ours' ]
  [ -f "$MAN/labyrinth.1.gz" ]
}

@test "another program's labyrinth man page is never replaced, and the manual is skipped" {
  inst_setup
  mkdir -p "$MAN"
  printf '.TH OTHER 1
something else
' | gzip -c > "$MAN/labyrinth.1.gz"
  before="$(sha256sum "$MAN/labyrinth.1.gz")"
  install_sh -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped: $MAN/labyrinth.1.gz belongs to another program"* ]]
  [ "$(sha256sum "$MAN/labyrinth.1.gz")" = "$before" ]
  [ ! -e "$MAN/laby.1.gz" ]
  [ -f "$ROOT/bin/labyrinth.sh" ]
}

@test "a laby found elsewhere on the PATH counts as taken" {
  inst_setup
  mkdir -p "$T/other"
  printf '#!/bin/sh\n' > "$T/other/laby"
  chmod +x "$T/other/laby"
  PATH="$T/other:$PATH"
  install_sh -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"a command named laby is already at $T/other/laby"* ]]
  [ ! -e "$LINKS/laby" ]
  [ -L "$LINKS/labyrinth" ]
}

@test "a labyrinth that something else owns is refused, and nothing is installed" {
  inst_setup
  mkdir -p "$LINKS"
  printf 'not ours\n' > "$LINKS/labyrinth"
  install_sh -y
  [ "$status" -eq 20 ]
  [[ "$output" == *'the command name labyrinth is taken'* ]]
  [ ! -e "$ROOT" ]
  [ ! -e "$LINKS/laby" ]
  [ "$(cat "$LINKS/labyrinth")" = 'not ours' ]
}

@test "a release that differs from release.sha256 is refused" {
  inst_setup
  printf '# changed\n' >> "$REL/core/config/config.sh"
  install_sh -y
  [ "$status" -eq 20 ]
  [[ "$output" == *'core/config/config.sh differs from the release'* ]]
  [ -z "$(ls -A "$SYS")" ]
}

@test "a file the release list does not name is refused" {
  inst_setup
  printf 'extra\n' > "$REL/core/extra.sh"
  install_sh -y
  [ "$status" -eq 20 ]
  [[ "$output" == *'core/extra.sh is not in the release'* ]]
  [ -z "$(ls -A "$SYS")" ]
}

@test "a copy with no release list installs with a note that it was not checked" {
  inst_setup
  rm "$REL/release.sha256"
  LC_ALL=C install_sh -y
  [ "$status" -eq 0 ]
  [[ "$output" == *'  | WARNING: THIS COPY HAS NO release.sha256, ABORT |'* ]]
  [[ "$output" == *'  |     ???? ???? ???? ???? ???? ???? ???? ????     |'* ]]
  [ -f "$ROOT/bin/labyrinth.sh" ]
  [ ! -e "$ROOT/bin/release.sha256" ]
}

@test "a copy with no built manual skips the manual in one line and still installs" {
  inst_setup
  rm -r "$REL/manual"
  seal
  install_sh -y
  [ "$status" -eq 0 ]
  [[ "$(tr -s " " <<< "$output")" == *"Manual skipped: this copy has no built manual"* ]]
  [ -f "$ROOT/bin/labyrinth.sh" ]
  [ ! -e "$MAN" ]
}

@test "an armed revert timer is refused, naming the run and when it fires" {
  inst_setup
  mkdir -p "$ROOT/bin" "$ROOT/state/runs/20261002T140301Z-4f2a"
  printf 'old code\n' > "$ROOT/bin/labyrinth.sh"
  printf 'lab-revert-20261002T140301Z-4f2a-1\n' > "$ROOT/state/runs/20261002T140301Z-4f2a/timer"
  printf '2026-10-02T14:08:01Z\n' > "$ROOT/state/runs/20261002T140301Z-4f2a/timer-due"
  before="$(snapshot)"
  install_sh -y
  [ "$status" -eq 20 ]
  [[ "$output" == *'run 20261002T140301Z-4f2a'* ]]
  [[ "$output" == *'fires at 2026-10-02T14:08:01Z'* ]]
  [[ "$output" == *'laby -k ID'* ]]
  [[ "$output" == *'laby -u ID'* ]]
  [ "$(snapshot)" = "$before" ]
}

@test "a run with no timer armed does not stop the install" {
  inst_setup
  mkdir -p "$ROOT/state/runs/20261002T140301Z-4f2a"
  printf 'record\n' > "$ROOT/state/runs/20261002T140301Z-4f2a/manifest.jsonl"
  install_sh -y
  [ "$status" -eq 0 ]
}

@test "a folder that others can write to, above the install, is refused" {
  inst_setup
  : > "$REL/UNTRUSTED"
  install_sh -y
  [ "$status" -eq 20 ]
  [[ "$output" == *'can be changed by an account other than root'* ]]
  [ -z "$(ls -A "$SYS")" ]
}

@test "the real folder check: a folder owned by root and closed to others passes, one that is not fails" {
  REPO="$BATS_TEST_DIRNAME/../.."
  # shellcheck source=/dev/null
  source "$REPO/core/safety/system.sh"
  # /usr/bin is root's and closed to others on any Linux host; the folder it
  # would be made in is checked from its nearest existing folder.
  lab_path_trusted /usr/bin
  lab_path_trusted /usr/bin/not-made-yet/deeper
  [ "$(id -u)" -ne 0 ] || skip 'root owns everything it makes'
  T="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  run lab_path_trusted "$T/mine"
  [ "$status" -eq 1 ]
  [ -n "$output" ]
}

@test "an existing data root with something in it that others can change is refused" {
  inst_setup
  mkdir -p "$ROOT/etc"
  : > "$REL/UNTRUSTED_TREE"
  install_sh -y
  [ "$status" -eq 20 ]
  [[ "$output" == *'can be changed by an account other than root, so nothing was installed'* ]]
  [ ! -e "$ROOT/bin" ]
  [ ! -e "$LINKS/laby" ]
}

@test "a code folder that is a link is refused, and what it points to is untouched" {
  inst_setup
  mkdir -p "$ROOT" "$T/elsewhere"
  printf 'keep
' > "$T/elsewhere/labyrinth.sh"
  ln -s "$T/elsewhere" "$ROOT/bin"
  install_sh -y
  [ "$status" -eq 20 ]
  [[ "$output" == *"$ROOT/bin is a link, not a folder"* ]]
  [ "$(cat "$T/elsewhere/labyrinth.sh")" = keep ]
}

@test "the runner and the installer are made executable even when the release lost its modes" {
  inst_setup
  chmod 644 "$REL/labyrinth.sh" "$REL/install.sh"
  install_sh -y
  [ "$status" -eq 0 ]
  [ -x "$ROOT/bin/labyrinth.sh" ]
  [ -x "$ROOT/bin/install.sh" ]
}

@test "without root it refuses" {
  inst_setup
  : > "$REL/NOT_ADMIN"
  install_sh -y
  [ "$status" -eq 20 ]
  [[ "$output" == *'must run as root'* ]]
  [ -z "$(ls -A "$SYS")" ]
}

@test "a code folder that is not Labyrinth's and not empty is not replaced" {
  inst_setup
  mkdir -p "$ROOT/bin"
  printf 'someone else\n' > "$ROOT/bin/notes.txt"
  install_sh -y
  [ "$status" -eq 20 ]
  [[ "$output" == *'is not a Labyrinth folder'* ]]
  [ "$(cat "$ROOT/bin/notes.txt")" = 'someone else' ]
}

@test "the installed copy refuses to install over itself" {
  inst_setup
  install_sh -y
  [ "$status" -eq 0 ]
  run bash "$ROOT/bin/install.sh" --root "$ROOT" --link-dir "$LINKS" --man-dir "$MAN" -y
  [ "$status" -eq 20 ]
  [[ "$output" == *'installed copy'* ]]
}

@test "a root other than the default is named in the Next line" {
  inst_setup
  install_sh -y
  [[ "$output" == *"Next: sudo laby --root $ROOT"* ]]
}

@test "usage errors exit 40 and name the fix" {
  inst_setup
  run bash "$REL/install.sh" --bogus
  [ "$status" -eq 40 ]
  [[ "$output" == *"install.sh: unknown option '--bogus'"* ]]
  [[ "$output" == *"Try 'install.sh -h'."* ]]
  run bash "$REL/install.sh" --root relative/dir
  [ "$status" -eq 40 ]
  run bash "$REL/install.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *'Usage: sudo ./install.sh'* ]]
}

# ---- The runner started through the installed link ----

@test "started through the link on the PATH, the runner names itself laby" {
  lab_setup
  links="$BATS_TEST_TMPDIR/links"
  mkdir -p "$links"
  ln -s "$LAB/labyrinth.sh" "$links/laby"
  ln -s "$LAB/labyrinth.sh" "$links/labyrinth"
  # It finds its core through the link, so it must resolve it to the real folder.
  run env PATH="$links:$PATH" laby -h
  [ "$status" -eq 0 ]
  [[ "$output" == *'Usage: laby PHASE'* ]]
  run env PATH="$links:$PATH" labyrinth -h
  [[ "$output" == *'Usage: labyrinth PHASE'* ]]
  run env PATH="$links:$PATH" laby --nonsense
  [ "$status" -eq 40 ]
  [[ "$output" == *"laby: unknown option '--nonsense'"* ]]
  [[ "$output" == *"Try 'laby -h'."* ]]
}

@test "started through the link by its full path and not on the PATH, it shows the path" {
  lab_setup
  links="$BATS_TEST_TMPDIR/links"
  mkdir -p "$links"
  ln -s "$LAB/labyrinth.sh" "$links/laby"
  run "$links/laby" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: $links/laby PHASE"* ]]
}

@test "a different command named laby on the PATH does not make the runner call itself laby" {
  lab_setup
  links="$BATS_TEST_TMPDIR/links"
  elsewhere="$BATS_TEST_TMPDIR/elsewhere"
  mkdir -p "$links" "$elsewhere"
  ln -s "$LAB/labyrinth.sh" "$links/laby"
  printf '#!/bin/sh\n' > "$elsewhere/laby"
  chmod +x "$elsewhere/laby"
  run env PATH="$elsewhere:$links:$PATH" "$links/laby" -h
  [[ "$output" == *"Usage: $links/laby PHASE"* ]]
}

@test "the revert timer's command names the installed code, not the link" {
  lab_setup
  hosts ring1
  profile observe.toggle
  answers root ring1 no
  links="$BATS_TEST_TMPDIR/links"
  mkdir -p "$links"
  ln -s "$LAB/labyrinth.sh" "$links/laby"
  real="$(cd "$LAB" && pwd -P)"
  run env PATH="$links:$PATH" laby --root "$ROOT" --config "$ETC" -r observe < "$ANSWERS"
  [ "$status" -eq 0 ]
  # What the operator is told to type names the command, as typed.
  [[ "$output" == *"To keep later: laby -k "* ]]
  # What the timer runs as root names the installed code, not the link.
  timer_cmd="$(cat "$ROOT/state/runs/$(run_id)/timer")"
  [[ "$timer_cmd" == *"$real/labyrinth.sh --root $ROOT --config $ETC -u $(run_id)"* ]]
  [[ "$timer_cmd" != *"$links"* ]]
}
