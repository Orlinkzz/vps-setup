#!/usr/bin/env bash
# Smoke tests: syntax, message-key coverage, and a full non-interactive dry run.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
fail=0

echo "== syntax =="
for f in setup.sh install.sh lib/*.sh lib/i18n/*.sh modules/*/*.sh tests/*.sh; do
  bash -n "$f" || { echo "SYNTAX ERROR: $f"; fail=1; }
done

echo "== message keys used but not defined in en.sh =="
used=$(grep -rhoE '\bt "?[a-z0-9_]+\.[a-z0-9_.]+' setup.sh lib modules | sed -E 's/^t "?//' | grep -v '\.$' | sort -u)
for k in $used; do
  grep -qF "MSG[$k]=" lib/i18n/en.sh || { echo "MISSING: $k"; fail=1; }
done

echo "== dry run: recommended =="
bash ./setup.sh --yes --dry-run --preset recommended --lang en --ssh-key \
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl test@example" \
  >/tmp/vps-dry.out 2>&1 || { echo "dry run FAILED"; tail -n 30 /tmp/vps-dry.out; fail=1; }

# Regresi: fitur preset tidak boleh gugur diam-diam (mis. nginx_jails saat nginx baru dipasang di run yang sama)
# shellcheck disable=SC2015  # the || branch is the failure report, it never runs after a success
grep -q "Nginx fail2ban jails" /tmp/vps-dry.out && ! grep -q "^! Skipped:" /tmp/vps-dry.out \
  || { echo "REGRESSION: a selected feature was dropped"; grep "Skipped" /tmp/vps-dry.out; fail=1; }

# Regresi: nilai CFG yang diisi di run_<fitur> (subshell) harus sampai ke catatan akhir
echo "== CFG survives the feature subshell =="
cat > modules/ubuntu/99-ztest.sh <<'EOT'
register_feature ztest test on
run_ztest() { CFG[ztest]=from-subshell; }
notes_ztest() { echo "ZTEST_VALUE=${CFG[ztest]:-MISSING}"; }
EOT
echo ztest > presets/_z.list
bash ./setup.sh --yes --dry-run --preset _z --lang en >/tmp/vps-dry-z.out 2>&1
grep -q "ZTEST_VALUE=from-subshell" /tmp/vps-dry-z.out \
  || { echo "REGRESSION: CFG lost after run_<feature>"; fail=1; }
rm -f modules/ubuntu/99-ztest.sh presets/_z.list

echo "== dry run: minimal (id) =="
bash ./setup.sh --yes --dry-run --preset minimal --lang id >/tmp/vps-dry2.out 2>&1 || true

printf 'webserver\nadd_domain\n' > presets/_wd.list
trap 'rm -f presets/_wd.list' EXIT
echo "== dry run: every web server x site type =="
for ws in nginx apache caddy; do
  for ty in static spa proxy laravel php wordpress redirect; do
    bash ./setup.sh --yes --dry-run --preset _wd --lang en --webserver "$ws" --email me@example.com \
      --domain "t-$ty.example.com" --site-type "$ty" --port 3000 --redirect-to https://example.org \
      >/tmp/vps-dry3.out 2>&1 || { echo "dry run FAILED: $ws/$ty"; tail -n 15 /tmp/vps-dry3.out; fail=1; }
  done
done

exit $fail
