#!/usr/bin/env bash
# labyrinth.sh: main program for Linux hosts (design 00, section 5;
# docs/Conventions.md sections 3.1 and 3.2).
#
#   labyrinth.sh plan <phase>        show what would change; changes nothing
#   labyrinth.sh apply <phase>       plan, confirm, then make the changes
#   labyrinth.sh keep [<run>]        keep a run: cancel its revert timer
#   labyrinth.sh rollback <run>      undo a run, newest change first
#   labyrinth.sh runs                list this host's runs and their state
#   labyrinth.sh probe               test every scored service once
#   labyrinth.sh help [<topic>]      help on a command, 'basics' or a module;
#                                    also -h and --help
#   labyrinth.sh version             the version; also -V and --version
#
# Options may come anywhere; 'labyrinth.sh help' lists them.
# Exit codes (design 00, section 4); the highest code from any module wins:
#   0 nothing to do or success, 10 change needed, 20 blocked,
#   30 verify failed or a scored service regressed, 40 error
set -Eeuo pipefail

# on_internal_error RC FILE LINE COMMAND: the ERR trap (docs/Conventions.md
# section 4). It fires only where errexit ends the program anyway, and says
# what is known instead of exiting silently. In a subshell it does nothing:
# the shell that started the subshell sees the failure and reports it.
on_internal_error() {
  (( BASH_SUBSHELL == 0 )) || return "$1"
  trap - ERR
  set +e
  local what="$4"
  (( ${#what} <= 60 )) || what="${what:0:57}..."
  printf 'labyrinth: internal error at %s:%s (%s), exit %s\n' "$2" "$3" "$what" "$1" >&2
  run_recovery >&2
  exit 40
}
trap 'on_internal_error "$?" "${BASH_SOURCE[0]##*/}" "$LINENO" "$BASH_COMMAND"' ERR

readonly LAB_VERSION='0.1.0-dev'
readonly PHASES='lockout observe deceive sustain'
readonly MODULE_KEYS='id title phase priority platforms risk touches_scored requires outputs spec'
readonly -a REQUIRED_KEYS=(id title phase priority platforms risk touches_scored)
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
LOAD_ERRORS=0              # modules of the phase that could not be loaded
LOAD_SKIPPED=0             # modules skipped: no entry points for this platform
STOPPED=0                  # 1 when an apply stopped partway
APPLIED=0                  # 1 once apply starts changing things
DATA_ROOT=''               # the data root (--root)
OPT_PROFILE='' OPT_BREAKGLASS='' OPT_CONFIRM=''
RUN_REF=''                 # the run keep or rollback acts on
CMD=''                     # the command being run, for on_internal_error
RUN_OPEN=0                 # 1 once an apply has recorded run_start
SELF="${0##*/}"            # how the operator started this program, for hints
readonly COMMANDS='plan apply keep rollback runs probe help version'

# The options, one row each (docs/Conventions.md section 3.1): the canonical
# name, the keys it is matched by (lower case, no dashes), and whether it
# takes a value.
readonly -a OPT_NAMES=(profile root config break-glass confirm-group apply help version)
readonly -a OPT_KEYS=('profile profilename' root config breakglass 'confirmgroup confirm' apply help version)
readonly -a OPT_VALUE=(1 1 1 1 1 0 0 0)
declare -A GIVEN=()        # canonical option name -> value given
declare -a WORDS=()        # the words that are not options, in order
PARSE_ERR=""                # the first option error, reported by main
ERROR_COUNT=0              # ERROR lines in the Summary, for the Next line
BEFORE=''                  # probe results before the first change
HAVE_SERVICES=0            # 1 when the scored-service list loaded

# The modules of this run, in run order, one array element per module.
declare -a RUN_IDS=() RUN_DIR=() RUN_RISK=() RUN_SCORED=() RUN_REQUIRES=() RUN_RC=() RUN_STATE=()

# cmd_help [COMMAND]: the help for every command, or for one, on stdout.
# Each topic is at most 15 lines of at most 78 columns, with one Exit line
# and one Example line (docs/Conventions.md section 3.2).
cmd_help() {
  local where="Where:
  --root DIR             data root (default /opt/labyrinth)
  --config DIR           configuration folder (default <root>/etc)"
  case "${1:-}" in
    '') cat <<EOF
Usage: $SELF <command> [<phase> | <run>] [options]
New to Labyrinth? Start with '$SELF help basics'.

  plan <phase>      show what would change; changes nothing
  apply <phase>     plan, confirm, then make the changes
  keep [<run>]      keep a run: cancel its revert timer
  rollback <run>    undo a run, newest change first
  runs              list this host's runs and their state
  probe             test every scored service once
  help [<topic>]    help on a command, 'basics', or a module ID
  version           print the version

Phases: lockout, observe, deceive, sustain. <run>: an ID or its last 4.
Exit: 0 ok, 10 change needed, 20 blocked, 30 check failed, 40 error.
Example: $SELF plan lockout
Manual: 'man labyrinth' once installed; docs/manual in the release.
EOF
    ;;
    plan) cat <<EOF
Usage: $SELF plan <phase> [options]

Show what every module of the phase would change on this host.
Nothing is changed and nothing is written. <phase> is lockout,
observe, deceive or sustain.

$where
  --profile NAME         use this profile, not the one in the hosts file

Exit: 0 nothing to do, 10 change needed, 20 blocked, 40 error.
Example: $SELF plan lockout
Compatibility: '$SELF <phase>' also plans.
EOF
    ;;
    apply) cat <<EOF
Usage: $SELF apply <phase> [options]

Plan, confirm, then change; a revert timer undoes it unless kept.

$where
  --profile NAME         must match this host's line in the hosts file
Apply only:
  --break-glass NAME     answer the break-glass prompt
  --confirm-group GROUP  answer the group-name prompt

Exit: 0 done, 10 manual steps left, 20 blocked, 30 check failed, 40 error.
Example: $SELF apply lockout
Compatibility: '$SELF <phase> --apply' also applies.
EOF
    ;;
    keep) cat <<EOF
Usage: $SELF keep [<run>] [options]

Keep a run's changes: cancel its revert timer, then record the keep.
Without <run>, keep the one run whose timer is armed. <run> is a run
ID or its last 4 characters; '$SELF runs' lists them.

$where

Exit: 0 kept, 20 not root or too late (rolled back), 40 error.
Example: $SELF keep 4f2a
EOF
    ;;
    rollback) cat <<EOF
Usage: $SELF rollback <run> [options]

Undo everything the run changed, newest change first. This is what
the revert timer runs. Safe to run twice. <run> is a run ID or its
last 4 characters; '$SELF runs' lists them.

$where

Exit: 0 rolled back, 20 not root, 40 error.
Example: $SELF rollback 4f2a
EOF
    ;;
    runs) cat <<EOF
Usage: $SELF runs [options]

List this host's runs, oldest first: run ID, phase, start time (UTC)
and state (armed, kept, rolled back, or not kept, no timer).
Changes nothing; needs root.

$where

Exit: 0 listed, 20 not root, 40 error.
Example: $SELF runs
EOF
    ;;
    probe) cat <<EOF
Usage: $SELF probe [options]

Test every scored service once, the way the scoring engine would,
and print one line per service. Changes nothing.

$where

Exit: 0 all pass, 20 no service list, 30 a service failed, 40 error.
Example: $SELF probe
EOF
    ;;
    help) cat <<EOF
Usage: $SELF help [<command> | basics | <module-id>]

Print help for every command, or for one. '$SELF <command> --help'
and '$SELF <command> -h' print the same. 'basics' explains the ideas
in plain words. A module ID, such as the ones a plan prints, explains
that module: what it checks and changes, and how to undo it.

Exit: 0 printed, 40 unknown topic.
Example: $SELF help apply
EOF
    ;;
    basics) cat <<EOF
Usage: $SELF help basics

Labyrinth makes this host harder to break into, in four phases run in
order: lockout, observe, deceive and sustain. Each phase is a list of
modules. A module does one small job, such as turning off SSH password
logins. '$SELF help <module-id>' explains any module.

1. Plan: '$SELF plan lockout' shows what each module would change.
   It changes nothing, so run it as often as you like.
