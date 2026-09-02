#!/bin/sh
# bootstrap-ssh — idempotently grant SSH access to an endpoint.
#
# Installs a public key into the target user's authorized_keys and trusts an
# SSH certificate authority, so that both raw-key and certificate logins work.
# Safe to run repeatedly: it converges the box to the desired state and reports
# "unchanged" when there is nothing to do.
#
# Supports Linux (systemd, OpenRC, SysV) and macOS.

set -eu

VERSION=1.0.0
PROG=bootstrap-ssh

BEGIN_MARK='# >>> bootstrap-ssh managed block >>>'
END_MARK='# <<< bootstrap-ssh managed block <<<'
BLOCK_NOTE='# Managed by bootstrap-ssh. Changes between these markers are overwritten.'

# DESTDIR-style prefix. Empty in normal use; set it to a scratch directory to
# exercise the --system path against a fake /etc (this also drops the root
# requirement, since nothing outside the prefix is touched).
ETC=${BOOTSTRAP_SSH_PREFIX:-}
SYS_CA_FILE=$ETC/etc/ssh/bootstrap-ssh-ca.pub
SYS_DROPIN=$ETC/etc/ssh/sshd_config.d/50-bootstrap-ssh.conf
SSHD_CONFIG=$ETC/etc/ssh/sshd_config

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

TARGET_USER=""
KEY_FILE=""
CA_FILE=""
DO_SYSTEM=0
DRY_RUN=0
DO_RELOAD=1
DO_REMOVE=0
QUIET=0
CHANGED=0
WARNED=0
OS=$(uname -s)

# ---------------------------------------------------------------- output ----

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_OK=$(printf '\033[32m'); C_WARN=$(printf '\033[33m')
    C_ERR=$(printf '\033[31m'); C_DIM=$(printf '\033[2m')
    C_B=$(printf '\033[1m');    C_0=$(printf '\033[0m')
else
    C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_B=''; C_0=''
fi

