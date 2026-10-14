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

# "Sudah ada ATAU akan dipasang di run ini". Prompt berjalan sebelum instalasi, jadi cek
# binary saja membuat fitur yang bergantung pada webserver/DB di run yang sama gugur diam-diam.
_nginx_ready() {
  _has_nginx || { feature_selected webserver && [[ ${CFG[webserver]:-} == nginx ]]; }
}
_db_ready() {
  _has_postgres || _has_mysql || feature_selected postgresql || feature_selected mysql
}

_backup_dir() {
  local dir="$BACKUP_ROOT/db"
  (( DRY_RUN )) || install -d -m 750 "$dir"
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

  if ! _db_ready; then
    ui_msg "$title" "$(t ops.backup.no_db)"
    return 1
  fi

  CFG[backup_retention]=$(ui_input "$title" "$(t ops.backup.ask_retention)" "7") || return 1
  (( ASSUME_YES )) && CFG[backup_retention]=${CFG[backup_retention]:-7}
}

# systemd_timer <name> <OnCalendar> <command> <description>
# Runs <command> as root on a schedule. systemd timers work on every supported system; minimal
# images (AlmaLinux/Rocky containers, some cloud images) do not ship a cron daemon.
systemd_timer() {
  local name=$1 when=$2 cmd=$3 desc=$4
  write_file "/etc/systemd/system/$name.service" 644 <<EOF
# Managed by vps-setup
[Unit]
Description=$desc

[Service]
Type=oneshot
ExecStart=$cmd
EOF
  write_file "/etc/systemd/system/$name.timer" 644 <<EOF
# Managed by vps-setup
[Unit]
Description=$desc (schedule)

[Timer]
OnCalendar=$when
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF
  run systemctl daemon-reload
  run systemctl enable --now "$name.timer"
  # Older versions used cron for the same job
  [[ -e /etc/cron.d/$name ]] && run rm -f "/etc/cron.d/$name"
  return 0
}

