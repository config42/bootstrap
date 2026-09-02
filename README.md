# bootstrap

Idempotent SSH access bootstrapping for Linux servers and Macs. Installs your
public key, trusts your SSH CA. Safe to re-run.

## Run
```bash
curl -fsSL https://github.com/config42/bootstrap/releases/latest/download/install.sh | sh
```

## Deploy Across Fleet
From a clone, or a saved `install.sh` — streams itself over ssh:
```bash
./bootstrap.sh --push web-1 web-2 db-1
```

## Uninstall
```bash
curl -fsSL https://github.com/config42/bootstrap/releases/latest/download/install.sh | sh -s -- --remove
```

One script, one path: `--push` also works from `install.sh` itself, so the
same file you curl for a single box is what you'd save and use for a fleet.
`install.sh` is `bootstrap.sh` with `keys/` embedded, so it runs standalone.
The bare script needs `keys/` beside it — `archive/refs/heads/main.tar.gz`
(latest commit) or `releases/latest/download/bootstrap.tar.gz` (full toolkit:
ca.sh, keys/, at the latest release) both give you that.

Everything else is in `./bootstrap.sh --help` and `./ca.sh --help`. Key files:
[keys/README.md](keys/README.md).
