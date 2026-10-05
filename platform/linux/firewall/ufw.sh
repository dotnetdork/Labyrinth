# shellcheck shell=bash
# platform/linux/firewall/ufw.sh: the UFW backend of the firewall adapter
# (design 19, section 5). Sourced by firewall.sh; call it through lab_fw.

_LAB_UFW_FILES='user.rules user6.rules before.rules before6.rules after.rules after6.rules ufw.conf'

_lab_fw_ufw_snapshot() {
  local dir="$1" root="${LAB_SYSROOT:-}" f
  mkdir -p -- "$dir/ufw" || return 1
  for f in $_LAB_UFW_FILES; do
    if [[ -f "$root/etc/ufw/$f" ]]; then
      cp -p -- "$root/etc/ufw/$f" "$dir/ufw/$f" || return 1
    fi
  done
  if [[ -f "$root/etc/default/ufw" ]]; then
    cp -p -- "$root/etc/default/ufw" "$dir/default-ufw" || return 1
  fi
}

_lab_fw_ufw_restore() {
  local dir="$1" root="${LAB_SYSROOT:-}" f
  for f in $_LAB_UFW_FILES; do
    if [[ -f "$dir/ufw/$f" ]]; then
      lab_restore_one "$dir/ufw/$f" "$root/etc/ufw/$f" || return 1
    fi
  done
  if [[ -f "$dir/default-ufw" ]]; then
    lab_restore_one "$dir/default-ufw" "$root/etc/default/ufw" || return 1
  fi
  ufw reload > /dev/null
}

# prepend puts the allow ahead of any deny rule already in the user rules.
_lab_fw_ufw_allow() {
  ufw prepend allow proto "$1" from "$3" to any port "$2" > /dev/null
}

# UFW's before.rules keep loopback, established connections and ICMP. A
# default deny is refused if they no longer accept ICMP echo requests.
_lab_fw_ufw_deny_ready() {
  local f="${LAB_SYSROOT:-}/etc/ufw/before.rules"
  if ! grep -qE -- '^-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT' "$f" 2> /dev/null; then
    _lab_fw_err "default deny is refused: $f no longer accepts ICMP echo requests"
    return 20
  fi
}

_lab_fw_ufw_default_deny_in() { ufw default deny incoming > /dev/null; }

_lab_fw_ufw_state() { ufw status verbose; }
