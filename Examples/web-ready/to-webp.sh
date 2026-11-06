#!/bin/sh
for f in "$@"; do
  name=$(basename "${f%.*}" | sed 's/-1920-clean$//')
  cwebp -quiet -q 82 "$f" -o "$SHAKEN_OUTPUT/$name.webp" || exit 1
done
