#!/bin/bash
# Renders docs/images/wheel-turn.gif: the real wheel turning between three wheels.
# Frames come from the app's snapshot mode; ffmpeg turns them into a looping GIF.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
command -v ffmpeg >/dev/null || { echo "needs ffmpeg (brew install ffmpeg)"; exit 1; }
swift build >/dev/null
TMP=$(mktemp -d)
SHAKEN_SNAPSHOT_MOTION=1 SHAKEN_SNAPSHOT="$TMP" .build/debug/Shaken
ffmpeg -hide_banner -loglevel error -y -framerate 30 -i "$TMP/motion/f%04d.png" \
  -vf "fps=24,scale=440:440:flags=lanczos,split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  -loop 0 docs/images/wheel-turn.gif
rm -rf "$TMP"
echo "wrote docs/images/wheel-turn.gif ($(du -h docs/images/wheel-turn.gif | cut -f1))"
