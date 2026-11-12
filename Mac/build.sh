#!/bin/zsh
# Builds the Mac menu-bar app into Mac/build/Couchpad.app (or $OUT/Couchpad.app: release.sh
# builds into its own folder, so a release never replaces the dev app. macOS ties the
# Accessibility and Screen Recording grants to the signature, and one path holding the
# Apple Development build one day and the Developer ID build the next lost them each time).
set -e -o pipefail
cd "$(dirname "$0")"
swift build -c release 2>&1 | grep -v '^\[' || { echo 'swift build failed' >&2; exit 1; }
APP="${OUT:-build}/Couchpad.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CouchpadMac "$APP/Contents/MacOS/Couchpad"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Sign with SIGN_IDENTITY (see release.sh) or, failing that, any Apple Development
# certificate in the keychain: a certificate gives the app a stable identity, so the
# Accessibility grant survives rebuilds. Ad-hoc signing is the last resort.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')}"
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"
echo "Signed as: ${IDENTITY:-ad-hoc}"
echo "Built: $PWD/$APP"
