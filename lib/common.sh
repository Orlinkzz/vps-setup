#!/usr/bin/env bash
# shellcheck shell=bash
# Common helpers: logging, command runner, file writer, validators, registry.

: "${DRY_RUN:=0}"
: "${ASSUME_YES:=0}"
BACKUP_DIR=/var/backups/vps-setup
STATE_DIR=/var/lib/vps-setup

if [[ -z ${LOG_FILE:-} ]]; then
  LOG_FILE=/var/log/vps-setup.log
  { : >>"$LOG_FILE"; } 2>/dev/null || LOG_FILE="${TMPDIR:-/tmp}/vps-setup.log"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
fi

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""; C_BOLD=""
fi

# ------------------------------------------------------------------ registry
declare -ga FEATURE_IDS=()
declare -gA FEATURE_GROUP=() FEATURE_DEFAULT=() SELECTED_SET=() CFG=() RESULT=()
declare -gA MSG=()

# register_feature <id> <group> <on|off>
register_feature() {
  FEATURE_IDS+=("$1")
  FEATURE_GROUP[$1]=$2
  FEATURE_DEFAULT[$1]=$3
}

feature_selected() { [[ -n ${SELECTED_SET[$1]:-} ]]; }

# Call as the last thing a feature does when there is nothing to do.
# Exit code 10 means "skipped" to the runner.
feature_skip() { log_warn "$*"; return 10; }

# ------------------------------------------------------------------ i18n
# t <key> [printf args...]
t() {
  local key=$1
  shift
  local fmt=${MSG[$key]-$key}
  # shellcheck disable=SC2059
  printf -- "$fmt" "$@"
}

