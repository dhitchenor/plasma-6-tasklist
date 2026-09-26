#!/bin/bash

# Development script: reinstalls the widget and restarts Plasma

WIDGET_NAME="dhitchenor.plasma.tasklist"
WIDGET_DIR="plasma-widget"

# As root, kpackagetool6 would work on /root's copy of the widget and the
# restart would target root's plasmashell, not the desktop session's.
if [ "$(id -u)" -eq 0 ]; then
    echo "❌ Error: don't run this as root (or with sudo)"
    echo "Run it as the user whose desktop should show the widget."
    exit 1
fi

if [ ! -d "$WIDGET_DIR" ]; then
    echo "❌ Error: the $WIDGET_DIR folder does not exist (run this from the repo root)"
    exit 1
fi

echo "🔄 Updating the widget..."

kpackagetool6 --type=Plasma/Applet --remove="$WIDGET_NAME" &> /dev/null
kpackagetool6 --type=Plasma/Applet --install "$WIDGET_DIR"

if [ $? -eq 0 ]; then
    echo "✅ Widget reinstalled"
    echo "🔄 Restarting Plasma..."

    # Plasma 6 runs plasmashell as a systemd user service; restarting it
    # there stays it supervised, where killall + relaunch would detach it.
    if systemctl --user is-active --quiet plasma-plasmashell; then
        systemctl --user restart plasma-plasmashell
    else
        plasmashell --replace &> /dev/null & disown
    fi

    echo "✅ Done! The widget has been updated."
else
    echo "❌ Reinstall failed"
    exit 1
fi
