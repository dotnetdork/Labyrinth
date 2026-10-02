#!/usr/bin/env bash
# labyrinth.sh: main program for Linux hosts (design 00, section 5;
# docs/Conventions.md section 3.1).
#
#   labyrinth.sh [options] <phase>            plan: show what would change (default)
#   labyrinth.sh [options] --apply <phase>    apply the plan, behind the safety gates
#   labyrinth.sh [options] probe              probe every scored service once
#   labyrinth.sh [options] keep <run>         keep a run's changes: cancel its revert timer
#   labyrinth.sh [options] rollback <run>     undo what a run applied, newest module first
#
# Exit codes (design 00, section 4); the highest code from any module wins:
#   0 nothing to do or success, 10 change needed, 20 blocked,
#   30 verify failed or a scored service regressed, 40 error
set -Eeuo pipefail

readonly LAB_VERSION='0.1.0-dev'
readonly PHASES='lockout observe deceive sustain'
readonly MODULE_KEYS='id phase priority platforms risk touches_scored requires outputs spec'
readonly -a REQUIRED_KEYS=(id phase priority platforms risk touches_scored)
readonly RISKS='read-only reversible service-affecting approval manual-only'
readonly PLATFORMS='ubuntu rhel-family windows appliance'
readonly RE_RUN_ID='^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$'
readonly RE_MODULE_ID='^(lockout|observe|deceive|sustain)\.[a-z0-9_-]+$'

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LAB_ROOT
# shellcheck source=core/lib.sh
source "$LAB_ROOT/core/lib.sh"

declare -A MOD=()          # fields of the module.yml being read
declare -a PROFILE_IDS=()  # module ids from the profile, in order
ENTRY_RC=0                 # exit code of the last entry point run
APPROVED=''                # items approved for the module being applied
PHASE_COUNT=0              # modules of the phase in the profile
DATA_ROOT=''               # the data root (--root)
OPT_PROFILE='' OPT_BREAKGLASS='' OPT_CONFIRM=''
BEFORE=''                  # probe results before the first change
HAVE_SERVICES=0            # 1 when the scored-service list loaded

# The modules of this run, in run order, one array element per module.
declare -a RUN_IDS=() RUN_DIR=() RUN_RISK=() RUN_SCORED=() RUN_REQUIRES=() RUN_RC=() RUN_STATE=()

