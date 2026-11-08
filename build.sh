#!/bin/zsh
# Builds a release binary and wraps it in "Ancient World Map.app" under ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="build/Ancient World Map.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AncientWorldMap "$APP/Contents/MacOS/AncientWorldMap"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
