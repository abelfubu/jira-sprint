#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/dist/Jira Sprint.app"
BINARY="$ROOT/.build/release/JiraSprint"

cd "$ROOT"
if [ "${UNIVERSAL:-0}" = "1" ]; then
  swift build -c release --arch arm64 --arch x86_64
else
  swift build -c release
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/JiraSprint"
chmod +x "$APP/Contents/MacOS/JiraSprint"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Jira Sprint</string>
  <key>CFBundleDisplayName</key><string>Jira Sprint</string>
  <key>CFBundleIdentifier</key><string>dev.abelfubu.jira-sprint</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER:-1}</string>
  <key>CFBundleShortVersionString</key><string>${APP_VERSION:-0.1.0}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>JiraSprint</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
printf '%s\n' "$APP"
if [ "${1:-}" = "--open" ]; then open "$APP"; fi
