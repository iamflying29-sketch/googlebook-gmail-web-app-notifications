# Gmail Web App Notification Issue

Real, lasting Gmail notifications for the Gmail web app on a Lenovo Googlebook 15 running GooglebookOS, even when
Gmail is completely closed. Each new email pops up, stays in the Notification Center until you deal with it, and has
three working buttons: Reply, Delete and Mark as read. The system is built from four parts: Google's Gmail Go app as
the push engine, the [Notification Keeper](https://github.com/iamflying29-sketch/googlebook-notification-keeper)
app, an accessibility helper inside Notification Keeper, and a small background service in the Linux Terminal. This
repository holds the Linux Terminal service, its account tools and a recovery script, and it is the complete setup
guide for the whole system, in order.

## What it does

This project gives the Gmail web app on my Googlebook real, lasting notifications, even when Gmail is completely
closed. Each new email pops up as its own notification, stays in the Notification Center until I deal with it, and
is grouped by account. Every email notification has three buttons: Reply, Delete and Mark as read. Tapping a
notification opens that email in the Gmail web app.

It has four parts:

| Part | Where it runs | Its job |
|---|---|---|
| Gmail Go, 2021 version | GooglebookOS | Receives Google's push messages and syncs new mail. It works only as the engine, and its own notifications are kept silent. |
| Notification Keeper | GooglebookOS | Turns each Gmail Go alert into a proper notification, removes duplicates, and guards Gmail's notification settings. |
| Gmail helper (an accessibility service inside Notification Keeper) | GooglebookOS | Carries out a tap, Reply or Delete in the Gmail web app window. |
| Ghost daemon (`ghostd.py`, this repository) | Linux Terminal | Handles Mark as read in a hidden browser, without opening any window. |

This repository contains the ghost daemon, its tools and the recovery script `notif-restore`. Notification Keeper
and its Gmail helper live in their own repository. Gmail Go is Google's app, and you get it yourself, as explained
in [Getting Gmail Go](#getting-gmail-go).

## The problem

On the Googlebook, Gmail is a web app. The Gmail app that GooglebookOS ships is a thin wrapper (a Trusted Web
Activity) that shows mail.google.com in Chrome. Its alerts are created by the open Gmail web page, and Gmail's own web
code withdraws each alert about 7 seconds after posting it. Android records the removal with reason 8, which means
the app itself cancelled it, so nothing is left in the Notification Center. When I close the window, GooglebookOS ends
the page. From then on nothing can notify at all, because Gmail's web code has no way to receive push messages while
it is closed: its service worker has no push handler. Do Not Disturb, notification settings, battery settings, rate
limits, snoozing and notification timeouts were all checked and ruled out.

Installing the full Gmail Android app did not solve it. On a Googlebook, the full app detects the desktop (Google's
server flag plus the system feature `com.google.desktop.gms`) and switches itself into the same web mode. It then
disables 84 of its own components for my Android user, including `FirebaseInstanceIdReceiver`, which receives push
messages, and the mail sync adapter. The adb shell is not allowed to switch those components back on: every attempt
ends with "Shell cannot change component state". Google Play also replaces the full app with the web wrapper when it
updates Gmail.

The newer 2022 version of Gmail Go targets Android 13 (SDK 33), where an app must ask for permission to post
notifications. It never asks, so Android blocks all of its notifications.

## How I solved it

### 1. Gmail Go as the push engine

The 2021 version of Gmail Go (2021.11.03.429633235, target SDK 31) has no web mode, keeps its own push receiver and
mail sync, and targets an Android version old enough that its notification permission can be granted from adb. I
installed Google's own signed copy, granted it that permission, put it on the battery optimization whitelist, allowed
it to run in the background, and turned off automatic permission revocation for it. When new mail arrives, Google's
push wakes Gmail Go even if its window has been closed, and it syncs the email and posts a notification. Gmail Go and
the Gmail web app live side by side without conflict.

### 2. Notification Keeper shows its own copy

Notification Keeper is a notification listener. For every email notification that Gmail Go posts, it posts its own
copy on its own high-importance categories (one per Gmail Go category, grouped by account), so the copy pops up and
stays. Only after its copy is up does it remove Gmail Go's original, so there is exactly one notification per email.
It keeps its own "N new messages" summary for each account. The whole chain takes about 1 to 1.5 seconds from
Google's push to the pop-up.

A settings guard keeps Gmail Go's own categories silent, so nothing alerts twice, and it saves my Gmail and Gmail Go
notification settings and puts them back if they are ever reset. To manage another app's notification categories,
Notification Keeper needs a companion device link, which adb can create.

If the Gmail web app is open and posts its own alert for the same email, the Keeper removes that duplicate, but only
once its own copy for that account is showing. If the Gmail Go copy has not appeared within 2.5 seconds, the web
alert is left in place, so I am never left with nothing.

### 3. Tap, Reply and Delete in the Gmail web app

Gmail Go's notifications do not carry Gmail's internal message ID (reading it needs a permission that only Google's
own apps can have), so there is no exact link to an email. Instead, tap, Reply and Delete open the right account's
Inbox in the Gmail web app (`https://mail.google.com/mail/?authuser=<account>#inbox`), and the Gmail helper finds
the email there the way I would by hand:

- It matches the email's exact subject, ignoring "Re:" and "Fwd:" prefixes, and its arrival time within 2 minutes,
  so an older email with the same subject is never touched. It prefers unread rows and rows whose sender name
  matches the notification.
- It scrolls to the email, presses Refresh once if the Inbox has not caught up yet, and checks up to 5 older pages.
- A tap clicks the email so it opens. Reply and Delete use a long press, which Gmail treats as a right-click, and
  then pick that item in Gmail's own menu. For Reply, it checks that the reply window opened.
- It only touches the screen when the Gmail web app is the active window and no other window covers that spot.
- A tap removes the notification at once, like any tapped notification. Reply removes it only after the reply
  window has opened, and Delete only after Delete has been picked in Gmail's menu (the helper does not check
  afterwards that the email is gone). A Reply or Delete that cannot finish gives up after 45 seconds and leaves the
  notification in place.
- When I open an email in the Gmail web app myself, the helper clears that email's notification.

### 4. Mark as read without opening anything

Mark as read could not be done on the Android side. Gmail Go's mark-as-read needs a permission that only Google's
apps can hold, the adb shell has no secure web client, and Gmail retired its Basic HTML view in January 2024. Google
also blocks sign-in inside embedded app browsers. A real Chromium browser in the Linux Terminal is not an embedded
browser, so I sign in to each Gmail account there once, and the session keeps working in a hidden (headless)
browser afterwards.

The Mark as read button works like this:

1. Notification Keeper writes one JSON line to the Android system log (logcat) under the tag `GmailGhostCmd`. It
   holds the account, the sender's email address, the subject and the arrival time. The Keeper removes its
   notification at the same moment.
2. The ghost daemon in the Linux Terminal (`ghostd.py --adb`, run by a systemd user service) listens with
   `adb logcat` over Wireless debugging. It runs adb through `stdbuf` because adb otherwise buffers its output into
   the pipe, which delayed commands by about a minute. It skips duplicate commands and ignores any command older
   than 120 seconds. I used logcat as the bridge because the Linux Terminal's shared folder is not visible to the adb
   shell.
3. It uses a warm headless Chromium that is signed in to that account (one browser profile per account), opens the
   Inbox and presses Gmail's own Refresh.
4. It finds the unread row whose sender address matches, whose subject matches exactly (again ignoring "Re:" and
   "Fwd:"), and whose listed time is within 2.5 minutes of the notification. It checks up to 5 pages.
5. It hovers over the row and clicks Gmail's own Mark as read button on it (or, if that button is not there, selects
   the row and uses Mark as read in the toolbar). Then it refreshes and checks that the row is no longer unread.

