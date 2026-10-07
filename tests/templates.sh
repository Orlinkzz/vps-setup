#!/usr/bin/env bash
# shellcheck disable=SC2178,SC2128  # "out" holds command output here; the array warning is a false positive
# shellcheck disable=SC2015,SC2001  # pass() never fails, so "A && pass || bad" is a safe if/else
# Renders every template and validates it with the web server's own config test.
# Servers that are not installed are skipped. Run as root (nginx/caddy paths).
#   Live checks (nginx only) run when port 80 is free; set NO_LIVE=1 to skip them.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT_DIR=$PWD; TPL=$ROOT_DIR/templates
LOG_FILE=/tmp/vps-templates.log; DRY_RUN=1; ASSUME_YES=1
# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/os.sh
source lib/os.sh

TYPES=(static spa proxy laravel php wordpress redirect)
fail=0
pass() { echo "  ok   $*"; }
bad()  { echo "  FAIL $*"; fail=1; }
SOCK=/run/php/php8.3-fpm.sock

vars() { # vars <domain> <www 0|1>  → prints KEY=value lines
  local d=$1 www=$2 names=$1 comma=$1 alias=""
  if [[ $www == 1 ]]; then names="$d www.$d"; comma="$d, www.$d"; alias="    ServerAlias www.$d"; fi
  printf '%s\n' "DOMAIN=$d" "SERVER_NAMES=$names" "SERVER_NAMES_COMMA=$comma" "SERVER_ALIAS_LINE=$alias" \
    "ROOT=/var/www/$d/public" "UPSTREAM=127.0.0.1:3999" "PHP_SOCKET_PATH=$SOCK" \
    "REDIRECT_TARGET=https://example.org" "MAX_BODY=64m" "MAX_BODY_BYTES=67108864"
}

# ------------------------------------------------------------------ placeholders
echo "== every placeholder is provided by the code =="
known='DOMAIN SERVER_NAMES SERVER_NAMES_COMMA SERVER_ALIAS_LINE ROOT UPSTREAM PHP_SOCKET_PATH REDIRECT_TARGET MAX_BODY MAX_BODY_BYTES GLOBAL_OPTIONS CATCHALL'
while IFS= read -r ph; do
  [[ " $known " == *" $ph "* ]] || bad "unknown placeholder {{$ph}}"
done < <(grep -rhoE '\{\{[A-Z_]+\}\}' templates | tr -d '{}' | sort -u)
for s in nginx apache caddy; do
  for ty in "${TYPES[@]}"; do
    compgen -G "templates/$s/sites/$ty.*" >/dev/null || bad "missing $s template for type '$ty'"
  done
done
[[ $fail == 0 ]] && pass "placeholders + one template per site type per server"

