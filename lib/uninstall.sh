#!/usr/bin/env bash
# =============================================================================
# VPS Setup — uninstall / rollback
# Removes files and configs created by vps-setup. Does NOT uninstall packages.
#
# Usage:  sudo ./lib/uninstall.sh [--yes]
# =============================================================================
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSUME_YES=0
[[ ${1:-} == --yes ]] && ASSUME_YES=1

# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"

CONFIRM_MSG="This will remove vps-setup managed files and backup configs.\nPackages installed by vps-setup are NOT removed.\n\nContinue?"

if (( ! ASSUME_YES )); then
  echo -e "$CONFIRM_MSG"
  read -r -p "Type 'yes' to continue: " reply
  [[ $reply == yes ]] || { echo "Cancelled."; exit 0; }
fi

echo "==> Rolling back vps-setup changes..."

# Web server configs (Debian/Ubuntu paths, then AlmaLinux/Rocky/RHEL paths)
for f in /etc/nginx/conf.d/00-vps-setup.conf /etc/nginx/sites-available/00-default.conf \
         /etc/nginx/sites-available/00-default-https.conf /etc/nginx/sites-enabled/00-default.conf \
         /etc/nginx/sites-enabled/00-default-https.conf \
         /etc/nginx/conf.d/00-default.conf /etc/nginx/conf.d/00-default-https.conf \
         /etc/nginx/snippets/vps-setup/security-headers.conf /etc/nginx/snippets/vps-setup/deny-hidden.conf \
         /etc/nginx/snippets/vps-setup/static-cache.conf /etc/nginx/snippets/vps-setup/proxy-params.conf; do
  rm -f "$f" 2>/dev/null; echo "  removed: $f"
done
rmdir /etc/nginx/snippets/vps-setup 2>/dev/null

for f in /etc/apache2/conf-available/vps-setup.conf /etc/apache2/conf-enabled/vps-setup.conf \
         /etc/apache2/sites-available/000-vps-default.conf /etc/apache2/sites-enabled/000-vps-default.conf \
         /etc/httpd/conf.d/00-vps-setup.conf /etc/httpd/conf.d/000-vps-default.conf; do
  rm -f "$f" 2>/dev/null; echo "  removed: $f"
done

rm -f /etc/caddy/sites-enabled/00-*.caddy 2>/dev/null
echo "  removed: caddy catch-all sites"

# SSH drop-in
rm -f /etc/ssh/sshd_config.d/00-vps-setup.conf
echo "  removed: SSH config drop-in"

# Sudoers drop-ins
for f in /etc/sudoers.d/90-vps-setup-*; do
  [[ -f $f ]] && rm -f "$f" && echo "  removed: $f"
done

# System tweaks
rm -f /etc/sysctl.d/99-vps-setup.conf
rm -f /etc/apt/apt.conf.d/20auto-upgrades /etc/apt/apt.conf.d/52vps-setup-unattended
rm -f /etc/dnf/automatic.conf
echo "  removed: sysctl + apt/dnf configs"

# Fail2ban jails
rm -f /etc/fail2ban/jail.d/00-vps-setup.local /etc/fail2ban/jail.d/10-vps-setup-nginx.local
rm -f /etc/fail2ban/filter.d/nginx-bad-request.conf
# nginx-botsearch.conf belongs to fail2ban itself. Only our OLD custom version (it carries the
# marker) is removed, and the original is put back from backup when we have one.
bot=/etc/fail2ban/filter.d/nginx-botsearch.conf
if grep -qs 'Managed by vps-setup' "$bot"; then
  rm -f "$bot"
  orig=$(find "$BACKUP_DIR" -maxdepth 1 -name '_etc_fail2ban_filter.d_nginx-botsearch.conf.*' 2>/dev/null | sort | head -n 1)
  if [[ -n $orig ]] && ! grep -qs 'Managed by vps-setup' "$orig"; then
    cp -a "$orig" "$bot" && echo "  restored: $bot (from backup)"
  else
    echo "  NOTE: removed our old $bot; reinstall the fail2ban package to get the stock one back."
  fi
fi
echo "  removed: fail2ban configs"

# DB tuning (Debian paths + RHEL paths)
rm -f /etc/postgresql/*/main/conf.d/vps-setup-tuning.conf 2>/dev/null || true
rm -f /var/lib/pgsql/data/conf.d/vps-setup-tuning.conf 2>/dev/null || true
rm -f /etc/mysql/mysql.conf.d/vps-setup-tuning.cnf 2>/dev/null || true
rm -f /etc/my.cnf.d/vps-setup-tuning.cnf 2>/dev/null || true
echo "  removed: database tuning configs"

# Redis
if [[ -f /etc/redis/redis.conf ]] && grep -q 'Managed by vps-setup' /etc/redis/redis.conf; then
  echo "  WARN: /etc/redis/redis.conf was rewritten by vps-setup. Restore from backup in $BACKUP_DIR"
fi

# Backup script + cron
rm -f /usr/local/bin/vps-setup-backup /usr/local/bin/vps-setup-health
rm -f /etc/cron.d/vps-setup-backup /etc/cron.d/vps-setup-health
echo "  removed: backup scripts + cron jobs"

# FrankenPHP service
rm -f /etc/systemd/system/frankenphp.service
echo "  removed: frankenphp systemd service"

# Default page
rm -rf /var/www/_default
echo "  removed: default page"

# MySQL root login. NOT removed on purpose: root authenticates with this password now,
# so deleting the file would lock you out of MySQL.
if grep -qs 'Managed by vps-setup' /root/.my.cnf; then
  echo "  NOTE: /root/.my.cnf holds the MySQL root login set by vps-setup. It was kept so you do not"
  echo "        lose access. Remove it only after you have set a password you know."
fi

# Software installed outside the package manager (like packages, it stays)
if [[ -d /opt/bun ]]; then
  echo "  NOTE: Bun (/opt/bun) was not removed: sudo rm -rf /opt/bun /usr/local/bin/bun /usr/local/bin/bunx"
fi

# A service vps-setup stopped to free port 80
stopped=$(sed -n 's/^web_stopped_unit=//p' /etc/vps-setup/settings.conf 2>/dev/null | tail -n 1)
if [[ -n $stopped ]]; then
  echo "  NOTE: vps-setup disabled the service '$stopped' to free port 80. To use it again:"
  echo "    sudo systemctl enable --now $stopped"
fi

# Settings + state
rm -rf /etc/vps-setup /var/lib/vps-setup
echo "  removed: settings + state"

# Swap file (if created by vps-setup)
if [[ -f /swapfile ]] && grep -q '/swapfile' /etc/fstab 2>/dev/null; then
  echo "  NOTE: /swapfile was not removed. Run these to remove it manually:"
  echo "    sudo swapoff /swapfile && sudo rm -f /swapfile"
  echo "    sudo sed -i '/\\/swapfile/d' /etc/fstab"
fi

echo ""
echo "Done. Packages installed by vps-setup remain installed."
echo "Backups (if any) are in $BACKUP_DIR"
echo ""
echo "To remove packages that are no longer needed:"
echo "  sudo apt-get autoremove --purge"
