#!/usr/bin/env bats
# Unit tests for the Linux platform facts (core/platform/platform.sh,
# design 19). Each test builds a fake root under LAB_SYSROOT and puts stub
# commands first on PATH, so no real host file or firewall is read.

setup() {
  LAB_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export LAB_ROOT
  export LAB_SYSROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$LAB_SYSROOT/etc" "$BATS_TEST_TMPDIR/bin"
  # Only the stubs and the basic tools are on PATH, so a real ufw, nft or
  # rpm on the test machine is never found.
  local t sh
  sh="$(command -v bash)"
  for t in bash cat chmod env ls mkdir rm; do
    printf '#!%s\nexec %s "$@"\n' "$sh" "$(command -v "$t")" > "$BATS_TEST_TMPDIR/bin/$t"
    chmod +x "$BATS_TEST_TMPDIR/bin/$t"
  done
  PATH="$BATS_TEST_TMPDIR/bin"
  # shellcheck source=/dev/null
  source "$LAB_ROOT/core/lib.sh"
}

# stub NAME BODY: put a fake command on PATH
stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BATS_TEST_TMPDIR/bin/$1"
  chmod +x "$BATS_TEST_TMPDIR/bin/$1"
}

os_release() { printf '%s\n' "$@" > "$LAB_SYSROOT/etc/os-release"; }

@test "facts: each supported family is recognized, including through ID_LIKE" {
  local id like want
  while read -r id like want; do
    os_release "ID=$id" "ID_LIKE=\"${like//,/ }\"" 'VERSION_ID="1.0"'
    [ "$(lab_fact os_id)" = "$id" ] || { echo "os_id for $id"; return 1; }
    [ "$(lab_fact os_family)" = "$want" ] || { echo "family for $id: $(lab_fact os_family)"; return 1; }
  done <<'EOF'
ubuntu debian debian
debian - debian
linuxmint ubuntu,debian debian
fedora - rhel
rhel fedora rhel
rocky rhel,centos,fedora rhel
ol fedora rhel
almalinux rhel,centos,fedora rhel
centos rhel,fedora rhel
EOF
  [ "$(lab_fact os_version)" = 1.0 ]
}

@test "facts: an unknown or missing os-release gives unknown" {
  os_release 'ID=plan9'
  [ "$(lab_fact os_id)" = plan9 ]
  [ "$(lab_fact os_family)" = unknown ]
  [ "$(lab_fact os_version)" = unknown ]
  rm "$LAB_SYSROOT/etc/os-release"
  [ "$(lab_fact os_id)" = unknown ]
  [ "$(lab_fact os_family)" = unknown ]
}

@test "facts: quotes and Windows line endings are stripped" {
  printf 'ID="ubuntu"\r\nVERSION_ID='"'"'24.04'"'"'\r\n' > "$LAB_SYSROOT/etc/os-release"
  [ "$(lab_fact os_id)" = ubuntu ]
  [ "$(lab_fact os_version)" = 24.04 ]
}

@test "facts: init, package database and SELinux" {
  os_release 'ID=rocky' 'ID_LIKE="rhel centos fedora"'
  [ "$(lab_fact init)" = other ]
  [ "$(lab_fact pkg_db)" = none ]
  [ "$(lab_fact selinux)" = absent ]
  mkdir -p "$LAB_SYSROOT/run/systemd/system"
  stub rpm 'exit 0'
  stub getenforce 'echo Enforcing'
  [ "$(lab_fact init)" = systemd ]
  [ "$(lab_fact pkg_db)" = rpm ]
  [ "$(lab_fact selinux)" = enforcing ]
  os_release 'ID=debian'
  stub dpkg-query 'exit 0'
  [ "$(lab_fact pkg_db)" = dpkg ]
}

@test "firewall: none when no backend is active" {
  [ "$(lab_fact firewall)" = none ]
  stub ufw 'echo "Status: inactive"'
  stub firewall-cmd 'echo "not running"; exit 252'
  stub nft 'exit 0'
  stub iptables 'printf -- "-P INPUT ACCEPT\n-P FORWARD ACCEPT\n-P OUTPUT ACCEPT\n"'
  [ "$(lab_fact firewall)" = none ]
}

@test "firewall: UFW active is ufw, even though nftables shows its tables" {
  stub ufw 'echo "Status: active"'
  stub nft 'printf "table ip filter\ntable ip6 filter\n"'
  stub iptables 'printf -- "-P INPUT DROP\n-A INPUT -j ufw-before-input\n"'
  [ "$(lab_fact firewall)" = ufw ]
}

@test "firewall: firewalld, nftables and iptables are each recognized" {
  stub firewall-cmd 'echo running'
  stub nft 'printf "table inet firewalld\n"'
  [ "$(lab_fact firewall)" = firewalld ]
  rm "$BATS_TEST_TMPDIR/bin/firewall-cmd"
  stub nft 'printf "table inet filter\n"'
  [ "$(lab_fact firewall)" = nftables ]
  stub nft 'printf "table ip nat\ntable ip filter\n"'
  stub iptables 'printf -- "-P INPUT ACCEPT\n-A INPUT -p tcp --dport 22 -j ACCEPT\n"'
  [ "$(lab_fact firewall)" = iptables ]
}

@test "firewall: the nftables service counts as active" {
  stub nft 'exit 0'
  stub systemctl '[ "$*" = "is-active --quiet nftables" ]'
  [ "$(lab_fact firewall)" = nftables ]
}

@test "firewall: two active backends are a conflict" {
  stub ufw 'echo "Status: active"'
  stub firewall-cmd 'echo running'
  [ "$(lab_fact firewall)" = conflict ]
}

@test "firewall: a check that cannot run gives unknown, not none" {
  stub ufw 'echo "ERROR: You need to be root to run this script" >&2; exit 1'
  [ "$(lab_fact firewall)" = unknown ]
  rm "$BATS_TEST_TMPDIR/bin/ufw"
  stub nft 'echo "Operation not permitted" >&2; exit 1'
  [ "$(lab_fact firewall)" = unknown ]
}

@test "facts: lab_facts prints every fact, and lab_facts_load keeps them" {
  os_release 'ID=ubuntu' 'VERSION_ID="24.04"'
  run lab_facts
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 7 ]
  [[ "$output" == *"os_family=debian"* ]]
  [[ "$output" == *"firewall=none"* ]]
  lab_facts_load
  os_release 'ID=fedora'
  [ "$(lab_fact os_id)" = ubuntu ]
}

@test "facts: an unknown fact name is an error" {
  run lab_fact colour
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown fact colour"* ]]
}

@test "facts: lab_have finds only commands on the path" {
  stub jq 'exit 0'
  lab_have jq
  ! lab_have python3
}

@test "facts: reading every fact changes no file under the fake root" {
  os_release 'ID=ubuntu'
  mkdir -p "$LAB_SYSROOT/run/systemd/system"
  stub ufw 'echo "Status: active"'
  local before after
  before="$(cd "$LAB_SYSROOT" && ls -lRa --time-style=full-iso . 2> /dev/null || ls -lRa .)"
  lab_facts > /dev/null
  after="$(cd "$LAB_SYSROOT" && ls -lRa --time-style=full-iso . 2> /dev/null || ls -lRa .)"
  [ "$before" = "$after" ]
}
