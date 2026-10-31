#!/usr/bin/env bats
# Acceptance tests for the release archives (tools/release/archive.sh, design
# 21, sections 5.2 and 6): the .tar.gz holds release.sha256 and the manual and
# checks; every member is root's and not writable by group or others; one
# unpacked as root with --no-same-owner passes the immutable-location check;
# and the manual's Linux steps compare the archive's hash before they unpack
# it, using only the host's own tools. The Windows half is
# tests/release/Archive.Tests.ps1.
#
# The manual is built by a stand-in, because the real build needs pandoc and
# Chrome (the manual job of CI checks that build).

TAG=v0.0.0-test

setup_file() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  cat > "$BATS_FILE_TMPDIR/build-manual.sh" <<'STUB'
#!/usr/bin/env bash
mkdir -p "$1"
printf '.TH LABYRINTH 1\n' > "$1/labyrinth.1"
printf 'TOPIC\n    about_Labyrinth\n' > "$1/about_Labyrinth.help.txt"
STUB
  export LAB_ARCHIVE_MANUAL_BUILDER="$BATS_FILE_TMPDIR/build-manual.sh"
  OUT="$BATS_FILE_TMPDIR/out"
  bash "$REPO/tools/release/archive.sh" "$TAG" "$OUT" > "$BATS_FILE_TMPDIR/archive.out" 2>&1 \
    || { cat "$BATS_FILE_TMPDIR/archive.out" >&2; return 1; }
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  OUT="$BATS_FILE_TMPDIR/out"
  TGZ="$OUT/labyrinth-$TAG.tar.gz"
}

@test "archive: it prints the sha256sum line of each archive and of the release list" {
  run cat "$BATS_FILE_TMPDIR/archive.out"
  [[ "$output" =~ (^|$'\n')[0-9a-f]{64}\ \ labyrinth-v0\.0\.0-test\.tar\.gz($'\n'|$) ]]
  [[ "$output" =~ (^|$'\n')[0-9a-f]{64}\ \ labyrinth-v0\.0\.0-test\.zip($'\n'|$) ]]
  [[ "$output" =~ (^|$'\n')[0-9a-f]{64}\ \ release\.sha256($'\n'|$) ]]
  [ -f "$OUT/labyrinth-$TAG.zip" ]
  (cd "$OUT" && sha256sum -c --quiet <(grep -E '^[0-9a-f]{64}  labyrinth-' "$BATS_FILE_TMPDIR/archive.out"))
}

@test "archive: the top folder is labyrinth-TAG, in both archives" {
  run tar -tzf "$TGZ"
  [ "$status" -eq 0 ]
  while IFS= read -r m; do
    case "$m" in "labyrinth-$TAG" | "labyrinth-$TAG/"*) ;; *) echo "outside the top folder: $m"; return 1 ;; esac
  done <<< "$output"
  run unzip -Z1 "$OUT/labyrinth-$TAG.zip"
  [ "$status" -eq 0 ]
  while IFS= read -r m; do
    case "$m" in "labyrinth-$TAG/"*) ;; *) echo "outside the top folder: $m"; return 1 ;; esac
  done <<< "$output"
}

@test "archive: it holds release.sha256 and the manual, and the list checks once unpacked" {
  mkdir "$BATS_TEST_TMPDIR/x"
  tar --no-same-owner -xzf "$TGZ" -C "$BATS_TEST_TMPDIR/x"
  cd "$BATS_TEST_TMPDIR/x/labyrinth-$TAG"
  [ -s release.sha256 ]
  [ -s manual/labyrinth.1 ]
  [ -s manual/about_Labyrinth.help.txt ]
  grep -q '  manual/labyrinth\.1$' release.sha256
  grep -q '  labyrinth\.sh$' release.sha256
  sha256sum -c --quiet release.sha256
  # The hash printed for the offline record is the list's own SHA-256.
  [ "$(grep ' release.sha256$' "$BATS_FILE_TMPDIR/archive.out" | cut -d' ' -f1)" = "$(sha256sum < release.sha256 | cut -d' ' -f1)" ]
}

@test "archive: the zip holds the same files as the tar.gz" {
  mkdir "$BATS_TEST_TMPDIR/t" "$BATS_TEST_TMPDIR/z"
  tar --no-same-owner -xzf "$TGZ" -C "$BATS_TEST_TMPDIR/t"
  unzip -q "$OUT/labyrinth-$TAG.zip" -d "$BATS_TEST_TMPDIR/z"
  run diff -r "$BATS_TEST_TMPDIR/t" "$BATS_TEST_TMPDIR/z"
  [ "$status" -eq 0 ]
}

@test "archive: every member is owned by 0/0 and has no group or other write bit" {
  run tar --numeric-owner -tvzf "$TGZ"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  while IFS= read -r l; do
    read -r mode owner _ <<< "$l"
    [ "$owner" = 0/0 ] || { echo "owner $owner: $l"; return 1; }
    [ "${mode:5:1}" != w ] && [ "${mode:8:1}" != w ] || { echo "writable: $l"; return 1; }
  done <<< "$output"
}

