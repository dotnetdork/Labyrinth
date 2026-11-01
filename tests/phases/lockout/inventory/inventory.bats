#!/usr/bin/env bats
# Tests for lockout.inventory on Linux (design 08, section 3.1).
# The parsers take text, so most tests feed them captured output. The rest run
# check.sh against the host it is on, read-only apart from the state folder,
# and one test (LAB_REALSYSTEM=1, CI only) opens real sockets.

REPO="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
MOD="$REPO/phases/lockout/modules/inventory"

setup() {
  W="$BATS_TEST_TMPDIR"
  export LAB_ROOT="$REPO" LAB_CONFIG_DIR="$W/config" LAB_STATE_DIR="$W/state" LAB_LOG_DIR="$W/logs"
  export LAB_BACKUP_DIR="$W/backup" LAB_RUN_ID=20261101T000000Z-abcd LAB_MODULE_ID=lockout.inventory
  export LAB_ENTRY=check
  mkdir -p "$LAB_CONFIG_DIR"
  # shellcheck source=core/lib.sh
  source "$REPO/core/lib.sh"
  # shellcheck source=phases/lockout/modules/inventory/inventory.sh
  source "$MOD/inventory.sh"
  SEP=$'\037'
}

# A captured `ss -H -tunap`: nginx (pid 100) listens on 80 and has a client;
# php-fpm (pid 101, a child of 100) talks to a database; a login shell holds
# an outbound connection of its own; DNS listens on 53.
SS_TEXT='tcp   LISTEN 0      511          0.0.0.0:80         0.0.0.0:*     users:(("nginx",pid=100,fd=6))
tcp   ESTAB  0      0         192.0.2.10:80    203.0.113.9:51000 users:(("nginx",pid=100,fd=7))
tcp   ESTAB  0      0         192.0.2.10:44444 198.51.100.5:5432 users:(("php-fpm",pid=101,fd=9))
tcp   ESTAB  0      0         192.0.2.10:44445 127.0.0.1:3306    users:(("php-fpm",pid=101,fd=10))
tcp   ESTAB  0      0         192.0.2.10:55555 203.0.113.77:22   users:(("ssh",pid=300,fd=3))
udp   UNCONN 0      0               0.0.0.0:53         0.0.0.0:*   users:(("named",pid=200,fd=5))
udp   ESTAB  0      0         192.0.2.10:40000 198.51.100.53:53  users:(("named",pid=200,fd=8))
tcp   ESTAB  0      0   [::ffff:192.0.2.10]:44446 [::ffff:198.51.100.6]:25 users:(("php-fpm",pid=101,fd=11))
tcp   LISTEN 0      4096         [::]:22            [::]:*       '

PS_TEXT='1 0
100 1
101 100
200 1
300 1
400 101'

@test "ss output becomes one line per socket and process" {
  run inv_parse_ss "$SS_TEXT"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "tcp${SEP}LISTEN${SEP}0.0.0.0${SEP}80${SEP}0.0.0.0${SEP}*${SEP}100${SEP}nginx" ]]
  [[ "${lines[2]}" == "tcp${SEP}ESTAB${SEP}192.0.2.10${SEP}44444${SEP}198.51.100.5${SEP}5432${SEP}101${SEP}php-fpm" ]]
  # IPv6 brackets are removed, and a socket with no visible process has an empty pid.
  [[ "${lines[8]}" == "tcp${SEP}LISTEN${SEP}::${SEP}22${SEP}::${SEP}*${SEP}${SEP}" ]]
}

@test "a systemd service is read from the cgroup text, a session or container is not" {
  inv_cgroup_unit '0::/system.slice/nginx.service'
  [ "$INV_UNIT" = nginx.service ]
  inv_cgroup_unit $'12:cpu:/\n1:name=systemd:/system.slice/ssh.service\n'
  [ "$INV_UNIT" = ssh.service ]
  inv_cgroup_unit '0::/user.slice/user-1000.slice/session-3.scope'
  [ -z "$INV_UNIT" ]
  inv_cgroup_unit '0::/system.slice/docker-abc.scope'
  [ -z "$INV_UNIT" ]
  inv_cgroup_unit ''
  [ -z "$INV_UNIT" ]
}

