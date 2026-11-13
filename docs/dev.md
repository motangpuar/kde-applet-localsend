# Development notes

How the applet is put together, what the wire contracts are, and which mistakes already cost time.
For install, use and troubleshooting, read the [README](../README.md).

## Architecture

```
┌─────────────────────────┐   shell out (JSON)   ┌────────────────────────────┐
│ plasmoid (QML only)     │ ───────────────────► │ contents/backend/manage.sh │
│ tray badge, lists, tabs │ ◄─────────────────── │ ensure|stop|ctl|enable     │
└─────────────────────────┘                      └───────────┬────────────────┘
                                                             │ newline JSON over
                                                             │ control.sock (0600)
                                                             ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ localsendd (Python, one process per host)                                     │
│  discovery  multicast 224.0.0.167:53317 announce + scan                      │
│  HTTPS      :53317  /api/localsend/v2/{info,register,prepare-upload,upload}   │
│  control    Unix socket, JSON in / JSON out, doubles as the widget heartbeat   │
│  state      peers, sessions, prompts, history, favorites in ~/.config/localsendd │
└──────────────────────────────────────────────────────────────────────────────┘
```

The daemon is the only part that speaks the protocol. QML never opens a socket: it shells out to
`manage.sh`, which stages the Python payload under `~/.local/share/localsend-applet/bin/` and runs it.

## Repository layout

```
python/localsendd         daemon: discovery, HTTPS receive/send, control socket, watchdog
python/localsendctl       CLI client, same JSON surface the widget uses
python/tests/             unittest suite (hermetic dirs, discovery off)
plasmoid/…/contents/ui/   QML: main (polling/state), Full and Compact representations, config
plasmoid/…/contents/backend/manage.sh   supervisor shipped inside the package
plasmoid/…/contents/icons/              app icon plus symbolic variant
scripts/                  install, uninstall, restart-plasma, package
docs/                     this file, KDE Store text, generated icon preview
```

## Control plane

One line of JSON in, one line of JSON out, `{"ok": true, ...}` or `{"ok": false, "error": "..."}`.
Socket is `$XDG_RUNTIME_DIR/localsend-applet/control.sock`, mode `0600`, 30 s read timeout.

```bash
printf '{"cmd":"peers"}\n' | socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/localsend-applet/control.sock
```

| Verb | Arguments | Result |
|---|---|---|
| `state` | none | daemon info, peers, sessions, prompts, history, favorites. Touches the heartbeat |
| `peers` | none | discovered devices |
| `scan` | none | announce immediately and prune peers that stopped answering |
| `send` | `fingerprint`, `files` | starts an outgoing session, returns its id |
| `respond` | `prompt_id`, `action` (`accept`/`reject`/`cancel`), optional `pin` | answers an incoming offer |
| `cancel` | `session_id` | aborts a running transfer |
| `history`, `clear-history` | none | read or drop the transfer log |
| `favorite` | `fingerprint`, `on` | trust or untrust a device |
| `auto-accept` | `on` | skip prompts for trusted devices |
| `wait-ready` | `timeout_ms` | block until the daemon answers; used by `manage.sh ensure` |
| `ping` | none | liveness check without touching state |
| `shutdown` | none | graceful exit |

`localsendctl` is a thin client for these. `manage.sh` adds the supervisor verbs:
`ensure [--idle-exit SECS]`, `stop`, `restart`, `enable`, `disable`, `query-enabled`, `ctl`,
`open <path>`, `reveal <path...>`.

## Lifecycle and concurrency

- **Widget as supervisor.** `ensure` probes the socket, then starts the daemon with `setsid` so it
  survives the shell that spawned it. No systemd unit, no D-Bus activation.
- **Two single instance guards.** `flock` on `$XDG_RUNTIME_DIR/localsend-applet/daemon.lock` and an
  abstract socket named `\0localsend-applet-<uid>`. A second `ensure` adopts the running daemon
  instead of racing it, which is what used to produce duplicate daemons announcing one fingerprint
  from two ports.
- **Heartbeat plus idle exit.** Every `state` call touches the heartbeat. `--idle-exit 900` reaps the
  daemon only when it is quiescent: no sessions, no prompts, no recent request. A crashed plasmashell
  therefore cleans up after itself, and an active transfer is never killed.
- **Master switch is a marker file.** `~/.local/share/localsend-applet/disabled` is the source of
  truth; KConfig mirrors it for display only. KConfig dropped the key once and left the backend dead
  with no trace.
- **Cancellation is checked between chunks.** Both sides poll the session status while bytes move,
  so a cancel lands within one chunk, never after the current file. A cancelled session keeps its
  terminal status and its partial download is deleted, not renamed.
- **Listener first.** The HTTPS listener binds before the control socket answers, so `wait-ready`
  cannot succeed against a half-started daemon.
- **Process name.** The daemon renames itself through `prctl(PR_SET_NAME)` so `pgrep -x localsendd`
  and `pkill` behave as expected.

## Security model

| Asset | Handling |
|---|---|
| TLS identity | Self-signed cert and key generated on first start in `~/.config/localsendd/`, fingerprint is SHA-256 of the DER |
| Trust | Fingerprint compare on every peer; no CA and no hostname validation, matching the protocol |
| Prompts | 5 min timeout, optional PIN, auto-accept only for starred devices |
| Control socket | `0600` inside `$XDG_RUNTIME_DIR`, single line requests, no shell involved |
| Downloads | Written to a `.localsend.part` sibling, size checked against the announcement, renamed on the last byte; stale parts are swept at startup |
| Privileges | Never runs as root, binds no privileged port, the widget starts and stops the daemon |

