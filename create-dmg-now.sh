#!/bin/bash
set -e

# Use the notarized app from Submissions (this is the one that was notarized!)
APP_PATH="$HOME/Library/Developer/Xcode/Archives/2025-12-24/Grok 12-24-25, 4.28 PM.xcarchive/Submissions/FFB210CE-0EEA-429A-BF6A-C7E773F8AF4C/Grok.app"

echo "📦 Using notarized app from: $APP_PATH"

# Create temp directory
TMP_DIR=$(mktemp -d)
DMG_DIR="$TMP_DIR/Grok"
mkdir -p "$DMG_DIR"

echo "📋 Copying Grok.app..."
cp -R "$APP_PATH" "$DMG_DIR/"

echo "🔗 Creating Applications symlink..."
ln -s /Applications "$DMG_DIR/Applications"

OUTPUT_DMG="$HOME/Downloads/Grok.dmg"

if [ -f "$OUTPUT_DMG" ]; then
    echo "🗑️  Removing old DMG..."
    rm "$OUTPUT_DMG"
fi

echo "🎨 Creating DMG..."
hdiutil create -volname "Grok" -srcfolder "$DMG_DIR" -ov -format UDZO "$OUTPUT_DMG"

rm -rf "$TMP_DIR"

echo ""
echo "✅ DMG CREATED!"
echo "📍 $OUTPUT_DMG"
echo ""
ls -lh "$OUTPUT_DMG"
