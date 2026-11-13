import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

Item {
    id: compact
    required property var applet

    Item {
        anchors.centerIn: parent
        width: Math.min(parent.width, parent.height)
        height: width
        visible: !compact.applet.startingUp
        // Off means the daemon is stopped: dim hard so the tray reflects it at a glance.
        opacity: !compact.applet.networkEnabled ? 0.35 : (compact.applet.daemonUp ? 1.0 : 0.55)

        Kirigami.Icon {
            anchors.fill: parent
            visible: compact.applet.trayIconFile === ""
            source: compact.applet.pendingCount > 0 ? "mail-unread" : compact.applet.trayIconName
        }

        Image {
            anchors.fill: parent
            visible: compact.applet.trayIconFile !== ""
            source: compact.applet.trayIconFile !== "" ? "file://" + compact.applet.trayIconFile : ""
            fillMode: Image.PreserveAspectFit
            sourceSize.width: width
            sourceSize.height: height
        }
    }

    // The daemon takes a moment to boot after the switch flips on: show that instead of a dead icon.
    PlasmaComponents3.BusyIndicator {
        anchors.centerIn: parent
        implicitWidth: Math.min(parent.width, parent.height) * 0.9
        implicitHeight: implicitWidth
        running: compact.applet.startingUp
        visible: running
    }

    // Badge: pending requests win over in-flight transfers; nothing to say -> no badge.
    Kirigami.Badge {
        anchors.right: parent.right
        anchors.top: parent.top
        visible: compact.applet.pendingCount > 0 || compact.applet.activeCount > 0
        text: compact.applet.pendingCount > 0 ? String(compact.applet.pendingCount)
                                              : String(compact.applet.activeCount)
        customColor: compact.applet.pendingCount > 0
                     ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.highlightColor
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onClicked: compact.applet.expanded = !compact.applet.expanded
    }
}
