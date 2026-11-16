#!/bin/bash
# Builds "build/Mac Fan.app", with the fan helper (macfan) inside it at
# Contents/Resources/macfan so the app can install or update the daemon itself.
# Set CONFIG=debug for a debug build, or SIGN_IDENTITY to sign with a real
# certificate instead of ad hoc.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="build/Mac Fan.app"

# Prefer a full Xcode toolchain for SwiftUI macro support. The standalone
# Command Line Tools included with macOS beta releases can lack SwiftUIMacros.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    elif [ -d "/Applications/Xcode-beta.app/Contents/Developer" ]; then
        export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
    fi
fi

swift build -c "$CONFIG" --quiet
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

if [ ! -f MacFan.icns ]; then
    swift Scripts/generate-icon.swift
    iconutil -c icns MacFan.iconset -o MacFan.icns
    rm -rf MacFan.iconset
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacFanApp" "$APP/Contents/MacOS/MacFanApp"
cp "$BIN_DIR/macfan" "$APP/Contents/Resources/macfan"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp MacFan.icns "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP"

codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"

echo "Built $APP"
