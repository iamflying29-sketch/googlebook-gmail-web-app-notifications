#!/bin/bash
# Builds and signs GmailGhost.apk with the Android SDK in ~/tools/android-sdk and the Kotlin
# compiler in ~/tools/kotlin/kotlinc. The ghost's own files (ghost.sh, env.sh and node-wrap.sh from
# googlebook/device, and ghostd.py) are bundled into the app as assets, so the app can install them
# on the Googlebook. A fresh build directory is used each time; nothing is
# ever deleted.
set -euo pipefail
cd "$(dirname "$0")"
SDK="${ANDROID_SDK:-$HOME/tools/android-sdk}"
KOTLIN="${KOTLIN_HOME:-$HOME/tools/kotlin/kotlinc}"
BT=$SDK/build-tools/35.0.0
JAR=$SDK/platforms/android-35/android.jar
KS=keystore.jks
KS_PASS_FILE="$HOME/.config/gmail-ghost-app/app-signing.pass"
VERSION_NAME=1.0
VERSION_CODE=$(( $(date +%s) / 60 ))   # epoch minutes: always increases, never a downgrade

B=build/$(date +%Y%m%d-%H%M%S)
mkdir -p "$B/classes" "$B/gen" "$B/assets"
# In the repository the ghost's files sit beside this folder; otherwise in ~/projects.
if [ -d ../googlebook/device ] && [ -f ../ghostd.py ]; then DEVDIR=../googlebook/device; GHOSTD=../ghostd.py
else DEVDIR="$HOME"/projects/gmailghost-device/device; GHOSTD="$HOME"/projects/gmail-ghost/ghostd.py; fi
cp "$DEVDIR"/ghost.sh "$DEVDIR"/env.sh "$DEVDIR"/node-wrap.sh "$GHOSTD" "$B/assets/"

"$BT/aapt2" compile --dir res -o "$B/res.zip"
"$BT/aapt2" link -o "$B/unsigned.apk" -I "$JAR" --manifest AndroidManifest.xml -A "$B/assets" \
    --min-sdk-version 34 --target-sdk-version 35 --version-code $VERSION_CODE --version-name $VERSION_NAME \
    --java "$B/gen" "$B/res.zip"
javac -Xlint:-options -source 11 -target 11 -cp "$JAR" -d "$B/classes" "$B/gen/local/gmailghost/R.java"
"$KOTLIN/bin/kotlinc" -jvm-target 11 -no-reflect -cp "$JAR:$B/classes" -d "$B/classes" \
    $(find src/kotlin -name '*.kt') 2>&1 | grep -vE "^warning:|^w: " || true
test -f "$B/classes/local/gmailghost/MainActivity.class" || { echo "Kotlin compilation failed"; exit 1; }
"$BT/d8" --min-api 34 --lib "$JAR" --output "$B" $(find "$B/classes" -name '*.class') "$KOTLIN/lib/kotlin-stdlib.jar"
python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1], "a").write(sys.argv[2], "classes.dex")' \
    "$B/unsigned.apk" "$B/classes.dex"
"$BT/zipalign" -p -f 4 "$B/unsigned.apk" "$B/aligned.apk"
if [ ! -f "$KS_PASS_FILE" ]; then
    mkdir -p "$(dirname "$KS_PASS_FILE")"
    head -c 24 /dev/urandom | base64 | tr -d '/+=' > "$KS_PASS_FILE"
    chmod 600 "$KS_PASS_FILE"
fi
KS_PASS=$(cat "$KS_PASS_FILE")
if [ ! -f "$KS" ]; then
    keytool -genkeypair -keystore "$KS" -storepass "$KS_PASS" -keypass "$KS_PASS" -alias gmailghost \
        -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Gmail Ghost (local build)"
fi
"$BT/apksigner" sign --ks "$KS" --ks-pass "pass:$KS_PASS" --out GmailGhost.apk "$B/aligned.apk"
"$BT/apksigner" verify GmailGhost.apk
echo "Built $(pwd)/GmailGhost.apk (version $VERSION_NAME, code $VERSION_CODE)"
