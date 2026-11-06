#!/bin/bash
# Builds build/Shaken.app (universal) without opening Xcode.
#   VERSION=0.1.0 scripts/build-app.sh
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/build-app.sh   # signed for notarization
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
VERSION="${VERSION:-0.2.1}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP=build/Shaken.app

ARCHS=(--arch arm64 --arch x86_64)
if ! swift build -c release "${ARCHS[@]}" >/dev/null 2>&1; then
  echo "universal build unavailable, building for this Mac only"
  ARCHS=()
  swift build -c release
fi
BIN_DIR=$(swift build -c release "${ARCHS[@]}" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Shaken" "$APP/Contents/MacOS/Shaken"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp -R Examples "$APP/Contents/Resources/Examples"
cp -R Resources/Glyphs "$APP/Contents/Resources/Glyphs"
cp Resources/ShakenMenuBarTemplate.pdf "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" && \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"

# English only: keys in the source are the English text.
mkdir -p "$APP/Contents/Resources/en.lproj"
printf '' > "$APP/Contents/Resources/en.lproj/Localizable.strings"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"   # ad-hoc: runs locally, Gatekeeper will warn elsewhere
fi
codesign --verify --strict "$APP"
echo "built $APP ($VERSION)"
