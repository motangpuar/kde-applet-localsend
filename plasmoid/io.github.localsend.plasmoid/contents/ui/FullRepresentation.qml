import QtQml
import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

Item {
    id: full
    required property var applet

    Layout.preferredWidth: Kirigami.Units.gridUnit * 24
    Layout.preferredHeight: Kirigami.Units.gridUnit * 28

    // Drag files anywhere onto the popup: they go to the selected peer (or the first one).
    property string selectedPeer: ""

    // Favorites float to the top; the rest keep the daemon's alias order.
    readonly property bool hasSelection: String(selectedPeer || "").length > 0
    readonly property var orderedPeers: {
        const favored = applet.favorites || []
        const list = (applet.peers || []).slice()
        list.sort((a, b) => {
            const left = favored.indexOf(a.fingerprint) >= 0
            const right = favored.indexOf(b.fingerprint) >= 0
            if (left !== right) {
                return left ? -1 : 1
            }
            return String(a.alias || "").toLowerCase() < String(b.alias || "").toLowerCase() ? -1 : 1
        })
        return list
    }

    function dropTarget() {
        if (full.selectedPeer.length > 0) {
            return full.selectedPeer
        }
        return full.orderedPeers.length > 0 ? full.orderedPeers[0].fingerprint : ""
    }

    function deviceIcon(deviceType) {
        if (deviceType === "mobile") return "smartphone"
        if (deviceType === "headless") return "computer"
        if (deviceType === "tv") return "tv"
        return "computer"
    }

    function statusColor(status) {
        if (status === "done") return Kirigami.Theme.positiveTextColor
        if (status === "error" || status === "declined") return Kirigami.Theme.negativeTextColor
        return Kirigami.Theme.disabledTextColor
    }

    /// Readable words instead of the daemon's wire statuses.
    function statusText(status) {
        switch (status) {
        case "done": return i18n("Completed")
        case "error": return i18n("Failed")
        case "declined": return i18n("Declined")
        case "cancelled": return i18n("Cancelled")
        case "timed out": return i18n("Timed out")
        default: return status ? String(status) : i18n("Unknown")
        }
    }

    function filesLabel(count) {
        return count === 1 ? i18n("1 file") : i18n("%1 files", count)
    }

    /// "3 files · 29.8 MiB · 2.1 s · 14.2 MiB/s · 00:20" — everything the entry knows.
    function historyMeta(entry, fileCount, duration) {
        const parts = [full.filesLabel(fileCount), applet.formatBytes(entry.bytes || 0)]
        if (duration > 0) {
            parts.push(applet.formatDuration(duration))
            const rate = applet.formatRate((Number(entry.bytes) || 0) / (duration / 1000))
            if (rate.length > 0) {
                parts.push(rate)
            }
        }
        parts.push(applet.formatClock(entry.finishedMs || entry.startedMs))
        return parts.join(" · ")
    }

    /// First two file names, then "+N more": long albums stay on one line.
    function fileListLabel(files) {
        const names = (files || []).map(f => (f && f.name) ? String(f.name) : "").filter(n => n.length > 0)
        if (names.length === 0) {
            return ""
        }
        const shown = names.slice(0, 2).join(", ")
        return names.length > 2 ? i18n("%1 +%2 more", shown, names.length - 2) : shown
    }

    readonly property var historyRows: applet.history || []

    /// Totals for the History tab header, recomputed only when the daemon snapshot changes.
    readonly property var historySummary: {
        const rows = full.historyRows
        let sent = 0
        let received = 0
        let failed = 0
        let bytes = 0
        for (let i = 0; i < rows.length; ++i) {
            const row = rows[i] || {}
            if (row.direction === "send") {
                sent += 1
            } else {
                received += 1
            }
            if (row.status !== "done") {
                failed += 1
            }
            bytes += Number(row.bytes) || 0
        }
        return { "sent": sent, "received": received, "failed": failed,
                 "bytes": bytes, "total": rows.length }
    }

    function historySummaryLine() {
        const stats = full.historySummary
        const parts = [i18n("%1 sent", stats.sent),
                       i18n("%1 received", stats.received),
                       applet.formatBytes(stats.bytes)]
        if (stats.failed > 0) {
            parts.push(i18n("%1 not completed", stats.failed))
        }
        return parts.join(" · ")
    }

    DropArea {
        anchors.fill: parent
        onDropped: (drop) => {
            if (!drop.hasUrls) {
                return
            }
            const target = full.dropTarget()
            if (target.length === 0) {
                return
            }
            applet.sendPaths(target, drop.urls)
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing
        spacing: Kirigami.Units.smallSpacing

        // ---- header ----
        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            // Spinner while the daemon boots, static icon once it answers.
            Item {
                implicitWidth: Kirigami.Units.iconSizes.smallMedium
                implicitHeight: implicitWidth

                Kirigami.Icon {
                    anchors.fill: parent
                    source: "network-transmit-receive"
                    visible: !applet.startingUp
                    opacity: applet.daemonUp ? 1.0 : 0.5
                }

                PlasmaComponents3.BusyIndicator {
                    anchors.fill: parent
                    running: applet.startingUp
                    visible: applet.startingUp
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    font.bold: true
                    text: applet.daemonUp ? (applet.daemon.alias || i18n("LocalSend"))
                                          : i18n("LocalSend")
                }
                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    opacity: 0.7
                    font: Kirigami.Theme.smallFont
                    text: applet.daemonUp
                          ? i18n("port %1 · this device", applet.daemon.port)
                          : (applet.startingUp ? i18n("Starting the background service…")
                             : (applet.lastError.length > 0 ? applet.lastError
                                                            : i18n("Start localsendd to send files")))
                }
            }

            PlasmaComponents3.ToolButton {
                icon.name: "view-refresh"
                enabled: !applet.scanning
                onClicked: applet.scanForPeers()
                PlasmaComponents3.ToolTip.text: applet.networkEnabled
                    ? i18n("Scan for devices now")
                    : i18n("Start the background service and scan")
                PlasmaComponents3.ToolTip.visible: hovered
                PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay

                PlasmaComponents3.BusyIndicator {
                    anchors.centerIn: parent
                    implicitWidth: Kirigami.Units.iconSizes.smallMedium
                    implicitHeight: implicitWidth
                    running: applet.scanning
                    visible: applet.scanning
                }
            }

            PlasmaComponents3.ToolButton {
                icon.name: "folder-open"
                visible: applet.daemonUp
                onClicked: applet.openDownloadDir()
                PlasmaComponents3.ToolTip.text: i18n("Open download folder")
                PlasmaComponents3.ToolTip.visible: hovered
                PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay
            }
        }

        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Kirigami.Theme.disabledTextColor; opacity: 0.4 }

        // ---- incoming prompts ----
        Repeater {
            model: applet.prompts
            delegate: Rectangle {
                required property var modelData
                Layout.fillWidth: true
                implicitHeight: promptColumn.implicitHeight + Kirigami.Units.largeSpacing
                radius: Kirigami.Units.smallSpacing
                color: Kirigami.Theme.neutralBackgroundColor
                border.width: 1
                border.color: Kirigami.Theme.positiveTextColor

                ColumnLayout {
                    id: promptColumn
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        font.bold: true
                        text: i18n("%1 → %2 file(s), %3",
                                   modelData.peerAlias || modelData.peerIp,
                                   modelData.fileCount,
                                   applet.formatBytes(modelData.bytesTotal))
                    }
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        visible: (modelData.fileNames || []).length > 0
                        elide: Text.ElideMiddle
                        opacity: 0.75
                        font: Kirigami.Theme.smallFont
                        text: (modelData.fileNames || []).join(", ")
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        PlasmaComponents3.Button {
                            Layout.fillWidth: true
                            text: i18n("Accept")
                            icon.name: "dialog-ok-apply"
                            onClicked: applet.respond(modelData.id, true)
                        }
                        PlasmaComponents3.Button {
                            Layout.fillWidth: true
                            text: i18n("Decline")
                            icon.name: "dialog-cancel"
                            onClicked: applet.respond(modelData.id, false)
                        }
                    }
                }
            }
        }

        // ---- active transfers ----
        Repeater {
            model: applet.sessions
            delegate: ColumnLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 0
                visible: modelData.status === "running" || modelData.status === "negotiating"
                         || modelData.status === "waiting" || modelData.status === "error"

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        maximumLineCount: modelData.status === "error" ? 4 : 1
                        elide: modelData.status === "error" ? Text.ElideNone : Text.ElideRight
                        font: Kirigami.Theme.smallFont
                        text: {
                            const direction = modelData.direction === "send" ? i18n("Sending") : i18n("Receiving")
                            const peer = modelData.peer || i18n("peer")
                            if (modelData.status === "error") {
                                return direction + " · " + peer + " · " + (modelData.error || i18n("failed"))
                            }
                            const done = applet.formatBytes(modelData.bytesDone || 0)
                            const total = applet.formatBytes(modelData.bytesTotal || 0)
                            const elapsed = Math.max(0.5, (Date.now() - Number(modelData.startedMs || 0)) / 1000)
                            const rate = applet.formatRate((modelData.bytesDone || 0) / elapsed)
                            const suffix = rate.length > 0 ? " · " + rate : ""
                            return direction + " · " + peer + " · " + done + " / " + total + suffix
                        }
                    }
                    PlasmaComponents3.ToolButton {
                        icon.name: "dialog-cancel"
                        visible: modelData.status !== "error"
                        onClicked: applet.cancelSession(modelData.id)
                        PlasmaComponents3.ToolTip.text: i18n("Cancel transfer")
                        PlasmaComponents3.ToolTip.visible: hovered
                        PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay
                    }
                }
                PlasmaComponents3.ProgressBar {
                    Layout.fillWidth: true
                    visible: modelData.status !== "error"
                    from: 0
                    to: Math.max(1, Number(modelData.bytesTotal) || 1)
                    value: Number(modelData.bytesDone) || 0
                }
            }
        }

        // ---- Devices / History tabs ----
        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents3.TabBar {
                id: viewTabs
                currentIndex: applet.page === "history" ? 1 : 0
                onCurrentIndexChanged: {
                    applet.page = currentIndex === 1 ? "history" : "devices"
                    // Clicking breaks the binding; restore it so programmatic page switches steer the tabs.
                    currentIndex = Qt.binding(() => applet.page === "history" ? 1 : 0)
                }
                PlasmaComponents3.TabButton {
                    text: i18n("Devices")
                    icon.name: "network-wired"
                    width: implicitWidth
                }
                PlasmaComponents3.TabButton {
                    text: i18n("History")
                    icon.name: "view-history"
                    width: implicitWidth
                }
            }
            Item { Layout.fillWidth: true }
            PlasmaComponents3.Label {
                visible: applet.page === "history" && full.historySummary.total > 0
                opacity: 0.75
                font: Kirigami.Theme.smallFont
                text: full.historySummaryLine()
            }
            PlasmaComponents3.ToolButton {
                icon.name: "edit-clear-history"
                visible: applet.page === "history" && (applet.history || []).length > 0
                onClicked: applet.clearHistory()
                PlasmaComponents3.ToolTip.text: i18n("Clear history")
                PlasmaComponents3.ToolTip.visible: hovered
                PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay
            }
        }

        // ---- devices view ----
        ListView {
            id: peerList
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredHeight: Kirigami.Units.gridUnit * 10
            Layout.minimumHeight: Kirigami.Units.gridUnit * 4
            visible: applet.page === "devices"
            clip: true
            model: full.orderedPeers
            spacing: 2

            delegate: Rectangle {
                required property var modelData
                width: peerList.width
                implicitHeight: peerRow.implicitHeight + Kirigami.Units.smallSpacing
                radius: Kirigami.Units.smallSpacing
                color: full.selectedPeer === modelData.fingerprint
                       ? Kirigami.Theme.highlightColor : "transparent"

                RowLayout {
                    id: peerRow
                    anchors.fill: parent
                    anchors.leftMargin: Kirigami.Units.smallSpacing
                    anchors.rightMargin: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    Kirigami.Icon {
                        source: full.deviceIcon(modelData.deviceType)
                        implicitWidth: Kirigami.Units.iconSizes.smallMedium
                        implicitHeight: implicitWidth
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: modelData.alias || modelData.ip
                            color: full.selectedPeer === modelData.fingerprint
                                   ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.textColor
                        }
                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            opacity: 0.7
                            font: Kirigami.Theme.smallFont
                            text: modelData.ip + ":" + modelData.port
                            color: full.selectedPeer === modelData.fingerprint
                                   ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.textColor
                        }
                    }
                    PlasmaComponents3.ToolButton {
                        icon.name: applet.isFavorite(modelData.fingerprint) ? "rating" : "rating-unrated"
                        onClicked: applet.toggleFavorite(modelData.fingerprint)
                        PlasmaComponents3.ToolTip.text: applet.isFavorite(modelData.fingerprint)
                                                     ? i18n("Trusted: offers from this device start without asking. Click to stop trusting.")
                                                     : i18n("Trust this device")
                        PlasmaComponents3.ToolTip.visible: hovered
                        PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay
                    }
                    PlasmaComponents3.Button {
                        text: i18n("Send…")
                        icon.name: "document-send"
                        onClicked: applet.sendTo(modelData.fingerprint)
                    }
                }

                TapHandler {
                    onTapped: full.selectedPeer = modelData.fingerprint
                }
            }
        }

        PlasmaComponents3.Label {
            Layout.fillWidth: true
            visible: applet.page === "devices" && full.orderedPeers.length === 0
            Layout.fillHeight: true
            wrapMode: Text.WordWrap
            opacity: 0.7
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: applet.daemonUp
                  ? i18n("No devices discovered yet. Press refresh in the header, make sure the other device runs LocalSend on the same network, or drop files here once one appears.")
                  : i18n("localsendd is not running.")
        }

        // ---- history view: one card per transfer, grouped by day ----
        ListView {
            id: historyList
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredHeight: Kirigami.Units.gridUnit * 10
            Layout.minimumHeight: Kirigami.Units.gridUnit * 4
            visible: applet.page === "history"
            clip: true
            model: full.historyRows
            spacing: 0
            boundsBehavior: Flickable.StopAtBounds

            delegate: ColumnLayout {
                id: historyRow
                required property var modelData
                required property int index

                readonly property real stamp: Number(modelData.finishedMs || modelData.startedMs || 0)
                readonly property var previousEntry: index > 0 ? (full.historyRows[index - 1] || null) : null
                readonly property bool startsDay: !previousEntry
                    || full.dayKey(Number(previousEntry.finishedMs || previousEntry.startedMs || 0))
                       !== full.dayKey(stamp)
                readonly property int fileCount: (modelData.files || []).length
                readonly property real duration:
                    Math.max(0, Number(modelData.finishedMs || 0) - Number(modelData.startedMs || 0))
                readonly property bool failed: modelData.status !== "done"

                width: historyList.width
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.Label {
                    visible: historyRow.startsDay
                    Layout.fillWidth: true
                    Layout.topMargin: historyRow.index === 0 ? 0 : Kirigami.Units.smallSpacing
                    Layout.bottomMargin: Kirigami.Units.smallSpacing
                    text: applet.dayLabel(historyRow.stamp)
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    font.bold: true
                    opacity: 0.75
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: historyCard.implicitHeight + Kirigami.Units.smallSpacing * 2
                    radius: Kirigami.Units.smallSpacing
                    color: historyRow.failed
                           ? Qt.rgba(Kirigami.Theme.negativeTextColor.r,
                                     Kirigami.Theme.negativeTextColor.g,
                                     Kirigami.Theme.negativeTextColor.b, 0.08)
                           : Kirigami.Theme.alternateBackgroundColor

                    RowLayout {
                        id: historyCard
                        anchors.fill: parent
                        anchors.margins: Kirigami.Units.smallSpacing
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Icon {
                            Layout.alignment: Qt.AlignTop
                            implicitWidth: Kirigami.Units.iconSizes.smallMedium
                            implicitHeight: implicitWidth
                            source: historyRow.modelData.direction === "send" ? "document-send"
                                                                             : "document-save"
                            color: full.statusColor(historyRow.modelData.status)
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                PlasmaComponents3.Label {
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    font.bold: true
                                    text: historyRow.modelData.direction === "send"
                                          ? i18n("Sent to %1", historyRow.modelData.peer || i18n("unknown device"))
                                          : i18n("Received from %1", historyRow.modelData.peer || i18n("unknown device"))
                                }

                                Rectangle {
                                    Layout.alignment: Qt.AlignVCenter
                                    visible: historyRow.failed
                                    implicitWidth: historyChipLabel.implicitWidth + Kirigami.Units.smallSpacing * 2
                                    implicitHeight: historyChipLabel.implicitHeight + Kirigami.Units.smallSpacing
                                    radius: height / 2
                                    color: Qt.rgba(full.statusColor(historyRow.modelData.status).r,
                                                   full.statusColor(historyRow.modelData.status).g,
                                                   full.statusColor(historyRow.modelData.status).b, 0.18)

                                    PlasmaComponents3.Label {
                                        id: historyChipLabel
                                        anchors.centerIn: parent
                                        text: full.statusText(historyRow.modelData.status)
                                        color: full.statusColor(historyRow.modelData.status)
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        font.bold: true
                                    }
                                }
                            }

                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                opacity: 0.8
                                font: Kirigami.Theme.smallFont
                                text: full.historyMeta(historyRow.modelData, historyRow.fileCount,
                                                       historyRow.duration)
                            }

                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                visible: text.length > 0
                                text: full.fileListLabel(historyRow.modelData.files)
                                elide: Text.ElideMiddle
                                opacity: 0.7
                                font: Kirigami.Theme.smallFont
                            }

                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                visible: historyRow.failed
                                         && String(historyRow.modelData.error || "").length > 0
                                text: historyRow.modelData.error || ""
                                color: Kirigami.Theme.negativeTextColor
                                font: Kirigami.Theme.smallFont
                                wrapMode: Text.WordWrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
            }
        }

        PlasmaComponents3.Label {
            Layout.fillWidth: true
            visible: applet.page === "history" && (applet.history || []).length === 0
            Layout.fillHeight: true
            wrapMode: Text.WordWrap
            opacity: 0.7
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: i18n("No transfers yet. Sent and received files show up here.")
        }

        // ---- footer: master switch + trust settings ----
        ColumnLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents3.Switch {
                id: enabledSwitch
                Layout.fillWidth: true
                text: i18n("LocalSend enabled")
                onToggled: {
                    if (checked !== applet.networkEnabled) {
                        applet.setNetworkEnabled(checked)
                    }
                }
                Binding {
                    target: enabledSwitch
                    property: "checked"
                    value: applet.networkEnabled
                    restoreMode: Binding.RestoreNone
                }
                PlasmaComponents3.ToolTip.text: applet.networkEnabled
                    ? i18n("The background service runs: devices can discover and send to you")
                    : i18n("Stops the background service: nothing announced, nothing received")
                PlasmaComponents3.ToolTip.visible: hovered
                PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                visible: applet.daemonUp

                PlasmaComponents3.Switch {
                    id: autoAcceptSwitch
                    text: i18n("Auto-accept trusted devices")
                    enabled: (applet.favorites || []).length > 0
                    onToggled: {
                        if (checked !== applet.autoAccept) {
                            applet.setAutoAccept(checked)
                        }
                    }
                    Binding {
                        target: autoAcceptSwitch
                        property: "checked"
                        value: applet.autoAccept
                        restoreMode: Binding.RestoreNone
                    }
                    PlasmaComponents3.ToolTip.text: (applet.favorites || []).length > 0
                        ? i18n("Transfers from starred devices start without asking")
                        : i18n("Star a device first")
                    PlasmaComponents3.ToolTip.visible: hovered
                    PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay
                }
                PlasmaComponents3.Label {
                    visible: (applet.favorites || []).length === 0
                    opacity: 0.7
                    font: Kirigami.Theme.smallFont
                    text: i18n("Star a device to trust it")
                }
                Item { Layout.fillWidth: true }
            }

            PlasmaComponents3.Label {
                visible: applet.lastError.length > 0
                Layout.fillWidth: true
                elide: Text.ElideRight
                font: Kirigami.Theme.smallFont
                color: Kirigami.Theme.negativeTextColor
                text: applet.lastError
            }
            PlasmaComponents3.Label {
                visible: !applet.networkEnabled
                Layout.fillWidth: true
                opacity: 0.7
                wrapMode: Text.WordWrap
                font: Kirigami.Theme.smallFont
                text: i18n("LocalSend is off: the background service is stopped, so other devices cannot see or reach this machine.")
            }
        }
    }
}
