#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2317,SC2329  # "A && pass || bad" is an if/else; stubs are called by the sourced code (SC2317 = shellcheck <=0.9, SC2329 = >=0.10); single quotes are intentional
# Feature-level tests: preset parsing, prompts that depend on other features, port-80 mapping,
# WSL detection and the fail2ban filter regex. No root, no changes to the system.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
export LOG_FILE=/tmp/vps-features.log
fail=0
pass() { echo "  ok   $*"; }
bad()  { echo "  FAIL $*"; fail=1; }
check() { local d=$1; shift; if "$@"; then pass "$d"; else bad "$d"; fi; }
reject() { local d=$1; shift; if "$@"; then bad "$d"; else pass "$d"; fi; }

# shellcheck source=../setup.sh
source ./setup.sh
DRY_RUN=1; ASSUME_YES=1
OS_ID=ubuntu; OS_VERSION=24.04
load_modules

echo "== presets =="
printf 'alpha\nbeta # comment\ngamma' > presets/_t.list          # no newline at the end
trap 'rm -f presets/_t.list' EXIT
load_preset _t
check "last preset line without trailing newline is read" test -n "${PRESET_SET[gamma]:-}"
check "comments and spaces are stripped"                  test -n "${PRESET_SET[beta]:-}"
for f in presets/*.list; do
  [[ $f == presets/_t.list ]] && continue
  while IFS= read -r id || [[ -n $id ]]; do
    id=${id%%#*}; id=${id//[[:space:]]/}
    [[ -z $id ]] && continue
    [[ " ${FEATURE_IDS[*]} " == *" $id "* ]] || bad "$f lists unknown feature '$id'"
  done <"$f"
done
pass "every preset entry is a registered feature"

echo "== prompts see features installed in the same run =="
_has_nginx() { return 1; }; _has_postgres() { return 1; }; _has_mysql() { return 1; }
SELECTED_SET=(); CFG=()
reject "nginx_jails refused when no nginx and none selected" prompt_nginx_jails
SELECTED_SET[webserver]=1; CFG[webserver]=apache
reject "nginx_jails refused when apache is the chosen web server" prompt_nginx_jails
CFG[webserver]=nginx
check  "nginx_jails accepted when nginx is installed in this run" prompt_nginx_jails
SELECTED_SET=()
reject "db_backup refused when no database anywhere" prompt_db_backup
SELECTED_SET[postgresql]=1
check  "db_backup accepted when PostgreSQL is selected" prompt_db_backup

echo "== port 80 owner mapping =="
check "nginx -> nginx"        test "$(_port80_web nginx)" = nginx
check "apache2 -> apache"     test "$(_port80_web apache2)" = apache
check "httpd (RHEL) -> apache" test "$(_port80_web httpd)" = apache
check "caddy -> caddy"        test "$(_port80_web caddy)" = caddy
check "unknown process -> empty" test -z "$(_port80_web haproxy)"
CFG=()
reject "port conflict defaults to cancel with --yes" _resolve_port80_conflict "t" haproxy

# "stop" path: choice is only recorded while asking; the service is stopped later in run_webserver
(
  ASSUME_YES=0
  ui_menu() { echo stop; }
  has_systemd() { return 0; }
  systemctl() { return 0; }
  CFG=()
  _resolve_port80_conflict t haproxy || exit 1
  [[ ${CFG[web_stop_unit]:-} == haproxy ]] || exit 2
  DRY_RUN=1; CFG[webserver]=nginx
  run_webserver_nginx() { :; }; ws_ufw_open() { :; }
  out=$(run_webserver 2>&1)
  [[ $out == *"systemctl disable --now haproxy"* ]]
) && pass "choosing 'stop' records the unit and run_webserver stops it" || bad "port 80 stop flow"
(
  ASSUME_YES=0
  ui_menu() { echo ignore; }
  has_systemd() { return 1; }
  CFG=()
  _resolve_port80_conflict t haproxy && [[ -z ${CFG[web_stop_unit]:-} ]]
) && pass "choosing 'ignore' continues without stopping anything" || bad "port 80 ignore flow"

echo "== supported platforms =="
os_rc() { local rc=0; OS_ID=$1 OS_VERSION=$2 os_check || rc=$?; echo "$rc"; }
for pair in "ubuntu 22.04" "ubuntu 24.04" "debian 12" "almalinux 9" "almalinux 8" "rocky 9" "rocky 8"; do
  # shellcheck disable=SC2086
  check "supported: $pair" test "$(os_rc $pair)" = 0
done
for pair in "ubuntu 20.04" "ubuntu 18.04" "debian 11" "debian 10"; do
  # shellcheck disable=SC2086
  check "end of life (3): $pair" test "$(os_rc $pair)" = 3
done
for pair in "debian 13" "ubuntu 26.04" "almalinux 10"; do
  # shellcheck disable=SC2086
  check "untested (1): $pair" test "$(os_rc $pair)" = 1
done
check "unsupported distro (2): arch" test "$(os_rc arch rolling)" = 2

# check_os on an end-of-life release: --yes only warns, interactive asks first
eol_check() { # <ASSUME_YES> <exit code of the yes/no dialog>
  ( ASSUME_YES=$1; ans=$2
    detect_os() { OS_ID=debian; OS_VERSION=11; OS_PRETTY="Debian 11"; return 0; }
    ui_yesno() { return "$ans"; }
    check_os )
}
out=$(eol_check 1 1 2>&1); rc=$?
check "EOL with --yes: continues" test "$rc" -eq 0
check "EOL with --yes: prints the warning" grep -q "end of life" <<<"$out"
out=$(eol_check 0 0 2>&1); rc=$?
check "EOL interactive, user says yes: continues" test "$rc" -eq 0
out=$(eol_check 0 1 2>&1); rc=$?
check "EOL interactive, user says no: stops" test "$rc" -eq 130

echo "== environment =="
check "WSL_DISTRO_NAME means WSL" env WSL_DISTRO_NAME=Ubuntu bash -c 'source lib/os.sh; is_wsl'
out=$(WSL_DISTRO_NAME=Ubuntu bash ./setup.sh --yes --dry-run --preset minimal --lang en 2>&1)
check "WSL is warned about but --yes keeps going" bash -c '[[ $1 == *"Windows Subsystem for Linux"* && $1 == *"==> [1/"* ]]' _ "$out"

echo "== fail2ban nginx-bad-request regex =="
if command -v python3 >/dev/null 2>&1; then
  for f in modules/ubuntu/70-ops.sh modules/almalinux/70-ops.sh; do
    python3 - "$f" <<'PY' && pass "$f: counts 400/444 only" || bad "$f: regex wrong"
import re, sys
src = open(sys.argv[1]).read()
rx = re.search(r'nginx-bad-request\.conf.*?^failregex = ([^\n]+)$', src, re.S | re.M).group(1)
rx = re.compile(rx.replace('<HOST>', r'(?P<host>\S+)'))
line = '203.0.113.9 - - [06/Oct/2026:10:00:00 +0700] "%s" %s 150 "-" "ua"'
must = [line % ('GET / HTTP/1.1', 400), line % ('\\x16\\x03\\x01', 400), line % ('GET / HTTP/1.1', 444)]
must_not = [line % ('GET /favicon.ico HTTP/1.1', 404), line % ('GET / HTTP/1.1', 200), line % ('GET / HTTP/1.1', 499)]
sys.exit(0 if all(rx.search(l) for l in must) and not any(rx.search(l) for l in must_not) else 1)
PY
  done
else
  echo "  skip python3 not installed"
fi

(( fail )) && echo "FEATURE TESTS FAILED" || echo "feature tests passed"
exit $fail
