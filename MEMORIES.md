# MEMORIES

## Current Status
Feature round 10 (2026-11-12): manual scan, popup survives the file picker, and every toggle now
mirrors daemon state instead of a one-shot QML binding. `localsendd` gained a `scan` control method
(immediate announce + stale-peer prune, `DISCOVERY` registry holds the live socket) plus atomic
`config.json` writes; `localsendctl scan`; popup header ⟳ button with busy indicator and a
**Scan for devices** button in the empty state; `FileDialog.onAccepted/onRejected` re-expand the
popup after 120 ms. Checkboxes/switches replaced `checked = Qt.binding()` re-arms with `Binding`
elements (`restoreMode: Binding.RestoreNone`) so favorites and auto-accept render daemon truth after
any click. Suite now 11 cases (persistence across restart, scan with discovery off).
Verified live: `ctl scan` → `{"ok":true,"scanning":true,"peers":1}`, `Hot Mushroom` found;
favorites/auto-accept survive `manage.sh restart` (config `favorites` + `auto_accept_favorites`).

## Previous Status
Feature round 9 (2026-11-12): the repository is Python-only. The daemon is `python/localsendd`, the CLI
`python/localsendctl`, the suite `python/tests/test_backend.py` (9 cases green); Rust tree, Cargo files
and `target/` are gone. Makefile: `help|test|lint|backend|verify|install|uninstall|run|ctl|clean`.
Live daemon: staged copy under `~/.local/share/localsend-applet/bin`, fingerprint `944bcc88…`,
discovers `Hot Mushroom`. README rewritten to the FAANG layout, MIT `LICENSE` added.

## Previous Status
Feature round 7 (2026-11-12): startup spinner (`startingUp`) in popup header + tray icon, and the
master switch now lives in `manage.sh` (`disable`/`enable`/`query-enabled` on a marker file) because
KConfig silently dropped `networkEnabled` and left the backend dead.

## Previous Status
Feature round 6 (2026-11-12): D-Bus is gone. The control plane is newline JSON on
`$XDG_RUNTIME_DIR/localsend-applet/control.sock`, so the stack needs no session bus and no systemd;
duplicate daemons are impossible (flock + abstract socket name). `zbus`/`src/dbus.rs` deleted.

## Previous Status
Feature round 5 (2026-11-12): systemd removed, the widget supervises the daemon itself and the
backend ships inside the plasmoid package (`contents/backend/`). Everything rebuilds from
`./scripts/install.sh`; `./scripts/uninstall.sh` leaves no binaries behind. 8 unit + 2 e2e green.

## Previous Status
MVP shipped and running on the host: `localsendd` (discovery + send + receive) answers on the session
bus, plasmoid `io.github.localsend.plasmoid` installed via host `kpackagetool6`. 8 tests green.

## Active State (round 9 — Python backend)
- `python/localsendd` (≈1 200 lines): `ThreadingHTTPServer` + `ssl` receive server, sender via
  `http.client`, discovery thread, control-socket accept loop, history sync thread, watchdog thread.
  Bind order: HTTPS listener **before** the control socket answers.
- `python/localsendctl`: compact JSON (`separators=(",",":")`) so `manage.sh probe()` matches
  `"ok":true`; `manage.sh` itself now uses `grep -Eq '"ok":[[:space:]]*true'`.
- Test suite `python/tests/test_backend.py`: 9 cases, hermetic `HOME`/`XDG_*` temp dirs, discovery off,
  one test asserts the two-process send path against a stand-in receiver over real TLS.
- Removed: `src/`, `tests/e2e.rs`, `Cargo.toml`, `Cargo.lock`, `target/`; `.gitignore` drops `/target`,
  ignores `__pycache__`. Makefile targets are Python-only; `install.sh` checks `python3 ≥ 3.11`.
- Live verification: staged `~/.local/share/localsend-applet/bin/localsendd`, fp `944bcc88…`,
  alias `infidel@aurora`, phone `Hot Mushroom` discovered, `stop/ensure/restart` tokens correct,
  `--idle-exit 3` reaps without heartbeat and survives heartbeats.

