#!/usr/bin/env bats
# Unit tests for the release check (core/safety/release.sh, design 07,
# section 5.1).

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # shellcheck source=/dev/null
  source "$REPO/core/safety/release.sh"
  R="$BATS_TEST_TMPDIR/rel"
  mkdir -p "$R/core/safety" "$R/phases/observe/modules/a" "$R/profiles" "$R/docs"
  printf 'runner\n' > "$R/labyrinth.sh"
  printf 'lib\n' > "$R/core/lib.sh"
  printf 'id: observe.a\n' > "$R/phases/observe/modules/a/module.yml"
  printf 'observe.a\n' > "$R/profiles/x.profile"
  printf 'not covered\n' > "$R/docs/notes.md"
}

# check: run lab_release_check on the test folder, keeping its globals.
check() {
  RC=0
  lab_release_check "$R" || RC=$?
}

@test "release: the written list checks, and its hash is the list's SHA-256" {
  local sum
  sum="$(lab_release_write "$R")"
  [[ "$sum" =~ ^[0-9a-f]{64}$ ]]
  [ "$sum" = "$(sha256sum < "$R/release.sha256" | cut -d' ' -f1)" ]
  check
  [ "$RC" -eq 0 ]
  [ "$LAB_RELEASE_HASH" = "$sum" ]
  # Paths are relative, sorted, in the format sha256sum -c reads.
  grep -q '^[0-9a-f]\{64\}  core/lib.sh$' "$R/release.sha256"
  if grep -q 'docs/' "$R/release.sha256"; then return 1; fi
  (cd "$R" && sha256sum -c --quiet release.sha256)
}

@test "release: no list is reported as missing, not as a problem" {
  check
  [ "$RC" -eq 1 ]
  [ -z "$LAB_RELEASE_HASH" ]
  [ -z "$LAB_RELEASE_PROBLEM" ]
}

@test "release: a changed core file is refused, naming the file" {
  lab_release_write "$R" > /dev/null
  printf 'lib\nextra line\n' > "$R/core/lib.sh"
  check
  [ "$RC" -eq 2 ]
  [ "$LAB_RELEASE_PROBLEM" = 'core/lib.sh differs from the release' ]
}

@test "release: a file planted under a covered folder is refused" {
  lab_release_write "$R" > /dev/null
  printf 'x\n' > "$R/phases/observe/modules/a/apply.sh"
  check
  [ "$RC" -eq 2 ]
  [ "$LAB_RELEASE_PROBLEM" = 'phases/observe/modules/a/apply.sh is not in the release' ]
}

@test "release: a file outside the covered folders is not checked" {
  lab_release_write "$R" > /dev/null
  printf 'changed\n' > "$R/docs/notes.md"
  printf 'x\n' > "$R/NOT_ADMIN"
  check
  [ "$RC" -eq 0 ]
}

@test "release: a listed file that is missing or a link is refused" {
  lab_release_write "$R" > /dev/null
  mv "$R/profiles/x.profile" "$BATS_TEST_TMPDIR/x.profile"
  check
  [ "$RC" -eq 2 ]
  [ "$LAB_RELEASE_PROBLEM" = 'profiles/x.profile is missing, or is not a plain file' ]
  ln -s "$BATS_TEST_TMPDIR/x.profile" "$R/profiles/x.profile"
  check
  [ "$RC" -eq 2 ]
  [ "$LAB_RELEASE_PROBLEM" = 'profiles/x.profile is missing, or is not a plain file' ]
}

@test "release: a malformed, empty or escaping list is refused" {
  local h
  h="$(printf '%064d' 0)"
  printf 'not a line\n' > "$R/release.sha256"
  check
  [ "$RC" -eq 2 ]
  [ "$LAB_RELEASE_PROBLEM" = "line 1 of release.sha256 is not '<sha256>  <path>'" ]
  : > "$R/release.sha256"
  check
  [ "$RC" -eq 2 ]
  [ "$LAB_RELEASE_PROBLEM" = 'release.sha256 lists no files' ]
  for path in ../etc/passwd core/../../x core//lib.sh ./core/lib.sh /etc/passwd; do
    printf '%s  %s\n' "$h" "$path" > "$R/release.sha256"
    check
    [ "$RC" -eq 2 ]
    [[ "$LAB_RELEASE_PROBLEM" == "line 1 of release.sha256 names a path outside"* ]] || { echo "$path: $LAB_RELEASE_PROBLEM"; return 1; }
  done
}

@test "release: a path listed twice, or a list with Windows line ends, is refused" {
  lab_release_write "$R" > /dev/null
  head -n 1 "$R/release.sha256" >> "$R/release.sha256"
  check
  [ "$RC" -eq 2 ]
  [[ "$LAB_RELEASE_PROBLEM" == 'release.sha256 lists '*' twice' ]]
  lab_release_write "$R" > /dev/null
  sed -i 's/$/\r/' "$R/release.sha256"
  check
  [ "$RC" -eq 2 ]
  [ "$LAB_RELEASE_PROBLEM" = "line 1 of release.sha256 is not '<sha256>  <path>'" ]
}

@test "release: the list itself may not be a link" {
  lab_release_write "$R" > /dev/null
  mv "$R/release.sha256" "$BATS_TEST_TMPDIR/list"
  ln -s "$BATS_TEST_TMPDIR/list" "$R/release.sha256"
  check
  [ "$RC" -eq 2 ]
  [ "$LAB_RELEASE_PROBLEM" = 'release.sha256 is not a plain file' ]
}

@test "release: the tool writes the list and prints the hash to record" {
  run bash "$REPO/tools/release/manifest.sh" "$R"
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "Release: $(sha256sum < "$R/release.sha256" | cut -d' ' -f1)" ]
  check
  [ "$RC" -eq 0 ]
}

@test "release: the repository's own files fit the list's path rules" {
  local bad
  bad="$(lab_release_files "$REPO" | grep -v '^[A-Za-z0-9._/-]*$' || true)"
  [ -z "$bad" ] || { echo "$bad"; return 1; }
}
