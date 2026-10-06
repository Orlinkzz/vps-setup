#!/usr/bin/env bash
# shellcheck shell=bash
# Ubuntu — databases: PostgreSQL, MySQL/MariaDB, Redis with RAM tuning, create DB wizard.

register_feature postgresql      database off
register_feature mysql           database off
register_feature redis           database off
register_feature create_database database off

PG_CONF_D="/etc/postgresql-common"
MYSQL_CONF_D="/etc/mysql/mysql.conf.d"
REDIS_CONF="/etc/redis/redis.conf"
# ---- helpers ----
db_installed() {
  case "$1" in
    postgresql) command -v psql >/dev/null 2>&1 ;;
    mysql)      command -v mysql >/dev/null 2>&1 ;;
    redis)      command -v redis-server >/dev/null 2>&1 ;;
    *)          return 1 ;;
  esac
}

_db_share() {
  local count=0
  feature_selected postgresql && count=$((count+1))
  feature_selected mysql && count=$((count+1))
  feature_selected redis && count=$((count+1))
  (( count == 0 )) && count=1
  printf '%s' "$count"
}

installed_dbs() {
  command -v psql >/dev/null 2>&1 && echo postgresql
  command -v mysql >/dev/null 2>&1 && echo mysql
  command -v redis-server >/dev/null 2>&1 && echo redis
  return 0
}

_rand_pass() {
  printf '%s' "$(openssl rand -base64 24 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c20 || echo 'changeme_123')"
}

# ---- PostgreSQL ----
prompt_postgresql() { return 0; }

run_postgresql() {
  local share=$(_db_share) pg_ver pg_conf
  pkg_install postgresql postgresql-contrib libpq-dev

  pg_ver=$(find /etc/postgresql -maxdepth 1 -name '[0-9]*' -type d 2>/dev/null | head -n 1 || true)
  pg_ver=$(basename "$pg_ver" 2>/dev/null || dpkg -l | sed -n 's/^ii.*postgresql-\([0-9]*\).*/\1/p' | head -n 1)
  [[ -z $pg_ver ]] && pg_ver=16

  pg_conf="/etc/postgresql/$pg_ver/main/conf.d"
  pg_hba="/etc/postgresql/$pg_ver/main/pg_hba.conf"

  # RAM tuning
  local sb_128=$(( MEM_MB * 25 / 100 / share ))  # shared_buffers  ~25%
  local ec_256=$(( MEM_MB * 50 / 100 / share ))   # effective_cache ~50%
  local wm=$(( MEM_MB * 2 / 100 / share ))        # work_mem         ~2%
  local mwm=$(( MEM_MB * 5 / 100 / share ))       # maintenance     ~5%
  (( sb_128 < 128 )) && sb_128=128; (( sb_128 > 4096 )) && sb_128=4096
  (( ec_256 < 256 )) && ec_256=256; (( ec_256 > 8192 )) && ec_256=8192
  (( wm < 4 ))  && wm=4;  (( wm > 64 ))  && wm=64
  (( mwm < 64 )) && mwm=64; (( mwm > 512 )) && mwm=512

  install -d -m 755 "$pg_conf"
  write_file "$pg_conf/vps-setup-tuning.conf" 644 <<EOF
# Managed by vps-setup — RAM-based tuning
shared_buffers = ${sb_128}MB
effective_cache_size = ${ec_256}MB
work_mem = ${wm}MB
maintenance_work_mem = ${mwm}MB
EOF

  # Listen on local socket only (default, but ensure)
  run sed -i "s/^#*listen_addresses = .*/listen_addresses = 'localhost'/" "/etc/postgresql/$pg_ver/main/postgresql.conf"

  run systemctl restart "postgresql@$pg_ver-main" || svc_restart postgresql

  log_ok "$(t db.postgresql.done)"
}

summary_postgresql() {
  local share=$(_db_share)
  local sb=$(( MEM_MB * 25 / 100 / share ))
  (( sb < 128 )) && sb=128; (( sb > 4096 )) && sb=4096
  t sum.postgresql "$sb"
}

