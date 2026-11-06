#!/bin/sh
host=$(printf '%s' "$1" | sed -E 's#^[a-z]+://([^/]+).*#\1#')
url=$(printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g')
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>URL</key><string>%s</string></dict></plist>\n' "$url" > "$SHAKEN_OUTPUT/$host.webloc"