usage() {
  cat <<'EOF'
usage: labyrinth.sh [options] <phase>
       labyrinth.sh [options] --apply <phase>
       labyrinth.sh [options] probe | keep <run> | rollback <run>

  <phase>            lockout | observe | deceive | sustain
  --profile NAME     host profile (default: this host's line in the hosts file)
  --root DIR         Labyrinth data root (default /opt/labyrinth)
  --config DIR       run-time configuration (default <root>/etc)
  --apply            apply the plan, behind the safety gates
  --breakglass NAME  the break-glass account confirmed at this host's console
  --confirm GROUP    the host's group name, typed to approve the plan
  --version          print the version
  -h, --help         this help

Plan mode is the default: modules report what they would change, and
nothing is changed. After an apply, the revert timer undoes the run unless
it is kept: type keep when asked, or run 'labyrinth.sh keep <run>'.
EOF
}

die() { printf 'labyrinth: %s\n' "$1" >&2; exit "${2:-40}"; }

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
    line="$(lab_trim "$raw")"
    if [[ -z "$line" || "$line" == \#* ]]; then continue; fi
    [[ "$line" =~ $re_line ]] || { yml_error "$file:$n" 'not a key: value line'; return 1; }
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    lab_in_list "$key" "$MODULE_KEYS" || { yml_error "$file:$n" "unknown key $key"; return 1; }
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

# list_items VALUE: print the items of an inline list, space-separated.
list_items() {
  local -a list=()
  local re_list='^\[(.*)\]$'
  [[ "$1" =~ $re_list ]] || return 1
  IFS=', ' read -r -a list <<< "${BASH_REMATCH[1]}"
  printf '%s' "${list[*]-}"
}

# Check MOD's values against design 00, section 4.
validate_module() {
  local file="$1" want_id="$2" want_phase="$3" p items
  [[ "${MOD[id]}" == "$want_id" ]] || { yml_error "$file" "id ${MOD[id]} does not match $want_id"; return 1; }
  [[ "${MOD[phase]}" == "$want_phase" ]] || { yml_error "$file" "phase ${MOD[phase]} does not match $want_phase"; return 1; }
  [[ "${MOD[priority]}" =~ ^P[0-3]$ ]] || { yml_error "$file" 'priority must be P0 to P3'; return 1; }
  lab_in_list "${MOD[risk]}" "$RISKS" || { yml_error "$file" "unknown risk ${MOD[risk]}"; return 1; }
  lab_in_list "${MOD[touches_scored]}" 'true false' || { yml_error "$file" 'touches_scored must be true or false'; return 1; }
  items="$(list_items "${MOD[platforms]}")" || { yml_error "$file" 'platforms must be a list'; return 1; }
  [[ -n "$items" ]] || { yml_error "$file" 'platforms is empty'; return 1; }
  for p in $items; do
    lab_in_list "$p" "$PLATFORMS" || { yml_error "$file" "unknown platform $p"; return 1; }
  done
  if [[ -n "${MOD[requires]:-}" ]]; then
    list_items "${MOD[requires]}" > /dev/null || { yml_error "$file" 'requires must be a list'; return 1; }
  fi
}

# Read a profile into PROFILE_IDS: one module id per line. A run-time
# profile of the same name replaces the shipped one (Conventions 2.3).
read_profile() {
  local name="$1" file n=0 raw line
  PROFILE_IDS=()
  file="$LAB_CONFIG_DIR/profiles/$name.profile"
  [[ -f "$file" ]] || file="$LAB_ROOT/profiles/$name.profile"
  [[ -f "$file" ]] || die "no profile named $name"
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    n=$((n + 1))
    line="$(lab_trim "${raw%%#*}")"
    if [[ -z "$line" ]]; then continue; fi
    [[ "$line" =~ $RE_MODULE_ID ]] || die "$file:$n: not a module id: $line"
    PROFILE_IDS+=("$line")
  done < "$file"
}

new_run_id() {
  local hex
  hex="$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$hex"
}

# run_entry DIR ENTRY ID [DRY_RUN]: run one entry point as its own process
# with the contract's environment (docs/Conventions.md section 3). Its
# output goes straight to the operator; its stdin is empty, so it can
# never take an answer meant for the runner. Its exit code is left in ENTRY_RC.
run_entry() {
  local dir="$1" entry="$2" id="$3" dry="${4:-1}"
  ENTRY_RC=0
  LAB_MODULE_ID="$id" LAB_ENTRY="$entry" LAB_DRY_RUN="$dry" LAB_APPROVED="$APPROVED" \
    bash "$dir/$entry.sh" < /dev/null || ENTRY_RC=$?
}

# load_modules PHASE: read and check every module of PHASE in the profile,
# then put them in run order: by priority, P0 first, and in profile order
# within a priority. Returns 40 if any module is invalid.
load_modules() {
  local phase="$1" id name dir worst=0 p i entry needed
  local -a ids=() dirs=() risks=() scored=() reqs=() prios=()
  PHASE_COUNT=0
  for id in "${PROFILE_IDS[@]+"${PROFILE_IDS[@]}"}"; do
    if [[ "${id%%.*}" != "$phase" ]]; then continue; fi
    PHASE_COUNT=$((PHASE_COUNT + 1))
    name="${id#*.}"
    dir="$LAB_ROOT/phases/$phase/modules/$name"
    if [[ ! -d "$dir" ]]; then
      printf '[%s] error: module not found\n' "$id"; worst=40; continue
    fi
    if ! read_module_yml "$dir/module.yml" || ! validate_module "$dir/module.yml" "$id" "$phase"; then
      printf '[%s] error: invalid module.yml\n' "$id"; worst=40; continue
    fi
    if ! compgen -G "$dir/*.sh" > /dev/null; then
      printf '[%s] skipped: no Linux entry points\n' "$id"; continue
    fi
    needed='check'
    case "${MOD[risk]}" in
      reversible | service-affecting | approval) needed='check apply verify rollback' ;;
    esac
    for entry in $needed; do
      if [[ ! -f "$dir/$entry.sh" ]]; then
        printf '[%s] error: missing %s.sh (needed for risk %s)\n' "$id" "$entry" "${MOD[risk]}"; worst=40; continue 2
      fi
    done
    ids+=("$id"); dirs+=("$dir"); risks+=("${MOD[risk]}"); scored+=("${MOD[touches_scored]}")
    reqs+=("$(list_items "${MOD[requires]:-[]}")"); prios+=("${MOD[priority]}")
  done
  RUN_IDS=() RUN_DIR=() RUN_RISK=() RUN_SCORED=() RUN_REQUIRES=() RUN_RC=() RUN_STATE=()
  for p in P0 P1 P2 P3; do
    for ((i = 0; i < ${#ids[@]}; i++)); do
      if [[ "${prios[i]}" != "$p" ]]; then continue; fi
      RUN_IDS+=("${ids[i]}"); RUN_DIR+=("${dirs[i]}"); RUN_RISK+=("${risks[i]}")
      RUN_SCORED+=("${scored[i]}"); RUN_REQUIRES+=("${reqs[i]}"); RUN_RC+=(0); RUN_STATE+=(planned)
    done
  done
  return "$worst"
}

# plan_one INDEX: run check and, when a change is needed, plan. Returns the
# module's contract code and keeps it in RUN_RC.
plan_one() {
  local i="$1" id dir rc
  id="${RUN_IDS[i]}"; dir="${RUN_DIR[i]}"
  rc=0
  run_entry "$dir" check "$id"
  case "$ENTRY_RC" in
    0)  printf '[%s] check: nothing to do\n' "$id" ;;
    10)
      if [[ ! -f "$dir/plan.sh" ]]; then
        printf '[%s] error: change needed but plan.sh is missing\n' "$id"; rc=40
      else
        printf '[%s] check: change needed; plan follows\n' "$id"
        run_entry "$dir" plan "$id"
        case "$ENTRY_RC" in
          0 | 10) rc=10 ;;
          20)     printf '[%s] plan: blocked by a safety gate\n' "$id"; rc=20 ;;
          *)      printf '[%s] plan: error (exit %s)\n' "$id" "$ENTRY_RC"; rc=40 ;;
        esac
      fi
      ;;
    20) printf '[%s] check: blocked by a safety gate\n' "$id"; rc=20 ;;
    *)  printf '[%s] check: error (exit %s)\n' "$id" "$ENTRY_RC"; rc=40 ;;
  esac
  RUN_RC[i]=$rc
  return "$rc"
}