say()     { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
step()    { [ "$QUIET" -eq 1 ] || printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
changed() {
    CHANGED=$((CHANGED + 1))
    [ "$QUIET" -eq 1 ] && return 0
    if [ "$DRY_RUN" -eq 1 ]
        then printf '  %swould%s    %s\n' "$C_WARN" "$C_0" "$*"
        else printf '  %schanged%s  %s\n' "$C_OK"   "$C_0" "$*"
    fi
}
same()    { [ "$QUIET" -eq 1 ] || printf '  %sok%s       %s\n' "$C_DIM" "$C_0" "$*"; }
warn()    { WARNED=$((WARNED + 1)); printf '  %swarn%s     %s\n' "$C_WARN" "$C_0" "$*" >&2; }
die()     { printf '%serror:%s %s\n' "$C_ERR" "$C_0" "$*" >&2; exit 1; }

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        [ "$QUIET" -eq 1 ] || printf '  %swould run%s  %s\n' "$C_DIM" "$C_0" "$*"
        return 0
    fi
    "$@"
}

usage() {
    cat <<HELPTEXT
$PROG $VERSION — idempotently grant SSH access to a Linux or macOS endpoint.

USAGE
    $0 [options]

Installs the public key(s) from keys/authorized.pub into the target user's
authorized_keys, and trusts the CA(s) in keys/ca.pub so certificates they
signed are accepted. Run it as many times as you like.

OPTIONS
    -u, --user USER    Target user (default: \$SUDO_USER if set, else you)
    -k, --key FILE     Public key file       (default: $SELF_DIR/keys/authorized.pub)
    -c, --ca FILE      CA public key file    (default: $SELF_DIR/keys/ca.pub)
    -s, --system       Also trust the CA host-wide via sshd's TrustedUserCAKeys.
                       Requires root; without it CA trust is per-user only.
        --no-reload    Change sshd config but do not reload the daemon
        --remove       Undo: strip the managed blocks and system CA file
    -n, --dry-run      Show what would change, touch nothing
    -q, --quiet        Only warnings and errors
    -h, --help         This text

EXAMPLES
    ./bootstrap.sh                      # per-user trust, no root needed
    sudo ./bootstrap.sh -u deploy -s    # user + host-wide CA trust
    ./bootstrap.sh --dry-run            # preview
    ./push.sh web-1 web-2 -- --system   # run it on several hosts
HELPTEXT
}

# ----------------------------------------------------------------- utils ----

have() { command -v "$1" >/dev/null 2>&1; }

home_of() {
    _u=$1; _h=""
    if have getent; then
        _h=$(getent passwd "$_u" 2>/dev/null | cut -d: -f6) || _h=""
    fi
    if [ -z "$_h" ] && have dscl; then
        _h=$(dscl . -read "/Users/$_u" NFSHomeDirectory 2>/dev/null |
             sed -n 's/^NFSHomeDirectory: //p') || _h=""
    fi
    if [ -z "$_h" ] && [ -r /etc/passwd ]; then
        _h=$(awk -F: -v u="$_u" '$1==u{print $6; exit}' /etc/passwd) || _h=""
    fi
    printf '%s' "$_h"
}

find_sshd() {
    for _p in /usr/sbin/sshd /sbin/sshd /usr/local/sbin/sshd /opt/homebrew/sbin/sshd; do
        [ -x "$_p" ] && { printf '%s' "$_p"; return 0; }
    done
    command -v sshd 2>/dev/null || printf ''
}

# Emit the key lines of a public-key file: blanks and comments dropped.
key_lines() {
    sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d' "$1"
}

# Reject anything that is not a usable public key. Checks every line, not just
# the file as a whole: ssh-keygen -l happily fingerprints a *private* key file,
# so a file-level check would let private material into authorized_keys.
validate_pub() {
    _f=$1; _role=$2
    [ -f "$_f" ] || die "$_role file not found: $_f"
    [ -s "$_f" ] || die "$_role file is empty: $_f"

    if grep -q 'PRIVATE KEY' "$_f"; then
        die "$_f contains a PRIVATE key. Only public keys belong here.
The public half is the matching .pub file, or: ssh-keygen -y -f $_f"
    fi

    key_lines "$_f" > "$TMP/kl"
    _n=$(wc -l < "$TMP/kl" | tr -d ' ')
    [ "${_n:-0}" -gt 0 ] ||
        die "no keys in $_f — add your $_role (see $SELF_DIR/keys/README.md)"

    _i=0
    while IFS= read -r _line; do
        _i=$((_i + 1))
        printf '%s\n' "$_line" > "$TMP/one"
        _out=$(ssh-keygen -l -f "$TMP/one" 2>&1) ||
            die "$_f line $_i is not a valid SSH public key:
  $_line
ssh-keygen said: $_out
Each line must be a bare public key — type, base64, optional comment."

        case "$_out" in
          *-CERT\)*)
            if [ "$_role" = "CA public key" ]; then
                die "$_f line $_i is a certificate, not a CA public key.

A certificate cannot be used to trust its own issuer: it carries only the CA's
fingerprint, not the CA's key, so sshd has nothing to verify future certs with.
Run  ssh-keygen -L -f $_f  — the \"Signing CA\" line names the key you need, and
you copy that key's .pub file here."
            fi
            die "$_f line $_i is a certificate, not a public key. Use the plain .pub." ;;
        esac
    done < "$TMP/kl"
}