notes_postgresql() {
  t note.postgresql; echo
}

# ---- MySQL / MariaDB ----
prompt_mysql() { return 0; }

run_mysql() {
  local share=$(_db_share) root_pass
  pkg_install mysql-server

  root_pass=$(_rand_pass)

  # Create a deploy-friendly root password + mysql_native_password fallback
  if (( ! DRY_RUN )); then
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$root_pass';" 2>/dev/null || true
  fi

  CFG[mysql_root_pass]=$root_pass

  # RAM tuning
  local bp=$(( MEM_MB * 25 / 100 / share ))  # innodb_buffer_pool
  (( bp < 64 )) && bp=64; (( bp > 4096 )) && bp=4096

  install -d -m 755 "$MYSQL_CONF_D"
  write_file "$MYSQL_CONF_D/vps-setup-tuning.cnf" 644 <<EOF
# Managed by vps-setup — RAM-based tuning
[mysqld]
innodb_buffer_pool_size = ${bp}M
key_buffer_size = 32M
max_allowed_packet = 64M
query_cache_type = 0
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
EOF

  svc_enable_now mysql || svc_restart mysql

  log_ok "$(t db.mysql.done)"
}

summary_mysql() {
  local share=$(_db_share)
  local bp=$(( MEM_MB * 25 / 100 / share ))
  (( bp < 64 )) && bp=64; (( bp > 4096 )) && bp=4096
  t sum.mysql "$bp"
}

notes_mysql() {
  t note.mysql; echo
  t note.mysql_root; echo
}

# ---- Redis ----
prompt_redis() { return 0; }

run_redis() {
  local share=$(_db_share)

  (( IS_CONTAINER )) || pkg_install redis-server
  (( IS_CONTAINER )) && pkg_install redis

  local maxmem=$(( MEM_MB * 30 / 100 / share ))  # 30% per share
  (( maxmem < 16 )) && maxmem=16
  (( maxmem > 2048 )) && maxmem=2048

  backup_file "$REDIS_CONF"
  write_file "$REDIS_CONF" 644 <<EOF
# Managed by vps-setup
port 6379
bind 127.0.0.1 -::1
daemonize no
supervised systemd
loglevel notice
maxmemory ${maxmem}mb
maxmemory-policy allkeys-lru
save 900 1
save 300 10
save 60 10000
databases 16
tcp-backlog 511
timeout 0
tcp-keepalive 300
EOF

  svc_enable_now redis-server || svc_restart redis-server

  log_ok "$(t db.redis.done)"
}

summary_redis() {
  local share=$(_db_share)
  local maxmem=$(( MEM_MB * 30 / 100 / share ))
  (( maxmem < 16 )) && maxmem=16; (( maxmem > 2048 )) && maxmem=2048
  t sum.redis "$maxmem"
}

notes_redis() { t note.redis; echo; }

