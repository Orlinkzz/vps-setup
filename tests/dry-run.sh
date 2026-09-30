#!/usr/bin/env bash
# Smoke tests: syntax, message-key coverage, and a full non-interactive dry run.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fail=0

echo "== syntax =="
for f in setup.sh install.sh lib/*.sh lib/i18n/*.sh modules/*/*.sh tests/*.sh; do
  bash -n "$f" || { echo "SYNTAX ERROR: $f"; fail=1; }
done

echo "== message keys used but not defined in en.sh =="
used=$(grep -rhoE '\bt "?[a-z0-9_]+\.[a-z0-9_.]+' setup.sh lib modules | sed -E 's/^t "?//' | sort -u)
for k in $used; do
  grep -qF "MSG[$k]=" lib/i18n/en.sh || { echo "MISSING: $k"; fail=1; }
done

echo "== dry run: recommended =="
bash ./setup.sh --yes --dry-run --preset recommended --lang en --ssh-key \
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl test@example" \
  >/tmp/vps-dry.out 2>&1 || { echo "dry run FAILED"; tail -n 30 /tmp/vps-dry.out; fail=1; }

echo "== dry run: minimal (id) =="
bash ./setup.sh --yes --dry-run --preset minimal --lang id >/tmp/vps-dry2.out 2>&1 || true

exit $fail
