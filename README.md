# VPS Setup

Interactive, beginner-friendly setup for a fresh Linux server.
Pick what you want from a menu, answer a few simple questions, review, and go.

> **Status:** Phase 1 of 6 — Ubuntu 22.04 / 24.04. More software and more distros are coming (see [Roadmap](#roadmap)).

## Quick start

On a **fresh** Ubuntu server, as root or with sudo:

```bash
curl -fsSL https://raw.githubusercontent.com/orlinkzz/vps-setup/main/install.sh | sudo bash
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
| `--preset NAME` | `recommended`, `minimal` or `custom` (skips the first menu) |
| `--lang en\|id` | Interface language |
| `--dry-run` | Show what would happen, change nothing (works without root) |
| `-y`, `--yes` | Non-interactive, accept defaults (requires `--preset`) |
| `--ssh-key "KEY"` | Public SSH key for the admin user (handy with `--yes`) |

```bash
sudo ./setup.sh --dry-run                     # preview only
sudo ./setup.sh --lang id                     # Bahasa Indonesia
sudo ./setup.sh --yes --preset recommended --ssh-key "ssh-ed25519 AAAA..."
```

## What Phase 1 can do

| Group | Feature |
|---|---|
| System | Update & base tools · Timezone · Hostname (optional) · Swap file |
| Access | Non-root admin user (SSH key + sudo) · SSH hardening (root login off, key-only login, optional custom port) |
| Security | UFW firewall · Fail2ban · Automatic security updates |

Presets: **recommended** (everything except hostname), **minimal** (basics), **custom** (start from defaults).
Every preset opens a checklist, so you can always tick/untick items.

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
tests/                 unit + smoke tests
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
bash tests/unit.sh       # validators, idempotent write_file
bash tests/dry-run.sh    # syntax, i18n key coverage, full non-interactive dry run
shellcheck -x -s bash setup.sh lib/*.sh modules/*/*.sh
```

## Roadmap

| Phase | Scope |
|---|---|
| 1 ✅ | Framework, menus, i18n, system + access + security |
| 2 | Web servers (Nginx, Caddy, Apache), Certbot, "add a domain" wizard |
| 3 | Databases (PostgreSQL, MySQL/MariaDB, Redis) with RAM-based tuning, create DB/user wizard |
| 4 | Runtimes (PHP-FPM, Composer, Node, Bun, Go, Python, Docker, FrankenPHP) |
| 5 | Ops: DB backups with rotation, monitoring, Nginx fail2ban jails |
| 6 | Uninstall/rollback, CI, docs, more distros (Debian, AlmaLinux/Rocky) |

## License

MIT — see [LICENSE](LICENSE). Replace `orlinkzz` in `install.sh` / this README with your GitHub username, and `Orlinkzz` in `LICENSE`.