## Legacy State (round 7)
- `main.qml`: `readonly property bool startingUp: networkEnabled && ((!daemonUp && lastError.length === 0) || starting)`;
  `startDaemon()` clears `lastError` first so a retry shows the spinner again.
  FullRepresentation header swaps the static icon for `PlasmaComponents3.BusyIndicator` and shows
  "Starting the background service…"; CompactRepresentation draws the spinner instead of the dimmed
  icon; the tooltip says the same.
- Switch truth moved out of KConfig: `manage.sh disable|enable|query-enabled` on
  `$DATA/disabled`; `ensure` prints `LOCALSEND_DISABLED` and exits 0 while it exists;
  `Component.onCompleted` -> `syncSwitch()` (query, mirror into config, then `startDaemon()`);
  `setNetworkEnabled` runs `enable`/`disable`; a `LOCALSEND_DISABLED` answer flips the UI switch off
  without an error. `plasmoid` config `networkEnabled` is now only a cache.
- Root cause of the "widget shows a dead LocalSend" report: `appletsrc` had
  `networkEnabled=false`, so the widget neither polled nor started anything and logged nothing.
  Fixed by editing `appletsrc` with plasmashell stopped (`networkEnabled=true`) and by the marker.
- Verified: `enable`/`disable`/`ensure`-while-disabled/`query-enabled` transitions by hand;
  plasmashell restart 202516 -> daemon 202669 in the plasmashell cgroup, `state ok infidel@aurora
  53317`, only one expected `control.sock: No such file` line in the host journal.

## Legacy State (round 6, Rust era)
- `src/control.rs` replaced `src/dbus.rs`: one JSON request/response per connection; methods
  `ping state send respond cancel history clear-history favorite auto-accept shutdown`.
  `localsendctl` (`src/ctl.rs`) is a blocking socket client; QML still only runs
  `manage.sh ctl …`, so nothing in the UI knew about D-Bus.
- Single instance: `flock(LOCK_EX|LOCK_NB)` on `$XDG_RUNTIME_DIR/localsend-applet/daemon.lock`
  **plus** an abstract socket name `\0localsend-applet-<uid>` (auto-released on death, shared per
  network namespace). The abstract guard catches a daemon started from a container/sandbox with a
  different `$XDG_RUNTIME_DIR` - that was the real cause of the duplicate-instance report.
- `daemon.pid` is written by the daemon; `manage.sh stop` = graceful `ctl shutdown` -> SIGTERM that
  pid -> `pkill -x localsendd`; `manage.sh ensure` adopts a daemon another ensure is already
  booting (`pgrep` + `wait_up 12`) instead of failing.
- 5 concurrent `ensure` runs now yield exactly one `LOCALSEND_STARTED`, four `LOCALSEND_RUNNING`,
  one process. Verified: second daemon refused (`another instance is already running`), refused even
  with `XDG_RUNTIME_DIR=/tmp/rt-alt` (`holds the abstract socket`).
- Runtime files: `$XDG_RUNTIME_DIR/localsend-applet/{control.sock,daemon.lock,daemon.pid}`; a
  graceful exit removes socket+pid (lock file stays by design).
- Removed `zbus` dependency, added `libc`; `snapshot()` is now wrapped with `{"ok":true}` inside the
  control plane (state used to get that from the D-Bus layer) - `probe()` in manage.sh greps for it.
- Live: uninstall -> install -> plasmashell restart (195187) -> daemon in the plasmashell cgroup,
  `state ok infidel@aurora 53317`; host journal shows no `ServiceUnknown` any more, only the two
  expected "control.sock: No such file" lines while the daemon is still binding.

## Legacy State (round 5)
- `plasmoid/.../contents/backend/{localsendd,localsendctl,manage.sh}`: `install.sh` stages the built
  binaries there (gitignored), `manage.sh` copies them to `~/.local/share/localsend-applet/bin` on
  change and starts the daemon with `setsid ... --idle-exit 900`.
- Lifecycle model copied from `../kde-news-curator`: widget = supervisor, daemon = worker, no unit,
  no PATH entry, no autostart; orphan safety via heartbeat + `--idle-exit` instead of systemd.
- D-Bus `get_state` is the heartbeat (`AppState::touch`), `Shutdown` method + `localsendctl shutdown`
  give a graceful stop; `quiescent()` prevents reaping mid-transfer.
