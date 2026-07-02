#!/bin/zsh
# Build ContextLayer.app from the SPM package (Command Line Tools only, no Xcode).
set -euo pipefail
cd "$(dirname "$0")"

VERSION=0.2.2

./vendor/fetch-ollama.sh

swift build -c release

APP=build/ContextLayer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ContextLayer "$APP/Contents/MacOS/ContextLayer"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cp vendor/ollama-arm64/ollama vendor/ollama-arm64/llama-server "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ContextLayer</string>
    <key>CFBundleIdentifier</key><string>com.nikliolios.contextlayer</string>
    <key>CFBundleName</key><string>Context Layer</string>
    <key>CFBundleDisplayName</key><string>Context Layer</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>4</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Local-first. Raw messages never leave this Mac.</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"

# Ad-hoc signature: stable identity so the Full Disk Access grant survives
# rebuilds on the same machine. Real Developer ID signing comes later.
codesign --force --sign - --identifier com.nikliolios.contextlayer "$APP"

(cd build && rm -f ContextLayer-*.zip && zip -qry "ContextLayer-${VERSION}.zip" ContextLayer.app)
echo "built: $PWD/$APP"
echo "zip:   $PWD/build/ContextLayer-${VERSION}.zip ($(du -h build/ContextLayer-${VERSION}.zip | cut -f1))"
