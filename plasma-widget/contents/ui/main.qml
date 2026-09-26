import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "storage.js" as Storage

PlasmoidItem {
    id: root

    width: Kirigami.Units.gridUnit * 25
    height: Kirigami.Units.gridUnit * 35

    // Only on the desktop, to show the icon there instead of the full list;
    // panels use the icon anyway. It must stay unset in the system tray: the
    // tray only shows a widget's popup content when preferredRepresentation
    // is null (PlasmoidPopupsContainer.qml in plasma-workspace).
    preferredRepresentation: Plasmoid.formFactor === PlasmaCore.Types.Planar ? compactRepresentation : null

    property string currentFilter: "all" // all, active, completed

    readonly property string localList: "local:" + Plasmoid.id
    // Lists this instance syncs, as [{ url, name, color }]. Empty means the
    // instance keeps its tasks on this computer (see storage.js).
    readonly property var lists: parseLists(Plasmoid.configuration.lists)
    readonly property bool synced: lists.length > 0

    // Lists picked as chips in the search field; none means all lists.
    // Entries for lists since removed in the settings are dropped.
    readonly property var viewLists: parseUrls(Plasmoid.configuration.viewLists).filter(function(url) {
        return listByUrl(url) !== null
    })
    property string searchText: ""

    // Task dots and the add-target hint only matter when the tasks on screen
    // can come from more than one list.
    readonly property bool mixedView: lists.length > 1 && viewLists.length !== 1

    // Where new tasks go: the single list picked as a chip, otherwise the one
    // chosen in the settings (first list by default).
    readonly property string addTarget: {
        if (!synced) return localList
        if (viewLists.length === 1) return viewLists[0]
        return listByUrl(Plasmoid.configuration.defaultList) ? Plasmoid.configuration.defaultList : lists[0].url
    }

    // Every task in every list this instance shows; `todos` is what the
    // chips and search text leave visible.
    property var allTodos: []
    readonly property var todos: {
        var needle = searchText.trim().toLowerCase()
        return allTodos.filter(function(t) {
            if (viewLists.length > 0 && viewLists.indexOf(t.list) === -1) return false
            return needle === "" || t.title.toLowerCase().indexOf(needle) !== -1
        })
    }

    property int syncsRunning: 0
    readonly property bool syncing: syncsRunning > 0
    property var syncErrors: ({})
    readonly property string syncError: {
        var lines = []
        for (var url in syncErrors) {
            var list = listByUrl(url)
            if (!list) continue
            lines.push(lists.length > 1 ? list.name + ": " + syncErrors[url] : syncErrors[url])
        }
        return lines.join("\n")
    }

    toolTipSubText: lists.length === 1 ? lists[0].name : lists.length > 1 ? i18np("%1 list", "%1 lists", lists.length) : ""

    // Counts every list, not just the one on screen: the badge and the tray
    // status should reflect all outstanding work.
    readonly property int incompleteCount: {
        var count = 0
        for (var i = 0; i < allTodos.length; i++) {
            if (!allTodos[i].completed) count++
        }
        return count
    }

    // In the system tray, Active shows the icon and Passive tucks it under the
    // tray's arrow. Users can still pin it either way in the tray settings.
    //
    // Set imperatively, not as a binding: Plasma's popup wrapper assigns
    // Plasmoid.status itself (RequiresAttention while open, the old value on
    // close), which would silently destroy a binding after the first open.
    // Left alone while expanded so the two don't fight.
    function updateStatus() {
        if (expanded) return
        Plasmoid.status = incompleteCount > 0 ? PlasmaCore.Types.ActiveStatus : PlasmaCore.Types.PassiveStatus
    }
    onIncompleteCountChanged: updateStatus()

    function parseLists(json) {
        try {
            var parsed = JSON.parse(json || "[]")
            return Array.isArray(parsed) ? parsed.filter(function(l) { return l && typeof l.url === "string" && l.url !== "" }) : []
        } catch (e) {
            return []
        }
    }

    function parseUrls(json) {
        try {
            var parsed = JSON.parse(json || "[]")
            return Array.isArray(parsed) ? parsed.filter(function(u) { return typeof u === "string" }) : []
        } catch (e) {
            return []
        }
    }

    function setViewLists(urls) {
        Plasmoid.configuration.viewLists = JSON.stringify(urls)
    }

    function addViewList(url) {
        if (viewLists.indexOf(url) === -1) setViewLists(viewLists.concat([url]))
    }

    function removeViewList(url) {
        setViewLists(viewLists.filter(function(u) { return u !== url }))
    }

    function listByUrl(url) {
        for (var i = 0; i < lists.length; i++) {
            if (lists[i].url === url) return lists[i]
        }
        return null
    }

    onListsChanged: {
        if (synced) Storage.adoptLocalTasks(localList, addTarget)
        loadTodos()
    }

    Component.onCompleted: {
        // Settings from before multiple lists stored a single list in
        // listUrl/listName/listColor.
        if (Plasmoid.configuration.lists === "" && Plasmoid.configuration.listUrl !== "") {
            Plasmoid.configuration.lists = JSON.stringify([{
                url: Plasmoid.configuration.listUrl,
                name: Plasmoid.configuration.listName,
                color: Plasmoid.configuration.listColor
            }])
            Plasmoid.configuration.listUrl = ""
        }
        Storage.initDatabase(localList)
        loadTodos()
        updateStatus()
    }

    // Picks up changes made by other widget instances or by a sync they ran
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: root.loadTodos()
    }

    Timer {
        interval: Math.max(1, Plasmoid.configuration.syncIntervalMinutes) * 60000
        running: root.synced
        repeat: true
        triggeredOnStart: true
        onTriggered: root.syncNow()
    }

    // Batches rapid edits (ticking off several tasks) into one sync
    Timer {
        id: pushDebounce
        interval: 1500
        onTriggered: root.syncNow()
    }

    Connections {
        target: Plasmoid.configuration
        function onValueChanged(key, value) {
            if (key === "lists" || key === "username" || key === "password") pushDebounce.restart()
        }
    }

    onExpandedChanged: {
        if (root.expanded) root.syncNow()
        else root.updateStatus()
    }

    function syncNow() {
        if (!synced) {
            syncErrors = {}
            return
        }
        Storage.adoptLocalTasks(localList, addTarget)
        lists.forEach(function(list) {
            const cfg = {
                listUrl: list.url,
                username: Plasmoid.configuration.username.trim(),
                password: Plasmoid.configuration.password
            }
            // Counted before starting: an immediate failure calls back synchronously
            syncsRunning++
            const started = Storage.sync(cfg, function(error) {
                syncsRunning--
                const next = Object.assign({}, syncErrors)
                if (error) next[cfg.listUrl] = error
                else delete next[cfg.listUrl]
                syncErrors = next
                loadTodos()
            })
            if (!started) syncsRunning--
        })
    }

    function loadTodos() {
        var sources = synced ? lists.map(function(l) { return l.url }) : [localList]
        var out = []
        for (var i = 0; i < sources.length; i++) out = out.concat(Storage.getAllTodos(sources[i]))
        // Same order storage uses within one list, applied across lists
        out.sort(function(a, b) {
            if (a.completed !== b.completed) return a.completed ? 1 : -1
            return a.created_at < b.created_at ? 1 : a.created_at > b.created_at ? -1 : 0
        })
        allTodos = out
    }

    function addTodo(text) {
        if (text.trim() === "") return
        Storage.addTodo(addTarget, text.trim())
        loadTodos()
        pushDebounce.restart()
    }

    function toggleTodo(list, id) {
        Storage.toggleTodo(list, id)
        loadTodos()
        pushDebounce.restart()
    }

    function deleteTodo(list, id) {
        Storage.deleteTodo(list, id)
        loadTodos()
        pushDebounce.restart()
    }

    function escapeHtml(text) {
        return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
    }

    // Titles come from the server (possibly a shared list) and are shown as
    // rich text, so everything is escaped; otherwise markup such as <img>
    // would render and load. URLs are found in the raw title before escaping,
    // because the URL pattern allows & and ; and would swallow entities.
    function renderTitle(title) {
        var pattern = /\b(?:https?|ftp):\/\/[-A-Z0-9+&@#\/%?=~_|!:,.;]*[-A-Z0-9+&@#\/%=~_|]/gi
        var out = ""
        var last = 0
        var match
        while ((match = pattern.exec(title)) !== null) {
            var url = escapeHtml(match[0])
            out += escapeHtml(title.slice(last, match.index)) + '<a href="' + url + '">' + url + '</a>'
            last = match.index + match[0].length
        }
        return out + escapeHtml(title.slice(last))
    }

    // Whole days from the given date to today, by local calendar day:
    // 1 is yesterday, -1 is tomorrow.
    function daysBefore(dateString) {
        const today = new Date()
        today.setHours(0, 0, 0, 0)
        const day = new Date(dateString)
        day.setHours(0, 0, 0, 0)
        // Rounded, not floored: across a DST change the gap between two local
        // midnights is 23 or 25 hours, and flooring 23h would call yesterday
        // "Today".
        return Math.round((today - day) / (1000 * 60 * 60 * 24))
    }

    function getDateLabel(dateString) {
        const todoDate = new Date(dateString)
        const today = new Date()
        const diffDays = daysBefore(dateString)

        if (diffDays === 0) return i18n("Today")
        if (diffDays === 1) return i18n("Yesterday")
        if (diffDays > 1 && diffDays < 7) return Qt.locale().standaloneDayName(todoDate.getDay(), Locale.LongFormat)

        const format = todoDate.getFullYear() === today.getFullYear() ? "d MMMM" : "d MMMM yyyy"
        return todoDate.toLocaleDateString(Qt.locale(), format)
    }

    function getFilteredTodos() {
        var filtered = []
        for (var i = 0; i < todos.length; i++) {
            var todo = todos[i]
            if (currentFilter === "all") {
                filtered.push(todo)
            } else if (currentFilter === "active" && !todo.completed) {
                filtered.push(todo)
            } else if (currentFilter === "completed" && todo.completed) {
                filtered.push(todo)
            }
        }
        return filtered
    }

    function getTodoCount(filter) {
        var count = 0
        for (var i = 0; i < todos.length; i++) {
            if (filter === "all") {
                count++
            } else if (filter === "active" && !todos[i].completed) {
                count++
            } else if (filter === "completed" && todos[i].completed) {
                count++
            }
        }
        return count
    }

    readonly property string groupBy: Plasmoid.configuration.groupBy || "created"

    function chainCompare() {
        var compares = arguments
        return function(a, b) {
            for (var i = 0; i < compares.length; i++) {
                var result = compares[i](a, b)
                if (result !== 0) return result
            }
            return 0
        }
    }
    function openFirst(a, b) { return a.completed === b.completed ? 0 : (a.completed ? 1 : -1) }
    function newestFirst(a, b) { return a.created_at < b.created_at ? 1 : a.created_at > b.created_at ? -1 : 0 }
    function earliestDueFirst(a, b) {
        if (a.due === b.due) return 0
        if (!a.due) return 1
        if (!b.due) return -1
        return a.due < b.due ? -1 : 1
    }

    // RFC 5545 §3.8.1.9 maps 1-4 to high, 5 to medium and 6-9 to low
    function priorityGroup(todo) {
        if (todo.priority >= 1 && todo.priority <= 4) return 0
        if (todo.priority === 5) return 1
        if (todo.priority >= 6) return 2
        return 3
    }

    // A completed task whose due date has passed isn't overdue; it gets its
    // own group at the end instead of cluttering "Overdue".
    function dueGroup(todo) {
        if (!todo.due) return 4
        var daysLeft = -daysBefore(todo.due)
        if (daysLeft < 0) return todo.completed ? 5 : 0
        if (daysLeft === 0) return 1
        if (daysLeft < 7) return 2
        return 3
    }

    function isOverdue(todo) {
        return !todo.completed && !!todo.due && daysBefore(todo.due) > 0
    }

    function dueText(todo) {
        if (!todo.due) return ""
        var daysLeft = -daysBefore(todo.due)
        if (daysLeft === 0) return i18n("Due today")
        if (daysLeft === 1) return i18n("Due tomorrow")
        if (daysLeft === -1) return i18n("Due yesterday")
        var date = new Date(todo.due)
        var format = date.getFullYear() === new Date().getFullYear() ? "d MMM" : "d MMM yyyy"
        return i18n("Due %1", date.toLocaleDateString(Qt.locale(), format))
    }

    // The visible tasks as ordered groups, [{ label, items }]; an empty label
    // means no heading.
    function groupTodos() {
        var todos = getFilteredTodos().slice()
        var groups = []

        function bucket(labels, groupOf, compare) {
            todos.sort(compare)
            var buckets = labels.map(function() { return [] })
            todos.forEach(function(todo) { buckets[groupOf(todo)].push(todo) })
            labels.forEach(function(label, i) {
                if (buckets[i].length > 0) groups.push({ label: label, items: buckets[i] })
            })
        }

        if (groupBy === "due") {
            bucket([i18n("Overdue"), i18n("Today"), i18n("This week"), i18n("Later"), i18n("No due date"), i18n("Earlier")],
                dueGroup, chainCompare(openFirst, earliestDueFirst, newestFirst))
        } else if (groupBy === "priority") {
            bucket([i18n("High priority"), i18n("Medium priority"), i18n("Low priority"), i18n("No priority")],
                priorityGroup, chainCompare(openFirst, earliestDueFirst, newestFirst))
        } else if (groupBy === "list") {
            var urls = synced ? lists.map(function(l) { return l.url }) : [localList]
            var names = synced ? lists.map(function(l) { return l.name }) : [i18n("On this computer")]
            bucket(names, function(todo) { return Math.max(0, urls.indexOf(todo.list)) },
                chainCompare(openFirst, newestFirst))
        } else if (groupBy === "alpha") {
            todos.sort(chainCompare(openFirst, function(a, b) { return a.title.localeCompare(b.title) }))
            groups.push({ label: "", items: todos })
        } else {
            // By date added: groups appear in the order their newest task does
            todos.sort(chainCompare(openFirst, newestFirst))
            var index = {}
            todos.forEach(function(todo) {
                var label = getDateLabel(todo.created_at)
                if (!(label in index)) {
                    index[label] = groups.length
                    groups.push({ label: label, items: [] })
                }
                groups[index[label]].items.push(todo)
            })
        }
        return groups
    }

    // Compact representation (for panel)
    compactRepresentation: Item {
        Layout.preferredWidth: Kirigami.Units.iconSizes.medium
        Layout.preferredHeight: Kirigami.Units.iconSizes.medium

        Kirigami.Icon {
            id: icon
            anchors.fill: parent
            source: "view-list-details"
            active: mouseArea.containsMouse

            // Badge showing number of incomplete todos
            Rectangle {
                visible: root.incompleteCount > 0
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.rightMargin: -4
                anchors.topMargin: -4
                width: Math.max(16, badgeText.width + 6)
                height: 16
                radius: 8
                color: Kirigami.Theme.highlightColor

                QQC2.Label {
                    id: badgeText
                    anchors.centerIn: parent
                    text: root.incompleteCount > 99 ? "99+" : root.incompleteCount.toString()
                    color: "white"
                    font.pixelSize: 10
                    font.bold: true
                }
            }
        }

        MouseArea {
            id: mouseArea
            anchors.fill: parent
            hoverEnabled: true
            onClicked: root.expanded = !root.expanded
        }
    }

    fullRepresentation: ColumnLayout {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 20
        Layout.minimumHeight: Kirigami.Units.gridUnit * 25
        Layout.preferredWidth: Kirigami.Units.gridUnit * 25
        Layout.preferredHeight: Kirigami.Units.gridUnit * 35
        spacing: 0

        // Header
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: headerColumn.implicitHeight + Kirigami.Units.largeSpacing * 2
            color: Kirigami.Theme.backgroundColor

            ColumnLayout {
                id: headerColumn
                anchors.fill: parent
                anchors.margins: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing

                // Search field holding the picked lists as chips, plus the
                // dropdown that adds them
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    QQC2.TextField {
                        id: searchField
                        Layout.fillWidth: true
                        placeholderText: root.viewLists.length > 0 || root.lists.length < 2
                            ? i18n("Search tasks…") : i18n("Search all lists…")
                        leftPadding: chipFlick.width > 0
                            ? chipFlick.width + Kirigami.Units.smallSpacing * 2
                            : Kirigami.Units.largeSpacing
                        onTextChanged: root.searchText = text

                        // Backspace in an empty field removes the last chip,
                        // as in other token inputs.
                        Keys.onPressed: function(event) {
                            if (event.key === Qt.Key_Backspace && text === "" && root.viewLists.length > 0) {
                                root.removeViewList(root.viewLists[root.viewLists.length - 1])
                                event.accepted = true
                            } else if (event.key === Qt.Key_Escape && text !== "") {
                                text = ""
                                event.accepted = true
                            }
                        }

                        // Capped at 60% of the field and scrollable, so many
                        // chips never squeeze out the text being typed.
                        Flickable {
                            id: chipFlick
                            anchors.left: parent.left
                            anchors.leftMargin: Kirigami.Units.smallSpacing
                            anchors.verticalCenter: parent.verticalCenter
                            width: root.viewLists.length > 0 ? Math.min(chipRow.implicitWidth, parent.width * 0.6) : 0
                            height: chipRow.implicitHeight
                            contentWidth: chipRow.implicitWidth
                            flickableDirection: Flickable.HorizontalFlick
                            clip: true

                            Row {
                                id: chipRow
                                spacing: Kirigami.Units.smallSpacing

                                Repeater {
                                    model: root.viewLists

                                    Kirigami.Chip {
                                        readonly property var list: root.listByUrl(modelData)
                                        text: list ? list.name : modelData
                                        icon.name: "tag"
                                        icon.color: list && list.color ? list.color : Kirigami.Theme.textColor
                                        checkable: false
                                        closable: true
                                        onRemoved: root.removeViewList(modelData)
                                    }
                                }
                            }
                        }
                    }

                    QQC2.ComboBox {
                        id: listPicker
                        visible: root.lists.length > 1
                        // Lists not already in the search field
                        model: root.lists.filter(function(l) { return root.viewLists.indexOf(l.url) === -1 })
                        enabled: model.length > 0
                        textRole: "name"
                        currentIndex: -1
                        displayText: i18n("Lists")
                        onActivated: function(index) {
                            root.addViewList(model[index].url)
                            currentIndex = -1
                        }

                        delegate: QQC2.ItemDelegate {
                            width: ListView.view ? ListView.view.width : implicitWidth
                            highlighted: listPicker.highlightedIndex === index
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

                // Input field with Add button
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    QQC2.TextField {
                        id: inputField
                        Layout.fillWidth: true
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 2.5
                        placeholderText: root.mixedView
                            ? i18n("Add a task to %1…", root.listByUrl(root.addTarget).name)
                            : i18n("Add a task…")
                        leftPadding: Kirigami.Units.largeSpacing
                        rightPadding: Kirigami.Units.largeSpacing

                        Keys.onReturnPressed: {
                            root.addTodo(text)
                            text = ""
                        }
                    }

                    QQC2.Button {
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 2.5
                        text: i18n("Add")
                        icon.name: "list-add"
                        highlighted: true
                        leftPadding: Kirigami.Units.largeSpacing * 1.5
                        rightPadding: Kirigami.Units.largeSpacing * 1.5
                        onClicked: {
                            root.addTodo(inputField.text)
                            inputField.text = ""
                        }
                    }
                }

                // Filters
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    QQC2.Button {
                        text: i18n("All %1", root.getTodoCount("all"))
                        checkable: true
                        checked: root.currentFilter === "all"
                        flat: !checked
                        onClicked: root.currentFilter = "all"
                    }

                    QQC2.Button {
                        text: i18n("Active %1", root.getTodoCount("active"))
                        checkable: true
                        checked: root.currentFilter === "active"
                        flat: !checked
                        onClicked: root.currentFilter = "active"
                    }

                    QQC2.Button {
                        text: i18n("Completed %1", root.getTodoCount("completed"))
                        checkable: true
                        checked: root.currentFilter === "completed"
                        flat: !checked
                        onClicked: root.currentFilter = "completed"
                    }

                    Item { Layout.fillWidth: true }

                    QQC2.ComboBox {
                        id: viewPicker
                        model: [
                            { key: "created", name: i18n("By date added") },
                            { key: "due", name: i18n("By due date") },
                            { key: "priority", name: i18n("By priority") },
                            { key: "list", name: i18n("By list") },
                            { key: "alpha", name: i18n("A to Z") }
                        ]
                        textRole: "name"
                        currentIndex: {
                            for (var i = 0; i < model.length; i++) {
                                if (model[i].key === root.groupBy) return i
                            }
                            return 0
                        }
                        onActivated: function(index) { Plasmoid.configuration.groupBy = model[index].key }
                    }

                    PlasmaComponents.BusyIndicator {
                        visible: root.syncing
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                    }

                    PlasmaComponents.ToolButton {
                        visible: root.synced && !root.syncing
                        icon.name: root.syncError !== "" ? "dialog-warning" : "view-refresh"
                        text: i18n("Sync now")
                        display: QQC2.AbstractButton.IconOnly
                        onClicked: root.syncNow()

                        PlasmaComponents.ToolTip {
                            text: root.syncError !== "" ? root.syncError : parent.text
                        }
                    }
                }
            }
        }

        // Separator
        Kirigami.Separator {
            Layout.fillWidth: true
        }

        PlasmaComponents.Label {
            visible: root.syncError !== ""
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            text: root.syncError
            color: Kirigami.Theme.negativeTextColor
            wrapMode: Text.Wrap
            font: Kirigami.Theme.smallFont
        }

        // Todo list
        QQC2.ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ListView {
                id: todoListView
                clip: true
                spacing: 0

                model: {
                    const items = []
                    root.groupTodos().forEach(function(group) {
                        if (group.label !== "") items.push({ type: "header", text: group.label })
                        group.items.forEach(function(todo) { items.push({ type: "todo", data: todo }) })
                    })
                    return items
                }

                delegate: Loader {
                    width: todoListView.width
                    sourceComponent: modelData.type === "header" ? headerComponent : todoComponent

                    property var itemData: modelData
                }
            }
        }
    }

    Component {
        id: headerComponent

        Item {
            height: Kirigami.Units.gridUnit * 2

            Kirigami.Heading {
                level: 4
                text: itemData.text
                color: Kirigami.Theme.disabledTextColor
                anchors.left: parent.left
                anchors.leftMargin: Kirigami.Units.largeSpacing
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    Component {
        id: todoComponent

        PlasmaComponents.ItemDelegate {
            height: Kirigami.Units.gridUnit * 3

            contentItem: RowLayout {
                spacing: Kirigami.Units.largeSpacing

                // Checkbox using system colors
                QQC2.CheckBox {
                    Layout.alignment: Qt.AlignVCenter
                    checked: itemData.data.completed
                    onClicked: root.toggleTodo(itemData.data.list, itemData.data.id)
                }

                // Which list the task is in, when several are shown together
                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small / 2
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small / 2
                    radius: width / 2
                    visible: root.mixedView
                    color: {
                        var list = root.listByUrl(itemData.data.list)
                        return list && list.color ? list.color : Kirigami.Theme.disabledTextColor
                    }
                }

                QQC2.Label {
                    Layout.fillWidth: true
                    text: root.renderTitle(itemData.data.title)
                    textFormat: Text.RichText
                    wrapMode: Text.Wrap
                    font.strikeout: itemData.data.completed
                    color: itemData.data.completed ? Kirigami.Theme.disabledTextColor : Kirigami.Theme.textColor
                    onLinkActivated: function(link) {
                        Qt.openUrlExternally(link)
                    }

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor
                    }
                }

                PlasmaComponents.Label {
                    Layout.alignment: Qt.AlignVCenter
                    visible: text !== ""
                    text: root.dueText(itemData.data)
                    font: Kirigami.Theme.smallFont
                    color: root.isOverdue(itemData.data) ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.disabledTextColor
                }

                // Delete button
                PlasmaComponents.ToolButton {
                    icon.name: "edit-delete"
                    icon.width: Kirigami.Units.iconSizes.small
                    icon.height: Kirigami.Units.iconSizes.small
                    onClicked: root.deleteTodo(itemData.data.list, itemData.data.id)
                }
            }
        }
    }
}
