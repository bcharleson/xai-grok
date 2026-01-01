#!/bin/bash

# =============================================================================
# Package existing Xcode build into DMG
# Uses the build you already created with Command+B in Xcode
# =============================================================================

set -e

APP_NAME="Grok"
DMG_NAME="Grok-universal"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"

echo "🔍 Looking for existing Xcode build..."

# Find the most recent Release build
APP_PATH=$(find "$DERIVED_DATA" -name "Grok.app" -path "*/Build/Products/Release/*" -type d 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    echo "❌ No Grok.app found in DerivedData"
    echo "   Please build in Xcode first:"
    echo "   1. Select 'Any Mac' destination"
    echo "   2. Press Command+B"
    exit 1
fi

echo "✅ Found: $APP_PATH"
echo ""

# Check architectures
echo "🔍 Checking architectures..."
ARCH_INFO=$(lipo -info "$APP_PATH/Contents/MacOS/Grok" 2>&1)
echo "$ARCH_INFO"
echo ""

# Verify it's universal
if echo "$ARCH_INFO" | grep -q "x86_64" && echo "$ARCH_INFO" | grep -q "arm64"; then
    echo "✅ Universal Binary detected (Intel + Apple Silicon)"
    DMG_NAME="Grok-universal"
elif echo "$ARCH_INFO" | grep -q "arm64"; then
    echo "⚠️  Apple Silicon only (arm64)"
    echo "   To build Universal, select 'Any Mac (arm64, x86_64)' in Xcode"
    DMG_NAME="Grok-arm64"
else
    echo "⚠️  Intel only (x86_64)"
    DMG_NAME="Grok-x86_64"
fi

echo ""

# Create temp folder
TEMP_DIR=$(mktemp -d)
DMG_DIR="$TEMP_DIR/$APP_NAME"
mkdir -p "$DMG_DIR"

# Copy app
echo "📦 Copying app..."
cp -R "$APP_PATH" "$DMG_DIR/$APP_NAME.app"

# Create Applications symlink
ln -s /Applications "$DMG_DIR/Applications"

# Create DMG
OUTPUT_DIR="$HOME/Desktop"
OUTPUT_PATH="$OUTPUT_DIR/$DMG_NAME.dmg"

echo "💿 Creating DMG..."
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_DIR" -ov -format UDZO "$OUTPUT_PATH"

# Cleanup
rm -rf "$TEMP_DIR"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Done! DMG created at:"
echo "   $OUTPUT_PATH"
echo ""
echo "📤 Ready to sign and upload!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

