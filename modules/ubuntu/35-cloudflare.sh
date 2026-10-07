#!/usr/bin/env bash
# shellcheck shell=bash
# Cloudflare: show the real visitor IP when the site is behind Cloudflare's proxy.
# All the work is done by templates/cloudflare/vps-setup-cloudflare-ips.sh, which this feature
# installs as /usr/local/sbin/vps-setup-cloudflare-ips (it also refreshes the ranges weekly).
# Same code for Ubuntu, Debian and AlmaLinux/Rocky: the script finds the right paths itself.

register_feature cloudflare web off

CF_BIN=/usr/local/sbin/vps-setup-cloudflare-ips

# The web server this feature should configure: the one chosen in this run, else an installed
# one. Prints nginx or apache, or nothing (no web server, or Caddy, which is not supported).
_cf_server() {
  local ws=""
  if feature_selected webserver && [[ -n ${CFG[webserver]:-} ]]; then
    ws=${CFG[webserver]}
  else
    ws=$(installed_webservers | head -n 1)
  fi
  [[ $ws == nginx || $ws == apache ]] && printf '%s' "$ws"
  return 0
}

prompt_cloudflare() {
  local title ws
  title=$(t feat.cloudflare.title)
  ws=$(_cf_server)
  if [[ -z $ws ]]; then
    ui_msg "$title" "$(t cf.need_web)"
    return 1
  fi
  CFG[cf_server]=$ws
  CFG[cf_extra]=""
  # A Cloudflare Tunnel (cloudflared) connects from this very machine.
  if ui_yesno "$title" "$(t cf.ask_tunnel)" no; then CFG[cf_extra]="127.0.0.1 ::1"; fi
}

run_cloudflare() {
  local ws=${CFG[cf_server]:-$(_cf_server)} extra=${CFG[cf_extra]:-}
  [[ -n $ws ]] || { feature_skip "$(t cf.need_web)"; return; }

  log_info "$(t cf.installing)"
  pkg_install curl
  run install -d -m 755 /etc/vps-setup /usr/local/sbin
  write_file /etc/vps-setup/cloudflare.conf 644 <<EOT
# Managed by vps-setup — read by vps-setup-cloudflare-ips
# Extra addresses that may send the CF-Connecting-IP header (space separated).
CF_EXTRA_TRUSTED="$extra"
EOT
  write_file "$CF_BIN" 755 <"$TPL_DIR/cloudflare/vps-setup-cloudflare-ips.sh"

  if ! run "$CF_BIN" --server "$ws" --quiet; then
    log_err "$(t cf.failed "$LOG_FILE")"
    return 1
  fi

  if (( DRY_RUN )) || has_systemd; then
    write_file /etc/systemd/system/vps-setup-cloudflare.service 644 <<EOT
# Managed by vps-setup
[Unit]
Description=Refresh Cloudflare IP ranges for the web server (vps-setup)

[Service]
Type=oneshot
ExecStart=$CF_BIN --server $ws --quiet
EOT
    write_file /etc/systemd/system/vps-setup-cloudflare.timer 644 <<'EOT'
# Managed by vps-setup
[Unit]
Description=Weekly refresh of Cloudflare IP ranges (vps-setup)

[Timer]
OnCalendar=weekly
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOT
    run systemctl daemon-reload
    run systemctl enable --now vps-setup-cloudflare.timer
  else
    log_warn "$(t cf.no_systemd)"
  fi
  log_ok "$(t cf.done "$ws")"
}

summary_cloudflare() { t sum.cloudflare "$(_cf_server)"; }
notes_cloudflare()   { t note.cloudflare "${CFG[cf_server]:-nginx}"; }
