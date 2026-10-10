#!/bin/sh
# Packages Sesh into dist/Sesh-<version>.dmg for distribution: a Release build,
# Developer ID signed with the hardened runtime, notarized and stapled — the app
# first, then the DMG around it — so a downloaded copy opens with no Gatekeeper
# override and no network round-trip for its ticket.
#
# Signing reads nothing from this repo, secret or personal: the identity is the
# one "Developer ID Application" certificate in the keychain, found at run time,
# and notarytool authenticates through a keychain profile (created once with
# `xcrun notarytool store-credentials <profile>`). Override either with
# SESH_SIGN_IDENTITY (a name or SHA-1 hash) / SESH_NOTARY_PROFILE.
#
# Usage:
#   scripts/package.sh              build, sign, notarize, staple, verify
#   scripts/package.sh --preflight  only check the identity and notary profile
set -eu
cd "$(dirname "$0")/.."

SIGN_IDENTITY=${SESH_SIGN_IDENTITY:-}
NOTARY_PROFILE=${SESH_NOTARY_PROFILE:-notary}

# Every release so far has been universal, and the in-app updater takes the one
# DMG a release carries, so an Intel Mac would install whatever this builds.
ARCHS="arm64 x86_64"

MODE=release
case "${1:-}" in
  "") ;;
  --preflight) MODE=preflight ;;
  -h|--help) sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: scripts/package.sh [--preflight]" >&2; exit 2 ;;
esac

die() { printf '%s\n' "error: $*" >&2; exit 1; }

# Checked before anything builds, and on its own with --preflight, so a missing
# certificate or profile stops a release before its version bump is pushed.
preflight() {
  if [ -n "$SIGN_IDENTITY" ]; then
    security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY" \
      || die "SESH_SIGN_IDENTITY is not a valid signing identity in the keychain"
  else
    # Signed by SHA-1 hash, not name: a renewed certificate keeps its name, and
    # codesign refuses a name two valid certificates share.
    found=$(security find-identity -v -p codesigning | grep '"Developer ID Application: ' || true)
    case $(printf '%s' "$found" | grep -c . || true) in
      0) die "no valid \"Developer ID Application\" certificate in the keychain" ;;
      1) SIGN_IDENTITY=$(printf '%s' "$found" | awk '{print $2}') ;;
      *) printf '%s\n' "$found" >&2
         die "several Developer ID Application certificates — pick one with SESH_SIGN_IDENTITY=<hash>" ;;
    esac
  fi
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "notary keychain profile '$NOTARY_PROFILE' is missing or rejected — run: xcrun notarytool store-credentials $NOTARY_PROFILE"
}

# Submits one file and waits. notarytool exits 0 for an Invalid verdict too, so
# the status is read from its JSON, and a rejection prints Apple's log.
notarize() {
  out=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json) || die "notarytool submit failed for $1"
  id=$(printf '%s' "$out" | plutil -extract id raw -o - -)
  status=$(printf '%s' "$out" | plutil -extract status raw -o - -)
  if [ "$status" != "Accepted" ]; then
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "notarization of $1 ended '$status' (submission $id)"
  fi
  echo "notarized $1 ($id)"
}

preflight
if [ "$MODE" = preflight ]; then
  echo "signing ready: identity $SIGN_IDENTITY, notary profile '$NOTARY_PROFILE'"
  exit 0
fi

tuist generate --no-open
xcodebuild -workspace sshconfig.xcworkspace -scheme Sesh -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build build

APP=build/Build/Products/Release/Sesh.app
PLIST="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")

# Read off the built executable, not the build flags.
built_archs=$(lipo -archs "$APP/Contents/MacOS/Sesh")
for arch in $ARCHS; do
  case " $built_archs " in
    *" $arch "*) ;;
    *) die "built executable is missing $arch (has: $built_archs)" ;;
  esac
done

# Inside out: each nested framework or dylib first, the app last, since the
# app's seal records the signatures of what it contains. Re-signing without
# --entitlements also drops Xcode's get-task-allow, which notarization refuses.
sign() { codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$1"; }
for nested in "$APP"/Contents/Frameworks/*; do
  if [ -e "$nested" ]; then sign "$nested"; fi
done
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# The app is notarized and stapled on its own before the DMG is made, so the
# copy a user drags out carries its ticket — and so does the copy the in-app
# updater lifts out of the DMG.
WORK=$(mktemp -d)
ditto -c -k --keepParent "$APP" "$WORK/Sesh.zip"
notarize "$WORK/Sesh.zip"
rm -rf "$WORK"
xcrun stapler staple "$APP"
spctl -a -vvv -t exec "$APP"

STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Sesh.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
DMG="dist/Sesh-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Sesh $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl -a -vvv -t open --context context:primary-signature "$DMG"

# SHA-256 sidecar (bare lowercase hex) — the in-app self-updater verifies the
# download against this. Written LAST: stapling rewrites the DMG. Upload it
# alongside the DMG in the release.
SHA="$DMG.sha256"
shasum -a 256 "$DMG" | awk '{print $1}' > "$SHA"

echo "Packaged $DMG + $SHA (version $VERSION, $built_archs) — Developer ID signed, notarized, stapled"