# ---- Create DB/user wizard (standalone or part of full setup) ----
prompt_create_database() {
  local title engines=() e
  title=$(t feat.create_database.title)

  # --yes --preset database: use CLI args
  if (( ASSUME_YES )); then
    local db="${CFG[arg_db]:-}"
    if [[ -z $db ]]; then
      log_warn "--db is required with --yes --preset database"
      return 1
    fi
    eng="${CFG[arg_engine]:-postgresql}"
    user="${CFG[arg_db_user]:-$db}"
    pass=$(_rand_pass)
    CFG[wizard_1_engine]=$eng
    CFG[wizard_1_db]=$db
    CFG[wizard_1_user]=$user
    CFG[wizard_1_pass]=$pass
    CFG[wizard_count]=1
    return 0
  fi

  # Detect installed engines
  # Engine yang sudah ada ATAU dipilih di run ini (run_create_database berjalan setelah instalasi DB)
  for e in postgresql mysql; do
    if db_installed "$e" || feature_selected "$e"; then engines+=("$e"); fi
  done

  if (( ${#engines[@]} == 0 )); then
    ui_msg "$title" "$(t db.wizard.no_db)"
    return 1
  fi

  local n=0
  while true; do
    local eng d user pass
    # pick engine
    if (( ${#engines[@]} == 1 )); then
      eng=${engines[0]}
    else
      local -a items=()
      for e in "${engines[@]}"; do
        items+=("$e" "$(t "db.wizard.engine.$e")")
      done
      eng=$(ui_menu "$title" "$(t db.wizard.pick_engine)" "${engines[0]}" "${items[@]}") || return 1
    fi

    d=$(ui_input "$title" "$(t db.wizard.db_name)" "") || return 1
    [[ -z $d ]] && break

    user=$(ui_input "$title" "$(t db.wizard.user_name "$d")" "$d") || return 1
    if (( ASSUME_YES )); then
      pass=$(_rand_pass)
    else
      local p1 p2
      while true; do
        p1=$(ui_password "$title" "$(t db.wizard.pass)") || return 1
        if (( ${#p1} < 8 )); then ui_msg "$title" "$(t db.wizard.pass_short)"; continue; fi
        p2=$(ui_password "$title" "$(t db.wizard.pass2)") || return 1
        if [[ $p1 == "$p2" ]]; then pass=$p1; break; fi
        ui_msg "$title" "$(t db.wizard.pass_mismatch)"
      done
    fi

    n=$((n+1))
    CFG[wizard_${n}_engine]=$eng
    CFG[wizard_${n}_db]=$d
    CFG[wizard_${n}_user]=$user
    CFG[wizard_${n}_pass]=$pass

    (( ASSUME_YES )) && { n=1; break; }
    ui_yesno "$title" "$(t db.wizard.ask_more)" no || break
  done

  CFG[wizard_count]=$n
  (( n > 0 ))
}

run_create_database() {
  local i n=${CFG[wizard_count]:-0} eng d user pass

  for ((i = 1; i <= n; i++)); do
    eng=${CFG[wizard_${i}_engine]}; d=${CFG[wizard_${i}_db]}
    user=${CFG[wizard_${i}_user]}; pass=${CFG[wizard_${i}_pass]}

    log_info "$(t db.wizard.creating "$d" "$eng")"

    case $eng in
      postgresql)
        run sudo -u postgres createdb "$d"
        run sudo -u postgres psql -c "CREATE USER \"$user\" WITH PASSWORD '$pass';"
        run sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE \"$d\" TO \"$user\";"
        # Grant on public schema for modern PostgreSQL
        run sudo -u postgres psql -d "$d" -c "GRANT ALL ON SCHEMA public TO \"$user\";" 2>/dev/null || true
        ;;
      mysql)
        run mysql -e "CREATE DATABASE IF NOT EXISTS \`${d}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
        run mysql -e "CREATE USER IF NOT EXISTS '${user}'@'localhost' IDENTIFIED BY '${pass}';"
        run mysql -e "GRANT ALL PRIVILEGES ON \`${d}\`.* TO '${user}'@'localhost'; FLUSH PRIVILEGES;"
        ;;
    esac

    log_ok "$(t db.wizard.created "$d")"
  done
}

summary_create_database() {
  local i n=${CFG[wizard_count]:-0} note
  for ((i = 1; i <= n; i++)); do
    (( i > 1 )) && printf '\n     '
    note="${CFG[wizard_${i}_db]} (${CFG[wizard_${i}_engine]}, user: ${CFG[wizard_${i}_user]})"
    t sum.wizard "$note"
  done
}

notes_create_database() {
  local i n=${CFG[wizard_count]:-0}
  for ((i = 1; i <= n; i++)); do
    printf '  DB:     %s\n' "${CFG[wizard_${i}_db]}"
    printf '  Engine: %s\n' "${CFG[wizard_${i}_engine]}"
    printf '  User:   %s\n' "${CFG[wizard_${i}_user]}"
    printf '  Pass:   %s\n\n' "${CFG[wizard_${i}_pass]}"
  done
}
