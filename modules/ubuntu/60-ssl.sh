#!/usr/bin/env bash
# shellcheck shell=bash
# Ubuntu — free HTTPS (Certbot) and the "add a website / domain" wizard.

register_feature certbot     web on
register_feature add_domain  web off

SITE_TYPES=(static spa proxy laravel php wordpress redirect)
_PUBLIC_IP=""

# ------------------------------------------------------------------ helpers
# Web servers we can act on: the one chosen in this run, else what is installed.
target_servers() {
  if feature_selected webserver && [[ -n ${CFG[webserver]:-} ]]; then
    printf '%s\n' "${CFG[webserver]}"
  else
    installed_webservers
  fi
}

install_certbot_pkgs() {
  local servers pkgs=(certbot)
  servers=$(target_servers)
  if grep -qx nginx <<<"$servers"; then pkgs+=(python3-certbot-nginx); fi
  if grep -qx apache <<<"$servers"; then pkgs+=(python3-certbot-apache); fi
  pkg_install "${pkgs[@]}"
  run systemctl enable --now certbot.timer
}

public_ip() {
  if [[ -z $_PUBLIC_IP ]]; then
    _PUBLIC_IP=$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null) || _PUBLIC_IP=""
    [[ $_PUBLIC_IP =~ ^[0-9.]+$ ]] || _PUBLIC_IP=$(primary_ip)
  fi
  printf '%s' "$_PUBLIC_IP"
}
dns_points_here() { getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u | grep -qx "$(public_ip)"; }

# shellcheck disable=SC2012
php_fpm_sockets() { ls /run/php/php[0-9]*-fpm.sock 2>/dev/null | sort -V || true; }
default_php_socket() {
  local s
  s=$(php_fpm_sockets | tail -n 1)
  if [[ -n $s ]]; then printf '%s' "$s"; return; fi
  case "$OS_VERSION" in
    24.04) printf '/run/php/php8.3-fpm.sock' ;;
    *)     printf '/run/php/php8.1-fpm.sock' ;;
  esac
}

site_exists() {
  case "$1" in
    nginx)  [[ -e /etc/nginx/sites-available/$2.conf ]] ;;
    apache) [[ -e /etc/apache2/sites-available/$2.conf ]] ;;
    caddy)  [[ -e /etc/caddy/sites-enabled/$2.caddy ]] ;;
    *) return 1 ;;
  esac
}

# Document root: WordPress lives in the app folder, everything else in public/.
site_root() {
  case "$1" in
    wordpress) printf '/var/www/%s' "$2" ;;
    *)         printf '/var/www/%s/public' "$2" ;;
  esac
}

site_owner() {
  local u
  u=$(getent group "$ADMIN_GROUP" | cut -d: -f4 | tr ',' '\n' | grep -vx root | head -n 1) || true
  if [[ -n ${CFG[username]:-} ]] && id "${CFG[username]}" >/dev/null 2>&1; then u=${CFG[username]}; fi
  printf '%s' "${u:-root}"
}

# Sensible default for "also serve www."
default_www() {
  local d=$1 labels
  labels=$(awk -F. '{print NF}' <<<"$d")
  if (( labels <= 2 )) || [[ $d =~ \.(co|com|or|ac|web|go|sch|net|org)\.[a-z]{2}$ && $labels -le 3 ]]; then
    printf 'yes'
  else
    printf 'no'
  fi
}

# ------------------------------------------------------------------ certbot
prompt_certbot() {
  local title servers
  title=$(t feat.certbot.title)
  servers=$(target_servers)
  if [[ -z $servers ]]; then ui_msg "$title" "$(t certbot.need_web)"; return 1; fi
  if [[ $servers == caddy ]]; then ui_msg "$title" "$(t certbot.caddy_auto)"; return 1; fi
  ensure_acme_email "$title" || return 1
}

run_certbot() {
  install_certbot_pkgs
  if [[ -n ${CFG[acme_email]:-} ]]; then setting_set acme_email "${CFG[acme_email]}"; fi
  log_ok "$(t certbot.installed)"
}

summary_certbot() { t sum.certbot "${CFG[acme_email]:-$(t word.none)}"; }

