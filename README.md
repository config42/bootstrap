# bootstrap

Idempotent SSH access bootstrapping for Linux servers and Macs. Installs your
public key, trusts your SSH CA. Safe to re-run.

## Run

On one endpoint:

```bash
mkdir -p /tmp/bs
curl -fsSL https://github.com/config42/bootstrap/archive/refs/tags/v1.0.0.tar.gz \
  | tar xz --strip-components=1 -C /tmp/bs
/tmp/bs/bootstrap.sh
```

Add `--dry-run` to preview, `--system` for host-wide CA trust (needs root),
`--remove` to undo.

Across a fleet, from a clone — streams your current keys over ssh, needs nothing
installed on the far end:

```bash
./push.sh web-1 web-2 db-1
```

Other URLs: `releases/latest/download/bootstrap.tar.gz` for the latest release
(requires the attached asset — see below), `archive/refs/heads/main.tar.gz` for
the latest commit. `curl .../bootstrap.sh | sh` does **not** work: the script
reads `keys/` beside itself.

Everything else is in `./bootstrap.sh --help` and `./ca.sh --help`. Key files:
[keys/README.md](keys/README.md).

## Release

`VERSION=` in `bootstrap.sh` and `ca.sh` must match the tag. Current: **v1.0.0**.

```bash
V=1.1.0
sed -i '' "s/^VERSION=.*/VERSION=$V/" bootstrap.sh ca.sh    # GNU sed: drop the ''
git commit -am "Release v$V"
git tag -a "v$V" -m "v$V" && git push && git push origin "v$V"
git archive --format=tar.gz --prefix=bootstrap/ -o bootstrap.tar.gz "v$V"
gh release create "v$V" --generate-notes bootstrap.tar.gz
```

`bootstrap.tar.gz` must keep the same filename every release — that is what makes
the `releases/latest/download/` URL stable. Without it that URL 404s; attach one
to an existing release with `gh release upload v1.0.0 bootstrap.tar.gz`.

`--draft` stages the release for review instead of publishing.
