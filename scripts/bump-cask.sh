#!/bin/bash
# Points the Homebrew cask at a release: sets `version` and `sha256` in
# ../homebrew-nox/Casks/shaken.rb (or $CASK) from build/Shaken-<version>.dmg, checks the
# DMG matches the one on the GitHub release, then commits only the cask.
#   scripts/bump-cask.sh            # version from build/Shaken.app
#   scripts/bump-cask.sh 0.1.1      # a given version
# Push the tap yourself afterwards: git -C ../homebrew-nox push
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Shaken.app/Contents/Info.plist)}"
DMG="build/Shaken-$VERSION.dmg"
CASK="${CASK:-../homebrew-nox/Casks/shaken.rb}"
[ -f "$DMG" ] || { echo "No $DMG. Run scripts/make-dmg.sh first."; exit 1; }
[ -f "$CASK" ] || { echo "No cask at $CASK (set CASK=…)."; exit 1; }
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)

# The cask downloads from the release, so the uploaded DMG has to be this exact file.
if command -v gh >/dev/null; then
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  if gh release download "v$VERSION" -R noxhsxrk/shaken -p "Shaken-$VERSION.dmg" -D "$TMP" 2>/dev/null; then
    REMOTE=$(shasum -a 256 "$TMP/Shaken-$VERSION.dmg" | cut -d' ' -f1)
    [ "$REMOTE" = "$SHA" ] || { echo "The DMG on release v$VERSION ($REMOTE) isn't $DMG ($SHA)."; exit 1; }
  else
    echo "Release v$VERSION has no Shaken-$VERSION.dmg yet. Publish the release first."; exit 1
  fi
fi

sed -i '' -E "s/^  version \"[^\"]*\"/  version \"$VERSION\"/; s/^  sha256 \"[0-9a-f]*\"/  sha256 \"$SHA\"/" "$CASK"
grep -q "version \"$VERSION\"" "$CASK" && grep -q "sha256 \"$SHA\"" "$CASK" || { echo "Couldn't update $CASK"; exit 1; }
TAP=$(cd "$(dirname "$CASK")/.." && pwd)
REL="Casks/$(basename "$CASK")"
if git -C "$TAP" diff --quiet -- "$REL"; then
  echo "Cask already at $VERSION ($SHA)."
else
  # Commit only the cask, whatever else is staged in the tap.
  git -C "$TAP" commit -q -m "chore: shaken $VERSION" -- "$REL"
  echo "Cask set to $VERSION ($SHA) and committed in $TAP. Push it: git -C $TAP push"
fi
