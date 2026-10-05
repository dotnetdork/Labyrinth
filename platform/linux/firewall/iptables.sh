# shellcheck shell=bash
# platform/linux/firewall/iptables.sh: the iptables backend of the firewall
# adapter (design 19, section 5). Sourced by firewall.sh; call it through
# lab_fw.
#
# Labyrinth's rules live in their own chain, LAB-INPUT, jumped to from the
# top of INPUT, for IPv4 and, where ip6tables exists, IPv6.

# _lab_fw_iptables_cmds FAMILY: the commands for 4, 6 or both.
_lab_fw_iptables_cmds() {
  case "$1" in
    4 | both) printf 'iptables\n' ;;
  esac
  case "$1" in
    6 | both) if lab_have ip6tables; then printf 'ip6tables\n'; fi ;;
  esac
}

_lab_fw_iptables_snapshot() {
  local dir="$1"
  iptables-save > "$dir/rules.v4" || return 1
  if lab_have ip6tables-save; then
    ip6tables-save > "$dir/rules.v6" || return 1
  fi
}

_lab_fw_iptables_restore() {
  local dir="$1"
  [[ -f "$dir/rules.v4" ]] || return 1
  iptables-restore < "$dir/rules.v4" || return 1
  if [[ -f "$dir/rules.v6" ]]; then
    ip6tables-restore < "$dir/rules.v6" || return 1
  fi
}

# _lab_fw_iptables_add CMD RULE...: append RULE to LAB-INPUT unless present.
_lab_fw_iptables_add() {
  local cmd="$1"
  shift
  "$cmd" -C LAB-INPUT "$@" > /dev/null 2>&1 && return 0
  "$cmd" -A LAB-INPUT "$@"
}

_lab_fw_iptables_chain() {
  local cmd="$1"
  if ! "$cmd" -S LAB-INPUT > /dev/null 2>&1; then
    "$cmd" -N LAB-INPUT || return 1
  fi
  "$cmd" -C INPUT -j LAB-INPUT > /dev/null 2>&1 || "$cmd" -I INPUT 1 -j LAB-INPUT
}

_lab_fw_iptables_allow() {
  local proto="$1" port="$2" source="$3" cmd
  local -a from=()
  [[ "$source" == any ]] || from=(-s "$source")
  while IFS= read -r cmd; do
    _lab_fw_iptables_chain "$cmd" || return 1
    _lab_fw_iptables_add "$cmd" -p "$proto" ${from[@]+"${from[@]}"} --dport "$port" -j ACCEPT || return 1
  done < <(_lab_fw_iptables_cmds "$(_lab_fw_family "$source")")
}

_lab_fw_iptables_deny_ready() { return 0; }

_lab_fw_iptables_default_deny_in() {
  local cmd icmp
  while IFS= read -r cmd; do
    icmp=icmp
    [[ "$cmd" == ip6tables ]] && icmp=ipv6-icmp
    _lab_fw_iptables_chain "$cmd" || return 1
    _lab_fw_iptables_add "$cmd" -i lo -j ACCEPT || return 1
    _lab_fw_iptables_add "$cmd" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || return 1
    _lab_fw_iptables_add "$cmd" -p "$icmp" -j ACCEPT || return 1
    "$cmd" -P INPUT DROP || return 1
  done < <(_lab_fw_iptables_cmds both)
}

# Comments and packet counters change all the time, so they are left out.
_lab_fw_iptables_state() {
  local out
  out="$(iptables-save)" || return 1
  if lab_have ip6tables-save; then
    out+=$'\n'"$(ip6tables-save)" || return 1
  fi
  printf '%s\n' "$out" | sed -E '/^#/d; s/\[[0-9]+:[0-9]+\]/[0:0]/'
}
