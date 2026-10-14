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

# Backups and monitoring are shared with Ubuntu (distro-neutral scripts + systemd timers).