@test "descendants include the process itself and everything below it" {
  run inv_descendants "$PS_TEXT" 100
  [ "$status" -eq 0 ]
  [ "$output" = $'100\n101\n400' ]
  run inv_descendants "$PS_TEXT" 300
  [ "$output" = 300 ]
}

@test "the processes of a scored service: its unit if it has one, else the listener and its children" {
  ss="$(inv_parse_ss "$SS_TEXT")"
  # No unit: the listener (100) and its descendants.
  run inv_service_pids "$ss" 80 tcp "$PS_TEXT" ''
  [ "$output" = $'100\n101\n400' ]
  # With a unit: every process of the unit, not the children.
  map="100${SEP}nginx.service"$'\n'"150${SEP}nginx.service"$'\n'"300${SEP}ssh.service"
  run inv_service_pids "$ss" 80 tcp "$PS_TEXT" "$map"
  [ "$output" = $'100\n150' ]
  # DNS answers on UDP and TCP.
  run inv_service_pids "$ss" 53 'tcp udp' "$PS_TEXT" ''
  [ "$output" = 200 ]
  # TCP only: the UDP listener is not the service.
  run inv_service_pids "$ss" 53 tcp "$PS_TEXT" ''
  [ -z "$output" ]
  # Nothing listens on the port.
  run inv_service_pids "$ss" 8080 tcp "$PS_TEXT" ''
  [ -z "$output" ]
}

@test "outbound: a scored service's connection is in, an inbound client is not" {
  ss="$(inv_parse_ss "$SS_TEXT")"
  ports="$(inv_listen_ports "$ss")"
  [ "$ports" = $'22\n53\n80' ]
  run inv_outbound "$ss" $'100\n101\n400' "$ports"
  [ "$status" -eq 0 ]
  # php-fpm's database, and its IPv4-mapped IPv6 mail connection shown as IPv4.
  [[ "$output" == *"198.51.100.5 tcp 5432 php-fpm"* ]]
  [[ "$output" == *"198.51.100.6 tcp 25 php-fpm"* ]]
  # nginx's client (local port 80 is a listening port), loopback, and another
  # program's connection are not.
  [[ "$output" != *"203.0.113.9"* ]]
  [[ "$output" != *"127.0.0.1"* ]]
  [[ "$output" != *"203.0.113.77"* ]]
  # A connected UDP socket counts.
  run inv_outbound "$ss" 200 "$ports"
  [ "$output" = "198.51.100.53 udp 53 named" ]
}

@test "the map only grows: no duplicates, nothing removed, hand edits kept" {
  f="$W/deps"
  inv_merge_map "$f" 'web 198.51.100.5 tcp 5432 php-fpm' 'web 198.51.100.6 tcp 25 php-fpm'
  [ "${#INV_MAP_NEW[@]}" -eq 2 ]
  head -n 1 "$f" | grep -q '^# service'
  # A person adds a line; a later run sees fewer connections and one new one.
  printf '%s\n' 'web 192.0.2.99 tcp 389 ldap' >> "$f"
  inv_merge_map "$f" 'web 198.51.100.5 tcp 5432 php-fpm-other' 'dns1 198.51.100.53 udp 53 named'
  [ "${#INV_MAP_NEW[@]}" -eq 1 ]
  [ "$(grep -c . "$f")" -eq 6 ]
  for want in 'web 198.51.100.5 tcp 5432 php-fpm' 'web 198.51.100.6 tcp 25 php-fpm' 'web 192.0.2.99 tcp 389 ldap' 'dns1 198.51.100.53 udp 53 named'; do
    grep -qx "$want" "$f"
  done
  # Nothing new: the file is byte for byte the same.
  before="$(cat "$f")"
  inv_merge_map "$f"
  [ "$(cat "$f")" = "$before" ]
  # A repeat adds nothing.
  inv_merge_map "$f" 'dns1 198.51.100.53 udp 53 named'
  [ "${#INV_MAP_NEW[@]}" -eq 0 ]
  [ "$(cat "$f")" = "$before" ]
}

@test "the map's lines have the columns of outbound-allow after the service name" {
  inv_merge_map "$W/deps" 'web 198.51.100.5 tcp 5432 php-fpm'
  # The firewall reads columns 2 to 4 as address, protocol and port.
  run awk '!/^#/ {print $2, $3, $4}' "$W/deps"
  [ "$output" = "198.51.100.5 tcp 5432" ]
}