# Replace (or insert) our managed block in a file. Returns 1 if already correct.
apply_block() {
    _file=$1; _block=$2; _mode=$3; _owner=$4

    _cur=""
    if [ -f "$_file" ]; then
        _nb=$(grep -cxF "$BEGIN_MARK" "$_file" || true)
        _ne=$(grep -cxF "$END_MARK" "$_file" || true)
        if [ "$_nb" != "$_ne" ] || [ "$_nb" -gt 1 ]; then
            die "$_file has malformed $PROG markers ($_nb begin, $_ne end).
Fix it by hand, then re-run."
        fi
        _cur=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" \
                   '$0==b{i=1} i{print} $0==e{i=0}' "$_file")
    fi

    [ "$_cur" = "$_block" ] && return 1

    if [ "$DRY_RUN" -eq 1 ]; then
        [ -n "$_cur" ] && say "  ${C_DIM}would replace managed block in${C_0} $_file" \
                       || say "  ${C_DIM}would add managed block to${C_0} $_file"
        return 0
    fi

    _tmp=$TMP/blk.$$
    if [ -f "$_file" ]; then
        cp -p -- "$_file" "$_file.bak.$(date +%Y%m%d%H%M%S)"
        awk -v b="$BEGIN_MARK" -v e="$END_MARK" \
            '$0==b{i=1;next} $0==e{i=0;next} !i{print}' "$_file" > "$_tmp"
    else
        : > "$_tmp"
    fi
    # Guarantee the block starts on its own line even if the file lacked a
    # trailing newline (command substitution strips one, so a file ending in
    # "\n" yields an empty result here and nothing is added).
    if [ -s "$_tmp" ] && [ -n "$(tail -c 1 "$_tmp")" ]; then
        printf '\n' >> "$_tmp"
    fi
    printf '%s\n' "$_block" >> "$_tmp"

    chmod "$_mode" "$_tmp"
    [ -n "$_owner" ] && chown "$_owner" "$_tmp" 2>/dev/null || true
    mv -f -- "$_tmp" "$_file"
    return 0
}

remove_block() {
    _file=$1
    [ -f "$_file" ] || return 1
    grep -qxF "$BEGIN_MARK" "$_file" || return 1
    if [ "$DRY_RUN" -eq 1 ]; then
        say "  ${C_DIM}would strip managed block from${C_0} $_file"; return 0
    fi
    _tmp=$TMP/rm.$$
    cp -p -- "$_file" "$_file.bak.$(date +%Y%m%d%H%M%S)"
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" \
        '$0==b{i=1;next} $0==e{i=0;next} !i{print}' "$_file" > "$_tmp"
    cat "$_tmp" > "$_file"
    rm -f "$_tmp"
    return 0
}

# ------------------------------------------------------------------- args ----

while [ $# -gt 0 ]; do
    case $1 in
        -u|--user)   TARGET_USER=${2:?--user needs a value}; shift 2 ;;
        -k|--key)    KEY_FILE=${2:?--key needs a value};     shift 2 ;;
        -c|--ca)     CA_FILE=${2:?--ca needs a value};       shift 2 ;;
        -s|--system) DO_SYSTEM=1;  shift ;;
        -n|--dry-run) DRY_RUN=1;   shift ;;
        -q|--quiet)  QUIET=1;      shift ;;
        --no-reload) DO_RELOAD=0;  shift ;;
        --remove)    DO_REMOVE=1;  shift ;;
        -h|--help)   usage; exit 0 ;;
        --version)   printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
        --)          shift; break ;;
        *)           die "unknown option: $1 (try --help)" ;;
    esac
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-ssh.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

: "${KEY_FILE:=$SELF_DIR/keys/authorized.pub}"
: "${CA_FILE:=$SELF_DIR/keys/ca.pub}"

# ------------------------------------------------------------ target user ----

if [ -z "$TARGET_USER" ]; then
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        TARGET_USER=$SUDO_USER
    else
        TARGET_USER=$(id -un)
    fi
fi

if [ "$TARGET_USER" = "$(id -un)" ]; then
    TARGET_HOME=${HOME:-$(home_of "$TARGET_USER")}
else
    TARGET_HOME=$(home_of "$TARGET_USER")
fi
[ -n "$TARGET_HOME" ] || die "cannot resolve home directory for user '$TARGET_USER'"
[ -d "$TARGET_HOME" ] || die "home directory does not exist: $TARGET_HOME"

IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1
if [ "$IS_ROOT" -eq 0 ] && [ "$TARGET_USER" != "$(id -un)" ]; then
    die "writing to another user's account needs root — re-run under sudo"