# ------------------------------------------------------------------ logging
_log_file() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$LOG_FILE" 2>/dev/null || true; }
log_info() { printf '%s•%s %s\n' "$C_BLUE" "$C_RESET" "$*"; _log_file INFO "$*"; }
log_ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; _log_file OK "$*"; }
log_warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; _log_file WARN "$*"; }
log_err()  { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; _log_file ERROR "$*"; }
log_step() { printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_RESET"; _log_file STEP "$*"; }
log_dry()  { printf '%s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$*"; _log_file DRY "$*"; }

die() { log_err "$*"; exit 1; }

# ------------------------------------------------------------------ runners
# run <cmd...>  — quiet execution, output goes to the log; honours --dry-run.
run() {
  if (( DRY_RUN )); then log_dry "$*"; return 0; fi
  _log_file CMD "$*"
  local rc=0
  "$@" </dev/null >>"$LOG_FILE" 2>&1 || rc=$?
  if (( rc != 0 )); then
    log_err "$(t err.cmd_failed "$*")"
    tail -n 12 "$LOG_FILE" | sed 's/^/    /' >&2 || true
    return "$rc"
  fi
  return 0
}

run_sh() { run bash -c "$1"; }

# run_stdin <secret> <stdin text> <cmd...>
# Like run, but the text reaches the command through stdin, not through its arguments. Use it for
# anything that carries a password (SQL with PASSWORD '...'): arguments show up in the process
# list and in the log, stdin does not. Only the command itself is logged, as "(input hidden)".
# <secret> is masked in the command's own output before that is logged, because some clients echo
# part of a failing statement; pass "" when there is nothing to mask.
run_stdin() {
  local secret=$1 input=$2; shift 2
  if (( DRY_RUN )); then log_dry "$* (input hidden)"; return 0; fi
  _log_file CMD "$* (input hidden)"
  local out rc=0
  out=$(printf '%s\n' "$input" | "$@" 2>&1) || rc=$?
  if [[ -n $secret ]]; then out=${out//"$secret"/********}; fi
  if [[ -n $out ]]; then printf '%s\n' "$out" >>"$LOG_FILE" 2>/dev/null || true; fi
  if (( rc != 0 )); then
    log_err "$(t err.cmd_failed "$* (input hidden)")"
    tail -n 12 "$LOG_FILE" | sed 's/^/    /' >&2 || true
    return "$rc"
  fi
  return 0
}

backup_file() {
  local f=$1
  [[ -e $f ]] || return 0
  if (( DRY_RUN )); then return 0; fi
  install -d -m 700 "$BACKUP_DIR"
  cp -a "$f" "$BACKUP_DIR/$(printf '%s' "$f" | tr / _).$(date +%Y%m%d%H%M%S)"
}

# _same_file <a> <b>: true when both files have identical content. Uses cmp, but minimal RHEL-family
# images (AlmaLinux / Rocky containers) ship without diffutils; the trailing "x" keeps the final
# newline, which $(...) would otherwise strip.
_same_file() {
  if command -v cmp >/dev/null 2>&1; then cmp -s "$1" "$2"; return; fi
  [[ $(cat "$1"; printf x) == "$(cat "$2"; printf x)" ]]
}

# write_file <path> [mode]  — content on stdin. Idempotent: skips if unchanged.
write_file() {
  local path=$1 mode=${2:-644} tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if [[ -f $path ]] && _same_file "$tmp" "$path"; then
    rm -f "$tmp"
    _log_file INFO "unchanged: $path"
    return 0
  fi
  if (( DRY_RUN )); then
    log_dry "write $path"
    rm -f "$tmp"
    return 0
  fi
  backup_file "$path"
  install -D -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
  _log_file INFO "wrote: $path"
}

state_mark() {
  if (( DRY_RUN )); then return 0; fi
  install -d -m 755 "$STATE_DIR" 2>/dev/null || return 0
  printf '%s %s %s\n' "$(date '+%F %T')" "$1" "$2" >>"$STATE_DIR/history.log" 2>/dev/null || true
}

# ------------------------------------------------------------------ validators
valid_username() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_hostname() { [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; }
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_ssh_port() { valid_port "$1" && { (( 10#$1 == 22 )) || (( 10#$1 >= 1024 )); }; }

valid_ssh_pubkey() {
  local key=$1 tmp rc=0
  local re='^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$'
  [[ $key =~ $re ]] || return 1
  if command -v ssh-keygen >/dev/null 2>&1; then
    tmp=$(mktemp)
    printf '%s\n' "$key" >"$tmp"
    ssh-keygen -l -f "$tmp" >/dev/null 2>&1 || rc=$?
    rm -f "$tmp"
    return "$rc"
  fi
  return 0
}

# valid_port_list "3000, 8080/tcp 51820/udp"
valid_port_list() {
  local tok list=${1//,/ }
  [[ -n ${list// /} ]] || return 1
  for tok in $list; do
    [[ $tok =~ ^([0-9]{1,5})(/(tcp|udp))?$ ]] || return 1
    valid_port "${BASH_REMATCH[1]}" || return 1
  done
}

# ------------------------------------------------------------------ templates
# render_tpl <file> KEY=value ...  → prints the file with {{KEY}} replaced.
# Fails if any {{PLACEHOLDER}} is left over (catches typos early).
render_tpl() {
  local f=$1 c kv
  shift
  [[ -r $f ]] || { log_err "template not found: $f"; return 1; }
  shopt -u patsub_replacement 2>/dev/null || true
  c=$(<"$f")
  for kv in "$@"; do
    c=${c//"{{${kv%%=*}}}"/${kv#*=}}
  done
  if [[ $c == *"{{"* ]]; then
    log_err "unreplaced placeholder in $f: $(printf '%s' "$c" | grep -o '{{[A-Z_]*}}' | sort -u | tr '\n' ' ')"
    return 1
  fi
  printf '%s\n' "$c"
}

# ------------------------------------------------------------------ settings
# Small key=value store so later runs (e.g. "add a domain") remember choices.
SETTINGS_FILE=/etc/vps-setup/settings.conf

setting_get() {
  [[ -f $SETTINGS_FILE ]] || return 0
  sed -n "s/^$1=//p" "$SETTINGS_FILE" | tail -n 1
}

setting_set() {
  local k=$1 v=$2 tmp
  if (( DRY_RUN )); then log_dry "setting $k=$v"; return 0; fi
  install -d -m 755 "$(dirname "$SETTINGS_FILE")"
  tmp=$(mktemp)
  { [[ -f $SETTINGS_FILE ]] && grep -v "^${k}=" "$SETTINGS_FILE"; printf '%s=%s\n' "$k" "$v"; } >"$tmp" || true
  install -m 644 "$tmp" "$SETTINGS_FILE"
  rm -f "$tmp"
}

# ------------------------------------------------------------------ more validators
valid_domain() {
  local re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
  (( ${#1} <= 253 )) && [[ $1 =~ $re ]]
}
valid_email() {
  local re='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
  [[ $1 =~ $re ]]
}
# normalize_domain "HTTPS://Example.com/path" → example.com
normalize_domain() {
  local d=${1,,}
  d=${d#http://}; d=${d#https://}; d=${d%%/*}; d=${d%%:*}; d=${d// /}
  printf '%s' "$d"
}
