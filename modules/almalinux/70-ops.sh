#!/usr/bin/env bash
# shellcheck shell=bash
# AlmaLinux / Rocky / RHEL — ops. Same scripts; service names and cron differ slightly.
# shellcheck source=../ubuntu/70-ops.sh
source "$ROOT_DIR/modules/ubuntu/70-ops.sh"

_has_nginx() { command -v nginx >/dev/null 2>&1; }

# RHEL: fail2ban comes from EPEL.
run_nginx_jails() {
  log_info "$(t ops.jails.creating)"

  if ! pkg_installed fail2ban; then
    pkg_install epel-release || true
    pkg_update
  fi
  pkg_install fail2ban

  write_file /etc/fail2ban/jail.d/10-vps-setup-nginx.local 644 <<'EOF'
# Managed by vps-setup

[nginx-http-auth]
enabled  = true
port     = http,https
filter   = nginx-http-auth
logpath  = /var/log/nginx/error.log
maxretry = 5
bantime  = 1h
findtime = 10m

[nginx-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
logpath  = /var/log/nginx/error.log
maxretry = 2
bantime  = 4h
findtime = 30m

[nginx-bad-request]
enabled   = true
port      = http,https
filter    = nginx-bad-request
logpath   = /var/log/nginx/access.log
maxretry  = 10
bantime   = 1h
findtime  = 1m
EOF

  write_file /etc/fail2ban/filter.d/nginx-bad-request.conf 644 <<'EOF'
# Managed by vps-setup — blocks IPs that repeatedly hit bad requests
[Definition]
failregex = ^<HOST> - - \[.*\] "(GET|POST|HEAD|PUT|DELETE|CONNECT|OPTIONS|PATCH|PROPFIND|MKCOL|COPY|MOVE).*" (400|404|444|499) .*$
ignoreregex =
EOF

  write_file /etc/fail2ban/filter.d/nginx-botsearch.conf 644 <<'EOF'
# Managed by vps-setup — blocks aggressive URL scanners
[Definition]
failregex = ^<HOST> - - \[.*\] "(GET|POST|HEAD).*" (404|444) .*$
ignoreregex =
EOF

  svc_restart fail2ban
  log_ok "$(t ops.jails.done)"
}

# RHEL: journal unit is sshd, and "sudo -u postgres" needs an explicit shell.
run_db_backup() {
  local dir retention=${CFG[backup_retention]:-7}
  dir=$(_backup_dir)

  log_info "$(t ops.backup.creating)"

  write_file /usr/local/bin/vps-setup-backup 750 <<'SCRIPT'
#!/usr/bin/env bash
# Managed by vps-setup — runs daily via cron
set -uo pipefail
LOG=/var/log/vps-setup-backup.log
DIR=/var/backups/vps-setup/db
RETENTION=7

mkdir -p "$DIR"
echo "=== $(date) ===" >>"$LOG"

if command -v pg_dumpall >/dev/null 2>&1; then
  for db in $(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres'" 2>/dev/null); do
    db=$(echo "$db" | tr -d ' ')
    [ -z "$db" ] && continue
    sudo -u postgres pg_dump "$db" | gzip > "$DIR/${db}_postgresql_$(date +%F).sql.gz"
    echo "  pg: $db" >>"$LOG"
  done
fi

if command -v mysql >/dev/null 2>&1; then
  for db in $(mysql -NBe "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys')" 2>/dev/null); do
    mysqldump "$db" | gzip > "$DIR/${db}_mysql_$(date +%F).sql.gz"
    echo "  mysql: $db" >>"$LOG"
  done
fi

find "$DIR" -name '*.sql.gz' -mtime "+$RETENTION" -delete
echo "  retention: $RETENTION days" >>"$LOG"
SCRIPT

  write_file /etc/vps-setup/backup.conf 644 <<EOF
# Managed by vps-setup
RETENTION=$retention
EOF

  if (( ! DRY_RUN )); then
    write_file /etc/cron.d/vps-setup-backup 644 <<'EOF'
# Managed by vps-setup — DB backups
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * root /usr/local/bin/vps-setup-backup >/dev/null 2>&1
EOF
  fi

  log_ok "$(t ops.backup.done)"
}
