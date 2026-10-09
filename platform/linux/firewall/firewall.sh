# shellcheck shell=bash
# platform/linux/firewall/firewall.sh: the Linux firewall adapter (design 19,
# section 5). A module sources it after core/lib.sh:
#
#   source "$LAB_ROOT/platform/linux/firewall/firewall.sh"
#
# and calls lab_fw FUNCTION ARGS. The dispatcher picks the backend from the
# firewall fact and keeps the rules every backend shares: no change without a
# snapshot taken by the same module in the same run, every change recorded
# in the manifest before it is made, and no default deny until every address
# in the scoring allowlist has an allow. The backend files hold only the
# commands that touch their own firewall.
#
# Return codes: 0 done, 20 refused, 30 restore did not give back the saved
# state, 40 error. The reason goes to standard error.

# shellcheck source=platform/linux/firewall/ufw.sh
source "$LAB_ROOT/platform/linux/firewall/ufw.sh"
# shellcheck source=platform/linux/firewall/firewalld.sh
source "$LAB_ROOT/platform/linux/firewall/firewalld.sh"
# shellcheck source=platform/linux/firewall/nftables.sh
source "$LAB_ROOT/platform/linux/firewall/nftables.sh"
# shellcheck source=platform/linux/firewall/iptables.sh
source "$LAB_ROOT/platform/linux/firewall/iptables.sh"

_lab_fw_err() { printf 'firewall: %s\n' "$1" >&2; }

# lab_fw FUNCTION ARGS: snapshot [DIR], restore DIR, allow PROTO PORT SOURCE,
# default_deny_in or state.
lab_fw() {
  local fn="${1:-}" backend
  [[ $# -gt 0 ]] && shift
  case "$fn" in
    restore) _lab_fw_restore "$@"; return ;;
    snapshot | allow | default_deny_in | state) ;;
    *) _lab_fw_err "unknown function: ${fn:-(none)}"; return 40 ;;
  esac
  backend="$(lab_fact firewall)"
  case "$backend" in
    ufw | firewalld | nftables | iptables) ;;
    *)
      _lab_fw_err "the active firewall is '$backend' (design 19, section 3.1); nothing was changed"
      return 20
      ;;
  esac
  "_lab_fw_$fn" "$backend" "$@"
}

# _lab_fw_changing ACTION: refuse a change in plan mode.
_lab_fw_changing() {
  if [[ "${LAB_DRY_RUN:-1}" != 0 ]]; then
    _lab_fw_err "$1 is refused in plan mode"
    return 20
  fi
}

_lab_fw_allows_file() { printf '%s/runs/%s/firewall-allows' "$LAB_STATE_DIR" "$LAB_RUN_ID"; }

# _lab_fw_snapshots: print, newest first, the snapshot folders the current
# module recorded in the current run.
_lab_fw_snapshots() {
  local f line
  f="$(lab_manifest_file)"
  [[ -f "$f" ]] || return 0
  while IFS= read -r line; do
    [[ "$(lab_json_get "$line" module)" == "${LAB_MODULE_ID:-}" ]] || continue
    [[ "$(lab_json_get "$line" action)" == firewall_snapshot ]] || continue
    lab_json_get "$line" backup
    printf '\n'
  done < <(tac -- "$f")
}

_lab_fw_need_snapshot() {
  if [[ -z "$(_lab_fw_snapshots)" ]]; then
    _lab_fw_err "$1 is refused: this module has taken no firewall snapshot in this run"
    return 20
  fi
}

_lab_fw_snapshot() {
  local backend="$1" dir="${2:-}"
  _lab_fw_changing snapshot || return
  if [[ -z "$dir" ]]; then
    dir="$LAB_BACKUP_DIR/$LAB_RUN_ID/$LAB_MODULE_ID/$(lab_manifest_next_seq)-firewall"
  fi
  if [[ -e "$dir" && -n "$(ls -A -- "$dir" 2> /dev/null)" ]]; then
    _lab_fw_err "snapshot folder is not empty: $dir"
    return 40
  fi
  mkdir -p -- "$dir" || return 40
  "_lab_fw_${backend}_snapshot" "$dir" || { _lab_fw_err "the $backend snapshot failed"; return 40; }
  "_lab_fw_${backend}_state" > "$dir/state" || { _lab_fw_err "could not read the $backend rules"; return 40; }
  printf '%s\n' "$backend" > "$dir/backend"
  lab_manifest_record firewall_snapshot "$backend" "$dir" || return 40
  lab_log_info firewall_snapshot "saved the $backend rules to $dir" || true
}

