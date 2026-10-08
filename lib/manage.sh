#!/usr/bin/env bash
# shellcheck shell=bash
# Management commands for what vps-setup created: list / remove websites, list / drop databases.
# Sourced by setup.sh after the OS module set is loaded: it reuses nginx_apply, apache_apply and
# caddy_apply, which test the configuration before they reload the web server.
#
# Safety rules:
#   * only config files that carry the "Managed by vps-setup" marker are ever removed;
#   * a copy of every removed config is kept in BACKUP_DIR, and it is put back when the web
#     server refuses the configuration without it;
#   * site files (/var/www/<domain>) are never deleted: --purge-files MOVES them to
#     BACKUP_DIR/removed-sites;
#   * a database is dumped to BACKUP_DIR/dropped-databases before it is dropped.
#
# VPS_SETUP_ROOT is a test hook: it is prefixed to every /etc and /var/www path below.

MANAGED_MARK="Managed by vps-setup"
_R=${VPS_SETUP_ROOT:-}

_is_rhel() {
  case "$OS_ID" in almalinux|rocky|rhel|centos) return 0 ;; esac
  return 1
}

# ------------------------------------------------------------------ site layout
# Directory that holds the main config file of a site, per server and distro family.
_site_main_dir() {
  case "$1" in
    nginx)  if _is_rhel; then printf '%s' "$_R/etc/nginx/conf.d"; else printf '%s' "$_R/etc/nginx/sites-available"; fi ;;
    apache) if _is_rhel; then printf '%s' "$_R/etc/httpd/conf.d"; else printf '%s' "$_R/etc/apache2/sites-available"; fi ;;
    caddy)  printf '%s' "$_R/etc/caddy/sites-enabled" ;;
  esac
}

_site_ext() { if [[ $1 == caddy ]]; then printf 'caddy'; else printf 'conf'; fi; }

site_main_file() { printf '%s/%s.%s' "$(_site_main_dir "$1")" "$2" "$(_site_ext "$1")"; }

# Every config file that belongs to one site (one path per line, they may not all exist).
# Certbot's Apache plugin adds a second "<domain>-le-ssl.conf" next to the site.
site_conf_paths() {
  local server=$1 d=$2
  case "$server" in
    nginx)
      if _is_rhel; then
        printf '%s\n' "$_R/etc/nginx/conf.d/$d.conf"
      else
        printf '%s\n' "$_R/etc/nginx/sites-enabled/$d.conf" "$_R/etc/nginx/sites-available/$d.conf"
      fi ;;
    apache)
      if _is_rhel; then
        printf '%s\n' "$_R/etc/httpd/conf.d/$d.conf" "$_R/etc/httpd/conf.d/$d-le-ssl.conf"
      else
        printf '%s\n' "$_R/etc/apache2/sites-enabled/$d.conf" "$_R/etc/apache2/sites-enabled/$d-le-ssl.conf" \
          "$_R/etc/apache2/sites-available/$d.conf" "$_R/etc/apache2/sites-available/$d-le-ssl.conf"
      fi ;;
    caddy)
      printf '%s\n' "$_R/etc/caddy/sites-enabled/$d.caddy" ;;
  esac
}

# True when the web server really serves the site (Debian-style symlink exists).
_site_enabled() {
  if _is_rhel || [[ $1 == caddy ]]; then return 0; fi
  case "$1" in
    nginx)  [[ -e $_R/etc/nginx/sites-enabled/$2.conf ]] ;;
    apache) [[ -e $_R/etc/apache2/sites-enabled/$2.conf ]] ;;
  esac
}

