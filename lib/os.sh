#!/usr/bin/env bash
# shellcheck shell=bash
# OS detection and package-manager / service abstraction.
# Phase 1 implements apt (Ubuntu). Other families plug in here later.

OS_ID=""; OS_VERSION=""; OS_CODENAME=""; OS_PRETTY=""
MEM_MB=0; CPU_COUNT=1; IS_CONTAINER=0

detect_os() {
  [[ -r /etc/os-release ]] || return 1
  OS_ID=$(. /etc/os-release && printf '%s' "${ID:-}")
  OS_VERSION=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
  OS_CODENAME=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")
  OS_PRETTY=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-$ID}")
}

# 0 = supported, 1 = untested version, 2 = unsupported distro
os_check() {
  case "$OS_ID" in
    ubuntu)
      case "$OS_VERSION" in
        22.04|24.04) return 0 ;;
        *) return 1 ;;
      esac ;;
    *) return 2 ;;
  esac
}

detect_hw() {
  MEM_MB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
  CPU_COUNT=$(nproc 2>/dev/null || echo 1)
  if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -cq 2>/dev/null; then
    IS_CONTAINER=1
  fi
}

# True when the kernel really has IPv6 (some VPS images disable it; nginx then refuses "listen [::]:80").
ipv6_ok() {
  [[ -s /proc/net/if_inet6 ]] || return 1
  [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0) == 0 ]]
}

# nginx_filter: stdin → stdout; drops IPv6 listen lines when IPv6 is unavailable.
nginx_filter() {
  if ipv6_ok; then cat; else grep -vE '^[[:space:]]*listen[[:space:]]+\[::\]' || true; fi
}

has_systemd() { [[ -d /run/systemd/system ]]; }

primary_ip() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || true
  [[ -z $ip ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
  printf '%s' "${ip:-YOUR_SERVER_IP}"
}

# ------------------------------------------------------------ apt (Ubuntu)
APT_OPTS=(-o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

pkg_update()  { run env DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" update; }
pkg_upgrade() { run env DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" -y upgrade; }
pkg_install() { run env DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" -y install "$@"; }
pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------ services
svc_enable_now() { run systemctl enable --now "$1"; }
svc_restart()    { run systemctl restart "$1"; }
svc_reload()     { run systemctl reload "$1"; }
SSH_SERVICE=ssh

# ------------------------------------------------------------ SSH helpers
detect_ssh_port() {
  local p
  p=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}') || true
  printf '%s' "${p:-22}"
}
