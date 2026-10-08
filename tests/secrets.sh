#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329  # has() is called through check/reject (SC2317 = shellcheck <=0.9, SC2329 = >=0.10)
# Passwords must never reach the log, the screen or a command line (CONTRIBUTING: "Safety").
# Uses stub "sudo" / "mysql" programs that record what they are given. No root, no real database.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
fail=0
pass() { echo "  ok   $*"; }
bad()  { echo "  FAIL $*"; fail=1; }
check()  { local d=$1; shift; if "$@"; then pass "$d"; else bad "$d"; fi; }
reject() { local d=$1; shift; if "$@"; then bad "$d"; else pass "$d"; fi; }
has() { grep -qF -- "$2" "$1"; }   # has <file> <literal text>

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export ROOT_DIR=$PWD LOG_FILE=$tmp/vps.log
# shellcheck disable=SC1091
source lib/common.sh; source lib/os.sh; source lib/i18n/en.sh
OS_ID=ubuntu; MEM_MB=2048; ASSUME_YES=1; VERSION="test"
source modules/ubuntu/40-database.sh

# Stub programs: record argv and stdin; optionally fail while echoing the secret like a SQL client may.
mkdir "$tmp/bin"
for b in sudo mysql; do
  cat > "$tmp/bin/$b" <<'STUB'
#!/usr/bin/env bash
{ printf 'ARGV:'; printf ' [%s]' "$@"; printf '\n'; } >>"$STUB_ARGV"
cat >>"$STUB_STDIN"
if [[ -n ${STUB_FAIL:-} ]]; then echo "ERROR 1064: syntax error near '$STUB_SECRET'" >&2; exit 1; fi
exit 0
STUB
  chmod +x "$tmp/bin/$b"
done
export PATH="$tmp/bin:$PATH" STUB_ARGV=$tmp/argv STUB_STDIN=$tmp/stdin
reset() { : >"$LOG_FILE"; : >"$STUB_ARGV"; : >"$STUB_STDIN"; }

SECRET="x'y\\z\"; DROP USER q; --"     # quote, backslash, double quote, semicolon, comment
CFG=(); CFG[wizard_count]=2
CFG[wizard_1_engine]=postgresql; CFG[wizard_1_db]=appdb; CFG[wizard_1_user]=appuser; CFG[wizard_1_pass]=$SECRET
CFG[wizard_2_engine]=mysql;      CFG[wizard_2_db]=appdb; CFG[wizard_2_user]=appuser; CFG[wizard_2_pass]=$SECRET

echo "== database wizard: the password is only ever sent through stdin =="
DRY_RUN=0; reset
res=$(run_create_database 2>&1); rc=$?
check  "wizard finishes"                                   test "$rc" -eq 0
reject "password is not in any command line"               has "$STUB_ARGV" "$SECRET"
reject "password is not in the log"                        has "$LOG_FILE" "$SECRET"
reject "password is not on the screen"                     grep -qF -- "$SECRET" <<<"$res"
check  "log says the input was hidden"                     has "$LOG_FILE" "(input hidden)"
check  "PostgreSQL gets it on stdin, quote doubled"        has "$STUB_STDIN" "WITH PASSWORD 'x''y\\z\"; DROP USER q; --';"
check  "MySQL gets it on stdin, backslash and quote escaped" has "$STUB_STDIN" "IDENTIFIED BY 'x''y\\\\z\"; DROP USER q; --';"
check  "psql keeps a failing exit status (ON_ERROR_STOP)"  has "$STUB_ARGV" "[ON_ERROR_STOP=1]"

echo "== --dry-run prints nothing secret either =="
DRY_RUN=1; reset
res=$(run_create_database 2>&1)
reject "password is not on the screen"                     grep -qF -- "$SECRET" <<<"$res"
reject "password is not in the log"                        has "$LOG_FILE" "$SECRET"
DRY_RUN=0

echo "== a failing command: error is reported, secret is masked =="
reset; export STUB_FAIL=1 STUB_SECRET=$SECRET
res=$(run_stdin "$SECRET" "CREATE USER u PASSWORD '$SECRET';" sudo -u postgres psql 2>&1); rc=$?
unset STUB_FAIL STUB_SECRET
reject "run_stdin returns the failing status"              test "$rc" -eq 0
reject "secret is masked in the log"                       has "$LOG_FILE" "$SECRET"
reject "secret is masked on the screen"                    grep -qF -- "$SECRET" <<<"$res"
check  "the log keeps the rest of the error"               has "$LOG_FILE" "ERROR 1064"

echo "== guard: no command line may carry a password =="
bad_lines=$(grep -rnE '^\s*run(_sh)? .*(PASSWORD|IDENTIFIED BY)' modules lib setup.sh || true)
check  "no run/run_sh line contains PASSWORD or IDENTIFIED BY" test -z "$bad_lines"
[[ -n $bad_lines ]] && echo "$bad_lines"

(( fail )) && echo "SECRET TESTS FAILED" || echo "secret tests passed"
exit $fail