# _lab_fw_restore DIR: uses the backend saved in DIR, not the current fact.
_lab_fw_restore() {
  local dir="${1:-}" backend now
  if [[ -z "$dir" || ! -f "$dir/backend" || ! -f "$dir/state" ]]; then
    _lab_fw_err "not a firewall snapshot: ${dir:-(none)}"
    return 40
  fi
  backend="$(< "$dir/backend")"
  case "$backend" in
    ufw | firewalld | nftables | iptables) ;;
    *) _lab_fw_err "unknown backend in $dir: $backend"; return 40 ;;
  esac
  "_lab_fw_${backend}_restore" "$dir" || { _lab_fw_err "the $backend restore failed from $dir"; return 40; }
  now="$("_lab_fw_${backend}_state")" || { _lab_fw_err "could not read the $backend rules"; return 40; }
  if [[ "$now" != "$(< "$dir/state")" ]]; then
    _lab_fw_err "the $backend rules differ from the snapshot in $dir after the restore"
    return 30
  fi
}

_lab_fw_valid() {
  local proto="$1" port="$2" source="$3"
  [[ "$proto" == tcp || "$proto" == udp ]] || { _lab_fw_err "protocol must be tcp or udp: $proto"; return 40; }
  if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
    _lab_fw_err "not a port: $port"
    return 40
  fi
  [[ "$source" == any ]] || lab_addr_valid "$source" || { _lab_fw_err "not an address or CIDR: $source"; return 40; }
}

