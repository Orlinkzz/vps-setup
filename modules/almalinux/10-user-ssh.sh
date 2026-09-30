#!/usr/bin/env bash
# shellcheck shell=bash
# AlmaLinux / Rocky / RHEL — access: admin user and SSH hardening.
# Same flow as Ubuntu; the admin group is "wheel" and "adduser" has no --disabled-password.
# shellcheck source=../ubuntu/10-user-ssh.sh
source "$ROOT_DIR/modules/ubuntu/10-user-ssh.sh"

# RHEL has no sudo group; membership in "wheel" grants admin rights.
have_safe_user() {
  local u home
  if feature_selected create_user && [[ ${CFG[new_user_has_key]:-0} == 1 ]]; then
    if (( DRY_RUN )) || [[ -z ${RESULT[create_user]:-} ]]; then return 0; fi
  fi
  for u in $(getent group wheel 2>/dev/null | cut -d: -f4 | tr ',' ' '); do
    [[ $u == root ]] && continue
    home=$(getent passwd "$u" | cut -d: -f6)
    [[ -n $home && -s "$home/.ssh/authorized_keys" ]] && return 0
  done
  return 1
}

run_create_user() {
  local user=${CFG[username]} home tmp line
  if id "$user" >/dev/null 2>&1; then
    log_info "$(t user.exists "$user")"
  else
    run useradd -m -s /bin/bash "$user"
  fi
  run usermod -aG wheel "$user"

  if [[ ${CFG[user_sudo]} == nopasswd ]]; then
    tmp=$(mktemp)
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" >"$tmp"
    if (( !DRY_RUN )) && ! visudo -cf "$tmp" >/dev/null 2>&1; then rm -f "$tmp"; return 1; fi
    write_file "/etc/sudoers.d/90-vps-setup-$user" 440 <"$tmp"
    rm -f "$tmp"
  fi

  if [[ -n ${CFG[user_password]:-} ]]; then
    if (( DRY_RUN )); then log_dry "set password for $user"
    else printf '%s:%s\n' "$user" "${CFG[user_password]}" | chpasswd; fi
  fi

  if [[ -n ${CFG[user_key]:-} ]]; then
    home=$(getent passwd "$user" | cut -d: -f6 || true)
    home=${home:-/home/$user}
    if (( DRY_RUN )); then log_dry "install SSH key for $user"
    else
      install -d -m 700 -o "$user" -g "$user" "$home/.ssh"
      touch "$home/.ssh/authorized_keys"
      while IFS= read -r line; do
        [[ -n $line ]] || continue
        grep -qxF -- "$line" "$home/.ssh/authorized_keys" || printf '%s\n' "$line" >>"$home/.ssh/authorized_keys"
      done <<<"${CFG[user_key]}"
      chown "$user:$user" "$home/.ssh/authorized_keys"
      chmod 600 "$home/.ssh/authorized_keys"
      # RHEL enables SELinux: give sshd the right context
      if command -v restorecon >/dev/null 2>&1; then restorecon -RF "$home/.ssh" 2>/dev/null || true; fi
    fi
  fi
  log_ok "$(t user.created "$user")"
}
