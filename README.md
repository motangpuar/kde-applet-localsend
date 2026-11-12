# LocalSend for KDE Plasma 6

A panel/desktop widget that does **LocalSend** transfers without the official Flutter app:
a Python daemon speaks the LocalSend v2 wire protocol (discovery, send, receive), the plasmoid is
just the UI. Nothing to keep open, no systemd unit, no D-Bus, no compiler at run time.

- **Status:** working against the official Android app in both directions; protocol `2.2`.
- **Dependencies:** Plasma 6, `python3` ≥ 3.11 (stdlib only; `cryptography` optional for cert
  generation — `openssl` is the fallback).
- **Footprint:** ~2 000 lines (backend ~1 200, QML ~800), files under `~/.local/share/plasma/plasmoids/`.

---

## Why this exists

LocalSend's own Linux client is an Electron-era Flutter app you must keep running. This replaces it
with a widget that is always where you already look — the system tray — and a backend that starts on
demand and exits on its own when idle.

| Need | How it is met |
|---|---|
| Send/receive without opening an app | Tray widget + `send` CLI; the daemon is a supervisor-managed worker |
| Trusted devices that never prompt | Per-device star + `auto_accept_favorites` |
| Interop with phones/other desktops | Real LocalSend v2 protocol, self-signed TLS, fingerprint identity |
| No background daemon forever | Heartbeat from the widget, `--idle-exit` reaper, marker-file master switch |
| No systemd / no session bus | Unix control socket in `$XDG_RUNTIME_DIR` |

---

## Architecture

```
┌─────────────────────────┐   shell out (JSON)   ┌────────────────────────────┐
│ plasmoid (QML only)     │ ───────────────────► │ contents/backend/manage.sh │
│ tray badge, lists, tabs │ ◄─────────────────── │ ensure|stop|ctl|enable     │
└─────────────────────────┘                      └───────────┬────────────────┘
                                                             │ newline JSON over
                                                             │ control.sock (0600)
                                                 ┌───────────▼────────────────┐
                                                 │ localsendd (Python worker) │
                                                 │ discovery · HTTPS · sender │
                                                 └───────────┬────────────────┘
                                                             │ LocalSend v2.2
                                                 ┌───────────▼────────────────┐
                                                 │ phones / laptops / desktops│
                                                 └────────────────────────────┘
```

Design rules, in priority order:

1. **One protocol speaker.** Only `localsendd` opens sockets; the QML never does I/O.
2. **Widget is the supervisor.** It calls `manage.sh ensure`; the daemon dies by idle-exit, not by
   being killed on plasmoid destruction (that raced plasmashell restarts).
3. **State that matters is a file, not KConfig.** The enabled/disabled switch is
   `$XDG_DATA_HOME/localsend-applet/disabled`; KConfig silently lost it once and left the backend
   dead with no log trace.
4. **Binaries ship inside the package.** `contents/backend/` holds the staged payload, so a GUI
   uninstall removes everything.

---

## Install

Two ways in. **Release archive** (what the tray widget ships as):

```bash
# every tagged release attaches io.github.localsend.plasmoid-<version>.plasmoid
kpackagetool6 --type Plasma/Applet --install io.github.localsend.plasmoid-0.2.0.plasmoid
# or, to upgrade an existing install
kpackagetool6 --type Plasma/Applet --upgrade io.github.localsend.plasmoid-0.2.0.plasmoid
```

The archive carries the guarded Python backend, so nothing is downloaded at install time; it still
needs `python3` ≥ 3.11 on the machine that runs plasmashell.

**From source** (development):

```bash
git clone https://github.com/motangpuar/kde-applet-localsend.git
cd kde-applet-localsend
make verify                 # tests + package layout
./scripts/install.sh        # validates python3, stages backend, kpackagetool6 --upgrade
distrobox-host-exec ./scripts/restart-plasma.sh   # or re-login
```

Then add **LocalSend** to a panel or desktop (right-click → *Add Widgets…*).

Uninstall:

```bash
./scripts/uninstall.sh            # package only
./scripts/uninstall.sh --purge    # also config, history and certificates
```

`install.sh` migrates older layouts: it stops a unit-managed daemon and removes the former
`~/.config/systemd/user/localsendd.service` and `~/.local/bin` copies.

---

## Use

