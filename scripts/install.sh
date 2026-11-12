#!/usr/bin/env bash
# Install the LocalSend applet. Everything ships inside the plasmoid package: the widget
# supervises the daemon itself (contents/backend/manage.sh), so there is no systemd unit,
# no ~/.local/bin entry and nothing else to remove when the applet is uninstalled.
# Works from inside a distrobox: writes into the shared $HOME and uses the host
# kpackagetool6 (via distrobox-host-exec) when it exists.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Inside a distrobox the container $HOME is not the session home that plasmashell reads.
# Prefer the host user's home when it is bind-mounted (distrobox mounts /home).
TARGET_HOME="${TARGET_HOME:-$HOME}"
if [ -n "${CONTAINER_ID:-}" ] && [ -d "/home/$(id -un)" ] && [ "/home/$(id -un)" != "$HOME" ]; then
    TARGET_HOME="/home/$(id -un)"
fi

PLASMOID_SRC="$HERE/plasmoid/io.github.localsend.plasmoid"
PLASMOID_ID="$(basename "$PLASMOID_SRC")"
PLASMOID_DST="$TARGET_HOME/.local/share/plasma/plasmoids/$PLASMOID_ID"
BACKEND_SRC="$PLASMOID_SRC/contents/backend"

say() { printf '\033[1m%s\033[0m\n' "$*"; }

run_host() {
    if command -v "$1" >/dev/null 2>&1; then "$@"; else distrobox-host-exec "$@" 2>/dev/null || true; fi
}

say "1/3 checking the Python backend prerequisites"
PY_BIN="$(command -v python3 || true)"
if [ -z "$PY_BIN" ]; then
    printf 'install: python3 is required by the daemon\n' >&2
    exit 1
fi
"$PY_BIN" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' || {
    printf 'install: python 3.11+ is required (found %s)\n' "$("$PY_BIN" -V 2>&1)" >&2
    exit 1
}
"$PY_BIN" -m py_compile "$HERE/python/localsendd" "$HERE/python/localsendctl"

say "2/3 staging the backend into the package ($BACKEND_SRC)"
mkdir -p "$BACKEND_SRC"
install -m755 "$HERE/python/localsendd" "$BACKEND_SRC/localsendd"
install -m755 "$HERE/python/localsendctl" "$BACKEND_SRC/localsendctl"
chmod 755 "$BACKEND_SRC/manage.sh"

say "3/3 migrating away from the old global install"
run_host pkill -x localsendd || true
run_host systemctl --user disable --now localsendd.service >/dev/null 2>&1 || true
rm -f "$TARGET_HOME/.config/systemd/user/localsendd.service"
run_host systemctl --user daemon-reload >/dev/null 2>&1 || true
rm -f "$TARGET_HOME/.local/bin/localsendd" \
      "$TARGET_HOME/.local/bin/localsendctl" \
      "$TARGET_HOME/.local/bin/localsend-bootstrap.sh"
rm -f "$TARGET_HOME/.config/autostart/localsendd.desktop"

say "3/3 installing plasmoid -> $PLASMOID_DST"
if command -v kpackagetool6 >/dev/null 2>&1; then
    kpackagetool6 --type Plasma/Applet --upgrade "$PLASMOID_SRC" 2>/dev/null \
        || kpackagetool6 --type Plasma/Applet --install "$PLASMOID_SRC"
elif command -v distrobox-host-exec >/dev/null 2>&1 && distrobox-host-exec command -v kpackagetool6 >/dev/null 2>&1; then
    distrobox-host-exec kpackagetool6 --type Plasma/Applet --upgrade "$PLASMOID_SRC" 2>/dev/null \
        || distrobox-host-exec kpackagetool6 --type Plasma/Applet --install "$PLASMOID_SRC"
else
    rm -rf "$PLASMOID_DST"
    mkdir -p "$(dirname "$PLASMOID_DST")"
    cp -r "$PLASMOID_SRC" "$PLASMOID_DST"
fi

say "done"
cat <<TXT
Installed. The applet starts the daemon itself on load and stops it on removal; the daemon
also exits after 15 min without a widget heartbeat, so an orphan cannot outlive the widget.

Next steps:
  - restart plasmashell : distrobox-host-exec $HERE/scripts/restart-plasma.sh
  - CLI (no PATH entry) : sh $PLASMOID_DST/contents/backend/manage.sh ctl state
  - daemon log          : \${XDG_CACHE_HOME:-\$HOME/.cache}/localsend-applet/daemon.log
  - received files go to ~/Downloads/LocalSend (override in ~/.config/localsendd/config.json)
TXT
