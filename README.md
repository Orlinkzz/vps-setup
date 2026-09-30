# VPS Setup

Interactive, beginner-friendly setup for a fresh Linux server.
Pick what you want from a menu, answer a few simple questions, review, and go.

> **Status:** Phase 2 of 6 — Ubuntu 22.04 / 24.04. More software and more distros are coming (see [Roadmap](#roadmap)).

## Quick start

On a **fresh** Ubuntu server, as root or with sudo:

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/vps-setup/main/install.sh | sudo bash
```

Prefer to read the code first? (Recommended.)

```bash
git clone https://github.com/OWNER/vps-setup.git
cd vps-setup
sudo ./setup.sh
```

The interface is **English by default**; you can pick **Bahasa Indonesia** on the first screen or with `--lang id`.

## Options

| Option | Meaning |
|---|---|
| `--preset NAME` | `recommended`, `minimal` or `custom` (skips the first menu) |
| `--lang en\|id` | Interface language |
| `--dry-run` | Show what would happen, change nothing (works without root) |
| `-y`, `--yes` | Non-interactive, accept defaults (requires `--preset`) |
| `--ssh-key "KEY"` | Public SSH key for the admin user (handy with `--yes`) |
| `--add-domain` | Jump straight to the "add a website / domain" wizard |
| `--webserver NAME` | With `--yes`: `nginx` (default), `caddy` or `apache` |
| `--email ADDRESS` | Email for Let's Encrypt (handy with `--yes`) |
| `--domain`, `--site-type`, `--port`, `--redirect-to` | With `--yes --preset domain`: describe the site to add |

```bash
sudo ./setup.sh --dry-run                     # preview only
sudo ./setup.sh --lang id                     # Bahasa Indonesia
sudo ./setup.sh --yes --preset recommended --ssh-key "ssh-ed25519 AAAA..."
sudo ./setup.sh --add-domain                  # add another website later
sudo ./setup.sh --yes --preset domain --domain app.example.com --site-type proxy --port 3000
```

## What it can do so far

| Group | Feature |
|---|---|
| System | Update & base tools · Timezone · Hostname (optional) · Swap file |
| Access | Non-root admin user (SSH key + sudo) · SSH hardening (root login off, key-only login, optional custom port) |
| Security | UFW firewall · Fail2ban · Automatic security updates |
| Web | Web server (**Nginx**, **Caddy** or **Apache**) · Free HTTPS with Certbot · **Add a website / domain** wizard |

Presets: **recommended** (everything except hostname and the domain wizard), **minimal** (basics), **custom** (start from defaults), **domain** (only the domain wizard).
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

## Safety by design

- **Anti-lockout for SSH.** Root/password login is only disabled when a sudo user with a working SSH key exists (or is being created in the same run). Otherwise the step is skipped with an explanation.
- **Firewall never cuts you off.** The real SSH port is always allowed before UFW is enabled; a port change is opened in UFW *before* SSH moves.
- **Dry run.** `--dry-run` prints every command and file write without executing them.
- **Idempotent.** Safe to run again; finished work is detected and skipped. Files are only rewritten when content changes, and replaced files are backed up to `/var/backups/vps-setup/`.
- **Logged.** Everything is written to `/var/log/vps-setup.log` (passwords are never logged).
- **Review before changes.** A summary screen lists exactly what will run.

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
├── modules/ubuntu/
│   ├── 00-system.sh        # update, timezone, hostname, swap
│   ├── 10-user-ssh.sh      # user deploy, SSH hardening
│   ├── 20-security.sh      # UFW, fail2ban, auto-update
│   ├── 30-webserver.sh     # Nginx / Caddy / Apache
│   ├── 40-database.sh      # PostgreSQL / MySQL / MariaDB / Redis
│   ├── 50-runtime.sh       # PHP, Node, Bun, Go, Python, Docker
│   ├── 60-ssl.sh           # Certbot + wizard tambah domain
│   └── 70-ops.sh           # backup DB, logrotate, monitoring
├── presets/                # daftar modul per preset
├── templates/              # config nginx, postgres, dll.
├── docs/                   # panduan pemula (ID/EN)
└── tests/                  # shellcheck + uji di container Ubuntu 22/24
```

## Layout

```
setup.sh               entry point + menus
install.sh             curl | bash bootstrap
lib/common.sh          logging, run/dry-run, write_file, validators, feature registry
lib/os.sh              OS detection, package manager / service abstraction (apt today)
lib/ui.sh              whiptail wrappers (all return defaults with --yes)
lib/i18n/{en,id}.sh    all user-visible text
modules/ubuntu/*.sh    one file per group of features
presets/*.list         feature ids per preset
templates/             web server configs (nginx, apache, caddy) and placeholder pages
tests/                 unit, smoke, template and integration tests
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
bash tests/dry-run.sh     # syntax, i18n key coverage, dry runs (all servers x all site types)
bash tests/templates.sh   # every template validated by nginx -t / apache2 -t / caddy validate,
                          # plus live HTTP checks on nginx (needs root; skips missing servers)
DISPOSABLE=1 bash tests/integration.sh   # real (non-dry-run) nginx + apache flow, run twice.
                                         # DESTRUCTIVE: only inside a throw-away container/VM
shellcheck -x -s bash setup.sh install.sh lib/*.sh lib/i18n/*.sh modules/*/*.sh tests/*.sh
```

## Roadmap

| Phase | Scope |
|---|---|
| 1 ✅ | Framework, menus, i18n, system + access + security |
| 2 ✅ | Web servers (Nginx, Caddy, Apache), Certbot, "add a domain" wizard, site templates |
| 3 | Databases (PostgreSQL, MySQL/MariaDB, Redis) with RAM-based tuning, create DB/user wizard |
| 4 | Runtimes (PHP-FPM, Composer, Node, Bun, Go, Python, Docker, FrankenPHP) |
| 5 | Ops: DB backups with rotation, monitoring, Nginx fail2ban jails |
| 6 | Uninstall/rollback, CI, docs, more distros (Debian, AlmaLinux/Rocky) |

## License

MIT — see [LICENSE](LICENSE). Replace `OWNER` in `install.sh` / this README with your GitHub username, and `<YOUR NAME>` in `LICENSE`.