# ------------------------------------------------------------------ list sites
list_sites() {
  local server dir ext f b d line type https status found=0
  for server in nginx apache caddy; do
    dir=$(_site_main_dir "$server"); ext=$(_site_ext "$server")
    [[ -d $dir ]] || continue
    for f in "$dir"/*."$ext"; do
      [[ -f $f ]] || continue
      b=${f##*/}; d=${b%."$ext"}
      valid_domain "$d" || continue
      grep -qF "$MANAGED_MARK" "$f" || continue
      if (( found == 0 )); then printf '%s\n' "$(t manage.sites_header)"; fi
      found=$((found + 1))
      line=$(head -n 1 "$f")
      type=-
      if [[ $line == *"$MANAGED_MARK"* ]]; then
        type=${line##*vps-setup}              # text after the last "vps-setup"
        type=${type#"${type%%[[:alnum:]]*}"}  # drop the leading punctuation/spaces (": ", " - ")
      fi
      if [[ $server == caddy ]]; then
        https=auto
      elif [[ -d $_R/etc/letsencrypt/live/$d ]]; then
        https=yes
      else
        https=no
      fi
      if _site_enabled "$server" "$d"; then status=enabled; else status=disabled; fi
      printf '%-32s %-8s %-24s %-8s %s\n' "$d" "$server" "$type" "$https" "$status"
    done
  done
  if (( found == 0 )); then log_info "$(t manage.sites_none)"; fi
  return 0
}

# ------------------------------------------------------------------ remove a site
# remove_domain <domain>   (CFG[arg_purge]=1 moves /var/www/<domain> away, CFG[arg_keep_cert]=1 keeps the certificate)
remove_domain() {
  local d=$1 purge=${CFG[arg_purge]:-0} keep_cert=${CFG[arg_keep_cert]:-0}
  local s main p tmp applyfn root dest ts title certact=none filesact=none certtxt filestxt
  local has_cert=0 uses_le=0 dir n
  local -a servers=() dirs=() saved_src=() saved_cpy=()

  d=$(normalize_domain "$d")
  if ! valid_domain "$d"; then log_err "$(t manage.bad_domain "$d")"; return 1; fi

  for s in nginx apache caddy; do
    main=$(site_main_file "$s" "$d")
    [[ -f $main ]] || continue
    if grep -qF "$MANAGED_MARK" "$main"; then
      servers+=("$s")
    else
      log_warn "$(t manage.not_managed "$d")"
    fi
  done
  if (( ${#servers[@]} == 0 )); then log_err "$(t manage.site_not_found "$d")"; return 1; fi

  for s in "${servers[@]}"; do
    if [[ $s != caddy ]]; then uses_le=1; fi
  done
  if [[ -d $_R/etc/letsencrypt/live/$d ]]; then has_cert=1; fi
  if (( has_cert && uses_le && ! keep_cert )); then
    if command -v certbot >/dev/null 2>&1; then
      certact=delete
    else
      certact=keep
      log_warn "$(t manage.cert_no_certbot "$d")"
    fi
  elif (( has_cert )); then
    certact=keep
  fi

  root=$_R/var/www/$d
  ts=$(date +%Y%m%d%H%M%S)
  dest=$BACKUP_DIR/removed-sites/$d.$ts
  if [[ -d $root && ! -L $root ]]; then
    if (( purge )); then filesact=move; else filesact=keep; fi
  fi

  case "$certact" in
    delete) certtxt=$(t manage.cert.delete) ;;
    keep)   certtxt=$(t manage.cert.keep) ;;
    *)      certtxt=$(t manage.cert.none) ;;
  esac
  case "$filesact" in
    move) filestxt=$(t manage.files.move "$dest") ;;
    keep) filestxt=$(t manage.files.keep "$root") ;;
    *)    filestxt=$(t manage.files.none) ;;
  esac

  title=$(t manage.confirm_site_title)
  if (( ! ASSUME_YES )); then
    if ! ui_yesno "$title" "$(t manage.confirm_site "$d" "${servers[*]}" "$certtxt" "$filestxt")" no; then
      log_info "$(t msg.cancelled)"
      return 0
    fi
  fi

  # ---- 1. web server config (tested before reload; restored when the server refuses it)
  # Each file is restored one by one on purpose: "cp -a dir/. /" would also copy dir's own
  # attributes (mode, owner) onto the target directory.
  for s in "${servers[@]}"; do
    log_info "$(t manage.removing "$d" "$s")"
    backup_file "$(site_main_file "$s" "$d")"
    tmp=$(mktemp -d)
    saved_src=(); saved_cpy=(); n=0
    while IFS= read -r p; do
      [[ -e $p || -L $p ]] || continue
      n=$((n + 1))
      if (( ! DRY_RUN )); then cp -a "$p" "$tmp/$n" || true; fi
      saved_src+=("$p"); saved_cpy+=("$tmp/$n")
      run rm -f "$p"
    done < <(site_conf_paths "$s" "$d")
    case "$s" in
      nginx)  applyfn=nginx_apply ;;
      apache) applyfn=apache_apply ;;
      *)      applyfn=caddy_apply ;;
    esac
    if ! "$applyfn"; then
      if (( ! DRY_RUN )); then
        for ((n = 0; n < ${#saved_src[@]}; n++)); do cp -a "${saved_cpy[$n]}" "${saved_src[$n]}"; done
      fi
      rm -rf "$tmp"
      log_err "$(t manage.config_restored)"
      return 1
    fi
    rm -rf "$tmp"
  done

  # ---- 2. certificate (not while another site still points at it)
  if [[ $certact == delete ]]; then
    for dir in nginx apache2 httpd caddy; do
      if [[ -d $_R/etc/$dir ]]; then dirs+=("$_R/etc/$dir"); fi
    done
    if (( ${#dirs[@]} > 0 )) && grep -rlsqF -- "/etc/letsencrypt/live/$d/" "${dirs[@]}"; then
      log_warn "$(t manage.cert_in_use "$d")"
    elif run certbot delete --cert-name "$d" --non-interactive; then
      log_ok "$(t manage.cert_deleted "$d")"
    else
      log_warn "$(t manage.cert_failed "$d")"
    fi
  fi

  # ---- 3. site files: moved, never deleted
  case "$filesact" in
    move)
      if run install -d -m 700 "$BACKUP_DIR/removed-sites" && run mv -- "$root" "$dest"; then
        log_ok "$(t manage.files_moved "$dest")"
      else
        log_warn "$(t manage.files_move_failed "$root")"
      fi ;;
    keep)
      log_info "$(t manage.files_kept "$root")" ;;
  esac

  log_ok "$(t manage.removed "$d")"
  return 0
}

# ------------------------------------------------------------------ databases
# Letters, digits and underscore only: safe to put inside the SQL below without escaping.
_db_name_ok() { [[ $1 =~ ^[A-Za-z0-9_]{1,63}$ ]]; }
_db_is_system() {
  case "${1,,}" in
    postgres|template0|template1|mysql|information_schema|performance_schema|sys|root|mariadb|debian_sys_maint) return 0 ;;
  esac
  return 1
}

_psql() { ( cd / && sudo -u postgres psql -X -q "$@" ); }

_dump_db() {  # _dump_db <engine> <database>  → SQL on stdout
  case "$1" in
    postgresql) ( cd / && sudo -u postgres pg_dump "$2" ) ;;
    mysql)      mysqldump --single-transaction --routines --events "$2" ;;
  esac
}