_lab_fw_allow() {
  local backend="$1" proto="${2:-}" port="${3:-}" source="${4:-}" f entry
  [[ $# -eq 4 ]] || { _lab_fw_err 'usage: allow PROTO PORT SOURCE'; return 40; }
  _lab_fw_valid "$proto" "$port" "$source" || return
  port="$((10#$port))"
  _lab_fw_changing allow || return
  _lab_fw_need_snapshot allow || return
  f="$(_lab_fw_allows_file)"
  entry="$proto $port $source"
  if [[ -f "$f" ]] && grep -qxF -- "$entry" "$f"; then
    return 0
  fi
  lab_manifest_record firewall_allow "$proto/$port from $source" '' '' "$backend" || return 40
  "_lab_fw_${backend}_allow" "$proto" "$port" "$source" \
    || { _lab_fw_err "the $backend allow for $proto/$port from $source failed"; return 40; }
  mkdir -p -- "${f%/*}"
  printf '%s\n' "$entry" >> "$f"
  lab_log_info firewall_allow "allowed $proto/$port from $source ($backend)" || true
}

# _lab_fw_local_addrs: this host's own addresses, one per line.
_lab_fw_local_addrs() {
  local a
  if lab_have ip; then
    ip -o addr show 2> /dev/null | while read -r _ _ _ a _; do printf '%s\n' "${a%/*}"; done
  elif lab_have hostname; then
    hostname -I 2> /dev/null | tr ' ' '\n'
  fi
}

# _lab_fw_is_local HOST: is HOST, from the services file, this host? By its
# short name, by one of its addresses, or by what HOST resolves to (a simple
# DNS lookup, which rule 5.6.4 allows).
_lab_fw_is_local() {
  local h="${1,,}" mine r
  mine="$(_lab_fw_local_addrs)"
  if lab_addr_valid "$h" && [[ "$h" != */* ]]; then
    grep -qixF -- "$h" <<< "$mine"
    return
  fi
  r="$(lab_host)"
  [[ "${h%%.*}" == "${r,,}" ]] && return 0
  lab_have getent || return 1
  while read -r r _; do
    [[ -n "$r" ]] && grep -qixF -- "$r" <<< "$mine" && return 0
  done < <(getent ahosts "$h" 2> /dev/null)
  return 1
}

# _lab_fw_scoring_covered: may the inbound default be deny? For each scored
# service on this host (services file), every scoring address must have an
# allow on that service's port and transport, or the allow's source must be
# 'any'. With no scored service found on this host, every scoring address
# must still have some allow. The missing pairs go to standard error.
_lab_fw_scoring_covered() {
  local f rc=0 a p n s i missing=''
  local -A have=() seen=()
  local -a need=()
  lab_addrs_load scoring-allowlist > /dev/null 2>&1 || rc=$?
  case "$rc" in
    0) ;;
    2) _lab_fw_err 'default deny is refused: the scoring allowlist is missing or empty'; return 20 ;;
    *) _lab_fw_err 'default deny is refused: the scoring allowlist does not load'; return 40 ;;
  esac
  rc=0
  lab_services_load > /dev/null 2>&1 || rc=$?
  if [[ "$rc" == 1 ]]; then
    _lab_fw_err 'default deny is refused: the services file does not load'
    return 40
  fi
  for ((i = 0; i < ${#LAB_SVC_NAME[@]}; i++)); do
    _lab_fw_is_local "${LAB_SVC_HOST[i]}" || continue
    need+=("tcp ${LAB_SVC_PORT[i]} ${LAB_SVC_NAME[i]}")
    if [[ "${LAB_SVC_PROTO[i]}" == dns ]]; then need+=("udp ${LAB_SVC_PORT[i]} ${LAB_SVC_NAME[i]}"); fi
  done
  f="$(_lab_fw_allows_file)"
  if [[ -f "$f" ]]; then
    while read -r p n s; do
      [[ -n "$s" ]] || continue
      have["$p $n $s"]=1
      seen["$s"]=1
    done < "$f"
  fi
  if (( ${#need[@]} > 0 )); then
    for i in "${need[@]}"; do
      read -r p n s <<< "$i"
      [[ -n "${have[$p $n any]+set}" ]] && continue
      for a in "${LAB_ADDRS[@]}"; do
        [[ -n "${have[$p $n $a]+set}" ]] || missing+=" $s $p/$n from $a;"
      done
    done
    if [[ -n "$missing" ]]; then
      _lab_fw_err "default deny is refused: no allow yet for scored service(s):${missing%;}"
      return 20
    fi
    return 0
  fi
  [[ -n "${seen[any]+set}" ]] && return 0
  for a in "${LAB_ADDRS[@]}"; do
    [[ -n "${seen[$a]+set}" ]] || missing+=" $a"
  done
  if [[ -n "$missing" ]]; then
    _lab_fw_err "default deny is refused: no allow yet from the scoring address(es)$missing"
    return 20
  fi
}

_lab_fw_default_deny_in() {
  local backend="$1"
  _lab_fw_changing default_deny_in || return
  _lab_fw_need_snapshot default_deny_in || return
  _lab_fw_scoring_covered || return
  "_lab_fw_${backend}_deny_ready" || return
  lab_manifest_record firewall_default_deny "$backend" || return 40
  "_lab_fw_${backend}_default_deny_in" || { _lab_fw_err "the $backend default deny failed"; return 40; }
  lab_log_info firewall_default_deny "set the $backend inbound default to deny" || true
}

_lab_fw_state() { "_lab_fw_${1}_state" || return 40; }

# lab_fw_rollback: restore, newest first, every snapshot the current module
# took in the current run. Safe to run repeatedly.
lab_fw_rollback() {
  local dir rc=0 r
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    r=0
    _lab_fw_restore "$dir" || r=$?
    if (( r > rc )); then rc="$r"; fi
  done < <(_lab_fw_snapshots)
  return "$rc"
}

# _lab_fw_family SOURCE: 4, 6 or both (any).
_lab_fw_family() {
  case "$1" in
    any) printf 'both\n' ;;
    *:*) printf '6\n' ;;
    *) printf '4\n' ;;
  esac
}
