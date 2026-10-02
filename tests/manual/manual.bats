#!/usr/bin/env bats
# Tests for the operator manual's single source (docs/manual/labyrinth.md) and
# its splitter (tools/manual/split.sh). Each platform's manual must carry
# every command, option and exit code, and nothing from the other platform.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SPLIT="$REPO/tools/manual/split.sh"
  T="$BATS_TEST_TMPDIR"
}

@test "both manuals split cleanly, with no markers or placeholders left" {
  for p in linux windows; do
    run bash "$SPLIT" "$p"
    [ "$status" -eq 0 ]
    [[ "$output" != *"<!--"* ]]
    if grep -Eq '@(CMD|ROOT|ADMIN|MANUAL)@' <<<"$output"; then return 1; fi
  done
}

@test "the Windows manual has nothing from the Linux one" {
  run bash "$SPLIT" windows
  [ "$status" -eq 0 ]
  if grep -Eq 'sudo|labyrinth\.sh|systemd|/opt/labyrinth|--(profile|root|config|break-glass|confirm-group)' <<<"$output"; then return 1; fi
  [[ "$output" == *'.\labyrinth.ps1 plan lockout'* ]]
  [[ "$output" == *'C:\ProgramData\Labyrinth'* ]]
}

@test "the Linux manual has nothing from the Windows one" {
  run bash "$SPLIT" linux
  [ "$status" -eq 0 ]
  if grep -Eq 'labyrinth\.ps1|PowerShell|ProgramData|scheduled task|Administrator|(^|[ `])-(Profile|Root|Config|BreakGlass|ConfirmGroup|Help|Version)' <<<"$output"; then return 1; fi
  [[ "$output" == *'sudo ./labyrinth.sh plan lockout'* ]]
  [[ "$output" == *'/opt/labyrinth'* ]]
}

@test "both manuals describe every command, exit code and option" {
  for p in linux windows; do
    run bash "$SPLIT" "$p"
    for c in plan apply keep rollback runs probe help version; do
      grep -Eq "^## $c( |\$)" <<<"$output" || { echo "$p: no section for $c"; return 1; }
    done
    for code in 0 10 20 30 40; do
      grep -Eq "^\| $code \|" <<<"$output" || { echo "$p: exit code $code missing"; return 1; }
    done
  done
  run bash "$SPLIT" linux
  for o in --profile --root --config --break-glass --confirm-group --help --version; do
    [[ "$output" == *"\`$o"* ]] || { echo "linux: $o missing"; return 1; }
  done
  run bash "$SPLIT" windows
  for o in -Profile -Root -Config -BreakGlass -ConfirmGroup -Help -Version; do
    [[ "$output" == *"\`$o"* ]] || { echo "windows: $o missing"; return 1; }
  done
}

@test "a block that is never closed is refused" {
  printf 'a\n<!-- linux -->\nb\n' > "$T/src.md"
  run bash "$SPLIT" linux "$T/src.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not closed"* ]]
}

@test "a block inside a block, or an end with no block, is refused" {
  printf '<!-- linux -->\n<!-- windows -->\n<!-- end -->\n' > "$T/nested.md"
  run bash "$SPLIT" linux "$T/nested.md"
  [ "$status" -eq 1 ]
  printf 'a\n<!-- end -->\n' > "$T/stray.md"
  run bash "$SPLIT" windows "$T/stray.md"
  [ "$status" -eq 1 ]
}

@test "a misspelled marker is refused rather than shown to both platforms" {
  printf '<!-- Linux -->\nb\n<!-- end -->\n' > "$T/src.md"
  run bash "$SPLIT" windows "$T/src.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"marker must be exactly"* ]]
}

@test "platform text, author comments and placeholders are handled" {
  printf '%s\n' '<!--' 'for authors' '-->' 'both @ADMIN@' '<!-- linux -->' 'only linux' '<!-- end -->' \
    '<!-- windows -->' 'only windows @ROOT@' '<!-- end -->' > "$T/src.md"
  run bash "$SPLIT" windows "$T/src.md"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' 'both an Administrator' 'only windows C:\ProgramData\Labyrinth')" ]
  run bash "$SPLIT" linux "$T/src.md"
  [ "$output" = "$(printf '%s\n' 'both root' 'only linux')" ]
}

@test "an unknown platform is a usage error" {
  run bash "$SPLIT" macos
  [ "$status" -eq 2 ]
}
