#!/system/bin/sh
# Gmail Ghost: the supervisor. It runs the ghost daemon (ghostd.py --device), which marks emails read
# for the Notification Keeper, on the Googlebook itself as the adb shell user, so it needs neither the
# Linux Terminal nor a computer. The Gmail Ghost app starts it through its own paired adb key at every
# restart and every 15 minutes; it can also be started by hand.
#
#   sh ghost.sh start      start the ghost (does nothing if it is already running); clears a stop
#   sh ghost.sh ensure     the app's automatic start: does nothing if you stopped it
#   sh ghost.sh restart    the app's restart after it installed newer files (not if you stopped it)
#   sh ghost.sh stop       stop the ghost; it stays stopped until "start"
#   sh ghost.sh status     first line "running" or "NOT running", then details
#
# The supervisor restarts the daemon whenever it exits, and also when the daemon stops writing its
# alive file for 5 minutes (a hang), waiting a little longer after each quick failure so it never
# hammers. It holds no wake lock, changes no setting and never deletes a file: state is kept by
# overwriting small files, and every month gets a log file of its own.
#
# Files, all in /data/local/tmp/gmailghost: rt/ (the runtime), ghostd.py, profiles/ (the signed-in
# Gmail accounts), logs/ghostd.log (what the ghost did), logs/ghost-YYYY-MM.txt (what this supervisor
# did), logs/daemon-output.txt (the daemon's own output, overwritten at each start), status.

G=/data/local/tmp/gmailghost
SCRIPT=$G/ghost.sh
HANG_S=300            # restart a daemon that has not written its alive file for this long
DNS_FILE=/sdcard/.ggdns
umask 077
mkdir -p $G/logs

note() { echo "$(date '+%Y-%m-%d %H:%M:%S %Z') $*" >> $G/logs/ghost-$(date +%Y-%m).txt; }
control() { cat $G/control 2>/dev/null; }

SUP="sh $SCRIPT supervise"
pids_of() { ps -A -o PID,ARGS 2>/dev/null | sed 1d | while read -r p a; do [ "$a" = "$1" ] && echo "$p"; done; }
supervisor_alive() { [ -n "$(pids_of "$SUP")" ]; }
daemon_pid() {
    p=$(cat $G/daemon.pid 2>/dev/null)
    [ -n "$p" ] && grep -q "ghostd.py" /proc/$p/cmdline 2>/dev/null && echo "$p"
}

# The runtime's C library reads its DNS servers from this file (Android has no /etc/resolv.conf).
# The Googlebook's current DNS servers come first, public ones after them as a fallback.
write_dns() {
    servers=$(timeout 15 dumpsys connectivity 2>/dev/null | grep -oE 'DnsAddresses: \[[^]]*\]' |
              grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -3)
    {
        for s in $servers 8.8.8.8 1.1.1.1; do echo "nameserver $s"; done | awk '!seen[$0]++' | head -3
        echo "options timeout:2 attempts:2"
    } > $DNS_FILE.new && mv $DNS_FILE.new $DNS_FILE
}

start_daemon() {
    write_dns
    # The daemon's own output goes to a file, never a pipe, so it can never wait on us.
    sh -c '. "$0"/env.sh; cd "$0"; echo $$ > "$0"/daemon.pid
           exec $PY "$0"/ghostd.py --device > "$0"/logs/daemon-output.txt 2>&1 < /dev/null' $G 9>&- &
    sleep 1
    echo "$(date +%s)" > $G/logs/alive
    note "ghost daemon started (pid $(cat $G/daemon.pid 2>/dev/null))"
}

stop_daemon() {
    p=$(daemon_pid)
    [ -n "$p" ] || return 0
    kill $p 2>/dev/null
    i=0
    while [ -n "$(daemon_pid)" ] && [ $i -lt 10 ]; do sleep 1; i=$((i + 1)); done
    p=$(daemon_pid); [ -n "$p" ] && kill -9 $p 2>/dev/null
    # Its browser and node driver, if any were left behind: only processes of this runtime.
    for q in $(ps -A -o PID,ARGS 2>/dev/null | sed 1d | while read -r pp aa; do
                   case "$aa" in *"$G/rt/"*) echo "$pp" ;; esac; done); do
        kill $q 2>/dev/null
    done
}

