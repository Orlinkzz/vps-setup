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

# Web server configs
for f in /etc/nginx/conf.d/00-vps-setup.conf /etc/nginx/sites-available/00-default.conf \
         /etc/nginx/sites-available/00-default-https.conf /etc/nginx/sites-enabled/00-default.conf \
         /etc/nginx/sites-enabled/00-default-https.conf; do
  rm -f "$f" 2>/dev/null; echo "  removed: $f"
done

for f in /etc/apache2/conf-available/vps-setup.conf /etc/apache2/conf-enabled/vps-setup.conf \
         /etc/apache2/sites-available/000-vps-default.conf /etc/apache2/sites-enabled/000-vps-default.conf; do
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
echo "  removed: sysctl + apt configs"

# Fail2ban jails
rm -f /etc/fail2ban/jail.d/00-vps-setup.local /etc/fail2ban/jail.d/10-vps-setup-nginx.local
rm -f /etc/fail2ban/filter.d/nginx-bad-request.conf /etc/fail2ban/filter.d/nginx-botsearch.conf
echo "  removed: fail2ban configs"

# DB tuning
rm -f /etc/postgresql/*/main/conf.d/vps-setup-tuning.conf 2>/dev/null || true
rm -f /etc/mysql/mysql.conf.d/vps-setup-tuning.cnf 2>/dev/null || true
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