# plan_all PHASE: load and plan the phase's modules; print the worst code.
plan_all() {
  local phase="$1" worst=0 rc=0 i
  load_modules "$phase" || worst=$?
  for ((i = 0; i < ${#RUN_IDS[@]}; i++)); do
    rc=0
    plan_one "$i" || rc=$?
    if (( rc > worst )); then worst=$rc; fi
  done
  if (( PHASE_COUNT == 0 )); then
    printf 'no %s modules in profile %s\n' "$1" "$OPT_PROFILE"
  fi
  return "$worst"
}

# gate_protected: the protected set must load and hold at least one account
# (design 01, section 7). Plan mode needs it too, because plans that touch
# accounts depend on it.
gate_protected() {
  local rc=0
  lab_protected_load || rc=$?
  case "$rc" in
    0) ;;
    2) die 'the protected set is not loaded, so Labyrinth refuses to run (design 01, section 7)' 20 ;;
    *) die 'the protected set is malformed' 40 ;;
  esac
}

# ask PROMPT: print PROMPT and read one line into ANSWER. Returns 1 on end
# of input.
ANSWER=''
ask() {
  printf '%s' "$1"
  ANSWER=''
  if ! IFS= read -r ANSWER; then
    printf '\n'
    return 1
  fi
  ANSWER="$(lab_trim "$ANSWER")"
}

