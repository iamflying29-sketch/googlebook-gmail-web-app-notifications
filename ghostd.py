#!/usr/bin/env python3
"""
Ghost daemon: instant background "Mark as read" for the Notification Keeper.

With --adb (the normal mode, used by the systemd service) it listens on adb logcat for the one-line
commands the Notification Keeper logs under the tag GmailGhostCmd. Without --adb it watches the
command folder bridge/cmd/ instead (a testing mode). For each command it marks the exact email read
in a hidden, already-logged-in Chromium - no window, no screen touching.

The Googlebook's adb serial (the Wireless debugging IP:PORT) comes from the ANDROID_SERIAL
environment variable or, if that is not set, from the line ANDROID_SERIAL=IP:PORT in the file
ghost.env next to this script (setup.sh writes it). The file is read again every time the adb
stream is restarted, so a new port can be put there without restarting the daemon.

Design rules (never block / never hang):
  - one warm headless Chromium per account, reused for speed, closed after it's idle a while
  - every browser call has a timeout; a whole command has a hard deadline
  - if a browser hangs, it is killed and relaunched; a command never blocks the queue forever
  - processed command files are MOVED (never deleted) into processed/, with a result in done/
  - in the command-folder mode the daemon exits on its own after a long idle; the adb mode runs as
    a service that systemd supervises and restarts
"""
import json, os, re, select, subprocess, sys, time, traceback, urllib.parse
from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout

LOGCAT_TAG = "GmailGhostCmd"          # the Keeper logs commands under this tag
STALE_CMD_SECONDS = 120               # ignore commands older than this (e.g. after a daemon restart)

ROOT = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(ROOT, "ghost.env")  # holds ANDROID_SERIAL=IP:PORT (written by setup.sh)
CMD = os.path.join(ROOT, "bridge", "cmd")
PROCESSED = os.path.join(ROOT, "bridge", "processed")
DONE = os.path.join(ROOT, "bridge", "done")
PROFILES = os.path.join(ROOT, "profiles")
LOG = os.path.join(ROOT, "logs", "ghostd.log")

POLL_SECONDS = 1.0
IDLE_CLOSE_SECONDS = 180     # close a warm browser after this many idle seconds
DAEMON_IDLE_EXIT_SECONDS = 1800  # command-folder mode: the daemon exits after this long with no commands
OP_DEADLINE_SECONDS = 25     # hard cap for one mark-read
NAV_TIMEOUT_MS = 20000
ARGS = ["--no-first-run", "--no-default-browser-check", "--disable-blink-features=AutomationControlled"]


def android_serial():
    """The Googlebook's adb serial: $ANDROID_SERIAL, else ANDROID_SERIAL= in ghost.env, else ''."""
    serial = os.environ.get("ANDROID_SERIAL", "").strip()
    if serial:
        return serial
    try:
        with open(CONFIG) as f:
            for line in f:
                line = line.strip()
                if line.startswith("ANDROID_SERIAL="):
                    serial = line.split("=", 1)[1].strip().strip('"').strip("'")
    except OSError:
        pass
    return serial


def log(msg):
    line = time.strftime("%H:%M:%S") + " " + msg
    print(line, flush=True)
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


class Browsers:
    """Warm headless Chromium per account, with idle close."""

    def __init__(self, pw):
        self.pw = pw
        self.sessions = {}  # account -> {"ctx":..., "page":..., "used":ts}

    def profile_dir(self, account):
        return os.path.join(PROFILES, account)

    def get(self, account):
        s = self.sessions.get(account)
        if s:
            s["used"] = time.time()
            return s["page"]
        prof = self.profile_dir(account)
        if not os.path.isdir(prof):
            raise RuntimeError("account not set up (no profile): " + account)
        ctx = self.pw.chromium.launch_persistent_context(prof, headless=True, args=ARGS)
        ctx.set_default_timeout(NAV_TIMEOUT_MS)
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        self.sessions[account] = {"ctx": ctx, "page": page, "used": time.time()}
        log("warmed browser for " + account)
        return page

    def drop(self, account):
        s = self.sessions.pop(account, None)
        if s:
            try:
                s["ctx"].close()
            except Exception:
                pass
            log("closed browser for " + account)

    def close_idle(self):
        now = time.time()
        for acct in [a for a, s in self.sessions.items() if now - s["used"] > IDLE_CLOSE_SECONDS]:
            self.drop(acct)

    def close_all(self):
        for acct in list(self.sessions):
            self.drop(acct)


