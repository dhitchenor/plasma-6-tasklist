import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import "caldav.js" as CalDAV

KCM.SimpleKCM {
    id: page

    property alias cfg_serverUrl: serverField.text
    property alias cfg_username: usernameField.text
    property alias cfg_password: passwordField.text
    // JSON array of { url, name, color }; see main.qml
    property string cfg_lists
    property string cfg_defaultList
    property alias cfg_syncIntervalMinutes: intervalSpin.value

    // Lists found on the server by the last discovery
    property var lists: []
    readonly property var selected: parseLists(cfg_lists)
    // Found lists not yet added, for the dropdown
    readonly property var addableLists: lists.filter(function(l) { return !findList(selected, l.url) })
    property bool discovering: false
    property string discoveryError: ""
    property bool discovered: false

    // Guards against a slow earlier discovery overwriting a newer one's result
    property int discoveryRequest: 0

    function discover() {
        const request = ++discoveryRequest
        discovering = true
        discoveryError = ""
        CalDAV.discoverTaskLists({
            serverUrl: serverField.text,
            username: usernameField.text.trim(),
            password: passwordField.text
        }, function(error, found) {
            if (request !== discoveryRequest) return
            discovering = false
            discovered = !error
            discoveryError = error || ""
            lists = found || []
            if (lists.length === 1 && selected.length === 0) {
                addSelected(lists[0])
            } else {
                refreshSelectedDetails()
            }
        })
    }

    function parseLists(json) {
        try {
            var parsed = JSON.parse(json || "[]")
            return Array.isArray(parsed) ? parsed : []
        } catch (e) {
            return []
        }
    }

    function findList(array, url) {
        for (var i = 0; i < array.length; i++) {
            if (CalDAV.normalizeHref(array[i].url) === CalDAV.normalizeHref(url)) return array[i]
        }
        return null
    }

    // Chip order is the order lists were added, which also makes the first
    // chip the default target for new tasks.
    function addSelected(list) {
        if (findList(selected, list.url)) return
        cfg_lists = JSON.stringify(selected.concat([{ url: list.url, name: list.name, color: list.color }]))
    }

    function removeSelected(url) {
        var out = selected.filter(function(l) {
            return CalDAV.normalizeHref(l.url) !== CalDAV.normalizeHref(url)
        })
        cfg_lists = JSON.stringify(out)
        if (!findList(out, cfg_defaultList)) cfg_defaultList = ""
    }

    // Picks up lists renamed or recoloured on the server. Only writes when
    // something changed, so opening the page doesn't mark settings as modified.
    function refreshSelectedDetails() {
        var out = selected.map(function(s) {
            var found = findList(lists, s.url)
            return found ? { url: s.url, name: found.name, color: found.color } : s
        })
        var json = JSON.stringify(out)
        if (json !== JSON.stringify(selected)) cfg_lists = json
    }

    Component.onCompleted: {
        if (serverField.text !== "" && usernameField.text !== "") discover()
    }

    Kirigami.FormLayout {
        QQC2.TextField {
            id: serverField
            Kirigami.FormData.label: i18n("Server:")
            placeholderText: "cloud.example.org"
            Layout.fillWidth: true
            onEditingFinished: page.discovered = false
        }

        // Every request carries the password, so over plain http it travels
        // unencrypted. Still allowed, for LAN-only servers without TLS.
        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: /^http:\/\//i.test(serverField.text.trim())
            type: Kirigami.MessageType.Warning
            text: i18n("This address is not encrypted: your password would be sent in plain text. Use https:// unless this server is only on your local network.")
        }

        QQC2.TextField {
            id: usernameField
            Kirigami.FormData.label: i18n("Username:")
            onEditingFinished: page.discovered = false
        }

        Kirigami.PasswordField {
            id: passwordField
            Kirigami.FormData.label: i18n("App password:")
            onEditingFinished: page.discovered = false
        }

        QQC2.Label {
            text: i18n("Stored unencrypted in your Plasma configuration. Use an app password rather than your account password.")
            font: Kirigami.Theme.smallFont
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }

        RowLayout {
            QQC2.Button {
                text: page.discovered ? i18n("Refresh lists") : i18n("Find task lists")
                icon.name: "edit-find"
                enabled: !page.discovering && serverField.text.trim() !== "" && usernameField.text.trim() !== ""
                onClicked: page.discover()
            }
            QQC2.BusyIndicator {
                visible: page.discovering
                Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                Layout.preferredWidth: Kirigami.Units.iconSizes.medium
            }
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: text !== ""
            type: Kirigami.MessageType.Error
            text: page.discoveryError
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: page.discovered && page.lists.length === 0
            type: Kirigami.MessageType.Warning
            text: i18n("The account was found, but it has no calendars that can hold tasks.")
        }

        // Same chip-and-dropdown pattern as the popup's search field
        RowLayout {
            Kirigami.FormData.label: i18n("Task lists:")
            Layout.fillWidth: true
            visible: page.lists.length > 0 || page.selected.length > 0
            spacing: Kirigami.Units.smallSpacing

            // Wraps rather than scrolls: the settings page has room to grow
            QQC2.Frame {
                Layout.fillWidth: true
                Layout.minimumWidth: Kirigami.Units.gridUnit * 14
                padding: Kirigami.Units.smallSpacing

                Flow {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    spacing: Kirigami.Units.smallSpacing

                    Repeater {
                        model: page.selected

                        Kirigami.Chip {
                            // A saved list that discovery ran without finding:
                            // offline, or deleted on the server
                            readonly property bool missing: page.discovered && !page.findList(page.lists, modelData.url)
                            text: missing ? i18n("%1 (not found on the server)", modelData.name || modelData.url)
                                          : (modelData.name || modelData.url)
                            icon.name: missing ? "dialog-warning" : "tag"
                            icon.color: missing ? Kirigami.Theme.neutralTextColor
                                      : (modelData.color || Kirigami.Theme.textColor)
                            checkable: false
                            closable: true
                            onRemoved: page.removeSelected(modelData.url)
                        }
                    }

                    QQC2.Label {
                        visible: page.selected.length === 0
                        height: Kirigami.Units.gridUnit * 1.5
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: Kirigami.Units.smallSpacing
                        text: i18n("No lists: tasks stay on this computer")
                        color: Kirigami.Theme.disabledTextColor
                    }
                }
            }

            QQC2.ComboBox {
                id: addListCombo
                Layout.alignment: Qt.AlignTop
                model: page.addableLists
                enabled: page.addableLists.length > 0
                textRole: "name"
                currentIndex: -1
                displayText: i18n("Add list")
                onActivated: function(index) {
                    page.addSelected(page.addableLists[index])
                    currentIndex = -1
                }

                delegate: QQC2.ItemDelegate {
                    width: ListView.view ? ListView.view.width : implicitWidth
                    highlighted: addListCombo.highlightedIndex === index
                    contentItem: RowLayout {
                        spacing: Kirigami.Units.smallSpacing
                        Rectangle {
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small / 2
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small / 2
                            radius: width / 2
                            color: modelData.color || Kirigami.Theme.disabledTextColor
                        }
                        QQC2.Label {
                            Layout.fillWidth: true
                            text: modelData.name
                            elide: Text.ElideRight
                        }
                    }
                }
            }
        }

        QQC2.ComboBox {
            id: defaultCombo
            Kirigami.FormData.label: i18n("New tasks in \"All lists\" go to:")
            Layout.fillWidth: true
            visible: page.selected.length > 1
            model: page.selected
            textRole: "name"
            currentIndex: {
                for (var i = 0; i < page.selected.length; i++) {
                    if (page.selected[i].url === page.cfg_defaultList) return i
                }
                return 0
            }
            onActivated: function(index) { page.cfg_defaultList = page.selected[index].url }
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.SpinBox {
            id: intervalSpin
            Kirigami.FormData.label: i18n("Sync every:")
            from: 1
            to: 1440
            textFromValue: function(value) { return i18np("%1 minute", "%1 minutes", value) }
            valueFromText: function(text) { return parseInt(text, 10) }
        }
    }
}
