#!/usr/bin/env bash
# shellcheck shell=bash
# AlmaLinux / Rocky / RHEL — HTTPS + domain wizard.
# Certbot comes from EPEL; nginx site layout uses conf.d, not sites-available.
# shellcheck source=../ubuntu/60-ssl.sh
source "$ROOT_DIR/modules/ubuntu/60-ssl.sh"

install_certbot_pkgs() {
  local servers pkgs=(certbot python3-certbot)
  servers=$(target_servers)
  if grep -qx nginx <<<"$servers"; then pkgs+=(python3-certbot-nginx); fi
  if grep -qx apache <<<"$servers"; then pkgs+=(python3-certbot-apache); fi

  if ! pkg_installed certbot; then
    pkg_install epel-release || true
    pkg_update
  fi
  pkg_install "${pkgs[@]}"
  run systemctl enable --now certbot-renew.timer 2>/dev/null || run systemctl enable --now certbot.timer
}

# RHEL nginx: a "site" is a single file in conf.d.
site_exists() {
  case "$1" in
    nginx)  [[ -e /etc/nginx/conf.d/$2.conf ]] ;;
    apache) [[ -e /etc/httpd/conf.d/$2.conf ]] ;;
    caddy)  [[ -e /etc/caddy/sites-enabled/$2.caddy ]] ;;
    *) return 1 ;;
  esac
}

site_write_nginx() {
  local type=$1 d=$2 content
  shift 2
  content=$(render_tpl "$TPL_DIR/nginx/sites/$type.conf.tpl" "$@") || return 1
  printf '%s\n' "$content" | nginx_filter | write_file "/etc/nginx/conf.d/$d.conf" 644 || return 1
  nginx_apply "/etc/nginx/conf.d/$d.conf"
}

site_write_apache() {
  local type=$1 d=$2 content
  shift 2
  content=$(render_tpl "$TPL_DIR/apache/sites/$type.conf.tpl" "$@") || return 1
  printf '%s\n' "$content" | write_file "/etc/httpd/conf.d/$d.conf" 644 || return 1
  apache_apply "/etc/httpd/conf.d/$d.conf"
}

# PHP socket path differs on RHEL.
default_php_socket() { printf '/run/php-fpm/www.sock'; }
