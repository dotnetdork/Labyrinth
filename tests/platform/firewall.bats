#!/usr/bin/env bats
# Unit tests for the Linux firewall adapter (platform/linux/firewall/,
# design 19, section 5). Every firewall command is a stub that writes its
# arguments to $CALLS, so the tests see exactly what would have run. No real
# firewall is read or changed.

setup() {
  LAB_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export LAB_ROOT
  export LAB_SYSROOT="$BATS_TEST_TMPDIR/root"
  export LAB_CONFIG_DIR="$BATS_TEST_TMPDIR/etc"
  export LAB_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export LAB_LOG_DIR="$BATS_TEST_TMPDIR/logs"
  export LAB_BACKUP_DIR="$BATS_TEST_TMPDIR/backup"
  export LAB_RUN_ID='20261005T120000Z-abcd'
  export LAB_MODULE_ID='lockout.firewall'
  export LAB_DRY_RUN=0
  export CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$LAB_SYSROOT/etc" "$LAB_CONFIG_DIR" "$BATS_TEST_TMPDIR/bin"
  : > "$CALLS"
  printf '198.51.100.7\n2001:db8::7\n' > "$LAB_CONFIG_DIR/scoring-allowlist"
  # Only the stubs and the basic tools are on PATH, so a real firewall
  # command on the test machine is never found.
  local t sh p
  sh="$(command -v bash)"
  for t in bash cat chmod chown cp date dirname env find grep head hostname id ls mkdir mv rm sed tac tr uname wc; do
    p="$(command -v "$t")" || continue
    printf '#!%s\nexec %s "$@"\n' "$sh" "$p" > "$BATS_TEST_TMPDIR/bin/$t"
    chmod +x "$BATS_TEST_TMPDIR/bin/$t"
  done
  PATH="$BATS_TEST_TMPDIR/bin"
  # shellcheck source=/dev/null
  source "$LAB_ROOT/core/lib.sh"
  # shellcheck source=/dev/null
  source "$LAB_ROOT/platform/linux/firewall/firewall.sh"
}

# stub NAME BODY: put a fake command on PATH that logs its arguments
stub() {
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS"\n%s\n' "$1" "$2" > "$BATS_TEST_TMPDIR/bin/$1"
  chmod +x "$BATS_TEST_TMPDIR/bin/$1"
}

calls() { cat "$CALLS"; }
called() { grep -qxF -- "$1" "$CALLS"; }
# A bare "! cmd" never fails a bats test, so the negative checks are functions.
not_called() { ! grep -qxF -- "$1" "$CALLS"; }
never_ran() { ! grep -q -- "$1" "$CALLS"; }
manifest_actions() { sed -E 's/.*"action":"([a-z_]+)".*/\1/' "$(lab_manifest_file)" | tr '\n' ' '; }

ufw_host() {
  LAB_FACT_firewall=ufw
  mkdir -p "$LAB_SYSROOT/etc/ufw" "$LAB_SYSROOT/etc/default"
  printf '%s\n' '-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT' > "$LAB_SYSROOT/etc/ufw/before.rules"
  printf 'user rules v1\n' > "$LAB_SYSROOT/etc/ufw/user.rules"
  printf 'ENABLED=yes\n' > "$LAB_SYSROOT/etc/ufw/ufw.conf"
  printf 'IPV6=yes\n' > "$LAB_SYSROOT/etc/default/ufw"
  stub ufw '[ "$1 $2" = "status verbose" ] && echo "Status: active" || true'
}

@test "firewall: every function but restore is refused when the backend is not known" {
  local fact fn
  for fact in conflict unknown; do
    LAB_FACT_firewall="$fact"
    for fn in snapshot 'allow tcp 22 any' default_deny_in state; do
      run lab_fw $fn
      [ "$status" -eq 20 ] || { echo "$fact $fn: $status"; return 1; }
      [[ "$output" == *"the active firewall is '$fact'"* ]]
    done
  done
  [ -z "$(calls)" ]
  [ ! -e "$(lab_manifest_file)" ]
}

@test "firewall: with no active firewall, an installed nft is used, then iptables, else refused" {
  LAB_FACT_firewall=none
  run lab_fw snapshot
  [ "$status" -eq 20 ]
  [[ "$output" == *"neither nft nor iptables is installed"* ]]
  [ ! -e "$(lab_manifest_file)" ]
  stub iptables-save 'echo "*filter"'
  stub ip6tables-save 'echo "*filter"'
  stub iptables 'exit 0'
  lab_fw snapshot
  [ "$(cat "$(lab_json_get "$(grep firewall_snapshot "$(lab_manifest_file)")" backup)/backend")" = iptables ]
  stub nft 'exit 0'
  lab_fw snapshot
  # The stubbed PATH has no tail, so take the last line in bash.
  local last
  last="$(grep firewall_snapshot "$(lab_manifest_file)")"
  last="${last##*$'\n'}"
  [ "$(lab_json_get "$last" target)" = nftables ]
}

