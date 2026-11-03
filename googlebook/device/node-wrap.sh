#!/system/bin/sh
# Starts Playwright's node through the Gmail Ghost runtime's own loader (Android has no /lib64 loader).
RT=/data/local/tmp/gmailghost/rt
exec $RT/lib/ld-linux-x86-64.so.2 --library-path $RT/lib $RT/site/playwright/driver/node "$@"