- Deliberately dropped `Component.onDestruction: stop` - it raced a restarted plasmashell and killed
  the daemon the new instance had just started (`LOCALSEND_FAILED` + 20 s flap).
- plasmashell restart still kills the daemon (same cgroup) -> new instance restarts it in ~2 s;
  "attach not restart" only applies to a daemon started outside plasmashell.
- `install.sh` migrates old installs: disable/remove `localsendd.service`, delete `~/.local/bin`
  copies, `pkill` the old daemon; `uninstall.sh` removes package + staged copies + cache (config kept).
- i18n with positional args prints `%1` literally in this plasmashell build -> diagnostics use string
  concatenation instead.
- Verified: uninstall -> install cycle restores the widget and the daemon; `manage.sh stop` -> applet
  revives it in 18 s (15 s start throttle); `--idle-exit 4` reaped in 4 s without heartbeats and
  stayed alive 9 s with them; `ctl shutdown` exits cleanly.

## Legacy State (rounds 1-4)
- Feature round 3: "Visible on network" toggle (daemon `announce` flag), TabBar views, toggle binding fixes.
- QML gotchas hit: `visible` is FINAL on PlasmoidItem (use `visibleOnNetwork`); a `readonly property bool`
  holding a lambda is NOT callable ("Property 'isFavorite' is not a function") - use `function`;
  `MenuItem` has `onTriggered`, not `onToggled`; after a user click a `checked:` binding dies, re-arm it
  with `checked = Qt.binding(() => ...)`.

- Verified in container: `cargo test` (6 unit + 2 e2e real-TLS loopback transfer), `cargo clippy -D warnings`, `cargo fmt --check`.
- Verified on host: `localsendd` up on port 53317, `localsendctl state` JSON, multicast announce captured
  by an independent UDP listener, peer announce accepted into the peer table (fake-peer test).
- Verified live: applet logs `localsend: daemon up infidel@archfox port 53317` and polls every 2 s
  (`localsendctl state` processes observed); main daemon discovers the user's phone running the official
  LocalSend app (`Hot Mushroom`, Google/mobile, 192.168.18.161:53317) → cross-implementation discovery OK.
- Verified against the official app: send to phone `Hot Mushroom` reached `status=done` after the phone
  accepted, and a phone-initiated send landed as `~/Downloads/LocalSend/IMG-20261112-WA0002.jpg` (149 KB).
- Unverified: drag-and-drop, FullRepresentation rendering in a real popup, PIN-protected transfers.
- Fixed after first user run: bare `localsendctl` on plasmashell PATH -> "unparsable output"/"not running".
  Now absolute paths + JSON errors on stdout; recovery loop re-verified with plasmashell's exact PATH.

## Known Blockers
- Master switch = stop the daemon (no announce, no HTTP, no answers). HTTP-level stealth was tried first
  and dropped as over-engineering. Verified with plasmashell stopped: off -> `pids 0`, no TCP 53317,
  6 s of multicast silence, unit `disabled inactive`; on -> bootstrap `{"ok":true,"state":"started"}`,
  unit `enabled active`, announcement back. QML must set the persisted flag before the kill so the
  2 s poll cannot auto-bootstrap it back.

- **LocalSend is mutual TLS.** The official receiver demands a client certificate: without
  `reqwest::Identity` the failure is `received fatal alert: CertificateRequired` wrapped as
  "error sending request for url". `send.rs` now presents our persisted pair (accept any peer cert).
- CLI flags must stay ephemeral: a `--alias/--port/--download-dir` test instance used to be written into
  `config.json`, hijacking the real daemon (alias `plasmoid-test`, port 53320, download dir `/tmp/...`).
  Now only the fingerprint persists; the listen port is never persisted (it is picked at runtime).
- No QML tooling anywhere (`qmllint6`, `cmake`, plasma-framework headers absent) → QML is only
  structurally checked (brace balance + `kpackagetool6` install). Keep using proven Plasma 6 idioms.
- `axum-server` must stay `tls-rustls-no-provider`, otherwise rustls has two CryptoProviders and panics.
- Container `$HOME` is `/home/infidel/distrobox/archfox`; the session home is `/home/infidel`.
  `scripts/install.sh` auto-detects this via `CONTAINER_ID`; never write plasmoids into container home.
