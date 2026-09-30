#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2001  # pass() never fails, so "A && pass || bad" is a safe if/else
# Runs the REAL (non-dry-run) web server + add-domain code against an installed nginx/apache,
# with a fake systemctl so it works in containers. DESTRUCTIVE: rewrites /etc/nginx, /etc/apache2
# and /var/www. Only run in a disposable container/VM:   DISPOSABLE=1 bash tests/integration.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
[[ ${DISPOSABLE:-0} == 1 && $EUID == 0 ]] || { echo "skipped (needs root and DISPOSABLE=1)"; exit 0; }

fail=0; pass() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
STUB=$(mktemp -d)
cat >"$STUB/systemctl" <<'EOF'
#!/bin/sh
svc=$2; [ "$svc" = "--quiet" ] && svc=$3
proc=$svc; [ "$svc" = "apache2" ] && proc=apache2
case "$1" in
  is-active) pgrep -x "$proc" >/dev/null ;;
  start|restart) case "$svc" in nginx) nginx ;; apache2) apachectl start ;; esac ;;
  reload) case "$svc" in nginx) nginx -s reload ;; apache2) apachectl graceful ;; esac ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUB/systemctl"
export PATH="$STUB:$PATH"
printf 'webserver\nadd_domain\n' > presets/_test.list
trap 'rm -f presets/_test.list; rm -rf "$STUB"; nginx -s stop 2>/dev/null; apachectl stop 2>/dev/null' EXIT

check_server() {  # <name> <domain> <type>
  local ws=$1 d=$2 type=$3 code
  echo "== real run: $ws / $type =="
  nginx -s stop 2>/dev/null; apachectl stop 2>/dev/null; sleep 1
  extra=(); [[ $type == proxy ]] && extra=(--port 3999)
  [[ $type == redirect ]] && extra=(--redirect-to https://example.org)
  if bash setup.sh --yes --preset _test --lang en --webserver "$ws" --domain "$d" --site-type "$type" "${extra[@]}" >/tmp/vps-int.out 2>&1; then
    pass "setup.sh finished without errors"
  else bad "setup.sh failed"; tail -n 25 /tmp/vps-int.out | sed 's/^/       /'; return; fi
  sleep 1
  c() { curl -s -o /tmp/body -w '%{http_code}' -H "Host: $1" "http://127.0.0.1$2"; }
  case $type in
    static) code=$(c "$d" /); [[ $code == 200 ]] && grep -q "$d is ready" /tmp/body && pass "site answers with the placeholder page" || bad "site ($code)" ;;
    proxy)  (cd /tmp && python3 -m http.server 3999 --bind 127.0.0.1 >/dev/null 2>&1 & echo $! >/tmp/py.pid); sleep 1
            code=$(c "$d" /); [[ $code == 200 ]] && pass "proxy reaches the app" || bad "proxy ($code)"; kill "$(cat /tmp/py.pid)" 2>/dev/null ;;
    redirect) code=$(c "$d" /x); [[ $code == 301 || $code == 302 ]] && pass "redirect answers" || bad "redirect ($code)" ;;
  esac
  c unknown.example.test / >/dev/null; grep -q "Server is running" /tmp/body && pass "unknown host gets the friendly page" || bad "catch-all page missing"
  # idempotency: a second run must succeed and change nothing important
  if bash setup.sh --yes --preset _test --lang en --webserver "$ws" --domain "$d" --site-type "$type" "${extra[@]}" >/tmp/vps-int2.out 2>&1; then pass "second run is safe (idempotent)"; else bad "second run failed"; tail -n 15 /tmp/vps-int2.out | sed 's/^/       /'; fi
}

check_server nginx  n1.example.test static
check_server nginx  n2.example.test proxy
check_server nginx  n3.example.test redirect
check_server apache a1.example.test static
check_server apache a2.example.test proxy

echo; (( fail )) && echo "INTEGRATION TESTS FAILED" || echo "integration tests passed"
exit $fail
