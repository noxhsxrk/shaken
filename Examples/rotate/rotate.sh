#!/bin/sh
for f in "$@"; do
  base=$(basename "${f%.*}"); ext="${f##*.}"
  sips -r 90 "$f" --out "$SHAKEN_OUTPUT/$base-rotated.$ext" >/dev/null || { echo "sips couldn't rotate $(basename "$f")" >&2; exit 1; }
done
