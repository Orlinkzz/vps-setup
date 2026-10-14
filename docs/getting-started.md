# Getting started with your first VPS

So you rented a Linux server (a "VPS") from a provider like DigitalOcean, Linode, Vultr, or
any other. Now what? This guide walks you through the first steps to make it safe and usable.

---

## 1. Make an SSH key on your own computer (do this first)

VPS Setup turns off password logins over SSH, because passwords get guessed by bots all day.
From then on you log in with an **SSH key**: a pair of files on your computer. Make one now, before
you touch the server:

```bash
ssh-keygen -t ed25519 -C "my-laptop"
```

Press Enter to accept the default location. A passphrase is optional but recommended.
This creates two files in `~/.ssh/` (on Windows: `C:\Users\<you>\.ssh\`):

- `id_ed25519` — the **private** key. Never share it, never upload it anywhere.
- `id_ed25519.pub` — the **public** key. This one goes to the server.

Show the public key so you can copy it:

```bash
cat ~/.ssh/id_ed25519.pub
```

It is one line that starts with `ssh-ed25519 AAAA...`. VPS Setup asks you to paste it.

> **Windows users:** run these commands in PowerShell or Windows Terminal. If `ssh` is not
> recognised, install it from Settings → Apps → Optional features → Add "OpenSSH Client".

## 2. Log in for the first time

Your provider gave you an IP address and a root password (or already added your key). Connect:

```bash
ssh root@<YOUR_SERVER_IP>
```

Example: `ssh root@203.0.113.10`

The first time you connect you'll be asked to confirm the server's fingerprint — type `yes`.

## 3. Download and run VPS Setup

```bash
curl -fsSL https://raw.githubusercontent.com/orlinkzz/vps-setup/main/install.sh | sudo bash
```

This installs the tool in `/opt/vps-setup`, adds the command `vps-setup`, and opens the menu.
From then on you can start it from anywhere with `sudo vps-setup`.

Prefer to read the code first? (Recommended.)

```bash
git clone https://github.com/orlinkzz/vps-setup.git
cd vps-setup
sudo ./setup.sh
```

(In a cloned copy, use `sudo ./setup.sh` wherever this guide says `sudo vps-setup`.)

## 4. Follow the menus

**Choose a starting point:**

- **Recommended** — best for most people. Installs updates, a secure user, firewall, a web
  server, PostgreSQL, Redis, Python, and more.
- **Minimal** — just the essentials: updates, swap, a user, and a firewall.
- **Custom** — pick everything yourself.
- **Add a website**, **Create a database**, **Behind Cloudflare** — single tasks for later.
- **Manage this server** — health check, list or remove websites and databases.

**Choose features:** you can tick or untick each item. Press SPACE to tick/untick, ENTER to
continue.

**Answer questions:** the tool asks simple questions like "what should the username be?" and
"paste your public SSH key" (from step 1).

**Review:** a summary shows exactly what will happen. If it looks right, confirm. Nothing
changes before this point.

**Wait:** the tool runs each step. Most steps finish in seconds; package installation may
take a few minutes. Do not close the terminal.

## 5. What just happened?

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

## 6. Log in as your new user — before you close anything

Open a **new terminal window** and keep the old one open until this works:

```bash
ssh deploy@<YOUR_SERVER_IP>
# if you moved SSH to another port:
ssh -p 2222 deploy@<YOUR_SERVER_IP>
```

If that works, you're all set and the old root session can be closed. If it does not, use the
old session to fix it (see *Troubleshooting* below) — that is why you kept it open.

## 7. What's next?

| Task | Command |
|---|---|
| Add a website | `sudo vps-setup --add-domain` |
| Create a database | `sudo vps-setup --add-database` |
| Is everything healthy? | `sudo vps-setup --doctor` |
| What did I create? | `sudo vps-setup --list-sites` / `--list-databases` |
| Remove a website | `sudo vps-setup --remove-domain old.example.com` (asks first) |
| Update the tool | `sudo vps-setup --update` |
| Undo what it configured | `sudo vps-setup --uninstall` (packages and data stay) |

- **Run the tool again whenever you like:** finished steps are skipped automatically.
- **See the full log:** everything is written to `/var/log/vps-setup.log`.

## Troubleshooting

**I'm locked out of SSH.**
Every provider has a web console ("Console", "Recovery", "VNC") in its dashboard that works
without SSH. Log in there as root, then:
- check the configuration: `sshd -t` (no output means it is valid)
- see which port SSH uses: `sshd -T | grep ^port`
- make sure the firewall allows it: `ufw status` (Ubuntu/Debian) or `firewall-cmd --list-all` (AlmaLinux/Rocky)
- check that your public key is in `/home/deploy/.ssh/authorized_keys`
- `sudo vps-setup --doctor` points at the usual causes.

**The HTTPS certificate was not created.**
Let's Encrypt can only issue a certificate when the domain already points at this server.
Check with `getent hosts example.com`: the address must be your server's IP. After a DNS change
it can take a while to spread. Then run `sudo vps-setup --add-domain` again for that domain.
Too many attempts hit Let's Encrypt's rate limit; wait an hour before retrying.

**"Port 80 is already in use".**
Another web server or app is running. The web server step asks what to do (stop it, continue,
or skip). `sudo ss -ltnp 'sport = :80'` shows who is using it.

**A step failed.**
The summary marks it with ✗. Read the last lines of `/var/log/vps-setup.log`, fix the cause, and
run the tool again: it continues where it stopped.

## Tips for beginners

- **Keep your server updated:** the tool enables automatic security updates. You don't need
  to check for updates manually.
- **Use the dry-run flag first:** `sudo vps-setup --dry-run` shows you everything without
  changing anything.
- **Your cloud provider's firewall:** if your VPS provider has its own firewall panel
  ("security groups"), open ports 80 (HTTP) and 443 (HTTPS) there too, and your SSH port.
- **Docker:** published container ports listen on `127.0.0.1` only. To expose one on purpose,
  write `-p 0.0.0.0:8080:80` and open the port in the firewall.
