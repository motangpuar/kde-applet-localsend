# kde-applet-localsend

## Overview
KDE Plasma 6 applet for LocalSend: a Python daemon (`python/localsendd`) owns the LocalSend v2
protocol (UDP multicast discovery, HTTPS receive server, sending) and a thin QML plasmoid drives it
through `localsendctl` over a unix control socket. No dependency on the Flutter LocalSend app, no
D-Bus, no systemd, no compiler at run time.

## Toolchain
- Python ≥ 3.11, standard library only; `cryptography` optional for the self-signed certificate
  (`openssl` CLI fallback). No third-party packages, so no venv and no lockfile to maintain.
- QML/Plasma 6 package (`KPackageStructure: Plasma/Applet`), Kirigami + PlasmaComponents3
- Host integration: `kpackagetool6` lives on the host; container reaches it via `distrobox-host-exec`

## Backend contract
- `python/localsendd` + `python/localsendctl` are staged verbatim into `contents/backend/` by
  `make backend`; the filenames must stay extension-free with a `#!/usr/bin/env python3` shebang.
- `manage.sh` and the QML must not assume compact JSON: probe with `"ok":[[:space:]]*true`.
- Test hooks (never set in production): `LOCALSENDD_DISCOVERY=0` skips discovery,
  `LOCALSENDD_DISCOVERY_PORT=<n>` scopes announcements to one socket, `LOCALSENDD_GUARD_NAME=<n>`
  renames the abstract single-instance socket. Needed because the suite shares the network namespace
  with the live daemon and `SO_REUSEPORT` load-balances multicast between local sockets.

## Commands
- build/stage: `make backend` (`py_compile` + copy into `contents/backend/`)
- test: `make test` (9 unittest cases; hermetic dirs, discovery off, real TLS loopback)
- lint: `make lint` (`py_compile` + `compileall`); `sh -n` on every script under `scripts/` and
  `contents/backend/manage.sh`
- install: `./scripts/install.sh` (checks python3 ≥ 3.11, stages the backend, `kpackagetool6 --upgrade`)
- uninstall: `./scripts/uninstall.sh` (`--purge` also drops config/history)
- smoke: `sh /var/home/infidel/.local/share/plasma/plasmoids/io.github.localsend.plasmoid/contents/backend/manage.sh ctl state`
- restart shell: `distrobox-host-exec ./scripts/restart-plasma.sh`
- packaged verify: `make verify`

## Package layout
- `plasmoid/io.github.localsend.plasmoid/contents/backend/` holds `localsendd`, `localsendctl` and
  `manage.sh`; `install.sh` stages the binaries there, `.gitignore` keeps them out of git.
- Nothing is installed outside the package except runtime data: staged copies in
  `~/.local/share/localsend-applet/`, log in `~/.cache/localsend-applet/`, config/history in
  `~/.config/localsendd/`.

## Architecture invariants
- `localsendd` is the only component that speaks the protocol; QML never opens sockets.
- Wire session id from `prepare-upload` (receiver-owned) is what `upload` must use; the local
  session id is only a UI handle. Mixing them silently breaks transfers.
- Port 53317 is shared, not owned: discovery binds UDP 53317 with SO_REUSEADDR|SO_REUSEPORT and the
  HTTPS server auto-increments from 53317 when the official app holds it.
- Self-signed TLS is accepted on purpose; peer identity is the device fingerprint.
- Lifecycle: the widget supervises the daemon through `manage.sh` (no systemd unit). Every `state`
  request is the supervisor heartbeat; `--idle-exit` (default 900 s) reaps a daemon whose
  widget vanished. The enabled/disabled switch is a marker file `$DATA/disabled` read through
  `manage.sh query-enabled` on every widget load — never trust `Plasmoid.configuration` alone.
  Do not stop the daemon from `Component.onDestruction` — that races a restarted
  plasmashell and kills the daemon it just attached to.
- Control plane `python/localsendd` (`serve_control`): one newline-delimited JSON request/response per connection on
  `$XDG_RUNTIME_DIR/localsend-applet/control.sock`; `localsendctl` prints the response so QML only
  parses stdout. No session bus anywhere in the stack.
