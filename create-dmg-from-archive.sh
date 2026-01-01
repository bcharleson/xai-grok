#!/bin/bash

set -e

echo "🔍 Finding latest Xcode archive..."

# Find the most recent archive
LATEST_ARCHIVE=$(ls -t ~/Library/Developer/Xcode/Archives/2025-12-24/*.xcarchive 2>/dev/null | head -1)

if [ -z "$LATEST_ARCHIVE" ]; then
    echo "❌ No archive found!"
    exit 1
fi

echo "📦 Found archive: $LATEST_ARCHIVE"

# Extract the app from the archive
APP_PATH="$LATEST_ARCHIVE/Products/Applications/Grok.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Grok.app not found in archive!"
    exit 1
fi

echo "✅ Found Grok.app in archive"

# Create a temporary directory for DMG creation
TMP_DIR=$(mktemp -d)
DMG_DIR="$TMP_DIR/Grok"
mkdir -p "$DMG_DIR"

echo "📋 Copying Grok.app to temporary directory..."
cp -R "$APP_PATH" "$DMG_DIR/"

# Create Applications symlink
echo "🔗 Creating Applications symlink..."
ln -s /Applications "$DMG_DIR/Applications"

# Output DMG path
OUTPUT_DMG="$HOME/Downloads/Grok.dmg"

# Remove old DMG if it exists
if [ -f "$OUTPUT_DMG" ]; then
    echo "🗑️  Removing old DMG..."
    rm "$OUTPUT_DMG"
fi

echo "🎨 Creating DMG..."

# Create the DMG
hdiutil create -volname "Grok" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$OUTPUT_DMG"

# Clean up
echo "🧹 Cleaning up..."
rm -rf "$TMP_DIR"

echo ""
echo "✅ DMG created successfully!"
echo "📍 Location: $OUTPUT_DMG"
echo ""
echo "🚀 Now run:"
echo "   ./deploy-notarized.sh 1.0.82 $OUTPUT_DMG"

