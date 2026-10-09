// A message with an action button and Close, like KMessageBox, run with
// Qt's qml tool (see qml_linux.go). Input: {title, message, action, icon};
// answer: {ok}.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

QQC2.ApplicationWindow {
    id: root

    readonly property var form: JSON.parse(Qt.application.arguments[Qt.application.arguments.length - 1])
    property bool answered: false

    function answer(ok) {
        if (answered)
            return;
        answered = true;
        console.log("FOXDEN-RESULT " + JSON.stringify({
            ok: ok
        }));
        Qt.quit();
    }

    title: form.title
    flags: Qt.Dialog
    visible: true
    // A fixed size that follows the content, as for a dialog.
    minimumWidth: Kirigami.Units.gridUnit * 28
    maximumWidth: minimumWidth
    width: minimumWidth
    minimumHeight: content.implicitHeight + 2 * Kirigami.Units.largeSpacing
    maximumHeight: minimumHeight
    height: minimumHeight
    onClosing: answer(false)
    Component.onCompleted: {
        Qt.application.displayName = "FoxDen VPN";
        requestActivate();
    }

    Shortcut {
        sequences: [StandardKey.Cancel]
        onActivated: root.answer(false)
    }

    ColumnLayout {
        id: content

        x: Kirigami.Units.largeSpacing
        y: Kirigami.Units.largeSpacing
        width: parent.width - 2 * Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.largeSpacing

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.largeSpacing

            Kirigami.Icon {
                Layout.alignment: Qt.AlignTop
                implicitWidth: Kirigami.Units.iconSizes.large
                implicitHeight: Kirigami.Units.iconSizes.large
                source: root.form.icon
            }

            // Selectable, for the public key.
            Kirigami.SelectableLabel {
                Layout.fillWidth: true
                text: root.form.message
                wrapMode: Text.Wrap
            }
        }

        QQC2.DialogButtonBox {
            Layout.fillWidth: true
            standardButtons: QQC2.DialogButtonBox.Ok | QQC2.DialogButtonBox.Close
            onAccepted: root.answer(true)
            onRejected: root.answer(false)
            Component.onCompleted: {
                const ok = standardButton(QQC2.DialogButtonBox.Ok);
                ok.text = root.form.action;
                ok.icon.name = ""; // a checkmark does not fit "Remove" or "Copy"
                ok.forceActiveFocus();
            }
        }
    }
}
