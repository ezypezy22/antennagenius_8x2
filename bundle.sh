#!/bin/zsh
# Builds a release binary and wraps it in build/AntennaGenius.app (no Xcode project needed).
# The version comes from the VERSION file (YY.MM.N).
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUM="${VERSION##*.}"
swift build -c release
APP=build/AntennaGenius.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/AntennaGenius "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Antenna Genius</string>
<key>CFBundleIdentifier</key><string>local.antennagenius.mac</string>
<key>CFBundleExecutable</key><string>AntennaGenius</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>${BUILD_NUM}</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Finds and controls your 4O3A Antenna Genius on the local network.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP ($VERSION)"