# ------------------------------------------------------------------ nginx
if command -v nginx >/dev/null 2>&1; then
  echo "== nginx $(nginx -v 2>&1 | sed 's|.*/||') =="
  T=$(mktemp -d); mkdir -p "$T"/{conf.d,sites,snippets/vps-setup,logs}
  cp templates/nginx/snippets/*.conf "$T/snippets/vps-setup/"
  cp /etc/nginx/snippets/fastcgi-php.conf "$T/snippets/"
  cp /etc/nginx/{fastcgi_params,fastcgi.conf,mime.types} "$T/"
  render_tpl templates/nginx/00-vps-setup.conf.tpl MAX_BODY=64m >"$T/conf.d/00-vps-setup.conf"
  nginx_filter <templates/nginx/default-page.conf.tpl >"$T/sites/00-default.conf"
  nginx_filter <templates/nginx/default-https.conf.tpl >"$T/sites/00-default-https.conf"
  for ty in "${TYPES[@]}"; do
    mapfile -t v < <(vars "t-$ty.test" 1)
    render_tpl "templates/nginx/sites/$ty.conf.tpl" "${v[@]}" | nginx_filter >"$T/sites/t-$ty.test.conf" || bad "render $ty"
  done
  mapfile -t v < <(vars ref.test 1)
  render_tpl templates/nginx/reference/https-full.conf.tpl "${v[@]}" | nginx_filter >"$T/sites/ref.test.conf.disabled"
  if command -v openssl >/dev/null 2>&1 && [[ $EUID == 0 ]]; then
    mkdir -p /etc/letsencrypt/live/ref.test
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=ref.test" \
      -keyout /etc/letsencrypt/live/ref.test/privkey.pem -out /etc/letsencrypt/live/ref.test/fullchain.pem 2>/dev/null
    cp "$T/sites/ref.test.conf.disabled" "$T/sites/ref.test.conf"
    REF_CERT=1
  fi
  cat >"$T/nginx.conf" <<EOF
pid $T/nginx.pid;
error_log $T/logs/error.log;
events {}
http {
  include $T/mime.types;
  access_log off;
  include $T/conf.d/*.conf;
  include $T/sites/*.conf;
}
EOF
  if out=$(nginx -t -c "$T/nginx.conf" 2>&1); then pass "nginx -t (global + catch-all + ${#TYPES[@]} site types + HTTPS reference)"; else bad "nginx -t"; echo "$out" | sed 's/^/       /'; fi

  # live behaviour
  if [[ ${NO_LIVE:-0} != 1 ]] && ! ss -ltn 'sport = :80' 2>/dev/null | grep -q LISTEN; then
    rm -f "$T"/sites/t-{php,laravel,wordpress}.test.conf "$T/sites/ref.test.conf"
    for ty in static spa; do
      mkdir -p "/var/www/t-$ty.test/public"; echo "hello-$ty" >"/var/www/t-$ty.test/public/index.html"
      echo secret >"/var/www/t-$ty.test/public/.env"
    done
    mkdir -p /var/www/_default; render_tpl templates/html/default.html.tpl >/var/www/_default/index.html
    (cd /tmp && python3 -m http.server 3999 --bind 127.0.0.1 >/dev/null 2>&1 & echo $! >"$T/py.pid")
    nginx -c "$T/nginx.conf" && sleep 1
    c() { curl -s -o /tmp/body -w '%{http_code}' -H "Host: $1" "http://127.0.0.1$2"; }
    [[ $(c t-static.test /) == 200 && $(cat /tmp/body) == hello-static ]] && pass "live: static serves index" || bad "live: static"
    [[ $(c t-static.test /.env) == 403 ]] && pass "live: dotfiles denied" || bad "live: .env is reachable!"
    [[ $(c t-spa.test /some/deep/route) == 200 && $(cat /tmp/body) == hello-spa ]] && pass "live: SPA fallback to index.html" || bad "live: spa fallback"
    [[ $(c www.t-static.test /) == 200 ]] && pass "live: www alias works" || bad "live: www alias"
    code=$(c t-proxy.test /); [[ $code == 200 ]] && pass "live: reverse proxy reaches upstream" || bad "live: proxy ($code)"
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: t-redirect.test" "http://127.0.0.1/a/b?x=1")
    loc=$(curl -s -o /dev/null -w '%{redirect_url}' -H "Host: t-redirect.test" "http://127.0.0.1/a/b?x=1")
    [[ $code == 301 && $loc == "https://example.org/a/b?x=1" ]] && pass "live: redirect keeps path + query" || bad "live: redirect ($code $loc)"
    c unknown.test / >/dev/null; grep -q "Server is running" /tmp/body && pass "live: unknown host gets the friendly page" || bad "live: catch-all"
    nginx -c "$T/nginx.conf" -s stop 2>/dev/null; kill "$(cat "$T/py.pid")" 2>/dev/null
    rm -rf /var/www/t-static.test /var/www/t-spa.test
  else
    echo "  --   live checks skipped (port 80 busy or NO_LIVE=1)"
  fi
  rm -rf "$T" /etc/letsencrypt/live/ref.test
else
  echo "== nginx not installed: skipped =="
fi

# ------------------------------------------------------------------ apache
if command -v apache2 >/dev/null 2>&1; then
  echo "== apache $(apache2 -v | sed -n '1s|.*/\([0-9.]*\).*|\1|p') =="
  A=$(mktemp -d); mkdir -p "$A"/{conf,sites,logs,run}
  render_tpl templates/apache/vps-setup.conf.tpl MAX_BODY=64m MAX_BODY_BYTES=67108864 >"$A/conf/00-vps-setup.conf"
  cp templates/apache/default-page.conf.tpl "$A/sites/000-default.conf"
  for ty in "${TYPES[@]}"; do
    mapfile -t v < <(vars "t-$ty.test" 1)
    render_tpl "templates/apache/sites/$ty.conf.tpl" "${v[@]}" >"$A/sites/t-$ty.test.conf" || bad "render $ty"
  done
  mods=""
  for m in mpm_event authz_core authz_host alias dir mime headers rewrite proxy proxy_http proxy_wstunnel proxy_fcgi setenvif deflate expires filter; do
    mods+="LoadModule ${m}_module /usr/lib/apache2/modules/mod_$m.so"$'\n'
  done
  cat >"$A/apache2.conf" <<EOF
