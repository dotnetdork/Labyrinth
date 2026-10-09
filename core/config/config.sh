# shellcheck shell=bash
# core/config/config.sh: readers for the run-time configuration
# (docs/Conventions.md section 2.2). Sourced through core/lib.sh.
#
# Configuration is data: every file is parsed line by line and never
# sourced. Comments after '#' are removed, whitespace is trimmed and blank
# lines are skipped. A line that does not match its file's format is
# rejected with the file name and line number.
#
# Readers return 0 when the file loaded, 1 when it is malformed (the caller
# treats this as an error, exit 40) and 2 when it is missing or holds no
# entries (the caller decides whether that blocks the run, exit 20).
# Results are kept in globals, because bash 4.2 has no namerefs.

readonly LAB_ACCOUNT_CLASSES='official scoring employee operator breakglass service builtin'
readonly LAB_PROBE_PROTOS='http https dns smtp pop3 ftp tcp'
readonly LAB_HOST_PLATFORMS='ubuntu rhel-family windows appliance'

declare -ga LAB_CFG_LINES=() LAB_CFG_NOS=()
declare -gA LAB_EVENT=()
declare -gA LAB_PROTECTED=()
declare -ga LAB_ADDRS=()
declare -ga LAB_PRE_RULES=()
declare -ga LAB_SVC_NAME=() LAB_SVC_PROTO=() LAB_SVC_HOST=() LAB_SVC_PORT=() LAB_SVC_EXPECT=()
LAB_HOST_GROUP='' LAB_HOST_PROFILE='' LAB_HOST_PLATFORM=''

