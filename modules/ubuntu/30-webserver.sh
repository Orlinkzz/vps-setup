#!/usr/bin/env bash
# shellcheck shell=bash
# Ubuntu — web server: Nginx, Caddy or Apache (pick one).
# Templates live in templates/<server>/ ; this file only installs, wires and validates them.

register_feature webserver web on

TPL_DIR="$ROOT_DIR/templates"
MAX_BODY="64m"
MAX_BODY_BYTES=67108864
DEFAULT_PAGE_DIR=/var/www/_default

# ------------------------------------------------------------------ helpers
# Web servers currently installed (one name per line: nginx, apache, caddy).
installed_webservers() {
  if command -v nginx >/dev/null 2>&1 && pkg_installed nginx; then echo nginx; fi
  if pkg_installed apache2; then echo apache; fi
  if command -v caddy >/dev/null 2>&1; then echo caddy; fi
  return 0
}

# Name of the process listening on port 80 (empty if free).
port80_owner() {
  ss -ltnpH 'sport = :80' 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | head -n 1 | sed -E 's/.*\("//; s/"$//' || true
}

# ensure_acme_email <dialog title> — asks once, remembers in settings.
ensure_acme_email() {
  local title=$1 cur email
  if (( ASSUME_YES )); then
    CFG[acme_email]=${CFG[acme_email]:-${CFG[arg_email]:-$(setting_get acme_email)}}
    return 0
  fi
  cur=${CFG[acme_email]:-$(setting_get acme_email)}
  if [[ -n $cur ]]; then CFG[acme_email]=$cur; return 0; fi
  if [[ -n ${CFG[acme_email_asked]:-} ]]; then return 0; fi
  while true; do
    email=$(ui_input "$title" "$(t acme.ask_email)" "") || return 1
    if [[ -z $email ]]; then
      if ui_yesno "$title" "$(t acme.no_email)" no; then
        CFG[acme_email]=""; CFG[acme_email_asked]=1; return 0
      fi
      continue
    fi
    if valid_email "$email"; then CFG[acme_email]=$email; CFG[acme_email_asked]=1; return 0; fi
    ui_msg "$title" "$(t acme.bad_email)"
  done
}

# True if nginx supports "ssl_reject_handshake" (>= 1.19.4).
nginx_reject_ok() {
  local v
  if command -v nginx >/dev/null 2>&1; then
    v=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')
    [[ -n $v && $(printf '%s\n1.19.4\n' "$v" | sort -V | head -n 1) == 1.19.4 ]]
    return
  fi
  [[ $(printf '%s\n22.04\n' "$OS_VERSION" | sort -V | tail -n 1) != 22.04 ]]
}

ws_default_page() {
  run install -d -m 755 "$DEFAULT_PAGE_DIR"
  write_file "$DEFAULT_PAGE_DIR/index.html" 644 <"$TPL_DIR/html/default.html.tpl"
}

ws_ufw_open() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    run ufw allow 80/tcp comment 'HTTP'
    run ufw allow 443/tcp comment 'HTTPS'
    log_info "$(t web.ufw_opened)"
  fi
}

# Config test + reload. On failure the given files are removed so the server stays healthy.
_ws_fail_cleanup() { local f; for f in "$@"; do rm -f "$f"; done; }

nginx_apply() {
  if (( DRY_RUN )); then log_dry "nginx -t && systemctl reload nginx"; return 0; fi
  if ! nginx -t >>"$LOG_FILE" 2>&1; then
    log_err "$(t web.config_invalid nginx)"
    nginx -t 2>&1 | sed 's/^/    /' >&2 || true
    _ws_fail_cleanup "$@"
    return 1
  fi
  if systemctl is-active --quiet nginx; then svc_reload nginx; else run systemctl start nginx; fi
}

apache_apply() {
  if (( DRY_RUN )); then log_dry "apachectl configtest && systemctl reload apache2"; return 0; fi
  if ! apachectl configtest >>"$LOG_FILE" 2>&1; then
    log_err "$(t web.config_invalid apache)"
    apachectl configtest 2>&1 | sed 's/^/    /' >&2 || true
    _ws_fail_cleanup "$@"
    return 1
  fi
  if systemctl is-active --quiet apache2; then svc_reload apache2; else run systemctl start apache2; fi
}

