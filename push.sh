#!/bin/sh
# push.sh — run bootstrap.sh on one or more remote endpoints.
#
#   ./push.sh web-1 web-2 db-1
#   ./push.sh --sudo web-1 -- --system      # args after -- go to bootstrap.sh
#   cat hosts.txt | ./push.sh -             # hosts on stdin, one per line
#
# The script and keys are streamed over the existing ssh connection into a
# temporary directory on the remote, run, and deleted. Nothing is left behind
# and no dependency beyond tar and sh is required on the far end.

set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
USE_SUDO=0
READ_STDIN=0
HOSTS=""
BOOT_ARGS=""
FAILED=""
SSH_OPTS="-o ConnectTimeout=10"

while [ $# -gt 0 ]; do
    case $1 in
        --sudo) USE_SUDO=1; shift ;;
        -)      READ_STDIN=1; shift ;;
        --)     shift; BOOT_ARGS="$*"; break ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)     SSH_OPTS="$SSH_OPTS $1"; shift ;;
        *)      HOSTS="$HOSTS $1"; shift ;;
    esac
done

[ "$READ_STDIN" -eq 1 ] && HOSTS="$HOSTS $(cat)"
[ -n "$(printf '%s' "$HOSTS" | tr -d ' ')" ] || {
    echo "usage: $0 [--sudo] host [host...] [-- bootstrap args]" >&2; exit 1; }

# --system implies root on the far side.
case " $BOOT_ARGS " in *" --system "*|*" -s "*) USE_SUDO=1 ;; esac

PREFIX=""; TTY=""
if [ "$USE_SUDO" -eq 1 ]; then
    PREFIX="sudo -p 'sudo password for %u@%H: '"
    TTY="-t"   # so sudo and any host-key prompt can reach the terminal
fi

for host in $HOSTS; do
    printf '\n\033[1m===== %s =====\033[0m\n' "$host"
    # shellcheck disable=SC2086
    if tar cf - -C "$SELF_DIR" bootstrap.sh keys |
       ssh $TTY $SSH_OPTS "$host" \
           "set -e
            d=\$(mktemp -d) && trap 'rm -rf \"\$d\"' EXIT INT TERM
            tar xf - -C \"\$d\"
            $PREFIX sh \"\$d/bootstrap.sh\" $BOOT_ARGS"
    then :; else
        FAILED="$FAILED $host"
        printf '\033[31mFAILED: %s\033[0m\n' "$host" >&2
    fi
done

if [ -n "$FAILED" ]; then
    printf '\n\033[31mFailed on:%s\033[0m\n' "$FAILED" >&2
    exit 1
fi
printf '\n\033[32mAll hosts bootstrapped.\033[0m\n'
