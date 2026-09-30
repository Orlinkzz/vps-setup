#!/usr/bin/env bash
# shellcheck shell=bash
# AlmaLinux / Rocky / RHEL — security: firewalld (not ufw), fail2ban, dnf-automatic.
# shellcheck source=../ubuntu/20-security.sh
source "$ROOT_DIR/modules/ubuntu/20-security.sh"

# ------------------------------------------------------------ firewalld
run_ufw() {
  local ssh_port p
  ssh_port=$(_effective_ssh_port)

  pkg_install firewalld
  svc_enable_now firewalld

  # SSH must be open BEFORE anything else so we cannot lock ourselves out.
  if valid_port "$ssh_port" && [[ $ssh_port != 22 ]]; then
    run firewall-cmd --permanent --add-port="${ssh_port}/tcp"
    run firewall-cmd --add-port="${ssh_port}/tcp"
  else
    run firewall-cmd --permanent --add-service=ssh
    run firewall-cmd --add-service=ssh
  fi

  for p in ${CFG[ufw_ports]:-}; do
    case "$p" in
      80/tcp)  run firewall-cmd --permanent --add-service=http ;;
      443/tcp) run firewall-cmd --permanent --add-service=https ;;
      *)       run firewall-cmd --permanent --add-port="$p" ;;
    esac
  done

  run firewall-cmd --reload
  run systemctl enable firewalld
  log_ok "$(t ufw.enabled)"
}

# ------------------------------------------------------------ fail2ban
run_fail2ban() {
  local port
  port=$(_effective_ssh_port)

  # EPEL provides fail2ban on RHEL family
  if ! pkg_installed fail2ban; then
    run dnf "${DNF_OPTS[@]}" -y install epel-release
    pkg_update
  fi
  # python3-systemd comes from EPEL; if it is missing, fail2ban still works (backend falls back).
  pkg_install fail2ban python3-systemd || pkg_install fail2ban

  write_file /etc/fail2ban/jail.d/00-vps-setup.local 644 <<EOF
# Managed by vps-setup
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1 ${CFG[f2b_ignore]:-}

[sshd]
enabled = true
port    = ${port}
backend = systemd
EOF
  svc_enable_now fail2ban
  svc_restart fail2ban
  log_ok "$(t fail2ban.enabled)"
}

# ------------------------------------------------------------ dnf-automatic
run_auto_updates() {
  pkg_install dnf-automatic
  write_file /etc/dnf/automatic.conf 644 <<EOF
# Managed by vps-setup
[commands]
upgrade_type = security
random_sleep = 0
apply_updates = yes

[emitters]
emit_via = stdio
EOF
  svc_enable_now dnf-automatic.timer
  log_ok "$(t auto.enabled)"
}
