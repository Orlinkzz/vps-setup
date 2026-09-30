#!/usr/bin/env bash
# shellcheck shell=bash
# AlmaLinux / Rocky / RHEL — system basics.
# Timezone, hostname and swap are identical to Ubuntu; the base tool list is not.
# shellcheck source=../ubuntu/00-system.sh
source "$ROOT_DIR/modules/ubuntu/00-system.sh"

# RHEL base tools differ (policycoreutils provides restorecon/semanage, etc.)
run_system_update() {
  log_info "$(t system_update.lists)"
  pkg_update
  log_info "$(t system_update.upgrade)"
  pkg_upgrade
  log_info "$(t system_update.base)"
  pkg_install curl wget git unzip zip htop nano ca-certificates openssl jq \
    policycoreutils policycoreutils-python-utils dnf-plugins-core
  log_ok "$(t system_update.done)"
}
