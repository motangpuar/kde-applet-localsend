# MEMORIES

Session ledger for the LocalSend Plasma applet. Newest round first; keep entries short and factual.

## Current Status
Round 12 (2026-11-13): release engineering and history UX. `scripts/package.sh` is the only packaging
path — stages the backend, stamps the version, builds `build/<id>-<version>.plasmoid`, then verifies
metadata id/version, required files, safe paths, executable bits and absence of `__pycache__`. CI runs
on every push/PR (shell syntax, byte-compile, 11 tests, archive artifact); `release.yml` on `v*` tags
re-runs the suite, refuses tags not on `main`, stamps the tag as the version and publishes the archive
with `SHA256SUMS`. The header overflow menu is gone (history tab, per-device send, ★, folder button and
footer switches already covered every item). History rebuilt: day-grouped cards with peer, file count,
size, duration, average rate, clock time, first two file names plus "+N more", and a colour chip plus
error text for anything that did not complete; the tab header shows totals (sent/received/size/failed).

Round 11 (2026-11-13): control-plane latency fixed. The daemon inherited fd 9 (the `.manage.lock`
flock) from `manage.sh`, so every later `ctl` call — each 2 s UI poll and every send — waited out
`flock -w 15`. Children now run with `9>&-`; `ctl ping` is 0.04 s (was 15.04 s) and sends reach the
peer immediately. `localsendd` sets `prctl(PR_SET_NAME, "localsendd")` so `pgrep -x`/`pkill -x` match
a shebang script again. Settings page reduced to *Show notifications*; the empty-state scan button is
gone (header refresh only); cold-start `daemon unreachable` journal noise silenced.

Round 10 (2026-11-12): manual `scan`, popup survives the file picker, toggles bound to daemon truth.
`localsendd` gained `scan` (immediate announce + stale-peer prune, `DISCOVERY` holds the live socket)
and atomic `config.json` writes; `localsendctl scan`; header refresh button with busy indicator;
`FileDialog.onAccepted/onRejected` re-expand the popup after 120 ms. Checkboxes/switches use `Binding`
elements (`restoreMode: Binding.RestoreNone`) instead of `checked = Qt.binding()` re-arms, so
favorites and auto-accept render daemon state after any click. Suite: 11 cases.

Round 9 (2026-11-12): repository is Python-only (daemon `python/localsendd`, CLI
`python/localsendctl`, suite `python/tests/test_backend.py`), Makefile targets
`help|test|lint|backend|verify|install|uninstall|run|ctl|clean`, FAANG README, MIT `LICENSE`.

## Active State
- `python/localsendd` (~1 220 lines): `ThreadingHTTPServer` + `ssl` receive server on `0.0.0.0:<port>`
  bound **before** the control socket answers, `http.client` sender (256 KiB chunks, 512 KiB progress
  flushes), multicast discovery thread (5 s announces, 60 s TTL, `announce:false` goodbye), unix
  control-socket accept loop, history sync thread, watchdog thread, `flock` +
  abstract-socket single-instance guards, `pick_port` preferred..+20.
- `python/localsendctl`: `state|peers|send|respond|cancel|history|clear-history|favorite|
  auto-accept|scan|wait-ready|shutdown|ping`, compact JSON so `probe()` can grep `"ok":true`.
- `plasmoid/io.github.localsend.plasmoid`: `main.qml` (poll + `runCtl`), `FullRepresentation.qml`
  (devices/history pages, prompts, footer switches), `CompactRepresentation.qml`,
  `contents/backend/manage.sh` (POSIX `sh` supervisor), `configGeneral.qml` (notifications only).
- `manage.sh`: stages `localsendd`/`localsendctl` into `~/.local/share/localsend-applet/bin` on
  content change, `flock` serialises callers, marker file `$DATA/disabled` owns the master switch,
  `probe`/`wait_up`/adopt-instead-of-race, `ctl` passthrough.

## Known Blockers
- Any process spawned by `manage.sh` must not inherit fd 9, or it holds `.manage.lock` and serialises
  every later call for the full `flock -w 15` timeout.
- Two daemons on one host cannot discover each other (`SO_REUSEPORT` load-balances multicast to one
  socket): one daemon per host; tests isolate `LOCALSENDD_DISCOVERY_PORT`.
- No `qmllint` in the distrobox container or on the host: QML is validated only by plasmashell's
  journal after `scripts/restart-plasma.sh`.
- `distrobox-host-exec systemctl --user is-active plasma-plasmashell` reports `failed` from inside the
  container; use `pgrep -c plasmashell` or the restart script.
- Editing `appletsrc` while plasmashell runs gets clobbered: stop plasmashell first.
- Drag-drop and PIN-protected transfers are untested against real devices.
- Container `$HOME` ≠ session home: drive `manage.sh` by hand only with
  `HOME=/home/infidel XDG_CONFIG_HOME=… XDG_CACHE_HOME=… XDG_DATA_HOME=… XDG_RUNTIME_DIR=/run/user/1000`.

## Key Facts
- One protocol speaker (`localsendd`); QML never opens sockets, it shells out to `manage.sh ctl`.
- Control plane: newline JSON on `$XDG_RUNTIME_DIR/localsend-applet/control.sock`; no D-Bus, no systemd.
- Master switch is the marker file `~/.local/share/localsend-applet/disabled`; KConfig is a cache.
- Lifecycle: widget-as-supervisor, `setsid` detach, `--idle-exit 900` reaps only when quiescent.
- Files: config/history/certs in `~/.config/localsendd/`, log `~/.cache/localsend-applet/daemon.log`,
  received files in `~/Downloads/LocalSend`.
- Test hooks (never in production): `LOCALSENDD_DISCOVERY=0`, `LOCALSENDD_DISCOVERY_PORT`,
  `LOCALSENDD_GUARD_NAME`.
- Restart helper: `distrobox-host-exec ./scripts/restart-plasma.sh` → prints `plasmashell up: <pid>`.

## Next Steps
1. Confirm in the UI: send prompt latency, header refresh button, single settings checkbox.
2. Exercise phone→PC receive and `Send…` again; verify favorites/auto-accept across a daemon restart.
3. Optional: mDNS (`_localsend._tcp`), KNotification inline accept/decline, v2.1 text/clipboard
   messages, KDE Store submission (source-only), i18n extraction, PKGBUILD.
