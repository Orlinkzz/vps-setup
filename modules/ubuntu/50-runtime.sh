#!/usr/bin/env bash
# shellcheck shell=bash
# Ubuntu — runtimes: PHP-FPM + Composer, Node, Bun, Go, Python, Docker, FrankenPHP.

register_feature php_runtime      runtime off
register_feature node_runtime     runtime off
register_feature bun_runtime      runtime off
register_feature go_runtime       runtime off
register_feature python_runtime   runtime on
register_feature docker_runtime   runtime off
register_feature frankenphp       runtime off

# ---- helpers ----
_system_php_ver() {
  case "$OS_VERSION" in
    24.04) printf '8.3' ;;
    22.04) printf '8.1' ;;
    *)     printf '8.3' ;;
  esac
}

# ============================================================ PHP-FPM
prompt_php_runtime() {
  local title ver
  title=$(t feat.php_runtime.title)
  CFG[php_ver]=$(_system_php_ver)
  ver=$(ui_input "$title" "$(t runtime.php.ask_ver)" "${CFG[php_ver]}") || return 1
  CFG[php_ver]=$ver
}

run_php_runtime() {
  local ver=${CFG[php_ver]:-$(_system_php_ver)} ext pkg
  log_info "$(t runtime.php.installing "$ver")"

  # ondrej/php PPA for recent PHP versions
  if ! pkg_installed "php${ver}-fpm"; then
    if ! pkg_installed software-properties-common; then pkg_install software-properties-common; fi
    run add-apt-repository -y ppa:ondrej/php
    pkg_update
  fi

  pkg_install "php${ver}-fpm" "php${ver}-cli" "php${ver}-common" \
    "php${ver}-mbstring" "php${ver}-xml" "php${ver}-curl" "php${ver}-gd" \
    "php${ver}-intl" "php${ver}-bcmath" "php${ver}-zip" "php${ver}-soap" \
    "php${ver}-mysql" "php${ver}-pgsql" "php${ver}-sqlite3" "php${ver}-redis"

  # Composer
  if ! command -v composer >/dev/null 2>&1; then
    run_sh "cd /tmp && curl -fsS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer"
    run chmod +x /usr/local/bin/composer
  fi

  CFG[php_socket]="/run/php/php${ver}-fpm.sock"
  log_ok "$(t runtime.php.done "$ver")"
}

summary_php_runtime() { t sum.php "${CFG[php_ver]:-$(_system_php_ver)}"; }
notes_php_runtime()   { t note.php "${CFG[php_ver]:-$(_system_php_ver)}"; echo; }

# ============================================================ Node.js
prompt_node_runtime() {
  local title default=22
  title=$(t feat.node_runtime.title)
  CFG[node_major]=$(ui_input "$title" "$(t runtime.node.ask_ver)" "$default") || return 1
}

run_node_runtime() {
  local ver=${CFG[node_major]:-22}
  log_info "$(t runtime.node.installing "$ver")"

  run_sh "curl -fsSL https://deb.nodesource.com/setup_${ver}.x | bash -"
  pkg_install nodejs

  log_ok "$(t runtime.node.done)"
}

summary_node_runtime() { t sum.node "${CFG[node_major]:-22}"; }

# ============================================================ Bun
prompt_bun_runtime() { return 0; }

run_bun_runtime() {
  log_info "$(t runtime.bun.installing)"
  run_sh "curl -fsSL https://bun.sh/install | bash"
  run ln -sf "$HOME/.bun/bin/bun" /usr/local/bin/bun 2>/dev/null || true
  run ln -sf "$HOME/.bun/bin/bunx" /usr/local/bin/bunx 2>/dev/null || true
  log_ok "$(t runtime.bun.done)"
}

summary_bun_runtime() { t sum.bun; }

# ============================================================ Go
prompt_go_runtime() { return 0; }

run_go_runtime() {
  local ver arch url
  log_info "$(t runtime.go.installing)"
  arch=$(uname -m)
  [[ $arch == x86_64 ]] && arch=amd64
  [[ $arch == aarch64 ]] && arch=arm64
  # Fetch latest go version
  ver=$(curl -fsSL https://go.dev/VERSION?m=text 2>/dev/null | head -n 1) || ver=go1.23.0
  url="https://go.dev/dl/${ver}.linux-${arch}.tar.gz"

  if [[ ! -d /usr/local/go ]]; then
    run_sh "curl -fsSL '$url' | tar -C /usr/local -xzf -"
  fi
  run ln -sf /usr/local/go/bin/go /usr/local/bin/go
  run ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

  log_ok "$(t runtime.go.done)"
}

summary_go_runtime() { t sum.go; }

# ============================================================ Python
prompt_python_runtime() { return 0; }

run_python_runtime() {
  log_info "$(t runtime.python.installing)"
  pkg_install python3 python3-pip python3-venv python3-dev build-essential
  run ln -sf /usr/bin/python3 /usr/local/bin/python 2>/dev/null || true
  log_ok "$(t runtime.python.done)"
}

summary_python_runtime() { t sum.python; }

# ============================================================ Docker
prompt_docker_runtime() { return 0; }

run_docker_runtime() {
  log_info "$(t runtime.docker.installing)"

  if ! command -v docker >/dev/null 2>&1; then
    run_sh "curl -fsSL https://get.docker.com | bash"
  fi

  pkg_install docker-compose-plugin

  # add deploy user to docker group if exists
  local u=${CFG[username]:-}
  if [[ -n $u ]] && id "$u" >/dev/null 2>&1; then
    run usermod -aG docker "$u"
  fi

  # Also add any sudo user
  local sudouser
  sudouser=$(getent group "$ADMIN_GROUP" | cut -d: -f4 | tr ',' '\n' | grep -vx root | head -n 1) || true
  if [[ -n $sudouser ]] && ! id -nG "$sudouser" 2>/dev/null | grep -qw docker; then
    run usermod -aG docker "$sudouser"
  fi

  log_ok "$(t runtime.docker.done)"
}

summary_docker_runtime() { t sum.docker; }
notes_docker_runtime()   { t note.docker; echo; }

# ============================================================ FrankenPHP
prompt_frankenphp() { return 0; }

run_frankenphp() {
  local arch url
  log_info "$(t runtime.frankenphp.installing)"
  arch=$(uname -m)
  [[ $arch == x86_64 ]] && arch=x86_64
  [[ $arch == aarch64 ]] && arch=aarch64
  url="https://github.com/dunglas/frankenphp/releases/latest/download/frankenphp-linux-${arch}"

  if [[ ! -f /usr/local/bin/frankenphp ]]; then
    run_sh "curl -fsSL '$url' -o /tmp/frankenphp"
    run install -m 755 /tmp/frankenphp /usr/local/bin/frankenphp
  fi

  # systemd service (requires a Caddyfile in /etc/frankenphp/)
  run install -d -m 755 /etc/frankenphp
  write_file /etc/systemd/system/frankenphp.service 644 <<'EOF'
[Unit]
Description=FrankenPHP (static binary)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frankenphp run --config /etc/frankenphp/Caddyfile
Restart=on-failure
RestartSec=5
User=www-data
Group=www-data
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

  log_ok "$(t runtime.frankenphp.done)"
}

summary_frankenphp() { t sum.frankenphp; }
notes_frankenphp()   { t note.frankenphp; echo; }
