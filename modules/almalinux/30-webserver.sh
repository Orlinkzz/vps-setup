#!/usr/bin/env bash
# shellcheck shell=bash
# AlmaLinux / Rocky / RHEL — web server.
# Nginx and Caddy work mostly unchanged; Apache is "httpd" with different paths and no a2enmod.
# shellcheck source=../ubuntu/30-webserver.sh
source "$ROOT_DIR/modules/ubuntu/30-webserver.sh"

installed_webservers() {
  if command -v nginx >/dev/null 2>&1 && pkg_installed nginx; then echo nginx; fi
  if pkg_installed httpd; then echo apache; fi
  if command -v caddy >/dev/null 2>&1; then echo caddy; fi
  return 0
}

# RHEL nginx: sites live in conf.d/, there is no sites-available/sites-enabled pattern.
run_webserver_nginx() {
  local f body snip=/etc/nginx/snippets/vps-setup tpl=default-drop
  log_info "$(t web.installing Nginx)"
  pkg_install nginx

  install -d -m 755 /etc/nginx/snippets /etc/nginx/conf.d

  for f in security-headers deny-hidden static-cache proxy-params; do
    write_file "$snip/$f.conf" 644 <"$TPL_DIR/nginx/snippets/$f.conf"
  done
  body=$(render_tpl "$TPL_DIR/nginx/00-vps-setup.conf.tpl" MAX_BODY="$MAX_BODY") || return 1
  printf '%s\n' "$body" | write_file /etc/nginx/conf.d/00-vps-setup.conf 644
  run sed -i -E 's/^\s*worker_processes\s+.*/worker_processes auto;/' /etc/nginx/nginx.conf
  run sed -i -E 's/^[[:space:]]*(types_hash_max_size|keepalive_timeout|server_tokens|client_max_body_size|client_body_timeout|client_header_timeout|send_timeout|gzip|gzip_vary|gzip_proxied|gzip_comp_level|gzip_min_length|gzip_types|gzip_buffers|gzip_http_version)[[:space:]].*/# (vps-setup) &/' /etc/nginx/nginx.conf

  if [[ ${CFG[web_catchall]:-page} == page ]]; then tpl=default-page; ws_default_page; fi
  nginx_filter <"$TPL_DIR/nginx/$tpl.conf.tpl" | write_file /etc/nginx/conf.d/00-default.conf 644

  if nginx_reject_ok; then
    nginx_filter <"$TPL_DIR/nginx/default-https.conf.tpl" | write_file /etc/nginx/conf.d/00-default-https.conf 644
  else
    log_warn "$(t web.old_nginx)"
    run rm -f /etc/nginx/conf.d/00-default-https.conf
  fi

  nginx_apply /etc/nginx/conf.d/00-vps-setup.conf \
    /etc/nginx/conf.d/00-default.conf /etc/nginx/conf.d/00-default-https.conf || return 1
  run systemctl enable nginx
}

run_webserver_apache() {
  local body tpl=default-drop
  log_info "$(t web.installing Apache)"
  pkg_install httpd mod_ssl

  # SELinux: allow httpd to make outbound proxy connections
  if command -v setsebool >/dev/null 2>&1; then
    run setsebool -P httpd_can_network_connect 1
  fi

  # Apache on RHEL: /etc/httpd/conf.d/ instead of conf-available + a2enconf
  install -d -m 755 /etc/httpd/conf.d
  body=$(render_tpl "$TPL_DIR/apache/vps-setup.conf.tpl" MAX_BODY="$MAX_BODY" MAX_BODY_BYTES="$MAX_BODY_BYTES") || return 1
  printf '%s\n' "$body" | write_file /etc/httpd/conf.d/00-vps-setup.conf 644

  # Drop stock welcome page config so our catch-all wins
  run rm -f /etc/httpd/conf.d/welcome.conf

  if [[ ${CFG[web_catchall]:-page} == page ]]; then tpl=default-page; ws_default_page; fi
  write_file /etc/httpd/conf.d/000-vps-default.conf 644 <"$TPL_DIR/apache/$tpl.conf.tpl"

  apache_apply /etc/httpd/conf.d/00-vps-setup.conf /etc/httpd/conf.d/000-vps-default.conf || return 1
  run systemctl enable httpd
}

# httpd config test + service name differ from apache2
apache_apply() {
  if (( DRY_RUN )); then log_dry "httpd -t && systemctl reload httpd"; return 0; fi
  if ! httpd -t >>"$LOG_FILE" 2>&1; then
    log_err "$(t web.config_invalid apache)"
    httpd -t 2>&1 | sed 's/^/    /' >&2 || true
    _ws_fail_cleanup "$@"
    return 1
  fi
  if systemctl is-active --quiet httpd; then svc_reload httpd; else run systemctl start httpd; fi
}

ws_ufw_open() {
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    run firewall-cmd --permanent --add-service=http
    run firewall-cmd --permanent --add-service=https
    run firewall-cmd --reload
    log_info "$(t web.ufw_opened)"
  fi
}
