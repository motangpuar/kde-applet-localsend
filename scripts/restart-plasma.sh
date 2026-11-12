#!/usr/bin/env bash
# Restart plasmashell so applet QML is re-read from disk. Run on the session host
# (from a distrobox: `distrobox-host-exec ./scripts/restart-plasma.sh`).
set -uo pipefail

# plasmashell runs inside app-plasmashell@<id>.service; restart the unit that actually owns the pid.
unit_of_pid() {
    local pid="$1"
    [ -z "$pid" ] && return
    systemctl --user status "$pid" --no-pager 2>/dev/null \
        | head -1 | sed -e 's/^[^A-Za-z0-9]*//' -e 's/ .*$//'
}

if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    # The old process stays visible to pgrep for a moment: wait for the pid to CHANGE.
    before="$(pgrep -x plasmashell | head -1)"
    unit="$(unit_of_pid "$before")"
    [ -n "$unit" ] || unit="plasma-plasmashell.service"
    systemctl --user restart "$unit"
    for _ in $(seq 1 80); do
        now="$(pgrep -x plasmashell | head -1)"
        [ -n "$now" ] && [ "$now" != "$before" ] && break
        sleep 0.25
    done
    sleep 3
    now="$(pgrep -x plasmashell | head -1)"
    if [ -n "$now" ] && [ "$now" != "$before" ]; then
        echo "plasmashell up: $now"
        exit 0
    fi
    echo "systemd restart did not bring plasmashell up, falling back" >&2
fi

echo "stopping plasmashell"
kquitapp6 plasmashell >/dev/null 2>&1 || true
for _ in $(seq 1 40); do pgrep -x plasmashell >/dev/null || break; sleep 0.25; done
if pgrep -x plasmashell >/dev/null; then
    echo "kquitapp6 did not finish, terminating"
    pkill -x plasmashell; sleep 1
    pgrep -x plasmashell >/dev/null && pkill -9 -x plasmashell
fi

echo "starting plasmashell"
setsid --fork env QT_QPA_PLATFORM=wayland kstart plasmashell >/dev/null 2>&1
for _ in $(seq 1 80); do pgrep -x plasmashell >/dev/null && break; sleep 0.25; done
sleep 2
if pgrep -x plasmashell >/dev/null; then
    echo "plasmashell up: $(pgrep -x plasmashell | head -1)"
else
    echo "plasmashell FAILED to start" >&2
    exit 1
fi