INBOX_URL = "https://mail.google.com/mail/u/0/#inbox"
MAX_PAGES = 5
TIME_SLACK_MS = 150_000  # 2.5 min: notification time vs the row's listed time


def bare_subject(s):
    t = (s or "").replace(" ", " ").replace(" ", " ").strip().lower()
    while True:
        import re as _re
        u = _re.sub(r"^(re|fwd|fw)\s*:\s*", "", t)
        if u == t:
            return t
        t = u


def row_subject(row):
    """The row's subject cell text (Gmail uses span.bog), or '' if not found."""
    try:
        cell = row.locator("span.bog, .bog").first
        if cell.count():
            return cell.inner_text()
    except Exception:
        pass
    return ""


def row_time_ms(row):
    """The row's listed time, parsed from its title attr (for example 'Mon, Jan 5, 2026, 9:30 AM'); 0 if unknown."""
    import datetime
    try:
        els = row.locator("span[title], td[title]")
        for i in range(els.count()):
            title = (els.nth(i).get_attribute("title") or "").replace(" ", " ").replace(" ", " ").strip()
            for fmt in ("%a, %b %d, %Y, %I:%M %p", "%b %d, %Y, %I:%M %p"):
                try:
                    dt = datetime.datetime.strptime(title, fmt)
                    return int(dt.timestamp() * 1000)
                except ValueError:
                    continue
    except Exception:
        pass
    return 0


def find_row(page, address, subject, when_ms=0):
    """
    The unread inbox row for this exact email: sender address match + exact subject; when several
    share a subject, the one whose listed time is closest to the notification's time.
    """
    want = bare_subject(subject)
    rows = page.locator("tr.zA.zE")
    best = None
    best_score = None
    for i in range(rows.count()):
        row = rows.nth(i)
        try:
            em = row.locator("[email]").first
            addr = (em.get_attribute("email") if em.count() else "") or ""
            if address and addr.lower() != address.lower():
                continue
            subj = row_subject(row)
            if subj:
                if bare_subject(subj) != want:
                    continue
            elif want and want not in row.inner_text().lower():
                continue  # no subject cell: fall back to a substring check
            # score by time closeness when we have a target time (lower is better)
            if when_ms:
                diff = abs(row_time_ms(row) - when_ms)
                score = diff
                if row_time_ms(row) == 0:
                    score = TIME_SLACK_MS  # unknown time: acceptable but not preferred
            else:
                score = i  # no target time: the newest match (topmost) wins
            if best is None or score < best_score:
                best, best_score = row, score
        except Exception:
            continue
    # with a target time, require it to be within slack (guards against the wrong same-subject email)
    if best is not None and when_ms and best_score > TIME_SLACK_MS:
        return None
    return best


def ensure_inbox_fresh(page):
    """Show the Inbox and pull the latest with Gmail's own fast Refresh (not a full page reload)."""
    if "#inbox" not in page.url:
        try:
            page.get_by_role("link", name="Inbox", exact=False).first.click(timeout=4000)
        except Exception:
            page.goto(INBOX_URL, timeout=NAV_TIMEOUT_MS, wait_until="domcontentloaded")
    page.wait_for_selector("tr.zA", state="attached", timeout=NAV_TIMEOUT_MS)
    try:
        page.locator("[aria-label='Refresh'], [data-tooltip='Refresh']").first.click(timeout=4000)
        page.wait_for_timeout(1100)
    except Exception:
        page.wait_for_timeout(400)


