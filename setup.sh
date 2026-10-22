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

# Prefer a full Xcode toolchain for SwiftUI macro support. The standalone
# Command Line Tools included with macOS beta releases can lack SwiftUIMacros.
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
elif [ -d "/Applications/Xcode-beta.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
fi

echo "Building Mac Fan (release)..."
swift build -c release --quiet

# App icon
if [ ! -f MacFan.icns ]; then
    echo "Generating app icon..."
    swift Scripts/generate-icon.swift
    iconutil -c icns MacFan.iconset -o MacFan.icns
    rm -rf MacFan.iconset
fi

echo "Installing daemon (requires admin password once)..."
pkill -x MacFanApp 2>/dev/null || true
sudo xattr -cr .build/release/macfan 2>/dev/null || true
sudo .build/release/macfan install

# Create the .app bundle in /Applications
APP_DIR="/Applications/Mac Fan.app/Contents"
sudo mkdir -p "$APP_DIR/MacOS" "$APP_DIR/Resources"
sudo cp .build/release/MacFanApp "$APP_DIR/MacOS/MacFanApp"
sudo cp MacFan.icns "$APP_DIR/Resources/AppIcon.icns"

sudo tee "$APP_DIR/Info.plist" > /dev/null << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Mac Fan</string>
    <key>CFBundleDisplayName</key>
    <string>Mac Fan</string>
    <key>CFBundleIdentifier</key>
    <string>com.macfan.app</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>MacFanApp</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

sudo xattr -cr "/Applications/Mac Fan.app"
# Bundle owned by the user so future app updates don't need sudo
sudo chown -R "$USER" "/Applications/Mac Fan.app"
sudo mdimport "/Applications/Mac Fan.app" 2>/dev/null || true

echo ""
echo "Mac Fan installed. Starting it now..."
open "/Applications/Mac Fan.app"
echo ""
echo "  - The fan icon with a temperature readout is in your menu bar"
echo "  - Turn on 'Launch at Login' in the dropdown to start it automatically"
echo "  - CLI: macfan status | set <rpm> | setfan <i> <rpm> | auto | max"
