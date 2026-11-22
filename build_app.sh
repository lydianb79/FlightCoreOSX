#!/bin/bash
# Builds FlightCore.app (release).
#   ./build_app.sh                  for this Mac, next to this script
#   ./build_app.sh x86_64 dist/x86  for another architecture (arm64 or x86_64), into a folder
set -euo pipefail
cd "$(dirname "$0")"
VERSION="2.1.0"     # shown in Finder and used in the release file names
BUILD="8"
ARCH="${1:-}"
OUT="${2:-.}"
if [ -n "$ARCH" ]; then
    swift build -c release --arch "$ARCH"
    BIN="$(swift build -c release --arch "$ARCH" --show-bin-path)/FlightCore"
else
    swift build -c release
    BIN=".build/release/FlightCore"
fi
mkdir -p "$OUT"
APP="$OUT/FlightCore.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/AppIcon.png Resources/Splash.jpg Resources/RockFPV.png "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp -R Resources/Previews "$APP/Contents/Resources/Previews"
cp "$BIN" "$APP/Contents/MacOS/FlightCore"
strip -S "$APP/Contents/MacOS/FlightCore" 2>/dev/null     # no debug map: it holds the paths of the Mac it was built on (signed again below)
find "$APP" -name .DS_Store -delete
chmod -R u+rwX,go+rX "$APP"     # readable by every user of the Mac it is installed on
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>FlightCore</string>
    <key>CFBundleDisplayName</key><string>FlightCore OSX</string>
    <key>CFBundleIdentifier</key><string>app.flightcore.sim</string>
    <key>CFBundleExecutable</key><string>FlightCore</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.simulation-games</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>GCSupportsControllerUserInteraction</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