@test "firewall: allow and default deny need a snapshot first" {
  ufw_host
  run lab_fw allow tcp 443 198.51.100.7
  [ "$status" -eq 20 ]
  [[ "$output" == *"no firewall snapshot"* ]]
  run lab_fw default_deny_in
  [ "$status" -eq 20 ]
  [ -z "$(calls)" ]
}

@test "firewall: nothing changes in plan mode" {
  ufw_host
  export LAB_DRY_RUN=1
  local fn
  for fn in snapshot 'allow tcp 443 any' default_deny_in; do
    run lab_fw $fn
    [ "$status" -eq 20 ] || { echo "$fn: $status"; return 1; }
    [[ "$output" == *"refused in plan mode"* ]]
  done
  [ -z "$(calls)" ]
}

@test "firewall: bad arguments are errors" {
  ufw_host
  lab_fw snapshot
  run lab_fw allow icmp 1 any
  [ "$status" -eq 40 ]
  run lab_fw allow tcp 70000 any
  [ "$status" -eq 40 ]
  run lab_fw allow tcp 22 not-an-address
  [ "$status" -eq 40 ]
  run lab_fw allow tcp 22
  [ "$status" -eq 40 ]
  run lab_fw open
  [ "$status" -eq 40 ]
  run lab_fw restore "$BATS_TEST_TMPDIR/nothing"
  [ "$status" -eq 40 ]
  never_ran 'prepend'
}

@test "ufw: snapshot, allow before any deny, then default deny, each recorded first" {
  ufw_host
  lab_fw snapshot
  local dir
  dir="$(lab_json_get "$(grep firewall_snapshot "$(lab_manifest_file)")" backup)"
  [ -f "$dir/ufw/user.rules" ] && [ -f "$dir/default-ufw" ] && [ "$(cat "$dir/backend")" = ufw ]
  [ "$(cat "$dir/state")" = 'Status: active' ]
  lab_fw allow tcp 443 198.51.100.7
  lab_fw allow tcp 443 198.51.100.7
  called 'ufw prepend allow proto tcp from 198.51.100.7 to any port 443'
  [ "$(grep -c prepend "$CALLS")" -eq 1 ]
  run lab_fw default_deny_in
  [ "$status" -eq 20 ]
  [[ "$output" == *"no allow yet from the scoring address(es) 2001:db8::7"* ]]
  never_ran 'default deny'
  lab_fw allow udp 53 2001:db8::7
  lab_fw default_deny_in
  called 'ufw default deny incoming'
  [ "$(manifest_actions)" = 'firewall_snapshot firewall_allow firewall_allow firewall_default_deny ' ]
}

@test "ufw: default deny is refused when before.rules no longer accept ping" {
  ufw_host
  : > "$LAB_SYSROOT/etc/ufw/before.rules"
  lab_fw snapshot
  lab_fw allow tcp 443 198.51.100.7
  lab_fw allow tcp 443 2001:db8::7
  run lab_fw default_deny_in
  [ "$status" -eq 20 ]
  [[ "$output" == *"no longer accepts ICMP echo requests"* ]]
  never_ran 'default deny'
}

@test "firewall: default deny needs each scored service's port allowed from every scoring address" {
  ufw_host
  printf 'web-main http %s 80 Welcome\ndns-main dns %s 53 www.example.test=192.0.2.20\nmail-smtp smtp other.example.test 25 -\n' \
    "$(lab_host)" "$(lab_host)" > "$LAB_CONFIG_DIR/services"
  lab_fw snapshot
  lab_fw allow tcp 22 198.51.100.7
  lab_fw allow tcp 22 2001:db8::7
  run lab_fw default_deny_in
  [ "$status" -eq 20 ]
  [[ "$output" == *"web-main tcp/80 from 198.51.100.7"* && "$output" == *"dns-main udp/53 from 2001:db8::7"* ]]
  [[ "$output" != *mail-smtp* ]]
  never_ran 'default deny'
  lab_fw allow tcp 80 any
  lab_fw allow tcp 53 198.51.100.7
  lab_fw allow tcp 53 2001:db8::7
  run lab_fw default_deny_in
  [ "$status" -eq 20 ]
  [[ "$output" == *"dns-main udp/53"* && "$output" != *web-main* ]]
  lab_fw allow udp 53 any
  lab_fw default_deny_in
  called 'ufw default deny incoming'
}