def mark_read(page, account, address, subject, when_ms, deadline):
    """Find the exact unread email in the Inbox (sender address + subject) and click Mark as read."""
    if "mail.google.com" not in page.url:
        page.goto(INBOX_URL, timeout=NAV_TIMEOUT_MS, wait_until="domcontentloaded")
    ensure_inbox_fresh(page)
    row = None
    for _ in range(MAX_PAGES):
        if time.time() > deadline:
            return {"ok": False, "detail": "deadline hit while searching the Inbox"}
        row = find_row(page, address, subject, when_ms)
        if row:
            break
        try:
            older = page.locator("[aria-label='Older'], [data-tooltip='Older']").first
            if older.count() and older.is_enabled():
                older.click(timeout=3000); page.wait_for_timeout(1000)
            else:
                break
        except Exception:
            break  # no more pages / couldn't page: stop (a notification's email is almost always page 1)
    if not row:
        return {"ok": True, "changed": False, "detail": "no matching unread email (already read?)"}

    row.scroll_into_view_if_needed(); row.hover(); page.wait_for_timeout(300)
    btn = row.locator("[aria-label='Mark as read'], [data-tooltip='Mark as read']").first
    if btn.count() and btn.is_visible():
        btn.click(timeout=5000); method = "row button"
    else:
        cb = row.locator("div[role=checkbox], [role=checkbox]").first
        cb.scroll_into_view_if_needed(); cb.hover(); cb.click(timeout=5000); page.wait_for_timeout(400)
        page.locator("[aria-label='Mark as read'], [data-tooltip='Mark as read']").first.click(timeout=5000)
        method = "checkbox + toolbar"

    if time.time() > deadline:
        return {"ok": True, "changed": True, "method": method, "detail": "clicked; skipped verify (deadline)"}
    page.wait_for_timeout(1400)
    ensure_inbox_fresh(page)
    still = find_row(page, address, subject, when_ms) is not None
    return {"ok": not still, "changed": not still, "method": method,
            "detail": "marked read" if not still else "clicked but still unread"}


