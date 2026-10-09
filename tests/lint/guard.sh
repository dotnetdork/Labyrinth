#!/usr/bin/env bash
# guard.sh: static check that Labyrinth code makes no outside calls and takes
# no blanket actions (Rules 5.6.4 and 5.6.5; design 08, section 4.5). The
# 'install' rules keep installs in one place: only the packages module and the
# core download helper may install, with an allow comment naming design 20.
#
# Usage: tests/lint/guard.sh [path ...]
#   With no paths, scans the code directories of the repository.
#   Exit 0: clean. Exit 1: findings. Exit 2: usage error.
#
# A legitimate match is allowed by a comment on the same line:
#   # lab-guard: allow <rule> -- <reason>
# See docs/Conventions.md, section 8.
set -Eeuo pipefail

# rule id, extended regular expression, message
RULES=(
  'network'   '(^|[^[:alnum:]_-])(curl|wget|ncat|netcat|socat)([^[:alnum:]_-]|$)'      'network client'
  'network'   '(^|[^[:alnum:]_-])nc[[:space:]]'                                         'netcat'
  'network'   '/dev/(tcp|udp)/'                                                         'bash network socket'
  'network'   'Invoke-WebRequest|Invoke-RestMethod|Start-BitsTransfer|Net\.WebClient|Net\.Http\.HttpClient|Net\.Sockets\.TcpClient' 'PowerShell network call'
  'install'   '(^|[^[:alnum:]_-])(apt|apt-get|dnf|yum|zypper|pip|pip3|npm|gem)[[:space:]].*install' 'package install'
  'install'   'Install-Module|Install-Package|Install-Script|Save-Module|Add-WindowsCapability|Install-WindowsFeature' 'PowerShell install'
  'install'   'git[[:space:]]+(clone|pull|fetch)'                                       'git download'
  'shells'    '(^|[^[:alnum:]_-])chsh([^[:alnum:]_-]|$)|usermod[[:space:]](.*[[:space:]])?(-s|--shell)[[:space:]]' 'changing login shells'
  'delete'    '(^|[^[:alnum:]_-])userdel([^[:alnum:]_-]|$)|Remove-LocalUser|Remove-ADUser' 'deleting accounts'
  'reboot'    '(^|[^[:alnum:]_-])(shutdown|reboot|poweroff|halt)([^[:alnum:]_-]|$)|Restart-Computer|Stop-Computer' 'reboot or shutdown'
  'blanket'   'Get-(Local|AD)User[^|]*\|.*(Disable-(Local|AD)User|Set-ADUser|Set-LocalUser)' 'acting on every account'
  'blanket'   '(iptables|ip6tables)[[:space:]]+(-F|--flush)|nft[[:space:]]+flush[[:space:]]+ruleset|(^|[^[:alnum:]_-])killall([^[:alnum:]_-]|$)|pkill[[:space:]].*-u' 'flushing or killing everything'
  'exec'      '(^|[^[:alnum:]_-])eval([^[:alnum:]_-]|$)|Invoke-Expression|(^|[^[:alnum:]_-])iex([^[:alnum:]_-]|$)' 'executing built-up strings'
)

usage() { echo "usage: $0 [path ...]" >&2; exit 2; }

repo_root() { cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd; }

collect_files() {
  local p
  for p in "$@"; do
    if [[ -f "$p" ]]; then
      printf '%s\n' "$p"
    elif [[ -d "$p" ]]; then
      find "$p" -type f \( -name '*.sh' -o -name '*.ps1' -o -name '*.psm1' -o -name '*.psd1' \) \
        -not -path '*/vendor/*' -not -path '*/.git/*' -print
    fi
  done
}

# Is this line a full-line comment in bash or PowerShell?
is_comment() { [[ "$1" =~ ^[[:space:]]*# ]]; }

main() {
  local -a targets files
  if (( $# == 0 )); then
    local root; root="$(repo_root)"
    targets=()
    local d
    for d in labyrinth.sh labyrinth.ps1 core phases platform report; do
      [[ -e "$root/$d" ]] && targets+=("$root/$d")
    done
  else
    [[ "$1" == -* ]] && usage
    targets=("$@")
  fi
  (( ${#targets[@]} == 0 )) && { echo "guard: nothing to scan"; exit 0; }
  # Checked here because a failure inside the process substitution below
  # would not change this script's exit code.
  local t
  for t in "${targets[@]}"; do
    [[ -e "$t" ]] || { echo "guard: no such path: $t" >&2; exit 2; }
  done

  mapfile -t files < <(collect_files "${targets[@]}")
  local findings=0 f n line i id re msg allow
  for f in "${files[@]}"; do
    n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      n=$((n + 1))
      line="${line%$'\r'}"
      is_comment "$line" && continue
      # A malformed allow comment is itself a finding.
      if [[ "$line" == *"lab-guard:"* ]] && ! [[ "$line" =~ lab-guard:\ allow\ [a-z]+\ --\ [^[:space:]] ]]; then
        printf '%s:%d: [guard] malformed lab-guard comment (need: lab-guard: allow <rule> -- <reason>)\n' "$f" "$n"
        findings=$((findings + 1))
        continue
      fi
      for (( i = 0; i < ${#RULES[@]}; i += 3 )); do
        id="${RULES[i]}"; re="${RULES[i+1]}"; msg="${RULES[i+2]}"
        # Only the code part before an allow comment is checked.
        if [[ "${line%%lab-guard:*}" =~ $re ]]; then
          allow="lab-guard: allow $id -- "
          if [[ "$line" == *"$allow"* ]]; then
            continue
          fi
          printf '%s:%d: [%s] %s\n' "$f" "$n" "$id" "$msg"
          findings=$((findings + 1))
        fi
      done
    done < "$f"
  done

  if (( findings > 0 )); then
    echo "guard: $findings finding(s). Fix them, or add '# lab-guard: allow <rule> -- <reason>' where the use is legitimate." >&2
    exit 1
  fi
  echo "guard: ${#files[@]} file(s) clean"
}

main "$@"
