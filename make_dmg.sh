#!/bin/zsh
# Builds the app and packages dist/AntennaGenius-<version>-macos-universal.dmg with an Applications shortcut.
#
# With SIGN_IDENTITY set the DMG is signed too, and with NOTARY_PROFILE also set it is notarized and stapled.
# Create the profile once with:
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <TEAMID> --password <app-specific password>
set -euo pipefail
cd "$(dirname "$0")"
./bundle.sh
VERSION="$(tr -d '[:space:]' < VERSION)"
DMG="dist/AntennaGenius-${VERSION}-macos-universal.dmg"
STAGE=build/dmg
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE" dist
cp -R build/AntennaGenius.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Antenna Genius $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
else
    echo "Note: ad hoc signed. Other Macs will block it until allowed in System Settings › Privacy & Security (see README)."
fi
echo "Built $DMG"