@test "firewall: with no scored service here, an allow from any covers every scoring address" {
  ufw_host
  lab_fw snapshot
  lab_fw allow tcp 80 any
  lab_fw default_deny_in
  called 'ufw default deny incoming'
}

@test "firewall: default deny is refused without a scoring allowlist" {
  ufw_host
  rm "$LAB_CONFIG_DIR/scoring-allowlist"
  lab_fw snapshot
  run lab_fw default_deny_in
  [ "$status" -eq 20 ]
  [[ "$output" == *"scoring allowlist is missing or empty"* ]]
  never_ran 'default deny'
}

@test "ufw: rollback writes the saved files back and reloads" {
  ufw_host
  lab_fw snapshot
  lab_fw allow tcp 22 any
  printf 'user rules v2\n' > "$LAB_SYSROOT/etc/ufw/user.rules"
  lab_fw_rollback
  [ "$(cat "$LAB_SYSROOT/etc/ufw/user.rules")" = 'user rules v1' ]
  called 'ufw reload'
  lab_fw_rollback
}

@test "firewall: a restore that does not give back the saved state is reported" {
  ufw_host
  lab_fw snapshot
  stub ufw 'echo "Status: inactive"'
  run lab_fw_rollback
  [ "$status" -eq 30 ]
  [[ "$output" == *"differ from the snapshot"* ]]
}

@test "firewall: restore uses the snapshot's backend after the fact changes" {
  ufw_host
  lab_fw snapshot
  LAB_FACT_firewall=conflict
  lab_fw_rollback
  called 'ufw reload'
}

@test "firewall: a snapshot never overwrites a folder in use" {
  ufw_host
  mkdir -p "$BATS_TEST_TMPDIR/snap"
  : > "$BATS_TEST_TMPDIR/snap/x"
  run lab_fw snapshot "$BATS_TEST_TMPDIR/snap"
  [ "$status" -eq 40 ]
}

@test "nftables: Labyrinth's own table, then a drop policy, restored in one transaction" {
  LAB_FACT_firewall=nftables
  stub nft '
case "$*" in
  "list ruleset") echo "table inet filter {"; echo "  counter packets 4 bytes 99"; echo "}" ;;
  "list chain inet labyrinth input") [ -f "$CALLS.chain" ] || exit 1; echo "type filter" ;;
  "add chain"*) : > "$CALLS.chain" ;;
esac
exit 0'
  lab_fw snapshot
  [ "$(lab_fw state)" = $'table inet filter {\n  counter\n}' ]
  lab_fw allow tcp 22 198.51.100.7
  lab_fw allow tcp 22 2001:db8::7
  lab_fw allow udp 53 any
  called 'nft add table inet labyrinth'
  called 'nft add chain inet labyrinth input { type filter hook input priority -10 ; policy accept ; }'
  [ "$(grep -c 'add chain' "$CALLS")" -eq 1 ]
  called 'nft add rule inet labyrinth input ip saddr 198.51.100.7 tcp dport 22 accept'
  called 'nft add rule inet labyrinth input ip6 saddr 2001:db8::7 tcp dport 22 accept'
  called 'nft add rule inet labyrinth input udp dport 53 accept'
  lab_fw default_deny_in
  called 'nft add rule inet labyrinth input iif lo accept'
  called 'nft add rule inet labyrinth input ct state established,related accept'
  called 'nft add rule inet labyrinth input meta l4proto { icmp, ipv6-icmp } accept'
  called 'nft add chain inet labyrinth input { type filter hook input priority -10 ; policy drop ; }'
  lab_fw_rollback
  local dir
  dir="$(lab_json_get "$(grep firewall_snapshot "$(lab_manifest_file)")" backup)"
  [ "$(head -n 1 "$dir/restore.nft")" = 'flush ruleset' ]
  called "nft -f $dir/restore.nft"
}

