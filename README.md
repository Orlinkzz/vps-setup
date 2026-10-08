# VPS Setup

Interactive, beginner-friendly setup for a fresh Linux server.
Pick what you want from a menu, answer a few simple questions, review, and go.

> **Status:** Phase 6 of 6 — Ubuntu 22.04 / 24.04, Debian 12, AlmaLinux / Rocky 8 / 9. All phases complete: system, security, web, databases, runtimes, ops, uninstall, CI.

## Quick start

On a **fresh** Ubuntu 22.04 / 24.04, Debian 12 or AlmaLinux / Rocky 8 / 9 server, as root or with sudo:

```bash
curl -fsSL https://raw.githubusercontent.com/orlinkzz/vps-setup/main/install.sh | sudo bash
```

For a reproducible install, pin a release tag or (strictest) a full commit SHA. A commit SHA is
content-addressed, so what you download is exactly what you reviewed:

```bash
curl -fsSL https://raw.githubusercontent.com/orlinkzz/vps-setup/v0.6.2/install.sh | sudo VPS_SETUP_REF=v0.6.2 bash
```

Prefer to read the code first? (Recommended.)

```bash
git clone https://github.com/orlinkzz/vps-setup.git
cd vps-setup
sudo ./setup.sh
```

The interface is **English by default**; you can pick **Bahasa Indonesia** on the first screen or with `--lang id`.

## Options

| Option | Meaning |
|---|---|
| `--preset NAME` | `recommended`, `minimal`, `custom`, `domain`, `database` or `cloudflare` (skips the first menu) |
| `--lang en\|id` | Interface language |
| `--dry-run` | Show what would happen, change nothing (works without root) |
| `-y`, `--yes` | Non-interactive, accept defaults (requires `--preset`) |
| `--ssh-key "KEY"` | Public SSH key for the admin user (handy with `--yes`) |
| `--add-domain` | Jump straight to the "add a website / domain" wizard |
| `--add-database` | Jump straight to the "create a database / user" wizard |
| `--engine NAME` | With `--yes --preset database`: `postgresql` or `mysql` (default: postgresql) |
| `--db NAME` | With `--yes --preset database`: database name to create |
| `--db-user NAME` | With `--yes --preset database`: database user (defaults to `--db` value) |
| `--list-sites` | List the websites vps-setup created (domain, server, type, HTTPS, status), then exit |
| `--remove-domain DOMAIN` | Remove a website: its web server config, its Let's Encrypt certificate and (with `--purge-files`) its files |
| `--purge-files`, `--keep-cert` | With `--remove-domain`: move `/var/www/DOMAIN` out of the way / keep the certificate |
| `--list-databases` | List the PostgreSQL / MySQL databases, then exit |
| `--drop-database NAME` | Drop a database (a compressed dump is saved first); add `--db-user` to drop that user too, `--engine` if both engines are installed |
| `--webserver NAME` | With `--yes`: `nginx` (default), `caddy` or `apache` |
| `--email ADDRESS` | Email for Let's Encrypt (handy with `--yes`) |
| `--domain`, `--site-type`, `--port`, `--redirect-to` | With `--yes --preset domain`: describe the site to add |

```bash
sudo ./setup.sh --dry-run                     # preview only
sudo ./setup.sh --lang id                     # Bahasa Indonesia
sudo ./setup.sh --yes --preset recommended --ssh-key "ssh-ed25519 AAAA..."
sudo ./setup.sh --add-domain                  # add another website later
sudo ./setup.sh --yes --preset domain --domain app.example.com --site-type proxy --port 3000
sudo ./setup.sh --add-database               # create a database later
sudo ./setup.sh --yes --preset database --engine postgresql --db myapp
sudo ./setup.sh --list-sites                  # what did I create?
sudo ./setup.sh --remove-domain old.example.com            # asks first
sudo ./setup.sh --yes --remove-domain old.example.com --purge-files
sudo ./setup.sh --list-databases
sudo ./setup.sh --drop-database myapp --db-user myapp      # asks you to type the name
```

### Removing things safely

The removal commands are built so that a wrong command is recoverable:

- **Only what vps-setup created is touched.** A site config must carry the `Managed by vps-setup` marker; anything else is refused. Stock files (`ssl.conf`, `00-default.conf`, ...) are never listed or removed.
- **The web server is tested before it reloads.** If it rejects the configuration without the site, the old files are put back and nothing changes.
- **Files are moved, not deleted.** `--purge-files` moves `/var/www/DOMAIN` to `/var/backups/vps-setup/removed-sites/`. A copy of the removed config goes to `/var/backups/vps-setup/` too.
- **Certificates:** removed through `certbot delete`, unless another site still points at it (or you pass `--keep-cert`).
- **Databases are dumped first** (`/var/backups/vps-setup/dropped-databases/NAME.ENGINE.TIMESTAMP.sql.gz`, mode 600); if the dump fails nothing is dropped. Interactively you must type the database name to confirm. Only letters, digits and `_` are accepted as names, and system databases/users (`postgres`, `mysql`, ...) are refused. The user is dropped only when you pass `--db-user`.
- `--dry-run` shows every step without doing it.

## What it can do so far

| Group | Feature |
|---|---|
| System | Update & base tools · Timezone · Hostname (optional) · Swap file |
| Access | Non-root admin user (SSH key + sudo) · SSH hardening (root login off, key-only login, optional custom port) |
| Security | UFW firewall · Fail2ban · Automatic security updates |
| Databases | **PostgreSQL** · **MySQL/MariaDB** · **Redis** (all with RAM-based tuning) · **Create a database / user** wizard |
| Runtimes | **PHP-FPM** + Composer · **Node.js** · **Bun** · **Go** · **Python 3** · **Docker** + Compose · **FrankenPHP** |
| Ops | **DB backups** with rotation · **Health monitoring** (`vps-setup-health`) · **Nginx fail2ban jails** (http-auth, botsearch, bad-request; 404s are not counted, so normal visitors and crawlers are not banned) |
| Web | Web server (**Nginx**, **Caddy** or **Apache**) · Free HTTPS with Certbot · **Add a website / domain** wizard · **Cloudflare** real visitor IP (Nginx/Apache) |
| Platforms | **Ubuntu 22.04 / 24.04** · **Debian 12** · **AlmaLinux / Rocky 8 / 9** (apt and dnf). Only releases that still get security updates are supported; end-of-life releases such as Debian 11 are warned about, not tested |

Presets: **recommended** (everything except hostname and the domain wizard), **minimal** (basics), **custom** (start from defaults), **domain** (only the domain wizard), **database** (only the create-database wizard).
Every preset opens a checklist, so you can always tick/untick items.

## Websites and templates

The **domain wizard** asks for a domain, whether to also serve `www.`, and the kind of site, then writes a configuration from a template, **tests it with the server's own checker, and only then reloads**. If the test fails, the new files are removed and the running server is untouched. It can run as often as you like.

| Site type | For | Needs |
|---|---|---|
| `static` | HTML/CSS/JS files | – |
| `spa` | React / Vue / Svelte build output (client-side routing) | – |
| `proxy` | Node, Bun, Go, Python, FrankenPHP, Docker ... on `127.0.0.1:PORT` (WebSockets included) | – |
| `laravel` | Laravel (app in `/var/www/DOMAIN`, web root `public/`) | PHP-FPM |
| `php` | Generic PHP site | PHP-FPM |
| `wordpress` | WordPress (files in `/var/www/DOMAIN`, no PHP in uploads) | PHP-FPM |
| `redirect` | Permanent 301 to another domain/URL, path and query preserved | – |

All templates live in [`templates/`](templates/) and double as **reference configs** you can copy by hand:

```
templates/nginx/    global settings, catch-all, snippets/, sites/<type>.conf.tpl, reference/https-full.conf.tpl
templates/apache/   global settings, catch-all, sites/<type>.conf.tpl
templates/caddy/    Caddyfile.tpl (+ catch-all), sites/<type>.caddy.tpl
templates/html/     placeholder pages
```

Placeholders: `{{DOMAIN}}` `{{SERVER_NAMES}}` `{{SERVER_NAMES_COMMA}}` `{{SERVER_ALIAS_LINE}}` `{{ROOT}}` `{{UPSTREAM}}` `{{PHP_SOCKET_PATH}}` `{{REDIRECT_TARGET}}` `{{MAX_BODY}}` `{{MAX_BODY_BYTES}}`.

