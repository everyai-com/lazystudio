#!/bin/bash
# Build LazyStudio.app from the SwiftPM executable (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/LazyStudio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LazyStudio "$APP/Contents/MacOS/LazyStudio"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --deep --sign - \
  --entitlements Resources/LazyStudio.entitlements \
  "$APP" 2>/dev/null || codesign --force --deep --sign - "$APP"

echo "Built $APP"
echo "Run: open $APP"