list_databases() {
  local rows name owner shown=0
  if command -v psql >/dev/null 2>&1; then
    shown=1
    printf '%s\n' "$(t manage.db_header PostgreSQL)"
    if rows=$(_psql -At -F ' ' -c "SELECT d.datname, r.rolname FROM pg_database d JOIN pg_roles r ON r.oid = d.datdba WHERE NOT d.datistemplate AND d.datname <> 'postgres' ORDER BY 1;" 2>>"$LOG_FILE"); then
      if [[ -z $rows ]]; then
        printf '%s\n' "$(t manage.db_empty)"
      else
        while read -r name owner; do
          printf '%s\n' "$(t manage.db_row "$name" "$owner")"
        done <<<"$rows"
      fi
    else
      log_warn "$(t manage.db_unreachable PostgreSQL)"
    fi
  fi
  if command -v mysql >/dev/null 2>&1; then
    shown=1
    printf '%s\n' "$(t manage.db_header MySQL/MariaDB)"
    if rows=$(mysql -N -B -e 'SHOW DATABASES;' 2>>"$LOG_FILE"); then
      rows=$(grep -Evx 'information_schema|performance_schema|mysql|sys' <<<"$rows" || true)
      if [[ -z $rows ]]; then
        printf '%s\n' "$(t manage.db_empty)"
      else
        while read -r name; do
          printf '  %s\n' "$name"
        done <<<"$rows"
      fi
    else
      log_warn "$(t manage.db_unreachable MySQL/MariaDB)"
    fi
  fi
  if (( shown == 0 )); then log_info "$(t manage.db_none)"; fi
  return 0
}

