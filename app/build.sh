#!/bin/zsh
# Build ContextLayer.app from the SPM package (Command Line Tools only, no Xcode).
set -euo pipefail
cd "$(dirname "$0")"

VERSION=0.6.0

./vendor/fetch-ollama.sh

swift build -c release

APP=build/Context.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ContextLayer "$APP/Contents/MacOS/ContextLayer"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp logo.png "$APP/Contents/Resources/logo.png"
cp menubar.png "$APP/Contents/Resources/menubar.png"

cp vendor/ollama-arm64/ollama vendor/ollama-arm64/llama-server "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ContextLayer</string>
    <key>CFBundleIdentifier</key><string>com.nikliolios.contextlayer</string>
    <key>CFBundleName</key><string>Context</string>
    <key>CFBundleDisplayName</key><string>Context</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>17</string>
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

# Distribution: a styled drag-to-Applications DMG.
rm -f build/Context-*.zip(N) build/ContextLayer-*.zip(N) build/Context-*.dmg(N)
PATH="$HOME/Library/Python/3.14/bin:$HOME/.local/bin:$PATH" dmgbuild -s dmg-settings.py -D app="$APP" "Context" "build/Context-${VERSION}.dmg"
echo "built: $PWD/$APP"
echo "dmg:   $PWD/build/Context-${VERSION}.dmg ($(du -h build/Context-${VERSION}.dmg | cut -f1))"
