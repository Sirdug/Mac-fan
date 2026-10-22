#!/bin/bash
#
# Mac Fan uninstall — stops the daemon, resets fans to Apple control,
# removes the CLI and the app bundle.
#

cd "$(dirname "$0")"

pkill -x MacFanApp 2>/dev/null || true

if [ -x /usr/local/bin/macfan ]; then
    sudo /usr/local/bin/macfan uninstall
elif [ -x .build/release/macfan ]; then
    sudo .build/release/macfan uninstall
fi

sudo rm -rf "/Applications/Mac Fan.app"

echo ""
echo "Mac Fan removed. Fans are back under Apple's control."
echo "To re-enable ThermalForge instead:"
echo "  sudo launchctl enable system/com.thermalforge.daemon"
echo "  sudo launchctl bootstrap system /Library/LaunchDaemons/com.thermalforge.daemon.plist"
