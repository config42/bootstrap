#!/bin/sh
# ca.sh — create an SSH certificate authority and issue user certificates.
#
#   ./ca.sh init              create the CA keypair, publish its public half
#   ./ca.sh sign KEY.pub      issue a certificate for a public key
#   ./ca.sh show FILE         inspect a certificate or key
#
# The CA *private* key is the crown jewel: anyone holding it can mint a
# certificate for any principal on every endpoint that trusts it. It is created
# outside this repository and this script refuses to place it inside a git work
# tree. Only the public half (keys/ca.pub) belongs in version control.

set -eu

VERSION=1.0.0
PROG=ca.sh
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

CA_DIR=${CA_DIR:-$HOME/.ssh/ca}
CA_KEY=$CA_DIR/ssh_ca
CA_PUB=$CA_DIR/ssh_ca.pub
SERIAL_FILE=$CA_DIR/serial
REPO_CA=$SELF_DIR/keys/ca.pub

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_OK=$(printf '\033[32m'); C_WARN=$(printf '\033[33m')
    C_ERR=$(printf '\033[31m'); C_DIM=$(printf '\033[2m')
    C_B=$(printf '\033[1m');    C_0=$(printf '\033[0m')
else
    C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_B=''; C_0=''
fi
say()  { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '  %sok%s       %s\n' "$C_OK" "$C_0" "$*"; }
warn() { printf '  %swarn%s     %s\n' "$C_WARN" "$C_0" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_ERR" "$C_0" "$*" >&2; exit 1; }

usage() {
    cat <<HELPTEXT
$PROG $VERSION — SSH certificate authority for the bootstrap fleet.

COMMANDS
    init [options]        Create the CA keypair and publish keys/ca.pub
    sign KEY.pub [opts]   Issue a user certificate signed by the CA
    show FILE             Print the details of a certificate or key

INIT OPTIONS
    --dir DIR             Where the CA lives (default: \$HOME/.ssh/ca)
    --no-passphrase       Skip the passphrase prompt. Strongly discouraged:
                          an unlocked CA key is a master key to every endpoint.
    -t TYPE               Key type (default: ed25519)

SIGN OPTIONS
    -n, --principals LIST Comma-separated usernames the cert may log in as.
                          Required — a cert with no principals opens nothing.
    -I, --identity ID     Key ID recorded in the endpoint's auth log
                          (default: <user>@<host>-<date>)
    -V, --validity SPEC   Lifetime, ssh-keygen syntax (default: +12w)
    -o, --out FILE        Output path (default: alongside KEY.pub)

EXAMPLES
    ./ca.sh init
    ./ca.sh sign ~/.ssh/id_ed25519.pub -n dispatch,admin,root,ubuntu
    ./ca.sh sign ~/.ssh/id_ed25519.pub -n root -V +1d -I emergency-access
    ./ca.sh show ~/.ssh/id_ed25519-cert.pub
HELPTEXT
}

# Refuse to put private key material anywhere git might pick it up.
assert_not_in_git() {
    _d=$1
    _probe=$_d
    while [ ! -d "$_probe" ] && [ "$_probe" != / ] && [ -n "$_probe" ]; do
        _probe=$(dirname "$_probe")
    done
    if git -C "$_probe" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        die "$_d is inside a git work tree ($_probe).

The CA private key must never be committable. Pick a location outside any
repository, e.g.  CA_DIR=\$HOME/.ssh/ca ./ca.sh init"
    fi
}

cmd_init() {
    KEY_TYPE=ed25519
    PASS_ARGS=""
    NO_PASS=0
    while [ $# -gt 0 ]; do
        case $1 in
            --dir) CA_DIR=${2:?--dir needs a value}
                   CA_KEY=$CA_DIR/ssh_ca; CA_PUB=$CA_DIR/ssh_ca.pub
                   SERIAL_FILE=$CA_DIR/serial; shift 2 ;;
            --no-passphrase) NO_PASS=1; shift ;;
            -t)    KEY_TYPE=${2:?-t needs a value}; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *)     die "unknown option for init: $1" ;;
        esac
    done

    step "Creating certificate authority in $CA_DIR"
    assert_not_in_git "$CA_DIR"

    if [ -f "$CA_KEY" ]; then
        ok "CA already exists — leaving it alone"
    else
        mkdir -p "$CA_DIR"
        chmod 700 "$CA_DIR"
        [ "$NO_PASS" -eq 1 ] && PASS_ARGS='-N '
        if [ "$NO_PASS" -eq 1 ]; then
            ssh-keygen -q -t "$KEY_TYPE" -N '' \
                -C "ssh-ca $(id -un)@$(hostname -s 2>/dev/null || echo host) $(date +%Y-%m-%d)" \
                -f "$CA_KEY"
            warn "created WITHOUT a passphrase — anyone who reads $CA_KEY"
            warn "can mint a login for any principal. Add one with:"
            warn "  ssh-keygen -p -f $CA_KEY"
        else
            say "  ${C_DIM}Choose a passphrase. This key is a master key for every"
            say "  endpoint that trusts it, so an empty one is a real risk.${C_0}"
            ssh-keygen -q -t "$KEY_TYPE" \
                -C "ssh-ca $(id -un)@$(hostname -s 2>/dev/null || echo host) $(date +%Y-%m-%d)" \
                -f "$CA_KEY"
        fi
        chmod 600 "$CA_KEY"; chmod 644 "$CA_PUB"
        say ""
        ok "CA private key  $CA_KEY  (never copy this anywhere)"
        ok "CA public key   $CA_PUB"
    fi
    [ -f "$SERIAL_FILE" ] || printf '0\n' > "$SERIAL_FILE"

    step "Publishing the public half to keys/ca.pub"
    _blob=$(awk '{for(i=1;i<=NF;i++) if ($i ~ /^AAAA/) {print $i; exit}}' "$CA_PUB")
    if [ -f "$REPO_CA" ] && grep -qF "$_blob" "$REPO_CA"; then
        ok "already present in keys/ca.pub"
    else
        cat "$CA_PUB" >> "$REPO_CA"
        ok "appended to keys/ca.pub"
    fi

    say ""
    say "${C_B}Next:${C_0}"
    say "  1. Issue yourself a certificate:"
    say "       ./ca.sh sign ~/.ssh/id_ed25519.pub -n dispatch,admin,root"
    say "  2. Add your public key to keys/authorized.pub (fallback access)"
    say "  3. Roll it out:   ./push.sh <host>..."
    say ""
    say "${C_WARN}Back up $CA_KEY somewhere offline.${C_0} Losing it means"
    say "re-bootstrapping every endpoint; leaking it means anyone can log in as you."
}

