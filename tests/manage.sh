#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2317,SC2329  # "A && pass || bad" is an if/else; stubs are written with single quotes on purpose (SC2317 = shellcheck <=0.9, SC2329 = >=0.10)
# Tests for lib/manage.sh: list / remove websites, list / drop databases.
# Hermetic: every /etc and /var/www path is redirected into a temp dir (VPS_SETUP_ROOT) and every
# system command (nginx, certbot, systemctl, psql, mysql, ...) is a stub. No root, nothing on the
# real system is touched, so it is safe anywhere.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
fail=0
pass() { echo "  ok   $*"; }
bad()  { echo "  FAIL $*"; fail=1; }
check()  { local d=$1; shift; if "$@"; then pass "$d"; else bad "$d"; fi; }
reject() { local d=$1; shift; if "$@"; then bad "$d"; else pass "$d"; fi; }
exists() { [[ -e $1 || -L $1 ]]; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export VPS_SETUP_ROOT=$T/root LOG_FILE=$T/vps.log
R=$VPS_SETUP_ROOT
mkdir -p "$R" "$T/bin"
export STUB_LOG=$T/stub.log STUB_FAIL_DIR=$T/fail
mkdir -p "$STUB_FAIL_DIR"
: >"$STUB_LOG"

# ------------------------------------------------------------------ stubs
mkstub() { printf '#!/bin/bash\n%s\n' "$2" >"$T/bin/$1"; chmod +x "$T/bin/$1"; }
mkstub nginx     'echo "nginx $*" >>"$STUB_LOG"; [ -e "$STUB_FAIL_DIR/nginx" ] && exit 1; exit 0'
mkstub apachectl 'echo "apachectl $*" >>"$STUB_LOG"; exit 0'
mkstub httpd     'echo "httpd $*" >>"$STUB_LOG"; exit 0'
mkstub caddy     'echo "caddy $*" >>"$STUB_LOG"; exit 0'
mkstub systemctl 'echo "systemctl $*" >>"$STUB_LOG"; exit 0'
mkstub certbot   'echo "certbot $*" >>"$STUB_LOG"; [ "$1" = delete ] && rm -rf "$VPS_SETUP_ROOT/etc/letsencrypt/live/$3"; exit 0'
mkstub sudo      'shift 2; exec "$@"'
mkstub psql      'echo "psql $*" >>"$STUB_LOG"
case "$*" in
  *"FROM pg_database d JOIN"*) printf "app1 owner1\napp2 owner2\n" ;;
  *"SELECT 1 FROM pg_database"*) case "$*" in *app1*) echo 1 ;; esac ;;
  *"DROP DATABASE"*) [ -e "$STUB_FAIL_DIR/drop" ] && exit 1 ;;
esac
exit 0'
mkstub pg_dump   '[ -e "$STUB_FAIL_DIR/dump" ] && exit 1; echo "-- dump of $1"'
mkstub mysql     'echo "mysql $*" >>"$STUB_LOG"
case "$*" in
  *"SHOW DATABASES"*) printf "information_schema\nmysql\nperformance_schema\nshop\nsys\n" ;;
  *"information_schema.SCHEMATA"*) case "$*" in *shop*) echo shop ;; esac ;;
esac
exit 0'
mkstub mysqldump '[ -e "$STUB_FAIL_DIR/dump" ] && exit 1; echo "-- mysqldump of $4"'
export PATH="$T/bin:$PATH"

# shellcheck source=../setup.sh
source ./setup.sh
DRY_RUN=0; ASSUME_YES=1
BACKUP_DIR=$T/backup
OS_ID=ubuntu; OS_VERSION=24.04
load_modules

logged() { grep -qF -- "$1" "$STUB_LOG"; }
clear_log() { : >"$STUB_LOG"; }

# A Debian-style nginx site with certificate and files.
mk_nginx_site() {  # <domain> [type text]
  local d=$1
  mkdir -p "$R/etc/nginx/sites-available" "$R/etc/nginx/sites-enabled" "$R/etc/letsencrypt/live/$d" "$R/var/www/$d/public"
  printf '# Managed by vps-setup — %s\nserver { server_name %s; }\n' "${2:-static website}" "$d" >"$R/etc/nginx/sites-available/$d.conf"
  ln -sfn "../sites-available/$d.conf" "$R/etc/nginx/sites-enabled/$d.conf"
  echo hello >"$R/var/www/$d/public/index.html"
}