Each Mark as read takes about 4 to 6 seconds. When a new email pops up, the Keeper also asks the daemon to warm up the
browser for that account, so it is ready when I press the button. A browser that has been idle for 180 seconds is
closed. Every browser call has a timeout, each command has a 25 second deadline that is checked between steps, and a
browser that fails is closed and started fresh for the next command.

Accounts are tied to Gmail Go's notification settings. When a Gmail account's mail category in Gmail Go is turned on,
the Keeper asks the daemon to set that account up, and the daemon opens the one-time sign-in window if the account
has no browser profile yet. When the category is turned off, the daemon closes that account's browser and moves its
profile aside.

### Proof

Every part was proven on October 12, 2026, including notifications with Gmail Go closed, Mark as read on more
than one account, and tap, Reply and Delete. Archive was left out because Android shows at most three buttons on a
notification. Mark as read currently needs the Linux Terminal running with Wireless debugging, and it works for
Gmail accounts only (@gmail.com, and the code also accepts @googlemail.com).

## Requirements

- **Device:** a Lenovo Googlebook 15 (x86-64 Intel). I built and tested this on GooglebookOS build
  CL3B.260622.271.R1 (Android 17), with the Linux Terminal running Debian 13 (trixie).
- **General setup:** Developer options, the Linux Terminal, adb, a paired Wireless debugging connection, your Android
  user ID, and the Android SDK build tools with a JDK. All of this is in the shared
  [Getting started guide](https://github.com/iamflying29-sketch/googlebook-projects/blob/main/GETTING-STARTED.md).
- **Gmail web app:** the Gmail app that comes with GooglebookOS, signed in to every Gmail account you want
  notifications for. Gmail's display language must be English, because the helper and the daemon look for Gmail's
  English labels (for example "Search mail", "Refresh", "Older" and "Mark as read").
- **Gmail Go 2021.11.03.429633235**, which you get yourself. See [Getting Gmail Go](#getting-gmail-go).
- **Notification Keeper**, built from its
  [repository](https://github.com/iamflying29-sketch/googlebook-notification-keeper).
- **In the Linux Terminal:** Python 3 with the `venv` module, `git`, `stdbuf` (part of coreutils), a systemd user
  session, and the ability to show a window on the Googlebook screen (used once per account for signing in). The
  setup script installs Playwright and the Chromium build it drives into this folder and into Playwright's download
  cache.
- **Accounts:** I built and tested this with Gmail accounts. Mark as read works for @gmail.com accounts (the code
  also accepts @googlemail.com), and tap, Reply and Delete need the account to be signed in to the Gmail web app.
- **Permissions used on GooglebookOS:** for Gmail Go, the notification permission, a battery whitelist entry and
  background running; for Notification Keeper, the notification permission, notification access, a companion device
  link, and the accessibility service for the Gmail helper. Everything uses the permissions adb's shell user already
  has. Nothing needs root.

## Getting Gmail Go

Gmail and Gmail Go are Google's apps. This project does not include, modify or redistribute them.

- **App:** Gmail Go by Google, package `com.google.android.gm.lite`.
- **Version this setup needs and was tested with:** 2021.11.03.429633235.Release (versionCode 62412338, minSdk 29,
  targetSdk 31). Newer builds (2022 and later) target SDK 33 without requesting the notification permission, so
  Android blocks their notifications.
- **Official source:** Google Play, <https://play.google.com/store/apps/details?id=com.google.android.gm.lite>.
  Google Play only offers the newest version, and on many devices it is listed only for Android (Go edition)
  devices, so it may not offer the 2021 build at all.

The legal routes, in order:

1. **Your own installed copy.** If you already have that version installed on a device you own (for example an
   older phone that got it from Google Play), you can copy your own installed copy. Connect that device with adb and
   run:

   ```bash
   adb shell pm path com.google.android.gm.lite
   # prints a line such as package:/data/app/.../base.apk
   adb pull /data/app/.../base.apk gmail-go.apk
   ```

   Use the exact path that the first command prints. If it prints more than one path, the app is split into several
   files; pull all of them and install them together later with `adb install-multiple`.
2. **An APK archive site.** Sites such as APKMirror (<https://www.apkmirror.com/>) host unmodified, developer-signed
   copies of free apps and verify the developer signature. Downloading a free app this way is at your own discretion;
   check the terms that apply where you live. Never use a "modded" or repackaged copy.

**Verify any copy before installing it.** In the Linux Terminal, with the SDK build tools from the shared guide:

```bash
~/tools/android-sdk/build-tools/35.0.0/apksigner verify --print-certs gmail-go.apk
sha256sum gmail-go.apk
```

The `apksigner` output must show the signer
`CN=Android, OU=Android, O=Google Inc., L=Mountain View, ST=California, C=US` with the certificate SHA-256 digest
`f0fd6c5b410f25cb25c3b53346c8972fae30f8ee7411df910480ad6b2d60db83`. If either one differs, do not install the file.
For reference, the exact base.apk I use has the file SHA-256
`83270e14561d2352212376a617e89a45f85ffd6cc5913f6a04c2aa377ac6fde0`. Variants for other devices can differ, so the
certificate digest is the check that matters.

This is not legal advice.

## Installation

Do these steps in order. In every command, replace `<USER_ID>` with the number that `adb shell am get-current-user`
prints, and `<GOOGLEBOOK_IP>:<PORT>` with the address under **IP address & Port** on the Wireless debugging screen.

### Step 1. General setup

Follow the shared [Getting started guide](https://github.com/iamflying29-sketch/googlebook-projects/blob/main/GETTING-STARTED.md)
through section 6: Developer options, the Linux Terminal, adb, pairing and connecting over Wireless debugging, your
Android user ID, and the SDK build tools with a JDK. Then install the extra packages this project needs:

```bash
sudo apt install python3-venv git
```

### Step 2. Prepare the Gmail web app

1. Open the Gmail app on the Googlebook and sign in to every Gmail account you want notifications for.
2. Make sure Gmail's display language is English (in Gmail's settings, on the General tab).

### Step 3. Install and set up Gmail Go

Get and verify Gmail Go as described in [Getting Gmail Go](#getting-gmail-go). Then, in the Linux Terminal:

```bash
# install it for your Android user
adb install --user <USER_ID> gmail-go.apk

# check the version: versionName must be 2021.11.03.429633235.Release and targetSdk 31
adb shell dumpsys package com.google.android.gm.lite | grep -E 'versionName|targetSdk'

# allow its notifications (possible because it targets SDK 31)
adb shell pm grant --user <USER_ID> com.google.android.gm.lite android.permission.POST_NOTIFICATIONS

# battery: whitelist it and let it run in the background, so Google's push can wake it
adb shell cmd deviceidle whitelist +com.google.android.gm.lite
adb shell cmd appops set --user <USER_ID> com.google.android.gm.lite RUN_ANY_IN_BACKGROUND allow

# never revoke its permissions automatically when it is not opened for a while
adb shell cmd appops set --user <USER_ID> com.google.android.gm.lite AUTO_REVOKE_PERMISSIONS_IF_UNUSED ignore

# check that the permission is granted
adb shell dumpsys package com.google.android.gm.lite | grep POST_NOTIFICATIONS
```

Now open Gmail Go once on the Googlebook and let it finish its first start and show your accounts. Gmail Go keeps
one mail notification category per account. You can close it afterwards; closing its window does not stop it from
being woken by Google's push.

Gmail Go's own notification categories must be silent so that only the Keeper's copy alerts. You do not have to do
this by hand: once Notification Keeper is linked in step 5, its settings guard sets every Gmail Go category that is on
to silent and leaves the ones you switched off alone. An account whose mail category you turn off in Gmail Go gets no
notifications.

**Turn off automatic updates for Gmail Go.** A Play Store update to a 2022 or later build would block its
notifications. If Google Play shows Gmail Go for your Googlebook, open its page in Play, open the three-dot menu and
turn off **Enable auto update**. If Play does not list Gmail Go for your device, there is no page to change, and
Notification Keeper warns you with "Gmail notifications stopped working" if Gmail Go can no longer post
notifications. It does not warn you if Gmail Go is removed, but its status window shows that Gmail Go is missing.

### Step 4. Build Notification Keeper

Clone the Notification Keeper repository into your home folder and build it with the steps in its
[README](https://github.com/iamflying29-sketch/googlebook-notification-keeper):

```bash
git clone https://github.com/iamflying29-sketch/googlebook-notification-keeper.git ~/googlebook-notification-keeper
cd ~/googlebook-notification-keeper
./build.sh
```

The build produces `~/googlebook-notification-keeper/NotificationKeeper.apk`. The setup script in step 5 installs it
from there if it is not installed yet. If you keep the APK somewhere else, set `KEEPER_APK` to its full path when you
run the setup script.

### Step 5. Install the ghost daemon and set up the Android side

Clone this repository into your home folder (use a folder path without spaces) and run the setup script:

```bash
git clone https://github.com/iamflying29-sketch/googlebook-gmail-web-app-notifications.git ~/googlebook-gmail-web-app-notifications
cd ~/googlebook-gmail-web-app-notifications
adb connect <GOOGLEBOOK_IP>:<PORT>
ANDROID_USER=<USER_ID> ./setup.sh
```

`setup.sh` is safe to run again at any time. It:

1. Checks for `python3`, `adb` and `stdbuf`.
2. Creates a Python virtual environment in `venv/`, installs `requirements.txt` (Playwright) and downloads
   Playwright's Chromium.
3. Takes the Googlebook's address from `ANDROID_SERIAL` if you set it, otherwise from the first device in
   `adb devices`, and writes it to `ghost.env` as `ANDROID_SERIAL=<GOOGLEBOOK_IP>:<PORT>`.
4. Installs the systemd user service `~/.config/systemd/user/ghostd.service` from `systemd/ghostd.service.in`,
   enables it and starts it. It also tries `loginctl enable-linger` so the service keeps running when you are not
   logged in to the Terminal, and tells you the command to run if it is not allowed to.
5. Runs `bin/notif-restore apply` (or a `notif-restore` on your `PATH`), which installs Notification Keeper if it is
   missing and sets up its permissions: the notification permission, no automatic permission revocation, the
   companion device link and notification access. See [What notif-restore does and does not do](#what-notif-restore-does-and-does-not-do).
6. Lists the Google accounts on the Googlebook and shows which ones are set up for Mark as read.

If you prefer to set up Notification Keeper by hand instead of through `notif-restore`, these are the same commands:

```bash
adb install -r --user <USER_ID> ~/googlebook-notification-keeper/NotificationKeeper.apk
adb shell pm grant --user <USER_ID> local.notifkeeper android.permission.POST_NOTIFICATIONS
adb shell cmd appops set --user <USER_ID> local.notifkeeper AUTO_REVOKE_PERMISSIONS_IF_UNUSED ignore
# companion device link: the address is a made-up, locally administered one and belongs to no real device
adb shell cmd companiondevice associate <USER_ID> local.notifkeeper 02:4E:4B:00:00:01
adb shell cmd notification allow_listener local.notifkeeper/local.notifkeeper.KeeperListener <USER_ID>
```

### Step 6. Turn on the Gmail helper

`notif-restore` does not turn on the accessibility helper, so do this by hand: open **Settings**, go to
**Accessibility** (search Settings for "Accessibility" if you cannot find it), and turn on **Notification Keeper:
Gmail helper**. Without it, a tap or a Reply or Delete button only opens the account's Inbox in the Gmail web app.

### Step 7. Sign in to each Gmail account for Mark as read

Google requires a person to sign in, so do this once per Gmail account:

```bash
cd ~/googlebook-gmail-web-app-notifications
./ghostctl enable <your Gmail address>
```

A Chromium window opens on the Googlebook screen with the address already filled in. Enter your password and finish
2-Step Verification. The window closes by itself as soon as the Gmail Inbox has loaded, and the sign-in is saved in
`profiles/<your Gmail address>/`. If you do not finish within 15 minutes, the window closes and you can run the command
again. A sign-in window can also open by itself when you turn on a Gmail account's mail category in Gmail Go, because
the Keeper then asks the daemon to set that account up.

### Step 8. Check that everything works

```bash
./ghostctl status
./ghostctl doctor
```

Then send yourself an email from another account. A notification should pop up within a few seconds of the email
arriving, even with Gmail and Gmail Go closed. Press **Mark as read** and watch the daemon's log:

```bash
./ghostctl logs
```

A result line that contains `"detail": "marked read"` means it worked. Press Ctrl+C to stop watching the log.

## Using it

Once it is set up, everything runs by itself.

- **New mail:** each email pops up as its own notification, grouped by account with an "N new messages" summary.
  It stays until you act on it or clear it.
- **Tap:** opens that account's Inbox in the Gmail web app, and the Gmail helper opens the email. Like any tapped
  notification, it disappears when you tap it.
- **Reply:** the helper right-clicks the email in the Gmail web app and picks Reply, and the notification goes away
  once the reply window is open.
- **Delete:** the helper right-clicks the email and picks Delete, and the notification goes away once Delete has
  been picked. The helper does not check afterwards that the email is gone.
- **Mark as read:** the notification goes away at once, and the ghost daemon marks the email read in the background
  within about 4 to 6 seconds.
- **Opening an email yourself** in the Gmail web app clears its notification.
- While the helper is working, it waits whenever another window is in front of Gmail, and it gives up after 45
  seconds. It handles one tap or button at a time; a newer one replaces an unfinished older one.

### Commands

Run these in the repository folder in the Linux Terminal.

| Command | What it does |
|---|---|
| `./ghostctl status` | Shows whether the service is active and whether the daemon is listening. |
| `./ghostctl list` | Lists the Google accounts on the Googlebook and which ones are set up for Mark as read. |
| `./ghostctl enable <account>` | Opens the one-time sign-in window for that account. |
| `./ghostctl disable <account>` | Moves that account's sign-in aside to `profiles/.<account>.disabled.<time>`. It is kept, not deleted. |
| `./ghostctl test <account> <sender address> "<subject>"` | Sends a Mark as read command through logcat, for checking. It marks a real email read if one matches. |
| `./ghostctl doctor` | Checks the adb connection, the service, Playwright and Chromium, each account's sign-in, and the Android side (through `notif-restore status`), and fixes what it can: it reconnects adb and restarts the service. |
| `./ghostctl logs` | Follows the daemon's log, `logs/ghostd.log`. |
| `bin/notif-restore status` | Shows the Android side without changing anything. |
| `bin/notif-restore apply` | Re-applies the Android side. Safe to run at any time; it only changes what is off. |
| `bin/notif-restore gmail-reset` | Only for the full Gmail app, see [Troubleshooting](#troubleshooting). |
| `systemctl --user status ghostd.service` | The service's state, from systemd. |

All `notif-restore` commands accept the Wireless debugging address as an extra argument, which they use when no
device is connected yet, for example `bin/notif-restore status 192.0.2.10:41000` (192.0.2.10 is a reserved example
address). Without that argument, they try the address in `ADB_PORT_FILE`.

### Configuration

- **The Googlebook's address.** The port changes on every Wi-Fi re-join, so the daemon follows it. If you run the
  [Sleep Guard](https://github.com/iamflying29-sketch/googlebook-sleep-guard) or
  [Shadow Trackpad Fix](https://github.com/iamflying29-sketch/googlebook-shadow-trackpad-fix) helpers, they republish
  the current address and the daemon reads the newest file automatically, so Mark as read keeps working across
  Wi-Fi re-joins with nothing to do. Without those helpers, the daemon uses the `ANDROID_SERIAL` environment
  variable, or `ghost.env` (`ANDROID_SERIAL=<GOOGLEBOOK_IP>:<PORT>`, which `setup.sh` writes and `ghost.env.example`
  shows the format of). It re-reads the address on every reconnect, so a new port takes effect without restarting
  the service.
- **`notif-restore`** reads these optional environment variables: `ANDROID_USER` (your Android user ID, default 10),
  `KEEPER_APK` (default `~/googlebook-notification-keeper/NotificationKeeper.apk`), `NOTIF_KIT` (a folder with spare
  APKs, default `~/notification-keeper-kit`, used for `NotificationKeeper.apk` when `KEEPER_APK` does not exist),
  `GMAIL_APK` (a full Gmail APK, not set by default), `EXTRA_PACKAGES` (more app package names, separated by spaces,
  that should also get the notification permission and Unrestricted battery use; empty by default) and
  `ADB_PORT_FILE` (default
  `/mnt/shared/Documents/Shadow Trackpad Fix/adb-port.txt`, the address file that
  [Shadow Trackpad Fix](https://github.com/iamflying29-sketch/googlebook-shadow-trackpad-fix) publishes).

### What notif-restore does and does not do

`bin/notif-restore` is a recovery command for the Android side. With `apply`, it:

- installs Notification Keeper from `KEEPER_APK` if it is not installed, grants it the notification permission,
  turns off automatic permission revocation for it, creates the companion device link if it is missing, and turns on
  its notification access (switching it off and on again if it was already on, so the Keeper re-checks Gmail's
  categories right away);
- grants the notification permission to Gmail, Chrome and any apps listed in `EXTRA_PACKAGES`, if they are installed
  and do not have it;
- sets battery use to Unrestricted for Gmail, Chrome and any apps listed in `EXTRA_PACKAGES`, if they are installed
  and not already unrestricted;
- installs a full Gmail app from `GMAIL_APK` if you set it, Gmail is currently the web-only version, and the file
  is signed by Google. This was part of an earlier approach and is not needed with Gmail Go.

It does **not** install, update or set up Gmail Go, it does not check Gmail Go at all, and it does **not** turn on the
Gmail helper. If Gmail Go needs to be put back, repeat [step 3](#step-3-install-and-set-up-gmail-go). If the Gmail
helper was switched off, repeat [step 6](#step-6-turn-on-the-gmail-helper).

With the stock Gmail web app, `notif-restore status` marks "Gmail is the WEB-ONLY version" with a cross. That is
expected with this setup, because Gmail Go provides the notifications. Its reminder about Play auto-updates refers to
the full Gmail app; for this setup, keep auto-updates off for Gmail Go.

## Updating, and what happens after app or GooglebookOS updates

- **This repository:** run `git pull` in the folder and then `ANDROID_USER=<USER_ID> ./setup.sh` again. The script
  is safe to repeat. It rewrites `ghost.env` from the device that is connected at that moment.
- **Notification Keeper:** rebuild it and install it again. Updating the app clears the notifications it is showing;
  new mail is shown as usual.

  ```bash
  adb install -r --user <USER_ID> ~/googlebook-notification-keeper/NotificationKeeper.apk
  ```

- **Gmail Go:** keep it at the 2021 build. If a Play update ever replaces it, Notification Keeper posts "Gmail
  notifications stopped working". Android does not let you install an older version over a newer one, so uninstall
  the newer one (`adb shell pm uninstall --user <USER_ID> com.google.android.gm.lite`; your mail stays on Google's
  servers) and repeat [step 3](#step-3-install-and-set-up-gmail-go).
- **Wireless debugging port:** the port changes when Wireless debugging restarts, for example after a reboot or
  after the Wi-Fi drops in deep sleep. If you run [Sleep Guard](https://github.com/iamflying29-sketch/googlebook-sleep-guard)
  or [Shadow Trackpad Fix](https://github.com/iamflying29-sketch/googlebook-shadow-trackpad-fix), each publishes the
  current address (`/mnt/shared/Documents/Sleep Guard/adb-port.txt` and
  `/mnt/shared/Documents/Shadow Trackpad Fix/adb-port.txt`), the daemon reads the newest one and reconnects on its
  own, so Mark as read keeps working with nothing to do. Without either helper, put the new address in `ghost.env`:

  ```bash
  echo "ANDROID_SERIAL=<GOOGLEBOOK_IP>:<PORT>" > ~/googlebook-gmail-web-app-notifications/ghost.env
  ```

  The daemon re-reads the address whenever its adb connection restarts, which happens by itself when the old
  connection drops, so you do not need to restart the service.
- **GooglebookOS updates:** a big update could switch off notification access or the accessibility service. Run
  `bin/notif-restore apply` for the Keeper's permissions, turn the Gmail helper back on by hand (step 6), and run
  `./ghostctl doctor`. Notification Keeper also posts an alert if it loses its notification access.
- **Linux Terminal restarts:** the service is enabled for your systemd user session and restarts by itself if it
  stops (`Restart=always`). Playwright and Chromium live in this folder's `venv/` and in Playwright's download cache,
  so a GooglebookOS update does not touch them.
- **Expired sign-ins:** Google can end a saved session. `./ghostctl doctor` reports an account that is signed out;
  sign in again with `./ghostctl enable <account>`.
- **Gmail web redesigns:** both the helper and the daemon rely on Gmail's web page layout and labels. A big redesign
  can break them until the selectors are updated. The daemon's selectors are all in `ghostd.py`; the helper's are in
  Notification Keeper's `WebGmailHelper.java`.

## Uninstalling

Stop and remove the ghost daemon in the Linux Terminal:

```bash
systemctl --user disable --now ghostd.service
rm ~/.config/systemd/user/ghostd.service
systemctl --user daemon-reload
```

Remove the repository folder. This also removes the saved sign-ins in its `profiles/` folder, including any that
`ghostctl disable` set aside there. Then remove Playwright's Chromium download if nothing else on your Linux Terminal
uses Playwright:

```bash
rm -r ~/googlebook-gmail-web-app-notifications
rm -r ~/.cache/ms-playwright
```

You can also end those sessions on Google's side: in your Google Account, open **Security** and sign out the device
under **Your devices**.

On the Googlebook, turn off **Notification Keeper: Gmail helper** in **Settings > Accessibility**, then remove the
apps you no longer want:

```bash
adb shell pm uninstall --user <USER_ID> local.notifkeeper
adb shell cmd deviceidle whitelist -com.google.android.gm.lite
adb shell pm uninstall --user <USER_ID> com.google.android.gm.lite
```

See the Notification Keeper README for anything else it set up.

## Troubleshooting

**No notification arrives while Gmail is closed.** Open Notification Keeper: it shows whether Gmail Go is installed
and allowed to post notifications. Check Gmail Go's version and permission with the two `dumpsys` commands in
[step 3](#step-3-install-and-set-up-gmail-go). If a Play update installed a newer Gmail Go, follow the Gmail Go item
under [Updating](#updating-and-what-happens-after-app-or-googlebookos-updates). Also make sure that account's mail
category in Gmail Go is not switched off.

**Every email alerts twice, or Gmail Go's own notification stays.** The settings guard cannot silence Gmail Go's
categories without the companion device link. Notification Keeper's window then says that it is not linked as a
companion app. Run `bin/notif-restore apply`, which creates the link.

**Notifications seem to arrive minutes late.** Measure before you blame the chain: from Gmail Go's notification to
the Keeper's pop-up took well under a second in my tests, also with the Gmail web app open and with several emails at
once. When I saw delays, the sending side was the cause (the sending app held the emails in its outbox). While the
Googlebook is in deep sleep with the lid closed, Wi-Fi can drop, and pushes then arrive when it wakes up.

**Tapping, Reply or Delete only opens the Inbox.** The Gmail helper is off (step 6), or it could not finish within 45
seconds and left the notification in place. Check that the Gmail web app is signed in to that account, that Gmail's
display language is English, that the email is in the Inbox (not archived or filtered elsewhere), and that no other
window covers Gmail while the helper works.

**Mark as read did nothing.** Run `./ghostctl logs` and press the button again.

- `no matching unread email (already read?)`: the email was already read, it is not in the Inbox, or it is not
  within the first 5 pages.
- `account not set up (no profile)`: sign in with `./ghostctl enable <account>`. Accounts that are not Gmail
  accounts are not supported.
- No line at all: the daemon is not running or not connected. Run `./ghostctl doctor`, check that `ghost.env` holds
  the current Wireless debugging address, and see the Wireless debugging item under
  [Updating](#updating-and-what-happens-after-app-or-googlebookos-updates).
- `error: ...`: the browser failed. The daemon closes it and starts a fresh one for the next command, so try again.

**The log says `prewarm skipped for <account>: not signed in`.** When a new email pops up, the Keeper asks the
daemon to warm up that account's browser. If the account has no saved sign-in in `profiles/`, the daemon skips the
warm-up, logs this line and keeps running. Mark as read will not work for that account until you sign in with
`./ghostctl enable <account>`. If you do not want Mark as read for it, you can ignore the line. A line starting with
`prewarm failed, dropping browser` means the browser itself failed to start; the daemon closes it and tries again with
the next command.

**The service does not start and the log says `ANDROID_SERIAL is not set`.** The daemon exits with status 2 and
systemd does not restart it until you fix the cause. Put `ANDROID_SERIAL=<GOOGLEBOOK_IP>:<PORT>` in `ghost.env`, then
run `systemctl --user restart ghostd.service`.

**`./ghostctl doctor` says an account is signed out right after you used Mark as read.** Chromium lets only one
browser use a profile at a time, and the daemon's warm browser may still have that profile open. Wait about 3
minutes, until the idle browser has closed, and run `doctor` again. If it still says signed out, run
`./ghostctl enable <account>`.

**The sign-in window does not appear.** The window is shown on display `:0`. Make sure the Linux Terminal can show
graphical apps, and run `./ghostctl enable <account>` from the Terminal so you can see its messages.

**`setup.sh` stops while creating the virtual environment.** Install the `venv` module with
`sudo apt install python3-venv` and run the script again.

**Chromium does not start because a system library is missing.** Install the missing library with `apt`. Playwright's
`install-deps` command (`sudo venv/bin/playwright install-deps chromium`) can do this on the Debian versions it
supports.

**Gmail opens and closes immediately after you installed a full Gmail app.** This only happened with the full Gmail
app, after Google Play had swapped it to the web wrapper and back. `bin/notif-restore gmail-reset` clears Gmail's app
data on the Googlebook once (your mail stays on Google's servers, and Notification Keeper puts Gmail's notification
settings back). It asks you to type YES before it clears anything. You do not need this with the stock Gmail web app.

## Safety and privacy notes

- **Gmail Go** is Google's own unmodified app, checked against Google's signing certificate before you install it.
  It uses the Google accounts already on your Googlebook.
- **Notification Keeper** has no internet permission. Its Gmail helper receives accessibility events only from
  Chrome and Gmail. It also looks at where other windows are on the screen, to make sure nothing covers Gmail before
  it touches it. It only touches the Gmail web app window while that window is in front and uncovered, and it
  stores nothing.
- **The Mark as read command is written to the Android system log.** It contains the email's subject and sender
  address, and adb and apps with log access can read it. The daemon also writes the first part of each command to
  `logs/ghostd.log` in this folder and to its output, which systemd keeps in your user journal.
- **The ghost browser holds real Google sessions.** Each account's folder in `profiles/` contains that account's
  browser sign-in (cookies), much like a normal browser profile. Your password is not stored. Anyone who can read
  your Linux Terminal files could use those sessions, so keep the Terminal to yourself. `ghostctl disable` and
  turning an account off in Gmail Go only move the profile aside; delete it yourself to remove it, and sign the
  session out in your Google Account if you want it ended on Google's side.
- The daemon starts Chromium with a flag that hides the standard automation marker
  (`--disable-blink-features=AutomationControlled`). It acts only on your own accounts, one email at a time, the way
  you would by hand. Automating a web service may not be allowed by that service's terms; decide for yourself
  whether you are comfortable with it.
- **The daemon asks GooglebookOS for very little.** It only runs `adb connect` with a time limit and reads a
  filtered `adb logcat` stream as it arrives, and otherwise it talks to Chromium and Gmail. `ghostctl list` asks for
  the account list (`dumpsys account`), which is small. `notif-restore status` reads the notification service's
  report through adb with a 30 second time limit and processes it as it arrives.
- Wireless debugging gives a paired computer a lot of control over your Googlebook. Only pair computers you own.

## Limitations and known issues

- **Mark as read gives no failure feedback.** The notification disappears as soon as you press the button, whether
  or not the daemon succeeds. Check `./ghostctl logs` if in doubt.
- **Mark as read needs the Linux Terminal running, Wireless debugging on, and the current address in `ghost.env`.**
  When the Wireless debugging port changes, you have to update `ghost.env`; the daemon does not find the new port by
  itself.
- **Non-Gmail accounts are not handled.** Gmail Go can show notifications for other accounts, but the ghost browser
  only handles @gmail.com and @googlemail.com accounts, and the Gmail helper only works in the Gmail web app. Google Workspace accounts were not
  tested.
- **Google Meet calls are not covered.** On the Googlebook, the Meet app has no push receiver, so calls only ring
  while Meet or the Gmail web app is open, and Gmail Go has no Meet support.
- **English only.** Both the helper and the daemon match Gmail's English labels.
- **It depends on Gmail's web layout.** A redesign of the Gmail web app can break the helper or the daemon until
  their selectors are updated.
- **It depends on an old Gmail Go build.** If Google ever stops serving that version's push messages, the engine
  stops working, and Notification Keeper warns you.
- **No Archive button.** Android shows at most three buttons on a notification, and I chose Reply, Delete and Mark as
  read.
- Notification Keeper shows at most 25 Gmail copies at a time and removes the oldest beyond that, because Android
  allows each app only 50 notifications.
- `notif-restore` still contains steps from an earlier approach (the full Gmail app, and permissions for Chrome and
  any apps listed in `EXTRA_PACKAGES`). They only act on apps that are installed, but read
  [what it does](#what-notif-restore-does-and-does-not-do) before you run it.
- Everything was built and tested on one Lenovo Googlebook 15 with one GooglebookOS build. Other devices and later
  builds may behave differently.

## Files in this repository

| File | Purpose |
|---|---|
| `ghostd.py` | The ghost daemon. With `--adb` it listens on logcat and marks emails read in a hidden Chromium. Without it, it watches `bridge/cmd/` for JSON command files instead (a testing mode that moves each processed file to `bridge/processed/`, writes the result to `bridge/done/`, and exits after 30 idle minutes, or after one batch with `--once`). |
| `ghostctl` | Manages the daemon and accounts: `status`, `list`, `enable`, `disable`, `test`, `doctor`, `logs`. |
| `login.py` | The one-time, on-screen sign-in for one account into `profiles/<account>/`. |
| `verify_login.py` | Checks that an account's saved sign-in still works. `ghostctl doctor` uses it. |
| `setup.sh` | Installs everything on the Linux Terminal side and runs `notif-restore apply`. |
| `requirements.txt` | The Python package the scripts need (Playwright). |
| `ghost.env.example` | The format of `ghost.env`, which holds your Googlebook's adb address. |
| `systemd/ghostd.service.in` | The systemd user service template that `setup.sh` fills in. |
| `bin/notif-restore` | The recovery command for the Android side (see above). |
| `LICENSE` | The MIT License. |

`setup.sh` and the daemon create `venv/`, `ghost.env`, `profiles/`, `logs/` and `bridge/` in this folder. They are
listed in `.gitignore`, because they hold your address, your sign-ins and your logs.

## Related projects

- [Notification Keeper](https://github.com/iamflying29-sketch/googlebook-notification-keeper): the Android app that
  shows the notifications and contains the Gmail helper. This system needs it.
- [Sleep Guard](https://github.com/iamflying29-sketch/googlebook-sleep-guard) and
  [Shadow Trackpad Fix](https://github.com/iamflying29-sketch/googlebook-shadow-trackpad-fix): both publish the
  current Wireless debugging address in the shared Documents folder, which `notif-restore` can read and which you can
  copy into `ghost.env`.
- [Googlebook Projects](https://github.com/iamflying29-sketch/googlebook-projects): the overview of all projects and
  the [Getting started guide](https://github.com/iamflying29-sketch/googlebook-projects/blob/main/GETTING-STARTED.md).

## Disclaimer and license

This is an independent, unofficial project. It is not affiliated with, endorsed by, or sponsored by Google, Lenovo
or any other company named here. All product names belong to their owners. Released under the MIT License.
Copyright (c) 2026 Thomas Liviakis.
