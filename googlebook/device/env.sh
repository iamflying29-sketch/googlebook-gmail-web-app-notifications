# Environment for the Gmail Ghost runtime on GooglebookOS (sourced by ghost.sh and by tests).
G=/data/local/tmp/gmailghost
RT=$G/rt
mkdir -p $G/home/.cache $G/home/.config $G/tmp $G/logs $G/profiles
export HOME=$G/home TMPDIR=$G/tmp XDG_CACHE_HOME=$G/home/.cache XDG_CONFIG_HOME=$G/home/.config
export PYTHONHOME=$RT/py PYTHONPATH=$RT/site PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
export PLAYWRIGHT_BROWSERS_PATH=$RT/browsers PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1
export FONTCONFIG_FILE=$RT/etc/fonts/fonts.conf TZ=UTC TZDIR=$RT/zoneinfo LANG=C.UTF-8 LC_ALL=C.UTF-8
unset LD_LIBRARY_PATH LD_PRELOAD
export PLAYWRIGHT_NODEJS_PATH=$G/node-wrap.sh
# Python is a fixed-address program, so it is started through the runtime's own loader.
for PYBIN in $RT/py/bin/python3*; do :; done   # the runtime's Python, whatever its version
PY="$RT/lib/ld-linux-x86-64.so.2 --library-path $RT/lib $PYBIN"
