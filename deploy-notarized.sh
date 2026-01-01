#!/bin/bash

# =============================================================================
# ⚠️ DEPRECATED - DO NOT USE ⚠️
# =============================================================================
# This script is DEPRECATED as of December 2024.
# Use Cursor commands instead: /release-grok
# See: RELEASE_WORKFLOW_2025.md for the new workflow
# =============================================================================
#
# Grok for Mac - Deploy Notarized Build (DEPRECATED)
# =============================================================================
# This script handles deployment of a notarized universal binary DMG.
# 
# PREREQUISITE: You must have already:
#   1. Built universal binary in Xcode (Product → Archive)
#   2. Distributed to Apple Notary Service
#   3. Waited for notarization to complete
#   4. Exported the notarized DMG
#
# Usage:
#   ./deploy-notarized.sh <version> <path-to-notarized-dmg>
#
# Example:
#   ./deploy-notarized.sh 1.0.81 ~/Downloads/Grok.dmg
#
# =============================================================================

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFO_PLIST="$SCRIPT_DIR/Sources/Info.plist"
APPCAST="$SCRIPT_DIR/appcast.xml"
TOFU_REPO_PATH="$HOME/Documents/DeveloperProjects/tofu-main-site"
DOWNLOADS_PATH="$TOFU_REPO_PATH/public/downloads"
GROK_PAGE_PATH="$TOFU_REPO_PATH/app/grok/page.tsx"

# =============================================================================
# Helper Functions
# =============================================================================

print_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "  $1"
}

get_current_version() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || echo "unknown"
}

get_current_build() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST" 2>/dev/null || echo "0"
}

# =============================================================================
# Main Script
# =============================================================================

print_header "🚀 Deploy Notarized Grok for Mac"

# Check arguments
if [ -z "$1" ] || [ -z "$2" ]; then
    CURRENT_VERSION=$(get_current_version)
    CURRENT_BUILD=$(get_current_build)
    
    echo ""
    echo "Usage: ./deploy-notarized.sh <version> <path-to-notarized-dmg>"
    echo ""
    echo "Current version: $CURRENT_VERSION (build $CURRENT_BUILD)"
    echo ""
    echo "Example:"
    echo "  ./deploy-notarized.sh 1.0.81 ~/Downloads/Grok.dmg"
    echo ""
    exit 1
fi

NEW_VERSION="$1"
DMG_SOURCE="$2"
CURRENT_BUILD=$(get_current_build)
NEW_BUILD=$((CURRENT_BUILD + 1))

# Validate DMG exists
if [ ! -f "$DMG_SOURCE" ]; then
    print_error "DMG not found at: $DMG_SOURCE"
    exit 1
fi

print_header "📋 Deployment Information"
print_info "Version:         $NEW_VERSION"
print_info "Build:           $NEW_BUILD"
print_info "Source DMG:      $DMG_SOURCE"
print_info "Destination:     $DOWNLOADS_PATH/Grok.dmg"
echo ""

# =============================================================================
# Step 1: Update Info.plist
# =============================================================================

print_header "Step 1: Updating Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$INFO_PLIST"
print_success "Updated CFBundleShortVersionString to $NEW_VERSION"

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$INFO_PLIST"
print_success "Updated CFBundleVersion to $NEW_BUILD"

# =============================================================================
# Step 2: Sign with Sparkle
# =============================================================================

print_header "Step 2: Signing with Sparkle"

if [ -f "$SCRIPT_DIR/bin/sign_update" ]; then
    SIGNATURE_OUTPUT=$("$SCRIPT_DIR/bin/sign_update" "$DMG_SOURCE")
    if [ $? -eq 0 ]; then
        print_success "DMG signed successfully"
        SIGNATURE=$(echo "$SIGNATURE_OUTPUT" | grep -o 'edSignature="[^"]*"' | cut -d'"' -f2)
        LENGTH=$(echo "$SIGNATURE_OUTPUT" | grep -o 'length="[^"]*"' | cut -d'"' -f2)
        
        if [ -z "$SIGNATURE" ] || [ -z "$LENGTH" ]; then
            print_error "Failed to parse signature output"
            exit 1
        fi
        print_info "Signature: ${SIGNATURE:0:20}..."
        print_info "Length: $LENGTH bytes"
    else
        print_error "Failed to sign update"
        exit 1
    fi
else
    print_error "sign_update tool not found in $SCRIPT_DIR/bin/"
    exit 1
fi

# =============================================================================
# Step 3: Update appcast.xml
# =============================================================================

print_header "Step 3: Updating appcast.xml"

# Find insertion point
INSERT_LINE=$(grep -n "<!-- LATEST VERSION" "$APPCAST" | cut -d: -f1)

if [ -z "$INSERT_LINE" ]; then
    INSERT_LINE=$(grep -n "<language>en</language>" "$APPCAST" | cut -d: -f1)
    INSERT_LINE=$((INSERT_LINE + 1))
