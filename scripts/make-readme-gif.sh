#!/bin/bash
# Renders the README's animations from the real wheel:
#   docs/images/demo.gif        drag a photo, shake, drop on Convert to JPG, drag the result into a form
#   docs/images/wheel-turn.gif  the wheel turning between three wheels
# Frames come from the app's snapshot mode; ffmpeg turns them into a looping GIF.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
command -v ffmpeg >/dev/null || { echo "needs ffmpeg (brew install ffmpeg)"; exit 1; }
swift build >/dev/null
TMP=$(mktemp -d)
SHAKEN_SNAPSHOT_MOTION=1 SHAKEN_SNAPSHOT_FLOW=1 SHAKEN_SNAPSHOT="$TMP" .build/debug/Shaken
ffmpeg -hide_banner -loglevel error -y -framerate 30 -i "$TMP/flow/f%04d.png" \
  -vf "fps=24,scale=640:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  -loop 0 docs/images/demo.gif
ffmpeg -hide_banner -loglevel error -y -framerate 30 -i "$TMP/motion/f%04d.png" \
  -vf "fps=24,scale=440:440:flags=lanczos,split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  -loop 0 docs/images/wheel-turn.gif
rm -rf "$TMP"
echo "wrote docs/images/demo.gif ($(du -h docs/images/demo.gif | cut -f1)) and docs/images/wheel-turn.gif ($(du -h docs/images/wheel-turn.gif | cut -f1))"
