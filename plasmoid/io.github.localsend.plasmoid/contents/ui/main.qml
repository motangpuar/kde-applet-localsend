import QtQuick
import QtCore
import QtQuick.Dialogs
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support

PlasmoidItem {
    id: root

    // --- wiring -------------------------------------------------------------
    // The backend ships inside the package (contents/backend) and the widget supervises it: no
    // systemd unit, no ~/.local/bin entry. Uninstalling the applet therefore removes everything.
    readonly property string backendDir: {
        // Qt.resolvedUrl hands back a file:// URL in QML.
        let url = Qt.resolvedUrl("../backend").toString()
        if (url.indexOf("file://") === 0) {
            url = url.substring(7)
        }
        return decodeURIComponent(url).replace(/\/+$/, "")
    }
    readonly property string managePath: backendDir + "/manage.sh"
    readonly property string ctl: managePath + " ctl"
    // Notifications point straight at the packaged SVG: no icon-theme install needed.
    readonly property string iconPath: {
        let url = Qt.resolvedUrl("../icons/io.github.localsend.plasmoid.svg").toString()
        return url.indexOf("file://") === 0 ? decodeURIComponent(url.substring(7)) : url
    }

    // --- daemon state -------------------------------------------------------
    property bool daemonUp: false
    property bool starting: false
    property var daemon: ({})
    property var peers: []
    property var favorites: []
    property var prompts: []
    property var sessions: []
    property var history: []
    property bool autoAccept: false
    /// Master switch. Off stops the daemon itself: nothing is announced, nothing is received,
    /// and a peer that cached our address gets no answer at all.
    property bool networkEnabled: Plasmoid.configuration.networkEnabled !== false
    property string lastError: ""
    /// True from the moment the switch flips on (or a dead daemon is noticed) until the first
    /// successful poll lands: the UI shows a spinner for that window instead of a dead icon.
    /// Suppressed while an error is being displayed, so a real failure does not spin forever.
    readonly property bool startingUp: networkEnabled
                                       && ((!daemonUp && lastError.length === 0) || starting)
    property double lastStartAttempt: 0
    property var announcedPrompts: ({})
    /// Prompts that already produced an actionable notification, so a refresh does not stack them.
    property var notifiedPrompts: ({})
    property var announcedSessions: ({})
    property string pendingPeer: ""
    /// True while a manual re-scan is in flight, so the header button can show a spinner.
    property bool scanning: false
    /// Popup view: "devices" | "history".
    property string page: "devices"

    readonly property int pendingCount: prompts.length
    readonly property int activeCount: {
        let n = 0
        for (let i = 0; i < sessions.length; ++i) {
            const st = sessions[i].status
            if (st === "running" || st === "negotiating" || st === "waiting") {
                ++n
            }
        }
        return n
    }
    function isFavorite(fingerprint) {
        return (root.favorites || []).indexOf(String(fingerprint)) >= 0
    }

    toolTipMainText: i18n("LocalSend")
    toolTipSubText: {
        if (!networkEnabled) {
            return i18n("Turned off · no discovery, no transfers")
        }
        if (startingUp && lastError.length === 0) {
            return i18n("Starting the background service…")
        }
        if (!daemonUp) {
            return lastError.length > 0 ? i18n("Daemon unreachable: %1", lastError) : i18n("Daemon not running")
        }
        const name = daemon.alias || "localsendd"
        if (pendingCount > 0) {
            return i18n("%1 pending request(s) · %2 device(s)", pendingCount, peers.length)
        }
        if (activeCount > 0) {
            return i18n("%1 transfer(s) in progress", activeCount)
        }
        return i18n("%1 · port %2 · %3 device(s)", name, daemon.port, peers.length)
    }

    Component.onCompleted: root.syncSwitch()
    // Deliberately not stopped on destruction: an outgoing widget instance must not kill the daemon
    // the next one is about to attach to. A widget that disappears without stopping it cannot
    // orphan it either -- the daemon reaps itself after 15 min without a heartbeat, and the
    // "LocalSend enabled" switch stops it immediately.

    compactRepresentation: CompactRepresentation {
        applet: root
    }
    fullRepresentation: FullRepresentation {
        applet: root
    }

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        property var queue: []

        function run(command, onDone, onFail) {
            queue.push({ cmd: command, done: onDone, fail: onFail })
            connectSource(command)
        }

        onNewData: (sourceName, data) => {
            let index = -1
            for (let i = 0; i < queue.length; ++i) {
                if (queue[i].cmd === sourceName) { index = i; break }
            }
            const entry = index >= 0 ? queue.splice(index, 1)[0] : null
            disconnectSource(sourceName)
            if (!entry) {
                return
            }
            const code = (data.exitCode === undefined || data.exitCode === null) ? 0 : Number(data.exitCode)
            if (code === 0 && entry.done) {
                entry.done(data)
            } else if (code !== 0 && entry.fail) {
                entry.fail(data)
            } else if (entry.done) {
                entry.done(data)
            }
        }
    }

    // The plasma5support executable engine runs through /bin/sh -c, so quote, don't escape.
    function q(value) {
        return "\"" + String(value).replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + "\""
    }

    function runCtl(args, onDone, onFail) {
        const parts = ["sh", q(root.managePath), "ctl"]
        for (let i = 0; i < args.length; ++i) {
            parts.push(args[i])
        }
        exec.run(parts.join(" "), onDone, onFail)
    }

    function notify(summary, body, icon) {
        if (!Plasmoid.configuration.showNotifications) {
            return
        }
        exec.run("notify-send -a LocalSend -i " + q(icon || root.iconPath)
                 + " " + q(summary) + " " + q(body), null, null)
    }

    function refresh() {
        if (!root.networkEnabled) {
            root.daemonUp = false
            return
        }
        runCtl(["state"], data => {
            const out = String(data.stdout || "").trim()
            const err = String(data.stderr || "").trim()
            if (out.length === 0) {
                root.daemonDown(err.length > 0 ? err
                                : ("ctl returned nothing (exit " + data.exitCode + "): " + root.ctl))
                return
            }
            let snapshot = null
            try {
                snapshot = JSON.parse(out)
            } catch (e) {
                root.daemonDown("Bad output from " + root.ctl + ": " + out.substring(0, 120))
                return
            }
            if (snapshot.ok === false) {
                root.daemonDown(String(snapshot.error || i18n("daemon unavailable")))
                return
            }
            root.daemon = snapshot.daemon || ({})
            root.peers = snapshot.peers || []
            root.prompts = snapshot.prompts || []
            root.sessions = snapshot.sessions || []
            root.history = snapshot.history || []
            root.favorites = snapshot.favorites || []
            root.autoAccept = snapshot.autoAcceptFavorites === true
            if (!root.daemonUp) {
                console.info("localsend: daemon up", root.daemon.alias || "", "port", root.daemon.port,
                             "peers", root.peers.length, "via", root.ctl)
            }
            root.daemonUp = true
            root.lastError = ""
            root.notifyPrompts()
            root.notifySessions()
        }, data => {
            const err = String(data.stderr || "").trim()
            root.daemonDown(err.length > 0 ? err
                            : ("cannot run " + root.ctl + " (exit " + data.exitCode + ")"))
        })
    }

    function daemonDown(reason) {
        if (!root.networkEnabled) {
            // Switched off on purpose: staying down is the desired state, not a failure.
            root.daemonUp = false
            root.lastError = ""
            return
        }
        // Only log a real transition: the cold-start window before the first successful poll is
        // expected and would otherwise spam the journal on every session start.
        if (root.daemonUp) {
            console.warn("localsend: daemon unreachable:", reason)
        }
        root.daemonUp = false
        root.lastError = reason
        root.maybeStartDaemon()
    }

    /// The widget is the supervisor: manage.sh starts the daemon (it also restages the binaries
    /// and restarts a daemon left running by a previous package version).
    function startDaemon() {
        if (!root.networkEnabled || root.starting) {
            return
        }
        root.starting = true
        root.lastError = ""   // a retry gets the spinner back instead of the stale error text
        exec.run("sh " + q(root.managePath) + " ensure", data => {
            const out = String(data.stdout || "")
            root.starting = false
            if (out.indexOf("LOCALSEND_RUNNING") >= 0 || out.indexOf("LOCALSEND_STARTED") >= 0) {
                root.refresh()
                return
            }
            if (out.indexOf("LOCALSEND_DISABLED") >= 0) {
                // Someone (or a previous session) turned the service off: honour it, stay quiet.
                root.networkEnabled = false
                Plasmoid.configuration.networkEnabled = false
                root.daemonUp = false
                root.lastError = ""
                return
            }
            root.daemonDown(String(data.stderr || out
                                    || ("manage.sh failed (exit " + data.exitCode + ")")))
        }, data => {
            root.starting = false
            root.daemonDown(String(data.stderr || ("cannot run " + root.managePath)))
        })
    }

    function maybeStartDaemon() {
        if (!root.networkEnabled) {
            return
        }
        const now = Date.now()
        if (now - root.lastStartAttempt < 15000) {
            return
        }
        root.lastStartAttempt = now
        root.startDaemon()
    }

    /// An incoming prompt shows up as a notification that can be answered without opening the popup.
    /// The popup keeps its own Accept and Decline buttons, so a dismissed notification is not a
    /// decision: the daemon still waits, and the click that does arrive wins either way.
    function notifyPrompts() {
        for (let i = 0; i < root.prompts.length; ++i) {
            const prompt = root.prompts[i]
            if (root.notifiedPrompts[prompt.id]) {
                continue
            }
            root.announcedPrompts[prompt.id] = true
            root.notifiedPrompts[prompt.id] = true
            root.notifyPrompt(prompt)
            root.expanded = true
        }
        // Drop ids that no longer exist, otherwise both maps grow for the life of the session.
        const live = ({})
        for (let i = 0; i < root.prompts.length; ++i) {
            live[root.prompts[i].id] = true
        }
        for (const key in root.notifiedPrompts) {
            if (!live[key]) {
                delete root.notifiedPrompts[key]
                delete root.announcedPrompts[key]
            }
        }
    }

    function notifyPrompt(prompt) {
        if (!Plasmoid.configuration.showNotifications) {
            return
        }
        const body = i18n("%1 wants to send %2 file(s) · %3", prompt.peerAlias, prompt.fileCount,
                          root.formatBytes(prompt.bytesTotal))
        // notify-send implies --wait with --action and prints the chosen action name on stdout,
        // so the callback only fires once the user answers or dismisses the notification. The
        // trailing comment is inert to the shell and makes the command unique per prompt, which
        // is what the executable engine matches its completions on.
        const command = "notify-send --app-name LocalSend --icon " + q(root.iconPath)
                        + " --action accept=" + q(i18n("Accept"))
                        + " --action decline=" + q(i18n("Decline"))
                        + " " + q(i18n("Incoming transfer")) + " " + q(body)
                        + " # prompt:" + prompt.id
        exec.run(command, data => {
            const answer = String(data.stdout || "").trim()
            if (answer !== "accept" && answer !== "decline") {
                return
            }
            root.respond(prompt.id, answer === "accept")
        })
    }

    /// One notification per finished transfer: completed receives also announce where the files landed.
    function notifySessions() {
        const terminal = ({ "done": true, "error": true, "declined": true, "cancelled": true, "timed out": true })
        for (let i = 0; i < root.sessions.length; ++i) {
            const session = root.sessions[i]
            if (!terminal[session.status] || root.announcedSessions[session.id]) {
                continue
            }
            root.announcedSessions[session.id] = true
            const files = (session.files || []).length
            const size = root.formatBytes(session.bytesDone || session.bytesTotal)
            if (session.status === "done") {
                if (session.direction === "receive") {
                    root.notify(i18n("Received from %1", session.peer || i18n("device")),
                                i18n("%1 file(s) · %2 · saved to %3", files, size, root.daemon.downloadDir || ""),
                                "document-save")
                } else {
                    root.notify(i18n("Sent to %1", session.peer || i18n("device")),
                                i18n("%1 file(s) · %2", files, size), "document-send")
                }
            } else {
                root.notify(i18n("Transfer with %1 failed", session.peer || i18n("device")),
                            session.error || session.status, "dialog-error")
            }
        }
    }

    function respond(promptId, accept) {
        runCtl(["respond", q(promptId), accept ? "accept" : "reject"], () => root.refresh(), () => root.refresh())
    }

    function retrySession(sessionId) {
        runCtl(["retry", q(sessionId)], () => root.refresh(), () => root.refresh())
    }

    function cancelSession(sessionId) {
        runCtl(["cancel", q(sessionId)], () => root.refresh(), () => root.refresh())
    }

    /// The switch state lives in `manage.sh` (marker file), not in the plasmoid config: KConfig
    /// silently dropped `networkEnabled` once and left the backend dead with no trace. The config
    /// entry is only a cache, so the widget always asks the supervisor on load.
    function syncSwitch() {
        exec.run("sh " + q(root.managePath) + " query-enabled", data => {
            const out = String(data.stdout || "")
            if (out.indexOf("LOCALSEND_DISABLED") >= 0) {
                root.networkEnabled = false
                Plasmoid.configuration.networkEnabled = false
                root.daemonUp = false
                return
            }
            root.networkEnabled = true
            Plasmoid.configuration.networkEnabled = true
            root.startDaemon()
        }, data => {
            // manage.sh unusable (package mid-upgrade): fall back to the cached config state.
            console.warn("localsend: cannot query the switch state:", String(data.stderr || ""))
            if (root.networkEnabled) {
                root.startDaemon()
            }
        })
    }

    function toggleFavorite(fingerprint) {
        if (String(fingerprint).length === 0) {
            return
        }
        const on = root.isFavorite(fingerprint)
        runCtl(["favorite", q(fingerprint), on ? "off" : "on"], () => root.refresh(), () => root.refresh())
    }

    /// Optimistic: flip the local flag first so the switch reacts immediately, then confirm.
    function setAutoAccept(enabled) {
        root.autoAccept = enabled
        runCtl(["auto-accept", enabled ? "on" : "off"], () => root.refresh(), () => root.refresh())
    }

    /// Off = stop the service (that is what "not visible" really means), on = start it again.
    /// `manage.sh enable|disable` flips the marker file, so the state survives a lost KConfig key.
    function setNetworkEnabled(enabled) {
        root.networkEnabled = enabled
        Plasmoid.configuration.networkEnabled = enabled
        if (enabled) {
            root.lastStartAttempt = 0
            root.lastError = ""
            exec.run("sh " + q(root.managePath) + " enable", data => root.startDaemon(), data => {
                root.daemonDown(String(data.stderr || "cannot enable the background service"))
            })
            return
        }
        root.announcedPrompts = ({})
        root.announcedSessions = ({})
        root.prompts = []
        root.sessions = []
        root.peers = []
        root.daemonUp = false
        root.lastError = ""
        exec.run("sh " + q(root.managePath) + " disable", null, null)
    }

    function clearHistory() {
        runCtl(["clear-history"], () => root.refresh(), () => root.refresh())
    }

    function openDownloadDir() {
        const dir = String(root.daemon.downloadDir || "")
        if (dir.length === 0) {
            return
        }
        exec.run("xdg-open " + q(dir), null, null)
    }

    /// Hand a path to the shell helper: QML has no file API and no D-Bus here.
    function openPath(path) {
        const target = String(path || "")
        if (target.length === 0) {
            return
        }
        exec.run("sh " + q(root.managePath) + " open " + q(target), null, null)
    }

    /// Show the given files in the file manager with the first one selected.
    function revealPaths(paths) {
        const list = (paths || []).filter(p => String(p || "").length > 0)
        if (list.length === 0) {
            return
        }
        let command = "sh " + q(root.managePath) + " reveal"
        for (let i = 0; i < list.length; ++i) {
            command += " " + q(list[i])
        }
        exec.run(command, null, null)
    }

    function sendTo(fingerprint) {
        root.pendingPeer = fingerprint
        fileDialog.open()
    }

    /// Opening a native file dialog deactivates the popup, so Plasma hides it. Re-open it once
    /// the dialog is gone: the user is still mid-task (pick files, then watch the transfer).
    function reopenPopup() {
        reopenTimer.restart()
    }

    /// Manual discovery round: the daemon announces right away instead of waiting for its tick.
    function scanForPeers() {
        if (!root.networkEnabled) {
            root.startDaemon()
            return
        }
        root.scanning = true
        runCtl(["scan"], () => {
            root.refresh()
            scanSettleTimer.restart()
        }, () => {
            root.scanning = false
            root.refresh()
        })
    }

    function sendPaths(fingerprint, urls) {
        const args = ["send", q(fingerprint)]
        for (let i = 0; i < urls.length; ++i) {
            const raw = String(urls[i])
            let path = raw.indexOf("file://") === 0 ? raw.substring(7) : raw
            try { path = decodeURIComponent(path) } catch (e) { /* keep raw path */ }
            args.push(q(path))
        }
        if (args.length < 3) {
            return
        }
        runCtl(args, data => {
            let parsed = ({})
            try { parsed = JSON.parse(data.stdout) } catch (e) { /* handled below */ }
            if (parsed.ok === false) {
                root.lastError = parsed.error || i18n("Send failed")
                return
            }
            root.lastError = ""
            root.refresh()
        }, data => {
            root.lastError = String(data.stderr || "").trim()
        })
    }

    FileDialog {
        id: fileDialog
        title: i18n("Files to send with LocalSend")
        fileMode: FileDialog.OpenFiles
        onAccepted: {
            root.sendPaths(root.pendingPeer, fileDialog.selectedFiles)
            root.pendingPeer = ""
            root.reopenPopup()
        }
        onRejected: {
            root.pendingPeer = ""
            root.reopenPopup()
        }
    }

    // Plasma hides the popup while the file dialog is up; asking again a beat later is enough.
    Timer {
        id: reopenTimer
        interval: 120
        onTriggered: root.expanded = true
    }

    /// Peers answer an announcement within a few hundred ms; poll once after that window.
    Timer {
        id: scanSettleTimer
        interval: 900
        onTriggered: {
            root.scanning = false
            root.refresh()
        }
    }

    function formatBytes(bytes) {
        const value = Number(bytes) || 0
        if (value >= 1024 * 1024 * 1024) return (value / (1024 * 1024 * 1024)).toFixed(2) + " GiB"
        if (value >= 1024 * 1024) return (value / (1024 * 1024)).toFixed(1) + " MiB"
        if (value >= 1024) return (value / 1024).toFixed(0) + " KiB"
        return value + " B"
    }

    function formatRate(bytesPerSecond) {
        const value = Number(bytesPerSecond) || 0
        if (!isFinite(value) || value <= 0) return ""
        return root.formatBytes(value) + "/s"
    }

    function formatWhen(ms) {
        const stamp = Number(ms) || 0
        if (stamp <= 0) return ""
        return Qt.formatDateTime(new Date(stamp), "yyyy-MM-dd HH:mm")
    }

    /// "0.8 s" / "12 s" / "3 m 20 s": transfer duration, not a wall clock.
    function formatDuration(ms) {
        const total = Math.max(0, Math.round(Number(ms) || 0))
        if (total < 1000) return i18n("%1 ms", total)
        const seconds = total / 1000
        if (seconds < 60) return i18n("%1 s", seconds < 10 ? seconds.toFixed(1) : Math.round(seconds))
        const minutes = Math.floor(seconds / 60)
        const rest = Math.round(seconds - minutes * 60)
        return i18n("%1 m %2 s", minutes, rest)
    }

    function formatClock(ms) {
        const stamp = Number(ms) || 0
        if (stamp <= 0) return ""
        return Qt.formatDateTime(new Date(stamp), "HH:mm")
    }

    /// History grouping: one key per calendar day, in the user's own timezone.
    function dayKey(ms) {
        const stamp = Number(ms) || 0
        if (stamp <= 0) return ""
        return Qt.formatDateTime(new Date(stamp), "yyyy-MM-dd")
    }

    function dayLabel(ms) {
        const stamp = Number(ms) || 0
        if (stamp <= 0) return i18n("Unknown date")
        const key = root.dayKey(stamp)
        const now = new Date()
        if (key === root.dayKey(now.getTime())) return i18n("Today")
        if (key === root.dayKey(now.getTime() - 24 * 60 * 60 * 1000)) return i18n("Yesterday")
        return Qt.formatDateTime(new Date(stamp), "ddd d MMM yyyy")
    }

    Timer {
        // 2 s keeps the popup responsive without waking the daemon needlessly.
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }
}