fi

SSH_DIR=$TARGET_HOME/.ssh
AUTH_KEYS=$SSH_DIR/authorized_keys
OWNER=""
[ "$IS_ROOT" -eq 1 ] && OWNER="$TARGET_USER"

say "${C_B}$PROG $VERSION${C_0}  ${C_DIM}$OS · user $TARGET_USER · $TARGET_HOME${C_0}"
[ "$DRY_RUN" -eq 1 ] && say "${C_WARN}dry run — nothing will be modified${C_0}"
say ""

# ----------------------------------------------------------------- remove ----

if [ "$DO_REMOVE" -eq 1 ]; then
    step "Removing $PROG configuration"
    if remove_block "$AUTH_KEYS"; then changed "stripped block from $AUTH_KEYS"
    else same "no managed block in $AUTH_KEYS"; fi
    if [ "$IS_ROOT" -eq 1 ] || [ -n "$ETC" ]; then
        for f in "$SYS_DROPIN" "$SYS_CA_FILE"; do
            if [ -f "$f" ]; then run rm -f "$f"; changed "removed $f"
            else same "absent $f"; fi
        done
        if remove_block "$SSHD_CONFIG"; then changed "stripped block from $SSHD_CONFIG"; fi
    fi
    say ""
    say "Removed. Existing sessions are unaffected; reload sshd to apply."
    exit 0
fi

# --------------------------------------------------------- key material ----

step "Validating key material"
validate_pub "$KEY_FILE" "public key"
validate_pub "$CA_FILE"  "CA public key"

ssh-keygen -l -f "$KEY_FILE" | while read -r line; do say "  key      $line"; done
ssh-keygen -l -f "$CA_FILE"  | while read -r line; do say "  CA       $line"; done

# ----------------------------------------------------- user-level install ----

step "Configuring $AUTH_KEYS"

if [ ! -d "$SSH_DIR" ]; then
    run mkdir -p "$SSH_DIR"
    [ -n "$OWNER" ] && run chown "$OWNER" "$SSH_DIR"
    changed "created $SSH_DIR"
fi
run chmod 700 "$SSH_DIR"

{
    printf '%s\n%s\n' "$BEGIN_MARK" "$BLOCK_NOTE"
    key_lines "$KEY_FILE"
    key_lines "$CA_FILE" | sed 's/^/cert-authority /'
    printf '%s\n' "$END_MARK"
} > "$TMP/block"

if apply_block "$AUTH_KEYS" "$(cat "$TMP/block")" 600 "$OWNER"; then
    changed "installed $(key_lines "$KEY_FILE" | wc -l | tr -d ' ') key(s) + $(key_lines "$CA_FILE" | wc -l | tr -d ' ') CA(s)"
else
    same "authorized_keys already correct"
fi

# Flag copies of the same key living outside our block: they are not errors,
# but they will survive --remove and quietly keep access open.
if [ -f "$AUTH_KEYS" ]; then
    key_lines "$KEY_FILE" | while read -r kline; do
        blob=$(printf '%s\n' "$kline" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^AAAA/) {print $i; exit}}')
        [ -n "$blob" ] || continue
        if awk -v b="$BEGIN_MARK" -v e="$END_MARK" \
               '$0==b{i=1} $0==e{i=0;next} !i' "$AUTH_KEYS" |
           grep -qF "$blob"; then
            warn "this key also appears outside the managed block in $AUTH_KEYS"
        fi
    done
fi

# --------------------------------------------------- system-wide CA trust ----

sshd_reload() {
    if [ "$OS" = Darwin ]; then
        if launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
            run launchctl kickstart -k system/com.openssh.sshd && return 0
        fi
        warn "sshd is not running (Remote Login off) — nothing to reload"
        return 0
    fi
    if have systemctl; then
        for unit in sshd ssh; do
            if systemctl is-active --quiet "$unit" 2>/dev/null; then
                run systemctl reload "$unit" && return 0
            fi
        done
    fi
    if have rc-service && rc-service sshd status >/dev/null 2>&1; then
        run rc-service sshd reload && return 0
    fi
    if have service; then
        for unit in sshd ssh; do
            run service "$unit" reload >/dev/null 2>&1 && return 0
        done
    fi
    warn "could not reload sshd automatically — do it by hand to apply CA trust"
    return 0
}

