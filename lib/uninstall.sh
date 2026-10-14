#!/usr/bin/env bash
# =============================================================================
# VPS Setup — uninstall / rollback
# Removes files and configs created by vps-setup. Does NOT uninstall packages.
#
# Usage:  sudo ./lib/uninstall.sh [--yes] [--dry-run]
#
# Safety rules:
#   - Every web server config is tested before it is reloaded. Snippets that a website still
#     includes are kept, so no running site breaks.
#   - SSH: the drop-in is removed only if sshd accepts the result, and port 22 is opened in the
#     firewall first when SSH was on a custom port.
#   - A sudo rule is kept when the user has no password (removing it would lock them out of sudo).
#   - Package-owned files we rewrote are restored from backup instead of deleted.
# =============================================================================
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSUME_YES=0
UNINSTALL_DRY=0
for arg in "$@"; do
  case $arg in
    --yes|-y)  ASSUME_YES=1 ;;
    --dry-run) UNINSTALL_DRY=1 ;;
    -h|--help) sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (use --yes, --dry-run or --help)" >&2; exit 2 ;;
  esac
done

# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"

if (( EUID != 0 )) && (( ! UNINSTALL_DRY )); then
  echo "Run as root: sudo $0 $*" >&2
  exit 1
fi

CONFIRM_MSG="This will remove vps-setup managed files and backup configs.\nPackages installed by vps-setup are NOT removed.\n\nContinue?"

if (( ! ASSUME_YES )) && (( ! UNINSTALL_DRY )); then
  echo -e "$CONFIRM_MSG"
  read -r -p "Type 'yes' to continue: " reply
  [[ $reply == yes ]] || { echo "Cancelled."; exit 0; }
fi

(( UNINSTALL_DRY )) && echo "==> DRY RUN: nothing is changed, the steps are only shown."
echo "==> Rolling back vps-setup changes..."

# ------------------------------------------------------------------ helpers
# act <cmd...>: run a command, or only show it with --dry-run
act() {
  if (( UNINSTALL_DRY )); then echo "  [dry-run] $*"; return 0; fi
  "$@"
}

# remove <path...>: delete files that exist and say so; missing files are silent
remove() {
  local f
  for f in "$@"; do
    [[ -e $f || -L $f ]] || continue
    if (( UNINSTALL_DRY )); then echo "  [dry-run] would remove: $f"; continue; fi
    if rm -f "$f"; then echo "  removed: $f"; else echo "  WARN: could not remove $f"; fi
  done
}

# oldest_backup <path>: the earliest backup of <path> that is not our own managed version
oldest_backup() {
  local f=$1 b
  while IFS= read -r b; do
    grep -qs 'Managed by vps-setup' "$b" || { printf '%s' "$b"; return 0; }
  done < <(find "$BACKUP_DIR" -maxdepth 1 -name "$(printf '%s' "$f" | tr / _).*" 2>/dev/null | sort)
  return 1
}

# restore_or_note <path>: a package-owned file we rewrote goes back to its original from backup
restore_or_note() {
  local f=$1 orig
  grep -qs 'Managed by vps-setup' "$f" || return 0
  if orig=$(oldest_backup "$f"); then
    act cp -a "$orig" "$f" && echo "  restored: $f (from backup)"
  else
    echo "  NOTE: $f was written by vps-setup and has no backup; it was left in place."
    echo "        Reinstall its package to get the stock version back."
  fi
}

# ------------------------------------------------------------------ web servers
# Nginx snippets are included by every website the domain wizard created. Remove them only when no
# remaining config still includes them, otherwise the next reload would take all sites down.
nginx_users=$(grep -rlsF 'snippets/vps-setup/' /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null \
  | grep -vE '/00-default(-https)?\.conf$' | sort -u)

remove /etc/nginx/conf.d/00-vps-setup.conf /etc/nginx/sites-available/00-default.conf \
       /etc/nginx/sites-available/00-default-https.conf /etc/nginx/sites-enabled/00-default.conf \
       /etc/nginx/sites-enabled/00-default-https.conf \
       /etc/nginx/conf.d/00-default.conf /etc/nginx/conf.d/00-default-https.conf

if [[ -n $nginx_users ]]; then
  echo "  KEPT: /etc/nginx/snippets/vps-setup/ (still used by these sites):"
  while IFS= read -r f; do echo "        $f"; done <<<"$nginx_users"
  echo "        Remove those sites first (sudo ./setup.sh --remove-domain DOMAIN), then run this again."
else
  remove /etc/nginx/snippets/vps-setup/security-headers.conf /etc/nginx/snippets/vps-setup/deny-hidden.conf \
         /etc/nginx/snippets/vps-setup/static-cache.conf /etc/nginx/snippets/vps-setup/proxy-params.conf
  [[ -d /etc/nginx/snippets/vps-setup ]] && act rmdir /etc/nginx/snippets/vps-setup 2>/dev/null
