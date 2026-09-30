#!/usr/bin/env bash
# shellcheck shell=bash
# Ubuntu — access: admin user and SSH hardening.

register_feature create_user access on
register_feature ssh_harden  access on

SSH_DROPIN=/etc/ssh/sshd_config.d/00-vps-setup.conf

# Only lines that are real keys (skips cloud "command=..." restricted entries)
collect_root_keys() { grep -hE '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys 2>/dev/null || true; }

# True when a sudo user with an SSH key exists (or is being created right now).
have_safe_user() {
  local u home
  # A user planned in this run counts while planning (prompts / dry-run). At run time the
  # real filesystem check below is authoritative, so a failed user creation is never trusted.
  if feature_selected create_user && [[ ${CFG[new_user_has_key]:-0} == 1 ]]; then
    if (( DRY_RUN )) || [[ -z ${RESULT[create_user]:-} ]]; then return 0; fi
  fi
  for u in $(getent group sudo 2>/dev/null | cut -d: -f4 | tr ',' ' '); do
    [[ $u == root ]] && continue
    home=$(getent passwd "$u" | cut -d: -f6)
    [[ -n $home && -s "$home/.ssh/authorized_keys" ]] && return 0
  done
  return 1
}

# ============================================================ create_user
prompt_create_user() {
  local title user src key="" mode pass="" pass1 pass2 default_src default_mode root_keys
  local -a items=()
  title=$(t feat.create_user.title)
  root_keys=$(collect_root_keys)

  while true; do
    user=$(ui_input "$title" "$(t user.ask_name)" "${CFG[username]:-deploy}") || return 1
    if valid_username "$user" && [[ $user != root ]]; then break; fi
    (( ASSUME_YES )) && return 1
    ui_msg "$title" "$(t user.bad_name)"
  done

  [[ -n $root_keys ]] && items+=(copy "$(t user.key_copy)")
  items+=(paste "$(t user.key_paste)" skip "$(t user.key_skip)")
  if [[ -n ${CFG[ssh_pubkey]:-} ]]; then default_src=paste
  elif [[ -n $root_keys ]]; then default_src=copy
  elif (( ASSUME_YES )); then default_src=skip
  else default_src=paste
  fi
  src=$(ui_menu "$title" "$(t user.ask_key)" "$default_src" "${items[@]}") || return 1

  case $src in
    copy) key=$root_keys ;;
    paste)
      while true; do
        key=$(ui_input "$title" "$(t user.paste_ask)" "${CFG[ssh_pubkey]:-}") || return 1
        valid_ssh_pubkey "$key" && break
        (( ASSUME_YES )) && return 1
        ui_msg "$title" "$(t user.bad_key)"
      done ;;
  esac

  if [[ -z $key ]]; then
    if (( ASSUME_YES )); then log_warn "$(t user.need_key_yes)"; return 1; fi
    mode=password
    ui_msg "$title" "$(t user.no_key_note)"
  else
    default_mode=password
    (( ASSUME_YES )) && default_mode=nopasswd
    mode=$(ui_menu "$title" "$(t user.ask_sudo)" "$default_mode" \
      password "$(t user.sudo_password)" nopasswd "$(t user.sudo_nopasswd)") || return 1
  fi

  if [[ $mode == password ]]; then
    while true; do
      pass1=$(ui_password "$title" "$(t user.ask_pass)") || return 1
      if (( ${#pass1} < 8 )); then ui_msg "$title" "$(t user.pass_short)"; continue; fi
      pass2=$(ui_password "$title" "$(t user.ask_pass2)") || return 1
      if [[ $pass1 == "$pass2" ]]; then pass=$pass1; break; fi
      ui_msg "$title" "$(t user.pass_mismatch)"
    done
  fi

  CFG[username]=$user
  CFG[user_key]=$key
  CFG[user_sudo]=$mode
  CFG[user_password]=$pass
  if [[ -n $key ]]; then CFG[new_user_has_key]=1; else CFG[new_user_has_key]=0; fi
}

run_create_user() {
  local user=${CFG[username]} home tmp line
  command -v sudo >/dev/null 2>&1 || pkg_install sudo
  if id "$user" >/dev/null 2>&1; then
    log_info "$(t user.exists "$user")"
  else
    run adduser --disabled-password --gecos "" "$user"
  fi
  run usermod -aG sudo "$user"

  if [[ ${CFG[user_sudo]} == nopasswd ]]; then
    tmp=$(mktemp)
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" >"$tmp"
    if (( !DRY_RUN )) && ! visudo -cf "$tmp" >/dev/null 2>&1; then rm -f "$tmp"; return 1; fi
    write_file "/etc/sudoers.d/90-vps-setup-$user" 440 <"$tmp"
    rm -f "$tmp"
  fi

  if [[ -n ${CFG[user_password]:-} ]]; then
    if (( DRY_RUN )); then
      log_dry "set password for $user"
    else
      printf '%s:%s\n' "$user" "${CFG[user_password]}" | chpasswd
    fi
  fi

  if [[ -n ${CFG[user_key]:-} ]]; then
    home=$(getent passwd "$user" | cut -d: -f6 || true)
    home=${home:-/home/$user}
    if (( DRY_RUN )); then
      log_dry "install SSH key for $user"
    else
      install -d -m 700 -o "$user" -g "$user" "$home/.ssh"
      touch "$home/.ssh/authorized_keys"
      while IFS= read -r line; do
        [[ -n $line ]] || continue
        grep -qxF -- "$line" "$home/.ssh/authorized_keys" || printf '%s\n' "$line" >>"$home/.ssh/authorized_keys"
      done <<<"${CFG[user_key]}"
      chown "$user:$user" "$home/.ssh/authorized_keys"
      chmod 600 "$home/.ssh/authorized_keys"
    fi
  fi
  log_ok "$(t user.created "$user")"
}

summary_create_user() {
  local k; k=$(t word.no)
  [[ ${CFG[new_user_has_key]:-0} == 1 ]] && k=$(t word.yes)
  t sum.user "${CFG[username]}" "${CFG[user_sudo]}" "$k"
}
notes_create_user() { t note.user_login "${CFG[username]}" "$(primary_ip)"; }

# ============================================================ ssh_harden
prompt_ssh_harden() {
  local title sel port
  title=$(t feat.ssh_harden.title)
  CFG[ssh_root_off]=0; CFG[ssh_pass_off]=0; CFG[ssh_port_new]=""

  if ! have_safe_user; then
    ui_msg "$title" "$(t ssh.no_safe_user)"
    return 0
  fi

  sel=$(ui_checklist "$title" "$(t ssh.ask)" \
    root "$(t ssh.opt_root)" on \
    pass "$(t ssh.opt_pass)" on \
    port "$(t ssh.opt_port)" off) || return 1

  grep -qx root <<<"$sel" && CFG[ssh_root_off]=1
  grep -qx pass <<<"$sel" && CFG[ssh_pass_off]=1
  if grep -qx port <<<"$sel"; then
    while true; do
      port=$(ui_input "$title" "$(t ssh.ask_port)" "2222") || return 1
      valid_ssh_port "$port" && break
      (( ASSUME_YES )) && return 1
      ui_msg "$title" "$(t ssh.bad_port)"
    done
    CFG[ssh_port_new]=$port
  fi
  return 0
}

run_ssh_harden() {
  local root_off=${CFG[ssh_root_off]:-0} pass_off=${CFG[ssh_pass_off]:-0}
  local cur port new_port=${CFG[ssh_port_new]:-}

  cur=$(detect_ssh_port)
  port=${new_port:-$cur}

  if (( root_off || pass_off )) && ! have_safe_user; then
    log_warn "$(t ssh.lockout_guard)"
    root_off=0; pass_off=0
  fi
  if (( !root_off && !pass_off )) && [[ -z $new_port ]]; then
    feature_skip "$(t ssh.lockout_guard)"
  fi

  # Make sure the main config reads the drop-in directory (missing on older Ubuntu)
  if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null; then
    backup_file /etc/ssh/sshd_config
    run sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  fi

  # Named 00-* so it wins over cloud-init's 50-cloud-init.conf (first value wins in sshd)
  {
    echo "# Managed by vps-setup"
    echo "Port $port"
    (( root_off )) && echo "PermitRootLogin no"
    if (( pass_off )); then
      echo "PasswordAuthentication no"
      echo "KbdInteractiveAuthentication no"
    fi
    echo "PubkeyAuthentication yes"
    echo "MaxAuthTries 3"
    echo "LoginGraceTime 30"
    echo "X11Forwarding no"
    echo "ClientAliveInterval 300"
    echo "ClientAliveCountMax 2"
  } | write_file "$SSH_DROPIN" 644

  if ! (( DRY_RUN )); then
    if ! sshd -t 2>>"$LOG_FILE"; then
      log_err "$(t ssh.bad_config)"
      rm -f "$SSH_DROPIN"
      return 1
    fi
  fi

  # Open the new port in the firewall BEFORE SSH moves, if UFW is already active
  if [[ $port != "$cur" ]] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    run ufw allow "${port}/tcp" comment 'SSH'
  fi

  # Ubuntu 24.04 uses socket activation, which ignores "Port": switch to the plain service
  if [[ $port != "$cur" ]] && systemctl list-unit-files ssh.socket >/dev/null 2>&1 \
     && systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    run systemctl disable --now ssh.socket
    run systemctl enable "$SSH_SERVICE"
  fi
  run systemctl restart "$SSH_SERVICE"

  if ! (( DRY_RUN )) && (( pass_off )); then
    sshd -T 2>/dev/null | grep -qx 'passwordauthentication no' \
      || log_warn "PasswordAuthentication is still enabled by another config file (see /etc/ssh/sshd_config.d/)"
  fi

  CFG[ssh_root_result]=$root_off
  CFG[ssh_pass_result]=$pass_off
  CFG[ssh_port_result]=$port
  log_ok "$(t ssh.applied "$port")"
}

summary_ssh_harden() {
  local r p
  r=$(t word.on); p=$(t word.on)
  [[ ${CFG[ssh_root_off]:-0} == 1 ]] && r=$(t word.off)
  [[ ${CFG[ssh_pass_off]:-0} == 1 ]] && p=$(t word.off)
  t sum.ssh "$r" "$p" "${CFG[ssh_port_new]:-$(detect_ssh_port)}"
}

notes_ssh_harden() {
  local u=${CFG[username]:-your-user} port=${CFG[ssh_port_result]:-22} opt=""
  t note.ssh_test; echo
  [[ $port != 22 ]] && opt="-p $port "
  printf '    ssh %s%s@%s\n' "$opt" "$u" "$(primary_ip)"
  [[ $port != 22 ]] && { t note.ssh_port "$port"; echo; }
  return 0
}
