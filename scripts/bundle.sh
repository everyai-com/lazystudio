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
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Prefer a real Developer ID identity from the Keychain; fall back to ad-hoc.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
SIGN="${IDENTITY:--}"
echo "Signing with: ${IDENTITY:-ad-hoc}"
codesign --force --options runtime --sign "$SIGN" \
  --entitlements Resources/LazyStudio.entitlements \
  "$APP" 2>/dev/null || codesign --force --deep --sign - "$APP"

echo "Built $APP"
echo "Run: open $APP"
