#!/bin/bash

# SwiftPM build script for the Grok macOS app.
#
# Produces a bare-bones Grok.app bundle from `swift build` for quick local
# iteration. For a signed/notarized DMG, use build-dmg.sh (which drives
# xcodebuild against GrokApp.xcodeproj so Sparkle and asset catalogs link
# correctly).

set -e

echo "Building Grok..."

# Clean previous builds
rm -rf .build

# Build the app (product name in Package.swift is "Grok", so the binary
# emitted by SwiftPM is .build/release/Grok — not .build/release/GrokChat)
swift build -c release

# Create app bundle structure
APP_NAME="Grok"
APP_BUNDLE="$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Remove old app bundle if exists
rm -rf "$APP_BUNDLE"

# Create directories
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy executable (SwiftPM names the binary after the product, not the target)
cp ".build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"

# Create Info.plist — keep values in sync with Sources/Info.plist so the
# SwiftPM-built bundle behaves the same as the Xcode-built one.
cat > "$CONTENTS_DIR/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.xai.Grok</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.4</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

echo "Build complete! You can find the app at: $APP_BUNDLE"
echo "To run the app, use: open $APP_BUNDLE"