if [ "$DO_SYSTEM" -eq 1 ]; then
    step "Configuring host-wide CA trust"
    if [ "$IS_ROOT" -eq 0 ] && [ -z "$ETC" ]; then
        die "--system needs root — re-run under sudo"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        say "  ${C_DIM}would write${C_0} $SYS_CA_FILE"
    elif [ -f "$SYS_CA_FILE" ] && cmp -s "$CA_FILE" "$SYS_CA_FILE"; then
        same "$SYS_CA_FILE up to date"
    else
        cp -- "$CA_FILE" "$TMP/ca.pub"
        chmod 644 "$TMP/ca.pub"; chown 0:0 "$TMP/ca.pub" 2>/dev/null || true
        mv -f -- "$TMP/ca.pub" "$SYS_CA_FILE"
        changed "wrote $SYS_CA_FILE"
    fi

    # Refuse to fight with a CA trust setting that someone else put there.
    existing=$(awk 'tolower($1)=="trustedusercakeys"{print $2}' \
                   "$SSHD_CONFIG" 2>/dev/null | head -1) || existing=""
    if [ -n "$existing" ] && [ "$existing" != "$SYS_CA_FILE" ]; then
        warn "$SSHD_CONFIG already sets TrustedUserCAKeys $existing"
        warn "leaving it alone — merge your CA into that file, or remove the line"
    else
        conf_target=$SSHD_CONFIG
        if grep -qE '^[[:space:]]*Include[[:space:]]+.*/etc/ssh/sshd_config\.d/' \
                "$SSHD_CONFIG" 2>/dev/null; then
            conf_target=$SYS_DROPIN
            [ -d /etc/ssh/sshd_config.d ] || run mkdir -p /etc/ssh/sshd_config.d
        fi

        {
            printf '%s\n%s\n' "$BEGIN_MARK" "$BLOCK_NOTE"
            printf 'TrustedUserCAKeys %s\n' "$SYS_CA_FILE"
            printf '%s\n' "$END_MARK"
        } > "$TMP/sblock"

        # Keep a rollback point: a bad sshd_config locks everyone out on reload.
        rollback=""
        if [ "$DRY_RUN" -eq 0 ] && [ -f "$conf_target" ]; then
            rollback=$TMP/rollback.conf
            cp -p -- "$conf_target" "$rollback"
        fi

        if apply_block "$conf_target" "$(cat "$TMP/sblock")" 644 "0:0"; then
            changed "TrustedUserCAKeys set in $conf_target"

            SSHD_BIN=$(find_sshd)
            [ -n "$ETC" ] && SSHD_BIN=""   # sandboxed: real sshd is not involved
            if [ "$DRY_RUN" -eq 0 ] && [ -n "$SSHD_BIN" ]; then
                if err=$("$SSHD_BIN" -t 2>&1); then
                    same "sshd config validates"
                else
                    if [ -n "$rollback" ]; then cat "$rollback" > "$conf_target"
                    else rm -f "$conf_target"; fi
                    die "sshd rejected the new config — rolled back. It said:
$err"
                fi
            fi
            if [ "$DO_RELOAD" -eq 1 ] && [ -z "$ETC" ]
                then sshd_reload
                else say "  ${C_DIM}reload skipped${C_0}"
            fi
        else
            same "TrustedUserCAKeys already set in $conf_target"
        fi
    fi
fi

# ------------------------------------------------------- platform sanity ----
#
# Everything below only reports. These are the conditions that make a
# correctly-installed key silently fail to log you in.

step "Checking the endpoint will actually accept the key"