2. Apply: '$SELF apply lockout' plans again, asks you to type this
   host's group name, then makes the changes and checks each one.
3. Keep: an apply is a run, named by an ID; its last 4 characters are
   enough. A revert timer undoes the run after a few minutes unless you
   keep it, so a change that locks you out undoes itself. Log in from
   a new session, and if that works, run '$SELF keep'.

To undo a run yourself: '$SELF rollback <run>'. To list the runs:
'$SELF runs'. Scored services are the ones the scoring engine tests.
Labyrinth tests them before and after each change, and undoes a change
that breaks one. To test them now: '$SELF probe'.

Exit: 0 printed.
Example: $SELF help basics
EOF
    ;;
    version) cat <<EOF
Usage: $SELF version

Print the version of Labyrinth. '-V' and '--version' do the same.

Exit: 0 printed.
Example: $SELF version
EOF
    ;;
  esac
}

cmd_version() { printf 'labyrinth %s\n' "$LAB_VERSION"; }

# risk_words RISK: what a module's risk means, in plain words.
risk_words() {
  case "$1" in
    read-only) printf 'only looks; it never changes anything' ;;
    reversible) printf 'changes this host; each change is saved first and can be undone' ;;
    service-affecting) printf 'may interrupt a service; each change can be undone' ;;
    approval) printf 'changes only what a person approves; each can be undone' ;;
    manual-only) printf 'never changes anything; it lists steps for a person' ;;
  esac
}

# module_ids: every module ID in this release.
module_ids() {
  local d phase
  for d in "$LAB_ROOT"/phases/*/modules/*/; do
    d="${d%/}"
    [[ -f "$d/module.yml" ]] || continue
    phase="${d%/modules/*}"
    printf '%s.%s\n' "${phase##*/}" "${d##*/}"
  done
}

# cmd_help_module ID: one module's help page: its module.yml in plain
# words, then its about.txt (design 00, section 4).
cmd_help_module() {
  local id="$1" phase="${1%%.*}" dir items hint
  dir="$LAB_ROOT/phases/$phase/modules/${id#*.}"
  if [[ ! "$id" =~ $RE_MODULE_ID || ! -d "$dir" ]]; then
    # shellcheck disable=SC2046 # one word per module ID
    hint="$(suggest "$id" basics $COMMANDS $(module_ids))"
    usage_error "no module '$id'${hint:+ (did you mean '$hint'?)}" help
  fi
  YML_ERR=''
  if ! read_module_yml "$dir/module.yml" || ! validate_module "$dir/module.yml" "$id" "$phase"; then
    items="${YML_ERR%%$'\n'*}"
    die "the module.yml of $id is not valid: ${items##*: }" 40 \
      "Report the module to its author, or correct ${items%: *}"
  fi
  items="$(list_items "${MOD[platforms]}")"
  printf '%s (%s)\n\n' "${MOD[title]}" "$id"
  printf 'Phase: %s. Order: %s (P0 runs first, P3 last).\n' "$phase" "${MOD[priority]}"
  printf 'Risk: %s.\n' "$(risk_words "${MOD[risk]}")"
  if [[ "${MOD[touches_scored]}" == true ]]; then
    printf 'Scored services: it can affect one, so they are tested after it.\n'
  else
    printf 'Scored services: it does not touch them.\n'
  fi
  printf 'Runs on: %s.\n' "${items// /, }"
  printf 'Folder: %s\n\n' "$dir"
  if [[ -f "$dir/about.txt" ]]; then
    cat -- "$dir/about.txt"
  else
    printf 'This module has no about.txt yet. Its scripts are in the folder above.\n'
  fi
}

# die MESSAGE [CODE] [FIX]: the error, then how to recover, on stderr.
die() {
  printf 'labyrinth: %s\n' "$1" >&2
  if [[ -n "${3:-}" ]]; then printf '%s\n' "$3" >&2; fi
  exit "${2:-40}"
}

# How to get the rights a command needs.
FIX_ADMIN='Run it again as root, for example with sudo.'
FIX_LINE='Correct that line, then run the same command again.'

# load_reason LOADER [ARG...]: the first error line a configuration loader
# prints, run in a subshell so that nothing it sets is kept.
load_reason() { "$@" 2>&1 >/dev/null | head -n 1; }

# host_lookup HOST: lab_host_lookup, with a malformed hosts file an error.
# Returns 0 when HOST is listed and 2 when it is not.
host_lookup() {
  local rc=0
  lab_host_lookup "$1" 2>/dev/null || rc=$?
  if (( rc == 1 )); then
    die "the hosts file is malformed: $(load_reason lab_host_lookup "$1")" 40 \
      'Each line is: host group profile platform. Correct it, then run the same command again.'
  fi
  return "$rc"
}

# profile_names: the profiles this host can use, comma-separated.
profile_names() {
  local f names=''
  for f in "$LAB_CONFIG_DIR"/profiles/*.profile "$LAB_ROOT"/profiles/*.profile; do
    [[ -f "$f" ]] || continue
    f="${f##*/}"; f="${f%.profile}"
    if [[ ", $names, " != *", $f, "* ]]; then names+="${names:+, }$f"; fi
  done
  printf '%s' "$names"
}

# run_recovery: after an internal error, what changed and what to do next.
run_recovery() {
  local ref="${RUN_REF:-}"
  if (( RUN_OPEN )); then
    if lab_timer_armed "$LAB_RUN_ID"; then
      run_stopped
    else
      printf 'The run stopped. Its manifest lists what it did.\n'
      printf 'To undo it: %s rollback %s\n' "$SELF" "${LAB_RUN_ID: -4}"
    fi
    return 0
  fi
  case "$CMD" in
    rollback)
      if [[ -n "$ref" ]]; then
        printf 'The rollback did not finish, and it is safe to repeat.\n'
        printf 'Retry: %s rollback %s\n' "$SELF" "${ref: -4}"
      else
        printf 'Nothing was rolled back.\n'
      fi ;;
    keep)
      if [[ -n "$ref" ]]; then
        printf "The run may not be kept; '%s runs' shows its state.\n" "$SELF"
        printf 'Retry: %s keep %s\n' "$SELF" "${ref: -4}"
      else
        printf 'Nothing was kept.\n'
      fi ;;
    *) printf 'Nothing was changed.\n' ;;
  esac
}

# run_stopped: what the operator needs after a run stops partway.
run_stopped() {
  local due
  printf 'The run stopped. Earlier changes stay until the revert timer undoes them.\n'
  if due="$(lab_timer_due "$LAB_RUN_ID" 2> /dev/null)"; then
    printf 'The revert timer rolls this run back at %s UTC.\n' "${due:11:5}"
  fi
  printf 'To keep them now: %s keep %s\n' "$SELF" "${LAB_RUN_ID: -4}"
  printf 'To undo them now: %s rollback %s\n' "$SELF" "${LAB_RUN_ID: -4}"
}

# usage_error MESSAGE [COMMAND] [FIX]: a usage error: one line, the fix if
# there is one, a pointer to help, exit 40 (docs/Conventions.md section 3.1).
usage_error() {
  printf 'labyrinth: %s\n' "$1" >&2
  if [[ -n "${3:-}" ]]; then printf '%s\n' "$3" >&2; fi
  printf "Try '%s help%s' for more information.\n" "$SELF" "${2:+ $2}" >&2
  exit 40
}

# parse_fail MESSAGE: note the first option error; main reports it once
# the command is known, so the pointer to help names that command.
parse_fail() { if [[ -z "$PARSE_ERR" ]]; then PARSE_ERR="$1"; fi; }

# warn MESSAGE: a warning on stderr.
warn() { printf 'labyrinth: warning: %s\n' "$1" >&2; }

# say WORD TEXT: a result line, the status word padded to 9 characters
# (docs/Conventions.md section 3.2).
say() { printf '%-9s%s\n' "$1" "$2"; }

# note TEXT: a second line for a status line, indented like module output.
note() { printf '           %s\n' "$1"; }

# indent: copy standard input, each line indented 11 spaces.
indent() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do printf '           %s\n' "$line"; done
}

