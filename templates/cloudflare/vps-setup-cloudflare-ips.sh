#!/usr/bin/env bash
# Managed by vps-setup — restore the real visitor IP behind Cloudflare.
#
# Behind Cloudflare's proxy every request reaches the web server from a Cloudflare address; the
# visitor's IP is only in the CF-Connecting-IP header. This script tells nginx / Apache to trust
# that header, but ONLY when the request really comes from a Cloudflare range (so nobody else can
# spoof it), and keeps the range list fresh. Logs, fail2ban and your apps then see the real IP.
#
#   vps-setup-cloudflare-ips --server nginx|apache    write or refresh the config, test, reload
#   vps-setup-cloudflare-ips --server nginx --remove   remove the config again
#
# Options:  --quiet       print only errors
#           --no-reload   test the config but do not reload the web server
#           --bundled     do not use the network, use the built-in list
#
# Extra trusted proxies (e.g. 127.0.0.1 when you use a Cloudflare Tunnel / cloudflared) go in
# /etc/vps-setup/cloudflare.conf :   CF_EXTRA_TRUSTED="127.0.0.1 ::1"
#
# Environment (mostly for tests): CF_IPS_BASE (default https://www.cloudflare.com),
#   CF_CONF_FILE (override the config path), CF_SETTINGS (override the settings file).
set -uo pipefail

SERVER=""; REMOVE=0; QUIET=0; RELOAD=1; BUNDLED=0
while (( $# )); do
  case "$1" in
    --server)    SERVER=${2:-}; shift ;;
    --remove)    REMOVE=1 ;;
    --quiet)     QUIET=1 ;;
    --no-reload) RELOAD=0 ;;
    --bundled)   BUNDLED=1 ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ $SERVER == nginx || $SERVER == apache ]] || { echo "--server nginx|apache is required" >&2; exit 2; }

say() { (( QUIET )) || echo "$*"; }
die() { echo "cloudflare-ips: $*" >&2; exit 1; }

