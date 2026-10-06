#!/usr/bin/env bash
# shellcheck shell=bash
# Debian — databases. PostgreSQL, Redis and the wizard are identical to Ubuntu;
# MySQL differs: Debian ships MariaDB, so mysql-server is mapped to mariadb-server.
# shellcheck source=../ubuntu/40-database.sh
source "$ROOT_DIR/modules/ubuntu/40-database.sh"

# Debian has no mysql-server package; the drop-in replacement is mariadb-server.
run_mysql() {
  local share=$(_db_share)
  pkg_install mariadb-server

  # MariaDB 10.4+ uses unix_socket auth for root by default ("sudo mysql"), so no password
  # is set. (A random password used to be generated and reported here but never applied.)

  local bp=$(( MEM_MB * 25 / 100 / share ))  # innodb_buffer_pool
  (( bp < 64 )) && bp=64; (( bp > 4096 )) && bp=4096

  install -d -m 755 /etc/mysql/mariadb.conf.d
  write_file /etc/mysql/mariadb.conf.d/vps-setup-tuning.cnf 644 <<EOF
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
