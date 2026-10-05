# shellcheck shell=bash
# core/platform/platform.sh: the platform facts for Linux (design 19,
# section 3). Sourced through core/lib.sh. Reading a fact changes nothing.
#
# lab_fact NAME prints one fact. A fact is worked out on first use; call
# lab_facts_load once to keep every fact in this shell, because a fact read
# inside $( ) is worked out again each time. Files are read under
# $LAB_SYSROOT when it is set, so tests can supply their own root.

LAB_FACT_NAMES='os_id os_family os_version init pkg_db firewall selinux'

# lab_have TOOL: is TOOL on the path? For the tools Labyrinth must not
# assume, such as jq, python3, curl and dig (design 19, section 3).
lab_have() { command -v "$1" > /dev/null 2>&1; }

# lab_fact NAME: print the fact NAME; exit 2 if there is no such fact.
lab_fact() {
  local var="LAB_FACT_$1"
  case " $LAB_FACT_NAMES " in
    *" $1 "*) ;;
    *) printf 'lab_fact: unknown fact %s\n' "$1" >&2; return 2 ;;
  esac
  if [[ -n "${!var:-}" ]]; then
    printf '%s\n' "${!var}"
  else
    "_lab_fact_$1"
  fi
}

# lab_facts_load: work out every fact once and keep it in this shell.
lab_facts_load() {
  local n
  for n in $LAB_FACT_NAMES; do
    printf -v "LAB_FACT_$n" '%s' "$("_lab_fact_$n")"
  done
}

# lab_facts: print every fact as name=value, one per line.
lab_facts() {
  local n
  for n in $LAB_FACT_NAMES; do
    printf '%s=%s\n' "$n" "$(lab_fact "$n")"
  done
}

# _lab_os_field KEY: print KEY's value from os-release, without quotes.
_lab_os_field() {
  local f="${LAB_SYSROOT:-}/etc/os-release" key val
  [[ -r "$f" ]] || f="${LAB_SYSROOT:-}/usr/lib/os-release"
  [[ -r "$f" ]] || return 1
  while IFS='=' read -r key val || [[ -n "$key" ]]; do
    if [[ "$key" == "$1" ]]; then
      val="${val%$'\r'}"
      val="${val#[\"\']}"
      val="${val%[\"\']}"
      printf '%s\n' "$val"
      return 0
    fi
  done < "$f"
  return 1
}

_lab_fact_os_id() {
  local id
  id="$(_lab_os_field ID)" || id=''
  id="${id,,}"
  printf '%s\n' "${id:-unknown}"
}

_lab_fact_os_version() {
  local v
  v="$(_lab_os_field VERSION_ID)" || v=''
  printf '%s\n' "${v:-unknown}"
}

# The family comes from ID first, then from each word of ID_LIKE.
_lab_fact_os_family() {
  local words w
  words="$(_lab_os_field ID) $(_lab_os_field ID_LIKE)"
  for w in ${words,,}; do
    case "$w" in
      debian | ubuntu) printf 'debian\n'; return 0 ;;
      rhel | fedora | centos | rocky | ol | almalinux) printf 'rhel\n'; return 0 ;;
    esac
  done
  printf 'unknown\n'
}

_lab_fact_init() {
  if [[ -d "${LAB_SYSROOT:-}/run/systemd/system" ]]; then
    printf 'systemd\n'
  else
    printf 'other\n'
  fi
}

_lab_fact_pkg_db() {
  case "$(lab_fact os_family)" in
    debian) if lab_have dpkg-query; then printf 'dpkg\n'; return 0; fi ;;
    rhel) if lab_have rpm; then printf 'rpm\n'; return 0; fi ;;
  esac
  printf 'none\n'
}

_lab_fact_selinux() {
  local mode
  if ! lab_have getenforce; then printf 'absent\n'; return 0; fi
  mode="$(getenforce 2> /dev/null)" || mode=''
  mode="${mode,,}"
  case "$mode" in
    enforcing | permissive | disabled) printf '%s\n' "$mode" ;;
    *) printf 'absent\n' ;;
  esac
}

# _lab_nft_own_tables TABLES: does the output of 'nft list tables' hold a
# table that iptables-nft (used by UFW and Docker) or firewalld did not make?
_lab_nft_own_tables() {
  local word family name
  while read -r word family name; do
    [[ "$word" == table ]] || continue
    case "$name" in
      filter | nat | mangle | raw | security) [[ "$family" == inet ]] && return 0 ;;
      firewalld) ;;
      *) return 0 ;;
    esac
  done <<< "$1"
  return 1
}

# _lab_iptables_has_rules RULES: does the output of 'iptables -S' hold
# anything but the built-in chains' default ACCEPT policies?
_lab_iptables_has_rules() {
  local a _ c
  while read -r a _ c; do
    [[ -z "$a" || "$a $c" == '-P ACCEPT' ]] || return 0
  done <<< "$1"
  return 1
}

# The active firewall (design 19, section 3.1): ufw, firewalld, nftables,
# iptables, none, conflict, or unknown when a check could not run.
_lab_fact_firewall() {
  local out count=0 found='' unknown=0
  if lab_have ufw; then
    if out="$(ufw status 2> /dev/null)"; then
      if [[ "$out" == *'Status: active'* ]]; then count=$((count + 1)); found=ufw; fi
    else
      unknown=1
    fi
  fi
  if lab_have firewall-cmd; then
    out="$(firewall-cmd --state 2> /dev/null)" || out=''
    if [[ "$out" == running ]]; then count=$((count + 1)); found=firewalld; fi
  fi
  if lab_have nft; then
    if lab_have systemctl && systemctl is-active --quiet nftables 2> /dev/null; then
      count=$((count + 1)); found=nftables
    elif out="$(nft list tables 2> /dev/null)"; then
      if _lab_nft_own_tables "$out"; then count=$((count + 1)); found=nftables; fi
    else
      unknown=1
    fi
  fi
  # Legacy iptables counts only when nothing else is active: UFW drives
  # iptables itself, so its rules there are not a second firewall.
  if [[ "$count" == 0 && "$unknown" == 0 ]] && lab_have iptables; then
    if out="$(iptables -S 2> /dev/null)"; then
      if _lab_iptables_has_rules "$out"; then count=1; found=iptables; fi
    else
      unknown=1
    fi
  fi
  if [[ "$unknown" == 1 ]]; then
    printf 'unknown\n'
  elif [[ "$count" -gt 1 ]]; then
    printf 'conflict\n'
  else
    printf '%s\n' "${found:-none}"
  fi
}
