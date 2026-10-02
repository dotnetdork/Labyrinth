#!/usr/bin/env bash
# labyrinth.sh: main program for Linux hosts (design 00, section 5).
#
# This build runs plan mode only: for each module of the requested phase in
# the profile, it runs `check` and, when a change is needed, `plan`. Nothing
# is changed. `apply`, the safety gates, logging and the run manifest arrive
# with the core (design 00; docs/Conventions.md).
#
# Exit codes (design 00, section 4); the highest code from any module wins:
#   0 nothing to do, 10 change needed, 20 blocked, 40 error
set -Eeuo pipefail

readonly LAB_VERSION='0.0.0-dev'
readonly PHASES='lockout observe deceive sustain'
readonly MODULE_KEYS='id phase priority platforms risk touches_scored requires outputs spec'
readonly -a REQUIRED_KEYS=(id phase priority platforms risk touches_scored)
readonly RISKS='read-only reversible service-affecting approval manual-only'
readonly PLATFORMS='ubuntu rhel-family windows appliance'

declare -A MOD=()          # fields of the module.yml being read
declare -a PROFILE_IDS=()  # module ids from the profile, in order
ENTRY_RC=0                 # exit code of the last entry point run

usage() {
  cat <<'EOF'
usage: labyrinth.sh [options] <phase>

  <phase>            lockout | observe | deceive | sustain
  --profile NAME     host profile to run (required)
  --root DIR         Labyrinth data root (default /opt/labyrinth)
  --config DIR       run-time configuration (default <root>/etc)
  --apply            not available in this build
  --version          print the version
  -h, --help         this help

Plan mode is the default: modules report what they would change, and
nothing is changed.
EOF
}

die() { printf 'labyrinth: %s\n' "$1" >&2; exit "${2:-40}"; }