## Protocol scope

Implemented, LocalSend v2.2:

| Endpoint | Use |
|---|---|
| `POST /api/localsend/v2/register` | device announcement reply, carries fingerprint and device info |
| `POST /api/localsend/v2/info` | peer identity check |
| `POST /api/localsend/v2/prepare-upload` | request a token per file |
| `POST /api/localsend/v2/upload?sessionId=&fileId=&token=` | receive file bytes |
| `POST /api/localsend/v2/prepare-download`, `cancel` | outbound side and session teardown |

Discovery is the documented multicast announce on `224.0.0.167:53317` with the `announce` payload,
plus a periodic scan round. `scan` is a forced announce, not a query: v2 has no "who is there" call.

Not implemented: v2.1 text and clipboard messages, reverse direction of some optional endpoints,
mDNS (`_localsend._tcp`), and the `pin` challenge variants added after 2.2 for some clients.

## Tests

```bash
make test      # 11 unittest cases, about 17 s
make lint      # py_compile
make verify    # tests plus package layout
```

The suite runs against real sockets on loopback with hermetic `HOME`, `XDG_*` and certificate
directories. Test hooks, never set in production:

- `LOCALSENDD_DISCOVERY=0` disables multicast.
- `LOCALSENDD_DISCOVERY_PORT=<n>` moves the multicast port.
- `LOCALSENDD_GUARD_NAME=<name>` renames the abstract socket guard.

They exist because the suite shares the network namespace with the live daemon and `SO_REUSEPORT`
load balances multicast between local sockets.

## Packaging and releases

`scripts/package.sh` is the single packaging path. It stages a temp copy, installs `localsendd` and
`localsendctl` with mode 755, validates metadata (Id equals the package directory name,
`MAJOR.MINOR.PATCH`, no unexpanded `{}`), optionally stamps `--version`, builds
`<out>/io.github.localsend.plasmoid-<version>.plasmoid`, then verifies the required file set, the Id,
the version, safe paths, exec bits inside the zip and the absence of `__pycache__`/`*.pyc`.

```bash
make package                          # build/
./scripts/package.sh --out dist --version 0.3.0
```

| Workflow | Trigger | Result |
|---|---|---|
| `.github/workflows/ci.yml` | push to `main`, pull request | `sh -n`, `bash -n`, byte-compile, full suite, archive build, 14-day artifact |
| `.github/workflows/release.yml` | tag `v*` or dispatch with `tag` | re-runs the suite, refuses tags not on `main`, stamps the version, publishes `.plasmoid` plus `SHA256SUMS` |

Release checklist:

```bash
make ci
git tag -a v0.3.0 -m "LocalSend applet 0.3.0"
git push origin v0.3.0
```

Two builds of one tree are content-identical but not bit-reproducible: `zip` stores source mtimes.
Pin the timestamps in `package.sh` if a reproducible sha256 matters.

## Icon

`contents/icons/io.github.localsend.plasmoid.svg` sits on a 64 unit grid: 56 unit tile with 6.25
percent margins, 6 unit stroke, so the glyph is still 2.06 px at the 22 px panel size. The gradient
stops come from measured contrast against the white glyph, 3.6:1 at the light end and 6.4:1 at the
dark end. `io.github.localsend.plasmoid-symbolic.svg` is the monochrome variant: 24 grid, 2 unit
stroke, mark spanning 4 to 20, `currentColor` plus `ColorScheme-Text`.

ImageMagick and `rsvg-convert` regenerate the review sheet, no design tool in the loop:

```bash
magick montage cell-*.png -tile 7x -geometry 168x168+0+0 -background '#8e9196' docs/icon-preview.png
```

Checks that work without eyes: corner alpha zero at every size, trim bbox inside the tile, equal ink
in the left and right halves, and 180 degree rotation RMSE near zero. The mark is an up arrow next to
a down arrow, so it is point-symmetric; a horizontal flip is the wrong symmetry test.

## Verified with

KDE Plasma 6 on Wayland, Python 3.14, Android LocalSend (`Hot Mushroom`): discovery, phone to PC and
PC to phone transfers, trusted device auto-accept, and the release archive installed through
`kpackagetool6`.

## Gotchas already paid for

- Children of `manage.sh` must not inherit the lock file descriptor. Close it explicitly (`9>&-`),
  otherwise `ctl ping` blocks for 15 s until the flock is released.
- Never assign `font:` and a `font.*` sub-property on the same QML object. It is a load time error and
  the whole `FullRepresentation` becomes unavailable.
- `zip` writes relative paths against the current directory, so resolve `--out` to an absolute path
  before the staging `cd`.
- Two daemons on one host cannot discover each other: `SO_REUSEPORT` load balances multicast between
  local sockets. One backend per host is the design, not a bug to fix.
- `pkill -f '<pattern>'` matches the invoking shell. Kill by explicit pid or `pgrep -x localsendd`.
- Editing `plasma-org.kde.plasma.desktop-appletsrc` while plasmashell runs gets clobbered. Stop it
  first, or restart afterwards.
- The system tray containment hides applets from the scripting API, so the popup cannot be expanded
  from a shell. Validate QML by reading the plasmashell journal after a restart.
