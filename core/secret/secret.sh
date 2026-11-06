# shellcheck shell=bash
# core/secret/secret.sh: new passwords, shown once on the operator's
# terminal for the offline record (design 04, section 2.3). Sourced through
# core/lib.sh.
#
# A module's standard output goes to the run log and its standard input is
# empty, so a password is written to the terminal directly and the answer
# is read from it. Nothing here logs, records or stores a password.

# The terminal primitives. Runner tests replace them with doubles.

# lab_tty_ok: is there a terminal to write to and read from?
lab_tty_ok() { ( exec 3<> /dev/tty ) 2> /dev/null; }

# lab_tty_write TEXT: write TEXT to the terminal, with no newline added.
lab_tty_write() { printf '%s' "$1" 2> /dev/null > /dev/tty; }

# lab_tty_read: one line typed at the terminal. Fails when the terminal is
# gone.
lab_tty_read() {
  local line
  IFS= read -r line < /dev/tty || return 1
  printf '%s\n' "$line"
}

# lab_tty_cols: the terminal's width in columns, read from the terminal
# itself; 80 when it cannot be read.
lab_tty_cols() {
  local size cols
  size="$(stty size < /dev/tty 2> /dev/null)" || size=''
  cols="${size#* }"
  if [[ "$cols" =~ ^[0-9]+$ ]] && (( cols > 0 )); then
    printf '%s\n' "$cols"
  else
    printf '80\n'
  fi
}

# lab_tty_rows TEXT WIDTH: print how many rows down the cursor moves while
# TEXT is written from the start of a row on a terminal WIDTH columns wide,
# counting long lines that wrap. A line that exactly fills the width counts
# one row more than it may take, so a clear never falls short.
lab_tty_rows() {
  local rest="$1" width="$2" line rows=0
  if [[ ! "$width" =~ ^[0-9]+$ ]] || (( width < 1 )); then width=80; fi
  while [[ "$rest" == *$'\n'* ]]; do
    line="${rest%%$'\n'*}"
    rows=$((rows + ${#line} / width + 1))
    rest="${rest#*$'\n'}"
  done
  rows=$((rows + ${#rest} / width))
  printf '%s\n' "$rows"
}

# lab_secret_new [LENGTH]: print a new password of LENGTH characters (14 to
# 64; 20 by default) from /dev/urandom. It uses letters, digits and -_.+=,
# leaves out characters easily mistaken when copied by hand (0 O 1 l I),
# starts with a letter, and has at least one of each kind. Capture it in a
# variable; never pass it on a command line.
lab_secret_new() {
  local len="${1:-20}" pw b bytes
  local chars='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789-_.+='
  local sym='[-_.+=]'
  if [[ ! "$len" =~ ^[0-9]+$ ]] || (( len < 14 || len > 64 )); then
    printf 'secret: the length must be 14 to 64, not %s\n' "$len" >&2
    return 40
  fi
  while :; do
    pw=''
    while (( ${#pw} < len )); do
      bytes="$(od -An -N64 -tu1 /dev/urandom)" || return 40
      for b in $bytes; do
        # 248 is 4 x 62: a byte above it would favour the first characters.
        if (( b < 248 )); then pw+="${chars:$((b % 62)):1}"; fi
        if (( ${#pw} == len )); then break; fi
      done
    done
    if [[ "$pw" =~ ^[A-Za-z] && "$pw" =~ [A-Z] && "$pw" =~ [a-z] && "$pw" =~ [0-9] && "$pw" =~ $sym ]]; then
      break
    fi
  done
  printf '%s\n' "$pw"
}

# lab_secret_can_show: can this run show a new password? Call it in apply
# before changing anything; without a terminal, change nothing and exit 20.
lab_secret_can_show() { lab_tty_ok; }

# lab_secret_show LABEL SECRET: show SECRET once on the terminal, wait until
# the operator types 'recorded', then clear it from the screen. Returns 20
# when there is no terminal, and 1 when the terminal goes before the answer:
# the module must then roll back the change, because nobody recorded it.
lab_secret_show() {
  local label="$1" secret="$2" answer typed shown prompt
  if ! lab_tty_ok; then
    printf 'secret: no terminal to show the new password on\n' >&2
    return 20
  fi
  prompt="  Type 'recorded' once it is in the offline record: "
  shown=$'\n'"  New password for $label, shown once:"$'\n\n'"      $secret"$'\n\n'
  lab_tty_write "$shown"
  while :; do
    lab_tty_write "$prompt"
    if ! answer="$(lab_tty_read)"; then
      lab_tty_write $'\n'
      return 1
    fi
    # The typed answer is echoed on the prompt's row, then Enter ends it.
    shown+="$prompt$answer"$'\n'
    answer="$(lab_trim "$answer")"
    if [[ "${answer,,}" == recorded ]]; then break; fi
  done
  # Back up over the rows shown (wrapped ones too) and clear to the end of
  # the screen.
  typed="$(lab_tty_rows "$shown" "$(lab_tty_cols)")"
  lab_tty_write $'\r\033['"$typed"$'A\033[J'
}
