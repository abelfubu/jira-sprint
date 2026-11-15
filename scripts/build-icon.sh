#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/Assets/AppIcon.svg"
OUTPUT="$ROOT/Assets/AppIcon.icns"

command -v qlmanage >/dev/null 2>&1 || {
  echo "qlmanage is required to rebuild the icon." >&2
  exit 1
}
command -v iconutil >/dev/null 2>&1 || {
  echo "iconutil is required to rebuild the icon." >&2
  exit 1
}

ICONSET=$(mktemp -d "${TMPDIR:-/tmp}/jira-sprint-iconset.XXXXXX")
trap 'rm -rf "$ICONSET"' EXIT INT TERM
mkdir -p "$ICONSET/AppIcon.iconset"

qlmanage -t -s 1024 -o "$ICONSET" "$SOURCE" >/dev/null 2>&1
mv "$ICONSET/AppIcon.svg.png" "$ICONSET/AppIcon.png"

render() {
  sips -z "$2" "$2" "$ICONSET/AppIcon.png" --out "$ICONSET/AppIcon.iconset/$1" >/dev/null
}

render icon_16x16.png 16
render icon_16x16@2x.png 32
render icon_32x32.png 32
render icon_32x32@2x.png 64
render icon_128x128.png 128
render icon_128x128@2x.png 256
render icon_256x256.png 256
render icon_256x256@2x.png 512
render icon_512x512.png 512
render icon_512x512@2x.png 1024

iconutil -c icns "$ICONSET/AppIcon.iconset" -o "$OUTPUT"
cp "$ICONSET/AppIcon.png" "$ROOT/Assets/AppIcon.png"
printf '%s\n' "$OUTPUT"
