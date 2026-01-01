#!/bin/bash

# =============================================================================
# Grok DMG Builder
# Creates a distributable .dmg file with optional code signing
#
# Requirements for Distribution:
#   1. Apple Developer Program membership ($99/year)
#   2. "Developer ID Application" certificate in Keychain
#   3. App-specific password for notarization (appleid.apple.com)
#
# Usage:
#   ./build-dmg.sh                    # Build without signing (dev only)
#   ./build-dmg.sh --sign             # Build with code signing
#   ./build-dmg.sh --sign --notarize  # Build, sign, and notarize
# =============================================================================

set -e

APP_NAME="Grok"
DMG_NAME="Grok"
BUNDLE_ID="com.xai.grok"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/GrokApp-*/Build/Products"

# Parse arguments
SIGN=false
NOTARIZE=false
UNIVERSAL=true  # Build Universal Binary by default
for arg in "$@"; do
    case $arg in
        --sign) SIGN=true ;;
        --notarize) NOTARIZE=true; SIGN=true ;;
        --arm64-only) UNIVERSAL=false ;;  # Option to build ARM64 only
    esac
done

# Build Universal Binary
if [ "$UNIVERSAL" = true ]; then
    echo "🏗️  Building Universal Binary (Intel + Apple Silicon)..."
    echo ""

    # Clean previous builds
    rm -rf "$PROJECT_DIR/build"

    # Build for ARM64 (Apple Silicon)
    echo "📱 Building for Apple Silicon (arm64)..."
    xcodebuild -project "$PROJECT_DIR/GrokApp.xcodeproj" \
        -scheme Grok \
        -configuration Release \
        -arch arm64 \
        -derivedDataPath "$PROJECT_DIR/build/arm64" \
        ONLY_ACTIVE_ARCH=NO \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        clean build

    # Build for x86_64 (Intel)
    echo ""
    echo "💻 Building for Intel (x86_64)..."
    xcodebuild -project "$PROJECT_DIR/GrokApp.xcodeproj" \
        -scheme Grok \
        -configuration Release \
        -arch x86_64 \
        -derivedDataPath "$PROJECT_DIR/build/x86_64" \
        ONLY_ACTIVE_ARCH=NO \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        clean build

    # Create Universal Binary
    echo ""
    echo "🔗 Creating Universal Binary..."

    ARM64_APP="$PROJECT_DIR/build/arm64/Build/Products/Release/Grok.app"
    X86_APP="$PROJECT_DIR/build/x86_64/Build/Products/Release/Grok.app"
    UNIVERSAL_APP="$PROJECT_DIR/build/Universal/Grok.app"

    # Copy ARM64 app as base
    mkdir -p "$PROJECT_DIR/build/Universal"
    cp -R "$ARM64_APP" "$UNIVERSAL_APP"

    # Create universal binary using lipo
    lipo -create \
        "$ARM64_APP/Contents/MacOS/Grok" \
        "$X86_APP/Contents/MacOS/Grok" \
        -output "$UNIVERSAL_APP/Contents/MacOS/Grok"

    APP_PATH="$UNIVERSAL_APP"

    # Verify universal binary
    echo ""
    echo "✅ Universal Binary created:"
    lipo -info "$APP_PATH/Contents/MacOS/Grok"

else
    # Use existing Release build (ARM64 only)
    SOURCE_APP="$DERIVED_DATA/Release/Grok.app"
    APP_PATH=$(ls -d $SOURCE_APP 2>/dev/null | head -1)

    if [ -z "$APP_PATH" ]; then
        echo "❌ Grok.app not found in Release folder"
        echo "   Make sure you built with Release configuration"
        echo "   Product → Scheme → Edit Scheme → Run → Build Configuration → Release"
        exit 1
    fi

    echo "✅ Found: $APP_PATH"
    lipo -info "$APP_PATH/Contents/MacOS/Grok"
fi

echo ""

