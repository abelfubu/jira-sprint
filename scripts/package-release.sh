#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=${1:-0.1.0}
if ! printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Expected a semantic version such as 0.1.0" >&2
  exit 1
fi

APP="$ROOT/dist/Jira Sprint.app"
ZIP="$ROOT/dist/Jira-Sprint-$VERSION.zip"
CHECKSUM="$ZIP.sha256"

cd "$ROOT"
APP_VERSION="$VERSION" UNIVERSAL=1 ./scripts/build-app.sh
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
ACTUAL_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")
if [ "$ACTUAL_VERSION" != "$VERSION" ]; then
  echo "Expected app version $VERSION, found $ACTUAL_VERSION" >&2
  exit 1
fi
lipo -info "$APP/Contents/MacOS/JiraSprint" | grep 'arm64' | grep -q 'x86_64'

rm -f "$ZIP" "$CHECKSUM"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$ROOT/dist" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$CHECKSUM")")
printf '%s\n%s\n' "$ZIP" "$CHECKSUM"
