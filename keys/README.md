# keys/

Two files, both **public** material, both safe to commit:

| File             | What goes in it                                        |
| ---------------- | ------------------------------------------------------ |
| `authorized.pub` | Your SSH public key(s) — installed into `authorized_keys` |
| `ca.pub`         | Your CA's public key(s) — trusted so signed certs work    |

Multiple lines are allowed in either file: one line per laptop in
`authorized.pub`, one line per CA in `ca.pub`.

## Filling them in

```bash
# your public key, from the machine you log in from
cat ~/.ssh/id_ed25519.pub >> keys/authorized.pub

# your CA's public key, from wherever you sign certificates
cat ~/ssh-ca/ca.pub >> keys/ca.pub
```

If your key lives in an agent (1Password, Secretive, a YubiKey) rather than on
disk, pull the public half out of the agent instead:

```bash
ssh-add -L | grep 'your-comment' >> keys/authorized.pub
```

## Certificate vs. CA key

`bootstrap.sh` rejects a certificate handed to `--ca`, because trusting a cert
does not work: a certificate carries only the *fingerprint* of its issuer, not
the issuer's key, so there is nothing in it for `sshd` to verify future certs
against. Inspect a cert with `ssh-keygen -L -f id_ed25519-cert.pub` — the
`Signing CA:` line names the key you need, and you copy that key's `.pub` here.

## Rotation

Edit the file, commit, re-run `bootstrap.sh` on each endpoint. The managed block
is rewritten wholesale, so removing a line here removes the access there.
Rotating the CA key is the fast path: one line, and every certificate it signed
stops working at once.