gate_breakglass() {
  local account=''
  if account="$(lab_breakglass_recorded)"; then
    printf 'break-glass: confirmed earlier for %s\n' "$account"
  else
    if [[ -n "$OPT_BREAKGLASS" ]]; then
      account="$OPT_BREAKGLASS"
    else
      ask 'Break-glass check: log in at this host'"'"'s console with the break-glass account, then type its name: ' \
        || die 'no answer: break-glass not confirmed; nothing was changed' 20
      account="$ANSWER"
    fi
    lab_breakglass_record "$account" || die 'break-glass not confirmed; nothing was changed' 20
    printf 'break-glass: %s confirmed and recorded\n' "$account"
  fi
  BREAKGLASS="$account"
}
BREAKGLASS=''

gate_confirm() {
  local group="$1" typed
  if [[ -n "$OPT_CONFIRM" ]]; then
    typed="$OPT_CONFIRM"
  else
    ask "Type the group name ($group) to apply this plan: " || typed=''
    typed="$ANSWER"
  fi
  [[ "$typed" == "$group" ]] || die 'the plan was not confirmed; nothing was changed' 20
}

# probe_now: probe every scored service; print the results.
probe_now() {
  if (( HAVE_SERVICES )); then
    lab_probe_all
  fi
}

# record_for ID ACTION [TARGET] [NOTE]: a manifest entry on a module's behalf.
record_for() { LAB_MODULE_ID="$1" lab_manifest_record "$2" "${3:-}" '' '' "${4:-}"; }

# rollback_module ID: undo one module's changes in the current run.
rollback_module() {
  local id="$1" phase="${1%%.*}" dir rc=0
  dir="$LAB_ROOT/phases/$phase/modules/${id#*.}"
  if [[ -f "$dir/rollback.sh" ]]; then
    run_entry "$dir" rollback "$id" 0
    rc="$ENTRY_RC"
  else
    LAB_MODULE_ID="$id" lab_restore_files || rc=$?
  fi
  if (( rc == 0 )); then
    record_for "$id" rolled_back
    printf '[%s] rolled back\n' "$id"
    LAB_MODULE_ID="$id" lab_log_warn rolled_back "rolled back"
    return 0
  fi
  printf '[%s] rollback FAILED (exit %s): restore this module by hand from %s\n' "$id" "$rc" "$LAB_BACKUP_DIR/$LAB_RUN_ID/$id"
  LAB_MODULE_ID="$id" lab_log_error rollback_failed "rollback failed with exit $rc"
  return 40
}

