import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid

Item {
    id: page

    property bool cfg_showNotifications: plasmoid.configuration.showNotifications
    property string cfg_iconStyle: plasmoid.configuration.iconStyle

    readonly property var iconStyles: [
        { value: "colored", label: i18n("Color") },
        { value: "symbolic", label: i18n("Monochrome") },
        { value: "system", label: i18n("System theme") }
    ]

    function iconStyleIndex(value) {
        for (let i = 0; i < iconStyles.length; ++i) {
            if (iconStyles[i].value === value) {
                return i
            }
        }
        return 0
    }

    Kirigami.FormLayout {
        anchors.fill: parent

        QQC2.ComboBox {
            Kirigami.FormData.label: i18n("Tray icon:")
            model: page.iconStyles.map(style => style.label)
            currentIndex: page.iconStyleIndex(page.cfg_iconStyle)
            onActivated: page.cfg_iconStyle = page.iconStyles[currentIndex].value
        }

        QQC2.CheckBox {
            Kirigami.FormData.label: i18n("Show notifications:")
            checked: page.cfg_showNotifications
            onToggled: page.cfg_showNotifications = checked
        }
    }
}
