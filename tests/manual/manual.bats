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
  if grep -Eq 'sudo|labyrinth\.sh|systemd|/opt/labyrinth|--(profile|root|config|break-glass|confirm-group|approve|all|apply)' <<<"$output"; then return 1; fi
  [[ "$output" == *'.\labyrinth.ps1 plan lockout'* ]]
  [[ "$output" == *'C:\ProgramData\Labyrinth'* ]]
}

@test "the Linux manual has nothing from the Windows one" {
  run bash "$SPLIT" linux
  [ "$status" -eq 0 ]
  if grep -Eq 'labyrinth\.ps1|PowerShell|ProgramData|scheduled task|Administrator|(^|[ `])-(Profile|Root|Config|BreakGlass|ConfirmGroup|Approve|All|Apply|Help|Version)' <<<"$output"; then return 1; fi
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
  for o in --profile --root --config --break-glass --confirm-group --approve --all --apply --help --version; do
    [[ "$output" == *"\`$o"* ]] || { echo "linux: $o missing"; return 1; }
  done
  run bash "$SPLIT" windows
  for o in -Profile -Root -Config -BreakGlass -ConfirmGroup -Approve -All -Apply -Help -Version; do
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

@test "paths and commands in running text are in code spans" {
  # A Windows path outside code loses its backslashes when pandoc reads it.
  run awk '
    /^<!--$/ { skip = 1; next }  skip && /^-->$/ { skip = 0; next }  skip { next }
    /^ *```/ { code = !code; next }  code { next }
    { line = $0; gsub(/`[^`]*`/, "", line) }
    line ~ /@(CMD|ROOT)@/ { print FILENAME ":" FNR ": " $0; bad = 1 }
    END { exit bad }' "$REPO/docs/manual/labyrinth.md"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "each manual's options table lists the short flags that edition accepts" {
  local rows
  run bash "$SPLIT" linux
  rows="$(grep -E '^\| `-[-a-zA-Z?]' <<<"$output")"
  for o in -h '-?' -V; do
    [[ "$rows" == *"\`$o\`"* ]] || { echo "linux: $o missing"; return 1; }
  done
  run bash "$SPLIT" windows
  rows="$(grep -E '^\| `-[-a-zA-Z?]' <<<"$output")"
  for o in -h -V; do
    [[ "$rows" == *"\`$o\`"* ]] || { echo "windows: $o missing"; return 1; }
  done
  # PowerShell takes -? for itself, so the Windows manual never offers it.
  [[ "$rows" != *'`-?`'* ]]
}

@test "the manual's sample output shows the runners' version" {
  v="$(sed -n "s/^readonly LAB_VERSION='\(.*\)'$/\1/p" "$REPO/labyrinth.sh")"
  [ -n "$v" ]
  grep -q "^\$LabVersion = '$v'\$" "$REPO/labyrinth.ps1"
  run grep -Eo '^labyrinth [^ :]+:' "$REPO/docs/manual/labyrinth.md"
  [ "${#lines[@]}" -gt 0 ]
  for l in "${lines[@]}"; do [ "$l" = "labyrinth $v:" ] || { echo "sample says $l"; return 1; }; done
}

@test "the README describes the commands that are built" {
  if grep -q 'plan mode only' "$REPO/README.md"; then return 1; fi
  grep -q 'plan, apply, keep, rollback, runs and probe' "$REPO/README.md"
}