@test "accounts: the password state is kept, the hash is not" {
  inv_parse_shadow $'alice:$6$salt$SECRETHASHVALUE:19000:0:99999:7:::\nbob:!$6$x$LOCKEDHASH:19000::::::\ncarol::19000::::::\nsvc:*:19000::::::'
  inv_parse_passwd $'alice:x:1000:1000:Alice:/home/alice:/bin/bash\nbob:x:1001:1001::/home/bob:/bin/sh\ncarol:x:1002:1002::/home/carol:/bin/sh\nsvc:x:998:998::/:/usr/sbin/nologin'
  [[ "$INV_OUT" == *'"name":"alice","uid":1000,"gid":1000,"home":"/home/alice","shell":"/bin/bash","password":"set"'* ]]
  [[ "$INV_OUT" == *'"name":"bob"'*'"password":"locked"'* ]]
  [[ "$INV_OUT" == *'"name":"carol"'*'"password":"none"'* ]]
  [[ "$INV_OUT" != *SECRETHASHVALUE* ]]
  [[ "$INV_OUT" != *LOCKEDHASH* ]]
  [ "${INV_COUNT[user]}" -eq 4 ]
}

@test "groups and sudo rules: comments are skipped, an include is kept" {
  inv_parse_group $'root:x:0:\nsudo:x:27:alice,bob'
  [[ "$INV_OUT" == *'"kind":"group","name":"sudo","gid":27,"members":"alice,bob"'* ]]
  inv_parse_sudoers /etc/sudoers $'# a comment\n\nroot ALL=(ALL:ALL) ALL\n%sudo ALL=(ALL:ALL) ALL\n#includedir /etc/sudoers.d\n'
  [ "${INV_COUNT[sudoers]}" -eq 3 ]
  [[ "$INV_OUT" == *'"rule":"#includedir /etc/sudoers.d"'* ]]
}

@test "keys are recorded by fingerprint, never the key itself" {
  inv_parse_authkeys alice /home/alice/.ssh/authorized_keys $'# a comment\ncommand="/bin/true",no-pty ssh-ed25519 dGVzdGtleWJsb2I= alice@example.test\n'
  [ "${INV_COUNT[key]}" -eq 1 ]
  [[ "$INV_OUT" == *'"type":"ssh-ed25519"'* ]]
  [[ "$INV_OUT" == *'"fingerprint":"SHA256:IZO8V5UocbGYVwglouCMXzRBM68lWPPjxWEnkyZ1uNc"'* ]]
  [[ "$INV_OUT" == *'"comment":"alice@example.test"'* ]]
  [[ "$INV_OUT" != *dGVzdGtleWJsb2I* ]]
}

@test "cron lines keep the program and a hash, not the arguments" {
  inv_parse_cron cron /etc/cron.d/backup 1 $'# m h dom mon dow user cmd\nMAILTO=root\n0 3 * * * root /usr/local/bin/backup --token=SECRETTOKEN\n@reboot root /usr/local/bin/start\n'
  [ "${INV_COUNT[task]}" -eq 2 ]
  [[ "$INV_OUT" == *'"user":"root","schedule":"0 3 * * *","command":"/usr/local/bin/backup"'* ]]
  [[ "$INV_OUT" == *'"schedule":"@reboot"'* ]]
  [[ "$INV_OUT" != *SECRETTOKEN* ]]
}

@test "packages are one record each, and a quote in a name stays valid JSON" {
  run inv_parse_packages $'bash\t5.2\nodd"name\t1\\2'
  [ "${lines[0]}" = '{"kind":"package","name":"bash","version":"5.2"}' ]
  [ "${lines[1]}" = '{"kind":"package","name":"odd\"name","version":"1\\2"}' ]
}

# run_check DRY_RUN: the module's check on this host.
run_check() {
  LAB_DRY_RUN="$1" run bash "$MOD/check.sh"
  echo "$output"
  if [ "$status" -ne 0 ]; then LAB_DRY_RUN="$1" bash -x "$MOD/check.sh" 2>&1 | tail -30; fi
}

