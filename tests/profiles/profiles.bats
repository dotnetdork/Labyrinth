#!/usr/bin/env bats
# The shipped profiles (Conventions, section 2.3; Blueprint, section 6.3).
# A profile lists only modules the release ships, each one able to run on
# the profile's platform, and the appliance profile only manual-only ones.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

# yml_value FILE KEY: the value of a top-level key in a module.yml.
yml_value() {
  sed -n "s/^$2:[[:space:]]*//p" "$1" | head -n 1 | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//'
}

# profile_problems ROOT: one line per problem in ROOT/profiles/*.profile.
profile_problems() {
  local root="$1" f name n raw line dir yml plats seen
  for f in "$root"/profiles/*.profile; do
    [[ -e "$f" ]] || continue
    name="${f##*/}"; name="${name%.profile}"; n=0; seen=' '
    while IFS= read -r raw || [[ -n "$raw" ]]; do
      n=$((n + 1))
      line="${raw%%#*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
      if [[ -z "$line" ]]; then continue; fi
      if [[ ! "$line" =~ ^(lockout|observe|deceive|sustain)\.[a-z0-9_-]+$ ]]; then
        echo "$name:$n: not a module id: $line"; continue
      fi
      if [[ "$seen" == *" $line "* ]]; then echo "$name:$n: listed twice: $line"; continue; fi
      seen+="$line "
      dir="$root/phases/${line%%.*}/modules/${line#*.}"; yml="$dir/module.yml"
      if [[ ! -f "$yml" ]]; then echo "$name:$n: no such module: $line"; continue; fi
      if [[ "$(yml_value "$yml" id)" != "$line" ]]; then echo "$name:$n: its module.yml has another id: $line"; fi
      plats="$(yml_value "$yml" platforms)"
      case "$name" in
        windows-*)
          if [[ "$plats" != *windows* ]] || ! compgen -G "$dir/*.ps1" > /dev/null; then
            echo "$name:$n: does not run on Windows: $line"
          fi ;;
        linux-*)
          if [[ ! "${plats//windows/}" =~ [a-z] ]] || ! compgen -G "$dir/*.sh" > /dev/null; then
            echo "$name:$n: does not run on Linux: $line"
          fi ;;
        appliance)
          if [[ "$(yml_value "$yml" risk)" != manual-only ]]; then
            echo "$name:$n: not manual-only: $line"
          fi ;;
      esac
    done < "$f"
  done
}

@test "the six profiles ship" {
  for name in linux-server linux-web linux-siem windows-member windows-dc appliance; do
    [ -f "$REPO/profiles/$name.profile" ]
  done
}

@test "every shipped profile lists only shipped modules that fit it" {
  run profile_problems "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the check finds each kind of wrong line" {
  local t="$BATS_TMPDIR/profiles-$$"
  rm -rf "$t"; mkdir -p "$t/profiles" "$t/phases/lockout/modules/lin" "$t/phases/lockout/modules/win"
  printf 'id: lockout.lin\nplatforms: [ubuntu]\nrisk: reversible\n' > "$t/phases/lockout/modules/lin/module.yml"
  : > "$t/phases/lockout/modules/lin/check.sh"
  printf 'id: lockout.win\nplatforms: [windows]\nrisk: manual-only\n' > "$t/phases/lockout/modules/win/module.yml"
  : > "$t/phases/lockout/modules/win/check.ps1"
  printf '# comment\n\nlockout.lin\nlockout.lin\nNot An Id\nlockout.gone\nlockout.win # wrong platform\n' \
    > "$t/profiles/linux-server.profile"
  printf 'lockout.win\nlockout.lin\n' > "$t/profiles/windows-member.profile"
  printf 'lockout.win\nlockout.lin\n' > "$t/profiles/appliance.profile"
  run profile_problems "$t"
  rm -rf "$t"
  [ "${lines[0]}" = "appliance:2: not manual-only: lockout.lin" ]
  [ "${lines[1]}" = "linux-server:4: listed twice: lockout.lin" ]
  [ "${lines[2]}" = "linux-server:5: not a module id: Not An Id" ]
  [ "${lines[3]}" = "linux-server:6: no such module: lockout.gone" ]
  [ "${lines[4]}" = "linux-server:7: does not run on Linux: lockout.win" ]
  [ "${lines[5]}" = "windows-member:2: does not run on Windows: lockout.lin" ]
  [ "${#lines[@]}" -eq 6 ]
}
