#!/bin/bash
# Build, sign, zip, and publish a GitHub release the in-app updater can install.
# Usage: ./scripts/release.sh 0.2.0 "Release notes"
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version> [notes]}"
NOTES="${2:-LazyStudio $VERSION}"

# Stamp the version into Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist

./scripts/bundle.sh

rm -f build/LazyStudio.zip
/usr/bin/ditto -c -k --keepParent build/LazyStudio.app build/LazyStudio.zip

gh release create "v$VERSION" build/LazyStudio.zip \
  --title "LazyStudio $VERSION" --notes "$NOTES"

echo "Released v$VERSION — installed apps will offer the update within a day."
