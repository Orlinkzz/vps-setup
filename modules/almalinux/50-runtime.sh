#!/usr/bin/env bash
# shellcheck shell=bash
# AlmaLinux / Rocky / RHEL — runtimes. Package names and PHP sources differ from Debian.
# shellcheck source=../ubuntu/50-runtime.sh
source "$ROOT_DIR/modules/ubuntu/50-runtime.sh"

_system_php_ver() {
  case "$OS_VERSION" in
    8) printf '8.0' ;;
    9) printf '8.1' ;;
    *) printf '8.1' ;;
  esac
}

# RHEL 9 ships PHP in AppStream; remi provides extra versions. Keep it simple: distro PHP.
run_php_runtime() {
  local ver
  log_info "$(t runtime.php.installing "system")"

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

  local u=${CFG[username]:-}
  if [[ -n $u ]] && id "$u" >/dev/null 2>&1; then run usermod -aG docker "$u"; fi
  log_ok "$(t runtime.docker.done)"
}
