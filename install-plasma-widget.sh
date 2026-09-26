#!/bin/bash

# Install script for the Task List Plasma widget

WIDGET_NAME="dhitchenor.plasma.tasklist"
WIDGET_DIR="plasma-widget"

echo "==================================="
echo "Task List widget installation"
echo "==================================="
echo ""

# kpackagetool6 installs into the current user's home, so as root the widget
# lands in /root and never appears in the desktop user's Add Widgets list.
if [ "$(id -u)" -eq 0 ]; then
    echo "❌ Error: don't run this as root (or with sudo)"
    echo "Run it as the user whose desktop should show the widget."
    exit 1
fi

if [ ! -d "$WIDGET_DIR" ]; then
    echo "❌ Error: the $WIDGET_DIR folder does not exist"
    exit 1
fi

if ! command -v kpackagetool6 &> /dev/null; then
    echo "❌ Error: kpackagetool6 is not installed"
    echo "Install it with: sudo pacman -S kpackage (Arch) or sudo apt install kpackagetool6 (Debian/Ubuntu)"
    exit 1
fi

echo "🔍 Checking for an existing installation..."
if kpackagetool6 --type=Plasma/Applet --show="$WIDGET_NAME" &> /dev/null; then
    echo "⚠️  Widget already installed, removing it first..."
    kpackagetool6 --type=Plasma/Applet --remove="$WIDGET_NAME"
fi

echo "📦 Installing the widget..."
kpackagetool6 --type=Plasma/Applet --install "$WIDGET_DIR"

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Widget installed successfully!"
    echo ""

    # The Add Widgets list is only built when Plasma starts.
    echo "🔄 Restarting Plasma so the widget appears in Add Widgets..."
    if systemctl --user is-active --quiet plasma-plasmashell; then
        systemctl --user restart plasma-plasmashell
    else
        plasmashell --replace &> /dev/null & disown
    fi
    echo ""
    echo "To use it:"
    echo "1. Right-click on the desktop or a panel"
    echo "2. Select 'Add Widgets...'"
    echo "3. Search for 'Task List'"
    echo "4. Drag the widget onto your desktop or panel"
    echo ""
    echo "To uninstall:"
    echo "  kpackagetool6 --type=Plasma/Applet --remove=$WIDGET_NAME"
    echo ""
else
    echo ""
    echo "❌ Installation failed"
    exit 1
fi