# shellcheck disable=SC2120  # optional args = files to delete when validation fails
caddy_apply() {
  if (( DRY_RUN )); then log_dry "caddy validate && systemctl reload caddy"; return 0; fi
  if ! caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >>"$LOG_FILE" 2>&1; then
    log_err "$(t web.config_invalid caddy)"
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1 | tail -n 15 | sed 's/^/    /' >&2 || true
    _ws_fail_cleanup "$@"
    return 1
  fi
  if systemctl is-active --quiet caddy; then svc_reload caddy; else run systemctl restart caddy; fi
}

# ------------------------------------------------------------------ prompt
prompt_webserver() {
  local title owner choice def=nginx installed
  title=$(t feat.webserver.title)
  installed=$(installed_webservers | head -n 1)
  [[ -n $installed ]] && def=$installed
  [[ -n ${CFG[arg_webserver]:-} ]] && def=${CFG[arg_webserver]}

  choice=$(ui_menu "$title" "$(t web.ask)" "$def" \
    nginx "$(t web.nginx)" caddy "$(t web.caddy)" apache "$(t web.apache)") || return 1

  owner=$(port80_owner)
  case "$owner" in
    ""|nginx|apache2|caddy)
      if [[ -n $owner ]]; then
        local mapped=$owner
        [[ $owner == apache2 ]] && mapped=apache
        if [[ $mapped != "$choice" ]]; then ui_msg "$title" "$(t web.port_busy "$owner" "$owner")"; return 1; fi
      fi ;;
    *) ui_msg "$title" "$(t web.port_busy "$owner" "$owner")"; return 1 ;;
  esac

  if ui_yesno "$title" "$(t web.ask_page)" yes; then CFG[web_catchall]=page; else CFG[web_catchall]=drop; fi
  [[ $choice == caddy ]] && { ensure_acme_email "$title" || return 1; }
  CFG[webserver]=$choice
}

summary_webserver() { t sum.web "${CFG[webserver]}" "${CFG[web_catchall]}"; }
notes_webserver()   { t note.webserver "$(primary_ip)"; }

# ------------------------------------------------------------------ run
run_webserver_nginx() {
  local f body snip=/etc/nginx/snippets/vps-setup tpl=default-drop
  log_info "$(t web.installing Nginx)"
  pkg_install nginx

  for f in security-headers deny-hidden static-cache proxy-params; do
    write_file "$snip/$f.conf" 644 <"$TPL_DIR/nginx/snippets/$f.conf"
  done
  body=$(render_tpl "$TPL_DIR/nginx/00-vps-setup.conf.tpl" MAX_BODY="$MAX_BODY") || return 1
  printf '%s\n' "$body" | write_file /etc/nginx/conf.d/00-vps-setup.conf 644
  # Ubuntu's stock nginx.conf already sets some of the same http-level directives; nginx refuses
  # duplicates, so the stock lines are commented out (backup kept) and ours in conf.d take over.
  backup_file /etc/nginx/nginx.conf
  run sed -i -E 's/^\s*worker_processes\s+.*/worker_processes auto;/' /etc/nginx/nginx.conf
  run sed -i -E 's/^[[:space:]]*(types_hash_max_size|keepalive_timeout|server_tokens|client_max_body_size|client_body_timeout|client_header_timeout|send_timeout|gzip|gzip_vary|gzip_proxied|gzip_comp_level|gzip_min_length|gzip_types|gzip_buffers|gzip_http_version)[[:space:]].*/# (vps-setup) &/' /etc/nginx/nginx.conf

  if [[ ${CFG[web_catchall]:-page} == page ]]; then tpl=default-page; ws_default_page; fi
  nginx_filter <"$TPL_DIR/nginx/$tpl.conf.tpl" | write_file /etc/nginx/sites-available/00-default.conf 644
  run ln -sfn /etc/nginx/sites-available/00-default.conf /etc/nginx/sites-enabled/00-default.conf
  run rm -f /etc/nginx/sites-enabled/default

  if ! ipv6_ok; then log_info "$(t web.no_ipv6)"; fi
  if nginx_reject_ok; then
    nginx_filter <"$TPL_DIR/nginx/default-https.conf.tpl" | write_file /etc/nginx/sites-available/00-default-https.conf 644
    run ln -sfn /etc/nginx/sites-available/00-default-https.conf /etc/nginx/sites-enabled/00-default-https.conf
  else
    log_warn "$(t web.old_nginx)"
    run rm -f /etc/nginx/sites-enabled/00-default-https.conf
  fi

  nginx_apply /etc/nginx/conf.d/00-vps-setup.conf \
    /etc/nginx/sites-enabled/00-default.conf /etc/nginx/sites-enabled/00-default-https.conf || return 1
  run systemctl enable nginx
}

