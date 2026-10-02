# shellcheck shell=bash
# core/probe/probe.sh: scoring-style probes of the services in the run-time
# service list (design 01, section 9; design 13). Sourced through
# core/lib.sh.
#
# A probe only checks that a service answers as expected; it never logs in.
# It uses what the host has: curl, dig or nslookup when present, and bash's
# own TCP support otherwise. When no tool can run a probe, the result is
# "unknown", which is never counted as a regression.
#
# Each probe prints one line: "<result> <detail>", result pass, fail or unknown.

# lab_probe_hostpart HOST: HOST as it goes in a URL (IPv6 in brackets).
lab_probe_hostpart() {
  if [[ "$1" == *:* ]]; then printf '[%s]' "$1"; else printf '%s' "$1"; fi
}

# lab_probe_exchange HOST PORT TIMEOUT REQUEST: connect, send REQUEST and
# print up to 64 KiB of the reply.
lab_probe_exchange() {
  # shellcheck disable=SC2016 # the inner script expands its own arguments
  timeout "$3" bash -c 'exec 3<>"/dev/tcp/$1/$2" || exit 1; printf "%s" "$3" >&3; head -c 65536 <&3 | tr -d "\000"' _ "$1" "$2" "$4"  # lab-guard: allow network -- probe of a listed scored service inside the event network
}

# lab_probe_banner HOST PORT TIMEOUT: connect and print the first line the
# service sends, then say QUIT politely.
lab_probe_banner() {
  # shellcheck disable=SC2016 # the inner script expands its own arguments
  timeout "$3" bash -c 'exec 3<>"/dev/tcp/$1/$2" || exit 1; IFS= read -r line <&3 || exit 3; printf "%s" "$line"; printf "QUIT\r\n" >&3' _ "$1" "$2"  # lab-guard: allow network -- probe of a listed scored service inside the event network
}

# lab_probe_connect HOST PORT TIMEOUT: can a TCP connection be opened?
lab_probe_connect() {
  # shellcheck disable=SC2016 # the inner script expands its own arguments
  timeout "$3" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$2" 2> /dev/null  # lab-guard: allow network -- probe of a listed scored service inside the event network
}

