# shellcheck shell=bash
# core/log/log.sh: the core logger (docs/Conventions.md section 6).
# Sourced through core/lib.sh.
#
# Each call appends one JSON object on one line to
#   $LAB_LOG_DIR/<category>/<YYYYMMDD>.jsonl
# In plan mode (LAB_DRY_RUN=1) nothing is written, so a plan leaves no
# trace on the host. Warnings and errors are also printed to stderr.
# Never pass a secret to these functions, not even masked.

readonly LAB_LOG_CATEGORIES='run auth integrity network deception report health'
readonly LAB_LOG_LEVELS='debug info warn error'

# lab_host: the short host name used in logs and the manifest.
lab_host() {
  local h="${HOSTNAME:-$(uname -n)}"
  printf '%s' "${h%%.*}"
}

# lab_now: the current UTC time in ISO 8601.
lab_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# lab_json_str STRING: print STRING as a JSON string literal.
lab_json_str() {
  local s="$1" out='' c i
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  if [[ "$s" =~ [[:cntrl:]] ]]; then
    for ((i = 0; i < ${#s}; i++)); do
      c="${s:i:1}"
      if [[ "$c" =~ [[:cntrl:]] ]]; then
        out+="$(printf '\\u%04x' "'$c")"
      else
        out+="$c"
      fi
    done
    s="$out"
  fi
  printf '"%s"' "$s"
}

# lab_log_to CATEGORY LEVEL EVENT MESSAGE: write one log line.
lab_log_to() {
  local category="$1" level="$2" event="$3" msg="$4" dir line
  lab_in_list "$category" "$LAB_LOG_CATEGORIES" || { printf 'lab_log: unknown category %s\n' "$category" >&2; return 1; }
  lab_in_list "$level" "$LAB_LOG_LEVELS" || { printf 'lab_log: unknown level %s\n' "$level" >&2; return 1; }
  [[ "$event" =~ ^[a-z0-9_]+$ ]] || { printf 'lab_log: event must be a short lower-case name: %s\n' "$event" >&2; return 1; }
  if [[ "$level" == warn || "$level" == error ]]; then
    printf '[%s] %s: %s\n' "${LAB_MODULE_ID:-labyrinth}" "$level" "$msg" >&2
  fi
  [[ "${LAB_DRY_RUN:-1}" == 0 && -n "${LAB_LOG_DIR:-}" ]] || return 0
  dir="$LAB_LOG_DIR/$category"
  mkdir -p "$dir"
  line="{\"ts\":$(lab_json_str "$(lab_now)"),\"host\":$(lab_json_str "$(lab_host)")"
  line+=",\"run\":$(lab_json_str "${LAB_RUN_ID:-}"),\"module\":$(lab_json_str "${LAB_MODULE_ID:-}")"
  line+=",\"entry\":$(lab_json_str "${LAB_ENTRY:-}"),\"level\":$(lab_json_str "$level")"
  line+=",\"event\":$(lab_json_str "$event"),\"msg\":$(lab_json_str "$msg")}"
  printf '%s\n' "$line" >> "$dir/$(date -u +%Y%m%d).jsonl"
}

# lab_log LEVEL EVENT MESSAGE: write to the run category.
lab_log() { lab_log_to run "$@"; }
lab_log_info() { lab_log_to run info "$@"; }
lab_log_warn() { lab_log_to run warn "$@"; }
lab_log_error() { lab_log_to run error "$@"; }
