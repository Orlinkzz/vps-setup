#!/usr/bin/env bash
# shellcheck shell=bash
# AlmaLinux / Rocky / RHEL — databases. Same engines, different package names and paths.
# shellcheck source=../ubuntu/40-database.sh
source "$ROOT_DIR/modules/ubuntu/40-database.sh"

# RHEL: postgresql-server requires an explicit initdb on the data directory.
run_postgresql() {
  local share=$(_db_share) pg_conf
  pkg_install postgresql-server postgresql-contrib

  # Initialise the cluster once
  if [[ ! -f /var/lib/pgsql/data/PG_VERSION ]]; then
    run postgresql-setup --initdb
  fi

  pg_conf="/var/lib/pgsql/data/conf.d"

  local sb_128=$(( MEM_MB * 25 / 100 / share ))
  local ec_256=$(( MEM_MB * 50 / 100 / share ))
  local wm=$(( MEM_MB * 2 / 100 / share ))
  local mwm=$(( MEM_MB * 5 / 100 / share ))
  (( sb_128 < 128 )) && sb_128=128; (( sb_128 > 4096 )) && sb_128=4096
  (( ec_256 < 256 )) && ec_256=256; (( ec_256 > 8192 )) && ec_256=8192
  (( wm < 4 ))  && wm=4;  (( wm > 64 ))  && wm=64
  (( mwm < 64 )) && mwm=64; (( mwm > 512 )) && mwm=512

  run install -d -m 700 -o postgres -g postgres "$pg_conf"
  {
    echo "# Managed by vps-setup — RAM-based tuning"
    echo "shared_buffers = ${sb_128}MB"
    echo "effective_cache_size = ${ec_256}MB"
    echo "work_mem = ${wm}MB"
    echo "maintenance_work_mem = ${mwm}MB"
  } | write_file "$pg_conf/vps-setup-tuning.conf" 600

  # Passwords for apps: store them as SCRAM (PostgreSQL < 14 still defaults to md5)
  echo "password_encryption = scram-sha-256" | write_file "$pg_conf/vps-setup-auth.conf" 600

  run sed -i "s/^#*listen_addresses = .*/listen_addresses = 'localhost'/" /var/lib/pgsql/data/postgresql.conf
  # initdb on RHEL uses "ident" for 127.0.0.1/::1, so apps with DB_HOST=127.0.0.1 cannot log in
  # with a password. Switch only those two TCP lines to scram-sha-256 (the local socket keeps peer).
  backup_file /var/lib/pgsql/data/pg_hba.conf
  run sed -i -E 's#^(host[[:space:]]+all[[:space:]]+all[[:space:]]+(127\.0\.0\.1/32|::1/128)[[:space:]]+)ident[[:space:]]*$#\1scram-sha-256#' /var/lib/pgsql/data/pg_hba.conf
  run sh -c "grep -q 'conf.d' /var/lib/pgsql/data/postgresql.conf || echo \"include_dir = 'conf.d'\" >> /var/lib/pgsql/data/postgresql.conf"
  run chown -R postgres:postgres /var/lib/pgsql/data

  svc_enable_now postgresql
  svc_restart postgresql
  log_ok "$(t db.postgresql.done)"
}

# RHEL: MariaDB is the default MySQL server package.
run_mysql() {
  local share=$(_db_share)
  pkg_install mariadb-server

  local bp=$(( MEM_MB * 25 / 100 / share ))
  (( bp < 64 )) && bp=64; (( bp > 4096 )) && bp=4096

  run install -d -m 755 /etc/my.cnf.d
  write_file /etc/my.cnf.d/vps-setup-tuning.cnf 644 <<EOF
# Managed by vps-setup — RAM-based tuning
[mysqld]
innodb_buffer_pool_size = ${bp}M
key_buffer_size = 32M
max_allowed_packet = 64M
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
# RHEL's MariaDB listens on every interface by default: keep it on this machine only
bind-address = 127.0.0.1
EOF

  svc_enable_now mariadb
  svc_restart mariadb
  _mariadb_secure_root
  log_ok "$(t db.mysql.done)"
}

# MariaDB < 10.4 (EL8) ships root with an EMPTY password plus anonymous users and a "test" database.
# Give root a random password kept only in /root/.my.cnf (mode 600), like on Ubuntu, and remove the
# anonymous users. Newer MariaDB uses unix_socket for root and is left alone.
_mariadb_secure_root() {
  local root_pass
  (( DRY_RUN )) && { log_dry "secure MariaDB root (only if it has an empty password)"; return 0; }
  [[ -e /root/.my.cnf ]] && return 0
  # Only act when root logs in with an empty password over TCP (the old, insecure default)
  mysql --protocol=TCP -h 127.0.0.1 -u root --password= -e 'SELECT 1' >/dev/null 2>&1 || return 0
  root_pass=$(_rand_pass)
  if run_stdin "$root_pass" "DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost');
DROP DATABASE IF EXISTS test;
SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$root_pass');
FLUSH PRIVILEGES;" mysql -u root; then
    write_file /root/.my.cnf 600 <<EOF
# Managed by vps-setup: MySQL root login (keeps "sudo mysql" working)
[client]
user=root
password="$root_pass"
EOF
    CFG[mysql_root_saved]=1
  else
    log_warn "$(t db.mysql.root_unchanged)"
  fi
}

run_redis() {
  local share=$(_db_share) conf=/etc/redis/redis.conf
  pkg_install redis
  # EL8 keeps the config at /etc/redis.conf, EL9 at /etc/redis/redis.conf
  [[ -f /etc/redis.conf && ! -f /etc/redis/redis.conf ]] && conf=/etc/redis.conf

  local maxmem=$(( MEM_MB * 30 / 100 / share ))
  (( maxmem < 16 )) && maxmem=16
  (( maxmem > 2048 )) && maxmem=2048

  backup_file "$conf"
  write_file "$conf" 640 <<EOF
# Managed by vps-setup
port 6379
bind 127.0.0.1 -::1
daemonize no
supervised systemd
pidfile /run/redis/redis.pid
loglevel notice
logfile /var/log/redis/redis.log
dir /var/lib/redis
dbfilename dump.rdb
maxmemory ${maxmem}mb
maxmemory-policy allkeys-lru
save 900 1
save 300 10
save 60 10000
databases 16
timeout 0
EOF

  run chown root:redis "$conf"
  svc_enable_now redis
  svc_restart redis
  log_ok "$(t db.redis.done)"
}

# RHEL runs redis as "redis"; the wizard detects engines via binaries.
db_installed() {
  case "$1" in
    postgresql) command -v psql >/dev/null 2>&1 ;;
    mysql)      command -v mysql >/dev/null 2>&1 ;;
    redis)      command -v redis-server >/dev/null 2>&1 || command -v redis-cli >/dev/null 2>&1 ;;
    *)          return 1 ;;
  esac
}
