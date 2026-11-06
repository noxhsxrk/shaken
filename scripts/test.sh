#!/bin/sh
# swift-testing needs the full Xcode toolchain; use it when Command Line Tools are selected.
set -e
cd "$(dirname "$0")/.."
if [ -d /Applications/Xcode.app ] && [ -z "$DEVELOPER_DIR" ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
exec swift test "$@"
