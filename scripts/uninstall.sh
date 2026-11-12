#!/usr/bin/env bash
# Remove the LocalSend applet and the backend that ships with it.
# Settings and transfer history (~/.config/localsendd) are kept unless --purge is given.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TARGET_HOME="${TARGET_HOME:-$HOME}"
if [ -n "${CONTAINER_ID:-}" ] && [ -d "/home/$(id -un)" ] && [ "/home/$(id -un)" != "$HOME" ]; then
    TARGET_HOME="/home/$(id -un)"
fi

PLASMOID_ID="io.github.localsend.plasmoid"
PLASMOID_DST="$TARGET_HOME/.local/share/plasma/plasmoids/$PLASMOID_ID"
PURGE="${PURGE:-0}"
[ "${1:-}" = "--purge" ] && PURGE=1

say() { printf '\033[1m%s\033[0m\n' "$*"; }

say "1/3 stopping the daemon"
if [ -x "$PLASMOID_DST/contents/backend/manage.sh" ]; then
    HOME="$TARGET_HOME" XDG_DATA_HOME="$TARGET_HOME/.local/share" \
        sh "$PLASMOID_DST/contents/backend/manage.sh" stop || true
fi
pkill -x localsendd >/dev/null 2>&1 || true

say "2/3 removing the package"
if command -v kpackagetool6 >/dev/null 2>&1; then
    kpackagetool6 --type Plasma/Applet --remove "$PLASMOID_ID" || rm -rf "$PLASMOID_DST"
elif command -v distrobox-host-exec >/dev/null 2>&1; then
    distrobox-host-exec kpackagetool6 --type Plasma/Applet --remove "$PLASMOID_ID" || rm -rf "$PLASMOID_DST"
else
    rm -rf "$PLASMOID_DST"
fi

say "3/3 removing staged copies and leftovers of the old layout"
rm -rf "$TARGET_HOME/.local/share/localsend-applet" "$TARGET_HOME/.cache/localsend-applet"
rm -f "$TARGET_HOME/.config/systemd/user/localsendd.service" \
      "$TARGET_HOME/.local/bin/localsendd" \
      "$TARGET_HOME/.local/bin/localsendctl" \
      "$TARGET_HOME/.local/bin/localsend-bootstrap.sh" \
      "$TARGET_HOME/.local/share/icons/hicolor/scalable/apps/$PLASMOID_ID.svg"
if [ "$PURGE" = "1" ]; then
    rm -rf "$TARGET_HOME/.config/localsendd"
    echo "  purged ~/.config/localsendd (settings + history)"
fi

say "done"
echo "Restart plasmashell to unload the widget: $HERE/scripts/restart-plasma.sh"
