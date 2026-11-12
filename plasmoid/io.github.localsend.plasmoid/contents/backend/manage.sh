#!/bin/sh
# Supervisor for the LocalSend widget: the widget owns the daemon, there is no systemd unit.
#
# Shipped at contents/backend/manage.sh next to the built binaries, so the applet needs no
# installer, no PATH entry and no service: removing the widget removes the whole backend.
#
#   sh manage.sh ensure [--idle-exit SECS]   start the daemon unless it already answers
#   sh manage.sh stop                        stop it (graceful API shutdown, then SIGTERM)
#   sh manage.sh restart                     ensure with forced restart
#   sh manage.sh enable | disable            flip the user-visible master switch
#   sh manage.sh query-enabled               LOCALSEND_ENABLED | LOCALSEND_DISABLED
#   sh manage.sh ctl <args...>               run localsendctl against the staged copy
#
# The master switch lives in a marker file (`$DATA/disabled`), not only in the plasmoid config:
# KConfig silently dropped the key once and left the backend dead with no trace. The marker is the
# single source of truth; the widget mirrors it into its config purely for display.
#
# Single instance: the daemon holds a flock on $XDG_RUNTIME_DIR/localsend-applet/daemon.lock, so
# repeated ensure calls (or a widget reload racing its own poll) can never produce two daemons,
# which would otherwise announce one fingerprint from two ports and show up as duplicates.
#
# Lifetime model: the widget polls `state` every few seconds, which doubles as the daemon's
# heartbeat. If the widget disappears (plasmashell crash, package removed from the store UI,
# uninstall without running the script) the daemon reaps itself after --idle-exit seconds
# without a heartbeat, so an orphan cannot linger. Tokens printed for the QML caller:
#   LOCALSEND_RUNNING <json> | LOCALSEND_STARTED <json> | LOCALSEND_STOPPED | LOCALSEND_FAILED <msg>
# Exit codes: 0 ok, 2 packaged binaries missing, 3 daemon did not come up.
set -eu

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/localsend-applet"
BIN="$DATA/bin"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/localsend-applet"
RUNTIME="${XDG_RUNTIME_DIR:-$CACHE/run}/localsend-applet"
PIDFILE="$RUNTIME/daemon.pid"
LOG="$CACHE/daemon.log"
IDLE="${LOCALSEND_IDLE_EXIT:-900}"
SWITCH="$DATA/disabled"
ACTION=ensure
RESTART=0
WANT_ENABLE=0
WANT_DISABLE=0
CTL_ARGS=""

while [ $# -gt 0 ]; do
    case "$1" in
        ensure|stop|restart|query-enabled) ACTION=$1; [ "$1" = restart ] && { ACTION=ensure; RESTART=1; }; shift ;;
        enable)  ACTION=ensure; WANT_ENABLE=1; shift ;;
        disable) ACTION=stop;   WANT_DISABLE=1; shift ;;
        ctl) ACTION=ctl; shift; CTL_ARGS="$*"; break ;;
        --idle-exit) IDLE=${2:?--idle-exit needs a value}; shift 2 ;;
        *) printf 'manage: unknown argument %s\n' "$1" >&2; exit 64 ;;
    esac
done

mkdir -p "$BIN" "$CACHE"
[ "$WANT_ENABLE" -eq 1 ] && rm -f "$SWITCH"
[ "$WANT_DISABLE" -eq 1 ] && : >"$SWITCH"

# Serialise concurrent callers: plasmashell loads the widget and its first poll can both ask.
if command -v flock >/dev/null 2>&1; then
    exec 9>"$CACHE/.manage.lock"
    flock -w 15 9 || true
fi

# Stage the binaries outside the package directory: a package upgrade replaces those files, and
# a running process must not depend on inode identity there.
stage() {
    src="$HERE/$1"
    dst="$BIN/$1"
    [ -f "$src" ] || { printf 'manage: packaged %s missing next to %s\n' "$1" "$0" >&2; exit 2; }
    if [ ! -f "$dst" ] || ! cmp -s "$src" "$dst"; then
        cp -f "$src" "$dst.tmp"
        chmod 755 "$dst.tmp"
        mv -f "$dst.tmp" "$dst"
        CHANGED=1
    fi
}

CHANGED=0
stage localsendd
stage localsendctl

DAEMON="$BIN/localsendd"
CTL="$BIN/localsendctl"

# Accept both compact (`"ok":true`, serde) and spaced (`"ok": true`, python) JSON.
probe() { "$CTL" state 2>/dev/null | grep -Eq '"ok":[[:space:]]*true'; }

# Wait for a freshly spawned daemon to answer (cold start includes cert generation).
wait_up() {
    _tries=$((${1:-15} * 10))
    while [ "$_tries" -gt 0 ]; do
        probe && return 0
        _tries=$((_tries - 1))
        sleep 0.1
    done
    return 1
}

pid_alive() {
    [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

stop_daemon() {
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if probe; then
        "$CTL" shutdown >/dev/null 2>&1 || true
        for _ in $(seq 1 30); do
            probe || break
            sleep 0.1
        done
    fi
    # A daemon that ignores the graceful request (stuck on a transfer) gets SIGTERM, and only
    # after that are strays from an older install reaped.
    if pid_alive "$pid"; then
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 20); do
            pid_alive "$pid" || break
            sleep 0.1
        done
    fi
    pkill -x localsendd >/dev/null 2>&1 || true
    rm -f "$PIDFILE"
    printf 'LOCALSEND_STOPPED\n'
}

case "$ACTION" in
    query-enabled)
        if [ -e "$SWITCH" ]; then printf 'LOCALSEND_DISABLED\n'; else printf 'LOCALSEND_ENABLED\n'; fi
        ;;
    stop)
        stop_daemon
        ;;
    ctl)
        if [ -z "$CTL_ARGS" ]; then
            printf 'manage: ctl needs arguments, e.g. "manage.sh ctl state"\n' >&2
            exit 64
        fi
        # shellcheck disable=SC2086
        exec "$CTL" $CTL_ARGS
        ;;
    ensure)
        if [ -e "$SWITCH" ]; then
            printf 'LOCALSEND_DISABLED\n'
            exit 0
        fi
        if probe; then
            if [ "$CHANGED" -eq 1 ] || [ "$RESTART" -eq 1 ]; then
                printf 'manage: package binaries changed, restarting daemon\n'
                stop_daemon >/dev/null
            else
                printf 'LOCALSEND_RUNNING %s\n' "$("$CTL" state)"
                exit 0
            fi
        fi
        # A concurrent ensure (widget load racing its own poll) may already be booting the daemon:
        # it holds the flock, so ours would exit immediately. Adopt that one instead of failing.
        if pgrep -x localsendd >/dev/null 2>&1; then
            if wait_up 12; then
                printf 'LOCALSEND_RUNNING %s\n' "$("$CTL" state)"
                exit 0
            fi
            printf 'manage: no daemon answered, reaping stragglers\n' >>"$LOG"
            stop_daemon >/dev/null
        fi
        mkdir -p "$CACHE"
        printf '=== %s start\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$LOG"
        setsid "$DAEMON" --idle-exit "$IDLE" >>"$LOG" 2>&1 </dev/null &
        if ! wait_up 20; then
            printf 'LOCALSEND_FAILED daemon did not answer, see %s\n' "$LOG"
            exit 3
        fi
        printf 'LOCALSEND_STARTED %s\n' "$("$CTL" state)"
        exit 0
        ;;
esac
