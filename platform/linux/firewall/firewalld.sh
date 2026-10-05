# shellcheck shell=bash
# platform/linux/firewall/firewalld.sh: the firewalld backend of the firewall
# adapter (design 19, section 5). Sourced by firewall.sh; call it through
# lab_fw.
#
# The snapshot is of the permanent configuration in /etc/firewalld. Changes
# are made both at run time and in the permanent configuration, so a reload
# keeps them.

_lab_fw_firewalld_etc() { printf '%s/etc/firewalld' "${LAB_SYSROOT:-}"; }

# _lab_fw_firewalld_zones: the active zones, or the default zone if no zone
# is active.
_lab_fw_firewalld_zones() {
  local out line found=0
  out="$(firewall-cmd --get-active-zones 2> /dev/null)" || out=''
  while IFS= read -r line; do
    [[ -n "$line" && "$line" != [[:space:]]* ]] || continue
    printf '%s\n' "${line%% *}"
    found=1
  done <<< "$out"
  [[ "$found" == 1 ]] || firewall-cmd --get-default-zone
}

# _lab_fw_firewalld_both ARGS: run a change at run time and in the
# permanent configuration.
_lab_fw_firewalld_both() {
  firewall-cmd "$@" > /dev/null && firewall-cmd --permanent "$@" > /dev/null
}

_lab_fw_firewalld_snapshot() {
  local dir="$1" etc
  etc="$(_lab_fw_firewalld_etc)"
  cp -a -- "$etc" "$dir/firewalld" || return 1
  if [[ "$(firewall-cmd --list-all-zones)" != "$(firewall-cmd --permanent --list-all-zones)" ]]; then
    _lab_fw_err 'warning: firewalld has rules that exist only at run time; a restore reloads the saved permanent configuration and drops them'
  fi
}

# Files added since the snapshot are moved into the snapshot folder, never
# deleted (design 19, section 6).
_lab_fw_firewalld_restore() {
  local dir="$1" etc rel
  etc="$(_lab_fw_firewalld_etc)"
  [[ -d "$dir/firewalld" ]] || return 1
  while IFS= read -r rel; do
    [[ -f "$dir/firewalld/$rel" ]] && continue
    mkdir -p -- "$(dirname -- "$dir/rolled-back/$rel")" || return 1
    mv -- "$etc/$rel" "$dir/rolled-back/$rel" || return 1
  done < <(cd "$etc" && find . -type f | sed 's|^\./||')
  while IFS= read -r rel; do
    mkdir -p -- "$(dirname -- "$etc/$rel")" || return 1
    lab_restore_one "$dir/firewalld/$rel" "$etc/$rel" || return 1
  done < <(cd "$dir/firewalld" && find . -type f | sed 's|^\./||')
  firewall-cmd --reload > /dev/null
}

_lab_fw_firewalld_allow() {
  local proto="$1" port="$2" source="$3" zone family
  family=ipv4
  [[ "$source" == *:* ]] && family=ipv6
  while IFS= read -r zone; do
    [[ -n "$zone" ]] || continue
    if [[ "$source" == any ]]; then
      _lab_fw_firewalld_both --zone="$zone" --add-port="$port/$proto" || return 1
    else
      _lab_fw_firewalld_both --zone="$zone" \
        --add-rich-rule="rule family=\"$family\" source address=\"$source\" port port=\"$port\" protocol=\"$proto\" accept" || return 1
    fi
  done < <(_lab_fw_firewalld_zones)
}

_lab_fw_firewalld_deny_ready() { return 0; }

# firewalld keeps loopback and established connections itself. The zone
# target can only be set in the permanent configuration, so a reload follows.
_lab_fw_firewalld_default_deny_in() {
  local zone
  while IFS= read -r zone; do
    [[ -n "$zone" ]] || continue
    _lab_fw_firewalld_both --zone="$zone" --add-rich-rule='rule protocol value="icmp" accept' || return 1
    _lab_fw_firewalld_both --zone="$zone" --add-rich-rule='rule protocol value="ipv6-icmp" accept' || return 1
    firewall-cmd --permanent --zone="$zone" --set-target=DROP > /dev/null || return 1
  done < <(_lab_fw_firewalld_zones)
  firewall-cmd --reload > /dev/null
}

_lab_fw_firewalld_state() {
  printf '# run time\n'
  firewall-cmd --list-all-zones || return 1
  printf '# permanent\n'
  firewall-cmd --permanent --list-all-zones
}