@test "iptables: Labyrinth's own chain, for the families each source needs" {
  LAB_FACT_firewall=iptables
  local t
  for t in iptables ip6tables; do
    stub "$t" 'case "$1" in -C | -S) exit 1 ;; esac; exit 0'
    stub "$t-save" 'echo "# Generated"; echo "*filter"; echo ":INPUT ACCEPT [12:345]"; echo "COMMIT"'
    stub "$t-restore" 'exit 0'
  done
  lab_fw snapshot
  [[ "$(lab_fw state)" == *':INPUT ACCEPT [0:0]'* ]]
  [[ "$(lab_fw state)" != *'Generated'* ]]
  lab_fw allow tcp 443 198.51.100.7
  lab_fw allow tcp 443 2001:db8::7
  lab_fw allow tcp 22 any
  called 'iptables -N LAB-INPUT'
  called 'iptables -I INPUT 1 -j LAB-INPUT'
  called 'iptables -A LAB-INPUT -p tcp -s 198.51.100.7 --dport 443 -j ACCEPT'
  called 'ip6tables -A LAB-INPUT -p tcp -s 2001:db8::7 --dport 443 -j ACCEPT'
  not_called 'iptables -A LAB-INPUT -p tcp -s 2001:db8::7 --dport 443 -j ACCEPT'
  called 'iptables -A LAB-INPUT -p tcp --dport 22 -j ACCEPT'
  called 'ip6tables -A LAB-INPUT -p tcp --dport 22 -j ACCEPT'
  lab_fw default_deny_in
  called 'iptables -A LAB-INPUT -i lo -j ACCEPT'
  called 'iptables -A LAB-INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT'
  called 'iptables -A LAB-INPUT -p icmp -j ACCEPT'
  called 'ip6tables -A LAB-INPUT -p ipv6-icmp -j ACCEPT'
  called 'iptables -P INPUT DROP'
  called 'ip6tables -P INPUT DROP'
  lab_fw_rollback
  called 'iptables-restore '
  called 'ip6tables-restore '
}

@test "iptables: without ip6tables, the default deny says IPv6 stays open" {
  LAB_FACT_firewall=iptables
  stub iptables 'case "$1" in -C | -S) exit 1 ;; esac; exit 0'
  stub iptables-save 'echo "*filter"'
  lab_fw snapshot
  lab_fw allow tcp 22 any
  run lab_fw default_deny_in
  [ "$status" -eq 0 ]
  [[ "$output" == *"ip6tables is not installed, so IPv6 stays open"* ]]
  called 'iptables -P INPUT DROP'
}

@test "firewalld: every active zone, at run time and permanently; added files moved aside" {
  LAB_FACT_firewall=firewalld
  mkdir -p "$LAB_SYSROOT/etc/firewalld/zones"
  printf 'conf v1\n' > "$LAB_SYSROOT/etc/firewalld/firewalld.conf"
  printf '<zone/>\n' > "$LAB_SYSROOT/etc/firewalld/zones/public.xml"
  stub firewall-cmd '
case "$*" in
  --get-active-zones) printf "public\n  interfaces: eth0\ninternal\n  sources: 10.0.0.0/8\n" ;;
  *list-all-zones) echo "public (active)" ;;
esac
exit 0'
  lab_fw snapshot
  lab_fw allow tcp 25 198.51.100.7
  lab_fw allow tcp 25 2001:db8::7
  lab_fw allow tcp 80 any
  local z
  for z in public internal; do
    called "firewall-cmd --zone=$z --add-rich-rule=rule family=\"ipv4\" source address=\"198.51.100.7\" port port=\"25\" protocol=\"tcp\" accept"
    called "firewall-cmd --permanent --zone=$z --add-rich-rule=rule family=\"ipv6\" source address=\"2001:db8::7\" port port=\"25\" protocol=\"tcp\" accept"
    called "firewall-cmd --zone=$z --add-port=80/tcp"
    called "firewall-cmd --permanent --zone=$z --add-port=80/tcp"
  done
  lab_fw default_deny_in
  called 'firewall-cmd --zone=public --add-rich-rule=rule protocol value="icmp" accept'
  called 'firewall-cmd --permanent --zone=internal --add-rich-rule=rule protocol value="ipv6-icmp" accept'
  called 'firewall-cmd --permanent --zone=public --set-target=DROP'
  called 'firewall-cmd --permanent --zone=internal --set-target=DROP'
  called 'firewall-cmd --reload'
  printf 'conf v2\n' > "$LAB_SYSROOT/etc/firewalld/firewalld.conf"
  printf '<zone/>\n' > "$LAB_SYSROOT/etc/firewalld/zones/planted.xml"
  lab_fw_rollback
  [ "$(cat "$LAB_SYSROOT/etc/firewalld/firewalld.conf")" = 'conf v1' ]
  [ ! -e "$LAB_SYSROOT/etc/firewalld/zones/planted.xml" ]
  local dir
  dir="$(lab_json_get "$(grep firewall_snapshot "$(lab_manifest_file)")" backup)"
  [ -f "$dir/rolled-back/zones/planted.xml" ]
}

@test "firewalld: the snapshot warns about rules that exist only at run time" {
  LAB_FACT_firewall=firewalld
  mkdir -p "$LAB_SYSROOT/etc/firewalld"
  stub firewall-cmd '
case "$*" in
  "--list-all-zones") echo "public: port 4444/tcp" ;;
  "--permanent --list-all-zones") echo "public:" ;;
esac
exit 0'
  run lab_fw snapshot
  [ "$status" -eq 0 ]
  [[ "$output" == *"exist only at run time"* ]]
}