# requires_met INDEX: did every module this one requires, in this run, finish?
requires_met() {
  local i="$1" req j
  for req in ${RUN_REQUIRES[i]}; do
    for ((j = 0; j < ${#RUN_IDS[@]}; j++)); do
      if [[ "${RUN_IDS[j]}" == "$req" && "${RUN_STATE[j]}" != 'done' && "${RUN_STATE[j]}" != planned ]]; then
        printf '[%s] blocked: requires %s, which did not complete\n' "${RUN_IDS[i]}" "$req"
        return 1
      fi
    done
  done
}

# apply_one INDEX: apply, verify and probe one module. Returns 0 (done or
# nothing to do), 20 (blocked; continue), or 30/40 (rolled back; stop).
apply_one() {
  local i="$1" id dir risk after reg rc tok
  id="${RUN_IDS[i]}"; dir="${RUN_DIR[i]}"; risk="${RUN_RISK[i]}"
  APPROVED=''
  if [[ "$risk" == manual-only ]]; then
    printf '[%s] manual-only: a person carries out the checklist above; nothing changed\n' "$id"
    RUN_STATE[i]=manual; return 0
  fi
  if [[ "${RUN_SCORED[i]}" == true ]]; then
    rc=0; lab_addrs_load scoring-allowlist || rc=$?
    if (( rc == 1 )); then RUN_STATE[i]=failed; return 40; fi
    if (( rc == 2 )); then
      printf '[%s] blocked: it touches scored services and the scoring allowlist is missing or empty\n' "$id"
      RUN_STATE[i]=blocked; return 20
    fi
    if (( ! HAVE_SERVICES )); then
      printf '[%s] blocked: it touches scored services and there is no service list to probe\n' "$id"
      RUN_STATE[i]=blocked; return 20
    fi
  fi
  requires_met "$i" || { RUN_STATE[i]=blocked; return 20; }
  if [[ "$risk" == approval ]]; then
    ask "[$id] Type the ids of the items to approve, separated by spaces, or press Enter for none: " || ANSWER=''
    for tok in $ANSWER; do
      [[ "$tok" =~ ^[A-Za-z0-9._:@-]+$ ]] || { printf '[%s] blocked: not an item id: %s\n' "$id" "$tok"; RUN_STATE[i]=blocked; return 20; }
    done
    APPROVED="$ANSWER"
    if [[ -z "$APPROVED" ]]; then
      printf '[%s] nothing approved; nothing changed\n' "$id"
      RUN_STATE[i]='done'; return 0
    fi
  fi
  if [[ ! -f "$dir/apply.sh" ]]; then
    RUN_STATE[i]='done'; return 0
  fi
  if [[ "$risk" != read-only ]]; then
    if ! lab_timer_arm "$((LAB_EVENT[REVERT_MINUTES] * 60))" "$LAB_RUN_ID" \
        "$BASH" "$LAB_ROOT/labyrinth.sh" --root "$DATA_ROOT" --config "$LAB_CONFIG_DIR" rollback "$LAB_RUN_ID"; then
      printf '[%s] blocked: the revert timer could not be armed\n' "$id"
      RUN_STATE[i]=blocked; return 20
    fi
  fi

  # Checked by hand: errexit is off inside a function called with ||, and a
  # change the manifest does not list could never be rolled back.
  if ! record_for "$id" apply_start '' "risk $risk"; then
    printf '[%s] error: the run manifest cannot be written, so it is not applied\n' "$id"
    RUN_STATE[i]=failed; return 40
  fi
  LAB_MODULE_ID="$id" lab_log_info apply_start "applying"
  run_entry "$dir" apply "$id" 0
  case "$ENTRY_RC" in
    0) ;;
    20)
      printf '[%s] apply: blocked by a safety gate\n' "$id"
      record_for "$id" rolled_back '' 'apply blocked before any change'
      RUN_STATE[i]=blocked; return 20
      ;;
    *)
      printf '[%s] apply: error (exit %s); rolling back\n' "$id" "$ENTRY_RC"
      RUN_STATE[i]=failed; rollback_module "$id" || true; return 40
      ;;
  esac

  if [[ -f "$dir/verify.sh" ]]; then
    run_entry "$dir" verify "$id" 0
    rc="$ENTRY_RC"
    if (( rc != 0 )); then
      printf '[%s] verify failed (exit %s); rolling back\n' "$id" "$rc"
      LAB_MODULE_ID="$id" lab_log_error verify_failed "verify exited $rc"
      RUN_STATE[i]=failed; rollback_module "$id" || true
      if (( rc == 30 )); then return 30; fi
      return 40
    fi
  fi

  if (( HAVE_SERVICES )); then
    after="$(probe_now)"
    reg="$(lab_probe_regressions "$BEFORE" "$after")"
    if [[ -n "$reg" ]]; then
      printf '[%s] scored service regressed: %s; rolling back\n' "$id" "${reg//$'\n'/ }"
      LAB_MODULE_ID="$id" lab_log_error regression "scored service regressed: ${reg//$'\n'/ }"
      RUN_STATE[i]=failed; rollback_module "$id" || true
      return 30
    fi
  fi

  if [[ -f "$dir/cleanup.sh" ]]; then
    run_entry "$dir" cleanup "$id" 0
    (( ENTRY_RC == 0 )) || printf '[%s] cleanup: exit %s (the change is kept)\n' "$id" "$ENTRY_RC"
  fi
  printf '[%s] applied and verified\n' "$id"
  LAB_MODULE_ID="$id" lab_log_info applied "applied and verified"
  RUN_STATE[i]='done'
  return 0
}