write_status() {   # $1 = state word
    {
        echo "state=$1"
        echo "since=$STARTED"
        echo "alive=$(date +%s)"
        echo "daemon_alive=$(cat $G/logs/alive 2>/dev/null || echo 0)"
        echo "daemon_starts=$STARTS"
        echo "boot=$(cat /proc/sys/kernel/random/boot_id)"
        echo "last_result=$(grep ' -> ' $G/logs/ghostd.log 2>/dev/null | tail -1 | cut -c1-200)"
    } > $G/status
}

supervise() {
    echo $$ > $G/supervisor.pid
    STARTED=$(date +%s); STARTS=0; backoff=5
    note "supervisor started (pid $$, build $(getprop ro.build.fingerprint))"
    stop_daemon   # never two daemons at once
    start_daemon; STARTS=1; started_at=$(date +%s)
    n=0
    write_status running
    while [ "$(control)" != stop ]; do
        [ "$(cat $G/supervisor.pid 2>/dev/null)" = "$$" ] || { note "another supervisor took over; this one exits"; exit 0; }
        sleep 5
        t=$(date +%s); n=$((n + 1))
        if [ -z "$(daemon_pid)" ]; then
            # A daemon that ran for a while starts again at once; quick failures wait longer each time.
            if [ $((t - started_at)) -ge 120 ]; then backoff=5; fi
            note "the ghost daemon had stopped ($(tail -1 $G/logs/daemon-output.txt 2>/dev/null | cut -c1-160)); starting it again in $backoff s"
            sleep $backoff
            [ "$(control)" = stop ] && break
            [ $backoff -lt 300 ] && backoff=$((backoff * 2))
            start_daemon; STARTS=$((STARTS + 1)); started_at=$(date +%s)
        else
            a=$(cat $G/logs/alive 2>/dev/null || echo 0)
            if [ $((t - a)) -ge $HANG_S ]; then
                note "the ghost daemon stopped responding (alive $((t - a)) s ago); restarting it"
                stop_daemon
                start_daemon; STARTS=$((STARTS + 1)); started_at=$(date +%s)
            fi
        fi
        [ $((n % 12)) = 0 ] && write_status running
    done
    stop_daemon
    write_status stopped
    note "supervisor stopped"
}

# One control action at a time (app, boot, by hand). The daemon is started with fd 9 closed so it never
# holds the lock.
locked() {
    (
        i=0
        until flock -n 9; do
            i=$((i + 1)); [ $i -ge 30 ] && { echo "another start or stop is still in progress"; exit 0; }
            sleep 1
        done
        "$@"
    ) 9>>$G/control.lock
}
do_start() {   # $1 = start | ensure
    [ "$1" = ensure ] && [ "$(control)" = stop ] && { echo "stopped by you"; return; }
    [ "$1" = start ] && echo run > $G/control
    supervisor_alive && { echo "already running"; return; }
    setsid sh $SCRIPT supervise < /dev/null > /dev/null 2>&1 9>&- &
    i=0
    while ! supervisor_alive && [ $i -lt 5 ]; do sleep 1; i=$((i + 1)); done
    if supervisor_alive; then echo "started"; else echo "failed to start"; fi
}
do_restart() {
    [ "$(control)" = stop ] && { echo "stopped by you"; return; }
    for p in $(pids_of "$SUP"); do kill $p 2>/dev/null; done
    i=0
    while [ -n "$(pids_of "$SUP")" ] && [ $i -lt 5 ]; do sleep 1; i=$((i + 1)); done
    for p in $(pids_of "$SUP"); do kill -9 $p 2>/dev/null; done
    stop_daemon
    note "restarting with the newly installed files"
    do_start ensure
}
do_stop() {
    echo stop > $G/control
    for p in $(pids_of "$SUP"); do kill $p 2>/dev/null; done
    stop_daemon
    STARTED=$(sed -n 's/^since=//p' $G/status 2>/dev/null); STARTS=$(sed -n 's/^daemon_starts=//p' $G/status 2>/dev/null)
    write_status stopped
    note "stopped by request"
    echo "stopped"
}

case "$1" in
    start|ensure) locked do_start "$1" ;;
    restart)      locked do_restart ;;
    stop)         locked do_stop ;;
    supervise)    supervise ;;
    status)
        if supervisor_alive && [ -n "$(daemon_pid)" ]; then echo "running"; else echo "NOT running"; fi
        [ "$(control)" = stop ] && echo "stopped by you"
        cat $G/status 2>/dev/null
        ;;
    *) echo "usage: sh ghost.sh start|ensure|restart|stop|status"; exit 2 ;;
esac
