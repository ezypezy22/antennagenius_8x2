#!/bin/zsh
# Builds the app and packages dist/AntennaGenius-<version>-macos-<arch>.dmg with an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")"
./bundle.sh
VERSION="$(tr -d '[:space:]' < VERSION)"
ARCH="$(uname -m)"
DMG="dist/AntennaGenius-${VERSION}-macos-${ARCH}.dmg"
STAGE=build/dmg
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE" dist
cp -R build/AntennaGenius.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Antenna Genius $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG"
