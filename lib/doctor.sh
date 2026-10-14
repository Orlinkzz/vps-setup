#!/usr/bin/env bash
# shellcheck shell=bash
# vps-setup --doctor: a read-only health check. It never changes anything; every finding says
# what to do next. Exit status: 0 = nothing failed, 1 = at least one check failed.

_DOC_FAIL=0
_doc_ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
_doc_warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
_doc_fail() { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*"; _DOC_FAIL=1; }
_doc_head() { printf '\n%s\n' "$*"; }
# A failing config test without root usually means "no permission", not "broken": only advise then
_doc_fail_root() { if (( EUID == 0 )); then _doc_fail "$*"; else _doc_warn "$* $(t doctor.need_root)"; fi; }

_doc_system() {
  local rc=0 use avail
  _doc_head "$(t doctor.h.system)"
  if detect_os; then
    os_check || rc=$?
    case $rc in
      0) _doc_ok "$OS_PRETTY" ;;
      3) _doc_fail "$(t doctor.os_eol "$OS_PRETTY")" ;;
      *) _doc_warn "$(t doctor.os_untested "$OS_PRETTY")" ;;
    esac
  else
    _doc_warn "$(t doctor.os_untested "unknown")"
  fi

  use=$(df -P / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')
  if [[ -n $use ]]; then
    if (( use >= 90 )); then _doc_fail "$(t doctor.disk "$use")"
    elif (( use >= 80 )); then _doc_warn "$(t doctor.disk "$use")"
    else _doc_ok "$(t doctor.disk "$use")"; fi
  fi
  avail=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
  [[ -n $avail ]] && { if (( avail < 100 )); then _doc_warn "$(t doctor.mem "$avail")"; else _doc_ok "$(t doctor.mem "$avail")"; fi; }

  if [[ -e /var/run/reboot-required ]]; then
    _doc_warn "$(t doctor.reboot)"
  elif command -v needs-restarting >/dev/null 2>&1 && ! needs-restarting -r >/dev/null 2>&1; then
    _doc_warn "$(t doctor.reboot)"
  fi

  local failed
  failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
  if [[ -n ${failed// /} ]]; then _doc_fail "$(t doctor.units_failed "$failed")"
  else _doc_ok "$(t doctor.units_ok)"; fi
}

_doc_access() {
  local port root pass fw=""
  _doc_head "$(t doctor.h.access)"
  if ! command -v sshd >/dev/null 2>&1; then _doc_warn "$(t doctor.no_sshd)"; return 0; fi
  if ! sshd -t >/dev/null 2>&1; then _doc_fail_root "$(t doctor.sshd_invalid)"; return 0; fi
  port=$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}')
  root=$(sshd -T 2>/dev/null | awk '$1=="permitrootlogin" {print $2; exit}')
  pass=$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication" {print $2; exit}')
  _doc_ok "$(t doctor.ssh_port "${port:-22}")"
  if [[ $root == no ]]; then _doc_ok "$(t doctor.root_off)"; else _doc_warn "$(t doctor.root_on)"; fi
  if [[ $pass == no ]]; then _doc_ok "$(t doctor.pass_off)"; else _doc_warn "$(t doctor.pass_on)"; fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    fw=ufw
    if ufw status 2>/dev/null | grep -qE "^(${port:-22}(/tcp)?|OpenSSH|22/tcp \(OpenSSH\))[[:space:]]+ALLOW"; then _doc_ok "$(t doctor.fw_ssh_ok ufw)"
    else _doc_fail "$(t doctor.fw_ssh_missing ufw "${port:-22}")"; fi
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    fw=firewalld
    if firewall-cmd --list-ports 2>/dev/null | grep -qw "${port:-22}/tcp" \
       || { [[ ${port:-22} == 22 ]] && firewall-cmd --list-services 2>/dev/null | grep -qw ssh; }; then
      _doc_ok "$(t doctor.fw_ssh_ok firewalld)"
    else _doc_fail "$(t doctor.fw_ssh_missing firewalld "${port:-22}")"; fi
  fi
  [[ -n $fw ]] || _doc_warn "$(t doctor.fw_off)"

  if command -v fail2ban-client >/dev/null 2>&1; then
    if systemctl is-active --quiet fail2ban; then _doc_ok "$(t doctor.f2b_ok)"; else _doc_fail "$(t doctor.f2b_down)"; fi
  fi
}

_doc_web() {
  local any=0 name
  local -a test
  _doc_head "$(t doctor.h.web)"
  for name in nginx apache2 httpd caddy; do
    case $name in
      nginx)   command -v nginx >/dev/null 2>&1 || continue; test=(nginx -t) ;;
      apache2) command -v apache2ctl >/dev/null 2>&1 || continue; test=(apache2ctl configtest) ;;
      httpd)   if ! command -v httpd >/dev/null 2>&1 || command -v apache2ctl >/dev/null 2>&1; then continue; fi
               test=(httpd -t) ;;
      caddy)   command -v caddy >/dev/null 2>&1 || continue; test=(caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile) ;;
    esac
    any=1
    if "${test[@]}" >/dev/null 2>&1; then
      if systemctl is-active --quiet "$name"; then _doc_ok "$(t doctor.web_ok "$name")"
      else _doc_fail "$(t doctor.web_down "$name")"; fi
    else
      _doc_fail_root "$(t doctor.web_invalid "$name" "${test[*]}")"
    fi
  done
  (( any )) || _doc_ok "$(t doctor.web_none)"

  # Let's Encrypt certificates that expire within 21 days (renewal should have happened by then)
  local cert dom
  for cert in /etc/letsencrypt/live/*/cert.pem; do
    [[ -e $cert ]] || continue
    dom=$(basename "$(dirname "$cert")")
    if openssl x509 -checkend $((21 * 86400)) -noout -in "$cert" >/dev/null 2>&1; then
      _doc_ok "$(t doctor.cert_ok "$dom")"
    else
      _doc_fail "$(t doctor.cert_expiring "$dom")"
    fi
  done
}

_doc_backups() {
  local newest age
  [[ -e /usr/local/bin/vps-setup-backup ]] || return 0
  _doc_head "$(t doctor.h.backups)"
  if tail -n 30 /var/log/vps-setup-backup.log 2>/dev/null | grep -q 'RESULT: at least one backup FAILED'; then
    _doc_fail "$(t doctor.backup_failed)"
  fi
  newest=$(find /var/backups/vps-setup/db -name '*.sql.gz' -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1)
  if [[ -z $newest ]]; then
    _doc_warn "$(t doctor.backup_none)"
  else
    age=$(( ( $(date +%s) - ${newest%.*} ) / 3600 ))
    if (( age > 48 )); then _doc_fail "$(t doctor.backup_old "$age")"; else _doc_ok "$(t doctor.backup_ok "$age")"; fi
  fi
}

doctor_main() {
  printf '%s\n' "$(t doctor.title)"
  (( EUID == 0 )) || _doc_warn "$(t doctor.not_root)"
  _doc_system
  _doc_access
  _doc_web
  _doc_backups
  printf '\n'
  if (( _DOC_FAIL )); then printf '%s\n' "$(t doctor.result_fail)"; return 1; fi
  printf '%s\n' "$(t doctor.result_ok)"
  return 0
}
