#!/usr/bin/env bash
# =============================================================================
# VPS Setup bootstrap — downloads the repo and starts the interactive setup.
#
#   curl -fsSL https://raw.githubusercontent.com/OWNER/vps-setup/main/install.sh | sudo bash
#   curl -fsSL .../install.sh | sudo bash -s -- --lang id
#
# Prefer to read the code first? Clone the repo and run: sudo ./setup.sh
# =============================================================================
set -euo pipefail

REPO="${VPS_SETUP_REPO:-OWNER/vps-setup}"   # TODO: replace OWNER with your GitHub username
REF="${VPS_SETUP_REF:-main}"
DEST="${VPS_SETUP_DIR:-/opt/vps-setup}"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root, e.g.: curl -fsSL <url> | sudo bash" >&2
  exit 1
fi

command -v apt-get >/dev/null 2>&1 || { echo "Only Ubuntu/Debian (apt) is supported for now." >&2; exit 1; }
for bin in curl tar; do
  command -v "$bin" >/dev/null 2>&1 || {
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl tar
  }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading ${REPO}@${REF} ..."
curl -fsSL "https://codeload.github.com/${REPO}/tar.gz/${REF}" -o "$tmp/src.tar.gz"
mkdir -p "$DEST"
tar -xzf "$tmp/src.tar.gz" --strip-components=1 -C "$DEST"
chmod +x "$DEST/setup.sh"

# When piped (curl | bash) stdin is the pipe, so hand the terminal back for the menus.
if [[ ! -t 0 && -r /dev/tty ]]; then
  exec "$DEST/setup.sh" "$@" </dev/tty
fi
exec "$DEST/setup.sh" "$@"
