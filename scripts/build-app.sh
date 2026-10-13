#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/ScanSlap.app"
ICONSET="$ROOT/build/AppIcon.iconset"

cd "$ROOT"
swift build -c release
rm -rf "$APP" "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONSET"

swift "$ROOT/scripts/make-icon.swift" "$ROOT/build/AppIcon-1024.png"
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    pixels="${spec%% *}"
    name="${spec#* }"
    sips -z "$pixels" "$pixels" "$ROOT/build/AppIcon-1024.png" --out "$ICONSET/$name.png" >/dev/null
 done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/.build/release/ScanSlap" "$APP/Contents/MacOS/ScanSlap"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
chmod 0444 "$APP/Contents/Info.plist" "$APP/Contents/Resources/LICENSE.txt" "$APP/Contents/Resources/AppIcon.icns"
chmod 0755 "$APP/Contents/MacOS/ScanSlap"
codesign --force --deep --sign - "$APP"
echo "$APP"
