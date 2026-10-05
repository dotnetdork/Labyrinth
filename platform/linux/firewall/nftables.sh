# shellcheck shell=bash
# platform/linux/firewall/nftables.sh: the nftables backend of the firewall
# adapter (design 19, section 5). Sourced by firewall.sh; call it through
# lab_fw.
#
# Labyrinth's rules live in their own table, inet labyrinth, whose input
# chain runs before the other tables' chains (priority -10). An accept there
# does not override a drop in another table, so the firewall module's plan
# lists such drops for a person.

_LAB_NFT_CHAIN_SPEC='type filter hook input priority -10 ;'

_lab_fw_nftables_snapshot() { nft list ruleset > "$1/ruleset.nft"; }

# The restore file first clears the ruleset, then loads the saved one, so
# nft applies both in one transaction: the host is never left without rules.
_lab_fw_nftables_restore() {
  local dir="$1"
  [[ -f "$dir/ruleset.nft" ]] || return 1
  { printf 'flush ruleset\n'; cat -- "$dir/ruleset.nft"; } > "$dir/restore.nft" || return 1
  nft -f "$dir/restore.nft"
}

# Create the table and chain once; never re-declare an existing chain,
# because that would reset its policy.
_lab_fw_nftables_chain() {
  nft list chain inet labyrinth input > /dev/null 2>&1 && return 0
  nft add table inet labyrinth || return 1
  nft add chain inet labyrinth input "{ $_LAB_NFT_CHAIN_SPEC policy accept ; }"
}

_lab_fw_nftables_allow() {
  local proto="$1" port="$2" source="$3"
  local -a match=()
  case "$(_lab_fw_family "$source")" in
    4) match=(ip saddr "$source") ;;
    6) match=(ip6 saddr "$source") ;;
  esac
  _lab_fw_nftables_chain || return 1
  nft add rule inet labyrinth input ${match[@]+"${match[@]}"} "$proto" dport "$port" accept
}

_lab_fw_nftables_deny_ready() { return 0; }

_lab_fw_nftables_default_deny_in() {
  _lab_fw_nftables_chain || return 1
  if nft list chain inet labyrinth input 2> /dev/null | grep -q 'policy drop'; then
    return 0
  fi
  nft add rule inet labyrinth input iif lo accept || return 1
  nft add rule inet labyrinth input ct state established,related accept || return 1
  nft add rule inet labyrinth input meta l4proto '{ icmp, ipv6-icmp }' accept || return 1
  nft add chain inet labyrinth input "{ $_LAB_NFT_CHAIN_SPEC policy drop ; }"
}

# Packet counters change all the time, so they are left out.
_lab_fw_nftables_state() {
  local out
  out="$(nft list ruleset)" || return 1
  printf '%s\n' "$out" | sed -E 's/counter packets [0-9]+ bytes [0-9]+/counter/'
}
