# keys/

Both files are public material, safe to commit.

| File | Contents |
| --- | --- |
| `authorized.pub` | Your SSH public key(s) — go into `authorized_keys` |
| `ca.pub` | Your CA's public key(s) — signed certs are then accepted |

One line per device / per CA. Blank lines and `#` comments ignored.

```bash
cat ~/.ssh/id_ed25519.pub >> keys/authorized.pub
cat ~/.ssh/ca/ssh_ca.pub  >> keys/ca.pub          # ./ca.sh init does this for you
```

Key in an agent (1Password, Secretive, YubiKey) rather than on disk:

```bash
ssh-add -L | grep 'your-comment' >> keys/authorized.pub
```

## ca.pub takes the CA key, not a certificate

`bootstrap.sh` rejects a certificate here. A cert carries only its issuer's
*fingerprint*, not the issuer's key, so sshd has nothing to verify future certs
against. `ssh-keygen -L -f cert.pub` names the key you need on its `Signing CA`
line — copy that key's `.pub` here.

## Rotation

Edit, commit, re-run `bootstrap.sh` on each endpoint. The managed block is
rewritten wholesale, so deleting a line here revokes that access there. Rotating
the CA key invalidates every certificate it signed at once.