fi

remove /etc/apache2/conf-available/vps-setup.conf /etc/apache2/conf-enabled/vps-setup.conf \
       /etc/apache2/sites-available/000-vps-default.conf /etc/apache2/sites-enabled/000-vps-default.conf \
       /etc/httpd/conf.d/00-vps-setup.conf /etc/httpd/conf.d/000-vps-default.conf
# RHEL: the APACHE_LOG_DIR define is needed as long as one of our sites remains
if ! grep -ls 'APACHE_LOG_DIR' /etc/httpd/conf.d/*.conf 2>/dev/null | grep -qv '00-vps-setup-env.conf'; then
  remove /etc/httpd/conf.d/00-vps-setup-env.conf
fi
# RHEL: our copy of Debian's fastcgi-php snippet, only when no site uses it any more
if grep -qs 'Managed by vps-setup' /etc/nginx/snippets/fastcgi-php.conf \
   && ! grep -rqsF 'snippets/fastcgi-php.conf' /etc/nginx/conf.d; then
  remove /etc/nginx/snippets/fastcgi-php.conf
fi

for f in /etc/caddy/sites-enabled/00-*.caddy; do remove "$f"; done

# ------------------------------------------------------------------ Cloudflare real-IP support
act systemctl disable --now vps-setup-cloudflare.timer >/dev/null 2>&1 || true
if command -v a2disconf >/dev/null 2>&1 && [[ -e /etc/apache2/conf-enabled/vps-setup-cloudflare.conf ]]; then
  act a2disconf vps-setup-cloudflare >/dev/null 2>&1
fi
remove /etc/nginx/conf.d/01-vps-setup-cloudflare.conf /etc/apache2/conf-available/vps-setup-cloudflare.conf \
       /etc/apache2/conf-enabled/vps-setup-cloudflare.conf /etc/httpd/conf.d/01-vps-setup-cloudflare.conf \
       /usr/local/sbin/vps-setup-cloudflare-ips /etc/vps-setup/cloudflare.conf \
       /etc/systemd/system/vps-setup-cloudflare.service /etc/systemd/system/vps-setup-cloudflare.timer

# Test each installed web server, then reload it. A failing test is reported, never reloaded.
reload_if_ok() { # <name> <unit> <test cmd...>
  local name=$1 unit=$2; shift 2
  command -v "$1" >/dev/null 2>&1 || return 0
  if (( UNINSTALL_DRY )); then echo "  [dry-run] $* && systemctl reload $unit"; return 0; fi
  if "$@" >/dev/null 2>&1; then
    systemctl is-active --quiet "$unit" && systemctl reload "$unit" && echo "  reloaded: $name"
  else
    echo "  ERROR: $name rejects its configuration now; it was NOT reloaded, so running sites keep working."
    echo "         See: sudo $*"
  fi
}
reload_if_ok Nginx nginx nginx -t
reload_if_ok Apache apache2 apache2ctl configtest
reload_if_ok Apache httpd apachectl configtest
reload_if_ok Caddy caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

# ------------------------------------------------------------------ SSH
ssh_dropin=/etc/ssh/sshd_config.d/00-vps-setup.conf
if [[ -f $ssh_dropin ]]; then
  ssh_port=$(sed -n 's/^Port[[:space:]]\+\([0-9]\+\).*/\1/p' "$ssh_dropin" | head -n 1)
  if (( UNINSTALL_DRY )); then
    echo "  [dry-run] remove $ssh_dropin, check with sshd -t, then reload SSH"
  else
    tmp_dropin=$(mktemp)
    cp -a "$ssh_dropin" "$tmp_dropin"
    rm -f "$ssh_dropin"
    if sshd -t 2>/dev/null; then
      # SSH goes back to port 22: make sure the firewall lets it in before sshd moves
      if [[ -n $ssh_port && $ssh_port != 22 ]]; then
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
          ufw allow 22/tcp comment 'SSH' >/dev/null && echo "  firewall: opened 22/tcp (UFW)"
        fi
        if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
          firewall-cmd --permanent --add-service=ssh >/dev/null && firewall-cmd --reload >/dev/null \
            && echo "  firewall: opened ssh (firewalld)"
        fi
      fi
      systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
      rm -f "$tmp_dropin"
      echo "  removed: $ssh_dropin"
      if [[ -n $ssh_port && $ssh_port != 22 ]]; then
        echo "  NOTE: SSH now listens on port 22 again (was $ssh_port). Keep this session open and test"
        echo "        a NEW login on port 22 before you close it. Port $ssh_port is still open in the firewall."
      fi
    else
      cp -a "$tmp_dropin" "$ssh_dropin"; rm -f "$tmp_dropin"
      echo "  ERROR: sshd rejects its configuration without our drop-in; it was put back unchanged."
    fi
  fi
fi