@test "a preview prints what it found and writes nothing" {
  printf 'web http www.example.test 80 Welcome\n' > "$LAB_CONFIG_DIR/services"
  run_check 1
  [ "$status" -eq 0 ]
  [[ "$output" == found:\ *user* ]]
  [[ "$output" != *"did:"* ]]
  [ ! -e "$W/state" ]
}

@test "a run writes the inventory and the map, and a second run never shrinks the map" {
  printf 'web http www.example.test 80 Welcome\n' > "$LAB_CONFIG_DIR/services"
  run_check 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"did: wrote the inventory to $W/state/inventory/"* ]]
  [ "$(find "$W/state/inventory" -name '*.jsonl' | wc -l)" -eq 1 ]
  [ -f "$W/state/inventory/deps" ]
  head -n 1 "$W/state/inventory/deps" | grep -q '^#'
  # Every line is a JSON object with a kind (a quick check, no JSON tool needed).
  run grep -vE '^\{"kind":"[a-z]+".*\}$' "$W/state/inventory"/*.jsonl
  [ "$status" -ne 0 ]
  grep -q '"kind":"user"' "$W/state/inventory"/*.jsonl
  printf '%s\n' 'web 192.0.2.99 tcp 389 ldap' >> "$W/state/inventory/deps"
  before="$(cat "$W/state/inventory/deps")"
  sleep 1
  run_check 0
  [ "$status" -eq 0 ]
  [ "$(find "$W/state/inventory" -name '*.jsonl' | wc -l)" -eq 2 ]
  after="$(cat "$W/state/inventory/deps")"
  # Every earlier line is still there, in order, at the start.
  [ "${after:0:${#before}}" = "$before" ]
}

@test "with no services file the inventory is still taken, with a note and no map lines" {
  run_check 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"found: note: there is no services file, so there is no dependency map"* ]]
  [ "$(find "$W/state/inventory" -name '*.jsonl' | wc -l)" -eq 1 ]
  [ ! -e "$W/state/inventory/deps" ]
}

@test "a services file that cannot be read gives a note, not a failure" {
  printf 'this is not a service line\n' > "$LAB_CONFIG_DIR/services"
  run_check 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"found: note: the services file could not be read"* ]]
}

@test "the run changes nothing outside the state folder, and records no secret" {
  printf 'web http www.example.test 80 Welcome\n' > "$LAB_CONFIG_DIR/services"
  touch "$W/marker"
  sleep 1
  cp -r "$LAB_CONFIG_DIR" "$W/config.before"
  run_check 0
  [ "$status" -eq 0 ]
  changed="$(find /etc /var/spool/cron /var/spool/cron/crontabs -xdev -newer "$W/marker" \
    -not -path /etc/resolv.conf -not -path '/etc/.*' -not -path /etc/mtab \
    -not -path /etc/cups -not -path /etc/ssl/certs 2> /dev/null || true)"
  [ -z "$changed" ]
  diff -r "$W/config.before" "$LAB_CONFIG_DIR"
  # The only new things under the work folder are the state folder (and the backups of this test).
  [ ! -e "$W/backup" ]
  [ ! -e "$W/logs" ]
  # No password hash and no private key or key body anywhere in what it wrote.
  run grep -rE '"[a-z]+":"\$(1|2[aby]|5|6|y)\$' "$W/state"
  [ "$status" -ne 0 ]
  run grep -rE 'PRIVATE KEY|AAAA[A-Za-z0-9+/]{40}' "$W/state"
  [ "$status" -ne 0 ]
}

@test "a missing tool is a note, never a failure" {
  # No ss, getent, systemctl or package tool on the path: the module still
  # exits 0 and says what it could not record.
  mkdir -p "$W/bin"
  for t in bash cat date mkdir sort sed awk tr head cut grep find uname id sleep wc mapfile; do
    p="$(command -v "$t" 2> /dev/null || true)"
    if [ -n "$p" ] && [ -x "$p" ]; then ln -sf "$p" "$W/bin/$t"; fi
  done
  LAB_DRY_RUN=1 PATH="$W/bin" run "$W/bin/bash" "$MOD/check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"found: note:"* ]]
}

@test "the module's code has no command that changes the host" {
  for f in "$MOD/inventory.sh" "$MOD/check.sh" "$MOD/plan.sh"; do
    code="$(sed 's/#.*$//' "$f")"
    run grep -nE '\b(useradd|usermod|userdel|chpasswd|chmod|chown|kill|pkill|rm|mv|cp|ln|tee|dd|apt|apt-get|dnf|yum|rpm -[ie]|systemctl +(start|stop|restart|enable|disable|mask|reload)|iptables +-[AIDFXP]|ufw +(enable|allow|deny|delete)|nft +(add|delete|flush))\b' <<< "$code"
    [ "$status" -ne 0 ] || { echo "$f: $output"; return 1; }
  done
}

@test "module.yml: read-only, first Lock out module in every shipped profile but the appliance" {
  grep -q '^risk: read-only' "$MOD/module.yml"
  for p in "$REPO"/profiles/*.profile; do
    name="$(basename "$p" .profile)"
    first="$(tr -d '\r' < "$p" | sed 's/#.*$//' | grep -E '^(lockout|observe|deceive|sustain)\.' | head -n 1)"
    case "$name" in
      appliance) [ "$first" != lockout.inventory ] ;;
      *) [ "$first" = lockout.inventory ] || { echo "$name: first module is $first"; return 1; } ;;
    esac
  done
}

@test "realsystem: a service's real outbound connection is mapped; a loopback or non-loopback client is not; accounts and the service are untouched" {
  [ "${LAB_REALSYSTEM:-}" = 1 ] || skip 'real-system tests run only on CI runners or lab VMs'
  command -v python3 > /dev/null || skip 'python3 is needed to hold the sockets'
  ip="$(hostname -I 2> /dev/null | awk '{print $1}')"
  [ -n "$ip" ] || skip 'this host has no non-loopback address'
  printf 'svc http host.example.test 38101 Welcome\n' > "$LAB_CONFIG_DIR/services"
  printf 'root breakglass\n' > "$LAB_CONFIG_DIR/protected-accounts"
  cat > "$W/hold.py" <<'PY'
import socket, sys, time
ip = sys.argv[1]
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", 38101)); srv.listen(5)       # the scored service's port
dep = socket.socket(); dep.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
dep.bind(("0.0.0.0", 38102)); dep.listen(5)       # a dependency it connects to
out = socket.create_connection((ip, 38102))       # the outbound connection
loop = socket.create_connection(("127.0.0.1", 38101))  # a loopback client
a1, _ = dep.accept(); a2, _ = srv.accept()
open(sys.argv[2], "w").write("ready")
c, peer = srv.accept()                            # a non-loopback client
open(sys.argv[3], "w").write(str(peer[1]))
time.sleep(60)
PY
  python3 "$W/hold.py" "$ip" "$W/ready" "$W/peer" &
  holder=$!
  for _ in $(seq 1 50); do [ -e "$W/ready" ] && break; sleep 0.2; done
  [ -e "$W/ready" ]
  python3 -c 'import socket, sys, time; s = socket.create_connection((sys.argv[1], 38101)); time.sleep(60)' "$ip" &
  client=$!
  for _ in $(seq 1 50); do [ -e "$W/peer" ] && break; sleep 0.2; done
  [ -e "$W/peer" ]
  accounts_before="$(getent passwd; getent group)"
  config_before="$(cat "$LAB_CONFIG_DIR/protected-accounts" "$LAB_CONFIG_DIR/services")"
  run_check 0
  kill "$client" 2> /dev/null || true
  [ "$status" -eq 0 ]
  # The service is still serving, and nothing it was given was changed.
  python3 -c 'import socket, sys; socket.create_connection((sys.argv[1], 38101), 3)' "$ip"
  kill "$holder" 2> /dev/null || true
  [ "$(getent passwd; getent group)" = "$accounts_before" ]
  [ "$(cat "$LAB_CONFIG_DIR/protected-accounts" "$LAB_CONFIG_DIR/services")" = "$config_before" ]
  grep -E "^svc $ip tcp 38102 python" "$W/state/inventory/deps"
  run grep -q ' 127\.' "$W/state/inventory/deps"
  [ "$status" -ne 0 ]
  # The address that connected in is not a dependency (its port is the
  # client's, not one the service uses). The client here may share the
  # service's systemd unit on a runner, so its own socket is not tested.
  run grep -qE " tcp $(cat "$W/peer")( |\$)" "$W/state/inventory/deps"
  [ "$status" -ne 0 ]
}

# ------------------------------------------------ review fixes

@test "systemd holding a socket (pid 1) is never a seed: the other owners are the service" {
  ss="$(inv_parse_ss 'tcp   LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("systemd",pid=1,fd=40),("sshd",pid=800,fd=3))')"
  ps=$'1 0\n800 1\n801 800\n900 1\n901 900'
  map="1${SEP}init.scope"$'\n'"800${SEP}ssh.service"$'\n'"801${SEP}ssh.service"$'\n'"900${SEP}cron.service"
  run inv_service_pids "$ss" 22 tcp "$ps" "$map" ''
  [ "$output" = $'800\n801' ]
  # With no unit map, the seed is still sshd (800) and its children, never process 1's tree.
  run inv_service_pids "$ss" 22 tcp "$ps" '' ''
  [ "$output" = $'800\n801' ]
}

@test "only pid 1 owns the port: the service its socket unit starts, never every process" {
  ss="$(inv_parse_ss 'tcp   LISTEN 0 4096 *:22 *:* users:(("systemd",pid=1,fd=40))')"
  ps=$'1 0\n800 1\n801 800\n900 1\n901 900'
  map="1${SEP}init.scope"$'\n'"800${SEP}ssh.service"$'\n'"801${SEP}ssh.service"$'\n'"900${SEP}cron.service"
  socks=$'0.0.0.0:22   ssh.socket   ssh.service\n[::]:22   ssh.socket   ssh.service\n/run/dbus/system_bus_socket dbus.socket dbus.service'
  run inv_service_pids "$ss" 22 tcp "$ps" "$map" "$socks"
  [ "$output" = $'800\n801' ]
  # Its Activates column may be missing: the socket's name with .service is used.
  run inv_service_pids "$ss" 22 tcp "$ps" "$map" '0.0.0.0:22   ssh.socket'
  [ "$output" = $'800\n801' ]
  # No socket information: nothing, not the whole process tree.
  run inv_service_pids "$ss" 22 tcp "$ps" "$map" ''
  [ -z "$output" ]
  # A socket for another port does not match.
  run inv_service_pids "$ss" 22 tcp "$ps" "$map" '0.0.0.0:80 nginx.socket nginx.service'
  [ -z "$output" ]
  # A process in init.scope other than pid 1 is also skipped.
  ss2="$(inv_parse_ss 'tcp   LISTEN 0 4096 *:22 *:* users:(("init",pid=2,fd=4))')"
  run inv_service_pids "$ss2" 22 tcp "$ps" "2${SEP}init.scope" ''
  [ -z "$output" ]
}

@test "the init scope is read from the cgroup text" {
  inv_cgroup_unit '0::/init.scope'
  [ "$INV_UNIT" = init.scope ]
}

@test "cron: a secret in NAME=value words before the program is never kept" {
  inv_parse_cron cron /etc/cron.d/db 1 $'0 3 * * * root PGPASSWORD=s3cret pg_dump db\n0 4 * * * root FOO="a b c" /usr/bin/env X=s3cret2 /usr/local/bin/backup --now\n'
  [[ "$INV_OUT" == *'"command":"pg_dump"'* ]]
  [[ "$INV_OUT" == *'"command":"/usr/local/bin/backup"'* ]]
  [[ "$INV_OUT" != *s3cret* ]]
  [[ "$INV_OUT" != *'a b c'* ]]
}

@test "the map: a file with no final newline gets one before the first new line" {
  f="$W/deps"
  printf '# header\nweb 192.0.2.99 tcp 389 ldap' > "$f"
  inv_merge_map "$f" 'web 198.51.100.5 tcp 5432 php-fpm'
  grep -qx 'web 192.0.2.99 tcp 389 ldap' "$f"
  grep -qx 'web 198.51.100.5 tcp 5432 php-fpm' "$f"
  [ "$(wc -l < "$f")" -eq 3 ]
  # Nothing new: a file without its newline is left alone.
  printf 'web 192.0.2.98 tcp 389 ldap' > "$W/deps2"
  inv_merge_map "$W/deps2"
  [ "$(cat "$W/deps2")" = 'web 192.0.2.98 tcp 389 ldap' ]
  [ "$(wc -l < "$W/deps2")" -eq 0 ]
}

@test "keys: quoted options with spaces and words like ssh-agent do not confuse the type" {
  inv_parse_authkeys alice /home/alice/.ssh/authorized_keys $'command="exec ssh-agent bash" ssh-ed25519 dGVzdGtleWJsb2I= c\nfrom="10.0.0.0/8",no-pty,environment="X=a b" sk-ssh-ed25519@openssh.com dGVzdGtleWJsb2I= second key\n'
  [ "${INV_COUNT[key]}" -eq 2 ]
  [[ "$INV_OUT" == *'"type":"ssh-ed25519","fingerprint":"SHA256:IZO8V5UocbGYVwglouCMXzRBM68lWPPjxWEnkyZ1uNc","comment":"c"'* ]]
  [[ "$INV_OUT" == *'"type":"sk-ssh-ed25519@openssh.com"'*'"comment":"second key"'* ]]
  [[ "$INV_OUT" != *dGVzdGtleWJsb2I* ]]
  [[ "$INV_OUT" != *ssh-agent* ]]
}

@test "ss: a zone id after the brackets is dropped" {
  run inv_parse_ss 'udp   UNCONN 0 0 [fe80::1]%eth0:546 [::]:* users:(("dhclient",pid=900,fd=5))
udp   UNCONN 0 0 fe80::2%eth1:547 [::]:* users:(("dhcpd",pid=901,fd=5))'
  [[ "${lines[0]}" == "udp${SEP}UNCONN${SEP}fe80::1${SEP}546${SEP}::${SEP}*${SEP}900${SEP}dhclient" ]]
  [[ "${lines[1]}" == "udp${SEP}UNCONN${SEP}fe80::2${SEP}547${SEP}::${SEP}*${SEP}901${SEP}dhcpd" ]]
}

@test "a few thousand sockets are recorded in seconds" {
  # Timed in a fresh shell: bats traces every command in its own, which would
  # measure the test harness and not the module.
  cat > "$W/perf.sh" <<'PERF'
source "$1/core/lib.sh"
source "$1/phases/lockout/modules/inventory/inventory.sh"
ss="$(awk 'BEGIN { for (n = 1; n <= 4000; n++) printf "tcp ESTAB 0 0 192.0.2.10:%d 198.51.100.%d:443 users:((\"proc%d\",pid=%d,fd=5))\n", 10000 + n, n % 250 + 1, n % 50, 1000 + n % 300
  print "tcp LISTEN 0 128 0.0.0.0:80 0.0.0.0:* users:((\"web\",pid=1000,fd=6))" }')"
start="$(date +%s%N)"
INV_SS="$(inv_parse_ss "$ss")"
INV_UNITS=''
inv_record_sockets
ports="$(inv_listen_ports "$INV_SS")"
out="$(inv_outbound "$INV_SS" "$(seq 1000 1299)" "$ports")"
end="$(date +%s%N)"
echo "ms=$(( (end - start) / 1000000 )) connections=${INV_COUNT[connection]} listeners=${INV_COUNT[listener]} mapped=$(printf '%s\n' "$out" | wc -l)"
PERF
  run bash "$W/perf.sh" "$REPO"
  [ "$status" -eq 0 ]
  echo "# 4001 sockets: parsed, recorded and mapped: $output" >&3
  [[ "$output" == *" connections=4000 listeners=1 mapped=250" ]]
  ms="${output#ms=}"; ms="${ms%% *}"
  [ "$ms" -lt 20000 ]
}

@test "the dependency map is written before the slow kinds are collected" {
  printf 'web http www.example.test 80 Welcome\n' > "$LAB_CONFIG_DIR/services"
  mkdir -p "$W/stub"
  printf '#!/bin/sh\nif [ -f "$LAB_STATE_DIR/inventory/deps" ]; then echo yes > "%s"; fi\nexit 0\n' "$W/seen" > "$W/stub/dpkg-query"
  chmod +x "$W/stub/dpkg-query"
  PATH="$W/stub:$PATH" run_check 0
  [ "$status" -eq 0 ]
  [ "$(cat "$W/seen")" = yes ]
  [ "$(find "$W/state/inventory" -name '*.jsonl' | wc -l)" -eq 1 ]
}
