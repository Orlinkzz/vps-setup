#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # pass() never fails (A && pass || bad is a safe if/else); the stub is single-quoted on purpose
# Tests templates/cloudflare/vps-setup-cloudflare-ips.sh against the real nginx / Apache config
# testers. Run as root (nginx -t opens /var/log/nginx). Servers that are not installed are skipped.
# Nothing is reloaded (--no-reload), so it is safe on a machine that already runs a web server.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
[[ $EUID == 0 ]] || { echo "skipped (needs root)"; exit 0; }
S=$PWD/templates/cloudflare/vps-setup-cloudflare-ips.sh
CONF=""
fail=0; pass() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
T=$(mktemp -d); trap 'rm -rf "$T"; [[ -n $CONF ]] && rm -f "$CONF"' EXIT

# A pretend "Cloudflare": one good list, one with an injection attempt in it.
mkdir "$T/good" "$T/bad"
printf '%s\n' 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 104.16.0.0/13 104.24.0.0/14 >"$T/good/ips-v4"
printf '%s\n' 2400:cb00::/32 2606:4700::/32 >"$T/good/ips-v6"
printf '%s\n' 103.21.244.0/22 'evil; deny all' >"$T/bad/ips-v4"
printf '%s\n' 2400:cb00::/32 >"$T/bad/ips-v6"

# --------------------------------------------------------------------------------- nginx
if command -v nginx >/dev/null 2>&1; then
  CONF=/etc/nginx/conf.d/01-vps-setup-cloudflare.conf; rm -f "$CONF"
  echo "== nginx =="
  CF_IPS_BASE=file://$T/good "$S" --server nginx --no-reload --quiet \
    && [[ $(grep -c '^set_real_ip_from' "$CONF") == 7 ]] && grep -q '^real_ip_header CF-Connecting-IP;' "$CONF" \
    && pass "live list rendered (5 IPv4 + 2 IPv6) and accepted by nginx -t" || bad "live list"

  m1=$(stat -c %Y "$CONF"); sleep 1
  CF_IPS_BASE=file://$T/good "$S" --server nginx --no-reload --quiet
  [[ $(stat -c %Y "$CONF") == "$m1" ]] && pass "second run changes nothing" || bad "file rewritten although nothing changed"

  CF_IPS_BASE=file://$T/bad "$S" --server nginx --no-reload --quiet
  if grep -q '173.245.48.0/20' "$CONF" && ! grep -q 'evil' "$CONF" && [[ $(grep -c '^set_real_ip_from' "$CONF") == 22 ]]; then
    pass "a list with a bad line is rejected, built-in ranges used"
  else bad "bad list was not rejected"; fi

  CF_IPS_BASE=file:///nonexistent "$S" --server nginx --no-reload --quiet
  [[ $(grep -c '^set_real_ip_from' "$CONF") == 22 ]] && pass "unreachable Cloudflare -> built-in ranges" || bad "no fallback"

  printf 'CF_EXTRA_TRUSTED="127.0.0.1 ::1"\n' >"$T/extra.conf"
  CF_SETTINGS=$T/extra.conf "$S" --server nginx --no-reload --quiet --bundled
  grep -q '^set_real_ip_from 127.0.0.1;' "$CONF" && pass "extra trusted proxy (Cloudflare Tunnel) added" || bad "extra trusted missing"

  printf 'CF_EXTRA_TRUSTED="1.2.3.4; evil"\n' >"$T/evil.conf"
  if CF_SETTINGS=$T/evil.conf "$S" --server nginx --no-reload --quiet --bundled 2>/dev/null; then bad "injection in CF_EXTRA_TRUSTED accepted"
  else pass "injection in CF_EXTRA_TRUSTED refused"; fi

  # nginx rejects the config -> the previous file must be put back untouched
  before=$(md5sum <"$CONF")
  mkdir "$T/stub"; real=$(command -v nginx)
  printf '#!/bin/sh\n[ "$1" = "-t" ] && { echo "nginx: [emerg] simulated failure" >&2; exit 1; }\nexec %s "$@"\n' "$real" >"$T/stub/nginx"
  chmod +x "$T/stub/nginx"
  if PATH=$T/stub:$PATH CF_IPS_BASE=file://$T/good "$S" --server nginx --no-reload --quiet 2>/dev/null; then bad "failure not reported"
  elif [[ $(md5sum <"$CONF") == "$before" ]]; then pass "failed config test -> previous config restored"
  else bad "config not restored after failure"; fi

  "$S" --server nginx --remove --no-reload --quiet
  [[ ! -e $CONF ]] && nginx -t >/dev/null 2>&1 && pass "--remove deletes the config and nginx still tests fine" || bad "--remove"
fi

# --------------------------------------------------------------------------------- apache
if command -v apache2ctl >/dev/null 2>&1 || command -v httpd >/dev/null 2>&1; then
  if [[ -d /etc/apache2 ]]; then CONF=/etc/apache2/conf-available/vps-setup-cloudflare.conf; else CONF=/etc/httpd/conf.d/01-vps-setup-cloudflare.conf; fi
  rm -f "$CONF"
  echo "== apache =="
  CF_IPS_BASE=file://$T/good "$S" --server apache --no-reload --quiet \
    && grep -q '^  RemoteIPHeader CF-Connecting-IP' "$CONF" && [[ $(grep -c 'RemoteIPTrustedProxy' "$CONF") == 7 ]] \
    && pass "apache config rendered and accepted by the config test" || bad "apache config"
  "$S" --server apache --remove --no-reload --quiet
  [[ ! -e $CONF ]] && pass "apache --remove" || bad "apache --remove"
fi

(( fail )) && echo "CLOUDFLARE TESTS FAILED" || echo "cloudflare tests passed"
exit $fail