# resolve_profile: --profile, or this host's line in the hosts file.
resolve_profile() {
  local rc=0
  lab_host_lookup "$(lab_host)" || rc=$?
  (( rc != 1 )) || die 'the hosts file is malformed'
  if [[ -z "$OPT_PROFILE" ]]; then
    [[ -n "$LAB_HOST_PROFILE" ]] || die "no profile: give --profile, or list this host ($(lab_host)) in $LAB_CONFIG_DIR/hosts"
    OPT_PROFILE="$LAB_HOST_PROFILE"
  fi
}

cmd_plan() {
  local phase="$1" worst=0
  export LAB_DRY_RUN=1
  resolve_profile
  read_profile "$OPT_PROFILE"
  lab_event_load || die 'event.conf is malformed'
  gate_protected
  printf 'labyrinth %s - run %s - %s - profile %s - plan mode\n' \
    "$LAB_VERSION" "$LAB_RUN_ID" "$phase" "$OPT_PROFILE"
  plan_all "$phase" || worst=$?
  printf 'plan finished: exit %d\n' "$worst"
  exit "$worst"
}

cmd_apply() {
  local phase="$1" host group worst=0 rc i todo=0 stopped=0
  export LAB_DRY_RUN=1
  umask 077
  host="$(lab_host)"
  lab_is_admin || die 'apply needs root' 20
  rc=0; lab_host_lookup "$host" || rc=$?
  (( rc != 1 )) || die 'the hosts file is malformed'
  (( rc == 0 )) || die "this host ($host) is not in $LAB_CONFIG_DIR/hosts, so its ring group is unknown" 20
  group="$LAB_HOST_GROUP"
  [[ "$group" != manual ]] || die "this host ($host) is in the manual group: Labyrinth never changes it" 20
  if [[ -n "$OPT_PROFILE" && "$OPT_PROFILE" != "$LAB_HOST_PROFILE" ]]; then
    die "the hosts file gives this host profile $LAB_HOST_PROFILE, not $OPT_PROFILE"
  fi
  OPT_PROFILE="$LAB_HOST_PROFILE"
  read_profile "$OPT_PROFILE"
  lab_event_load || die 'event.conf is malformed'
  gate_protected
  lab_lock_acquire 0 || exit 20
  trap 'lab_lock_release' EXIT

  printf 'labyrinth %s - run %s - %s - profile %s - host %s, group %s - APPLY\n' \
    "$LAB_VERSION" "$LAB_RUN_ID" "$phase" "$OPT_PROFILE" "$host" "$group"
  plan_all "$phase" || worst=$?
  (( worst < 40 )) || die 'the plan has errors; nothing was changed'
  for ((i = 0; i < ${#RUN_IDS[@]}; i++)); do
    if [[ "${RUN_RC[i]}" == 10 && "${RUN_RISK[i]}" != manual-only ]]; then todo=$((todo + 1)); fi
  done
  if (( todo == 0 )); then
    printf 'nothing to apply\napply finished: exit %d\n' "$worst"
    exit "$worst"
  fi

  gate_breakglass
  gate_confirm "$group"

  # From here on, changes are made: everything is recorded first.
  export LAB_DRY_RUN=0
  mkdir -p "$LAB_STATE_DIR/runs/$LAB_RUN_ID" "$LAB_BACKUP_DIR/$LAB_RUN_ID" \
    || die 'the run and backup folders cannot be created; nothing was changed' 20
  record_for '' run_start "$host" "phase $phase, profile $OPT_PROFILE, group $group"
  record_for '' breakglass_verified "$BREAKGLASS"
  lab_log_info run_start "apply $phase, profile $OPT_PROFILE, group $group"
  rc=0; lab_services_load || rc=$?
  (( rc != 1 )) || die 'the service list is malformed; nothing was changed'
  if (( rc == 0 )); then
    HAVE_SERVICES=1
    BEFORE="$(probe_now)"
    printf '%s\n' "$BEFORE" > "$LAB_STATE_DIR/runs/$LAB_RUN_ID/probes-before"
    printf 'probes before the run:\n%s\n' "$BEFORE"
  else
    printf 'warning: no service list (%s/services), so no before-and-after probes\n' "$LAB_CONFIG_DIR"
  fi

  worst=0
  for ((i = 0; i < ${#RUN_IDS[@]}; i++)); do
    if [[ "${RUN_RC[i]}" == 20 ]]; then worst=20; RUN_STATE[i]=blocked; continue; fi
    if [[ "${RUN_RC[i]}" != 10 ]]; then RUN_STATE[i]='done'; continue; fi
    rc=0
    apply_one "$i" || rc=$?
    if (( rc > worst )); then worst=$rc; fi
    if (( rc >= 30 )); then stopped=1; break; fi
  done
  lab_lock_release

  if (( stopped )); then
    printf 'The run stopped. Earlier changes stay until the revert timer undoes them.\n'
    printf 'To keep them now: labyrinth.sh keep %s    To undo them now: labyrinth.sh rollback %s\n' "$LAB_RUN_ID" "$LAB_RUN_ID"
  elif lab_timer_armed "$LAB_RUN_ID"; then
    printf 'All changes are applied and verified. From a NEW session, check that you can still log in.\n'
    if ask "Type keep to keep the changes; anything else leaves the revert timer to undo them in ${LAB_EVENT[REVERT_MINUTES]} minutes: " \
        && [[ "$ANSWER" == keep ]]; then
      keep_run || worst=$?
    else
      printf 'Not kept. To keep later: labyrinth.sh keep %s    To undo now: labyrinth.sh rollback %s\n' "$LAB_RUN_ID" "$LAB_RUN_ID"
    fi
  fi
  printf 'apply finished: exit %d\n' "$worst"
  exit "$worst"
}

# run_rolled_back: has the current run already been rolled back as a whole?
run_rolled_back() {
  grep -q '"action":"run_rolled_back"' "$(lab_manifest_file)" 2> /dev/null
}

# keep_run: cancel the current run's revert timer and record it.
keep_run() {
  lab_lock_acquire 10 || return 20
  if run_rolled_back; then
    lab_lock_release
    printf 'too late: run %s was already rolled back\n' "$LAB_RUN_ID"
    return 20
  fi
  # Checked by hand: errexit is off inside a function called with ||.
  if ! lab_timer_cancel "$LAB_RUN_ID"; then
    lab_lock_release
    printf 'labyrinth: the revert timer for run %s could not be cancelled, so the run is not kept and the timer will still roll it back; run keep again\n' "$LAB_RUN_ID" >&2
    return 40
  fi
  record_for '' run_kept
  lab_log_info run_kept "changes kept; revert timer cancelled"
  lab_lock_release
  printf 'kept: the revert timer for run %s is cancelled\n' "$LAB_RUN_ID"
}

cmd_keep() {
  export LAB_RUN_ID="$1" LAB_DRY_RUN=0
  lab_is_admin || die 'keep needs root' 20
  [[ -f "$(lab_manifest_file)" ]] || die "no run $LAB_RUN_ID on this host"
  local rc=0
  keep_run || rc=$?
  exit "$rc"
}

cmd_rollback() {
  local id rc=0 i
  local -a mods=()
  export LAB_RUN_ID="$1" LAB_DRY_RUN=0
  umask 077
  lab_is_admin || die 'rollback needs root' 20
  [[ -f "$(lab_manifest_file)" ]] || die "no run $LAB_RUN_ID on this host"
  # The revert timer must work even if a hung run still holds the lock.
  if lab_lock_acquire 120; then
    trap 'lab_lock_release' EXIT
  else
    printf 'warning: rolling back without the run lock\n' >&2
  fi
  mapfile -t mods < <(lab_manifest_applied "$LAB_RUN_ID")
  printf 'labyrinth %s - rolling back run %s\n' "$LAB_VERSION" "$LAB_RUN_ID"
  for ((i = ${#mods[@]} - 1; i >= 0; i--)); do
    id="${mods[i]}"
    [[ "$id" =~ $RE_MODULE_ID ]] || { printf 'skipping a bad module id in the manifest: %s\n' "$id"; rc=40; continue; }
    rollback_module "$id" || rc=40
  done
  # A timer left armed runs this rollback again, which is safe.
  if ! lab_timer_cancel "$LAB_RUN_ID"; then
    printf 'warning: the revert timer for run %s could not be removed; when it fires it repeats this rollback, which is safe\n' "$LAB_RUN_ID" >&2
  fi
  record_for '' run_rolled_back '' "exit $rc"
  lab_log_warn run_rolled_back "run rolled back, exit $rc"
  printf 'rollback finished: exit %d\n' "$rc"
  exit "$rc"
}

cmd_probe() {
  local out rc=0
  export LAB_DRY_RUN=1
  lab_event_load || die 'event.conf is malformed'
  out="$(lab_probe_all)" || rc=$?
  case "$rc" in
    0) ;;
    2) die "no service list at $LAB_CONFIG_DIR/services" 20 ;;
    *) die 'the service list is malformed' ;;
  esac
  printf '%s\n' "$out"
  if grep -q '^[^ ]* fail ' <<< "$out"; then exit 30; fi
  exit 0
}

main() {
  local apply=0 config='' cmd
  local -a args=()
  DATA_ROOT='/opt/labyrinth'
  while (( $# > 0 )); do
    case "$1" in
      --profile)    (( $# >= 2 )) || die 'missing value for --profile'; OPT_PROFILE="$2"; shift 2 ;;
      --root)       (( $# >= 2 )) || die 'missing value for --root'; DATA_ROOT="$2"; shift 2 ;;
      --config)     (( $# >= 2 )) || die 'missing value for --config'; config="$2"; shift 2 ;;
      --breakglass) (( $# >= 2 )) || die 'missing value for --breakglass'; OPT_BREAKGLASS="$2"; shift 2 ;;
      --confirm)    (( $# >= 2 )) || die 'missing value for --confirm'; OPT_CONFIRM="$2"; shift 2 ;;
      --apply)      apply=1; shift ;;
      --version)    printf 'labyrinth %s\n' "$LAB_VERSION"; exit 0 ;;
      -h | --help)  usage; exit 0 ;;
      -*)           usage >&2; exit 40 ;;
      *)            args+=("$1"); shift ;;
    esac
  done
  (( ${#args[@]} > 0 )) || { usage >&2; exit 40; }
  cmd="${args[0]}"
  if [[ -n "$OPT_PROFILE" && ! "$OPT_PROFILE" =~ ^[a-z0-9-]+$ ]]; then die "invalid profile name: $OPT_PROFILE"; fi
  [[ "$DATA_ROOT" == /* ]] || die '--root must be an absolute path'
  [[ -z "$config" || "$config" == /* ]] || die '--config must be an absolute path'

  LAB_CONFIG_DIR="${config:-$DATA_ROOT/etc}"
  LAB_STATE_DIR="$DATA_ROOT/state"
  LAB_LOG_DIR="$DATA_ROOT/logs"
  LAB_BACKUP_DIR="$DATA_ROOT/backup"
  LAB_RUN_ID="$(new_run_id)"
  export LAB_CONFIG_DIR LAB_STATE_DIR LAB_LOG_DIR LAB_BACKUP_DIR LAB_RUN_ID

  case "$cmd" in
    probe)
      (( ${#args[@]} == 1 && ! apply )) || die 'usage: labyrinth.sh probe'
      cmd_probe ;;
    keep | rollback)
      (( ${#args[@]} == 2 && ! apply )) || die "usage: labyrinth.sh $cmd <run>"
      [[ "${args[1]}" =~ $RE_RUN_ID ]] || die "not a run id: ${args[1]}"
      "cmd_$cmd" "${args[1]}" ;;
    *)
      (( ${#args[@]} == 1 )) || die "unexpected argument: ${args[1]}"
      lab_in_list "$cmd" "$PHASES" || die "unknown phase or command: $cmd"
      if (( apply )); then cmd_apply "$cmd"; else cmd_plan "$cmd"; fi ;;
  esac
}

main "$@"
