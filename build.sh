#!/bin/sh
# Baut TobiScan.app in diesem Ordner. Braucht nur die Xcode Command Line Tools.
set -e
cd "$(dirname "$0")"

APP="TobiScan.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
    Sources/TobiScan/*.swift -o "$APP/Contents/MacOS/TobiScan"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TobiScan</string>
    <key>CFBundleDisplayName</key><string>TobiScan</string>
    <key>CFBundleIdentifier</key><string>de.tobi.TobiScan</string>
    <key>CFBundleExecutable</key><string>TobiScan</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>de</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>TobiScan sucht im lokalen Netz nach dem ScanSnap und scannt über WLAN.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Fertig: $(pwd)/$APP"
