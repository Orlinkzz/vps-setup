#!/usr/bin/env bash
# shellcheck shell=bash
# Ubuntu — ops: DB backups with rotation, monitoring, nginx fail2ban jails.

register_feature db_backup     ops off
register_feature monitoring    ops off
register_feature nginx_jails   ops off

BACKUP_ROOT=/var/backups/vps-setup

# ---- helpers ----
_has_postgres() { command -v psql >/dev/null 2>&1; }
_has_mysql()    { command -v mysql >/dev/null 2>&1; }
_has_nginx()    { command -v nginx >/dev/null 2>&1; }

_backup_dir() {
  local dir="$BACKUP_ROOT/db"
  install -d -m 750 "$dir"
  printf '%s' "$dir"
}

_setting_or() {
  local k=$1 fallback=$2 v
  v=$(setting_get "$k")
  printf '%s' "${v:-$fallback}"
}

# ============================================================ DB backups
prompt_db_backup() {
  local title
  title=$(t feat.db_backup.title)

  if ! _has_postgres && ! _has_mysql; then
    ui_msg "$title" "$(t ops.backup.no_db)"
    return 1
  fi

  CFG[backup_retention]=$(ui_input "$title" "$(t ops.backup.ask_retention)" "7") || return 1
  (( ASSUME_YES )) && CFG[backup_retention]=${CFG[backup_retention]:-7}
}

