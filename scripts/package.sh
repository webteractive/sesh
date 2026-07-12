#!/bin/sh
# Packages Sesh into dist/Sesh-<version>.dmg for distribution.
#
# The build is ad-hoc signed (no Developer ID yet), so downloaded copies are
# quarantined by Gatekeeper — recipients must run:
#   xattr -d com.apple.quarantine /Applications/Sesh.app
# See the README "Download" section. Swap in Developer ID signing +
# notarization here when an Apple Developer account is available.
set -eu
cd "$(dirname "$0")/.."

tuist generate --no-open
xcodebuild -workspace sshconfig.xcworkspace -scheme Sesh -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build build

APP=build/Build/Products/Release/Sesh.app
PLIST="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")

STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Sesh.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
DMG="dist/Sesh-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Sesh $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

# SHA-256 sidecar (bare lowercase hex) — upload it alongside the DMG so users
# can verify the download.
SHA="$DMG.sha256"
shasum -a 256 "$DMG" | awk '{print $1}' > "$SHA"

echo "Packaged $DMG + $SHA (version $VERSION)"