run_db_backup() {
  local dir retention=${CFG[backup_retention]:-7}
  dir=$(_backup_dir)

  log_info "$(t ops.backup.creating)"

  # Write the backup script (the same on every supported system)
  write_file /usr/local/bin/vps-setup-backup 750 <<'SCRIPT'
#!/usr/bin/env bash
# Managed by vps-setup — runs daily (systemd timer vps-setup-backup.timer)
# A dump only counts when the whole pipeline succeeded: it is written to a temporary file first
# and renamed at the end, so a half-written .sql.gz never looks like a good backup.
set -uo pipefail
umask 077
LOG=/var/log/vps-setup-backup.log
DIR=/var/backups/vps-setup/db
RETENTION=7
# shellcheck disable=SC1091
[ -r /etc/vps-setup/backup.conf ] && . /etc/vps-setup/backup.conf

mkdir -p "$DIR"
echo "=== $(date) ===" >>"$LOG"
failed=0
stamp=$(date +%F)

# dump <name> <engine> <command...>: run the dump command, gzip it, keep it only on success
dump() {
  local name=$1 engine=$2; shift 2
  local out="$DIR/${name}_${engine}_${stamp}.sql.gz"
  if "$@" | gzip >"$out.part" && gzip -t "$out.part" 2>/dev/null; then
    mv -f "$out.part" "$out"
    echo "  ok   $engine: $name" >>"$LOG"
  else
    rm -f "$out.part"
    echo "  FAIL $engine: $name" >>"$LOG"
    failed=1
  fi
}

# PostgreSQL ("runuser" exists everywhere; minimal Debian has no sudo)
if command -v pg_dump >/dev/null 2>&1 && id postgres >/dev/null 2>&1; then
  for db in $(runuser -u postgres -- psql -At -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname <> 'postgres'" 2>>"$LOG"); do
    dump "$db" postgresql runuser -u postgres -- pg_dump "$db"
  done
fi

# MySQL / MariaDB (root login from /root/.my.cnf or the unix socket)
if command -v mysqldump >/dev/null 2>&1; then
  for db in $(mysql -NBe "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys')" 2>>"$LOG"); do
    dump "$db" mysql mysqldump --single-transaction --routines --triggers --events "$db"
  done
fi

# Rotate older than RETENTION days (only complete dumps carry the .sql.gz name)
find "$DIR" -name '*.sql.gz' -mtime "+$RETENTION" -delete
find "$DIR" -name '*.sql.gz.part' -delete
echo "  retention: $RETENTION days" >>"$LOG"
if [ "$failed" -ne 0 ]; then
  echo "  RESULT: at least one backup FAILED" >>"$LOG"
  exit 1
fi
SCRIPT

  # Write retention override
  write_file /etc/vps-setup/backup.conf 644 <<EOF
# Managed by vps-setup
RETENTION=$retention
EOF

  systemd_timer vps-setup-backup "*-*-* 03:00:00" /usr/local/bin/vps-setup-backup "vps-setup database backups"

  log_ok "$(t ops.backup.done)"
}

summary_db_backup() { t sum.backup "${CFG[backup_retention]:-7}"; }

# ============================================================ Monitoring
prompt_monitoring() {
  if _db_ready; then
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
# Prints a one-page system health summary. Works on Debian/Ubuntu and AlmaLinux/Rocky.
set -uo pipefail

echo "=== System Health ==="
echo "Uptime:  $(uptime -p | sed 's/up //')"
echo "Load:    $(cut -d' ' -f1-3 /proc/loadavg)"
echo "Memory:  $(free -h | awk '/^Mem:/{print $3 " / " $2}')"
echo "Disk:    $(df -h / | awk 'NR==2{print $3 " / " $2 " (" $5 ")"}')"
echo "Swap:    $(free -h | awk '/^Swap:/{print $3 " / " $2}')"
echo ""

echo "=== Services ==="
# Names differ per distro (ssh/sshd, apache2/httpd, redis-server/redis ...): only units that exist are shown
for svc in ssh sshd fail2ban ufw firewalld nginx apache2 httpd caddy php-fpm postgresql mysql mariadb \
           redis-server redis docker unattended-upgrades dnf-automatic.timer vps-setup-backup.timer; do
  systemctl cat "$svc" >/dev/null 2>&1 || continue   # not installed on this system
  if systemctl is-active --quiet "$svc"; then echo "  ✓ $svc"
  elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then echo "  ✗ $svc ($(systemctl is-active "$svc" 2>/dev/null))"
  fi
done
# Debian/Ubuntu name PHP-FPM after its version (php8.3-fpm ...)
for unit in $(systemctl list-units --type=service --all --no-legend 'php*-fpm.service' 2>/dev/null | awk '{print $1}' | grep -E '^php[0-9.]+-fpm'); do
  if systemctl is-active --quiet "$unit"; then echo "  ✓ $unit"; else echo "  ✗ $unit"; fi
done

echo ""
echo "=== Backups ==="
DIR=/var/backups/vps-setup/db
if [ -d "$DIR" ]; then
  count=$(find "$DIR" -name '*.sql.gz' 2>/dev/null | wc -l)
  echo "  DB backup files: $count"
  find "$DIR" -name '*.sql.gz' -printf '%T@ %f\n' 2>/dev/null | sort -n | tail -5 | cut -d' ' -f2 | sed 's/^/    /'
  if grep -q 'RESULT: at least one backup FAILED' <(tail -n 30 /var/log/vps-setup-backup.log 2>/dev/null); then
    echo "  ✗ the last backup run reported a failure: see /var/log/vps-setup-backup.log"
  fi
else
  echo "  No backup directory"
fi

echo ""
echo "=== Last login failures ==="
n=$(journalctl -u ssh -u sshd --since "1 day ago" -o cat 2>/dev/null | grep -cE "Failed password|Invalid user")
echo "  $n failed SSH attempts (24h)"
SCRIPT
  run chmod +x /usr/local/bin/vps-setup-health

  # Nightly health snapshot (systemd timer; the output goes to the journal and a log file)
  systemd_timer vps-setup-health "*-*-* 05:00:00" \
    "/bin/sh -c '/usr/local/bin/vps-setup-health >/var/log/vps-setup-health.log 2>&1'" "vps-setup nightly health snapshot"

  log_ok "$(t ops.monitor.done)"
}

summary_monitoring() { t sum.monitor; }
notes_monitoring()   { t note.monitor; echo; }

# ============================================================ Nginx fail2ban jails
# Older versions of this tool overwrote fail2ban's own nginx-botsearch filter with an
# aggressive one (any 2 x 404 = 4h ban). Remove it and restore the packaged filter.
_f2b_drop_custom_botsearch() {
  local f=/etc/fail2ban/filter.d/nginx-botsearch.conf
  grep -qs 'Managed by vps-setup' "$f" || return 0
  backup_file "$f"
  run rm -f "$f"
  case "$OS_ID" in
    almalinux|rocky|rhel|centos)
      run dnf "${DNF_OPTS[@]}" -y reinstall fail2ban-server || log_warn "$(t ops.jails.restore_failed)" ;;
    *)
      run env DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" -y install --reinstall \
        -o Dpkg::Options::=--force-confmiss fail2ban || log_warn "$(t ops.jails.restore_failed)" ;;
  esac
}

prompt_nginx_jails() {
  if ! _nginx_ready; then
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

# Uses fail2ban's own nginx-botsearch filter (known scanner paths such as wp-login.php).
[nginx-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
logpath  = /var/log/nginx/error.log
maxretry = 3
bantime  = 2h
findtime = 10m

[nginx-bad-request]
enabled   = true
port      = http,https
filter    = nginx-bad-request
logpath   = /var/log/nginx/access.log
maxretry  = 10
bantime   = 1h
findtime  = 10m
EOF

  # Create custom nginx-bad-request filter (blocks repeated 400/404/444 from same IP)
  write_file /etc/fail2ban/filter.d/nginx-bad-request.conf 644 <<'EOF'
# Managed by vps-setup — blocks IPs that keep sending malformed (400) or dropped (444) requests.
# 404 is deliberately NOT counted: broken links, favicons and crawlers would ban real visitors.
[Definition]
failregex = ^<HOST> - \S+ \[[^\]]+\] "[^"]*" (400|444) \d+ .*$
ignoreregex =
EOF

  _f2b_drop_custom_botsearch

  svc_restart fail2ban
  log_ok "$(t ops.jails.done)"
}

summary_nginx_jails() { t sum.jails; }
