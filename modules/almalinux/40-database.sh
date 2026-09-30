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

  run sed -i "s/^#*listen_addresses = .*/listen_addresses = 'localhost'/" /var/lib/pgsql/data/postgresql.conf
  run sh -c "grep -q 'conf.d' /var/lib/pgsql/data/postgresql.conf || echo \"include_dir = 'conf.d'\" >> /var/lib/pgsql/data/postgresql.conf"
  run chown -R postgres:postgres /var/lib/pgsql/data

  svc_enable_now postgresql || svc_restart postgresql
  log_ok "$(t db.postgresql.done)"
}

# RHEL: MariaDB is the default MySQL server package.
run_mysql() {
  local share=$(_db_share)
  pkg_install mariadb-server

  local bp=$(( MEM_MB * 25 / 100 / share ))
  (( bp < 64 )) && bp=64; (( bp > 4096 )) && bp=4096

  install -d -m 755 /etc/my.cnf.d
  write_file /etc/my.cnf.d/vps-setup-tuning.cnf 644 <<EOF
# Managed by vps-setup — RAM-based tuning
[mysqld]
innodb_buffer_pool_size = ${bp}M
key_buffer_size = 32M
max_allowed_packet = 64M
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
EOF

  svc_enable_now mariadb || svc_restart mariadb
  log_ok "$(t db.mysql.done)"
}

run_redis() {
  local share=$(_db_share)
  (( IS_CONTAINER )) || pkg_install redis
  (( IS_CONTAINER )) && pkg_install redis

  local maxmem=$(( MEM_MB * 30 / 100 / share ))
  (( maxmem < 16 )) && maxmem=16
  (( maxmem > 2048 )) && maxmem=2048

  backup_file /etc/redis/redis.conf
  write_file /etc/redis/redis.conf 644 <<EOF
# Managed by vps-setup
port 6379
bind 127.0.0.1 -::1
daemonize no
supervised systemd
loglevel notice
maxmemory ${maxmem}mb
maxmemory-policy allkeys-lru
save 900 1
save 300 10
save 60 10000
databases 16
timeout 0
EOF

  svc_enable_now redis || svc_restart redis
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
