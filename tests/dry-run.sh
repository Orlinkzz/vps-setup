#!/usr/bin/env bash
# shellcheck disable=SC2015  # in the checks below the || branch is the failure report; it never runs after a success
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

echo "== en.sh and id.sh define the same keys =="
keys() { grep -oE '^MSG\[[^]]+\]' "$1" | sort -u; }
if ! diff <(keys lib/i18n/en.sh) <(keys lib/i18n/id.sh) >/tmp/vps-keys.diff; then
  echo "KEY MISMATCH (< only in en.sh, > only in id.sh):"; cat /tmp/vps-keys.diff; fail=1
fi

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
# The fake module has to go into the module set that setup.sh loads on THIS distro.
fam=$(. /etc/os-release && case "$ID" in rocky|rhel|centos) echo almalinux ;; *) echo "$ID" ;; esac)
[[ -d modules/$fam ]] || fam=ubuntu
ztest=modules/$fam/99-ztest.sh
cat > "$ztest" <<'EOT'
register_feature ztest test on
run_ztest() { CFG[ztest]=from-subshell; }
notes_ztest() { echo "ZTEST_VALUE=${CFG[ztest]:-MISSING}"; }
EOT
echo ztest > presets/_z.list
bash ./setup.sh --yes --dry-run --preset _z --lang en >/tmp/vps-dry-z.out 2>&1
grep -q "ZTEST_VALUE=from-subshell" /tmp/vps-dry-z.out \
  || { echo "REGRESSION: CFG lost after run_<feature>"; fail=1; }
rm -f "$ztest" presets/_z.list

echo "== dry run: minimal (id) =="
bash ./setup.sh --yes --dry-run --preset minimal --lang id >/tmp/vps-dry2.out 2>&1 \
  || { echo "dry run FAILED: minimal (id)"; tail -n 15 /tmp/vps-dry2.out; fail=1; }

echo "== uninstall --dry-run changes nothing and finishes =="
bash lib/uninstall.sh --dry-run >/tmp/vps-uninst.out 2>&1 && grep -q "^Done\." /tmp/vps-uninst.out \
  && ! grep -q "^  removed: " /tmp/vps-uninst.out \
  || { echo "uninstall dry run FAILED"; tail -n 15 /tmp/vps-uninst.out; fail=1; }

printf 'webserver\nadd_domain\n' > presets/_wd.list
printf 'webserver\ncloudflare\n' > presets/_cf.list
trap 'rm -f presets/_wd.list presets/_cf.list' EXIT
echo "== dry run: every web server x site type =="
for ws in nginx apache caddy; do
  for ty in static spa proxy laravel php wordpress redirect; do
    bash ./setup.sh --yes --dry-run --preset _wd --lang en --webserver "$ws" --email me@example.com \
      --domain "t-$ty.example.com" --site-type "$ty" --port 3000 --redirect-to https://example.org \
      >/tmp/vps-dry3.out 2>&1 || { echo "dry run FAILED: $ws/$ty"; tail -n 15 /tmp/vps-dry3.out; fail=1; }
  done
done

echo "== dry run: app service (proxy --app-cmd), Laravel workers, --no-workers =="
bash ./setup.sh --yes --dry-run --preset _wd --lang en --webserver nginx --domain app.example.com \
  --site-type proxy --port 3000 --app-cmd 'npm start' --hsts >/tmp/vps-dry5.out 2>&1 \
  && grep -q "write /etc/systemd/system/app-app.example.com.service" /tmp/vps-dry5.out \
  && grep -q "systemctl enable app-app.example.com.service" /tmp/vps-dry5.out \
  || { echo "dry run FAILED: proxy --app-cmd"; tail -n 15 /tmp/vps-dry5.out; fail=1; }
bash ./setup.sh --yes --dry-run --preset _wd --lang en --webserver nginx --domain lv.example.com \
  --site-type laravel >/tmp/vps-dry5.out 2>&1 \
  && grep -q "enable --now laravel-lv.example.com-queue.service laravel-lv.example.com-schedule.timer" /tmp/vps-dry5.out \
  || { echo "dry run FAILED: laravel workers"; tail -n 15 /tmp/vps-dry5.out; fail=1; }
bash ./setup.sh --yes --dry-run --preset _wd --lang en --webserver nginx --domain lv.example.com \
  --site-type laravel --no-workers >/tmp/vps-dry5.out 2>&1 && ! grep -q "laravel-lv" /tmp/vps-dry5.out \
  || { echo "dry run FAILED: laravel --no-workers"; tail -n 15 /tmp/vps-dry5.out; fail=1; }
bash ./setup.sh --yes --dry-run --preset _wd --lang en --webserver nginx --domain bad.example.com \
  --site-type proxy --app-cmd "echo 'x'" >/tmp/vps-dry5.out 2>&1
grep -q "single quotes" /tmp/vps-dry5.out && ! grep -q "app-bad.example.com" /tmp/vps-dry5.out \
  || { echo "REGRESSION: an --app-cmd with single quotes must be refused"; tail -n 10 /tmp/vps-dry5.out; fail=1; }

echo "== dry run: Cloudflare real IP (nginx, apache; caddy must be refused, not dropped silently) =="
for ws in nginx apache; do
  bash ./setup.sh --yes --dry-run --preset _cf --lang en --webserver "$ws" >/tmp/vps-dry4.out 2>&1 \
    && grep -q "vps-setup-cloudflare-ips --server $ws" /tmp/vps-dry4.out \
    || { echo "dry run FAILED: cloudflare/$ws"; tail -n 15 /tmp/vps-dry4.out; fail=1; }
done
bash ./setup.sh --yes --dry-run --preset _cf --lang en --webserver caddy --email me@example.com >/tmp/vps-dry4.out 2>&1
grep -q "Cloudflare support needs Nginx or Apache" /tmp/vps-dry4.out && grep -q "Skipped: Cloudflare" /tmp/vps-dry4.out \
  || { echo "REGRESSION: cloudflare + caddy should be refused with an explanation"; tail -n 10 /tmp/vps-dry4.out; fail=1; }

exit $fail
