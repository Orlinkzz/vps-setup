#!/usr/bin/env bash
# =============================================================================
# VPS Setup bootstrap — downloads the repo and starts the interactive setup.
#
#   curl -fsSL https://raw.githubusercontent.com/orlinkzz/vps-setup/main/install.sh | sudo bash
#   curl -fsSL .../install.sh | sudo bash -s -- --lang id
#
# Prefer to read the code first? Clone the repo and run: sudo ./setup.sh
# =============================================================================
set -euo pipefail

REPO="${VPS_SETUP_REPO:-orlinkzz/vps-setup}"
REF="${VPS_SETUP_REF:-main}"
DEST="${VPS_SETUP_DIR:-/opt/vps-setup}"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root, e.g.: curl -fsSL <url> | sudo bash" >&2
  exit 1
fi

if command -v apt-get >/dev/null 2>&1; then
  PKG_UPDATE=(env DEBIAN_FRONTEND=noninteractive apt-get -qq update)
  PKG_INSTALL=(env DEBIAN_FRONTEND=noninteractive apt-get -y -qq install)
elif command -v dnf >/dev/null 2>&1; then
  PKG_UPDATE=(dnf -q -y makecache)
  PKG_INSTALL=(dnf -q -y install)
else
  echo "Only Ubuntu/Debian (apt) and AlmaLinux/Rocky (dnf) are supported for now." >&2
  exit 1
fi

for bin in curl tar; do
  command -v "$bin" >/dev/null 2>&1 || {
    "${PKG_UPDATE[@]}" >/dev/null 2>&1 || true
    "${PKG_INSTALL[@]}" curl tar >/dev/null 2>&1
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