# summary MODE: how many modules ended with each status word, counted
# from the run's arrays, not from the lines printed.
summary() {
  local mode="$1" i w out='' notrun=0
  local -A count=([OK]=0 [CHANGE]=0 [WARN]="$LOAD_SKIPPED" [BLOCKED]=0 [FAIL]=0 [ERROR]="$LOAD_ERRORS")
  for ((i = 0; i < ${#RUN_IDS[@]}; i++)); do
    if [[ "$mode" == plan ]]; then
      case "${RUN_RC[i]}" in 0) w=OK ;; 10) w=CHANGE ;; 20) w=BLOCKED ;; *) w=ERROR ;; esac
      if [[ "$w" == CHANGE && "${RUN_RISK[i]}" == manual-only ]]; then w=WARN; fi
    else
      case "${RUN_STATE[i]}" in
        done) w=OK ;; manual) w=WARN ;; blocked) w=BLOCKED ;; failed) w=FAIL ;; error) w=ERROR ;;
        *) notrun=$((notrun + 1)); continue ;;
      esac
    fi
    count[$w]=$((${count[$w]} + 1))
  done
  for w in OK CHANGE WARN BLOCKED FAIL ERROR; do
    if (( ${count[$w]} > 0 )); then out+="${out:+, }${count[$w]} $w"; fi
  done
  if (( notrun > 0 )); then out+="${out:+, }$notrun not run"; fi
  ERROR_COUNT="${count[ERROR]}"
  printf 'Summary: %s\n' "${out:-no modules}"
}

# shell_word WORD: WORD, quoted if the shell would split or expand it.
shell_word() {
  if [[ "$1" =~ ^[A-Za-z0-9/._:@=-]+$ ]]; then printf '%s' "$1"; else printf "'%s'" "$1"; fi
}

# next_step MODE CODE PHASE: the one command to run next, if there is one.
next_step() {
  local mode="$1" code="$2" phase="$3" i manual=0 other=0 opts=''
  if [[ "$mode" == apply ]] && (( STOPPED )); then
    printf 'Next: keep the earlier changes or undo them, with the commands above.\n'
  elif [[ "$mode" == apply ]] && lab_timer_armed "$LAB_RUN_ID"; then
    printf "Next: check you can log in from a NEW session, then '%s keep %s'.\n" "$SELF" "${LAB_RUN_ID: -4}"
  elif (( code == 40 )); then
    if (( ERROR_COUNT > 1 )); then
      printf 'Next: fix the errors above, then run the same command again.\n'
    else
      printf 'Next: fix the error above, then run the same command again.\n'
    fi
  elif (( code == 20 )); then
    printf 'Next: clear what blocked it above, then run the same command again.\n'
  elif (( code == 10 )); then
    for ((i = 0; i < ${#RUN_IDS[@]}; i++)); do
      if [[ "${RUN_RC[i]}" != 10 ]]; then continue; fi
      if [[ "${RUN_RISK[i]}" == manual-only ]]; then manual=$((manual + 1)); else other=$((other + 1)); fi
    done
    if (( other == 0 )); then
      printf 'Next: a person carries out the manual steps above; apply changes nothing.\n'
    else
      if [[ -n "${GIVEN[profile]:-}" ]]; then opts+=" --profile ${GIVEN[profile]}"; fi
      if [[ -n "${GIVEN[root]:-}" ]]; then opts+=" --root $(shell_word "${GIVEN[root]}")"; fi
      if [[ -n "${GIVEN[config]:-}" ]]; then opts+=" --config $(shell_word "${GIVEN[config]}")"; fi
      # A command too long for one line goes on a line of its own.
      if (( ${#SELF} + ${#phase} + ${#opts} + 13 > 78 )); then
        printf 'Next:\n  %s apply %s%s\n' "$SELF" "$phase" "$opts"
      else
        printf 'Next: %s apply %s%s\n' "$SELF" "$phase" "$opts"
      fi
    fi
  fi
}

# finish MODE CODE PHASE: the end of a plan or apply: Summary, Next and
# the exit code with its meaning; then exit with CODE.
finish() {
  local mode="$1" code="$2" what
  case "$mode:$code" in
    plan:0) what='nothing to do' ;;
    plan:10) what='change needed' ;;
    apply:0) what='done' ;;
    apply:10) what='manual steps needed' ;;
    *:20) what='blocked' ;;
    *:30) what='a check failed, and that change was undone' ;;
    *) what='error' ;;
  esac
  if [[ "$mode" == plan ]] || (( ! APPLIED )); then summary plan; else summary apply; fi
  next_step "$mode" "$code" "$3"
  printf '%s finished: exit %d (%s)\n' "$mode" "$code" "$what"
  exit "$code"
}

