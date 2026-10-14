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
  # PHP is not installed yet: point at the version the PHP feature would install
  printf '/run/php/php%s-fpm.sock' "$(_system_php_ver)"
}

# Group that owns website folders. Debian/Ubuntu web servers all run as www-data.
web_group() { printf 'www-data'; }

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
  local title server n=0 d www type port target sock ssl hsts workers names cancelled
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
    port=""; target=""; sock=""; workers=0; CFG[_app_cmd]=""; CFG[_app_rt]=""
    case "$type" in
      proxy)
        while true; do
          port=$(ui_input "$title" "$(t domain.ask_port)" "${CFG[arg_port]:-3000}") || { cancelled=1; break; }
          if valid_port "$port"; then break; fi
          (( ASSUME_YES )) && { cancelled=1; break; }
          ui_msg "$title" "$(t domain.bad_port)"
        done
        (( cancelled )) && break
        prompt_app_service "$title" "$d" "$port" || { cancelled=1; break; } ;;
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
        fi
        workers=0
        if [[ $type == laravel ]] && ui_yesno "$title" "$(t domain.ask_workers "$d")" "$( (( ${CFG[arg_no_workers]:-0} )) && echo no || echo yes)"; then
          workers=1
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

    # ---- 6. HSTS (off unless asked: a mistake keeps visitors out for a year)
    hsts=0
    if [[ $ssl != 0 ]] && ui_yesno "$title" "$(t domain.ask_hsts "$d")" "$( (( ${CFG[arg_hsts]:-0} )) && echo yes || echo no)"; then
      hsts=1
    fi

    n=$((n + 1))
    CFG[site_${n}_domain]=$d;   CFG[site_${n}_www]=$www;   CFG[site_${n}_type]=$type
    CFG[site_${n}_port]=$port;  CFG[site_${n}_target]=$target
    CFG[site_${n}_sock]=$sock;  CFG[site_${n}_ssl]=$ssl;   CFG[site_${n}_hsts]=$hsts
    CFG[site_${n}_app_cmd]=${CFG[_app_cmd]:-}; CFG[site_${n}_app_rt]=${CFG[_app_rt]:-}
    CFG[site_${n}_workers]=$workers
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
    [[ ${CFG[site_${i}_hsts]:-0} == 1 ]] && extra+=", HSTS"
    [[ -n ${CFG[site_${i}_app_cmd]:-} ]] && extra+=", $(t sum.app_svc "$(app_unit "${CFG[site_${i}_domain]}")")"
    [[ ${CFG[site_${i}_workers]:-0} == 1 ]] && extra+=", $(t sum.workers)"
    [[ -n ${CFG[site_${i}_port]} ]] && extra+=", :${CFG[site_${i}_port]}"
    [[ -n ${CFG[site_${i}_target]} ]] && extra+=" → ${CFG[site_${i}_target]}"
    t sum.site "${CFG[site_${i}_domain]}" "${CFG[site_server]}" "$(t "site.short.${CFG[site_${i}_type]}")" "$extra"
  done
}

# ------------------------------------------------------------------ app services (systemd)
# A "proxy" site can get a systemd service that keeps the app running; a Laravel site can get the
# scheduler (timer, every minute) and a queue worker. Units carry the "Managed by vps-setup"
# marker, so --remove-domain removes them with the site.
APP_RUNTIMES=(node python go other)
APP_ENV_DIR=/etc/vps-setup/apps