# ------------------------------------------------------------------ sudo
# Removing a NOPASSWD rule from a user that has no password would leave nobody able to use sudo.
for f in /etc/sudoers.d/90-vps-setup-*; do
  [[ -f $f ]] || continue
  u=${f#/etc/sudoers.d/90-vps-setup-}
  pw_state=$(passwd -S "$u" 2>/dev/null | awk '{print $2}')
  if [[ $pw_state == P || $pw_state == PS ]]; then
    remove "$f"
  else
    echo "  KEPT: $f — '$u' has no password, so without it '$u' could not use sudo."
    echo "        Set one first (sudo passwd $u), then: sudo rm $f"
  fi
done

# ------------------------------------------------------------------ system tweaks
remove /etc/sysctl.d/99-vps-setup.conf /etc/apt/apt.conf.d/20auto-upgrades /etc/apt/apt.conf.d/52vps-setup-unattended
restore_or_note /etc/dnf/automatic.conf   # belongs to the dnf-automatic package: restore, never delete

# ------------------------------------------------------------------ fail2ban
remove /etc/fail2ban/jail.d/00-vps-setup.local /etc/fail2ban/jail.d/10-vps-setup-nginx.local \
       /etc/fail2ban/filter.d/nginx-bad-request.conf
# nginx-botsearch.conf belongs to fail2ban itself. Only our OLD custom version (it carries the
# marker) is replaced, and the original comes back from backup when we have one.
restore_or_note /etc/fail2ban/filter.d/nginx-botsearch.conf
if command -v fail2ban-client >/dev/null 2>&1 && systemctl is-active --quiet fail2ban; then
  act systemctl restart fail2ban && echo "  reloaded: fail2ban"
fi

# ------------------------------------------------------------------ databases
for f in /etc/postgresql/*/main/conf.d/vps-setup-tuning.conf /var/lib/pgsql/data/conf.d/vps-setup-tuning.conf \
         /etc/mysql/mysql.conf.d/vps-setup-tuning.cnf /etc/mysql/mariadb.conf.d/vps-setup-tuning.cnf \
         /etc/my.cnf.d/vps-setup-tuning.cnf; do
  remove "$f"
done
echo "  NOTE: database tuning takes effect after the database service restarts (data is untouched)."

for f in /etc/redis/redis.conf /etc/redis.conf; do restore_or_note "$f"; done

# MySQL root login. NOT removed on purpose: root authenticates with this password now,
# so deleting the file would lock you out of MySQL.
if grep -qs 'Managed by vps-setup' /root/.my.cnf; then
  echo "  NOTE: /root/.my.cnf holds the MySQL root login set by vps-setup. It was kept so you do not"
  echo "        lose access. Remove it only after you have set a password you know."
fi

# ------------------------------------------------------------------ scripts, services, pages
for t in vps-setup-backup vps-setup-health; do
  [[ -e /etc/systemd/system/$t.timer ]] && act systemctl disable --now "$t.timer" >/dev/null 2>&1
done
remove /usr/local/bin/vps-setup-backup /usr/local/bin/vps-setup-health \
       /etc/cron.d/vps-setup-backup /etc/cron.d/vps-setup-health \
       /etc/systemd/system/vps-setup-backup.service /etc/systemd/system/vps-setup-backup.timer \
       /etc/systemd/system/vps-setup-health.service /etc/systemd/system/vps-setup-health.timer \
       /etc/systemd/system/frankenphp.service
act systemctl daemon-reload >/dev/null 2>&1 || true

if [[ -d /var/www/_default ]]; then act rm -rf /var/www/_default && echo "  removed: /var/www/_default"; fi

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
for d in /etc/vps-setup /var/lib/vps-setup; do
  if [[ -d $d ]]; then act rm -rf "$d" && echo "  removed: $d"; fi
done

# Swap file (if created by vps-setup)
if [[ -f /swapfile ]] && grep -q '/swapfile' /etc/fstab 2>/dev/null; then
  echo "  NOTE: /swapfile was not removed. Run these to remove it manually:"
  echo "    sudo swapoff /swapfile && sudo rm -f /swapfile"
  echo "    sudo sed -i '/\\/swapfile/d' /etc/fstab"
fi

if [[ -L /usr/local/bin/vps-setup ]]; then
  echo "  NOTE: the vps-setup tool itself was kept. To remove it too:"
  echo "    sudo rm -rf \"$(dirname "$(readlink -f /usr/local/bin/vps-setup)")\" /usr/local/bin/vps-setup"
fi

echo ""
echo "Done. Packages installed by vps-setup remain installed."
echo "Backups (if any) are in $BACKUP_DIR"
echo ""
echo "To remove packages that are no longer needed:"
if command -v dnf >/dev/null 2>&1; then
  echo "  sudo dnf autoremove"
else
  echo "  sudo apt-get autoremove --purge"
fi