| Action | Where |
|---|---|
| Enable/disable the backend | footer switch **LocalSend enabled** (persists as a marker file) |
| Send a file | drag files onto the tray icon, or **Send…** and pick files, then tap a device (the popup re-opens after the file picker) |
| Force a discovery round | refresh button in the popup header (`ctl scan`) |
| Accept an incoming transfer | popup prompt with file list; or star a device and enable auto-accept |
| Inspect history | *History* tab: day-grouped cards with peer, size, duration, average rate, per-file sizes and a status chip for anything that did not complete |
| Open a transferred file | click its row in the History tab (one file opens, several are revealed together) |
| Open or reveal from the clipboard menu | right-click a row: **Open File** or **Open File Location**, with the file pre-selected in Dolphin |
| Star / unstar a device | ★ on the device row, or **Trust this device** in the detail view |
| Clear history | *Clear* in the History tab |

The tray icon shows a badge while transfers run and a spinner while the backend boots.

---

## CLI

Everything the widget does is scriptable. The control plane is JSON-in/JSON-out.

```bash
LS="sh /home/$USER/.local/share/plasma/plasmoids/io.github.localsend.plasmoid/contents/backend/manage.sh"
$LS ctl state                       # full snapshot: daemon, peers, sessions, prompts, history
$LS ctl peers                       # discovered devices only
$LS ctl scan                        # announce now instead of waiting for the 5 s tick
$LS ctl send <fingerprint> FILE...  # start an outgoing transfer
$LS ctl respond <prompt-id> accept  # answer an incoming offer (reject/cancel also valid)
$LS ctl cancel <session-id>         # abort a transfer
$LS ctl favorite <fingerprint> on   # trust a device
$LS ctl auto-accept on              # skip prompts for trusted devices
$LS ctl history | clear-history
$LS ctl shutdown                    # stop the daemon gracefully
$LS ctl wait-ready 5000             # block until the daemon answers
```

Daemon lifecycle:

```bash
$LS ensure      # start if needed → LOCALSEND_RUNNING | LOCALSEND_STARTED | LOCALSEND_DISABLED | LOCALSEND_FAILED
$LS stop        # graceful shutdown → LOCALSEND_STOPPED
$LS restart
$LS disable     # set the marker + stop
$LS enable      # clear the marker + ensure
$LS query-enabled   # ENABLED | DISABLED
```

Daemon flags: `--alias`, `--port`, `--download-dir`, `--pin`, `--idle-exit <secs>` (default `900`,
`0` = never).

---

## Files and paths

| Path | Content |
|---|---|
| `~/.local/share/plasma/plasmoids/io.github.localsend.plasmoid/` | installed package (QML + `contents/backend/`) |
| `~/.local/share/localsend-applet/bin/` | copy-on-change staged daemon/CLI (what actually runs) |
| `~/.local/share/localsend-applet/disabled` | master-switch marker |
| `$XDG_RUNTIME_DIR/localsend-applet/` | `control.sock`, `daemon.lock`, `daemon.pid` |
| `~/.cache/localsend-applet/daemon.log` | daemon log (stdout/stderr) |
| `~/.config/localsendd/config.json` | alias, port, download dir, PIN, favorites |
| `~/.config/localsendd/history.json` | last 200 finished transfers |
| `~/.config/localsendd/{cert.pem,key.pem}` | self-signed identity; fingerprint = SHA-256 of the DER |
| `~/Downloads/LocalSend/` | received files (collisions get `name (1).ext`) |

No files outside the package, no `~/.local/bin` entry, no systemd unit, no hicolor icon.

---

## Protocol scope

Implemented (LocalSend v2.2, HTTPS with self-signed certs, identity by fingerprint):

| Endpoint | Use |
|---|---|
| `GET /api/localsend/v2/info` | device info, used by discovery and trust checks |
| `POST /api/localsend/v2/register` | mutual peer registration |
| `POST /api/localsend/v2/prepare-upload` | offer + optional PIN, returns per-file tokens |
| `POST /api/localsend/v2/upload` | streamed file body, `{"savedTo": …}` reply |
| `POST /api/localsend/v2/cancel` | abort a session |

Discovery: multicast `224.0.0.167:53317` (+ unicast replies), 5 s announcements, 60 s peer TTL,
`announce:false` goodbye on shutdown.

Not implemented: mDNS `_localsend._tcp`, v2.1 text/clipboard messages, multi-recipient sends,
favorite persistence on the peer side (LocalSend keeps that locally too).

---

## Lifecycle and concurrency

- **Single instance, two guards.** `flock` on `daemon.lock` plus an abstract unix socket
  `\0localsend-applet-<uid>`; the second guard also stops a sandbox/container daemon with a different
  `$XDG_RUNTIME_DIR` from duplicating the receiver port.
- **Startup ordering.** The HTTPS listener binds *before* the control socket answers, so a supervisor
  that sees a live control socket never races a half-started receiver.