# ------------------------------------------------------------------ add_domain: prompt
prompt_add_domain() {
  local title server n=0 d www type port target sock ssl names cancelled
  local -a items socks name_arr
  title=$(t feat.add_domain.title)
  pick_site_server "$title" || return 1
  server=${CFG[site_server]}
  CFG[site_count]=0

  while true; do
    # ---- 1. domain name
    d=""; cancelled=0
    if (( ASSUME_YES )); then
      d=$(normalize_domain "${CFG[arg_domain]:-}")
      if ! valid_domain "$d"; then log_warn "$(t domain.yes_needs)"; d=""; fi
    else
      while true; do
        d=$(ui_input "$title" "$(t domain.ask)" "") || { cancelled=1; d=""; break; }
        d=$(normalize_domain "$d")
        if valid_domain "$d"; then break; fi
        ui_msg "$title" "$(t domain.invalid "$d")"
      done
    fi
    if [[ -z $d ]]; then break; fi

    if site_exists "$server" "$d" || domain_in_session "$d" "$n"; then
      if ! ui_yesno "$title" "$(t domain.exists "$d")" no; then
        (( ASSUME_YES )) && break
        ui_yesno "$title" "$(t domain.ask_more)" no && continue
        break
      fi
    fi

    # ---- 2. www alias
    www=0
    if [[ $d != www.* ]] && ui_yesno "$title" "$(t domain.ask_www "$d")" "$(default_www "$d")"; then www=1; fi

    # ---- 3. site type
    if (( ASSUME_YES )); then
      type=${CFG[arg_type]:-static}
      [[ " ${SITE_TYPES[*]} " == *" $type "* ]] || { log_warn "$(t domain.bad_type "$type")"; break; }
    else
      items=()
      for type in "${SITE_TYPES[@]}"; do items+=("$type" "$(t "site.type.$type")"); done
      type=$(ui_menu "$title" "$(t domain.ask_type "$d")" static "${items[@]}") || { cancelled=1; break; }
    fi

    # ---- 4. type specific answers
    port=""; target=""; sock=""
    case "$type" in
      proxy)
        while true; do
          port=$(ui_input "$title" "$(t domain.ask_port)" "${CFG[arg_port]:-3000}") || { cancelled=1; break; }
          if valid_port "$port"; then break; fi
          (( ASSUME_YES )) && { cancelled=1; break; }
          ui_msg "$title" "$(t domain.bad_port)"
        done
        (( cancelled )) && break ;;
      redirect)
        while true; do
          target=$(ui_input "$title" "$(t domain.ask_target)" "${CFG[arg_target]:-}") || { cancelled=1; break; }
          target=${target%/}
          [[ $target =~ ^https?:// ]] || target="https://$target"
          if valid_domain "$(normalize_domain "$target")"; then break; fi
          (( ASSUME_YES )) && { cancelled=1; break; }
          ui_msg "$title" "$(t domain.bad_target)"
        done
        (( cancelled )) && break ;;
      laravel|php|wordpress)
        mapfile -t socks < <(php_fpm_sockets)
        if (( ${#socks[@]} > 1 )); then
          items=(); for sock in "${socks[@]}"; do items+=("$sock" ""); done
          sock=$(ui_menu "$title" "$(t domain.ask_php)" "${socks[-1]}" "${items[@]}") || { cancelled=1; break; }
        elif (( ${#socks[@]} == 1 )); then
          sock=${socks[0]}
        else
          sock=$(default_php_socket)
          if ! ui_yesno "$title" "$(t domain.no_php "$sock")" yes; then
            ui_yesno "$title" "$(t domain.ask_more)" no && continue
            break
          fi
        fi ;;
    esac

    # ---- 5. HTTPS
    ssl=0
    names=$d; [[ $www == 1 ]] && names="$d www.$d"
    read -ra name_arr <<<"$names"
    if [[ $server == caddy ]]; then
      ssl=auto
      if ! dns_ok_all "${name_arr[@]}"; then ui_msg "$title" "$(t domain.dns_caddy "$names" "$(public_ip)")"; fi
    elif ui_yesno "$title" "$(t domain.ask_ssl "$d")" yes; then
      if dns_ok_all "${name_arr[@]}" || ui_yesno "$title" "$(t domain.dns_mismatch "$names" "$(public_ip)")" no; then
        ssl=1
        ensure_acme_email "$title" || return 1
      fi
    fi

    n=$((n + 1))
    CFG[site_${n}_domain]=$d;   CFG[site_${n}_www]=$www;   CFG[site_${n}_type]=$type
    CFG[site_${n}_port]=$port;  CFG[site_${n}_target]=$target
    CFG[site_${n}_sock]=$sock;  CFG[site_${n}_ssl]=$ssl
    CFG[site_count]=$n

    (( ASSUME_YES )) && break
    ui_yesno "$title" "$(t domain.ask_more)" no || break
  done

  (( n > 0 ))
}

pick_site_server() {
  local title=$1 servers n s
  local -a items=()
  servers=$(target_servers)
  n=$(grep -c . <<<"$servers" || true)
  if (( n == 0 )); then ui_msg "$title" "$(t domain.need_web)"; return 1; fi
  if (( n == 1 )); then CFG[site_server]=$servers; return 0; fi
  for s in $servers; do items+=("$s" "$(t "web.$s")"); done
  CFG[site_server]=$(ui_menu "$title" "$(t domain.pick_server)" "$(head -n 1 <<<"$servers")" "${items[@]}") || return 1
}

domain_in_session() {  # domain_in_session <domain> <count>
  local i
  for ((i = 1; i <= $2; i++)); do [[ ${CFG[site_${i}_domain]:-} == "$1" ]] && return 0; done
  return 1
}

dns_ok_all() { local h; for h in "$@"; do dns_points_here "$h" || return 1; done; }

summary_add_domain() {
  local i n=${CFG[site_count]:-0} extra
  for ((i = 1; i <= n; i++)); do
    (( i > 1 )) && printf '\n     '
    extra=""
    [[ ${CFG[site_${i}_www]} == 1 ]] && extra+=" + www"
    case "${CFG[site_${i}_ssl]}" in 1|auto) extra+=", HTTPS" ;; esac
    [[ -n ${CFG[site_${i}_port]} ]] && extra+=", :${CFG[site_${i}_port]}"
    [[ -n ${CFG[site_${i}_target]} ]] && extra+=" → ${CFG[site_${i}_target]}"
    t sum.site "${CFG[site_${i}_domain]}" "${CFG[site_server]}" "$(t "site.short.${CFG[site_${i}_type]}")" "$extra"
  done
}

# ------------------------------------------------------------------ add_domain: run
site_prepare() {  # site_prepare <domain> <type> <root>
  local d=$1 type=$2 root=$3 app owner
  app=/var/www/$d
  case "$type" in proxy|redirect) return 0 ;; esac
  owner=$(site_owner)
  run install -d -m 755 -o "$owner" -g www-data "$app" || return 1
  case "$type" in
    static|spa|php)
      run install -d -m 755 -o "$owner" -g www-data "$root" || return 1
      if [[ -z $(ls -A "$root" 2>/dev/null) ]]; then
        local page
        page=$(render_tpl "$TPL_DIR/html/index.html.tpl" DOMAIN="$d" ROOT="$root") || return 1
        printf '%s\n' "$page" | write_file "$root/index.html" 644 || return 1
        run chown "$owner:www-data" "$root/index.html" || return 1
      fi ;;
  esac
}

site_write_nginx() {  # <type> <domain> KEY=value...
  local type=$1 d=$2 content avail enabled
  shift 2
  avail=/etc/nginx/sites-available/$d.conf; enabled=/etc/nginx/sites-enabled/$d.conf
  content=$(render_tpl "$TPL_DIR/nginx/sites/$type.conf.tpl" "$@") || return 1
  printf '%s\n' "$content" | nginx_filter | write_file "$avail" 644 || return 1
  run ln -sfn "$avail" "$enabled" || return 1
  nginx_apply "$enabled" "$avail"
}

site_write_apache() {
  local type=$1 d=$2 content avail enabled
  shift 2
  avail=/etc/apache2/sites-available/$d.conf; enabled=/etc/apache2/sites-enabled/$d.conf
  content=$(render_tpl "$TPL_DIR/apache/sites/$type.conf.tpl" "$@") || return 1
  printf '%s\n' "$content" | write_file "$avail" 644 || return 1
  run a2ensite "$d" || return 1
  apache_apply "$enabled" "$avail"
}

site_write_caddy() {
  local type=$1 d=$2 content file=/etc/caddy/sites-enabled/$2.caddy
  shift 2
  content=$(render_tpl "$TPL_DIR/caddy/sites/$type.caddy.tpl" "$@") || return 1
  run install -d -m 755 /etc/caddy/sites-enabled || return 1
  printf '%s\n' "$content" | write_file "$file" 644 || return 1
  caddy_apply "$file"
}

site_ssl() {  # site_ssl <domain> <www> <server>
  local d=$1 www=$2 server=$3 plugin=--nginx
  local -a dom=(-d "$d") mail=(--register-unsafely-without-email) extra=()
  [[ $www == 1 ]] && dom+=(-d "www.$d")
  [[ $server == apache ]] && plugin=--apache
  [[ -n ${CFG[acme_email]:-} ]] && mail=(-m "${CFG[acme_email]}")
  [[ ${VPS_SETUP_LE_STAGING:-0} == 1 ]] && extra=(--test-cert)
  log_info "$(t domain.ssl_running "$d")"
  if run certbot "$plugin" "${dom[@]}" --non-interactive --agree-tos --redirect "${mail[@]}" "${extra[@]}"; then
    log_ok "$(t domain.ssl_ok "$d")"
  else
    log_warn "$(t domain.ssl_failed "$d")"
  fi
  return 0
}

create_site() {
  local i=$1 server=${CFG[site_server]}
  local d=${CFG[site_${i}_domain]} type=${CFG[site_${i}_type]} www=${CFG[site_${i}_www]}
  local port=${CFG[site_${i}_port]} target=${CFG[site_${i}_target]} sock=${CFG[site_${i}_sock]} ssl=${CFG[site_${i}_ssl]}
  local names=$d comma=$d alias="" root
  if [[ $www == 1 ]]; then names="$d www.$d"; comma="$d, www.$d"; alias="    ServerAlias www.$d"; fi
  root=$(site_root "$type" "$d")

  log_info "$(t domain.creating "$d" "$(t "site.short.$type")")"
  site_prepare "$d" "$type" "$root" || return 1

  local -a vars=(DOMAIN="$d" SERVER_NAMES="$names" SERVER_NAMES_COMMA="$comma" SERVER_ALIAS_LINE="$alias"
                 ROOT="$root" UPSTREAM="127.0.0.1:$port" PHP_SOCKET_PATH="$sock" REDIRECT_TARGET="$target")
  case "$server" in
    nginx)  site_write_nginx  "$type" "$d" "${vars[@]}" || return 1 ;;
    apache) site_write_apache "$type" "$d" "${vars[@]}" || return 1 ;;
    caddy)  site_write_caddy  "$type" "$d" "${vars[@]}" || return 1 ;;
  esac
  log_ok "$(t domain.created "$d")"
  if [[ $ssl == 1 ]]; then site_ssl "$d" "$www" "$server"; fi
  return 0
}