@test "archive: the same commit gives the same bytes" {
  bash "$REPO/tools/release/archive.sh" "$TAG" "$BATS_TEST_TMPDIR/again" > /dev/null
  [ "$(sha256sum < "$TGZ")" = "$(sha256sum < "$BATS_TEST_TMPDIR/again/labyrinth-$TAG.tar.gz")" ]
}

@test "archive: a tag that is not a plain name is refused" {
  for bad in '../x' 'a b' 'v1;rm' '' 'a/b'; do
    run bash "$REPO/tools/release/archive.sh" "$bad" "$BATS_TEST_TMPDIR/bad"
    [ "$status" -eq 2 ]
  done
  [ ! -e "$BATS_TEST_TMPDIR/bad" ]
}

@test "archive: a changed archive no longer matches the hash that was printed" {
  cp "$TGZ" "$BATS_TEST_TMPDIR/copy.tar.gz"
  printf 'x' >> "$BATS_TEST_TMPDIR/copy.tar.gz"
  want="$(grep -E "  labyrinth-$TAG\.tar\.gz\$" "$BATS_FILE_TMPDIR/archive.out" | cut -d' ' -f1)"
  [ -n "$want" ]
  [ "$(sha256sum < "$TGZ" | cut -d' ' -f1)" = "$want" ]
  [ "$(sha256sum < "$BATS_TEST_TMPDIR/copy.tar.gz" | cut -d' ' -f1)" != "$want" ]
}

@test "archive: the Linux manual compares the archive's hash before it unpacks, with the host's own tools" {
  run bash "$REPO/tools/manual/split.sh" linux
  [ "$status" -eq 0 ]
  # The steps run from the line that starts them to the text after the
  # installer's command.
  steps="$(awk '/^\*\*Getting it onto a host\./ { on = 1 } /^It checks the release against/ { on = 0 } on' <<< "$output")"
  [ -n "$steps" ]
  # Only the commands inside code blocks.
  cmds="$(awk '/^```/ { c = !c; next } c && NF' <<< "$steps")"
  grep -qx 'url=https://github.com/dotnetdork/Labyrinth/releases/download/$tag' <<< "$cmds"
  fetch="$(grep -n '^curl -fsSLO "\$url/labyrinth-\$tag\.tar\.gz"$' <<< "$cmds" | head -1 | cut -d: -f1)"
  hash="$(grep -n '^sha256sum labyrinth-.*\.tar\.gz$' <<< "$cmds" | head -1 | cut -d: -f1)"
  unpack="$(grep -n '^sudo tar --no-same-owner -xzf ' <<< "$cmds" | head -1 | cut -d: -f1)"
  check="$(grep -n '^sha256sum -c --quiet release\.sha256$' <<< "$cmds" | head -1 | cut -d: -f1)"
  install="$(grep -n '^sudo \./install\.sh$' <<< "$cmds" | head -1 | cut -d: -f1)"
  for n in "$fetch" "$hash" "$unpack" "$check" "$install"; do [ -n "$n" ] || { echo "a step is missing"; echo "$cmds"; return 1; }; done
  { [ "$fetch" -lt "$hash" ] && [ "$hash" -lt "$unpack" ] && [ "$unpack" -lt "$check" ] && [ "$check" -lt "$install" ]; } \
    || { echo "the steps are out of order"; return 1; }
  # Nothing but curl, sha256sum, tar, cd and the installer; never a pipe.
  while IFS= read -r c; do
    case "$c" in
      tag=* | url=* | curl\ * | sha256sum\ * | sudo\ tar\ * | cd\ * | 'sudo ./install.sh') ;;
      *) echo "unexpected command: $c"; return 1 ;;
    esac
    case "$c" in *'|'*) echo "a pipe: $c"; return 1 ;; esac
  done <<< "$cmds"
  if grep -Eq '\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh\b' <<< "$steps"; then return 1; fi
}

@test "realsystem: unpacked as root with --no-same-owner, the folder is trusted and the release check passes" {
  [ "${LAB_REALSYSTEM:-}" = 1 ] || skip 'real-system tests run only on CI runners or lab VMs'
  B="$(sudo -n mktemp -d /var/tmp/lab-arch.XXXXXX)"
  # Files made by root would stop bats from removing its test directory.
  trap 'sudo -n rm -rf -- "$B"' RETURN
  sudo -n chmod 755 "$B"
  sudo -n tar --no-same-owner -xzf "$TGZ" -C "$B"
  run sudo -n env LAB_ROOT="$REPO" LAB_STATE_DIR="$B/state" R="$B/labyrinth-$TAG" bash -c '
    set -Eeuo pipefail
    source "$LAB_ROOT/core/lib.sh"
    lab_tree_trusted "$R"
    source "$LAB_ROOT/core/safety/release.sh"
    lab_release_check "$R"
    printf "%s\n" "$LAB_RELEASE_HASH"'
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  [ "${lines[-1]}" = "$(grep ' release.sha256$' "$BATS_FILE_TMPDIR/archive.out" | cut -d' ' -f1)" ]
}
