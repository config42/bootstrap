# bootstrap

Idempotent SSH access bootstrapping for endpoints — Linux servers and Macs.

One script installs your public key into a box's `authorized_keys` and teaches
it to trust your SSH certificate authority, so both raw-key and certificate
logins work. Run it as many times as you like: it converges the machine to the
desired state and tells you when there was nothing to do.

```
./bootstrap.sh                        # this machine, your user
./push.sh web-1 web-2 db-1            # a fleet
sudo ./bootstrap.sh -u deploy -s      # another user, host-wide CA trust
```

## Setup

Put your public material in `keys/` — both files are public and safe to commit:

```bash
cat ~/.ssh/id_ed25519.pub >> keys/authorized.pub   # your key(s)
cat ~/ssh-ca/ca.pub       >> keys/ca.pub           # your CA's public key
```

See [keys/README.md](keys/README.md) for the details, including how to pull your
public key out of an agent (1Password, Secretive, YubiKey) if it isn't on disk.

Then, on each endpoint:

```bash
./bootstrap.sh --dry-run   # look first
./bootstrap.sh             # apply
```

## What it changes

A single marked block in `~/.ssh/authorized_keys`, and nothing else:

```
# >>> bootstrap-ssh managed block >>>
# Managed by bootstrap-ssh. Changes between these markers are overwritten.
ssh-ed25519 AAAAC3Nz... chintan@laptop
cert-authority ssh-ed25519 AAAAC3Nz... my-ssh-ca
# <<< bootstrap-ssh managed block <<<
```

Lines outside the markers are never touched, so a box with other people's keys
on it stays intact. The `cert-authority` prefix is what makes certificates work:
any cert signed by that CA, whose principal list includes the target user, is
accepted — no per-machine change needed when you issue a new one.

Because it is per-user, **the default path needs no root at all.**

### `--system`

`--system` additionally writes the CA to `/etc/ssh/bootstrap-ssh-ca.pub` and
points `sshd` at it with `TrustedUserCAKeys`, so the CA is trusted for *every*
account on the host. This needs root. It prefers a drop-in at
`/etc/ssh/sshd_config.d/50-bootstrap-ssh.conf` and falls back to a marked block
in `sshd_config` on hosts too old to support `Include`.

If `sshd_config` already sets `TrustedUserCAKeys` to something else, the script
refuses to fight it — it warns and leaves the file alone.

Before reloading, it runs `sshd -t`. If the daemon rejects the new config the
change is rolled back and the script aborts, so a bad edit cannot lock you out.
Reloading `sshd` never drops existing sessions; keep one open until you have
confirmed a new login works anyway.

## What it refuses to do

Validation runs per line, before anything is written:

- **A private key** in either file is rejected. `ssh-keygen -l` will happily
  fingerprint a private key file, so a file-level check is not enough.
- **A certificate passed as the CA** is rejected with an explanation. This is
  the intuitive mistake, and it cannot work: a certificate carries only its
  issuer's *fingerprint*, not the issuer's key, so there is nothing in it for
  `sshd` to verify future certificates against. You need the CA's own `.pub`.
- **A malformed key line** is named by line number, with what `ssh-keygen` said.

## The silent-failure checks

Most of the time a key is installed correctly and login still fails, the cause
is elsewhere. The script checks the usual suspects and reports them:

| Check | Why it matters |
| --- | --- |
| SELinux labels | `sshd` cannot read `authorized_keys` without `ssh_home_t`; fixed via `restorecon` when run as root |
| Home directory permissions | `StrictModes` makes `sshd` ignore keys in a group- or world-writable home |
| `AuthorizedKeysFile` | A host that relocates it means the file you just wrote is never read |
| `PubkeyAuthentication` | Disabled in some hardened images |
| macOS Remote Login | `sshd` is off by default on macOS |
| `com.apple.access_ssh` | If Remote Login is limited to specific users, everyone else is refused despite a valid key |

## Fleets

`push.sh` streams the script and keys over each SSH connection into a temporary
directory, runs it, and cleans up. Nothing is installed on the far end and
nothing is left behind; `tar` and `sh` are the only requirements.

```bash
./push.sh web-1 web-2                 # per-user
./push.sh web-1 web-2 -- --system     # implies sudo, allocates a tty
cat hosts.txt | ./push.sh -           # hosts from stdin
./push.sh -J bastion internal-1       # unrecognised flags pass through to ssh
```

It reports per-host and exits non-zero if any host failed.

## Rotation and removal

The managed block is rewritten wholesale from `keys/`, so removing a line there
and re-running removes that access. Rotating the CA key is the fast path: change
one line and every certificate it signed stops working at once.

`./bootstrap.sh --remove` strips the managed blocks and deletes the system CA
file. It deliberately leaves untouched any copy of your key that lives *outside*
the block — the script warns when it finds one, precisely because that copy will
survive a removal and quietly keep access open.

Every modification backs the file up alongside itself first
(`authorized_keys.bak.20260901202112`). Idempotent runs change nothing, so
backups do not accumulate.

## Options

```
-u, --user USER    Target user (default: $SUDO_USER if set, else you)
-k, --key FILE     Public key file       (default: keys/authorized.pub)
-c, --ca FILE      CA public key file    (default: keys/ca.pub)
-s, --system       Also trust the CA host-wide via TrustedUserCAKeys (root)
    --no-reload    Change sshd config but do not reload the daemon
    --remove       Undo: strip the managed blocks and system CA file
-n, --dry-run      Show what would change, touch nothing
-q, --quiet        Only warnings and errors
-h, --help         Full help
```

## Portability

POSIX `sh` — no bashisms, no arrays, no `[[ ]]` — so it runs under `dash`,
BusyBox `ash`, and macOS's `bash` 3.2 alike. Syntax is verified against `sh`,
`bash`, and `dash`. Service reloads cover systemd, OpenRC, SysV `service`, and
macOS `launchctl`.

`BOOTSTRAP_SSH_PREFIX=/tmp/fake` redirects every `/etc` path under that prefix
and drops the root requirement, which is how the `--system` path is tested
without a real machine to break.
