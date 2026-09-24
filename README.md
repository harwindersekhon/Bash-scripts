# Bash-Scripts

Standalone scripts that install and set up common Linux services. Each script
installs the packages, then asks you how to set the service up (paths, users,
permissions), configures the firewall and SELinux, and prints a summary.

| Script | What it does |
|---|---|
| `scripts/install-lamp.sh` | Apache + MariaDB + PHP, default site or a vhost, app DB, phpMyAdmin |
| `scripts/setup-nfs-server.sh` | NFS server with one or more exports |
| `scripts/setup-nfs-client.sh` | NFS client mount, optionally persistent in `/etc/fstab` |
| `scripts/setup-vsftpd.sh` | vsftpd FTP server with dedicated, existing or anonymous users |
| `scripts/setup-samba.sh` | Samba share for new users, existing users or guests |

## Supported systems

| Family | Distros | Package manager | Firewall | MAC |
|---|---|---|---|---|
| RHEL | RHEL, Rocky, Alma, CentOS Stream, Fedora | dnf | firewalld | SELinux |
| Debian | Debian, Ubuntu | apt | ufw | – |

On the RHEL family, every script checks that **EPEL** is enabled and enables it
(along with CRB, or PowerTools on EL8, which EPEL depends on) if it isn't.
Fedora is skipped. If no firewall is active, the script skips the firewall
rules and prints a warning.

## Usage

Every script is self-contained. You can copy a single file to a server and run it:

```bash
sudo ./scripts/setup-vsftpd.sh            # interactive
sudo ./scripts/setup-vsftpd.sh --help     # all options
sudo ./scripts/setup-vsftpd.sh --dry-run  # show what would be done, change nothing
```

Every prompt has a matching flag. A prompt whose value you pass as a flag or
environment variable is skipped. `--yes` takes the defaults for everything
else, so the scripts can run unattended. Passwords are read from environment
variables, never from flags, so they don't show up in `ps`. With `--yes`, any
password you don't provide is generated and printed in the summary.

All scripts accept:

| Flag | Meaning |
|---|---|
| `-y`, `--yes` | Non-interactive: use defaults for anything not given |
| `-n`, `--dry-run` | Print commands and file contents instead of applying them |
| `-h`, `--help` | Show usage |

### setup-vsftpd.sh

Asks for:
- the FTP root (default `/srv/ftp`)
- the access mode:
  - **new-user**: create a dedicated FTP-only user whose home is the FTP root and who has no shell login
  - **existing-user**: grant an existing system user access. They either land in the FTP root with `rw`/`ro` access through an ACL, or in their own home directory
  - **anonymous**: read-only downloads from `<root>/pub`
- whether to chroot users
- the passive port range
- whether to enable TLS (self-signed FTPS)
- whether to allow only the listed users (allow-list)

You can add more users in the same run.

```bash
sudo FTP_PASSWORD='S3cret!' ./scripts/setup-vsftpd.sh --yes --mode new-user --user ftpuser
sudo ./scripts/setup-vsftpd.sh --yes --mode existing-user --user alice --perm ro --tls
sudo ./scripts/setup-vsftpd.sh --yes --mode anonymous --ftp-root /srv/pub
```

### setup-samba.sh

Asks for:
- the share name and path
- the access mode:
  - **new-user**: create a Samba-only user
  - **existing-user**: add an existing system user
  - **guest**: public share, no password
- read-write or read-only
- the workgroup
- whether to limit access to the local subnet

Users get access through a per-share group (`smb_<share>`). Each share is
written to `/etc/samba/shares.d/<share>.conf` and included from `smb.conf`, so
existing shares are left alone. The config is checked with `testparm` before
Samba restarts.

```bash
sudo SMB_PASSWORD='S3cret!' ./scripts/setup-samba.sh --yes --share docs --mode new-user --user docs
sudo ./scripts/setup-samba.sh --yes --share public --mode guest --perm ro
```

### install-lamp.sh

Asks for:
- the site: the default site, or a name-based vhost with its own document root
- who owns the site files: the web server user, or an existing developer account
- whether the web app may write to the document root
- extra PHP modules
- the MariaDB root password
- an optional application database and user
- whether to install phpMyAdmin (from EPEL on RHEL)
- whether to add a `phpinfo()` test page

MariaDB is secured without prompts: anonymous users, the test database and
remote root are removed. Root keeps socket login (`sudo mysql`) on MariaDB 10.4
and newer; on older releases (RHEL 8's default stream, Ubuntu 20.04) root
authenticates with the password only, and the script says so.

```bash
sudo ./scripts/install-lamp.sh
sudo DB_ROOT_PASSWORD='S3cret!' ./scripts/install-lamp.sh --yes \
    --site vhost --domain example.com --owner alice --app-db wordpress --info
```

### setup-nfs-server.sh

For each export, asks for:
- the directory and the allowed clients
- `rw`/`ro` and `sync`/`async`
- `root_squash`, `no_root_squash` or `all_squash`
- the owner: `nobody`, an existing user, or a new user with a fixed UID that matches your clients

You can add several exports in one run. An entry that already exists is only
replaced when you confirm.

```bash
sudo ./scripts/setup-nfs-server.sh --yes --path /srv/nfs/data --clients 192.168.1.0/24
```

### setup-nfs-client.sh

Asks for the server, then lists its exports (`showmount -e`) so you can pick
one. Then asks for the mount point and mount options, and whether to add an
`/etc/fstab` entry (added with `_netdev,nofail`).

```bash
sudo ./scripts/setup-nfs-client.sh --yes --server 192.168.1.10 --export /srv/nfs/data --mount /mnt/data
```

## Safety

- Every config file is backed up to `<file>.bak.<timestamp>` before it is changed.
- The scripts are safe to re-run: existing users, exports, fstab entries and include lines are detected rather than duplicated.
- Logs are written to `/var/log/bash-scripts/<script>.log`. Passwords are never logged, because they go to commands on stdin.

## Project layout

```
scripts/                   the setup scripts (each one standalone)
templates/script-skeleton.sh  starting point for new scripts; holds the master
                           copy of the COMMON HELPERS block
tools/sync-helpers.sh      copies the helper block from the skeleton into scripts/
Makefile                   check / lint / fmt / sync targets
```

### Shared helpers

To keep each script standalone, the helpers (logging, prompts, OS detection,
EPEL, packages, services, firewall, SELinux) are **copied** into every script
between the `BEGIN/END COMMON HELPERS` markers. To change a helper:

1. Edit it in `templates/script-skeleton.sh`.
2. Run `make sync` to copy the block into every script.
3. Run `make sync-check` (also part of `make all`) to confirm no script has drifted.

### Adding a new script

1. Copy `templates/script-skeleton.sh` to `scripts/<name>.sh`.
2. Fill in `usage`, `parse_args`, `set_os_vars` (package and service names per OS family) and `main`.
3. Use `run` for every command that changes the system, and `write_file` / `append_line_once` for files, so `--dry-run` works.
4. Run `make all`.

### Development

```bash
make check       # bash -n on every script
make lint        # shellcheck (needs shellcheck installed: dnf/apt install ShellCheck/shellcheck)
make fmt         # shfmt formatting
make sync-check  # helper blocks identical to the skeleton
```