cmd_sign() {
    [ $# -gt 0 ] || die "sign needs a public key file (try --help)"
    SRC=$1; shift
    PRINCIPALS=""
    IDENTITY="$(id -un)@$(hostname -s 2>/dev/null || echo host)-$(date +%Y%m%d)"
    VALIDITY="+12w"
    OUT=""
    while [ $# -gt 0 ]; do
        case $1 in
            -n|--principals) PRINCIPALS=${2:?-n needs a value}; shift 2 ;;
            -I|--identity)   IDENTITY=${2:?-I needs a value};   shift 2 ;;
            -V|--validity)   VALIDITY=${2:?-V needs a value};   shift 2 ;;
            -o|--out)        OUT=${2:?-o needs a value};        shift 2 ;;
            -h|--help)       usage; exit 0 ;;
            *)               die "unknown option for sign: $1" ;;
        esac
    done

    [ -f "$CA_KEY" ] || die "no CA at $CA_KEY — run: ./ca.sh init"
    [ -f "$SRC" ]    || die "public key not found: $SRC"
    [ -n "$PRINCIPALS" ] || die "-n/--principals is required.

A certificate with no principals cannot log in anywhere. List the usernames you
log in as, comma separated, e.g.  -n dispatch,admin,root,ubuntu"

    grep -q 'PRIVATE KEY' "$SRC" &&
        die "$SRC is a private key. Sign the public half (the .pub file)."
    _info=$(ssh-keygen -l -f "$SRC" 2>&1) ||
        die "$SRC is not a valid SSH public key: $_info"
    case "$_info" in *-CERT\)*)
        die "$SRC is already a certificate. Sign the underlying .pub instead." ;;
    esac

    # A serial makes a specific certificate revocable later via a KRL.
    _serial=$(cat "$SERIAL_FILE" 2>/dev/null || echo 0)
    _serial=$((_serial + 1))

    step "Issuing certificate"
    say "  key         $_info"
    say "  principals  $PRINCIPALS"
    say "  identity    $IDENTITY"
    say "  validity    $VALIDITY"
    say "  serial      $_serial"

    _work=$SRC
    if [ -n "$OUT" ]; then
        _work=${OUT%-cert.pub}.pub
        [ "$_work" = "$SRC" ] || cp -- "$SRC" "$_work"
    fi

    ssh-keygen -q -s "$CA_KEY" -I "$IDENTITY" -n "$PRINCIPALS" \
               -V "$VALIDITY" -z "$_serial" "$_work"
    printf '%s\n' "$_serial" > "$SERIAL_FILE"

    _cert=${_work%.pub}-cert.pub
    say ""
    ok "wrote $_cert"
    say ""
    ssh-keygen -L -f "$_cert" | sed 's/^/  /'
    say ""
    say "${C_B}To use it:${C_0}"
    say "  ssh picks the cert up automatically when it sits beside the private"
    say "  key. If your key lives only in an agent, point ssh at it explicitly:"
    say "     ${C_DIM}Host *${C_0}"
    say "     ${C_DIM}  CertificateFile $_cert${C_0}"
    say ""
    say "  Confirm the endpoint accepts it:"
    say "     ssh -v <host> 2>&1 | grep -i 'offering\\|certificate'"
}

cmd_show() {
    [ $# -gt 0 ] || die "show needs a file"
    for f in "$@"; do
        [ -f "$f" ] || die "not found: $f"
        step "$f"
        ssh-keygen -l -f "$f" | sed 's/^/  /'
        ssh-keygen -L -f "$f" 2>/dev/null | sed 's/^/  /' || true
    done
}

case ${1:-} in
    init) shift; cmd_init "$@" ;;
    sign) shift; cmd_sign "$@" ;;
    show) shift; cmd_show "$@" ;;
    -h|--help|help|'') usage ;;
    --version) printf '%s %s\n' "$PROG" "$VERSION" ;;
    *) die "unknown command: $1 (try --help)" ;;
esac
