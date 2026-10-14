# Security policy

vps-setup runs as root on servers that face the internet, so security reports are welcome and
taken seriously.

## Reporting a vulnerability

**Please do not open a public issue.** Report privately through GitHub's
**Security → Report a vulnerability** form on this repository. If that form is not available,
contact the maintainer through the [@Orlinkzz GitHub profile](https://github.com/Orlinkzz).

Please include:
- what an attacker can do, and under which conditions (for example "a local user can …", "a visitor
  of a site created by the domain wizard can …");
- the distro and version, the vps-setup version (`vps-setup --version`) and the options you used;
- steps to reproduce, or the relevant part of the generated config.

You will get an answer within a week. Please allow time for a fix and a release before you disclose
the issue publicly; you will be credited in the changelog unless you prefer not to be.

## Scope

In scope: everything in this repository, including the generated web server, firewall, SSH,
database and fail2ban configuration, the installer (`install.sh`) and the scripts it installs
(`vps-setup-backup`, `vps-setup-health`, `vps-setup-cloudflare-ips`).

Out of scope: vulnerabilities in the packages the tool installs (report those to their projects), and
problems that need an attacker who is already root on the server.

## Supported versions

Only the latest release and `main` receive fixes. Run `sudo vps-setup --update` to update.

## Verifying what you install

Every release lists the SHA256 of its archive. Install with both the tag and the checksum:

```bash
curl -fsSL https://raw.githubusercontent.com/orlinkzz/vps-setup/vX.Y.Z/install.sh \
  | sudo VPS_SETUP_REF=vX.Y.Z VPS_SETUP_SHA256=<sha256 from the release notes> bash
```

For the strictest setup, review the code and pin a full commit SHA instead of a tag.
