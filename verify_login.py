import os, sys
from playwright.sync_api import sync_playwright
# Checks that an account's saved ghost-browser sign-in still works (used by "ghostctl doctor").
# Usage: verify_login.py <account-email>   Prints "<account> -> SIGNED_IN: True|False | search box: N".
ROOT = os.path.dirname(os.path.abspath(__file__))
acct=sys.argv[1]; prof=os.path.join(ROOT, "profiles", acct)
ARGS=["--no-first-run","--no-default-browser-check","--disable-blink-features=AutomationControlled"]
with sync_playwright() as p:
    ctx=p.chromium.launch_persistent_context(prof,headless=True,args=ARGS)
    pg=ctx.pages[0] if ctx.pages else ctx.new_page()
    pg.goto("https://mail.google.com/mail/u/0/#inbox",timeout=40000,wait_until="domcontentloaded")
    pg.wait_for_timeout(4000)
    signed=pg.url.startswith("https://mail.google.com/mail") and "signin" not in pg.url and "ServiceLogin" not in pg.url
    search=pg.locator("[aria-label*='Search mail' i]").count()
    print(acct, "-> SIGNED_IN:", signed, "| search box:", search)
    ctx.close()
