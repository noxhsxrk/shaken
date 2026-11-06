#!/bin/bash
# Regenerates Resources/AppIcon.icns from the drawing in Sources/Shaken/Logo.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build >/dev/null
TMP=$(mktemp -d)
SHAKEN_ICONSET="$TMP/AppIcon.iconset" .build/debug/Shaken
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
cp "$TMP/AppIcon.iconset/icon_512x512.png" docs/images/app-icon.png
rm -rf "$TMP"
echo "wrote Resources/AppIcon.icns"