ServerRoot /etc/apache2
ServerName localhost
PidFile $A/run/apache.pid
DefaultRuntimeDir $A/run
User www-data
Group www-data
Listen 8081
Define APACHE_LOG_DIR $A/logs
ErrorLog $A/logs/error.log
$mods
IncludeOptional $A/conf/*.conf
IncludeOptional $A/sites/*.conf
EOF
  if out=$(apache2 -t -f "$A/apache2.conf" 2>&1); then pass "apache2 -t (global + catch-all + ${#TYPES[@]} site types, www alias)"; else bad "apache2 -t"; echo "$out" | sed 's/^/       /'; fi
  rm -rf "$A"
else
  echo "== apache not installed: skipped =="
fi

# ------------------------------------------------------------------ caddy
if command -v caddy >/dev/null 2>&1 && [[ $EUID == 0 ]]; then
  echo "== caddy $(caddy version | awk '{print $1}') =="
  bk=$(mktemp -d)
  [[ -f /etc/caddy/Caddyfile ]] && cp /etc/caddy/Caddyfile "$bk/Caddyfile"
  ls /etc/caddy/sites-enabled >/dev/null 2>&1 && cp -a /etc/caddy/sites-enabled "$bk/sites-enabled"
  mkdir -p /etc/caddy/sites-enabled; rm -f /etc/caddy/sites-enabled/t-*.caddy
  for ty in "${TYPES[@]}"; do
    mapfile -t v < <(vars "t-$ty.test" 1)
    render_tpl "templates/caddy/sites/$ty.caddy.tpl" "${v[@]}" >"/etc/caddy/sites-enabled/t-$ty.test.caddy" || bad "render $ty"
  done
  for catch in catchall-page catchall-drop; do
    for opts in "" $'{\n    email test@example.com\n}\n'; do
      render_tpl templates/caddy/Caddyfile.tpl GLOBAL_OPTIONS="$opts" CATCHALL="$(cat "templates/caddy/$catch.tpl")" >/etc/caddy/Caddyfile
      if out=$(caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1); then
        pass "caddy validate ($catch, email=$([[ -n $opts ]] && echo yes || echo no), ${#TYPES[@]} site types)"
      else bad "caddy validate ($catch)"; echo "$out" | tail -n 8 | sed 's/^/       /'; fi
    done
  done
  rm -f /etc/caddy/sites-enabled/t-*.caddy
  [[ -f $bk/Caddyfile ]] && cp "$bk/Caddyfile" /etc/caddy/Caddyfile
  rm -rf "$bk"
else
  echo "== caddy not installed (or not root): skipped =="
fi

echo
(( fail )) && echo "TEMPLATE TESTS FAILED" || echo "template tests passed"
exit $fail
