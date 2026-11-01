# shellcheck shell=bash
# inventory.sh: the functions of lockout.inventory (design 08, section 3.1),
# loaded by check.sh and plan.sh. Loading it only defines functions.
#
# The parsers take text and print records, so the tests feed them captured
# output; the functions that read the system (inv_read_*, inv_collect_*) are
# thin. Nothing here changes the host: the only writes are the inventory and
# the dependency map under the state folder, and only when the runner says
# this is a run (LAB_DRY_RUN=0, design 00, section 4).

INV_SEP=$'\037'
INV_OUT=''
INV_MAP_NOTE=''
INV_PASSWD=''
INV_UNITS=''
INV_SS=''
INV_UNIT=''
declare -gA INV_COUNT=()
declare -gA INV_PWSTATE=()
declare -ga INV_NOTES=()
declare -ga INV_MAP_ALL=()
declare -ga INV_MAP_NEW=()

inv_have() { command -v "$1" > /dev/null 2>&1; }

# inv_note TEXT: a thing that could not be recorded; check prints it as a
# found: line, and one missing tool never stops the rest.
inv_note() { INV_NOTES+=("$1"); }

# inv_rec KIND [KEY VALUE]...: append one JSON record to the inventory. The
# keys port, pid, uid and gid are numbers; every other value is a string.
inv_rec() {
  local kind="$1" k v line js
  shift
  js="$(lab_json_str "$kind")"
  line="{\"kind\":$js"
  while (( $# >= 2 )); do
    k="$1"; v="$2"; shift 2
    case "$k" in
      port | pid | uid | gid)
        if [[ "$v" =~ ^[0-9]+$ ]]; then line+=",\"$k\":$((10#$v))"; else line+=",\"$k\":null"; fi ;;
      *)
        js="$(lab_json_str "$v")"
        line+=",\"$k\":$js" ;;
    esac
  done
  INV_OUT+="$line}"$'\n'
  INV_COUNT[$kind]=$(( ${INV_COUNT[$kind]:-0} + 1 ))
}

# inv_hash_text TEXT: SHA-256 (hex) of TEXT, or nothing if sha256sum is missing.
inv_hash_text() {
  local h
  if ! inv_have sha256sum; then return 0; fi
  h="$(printf '%s' "$1" | sha256sum)" || return 0
  printf '%s' "${h%% *}"
}

# inv_hash_file FILE: SHA-256 (hex) of a file, or nothing.
inv_hash_file() {
  local h
  if ! inv_have sha256sum || [[ ! -r "$1" ]]; then return 0; fi
  h="$(sha256sum -- "$1" 2> /dev/null)" || return 0
  printf '%s' "${h%% *}"
}

# inv_fingerprint BASE64: an authorized key's fingerprint, SHA256: and the
# unpadded base64 of the digest of the key's blob, as ssh-keygen prints it.
# The key itself is never kept. Prints nothing when the tools are missing.
inv_fingerprint() {
  local hex bin='' i b64
  if ! inv_have base64 || ! inv_have sha256sum; then return 0; fi
  hex="$(printf '%s' "$1" | base64 -d 2> /dev/null | sha256sum 2> /dev/null)" || return 0
  hex="${hex%% *}"
  if (( ${#hex} != 64 )); then return 0; fi
  for ((i = 0; i < 64; i += 2)); do bin+="\\x${hex:i:2}"; done
  b64="$(printf '%b' "$bin" | base64 | tr -d '=\n')"
  printf 'SHA256:%s' "$b64"
}

# ---------------------------------------------------------------- parsers

# inv_parse_passwd TEXT: user records from getent passwd text. INV_PWSTATE
# (name -> set, locked or none) adds the password state, never a hash.
inv_parse_passwd() {
  local name uid gid home shell
  while IFS=: read -r name _ uid gid _ home shell; do
    if [[ -z "$name" ]]; then continue; fi
    inv_rec user name "$name" uid "$uid" gid "$gid" home "$home" shell "$shell" \
      password "${INV_PWSTATE[$name]:-unknown}"
  done <<< "$1"
}

# inv_parse_shadow TEXT: fill INV_PWSTATE from getent shadow text. Only the
# state of the password field is kept: the hash is read and dropped here.
inv_parse_shadow() {
  local name field
  while IFS=: read -r name field _; do
    if [[ -z "$name" ]]; then continue; fi
    case "$field" in
      '') INV_PWSTATE[$name]=none ;;
      '!'* | '*'*) INV_PWSTATE[$name]=locked ;;
      *) INV_PWSTATE[$name]='set' ;;
    esac
  done <<< "$1"
}

