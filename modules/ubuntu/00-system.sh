#!/usr/bin/env bash
# shellcheck shell=bash
# Ubuntu — system basics: update, timezone, hostname, swap.

register_feature system_update system on
register_feature timezone      system on
register_feature hostname      system off
register_feature swap          system on

# ============================================================ system_update
run_system_update() {
  log_info "$(t system_update.lists)"
  pkg_update
  log_info "$(t system_update.upgrade)"
  pkg_upgrade
  log_info "$(t system_update.base)"
  pkg_install curl wget git unzip zip htop ncdu nano ca-certificates gnupg \
    lsb-release software-properties-common openssl jq
  log_ok "$(t system_update.done)"
}

# ============================================================ timezone
prompt_timezone() {
  local current tz choice
  local -a items=()
  local -a common=(UTC Asia/Jakarta Asia/Makassar Asia/Jayapura Asia/Singapore
    Asia/Kuala_Lumpur Asia/Bangkok Asia/Manila Europe/London Europe/Berlin
    America/New_York America/Los_Angeles)

  current=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  current=${current:-UTC}
  items+=("$current" "$(t timezone.current)")
  for tz in "${common[@]}"; do
    [[ $tz == "$current" ]] || items+=("$tz" " ")
  done
  items+=("other" "$(t timezone.other)")

  choice=$(ui_menu "$(t feat.timezone.title)" "$(t timezone.ask)" "$current" "${items[@]}") || return 1

  if [[ $choice == other ]]; then
    while true; do
      tz=$(ui_input "$(t feat.timezone.title)" "$(t timezone.other_ask)" "") || return 1
      if timedatectl list-timezones 2>/dev/null | grep -qx -- "$tz"; then break; fi
      (( ASSUME_YES )) && return 1
      ui_msg "$(t feat.timezone.title)" "$(t timezone.invalid "$tz")"
    done
    choice=$tz
  fi
  CFG[timezone]=$choice
}

run_timezone() {
  local tz=${CFG[timezone]}
  if ! has_systemd || ! run timedatectl set-timezone "$tz"; then
    # Fallback for systems without a running systemd (e.g. containers)
    run ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
    run_sh "echo '$tz' > /etc/timezone"
  fi
  log_ok "$(t timezone.set "$tz")"
}
summary_timezone() { t sum.timezone "${CFG[timezone]}"; }

# ============================================================ hostname
prompt_hostname() {
  local title name
  title=$(t feat.hostname.title)
  while true; do
    name=$(ui_input "$title" "$(t hostname.ask)" "$(hostname -s 2>/dev/null || echo server)") || return 1
    if valid_hostname "$name"; then break; fi
    (( ASSUME_YES )) && return 1
    ui_msg "$title" "$(t hostname.invalid "$name")"
  done
  CFG[hostname]=$name
}

run_hostname() {
  local name=${CFG[hostname]}
  if ! has_systemd || ! run hostnamectl set-hostname "$name"; then
    run hostname "$name"
    run_sh "echo '$name' > /etc/hostname"
  fi
  backup_file /etc/hosts
  if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts 2>/dev/null; then
    run sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1 $name/" /etc/hosts
  else
    run_sh "echo '127.0.1.1 $name' >> /etc/hosts"
  fi
  log_ok "$(t hostname.set "$name")"
}
summary_hostname() { t sum.hostname "${CFG[hostname]}"; }

# ============================================================ swap
swap_active() { [[ -n $(swapon --show --noheadings 2>/dev/null) ]]; }

suggest_swap_mb() {
  if (( MEM_MB <= 4096 )); then echo 2048
  elif (( MEM_MB <= 16384 )); then echo 1024
  else echo 0
  fi
}

prompt_swap() {
  local title sug avail size default
  local -a items=()
  title=$(t feat.swap.title)
  CFG[swap_mb]=0

  if swap_active; then ui_msg "$title" "$(t swap.exists)"; return 0; fi
  if (( IS_CONTAINER )); then ui_msg "$title" "$(t swap.container)"; return 0; fi

  avail=$(df -Pm / | awk 'NR==2{print $4}')
  sug=$(suggest_swap_mb)
  default=0
  for size in 1024 2048 4096 8192; do
    (( size * 3 <= avail )) || continue
    items+=("$size" "$(t swap.size $(( size / 1024 )))")
    (( size <= sug )) && default=$size
  done
  if (( ${#items[@]} == 0 )); then ui_msg "$title" "$(t swap.disk)"; return 0; fi
  items+=("0" "$(t swap.none)")
  (( default == 0 && sug > 0 )) && default=${items[0]}

  CFG[swap_mb]=$(ui_menu "$title" "$(t swap.ask "$MEM_MB")" "$default" "${items[@]}") || return 1
}

_make_swapfile() { # <mb> <fallocate|dd>
  run rm -f /swapfile
  if [[ $2 == fallocate ]]; then
    run fallocate -l "${1}M" /swapfile
  else
    run dd if=/dev/zero of=/swapfile bs=1M count="$1" status=none
  fi
  run chmod 600 /swapfile
  run mkswap /swapfile
  run swapon /swapfile
}

run_swap() {
  local mb=${CFG[swap_mb]:-0} fs
  if (( mb == 0 )); then feature_skip "$(t swap.skipped)"; fi
  if swap_active; then feature_skip "$(t swap.exists)"; fi
  fs=$(stat -f -c %T / 2>/dev/null || echo unknown)
  case "$fs" in btrfs|zfs) feature_skip "$(t swap.fs)" ;; esac

  log_info "$(t swap.creating "$mb")"
  if ! _make_swapfile "$mb" fallocate; then
    log_warn "fallocate swap failed, retrying with dd"
    run swapoff /swapfile || true
    _make_swapfile "$mb" dd
  fi
  run_sh "grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab"

  write_file /etc/sysctl.d/99-vps-setup.conf 644 <<'EOF'
# Managed by vps-setup
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
  run sysctl --system
  log_ok "$(t swap.created)"
}
summary_swap() { t sum.swap "${CFG[swap_mb]}"; }
