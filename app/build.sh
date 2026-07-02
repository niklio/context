#!/bin/zsh
# Build ContextLayer.app from the SPM package (Command Line Tools only, no Xcode).
set -euo pipefail
cd "$(dirname "$0")"

VERSION=0.8.6

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
cp harness.js "$APP/Contents/Resources/harness.js"

# Sparkle auto-update framework (SPM binary artifact)
SPARKLE_FW=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"

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
    <key>CFBundleVersion</key><string>26</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Local-first. Raw messages never leave this Mac.</string>
    <key>SUFeedURL</key><string>https://context.nikliolios.com/appcast.xml</string>
    <key>SUPublicEDKey</key><string>9Ts9CqPxc+htnwz541nMcb26qTyYOVSEYW4eMP8jrJg=</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAutomaticallyUpdate</key><true/>
    <key>SUScheduledCheckInterval</key><integer>21600</integer>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"

# Ad-hoc signature: stable identity so the Full Disk Access grant survives
# rebuilds on the same machine. Real Developer ID signing comes later.
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - --identifier com.nikliolios.contextlayer "$APP"

# Distribution: a styled drag-to-Applications DMG.
rm -f build/Context-*.zip(N) build/ContextLayer-*.zip(N) build/Context-*.dmg(N)
PATH="$HOME/Library/Python/3.14/bin:$HOME/.local/bin:$PATH" dmgbuild -s dmg-settings.py -D app="$APP" "Context" "build/Context-${VERSION}.dmg"
echo "built: $PWD/$APP"
echo "dmg:   $PWD/build/Context-${VERSION}.dmg ($(du -h build/Context-${VERSION}.dmg | cut -f1))"
