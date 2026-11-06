#!/bin/bash
# Drives the real app through its main flows (see Sources/Shaken/SmokeTest.swift) with a throwaway
# settings folder, and prints PASS or FAIL per check. Run it before a release.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build >/dev/null
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
SHAKEN_SMOKE=1 SHAKEN_SUPPORT_DIR="$DIR" .build/debug/Shaken
