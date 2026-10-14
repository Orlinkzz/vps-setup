#!/usr/bin/env bash
# shellcheck shell=bash
# AlmaLinux / Rocky / RHEL — runtimes. Package names and PHP sources differ from Debian.
# shellcheck source=../ubuntu/50-runtime.sh
source "$ROOT_DIR/modules/ubuntu/50-runtime.sh"

# The newest PHP module stream AppStream offers (the default stream is old: 7.2 on EL8, 8.0 on EL9).
_php_newest_stream() {
  command -v dnf >/dev/null 2>&1 || return 1
  dnf -q module list php 2>/dev/null | awk '$1=="php" && $2 ~ /^[0-9]+\.[0-9]+$/ {print $2}' | sort -V | tail -n 1
}

_system_php_ver() {
  local v
  v=$(_php_newest_stream 2>/dev/null) || v=""
  if [[ -n $v ]]; then printf '%s' "$v"; return; fi
  case "$OS_VERSION" in
    8) printf '8.2' ;;
    *) printf '8.3' ;;
  esac
}

# Only AppStream's module streams are used (no third-party repo); the newest one is enabled.
prompt_php_runtime() { CFG[php_ver]=$(_system_php_ver); }

run_php_runtime() {
  local ver stream
  stream=$(_php_newest_stream 2>/dev/null) || stream=""
  log_info "$(t runtime.php.installing "${stream:-system}")"
  if [[ -n $stream ]] && ! pkg_installed php-fpm; then
    run dnf "${DNF_OPTS[@]}" -y module reset php
    run dnf "${DNF_OPTS[@]}" -y module enable "php:$stream"
  fi

  pkg_install php php-fpm php-cli php-mbstring php-xml php-curl php-gd \
    php-intl php-bcmath php-zip php-soap php-mysqlnd php-pgsql php-opcache

  # EPEL has php-pecl-redis
  if ! pkg_installed php-pecl-redis; then
    pkg_install epel-release || true
    pkg_update
    pkg_install php-pecl-redis || log_warn "php-pecl-redis not available; skipping"
  fi

  if ! command -v composer >/dev/null 2>&1; then
    run_sh "cd /tmp && curl -fsS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer"
    run chmod +x /usr/local/bin/composer
  fi

  # Unlike Debian, the RHEL package does not start the service
  svc_enable_now php-fpm

  ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || _system_php_ver)
  CFG[php_ver]=$ver
  CFG[php_socket]=/run/php-fpm/www.sock
  log_ok "$(t runtime.php.done "$ver")"
}

summary_php_runtime() {
  t sum.php "$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || _system_php_ver)"
}

# NodeSource setup script supports RHEL family the same way.
run_node_runtime() {
  local ver=${CFG[node_major]:-22}
  log_info "$(t runtime.node.installing "$ver")"
  run_sh "curl -fsSL https://rpm.nodesource.com/setup_${ver}.x | bash -"
  pkg_install nodejs
  log_ok "$(t runtime.node.done)"
}

run_python_runtime() {
  log_info "$(t runtime.python.installing)"
  pkg_install python3 python3-pip python3-devel gcc gcc-c++ make
  run ln -sf /usr/bin/python3 /usr/local/bin/python 2>/dev/null || true
  log_ok "$(t runtime.python.done)"
}

# Docker's convenience script auto-detects RHEL family.
run_docker_runtime() {
  log_info "$(t runtime.docker.installing)"
  if ! command -v docker >/dev/null 2>&1; then
    run_sh "curl -fsSL https://get.docker.com | bash"
  fi
  svc_enable_now docker
  docker_bind_localhost

  local u=${CFG[username]:-}
  if [[ -n $u ]] && id "$u" >/dev/null 2>&1; then run usermod -aG docker "$u"; fi
  log_ok "$(t runtime.docker.done)"
}
