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
#   ./build-dmg.sh --skip-build       # Reuse a prior xcodebuild output
# =============================================================================

set -e

# Always run from the directory containing this script so relative paths
# (GrokApp.xcodeproj, ./build) resolve regardless of where the script is
# invoked from.
cd "$(dirname "$0")"

APP_NAME="Grok"
DMG_NAME="Grok"
BUNDLE_ID="com.xai.Grok"
SCHEME="Grok"
CONFIGURATION="Release"
PROJECT="GrokApp.xcodeproj"
DERIVED_DATA="$(pwd)/build"
LOCAL_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
# Fallback: previously-built app sitting in the user's shared DerivedData.
FALLBACK_APP_GLOB="$HOME/Library/Developer/Xcode/DerivedData/GrokApp-*/Build/Products/$CONFIGURATION/$APP_NAME.app"

# Parse arguments
SIGN=false
NOTARIZE=false
SKIP_BUILD=false
for arg in "$@"; do
    case $arg in
        --sign) SIGN=true ;;
        --notarize) NOTARIZE=true; SIGN=true ;;
        --skip-build) SKIP_BUILD=true ;;
    esac
done

# Build the app via xcodebuild into a deterministic derived-data location so
# we never depend on a prior manual build (and avoid the non-deterministic
# GrokApp-* hash in the user's shared DerivedData).
if [ "$SKIP_BUILD" = false ]; then
    if ! command -v xcodebuild >/dev/null 2>&1; then
        echo "❌ xcodebuild not found. Install Xcode and command-line tools."
        exit 1
    fi

    echo "🛠  Building $SCHEME ($CONFIGURATION) via xcodebuild..."
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "$DERIVED_DATA" \
        -destination 'generic/platform=macOS' \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        clean build | xcpretty 2>/dev/null || \
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "$DERIVED_DATA" \
        -destination 'generic/platform=macOS' \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        clean build
fi

# Resolve the produced app: prefer our deterministic path, then fall back to
# whatever Xcode last produced in shared DerivedData.
if [ -d "$LOCAL_APP" ]; then
    APP_PATH="$LOCAL_APP"
else
    APP_PATH=$(ls -d $FALLBACK_APP_GLOB 2>/dev/null | head -1)
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "❌ $APP_NAME.app not found after build"
    echo "   Looked in: $LOCAL_APP"
    echo "   Fallback:  $FALLBACK_APP_GLOB"
    echo "   Try re-running without --skip-build."
    exit 1
fi

echo "✅ Found: $APP_PATH"

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

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Done! DMG created at:"
echo "   $OUTPUT_PATH"
echo ""

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