# inv_parse_group TEXT: group records from getent group text.
inv_parse_group() {
  local name gid members
  while IFS=: read -r name _ gid members; do
    if [[ -z "$name" ]]; then continue; fi
    inv_rec group name "$name" gid "$gid" members "$members"
  done <<< "$1"
}

# inv_parse_sudoers FILE TEXT: one record per rule line; comments and blank
# lines are skipped, #include and #includedir are kept.
inv_parse_sudoers() {
  local file="$1" line
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -z "$line" ]]; then continue; fi
    if [[ "$line" == '#'* && "$line" != '#include'* ]]; then continue; fi
    inv_rec sudoers file "$file" rule "$line"
  done <<< "$2"
}

# inv_parse_authkeys USER FILE TEXT: one record per authorized key: its type,
# fingerprint and comment. The key's own text is dropped.
inv_parse_authkeys() {
  local user="$1" file="$2" line f type blob comment fp
  local -a words
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    if [[ -z "$line" || "$line" == '#'* ]]; then continue; fi
    read -r -a words <<< "$line"
    type='' blob='' comment=''
    for ((f = 0; f < ${#words[@]}; f++)); do
      if [[ "${words[f]}" =~ ^(ssh-|ecdsa-|sk-|rsa-sha2-) ]]; then
        type="${words[f]}"
        blob="${words[f+1]:-}"
        comment="${words[*]:f+2}"
        break
      fi
    done
    if [[ -z "$type" ]]; then continue; fi
    fp="$(inv_fingerprint "$blob")"
    inv_rec key user "$user" file "$file" type "$type" fingerprint "$fp" comment "$comment"
  done <<< "$3"
}

# inv_parse_ss TEXT: normalize `ss -H -tunap` output to one line per socket
# and process: proto, state, local address, local port, remote address, remote
# port, pid and process name, separated by INV_SEP. A socket with no visible
# process gets an empty pid and name.
inv_parse_ss() {
  printf '%s\n' "$1" | awk '
    function hostport(s,   i, h, p) {
      i = length(s)
      while (i > 0 && substr(s, i, 1) != ":") i--
      h = substr(s, 1, i - 1); p = substr(s, i + 1)
      if (h ~ /^\[.*\]$/) h = substr(h, 2, length(h) - 2)
      sub(/%[^ ]*$/, "", h)
      HP_H = h; HP_P = p
    }
    $1 ~ /^(tcp|udp)/ && NF >= 6 {
      hostport($5); lh = HP_H; lp = HP_P
      hostport($6); rh = HP_H; rp = HP_P
      rest = ""
      for (i = 7; i <= NF; i++) rest = rest (i > 7 ? " " : "") $i
      n = 0
      while (match(rest, /\("[^"]*",pid=[0-9]+/)) {
        t = substr(rest, RSTART + 2, RLENGTH - 2)
        rest = substr(rest, RSTART + RLENGTH)
        name = t; sub(/",pid=.*$/, "", name)
        pid = t; sub(/^.*pid=/, "", pid)
        print substr($1, 1, 3) "\037" $2 "\037" lh "\037" lp "\037" rh "\037" rp "\037" pid "\037" name
        n++
      }
      if (n == 0) print substr($1, 1, 3) "\037" $2 "\037" lh "\037" lp "\037" rh "\037" rp "\037\037"
    }'
}

# inv_is_listener PROTO STATE: does the socket wait for others? A TCP socket
# in LISTEN, or a UDP socket with no peer (UNCONN).
inv_is_listener() {
  case "$1:$2" in
    tcp:LISTEN | udp:UNCONN) return 0 ;;
  esac
  return 1
}

# inv_norm_addr ADDRESS: lower case, with an IPv4-mapped IPv6 address shown
# as plain IPv4.
inv_norm_addr() {
  local a="${1,,}"
  if [[ "$a" =~ ^::ffff:([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then a="${BASH_REMATCH[1]}"; fi
  printf '%s' "$a"
}

# inv_is_local_addr ADDRESS: loopback, or no address at all (wildcard).
inv_is_local_addr() {
  local a
  a="$(inv_norm_addr "$1")"
  case "$a" in
    127.* | ::1 | '' | '*' | 0.0.0.0 | ::) return 0 ;;
  esac
  return 1
}

# inv_cgroup_unit TEXT: set INV_UNIT to the systemd service a process belongs
# to, from its /proc/PID/cgroup text: the last part of the path, when it ends
# in .service. Empty otherwise (a login session, a container, no systemd).
inv_cgroup_unit() {
  local line path=''
  INV_UNIT=''
  while IFS= read -r line; do
    case "$line" in
      *:name=systemd:*) path="${line#*:name=systemd:}"; break ;;
      0::*) path="${line#0::}"; break ;;
    esac
  done <<< "$1"
  path="${path%/}"
  if [[ "${path##*/}" == *.service ]]; then INV_UNIT="${path##*/}"; fi
  return 0
}

# inv_descendants PSTEXT PID...: each PID and every process below it, one per
# line. PSTEXT has "pid ppid" on each line.
inv_descendants() {
  local ps="$1"
  shift
  printf '%s\n' "$ps" | awk -v seeds="$*" '
    NF >= 2 { kid[++n] = $1; par[n] = $2 }
    END {
      m = split(seeds, s, " ")
      for (i = 1; i <= m; i++) inset[s[i]] = 1
      changed = 1
      while (changed) {
        changed = 0
        for (j = 1; j <= n; j++) {
          if (!(kid[j] in inset) && (par[j] in inset)) { inset[kid[j]] = 1; changed = 1 }
        }
      }
      for (p in inset) print p
    }' | sort -n
}

# inv_service_pids SSNORM PORT PROTOS PSTEXT UNITMAP: the processes of the
# scored service that listens on PORT (design 08, section 3.1). SSNORM is the
# output of inv_parse_ss; PROTOS is "tcp", "udp" or "tcp udp"; PSTEXT has
# "pid ppid" per line; UNITMAP has "pid<SEP>unit" per line for the processes
# that belong to a systemd service. For each process listening on the port:
# its systemd unit's every process, else itself and its descendants. Prints
# one pid per line, and nothing when nothing listens on PORT.
inv_service_pids() {
  local ss="$1" port="$2" protos="$3" ps="$4" map="$5"
  local proto state lp pid seen=' ' unit upid uname lpid
  local -a listeners=() out=()
  while IFS="$INV_SEP" read -r proto state _ lp _ _ pid _; do
    if [[ "$lp" != "$port" || -z "$pid" ]]; then continue; fi
    if [[ " $protos " != *" $proto "* ]] || ! inv_is_listener "$proto" "$state"; then continue; fi
    if [[ "$seen" == *" $pid "* ]]; then continue; fi
    seen+="$pid "
    listeners+=("$pid")
  done <<< "$ss"
  for lpid in "${listeners[@]+"${listeners[@]}"}"; do
    unit=''
    while IFS="$INV_SEP" read -r upid uname; do
      if [[ "$upid" == "$lpid" ]]; then unit="$uname"; break; fi
    done <<< "$map"
    if [[ -n "$unit" ]]; then
      while IFS="$INV_SEP" read -r upid uname; do
        if [[ "$uname" == "$unit" ]]; then out+=("$upid"); fi
      done <<< "$map"
    else
      mapfile -t -O "${#out[@]}" out < <(inv_descendants "$ps" "$lpid")
    fi
  done
  if (( ${#out[@]} > 0 )); then printf '%s\n' "${out[@]}" | sort -un; fi
}

# inv_listen_ports SSNORM: the local ports the host listens on, one per line.
inv_listen_ports() {
  local proto state lp
  while IFS="$INV_SEP" read -r proto state _ lp _; do
    if inv_is_listener "$proto" "$state"; then printf '%s\n' "$lp"; fi
  done <<< "$1" | sort -un
}

# inv_outbound SSNORM PIDS LISTENPORTS: the outbound connections of the
# processes in PIDS (one per line), as "address proto port process" lines,
# sorted, without repeats. Outbound means an established TCP connection or a
# connected UDP socket whose remote address is not loopback and whose local
# port is not one the host listens on (design 08, section 3.1).
inv_outbound() {
  local ss="$1" pids ports
  local proto state lp rh rp pid name
  pids=" $(printf '%s' "$2" | tr '\n' ' ') "
  ports=" $(printf '%s' "$3" | tr '\n' ' ') "
  while IFS="$INV_SEP" read -r proto state _ lp rh rp pid name; do
    if [[ -z "$pid" || "$state" != ESTAB ]]; then continue; fi
    if [[ "$pids" != *" $pid "* ]]; then continue; fi
    if [[ "$ports" == *" $lp "* ]]; then continue; fi
    if inv_is_local_addr "$rh" || [[ ! "$rp" =~ ^[0-9]+$ ]]; then continue; fi
    printf '%s %s %s %s\n' "$(inv_norm_addr "$rh")" "$proto" "$((10#$rp))" "${name// /_}"
  done <<< "$ss" | sort -u
}

# inv_merge_map FILE LINE...: add each "service address proto port process"
# line to FILE unless its first four columns are already there. Existing
# lines are never changed or removed. Fills INV_MAP_NEW with what was added.
# With FILE empty it only reports what would be added.
inv_merge_map() {
  local file="$1" line svc addr proto port key
  local -A have=()
  shift
  INV_MAP_NEW=()
  if [[ -n "$file" && -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      read -r svc addr proto port _ <<< "$line"
      if [[ -n "$port" ]]; then have["$svc $addr $proto $port"]=1; fi
    done < "$file"
  fi
  for line in "$@"; do
    read -r svc addr proto port _ <<< "$line"
    key="$svc $addr $proto $port"
    if [[ -n "${have[$key]+x}" ]]; then continue; fi
    have["$key"]=1
    INV_MAP_NEW+=("$line")
  done
  if [[ -z "$file" ]]; then return 0; fi
  if [[ ! -f "$file" ]]; then
    printf '%s\n' '# service  address  proto  port  process' \
      '# Written by lockout.inventory; same columns as outbound-allow. Lines are only ever added.' > "$file"
  fi
  if (( ${#INV_MAP_NEW[@]} > 0 )); then printf '%s
' "${INV_MAP_NEW[@]}" >> "$file"; fi
}

# inv_parse_units FILES UNITS: service records from `systemctl list-unit-files`
# (unit, enabled state) and `systemctl list-units` (unit, load, active, sub).
inv_parse_units() {
  local -A active=() sub=()
  local unit a b c
  while read -r unit _ b c _; do
    if [[ "$unit" == *.service ]]; then active[$unit]="$b"; sub[$unit]="$c"; fi
  done <<< "$2"
  while read -r unit a _; do
    if [[ "$unit" != *.service ]]; then continue; fi
    inv_rec service name "$unit" enabled "$a" active "${active[$unit]:-inactive}" state "${sub[$unit]:-dead}"
  done <<< "$1"
}

# inv_parse_timers TEXT: one task record per line of `systemctl list-timers`
# (the last two columns are the timer unit and the unit it starts).
inv_parse_timers() {
  local line
  local -a words
  while IFS= read -r line; do
    if [[ -z "$line" ]]; then continue; fi
    read -r -a words <<< "$line"
    if (( ${#words[@]} >= 2 )); then
      inv_rec task source timer file "${words[${#words[@]}-2]}" user root schedule timer \
        command "${words[${#words[@]}-1]}" sha256 ''
    fi
  done <<< "$1"
}

# inv_parse_cron SOURCE FILE USERFIELD TEXT: one task record per cron line.
# USERFIELD is 1 for /etc/crontab and /etc/cron.d (a user column follows the
# schedule) and 0 for a user's own crontab, whose name is FILE's basename.
# Only the program is kept, not its arguments, which could hold a secret; a
# hash of the whole line is kept to see changes.
inv_parse_cron() {
  local source="$1" file="$2" userfield="$3" line a b c d e user cmd prog schedule rest h
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    if [[ -z "$line" || "$line" == '#'* || "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then continue; fi
    if [[ "$line" == @* ]]; then
      read -r a rest <<< "$line"
      schedule="$a"
    else
      read -r a b c d e rest <<< "$line"
      schedule="$a $b $c $d $e"
    fi
    user="${file##*/}"
    if (( userfield )); then read -r user cmd <<< "$rest"; else cmd="$rest"; fi
    prog="${cmd%%[[:space:]]*}"
    h="$(inv_hash_text "$line")"
    inv_rec task source "$source" file "$file" user "$user" schedule "$schedule" command "$prog" sha256 "$h"
  done <<< "$4"
}

# inv_parse_packages TEXT: package records from tab-separated name and
# version lines. Written by awk, which is quick for thousands of lines; a
# field with a quote or a control character is cleaned first.
inv_parse_packages() {
  printf '%s\n' "$1" | awk -F'\t' '
    function esc(s) { gsub(/[^[:print:]]/, "", s); gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    NF >= 1 && $1 != "" { printf "{\"kind\":\"package\",\"name\":\"%s\",\"version\":\"%s\"}\n", esc($1), esc($2) }'
}

# ----------------------------------------------------------- system readers

# inv_read_proc_table: "pid ppid" for every process, from /proc.
inv_read_proc_table() {
  local f stat rest pid ppid
  for f in /proc/[0-9]*/stat; do
    pid="${f#/proc/}"; pid="${pid%/stat}"
    stat=''
    IFS= read -r -d '' stat 2> /dev/null < "$f" || [[ -n "$stat" ]] || continue
    rest="${stat##*) }"
    read -r _ ppid _ <<< "$rest"
    printf '%s %s\n' "$pid" "${ppid:-0}"
  done
}

# inv_read_unit_map: "pid<SEP>unit" for every process in a systemd service.
inv_read_unit_map() {
  local f cg pid
  for f in /proc/[0-9]*/cgroup; do
    pid="${f#/proc/}"; pid="${pid%/cgroup}"
    cg=''
    IFS= read -r -d '' cg 2> /dev/null < "$f" || [[ -n "$cg" ]] || continue
    inv_cgroup_unit "$cg"
    if [[ -n "$INV_UNIT" ]]; then printf '%s%s%s\n' "$pid" "$INV_SEP" "$INV_UNIT"; fi
  done
}

# inv_collect_ss: the sockets, normalized; empty with a note when ss is missing.
inv_collect_ss() {
  local raw
  INV_SS=''
  if ! inv_have ss; then
    inv_note 'ss is not installed, so listeners and connections were not recorded'
    return 0
  fi
  if ! raw="$(ss -H -tunap 2> /dev/null)"; then
    inv_note 'ss could not list the sockets, so listeners and connections were not recorded'
    return 0
  fi
  INV_SS="$(inv_parse_ss "$raw")"
}

# inv_record_sockets: listener and connection records from INV_SS.
inv_record_sockets() {
  local proto state lh lp rh rp pid name upid uname seen=' ' key
  local -A units=()
  while IFS="$INV_SEP" read -r upid uname; do
    if [[ -n "$upid" ]]; then units[$upid]="$uname"; fi
  done <<< "$INV_UNITS"
  while IFS="$INV_SEP" read -r proto state lh lp rh rp pid name; do
    if [[ -z "$proto" ]]; then continue; fi
    if inv_is_listener "$proto" "$state"; then
      key="$proto $lh $lp $pid"
      if [[ "$seen" == *" $key "* ]]; then continue; fi
      seen+="$key "
      inv_rec listener protocol "$proto" address "$(inv_norm_addr "$lh")" port "$lp" \
        process "$name" pid "$pid" unit "${pid:+${units[$pid]:-}}"
    else
      inv_rec connection protocol "$proto" state "$state" local_address "$(inv_norm_addr "$lh")" \
        local_port "$lp" remote_address "$(inv_norm_addr "$rh")" remote_port "$rp" process "$name" pid "$pid"
    fi
  done <<< "$INV_SS"
}

inv_collect_accounts() {
  local pw gr sh
  if ! inv_have getent; then
    inv_note 'getent is not installed, so accounts were not recorded'
    return 0
  fi
  if sh="$(getent shadow 2> /dev/null)"; then inv_parse_shadow "$sh"; fi
  pw="$(getent passwd 2> /dev/null)" || pw=''
  gr="$(getent group 2> /dev/null)" || gr=''
  inv_parse_passwd "$pw"
  inv_parse_group "$gr"
  INV_PASSWD="$pw"
}

inv_collect_sudoers() {
  local f txt found=0
  for f in /etc/sudoers /etc/sudoers.d/*; do
    if [[ ! -f "$f" ]]; then continue; fi
    found=1
    if txt="$(cat -- "$f" 2> /dev/null)"; then inv_parse_sudoers "$f" "$txt"; else inv_note "$f cannot be read"; fi
  done
  if (( ! found )); then inv_note 'no sudoers file was found'; fi
}

inv_collect_keys() {
  local name home f txt
  while IFS=: read -r name _ _ _ _ home _; do
    if [[ -z "$home" || ! -d "$home/.ssh" ]]; then continue; fi
    for f in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
      if [[ ! -f "$f" ]]; then continue; fi
      if txt="$(cat -- "$f" 2> /dev/null)"; then inv_parse_authkeys "$name" "$f" "$txt"; else inv_note "$f cannot be read"; fi
    done
  done <<< "$INV_PASSWD"
}

inv_collect_services() {
  local files units timers
  if ! inv_have systemctl; then
    inv_note 'systemctl is not installed, so services and timers were not recorded'
    return 0
  fi
  files="$(systemctl list-unit-files --type=service --no-legend --no-pager 2> /dev/null)" || files=''
  units="$(systemctl list-units --type=service --all --no-legend --no-pager --plain 2> /dev/null)" || units=''
  inv_parse_units "$files" "$units"
  timers="$(systemctl list-timers --all --no-legend --no-pager 2> /dev/null)" || timers=''
  inv_parse_timers "$timers"
}

inv_collect_tasks() {
  local f u txt h
  if [[ -r /etc/crontab ]] && txt="$(cat -- /etc/crontab 2> /dev/null)"; then inv_parse_cron cron /etc/crontab 1 "$txt"; fi
  for f in /etc/cron.d/*; do
    if [[ -f "$f" ]] && txt="$(cat -- "$f" 2> /dev/null)"; then inv_parse_cron cron "$f" 1 "$txt"; fi
  done
  for f in /var/spool/cron/crontabs/* /var/spool/cron/*; do
    if [[ -f "$f" ]] && txt="$(cat -- "$f" 2> /dev/null)"; then inv_parse_cron user-cron "$f" 0 "$txt"; fi
  done
  for u in hourly daily weekly monthly; do
    for f in /etc/cron."$u"/*; do
      if [[ -f "$f" ]]; then
        h="$(inv_hash_file "$f")"
        inv_rec task source "cron.$u" file "$f" user root schedule "$u" command "$f" sha256 "$h"
      fi
    done
  done
}

inv_collect_startup() {
  local f h
  for f in /etc/rc.local /etc/profile.d/* /etc/init.d/*; do
    if [[ -f "$f" ]]; then
      h="$(inv_hash_file "$f")"
      inv_rec startup source file path "$f" sha256 "$h"
    fi
  done
}

inv_collect_packages() {
  local txt='' out n
  if inv_have dpkg-query; then
    txt="$(dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' 2> /dev/null | awk -F'\t' '$3 ~ / installed$/ { print $1 "\t" $2 }')" || txt=''
  elif inv_have rpm; then
    txt="$(rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\n' 2> /dev/null)" || txt=''
  else
    inv_note 'neither dpkg-query nor rpm is installed, so packages were not recorded'
    return 0
  fi
  out="$(inv_parse_packages "$txt")"
  if [[ -n "$out" ]]; then
    INV_OUT+="$out"$'\n'
    n="$(printf '%s\n' "$out" | wc -l)"
    INV_COUNT[package]=$(( ${INV_COUNT[package]:-0} + n ))
  fi
}

# inv_rule_lines TOOL TEXT: one firewall record per non-empty line.
inv_rule_lines() {
  local tool="$1" line
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    if [[ -n "$line" ]]; then inv_rec firewall tool "$tool" rule "$line"; fi
  done <<< "$2"
}

# inv_collect_firewall: the rules of every firewall tool that is installed,
# listed read-only.
inv_collect_firewall() {
  local txt tool got=0
  if inv_have nft && txt="$(nft list ruleset 2> /dev/null)"; then inv_rule_lines nft "$txt"; got=1; fi
  for tool in iptables ip6tables; do
    if inv_have "$tool" && txt="$("$tool" -S 2> /dev/null)"; then inv_rule_lines "$tool" "$txt"; got=1; fi
  done
  if inv_have ufw && txt="$(ufw status 2> /dev/null)"; then inv_rule_lines ufw "$txt"; got=1; fi
  if inv_have firewall-cmd && txt="$(firewall-cmd --list-all 2> /dev/null)"; then inv_rule_lines firewall-cmd "$txt"; got=1; fi
  if (( ! got )); then
    inv_note 'no firewall tool could be read (it may need root), so firewall rules were not recorded'
  fi
}

# inv_collect_all: fill INV_OUT with the whole inventory.
inv_collect_all() {
  INV_OUT=''
  INV_COUNT=()
  INV_NOTES=()
  inv_collect_accounts
  inv_collect_sudoers
  inv_collect_keys
  INV_UNITS="$(inv_read_unit_map)"
  inv_collect_ss
  inv_record_sockets
  inv_collect_services
  inv_collect_tasks
  inv_collect_startup
  inv_collect_packages
  inv_collect_firewall
}

# inv_build_map: INV_MAP_ALL, the "service address proto port process" line
# of every outbound connection a scored service has open now.
inv_build_map() {
  local i rc=0 protos pids lines ps ports line
  INV_MAP_ALL=()
  INV_MAP_NOTE=''
  lab_services_load 2> /dev/null || rc=$?
  if (( rc == 1 )); then
    INV_MAP_NOTE='the services file could not be read, so there is no dependency map'
    return 0
  fi
  if (( rc != 0 )); then
    INV_MAP_NOTE='there is no services file, so there is no dependency map'
    return 0
  fi
  ps="$(inv_read_proc_table)"
  ports="$(inv_listen_ports "$INV_SS")"
  for ((i = 0; i < ${#LAB_SVC_NAME[@]}; i++)); do
    protos=tcp
    if [[ "${LAB_SVC_PROTO[i]}" == dns ]]; then protos='tcp udp'; fi
    pids="$(inv_service_pids "$INV_SS" "${LAB_SVC_PORT[i]}" "$protos" "$ps" "$INV_UNITS")"
    if [[ -z "$pids" ]]; then continue; fi
    lines="$(inv_outbound "$INV_SS" "$pids" "$ports")"
    while IFS= read -r line; do
      if [[ -n "$line" ]]; then INV_MAP_ALL+=("${LAB_SVC_NAME[i]} $line"); fi
    done <<< "$lines"
  done
}

# inv_say_found: the operator's found: lines (docs/Conventions.md section 3.2).
inv_say_found() {
  local kind out='' n
  for kind in user group sudoers key listener service task startup package firewall connection; do
    n="${INV_COUNT[$kind]:-0}"
    out+="${out:+, }$n $kind"
  done
  printf 'found: %s\n' "$out"
  for n in "${INV_NOTES[@]+"${INV_NOTES[@]}"}"; do printf 'found: note: %s\n' "$n"; done
  if [[ -n "$INV_MAP_NOTE" ]]; then printf 'found: note: %s\n' "$INV_MAP_NOTE"; fi
  for n in "${INV_MAP_ALL[@]+"${INV_MAP_ALL[@]}"}"; do printf 'found: dependency: %s\n' "$n"; done
}

# inv_write: write the inventory file and merge the map (a run only). Prints
# did: lines. Returns 1 when the state folder cannot be written.
inv_write() {
  local dir="$LAB_STATE_DIR/inventory" stamp file n=1
  umask 077
  mkdir -p -- "$dir" || return 1
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  file="$dir/$stamp.jsonl"
  while [[ -e "$file" ]]; do n=$((n + 1)); file="$dir/$stamp-$n.jsonl"; done
  printf '%s' "$INV_OUT" > "$file" || return 1
  printf 'did: wrote the inventory to %s\n' "$file"
  if [[ -n "$INV_MAP_NOTE" ]]; then return 0; fi
  inv_merge_map "$dir/deps" "${INV_MAP_ALL[@]+"${INV_MAP_ALL[@]}"}" || return 1
  printf 'did: added %d line(s) to the dependency map %s\n' "${#INV_MAP_NEW[@]}" "$dir/deps"
}