# Create temp folder
TEMP_DIR=$(mktemp -d)
DMG_DIR="$TEMP_DIR/$APP_NAME"
mkdir -p "$DMG_DIR"

# Copy app
echo "📦 Copying app..."
cp -R "$APP_PATH" "$DMG_DIR/$APP_NAME.app"

# Code Signing (if requested)
if [ "$SIGN" = true ]; then
    echo "🔐 Code signing..."

    # Find Developer ID certificate
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')

    if [ -z "$SIGNING_IDENTITY" ]; then
        echo "❌ No 'Developer ID Application' certificate found"
        echo "   To distribute outside the Mac App Store, you need:"
        echo "   1. Apple Developer Program membership ($99/year)"
        echo "   2. Create a 'Developer ID Application' certificate at developer.apple.com"
        echo "   3. Download and install it in Keychain Access"
        echo ""
        echo "   Continuing without code signing..."
        SIGN=false
    else
        echo "   Using: $SIGNING_IDENTITY"

        # Sign with hardened runtime (required for notarization)
        codesign --force --options runtime --deep --sign "$SIGNING_IDENTITY" "$DMG_DIR/$APP_NAME.app"

        # Verify signature
        if codesign --verify --verbose "$DMG_DIR/$APP_NAME.app" 2>/dev/null; then
            echo "✅ Code signing successful"
        else
            echo "⚠️  Code signing verification failed, continuing..."
        fi
    fi
fi

# Create Applications symlink
ln -s /Applications "$DMG_DIR/Applications"

# Create DMG
OUTPUT_DIR="$HOME/Desktop"
OUTPUT_PATH="$OUTPUT_DIR/$DMG_NAME.dmg"

echo "💿 Creating DMG..."
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_DIR" -ov -format UDZO "$OUTPUT_PATH"

# Sign DMG (if app was signed)
if [ "$SIGN" = true ] && [ -n "$SIGNING_IDENTITY" ]; then
    echo "🔐 Signing DMG..."
    codesign --force --sign "$SIGNING_IDENTITY" "$OUTPUT_PATH"
fi

# Notarize (if requested and signed)
if [ "$NOTARIZE" = true ] && [ "$SIGN" = true ] && [ -n "$SIGNING_IDENTITY" ]; then
    echo "📤 Submitting for notarization..."
    echo "   (This may take a few minutes)"

    # Check for stored credentials
    if xcrun notarytool store-credentials --help >/dev/null 2>&1; then
        # Try to notarize with stored "Grok" profile
        if xcrun notarytool submit "$OUTPUT_PATH" --keychain-profile "Grok" --wait 2>/dev/null; then
            echo "✅ Notarization successful"

            # Staple the notarization ticket
            echo "📎 Stapling ticket..."
            xcrun stapler staple "$OUTPUT_PATH"
            echo "✅ Stapling complete"
        else
            echo "⚠️  Notarization failed or credentials not found"
            echo "   To set up notarization, run:"
            echo "   xcrun notarytool store-credentials Grok --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID"
        fi
    else
        echo "⚠️  notarytool not available (requires Xcode 13+)"
    fi
fi

# Cleanup
rm -rf "$TEMP_DIR"
if [ "$UNIVERSAL" = true ]; then
    rm -rf "$PROJECT_DIR/build"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Done! DMG created at:"
echo "   $OUTPUT_PATH"
echo ""

if [ "$UNIVERSAL" = true ]; then
    echo "🌍 Universal Binary: Intel + Apple Silicon"
else
    echo "📱 Apple Silicon Only (arm64)"
fi

if [ "$SIGN" = true ] && [ -n "$SIGNING_IDENTITY" ]; then
    echo "🔐 Signed: Yes"
    if [ "$NOTARIZE" = true ]; then
        echo "📋 Notarized: Attempted (check output above)"
    fi
else
    echo "⚠️  NOT SIGNED - Users will see Gatekeeper warnings"
    echo "   Run with --sign to enable code signing"
fi
echo ""
echo "📤 Ready to upload to your website!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
