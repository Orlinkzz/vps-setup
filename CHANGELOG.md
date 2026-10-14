# Changelog

All notable changes to vps-setup. Versions follow [SemVer](https://semver.org/); the version is
`VERSION` in `setup.sh`, and a release is published by pushing the tag `vX.Y.Z` (see
`.github/workflows/release.yml`).

## [0.7.0] — unreleased

### Fixed — could break a server or lock you out
- **Uninstall no longer takes websites down.** It used to delete the Nginx snippets that every site
  created by the domain wizard includes, so the next reload or reboot failed. Snippets still in use are
  now kept, and every web server config is tested before it is reloaded.
- **Uninstall and SSH:** the SSH drop-in is only removed when `sshd -t` accepts the result, port 22 is
  opened in the firewall first when SSH was on a custom port, and SSH is reloaded. A NOPASSWD sudo rule is
  kept for a user without a password. Uninstall now requires root, has `--dry-run`, only reports files
  that really existed, and restores package-owned files (dnf-automatic, Redis, fail2ban) from backup
  instead of deleting them.
- **AlmaLinux/Rocky: moving SSH to another port** registers the port with SELinux (`semanage`) and opens
  it in firewalld before SSH restarts. Before, sshd could not bind the new port.
- **WordPress on Nginx:** PHP files in `uploads/` could be executed (the deny block came after the PHP
  block, and Nginx uses the first matching regex).
- **MySQL on Ubuntu** no longer fails to start after a restart (`query_cache_type` was removed in MySQL 8).
  The root password uses `caching_sha2_password` (`mysql_native_password` is gone in MySQL 8.4+).
- **Database and Redis tuning is applied right away:** services are restarted after their config is
  written (before, the restart never happened and tuning waited for the next reboot).
- **Redis** keeps its data directory, pid and log file in the rewritten config.
- **`--dry-run` changed the system** in a few places (`install -d` for PostgreSQL, MySQL, MariaDB,
  Nginx/httpd on RHEL and the backup folder). It no longer does.

### Fixed — AlmaLinux / Rocky
- Interactive menus work: `whiptail` (package `newt`) is installed with dnf.
- Website folders use the web server's group (`nginx`, `apache`, `caddy`) instead of `www-data`.
- PHP and WordPress sites on Nginx: vps-setup installs `snippets/fastcgi-php.conf`, which only Debian ships.
- Apache sites: `${APACHE_LOG_DIR}` is defined (`/var/log/httpd`).
- Caddy is installed from its official COPR repository instead of the Debian repository.
- PHP: the newest AppStream module stream is enabled (the default streams are end-of-life), php-fpm is
  started, and its socket is detected.
- Nginx reverse proxy: `httpd_can_network_connect` is enabled for Nginx too (SELinux returned 502).
- EL8's stock `nginx.conf` server no longer claims `default_server` next to ours.
- PostgreSQL: `127.0.0.1` and `::1` use `scram-sha-256` instead of `ident`, so apps can log in with a password.
- MariaDB listens on `127.0.0.1` only; on EL8 the empty root password, anonymous users and the `test`
  database are removed (root's new password is kept in `/root/.my.cnf`, mode 600).
- dnf-automatic honours the "reboot automatically" answer on EL9 and keeps a backup of its config.
- Backups and the health check use distro-neutral scripts (`runuser`, service names per distro).

### Fixed — other
- Apache reverse proxy sends the real scheme and port (`X-Forwarded-Proto` was hardcoded to `http`, which
  caused redirect loops after HTTPS).
- Ubuntu 22.04 defaults to PHP 8.3 (8.1 is end-of-life); the ondrej/php PPA is only added when the
  system does not offer the chosen version. Debian no longer asks for a PHP version it ignores.
- Behind Cloudflare, Apache logs the visitor (`%a`) instead of Cloudflare's address.
- Caddy + Laravel only executes `public/index.php`, like the Nginx and Apache templates.
- `--list-databases` / `--drop-database` work without `sudo` installed (minimal Debian).
- Backups: a failed or partial dump is reported and never kept as a good `.sql.gz`; MySQL dumps use
  `--single-transaction`.
- `install.sh` cleans up its temporary directory.
- Help texts: the database wizard example used a non-existent `--user` flag; the PHP description showed
  an empty "(default: )"; `--yes` without `--preset` listed only four presets.

### Added
- **`vps-setup` command** (`/usr/local/bin/vps-setup`) after a curl install: `sudo vps-setup ...` works
  from any directory.
- **`--doctor`**: read-only health check (SSH and firewall, failed services, web server configs,
  certificates expiring within 21 days, backups, pending reboot).
- **`--update`** and **`--uninstall`** flags.
- Main menu: **Create a database**, **Behind Cloudflare** and **Manage this server** (health check,
  list/remove websites, list/drop databases).
- `install.sh`: optional `VPS_SETUP_SHA256` verification; a release workflow publishes the checksum.
- Only one run at a time (`flock`); Ctrl-C removes temporary files that may hold generated passwords.
- Docker: published container ports listen on `127.0.0.1` by default, because Docker's rules bypass
  UFW/firewalld.
- Backups and the nightly health snapshot run from systemd timers (minimal images have no cron).

### Tests and CI
- CI validates every template against real Nginx, Apache and Caddy, runs `tests/manage.sh`, and runs the
  non-destructive tests plus Nginx template checks in AlmaLinux 8/9, Rocky 8/9, Debian 12 and Ubuntu 22.04
  containers. These distro jobs now block the build (Debian 13 stays experimental).
- New checks: `en.sh` and `id.sh` define the same keys; the Indonesian dry run must succeed; uninstall
  `--dry-run`; the backup script with a failing dump; the global command, `--doctor`, `--update`, `--uninstall`.

### Docs
- Beginner guides (EN/ID): how to make an SSH key before key-only login is enabled, the `vps-setup`
  command, a command table, and troubleshooting (locked out of SSH, certificate not issued, port 80 busy).
- README: one layout section, firewall wording for UFW and firewalld, correct pinning syntax (the
  `v0.6.2` tag in the old example was never published), CHANGELOG and SECURITY policy.

## [0.6.2] and earlier

Not recorded in this file; see the git history.