Good to know:
- **Unknown hostnames / direct IP access** show a friendly "Server is running" page (or, if you choose, the connection is closed). Nginx also refuses TLS handshakes for unknown names (nginx ≥ 1.19.4).
- **HTTPS:** Nginx/Apache use Certbot (`--redirect`, auto-renew timer); Caddy does it by itself. The wizard checks DNS first and warns instead of burning Let's Encrypt rate limits. Set `VPS_SETUP_LE_STAGING=1` to use test certificates.
- **PHP sites** can be created before PHP-FPM exists (they return 502 until Phase 4 installs it).
- **Dotfiles** (`.env`, `.git`, `.htaccess` ...) are never served; HSTS is left off until you decide to enable it.
- **IPv6-less servers** are detected and the `listen [::]` lines are left out automatically.
- Ubuntu's stock `nginx.conf` directives that would duplicate ours are commented out (a backup is kept in `/var/backups/vps-setup/`).

## Behind Cloudflare

If your sites use Cloudflare's proxy (orange cloud), the web server only sees Cloudflare's addresses, so
logs, fail2ban and your apps would all see the same few IPs. The **Cloudflare** feature
(`sudo ./setup.sh --preset cloudflare`, or tick it in the Web group) makes Nginx or Apache trust the
`CF-Connecting-IP` header **only for requests that come from Cloudflare's own ranges**, so nobody else can fake
it. The ranges come from `cloudflare.com/ips-v4` and `/ips-v6`; a list that fails validation is never used
(a built-in copy takes over), and a weekly systemd timer keeps them fresh. A config that the web server's own
tester rejects is rolled back automatically.

- Using a **Cloudflare Tunnel** (`cloudflared` on the same server)? Answer yes to the question and `127.0.0.1` is trusted too.
- fail2ban then sees real visitor IPs, but a firewall ban on your server cannot stop traffic that arrives *through*
  Cloudflare. Use Cloudflare's firewall rules to block.
- Refresh by hand: `sudo vps-setup-cloudflare-ips --server nginx` (or `apache`). Caddy is not supported yet.

## Safety by design

- **Anti-lockout for SSH.** Root/password login is only disabled when a sudo user with a working SSH key exists (or is being created in the same run). Otherwise the step is skipped with an explanation.
- **Firewall never cuts you off.** The real SSH port is always allowed before UFW is enabled; a port change is opened in UFW *before* SSH moves.
- **Dry run.** `--dry-run` prints every command and file write without executing them.
- **Idempotent.** Safe to run again; finished work is detected and skipped. Files are only rewritten when content changes, and replaced files are backed up to `/var/backups/vps-setup/`.
- **Logged.** Everything is written to `/var/log/vps-setup.log` (passwords are never logged).
- **Review before changes.** A summary screen lists exactly what will run.
- **Warns on unmaintained systems.** On an end-of-life release (for example Debian 11 or Ubuntu 20.04) it explains that the server cannot be kept secure and asks before going on (`--yes` only prints the warning).
- **Warns when it is not a real server.** Inside WSL, or without systemd, it asks before going on (`--yes` only prints the warning).
- **Port 80 already taken?** The web server step asks what to do: stop and disable that service, continue anyway, or skip the step. Nothing is stopped before the final review; with `--yes` the step is skipped.
- **Nothing gets dropped silently.** If a selected item cannot be installed (cancelled, or a requirement is missing) a screen lists it before anything runs. Items that depend on another item chosen in the same run (e.g. Nginx jails with Nginx) work together.
- **Secrets stay in files.** The generated MySQL root login is written to `/root/.my.cnf` (mode 600) and is not printed or logged.

> Your cloud provider may have its own firewall (security groups). Open the same ports there too.

## Structure Repo
```
vps-setup/
├── install.sh              # bootstrap (curl | bash)
├── setup.sh                # entry point + menu utama
├── lib/
│   ├── common.sh           # log, confirm, helper idempotent
│   ├── os.sh               # deteksi distro, abstraksi package manager
│   ├── ui.sh               # wrapper whiptail
│   └── i18n/{id,en}.sh     # teks UI dua bahasa
├── modules/
│   ├── ubuntu/             # 00-system … 70-ops (apt, ufw, apache2)
│   ├── debian/             # sama seperti Ubuntu; PHP tanpa PPA, MariaDB
│   └── almalinux/          # RHEL family: dnf, firewalld, httpd, wheel
├── presets/                # daftar modul per preset
├── templates/              # config nginx, apache, caddy, halaman HTML
├── docs/                   # panduan pemula (getting-started.md, memulai.md)
├── tests/                  # unit, dry-run, template, integration
├── .github/workflows/      # CI: shellcheck, i18n, dry-run, template, integration
└── lib/uninstall.sh        # rollback / uninstall
```

## Layout

