#!/bin/bash
# Builds the Gmail Ghost runtime for GooglebookOS: the same Python, Playwright and headless Chromium
# the ghost uses on Linux, plus every library they need, made to run on the Googlebook itself as the
# adb shell user from /data/local/tmp/gmailghost.
#
# Run it on a Linux x86-64 computer (the Googlebook's Linux Terminal works) after setup.sh has created
# the ghost's venv and installed Playwright's headless Chromium. The Googlebook is x86-64 too, so these
# programs run there natively.
#
# Android has no /lib64 loader, no /etc/resolv.conf and no /etc/fonts, so:
#   * Chromium gets its loader and library path pointed at the runtime folder (patchelf), while
#     Python and Playwright's node are started through the runtime's loader by ghost.sh (patchelf
#     damages those two fixed-address programs), and
#   * the runtime's own copy of the C library reads its DNS settings from /sdcard/.ggdns instead of
#     /etc/resolv.conf (a string of the same length, written by ghost.sh at every start), and
#   * fonts, temporary files, the time zone and the home folder are set through the environment
#     (env.sh).
#
# Output: a dated folder dist/rt-<stamp> and a tar of it. Never deletes anything.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# The ghost's own folder (ghostd.py and its venv): the folder above this one in the repository, or
# GHOST_DIR.
if [ -n "${GHOST_DIR:-}" ]; then GHOST=$GHOST_DIR
elif [ -f "$HERE/../ghostd.py" ]; then GHOST=$(cd "$HERE/.." && pwd)
else GHOST=$HOME/projects/gmail-ghost; fi
DEV=/data/local/tmp/gmailghost
RTDEV=$DEV/rt
STAMP=$(date -u +%Y%m%d-%H%M%S)
OUT=$HERE/dist/rt-$STAMP
PATCHELF=${PATCHELF:-$(command -v patchelf || echo "$HOME/tools/patchelf-venv/bin/patchelf")}
VPY=$GHOST/venv/bin/python
[ -x "$VPY" ] || { echo "no venv in $GHOST (run setup.sh first)"; exit 1; }
[ -x "$PATCHELF" ] || { echo "patchelf is needed: apt install patchelf, or pip install patchelf in a venv and set PATCHELF"; exit 1; }

# Ask Python and Playwright where everything is, so any version works.
PYEXE=$("$VPY" -c 'import os, sys; print(os.path.realpath(sys.executable))')
STDLIB=$("$VPY" -c 'import sysconfig; print(sysconfig.get_paths()["stdlib"])')
SITE=$("$VPY" -c 'import os, playwright; print(os.path.dirname(os.path.dirname(playwright.__file__)))')
SHELL_HOME=$("$VPY" -m playwright install --dry-run chromium-headless-shell 2>/dev/null |
             awk '/Install location:/ && /chromium_headless_shell/ {print $3; exit}')
[ -d "$SHELL_HOME" ] || { echo "Playwright's headless Chromium is not installed (run: $VPY -m playwright install chromium-headless-shell)"; exit 1; }
SHELL_NAME=$(basename "$SHELL_HOME")
SHELL_BIN=$(find "$SHELL_HOME" -maxdepth 2 -type f -name chrome-headless-shell | head -1)

mkdir -p "$OUT"/lib "$OUT"/py/bin "$OUT"/py/lib "$OUT"/site "$OUT"/browsers "$OUT"/fonts "$OUT"/etc/fonts "$OUT"/zoneinfo

# Python: the interpreter and its standard library (lib-dynload included).
cp -L "$PYEXE" "$OUT"/py/bin/"$(basename "$PYEXE")"
cp -a "$STDLIB" "$OUT"/py/lib/

# The ghost's packages, exactly as installed in the venv (pip is not needed on the Googlebook).
for p in "$SITE"/*; do
    case "$(basename "$p")" in pip|pip-*|__pycache__|setuptools*|_distutils_hack|distutils-precedence.pth) continue ;; esac
    cp -a "$p" "$OUT"/site/
done

# Headless Chromium, as Playwright installed it.
mkdir -p "$OUT"/browsers/"$SHELL_NAME"
cp -a "$SHELL_HOME"/. "$OUT"/browsers/"$SHELL_NAME"/
SHELL_OUT=$OUT/browsers/$SHELL_NAME/${SHELL_BIN#"$SHELL_HOME"/}

# Fonts and a fontconfig file that points at them, plus the UTC zone file.
for f in /usr/share/fonts/truetype/dejavu /usr/share/fonts/truetype/liberation; do
    [ -d "$f" ] && cp -a "$f" "$OUT"/fonts/
done
cat > "$OUT"/etc/fonts/fonts.conf <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir>$RTDEV/fonts</dir>
  <cachedir>$DEV/home/.cache/fontconfig</cachedir>
  <config></config>
</fontconfig>
EOF
cp -L /usr/share/zoneinfo/UTC "$OUT"/zoneinfo/UTC

# Libraries: everything the programs and the libraries they open later need, flattened into lib/.
# NSS opens its crypto modules later from its own folder; find that folder through Chromium's libraries.
NSS=$(dirname "$(ldd "$SHELL_BIN" | awk '/libnss3\.so/ {print $3; exit}')")
[ -f "$NSS/libsoftokn3.so" ] || { echo "NSS modules not found next to libnss3 ($NSS)"; exit 1; }
python3 "$HERE"/collect.py "$OUT"/lib \
    "$OUT"/py/bin/"$(basename "$PYEXE")" \
    "$OUT"/site/playwright/driver/node \
    "$SHELL_OUT" \
    $(find "$OUT"/py/lib -path '*lib-dynload*' -name '*.so') $(find "$OUT"/site -name '*.so') \
    $(for l in libsoftokn3 libfreeblpriv3 libfreebl3 libnssckbi libnssdbm3 libsmime3 libssl3; do
          [ -f "$NSS/$l.so" ] && echo "$NSS/$l.so"; done)

# The runtime's C library reads DNS settings from /sdcard/.ggdns (Android has no /etc/resolv.conf).
python3 - "$OUT"/lib/libc.so.6 <<'EOF'
import sys
p = sys.argv[1]
d = open(p, 'rb').read()
old, new = b'/etc/resolv.conf\x00', b'/sdcard/.ggdns\x00\x00\x00'
assert len(old) == len(new) and d.count(old) == 1, 'unexpected libc layout'
open(p, 'wb').write(d.replace(old, new))
print('libc: DNS settings path now /sdcard/.ggdns')
EOF

# Point Chromium at the runtime's loader and libraries. Python and Playwright's node are fixed-address
# programs that patchelf damages, so they stay untouched and ghost.sh starts them through the loader
# (node through PLAYWRIGHT_NODEJS_PATH and the node-wrap.sh wrapper).
LOADER=$RTDEV/lib/ld-linux-x86-64.so.2
"$PATCHELF" --set-interpreter "$LOADER" --force-rpath --set-rpath "\$ORIGIN:$RTDEV/lib" "$SHELL_OUT"

echo "$STAMP" > "$OUT"/VERSION
( cd "$HERE"/dist && tar -cf "rt-$STAMP.tar" "rt-$STAMP" )
du -sh "$OUT" "$HERE/dist/rt-$STAMP.tar"
echo "built $OUT"
