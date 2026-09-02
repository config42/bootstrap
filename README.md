# bootstrap

Idempotent SSH access bootstrapping for Linux servers and Macs. Installs your
public key, trusts your SSH CA. Safe to re-run.

## Quick start

```bash
cat ~/.ssh/id_ed25519.pub >> keys/authorized.pub   # your key
./ca.sh init                                       # create a CA (or paste an existing one into keys/ca.pub)
./bootstrap.sh --dry-run                           # preview
./push.sh web-1 web-2                              # roll out
```

## Files

| File | Purpose |
| --- | --- |
| `bootstrap.sh` | Installs the keys. Runs on the endpoint. |
| `push.sh` | Runs `bootstrap.sh` across hosts over ssh. |
| `ca.sh` | Creates the CA, issues certificates. |
| `keys/` | Your public key + CA public key. See [keys/README.md](keys/README.md). |

## What it writes

One marked block in `~/.ssh/authorized_keys`:

```
# >>> bootstrap-ssh managed block >>>
ssh-ed25519 AAAA... you@laptop
cert-authority ssh-ed25519 AAAA... your-ca
# <<< bootstrap-ssh managed block <<<
```

Lines outside the markers are never touched. The `cert-authority` prefix is what
makes certificates work. **No root required.**

`--system` additionally sets `TrustedUserCAKeys` in sshd, trusting the CA for
every account on the host. Needs root. Prefers a `sshd_config.d` drop-in, runs
`sshd -t` before reloading, and rolls back if sshd rejects the config.

## Options

```
-u, --user USER    Target user (default: $SUDO_USER, else you)
-k, --key FILE     Public key file    (default: keys/authorized.pub)
-c, --ca FILE      CA public key file (default: keys/ca.pub)
-s, --system       Host-wide CA trust via TrustedUserCAKeys (root)
    --no-reload    Edit sshd config but don't reload
    --remove       Undo everything
-n, --dry-run      Preview
-q, --quiet        Warnings and errors only
```

## Certificates

```bash
./ca.sh init                                        # create CA, publish keys/ca.pub
./ca.sh sign ~/.ssh/id_ed25519.pub -n admin,root    # issue a cert
./ca.sh show ~/.ssh/id_ed25519-cert.pub             # inspect
```

The CA private key goes in `~/.ssh/ca/`, never the repo — `init` refuses to
create it inside a git work tree. `-n` principals are the usernames the cert may
log in as, and are required. Default lifetime is 12 weeks (`-V +1d` for
short-lived). Each cert gets a serial so it can be revoked via a KRL.

`keys/ca.pub` takes one line per CA; `keys/authorized.pub` one per device.
Re-running rewrites the block wholesale, so deleting a line revokes that access.

## Releasing

Version lives in `VERSION=` at the top of `bootstrap.sh` and `ca.sh`. Bump both:

```bash
V=1.1.0; sed -i '' "s/^VERSION=.*/VERSION=$V/" bootstrap.sh ca.sh
```

Then commit, tag, publish:

```bash
git commit -am "Release v1.1.0"
git tag -a v1.1.0 -m "v1.1.0" && git push && git push origin v1.1.0
gh release create v1.1.0 --generate-notes
```

- GNU sed is `sed -i` (no `''`).
- `--draft` stages the release for review instead of publishing.
- `--notes-file NOTES.md` replaces the auto-generated commit list.
- Semver: patch for fixes, minor for new flags, major for a changed managed-block
  format (endpoints need re-running).

## Troubleshooting

Key installed but login still fails:

| Cause | Fix |
| --- | --- |
| SELinux labels | Run once as root; it calls `restorecon` |
| Home is group-writable | `chmod go-w ~` — sshd `StrictModes` ignores the keys otherwise |
| Relocated `AuthorizedKeysFile` | sshd is reading a different file |
| macOS: Remote Login off | System Settings → General → Sharing |
| macOS: user not in `com.apple.access_ssh` | `sudo dseditgroup -o edit -a USER -t user com.apple.access_ssh` |
| Cert refused | Principal must match the login username; check expiry with `ca.sh show` |

`bootstrap.sh` checks and reports all of these itself.

## Notes

- POSIX `sh` — runs under dash, BusyBox ash, and macOS bash 3.2.
- Every change writes a `*.bak.<timestamp>` beside the file. Idempotent runs make
  no backups.
- `--remove` strips the managed blocks and system CA file. It leaves copies of
  your key found *outside* the block; the script warns when it sees one.
- `BOOTSTRAP_SSH_PREFIX=/tmp/fake` redirects every `/etc` path for testing.
