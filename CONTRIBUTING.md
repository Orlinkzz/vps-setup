# Contributing Guide

Thanks for wanting to help improve **vps-setup**. This project exists so that anyone, including people touching a server for the first time, can set up a VPS safely. All contributions are welcome: bug reports, feature ideas, documentation fixes, translations, and pull requests.

## Table of contents

- [How to contribute](#how-to-contribute)
- [Reporting bugs](#reporting-bugs)
- [Suggesting features](#suggesting-features)
- [Setting up your development environment](#setting-up-your-development-environment)
- [Principles we hold to](#principles-we-hold-to)
- [Code style](#code-style)
- [Testing your changes](#testing-your-changes)
- [Pull request workflow](#pull-request-workflow)
- [Commit messages](#commit-messages)
- [Security](#security)

## How to contribute

1. **Check first** whether your topic already exists in [Issues](https://github.com/Orlinkzz/vps-setup/issues).
2. For bigger changes (new features, changes to the menu flow), **open an issue first** and discuss it before writing code. It saves you time.
3. For small fixes (typos, docs, obvious bugs), just send a pull request.

## Reporting bugs

Open a new issue and include:

- **Distro and version** (for example Ubuntu 24.04). Run `cat /etc/os-release`.
- **The command you ran**, including options (for example `sudo ./setup.sh --lang id`).
- **What you expected** and **what happened**.
- **A snippet of the log** from `/var/log/vps-setup.log`. Passwords are not logged, but still review it and remove sensitive data such as IPs or personal domain names before pasting.

If you can, reproduce the problem with `--dry-run` first to see whether it happens at the planning stage or during execution.

## Suggesting features

In your issue, explain:

- What problem it solves, and who it helps.
- Roughly how it would look in the menu, and what questions it needs to ask the user.
- What needs to be cleaned up on uninstall.

Good fits are features that are useful to most people with a fresh server and can be explained through simple questions.

## Setting up your development environment

1. Fork this repo, then clone your fork:

   ```bash
   git clone https://github.com/<your-username>/vps-setup.git
   cd vps-setup
   git checkout -b your-change-name
   ```

2. Get a **disposable test server**: a cheap VPS, a local VM, or a container. **Never test on a production server.**

3. Install [ShellCheck](https://www.shellcheck.net/) to lint the scripts:

   ```bash
   sudo apt install shellcheck
   ```

4. Run from your working copy, not from the install script:

   ```bash
   sudo ./setup.sh --dry-run
   ```

## Principles we hold to

This project changes configuration on other people's servers, so we are strict about the following. Pull requests are checked against this list.

- **Safe to re-run.** Running the script twice must not break anything. Files are only rewritten when their content actually changes.
- **Back up before replacing.** Any file that gets replaced must be backed up to `/var/backups/vps-setup/`.
- **Support `--dry-run`.** Every new step must be able to show what it would do without changing the system.
- **Reversible.** Anything you add must also be removed by `lib/uninstall.sh`, with original files restored from backup when needed.
- **Logged.** Important steps are written to `/var/log/vps-setup.log`. **Passwords and secrets must never be logged**, shown on screen, or passed as command arguments visible through `ps`. Send them through stdin with `run_stdin` (`lib/common.sh`) instead of `run`; `tests/secrets.sh` fails if one reaches a command line or the log. The one thing shown on screen is a password the tool generated for you (for example for a new database user), printed once at the end because that is the only way to hand it over.
- **Beginner-friendly.** Menus and questions use plain language. Provide sensible defaults and briefly explain what a choice does.
- **Only supported releases.** We support OS releases that still get security updates from their vendor. When one reaches end of life, move it to the end-of-life line in `os_check` (`lib/os.sh`), which makes the tool warn, and remove it from the README and the CI matrix in the next release. A new release goes into the CI matrix first; add it to `os_check` once its jobs are green.
- **Two languages.** User-facing text must be available in both English and Bahasa Indonesia (`--lang id`).
- **Don't overwrite user config silently.** If you must change an existing file, say so and back it up.

## Code style

- Scripts are written in **Bash**. Use `set -euo pipefail` where it matches the existing pattern in the repo.
- Quote your variables: `"$var"`, not `$var`.
- Use `local` for variables inside functions.
- One function, one job. Name it for what it does.
- Follow the style and structure of the existing files. Consistency matters more than personal taste.
- Comments explain **why**, not **what**.
- Code must pass ShellCheck:

  ```bash
  shellcheck setup.sh lib/*.sh
  ```

  If you need to disable a warning, explain why in a comment.

## Testing your changes

Before sending a pull request, test on a clean test server:

1. **ShellCheck** is clean, with no new warnings.
2. **`--dry-run`** shows the right plan and does not change the system.
3. **A normal run** works from start to finish.
4. **Run it twice.** The result is the same and nothing breaks (idempotent).
5. **Uninstall** cleans up everything you added.
6. **Both languages** display correctly: also run with `--lang id`.

In your pull request description, state the distro and version you tested on.

## Pull request workflow

1. Make sure your branch is up to date with the latest `main`.
2. Keep your change **focused**: one pull request, one purpose. Mixed changes are harder to review.
3. Update the docs (`README`) if any option, menu, or behavior changed.
4. Open the pull request and fill in the description:
   - What changed and why.
   - Related issue (for example `Closes #12`).
   - How you tested it.
5. Respond to review comments. Review is about the code, not the person.
6. Once approved, a maintainer will merge it.

## Commit messages

Keep them short and clear, in English or Indonesian, starting with a verb:

```
Add Redis option to the service menu
Fix nginx jail not reloading after install
Update README with --add-database example
```

One commit should be one logical change.

## Security

Found a security vulnerability? **Please don't open a public issue.** Contact the maintainer privately through the [@Orlinkzz GitHub profile](https://github.com/Orlinkzz) or the *Report a vulnerability* feature in the repo's Security tab (if enabled), and allow time for a fix before disclosing publicly.

---

Have a question this guide doesn't answer? Open an issue, we're happy to help. Thanks for contributing!