# edit_distance A B: the Levenshtein distance between A and B.
edit_distance() {
  local a="$1" b="$2" i j cost del ins sub
  local -a prev=() cur=()
  for ((j = 0; j <= ${#b}; j++)); do prev[j]=$j; done
  for ((i = 1; i <= ${#a}; i++)); do
    cur=("$i")
    for ((j = 1; j <= ${#b}; j++)); do
      cost=1
      if [[ "${a:i-1:1}" == "${b:j-1:1}" ]]; then cost=0; fi
      del=$((prev[j] + 1)); ins=$((cur[j-1] + 1)); sub=$((prev[j-1] + cost))
      if (( ins < del )); then del=$ins; fi
      if (( sub < del )); then del=$sub; fi
      cur[j]=$del
    done
    prev=("${cur[@]}")
  done
  printf '%s\n' "${prev[${#b}]}"
}

# suggest WORD CANDIDATE...: the candidate WORD most likely meant: the only
# one it is a prefix of, else the nearest within an edit distance of 2.
# Prints nothing when there is none.
suggest() {
  local word="$1" c best='' bestd=3 d
  local -a prefix=()
  shift
  [[ -n "$word" ]] || return 0
  for c in "$@"; do
    if [[ "$c" == "$word"* ]]; then prefix+=("$c"); fi
  done
  if (( ${#prefix[@]} == 1 )); then printf '%s\n' "${prefix[0]}"; return 0; fi
  for c in "$@"; do
    d="$(edit_distance "$word" "$c")"
    if (( d < bestd )); then bestd=$d; best="$c"; fi
  done
  if [[ -n "$best" ]]; then printf '%s\n' "$best"; fi
}

# opt_lookup KEY: the row of the option matched by KEY (lower case, no
# dashes), in OPT_ROW; returns 1 if none.
opt_lookup() {
  local i k
  for ((i = 0; i < ${#OPT_NAMES[@]}; i++)); do
    for k in ${OPT_KEYS[i]}; do
      if [[ "$k" == "$1" ]]; then OPT_ROW=$i; return 0; fi
    done
  done
  return 1
}

# parse_args WORD...: sort the words into options (GIVEN) and the rest
# (WORDS). Options may come anywhere; '--' ends them.
parse_args() {
  local w key val sep name hint ended=0
  local -a keys=() parts=()
  while (( $# > 0 )); do
    w="$1"; shift
    if (( ended )) || [[ "$w" != -?* ]]; then WORDS+=("$w"); continue; fi
    case "$w" in
      --) ended=1; continue ;;
      -h | '-?') w='--help' ;;
      -V) w='--version' ;;
      -v) parse_fail "unknown option '-v' (did you mean '-V', the version?)"; continue ;;
    esac
    key="${w#-}"; key="${key#-}"
    val='' sep=''
    if [[ "$key" =~ ^([^=:]*)([=:])(.*)$ ]]; then
      key="${BASH_REMATCH[1]}" sep="${BASH_REMATCH[2]}" val="${BASH_REMATCH[3]}"
    fi
    key="${key,,}"; key="${key//-/}"
    if ! opt_lookup "$key"; then
      keys=()
      # One candidate per option, its first key, so a prefix of two keys
      # of the same option still counts as one.
      for name in "${OPT_KEYS[@]}"; do read -ra parts <<< "$name"; keys+=("${parts[0]}"); done
      hint="$(suggest "$key" "${keys[@]}")"
      if [[ -n "$hint" ]] && opt_lookup "$hint"; then
        parse_fail "unknown option '${w%%[=:]*}' (did you mean '--${OPT_NAMES[OPT_ROW]}'?)"
      fi
      parse_fail "unknown option '${w%%[=:]*}'"
      continue
    fi
    name="${OPT_NAMES[OPT_ROW]}"
    if (( OPT_VALUE[OPT_ROW] )); then
      # '--name value', or PowerShell's '-Name:' with the value as the next word.
      if [[ -z "$sep" || ( "$sep" == : && -z "$val" ) ]]; then
        if (( $# == 0 )); then parse_fail "--$name needs a value"; continue; fi
        if [[ "$1" == -?* ]]; then parse_fail "--$name needs a value, but got '$1'"; continue; fi
        val="$1"; shift
      fi
      if [[ -z "$val" ]]; then parse_fail "--$name needs a value"; continue; fi
    elif [[ -n "$sep" ]]; then
      parse_fail "--$name takes no value"; continue
    fi
    if [[ -n "${GIVEN[$name]+set}" ]]; then parse_fail "--$name is given twice"; continue; fi
    GIVEN[$name]="$val"
  done
}

# check_used COMMAND OPTION...: note a warning for each value option given
# that COMMAND does not use. flush_warnings prints them once the command has
# passed its own checks, so a warning never comes before an error.
check_used() {
  local cmd="$1" name used u
  shift
  for name in profile break-glass confirm-group; do
    used=0
    for u in "$@"; do if [[ "$u" == "$name" ]]; then used=1; fi; done
    if [[ -n "${GIVEN[$name]+set}" ]] && (( ! used )); then
      PENDING_WARNINGS+=("--$name is not used by $cmd")
    fi
  done
}

# flush_warnings: print the warnings check_used noted.
flush_warnings() {
  local w
  for w in "${PENDING_WARNINGS[@]+"${PENDING_WARNINGS[@]}"}"; do warn "$w"; done
  PENDING_WARNINGS=()
}
PENDING_WARNINGS=()

# yml_error WHERE MESSAGE: keep a module.yml error, to print under the
# module's ERROR line; returns 1.
yml_error() { YML_ERR+="$1: $2"$'\n'; return 1; }
YML_ERR=''

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
  [[ "${MOD[title]}" =~ ^[\ -~]+$ ]] || { yml_error "$file" 'title must be plain ASCII text'; return 1; }
  (( ${#MOD[title]} <= 40 )) || { yml_error "$file" "title is ${#MOD[title]} characters; the most is 40"; return 1; }
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
  if [[ ! -f "$file" ]]; then
    local names
    names="$(profile_names)"
    if [[ -n "$names" ]]; then
      die "no profile named $name" 40 "Profiles here: $names."
    fi
    die "no profile named $name" 40 "There are no profiles in $LAB_CONFIG_DIR/profiles or $LAB_ROOT/profiles."
  fi
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
# output, both streams, goes to the operator as it comes, indented under
# the module's result line (section 3.2); its stdin is empty, so it can
# never take an answer meant for the runner. Its exit code is left in ENTRY_RC.
run_entry() {
  local dir="$1" entry="$2" id="$3" dry="${4:-1}"
  if LAB_MODULE_ID="$id" LAB_ENTRY="$entry" LAB_DRY_RUN="$dry" LAB_APPROVED="$APPROVED" \
      bash "$dir/$entry.sh" < /dev/null 2>&1 | indent; then
    ENTRY_RC=0
  else
    ENTRY_RC="${PIPESTATUS[0]}"
  fi
}

# capture_entry DIR ENTRY ID: like run_entry in plan mode, but the output
# is kept in ENTRY_OUT, because the result line that goes above it is known
# only when the entry point ends.
capture_entry() {
  local dir="$1" entry="$2" id="$3"
  ENTRY_RC=0
  ENTRY_OUT="$(LAB_MODULE_ID="$id" LAB_ENTRY="$entry" LAB_DRY_RUN=1 LAB_APPROVED="$APPROVED" \
    bash "$dir/$entry.sh" < /dev/null 2>&1)" || ENTRY_RC=$?
}
ENTRY_OUT=''

# show_output: print ENTRY_OUT, indented.
show_output() {
  if [[ -n "$ENTRY_OUT" ]]; then printf '%s\n' "$ENTRY_OUT" | indent; fi
}

# load_modules PHASE: read and check every module of PHASE in the profile,
# then put them in run order: by priority, P0 first, and in profile order
# within a priority. Returns 40 if any module is invalid.
load_modules() {
  local phase="$1" id name dir worst=0 p i entry needed
  local -a ids=() dirs=() risks=() scored=() reqs=() prios=()
  PHASE_COUNT=0 LOAD_ERRORS=0 LOAD_SKIPPED=0
  for id in "${PROFILE_IDS[@]+"${PROFILE_IDS[@]}"}"; do
    if [[ "${id%%.*}" != "$phase" ]]; then continue; fi
    PHASE_COUNT=$((PHASE_COUNT + 1))
    name="${id#*.}"
    dir="$LAB_ROOT/phases/$phase/modules/$name"
    if [[ ! -d "$dir" ]]; then
      say ERROR "[$id] error: module not found"
      printf 'looked in: %s\n' "$dir" | indent
      LOAD_ERRORS=$((LOAD_ERRORS + 1)); worst=40; continue
    fi
    YML_ERR=''
    if ! read_module_yml "$dir/module.yml" || ! validate_module "$dir/module.yml" "$id" "$phase"; then
      say ERROR "[$id] error: invalid module.yml"
      printf '%s' "$YML_ERR" | indent
      LOAD_ERRORS=$((LOAD_ERRORS + 1)); worst=40; continue
    fi
    if ! compgen -G "$dir/*.sh" > /dev/null; then
      say WARN "[$id] skipped: no Linux entry points"
      LOAD_SKIPPED=$((LOAD_SKIPPED + 1)); continue
    fi
    needed='check'
    case "${MOD[risk]}" in
      reversible | service-affecting | approval) needed='check apply verify rollback' ;;
    esac
    for entry in $needed; do
      if [[ ! -f "$dir/$entry.sh" ]]; then
        say ERROR "[$id] error: missing $entry.sh (needed for risk ${MOD[risk]})"
        LOAD_ERRORS=$((LOAD_ERRORS + 1)); worst=40; continue 2
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
  capture_entry "$dir" check "$id"
  case "$ENTRY_RC" in
    0)  say OK "[$id] check: nothing to do"; show_output ;;
    10)
      if [[ ! -f "$dir/plan.sh" ]]; then
        say ERROR "[$id] error: change needed but plan.sh is missing"; show_output; rc=40
      else
        if [[ "${RUN_RISK[i]}" == manual-only ]]; then
          say WARN "[$id] check: manual steps needed; plan follows"
        else
          say CHANGE "[$id] check: change needed; plan follows"
        fi
        show_output
        run_entry "$dir" plan "$id"
        case "$ENTRY_RC" in
          0 | 10) rc=10 ;;
          20)     say BLOCKED "[$id] plan: blocked by a safety gate"; rc=20 ;;
          *)      say ERROR "[$id] plan: error (exit $ENTRY_RC)"; rc=40 ;;
        esac
      fi
      ;;
    20) say BLOCKED "[$id] check: blocked by a safety gate"; show_output; rc=20 ;;
    *)  say ERROR "[$id] check: error (exit $ENTRY_RC)"; show_output; rc=40 ;;
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
    say WARN "[$1] no modules for this phase in profile $OPT_PROFILE"
  fi
  return "$worst"
}

# gate_protected: the protected set must load and hold at least one account
# (design 01, section 7). Plan mode needs it too, because plans that touch
# accounts depend on it.
gate_protected() {
  local rc=0 file="$LAB_CONFIG_DIR/protected-accounts" why
  lab_protected_load 2>/dev/null || rc=$?
  case "$rc" in
    0) ;;
    2) why="$file lists no accounts"
       if [[ ! -f "$file" ]]; then why="there is no $file"; fi
       die "the protected set is not loaded, so nothing runs: $why" 20 \
         'List, one "account class" per line, the accounts Labyrinth must never change.' ;;
    *) die "the protected set is malformed: $(load_reason lab_protected_load)" 40 \
         "$FIX_LINE" ;;
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
    # Checked by hand: this function is called with ||, so errexit is off.
    if ! record_for "$id" rolled_back; then
      say ERROR "[$id] rolled back, but the manifest cannot be written"
      note 'It still lists the change; rolling back again is safe.'
      return 40
    fi
    say OK "[$id] rolled back"
    LAB_MODULE_ID="$id" lab_log_warn rolled_back "rolled back"
    return 0
  fi
  say ERROR "[$id] rollback FAILED (exit $rc)"
  note "Restore its files by hand from $LAB_BACKUP_DIR/$LAB_RUN_ID/$id"
  LAB_MODULE_ID="$id" lab_log_error rollback_failed "rollback failed with exit $rc"
  return 40
}

# requires_met INDEX: did every module this one requires, in this run, finish?
requires_met() {
  local i="$1" req j
  for req in ${RUN_REQUIRES[i]}; do
    for ((j = 0; j < ${#RUN_IDS[@]}; j++)); do
      if [[ "${RUN_IDS[j]}" == "$req" && "${RUN_STATE[j]}" != 'done' && "${RUN_STATE[j]}" != planned ]]; then
        say BLOCKED "[${RUN_IDS[i]}] blocked: requires $req, which did not complete"
        return 1
      fi
    done
  done
}

# apply_one INDEX: apply, verify and probe one module. Returns 0 (done or
# nothing to do), 20 (blocked; continue), or 30/40 (rolled back; stop).
apply_one() {
  local i="$1" id dir risk after reg rc tok why
  id="${RUN_IDS[i]}"; dir="${RUN_DIR[i]}"; risk="${RUN_RISK[i]}"
  APPROVED=''
  if [[ "$risk" == manual-only ]]; then
    say WARN "[$id] manual-only; nothing changed"
    note 'A person carries out the checklist above.'
    RUN_STATE[i]=manual; return 0
  fi
  if [[ "${RUN_SCORED[i]}" == true ]]; then
    # Only the check is needed here, so the loader runs in a subshell and
    # its reason is printed under the ERROR line.
    rc=0; why="$(lab_addrs_load scoring-allowlist 2>&1)" || rc=$?
    if (( rc == 1 )); then
      say ERROR "[$id] error: the scoring allowlist is malformed"
      printf '%s\n' "$why" | indent
      RUN_STATE[i]=error; return 40
    fi
    if (( rc == 2 )); then
      say BLOCKED "[$id] blocked: it touches scored services"
      note 'The scoring allowlist is missing or empty.'
      RUN_STATE[i]=blocked; return 20
    fi
    if (( ! HAVE_SERVICES )); then
      say BLOCKED "[$id] blocked: it touches scored services"
      note 'There is no service list to probe.'
      RUN_STATE[i]=blocked; return 20
    fi
  fi
  requires_met "$i" || { RUN_STATE[i]=blocked; return 20; }
  if [[ "$risk" == approval ]]; then
    ask "[$id] Type the ids of the items to approve, separated by spaces, or press Enter for none: " || ANSWER=''
    for tok in $ANSWER; do
      [[ "$tok" =~ ^[A-Za-z0-9._:@-]+$ ]] || { say BLOCKED "[$id] blocked: not an item id: $tok"; RUN_STATE[i]=blocked; return 20; }
    done
    APPROVED="$ANSWER"
    if [[ -z "$APPROVED" ]]; then
      say OK "[$id] nothing approved; nothing changed"
      RUN_STATE[i]='done'; return 0
    fi
  fi
  if [[ ! -f "$dir/apply.sh" ]]; then
    say OK "[$id] no apply step; nothing changed"
    RUN_STATE[i]='done'; return 0
  fi
  if [[ "$risk" != read-only ]]; then
    if ! lab_timer_arm "$((LAB_EVENT[REVERT_MINUTES] * 60))" "$LAB_RUN_ID" \
        "$BASH" "$LAB_ROOT/labyrinth.sh" --root "$DATA_ROOT" --config "$LAB_CONFIG_DIR" rollback "$LAB_RUN_ID"; then
      say BLOCKED "[$id] blocked: the revert timer could not be armed"
      RUN_STATE[i]=blocked; return 20
    fi
  fi

  # Checked by hand: errexit is off inside a function called with ||, and a
  # change the manifest does not list could never be rolled back.
  if ! record_for "$id" apply_start '' "risk $risk"; then
    say ERROR "[$id] not applied: the run manifest cannot be written"
    RUN_STATE[i]=error; return 40
  fi
  LAB_MODULE_ID="$id" lab_log_info apply_start "applying"
  say CHANGE "[$id] applying"
  run_entry "$dir" apply "$id" 0
  case "$ENTRY_RC" in
    0) ;;
    20)
      say BLOCKED "[$id] apply: blocked by a safety gate"
      record_for "$id" rolled_back '' 'apply blocked before any change'
      RUN_STATE[i]=blocked; return 20
      ;;
    *)
      say ERROR "[$id] apply: error (exit $ENTRY_RC); rolling back"
      RUN_STATE[i]=error; rollback_module "$id" || true; return 40
      ;;
  esac

  if [[ -f "$dir/verify.sh" ]]; then
    run_entry "$dir" verify "$id" 0
    rc="$ENTRY_RC"
    if (( rc != 0 )); then
      say FAIL "[$id] verify failed (exit $rc); rolling back"
      LAB_MODULE_ID="$id" lab_log_error verify_failed "verify exited $rc"
      RUN_STATE[i]=failed; rollback_module "$id" || RUN_STATE[i]=error
      if (( rc == 30 )); then return 30; fi
      return 40
    fi
  fi

  if (( HAVE_SERVICES )); then
    after="$(probe_now)"
    reg="$(lab_probe_regressions "$BEFORE" "$after")"
    if [[ -n "$reg" ]]; then
      say FAIL "[$id] scored service regressed: ${reg//$'\n'/ }; rolling back"
      LAB_MODULE_ID="$id" lab_log_error regression "scored service regressed: ${reg//$'\n'/ }"
      RUN_STATE[i]=failed; rollback_module "$id" || RUN_STATE[i]=error
      return 30
    fi
  fi

  if [[ -f "$dir/cleanup.sh" ]]; then
    run_entry "$dir" cleanup "$id" 0
    (( ENTRY_RC == 0 )) || say WARN "[$id] cleanup: exit $ENTRY_RC (the change is kept)"
  fi
  say OK "[$id] applied and verified"
  LAB_MODULE_ID="$id" lab_log_info applied "applied and verified"
  RUN_STATE[i]='done'
  return 0
}

# check_host: the host checks for plan, apply and probe (docs/Conventions.md
# section 3.1). keep, rollback and runs skip them, so a stored revert-timer
# command still works after the configuration changes.
check_host() {
  local rc=0 host
  local fix='Give the folder with the hosts file, or leave out --config to use <root>/etc.'
  if [[ -n "${GIVEN[config]:-}" && -e "${GIVEN[config]}" && ! -d "${GIVEN[config]}" ]]; then
    die "the --config path is a file, not a folder: ${GIVEN[config]}" 40 "$fix"
  fi
  if [[ -n "${GIVEN[config]:-}" && ! -d "${GIVEN[config]}" ]]; then
    die "the --config folder does not exist: ${GIVEN[config]}" 40 "$fix"
  fi
  host="$(lab_host)" || host=''
  host_lookup "$host" || rc=$?
  (( rc == 0 )) || return 0           # not listed: plan may still run
  case "$LAB_HOST_PLATFORM" in
    ubuntu | rhel-family) ;;
    appliance) die "this host ($host) is an appliance: Labyrinth never changes it" 20 \
                 "Configure it by hand, from its runbook, or correct its line in $LAB_CONFIG_DIR/hosts" ;;
    *) die "this runner does not serve this host's platform, $LAB_HOST_PLATFORM" 20 \
         "Use the runner for $LAB_HOST_PLATFORM, or correct this host's line in $LAB_CONFIG_DIR/hosts" ;;
  esac
}

# resolve_profile: --profile, or this host's line in the hosts file.
resolve_profile() {
  host_lookup "$(lab_host)" || true
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
  lab_event_load 2>/dev/null || die "event.conf is malformed: $(load_reason lab_event_load)" 40 "$FIX_LINE"
  gate_protected
  flush_warnings
  printf 'labyrinth %s: plan %s, profile %s\n' "$LAB_VERSION" "$phase" "$OPT_PROFILE"
  printf 'run %s (plan mode: nothing is recorded)\n' "$LAB_RUN_ID"
  plan_all "$phase" || worst=$?
  finish plan "$worst" "$phase"
}

# recap HOST GROUP: what apply is about to do, before the group-name prompt.
recap() {
  local i what
  printf 'About to apply on host %s, group %s:\n' "$1" "$2"
  for ((i = 0; i < ${#RUN_IDS[@]}; i++)); do
    case "${RUN_RC[i]}" in
      10) what='will change'
          if [[ "${RUN_RISK[i]}" == manual-only ]]; then what='manual'; fi ;;
      20) what='blocked' ;;
      *) continue ;;
    esac
    printf '  %-12s %s\n' "$what" "${RUN_IDS[i]}"
  done
  printf 'Each change arms a revert timer that undoes the run in %s minutes\n' "${LAB_EVENT[REVERT_MINUTES]}"
  printf 'unless you keep it.\n'
}

cmd_apply() {
  local phase="$1" host group worst=0 rc i todo=0 stopped=0 due
  export LAB_DRY_RUN=1
  umask 077
  host="$(lab_host)"
  lab_is_admin || die 'apply needs root' 20 "$FIX_ADMIN"
  rc=0; host_lookup "$host" || rc=$?
  (( rc == 0 )) || die "this host is not in the hosts file, so its ring group is unknown" 20 \
    "Add the line '$host <group> <profile> <platform>' to $LAB_CONFIG_DIR/hosts"
  group="$LAB_HOST_GROUP"
  [[ "$group" != manual ]] || die "this host is in the manual group: Labyrinth never changes it" 20 \
    'Configure it by hand, from its runbook.'
  if [[ -n "$OPT_PROFILE" && "$OPT_PROFILE" != "$LAB_HOST_PROFILE" ]]; then
    die "the hosts file gives this host profile $LAB_HOST_PROFILE, not $OPT_PROFILE"
  fi
  OPT_PROFILE="$LAB_HOST_PROFILE"
  read_profile "$OPT_PROFILE"
  lab_event_load 2>/dev/null || die "event.conf is malformed: $(load_reason lab_event_load)" 40 "$FIX_LINE"
  gate_protected
  lab_lock_acquire 0 || exit 20
  trap 'lab_lock_release' EXIT
  flush_warnings

  printf 'labyrinth %s: APPLY %s, profile %s\n' "$LAB_VERSION" "$phase" "$OPT_PROFILE"
  printf 'run %s on host %s, group %s\n' "$LAB_RUN_ID" "$host" "$group"
  plan_all "$phase" || worst=$?
  (( worst < 40 )) || die 'the plan has errors; nothing was changed'
  for ((i = 0; i < ${#RUN_IDS[@]}; i++)); do
    if [[ "${RUN_RC[i]}" == 10 && "${RUN_RISK[i]}" != manual-only ]]; then todo=$((todo + 1)); fi
  done
  if (( todo == 0 )); then
    printf 'nothing to apply\n'
    finish apply "$worst" "$phase"
  fi

  gate_breakglass
  recap "$host" "$group"
  gate_confirm "$group"

  # From here on, changes are made: everything is recorded first.
  export LAB_DRY_RUN=0
  mkdir -p "$LAB_STATE_DIR/runs/$LAB_RUN_ID" "$LAB_BACKUP_DIR/$LAB_RUN_ID" \
    || die 'the run and backup folders cannot be created; nothing was changed' 20
  if ! record_for '' run_start "$host" "phase $phase, profile $OPT_PROFILE, group $group" \
      || ! record_for '' breakglass_verified "$BREAKGLASS"; then
    die 'the run manifest cannot be written; nothing was changed'
  fi
  RUN_OPEN=1 APPLIED=1
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

  STOPPED="$stopped"
  if (( stopped )); then
    run_stopped
  elif lab_timer_armed "$LAB_RUN_ID"; then
    printf 'All changes are applied and verified.\n'
    printf 'From a NEW session, check that you can still log in.\n'
    if due="$(lab_timer_due "$LAB_RUN_ID" 2> /dev/null)"; then
      printf 'The revert timer rolls this run back at %s UTC.\n' "${due:11:5}"
    fi
    if ask "Type keep to keep the changes; anything else leaves the revert timer to undo them in ${LAB_EVENT[REVERT_MINUTES]} minutes: " \
        && [[ "$ANSWER" == keep ]]; then
      keep_run || worst=$?
    else
      printf 'Not kept. To keep later: %s keep %s\n' "$SELF" "${LAB_RUN_ID: -4}"
      printf 'To undo now: %s rollback %s\n' "$SELF" "${LAB_RUN_ID: -4}"
    fi
  fi
  finish apply "$worst" "$phase"
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
    local when='' due
    if due="$(lab_timer_due "$LAB_RUN_ID" 2> /dev/null)"; then when=" at ${due:11:5} UTC"; fi
    printf 'labyrinth: the revert timer for run %s could not be cancelled\n' "$LAB_RUN_ID" >&2
    printf 'The run is not kept, and the timer still rolls it back%s.\n' "$when" >&2
    printf 'Retry: %s keep %s\n' "$SELF" "${LAB_RUN_ID: -4}" >&2
    return 40
  fi
  if ! record_for '' run_kept; then
    lab_lock_release
    printf 'labyrinth: the keep of run %s could not be recorded\n' "$LAB_RUN_ID" >&2
    printf 'Its revert timer is cancelled, so the changes stay.\n' >&2
    return 40
  fi
  lab_log_info run_kept "changes kept; revert timer cancelled"
  lab_lock_release
  printf 'kept: the revert timer for run %s is cancelled\n' "$LAB_RUN_ID"
}

# list_runs: this host's run IDs, oldest first; only runs with a manifest,
# because a plan writes nothing.
list_runs() {
  local d id
  for d in "$LAB_STATE_DIR"/runs/*/; do
    id="${d%/}"; id="${id##*/}"
    if [[ "$id" =~ $RE_RUN_ID && -f "$d/manifest.jsonl" ]]; then printf '%s\n' "$id"; fi
  done
}

# run_state RUN: the run's state, the first that applies: rolled back,
# kept, armed (with when the timer fires), or not kept, no timer.
run_state() {
  local f due now line note
  f="$(lab_manifest_file "$1")"
  line="$(grep '"action":"run_rolled_back"' "$f" 2> /dev/null | tail -n 1)" || true
  if [[ -n "$line" ]]; then
    note="$(lab_json_get "$line" note)" || note=''
    if [[ "$note" == 'exit 0' ]]; then printf 'rolled back\n'; else printf 'rolled back with errors\n'; fi
    return 0
  fi
  if grep -q '"action":"run_kept"' "$f" 2> /dev/null; then printf 'kept\n'; return 0; fi
  if lab_timer_armed "$1"; then
    if ! due="$(lab_timer_due "$1")"; then printf 'armed: rollback time unknown\n'; return 0; fi
    now="$(lab_now)"
    # The times are UTC in one fixed format, so they compare as strings.
    if [[ "$due" > "$now" ]]; then
      printf 'armed: rolls back at %s UTC\n' "${due:11:5}"
    else
      printf 'armed: was due %s UTC\n' "${due:11:5}"
    fi
    return 0
  fi
  printf 'not kept, no timer\n'
}

# run_phase RUN: the phase the run applied, from its run_start entry.
run_phase() {
  local line note
  line="$(grep -m 1 '"action":"run_start"' "$(lab_manifest_file "$1")" 2> /dev/null)" || true
  note="$(lab_json_get "$line" note 2> /dev/null)" || note=''
  note="${note#phase }"; note="${note%%,*}"
  printf '%s\n' "${note:--}"
}

# print_runs RUN...: the runs table, at most 78 columns.
print_runs() {
  local id
  printf '%-21s %-7s %-16s %s\n' RUN PHASE 'START (UTC)' STATE
  for id in "$@"; do
    printf '%-21s %-7s %-16s %s\n' "$id" "$(run_phase "$id")" \
      "${id:0:4}-${id:4:2}-${id:6:2} ${id:9:2}:${id:11:2}" "$(run_state "$id")"
  done
}

cmd_runs() {
  local -a runs=()
  local list
  lab_is_admin || die 'runs needs root' 20 "$FIX_ADMIN"
  list="$(list_runs)" || die "the runs in $LAB_STATE_DIR/runs cannot be read"
  flush_warnings
  if [[ -n "$list" ]]; then mapfile -t runs <<< "$list"; fi
  if (( ${#runs[@]} == 0 )); then
    printf 'no runs on this host\n'
    printf 'Runs are recorded in %s/runs\n' "$LAB_STATE_DIR"
    exit 0
  fi
  print_runs "${runs[@]}"
  # The example names the newest armed run, the one most likely to be kept.
  local example="${runs[${#runs[@]}-1]}" armed
  armed="$(armed_runs)" || armed=''
  if [[ -n "$armed" ]]; then example="${armed##*$'\n'}"; fi
  printf "\nName a run by its last 4 characters, like '%s keep %s'.\n" "$SELF" "${example: -4}"
  exit 0
}

# resolve_run COMMAND REF: the full run ID REF names, in RUN_REF. REF is a
# full ID, or its last 4 characters if they match exactly one run.
resolve_run() {
  local cmd="$1" ref="${2,,}" id list
  local -a hits=()
  if [[ "$2" =~ $RE_RUN_ID ]]; then
    [[ -f "$LAB_STATE_DIR/runs/$2/manifest.jsonl" ]] \
      || usage_error "no run $2 on this host" "$cmd" "'$SELF runs' lists them."
    RUN_REF="$2"; return 0
  fi
  list="$(list_runs)" || die "the runs in $LAB_STATE_DIR/runs cannot be read"
  for id in $list; do
    if [[ "${id: -4}" == "$ref" ]]; then hits+=("$id"); fi
  done
  case "${#hits[@]}" in
    0) usage_error "no run ending in '$2' on this host" "$cmd" "'$SELF runs' lists them." ;;
    1) RUN_REF="${hits[0]}"
       printf 'using run %s\n' "$RUN_REF" ;;
    *) usage_error "'$2' ends more than one run; give the full ID" "$cmd" "'$SELF runs' lists them." ;;
  esac
}

# armed_runs: the runs whose revert timer is armed and not yet kept or
# rolled back.
armed_runs() {
  local id
  for id in $(list_runs); do
    if [[ "$(run_state "$id")" == armed* ]]; then printf '%s\n' "$id"; fi
  done
}

cmd_keep() {
  local rc=0 list
  local -a armed=()
  export LAB_DRY_RUN=0
  lab_is_admin || die 'keep needs root' 20 "$FIX_ADMIN"
  if [[ -z "$1" ]]; then
    # Without a run, keep the one run whose timer is armed (section 3.1).
    list="$(armed_runs)" || die "the runs in $LAB_STATE_DIR/runs cannot be read"
    if [[ -n "$list" ]]; then mapfile -t armed <<< "$list"; fi
    case "${#armed[@]}" in
      0) usage_error 'no run on this host has an armed revert timer' keep 'There is nothing to keep.' ;;
      1) RUN_REF="${armed[0]}"
         printf 'using run %s\n' "$RUN_REF" ;;
      *) print_runs "${armed[@]}" >&2
         usage_error 'more than one run has an armed revert timer' keep "Name one, like '$SELF keep ${armed[0]: -4}'." ;;
    esac
  else
    resolve_run keep "$1"
  fi
  export LAB_RUN_ID="$RUN_REF"
  [[ -f "$(lab_manifest_file)" ]] || die "no run $LAB_RUN_ID on this host"
  flush_warnings
  keep_run || rc=$?
  exit "$rc"
}

cmd_rollback() {
  local id rc=0 i list
  local -a mods=() runs=()
  export LAB_DRY_RUN=0
  umask 077
  if [[ -z "$1" ]]; then
    # Rollback always needs a run (decision D3): list them, change nothing.
    if ! lab_is_admin; then
      usage_error 'rollback needs a run ID, or its last 4 characters' rollback "As root, '$SELF runs' lists them."
    fi
    list="$(list_runs)" || true
    if [[ -z "$list" ]]; then
      usage_error 'rollback needs a run ID, or its last 4 characters' rollback 'There are no runs on this host.'
    fi
    mapfile -t runs <<< "$list"; print_runs "${runs[@]}" >&2
    usage_error 'rollback needs a run ID, or its last 4 characters' rollback 'Pick one from the list above.'
  fi
  lab_is_admin || die 'rollback needs root' 20 "$FIX_ADMIN"
  resolve_run rollback "$1"
  export LAB_RUN_ID="$RUN_REF"
  [[ -f "$(lab_manifest_file)" ]] || die "no run $LAB_RUN_ID on this host"
  flush_warnings
  # The revert timer must work even if a hung run still holds the lock.
  if lab_lock_acquire 120; then
    trap 'lab_lock_release' EXIT
  else
    printf 'warning: rolling back without the run lock\n' >&2
  fi
  # Captured, not read from a process substitution, so a failure is seen.
  list="$(lab_manifest_applied "$LAB_RUN_ID")" || die "the manifest of run $LAB_RUN_ID cannot be read" 40 'Nothing was rolled back.'
  if [[ -n "$list" ]]; then mapfile -t mods <<< "$list"; fi
  printf 'labyrinth %s - rolling back run %s\n' "$LAB_VERSION" "$LAB_RUN_ID"
  for ((i = ${#mods[@]} - 1; i >= 0; i--)); do
    id="${mods[i]}"
    [[ "$id" =~ $RE_MODULE_ID ]] || { printf 'skipping a bad module id in the manifest: %s\n' "$id"; rc=40; continue; }
    rollback_module "$id" || rc=40
  done
  # A timer left armed runs this rollback again, which is safe.
  if ! lab_timer_cancel "$LAB_RUN_ID"; then
    printf 'warning: the revert timer for run %s could not be removed\n' "$LAB_RUN_ID" >&2
    printf 'When it fires, it repeats this rollback, which is safe.\n' >&2
  fi
  if ! record_for '' run_rolled_back '' "exit $rc"; then
    printf 'labyrinth: rolled back, but the manifest cannot be written to record it\n' >&2
    rc=40
  fi
  lab_log_warn run_rolled_back "run rolled back, exit $rc"
  if (( rc == 0 )); then
    printf 'rollback finished: exit 0 (rolled back)\n'
  else
    printf 'rollback finished: exit %d (error)\n' "$rc"
  fi
  exit "$rc"
}

cmd_probe() {
  local out rc=0
  export LAB_DRY_RUN=1
  lab_event_load 2>/dev/null || die "event.conf is malformed: $(load_reason lab_event_load)" 40 "$FIX_LINE"
  # Loaded first and quietly, so a bad list is reported once, below.
  lab_services_load 2>/dev/null || rc=$?
  if (( rc == 0 )); then out="$(lab_probe_all)" || rc=$?; fi
  case "$rc" in
    0) ;;
    2) die "no service list at $LAB_CONFIG_DIR/services" 20 \
         'List the scored services there, one "name proto host port expect" per line.' ;;
    *) die "the service list is malformed: $(load_reason lab_services_load)" 40 \
         "$FIX_LINE" ;;
  esac
  flush_warnings
  probe_report "$out"
}

# probe_report OUTPUT: lab_probe_all's lines as status lines, then the
# Summary, Next and finished lines; exit 30 when a service failed.
probe_report() {
  local name result detail w out='' code=0
  local -A count=([OK]=0 [WARN]=0 [FAIL]=0)
  printf 'labyrinth %s: probe the scored services\n' "$LAB_VERSION"
  while read -r name result detail; do
    [[ -n "$name" ]] || continue
    case "$result" in pass) w=OK ;; fail) w=FAIL ;; *) w=WARN ;; esac
    count[$w]=$((${count[$w]} + 1))
    say "$w" "[$name] $result${detail:+: $detail}"
  done <<< "$1"
  for w in OK WARN FAIL; do
    if (( ${count[$w]} > 0 )); then out+="${out:+, }${count[$w]} $w"; fi
  done
  printf 'Summary: %s\n' "${out:-no services}"
  if (( count[FAIL] == 1 )); then
    printf "Next: bring the failed service back, then run '%s probe' again.\n" "$SELF"
    printf 'probe finished: exit 30 (a service failed)\n'
    exit 30
  elif (( count[FAIL] > 1 )); then
    printf "Next: bring the failed services back, then run '%s probe' again.\n" "$SELF"
    printf 'probe finished: exit 30 (%d services failed)\n' "${count[FAIL]}"
    exit 30
  fi
  printf 'probe finished: exit 0 (no service failed)\n'
  exit 0
}

