#!/bin/bash
# Builds FlightCore.app (release) next to this script.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="FlightCore.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/AppIcon.png Resources/Splash.jpg Resources/RockFPV.png "$APP/Contents/Resources/"
cp -R Resources/Previews "$APP/Contents/Resources/Previews"
cp .build/release/FlightCore "$APP/Contents/MacOS/FlightCore"
cat > "$APP/Contents/Info.plist" <<'PLIST'
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
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
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