```
setup.sh               entry point + menus
install.sh             curl | bash bootstrap
lib/common.sh          logging, run/dry-run, write_file, validators, feature registry
lib/os.sh              OS detection, package manager / service abstraction (apt + dnf)
lib/ui.sh              whiptail wrappers (all return defaults with --yes)
lib/i18n/{en,id}.sh    all user-visible text
lib/uninstall.sh       rollback: removes everything vps-setup created
modules/*/*.sh         one file per group of features, per distro family
presets/*.list         feature ids per preset
templates/             web server configs (nginx, apache, caddy), placeholder pages, the Cloudflare IP script
tests/                 unit, smoke, template and integration tests
docs/                  beginner guide (EN + ID)
.github/workflows/     CI pipeline
```

## Adding a feature

Inside a file in `modules/<distro>/`:

```bash
register_feature myfeature group on        # id, group, default on|off

prompt_myfeature() { ...; CFG[key]=value; }  # optional: ask questions, return 1 to skip
run_myfeature()    { pkg_install foo; ... }  # required: do the work (runs with set -e)
summary_myfeature(){ t sum.myfeature; }      # optional: line on the review screen
notes_myfeature()  { t note.myfeature; }     # optional: "next steps" after success
```

Then add `feat.myfeature.title` / `feat.myfeature.desc` (and any other keys) to **both** `lib/i18n/en.sh` and `lib/i18n/id.sh`, and list the id in the presets that should include it.
Use `run`, `run_sh`, `write_file`, `pkg_install`, `svc_enable_now` — they respect `--dry-run` and logging. Return `feature_skip "reason"` when there is nothing to do.

## Tests

```bash
bash tests/unit.sh        # validators, idempotent write_file
bash tests/features.sh    # preset parsing, features that depend on others, port-80 flow, fail2ban regex
bash tests/dry-run.sh     # syntax, i18n key coverage, dry runs (all servers x all site types)
bash tests/manage.sh      # list/remove sites, list/drop databases (stubs + temp dirs, no root, touches nothing real)
bash tests/templates.sh   # every template validated by nginx -t / apache2 -t / caddy validate,
                          # plus live HTTP checks on nginx (needs root; skips missing servers)
bash tests/cloudflare.sh  # Cloudflare real-IP script vs the real nginx / Apache config testers (needs root)
DISPOSABLE=1 bash tests/integration.sh   # real (non-dry-run) nginx + apache flow, run twice.
                                         # DESTRUCTIVE: only inside a throw-away container/VM
shellcheck -x -s bash setup.sh install.sh lib/*.sh lib/i18n/*.sh modules/*/*.sh tests/*.sh
```

CI runs the same checks on every push (see [`.github/workflows/ci.yml`](.github/workflows/ci.yml)).

## Uninstall

Removes every file and config vps-setup created. **Packages are not removed.**

```bash
sudo ./lib/uninstall.sh            # asks for confirmation
sudo ./lib/uninstall.sh --yes      # non-interactive
```

Replaced files are restored from `/var/backups/vps-setup/` if needed. A few things are
left alone deliberately (swap file, databases, users, packages, Bun in `/opt/bun`, the MySQL
root login in `/root/.my.cnf`, and a service that was stopped to free port 80) — the script prints
the exact commands for each.

Colors: the dialogs use a fixed palette. Set `NEWT_COLORS` to use your own, or
`VPS_SETUP_COLORS=default` for whiptail's built-in colors.

## Beginner guide

New to servers? [`docs/getting-started.md`](docs/getting-started.md) (English) and
[`docs/memulai.md`](docs/memulai.md) (Bahasa Indonesia) walk through the first login,
running the tool, and what to do next.

## Roadmap

| Phase | Scope |
|---|---|
| 1 ✅ | Framework, menus, i18n, system + access + security |
| 2 ✅ | Web servers (Nginx, Caddy, Apache), Certbot, "add a domain" wizard, site templates |
| 3 ✅ | Databases (PostgreSQL, MySQL/MariaDB, Redis) with RAM-based tuning, create DB/user wizard |
| 4 ✅ | Runtimes (PHP-FPM, Composer, Node, Bun, Go, Python, Docker, FrankenPHP) |
| 5 ✅ | Ops: DB backups with rotation, monitoring, Nginx fail2ban jails |
| 6 ✅ | Uninstall/rollback, CI, docs, more distros (Debian, AlmaLinux/Rocky) |

## License

MIT — see [LICENSE](LICENSE).
