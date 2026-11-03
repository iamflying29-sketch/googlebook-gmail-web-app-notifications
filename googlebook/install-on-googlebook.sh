#!/bin/bash
# Puts the Gmail Ghost on the Googlebook itself, so Mark as read never needs the Linux Terminal:
#   1. builds the runtime (build-runtime.sh) unless one is named or one is already built in dist/,
#   2. streams it into /data/local/tmp/gmailghost/rt-<stamp> and points rt at it,
#   3. copies the signed-in Gmail profiles (without locks and caches) into profiles/,
#   4. installs ghost.sh, env.sh, node-wrap.sh and ghostd.py, and starts the ghost.
# Run it on a Linux computer that has adb connected to the Googlebook. The Gmail Ghost app keeps the
# ghost running after that. It never deletes anything: each runtime gets a folder of its own, and a
# profile that already exists on the Googlebook is left as it is.
#
#   ./install-on-googlebook.sh <ip:port> [dist/rt-<stamp>]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SERIAL=${1:?usage: $0 <ip:port> [dist/rt-<stamp>]}
RT=${2:-}
# The ghost's own folder (ghostd.py and profiles/): the folder above this one in the repository, or GHOST_DIR.
if [ -n "${GHOST_DIR:-}" ]; then GHOST=$GHOST_DIR
elif [ -f "$HERE/../ghostd.py" ]; then GHOST=$(cd "$HERE/.." && pwd)
else GHOST=$HOME/projects/gmail-ghost; fi
G=/data/local/tmp/gmailghost
A="timeout 60 adb -s $SERIAL"

# Without a named runtime, the newest one already built in dist/ is used, so running this again does
# not build and copy a new 490 MB runtime each time. Only when there is none is one built.
if [ -z "$RT" ]; then
    RT=$(ls -d "$HERE"/dist/rt-* 2>/dev/null | grep -v '\.tar$' | sort | tail -1 || true)
    if [ -z "$RT" ]; then
        "$HERE"/build-runtime.sh
        RT=$(ls -d "$HERE"/dist/rt-* | grep -v '\.tar$' | sort | tail -1)
    fi
fi
RT=$(cd "$RT" && pwd)
NAME=$(basename "$RT")
[ -f "$RT.tar" ] || ( cd "$(dirname "$RT")" && tar -cf "$NAME.tar" "$NAME" )

$A shell "umask 077; mkdir -p $G/logs $G/profiles && chmod 700 $G $G/profiles"
if [ "$($A shell "[ -d $G/$NAME ] && echo yes" | tr -d '\r')" != yes ]; then
    echo "streaming the runtime $NAME to the Googlebook"
    timeout 900 adb -s "$SERIAL" exec-in sh -c "cd $G && tar -xf -" < "$RT.tar"
fi
$A shell "cd $G && ln -sfn $NAME rt && cat rt/VERSION"

# Profiles: one folder per account, named by the account address. profile-gmail is the main account's
# folder in the Linux install (profiles/<address> links to it there), so links are followed.
# A folder of links only, in the temporary folder (cleared at every restart), so nothing piles up.
STAGE=$(mktemp -d -p "${TMPDIR:-/tmp}" gmailghost-profiles.XXXX)
mkdir -p "$STAGE/profiles"
for p in "$GHOST"/profiles/*@*; do
    name=$(basename "$p")
    case "$name" in .*) continue ;; esac
    if [ "$($A shell "[ -d '$G/profiles/$name' ] && echo yes" | tr -d '\r')" = yes ]; then
        echo "profile $name is already on the Googlebook; left as it is"
        continue
    fi
    ln -s "$(readlink -f "$p")" "$STAGE/profiles/$name"
done
if [ -n "$(ls -A "$STAGE/profiles")" ]; then
    ( cd "$STAGE" && tar -chf - --exclude='Singleton*' --exclude='*/Cache' --exclude='*/Code Cache' \
          --exclude='*/GPUCache' --exclude='*.pma' profiles ) |
        timeout 900 adb -s "$SERIAL" exec-in sh -c "umask 077; cd $G && tar -xf - && chmod 700 profiles/*"
fi

timeout 60 adb -s "$SERIAL" push "$HERE"/device/ghost.sh "$HERE"/device/env.sh "$HERE"/device/node-wrap.sh \
    "$GHOST"/ghostd.py $G/ >/dev/null
$A shell "cd $G && chmod 755 ghost.sh node-wrap.sh && chmod 644 env.sh ghostd.py && sh ghost.sh start && sleep 8 && sh ghost.sh status"
