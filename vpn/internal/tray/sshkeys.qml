// The Authorized SSH Keys dialog on Plasma, run with Qt's qml tool. The last
// command line argument is the form as JSON (sshKeysForm); the answer, the
// lines to remove and keys to add, is logged as "FOXDEN-RESULT <json>".
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

QQC2.ApplicationWindow {
    id: root

    readonly property var form: JSON.parse(Qt.application.arguments[Qt.application.arguments.length - 1])
    readonly property bool readOnly: form.read_only !== ""
    // Pending changes: authorized_keys lines to remove, and keys to add
    // (with what is known about them, for showing).
    property var removed: form.remove || []
    property var added: (form.add || []).map(text => ({
                text: text,
                fingerprint: ""
            }))
    readonly property bool changed: removed.length > 0 || added.length > 0
    property bool answered: false

    function answer(ok) {
        if (answered)
            return;
        answered = true;
        console.log("FOXDEN-RESULT " + JSON.stringify({
            ok: ok,
            remove: removed,
            add: added.map(a => a.text)
        }));
        Qt.quit();
    }

    function isRemoved(line) {
        return removed.indexOf(line) >= 0;
    }

    function toggleRemoved(line) {
        removed = isRemoved(line) ? removed.filter(l => l !== line) : removed.concat([line]);
    }

    // present reports whether a key is authorized after the pending changes.
    function present(fingerprint) {
        if (fingerprint === "")
            return false;
        for (const l of form.local)
            if (l.fingerprint === fingerprint && !isRemoved(l.line))
                return true;
        return added.some(a => a.fingerprint === fingerprint);
    }

    function add(row) {
        if (!present(row.fingerprint))
            added = added.concat([{
                    text: row.text,
                    fingerprint: row.fingerprint,
                    tag: row.tag || "",
                    type: row.type,
                    comment: row.comment
                }]);
    }

    function addPasted() {
        const text = paste.text.trim();
        if (text === "")
            return;
        added = added.concat([{
                text: text,
                fingerprint: ""
            }]);
        paste.text = "";
    }

    function describe(row) {
        return [row.type, row.fingerprint].filter(s => s).join(" · ");
    }

    title: form.title
    visible: true
    minimumWidth: Kirigami.Units.gridUnit * 34
    minimumHeight: Kirigami.Units.gridUnit * 20
    width: Kirigami.Units.gridUnit * 46
    height: Math.min(Kirigami.Units.gridUnit * 40, content.implicitHeight + buttons.implicitHeight + 4 * Kirigami.Units.largeSpacing)
    onClosing: answer(false)
    Component.onCompleted: {
        Qt.application.displayName = "FoxDen VPN";
        requestActivate();
    }

    Shortcut {
        sequences: [StandardKey.Cancel]
        onActivated: root.answer(false)
    }

    // One key: what it is, and a button.
    component KeyRow: RowLayout {
        id: keyRow

        property string heading
        property string detail
        property var badges: []
        property bool struck: false
        property alias action: button.text
        property alias actionIcon: button.icon.name
        property alias actionEnabled: button.enabled
        property string actionTip
        signal activated

        Layout.fillWidth: true
        spacing: Kirigami.Units.largeSpacing

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            opacity: keyRow.struck ? 0.5 : 1

            QQC2.Label {
                Layout.fillWidth: true
                text: keyRow.heading
                font.bold: true
                font.strikeout: keyRow.struck
                elide: Text.ElideRight
            }

            QQC2.Label {
                Layout.fillWidth: true
                text: keyRow.detail
                font: Kirigami.Theme.smallFont
                color: Kirigami.Theme.disabledTextColor
                elide: Text.ElideMiddle
            }
        }

        // Centred on the row, like the button next to them.
        Repeater {
            model: keyRow.badges

            delegate: QQC2.Label {
                Layout.alignment: Qt.AlignVCenter
                text: modelData
                font: Kirigami.Theme.smallFont
                leftPadding: Kirigami.Units.smallSpacing * 2
                rightPadding: leftPadding
                topPadding: Kirigami.Units.smallSpacing / 2
                bottomPadding: topPadding
                background: Rectangle {
                    radius: height / 2
                    color: Kirigami.ColorUtils.linearInterpolation(Kirigami.Theme.backgroundColor, Kirigami.Theme.textColor, 0.12)
                }
            }
        }

        QQC2.Button {
            id: button

            Layout.alignment: Qt.AlignVCenter
            visible: text !== ""
            onClicked: keyRow.activated()
            QQC2.ToolTip.text: keyRow.actionTip
            QQC2.ToolTip.visible: hovered && keyRow.actionTip !== ""
            QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
        }
    }

    QQC2.ScrollView {
        id: scroll

        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: buttons.top
        anchors.bottomMargin: Kirigami.Units.largeSpacing
        contentWidth: availableWidth
        QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff

        ColumnLayout {
            id: content

            x: Kirigami.Units.largeSpacing
            y: Kirigami.Units.largeSpacing
            width: scroll.availableWidth - 2 * Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.largeSpacing

            QQC2.Label {
                Layout.fillWidth: true
                text: root.form.message
                wrapMode: Text.Wrap
            }

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                type: Kirigami.MessageType.Error
                text: root.form.error
                visible: text !== ""
            }

            Kirigami.Heading {
                Layout.topMargin: Kirigami.Units.largeSpacing
                level: 3
                text: "This Machine"
            }

            QQC2.Label {
                Layout.fillWidth: true
                text: root.form.path
                font: Kirigami.Theme.smallFont
                color: Kirigami.Theme.disabledTextColor
                elide: Text.ElideMiddle
            }

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                type: Kirigami.MessageType.Warning
                text: root.form.read_only
                visible: root.readOnly
            }

            QQC2.Label {
                text: "No keys may log in here yet."
                visible: root.form.local.length === 0 && root.added.length === 0
                color: Kirigami.Theme.disabledTextColor
            }

            Repeater {
                model: root.form.local

                delegate: KeyRow {
                    readonly property bool gone: root.isRemoved(modelData.line)

                    heading: modelData.invalid ? "Line " + modelData.line + " is not a key" : (modelData.comment || modelData.type)
                    detail: modelData.invalid ? modelData.invalid + ": " + modelData.text : root.describe(modelData)
                    badges: [modelData.options ? "with options" : "", modelData.also === "kanidm" ? "also in Kanidm" : "", gone ? "removed" : ""].filter(s => s)
                    struck: gone
                    action: root.readOnly ? "" : gone ? "Keep" : "Remove"
                    actionIcon: gone ? "edit-undo" : "list-remove"
                    actionTip: modelData.options ? modelData.options : ""
                    onActivated: root.toggleRemoved(modelData.line)
                }
            }

            Repeater {
                model: root.added

                delegate: KeyRow {
                    heading: modelData.comment || modelData.tag || modelData.type || modelData.text
                    detail: modelData.fingerprint ? root.describe(modelData) : "Checked when saving"
                    badges: ["new"]
                    action: "Remove"
                    actionIcon: "list-remove"
                    onActivated: root.added = root.added.filter((_, i) => i !== index)
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: !root.readOnly

                QQC2.TextField {
                    id: paste

                    Layout.fillWidth: true
                    placeholderText: "Paste a public key: ssh-ed25519 AAAA… comment"
                    font.family: "monospace"
                    onAccepted: root.addPasted()
                }

                QQC2.Button {
                    text: "Add"
                    icon.name: "list-add"
                    enabled: paste.text.trim() !== ""
                    onClicked: root.addPasted()
                }
            }

            Kirigami.Heading {
                Layout.topMargin: Kirigami.Units.largeSpacing
                level: 3
                text: root.form.kanidm_user ? "Kanidm (" + root.form.kanidm_user + ")" : "Kanidm"
            }

            QQC2.Label {
                Layout.fillWidth: true
                text: "Accepted by the FoxDen servers. Read only here: add or remove them in Kanidm."
                font: Kirigami.Theme.smallFont
                color: Kirigami.Theme.disabledTextColor
                wrapMode: Text.Wrap
            }

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                type: root.form.kanidm_user ? Kirigami.MessageType.Warning : Kirigami.MessageType.Information
                text: root.form.kanidm_error
                visible: text !== ""
            }

            QQC2.Label {
                text: "You have no SSH keys in Kanidm."
                visible: root.form.kanidm.length === 0 && root.form.kanidm_error === ""
                color: Kirigami.Theme.disabledTextColor
            }

            Repeater {
                model: root.form.kanidm

                delegate: KeyRow {
                    readonly property bool here: root.present(modelData.fingerprint)

                    heading: modelData.tag || modelData.comment || modelData.type
                    detail: [modelData.tag && modelData.comment ? modelData.comment : "", root.describe(modelData)].filter(s => s).join(" · ")
                    badges: here ? ["authorized here"] : []
                    action: root.readOnly ? "" : "Add Here"
                    actionIcon: "list-add"
                    actionEnabled: !here
                    onActivated: root.add(modelData)
                }
            }

            Kirigami.Heading {
                Layout.topMargin: Kirigami.Units.largeSpacing
                level: 3
                text: "Your Keys"
                visible: root.form.own.length > 0
            }

            QQC2.Label {
                Layout.fillWidth: true
                text: "The public keys in ~/.ssh."
                font: Kirigami.Theme.smallFont
                color: Kirigami.Theme.disabledTextColor
                visible: root.form.own.length > 0
            }

            Repeater {
                model: root.form.own

                delegate: KeyRow {
                    readonly property bool here: root.present(modelData.fingerprint)

                    heading: modelData.comment
                    detail: modelData.tag + " · " + root.describe(modelData)
                    badges: here ? ["authorized here"] : []
                    action: root.readOnly ? "" : "Add Here"
                    actionIcon: "list-add"
                    actionEnabled: !here
                    onActivated: root.add(modelData)
                }
            }
        }
    }

    QQC2.DialogButtonBox {
        id: buttons

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Kirigami.Units.largeSpacing
        standardButtons: root.readOnly ? QQC2.DialogButtonBox.Close : QQC2.DialogButtonBox.Save | QQC2.DialogButtonBox.Cancel
        onAccepted: root.answer(true)
        onRejected: root.answer(false)
        Component.onCompleted: {
            const save = standardButton(QQC2.DialogButtonBox.Save);
            if (save)
                save.enabled = Qt.binding(() => root.changed);
        }
    }
}
