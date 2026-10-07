#!/usr/bin/env bash
# shellcheck shell=bash
# OS detection and package-manager / service abstraction.
# Phase 1 implements apt (Ubuntu). Other families plug in here later.

OS_ID=""; OS_VERSION=""; OS_CODENAME=""; OS_PRETTY=""
MEM_MB=0; CPU_COUNT=1; IS_CONTAINER=0
SSH_SERVICE=ssh
# Admin group that grants sudo/admin rights (wheel on RHEL family).
ADMIN_GROUP=sudo

detect_os() {
  [[ -r /etc/os-release ]] || return 1
  OS_ID=$(. /etc/os-release && printf '%s' "${ID:-}")
  OS_VERSION=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
  OS_CODENAME=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")
  OS_PRETTY=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-$ID}")
  case "$OS_ID" in
    almalinux|rocky|rhel|centos) SSH_SERVICE=sshd; ADMIN_GROUP=wheel ;;
    *)                           SSH_SERVICE=ssh;  ADMIN_GROUP=sudo  ;;
  esac
}

# 0 = supported, 1 = untested version, 2 = unsupported distro
os_check() {
  case "$OS_ID" in
    ubuntu)
      case "$OS_VERSION" in
        22.04|24.04) return 0 ;;
        *) return 1 ;;
      esac ;;
    debian)
      case "$OS_VERSION" in
        11|12) return 0 ;;
        *) return 1 ;;
      esac ;;
    almalinux|rocky)
      case "$OS_VERSION" in
        8|9) return 0 ;;
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

# Windows Subsystem for Linux: not a real server (no public IP, firewall/SSH steps are meaningless).
is_wsl() { [[ -n ${WSL_DISTRO_NAME:-} ]] || grep -qi microsoft /proc/version 2>/dev/null; }

primary_ip() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || true
  [[ -z $ip ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
  printf '%s' "${ip:-YOUR_SERVER_IP}"
}

# ------------------------------------------------------------ packages
# Two families: apt (Ubuntu/Debian) and dnf (AlmaLinux/Rocky).
APT_OPTS=(-o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
DNF_OPTS=(--setopt=install_weak_deps=False --setopt=timeout=120)

pkg_update() {
  case "$OS_ID" in
    almalinux|rocky|rhel|centos) run dnf "${DNF_OPTS[@]}" -y makecache ;;
    *) run env DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" update ;;
  esac
}

pkg_upgrade() {
  case "$OS_ID" in
    almalinux|rocky|rhel|centos) run dnf "${DNF_OPTS[@]}" -y upgrade ;;
    *) run env DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" -y upgrade ;;
  esac
}

pkg_install() {
  case "$OS_ID" in
    almalinux|rocky|rhel|centos) run dnf "${DNF_OPTS[@]}" -y install "$@" ;;
    *) run env DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" -y install "$@" ;;
  esac
}

pkg_installed() {
  case "$OS_ID" in
    almalinux|rocky|rhel|centos) rpm -q "$1" >/dev/null 2>&1 ;;
    *) dpkg -s "$1" >/dev/null 2>&1 ;;
  esac
}

# Package name translation (we write the Debian name; map it for dnf).
pkg_name() {
  case "$OS_ID" in
    almalinux|rocky|rhel|centos)
      case "$1" in
        apache2)          echo httpd ;;
        mysql-server)     echo mysql-server ;;
        postgresql-contrib) echo postgresql-contrib ;;
        python3-pip)      echo python3-pip ;;
        python3-venv)     echo python3 ;;
        python3-dev)      echo python3-devel ;;
        build-essential)  echo gcc gcc-c++ make ;;
        ufw)              echo firewalld ;;
        unattended-upgrades) echo dnf-automatic ;;
        lsb-release)      echo redhat-lsb-core ;;
        software-properties-common) echo dnf-plugins-core ;;
        sudo)             echo sudo ;;
        openssl)          echo openssl ;;
        ca-certificates)  echo ca-certificates ;;
        *)                echo "$1" ;;
      esac ;;
    *) echo "$1" ;;
  esac
}

# Install by Debian-style name, translating on RHEL family.
pkg_install_mapped() {
  local p out=()
  # Word splitting is intentional: pkg_name may map one name to several packages (gcc gcc-c++ make).
  # shellcheck disable=SC2207
  for p in "$@"; do out+=($(pkg_name "$p")); done
  pkg_install "${out[@]}"
}

# ------------------------------------------------------------ services
svc_enable_now() { run systemctl enable --now "$1"; }
svc_restart()    { run systemctl restart "$1"; }
svc_reload()     { run systemctl reload "$1"; }
# SSH_SERVICE is set in detect_os() once OS_ID is known.

# ------------------------------------------------------------ SSH helpers
detect_ssh_port() {
  local p
  p=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}') || true
  printf '%s' "${p:-22}"
}
