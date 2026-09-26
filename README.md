# Plasma 6 Tasklist

A simple and elegant task manager widget for KDE Plasma 6, now with CalDAV sync.

Forked from [todo-by-thepiou](https://github.com/miradozk/todo-by-thepiou) by [@miradozk](https://github.com/miradozk), with CalDAV sync added.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Plasma](https://img.shields.io/badge/Plasma-6.0+-blue.svg)

## Features

- **Quick task management** - Add, complete, and delete tasks easily
- **Smart filtering** - View all, active, or completed tasks
- **Badge counter** - Shows number of incomplete tasks on panel icon
- **Synchronized data** - All widget instances share the same task list
- **Date grouping** - Tasks organized by Today, Yesterday, and older dates
- **System integration** - Uses Plasma's native styling and colors

## Screenshots


![Task List Popup](https://raw.githubusercontent.com/dhitchenor/plasma-6-tasklist/main/.github/images/screenshot_1.png)
![Task List Settings](https://raw.githubusercontent.com/dhitchenor/plasma-6-tasklist/main/.github/images/screenshot_2.png)


## Views

The **View** dropdown in the popup chooses how tasks are grouped:

- **By date added**: Today, Yesterday, then weekday and date.
- **By due date**: Overdue, Today, This week, Later, No due date. Completed
  tasks whose due date has passed go under Earlier rather than Overdue.
- **By priority**: High, Medium and Low, following the iCalendar scale
  (1–4 high, 5 medium, 6–9 low), then No priority.
- **By list**: under each list's name.
- **A to Z**: alphabetically, without groups.

Open tasks come before completed ones in every view. Due dates and
priorities are the ones set in other apps such as Nextcloud Tasks or
tasks.org; each task shows its due date, in red when overdue.

## System tray

Besides sitting on a panel or the desktop, the widget can live in the system
tray: right-click the tray's arrow → Configure System Tray → Entries, find
"Task List" and set it to *Shown when relevant* or *Always shown*. With
*Shown when relevant*, the icon appears only while there are unfinished tasks.

The tray copy is its own widget instance, with its own settings and list.

## CalDAV sync

Tasks can be synced with a CalDAV task list (Nextcloud Tasks, Radicale,
Baïkal, and anything else that stores tasks as VTODO), so they show up in
Thunderbird, tasks.org, jtx Board and friends.

Right-click the widget → Configure → Sync:

1. Enter your **server** (just the host, e.g. `cloud.example.org`, is
   usually enough), **username** and an **app password**. The password is
   stored unencrypted in your Plasma configuration, so don't use your main
   account password.
2. Press **Find task lists**, then add the lists you want with **Add list**;
   each appears as a chip, removable with its ✕. Only calendars that can hold
   tasks are offered.

The search field at the top of the popup filters tasks by title. With several
lists added, the **Lists** dropdown next to it adds a list to the search
field as a chip; only tasks from the chipped lists are shown, and with no
chips every list is shown, each task marked with its list's colour. Remove a
chip with its ✕, or with Backspace in the empty field.

New tasks go to the chipped list when exactly one is picked; otherwise to the
list chosen under *New tasks in "All lists" go to*.

Each widget instance has its own lists. An instance with no lists keeps its
tasks on this computer; when you later add a list, those tasks are uploaded to
the first one. Edits made while offline are queued and sent on the next
successful sync; if a task changed on the server in the meantime, the
server's version wins.

On first start the widget imports tasks from the original "To Do" widget
(`thepiou.plasma.todo`) if it was used on this machine. The original's data
is copied, not moved.

## Installation

### Method 1: Using the install script

1. Clone this repository:
```bash
git clone https://github.com/dhitchenor/plasma-6-tasklist.git
cd plasma-6-tasklist
```

2. Run the installation script:
```bash
./install-plasma-widget.sh
```

3. Restart Plasma Shell:
```bash
plasmashell --replace &
```

4. Add the widget to your panel or desktop:
   - Right-click on desktop or panel
   - Select "Add Widgets..."
   - Search for "Task List"
   - Drag and drop to your preferred location

### Method 2: Manual installation

```bash
kpackagetool6 --type=Plasma/Applet --install plasma-widget
plasmashell --replace &
```

## Development

### Quick reload during development

After making changes to the widget:

```bash
./dev-reload.sh
```

This script will:
- Uninstall the current version
- Reinstall the updated widget
- Restart Plasma Shell

### Project structure

```
plasma-6-tasklist/
├── plasma-widget/
│   ├── metadata.json              # Widget metadata
│   └── contents/
│       ├── ui/
│       │   ├── main.qml          # Main UI
│       │   ├── configGeneral.qml # Sync settings page
│       │   ├── storage.js        # Local cache + sync engine
│       │   ├── caldav.js         # CalDAV requests
│       │   └── ical.js           # VTODO parsing/editing
│       └── config/
│           └── main.xml          # Configuration schema
├── install-plasma-widget.sh       # Installation script
├── dev-reload.sh                  # Development reload script
└── README.md
```

## Usage

### Adding a task
- Type your task in the input field
- Press Enter or click the "Ajouter" button

### Managing tasks
- Click the checkbox to mark a task as complete/incomplete
- Click the delete (×) button to remove a task

### Filtering tasks
- **Tout** - Show all tasks
- **Actives** - Show only incomplete tasks
- **Terminées** - Show only completed tasks

## Data Storage

Tasks are stored using QtQuick LocalStorage in:
```
~/.local/share/<app-name>/QML/OfflineStorage/
```

All widget instances (panel and desktop) share the same database, ensuring your tasks are always synchronized.

## Uninstallation

```bash
kpackagetool6 --type=Plasma/Applet --remove=dhitchenor.plasma.tasklist
plasmashell --replace &
```

## Requirements

- KDE Plasma 6.0 or higher
- Qt 6
- kpackagetool6

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](.github/legal/LICENSE) file for details.

## Authors

Maintained by [@dhitchenor](https://github.com/dhitchenor). Original widget by
[@miradozk](https://github.com/miradozk).