# Remove a trailing carriage return and surrounding whitespace.
trim() {
  local s="${1%$'\r'}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# in_list WORD LIST: is WORD one of the space-separated words in LIST?
in_list() {
  case " $2 " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

yml_error() { printf '%s: %s\n' "$1" "$2" >&2; return 1; }

# Parse module.yml, the strict flat subset in docs/Conventions.md
# section 2.1, into MOD. Any other construct is an error.
read_module_yml() {
  local file="$1" n=0 raw line key value
  local re_line='^([a-z_]+):[[:space:]]*(.*)$'
  local re_list='^\[[^][]*\]$'
  local re_yaml='^[&*|>{!%@]'
  MOD=()
  [[ -f "$file" ]] || { yml_error "$file" 'missing'; return 1; }
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    n=$((n + 1))
    line="$(trim "$raw")"
    if [[ -z "$line" || "$line" == \#* ]]; then continue; fi
    [[ "$line" =~ $re_line ]] || { yml_error "$file:$n" 'not a key: value line'; return 1; }
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    in_list "$key" "$MODULE_KEYS" || { yml_error "$file:$n" "unknown key $key"; return 1; }
    [[ -z "${MOD[$key]+set}" ]] || { yml_error "$file:$n" "duplicate key $key"; return 1; }
    if [[ "$value" == \[* && ! "$value" =~ $re_list ]]; then
      yml_error "$file:$n" 'malformed list'; return 1
    fi
    if [[ "$value" =~ $re_yaml ]]; then
      yml_error "$file:$n" 'YAML construct outside the flat subset'; return 1
    fi
    MOD[$key]="$value"
  done < "$file"
  for key in "${REQUIRED_KEYS[@]}"; do
    [[ -n "${MOD[$key]:-}" ]] || { yml_error "$file" "missing key $key"; return 1; }
  done
}

# Check MOD's values against design 00, section 4.
validate_module() {
  local file="$1" want_id="$2" want_phase="$3" p
  local -a list=()
  local re_list='^\[(.*)\]$'
  [[ "${MOD[id]}" == "$want_id" ]] || { yml_error "$file" "id ${MOD[id]} does not match $want_id"; return 1; }
  [[ "${MOD[phase]}" == "$want_phase" ]] || { yml_error "$file" "phase ${MOD[phase]} does not match $want_phase"; return 1; }
  [[ "${MOD[priority]}" =~ ^P[0-3]$ ]] || { yml_error "$file" 'priority must be P0 to P3'; return 1; }
  in_list "${MOD[risk]}" "$RISKS" || { yml_error "$file" "unknown risk ${MOD[risk]}"; return 1; }
  in_list "${MOD[touches_scored]}" 'true false' || { yml_error "$file" 'touches_scored must be true or false'; return 1; }
  [[ "${MOD[platforms]}" =~ $re_list ]] || { yml_error "$file" 'platforms must be a list'; return 1; }
  IFS=', ' read -r -a list <<< "${BASH_REMATCH[1]}"
  (( ${#list[@]} > 0 )) || { yml_error "$file" 'platforms is empty'; return 1; }
  for p in "${list[@]}"; do
    in_list "$p" "$PLATFORMS" || { yml_error "$file" "unknown platform $p"; return 1; }
  done
}

# Read a profile into PROFILE_IDS: one module id per line. A run-time
# profile of the same name replaces the shipped one (Conventions 2.3).
read_profile() {
  local name="$1" file n=0 raw line
  local re_id='^(lockout|observe|deceive|sustain)\.[a-z0-9_-]+$'
  PROFILE_IDS=()
  file="$LAB_CONFIG_DIR/profiles/$name.profile"
  [[ -f "$file" ]] || file="$LAB_ROOT/profiles/$name.profile"
  [[ -f "$file" ]] || die "no profile named $name"
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    n=$((n + 1))
    line="$(trim "${raw%%#*}")"
    if [[ -z "$line" ]]; then continue; fi
    [[ "$line" =~ $re_id ]] || die "$file:$n: not a module id: $line"
    PROFILE_IDS+=("$line")
  done < "$file"
}

new_run_id() {
  local hex
  hex="$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$hex"
}

# Run one entry point as its own process with the contract's environment
# (docs/Conventions.md section 3). Its output goes straight to the
# operator; its exit code is left in ENTRY_RC.
run_entry() {
  local dir="$1" entry="$2" id="$3"
  ENTRY_RC=0
  LAB_MODULE_ID="$id" LAB_DRY_RUN=1 bash "$dir/$entry.sh" || ENTRY_RC=$?
}

# Plan one module and return its contract code.
plan_module() {
  local id="$1" phase="${1%%.*}" name="${1#*.}" dir
  dir="$LAB_ROOT/phases/$phase/modules/$name"
  if [[ ! -d "$dir" ]]; then
    printf '[%s] error: module not found\n' "$id"; return 40
  fi
  if ! read_module_yml "$dir/module.yml" || ! validate_module "$dir/module.yml" "$id" "$phase"; then
    printf '[%s] error: invalid module.yml\n' "$id"; return 40
  fi
  if ! compgen -G "$dir/*.sh" > /dev/null; then
    printf '[%s] skipped: no Linux entry points\n' "$id"; return 0
  fi
  if [[ ! -f "$dir/check.sh" ]]; then
    printf '[%s] error: missing check.sh\n' "$id"; return 40
  fi

  run_entry "$dir" check "$id"
  case "$ENTRY_RC" in
    0)  printf '[%s] check: nothing to do\n' "$id"; return 0 ;;
    10) ;;
    20) printf '[%s] check: blocked by a safety gate\n' "$id"; return 20 ;;
    *)  printf '[%s] check: error (exit %s)\n' "$id" "$ENTRY_RC"; return 40 ;;
  esac

  if [[ ! -f "$dir/plan.sh" ]]; then
    printf '[%s] error: change needed but plan.sh is missing\n' "$id"; return 40
  fi
  printf '[%s] check: change needed; plan follows\n' "$id"
  run_entry "$dir" plan "$id"
  case "$ENTRY_RC" in
    0|10) return 10 ;;
    20)   printf '[%s] plan: blocked by a safety gate\n' "$id"; return 20 ;;
    *)    printf '[%s] plan: error (exit %s)\n' "$id" "$ENTRY_RC"; return 40 ;;
  esac
}

main() {
  local phase='' profile='' root='/opt/labyrinth' config=''
  while (( $# > 0 )); do
    case "$1" in
      --profile) (( $# >= 2 )) || die 'missing value for --profile'; profile="$2"; shift 2 ;;
      --root)    (( $# >= 2 )) || die 'missing value for --root'; root="$2"; shift 2 ;;
      --config)  (( $# >= 2 )) || die 'missing value for --config'; config="$2"; shift 2 ;;
      --apply)   die 'apply is not available in this build; plan mode only' ;;
      --version) printf 'labyrinth %s\n' "$LAB_VERSION"; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      -*)        usage >&2; exit 40 ;;
      *)         [[ -z "$phase" ]] || die "unexpected argument: $1"; phase="$1"; shift ;;
    esac
  done
  [[ -n "$phase" ]] || { usage >&2; exit 40; }
  in_list "$phase" "$PHASES" || die "unknown phase: $phase"
  [[ -n "$profile" ]] || die 'a profile is required (--profile NAME)'
  [[ "$profile" =~ ^[a-z0-9-]+$ ]] || die "invalid profile name: $profile"
  [[ "$root" == /* ]] || die '--root must be an absolute path'

  LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LAB_CONFIG_DIR="${config:-$root/etc}"
  LAB_STATE_DIR="$root/state"
  LAB_LOG_DIR="$root/logs"
  LAB_BACKUP_DIR="$root/backup"
  LAB_RUN_ID="$(new_run_id)"
  export LAB_ROOT LAB_CONFIG_DIR LAB_STATE_DIR LAB_LOG_DIR LAB_BACKUP_DIR LAB_RUN_ID

  read_profile "$profile"

  printf 'labyrinth %s - run %s - %s - profile %s - plan mode\n' \
    "$LAB_VERSION" "$LAB_RUN_ID" "$phase" "$profile"
  local id rc worst=0 count=0
  for id in "${PROFILE_IDS[@]+"${PROFILE_IDS[@]}"}"; do
    if [[ "${id%%.*}" != "$phase" ]]; then continue; fi
    count=$((count + 1))
    rc=0
    plan_module "$id" || rc=$?
    if (( rc > worst )); then worst=$rc; fi
  done
  if (( count == 0 )); then
    printf 'no %s modules in profile %s\n' "$phase" "$profile"
  fi
  printf 'plan finished: exit %d\n' "$worst"
  exit "$worst"
}

main "$@"
