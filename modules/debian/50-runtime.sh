#!/usr/bin/env bash
# shellcheck shell=bash
# Debian — runtimes. Node/Bun/Go/Python/Docker/FrankenPHP are identical to Ubuntu.
# PHP differs: Debian has no ondrej/php PPA, so only the distro's own PHP version is used.
# shellcheck source=../ubuntu/50-runtime.sh
source "$ROOT_DIR/modules/ubuntu/50-runtime.sh"

# Debian ships PHP in its own repos (11: 7.4, 12: 8.2).
_system_php_ver() {
  case "$OS_VERSION" in
    11) printf '7.4' ;;
    12) printf '8.2' ;;
    *)  printf '8.2' ;;
  esac
}

# No PPA on Debian: install the distro PHP directly instead of adding ondrej/php.
run_php_runtime() {
  local ver ext
  ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || _system_php_ver)
  log_info "$(t runtime.php.installing "$ver")"

  pkg_install php-fpm php-cli php-common php-mbstring php-xml php-curl php-gd \
    php-intl php-bcmath php-zip php-soap php-mysql php-pgsql php-sqlite3 php-redis

  if ! command -v composer >/dev/null 2>&1; then
    run_sh "cd /tmp && curl -fsS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer"
    run chmod +x /usr/local/bin/composer
  fi

  local sock
  # shellcheck disable=SC2012  # plain socket names; ls | head just picks the first one
  sock=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -n 1)
  CFG[php_socket]=${sock:-/run/php/php-fpm.sock}
  CFG[php_ver]=$ver
  log_ok "$(t runtime.php.done "$ver")"
}

summary_php_runtime() {
  local v
  v=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || _system_php_ver)
  t sum.php "$v"
}

notes_php_runtime() {
  local v
  v=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || _system_php_ver)
  t note.php "$v" "${v%.*}"; echo
}
