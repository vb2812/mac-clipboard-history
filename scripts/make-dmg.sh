#!/bin/zsh
# Release build → dist/Clipboard-History-<version>.dmg
# Optional: DEVELOPER_ID="Developer ID Application: Name (TEAMID)" re-signs for distribution;
#           NOTARY_PROFILE=<keychain profile from `xcrun notarytool store-credentials`> notarizes + staples.
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate --quiet
xcodebuild -project ClipboardHistory.xcodeproj -scheme ClipboardHistory -configuration Release -derivedDataPath build/dd-release \
  -destination 'platform=macOS' build -quiet
APP=build/dd-release/Build/Products/Release/ClipboardHistory.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"
mkdir -p dist; STAGE=$(mktemp -d); cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
DMG="dist/Clipboard-History-$VERSION.dmg"; rm -f "$DMG"
hdiutil create -quiet -volname "Clipboard History $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  [[ -n "${DEVELOPER_ID:-}" ]] || { echo "NOTARY_PROFILE needs DEVELOPER_ID" >&2; exit 1; }
  codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
echo "made $DMG"
