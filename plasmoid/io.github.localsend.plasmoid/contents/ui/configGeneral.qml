import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Dialogs as QQD
import QtQuick.Layouts
import org.kde.iconthemes as KIconThemes
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid

Item {
    id: page

    property bool cfg_showNotifications: plasmoid.configuration.showNotifications
    property string cfg_iconName: plasmoid.configuration.iconName
    property string cfg_iconPath: plasmoid.configuration.iconPath

    readonly property string defaultIcon: Qt.resolvedUrl("../icons/io.github.localsend.plasmoid.svg").toString()
    readonly property bool customised: page.cfg_iconName !== "" || page.cfg_iconPath !== ""
    readonly property string iconLabel: page.cfg_iconPath !== ""
                                        ? page.cfg_iconPath.split("/").pop()
                                        : (page.cfg_iconName !== "" ? page.cfg_iconName : i18n("Default"))

    /// QUrl from the file dialog to a plain path, which is what QIcon and Image want.
    function localPath(url) {
        let text = url.toString()
        if (text.indexOf("file://") === 0) {
            text = text.substring(7)
        }
        return decodeURIComponent(text)
    }

    Kirigami.FormLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.gridUnit

        RowLayout {
            Kirigami.FormData.label: i18n("Tray icon:")

            Kirigami.Icon {
                visible: page.cfg_iconName !== ""
                source: page.cfg_iconName
                Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                Layout.preferredHeight: Kirigami.Units.iconSizes.medium
            }

            Image {
                visible: page.cfg_iconName === ""
                source: page.cfg_iconPath !== "" ? "file://" + page.cfg_iconPath : page.defaultIcon
                fillMode: Image.PreserveAspectFit
                sourceSize.width: Kirigami.Units.iconSizes.medium * 2
                sourceSize.height: Kirigami.Units.iconSizes.medium * 2
                Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                Layout.preferredHeight: Kirigami.Units.iconSizes.medium
            }

            QQC2.Label {
                Layout.maximumWidth: Kirigami.Units.gridUnit * 14
                text: page.iconLabel
                elide: Text.ElideMiddle
                opacity: 0.7
            }

            QQC2.Button {
                text: i18n("Choose Icon…")
                onClicked: iconDialog.open()
            }

            QQC2.Button {
                text: i18n("Load Image…")
                onClicked: fileDialog.open()
            }

            QQC2.ToolButton {
                icon.name: "edit-reset"
                enabled: page.customised
                display: QQC2.AbstractButton.IconOnly
                onClicked: {
                    page.cfg_iconName = ""
                    page.cfg_iconPath = ""
                }
                QQC2.ToolTip.text: i18n("Use the default icon")
                QQC2.ToolTip.visible: hovered
                QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
            }
        }

        QQC2.CheckBox {
            Kirigami.FormData.label: i18n("Show notifications:")
            checked: page.cfg_showNotifications
            onToggled: page.cfg_showNotifications = checked
        }
    }

    // The same icon picker the menu editor uses: search, categories, and a browse button.
    // Its iconName is read-only, so the current choice cannot be preselected; only the result is read.
    KIconThemes.IconDialog {
        id: iconDialog
        title: i18n("Choose Tray Icon")
        onAccepted: {
            if (iconDialog.iconName !== "") {
                page.cfg_iconName = iconDialog.iconName
                page.cfg_iconPath = ""
            }
        }
    }

    QQD.FileDialog {
        id: fileDialog
        title: i18n("Load Tray Icon Image")
        nameFilters: [i18n("Images (*.svg *.svgz *.png)"), i18n("All files (*)")]
        onAccepted: {
            const path = page.localPath(selectedFile)
            if (path !== "") {
                page.cfg_iconPath = path
                page.cfg_iconName = ""
            }
        }
    }
}