# shellcheck disable=SC2016  # $PORT is expanded by the app's shell, not here
app_default_cmd() {
  case $1 in
    node)   printf 'npm start' ;;
    python) printf '.venv/bin/gunicorn --bind 127.0.0.1:$PORT app:app' ;;
    go)     printf './app' ;;
  esac
}
# The command goes inside bash -lc '...': no single quotes, no line breaks.
valid_app_cmd() { [[ -n ${1//[[:space:]]/} && $1 != *"'"* && $1 != *$'\n'* ]]; }
app_unit()      { printf 'app-%s' "$1"; }
laravel_units() { printf 'laravel-%s-queue laravel-%s-schedule' "$1" "$1"; }

# Asks whether vps-setup should run the app; sets CFG[_app_cmd] / CFG[_app_rt] (empty = no).
prompt_app_service() {  # <title> <domain> <port>
  local title=$1 d=$2 port=$3 rt cmd def=no
  local -a items=()
  CFG[_app_cmd]=""; CFG[_app_rt]=""
  [[ -n ${CFG[arg_app_cmd]:-} ]] && def=yes
  ui_yesno "$title" "$(t domain.ask_app "/var/www/$d")" "$def" || return 0
  if [[ -n ${CFG[arg_app_cmd]:-} ]]; then
    rt=other; cmd=${CFG[arg_app_cmd]}
  else
    for rt in "${APP_RUNTIMES[@]}"; do items+=("$rt" "$(t "app.rt.$rt")"); done
    rt=$(ui_menu "$title" "$(t domain.ask_runtime)" node "${items[@]}") || return 1
    cmd=$(app_default_cmd "$rt")
  fi
  while true; do
    cmd=$(ui_input "$title" "$(t domain.ask_app_cmd "/var/www/$d" "$port")" "$cmd") || return 1
    if valid_app_cmd "$cmd"; then break; fi
    (( ASSUME_YES )) && { log_warn "$(t domain.bad_app_cmd)"; return 1; }
    ui_msg "$title" "$(t domain.bad_app_cmd)"
  done
  CFG[_app_cmd]=$cmd; CFG[_app_rt]=$rt
}

# User that PHP-FPM runs as: the Laravel worker must write the same files (storage/, logs).
_php_default_user() { printf 'www-data'; }
php_fpm_user() {
  local f u=""
  for f in /etc/php/*/fpm/pool.d/www.conf /etc/php-fpm.d/www.conf; do
    [[ -r $f ]] || continue
    u=$(awk -F= '/^[[:space:]]*user[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$f")
    [[ -n $u ]] && break
  done
  printf '%s' "${u:-$(_php_default_user)}"
}
# PHP CLI that matches the site's FPM socket (/run/php/php8.3-fpm.sock -> /usr/bin/php8.3).
php_cli_for() {
  local v
  v=$(sed -n 's#.*/php\([0-9][0-9.]*\)-fpm\.sock$#\1#p' <<<"$1")
  if [[ -n $v && ( -x /usr/bin/php$v || $DRY_RUN == 1 ) ]]; then printf '/usr/bin/php%s' "$v"; else printf '/usr/bin/php'; fi
}

write_app_service() {  # <domain> <port> <runtime> <command>
  local d=$1 port=$2 rt=$3 cmd=$4 name dir owner env
  env="PORT=$port HOST=127.0.0.1"
  name=$(app_unit "$d"); dir=/var/www/$d; owner=$(site_owner)
  case $rt in
    node)   env+=" NODE_ENV=production" ;;
    python) env+=" PYTHONUNBUFFERED=1" ;;
  esac
  # systemd expands % and $ itself: double them so the shell sees the command as typed
  cmd=${cmd//%/%%}; cmd=${cmd//\$/\$\$}
  run install -d -m 755 -o "$owner" -g "$(web_group)" "$dir" || return 1
  run install -d -m 700 "$APP_ENV_DIR" || return 1
  write_file "/etc/systemd/system/$name.service" 644 <<EOF || return 1
# Managed by vps-setup — app for $d (listens on 127.0.0.1:$port)
# Deploy your code to $dir, then: sudo systemctl restart $name
# Secrets: KEY=value lines in $APP_ENV_DIR/$d.env (only root can read that folder)
[Unit]
Description=App for $d (vps-setup)
Wants=network-online.target
After=network-online.target
# Waits for the first deploy instead of failing in a loop on an empty folder
ConditionDirectoryNotEmpty=$dir

[Service]
Type=simple
User=$owner
WorkingDirectory=$dir
Environment=$env
EnvironmentFile=-$APP_ENV_DIR/$d.env
# A login shell reads ~/.profile, so tools put on PATH there are found (with nvm: use the full path to node)
ExecStart=/bin/bash -lc 'exec $cmd'
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
  run systemctl daemon-reload || return 1
  run systemctl enable "$name.service" || return 1
  # Restart (not start) so a changed command takes effect; skipped until the folder has files
  if [[ -n $(ls -A "$dir" 2>/dev/null) ]]; then run systemctl restart "$name.service" || log_warn "$(t app.start_failed "$name" "$name")"; fi
  log_ok "$(t app.created "$name")"
}

write_laravel_workers() {  # <domain> <php socket>
  local d=$1 dir=/var/www/$1 user php queue schedule
  user=$(php_fpm_user); php=$(php_cli_for "$2")
  read -r queue schedule <<<"$(laravel_units "$d")"
  write_file "/etc/systemd/system/$queue.service" 644 <<EOF || return 1
# Managed by vps-setup — Laravel queue worker for $d
# After each deploy: sudo systemctl restart $queue
[Unit]
Description=Laravel queue worker for $d (vps-setup)
After=network-online.target
ConditionPathExists=$dir/artisan

[Service]
Type=simple
User=$user
WorkingDirectory=$dir
ExecStart=$php artisan queue:work --sleep=3 --tries=3 --max-time=3600
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  write_file "/etc/systemd/system/$schedule.service" 644 <<EOF || return 1
# Managed by vps-setup — Laravel scheduler for $d (started every minute by $schedule.timer)
[Unit]
Description=Laravel scheduler for $d (vps-setup)
ConditionPathExists=$dir/artisan

[Service]
Type=oneshot
User=$user
WorkingDirectory=$dir
ExecStart=$php artisan schedule:run
NoNewPrivileges=true
PrivateTmp=true
EOF
  write_file "/etc/systemd/system/$schedule.timer" 644 <<EOF || return 1
# Managed by vps-setup — runs the Laravel scheduler for $d every minute
[Unit]
Description=Laravel scheduler for $d (every minute)

[Timer]
OnCalendar=*-*-* *:*:00
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
  run systemctl daemon-reload || return 1
  # Both wait for artisan (ConditionPathExists): nothing runs, nothing fails before the first deploy
  run systemctl enable --now "$queue.service" "$schedule.timer" || return 1
  log_ok "$(t app.workers_created "$d")"
}

# ------------------------------------------------------------------ add_domain: run
site_prepare() {  # site_prepare <domain> <type> <root>
  local d=$1 type=$2 root=$3 app owner group
  app=/var/www/$d
  case "$type" in proxy|redirect) return 0 ;; esac
  owner=$(site_owner)
  group=$(web_group)
  run install -d -m 755 -o "$owner" -g "$group" "$app" || return 1
  case "$type" in
    static|spa|php)
      run install -d -m 755 -o "$owner" -g "$group" "$root" || return 1
      if [[ -z $(ls -A "$root" 2>/dev/null) ]]; then
        local page
        page=$(render_tpl "$TPL_DIR/html/index.html.tpl" DOMAIN="$d" ROOT="$root") || return 1
        printf '%s\n' "$page" | write_file "$root/index.html" 644 || return 1
        run chown "$owner:$group" "$root/index.html" || return 1
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

site_ssl() {  # site_ssl <domain> <www> <server> [hsts]
  local d=$1 www=$2 server=$3 hsts=${4:-0} plugin=--nginx
  local -a dom=(-d "$d") mail=(--register-unsafely-without-email) extra=()
  [[ $www == 1 ]] && dom+=(-d "www.$d")
  [[ $server == apache ]] && plugin=--apache
  [[ -n ${CFG[acme_email]:-} ]] && mail=(-m "${CFG[acme_email]}")
  [[ ${VPS_SETUP_LE_STAGING:-0} == 1 ]] && extra=(--test-cert)
  # Certbot adds "Strict-Transport-Security: max-age=31536000" (no includeSubDomains, no preload)
  [[ $hsts == 1 ]] && extra+=(--hsts)
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
  local hsts=${CFG[site_${i}_hsts]:-0} app_cmd=${CFG[site_${i}_app_cmd]:-} names=$d comma=$d alias="" root hsts_line=""
  if [[ $www == 1 ]]; then names="$d www.$d"; comma="$d, www.$d"; alias="    ServerAlias www.$d"; fi
  root=$(site_root "$type" "$d")
  # Caddy sets headers in the site file; for Nginx/Apache certbot adds HSTS with the certificate
  [[ $hsts == 1 ]] && hsts_line='    header Strict-Transport-Security "max-age=31536000"'

  log_info "$(t domain.creating "$d" "$(t "site.short.$type")")"
  site_prepare "$d" "$type" "$root" || return 1

  local -a vars=(DOMAIN="$d" SERVER_NAMES="$names" SERVER_NAMES_COMMA="$comma" SERVER_ALIAS_LINE="$alias"
                 ROOT="$root" UPSTREAM="127.0.0.1:$port" PHP_SOCKET_PATH="$sock" REDIRECT_TARGET="$target"
                 HSTS_LINE="$hsts_line")
  case "$server" in
    nginx)  site_write_nginx  "$type" "$d" "${vars[@]}" || return 1 ;;
    apache) site_write_apache "$type" "$d" "${vars[@]}" || return 1 ;;
    caddy)  site_write_caddy  "$type" "$d" "${vars[@]}" || return 1 ;;
  esac
  log_ok "$(t domain.created "$d")"
  if [[ -n $app_cmd ]]; then write_app_service "$d" "$port" "${CFG[site_${i}_app_rt]:-other}" "$app_cmd" || return 1; fi
  if [[ $type == laravel && ${CFG[site_${i}_workers]:-0} == 1 ]]; then write_laravel_workers "$d" "$sock" || return 1; fi
  if [[ $ssl == 1 ]]; then site_ssl "$d" "$www" "$server" "$hsts"; fi
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
      proxy)
        if [[ -n ${CFG[site_${i}_app_cmd]:-} ]]; then
          t note.app_svc "/var/www/$d" "$(app_unit "$d")" "$(app_unit "$d")" "$APP_ENV_DIR/$d.env"; printf '\n'
        else
          t note.site_proxy "${CFG[site_${i}_port]}"; printf '\n'
        fi ;;
      redirect) ;;
      *)        t note.site_dir "$root"; printf '\n' ;;
    esac
    if [[ $type == laravel && ${CFG[site_${i}_workers]:-0} == 1 ]]; then
      t note.laravel_workers "$(laravel_units "$d" | cut -d' ' -f1)"; printf '\n'
    fi
  done
  t note.site_dns "$(public_ip)"
}
