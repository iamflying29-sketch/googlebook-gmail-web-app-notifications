#!/usr/bin/env bash
#
# setup.sh - one-shot installer for the Gmail ghost mark-as-read daemon on a Googlebook's Linux VM.
#
# It is idempotent: safe to re-run. It does everything automatable; the only human steps are the
# ones Google forces (signing in to each Gmail account once) and, the first time, pairing adb.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
say() { printf "\n\033[1m==> %s\033[0m\n" "$*"; }

# ---------------------------------------------------------------------------
say "1/6  Checking prerequisites (python3, adb, a display)"
for t in python3 adb stdbuf; do command -v "$t" >/dev/null || { echo "MISSING: $t"; exit 1; }; done
[ -n "${DISPLAY:-}" ] || export DISPLAY=:0
echo "ok (DISPLAY=$DISPLAY)"

# ---------------------------------------------------------------------------
say "2/6  Python venv + Playwright + Chromium"
if [ ! -x venv/bin/python ]; then python3 -m venv venv; fi
venv/bin/pip -q install --upgrade pip
venv/bin/pip -q install -r requirements.txt
venv/bin/playwright install chromium
echo "ok"

# ---------------------------------------------------------------------------
say "3/6  Connecting to the Googlebook over adb"
# Try an existing connection first; otherwise explain how to pair Wireless debugging.
SERIAL="${ANDROID_SERIAL:-}"
if [ -z "$SERIAL" ]; then
  SERIAL="$(adb devices | awk 'NR>1 && $2=="device"{print $1; exit}')"
fi
if [ -z "$SERIAL" ]; then
  cat <<'EOF'
No adb device found. One-time pairing (on the Googlebook):
  Settings > System > Developer options > Wireless debugging > ON
  "Pair device with pairing code" - note the IP:PORT and the 6-digit code, then run:
      adb pair <IP>:<PAIR_PORT>        (enter the code)
      adb connect <IP>:<CONNECT_PORT>
Re-run setup.sh afterwards.
EOF
  exit 1
fi
echo "ANDROID_SERIAL=$SERIAL" > ghost.env
echo "connected: $SERIAL"

# ---------------------------------------------------------------------------
say "4/6  Installing the ghost daemon as an autostart service"
mkdir -p "$HOME/.config/systemd/user"
# The service reads the adb address from ghost.env (written above), so it is not baked in here.
sed "s|__ROOT__|$ROOT|g; s|__UID__|$(id -u)|g" systemd/ghostd.service.in \
    > "$HOME/.config/systemd/user/ghostd.service"
systemctl --user daemon-reload
systemctl --user enable ghostd.service
systemctl --user restart ghostd.service
# keep it running without an active login, if we're allowed
sudo -n loginctl enable-linger "$USER" 2>/dev/null || echo "(note: run 'sudo loginctl enable-linger $USER' to keep it running when logged out)"
sleep 2
echo "daemon: $(systemctl --user is-active ghostd.service)"

# ---------------------------------------------------------------------------
say "5/6  Android side: Notification Keeper and its permissions (notif-restore apply)"
# notif-restore installs Notification Keeper if it is missing (from $KEEPER_APK) and re-applies its
# permissions. It does NOT install or set up Gmail Go and does NOT turn on the accessibility helper;
# those are manual steps (see README).
NOTIF_RESTORE="$(command -v notif-restore || true)"
[ -n "$NOTIF_RESTORE" ] || NOTIF_RESTORE="$ROOT/bin/notif-restore"
if [ -x "$NOTIF_RESTORE" ]; then
  "$NOTIF_RESTORE" apply "$SERIAL" || echo "(notif-restore reported an issue; see its output)"
else
  echo "notif-restore not found. Install NotificationKeeper.apk and set up its permissions manually (see README)."
fi

# ---------------------------------------------------------------------------
say "6/6  Sign in to your Gmail accounts (one-time, Google requires a human)"
echo "Accounts on this device:"
./ghostctl list
echo
echo "For each Gmail account you want instant Mark-as-read, run:  ./ghostctl enable <account>"
echo "A window opens; sign in once; it's saved for weeks."
echo
say "Done. Check status any time with:  ./ghostctl status"