# lab_trim STRING: print STRING without a trailing carriage return or
# surrounding whitespace.
lab_trim() {
  local s="${1%$'\r'}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# lab_in_list WORD LIST: is WORD one of the space-separated words in LIST?
lab_in_list() {
  case " $2 " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

lab_cfg_error() { printf '%s:%s: %s\n' "$1" "$2" "$3" >&2; return 1; }

# lab_config_lines FILE: load the data lines of FILE into LAB_CFG_LINES,
# with their line numbers in LAB_CFG_NOS. Returns 1 if FILE cannot be read,
# so an unreadable file is never taken for an empty one.
lab_config_lines() {
  local file="$1" raw line n=0
  LAB_CFG_LINES=()
  LAB_CFG_NOS=()
  if [[ ! -r "$file" ]]; then
    printf '%s: cannot be read; it needs root\n' "$file" >&2
    return 1
  fi
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    n=$((n + 1))
    line="$(lab_trim "${raw%%#*}")"
    if [[ -n "$line" ]]; then
      LAB_CFG_LINES+=("$line")
      LAB_CFG_NOS+=("$n")
    fi
  done < "$file"
}

# lab_event_load: read event.conf (KEY=value) into LAB_EVENT. The file is
# optional; the settings the core uses have defaults and are range-checked.
lab_event_load() {
  local file="$LAB_CONFIG_DIR/event.conf" i line
  LAB_EVENT=([REVERT_MINUTES]=5 [RING_MAX_HOSTS]=3 [PROBE_TIMEOUT]=5)
  [[ -f "$file" ]] || return 0
  lab_config_lines "$file" || return 1
  for ((i = 0; i < ${#LAB_CFG_LINES[@]}; i++)); do
    line="${LAB_CFG_LINES[i]}"
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] \
      || { lab_cfg_error "$file" "${LAB_CFG_NOS[i]}" 'expected KEY=value'; return 1; }
    LAB_EVENT[${BASH_REMATCH[1]}]="$(lab_trim "${BASH_REMATCH[2]}")"
  done
  lab_event_int "$file" REVERT_MINUTES 1 60 \
    && lab_event_int "$file" RING_MAX_HOSTS 1 99 \
    && lab_event_int "$file" PROBE_TIMEOUT 1 60
}

# lab_event_int FILE KEY MIN MAX: check that a setting is a whole number in range.
lab_event_int() {
  local v="${LAB_EVENT[$2]}"
  if [[ "$v" =~ ^[0-9]{1,3}$ ]] && (( 10#$v >= $3 && 10#$v <= $4 )); then
    LAB_EVENT[$2]=$((10#$v))
    return 0
  fi
  printf '%s: %s must be a whole number from %s to %s\n' "$1" "$2" "$3" "$4" >&2
  return 1
}

# lab_protected_load: read protected-accounts into LAB_PROTECTED
# (account -> class). Each line is "account class"; the account is
# everything before the last word, so a Windows account name may hold
# spaces. Missing or empty: return 2, the protected-set gate fails.
lab_protected_load() {
  local file="$LAB_CONFIG_DIR/protected-accounts" i line name class
  LAB_PROTECTED=()
  if [[ ! -f "$file" ]]; then
    printf 'protected set: %s not found\n' "$file" >&2
    return 2
  fi
  lab_config_lines "$file" || return 1
  for ((i = 0; i < ${#LAB_CFG_LINES[@]}; i++)); do
    line="${LAB_CFG_LINES[i]}"
    [[ "$line" =~ ^(.*[^[:space:]])[[:space:]]+([a-z]+)$ ]] \
      || { lab_cfg_error "$file" "${LAB_CFG_NOS[i]}" 'expected: account class'; return 1; }
    name="${BASH_REMATCH[1]}"
    class="${BASH_REMATCH[2]}"
    lab_in_list "$class" "$LAB_ACCOUNT_CLASSES" \
      || { lab_cfg_error "$file" "${LAB_CFG_NOS[i]}" "unknown class $class"; return 1; }
    if [[ -n "${LAB_PROTECTED[$name]+set}" && "${LAB_PROTECTED[$name]}" != "$class" ]]; then
      lab_cfg_error "$file" "${LAB_CFG_NOS[i]}" "$name is listed with two classes"
      return 1
    fi
    LAB_PROTECTED[$name]="$class"
  done
  if (( ${#LAB_PROTECTED[@]} == 0 )); then
    printf 'protected set: %s is empty\n' "$file" >&2
    return 2
  fi
}

# lab_protected_class ACCOUNT: print the account's class; return 1 if the
# account is not in the protected set.
lab_protected_class() {
  [[ -n "${LAB_PROTECTED[$1]+set}" ]] || return 1
  printf '%s' "${LAB_PROTECTED[$1]}"
}

# lab_addr_valid ADDRESS: is it an IPv4 or IPv6 address, with an optional
# CIDR prefix length?
lab_addr_valid() {
  local a="$1" ip bits='' o
  ip="${a%%/*}"
  [[ "$a" == */* ]] && bits="${a#*/}"
  if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    for o in "${BASH_REMATCH[@]:1}"; do
      (( 10#$o <= 255 )) || return 1
    done
    [[ -z "$bits" ]] || { [[ "$bits" =~ ^[0-9]{1,2}$ ]] && (( 10#$bits <= 32 )); }
  elif _lab_ip6_valid "$ip"; then
    [[ -z "$bits" ]] || { [[ "$bits" =~ ^[0-9]{1,3}$ ]] && (( 10#$bits <= 128 )); }
  else
    return 1
  fi
}

# _lab_ip6_valid ADDRESS: is it an IPv6 address: eight groups of 1 to 4 hex
# digits, or fewer around a single '::', the last two optionally written
# as an IPv4 address?
_lab_ip6_valid() {
  local ip="$1" v4 o a b
  [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
  if [[ "$ip" == *.* ]]; then
    v4="${ip##*:}"
    [[ "$v4" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
      (( 10#$o <= 255 )) || return 1
    done
    ip="${ip%"$v4"}0:0"
  fi
  if [[ "$ip" == *::* ]]; then
    [[ "${ip#*::}" != *::* ]] || return 1
    a="$(_lab_ip6_groups "${ip%%::*}")" || return 1
    b="$(_lab_ip6_groups "${ip#*::}")" || return 1
    [[ $((a + b)) -le 7 ]]
  else
    a="$(_lab_ip6_groups "$ip")" || return 1
    [[ "$a" == 8 ]]
  fi
}

# _lab_ip6_groups PART: print how many hex groups PART (no '::') holds;
# 1 if one is empty or not 1 to 4 hex digits.
_lab_ip6_groups() {
  local IFS=: g n=0
  if [[ -z "$1" ]]; then printf '0\n'; return 0; fi
  [[ "$1" != :* && "$1" != *: ]] || return 1
  for g in $1; do
    [[ "$g" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# lab_addrs_load NAME: read an address list (scoring-allowlist, never-ban)
# from the configuration directory into LAB_ADDRS.
lab_addrs_load() {
  local file="$LAB_CONFIG_DIR/$1" i
  LAB_ADDRS=()
  [[ -f "$file" ]] || return 2
  lab_config_lines "$file" || return 1
  for ((i = 0; i < ${#LAB_CFG_LINES[@]}; i++)); do
    lab_addr_valid "${LAB_CFG_LINES[i]}" \
      || { lab_cfg_error "$file" "${LAB_CFG_NOS[i]}" "not an address or CIDR: ${LAB_CFG_LINES[i]}"; return 1; }
    LAB_ADDRS+=("${LAB_CFG_LINES[i]}")
  done
  (( ${#LAB_ADDRS[@]} > 0 )) || return 2
}

# lab_preapproved_load: read the pre-approval rules (pre-approved) into
# LAB_PRE_RULES, one "module-id category item" per element, where item is
# an item id or '*' for every item of the category (docs/Conventions.md
# section 3.1). Missing or empty: return 2, nothing is pre-approved.
lab_preapproved_load() {
  local file="$LAB_CONFIG_DIR/pre-approved" i
  local re='^((lockout|observe|deceive|sustain)\.[a-z0-9_-]+)[[:space:]]+([a-z0-9-]+)[[:space:]]+([a-z0-9-]+|\*)$'
  LAB_PRE_RULES=()
  [[ -f "$file" ]] || return 2
  lab_config_lines "$file" || return 1
  for ((i = 0; i < ${#LAB_CFG_LINES[@]}; i++)); do
    [[ "${LAB_CFG_LINES[i]}" =~ $re ]] \
      || { lab_cfg_error "$file" "${LAB_CFG_NOS[i]}" 'expected: module-id category item-id (or * for every item)'; return 1; }
    LAB_PRE_RULES+=("${BASH_REMATCH[1]} ${BASH_REMATCH[3]} ${BASH_REMATCH[4]}")
  done
  (( ${#LAB_PRE_RULES[@]} > 0 )) || return 2
}

# lab_services_load: read the scored-service list into the LAB_SVC_* arrays.
# Each line is "name proto host port expect". Missing or empty: return 2,
# because an empty list is one nobody filled in, and a module that touches
# scored services is blocked without one (docs/Conventions.md section 3.1).
lab_services_load() {
  local file="$LAB_CONFIG_DIR/services" i n line
  local re='^([A-Za-z0-9_.-]+)[[:space:]]+([a-z0-9]+)[[:space:]]+([A-Za-z0-9.:_-]+)[[:space:]]+([0-9]{1,5})[[:space:]]+([^[:space:]]+)$'
  LAB_SVC_NAME=() LAB_SVC_PROTO=() LAB_SVC_HOST=() LAB_SVC_PORT=() LAB_SVC_EXPECT=()
  [[ -f "$file" ]] || return 2
  lab_config_lines "$file" || return 1
  for ((i = 0; i < ${#LAB_CFG_LINES[@]}; i++)); do
    line="${LAB_CFG_LINES[i]}"
    n="${LAB_CFG_NOS[i]}"
    [[ "$line" =~ $re ]] || { lab_cfg_error "$file" "$n" 'expected: name proto host port expect'; return 1; }
    # The probes pass these to commands, where a leading '-' reads as an
    # option; a lone '-' is the "no expected text" placeholder.
    if [[ "${BASH_REMATCH[1]}" == -* || "${BASH_REMATCH[3]}" == -* || "${BASH_REMATCH[5]}" == -?* ]]; then
      lab_cfg_error "$file" "$n" "a value may not begin with '-'"
      return 1
    fi
    lab_in_list "${BASH_REMATCH[2]}" "$LAB_PROBE_PROTOS" \
      || { lab_cfg_error "$file" "$n" "unknown protocol ${BASH_REMATCH[2]}"; return 1; }
    (( 10#${BASH_REMATCH[4]} >= 1 && 10#${BASH_REMATCH[4]} <= 65535 )) \
      || { lab_cfg_error "$file" "$n" "port out of range: ${BASH_REMATCH[4]}"; return 1; }
    if [[ "${BASH_REMATCH[2]}" == dns && "${BASH_REMATCH[5]}" != ?*=?* ]]; then
      lab_cfg_error "$file" "$n" 'a dns probe expects name=answer'
      return 1
    fi
    if lab_in_list "${BASH_REMATCH[1]}" "${LAB_SVC_NAME[*]-}"; then
      lab_cfg_error "$file" "$n" "duplicate service name ${BASH_REMATCH[1]}"
      return 1
    fi
    LAB_SVC_NAME+=("${BASH_REMATCH[1]}")
    LAB_SVC_PROTO+=("${BASH_REMATCH[2]}")
    LAB_SVC_HOST+=("${BASH_REMATCH[3]}")
    LAB_SVC_PORT+=("$((10#${BASH_REMATCH[4]}))")
    LAB_SVC_EXPECT+=("${BASH_REMATCH[5]}")
  done
  (( ${#LAB_SVC_NAME[@]} > 0 )) || return 2
}

# lab_host_lookup HOST: find HOST (case-insensitive) in the hosts file and
# set LAB_HOST_GROUP, LAB_HOST_PROFILE and LAB_HOST_PLATFORM. Returns 2 if
# the file is missing or the host is not listed.
# shellcheck disable=SC2034 # the variables it sets are read by the runner and modules
lab_host_lookup() {
  local file="$LAB_CONFIG_DIR/hosts" want="${1,,}" i line
  local re='^([A-Za-z0-9_.-]+)[[:space:]]+(ring[0-9]+|manual)[[:space:]]+([a-z0-9-]+)[[:space:]]+([a-z-]+)$'
  LAB_HOST_GROUP='' LAB_HOST_PROFILE='' LAB_HOST_PLATFORM=''
  [[ -f "$file" ]] || return 2
  lab_config_lines "$file" || return 1
  for ((i = 0; i < ${#LAB_CFG_LINES[@]}; i++)); do
    line="${LAB_CFG_LINES[i]}"
    [[ "$line" =~ $re ]] \
      || { lab_cfg_error "$file" "${LAB_CFG_NOS[i]}" 'expected: host group profile platform'; return 1; }
    lab_in_list "${BASH_REMATCH[4]}" "$LAB_HOST_PLATFORMS" \
      || { lab_cfg_error "$file" "${LAB_CFG_NOS[i]}" "unknown platform ${BASH_REMATCH[4]}"; return 1; }
    if [[ "${BASH_REMATCH[1],,}" == "$want" ]]; then
      LAB_HOST_GROUP="${BASH_REMATCH[2]}"
      LAB_HOST_PROFILE="${BASH_REMATCH[3]}"
      LAB_HOST_PLATFORM="${BASH_REMATCH[4]}"
    fi
  done
  [[ -n "$LAB_HOST_GROUP" ]] || return 2
}