def account_enable(browsers, account):
    """Notifications turned ON for this account: if it isn't set up, pop a one-time sign-in window."""
    prof = os.path.join(PROFILES, account)
    if os.path.isdir(prof):
        return {"ok": True, "detail": "already set up"}
    try:
        env = dict(os.environ, DISPLAY=os.environ.get("DISPLAY", ":0"))
        subprocess.Popen([sys.executable, os.path.join(ROOT, "login.py"), account],
                         env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log("account_enable: opened sign-in window for " + account)
        return {"ok": True, "detail": "sign-in window opened"}
    except Exception as e:
        return {"ok": False, "detail": "could not open sign-in: " + repr(e)[:120]}


def account_disable(browsers, account):
    """Notifications turned OFF for this account: close its browser and set its login aside (kept)."""
    browsers.drop(account)
    prof = os.path.join(PROFILES, account)
    if not os.path.exists(prof):
        return {"ok": True, "detail": "was not set up"}
    aside = os.path.join(PROFILES, ".%s.disabled.%d" % (account, int(time.time())))
    try:
        os.rename(prof, aside)  # MOVE aside (works on a symlink too), never delete
        return {"ok": True, "detail": "signed out, login set aside"}
    except Exception as e:
        return {"ok": False, "detail": "could not disable: " + repr(e)[:120]}


def process(browsers, cmd):
    account = cmd.get("account")
    op = cmd.get("op", "markread")
    deadline = time.time() + OP_DEADLINE_SECONDS
    if op == "prewarm":
        try:
            browsers.get(account)
        except RuntimeError:  # no saved sign-in (profile) for this account: skip it, keep running
            return {"ok": False, "detail": "prewarm skipped for %s: not signed in; run: ./ghostctl enable %s"
                    % (account, account)}
        except (PWTimeout, Exception) as e:
            log("prewarm failed, dropping browser: " + repr(e)[:160])
            browsers.drop(account)  # a hung/broken browser is thrown away, not reused
            return {"ok": False, "detail": "error: " + repr(e)[:160]}
        return {"ok": True, "detail": "warmed"}
    if op == "account_enable":
        return account_enable(browsers, account)
    if op == "account_disable":
        return account_disable(browsers, account)
    if op != "markread":
        return {"ok": False, "detail": "unknown op: " + str(op)}
    try:
        page = browsers.get(account)
        return mark_read(page, account, cmd.get("address"), cmd.get("subject"), cmd.get("when", 0), deadline)
    except (PWTimeout, Exception) as e:
        log("op failed, relaunching browser: " + repr(e)[:160])
        browsers.drop(account)  # a hung/broken browser is thrown away, not reused
        return {"ok": False, "detail": "error: " + repr(e)[:160]}


def run_adb(browsers, serial):
    """Listen for commands on the Keeper's logcat tag over adb; mark read as they arrive.

    Supervised: if the adb stream drops it is restarted (with the serial read again from ghost.env);
    commands are deduped by id and stale ones ignored; an idle browser is closed after a while.
    """
    seen = set()
    jsonre = re.compile(r"\{.*\}")
    # Always-on service: listens forever, reconnecting adb if it drops; the browser still sleeps when
    # idle (close_idle). Supervised by systemd (Restart=always) in a real install.
    while True:
        serial = android_serial() or serial  # re-read ghost.env on every (re)connect
        try:
            subprocess.run(["adb", "-s", serial, "connect", serial],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        except Exception:
            pass
        # -T 1: start near 'now' so we don't replay the whole buffer; stale/dedupe guards do the rest.
        # stdbuf -oL forces line-buffering so commands arrive instantly (adb block-buffers a pipe).
        proc = subprocess.Popen(
            ["stdbuf", "-oL", "-eL", "adb", "-s", serial, "logcat", "-s", LOGCAT_TAG + ":I", "-T", "1"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        log("listening on adb logcat tag " + LOGCAT_TAG + " (" + serial + ")")
        try:
            while True:
                # poll with a timeout so we can close an idle browser even when no commands arrive
                ready, _, _ = select.select([proc.stdout], [], [], 15)
                if not ready:
                    browsers.close_idle()
                    if proc.poll() is not None:
                        break
                    continue
                line = proc.stdout.readline()
                if not line:
                    break  # stream ended; outer loop restarts it
                m = jsonre.search(line)
                if not m:
                    continue
                try:
                    cmd = json.loads(m.group(0))
                except Exception:
                    continue
                cid = cmd.get("id") or m.group(0)
                if cid in seen:
                    continue
                if cmd.get("ts") and time.time() - cmd["ts"] / 1000.0 > STALE_CMD_SECONDS:
                    continue
                seen.add(cid)
                if len(seen) > 500:
                    seen.clear(); seen.add(cid)
                log("cmd via logcat: " + json.dumps(cmd)[:160])
                result = process(browsers, cmd)
                log("  -> " + json.dumps(result)[:200])
                last_activity = time.time()
                browsers.close_idle()
        finally:
            try:
                proc.terminate()
            except Exception:
                pass
        time.sleep(1)


def main():
    for d in (CMD, PROCESSED, DONE, PROFILES, os.path.dirname(LOG)):
        os.makedirs(d, exist_ok=True)
    once = "--once" in sys.argv
    adb_mode = "--adb" in sys.argv
    if adb_mode:
        serial = android_serial()
        if not serial:
            log("ANDROID_SERIAL is not set: put the line ANDROID_SERIAL=IP:PORT (your Wireless debugging "
                "address) in " + CONFIG + " or set the ANDROID_SERIAL environment variable (see README)")
            sys.exit(2)
        log("ghostd started (adb logcat mode)")
        with sync_playwright() as pw:
            browsers = Browsers(pw)
            try:
                run_adb(browsers, serial)
            finally:
                browsers.close_all()
                log("ghostd stopped")
        return
    log("ghostd started (once=%s)" % once)
    last_activity = time.time()
    with sync_playwright() as pw:
        browsers = Browsers(pw)
        try:
            while True:
                files = sorted(f for f in os.listdir(CMD) if f.endswith(".json"))
                for fn in files:
                    path = os.path.join(CMD, fn)
                    try:
                        cmd = json.load(open(path))
                    except Exception as e:
                        cmd = {"_bad": repr(e)}
                    log("cmd %s: %s" % (fn, json.dumps(cmd)[:160]))
                    result = process(browsers, cmd) if "_bad" not in cmd else {"ok": False, "detail": cmd["_bad"]}
                    json.dump({"cmd": cmd, "result": result, "ts": time.time()},
                              open(os.path.join(DONE, fn), "w"))
                    os.replace(path, os.path.join(PROCESSED, fn))  # MOVE, never delete
                    log("  -> " + json.dumps(result)[:200])
                    last_activity = time.time()
                if files and once:
                    break
                browsers.close_idle()
                if not once and time.time() - last_activity > DAEMON_IDLE_EXIT_SECONDS:
                    log("idle too long, exiting"); break
                if once and not files:
                    break
                time.sleep(POLL_SECONDS)
        finally:
            browsers.close_all()
            log("ghostd stopped")


if __name__ == "__main__":
    main()
