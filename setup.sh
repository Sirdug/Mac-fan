#!/bin/bash
#
# Mac Fan setup — build, install the root daemon, create the app bundle.
# Run once:  ./setup.sh   (asks for your admin password)
#
# Also disables competing fan daemons (ThermalForge, fancontrold) so only
# Mac Fan talks to the SMC. They stay on disk and can be re-enabled later.
#

set -e
cd "$(dirname "$0")"

if [ "$(uname -m)" != "arm64" ]; then
    echo "Mac Fan requires an Apple Silicon Mac. Run this installer outside Rosetta."
    exit 1
fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 26 ]; then
    echo "Mac Fan requires macOS 26 or newer, including on M1 Pro MacBook Pro."
    exit 1
fi

echo "Building Mac Fan (release)..."
CONFIG=release Scripts/build-app.sh
BUILT="build/Mac Fan.app"

echo "Installing daemon (requires admin password once)..."
pkill -x MacFanApp 2>/dev/null || true
sudo "$BUILT/Contents/Resources/macfan" install

# Copy the app bundle into /Applications. It carries the fan helper and the
# update settings, so later versions arrive through the app's own updater.
sudo rm -rf "/Applications/Mac Fan.app"
sudo ditto "$BUILT" "/Applications/Mac Fan.app"
sudo xattr -cr "/Applications/Mac Fan.app"
# Bundle owned by the user so the in-app updater can replace it without sudo
sudo chown -R "$USER" "/Applications/Mac Fan.app"
sudo mdimport "/Applications/Mac Fan.app" 2>/dev/null || true

echo ""
echo "Mac Fan installed. Starting it now..."
open "/Applications/Mac Fan.app"
echo ""
echo "  - The fan icon with a temperature readout is in your menu bar"
echo "  - Turn on 'Launch at Login' in the dropdown to start it automatically"
echo "  - CLI: macfan status | set <rpm> | setfan <i> <rpm> | auto | max"