main() {
  local cmd='' word='' lc phase
  parse_args "$@"
  set -- "${WORDS[@]+"${WORDS[@]}"}"
  if [[ -n "$PARSE_ERR" ]]; then
    # Point to the help of the command the line names, if it names one.
    lc="${1:-}"; lc="${lc,,}"
    if lab_in_list "$lc" "$PHASES"; then
      if [[ -n "${GIVEN[apply]+set}" ]]; then lc=apply; else lc=plan; fi
    elif ! lab_in_list "$lc" "$COMMANDS" || [[ "$lc" == help || "$lc" == version ]]; then
      lc=''
    fi
    usage_error "$PARSE_ERR" "$lc"
  fi

  # Work out the command; the whole line must parse before help is shown.
  if (( $# > 0 )); then
    lc="${1,,}"
    if lab_in_list "$lc" "$COMMANDS"; then
      cmd="$lc"; shift
    elif lab_in_list "$lc" "$PHASES"; then
      cmd=plan                        # compatibility: a phase alone
    else
      local hint
      hint="$(suggest "$lc" $COMMANDS $PHASES)"
      if [[ "$1" == '/?' ]]; then hint=help; fi
      usage_error "unknown command '$1'${hint:+ (did you mean '$hint'?)}"
    fi
  fi
  if [[ -n "${GIVEN[apply]+set}" ]]; then
    case "$cmd" in
      plan) [[ "${lc:-}" != plan ]] || usage_error "plan and --apply conflict; use '$SELF apply <phase>'" apply
            cmd=apply ;;
      apply) ;;
      '') usage_error '--apply needs a phase' apply ;;
      *) usage_error "--apply cannot be used with $cmd" "$cmd" ;;
    esac
  fi
  # The whole line must parse before help or the version is shown.
  local helping=0
  if [[ -n "${GIVEN[help]+set}" || -n "${GIVEN[version]+set}" ]]; then helping=1; fi
  local -a used=()
  case "$cmd" in
    '')
      if [[ -n "${GIVEN[help]+set}" ]]; then cmd_help ''; exit 0; fi
      if [[ -n "${GIVEN[version]+set}" ]]; then cmd_version; exit 0; fi
      {
        printf 'labyrinth: no command given\n'
        printf 'Start here:\n'
        printf '  1. %s help basics    what Labyrinth does, in plain words\n' "$SELF"
        printf '  2. %s plan lockout   what the first phase would change; safe\n' "$SELF"
        printf '  3. %s help           every command\n' "$SELF"
        printf 'Usage: %s <command> [<phase> | <run>] [options]\n' "$SELF"
      } >&2
      exit 40 ;;
    help)
      word="${1:-}"; word="${word,,}"
      if (( $# > 1 )); then
        if lab_in_list "$word" "$COMMANDS"; then
          usage_error "unexpected word '$2' after 'help $1'" "$word"
        fi
        usage_error "unexpected word '$2' after 'help $1'" help
      fi
      if [[ "$word" == basics ]]; then cmd_help basics; exit 0; fi
      if [[ "$word" == *.* ]]; then cmd_help_module "$word"; exit 0; fi
      if [[ -n "$word" ]] && ! lab_in_list "$word" "$COMMANDS"; then
        local hint
        hint="$(suggest "$word" basics $COMMANDS)"
        usage_error "no help for '$1'${hint:+ (did you mean '$hint'?)}"
      fi
      # 'help plan --help' is help on plan; 'help --help' is help on help.
      if [[ -z "$word" && -n "${GIVEN[help]+set}" ]]; then word=help; fi
      cmd_help "$word"; exit 0 ;;
    version)
      (( $# == 0 )) || usage_error "unexpected word '$1' after 'version'" version ;;
    plan | apply)
      if (( $# == 0 )); then
        (( helping )) || usage_error "$cmd needs a phase: lockout, observe, deceive or sustain" "$cmd"
      else
        phase="${1,,}"
        if [[ "$phase" == probe ]]; then usage_error "probe is a command, not a phase: run '$SELF probe'" probe; fi
        if ! lab_in_list "$phase" "$PHASES"; then
          local hint
          hint="$(suggest "$phase" $PHASES)"
          usage_error "unknown phase '$1'${hint:+ (did you mean '$hint'?)}" "$cmd"
        fi
        (( $# == 1 )) || usage_error "unexpected word '$2' after '$cmd $phase'" "$cmd"
      fi
      if [[ "$cmd" == plan ]]; then used=(profile); else used=(profile break-glass confirm-group); fi ;;
    keep | rollback)
      # Without a run, keep and rollback decide what to do (section 3.1).
      (( $# <= 1 )) || usage_error "unexpected word '$2' after '$cmd $1'" "$cmd"
      word="${1:-}"
      # A full run ID is accepted in any case, like its last 4 characters.
      if [[ "${word,,}" =~ ^[0-9]{8}t[0-9]{6}z-[0-9a-f]{4}$ ]]; then
        word="${word,,}"; word="${word:0:8}T${word:9:6}Z${word:16}"
      fi
      if [[ -n "$word" && ! "$word" =~ $RE_RUN_ID && ! "$word" =~ ^[0-9a-fA-F]{4}$ ]]; then
        usage_error "not a run ID: '$word' (give the ID or its last 4 characters)" "$cmd"
      fi ;;
    runs | probe)
      (( $# == 0 )) || usage_error "unexpected word '$1' after '$cmd'" "$cmd" ;;
  esac
  if [[ -n "${GIVEN[help]+set}" ]]; then cmd_help "$cmd"; exit 0; fi
  if [[ -n "${GIVEN[version]+set}" ]]; then cmd_version; exit 0; fi
  if [[ "$cmd" == version ]]; then cmd_version; exit 0; fi

  OPT_PROFILE="${GIVEN[profile]:-}"
  OPT_BREAKGLASS="${GIVEN[break-glass]:-}"
  OPT_CONFIRM="${GIVEN[confirm-group]:-}"
  DATA_ROOT="${GIVEN[root]:-/opt/labyrinth}"
  if [[ -n "$OPT_PROFILE" && ! "$OPT_PROFILE" =~ ^[a-z0-9-]+$ ]]; then
    usage_error "invalid profile name '$OPT_PROFILE' (lower-case letters, digits and -)" "$cmd"
  fi
  [[ "$DATA_ROOT" == /* ]] || usage_error "--root must be a full path, not '$DATA_ROOT'" "$cmd"
  [[ -z "${GIVEN[config]:-}" || "${GIVEN[config]}" == /* ]] || usage_error "--config must be a full path, not '${GIVEN[config]}'" "$cmd"

  # Noted now, printed by each command once its own checks pass.
  check_used "$cmd" "${used[@]+"${used[@]}"}"

  LAB_CONFIG_DIR="${GIVEN[config]:-$DATA_ROOT/etc}"
  LAB_STATE_DIR="$DATA_ROOT/state"
  LAB_LOG_DIR="$DATA_ROOT/logs"
  LAB_BACKUP_DIR="$DATA_ROOT/backup"
  LAB_RUN_ID="$(new_run_id)"
  export LAB_CONFIG_DIR LAB_STATE_DIR LAB_LOG_DIR LAB_BACKUP_DIR LAB_RUN_ID

  CMD="$cmd"
  case "$cmd" in plan | apply | probe) check_host ;; esac
  case "$cmd" in
    plan) cmd_plan "$phase" ;;
    apply) cmd_apply "$phase" ;;
    keep | rollback) "cmd_$cmd" "$word" ;;
    probe) cmd_probe ;;
    runs) cmd_runs ;;
  esac
}

main "$@"
