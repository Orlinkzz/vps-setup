#!/usr/bin/env bash
# =============================================================================
# VPS Setup bootstrap — downloads the repo and starts the interactive setup.
#
#   curl -fsSL https://raw.githubusercontent.com/orlinkzz/vps-setup/main/install.sh | sudo bash
#   curl -fsSL .../install.sh | sudo bash -s -- --lang id
#
# Pin what you install with VPS_SETUP_REF (a tag such as v0.6.2, or a full commit SHA).
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
mkdir -p "$tmp/src"
tar -xzf "$tmp/src.tar.gz" --strip-components=1 -C "$tmp/src"
[[ -f $tmp/src/setup.sh ]] || { echo "The downloaded archive does not look like vps-setup (no setup.sh)." >&2; exit 1; }

# Replace a previous copy cleanly, so files deleted in a newer version do not linger.
# Only touches a directory that already holds this tool. State lives in /etc/vps-setup and
# /var/lib/vps-setup, never here.
if [[ -n $DEST && $DEST != / && -f $DEST/setup.sh ]]; then
  find "$DEST" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
fi
mkdir -p "$DEST"
cp -a "$tmp/src/." "$DEST/"
chmod +x "$DEST/setup.sh"

# When piped (curl | bash) stdin is the pipe, so hand the terminal back for the menus.
if [[ ! -t 0 && -r /dev/tty ]]; then
  exec "$DEST/setup.sh" "$@" </dev/tty
fi
exec "$DEST/setup.sh" "$@"
