# Changelog

Every released plasmoid version is listed here. Numbers follow Semantic Versioning and match the
archive name in the release assets.

## Unreleased

### Changed

- New app icon on a 64 unit grid: 56 unit tile, 6 unit stroke, 6.25 percent margins, so the mark still
  reads at the 22 px panel size.
- Gradient stops chosen by measured contrast against the white glyph, 3.6:1 at the light end and 6.4:1
  at the dark end.
- Symbolic icon variant for panels that ask for monochrome icons.

### Added

- `scripts/package.sh` fails the build when the symbolic icon is missing from the archive.
- Cancelling a transfer stops the sender within one chunk instead of after the current file.
- History keeps 90 days of transfers and at most 200 entries, trimmed on read and on write.
- Discovery also runs over mDNS: the daemon publishes and browses `_localsend._tcp` and merges the
  results with the announcements, so devices still appear on networks that drop multicast announces.
- Outgoing transfers queue up: one runs, the rest wait in order and can be cancelled before they start.
- The tray icon is configurable: the icon picker from the menu editor offers every installed icon,
  and an SVG or PNG can be loaded from disk.
- A failed transfer can be retried, sending again only the files that failed.
- A failed transfer marks every untouched file as failed instead of leaving it pending.
- Incoming transfers can be accepted or declined straight from the notification.
- Temp downloads are swept at startup, so a daemon killed mid transfer leaves no debris.

### Fixed

- A dropped connection no longer produces a truncated file under its final name: bytes go to a
  `.localsend.part` sibling and are renamed only after the announced size has arrived.
- A cancelled session can no longer be rewritten to `done` or `error` afterwards.
- History records the path of a received file only once that file is complete.

## 0.2.0 - 2026-11-12

### Added

- `scripts/package.sh`: stages the backend, stamps the version, builds the `.plasmoid` archive and
  verifies the required file set, executable bits, metadata and path safety before printing a checksum.
- CI workflow: shell syntax checks, byte compilation, the unit tests and the packaging step on every
  push and pull request, with the archive uploaded as an artifact.
- Release workflow: a `v*` tag on `main` rebuilds the archive with the tagged version and publishes it
  together with `SHA256SUMS` through `gh release create`.
- `make package` and `make ci` targets.
- History rows are actionable. Click a file to open it, right click for Open File or Open File
  Location, with the file pre-selected in the file manager. Several files open as one selection.
- New `manage.sh open` and `manage.sh reveal` verbs. Reveal tries `org.freedesktop.FileManager1`,
  then `dolphin --select`, then the parent directory through `xdg-open`.
- Transfer history stores the path of every file. Older received entries are backfilled from the
  download directory when the file is still there.
- History grouped by day, with peer, file count, size, duration, average rate and clock time, per file
  sizes, a status chip for anything that did not complete, and a totals line for the whole history.

### Changed

- Header overflow menu removed. Every entry it held is reachable elsewhere: history through its tab,
  send through the row action, trust through the star, folder through the header button, switches
  through the footer.
- History view rebuilt as one delegate per transfer instead of a single joined text block.
- README documents the archive install path, the tagging checklist and the release workflows.

### Fixed

- Grouped font assignment in the history view, which made `FullRepresentation` fail to load and left
  the popup empty.
- Relative `--out` values in `scripts/package.sh`, which broke the archive step on CI.

## 0.1.0 - 2026-11-12

### Added

- LocalSend v2.2 backend in Python: multicast discovery, HTTPS receive with TLS and PIN, outbound send
  with per file progress. Interoperates with the official apps in both directions.
- `localsendctl` JSON control CLI: `state`, `peers`, `send`, `respond`, `cancel`, `history`,
  `clear-history`, `favorite`, `auto-accept`, `scan`, `wait-ready`, `shutdown`, `ping`.
- Plasmoid with device list, per device Send, trusted device toggle, auto accept, history tab, desktop
  notification and a tray badge.
- Manual scan through the header button, with a busy state.
- Single instance guard through `flock` plus an abstract socket, adopting a running daemon instead of
  racing with it.
- Applet as supervisor: no systemd unit, no D-Bus, backend staged under the applet data directory so
  removing the widget leaves nothing behind.
- Master switch stored as a marker file and honored by `manage.sh`.
- 11 unit tests covering TLS loopback, prompt handling, PIN rejection, the send flow, history paths and
  settings persistence.
- `install.sh`, `uninstall.sh`, `restart-plasma.sh`, `Makefile`, README, MIT license.

### Fixed

- The daemon inherited the `manage.sh` lock file descriptor, so `ctl ping` stalled for 15 s before
  answering. Control calls now answer in about 40 ms.
