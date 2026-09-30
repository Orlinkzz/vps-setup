#!/usr/bin/env bash
# Unit tests for validators and helpers (no root, no changes to the system).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
DRY_RUN=1; ASSUME_YES=1; LOG_FILE=/tmp/vps-unit.log
# shellcheck source=../lib/common.sh
source lib/common.sh
fail=0
ok()  { "$@" || { echo "FAIL (expected ok): $*"; fail=1; }; }
bad() { if "$@"; then echo "FAIL (expected reject): $*"; fail=1; fi; }

ok  valid_username deploy
ok  valid_username web_01
bad valid_username Root
bad valid_username "1abc"
bad valid_username "a b"
ok  valid_ssh_port 22
ok  valid_ssh_port 2222
bad valid_ssh_port 80
bad valid_ssh_port 70000
bad valid_ssh_port abc
ok  valid_hostname web-01
bad valid_hostname -bad
bad valid_hostname "a_b"
ok  valid_port_list "3000, 8080/tcp 51820/udp"
bad valid_port_list "3000/icmp"
bad valid_port_list "99999"
bad valid_port_list ""
ok  valid_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl me@x"
bad valid_ssh_pubkey "ssh-ed25519 notbase64!!"
bad valid_ssh_pubkey 'command="x" ssh-ed25519 AAAA'

# write_file must be idempotent and never touch disk in dry-run
tmp=$(mktemp -d)
DRY_RUN=0
printf 'a\n' | write_file "$tmp/f" 600
before=$(stat -c %Y "$tmp/f")
sleep 1
printf 'a\n' | write_file "$tmp/f" 600
[[ $(stat -c %Y "$tmp/f") == "$before" ]] || { echo "FAIL: write_file rewrote identical content"; fail=1; }
[[ $(stat -c %a "$tmp/f") == 600 ]] || { echo "FAIL: mode not applied"; fail=1; }
DRY_RUN=1
printf 'b\n' | write_file "$tmp/g" 600 >/dev/null
[[ -e $tmp/g ]] && { echo "FAIL: dry-run wrote a file"; fail=1; }
rm -rf "$tmp"

(( fail )) && echo "UNIT TESTS FAILED" || echo "unit tests passed"
exit $fail
