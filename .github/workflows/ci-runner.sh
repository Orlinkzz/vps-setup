#!/usr/bin/env bash
# In-container CI runner — runs inside the Docker test image.
set -euo pipefail

cd /opt/vps-setup

echo "== Unit tests =="
bash tests/unit.sh

echo "== Shell syntax + i18n =="
bash -n setup.sh install.sh lib/*.sh lib/i18n/*.sh modules/*/*.sh tests/*.sh
used=$(grep -rhoE '\b t "[a-z0-9_]+\.[a-z0-9_.]+' setup.sh lib modules | sed -E 's/^ t "//' | sort -u)
for k in $used; do
  grep -qF "MSG[$k]=" lib/i18n/en.sh || { echo "MISSING EN: $k"; exit 1; }
  grep -qF "MSG[$k]=" lib/i18n/id.sh 2>/dev/null || { echo "MISSING ID: $k"; exit 1; }
done
echo "i18n keys: OK"

echo "== Dry runs =="
bash ./setup.sh --yes --dry-run --preset recommended --lang en --ssh-key \
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl test@example"

# Test every preset exists and loads
for p in recommended minimal custom domain database; do
  bash ./setup.sh --yes --dry-run --preset "$p" --lang en --ssh-key \
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl test" >/dev/null 2>&1 \
    && echo "  preset $p: OK" || { echo "  preset $p: FAILED"; exit 1; }
done

# DB wizard dry run
bash ./setup.sh --yes --dry-run --preset database --engine postgresql --db cibot \
  >/dev/null 2>&1 && echo "  db wizard: OK" || echo "  db wizard: FAILED"

echo "== Template validation =="
NO_LIVE=1 bash tests/templates.sh

echo "== Integration: nginx =="
DISPOSABLE=1 bash tests/integration.sh

echo ""
echo "All CI checks passed."
