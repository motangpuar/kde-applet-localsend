# MEMORIES

Session ledger for the LocalSend Plasma applet. Newest round first; keep entries short and factual.

## Current Status
## History retention (#6, merged 51ddc22)
`History._prune()` is the only place that bounds `history.json`: entries older than `HISTORY_DAYS` (90)
or beyond `HISTORY_MAX` (200) are dropped, on `load()` and on `push()`. `load()` writes the pruned file
back so a legacy or hand edited file self heals on the next start; entries without a timestamp survive,
because builds before 0.2.0 recorded none. `save()` now creates the config dir, otherwise a fresh
profile silently lost the write. Tests 18 (was 15). Live check on a throwaway daemon: one recent and
one 120 day old entry in `history.json` came back as `['recent']` with its `path` intact, and the file
on disk held the same list. Real instance after restart: 29 entries, oldest 2026-11-12, nothing dropped.

## Transfer integrity (2026-11-16, merged 5e47f85, closes #7 + #4)
`upload()` used to write straight to the final unique name and treat EOF as success, so an interrupted
transfer produced a truncated file marked `done`. Now bytes go to `<name>.localsend.part`, the written
count is compared with the announced size, and `os.replace` happens on the last byte. Failures unlink
the part, `sweep_parts()` clears debris at startup, and `entry["path"]` is recorded only after the
rename. Cancellation now works on both sides: the receive loop and the sender loop check
`session.status` between chunks, `Cancelled` aborts the worker, and `_mark_file()` refuses to overwrite
the terminal `cancelled` status. Tests 14 (was 11): truncated body leaves no file, cancel mid receive
discards the part, cancel mid send stops before the whole file. Note: `HISTORY_MAX = 200` already caps
history entries, so issue #6 is only about time based retention and load time trimming, not an unbounded
file. Live check on the running daemon: a 4096 byte upload cut at 1024 bytes ended as `error` with
`short transfer: 1024 of 4096 bytes`, no file in `~/Downloads/LocalSend`, no `.part`, history bytes 1024
and no `path` key.

## Icon (2026-11-13)
Replaced the placeholder icon with a designed pair: `contents/icons/io.github.localsend.plasmoid.svg`
(64-unit grid, 56-unit tile with 6.25% margins, 6-unit stroke so the glyph is still 2.06 px at the
22 px tray render) and `io.github.localsend.plasmoid-symbolic.svg` (24 grid, 2-unit stroke, mark spans
4..20 = 75% of the box like Breeze symbolic icons, `currentColor` + `ColorScheme-Text`).
Gradient stops chosen numerically for contrast against the white glyph: `#12997e` = 3.6:1 (the 3:1
graphics minimum), `#0a6b5e` = 6.4:1; the previous `#3fd9ae` top was 1.8:1, i.e. white arrows on it
were nearly invisible. `docs/icon-preview.png` is a generated size/background sheet (ImageMagick +
rsvg-convert, no vision needed): `magick montage` of centred cells. Verification that works without
eyes: corner alpha 0 at every size, trim bbox inside the tile, equal ink in the left and right halves
(7094 units each) and 180°-rotation RMSE 0.001 (the mark is ⇅, so a horizontal flip is *not* the
correct symmetry test — it reads 0.16 and means nothing).
`scripts/package.sh` now also requires the symbolic file in the archive (12 files).

Released `v0.2.0` (2026-11-13): metadata bumped to 0.2.0, `make ci` green, CI run 43265066216 ok,
release run 43265080749 published `io.github.localsend.plasmoid-0.2.0.plasmoid` (sha256 `5a70b38c…`)
plus `SHA256SUMS`; that asset was installed on the host and plasmashell restarted clean.
Archive checksums differ between two builds of identical trees: `zip` stores source mtimes, so builds are
content-identical but not bit-reproducible (fix would be a Python zipfile writer with a pinned timestamp).

Round 13 (2026-11-13): history entries became actionable and the card layout got a proper hierarchy.
The daemon now records `path` per file (receive: the real `unique_path()` target; send: the resolved
source) and backfills older receive entries by looking the name up in the download dir. Left click on a
file row opens it, several files open through `reveal`; right click opens a shared `PlasmaComponents3.Menu`
with *Open File* / *Open File Location*. Both go through new `manage.sh open|reveal` verbs — `reveal`
tries `org.freedesktop.FileManager1.ShowItems`, then `dolphin --select`, then the parent dir via
`xdg-open`, because QML has no D-Bus or file API here. Layout: hour moved to the card corner, meta line
dropped the clock, file rows show name plus size with hover feedback, chip uses `font.pointSize` (grouped
`font` assignment is illegal), spacing unified on `Kirigami.Units.{small,large}Spacing`.

Round 12 (2026-11-13): release engineering and history UX. `scripts/package.sh` is the only packaging
path — stages the backend, stamps the version, builds `build/<id>-<version>.plasmoid`, then verifies
metadata id/version, required files, safe paths, executable bits and absence of `__pycache__`. CI runs
on every push/PR (shell syntax, byte-compile, 11 tests, archive artifact); `release.yml` on `v*` tags
re-runs the suite, refuses tags not on `main`, stamps the tag as the version and publishes the archive
with `SHA256SUMS`. The header overflow menu is gone (history tab, per-device send, ★, folder button and
footer switches already covered every item). History rebuilt: day-grouped cards with peer, file count,
size, duration, average rate, clock time, first two file names plus "+N more", and a colour chip plus
error text for anything that did not complete; the tab header shows totals (sent/received/size/failed).

Shipped: CI run 43258602099 green; `v0.1.0` tag published release with
`io.github.localsend.plasmoid-0.1.0.plasmoid` (sha256 `b9b11be0…`) + `SHA256SUMS`; installed that
downloaded asset with `kpackagetool6 --upgrade` and restarted plasmashell — journal clean, daemon up.
Gotchas found: `--out` must be resolved to an absolute path before zipping (CI passes `dist`), and QML
forbids assigning `font` plus `font.bold` on the same object (that broke FullRepresentation at load).

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

## Branch Workflow (user directive, 2026-11-13)
- Every feature starts on its own branch off `main`, then lands with a merge commit.
- Use `git merge --no-ff`, or a GitHub PR merged with "Create a merge commit". No fast-forward, no
  squash, no rebase onto `main`, so each feature leaves a bubble in the log.
- Delete the branch after it lands. Direct commits to `main` stay for docs and release bookkeeping.
- Issue tracker conventions: `feat:` titles, `Feature` issue type, `enhancement` label, self-assigned,
  body = one-line description plus an acceptance list with observable postconditions.

## Next Steps
1. Confirm in the UI: send prompt latency, header refresh button, single settings checkbox.
2. Exercise phone→PC receive and `Send…` again; verify favorites/auto-accept across a daemon restart.
3. Optional: mDNS (`_localsend._tcp`), KNotification inline accept/decline, v2.1 text/clipboard
   messages, KDE Store submission (source-only), i18n extraction, PKGBUILD.
