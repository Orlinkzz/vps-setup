#!/usr/bin/env bash
# shellcheck shell=bash
# Cloudflare real-IP support. Identical to Ubuntu: the installed script detects the distro paths
# (/etc/apache2 vs /etc/httpd) itself.
# shellcheck source=../ubuntu/35-cloudflare.sh
source "$ROOT_DIR/modules/ubuntu/35-cloudflare.sh"