# ================================================================== list sites
echo "== list sites =="
mk_nginx_site a.example.com
mk_nginx_site b.example.com "reverse proxy"
printf 'server { server_name other.example.com; }\n' >"$R/etc/nginx/sites-available/other.example.com.conf"          # not ours
printf '# Managed by vps-setup — catch-all\nserver { }\n' >"$R/etc/nginx/sites-available/00-default.conf"          # ours, but not a site
out=$(list_sites)
check "managed sites are listed"                    grep -q '^a.example.com .*nginx' <<<"$out"
check "type and https are shown"                    grep -q '^b.example.com .*reverse proxy .*yes' <<<"$out"
reject "a config without the marker is not listed"  grep -q 'other.example.com' <<<"$out"
reject "the catch-all is not listed as a site"      grep -q '00-default' <<<"$out"
rm "$R/etc/nginx/sites-enabled/b.example.com.conf"
check "a disabled site is flagged"                  grep -q '^b.example.com .*disabled' <<<"$(list_sites)"
ln -sfn "../sites-available/b.example.com.conf" "$R/etc/nginx/sites-enabled/b.example.com.conf"

# ================================================================== remove a site
echo "== remove a site =="
reject "invalid domain refused"                     remove_domain 'a b;rm'
reject "unknown domain refused"                     remove_domain nope.example.com
reject "a config we did not create is refused"      remove_domain other.example.com
check  "...and it is still there"                   exists "$R/etc/nginx/sites-available/other.example.com.conf"

CFG=(); clear_log
check  "remove a.example.com"                       remove_domain a.example.com
reject "site config removed"                        exists "$R/etc/nginx/sites-available/a.example.com.conf"
reject "enabled link removed"                       exists "$R/etc/nginx/sites-enabled/a.example.com.conf"
check  "config was tested and reloaded"             logged "nginx -t"
check  "certificate deleted through certbot"        logged "certbot delete --cert-name a.example.com --non-interactive"
reject "certificate directory gone"                 exists "$R/etc/letsencrypt/live/a.example.com"
check  "site files are kept by default"             exists "$R/var/www/a.example.com/public/index.html"
check  "a copy of the config is in the backup dir"  bash -c "ls '$BACKUP_DIR' | grep -q 'a.example.com.conf'"
check  "other sites untouched"                      exists "$R/etc/nginx/sites-available/b.example.com.conf"
check  "the catch-all is untouched"                 exists "$R/etc/nginx/sites-available/00-default.conf"

echo "== --purge-files moves, never deletes =="
mk_nginx_site c.example.com; CFG=([arg_purge]=1); clear_log
check  "remove c.example.com --purge-files"         remove_domain c.example.com
reject "site folder gone from /var/www"             exists "$R/var/www/c.example.com"
check  "...and its content sits in the backup dir"  bash -c "cat '$BACKUP_DIR'/removed-sites/c.example.com.*/public/index.html | grep -q hello"

echo "== --keep-cert =="
mk_nginx_site d.example.com; CFG=([arg_keep_cert]=1); clear_log
check  "remove d.example.com --keep-cert"           remove_domain d.example.com
reject "certbot was not called"                     logged "certbot delete"
check  "certificate is still there"                 exists "$R/etc/letsencrypt/live/d.example.com"

echo "== a certificate another site still uses is kept =="
mk_nginx_site e.example.com; mk_nginx_site f.example.com; CFG=(); clear_log
printf 'ssl_certificate /etc/letsencrypt/live/e.example.com/fullchain.pem;\n' >>"$R/etc/nginx/sites-available/f.example.com.conf"
check  "remove e.example.com"                       remove_domain e.example.com
reject "certbot was not called"                     logged "certbot delete"
check  "certificate is still there"                 exists "$R/etc/letsencrypt/live/e.example.com"

