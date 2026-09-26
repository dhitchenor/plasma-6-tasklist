#!/bin/bash

# Uninstall script for the Task List Plasma widget

WIDGET_NAME="dhitchenor.plasma.tasklist"

echo "==================================="
echo "Task List widget removal"
echo "==================================="
echo ""

if ! command -v kpackagetool6 &> /dev/null; then
    echo "❌ Error: kpackagetool6 is not installed"
    exit 1
fi

echo "🔍 Checking the installation..."
if ! kpackagetool6 --type=Plasma/Applet --show="$WIDGET_NAME" &> /dev/null; then
    echo "⚠️  The widget is not installed"
    exit 0
fi

echo "🗑️  Removing the widget..."
kpackagetool6 --type=Plasma/Applet --remove="$WIDGET_NAME"

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Widget removed successfully!"
    echo ""
else
    echo ""
    echo "❌ Removal failed"
    exit 1
fi
