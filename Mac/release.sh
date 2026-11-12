#!/bin/zsh
# Signs with Developer ID, packages a DMG (app + Applications shortcut), notarizes and staples it.
# One-time setup:  xcrun notarytool store-credentials couchpad --key AuthKey.p8 --key-id ID --issuer UUID
# Then:            SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./release.sh
set -e -o pipefail
cd "$(dirname "$0")"
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your 'Developer ID Application: …' identity}"
OUT=build/release ./build.sh
APP="build/release/Couchpad.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/Couchpad-$VERSION.dmg"
STAGE="build/dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Couchpad" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

codesign --force --sign "$SIGN_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile couchpad --wait
xcrun stapler staple "$DMG"
echo "Ready to upload: $PWD/$DMG"
