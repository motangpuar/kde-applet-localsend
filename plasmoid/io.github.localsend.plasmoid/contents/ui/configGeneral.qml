import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid

Item {
    id: page

    property string cfg_backendPath: plasmoid.configuration.backendPath
    property int cfg_pollIntervalMs: plasmoid.configuration.pollIntervalMs
    property bool cfg_showNotifications: plasmoid.configuration.showNotifications

    Kirigami.FormLayout {
        anchors.fill: parent

        QQC2.TextField {
            Kirigami.FormData.label: i18n("Supervisor script:")
            text: page.cfg_backendPath
            placeholderText: i18n("bundled (contents/backend/manage.sh)")
            onTextEdited: page.cfg_backendPath = text
        }

        QQC2.SpinBox {
            Kirigami.FormData.label: i18n("Refresh interval:")
            from: 500
            to: 10000
            stepSize: 500
            value: page.cfg_pollIntervalMs
            textFromValue: (value) => i18n("%1 ms", value)
            valueFromText: (text) => parseInt(text)
            onValueModified: page.cfg_pollIntervalMs = value
        }

        QQC2.CheckBox {
            Kirigami.FormData.label: i18n("Show notifications:")
            checked: page.cfg_showNotifications
            onToggled: page.cfg_showNotifications = checked
        }
    }
}