echo "== the web server rejects the result: everything is put back =="
mk_nginx_site g.example.com; CFG=(); clear_log
cat "$R/etc/nginx/sites-available/g.example.com.conf" >"$T/g.before"
touch "$STUB_FAIL_DIR/nginx"
reject "remove fails"                               remove_domain g.example.com
rm -f "$STUB_FAIL_DIR/nginx"
check  "config file restored"                       cmp -s "$T/g.before" "$R/etc/nginx/sites-available/g.example.com.conf"
check  "enabled symlink restored"                   test -L "$R/etc/nginx/sites-enabled/g.example.com.conf"
check  "...and it still points to the right file"   test -e "$R/etc/nginx/sites-enabled/g.example.com.conf"
reject "certbot was not called"                     logged "certbot delete"
check  "files untouched"                            exists "$R/var/www/g.example.com/public/index.html"
check  "the target directory keeps its mode"        test "$(stat -c %a "$R/etc/nginx/sites-available")" != 700

echo "== dry run changes nothing =="
mk_nginx_site h.example.com; CFG=([arg_purge]=1); DRY_RUN=1; clear_log
check  "dry-run remove succeeds"                    remove_domain h.example.com
DRY_RUN=0
check  "config still there"                         exists "$R/etc/nginx/sites-available/h.example.com.conf"
check  "files still there"                          exists "$R/var/www/h.example.com/public/index.html"
check  "certificate still there"                    exists "$R/etc/letsencrypt/live/h.example.com"
reject "certbot was not called"                     logged "certbot delete"

echo "== AlmaLinux / Rocky layout =="
OS_ID=almalinux
nginx_apply() { return 0; }; apache_apply() { return 0; }
mkdir -p "$R/etc/nginx/conf.d" "$R/etc/httpd/conf.d"
printf '# Managed by vps-setup — static website\nserver { }\n' >"$R/etc/nginx/conf.d/r1.example.com.conf"
printf '# Managed by vps-setup — PHP site\n<VirtualHost *:80>\n</VirtualHost>\n' >"$R/etc/httpd/conf.d/r2.example.com.conf"
printf '<IfModule mod_ssl.c>\n# letsencrypt\n</IfModule>\n' >"$R/etc/httpd/conf.d/r2.example.com-le-ssl.conf"
printf '# Managed by vps-setup — global\n' >"$R/etc/nginx/conf.d/00-vps-setup.conf"
printf 'ServerRoot x\n' >"$R/etc/httpd/conf.d/ssl.conf"
out=$(list_sites)
check  "nginx conf.d site listed"                   grep -q '^r1.example.com .*nginx' <<<"$out"
check  "httpd conf.d site listed"                   grep -q '^r2.example.com .*apache' <<<"$out"
reject "global files are not sites"                 grep -qE '00-vps-setup|ssl.conf' <<<"$out"
CFG=()
check  "remove r1 (nginx conf.d)"                   remove_domain r1.example.com
reject "r1 config removed"                          exists "$R/etc/nginx/conf.d/r1.example.com.conf"
check  "remove r2 (httpd)"                          remove_domain r2.example.com
reject "r2 config removed"                          exists "$R/etc/httpd/conf.d/r2.example.com.conf"
reject "r2 certbot -le-ssl config removed too"      exists "$R/etc/httpd/conf.d/r2.example.com-le-ssl.conf"
check  "stock httpd files untouched"                exists "$R/etc/httpd/conf.d/ssl.conf"
check  "global vps-setup file untouched"            exists "$R/etc/nginx/conf.d/00-vps-setup.conf"
OS_ID=ubuntu
unset -f nginx_apply apache_apply
load_modules

echo "== Caddy =="
mkdir -p "$R/etc/caddy/sites-enabled"
printf '# Managed by vps-setup — static website\nc1.example.com, www.c1.example.com {\n}\n' >"$R/etc/caddy/sites-enabled/c1.example.com.caddy"
check  "caddy site listed with auto https"          grep -q '^c1.example.com .*caddy .*auto' <<<"$(list_sites)"
clear_log
check  "remove caddy site"                          remove_domain c1.example.com
reject "caddy site file removed"                    exists "$R/etc/caddy/sites-enabled/c1.example.com.caddy"
check  "caddy config validated"                     logged "caddy validate"
reject "no certbot for caddy"                       logged "certbot"

# ================================================================== databases
echo "== list databases =="
out=$(list_databases)
check  "PostgreSQL databases with owner"            grep -q 'app1 .*owner1' <<<"$out"
check  "MySQL databases"                            grep -q '^  shop$' <<<"$out"
reject "MySQL system schemas hidden"                grep -qE 'information_schema|performance_schema' <<<"$out"