- **Heartbeat.** Every control call refreshes `last_seen`; the watchdog exits after `--idle-exit`
  seconds of silence **only when no session or prompt is live**.
- **Adoption.** Parallel `ensure` calls do not race: one starts, the others wait up to 12 s for the
  control socket and report `LOCALSEND_RUNNING`.
- **Restart survival.** The daemon lives in plasmashell's cgroup. A plasmashell restart kills it and
  the widget starts a fresh one within ~2 s; there is no seamless-attach pretence.

---

## Security model

- TLS on every hop, but peer authentication is **fingerprint based**: the daemon accepts self-signed
  peer certificates, matching LocalSend's own model. Treat discovery as trusted-LAN only.
- The control socket is `0600` inside `$XDG_RUNTIME_DIR`; any local process of the same user can
  drive it — same trust boundary as the widget itself.
- An optional PIN (`--pin` or `pin` in `config.json`) gates `prepare-upload` with `401`; the official
  app prompts for it automatically.
- File names from peers are reduced to a basename and stripped of control characters and `:`, so a
  sender cannot choose a target directory.
- Incoming files land only in the configured download directory, never overwriting: collisions become
  `name (1).ext`.

---

## Operations

| Symptom | Check |
|---|---|
| Widget greyed out, no peers | `$LS ctl state`; marker present? `$LS query-enabled` |
| Daemon not starting | `~/.cache/localsend-applet/daemon.log`, then `$LS restart` |
| Duplicate daemons | `pgrep -af bin/localsendd`; the guards print why a second one exits |
| Phone cannot see the PC | same LAN? multicast allowed? firewall open on 53317/udp+tcp |
| Transfer refused | receiver requires a PIN, or the prompt timed out after 5 min |
| Reset everything | `./scripts/uninstall.sh --purge`, then reinstall |

Logs in the shell: `journalctl --user -f | grep localsend` (the widget logs peer counts and errors).

---

## Development

```bash
make test      # 11 unittest cases: TLS loopback, prompts, PIN, sender, single instance, persistence
make lint      # py_compile the backend and tests
make verify    # tests + package layout
make backend   # stage python/localsend* into the package
make package   # build build/io.github.localsend.plasmoid-<version>.plasmoid
make ci        # lint + test + package: the same gate GitHub Actions runs
```

### CI and releases

| Workflow | Trigger | Result |
|---|---|---|
| `.github/workflows/ci.yml` | push to `main`, pull request | shell syntax, byte-compile, full unittest suite, archive build, 14-day artifact |
| `.github/workflows/release.yml` | tag `v*` (or manual dispatch) | re-runs the suite, stamps the tag into `metadata.json`, uploads `.plasmoid` + `SHA256SUMS` |

Both call `scripts/package.sh`, which is also what you run locally — a locally verified archive is
byte-for-byte the build the workflow produces. Release checklist:

```bash
make ci                       # must pass locally first
git tag v0.2.0 && git push origin v0.2.0    # workflow publishes the release
```

`package.sh` refuses to build when the metadata `Id` does not match the package directory, when the
version is not `MAJOR.MINOR.PATCH`, when a required file is missing from the archive, when the backend
payload is not executable inside the zip, or when build noise (`__pycache__`, `*.pyc`) leaks in.

```
python/localsendd         daemon: discovery, HTTPS receive/send, control socket, watchdog
python/localsendctl       CLI client (same JSON surface as the widget)
python/tests/             unittest suite (hermetic dirs, discovery off)
plasmoid/…/contents/ui/   QML: main (polling/state), Full/Compact representations, config
plasmoid/…/contents/backend/manage.sh   supervisor script shipped inside the package
scripts/install.sh, uninstall.sh, restart-plasma.sh
```

Test hooks (never set in production): `LOCALSENDD_DISCOVERY=0`, `LOCALSENDD_DISCOVERY_PORT=<n>`,
`LOCALSENDD_GUARD_NAME=<name>`. They exist because the suite shares the network namespace with the
live daemon and `SO_REUSEPORT` load-balances multicast between local sockets.

Verified with: KDE Plasma 6 (Wayland), Python 3.14, Android LocalSend (`Hot Mushroom`) — discovery,
phone→PC and PC→phone transfers, trusted-device auto-accept.

---

## Roadmap

- mDNS (`_localsend._tcp`) for networks that drop multicast.
- Accept/decline straight from the notification.
- v2.1 text and clipboard messages.
- KDE Store submission (source-only package; PIN the daemon dependency in the dependency notes).
- i18n extraction (strings are already `i18n`-wrapped).

## License

MIT — see `LICENSE`.
