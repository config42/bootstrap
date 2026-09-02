# bootstrap

Idempotent SSH access bootstrapping for Linux servers and Macs. Installs your
public key, trusts your SSH CA. Safe to re-run.

## Run

On one endpoint:

```bash
mkdir -p /tmp/bs
curl -fsSL https://github.com/config42/bootstrap/releases/latest/download/bootstrap.tar.gz \
  | tar xz --strip-components=1 -C /tmp/bs
/tmp/bs/bootstrap.sh
```

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

## Release

`VERSION=` in `bootstrap.sh` and `ca.sh` must match the tag.

```bash
V=1.0.0
sed -i '' "s/^VERSION=.*/VERSION=$V/" bootstrap.sh ca.sh
git tag -a "v$V" -m "v$V" && git push && git push origin "v$V"
git archive --format=tar.gz --prefix=bootstrap/ -o bootstrap.tar.gz "v$V"
gh release create "v$V" --generate-notes bootstrap.tar.gz
```
