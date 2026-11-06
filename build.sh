#!/bin/bash
# Build build/Shaken.app, quit the copy that's running, and open the new one.
#   ./build.sh            build + relaunch
#   ./build.sh --no-open  build only
set -euo pipefail
cd "$(dirname "$0")"

scripts/build-app.sh

[ "${1:-}" = "--no-open" ] && exit 0

if pgrep -x Shaken >/dev/null; then
  pkill -x Shaken || true
  for _ in $(seq 1 50); do pgrep -x Shaken >/dev/null || break; sleep 0.1; done
  pkill -9 -x Shaken 2>/dev/null || true
fi

open build/Shaken.app
echo "Shaken is running"