CF_IPS_BASE=${CF_IPS_BASE:-https://www.cloudflare.com}
CF_SETTINGS=${CF_SETTINGS:-/etc/vps-setup/cloudflare.conf}
CF_EXTRA_TRUSTED=""
# shellcheck disable=SC1090
[[ -r $CF_SETTINGS ]] && . "$CF_SETTINGS"

# ---------------------------------------------------------------- paths per web server / distro
APACHE_DEBIAN=0
[[ -d /etc/apache2 ]] && APACHE_DEBIAN=1
if [[ -n ${CF_CONF_FILE:-} ]]; then
  CONF=$CF_CONF_FILE
elif [[ $SERVER == nginx ]]; then
  CONF=/etc/nginx/conf.d/01-vps-setup-cloudflare.conf
elif (( APACHE_DEBIAN )); then
  CONF=/etc/apache2/conf-available/vps-setup-cloudflare.conf
else
  CONF=/etc/httpd/conf.d/01-vps-setup-cloudflare.conf
fi

web_test() {
  if [[ $SERVER == nginx ]]; then nginx -t
  elif (( APACHE_DEBIAN )); then apache2ctl configtest
  else httpd -t
  fi
}
web_unit() {
  if [[ $SERVER == nginx ]]; then echo nginx
  elif (( APACHE_DEBIAN )); then echo apache2
  else echo httpd
  fi
}
web_reload() {
  (( RELOAD )) || return 0
  local unit; unit=$(web_unit)
  if systemctl is-active --quiet "$unit" 2>/dev/null; then systemctl reload "$unit"; fi
}

# ---------------------------------------------------------------- remove
if (( REMOVE )); then
  if [[ $SERVER == apache ]] && (( APACHE_DEBIAN )) && command -v a2disconf >/dev/null 2>&1; then
    a2disconf vps-setup-cloudflare >/dev/null 2>&1 || true
  fi
  rm -f "$CONF"
  web_test >/dev/null 2>&1 || die "the config test fails after removal; check it with: $(web_unit) config test"
  web_reload || die "reload failed"
  say "Cloudflare real-IP config removed."
  exit 0
fi

# ---------------------------------------------------------------- the IP lists
# Built-in copy of https://www.cloudflare.com/ips-v4 and /ips-v6 (checked against Cloudflare's
# page, last update there: Sep 28, 2023). Used when the live list cannot be downloaded or looks
# wrong. The weekly refresh replaces it with the live list whenever the network allows.
FALLBACK_V4=(
  173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18
  108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17
  162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22
)
FALLBACK_V6=(
  2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32
  2a06:98c0::/29 2c0f:f248::/32
)

OCTET='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
RE_V4="^($OCTET\\.){3}$OCTET/([0-9]|[12][0-9]|3[0-2])$"
RE_V6='^[0-9a-fA-F:]*:[0-9a-fA-F:]*/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8])$'

# fetch_list <v4|v6> → prints the validated list; non-zero when it cannot be trusted.
fetch_list() {
  local kind=$1 re raw line n=0
  [[ $kind == v4 ]] && re=$RE_V4 || re=$RE_V6
  raw=$(curl -fsS --max-time 15 --retry 2 "$CF_IPS_BASE/ips-$kind" 2>/dev/null) || return 1
  while IFS= read -r line; do
    line=${line//$'\r'/}
    [[ -z $line ]] && continue
    [[ $line =~ $re ]] || return 1          # one odd line and the whole list is rejected
    echo "$line"; n=$((n + 1))
  done <<<"$raw"
  (( n >= 1 && n <= 100 ))
}

V4=(); V6=(); SOURCE=bundled
if (( ! BUNDLED )); then
  if l4=$(fetch_list v4) && l6=$(fetch_list v6) && [[ $(wc -l <<<"$l4") -ge 5 ]]; then
    mapfile -t V4 <<<"$l4"; mapfile -t V6 <<<"$l6"; SOURCE=live
  else
    say "Could not get a valid live list from Cloudflare; using the built-in ranges."
  fi
fi
if [[ $SOURCE == bundled ]]; then V4=("${FALLBACK_V4[@]}"); V6=("${FALLBACK_V6[@]}"); fi

EXTRA=()
for x in $CF_EXTRA_TRUSTED; do
  [[ $x =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]] || die "invalid address in CF_EXTRA_TRUSTED: $x"
  EXTRA+=("$x")
done

# ---------------------------------------------------------------- render
render() {
  local ip
  echo "# Managed by vps-setup — do not edit; rewritten by vps-setup-cloudflare-ips (list: $SOURCE)."
  echo "# Trusts the CF-Connecting-IP header only from Cloudflare's own addresses."
  if [[ $SERVER == nginx ]]; then
    for ip in "${V4[@]}" "${V6[@]}" ${EXTRA[@]+"${EXTRA[@]}"}; do echo "set_real_ip_from $ip;"; done
    echo "real_ip_header CF-Connecting-IP;"
  else
    echo "<IfModule mod_remoteip.c>"
    echo "  RemoteIPHeader CF-Connecting-IP"
    for ip in "${V4[@]}" "${V6[@]}" ${EXTRA[@]+"${EXTRA[@]}"}; do echo "  RemoteIPTrustedProxy $ip"; done
    echo "</IfModule>"
  fi
}

# ---------------------------------------------------------------- apply (with rollback)
install -d -m 755 "$(dirname "$CONF")"
NEW=$(mktemp); OLD=$(mktemp); trap 'rm -f "$NEW" "$OLD"' EXIT
render >"$NEW"
HAD_OLD=0
if [[ -f $CONF ]]; then
  HAD_OLD=1; cp -p "$CONF" "$OLD"
  if cmp -s "$NEW" "$CONF"; then
    say "Cloudflare ranges unchanged ($SOURCE list)."
    exit 0
  fi
fi

if [[ $SERVER == apache ]] && (( APACHE_DEBIAN )); then
  command -v a2enmod >/dev/null 2>&1 && a2enmod -q remoteip >/dev/null 2>&1
fi
install -m 644 "$NEW" "$CONF"
if [[ $SERVER == apache ]] && (( APACHE_DEBIAN )) && command -v a2enconf >/dev/null 2>&1; then
  a2enconf -q vps-setup-cloudflare >/dev/null 2>&1
fi

rollback() {
  if (( HAD_OLD )); then install -m 644 "$OLD" "$CONF"; else rm -f "$CONF"; fi
  if [[ $SERVER == apache ]] && (( APACHE_DEBIAN )) && (( ! HAD_OLD )) && command -v a2disconf >/dev/null 2>&1; then
    a2disconf -q vps-setup-cloudflare >/dev/null 2>&1 || true
  fi
}

if ! out=$(web_test 2>&1); then
  rollback
  printf '    %s\n' "${out//$'\n'/$'\n    '}" >&2
  die "the web server rejected the new config; the previous state was restored."
fi
web_reload || { rollback; die "reload failed; the previous config was restored."; }
say "Cloudflare real-IP config written: ${#V4[@]} IPv4 + ${#V6[@]} IPv6 ranges ($SOURCE list)."