run_add_domain() {
  local i n=${CFG[site_count]:-0} failed=0 need_ssl=0
  for ((i = 1; i <= n; i++)); do [[ ${CFG[site_${i}_ssl]} == 1 ]] && need_ssl=1; done
  if (( need_ssl )) && ! command -v certbot >/dev/null 2>&1; then install_certbot_pkgs; fi
  if [[ -n ${CFG[acme_email]:-} ]]; then setting_set acme_email "${CFG[acme_email]}"; fi
  for ((i = 1; i <= n; i++)); do
    create_site "$i" || failed=1
  done
  (( failed == 0 ))
}

notes_add_domain() {
  local i n=${CFG[site_count]:-0} d type root
  for ((i = 1; i <= n; i++)); do
    d=${CFG[site_${i}_domain]}; type=${CFG[site_${i}_type]}; root=$(site_root "$type" "$d")
    if [[ -d /etc/letsencrypt/live/$d || ${CFG[site_server]} == caddy ]]; then
      t note.site_https "$d"; printf '\n'
    else
      t note.site_http "$d"; printf '\n'
    fi
    case "$type" in
      proxy)    t note.site_proxy "${CFG[site_${i}_port]}"; printf '\n' ;;
      redirect) ;;
      *)        t note.site_dir "$root"; printf '\n' ;;
    esac
  done
  t note.site_dns "$(public_ip)"
}
