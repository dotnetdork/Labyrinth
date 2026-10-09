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
# Options may come anywhere; 'labyrinth.sh help <command>' lists them.
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
readonly MODULE_KEYS='id title phase priority platforms risk touches_scored requires outputs spec pre_approvable keep_on_verify'
readonly -a REQUIRED_KEYS=(id title phase priority platforms risk touches_scored)
readonly RISKS='read-only reversible service-affecting approval manual-only'
readonly PLATFORMS='ubuntu rhel-family windows appliance'
readonly RE_RUN_ID='^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$'
readonly RE_MODULE_ID='^(lockout|observe|deceive|sustain)\.[a-z0-9_-]+$'
# An item line from an approval module's plan, and one --approve entry
# (docs/Conventions.md section 3.1).
readonly RE_ITEM=$'^item\t([a-z0-9-]+)\t([a-z0-9-]+)\t([0-9a-f]{12})\t(.*)$'
readonly RE_APPROVE='^(lockout|observe|deceive|sustain)\.[a-z0-9_-]+:[a-z0-9-]+@[0-9a-f]{12}$'

# The real path, links resolved: the revert timer runs labyrinth.sh from it
# as root, so it must name the folder lab_tree_trusted checks.
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
export LAB_ROOT
# shellcheck source=core/lib.sh
source "$LAB_ROOT/core/lib.sh"