# drop_database <name>   (CFG[arg_engine], CFG[arg_db_user] optional)
drop_database() {
  local d=$1 eng=${CFG[arg_engine]:-} u=${CFG[arg_db_user]:-}
  local has_pg=0 has_my=0 exists="" typed title ts bdir out ask extra=""

  if ! _db_name_ok "$d"; then log_err "$(t manage.db_bad_name "$d")"; return 1; fi
  if _db_is_system "$d"; then log_err "$(t manage.db_system "$d")"; return 1; fi
  if [[ -n $u ]]; then
    if ! _db_name_ok "$u"; then log_err "$(t manage.db_bad_name "$u")"; return 1; fi
    if _db_is_system "$u"; then log_err "$(t manage.db_system "$u")"; return 1; fi
  fi

  if command -v psql >/dev/null 2>&1; then has_pg=1; fi
  if command -v mysql >/dev/null 2>&1; then has_my=1; fi
  if [[ -z $eng ]]; then
    if (( has_pg && has_my )); then
      if (( ASSUME_YES )); then log_err "$(t manage.db_need_engine)"; return 1; fi
      eng=$(ui_menu "$(t manage.db_confirm_title)" "$(t db.wizard.pick_engine)" postgresql \
        postgresql "$(t db.wizard.engine.postgresql)" mysql "$(t db.wizard.engine.mysql)") || return 0
    elif (( has_pg )); then eng=postgresql
    elif (( has_my )); then eng=mysql
    else log_err "$(t manage.db_none)"; return 1
    fi
  fi
  case "$eng" in
    postgresql) (( has_pg )) || { log_err "$(t manage.db_no_engine PostgreSQL)"; return 1; } ;;
    mysql)      (( has_my )) || { log_err "$(t manage.db_no_engine MySQL/MariaDB)"; return 1; } ;;
    *) log_err "$(t manage.db_no_engine "$eng")"; return 1 ;;
  esac

  case "$eng" in
    postgresql) exists=$(_psql -At -c "SELECT 1 FROM pg_database WHERE datname = '$d';" 2>>"$LOG_FILE") || exists="" ;;
    mysql)      exists=$(mysql -N -B -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$d';" 2>>"$LOG_FILE") || exists="" ;;
  esac
  if [[ -z $exists ]]; then log_err "$(t manage.db_not_found "$d" "$eng")"; return 1; fi

  ts=$(date +%Y%m%d%H%M%S)
  bdir=$BACKUP_DIR/dropped-databases
  out=$bdir/$d.$eng.$ts.sql.gz
  title=$(t manage.db_confirm_title)
  if [[ -n $u ]]; then extra=$(t manage.db_user_part "$u"); fi

  # Typing the name back is the confirmation: a stray Enter cannot drop a database.
  if (( ! ASSUME_YES )); then
    ask=$(t manage.db_confirm "$eng" "$d" "$extra" "$bdir")
    typed=$(ui_input "$title" "$ask" "") || { log_info "$(t msg.cancelled)"; return 0; }
    if [[ $typed != "$d" ]]; then log_info "$(t manage.db_mismatch)"; return 0; fi
  fi

  # Dump first. If the dump fails, nothing is dropped.
  if (( DRY_RUN )); then
    log_dry "dump $d -> $out"
  else
    install -d -m 700 "$bdir" || return 1
    log_info "$(t manage.db_backup "$d" "$out")"
    if ! ( umask 077; set -o pipefail; _dump_db "$eng" "$d" | gzip >"$out" ) 2>>"$LOG_FILE"; then
      rm -f "$out"
      log_err "$(t manage.db_backup_failed)"
      return 1
    fi
  fi

  case "$eng" in
    postgresql)
      if ! run _psql -c "DROP DATABASE \"$d\";"; then log_err "$(t manage.db_drop_failed "$d")"; return 1; fi
      if [[ -n $u ]]; then
        if run _psql -c "DROP ROLE IF EXISTS \"$u\";"; then log_ok "$(t manage.db_user_dropped "$u")"; else log_warn "$(t manage.db_user_failed "$u")"; fi
      fi ;;
    mysql)
      if ! run mysql -e "DROP DATABASE \`$d\`;"; then log_err "$(t manage.db_drop_failed "$d")"; return 1; fi
      if [[ -n $u ]]; then
        if run mysql -e "DROP USER IF EXISTS '$u'@'localhost';"; then log_ok "$(t manage.db_user_dropped "$u")"; else log_warn "$(t manage.db_user_failed "$u")"; fi
      fi ;;
  esac
  log_ok "$(t manage.db_dropped "$d" "$out")"
  return 0
}
