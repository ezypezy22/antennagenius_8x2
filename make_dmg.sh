#!/bin/zsh
# Builds the app and packages it into build/AntennaGenius.dmg with an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")"
./bundle.sh
STAGE=build/dmg
rm -rf "$STAGE" build/AntennaGenius.dmg
mkdir -p "$STAGE"
cp -R build/AntennaGenius.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Antenna Genius" -srcfolder "$STAGE" -ov -format UDZO build/AntennaGenius.dmg
rm -rf "$STAGE"
echo "Built build/AntennaGenius.dmg"
