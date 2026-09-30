# Getting started with your first VPS

So you rented a Linux server (a "VPS") from a provider like DigitalOcean, Linode, Vultr, or
any other. Now what? This guide walks you through the first steps to make it safe and usable.

---

## 1. Log in for the first time

Your provider gave you an IP address and a root password (or SSH key). Connect from your
terminal:

```bash
ssh root@<YOUR_SERVER_IP>
```

Example: `ssh root@203.0.113.10`

The first time you connect you'll be asked to confirm the server's fingerprint — type `yes`.

> **Windows users:** open PowerShell or Windows Terminal. If `ssh` is not recognised,
> install it from Settings → Apps → Optional features → Add "OpenSSH Client".

## 2. Download and run VPS Setup

```bash
curl -fsSL https://raw.githubusercontent.com/orlinkzz/vps-setup/main/install.sh | sudo bash
```

This downloads the tool and opens a menu. If you prefer to inspect the code first:

```bash
git clone https://github.com/orlinkzz/vps-setup.git
cd vps-setup
sudo ./setup.sh
```

## 3. Follow the menus

**Choose a starting point:**

- **Recommended** — best for most people. Installs updates, a secure user, firewall, a web
  server, PostgreSQL, Redis, Python, and more.
- **Minimal** — just the essentials: updates, swap, a user, and a firewall.
- **Custom** — pick everything yourself.

**Choose features:** you can tick or untick each item. Press SPACE to tick/untick, ENTER to
continue. Hover over an item to read what it does.

**Answer questions:** the tool asks simple questions like "what should the username be?"
Just type your answer.

**Review:** a summary shows exactly what will happen. If it looks right, confirm. Nothing
changes before this point.

**Wait:** the tool runs each step. Most steps finish in seconds; package installation may
take a few minutes. Do not close the terminal.

## 4. What just happened?

When the tool finishes you'll see a summary:

```
✓  System is up to date
✓  Swap file created
✓  User "deploy" is ready
✓  SSH hardening applied (port 22)
✓  Firewall enabled
✓  PostgreSQL installed
✓  Nginx installed
…
```

Your server now has:
- A non-root admin user (you log in as `deploy` instead of `root`)
- SSH key-only login (more secure than passwords)
- A firewall that blocks everything except SSH and websites
- A web server ready to serve your sites
- A database server if you chose one

## 5. Log in as your new user

Open a **new terminal window** (keep the old one open until you test):

```bash
ssh deploy@<YOUR_SERVER_IP>
```

If that works, you're all set. The old root session can be closed.

## 6. What's next?

- **Add a website:** run `sudo ./setup.sh --add-domain` and follow the wizard.
- **Create a database:** run `sudo ./setup.sh --add-database`.
- **Check server health:** run `sudo vps-setup-health`.
- **Run the tool again:** it's safe — finished steps are automatically skipped.
- **See the full log:** everything is written to `/var/log/vps-setup.log`.

## Tips for beginners

- **Keep your server updated:** the tool enables automatic security updates. You don't need
  to check for updates manually.
- **Use the dry-run flag first:** `sudo ./setup.sh --dry-run` shows you everything without
  changing anything.
- **Your cloud provider's firewall:** if your VPS provider has its own firewall panel
  ("security groups"), open ports 80 (HTTP) and 443 (HTTPS) there too.
- **Need help?** Check the log file at `/var/log/vps-setup.log` — it records every command.