- plasma5support executable engine does **not** run a shell (reference applet prefixes `sh`), so commands
  are argv-quoted with `q()`, never shell-quoted/concatenated with `;`.
- **`StandardPaths.writableLocation()` returns a `file://` URL** in QML, not a path — strip the scheme
  before building binary paths (this was the "Unparsable daemon output"/"not running" cause).
- The plasma5support `executable` engine runs commands through `/bin/sh -c` (proven by a shell error line
  in the journal), so argv quoting with `q()` is correct and shell metacharacters would work.
- **plasmashell PATH has no `~/.local/bin`** (`/usr/lib64/ccache:/usr/local/bin:/usr/bin:/bin:...`), so the
  plasmoid resolves binaries via `StandardPaths.HomeLocation` (`import QtCore`), never bare names.
- Two daemons on one machine share `config.json` → same fingerprint, so they see each other as self;
  run a second instance with `--download-dir` only, never for peer tests.
- D-Bus activation (`~/.local/share/dbus-1/services/*.service`) never became activatable on this bus
  ("name is not activatable") — abandoned; on-demand start goes through `localsend-bootstrap.sh`.
- `localsendctl` must always print JSON on **stdout** (including fatal errors) and the QML must treat
  `{"ok":false}` as down, not as a snapshot.

## Next Steps
1. User: reload plasmashell, add widget, confirm a real phone (official LocalSend app) appears and a
   transfer in both directions succeeds — that is the first cross-implementation check.
2. Add mDNS (`_localsend._tcp`) discovery for networks that drop multicast.
3. Inline accept/decline via KNotification actions instead of notify-send.
4. Package: PKGBUILD, KDE Store metadata, i18n extraction (strings already wrapped in `i18n`).

## Chronological History
- 2026-11-12 round 9: repository is Python-only — `src/`, `tests/e2e.rs`, `Cargo.*` deleted, `target/`
  gone, `__pycache__` ignored, Makefile rebuilt around `test|lint|backend|verify|install|uninstall|run|ctl`,
  README rewritten (outcome-first, architecture, paths, protocol scope, ops, security, dev hooks),
  MIT `LICENSE` added. Live daemon verified after restage (fp `944bcc88…`, phone `Hot Mushroom` seen).
- 2026-11-12 round 8 (branch `python-backend`): rewrote the backend in Python
  (`python/localsendd`, `python/localsendctl`) behind the same control socket, config/history files
  and `manage.sh` contract. `make backend` stages the scripts instead of cargo output; `install.sh`
  checks `python3 >= 3.11` + `py_compile`. Findings: `manage.sh probe()` must tolerate spaced JSON
  (`"ok": true` from python vs `"ok":true` from serde) — fixed on both sides; the receive server now
  binds before the control socket answers so a supervisor cannot race a half-started listener;
  abstract-socket guard name is overridable (`LOCALSENDD_GUARD_NAME`) because the hermetic tests
  share the netns with the live daemon; `SO_REUSEPORT` load-balances multicast between local
  sockets, so two same-host daemons never see each other unless the discovery port is separated
  (`LOCALSENDD_DISCOVERY_PORT`) — that made a real 3 MB two-process transfer testable.
- 2026-11-12 round 7: startup spinner; master switch moved to a marker file with
  `enable|disable|query-enabled` because KConfig lost `networkEnabled=false` silently.
- 2026-11-12 round 6: replaced D-Bus with a unix control socket; flock + abstract-socket
  single-instance guard; pid-based stop; fixed duplicate daemons from parallel `ensure`.
- 2026-11-12 round 5: dropped systemd; widget supervises daemon via `contents/backend/manage.sh`;
  binaries ship inside the package; `--idle-exit` heartbeat reaper; install/uninstall scripts.
- 2026-11-12 round 4: LocalSend-enabled switch stops the daemon; real TabBar; TSV checkboxes fixed.

- 2026-11-12: Repo scaffold; LocalSend v2 daemon (multicast discovery, HTTPS send/receive, D-Bus API),
  `localsendctl`, Plasma 6 applet (peer list, prompts, progress, drag-drop), installer, e2e tests.
  Fixed: upload must use the receiver-owned session id from `prepare-upload`; QML cross-file id scoping
  (`applet:` property injected instead of referencing `root`); Badge `borderColor` is readonly.
