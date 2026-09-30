#!/usr/bin/env bash
# shellcheck shell=bash
# Ubuntu — security: firewall, fail2ban, automatic updates.

register_feature ufw          security on
register_feature fail2ban     security on
register_feature auto_updates security on

# Port SSH will use when this step runs (SSH step runs first)
_effective_ssh_port() {
  if (( DRY_RUN )) && [[ -n ${CFG[ssh_port_new]:-} ]]; then
    printf '%s' "${CFG[ssh_port_new]}"
  else
    detect_ssh_port
  fi
}

# ============================================================ ufw
prompt_ufw() {
  local title sel extra="" ports=""
  title=$(t feat.ufw.title)
  sel=$(ui_checklist "$title" "$(t ufw.ask "$(_effective_ssh_port)")" \
    http "$(t ufw.opt_http)" on \
    https "$(t ufw.opt_https)" on \
    extra "$(t ufw.opt_extra)" off) || return 1

  grep -qx http <<<"$sel" && ports+=" 80/tcp"
  grep -qx https <<<"$sel" && ports+=" 443/tcp"
  if grep -qx extra <<<"$sel"; then
    while true; do
      extra=$(ui_input "$title" "$(t ufw.ask_extra)" "") || return 1
      valid_port_list "$extra" && break
      (( ASSUME_YES )) && return 1
      ui_msg "$title" "$(t ufw.bad_extra)"
    done
    extra=${extra//,/ }
    local tok
    for tok in $extra; do
      [[ $tok == */* ]] && ports+=" $tok" || ports+=" $tok/tcp"
    done
  fi
  CFG[ufw_ports]=${ports# }
}

run_ufw() {
  local ssh_port p
  ssh_port=$(_effective_ssh_port)
  pkg_install ufw
  run ufw default deny incoming
  run ufw default allow outgoing
  run ufw allow "${ssh_port}/tcp" comment 'SSH'
  for p in ${CFG[ufw_ports]:-}; do
    run ufw allow "$p"
  done
  run ufw --force enable
  run systemctl enable ufw
  log_ok "$(t ufw.enabled)"
}

summary_ufw() { t sum.ufw "$(printf ', %s' ${CFG[ufw_ports]:-} | sed 's#/tcp##g')"; }
notes_ufw() { t note.ufw_cloud; echo; }

# ============================================================ fail2ban
# IP of the current SSH session (empty when not connected over SSH)
_client_ip() {
  local ip=""
  ip=$(who -m 2>/dev/null | grep -oE '\([0-9a-fA-F:.]+\)' | head -n1 | tr -d '()') || true
  [[ -z $ip && -n ${SSH_CLIENT:-} ]] && ip=${SSH_CLIENT%% *}
  _valid_ip "$ip" && printf '%s' "$ip"
  return 0
}

# IPv4, IPv6 or CIDR range
_valid_ip() {
  local v4='^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'
  local v6='^[0-9a-fA-F:]*:[0-9a-fA-F:]*:[0-9a-fA-F:.]*(/[0-9]{1,3})?$'
  [[ $1 =~ $v4 || $1 =~ $v6 ]]
}

_valid_ip_list() {
  local tok
  for tok in $1; do
    _valid_ip "$tok" || return 1
  done
  return 0
}

prompt_fail2ban() {
  local title ip ign
  title=$(t feat.fail2ban.title)
  ip=$(_client_ip)
  while true; do
    ign=$(ui_input "$title" "$(t fail2ban.ask_ignore)" "$ip") || return 1
    _valid_ip_list "$ign" && break
    (( ASSUME_YES )) && return 1
    ui_msg "$title" "$(t fail2ban.bad_ip)"
  done
  CFG[f2b_ignore]=$ign
}

run_fail2ban() {
  local port
  port=$(_effective_ssh_port)
  pkg_install fail2ban python3-systemd
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
summary_fail2ban() { t sum.fail2ban; }

# ============================================================ auto_updates
prompt_auto_updates() {
  CFG[auto_reboot]=0
  if ui_yesno "$(t feat.auto_updates.title)" "$(t auto.ask_reboot)" no; then
    CFG[auto_reboot]=1
  fi
  return 0
}

run_auto_updates() {
  pkg_install unattended-upgrades
  write_file /etc/apt/apt.conf.d/20auto-upgrades 644 <<'EOF'
// Managed by vps-setup
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  if [[ ${CFG[auto_reboot]:-0} == 1 ]]; then
    write_file /etc/apt/apt.conf.d/52vps-setup-unattended 644 <<'EOF'
// Managed by vps-setup
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
  else
    write_file /etc/apt/apt.conf.d/52vps-setup-unattended 644 <<'EOF'
// Managed by vps-setup
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  fi
  svc_enable_now unattended-upgrades
  log_ok "$(t auto.enabled)"
}
summary_auto_updates() {
  local r; r=$(t word.no)
  [[ ${CFG[auto_reboot]:-0} == 1 ]] && r=$(t word.yes)
  t sum.auto "$r"
}
