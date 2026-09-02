# bootstrap

Idempotent SSH access bootstrapping for Linux servers and Macs. Installs your
public key, trusts your SSH CA. Safe to re-run.

## Deploy Across Fleet
```bash
/tmp/bs/push.sh web-1 web-2 db-1
```

## Uninstall
```bash
/tmp/bs/bootstrap.sh --remove
```

Other URLs: `releases/latest/download/bootstrap.tar.gz` for the latest release
(requires the attached asset — see below), `archive/refs/heads/main.tar.gz` for
the latest commit. `curl .../bootstrap.sh | sh` does **not** work: the script
reads `keys/` beside itself.

Everything else is in `./bootstrap.sh --help` and `./ca.sh --help`. Key files:
[keys/README.md](keys/README.md).