declare -A MOD=()          # fields of the module.yml being read
declare -a PROFILE_IDS=()  # module ids from the profile, in order
ENTRY_RC=0                 # exit code of the last entry point run
APPROVED=''                # items approved for the module being applied
PRE=''                     # those of them a pre-approval rule approved
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
# How the operator started this program, so a hint can be pasted and run
# (docs/Conventions.md section 3.2): the path as typed, './' added when it
# was a bare name not on the PATH, quoted if it needs it, and 'sudo' in
# front when sudo started it.
SELF="$0"
if [[ "$SELF" != */* ]] && ! command -v -- "$SELF" > /dev/null 2>&1; then SELF="./$SELF"; fi
if [[ ! "$SELF" =~ ^[A-Za-z0-9_./+-]+$ ]]; then SELF="$(printf '%q' "$SELF")"; fi
if [[ -n "${SUDO_USER:-}" ]]; then SELF="sudo $SELF"; fi
readonly COMMANDS='plan apply keep rollback runs probe help version'

# The options, one row each (docs/Conventions.md section 3.1): the canonical
# name, the keys it is matched by (lower case, no dashes), and whether it
# takes a value.
readonly -a OPT_NAMES=(profile root config break-glass confirm-group approve apply all help version)
readonly -a OPT_KEYS=('profile profilename' root config breakglass 'confirmgroup confirm' approve apply all help version)
readonly -a OPT_VALUE=(1 1 1 1 1 1 0 0 0 0)
declare -A GIVEN=()        # canonical option name -> value given
declare -a WORDS=()        # the words that are not options, in order
PARSE_ERR=""                # the first option error, reported by main
ERROR_COUNT=0              # ERROR lines in the Summary, for the Next line
BEFORE=''                  # probe results before the first change
HAVE_SERVICES=0            # 1 when the scored-service list loaded
GAVE_REASON=0              # 1 when the last entry point ended with 'problem:'
declare -A TITLES=()       # module id -> its plain name, from module.yml
LOG_FILE=''                # the run's output.log, once its folder exists
LOG_ON=0                   # 1 when this command keeps a run log
LOG_BUF=''                 # log lines from before the run folder existed
readonly LOG_CAP=500       # most lines logged from one entry point

# The modules of this run, in run order, one array element per module.
# RUN_ITEMS holds the items an approval module's plan listed, one
# 'id<TAB>category<TAB>fingerprint<TAB>reason' line each, RUN_PREOK the
# categories its module.yml lets a pre-approval rule approve, and RUN_KEEP
# its keep_on_verify (true or false).
declare -a RUN_IDS=() RUN_DIR=() RUN_RISK=() RUN_SCORED=() RUN_REQUIRES=() RUN_RC=() RUN_STATE=() RUN_ITEMS=() RUN_PREOK=() RUN_KEEP=()

# cmd_help [COMMAND]: the help for every command, or for one, on stdout.
# Each topic is at most 18 lines (basics 24) of at most 78 columns, not
# counting the command in hints, with one Exit line and one Example line
# (docs/Conventions.md section 3.2).
cmd_help() {
  local where="Options:
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
Options: '$SELF help <command>' lists them; so does <command> -h.
Exit: 0 ok, 10 change needed, 20 blocked, 30 check failed, 40 error.
Example: $SELF plan lockout
Manual: the Linux parts of $LAB_ROOT/docs/manual/labyrinth.md
EOF
    ;;
    plan) cat <<EOF
Usage: $SELF plan <phase> [options]

Show what every module of the phase would change on this host.
Nothing is changed and nothing is written. <phase> is lockout,
observe, deceive or sustain. Needs root to read the configuration.

$where
  --profile NAME         use this profile, not the one in the hosts file

Exit: 0 nothing to do, 10 change needed, 20 blocked, 40 error.
Example: $SELF plan lockout
Compatibility: '$SELF <phase>' also plans.
EOF
    ;;
    apply) cat <<EOF
Usage: $SELF apply <phase> [options]

Plan, then ask you to name the break-glass account (first apply only)
and to type this host's group name. Then change, checking each change;
a revert timer undoes the run unless you keep it. Needs root.

$where
  --profile NAME         must match this host's line in the hosts file
  --break-glass NAME     answer the break-glass prompt
  --confirm-group GROUP  answer the group-name prompt
  --approve LIST         approve without asking: module:item@fingerprint,...

Exit: 0 done, 10 manual steps left, 20 blocked, 30 check failed, 40 error.
Blocked: not root, another run, host not in hosts, or a safety gate.
Example: $SELF apply lockout
Compatibility: '$SELF <phase> --apply' also applies.
EOF
    ;;
    keep) cat <<EOF
Usage: $SELF keep [<run>] [options]

Keep a run's changes: cancel its revert timer, then record the keep.
Without <run>, keep the one run whose timer is armed. <run> is a run
ID or its last 4 characters; '$SELF runs' lists them. Needs root.

$where

Exit: 0 kept or none armed, 20 blocked, 40 error.
Blocked: not root, a file another account can change, or too late
(the run was already rolled back).
Example: $SELF keep 4f2a
EOF
    ;;
    rollback) cat <<EOF
Usage: $SELF rollback <run> [options]

Undo what the run changed, newest change first. This is what the
revert timer runs. Safe to run twice. <run> is a run ID or its last
4 characters; '$SELF runs' lists them. Needs root.

$where
  --all                  also undo changes kept once they verified

Exit: 0 rolled back, 20 blocked, 40 error.
Blocked: not root, or a file another account can change.
Example: $SELF rollback 4f2a
EOF
    ;;
    runs) cat <<EOF
Usage: $SELF runs [options]

List this host's runs, oldest first: run ID, phase, start time (UTC)
and state: armed (and when it rolls back), kept, rolled back,
rolled back with errors, or not kept, no timer. 'armed: timer lost'
means the host restarted and nothing will undo the run by itself:
keep it or roll it back. Changes nothing; needs root.

$where

Exit: 0 listed, 20 not root, 40 error.
Example: $SELF runs
EOF
    ;;
    probe) cat <<EOF
Usage: $SELF probe [options]

Test every scored service once, the way the scoring engine would,
and print one line per service. Changes nothing. Needs root to read
the configuration.

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
2. Apply: '$SELF apply lockout' plans again, has you name the
   break-glass account the first time, asks you to type this host's
   group name, then makes the changes and checks each one.
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

Print the version of Labyrinth and which program printed it.
'-V' and '--version' do the same.

Exit: 0 printed.
Example: $SELF version
EOF
    ;;
  esac
}

cmd_version() { printf 'labyrinth %s (labyrinth.sh, for Linux)\n' "$LAB_VERSION"; }

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
    # Each error is "FILE: message" or "FILE:LINE: message", and the message
    # may hold ": " itself, so the known file name is taken off the front.
    items="${YML_ERR%%$'\n'*}"
    items="${items#"$dir/module.yml"}"
    hint=''
    if [[ "$items" =~ ^:([0-9]+): ]]; then hint=":${BASH_REMATCH[1]}"; items="${items#:"${BASH_REMATCH[1]}"}"; fi
    die "the module.yml of $id is not valid: ${items#: }" 40 \
      "Report the module to its author, or correct $dir/module.yml$hint"
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
  if [[ "${MOD[keep_on_verify]:-false}" == true ]]; then
    printf 'Kept once it verifies and no scored service got worse; the revert\n'
    printf 'timer then leaves it alone.\n'
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
  log_line "labyrinth: $1"
  if [[ -n "${3:-}" ]]; then printf '%s\n' "$3" >&2; log_line "$3"; fi
  exit "${2:-40}"
}

# How to get the rights a command needs.
FIX_ADMIN='Run it again as root, for example with sudo.'
FIX_LINE='Correct that line, then run the same command again.'
FIX_DATA='Check that the data folder is not full or read-only, then run the same command again.'
FIX_SERVICES='List the scored services there, one "name proto host port expect" per line.'

# load_reason LOADER [ARG...]: the first error line a configuration loader
# prints, run in a subshell so that nothing it sets is kept.
load_reason() { "$@" 2>&1 >/dev/null | head -n 1; }

# load_preapproved: read the pre-approval rules; a malformed file is an
# error, and a missing one approves nothing in advance.
load_preapproved() {
  local rc=0
  lab_preapproved_load 2>/dev/null || rc=$?
  if [[ "$rc" == 1 ]]; then
    die "pre-approved is malformed: $(load_reason lab_preapproved_load)" 40 "$FIX_LINE"
  fi
  return 0
}

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
  local when
  out 'The run stopped. Earlier changes stay until the revert timer undoes them.'
  if when="$(due_words "$LAB_RUN_ID")"; then
    out "The revert timer rolls this run back $when."
  fi
  out "To undo them now: $SELF rollback ${LAB_RUN_ID: -4}"
  out "To keep them now: $SELF keep ${LAB_RUN_ID: -4}"
  out 'If in doubt, undo them.'
}

# due_words RUN: when the run's revert timer fires, as 'at HH:MM UTC, in N
# minutes'. Returns 1 when the time is not known.
due_words() {
  local due at now mins
  due="$(lab_timer_due "$1" 2> /dev/null)" || return 1
  at="$(date -u -d "$due" +%s 2> /dev/null)" || at=''
  now="$(date -u +%s)"
  if [[ -z "$at" ]]; then printf 'at %s UTC' "${due:11:5}"; return 0; fi
  mins=$(( (at - now + 59) / 60 ))
  if (( mins > 1 )); then
    printf 'at %s UTC, in %d minutes' "${due:11:5}" "$mins"
  elif (( mins == 1 )); then
    printf 'at %s UTC, in 1 minute' "${due:11:5}"
  else
    printf 'at %s UTC, which is now' "${due:11:5}"
  fi
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
say() {
  local l
  printf -v l '%-9s%s' "$1" "$2"
  out "$l"
}

# out TEXT: one line to the operator, and to the run log unless NO_LOG is 1.
out() {
  printf '%s\n' "$1"
  if (( ! ${NO_LOG:-0} )); then log_line "$1"; fi
}

# err TEXT: one line on stderr, and to the run log.
err() { printf '%s\n' "$1" >&2; log_line "$1"; }

# safe_text TEXT: TEXT with a tab as a space and every other control
# character as '?', so the
# output of a module or of a probed service cannot move the cursor, clear
# a line or hide text, on the operator's screen or in the run log. A
# forged 'OK' line must never pass for the runner's own (section 3.2).
safe_text() {
  local s="$1"
  if [[ "$s" =~ [[:cntrl:]] ]]; then
    s="${s//$'\t'/ }"
    s="${s//[[:cntrl:]]/?}"
  fi
  printf '%s' "$s"
}

# detail LABEL TEXT: a labelled line under a status line (section 3.2).
# Long text wraps onto more lines with the same label, so that each line
# makes sense alone; a word longer than a line, such as a path, is not split.
detail() {
  local label="$1:" text head l
  text="$(safe_text "$2")"
  while (( ${#text} > 65 )); do
    head="${text:0:66}"; head="${head% *}"
    if [[ "$head" == "${text:0:66}" || -z "$head" ]]; then break; fi
    printf -v l '  %-11s%s' "$label" "$head"; out "$l"
    text="${text:${#head}+1}"
  done
  printf -v l '  %-11s%s' "$label" "$text"; out "$l"
}

# more ID: the last line of a WARN, BLOCKED, FAIL or ERROR block.
more() { detail More "$SELF help $1"; }

# log_ref: the run log's path, under a FAIL or ERROR line.
log_ref() { if [[ -n "$LOG_FILE" ]]; then detail Log "$LOG_FILE"; fi; }

# module_name ID: 'Title (id)', or the ID alone when its title is unknown.
module_name() {
  if [[ -n "${TITLES[$1]:-}" ]]; then printf '%s (%s)' "${TITLES[$1]}" "$1"; else printf '%s' "$1"; fi
}

# load_title ID: keep the title of module ID, if its module.yml reads.
load_title() {
  local dir="$LAB_ROOT/phases/${1%%.*}/modules/${1#*.}"
  YML_ERR=''
  if [[ -z "${TITLES[$1]:-}" ]] && read_module_yml "$dir/module.yml" && [[ -n "${MOD[title]:-}" ]]; then
    TITLES[$1]="${MOD[title]}"
  fi
  YML_ERR=''
}

# item_words ID CATEGORY FINGERPRINT REASON: an item as an Item line shows
# it: 'id@fingerprint (category): reason'.
item_words() { printf '%s@%s (%s)%s' "$1" "$3" "$2" "${4:+: $4}"; }

# label_line LINE: one line a module printed, as a labelled line. An item
# line is an Item; a line 'key: text', with a key from the label list,
# keeps that label; any other line is a Note (docs/Conventions.md section
# 3.2). Blank lines are dropped.
label_line() {
  local line="${1%$'\r'}" key
  if [[ -z "${line//[[:space:]]/}" ]]; then return 0; fi
  line="${line#"${line%%[![:space:]]*}"}"
  if [[ "$line" =~ $RE_ITEM ]]; then
    detail Item "$(item_words "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}")"
    return 0
  fi
  if [[ "$line" =~ ^([A-Za-z][A-Za-z ]*):[[:space:]]+(.*)$ ]]; then
    key="${BASH_REMATCH[1],,}"
    case "$key" in
      found | 'will do' | did | why | risk | problem | cause | fix | undo)
        detail "${key^}" "${BASH_REMATCH[2]}"; return 0 ;;
    esac
  fi
  detail Note "$line"
}

# is_problem_line LINE: is LINE a 'problem:' line?
is_problem_line() { [[ "${1,,}" =~ ^[[:space:]]*problem:[[:space:]] ]]; }

# has_label KEY TEXT: does TEXT have a 'KEY:' line?
has_label() { grep -qi "^[[:space:]]*$1:[[:space:]]" <<< "$2"; }

# log_line TEXT: add TEXT to the run log, or keep it until the log exists.
# A log that cannot be written never stops a run.
log_line() {
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s\n' "$1" >> "$LOG_FILE" 2> /dev/null || true
  elif (( LOG_ON )); then
    LOG_BUF+="$1"$'\n'
  fi
}

# log_open WHAT: open the run's output.log, readable by root only, with a
# line saying what writes to it, then the lines kept so far.
log_open() {
  local file="$LAB_STATE_DIR/runs/$LAB_RUN_ID/output.log"
  if ( umask 077; printf '%s %s: %s\n' "$(lab_now)" "labyrinth $LAB_VERSION" "$1" >> "$file" ) 2> /dev/null \
      && chmod 600 "$file" 2> /dev/null; then
    LOG_FILE="$file"
    if [[ -n "$LOG_BUF" ]]; then printf '%s' "$LOG_BUF" >> "$LOG_FILE" 2> /dev/null || true; fi
  fi
  LOG_BUF=''
}

# log_entry ID ENTRY: the raw output of an entry point (ENTRY_OUT) and its
# exit code, for the run log; at most LOG_CAP lines.
log_entry() {
  local n=0 line
  if [[ -z "$LOG_FILE" ]] && (( ! LOG_ON )); then return 0; fi
  if [[ -n "$ENTRY_OUT" ]]; then
    while IFS= read -r line; do
      n=$((n + 1))
      if (( n <= LOG_CAP )); then log_line "$1 $2| $(safe_text "${line%$'\r'}")"; fi
    done <<< "$ENTRY_OUT"
  fi
  if (( n > LOG_CAP )); then log_line "$1 $2: $((n - LOG_CAP)) more lines not logged"; fi
  log_line "$(date -u +%H:%M:%S) $1 $2 exited $ENTRY_RC"
}

# stream ID ENTRY: an entry point's output, as it comes: labelled lines to
# the operator, raw lines to the run log. Returns 0 when its last line was
# a 'problem:' line, and 1 when it was not.
stream() {
  local line last='' n=0 NO_LOG=1
  while IFS= read -r line || [[ -n "$line" ]]; do
    label_line "$line"
    n=$((n + 1))
    if (( n <= LOG_CAP )); then log_line "$1 $2| $(safe_text "${line%$'\r'}")"; fi
    if [[ -n "${line//[[:space:]]/}" ]]; then last="$line"; fi
  done
  if (( n > LOG_CAP )); then log_line "$1 $2: $((n - LOG_CAP)) more lines not logged"; fi
  is_problem_line "$last"
}

# summary MODE: how many modules ended with each status word, counted
# from the run's arrays, not from the lines printed.
summary() {
  local mode="$1" i w out='' notrun=0 total=0
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
    total=$((total + ${count[$w]}))
    if (( ${count[$w]} > 0 )); then out+="${out:+, }${count[$w]} $w"; fi
  done
  total=$((total + notrun))
  if (( notrun > 0 )); then out+="${out:+, }$notrun not run"; fi
  ERROR_COUNT="${count[ERROR]}"
  if (( total == 0 )); then
    out 'Summary: no modules.'
  elif (( total == 1 )); then
    out "Summary: 1 module: $out."
  else
    out "Summary: $total modules: $out."
  fi
}

# shell_word WORD: WORD, quoted if the shell would split or expand it.
shell_word() {
  if [[ "$1" =~ ^[A-Za-z0-9/._:@=-]+$ ]]; then printf '%s' "$1"; else printf "'%s'" "$1"; fi
}

# next_step MODE CODE PHASE: the one command to run next, if there is one.
next_step() {
  local mode="$1" code="$2" phase="$3" i manual=0 other=0 opts=''
  if [[ "$mode" == apply ]] && (( STOPPED )); then
    out 'Next: undo the earlier changes, or keep them, with the commands above.'
  elif [[ "$mode" == apply ]] && lab_timer_armed "$LAB_RUN_ID"; then
    out "Next: check you can log in from a NEW session, then '$SELF keep ${LAB_RUN_ID: -4}'."
  elif (( code == 40 )); then
    if (( ERROR_COUNT > 1 )); then
      out 'Next: fix the errors above, then run the same command again.'
    else
      out 'Next: fix the error above, then run the same command again.'
    fi
  elif (( code == 20 )); then
    out 'Next: clear what blocked it above, then run the same command again.'
  elif (( code == 10 )); then
    for ((i = 0; i < ${#RUN_IDS[@]}; i++)); do
      if [[ "${RUN_RC[i]}" != 10 ]]; then continue; fi
      if [[ "${RUN_RISK[i]}" == manual-only ]]; then manual=$((manual + 1)); else other=$((other + 1)); fi
    done
    if (( other == 0 )); then
      out 'Next: a person carries out the manual steps above; apply changes nothing.'
    elif [[ -z "${LAB_HOST_GROUP:-}" ]]; then
      out 'Next: list this host in the hosts file, with its group and profile;'
      out "  apply needs it there: $LAB_CONFIG_DIR/hosts"
    elif [[ -n "${GIVEN[profile]:-}" && "${GIVEN[profile]}" != "$LAB_HOST_PROFILE" ]]; then
      out "Next: apply uses this host's profile in the hosts file, $LAB_HOST_PROFILE."
      out "  To apply ${GIVEN[profile]}, change that line first: $LAB_CONFIG_DIR/hosts"
    else
      if [[ -n "${GIVEN[root]:-}" ]]; then opts+=" --root $(shell_word "${GIVEN[root]}")"; fi
      if [[ -n "${GIVEN[config]:-}" ]]; then opts+=" --config $(shell_word "${GIVEN[config]}")"; fi
      # A command too long for one line goes on a line of its own.
      if (( ${#SELF} + ${#phase} + ${#opts} + 13 > 78 )); then
        out 'Next:'
        out "  $SELF apply $phase$opts"
      else
        out "Next: $SELF apply $phase$opts"
      fi
    fi
  fi
}

# finish MODE CODE PHASE: the end of a plan or apply: Summary, what
# changed, the log, Next and the exit code with its meaning; then exit.
finish() {
  local mode="$1" code="$2" what i problems="$STOPPED"
  case "$mode:$code" in
    plan:0) what='nothing to do' ;;
    plan:10) what='change needed' ;;
    plan:40) what='error: a module could not be checked' ;;
    apply:0) what='done' ;;
    apply:10) what='manual steps needed' ;;
    *:20) what='blocked' ;;
    *:30) what='a check failed and that change was undone; earlier ones stay' ;;
    *) what='error' ;;
  esac
  out ''
  if [[ "$mode" == plan ]] || (( ! APPLIED )); then
    summary plan
    out 'Nothing on this host was changed.'
  else
    summary apply
    for ((i = 0; i < ${#RUN_IDS[@]}; i++)); do
      case "${RUN_STATE[i]}" in failed | error) problems=1 ;; esac
    done
    if (( problems )); then mark_problems; fi
  fi
  if [[ -n "$LOG_FILE" ]]; then out "Log: $LOG_FILE"; fi
  next_step "$mode" "$code" "$3"
  out "$mode finished: exit $code ($what)"
  exit "$code"
}

# mark_problems: note in the run folder that the run had problems, so
# that 'runs' points to its log.
mark_problems() {
  : > "$LAB_STATE_DIR/runs/$LAB_RUN_ID/problems" 2> /dev/null || true
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
# one it is a prefix of, else the nearest within an edit distance of 2, or
# of 1 for a word of 3 letters or fewer. Prints nothing when there is none.
suggest() {
  local word="$1" c best='' bestd=3 d
  local -a prefix=()
  shift
  [[ -n "$word" ]] || return 0
  if (( ${#word} < 4 )); then bestd=2; fi
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

# synonym WORD: the command an everyday word for it means, or nothing.
synonym() {
  case "$1" in
    undo | revert) printf 'rollback\n' ;;
    status | list) printf 'runs\n' ;;
    check | test) printf 'probe\n' ;;
    dry-run | dryrun) printf 'plan\n' ;;
  esac
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
      case "$key" in
        dryrun) parse_fail "unknown option '${w%%[=:]*}' (did you mean the command 'plan'?)"; continue ;;
        yes | force) parse_fail "unknown option '${w%%[=:]*}' (did you mean '--confirm-group'?)"; continue ;;
      esac
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
  for name in profile break-glass confirm-group approve; do
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
  if [[ -n "${MOD[pre_approvable]:-}" ]]; then
    items="$(list_items "${MOD[pre_approvable]}")" || { yml_error "$file" 'pre_approvable must be a list'; return 1; }
    [[ "${MOD[risk]}" == approval ]] || { yml_error "$file" 'pre_approvable is only for approval modules'; return 1; }
    for p in $items; do
      [[ "$p" =~ ^[a-z0-9-]+$ ]] || { yml_error "$file" "not a category: $p"; return 1; }
    done
  fi
  if [[ -n "${MOD[keep_on_verify]:-}" ]]; then
    lab_in_list "${MOD[keep_on_verify]}" 'true false' || { yml_error "$file" 'keep_on_verify must be true or false'; return 1; }
    if [[ "${MOD[keep_on_verify]}" == true ]] && ! lab_in_list "${MOD[risk]}" 'reversible service-affecting approval'; then
      yml_error "$file" 'keep_on_verify is only for a module that changes something'; return 1
    fi
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
    [[ "$line" =~ $RE_MODULE_ID ]] || die "$file:$n: not a module id: $line" 40 \
      'Each line is one module ID, such as lockout.ssh-config. Correct it, then run the same command again.'
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
# output, both streams, goes to the operator as it comes, as labelled lines
# (section 3.2), and to the run log; its stdin is empty, so it can never take
# an answer meant for the runner. Its exit code is left in ENTRY_RC, and
# whether it ended with a 'problem:' line in GAVE_REASON.
run_entry() {
  local dir="$1" entry="$2" id="$3" dry="${4:-1}"
  local -a st
  log_line "$(date -u +%H:%M:%S) $id $entry started"
  if LAB_MODULE_ID="$id" LAB_ENTRY="$entry" LAB_DRY_RUN="$dry" LAB_APPROVED="$APPROVED" \
      bash "$dir/$entry.sh" < /dev/null 2>&1 | stream "$id" "$entry"; then
    st=("${PIPESTATUS[@]}")
  else
    st=("${PIPESTATUS[@]}")
  fi
  ENTRY_RC="${st[0]}"
  if (( ${st[1]} == 0 )); then GAVE_REASON=1; else GAVE_REASON=0; fi
  log_line "$(date -u +%H:%M:%S) $id $entry exited $ENTRY_RC"
}

# capture_entry DIR ENTRY ID: run an entry point in plan mode, keeping its
# output in ENTRY_OUT, because the result line that goes above it is known
# only when it ends. Sets ENTRY_RC and GAVE_REASON like run_entry.
capture_entry() {
  local dir="$1" entry="$2" id="$3" line last=''
  ENTRY_RC=0
  ENTRY_OUT="$(LAB_MODULE_ID="$id" LAB_ENTRY="$entry" LAB_DRY_RUN=1 LAB_APPROVED="$APPROVED" \
    bash "$dir/$entry.sh" < /dev/null 2>&1)" || ENTRY_RC=$?
  while IFS= read -r line; do
    if [[ -n "${line//[[:space:]]/}" ]]; then last="$line"; fi
  done <<< "$ENTRY_OUT"
  if is_problem_line "$last"; then GAVE_REASON=1; else GAVE_REASON=0; fi
  log_entry "$id" "$entry"
}
ENTRY_OUT=''

# show_output [TEXT]: TEXT, or ENTRY_OUT, as labelled lines. The run log
# has the raw lines already.
show_output() {
  local text="${1-$ENTRY_OUT}" line NO_LOG=1
  if [[ -z "$text" ]]; then return 0; fi
  while IFS= read -r line; do label_line "$line"; done <<< "$text"
}

# failed ENTRY CODE SCRIPT: the Problem line after an entry point failed
# (design 00: a failing entry point prints a 'problem:' line last). Without
# one, the runner says it gave no reason, and where the script is.
failed() {
  local what="failed with exit code $2"
  if [[ "$2" == 20 ]]; then what='was blocked (exit code 20)'; fi
  if (( GAVE_REASON )); then
    detail Problem "its $1 script $what, for the reason above"
  else
    detail Problem "its $1 script $what and gave no reason"
    detail Script "$3"
  fi
}

# explain ENTRY CODE SCRIPT: in plan mode, what a failed entry point said:
# its labelled lines when it gave a reason; otherwise the runner's Problem
# line and its last 10 lines.
explain() {
  local line n=0
  if (( GAVE_REASON )); then show_output; return 0; fi
  failed "$1" "$2" "$3"
  if [[ -z "${ENTRY_OUT//[[:space:]]/}" ]]; then detail 'It said' nothing; return 0; fi
  while IFS= read -r line; do
    line="${line%$'\r'}"
    if [[ -n "${line//[[:space:]]/}" ]]; then detail 'It said' "$line"; n=$((n + 1)); fi
  done < <(printf '%s\n' "$ENTRY_OUT" | grep -v '^[[:space:]]*$' | tail -n 10)
}

# load_modules PHASE: read and check every module of PHASE in the profile,
# then put them in run order: by priority, P0 first, and in profile order
# within a priority. Returns 40 if any module is invalid.
load_modules() {
  local phase="$1" id name dir worst=0 p i entry needed line
  local -a ids=() dirs=() risks=() scored=() reqs=() prios=() preok=() keeps=()
  PHASE_COUNT=0 LOAD_ERRORS=0 LOAD_SKIPPED=0
  for id in "${PROFILE_IDS[@]+"${PROFILE_IDS[@]}"}"; do
    if [[ "${id%%.*}" != "$phase" ]]; then continue; fi
    PHASE_COUNT=$((PHASE_COUNT + 1))
    name="${id#*.}"
    dir="$LAB_ROOT/phases/$phase/modules/$name"
    if [[ ! -d "$dir" ]]; then
      say ERROR "$id"
      detail Problem 'module not found: the profile lists it, but there is no such module'
      detail Found "no folder $dir"
      detail Fix "correct the ID in profile $OPT_PROFILE, or add the module"
      LOAD_ERRORS=$((LOAD_ERRORS + 1)); worst=40; continue
    fi
    YML_ERR=''
    if ! read_module_yml "$dir/module.yml" || ! validate_module "$dir/module.yml" "$id" "$phase"; then
      say ERROR "$id"
      detail Problem 'invalid module.yml, so the module cannot be loaded'
      while IFS= read -r line; do
        if [[ -n "$line" ]]; then detail Found "${line#"$dir/"}"; fi
      done <<< "$YML_ERR"
      detail Fix "report the module to its author, or correct it in $dir"
      LOAD_ERRORS=$((LOAD_ERRORS + 1)); worst=40; continue
    fi
    TITLES[$id]="${MOD[title]}"
    if ! compgen -G "$dir/*.sh" > /dev/null; then
      say WARN "$(module_name "$id")"
      detail Found 'skipped: no Linux entry points; it runs on other hosts'
      more "$id"
      LOAD_SKIPPED=$((LOAD_SKIPPED + 1)); continue
    fi
    needed='check'
    case "${MOD[risk]}" in
      reversible | service-affecting | approval) needed='check apply verify rollback' ;;
    esac
    for entry in $needed; do
      if [[ ! -f "$dir/$entry.sh" ]]; then
        say ERROR "$(module_name "$id")"
        detail Problem "missing $entry.sh, which a module of risk ${MOD[risk]} needs"
        detail Fix 'report the module to its author'
        more "$id"
        LOAD_ERRORS=$((LOAD_ERRORS + 1)); worst=40; continue 2
      fi
    done
    # A module that never changes anything ships no entry point that does.
    if [[ "${MOD[risk]}" == read-only || "${MOD[risk]}" == manual-only ]]; then
      for entry in apply rollback cleanup; do
        if [[ -f "$dir/$entry.sh" ]]; then
          say ERROR "$(module_name "$id")"
          detail Problem "$entry.sh is not allowed: a ${MOD[risk]} module changes nothing"
          detail Fix 'report the module to its author'
          more "$id"
          LOAD_ERRORS=$((LOAD_ERRORS + 1)); worst=40; continue 2
        fi
      done
    fi
    ids+=("$id"); dirs+=("$dir"); risks+=("${MOD[risk]}"); scored+=("${MOD[touches_scored]}")
    reqs+=("$(list_items "${MOD[requires]:-[]}")"); prios+=("${MOD[priority]}")
    preok+=("$(list_items "${MOD[pre_approvable]:-[]}")"); keeps+=("${MOD[keep_on_verify]:-false}")
  done
  RUN_IDS=() RUN_DIR=() RUN_RISK=() RUN_SCORED=() RUN_REQUIRES=() RUN_RC=() RUN_STATE=() RUN_ITEMS=() RUN_PREOK=() RUN_KEEP=()
  for p in P0 P1 P2 P3; do
    for ((i = 0; i < ${#ids[@]}; i++)); do
      if [[ "${prios[i]}" != "$p" ]]; then continue; fi
      RUN_IDS+=("${ids[i]}"); RUN_DIR+=("${dirs[i]}"); RUN_RISK+=("${risks[i]}")
      RUN_SCORED+=("${scored[i]}"); RUN_REQUIRES+=("${reqs[i]}"); RUN_RC+=(0); RUN_STATE+=(planned); RUN_ITEMS+=('')
      RUN_PREOK+=("${preok[i]}"); RUN_KEEP+=("${keeps[i]}")
    done
  done
  return "$worst"
}

# plan_one INDEX: run check and, when a change is needed, plan; print the
# module's status line and its labelled lines. Returns the module's
# contract code and keeps it in RUN_RC.
plan_one() {
  local i="$1" id dir rc name said risk
  id="${RUN_IDS[i]}"; dir="${RUN_DIR[i]}"; risk="${RUN_RISK[i]}"
  name="$(module_name "$id")"
  rc=0
  capture_entry "$dir" check "$id"
  case "$ENTRY_RC" in
    0)  say OK "$name"
        if [[ -n "${ENTRY_OUT//[[:space:]]/}" ]]; then show_output; else detail Found 'nothing to do'; fi ;;
    10)
      said="$ENTRY_OUT"
      if [[ ! -f "$dir/plan.sh" ]]; then
        say ERROR "$name"; show_output
        detail Problem 'its check found a change to make, but plan.sh is missing'
        detail Fix 'report the module to its author; the others were still checked'
        more "$id"; rc=40
      else
        capture_entry "$dir" plan "$id"
        if [[ "$risk" == approval ]] && [[ "$ENTRY_RC" == 0 || "$ENTRY_RC" == 10 ]] && ! read_items "$i"; then
          say ERROR "$name"; show_output "$said"; show_output
          detail Problem "its plan listed an item wrongly: $ITEM_ERR"
          detail Fix 'report the module to its author; the others were still checked'
          more "$id"; RUN_RC[i]=40
          return 40
        fi
        case "$ENTRY_RC" in
          0 | 10)
            if [[ "$risk" == manual-only ]]; then
              say WARN "$name"
              detail Found 'this needs a person; Labyrinth will not change it'
            else
              say CHANGE "$name"
            fi
            show_output "$said"; show_output
            if [[ "$risk" == manual-only ]]; then
              more "$id"
            elif ! has_label risk "$said"$'\n'"$ENTRY_OUT"; then
              detail Risk "$(risk_words "$risk")"
            fi
            if [[ "$risk" == approval ]]; then
              pre_items "$i"
              if [[ -n "$PRE" ]]; then detail Note "pre-approved, so applied without asking: $(item_list "$PRE")"; fi
            fi
            rc=10 ;;
          20)
            say BLOCKED "$name"; show_output "$said"; explain plan 20 "$dir/plan.sh"
            detail Fix 'clear what blocked it, then run the same command again'
            more "$id"; rc=20 ;;
          *)
            say ERROR "$name"; show_output "$said"; explain plan "$ENTRY_RC" "$dir/plan.sh"
            detail Fix 'report the module to its author; the others were still checked'
            more "$id"; rc=40 ;;
        esac
      fi
      ;;
    20) say BLOCKED "$name"; explain check 20 "$dir/check.sh"
        detail Fix 'clear what blocked it, then run the same command again'
        more "$id"; rc=20 ;;
    *)  say ERROR "$name"; explain check "$ENTRY_RC" "$dir/check.sh"
        detail Fix 'report the module to its author; the others were still checked'
        more "$id"; rc=40 ;;
  esac
  RUN_RC[i]=$rc
  return "$rc"
}

# read_items INDEX: keep the items an approval module's plan listed
# (ENTRY_OUT) in RUN_ITEMS (docs/Conventions.md section 3.1). Returns 1,
# with the reason in ITEM_ERR, when an item line is malformed or an id is
# listed twice.
read_items() {
  local i="$1" line items='' seen=' '
  ITEM_ERR=''
  while IFS= read -r line; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    if [[ "$line" != item$'\t'* ]]; then continue; fi
    if [[ ! "$line" =~ $RE_ITEM ]]; then
      ITEM_ERR="not 'item', id, category, fingerprint and reason, separated by tabs: ${line//$'\t'/ }"
      return 1
    fi
    if [[ "$seen" == *" ${BASH_REMATCH[1]} "* ]]; then
      ITEM_ERR="the id ${BASH_REMATCH[1]} is listed twice"
      return 1
    fi
    seen+="${BASH_REMATCH[1]} "
    items+="${BASH_REMATCH[1]}"$'\t'"${BASH_REMATCH[2]}"$'\t'"${BASH_REMATCH[3]}"$'\t'"${BASH_REMATCH[4]}"$'\n'
  done <<< "$ENTRY_OUT"
  RUN_ITEMS[i]="$items"
}
ITEM_ERR=''

# item_fp INDEX ID: the fingerprint the plan of module INDEX gave item ID;
# returns 1 when its plan did not list it.
item_fp() {
  local id fp
  while IFS=$'\t' read -r id _ fp _; do
    if [[ -n "$id" && "$id" == "$2" ]]; then printf '%s' "$fp"; return 0; fi
  done <<< "${RUN_ITEMS[$1]}"
  return 1
}

# pre_items INDEX: the items of module INDEX that a pre-approval rule
# approves, as 'id@fingerprint' words in PRE, with this run's fingerprints.
# A rule counts only for a category the module's pre_approvable lists
# (docs/Conventions.md section 3.1).
pre_items() {
  local i="$1" rule iid cat fp
  local -a r=()
  PRE=''
  for rule in "${LAB_PRE_RULES[@]+"${LAB_PRE_RULES[@]}"}"; do
    read -ra r <<< "$rule"
    if [[ "${r[0]}" != "${RUN_IDS[i]}" ]] || ! lab_in_list "${r[1]}" "${RUN_PREOK[i]}"; then continue; fi
    while IFS=$'\t' read -r iid cat fp _; do
      if [[ -z "$iid" || "$cat" != "${r[1]}" ]]; then continue; fi
      if [[ "${r[2]}" != '*' && "${r[2]}" != "$iid" ]]; then continue; fi
      if [[ " $PRE " != *" $iid@"* ]]; then PRE+="${PRE:+ }$iid@$fp"; fi
    done <<< "${RUN_ITEMS[i]}"
  done
}

# item_list WORDS: the ids of 'id@fingerprint' words, comma-separated.
item_list() {
  local word shown=''
  for word in $1; do shown+="${shown:+, }${word%@*}"; done
  printf '%s' "$shown"
}

# pre_unmatched: after the plan, each pre-approval rule for a module in this
# run whose module.yml does not let that category be pre-approved is
# ignored, with a line saying so. Rules for other modules are for other
# hosts, and are passed over in silence.
pre_unmatched() {
  local rule i said=0
  local -a r=()
  for rule in "${LAB_PRE_RULES[@]+"${LAB_PRE_RULES[@]}"}"; do
    read -ra r <<< "$rule"
    for ((i = 0; i < ${#RUN_IDS[@]}; i++)); do
      if [[ "${RUN_IDS[i]}" != "${r[0]}" ]] || lab_in_list "${r[1]}" "${RUN_PREOK[i]}"; then continue; fi
      if (( ! said )); then out ''; said=1; fi
      out "Pre-approval ignored: ${r[0]} does not let category ${r[1]} be pre-approved: $rule"
    done
  done
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
  pre_unmatched
  if (( PHASE_COUNT == 0 )); then
    say WARN "Phase $1"
    detail Found "profile $OPT_PROFILE lists no $1 modules: nothing to check"
    detail Fix "add $1 modules to the profile, or plan another phase"
    detail More "$SELF help basics"
  fi
  return "$worst"
}

# gate_trusted: only root may be able to change Labyrinth's code, its
# configuration and its data root, because they run as root, later too, by
# the revert timer (design 07, section 5).
gate_trusted() {
  local bad
  bad="$(lab_tree_trusted "$LAB_ROOT" "$LAB_CONFIG_DIR" "$DATA_ROOT")" && return 0
  die "$bad can be changed by an account other than root, so Labyrinth will not run as root from it" 20 \
    "Keep Labyrinth's folders owned by root and not writable by others ('chown -R root:' and 'chmod -R go-w'), in folders only root can change."
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
    log_line "$1(no answer)"
    return 1
  fi
  ANSWER="$(lab_trim "$ANSWER")"
  log_line "$1$ANSWER"
}

# gate_breakglass: before any change, the operator confirms the break-glass
# account still works (design 01, section 7).
gate_breakglass() {
  local account='' sid='' rc
  if account="$(lab_breakglass_recorded)"; then
    out "Break-glass account $account: confirmed earlier, so not asked again."
  else
    if [[ -n "$OPT_BREAKGLASS" ]]; then
      account="$OPT_BREAKGLASS"
    else
      out 'Before any change, check you can still get in if remote logins break.'
      out "Break-glass check: log in at this host's console with the break-glass"
      out 'account, then type its name here.'
      ask 'Break-glass account name: ' \
        || die 'no answer: break-glass not confirmed; nothing was changed' 20 \
          'Run apply again and answer the prompt, or name the account with --break-glass NAME.'
      account="$ANSWER"
    fi
    if [[ "$(lab_protected_class "$account" || true)" != breakglass ]]; then
      die "break-glass not confirmed: '$(safe_text "$account")' is not listed with class breakglass in $LAB_CONFIG_DIR/protected-accounts; nothing was changed" 20 \
        'Name the account you logged in with at the console; that file lists it as "NAME breakglass".'
    fi
    # Recorded only once the plan is confirmed (gate_confirm), so a run
    # that stops at the group prompt leaves nothing behind.
    BREAKGLASS_NEW=1
    # The answer is the operator's word. A session for the account at the
    # console backs it up; without one, the run goes on with a warning, and
    # the manifest says which it was.
    rc=0; sid="$(lab_console_session "$account")" || rc=$?
    case "$rc" in
      0) BREAKGLASS_NOTE="console session $sid"
         out "Break-glass account $account: confirmed." ;;
      1) BREAKGLASS_NOTE='no console session found'
         out "Break-glass account $account: confirmed."
         warn "no session for $account was found at this host's console; check that the break-glass login works before relying on it" ;;
      *) BREAKGLASS_NOTE='console sessions could not be listed'
         out "Break-glass account $account: confirmed."
         warn "this host cannot list console sessions, so the break-glass answer was not checked against one" ;;
    esac
  fi
  BREAKGLASS="$account"
}
BREAKGLASS=''
BREAKGLASS_NOTE='confirmed earlier'
BREAKGLASS_NEW=0           # 1 when this run asked, so the answer is recorded

gate_confirm() {
  local group="$1" typed
  if [[ -n "$OPT_CONFIRM" ]]; then
    typed="$OPT_CONFIRM"
  else
    ask "Type the group name ($group) to apply this plan: " || typed=''
    typed="$ANSWER"
  fi
  if [[ "$typed" != "$group" ]]; then
    if [[ -z "$typed" ]]; then typed='no group name was typed'; else typed="'$(safe_text "$typed")' was typed, not $group"; fi
    die "the plan was not confirmed: $typed; nothing was changed" 20 \
      "Run apply again and type $group at the prompt, or give it with --confirm-group $group."
  fi
  if (( BREAKGLASS_NEW )); then
    lab_breakglass_record "$BREAKGLASS" \
      || die 'the break-glass answer could not be recorded; nothing was changed' 40 "$FIX_DATA"
  fi
}

# services_missing: why there is no service list, for a message.
services_missing() {
  if [[ -f "$LAB_CONFIG_DIR/services" ]]; then
    printf '%s lists no service' "$LAB_CONFIG_DIR/services"
  else
    printf 'no service list at %s' "$LAB_CONFIG_DIR/services"
  fi
}

# check_services: a malformed service list is an error before anything is
# asked, in plan and apply alike; a missing or empty one is not.
check_services() {
  local rc=0
  lab_services_load 2> /dev/null || rc=$?
  if (( rc == 1 )); then
    die "the service list is malformed: $(load_reason lab_services_load)" 40 "$FIX_LINE"
  fi
  return 0
}

# probe_now: probe every scored service; print the results.
probe_now() {
  if (( HAVE_SERVICES )); then
    lab_probe_all
  fi
}

# probe_lines RESULTS [NAMES]: lab_probe_all's lines as Found lines; with
# NAMES, only those services, each of which passed before the change.
probe_lines() {
  local name result rest
  while read -r name result rest; do
    if [[ -z "$name" ]]; then continue; fi
    if (( $# > 1 )); then
      if ! grep -qx -- "$name" <<< "$2"; then continue; fi
      detail Found "$name: $result${rest:+ ($rest)}; it passed before"
    else
      detail Found "$name: $result${rest:+ ($rest)}"
    fi
  done <<< "$1"
}

# record_for ID ACTION [TARGET] [NOTE]: a manifest entry on a module's behalf.
record_for() { LAB_MODULE_ID="$1" lab_manifest_record "$2" "${3:-}" '' '' "${4:-}"; }

# rollback_module ID [inline]: undo one module's changes in the current run.
# Inline, under the FAIL or ERROR block of a failed apply, success is one
# Did line; otherwise the module gets its own CHANGE and OK lines.
rollback_module() {
  local id="$1" mode="${2:-own}" phase="${1%%.*}" dir rc=0 name
  dir="$LAB_ROOT/phases/$phase/modules/${id#*.}"
  name="$(module_name "$id")"
  if [[ "$mode" == own ]]; then
    say CHANGE "$name"
    detail 'Will do' 'undo what this run changed'
  fi
  if [[ -f "$dir/rollback.sh" ]]; then
    run_entry "$dir" rollback "$id" 0
    rc="$ENTRY_RC"
  else
    LAB_MODULE_ID="$id" lab_restore_files || rc=$?
  fi
  if (( rc == 0 )); then
    # Checked by hand: this function is called with ||, so errexit is off.
    if ! record_for "$id" rolled_back; then
      say ERROR "$name"
      detail Problem 'rolled back, but the manifest cannot be written'
      detail Found 'the manifest still lists the change; rolling back again is safe'
      detail Fix "run '$SELF rollback ${LAB_RUN_ID: -4}' again"
      log_ref; more "$id"
      return 40
    fi
    if [[ "$mode" == own ]]; then say OK "$name"; fi
    detail Did 'rolled back'
    LAB_MODULE_ID="$id" lab_log_warn rolled_back "rolled back" 2> /dev/null
    return 0
  fi
  say ERROR "$name"
  detail Problem "its rollback stopped with exit code $rc; the change may still be in place"
  if [[ -f "$dir/rollback.sh" ]]; then detail Script "$dir/rollback.sh"; fi
  detail Fix "restore its files by hand from $LAB_BACKUP_DIR/$LAB_RUN_ID/$id"
  log_ref; more "$id"
  LAB_MODULE_ID="$id" lab_log_error rollback_failed "rollback failed with exit $rc" 2> /dev/null
  return 40
}

# requires_met INDEX: did every module this one requires, in this run, finish?
requires_met() {
  local i="$1" req j
  for req in ${RUN_REQUIRES[i]}; do
    for ((j = 0; j < ${#RUN_IDS[@]}; j++)); do
      if [[ "${RUN_IDS[j]}" == "$req" && "${RUN_STATE[j]}" != 'done' && "${RUN_STATE[j]}" != planned ]]; then
        say BLOCKED "$(module_name "${RUN_IDS[i]}")"
        detail Problem "it needs $(module_name "$req") to finish first, and it did not"
        detail Fix 'fix that module first, then run the same command again'
        more "${RUN_IDS[i]}"
        return 1
      fi
    done
  done
}

# choose_items INDEX: the items of approval module INDEX that a person
# approved, as 'id@fingerprint' words in APPROVED (docs/Conventions.md
# section 3.1): those a pre-approval rule approves, then the --approve
# entries that name the module when it was given, otherwise the ids and
# categories typed at the prompt, which is not asked when every item is
# pre-approved. An --approve entry
# whose fingerprint differs from this run's plan is recorded as refused and
# left out. Returns 0 with something approved; 1, after an OK block, when
# nothing was; 20, after a BLOCKED block, when the answer is not ids and
# categories.
choose_items() {
  local i="$1" id name tok iid cat fp reason hit chosen=' ' rest
  local -a words=()
  id="${RUN_IDS[i]}"; name="$(module_name "$id")"
  APPROVED='' REFUSED='' PRE=''
  if [[ -z "${RUN_ITEMS[i]}" ]]; then
    say OK "$name"
    detail Did 'its plan listed no items to approve, so nothing changed'
    return 1
  fi
  pre_items "$i"
  for tok in $PRE; do chosen+="$tok "; done
  rest=0
  while IFS=$'\t' read -r iid _; do
    if [[ -n "$iid" && "$chosen" != *" $iid@"* ]]; then rest=1; fi
  done <<< "${RUN_ITEMS[i]}"
  if [[ -n "${GIVEN[approve]+set}" ]]; then
    IFS=',' read -ra words <<< "${GIVEN[approve]}"
    for tok in "${words[@]}"; do
      if [[ "${tok%%:*}" != "$id" ]]; then continue; fi
      tok="${tok#*:}"
      fp="$(item_fp "$i" "${tok%@*}")" || continue   # reported after the plan
      if [[ "$chosen" == *" ${tok%@*}@"* ]]; then continue; fi
      if [[ "$fp" != "${tok#*@}" ]]; then
        record_for "$id" approval_refused "${tok%@*}" "approved ${tok#*@}, changed since the plan; now $fp" || true
        REFUSED+="${tok%@*}"$'\n'
        continue
      fi
      chosen+="$tok "
    done
  elif (( rest )); then
    out "$name changes only the items you approve:"
    if [[ -n "$PRE" ]]; then detail Approved "$(item_list "$PRE") (pre-approved)"; fi
    while IFS=$'\t' read -r iid cat fp reason; do
      if [[ -z "$iid" || "$chosen" == *" $iid@"* ]]; then continue; fi
      detail Item "$(item_words "$iid" "$cat" "$fp" "$reason")"
    done <<< "${RUN_ITEMS[i]}"
    out 'Type the ids of the items to approve, separated by spaces. To approve'
    out 'every item of a category, type category: and its name.'
    ask 'Items to approve (Enter for none): ' || ANSWER=''
    read -ra words <<< "$ANSWER"
    for tok in ${words[@]+"${words[@]}"}; do
      if [[ ! "$tok" =~ ^(category:)?[a-z0-9-]+$ ]]; then
        say BLOCKED "$name"
        detail Problem "not an item id or a category: $tok"
        detail Fix 'type ids from its plan above, separated by spaces'
        more "$id"
        return 20
      fi
    done
    for tok in ${words[@]+"${words[@]}"}; do
      hit=0
      while IFS=$'\t' read -r iid cat fp reason; do
        if [[ -z "$iid" ]]; then continue; fi
        if [[ "$tok" == "$iid" || "$tok" == "category:$cat" ]]; then
          hit=1
          if [[ "$chosen" != *" $iid@"* ]]; then chosen+="$iid@$fp "; fi
        fi
      done <<< "${RUN_ITEMS[i]}"
      if (( ! hit )); then out "Not in its plan, so ignored: $tok"; fi
    done
  fi
  APPROVED="$(lab_trim "$chosen")"
  if [[ -z "$APPROVED" ]]; then
    say OK "$name"
    show_choice
    detail Did 'nothing approved, so nothing changed'
    return 1
  fi
}
REFUSED=''

# show_choice: under a module's status line, the items approved, each one a
# pre-approval rule approved marked so, and those left alone because they
# changed since the plan.
show_choice() {
  local word shown='' line
  for word in $APPROVED; do
    shown+="${shown:+, }${word%@*}"
    if [[ " $PRE " == *" $word "* ]]; then shown+=' (pre-approved)'; fi
  done
  if [[ -n "$shown" ]]; then detail Approved "$shown"; fi
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then detail Found "$line changed since the plan, so it is left alone"; fi
  done <<< "$REFUSED"
}

# approve_unmatched: after the plan, each --approve entry that names no item
# of an approval module in this run's plan is ignored, with a line saying so.
approve_unmatched() {
  local tok item i found said=0
  local -a words=()
  IFS=',' read -ra words <<< "${GIVEN[approve]}"
  for tok in "${words[@]}"; do
    item="${tok#*:}"; item="${item%@*}"; found=0
    for ((i = 0; i < ${#RUN_IDS[@]}; i++)); do
      if [[ "${RUN_IDS[i]}" == "${tok%%:*}" && "${RUN_RISK[i]}" == approval && "${RUN_RC[i]}" == 10 ]] \
          && item_fp "$i" "$item" > /dev/null; then
        found=1
      fi
    done
    if (( ! found )); then
      if (( ! said )); then out ''; said=1; fi
      out "Not in this run's plan, so ignored: $tok"
    fi
  done
}

# check_approve: each --approve entry must be <module-id>:<item-id>@<fingerprint>.
check_approve() {
  local tok fix='Copy each item from a plan: the module ID, a colon, then the item as its Item line shows it.'
  local -a words=()
  IFS=',' read -ra words <<< "${GIVEN[approve]},"
  for tok in "${words[@]}"; do
    if [[ "$tok" == *:category:* ]]; then
      usage_error "--approve takes no categories, only items: '$tok'" apply "$fix"
    fi
    [[ "$tok" =~ $RE_APPROVE ]] || usage_error "--approve: not <module-id>:<item-id>@<fingerprint>: '$tok'" apply "$fix"
  done
}

# apply_one INDEX: apply, verify and probe one module. Returns 0 (done or
# nothing to do), 20 (blocked; continue), or 30/40 (rolled back; stop).
apply_one() {
  local i="$1" id dir risk name after reg rc why line note
  id="${RUN_IDS[i]}"; dir="${RUN_DIR[i]}"; risk="${RUN_RISK[i]}"
  name="$(module_name "$id")"
  APPROVED='' PRE=''
  if [[ "$risk" == manual-only ]]; then
    say WARN "$name"
    detail Found 'this needs a person; Labyrinth changed nothing'
    detail Fix 'carry out the steps its plan listed above'
    more "$id"
    RUN_STATE[i]=manual; return 0
  fi
  if [[ "${RUN_SCORED[i]}" == true ]]; then
    # Only the check is needed here, so the loader runs in a subshell and
    # its reason is printed under the ERROR line.
    rc=0; why="$(lab_addrs_load scoring-allowlist 2>&1)" || rc=$?
    if (( rc == 1 )); then
      say ERROR "$name"
      detail Problem 'the scoring allowlist is malformed'
      while IFS= read -r line; do
        if [[ -n "$line" ]]; then detail Found "${line#"$LAB_CONFIG_DIR/"}"; fi
      done <<< "$why"
      detail Fix "$FIX_LINE"
      more "$id"
      RUN_STATE[i]=error; return 40
    fi
    if (( rc == 2 )); then
      say BLOCKED "$name"
      detail Problem 'it can affect a scored service, and the scoring allowlist is missing or empty'
      detail Fix "list the scoring addresses in $LAB_CONFIG_DIR/scoring-allowlist"
      more "$id"
      RUN_STATE[i]=blocked; return 20
    fi
    if (( ! HAVE_SERVICES )); then
      say BLOCKED "$name"
      detail Problem 'it can affect a scored service, and there is no service list to test it with'
      detail Fix "list the scored services in $LAB_CONFIG_DIR/services"
      more "$id"
      RUN_STATE[i]=blocked; return 20
    fi
  fi
  requires_met "$i" || { RUN_STATE[i]=blocked; return 20; }
  if [[ "$risk" == approval ]]; then
    rc=0; choose_items "$i" || rc=$?
    if (( rc == 1 )); then RUN_STATE[i]='done'; return 0; fi
    if (( rc == 20 )); then RUN_STATE[i]=blocked; return 20; fi
  fi
  if [[ ! -f "$dir/apply.sh" ]]; then
    say OK "$name"
    detail Found 'it has no apply step; nothing changed'
    RUN_STATE[i]='done'; return 0
  fi
  if [[ "$risk" != read-only ]]; then
    if ! lab_timer_arm "$((LAB_EVENT[REVERT_MINUTES] * 60))" "$LAB_RUN_ID" \
        "$BASH" "$LAB_ROOT/labyrinth.sh" --root "$(readlink -m -- "$DATA_ROOT")" \
        --config "$(readlink -m -- "$LAB_CONFIG_DIR")" rollback "$LAB_RUN_ID"; then
      say BLOCKED "$name"
      detail Problem 'the revert timer could not be armed, so nothing was changed'
      detail Fix 'check that systemd timers work on this host, then run the same command again'
      more "$id"
      RUN_STATE[i]=blocked; return 20
    fi
  fi

  # Checked by hand: errexit is off inside a function called with ||, and a
  # change the manifest does not list could never be rolled back.
  note="risk $risk"
  if [[ -n "$APPROVED" ]]; then note+=", approved $APPROVED"; fi
  if [[ -n "$PRE" ]]; then note+=", pre-approved $PRE"; fi
  if ! record_for "$id" apply_start '' "$note"; then
    say ERROR "$name"
    detail Problem 'not applied: the run manifest cannot be written'
    detail Fix "check that $LAB_STATE_DIR can be written, then run the same command again"
    log_ref; more "$id"
    RUN_STATE[i]=error; return 40
  fi
  LAB_MODULE_ID="$id" lab_log_info apply_start "applying"
  say CHANGE "$name"
  if [[ -n "$APPROVED" ]]; then show_choice; fi
  run_entry "$dir" apply "$id" 0
  case "$ENTRY_RC" in
    0) ;;
    20)
      say BLOCKED "$name"
      failed apply 20 "$dir/apply.sh"
      detail Found 'it stopped before changing anything'
      detail Fix 'clear what blocked it, then run the same command again'
      more "$id"
      record_for "$id" rolled_back '' 'apply blocked before any change'
      RUN_STATE[i]=blocked; return 20
      ;;
    *)
      say ERROR "$name"
      failed apply "$ENTRY_RC" "$dir/apply.sh"
      RUN_STATE[i]=error; rollback_module "$id" inline || true
      log_ref; more "$id"
      return 40
      ;;
  esac

  if [[ -f "$dir/verify.sh" ]]; then
    run_entry "$dir" verify "$id" 0
    rc="$ENTRY_RC"
    if (( rc != 0 )); then
      say FAIL "$name"
      failed verify "$rc" "$dir/verify.sh"
      LAB_MODULE_ID="$id" lab_log_error verify_failed "verify exited $rc" 2> /dev/null
      RUN_STATE[i]=failed; rollback_module "$id" inline || RUN_STATE[i]=error
      log_ref; more "$id"
      if (( rc == 30 )); then return 30; fi
      return 40
    fi
  fi

  if (( HAVE_SERVICES )); then
    after="$(probe_now)"
    reg="$(lab_probe_regressions "$BEFORE" "$after")"
    if [[ -n "$reg" ]]; then
      say FAIL "$name"
      detail Problem "a scored service stopped working after the change: ${reg//$'\n'/, }"
      probe_lines "$after" "$reg"
      LAB_MODULE_ID="$id" lab_log_error regression "scored service regressed: ${reg//$'\n'/ }" 2> /dev/null
      RUN_STATE[i]=failed; rollback_module "$id" inline || RUN_STATE[i]=error
      log_ref; more "$id"
      return 30
    fi
  fi

  if [[ -f "$dir/cleanup.sh" ]]; then
    run_entry "$dir" cleanup "$id" 0
    if (( ENTRY_RC != 0 )); then
      say WARN "$name"
      detail Problem "its cleanup script stopped with exit code $ENTRY_RC; the change is kept"
      more "$id"
    fi
  fi
  say OK "$name"
  detail Did 'applied and verified'
  LAB_MODULE_ID="$id" lab_log_info applied "applied and verified"
  if [[ "${RUN_KEEP[i]}" == true ]]; then keep_module "$id"; fi
  RUN_STATE[i]='done'
  return 0
}

# keep_module ID: keep a keep_on_verify module that verified, so the revert
# timer leaves it alone (docs/Conventions.md section 3.1). Only when the
# scored services were tested, so that none is known to have got worse.
# A failure leaves the module under the timer, which is the safe side.
keep_module() {
  local id="$1"
  if (( ! HAVE_SERVICES )); then
    detail Note 'not kept yet: with no service list, nothing shows that no scored service got worse, so the revert timer still covers it'
    return 0
  fi
  if ! record_for "$id" module_kept '' 'verified; no scored service got worse'; then
    detail Note 'not kept yet: the manifest cannot be written, so the revert timer still covers it'
    return 0
  fi
  detail Did 'kept: it verified and no scored service got worse, so the revert timer leaves it alone'
  LAB_MODULE_ID="$id" lab_log_info module_kept "kept once verified"
}

# unkept_modules: the modules of the current run that a rollback started
# by the revert timer would still undo.
unkept_modules() {
  local applied kept m
  applied="$(lab_manifest_applied "$LAB_RUN_ID")" || return 1
  kept="$(lab_manifest_kept "$LAB_RUN_ID")" || return 1
  for m in $applied; do
    lab_in_list "$m" "${kept//$'\n'/ }" || printf '%s\n' "$m"
  done
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
  if [[ ! -d "$LAB_CONFIG_DIR" ]]; then
    die "the configuration folder does not exist: $LAB_CONFIG_DIR" 40 \
      'Check --root, or give the folder with the hosts file with --config.'
  fi
  check_readable
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

# check_readable: every configuration file must be readable. One that is
# not would otherwise look missing or empty, which can quietly weaken a gate.
check_readable() {
  local f
  if [[ ! -r "$LAB_CONFIG_DIR" || ! -x "$LAB_CONFIG_DIR" ]]; then
    die "needs root to read $LAB_CONFIG_DIR" 20 "$FIX_ADMIN"
  fi
  for f in "$LAB_CONFIG_DIR"/* "$LAB_CONFIG_DIR"/profiles "$LAB_CONFIG_DIR"/profiles/*; do
    [[ -e "$f" ]] || continue
    if [[ ! -r "$f" ]] || [[ -d "$f" && ! -x "$f" ]]; then
      die "needs root to read $f" 20 "$FIX_ADMIN"
    fi
  done
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
  load_preapproved
  check_services
  gate_protected
  flush_warnings
  out "labyrinth $LAB_VERSION: plan $phase, profile $OPT_PROFILE"
  out "run $LAB_RUN_ID (plan mode: nothing is recorded)"
  plan_intro plan "$phase"
  plan_all "$phase" || worst=$?
  finish plan "$worst" "$phase"
}

# plan_intro MODE PHASE: after the two-line header, what happens next and
# how many modules are checked.
plan_intro() {
  local host n=0 id
  host="$(lab_host)"
  for id in "${PROFILE_IDS[@]+"${PROFILE_IDS[@]}"}"; do
    if [[ "${id%%.*}" == "$2" ]]; then n=$((n + 1)); fi
  done
  if [[ "$1" == plan ]]; then
    out "This is a plan: Labyrinth only looks, and nothing on $host changes."
    if [[ -n "${LAB_HOST_GROUP:-}" ]]; then
      out "Host $host is in group ${LAB_HOST_GROUP}."
    else
      out "Host $host is not in the hosts file; apply needs it there."
    fi
  else
    out 'First Labyrinth plans; nothing changes until you confirm.'
  fi
  if (( n == 1 )); then
    out "Checking 1 module of profile $OPT_PROFILE."
  else
    out "Checking $n modules of profile $OPT_PROFILE, most urgent first."
  fi
  out ''
}

# recap HOST GROUP: what apply is about to do, before the group-name prompt.
recap() {
  local i what l remote=0 kept=0
  out ''
  out "About to apply on host $1, group $2:"
  for ((i = 0; i < ${#RUN_IDS[@]}; i++)); do
    case "${RUN_RC[i]}" in
      10) what='Will change:'
          if [[ "${RUN_RISK[i]}" == manual-only ]]; then what='Manual:'; fi
          if [[ "${RUN_RISK[i]}" == service-affecting ]]; then remote=1; fi
          if [[ "${RUN_KEEP[i]}" == true ]]; then kept=1; fi ;;
      20) what='Blocked:' ;;
      *) continue ;;
    esac
    printf -v l '  %-13s%s' "$what" "$(module_name "${RUN_IDS[i]}")"
    out "$l"
  done
  out "A revert timer undoes this run in ${LAB_EVENT[REVERT_MINUTES]} minutes unless you keep it."
  if (( kept )); then
    out 'A change that only takes access away is kept once it verifies; the timer'
    out 'then leaves it alone.'
  fi
  if (( remote )) && [[ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ]]; then
    out 'You are connected over SSH, and a change may interrupt a service.'
    out 'Keep a second session open until you have checked you can log in.'
  fi
  out 'To go ahead, type the group name. Anything else stops here; nothing changes.'
}

cmd_apply() {
  local phase="$1" host group worst=0 rc i todo=0 stopped=0 when unkept
  export LAB_DRY_RUN=1
  umask 077
  host="$(lab_host)"
  lab_is_admin || die 'apply needs root' 20 "$FIX_ADMIN"
  gate_trusted
  rc=0; host_lookup "$host" || rc=$?
  (( rc == 0 )) || die "this host is not in the hosts file, so its ring group is unknown" 20 \
    "Add the line '$host <group> <profile> <platform>' to $LAB_CONFIG_DIR/hosts"
  group="$LAB_HOST_GROUP"
  [[ "$group" != manual ]] || die "this host is in the manual group: Labyrinth never changes it" 20 \
    'Configure it by hand, from its runbook.'
  if [[ -n "$OPT_PROFILE" && "$OPT_PROFILE" != "$LAB_HOST_PROFILE" ]]; then
    die "the hosts file gives this host profile $LAB_HOST_PROFILE, not $OPT_PROFILE" 40 \
      "Leave out --profile, or change this host's line in $LAB_CONFIG_DIR/hosts."
  fi
  OPT_PROFILE="$LAB_HOST_PROFILE"
  read_profile "$OPT_PROFILE"
  lab_event_load 2>/dev/null || die "event.conf is malformed: $(load_reason lab_event_load)" 40 "$FIX_LINE"
  load_preapproved
  check_services
  gate_protected
  lab_lock_acquire 0 || exit 20
  trap 'lab_lock_release' EXIT
  flush_warnings

  # The run log keeps every line from here; it is written once the run
  # folder exists, after the group is confirmed.
  LOG_ON=1
  out "labyrinth $LAB_VERSION: APPLY $phase, profile $OPT_PROFILE"
  out "run $LAB_RUN_ID on host $host, group $group"
  plan_intro apply "$phase"
  plan_all "$phase" || worst=$?
  if (( worst >= 40 )); then
    out ''
    out 'The plan has errors, so apply stops here.'
    finish apply "$worst" "$phase"
  fi
  if [[ -n "${GIVEN[approve]+set}" ]]; then approve_unmatched; fi
  for ((i = 0; i < ${#RUN_IDS[@]}; i++)); do
    if [[ "${RUN_RC[i]}" == 10 && "${RUN_RISK[i]}" != manual-only ]]; then todo=$((todo + 1)); fi
  done
  if (( todo == 0 )); then
    out ''
    out 'There is nothing to apply: no module needs a change Labyrinth can make.'
    finish apply "$worst" "$phase"
  fi

  gate_breakglass
  recap "$host" "$group"
  gate_confirm "$group"

  # From here on, changes are made: everything is recorded first.
  export LAB_DRY_RUN=0
  mkdir -p "$LAB_STATE_DIR/runs/$LAB_RUN_ID" "$LAB_BACKUP_DIR/$LAB_RUN_ID" \
    || die 'the run and backup folders cannot be created; nothing was changed' 40
  if ! record_for '' run_start "$host" "phase $phase, profile $OPT_PROFILE, group $group" \
      || ! record_for '' breakglass_verified "$BREAKGLASS" "$BREAKGLASS_NOTE"; then
    die 'the run manifest cannot be written; nothing was changed' 40 "$FIX_DATA"
  fi
  RUN_OPEN=1 APPLIED=1
  log_open "apply $phase, run $LAB_RUN_ID, host $host"
  lab_log_info run_start "apply $phase, profile $OPT_PROFILE, group $group"
  rc=0; lab_services_load 2> /dev/null || rc=$?
  (( rc != 1 )) || die "the service list is malformed; nothing was changed: $(load_reason lab_services_load)" 40 "$FIX_LINE"
  if (( rc == 0 )); then
    HAVE_SERVICES=1
    BEFORE="$(probe_now)"
    printf '%s\n' "$BEFORE" > "$LAB_STATE_DIR/runs/$LAB_RUN_ID/probes-before"
    out ''
    out 'Scored services before any change:'
    probe_lines "$BEFORE"
  else
    out ''
    out "No scored service is tested: $(services_missing)"
  fi
  out ''

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
  out ''
  if (( stopped )); then
    run_stopped
  elif lab_timer_armed "$LAB_RUN_ID" && unkept="$(unkept_modules)" && [[ -z "$unkept" ]]; then
    # Every change was kept once verified: the timer has nothing to undo.
    out 'All changes are applied, verified and kept.'
    keep_run || worst=$?
  elif lab_timer_armed "$LAB_RUN_ID"; then
    out 'All changes are applied and verified.'
    out 'From a NEW session, check that you can still log in.'
    if when="$(due_words "$LAB_RUN_ID")"; then
      out "The revert timer rolls this run back $when."
    fi
    if ask 'Type keep to keep the changes, or press Enter to leave them to the timer: ' \
        && [[ "$ANSWER" == keep ]]; then
      keep_run || worst=$?
    else
      out "Not kept. To keep later: $SELF keep ${LAB_RUN_ID: -4}"
      out "To undo now: $SELF rollback ${LAB_RUN_ID: -4}"
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
    err "labyrinth: too late: run $LAB_RUN_ID was already rolled back"
    err 'Its changes are gone. Plan and apply again if you still want them.'
    return 20
  fi
  # Checked by hand: errexit is off inside a function called with ||.
  if ! lab_timer_cancel "$LAB_RUN_ID"; then
    lab_lock_release
    local when=''
    if when="$(due_words "$LAB_RUN_ID")"; then when=" $when"; fi
    err "labyrinth: the revert timer for run $LAB_RUN_ID could not be cancelled"
    err "The run is not kept, and the timer still rolls it back$when."
    err "Retry: $SELF keep ${LAB_RUN_ID: -4}"
    return 40
  fi
  if ! record_for '' run_kept; then
    lab_lock_release
    err "labyrinth: the keep of run $LAB_RUN_ID could not be recorded"
    err 'Its revert timer is cancelled, so the changes stay.'
    return 40
  fi
  lab_log_info run_kept "changes kept; revert timer cancelled"
  lab_lock_release
  out "kept: the revert timer for run $LAB_RUN_ID is cancelled"
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
    # A reboot drops the transient timer; the run stays armed so keep and
    # rollback still find it, but nothing will roll it back by itself.
    if lab_timer_live "$1"; then :; elif [[ $? -eq 1 ]]; then
      printf 'armed: timer lost (restart?)\n'
      return 0
    fi
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
  list="$(list_runs)" || die "the runs in $LAB_STATE_DIR/runs cannot be read" 40 "$FIX_DATA"
  flush_warnings
  if [[ -n "$list" ]]; then mapfile -t runs <<< "$list"; fi
  if (( ${#runs[@]} == 0 )); then
    printf 'no runs on this host\n'
    printf 'Runs are recorded in %s/runs\n' "$LAB_STATE_DIR"
    exit 0
  fi
  print_runs "${runs[@]}"
  # The example names the newest armed run, the one most likely to be kept.
  local example="${runs[${#runs[@]}-1]}" armed id
  armed="$(armed_runs)" || armed=''
  if [[ -n "$armed" ]]; then example="${armed##*$'\n'}"; fi
  printf "\nName a run by its last 4 characters, like '%s keep %s'.\n" "$SELF" "${example: -4}"
  local -a probs=()
  for id in "${runs[@]}"; do
    if [[ -f "$LAB_STATE_DIR/runs/$id/problems" ]]; then probs+=("$id"); fi
  done
  if (( ${#probs[@]} > 0 )); then
    printf '\nThese runs had problems; their logs say what happened:\n'
    for id in "${probs[@]}"; do
      printf '  %s  %s\n' "${id: -4}" "$LAB_STATE_DIR/runs/$id/output.log"
    done
  fi
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
  list="$(list_runs)" || die "the runs in $LAB_STATE_DIR/runs cannot be read" 40 "$FIX_DATA"
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
  gate_trusted
  if [[ -z "$1" ]]; then
    # Without a run, keep the one run whose timer is armed (section 3.1).
    list="$(armed_runs)" || die "the runs in $LAB_STATE_DIR/runs cannot be read" 40 "$FIX_DATA"
    if [[ -n "$list" ]]; then mapfile -t armed <<< "$list"; fi
    case "${#armed[@]}" in
      0) out 'There is nothing to keep: no run on this host has an armed revert timer.'
         exit 0 ;;
      1) RUN_REF="${armed[0]}"
         printf 'using run %s\n' "$RUN_REF" ;;
      *) print_runs "${armed[@]}" >&2
         usage_error 'more than one run has an armed revert timer' keep "Name one, like '$SELF keep ${armed[0]: -4}'." ;;
    esac
  else
    resolve_run keep "$1"
  fi
  export LAB_RUN_ID="$RUN_REF"
  [[ -f "$(lab_manifest_file)" ]] || die "no run $LAB_RUN_ID on this host" 40 "'$SELF runs' lists them."
  flush_warnings
  umask 077
  log_open "keep run $LAB_RUN_ID"
  keep_run || rc=$?
  if [[ -n "$LOG_FILE" ]]; then out "Log: $LOG_FILE"; fi
  exit "$rc"
}

cmd_rollback() {
  local id rc=0 i list ok=0 bad=0 parts kept=''
  local -a mods=() runs=() left=() rest=()
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
  gate_trusted
  resolve_run rollback "$1"
  export LAB_RUN_ID="$RUN_REF"
  [[ -f "$(lab_manifest_file)" ]] || die "no run $LAB_RUN_ID on this host" 40 "'$SELF runs' lists them."
  flush_warnings
  # The revert timer must work even if a run still holds the lock, hung or
  # waiting at a prompt. That run is stopped first: rolling back beside it
  # would undo changes while it goes on making them and reports success.
  local locked=1
  if ! lab_lock_acquire 10; then
    lab_lock_stop_holder 30 || true
    lab_lock_acquire 10 || locked=0
  fi
  if (( locked )); then
    trap 'lab_lock_release' EXIT
  else
    warn 'rolling back without the run lock'
  fi
  # Captured, not read from a process substitution, so a failure is seen.
  list="$(lab_manifest_applied "$LAB_RUN_ID")" || die "the manifest of run $LAB_RUN_ID cannot be read" 40 'Nothing was rolled back.'
  if [[ -n "$list" ]]; then mapfile -t mods <<< "$list"; fi
  # Modules kept once verified stay, unless --all (section 3.1).
  if [[ -z "${GIVEN[all]+set}" ]]; then
    kept="$(lab_manifest_kept "$LAB_RUN_ID")" || die "the manifest of run $LAB_RUN_ID cannot be read" 40 'Nothing was rolled back.'
    for id in "${mods[@]+"${mods[@]}"}"; do
      if lab_in_list "$id" "${kept//$'\n'/ }"; then left+=("$id"); else rest+=("$id"); fi
    done
    mods=("${rest[@]+"${rest[@]}"}")
  fi
  # A rollback started by the revert timer is logged too, though no one watches it.
  log_open "rollback run $LAB_RUN_ID"
  out "labyrinth $LAB_VERSION: rollback run $LAB_RUN_ID"
  if (( ${#left[@]} > 0 )); then
    out 'Kept once verified, so left in place (add --all to undo these too):'
    for id in "${left[@]}"; do
      load_title "$id"
      out "  $(module_name "$id")"
    done
  fi
  case "${#mods[@]}" in
    0) if (( ${#left[@]} > 0 )); then out 'Nothing else needs undoing.'
       else out 'This run changed nothing that needs undoing.'; fi ;;
    1) out 'Undoing 1 module.' ;;
    *) out "Undoing ${#mods[@]} modules, newest change first." ;;
  esac
  out ''
  for ((i = ${#mods[@]} - 1; i >= 0; i--)); do
    id="${mods[i]}"
    if [[ ! "$id" =~ $RE_MODULE_ID ]]; then
      say ERROR 'Run manifest'
      detail Problem "it lists a bad module ID, which was skipped: $id"
      bad=$((bad + 1)); rc=40; continue
    fi
    load_title "$id"
    if rollback_module "$id"; then ok=$((ok + 1)); else bad=$((bad + 1)); rc=40; fi
  done
  # A timer left armed runs this rollback again, which is safe.
  if ! lab_timer_cancel "$LAB_RUN_ID"; then
    err "labyrinth: warning: the revert timer for run $LAB_RUN_ID could not be removed"
    err 'When it fires, it repeats this rollback, which is safe.'
  fi
  if ! record_for '' run_rolled_back '' "exit $rc"; then
    err 'labyrinth: rolled back, but the manifest cannot be written to record it'
    rc=40
  fi
  lab_log_warn run_rolled_back "run rolled back, exit $rc" 2> /dev/null
  if (( ok + bad > 0 )); then
    # Whoever is logged in learns that changes were undone; best effort.
    lab_notify_all "Labyrinth rolled back run $LAB_RUN_ID on $(lab_host): its changes are undone. See '$SELF runs'." || true
  fi
  out ''
  parts=''
  if (( ok > 0 )); then parts="$ok OK"; fi
  if (( bad > 0 )); then parts+="${parts:+, }$bad ERROR"; fi
  case "$((ok + bad))" in
    0) out 'Summary: no changes to undo.' ;;
    1) out "Summary: 1 module: $parts." ;;
    *) out "Summary: $((ok + bad)) modules: $parts." ;;
  esac
  if [[ -n "$LOG_FILE" ]]; then out "Log: $LOG_FILE"; fi
  if (( rc == 0 )); then
    out 'rollback finished: exit 0 (rolled back)'
  else
    mark_problems
    out 'Next: fix what is listed above, then run the rollback again; it is safe:'
    out "  $SELF rollback ${LAB_RUN_ID: -4}"
    out "rollback finished: exit $rc (error)"
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
    2) die "$(services_missing)" 20 "$FIX_SERVICES" ;;
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
      hint="$(synonym "$lc")"
      if [[ -z "$hint" ]]; then hint="$(suggest "$lc" $COMMANDS $PHASES)"; fi
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
  if [[ -n "${GIVEN[all]+set}" && -n "$cmd" && "$cmd" != rollback && "$cmd" != help ]]; then
    usage_error "--all is only for rollback, not $cmd" "$cmd"
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
        hint="$(synonym "$word")"
        if [[ -z "$hint" ]]; then hint="$(suggest "$word" basics $COMMANDS)"; fi
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
      if [[ "$cmd" == plan ]]; then used=(profile); else used=(profile break-glass confirm-group approve); fi ;;
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
  if [[ "$cmd" == apply && -n "${GIVEN[approve]+set}" ]]; then check_approve; fi

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