lab_probe_http() {
  local proto="$1" host="$2" port="$3" expect="$4" t="$5" url out code body status
  url="$proto://$(lab_probe_hostpart "$host"):$port/"
  if command -v curl > /dev/null 2>&1; then  # lab-guard: allow network -- only checks whether curl is installed
    if ! out="$(curl -sS -k --max-time "$t" -w '\n%{http_code}' -- "$url" 2>&1 | tr -d '\000')"; then  # lab-guard: allow network -- probe of a listed scored service inside the event network
      printf 'fail %s\n' "$(printf '%s' "$out" | tail -n 1)"
      return 0
    fi
    code="${out##*$'\n'}"
    body="${out%$'\n'*}"
  elif [[ "$proto" == http ]] && command -v timeout > /dev/null 2>&1; then
    if ! out="$(lab_probe_exchange "$host" "$port" "$t" "GET / HTTP/1.0"$'\r\n'"Host: $host"$'\r\n'"Connection: close"$'\r\n\r\n')" || [[ -z "$out" ]]; then
      printf 'fail no HTTP response\n'
      return 0
    fi
    status="${out%%$'\n'*}"
    [[ "$status" =~ ^HTTP/[0-9.]+\ ([0-9]{3}) ]] || { printf 'fail not an HTTP response\n'; return 0; }
    code="${BASH_REMATCH[1]}"
    body="$out"
  elif [[ "$proto" == https ]] && command -v openssl > /dev/null 2>&1 && command -v timeout > /dev/null 2>&1; then
    out="$(printf 'GET / HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n' "$host" \
      | timeout "$t" openssl s_client -quiet -ign_eof -connect "$(lab_probe_hostpart "$host"):$port" -servername "$host" 2> /dev/null \
      | head -c 65536 | tr -d '\000' || true)"
    [[ "$out" =~ ^HTTP/[0-9.]+\ ([0-9]{3}) ]] || { printf 'fail no HTTPS response\n'; return 0; }
    code="${BASH_REMATCH[1]}"
    body="$out"
  else
    printf 'unknown no tool on this host can probe %s\n' "$proto"
    return 0
  fi
  if ! [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
    printf 'fail status %s\n' "$code"
  elif [[ "$expect" != - && "$body" != *"$expect"* ]]; then
    printf 'fail status %s but the expected text is missing\n' "$code"
  else
    printf 'pass status %s\n' "$code"
  fi
}

lab_probe_dns() {
  local host="$1" port="$2" expect="$3" t="$4" qname answer type=A out line
  qname="${expect%%=*}"
  answer="${expect#*=}"
  answer="${answer%.}"
  [[ "$answer" == *:* ]] && type=AAAA
  if command -v dig > /dev/null 2>&1; then
    out="$(dig +short +time="$t" +tries=1 -p "$port" -t "$type" "@$host" "$qname" 2>&1)" \
      || { printf 'fail no answer from %s\n' "$host"; return 0; }
  elif command -v nslookup > /dev/null 2>&1 && command -v timeout > /dev/null 2>&1; then
    out="$(timeout "$t" nslookup -port="$port" -type="$type" "$qname" "$host" 2>&1 \
      | awk '/^Name:/ { f = 1 } f && /^Address/ { print $NF }' || true)"
  else
    printf 'unknown no dig or nslookup on this host\n'
    return 0
  fi
  while IFS= read -r line; do
    line="${line%.}"
    if [[ "${line,,}" == "${answer,,}" ]]; then
      printf 'pass %s answered %s\n' "$qname" "$answer"
      return 0
    fi
  done <<< "$out"
  printf 'fail %s did not answer %s\n' "$qname" "$answer"
}

# lab_probe_banner_check HOST PORT TIMEOUT PREFIX EXPECT
lab_probe_banner_check() {
  local banner
  banner="$(lab_probe_banner "$1" "$2" "$3")" || banner=''
  banner="${banner%$'\r'}"
  if [[ -z "$banner" ]]; then
    printf 'fail no banner\n'
  elif [[ -n "$4" && "$banner" != "$4"* ]]; then
    printf 'fail unexpected banner\n'
  elif [[ "$5" != - && "$banner" != *"$5"* ]]; then
    printf 'fail the banner lacks the expected text\n'
  else
    printf 'pass banner received\n'
  fi
}

# lab_probe_service PROTO HOST PORT EXPECT TIMEOUT: probe one service.
lab_probe_service() {
  local proto="$1" host="$2" port="$3" expect="$4" t="$5"
  case "$proto" in
    http | https) lab_probe_http "$proto" "$host" "$port" "$expect" "$t"; return 0 ;;
    dns) lab_probe_dns "$host" "$port" "$expect" "$t"; return 0 ;;
  esac
  if ! command -v timeout > /dev/null 2>&1; then
    printf 'unknown no timeout command on this host\n'
    return 0
  fi
  case "$proto" in
    smtp) lab_probe_banner_check "$host" "$port" "$t" 220 "$expect" ;;
    pop3) lab_probe_banner_check "$host" "$port" "$t" '+OK' "$expect" ;;
    ftp) lab_probe_banner_check "$host" "$port" "$t" 220 "$expect" ;;
    tcp)
      if [[ "$expect" != - ]]; then
        lab_probe_banner_check "$host" "$port" "$t" '' "$expect"
      elif lab_probe_connect "$host" "$port" "$t"; then
        printf 'pass connected\n'
      else
        printf 'fail no connection\n'
      fi
      ;;
    *) printf 'unknown unsupported protocol %s\n' "$proto" ;;
  esac
}

# lab_probe_all: probe every service in the service list. Prints one line
# per service: "<name> <result> <detail>". Returns 2 if there is no list.
lab_probe_all() {
  local i rc=0 t
  lab_services_load || rc=$?
  (( rc == 0 )) || return "$rc"
  t="${LAB_EVENT[PROBE_TIMEOUT]:-5}"
  for ((i = 0; i < ${#LAB_SVC_NAME[@]}; i++)); do
    printf '%s %s\n' "${LAB_SVC_NAME[i]}" \
      "$(lab_probe_service "${LAB_SVC_PROTO[i]}" "${LAB_SVC_HOST[i]}" "${LAB_SVC_PORT[i]}" "${LAB_SVC_EXPECT[i]}" "$t")"
  done
}

# lab_probe_regressions BEFORE AFTER: given two outputs of lab_probe_all,
# print the services that passed before and fail after.
lab_probe_regressions() {
  local name result
  local -A before=()
  while read -r name result _; do
    [[ -n "$name" ]] && before[$name]="$result"
  done <<< "$1"
  while read -r name result _; do
    if [[ -n "$name" && "$result" == fail && "${before[$name]:-}" == pass ]]; then
      printf '%s\n' "$name"
    fi
  done <<< "$2"
}
