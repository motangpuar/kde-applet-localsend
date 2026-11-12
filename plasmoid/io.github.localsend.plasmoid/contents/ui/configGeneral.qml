import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid

Item {
    id: page

    property bool cfg_showNotifications: plasmoid.configuration.showNotifications

    Kirigami.FormLayout {
        anchors.fill: parent

        QQC2.CheckBox {
            Kirigami.FormData.label: i18n("Show notifications:")
            checked: page.cfg_showNotifications
            onToggled: page.cfg_showNotifications = checked
        }
    }
}