fi

# Create temp file
TMP_CAST="$APPCAST.tmp"

# Write header
head -n $((INSERT_LINE - 1)) "$APPCAST" > "$TMP_CAST"

# Write new item
echo "        <!-- LATEST VERSION: $NEW_VERSION (Build $NEW_BUILD) -->" >> "$TMP_CAST"
cat <<EOF >> "$TMP_CAST"
        <item>
            <title>Version $NEW_VERSION</title>
            <pubDate>$(date -R)</pubDate>
            <description><![CDATA[
                <h2>What's New in $NEW_VERSION</h2>
                <ul>
                    <li>Universal binary (Apple Silicon + Intel)</li>
                    <li>Apple notarized for enhanced security</li>
                    <li>Bug fixes and performance improvements</li>
                </ul>
            ]]></description>
            <enclosure
                url="https://www.topoffunnel.com/downloads/Grok.dmg"
                sparkle:version="$NEW_BUILD"
                sparkle:shortVersionString="$NEW_VERSION"
                sparkle:edSignature="$SIGNATURE"
                length="$LENGTH"
                type="application/octet-stream"
            />
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
        </item>
EOF

# Write tail
tail -n +$INSERT_LINE "$APPCAST" | sed 's/LATEST VERSION/VERSION/' >> "$TMP_CAST"

# Overwrite original
mv "$TMP_CAST" "$APPCAST"
print_success "Updated appcast.xml"

# Validate XML
if command -v xmllint &> /dev/null; then
    if xmllint --noout "$APPCAST" 2>/dev/null; then
        print_success "appcast.xml XML syntax is valid"
    else
        print_error "CRITICAL: appcast.xml has invalid XML syntax!"
        xmllint --noout "$APPCAST"
        exit 1
    fi
fi

# =============================================================================
# Step 4: Deploy to tofu-main-site
# =============================================================================

print_header "Step 4: Deploying to tofu-main-site"

if [ ! -d "$TOFU_REPO_PATH" ]; then
    print_error "tofu-main-site repo not found at $TOFU_REPO_PATH"
    exit 1
fi

# Copy DMG
cp "$DMG_SOURCE" "$DOWNLOADS_PATH/Grok.dmg"
print_success "Copied Grok.dmg to $DOWNLOADS_PATH"

# Copy appcast
cp "$APPCAST" "$DOWNLOADS_PATH/appcast.xml"
print_success "Copied appcast.xml to $DOWNLOADS_PATH"

print_info "Note: Grok page updates should be handled by tofu-main-site workspace"

# =============================================================================
# Step 5: Commit and Push
# =============================================================================

print_header "Step 5: Committing to Git"

cd "$TOFU_REPO_PATH" || exit
git add public/downloads/Grok.dmg public/downloads/appcast.xml
git commit -m "Release Grok for Mac v$NEW_VERSION (Build $NEW_BUILD) - Universal Binary + Notarized"
git push origin main
print_success "Pushed DMG and appcast.xml to tofu-main-site"

cd "$SCRIPT_DIR" || exit

# =============================================================================
# Step 6: Verify Deployment
# =============================================================================

print_header "Step 6: Verifying Deployment"

echo "  Waiting 15 seconds for Vercel to deploy..."
sleep 15

# Check appcast
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://www.topoffunnel.com/downloads/appcast.xml")
if [ "$HTTP_STATUS" = "200" ]; then
    print_success "appcast.xml is live (HTTP $HTTP_STATUS)"
else
    print_error "appcast.xml returned HTTP $HTTP_STATUS"
fi

# Check DMG
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -I "https://www.topoffunnel.com/downloads/Grok.dmg")
if [ "$HTTP_STATUS" = "200" ]; then
    print_success "Grok.dmg is live (HTTP $HTTP_STATUS)"
else
    print_error "Grok.dmg returned HTTP $HTTP_STATUS"
fi

# Verify version in live appcast
LIVE_APPCAST=$(curl -s "https://www.topoffunnel.com/downloads/appcast.xml" 2>/dev/null)
if echo "$LIVE_APPCAST" | grep -q "sparkle:version=\"$NEW_BUILD\""; then
    print_success "Live appcast contains version $NEW_VERSION (build $NEW_BUILD)"
else
    print_warning "Live appcast may not have updated yet (CDN cache)"
fi

# =============================================================================
# Summary
# =============================================================================

print_header "✅ Deployment Complete!"

echo ""
print_success "Grok for Mac v$NEW_VERSION (Build $NEW_BUILD) is now live!"
echo ""
print_info "Download URL: https://www.topoffunnel.com/downloads/Grok.dmg"
print_info "Appcast URL:  https://www.topoffunnel.com/downloads/appcast.xml"
print_info "Landing Page: https://www.topoffunnel.com/grok"
echo ""
print_info "Users will receive the update automatically via Sparkle."
echo ""