echo "== drop a database: refused cases =="
CFG=([arg_engine]=postgresql); clear_log
reject "system database refused (postgres)"         drop_database postgres
reject "system database refused (mysql)"            drop_database mysql
reject "odd characters refused"                     drop_database 'a;b'
reject "quote refused"                              drop_database 'a"b'
CFG=([arg_engine]=postgresql [arg_db_user]='x;y')
reject "bad --db-user refused"                      drop_database app1
CFG=([arg_engine]=postgresql)
reject "database that does not exist"               drop_database app9
reject "nothing was dropped so far"                 logged "DROP"
CFG=()
reject "both engines installed and no --engine"     drop_database app1

echo "== drop a database: PostgreSQL =="
CFG=([arg_engine]=postgresql [arg_db_user]=app1); clear_log
check  "drop app1 + its user"                       drop_database app1
check  "database dropped"                           logged 'DROP DATABASE "app1";'
check  "user dropped"                               logged 'DROP ROLE IF EXISTS "app1";'
dump=""
for f in "$BACKUP_DIR"/dropped-databases/app1.postgresql.*.sql.gz; do
  if [[ -f $f ]]; then dump=$f; fi
done
check  "a compressed dump was saved first"          test -n "$dump"
check  "the dump holds the data"                    bash -c "gunzip -c '$dump' | grep -q 'dump of app1'"
check  "the dump is private (600)"                  test "$(stat -c %a "$dump")" = 600

echo "== drop a database: a failed dump stops everything =="
CFG=([arg_engine]=postgresql); clear_log
touch "$STUB_FAIL_DIR/dump"
reject "drop refused"                               drop_database app1
rm -f "$STUB_FAIL_DIR/dump"
reject "nothing was dropped"                        logged "DROP DATABASE"

echo "== drop a database: still connected =="
CFG=([arg_engine]=postgresql [arg_db_user]=app1); clear_log
touch "$STUB_FAIL_DIR/drop"
reject "drop fails"                                 drop_database app1
rm -f "$STUB_FAIL_DIR/drop"
reject "the user is kept when the database stays"  logged "DROP ROLE"

echo "== drop a database: MySQL =="
CFG=([arg_engine]=mysql [arg_db_user]=shop); clear_log
check  "drop shop + its user"                       drop_database shop
check  "database dropped"                           logged 'DROP DATABASE `shop`;'
check  "user dropped"                               logged "DROP USER IF EXISTS 'shop'@'localhost';"
check  "mysqldump saved"                            bash -c "ls '$BACKUP_DIR'/dropped-databases/shop.mysql.*.sql.gz"

echo "== drop a database: dry run =="
CFG=([arg_engine]=postgresql); DRY_RUN=1; clear_log
rm -rf "$BACKUP_DIR/dropped-databases"
check  "dry-run succeeds"                           drop_database app1
DRY_RUN=0
reject "nothing dropped"                            logged "DROP DATABASE"
reject "no dump written"                            exists "$BACKUP_DIR/dropped-databases"

# ================================================================== through setup.sh
echo "== command line =="
cs=$R/etc/caddy/sites-enabled
printf '# Managed by vps-setup — static website\nx1.example.com {\n}\n' >"$cs/x1.example.com.caddy"
out=$(bash setup.sh --dry-run --lang en --list-sites 2>&1); rc=$?
check  "--list-sites works end to end"              test "$rc" = 0
check  "...and shows the site"                      grep -q '^x1.example.com ' <<<"$out"
out=$(bash setup.sh --dry-run --yes --lang en --remove-domain x1.example.com 2>&1); rc=$?
check  "--remove-domain --dry-run succeeds"         test "$rc" = 0
check  "...announces the removal"                   grep -q 'rm -f' <<<"$out"
check  "...but changes nothing"                     exists "$cs/x1.example.com.caddy"
out=$(bash setup.sh --dry-run --yes --lang en --remove-domain nope.example.com 2>&1); rc=$?
check  "an unknown domain gives a non-zero exit"    test "$rc" != 0
out=$(bash setup.sh --remove-domain 2>&1); rc=$?
check  "--remove-domain without a value is refused" test "$rc" != 0
out=$(bash setup.sh --help 2>&1)
check  "--help documents the new options"           bash -c 'grep -q -- --remove-domain <<<"$1" && grep -q -- --drop-database <<<"$1"' _ "$out"

(( fail )) && echo "MANAGE TESTS FAILED" || echo "manage tests passed"
exit $fail