# SELinux: sshd cannot read authorized_keys without the right label.
if have restorecon && have getenforce && [ "$(getenforce 2>/dev/null)" != Disabled ]; then
    if [ "$IS_ROOT" -eq 1 ]; then
        run restorecon -RF "$SSH_DIR" >/dev/null 2>&1 || true
        same "SELinux labels restored on $SSH_DIR"
    else
        warn "SELinux is enforcing; run once as root so labels get fixed"
    fi
fi

# StrictModes: a group- or world-writable home makes sshd ignore the keys.
if find "$TARGET_HOME" -maxdepth 0 \( -perm -0020 -o -perm -0002 \) 2>/dev/null |
   grep -q .; then
    warn "$TARGET_HOME is group/other-writable — sshd StrictModes will reject it"
    warn "fix with: chmod go-w $TARGET_HOME"
else
    same "home directory permissions ok"
fi

# A non-default AuthorizedKeysFile would send sshd looking somewhere else.
SSHD_BIN=${SSHD_BIN:-$(find_sshd)}
if [ "$IS_ROOT" -eq 1 ] && [ -n "$SSHD_BIN" ]; then
    if eff=$("$SSHD_BIN" -T -C "user=$TARGET_USER,host=localhost,addr=127.0.0.1" \
             2>/dev/null); then
        akf=$(printf '%s\n' "$eff" | awk 'tolower($1)=="authorizedkeysfile"{$1="";print}')
        case "$akf" in
            *".ssh/authorized_keys"*) same "sshd reads .ssh/authorized_keys" ;;
            "") ;;
            *) warn "sshd reads AuthorizedKeysFile:$akf — not the file we wrote" ;;
        esac
        tuck=$(printf '%s\n' "$eff" | awk 'tolower($1)=="trustedusercakeys"{print $2}')
        [ -n "$tuck" ] && [ "$tuck" != none ] && same "sshd trusts CA file $tuck"
        pka=$(printf '%s\n' "$eff" | awk 'tolower($1)=="pubkeyauthentication"{print $2}')
        [ "$pka" = no ] && warn "PubkeyAuthentication is disabled in sshd config!"
    fi
fi

if [ "$OS" = Darwin ]; then
    if launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
        same "Remote Login is on"
    else
        warn "Remote Login is OFF — enable it in System Settings > General >"
        warn "Sharing > Remote Login, or: sudo systemsetup -setremotelogin on"
    fi
    # If access is restricted to a group, the user must be in it.
    if dseditgroup -o read com.apple.access_ssh >/dev/null 2>&1; then
        if dseditgroup -o checkmember -m "$TARGET_USER" com.apple.access_ssh \
           2>/dev/null | grep -q '^yes'; then
            same "$TARGET_USER is allowed by com.apple.access_ssh"
        else
            warn "Remote Login is limited to specific users and $TARGET_USER is"
            warn "not among them. Add them in Sharing > Remote Login, or:"
            warn "  sudo dseditgroup -o edit -a $TARGET_USER -t user com.apple.access_ssh"
        fi
    else
        same "Remote Login is open to all users"
    fi
fi

if [ "$DO_SYSTEM" -eq 0 ]; then
    say "  ${C_DIM}note${C_0}     CA trusted for $TARGET_USER only; use --system for host-wide"
fi

# ---------------------------------------------------------------- summary ----

say ""
if [ "$DRY_RUN" -eq 1 ]; then
    say "${C_B}Dry run complete.${C_0} Re-run without --dry-run to apply."
elif [ "$CHANGED" -eq 0 ]; then
    say "${C_OK}Already bootstrapped.${C_0} Nothing changed."
else
    say "${C_OK}Bootstrapped.${C_0} $CHANGED change(s) applied."
fi
[ "$WARNED" -gt 0 ] && say "${C_WARN}$WARNED warning(s) above — read them before you close the session.${C_0}"

say ""
say "${C_DIM}Verify from your workstation, keeping this session open as a fallback:${C_0}"
say "  ssh -o PreferredAuthentications=publickey $TARGET_USER@$(hostname 2>/dev/null || echo HOST)"
exit 0