run_webserver_apache() {
  local body tpl=default-drop
  log_info "$(t web.installing Apache)"
  pkg_install apache2
  run a2enmod rewrite headers deflate expires proxy proxy_http proxy_wstunnel proxy_fcgi setenvif

  body=$(render_tpl "$TPL_DIR/apache/vps-setup.conf.tpl" MAX_BODY="$MAX_BODY" MAX_BODY_BYTES="$MAX_BODY_BYTES") || return 1
  printf '%s\n' "$body" | write_file /etc/apache2/conf-available/vps-setup.conf 644
  run a2enconf vps-setup

  if [[ -e /etc/apache2/sites-enabled/000-default.conf ]]; then run a2dissite 000-default; fi
  if [[ -e /etc/apache2/sites-enabled/default-ssl.conf ]]; then run a2dissite default-ssl; fi

  if [[ ${CFG[web_catchall]:-page} == page ]]; then tpl=default-page; ws_default_page; fi
  write_file /etc/apache2/sites-available/000-vps-default.conf 644 <"$TPL_DIR/apache/$tpl.conf.tpl"
  run a2ensite 000-vps-default

  apache_apply /etc/apache2/conf-enabled/vps-setup.conf /etc/apache2/sites-enabled/000-vps-default.conf || return 1
  run systemctl enable apache2
}

run_webserver_caddy() {
  local global="" catch body list=/etc/apt/sources.list.d/caddy-stable.list key=/usr/share/keyrings/caddy-stable-archive-keyring.gpg
  log_info "$(t web.installing Caddy)"
  if ! command -v caddy >/dev/null 2>&1; then
    pkg_install apt-transport-https curl gnupg ca-certificates
    if [[ ! -f $key ]]; then
      run_sh "set -o pipefail; curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o $key"
    fi
    if [[ ! -f $list ]]; then
      run_sh "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' -o $list"
    fi
    run chmod a+r "$key" "$list"
    pkg_update
    pkg_install caddy
  fi

  [[ -n ${CFG[acme_email]:-} ]] && global=$'{\n    email '"${CFG[acme_email]}"$'\n}\n'
  if [[ ${CFG[web_catchall]:-page} == page ]]; then catch=catchall-page; ws_default_page; else catch=catchall-drop; fi
  catch=$(cat "$TPL_DIR/caddy/$catch.tpl")
  body=$(render_tpl "$TPL_DIR/caddy/Caddyfile.tpl" GLOBAL_OPTIONS="$global" CATCHALL="$catch") || return 1
  run install -d -m 755 /etc/caddy/sites-enabled
  printf '%s\n' "$body" | write_file /etc/caddy/Caddyfile 644
  caddy_apply || return 1
  run systemctl enable caddy
}

run_webserver() {
  local choice=${CFG[webserver]}
  case "$choice" in
    nginx)  run_webserver_nginx  ;;
    apache) run_webserver_apache ;;
    caddy)  run_webserver_caddy  ;;
    *) log_err "unknown web server: $choice"; return 1 ;;
  esac
  ws_ufw_open
  log_ok "$(t web.configured "$choice")"
}
