#!/bin/zsh
# Builds a universal (Apple silicon + Intel) release binary and wraps it in build/AntennaGenius.app
# (no Xcode project needed). The version comes from the VERSION file (YY.MM.N).
#
# Signing: with SIGN_IDENTITY set (e.g. "Developer ID Application: Your Name (TEAMID)") the app is signed
# with the hardened runtime and a secure timestamp, ready for notarization; without it, it is signed ad hoc.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUM="${VERSION##*.}"
# One build per architecture, joined with lipo: a single multi-arch `swift build` goes through XCBuild,
# which in some Xcode versions rejects the Swift 5 language mode set in Package.swift.
# Each slice is copied out at once, since some toolchains build both architectures into the same folder.
mkdir -p build
SLICES=()
for arch in arm64 x86_64; do
    swift build -c release --arch $arch
    cp "$(swift build -c release --arch $arch --show-bin-path)/AntennaGenius" "build/AntennaGenius-$arch"
    SLICES+=("build/AntennaGenius-$arch")
done
BIN=build/AntennaGenius-universal
lipo -create $SLICES -output "$BIN"
APP=build/AntennaGenius.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp "$BIN" "$APP/Contents/MacOS/AntennaGenius"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Antenna Genius</string>
<key>CFBundleIdentifier</key><string>io.github.ezypezy22.antennagenius</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>AntennaGenius</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>${BUILD_NUM}</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Finds and controls your 4O3A Antenna Genius on the local network.</string>
</dict></plist>
PLIST
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/AntennaGenius"))"
