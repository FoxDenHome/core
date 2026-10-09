// The Expose Local Port form on Plasma, run with Qt's qml tool. The last
// command line argument is the form as JSON (exposeForm); the answer is
// logged as "FOXDEN-RESULT <json>".
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

QQC2.ApplicationWindow {
    id: root

    readonly property var form: JSON.parse(Qt.application.arguments[Qt.application.arguments.length - 1])
    readonly property bool tcp: tcpButton.checked
    readonly property bool valid: target.acceptableInput && (tcp || name.acceptableInput || name.text === "")
    // The public ports a TCP tunnel can ask for; the step below the first
    // is "Random". Without a known range, any port.
    readonly property int portFirst: form.tcp_first > 0 ? form.tcp_first : 1
    readonly property int portLast: form.tcp_first > 0 ? form.tcp_last : 65535
    property bool answered: false

    function answer(ok) {
        if (answered)
            return;
        answered = true;
        console.log("FOXDEN-RESULT " + JSON.stringify({
            ok: ok,
            target: target.text,
            tcp: tcp,
            name: name.text,
            port: port.value < portFirst ? "" : String(port.value)
        }));
        Qt.quit();
    }

    function submit() {
        port.commit(); // a port typed but not yet taken
        if (valid)
            answer(true);
    }

    title: form.title
    flags: Qt.Dialog
    visible: true
    // A fixed size that follows the content, as for a dialog.
    minimumWidth: Kirigami.Units.gridUnit * 30
    maximumWidth: minimumWidth
    width: minimumWidth
    minimumHeight: content.implicitHeight + 2 * Kirigami.Units.largeSpacing
    maximumHeight: minimumHeight
    height: minimumHeight
    onClosing: answer(false)
    Component.onCompleted: {
        Qt.application.displayName = "FoxDen VPN";
        (form.target === "" ? target : tcp ? port : name).forceActiveFocus();
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

        QQC2.Label {
            Layout.fillWidth: true
            text: root.form.message
            wrapMode: Text.Wrap
            visible: text !== ""
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            type: Kirigami.MessageType.Error
            text: root.form.error
            visible: text !== ""
        }

        Kirigami.FormLayout {
            Layout.fillWidth: true

            QQC2.TextField {
                id: target

                Kirigami.FormData.label: "Target:"
                Layout.fillWidth: true
                text: root.form.target
                placeholderText: "Port, or host:port"
                validator: RegularExpressionValidator {
                    regularExpression: /^(\d{1,5}|.+:\d{1,5})$/
                }
                onAccepted: root.submit()
            }

            QQC2.ButtonGroup {
                id: kind
            }

            QQC2.RadioButton {
                id: httpsButton

                Kirigami.FormData.label: "Publish as:"
                text: "HTTPS (TLS ends at FoxDen, the port gets plain HTTP)"
                checked: !root.form.tcp
                QQC2.ButtonGroup.group: kind
            }

            QQC2.RadioButton {
                id: tcpButton

                text: "TCP (a public port, passed through as is)"
                checked: root.form.tcp
                QQC2.ButtonGroup.group: kind
            }

            RowLayout {
                Kirigami.FormData.label: "Name:"
                Layout.fillWidth: true
                visible: !root.tcp
                spacing: 0

                QQC2.TextField {
                    id: name

                    Layout.fillWidth: true
                    text: root.form.name
                    placeholderText: "random"
                    validator: RegularExpressionValidator {
                        regularExpression: /^[a-zA-Z0-9]([a-zA-Z0-9-]{0,30}[a-zA-Z0-9])?$/
                    }
                    onAccepted: root.submit()
                }

                QQC2.Label {
                    text: "." + root.form.domain
                    visible: root.form.domain !== ""
                }
            }

            ColumnLayout {
                Kirigami.FormData.label: "Public port:"
                visible: root.tcp
                spacing: Kirigami.Units.smallSpacing

                QQC2.SpinBox {
                    id: port

                    function commit() {
                        value = valueFromText(contentItem.text, locale);
                    }

                    // Sized for the placeholder, not only for numbers.
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 7
                    from: root.portFirst - 1
                    to: root.portLast
                    value: {
                        const p = parseInt(root.form.port);
                        return p >= root.portFirst && p <= root.portLast ? p : from;
                    }
                    editable: true
                    // Plain numbers: "30,042" would be odd for a port. The
                    // step below the range is a random port: left empty,
                    // with a placeholder.
                    textFromValue: (v, locale) => v < root.portFirst ? "" : String(v)
                    valueFromText: (text, locale) => {
                        const p = parseInt(text);
                        return isNaN(p) ? from : Math.max(from, Math.min(to, p));
                    }
                    validator: RegularExpressionValidator {
                        regularExpression: /^(\d{0,5}|[Rr]andom)$/
                    }
                    Keys.onReturnPressed: {
                        commit();
                        root.submit();
                    }
                    Keys.onEnterPressed: {
                        commit();
                        root.submit();
                    }

                    // The style's text field draws no placeholder.
                    QQC2.Label {
                        parent: port.contentItem
                        x: port.contentItem.leftPadding
                        anchors.verticalCenter: parent.verticalCenter
                        text: "random"
                        font: port.font
                        color: Kirigami.Theme.disabledTextColor
                        visible: port.contentItem.text === ""
                    }
                }

                QQC2.Label {
                    text: root.form.tcp_first > 0 ? "From " + root.form.tcp_first + " to " + root.form.tcp_last : ""
                    visible: text !== ""
                    font: Kirigami.Theme.smallFont
                    color: Kirigami.Theme.disabledTextColor
                }
            }
        }

        QQC2.DialogButtonBox {
            Layout.fillWidth: true
            standardButtons: QQC2.DialogButtonBox.Ok | QQC2.DialogButtonBox.Cancel
            onAccepted: root.submit()
            onRejected: root.answer(false)
            Component.onCompleted: {
                const ok = standardButton(QQC2.DialogButtonBox.Ok);
                ok.text = "Publish";
                ok.icon.name = "document-share";
                ok.enabled = Qt.binding(() => root.valid);
            }
        }
    }
}