run_db_backup() {
  local dir retention=${CFG[backup_retention]:-7}
  dir=$(_backup_dir)

  log_info "$(t ops.backup.creating)"

  # Write the backup script
  write_file /usr/local/bin/vps-setup-backup 750 <<'SCRIPT'
#!/usr/bin/env bash
# Managed by vps-setup — runs daily via cron
set -uo pipefail
LOG=/var/log/vps-setup-backup.log
DIR=/var/backups/vps-setup/db
RETENTION=7

mkdir -p "$DIR"
echo "=== $(date) ===" >>"$LOG"

# PostgreSQL
if command -v pg_dumpall >/dev/null 2>&1; then
  for db in $(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres'" 2>/dev/null); do
    db=$(echo "$db" | tr -d ' ')
    [ -z "$db" ] && continue
    sudo -u postgres pg_dump "$db" | gzip > "$DIR/${db}_postgresql_$(date +%F).sql.gz"
    echo "  pg: $db" >>"$LOG"
  done
fi

# MySQL / MariaDB
if command -v mysql >/dev/null 2>&1; then
  for db in $(mysql -NBe "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys')" 2>/dev/null); do
    mysqldump "$db" | gzip > "$DIR/${db}_mysql_$(date +%F).sql.gz"
    echo "  mysql: $db" >>"$LOG"
  done
fi

# Rotate older than RETENTION days
find "$DIR" -name '*.sql.gz' -mtime "+$RETENTION" -delete
echo "  retention: $RETENTION days" >>"$LOG"
SCRIPT

  # Write retention override
  write_file /etc/vps-setup/backup.conf 644 <<EOF
# Managed by vps-setup
RETENTION=$retention
EOF

  # Cron daily
  if (( ! DRY_RUN )); then
    install -d -m 755 /etc/cron.d
    write_file /etc/cron.d/vps-setup-backup 644 <<EOF
# Managed by vps-setup — DB backups
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * root /usr/local/bin/vps-setup-backup >/dev/null 2>&1
EOF
  fi

  log_ok "$(t ops.backup.done)"
}

summary_db_backup() { t sum.backup "${CFG[backup_retention]:-7}"; }

# ============================================================ Monitoring
prompt_monitoring() {
  if _has_postgres || _has_mysql; then
    CFG[monitor_db]=1
  else
    CFG[monitor_db]=0
  fi
  return 0
}

run_monitoring() {
  log_info "$(t ops.monitor.creating)"

  write_file /usr/local/bin/vps-setup-health 750 <<'SCRIPT'
#!/usr/bin/env bash
# Managed by vps-setup — run: sudo vps-setup-health
# Prints a one-page system health summary.
set -uo pipefail

echo "=== System Health ==="
echo "Uptime:  $(uptime -p | sed 's/up //')"
echo "Load:    $(cat /proc/loadavg | cut -d' ' -f1-3)"
echo "Memory:  $(free -h | awk '/^Mem:/{print $3 " / " $2}')"
echo "Disk:    $(df -h / | awk 'NR==2{print $3 " / " $2 " (" $5 ")"}')"
echo "Swap:    $(free -h | awk '/^Swap:/{print $3 " / " $2}')"
echo ""

echo "=== Services ==="
for svc in ssh fail2ban nginx apache2 caddy postgresql mysql redis-server docker unattended-upgrades; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then echo "  ✓ $svc"
  elif systemctl list-units --type=service --state=failed 2>/dev/null | grep -q "$svc"; then echo "  ✗ $svc (failed)"
  fi
done

echo ""
echo "=== Backups ==="
DIR=/var/backups/vps-setup/db
if [ -d "$DIR" ]; then
  count=$(find "$DIR" -name '*.sql.gz' 2>/dev/null | wc -l)
  echo "  DB backup files: $count"
  ls -1 "$DIR" 2>/dev/null | tail -5 | sed 's/^/    /'
else
  echo "  No backup directory"
fi

echo ""
echo "=== Last login failures ==="
journalctl -u ssh --since "1 day ago" -o cat 2>/dev/null | grep -c "Failed password" | xargs -I{} echo "  {} failed SSH attempts (24h)"
SCRIPT
  run chmod +x /usr/local/bin/vps-setup-health

  # Health check cron (nightly, writes to log only)
  if (( ! DRY_RUN )); then
    install -d -m 755 /etc/cron.d
    write_file /etc/cron.d/vps-setup-health 644 <<'EOF'
# Managed by vps-setup — nightly health snapshot
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 5 * * * root /usr/local/bin/vps-setup-health >/var/log/vps-setup-health.log 2>&1
EOF
  fi

  log_ok "$(t ops.monitor.done)"
}

summary_monitoring() { t sum.monitor; }
notes_monitoring()   { t note.monitor; echo; }

# ============================================================ Nginx fail2ban jails
prompt_nginx_jails() {
  if ! _has_nginx; then
    ui_msg "$(t feat.nginx_jails.title)" "$(t ops.jails.no_nginx)"
    return 1
  fi
  return 0
}

run_nginx_jails() {
  local port=443  # jail watches both 80 and 443

  log_info "$(t ops.jails.creating)"

  pkg_install fail2ban  # idempotent if already installed

  write_file /etc/fail2ban/jail.d/10-vps-setup-nginx.local 644 <<EOF
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

  # Create custom nginx-bad-request filter (blocks repeated 400/404/444 from same IP)
  write_file /etc/fail2ban/filter.d/nginx-bad-request.conf 644 <<'EOF'
# Managed by vps-setup — blocks IPs that repeatedly hit bad requests
[Definition]
failregex = ^<HOST> - - \[.*\] "(GET|POST|HEAD|PUT|DELETE|CONNECT|OPTIONS|PATCH|PROPFIND|MKCOL|COPY|MOVE).*" (400|404|444|499) .*$
ignoreregex =
EOF

  # Create custom nginx-botsearch filter (scanner/robot detection)
  write_file /etc/fail2ban/filter.d/nginx-botsearch.conf 644 <<'EOF'
# Managed by vps-setup — blocks aggressive URL scanners
[Definition]
failregex = ^<HOST> - - \[.*\] "(GET|POST|HEAD).*" (404|444) .*$
ignoreregex =
EOF

  svc_restart fail2ban
  log_ok "$(t ops.jails.done)"
}

summary_nginx_jails() { t sum.jails; }
