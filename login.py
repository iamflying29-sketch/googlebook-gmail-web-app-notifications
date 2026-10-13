#!/usr/bin/env python3
"""
One-time sign-in for a Gmail account into the ghost browser.

Google requires a human to sign in (password + 2FA) in a real browser - it blocks scripted logins.
So this pops a Chromium window on screen, pre-fills the email, and waits for you to finish. The
session is saved to profiles/<account>/ and persists for weeks; the daemon reuses it headless.

Usage:  login.py <account-email>
"""
import os, sys, time
from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.abspath(__file__))
ARGS = ["--no-first-run", "--no-default-browser-check", "--disable-blink-features=AutomationControlled"]
DEADLINE_SECONDS = 900  # 15 min watchdog: the window always closes, nothing left hanging


def profile_dir(account):
    return os.path.join(ROOT, "profiles", account)


def login(account):
    prof = profile_dir(account)
    os.makedirs(prof, exist_ok=True)
    deadline = time.time() + DEADLINE_SECONDS
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            prof, headless=False, viewport={"width": 1100, "height": 820}, args=ARGS)
        try:
            pg = ctx.pages[0] if ctx.pages else ctx.new_page()
            # go straight to the sign-in, pre-filling the email so it's just password + 2FA
            pg.goto("https://accounts.google.com/ServiceLogin?service=mail&Email=" + account,
                    timeout=30000, wait_until="domcontentloaded")
            try:
                box = pg.locator("input[type=email]").first
                if box.count():
                    box.fill(account, timeout=4000)
            except Exception:
                pass
            print("STATE: waiting for you to finish signing in to", account)
            ok = False
            while time.time() < deadline:
                try:
                    if pg.url.startswith("https://mail.google.com/mail") and (
                        pg.locator("[aria-label*='Search mail' i]").count()
                        or pg.get_by_role("button", name="Compose").count()):
                        ok = True
                        break
                except Exception:
                    pass
                time.sleep(2)
            print("RESULT:", "LOGGED_IN" if ok else "TIMEOUT")
            return 0 if ok else 2
        finally:
            ctx.close()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: login.py <account-email>"); sys.exit(1)
    sys.exit(login(sys.argv[1]))
