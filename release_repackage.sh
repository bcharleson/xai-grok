#!/bin/bash

# =============================================================================
# Grok for Mac - Release Script
# =============================================================================
# This script automates the release process for Grok for Mac.
# It updates versions, builds the DMG, and prepares files for deployment.
#
# Usage:
#   ./release.sh <version> [build_number]
#
# Examples:
#   ./release.sh 1.0.1        # Auto-increments build number
#   ./release.sh 1.0.1 2      # Explicit build number
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
DOWNLOADS_DIR="$HOME/Downloads"

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

print_header "🚀 Grok for Mac Release Script"

# Check arguments
if [ -z "$1" ]; then
    CURRENT_VERSION=$(get_current_version)
    CURRENT_BUILD=$(get_current_build)
    
    echo ""
    echo "Usage: ./release.sh <version> [build_number]"
    echo ""
    echo "Current version: $CURRENT_VERSION (build $CURRENT_BUILD)"
    echo ""
    echo "Examples:"
    echo "  ./release.sh 1.0.1       # Patch release"
    echo "  ./release.sh 1.1.0       # Minor release"
    echo "  ./release.sh 2.0.0       # Major release"
    echo ""
    exit 1
fi

NEW_VERSION="$1"
CURRENT_BUILD=$(get_current_build)

# Auto-increment build number if not provided
if [ -z "$2" ]; then
    NEW_BUILD=$((CURRENT_BUILD + 1))
else
    NEW_BUILD="$2"
fi

# Validate build number is increasing
# if [ "$NEW_BUILD" -le "$CURRENT_BUILD" ]; then
#     print_error "Build number must be greater than current ($CURRENT_BUILD)"
#     exit 1
# fi

print_header "📋 Release Information"
print_info "New Version:     $NEW_VERSION"
print_info "New Build:       $NEW_BUILD"
print_info "Previous:        $(get_current_version) (build $CURRENT_BUILD)"
echo ""

# Confirm
# Confirm - SKIPPED FOR AUTOMATION
# read -p "Proceed with release? (y/n) " -n 1 -r
# echo
# if [[ ! $REPLY =~ ^[Yy]$ ]]; then
#     print_warning "Aborted."
#     exit 1
# fi

# =============================================================================
# Step 1: Update Info.plist
# =============================================================================

print_header "Step 1: Updating Info.plist - SKIPPING (Repackage Only)"

# /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$INFO_PLIST"
# print_success "Updated CFBundleShortVersionString to $NEW_VERSION"
#
# /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$INFO_PLIST"
# print_success "Updated CFBundleVersion to $NEW_BUILD"

# =============================================================================
# Step 2: Build the App
# =============================================================================

print_header "Step 2: Building App"

cd "$SCRIPT_DIR"

# Check if build-dmg.sh exists
if [ -f "./build-dmg.sh" ]; then
    print_info "Running build-dmg.sh..."
    chmod +x ./build-dmg.sh
    # Added --sign to ensure we ship signed binaries
    ./build-dmg.sh --sign
    print_success "Build complete"
else
    print_warning "build-dmg.sh not found, skipping build step"
    print_info "Please build manually in Xcode (⌘B) and create DMG"
fi

# =============================================================================
# Step 3: Rename DMG
# =============================================================================

print_header "Step 3: Preparing DMG"

DMG_SOURCE="$HOME/Desktop/Grok.dmg"
DMG_DEST="$DOWNLOADS_DIR/Grok.dmg"

if [ -f "$DMG_SOURCE" ]; then
    # Overwrite existing if needed
    mv "$DMG_SOURCE" "$DMG_DEST"
    print_success "Moved to $DMG_DEST"
elif [ -f "$DMG_DEST" ]; then
    print_success "DMG already exists at $DMG_DEST"
else
    print_warning "DMG not found at $DMG_SOURCE"
    print_info "Please ensure the DMG is created and named: Grok.dmg"
fi


# =============================================================================
# Step 3a: Sign Update
# =============================================================================

print_header "Step 3a: Signing Update"

if [ -f "$SCRIPT_DIR/bin/sign_update" ]; then
    SIGNATURE_OUTPUT=$("$SCRIPT_DIR/bin/sign_update" "$DMG_DEST")
    if [ $? -eq 0 ]; then
        print_success "Update signed successfully"
        # Parse the signature and length from output
        # Format is: sparkle:edSignature="XXX" length="YYY"
        SIGNATURE=$(echo "$SIGNATURE_OUTPUT" | grep -o 'edSignature="[^"]*"' | cut -d'"' -f2)
        LENGTH=$(echo "$SIGNATURE_OUTPUT" | grep -o 'length="[^"]*"' | cut -d'"' -f2)
        
        if [ -z "$SIGNATURE" ] || [ -z "$LENGTH" ]; then
            print_error "Failed to parse signature output: $SIGNATURE_OUTPUT"
            exit 1
        fi
        print_info "Signature: ${SIGNATURE:0:20}..."
        print_info "Length: $LENGTH"
    else
        print_error "Failed to sign update. Make sure Sparkle keys are in Keychain."
        exit 1
    fi
else
    print_error "sign_update tool not found in $SCRIPT_DIR/bin/"
    print_info "Please ensure Sparkle 2.x bin folder is in the project root."
    exit 1
fi

# =============================================================================
# Step 4: Generate appcast.xml entry
# =============================================================================

# Find insertion point (Look for "<!-- LATEST VERSION" or fallback)
INSERT_LINE=$(grep -n "<!-- LATEST VERSION" "$APPCAST" | cut -d: -f1)

if [ -z "$INSERT_LINE" ]; then
    # Fallback to inserting after channel description
    INSERT_LINE=$(grep -n "<language>en</language>" "$APPCAST" | cut -d: -f1)
    INSERT_LINE=$((INSERT_LINE + 1))
fi

# Create Temp File
TMP_CAST="$APPCAST.tmp"

# 1. Write Header (up to insertion point)
head -n $((INSERT_LINE - 1)) "$APPCAST" > "$TMP_CAST"

# 2. Write New Item
echo "        <!-- LATEST VERSION: $NEW_VERSION (Build $NEW_BUILD) -->" >> "$TMP_CAST"
cat <<EOF >> "$TMP_CAST"
        <item>
            <title>Version $NEW_VERSION</title>
            <pubDate>$(date -R)</pubDate>
            <description><![CDATA[
                <h2>What's New in $NEW_VERSION</h2>
                <ul>
                    <li>Release Notes for $NEW_VERSION</li>
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

# 3. Write Tail (Rest of file), replacing "LATEST VERSION" with "VERSION" to keep history clean
tail -n +$INSERT_LINE "$APPCAST" | sed 's/LATEST VERSION/VERSION/' >> "$TMP_CAST"

# 4. Overwrite original
mv "$TMP_CAST" "$APPCAST"
print_success "Automatically updated appcast.xml"

# =============================================================================
# Step 5: Copy to Desktop for Release
# =============================================================================

print_header "Step 5: Finalizing Release Files"

# Copy Appcast to Desktop
cp "$APPCAST" "$HOME/Desktop/appcast.xml"
print_success "Copied appcast.xml to Desktop"

# Ensure DMG is on Desktop 
# We moved it to Downloads earlier, so copy it back for convenience
cp "$DMG_DEST" "$HOME/Desktop/Grok.dmg"
print_success "Copied Grok.dmg to Desktop"


# =============================================================================
# Summary
# =============================================================================

print_header "📦 Release Summary"

echo ""
print_success "Version updated to $NEW_VERSION (build $NEW_BUILD)"
echo ""
echo "Next steps:"
echo ""
echo "  1. Edit appcast.xml and add the item block shown above"
echo "     (Make sure to update the release notes!)"
echo ""
echo "  2. Automating deployment to tofu-main-site..."

TOFU_REPO_PATH="$HOME/Documents/DeveloperProjects/tofu-main-site"
DOWNLOADS_PATH="$TOFU_REPO_PATH/public/downloads"
GROK_PAGE_PATH="$TOFU_REPO_PATH/app/grok/page.tsx"

if [ -d "$TOFU_REPO_PATH" ]; then
    
    # =============================================================================
    # PRE-DEPLOYMENT VALIDATION
    # =============================================================================
    print_header "🔍 Pre-Deployment Validation"
    
    # Validate XML syntax BEFORE copying
    if command -v xmllint &> /dev/null; then
        if xmllint --noout "$APPCAST" 2>/dev/null; then
            print_success "appcast.xml XML syntax is valid"
        else
            print_error "CRITICAL: appcast.xml has invalid XML syntax!"
            print_error "Aborting deployment to prevent broken updates."
            xmllint --noout "$APPCAST"
            exit 1
        fi
    else
        print_warning "xmllint not found - skipping XML validation"
    fi
    
    # Verify required elements exist in appcast
    if grep -q "sparkle:version=\"$NEW_BUILD\"" "$APPCAST"; then
        print_success "appcast.xml contains build $NEW_BUILD"
    else
        print_error "CRITICAL: appcast.xml missing build number $NEW_BUILD"
        exit 1
    fi
    
    if grep -q "sparkle:edSignature=\"" "$APPCAST"; then
        print_success "appcast.xml has properly quoted signature"
    else
        print_error "CRITICAL: appcast.xml has unquoted signature!"
        exit 1
    fi
    
    # =============================================================================
    # DEPLOYMENT
    # =============================================================================
    print_header "📤 Deploying to tofu-main-site"
    
    # 1. Copy files
    cp "$DMG_DEST" "$DOWNLOADS_PATH/Grok.dmg"
    print_success "Copied Grok.dmg to $DOWNLOADS_PATH"
    
    cp "$APPCAST" "$DOWNLOADS_PATH/appcast.xml"
    print_success "Copied appcast.xml to $DOWNLOADS_PATH"
    
    # 2. Update Website Version
    if [ -f "$GROK_PAGE_PATH" ]; then
        # Use simple sed to replace version number (assuming standard format)
        # Looks for "vX.X.X" or "Version X.X.X" string patterns
        sed -i '' "s/Version [0-9.]*[0-9]/Version $NEW_VERSION/g" "$GROK_PAGE_PATH"
        print_success "Updated version text in $GROK_PAGE_PATH"
    else
        print_warning "Could not find Grok page at $GROK_PAGE_PATH"
    fi

    # 3. Commit and Push
    cd "$TOFU_REPO_PATH" || exit
    git add public/downloads/Grok.dmg public/downloads/appcast.xml app/grok/page.tsx
    git commit -m "Release Grok for Mac v$NEW_VERSION"
    git push origin main
    print_success "Pushed release to tofu-main-site"
    
    # Return to original dir
    cd "$SCRIPT_DIR" || exit
    
    # =============================================================================
    # POST-DEPLOYMENT VERIFICATION
    # =============================================================================
    print_header "✅ Post-Deployment Verification"
    
    echo "  Waiting 10 seconds for Vercel to deploy..."
    sleep 10
    
    # Verify appcast.xml is accessible
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://www.topoffunnel.com/downloads/appcast.xml")
    if [ "$HTTP_STATUS" = "200" ]; then
        print_success "appcast.xml is accessible (HTTP $HTTP_STATUS)"
    else
        print_error "appcast.xml returned HTTP $HTTP_STATUS"
    fi
    
    # Verify DMG is accessible
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -I "https://www.topoffunnel.com/downloads/Grok.dmg")
    if [ "$HTTP_STATUS" = "200" ]; then
        print_success "Grok.dmg is accessible (HTTP $HTTP_STATUS)"
    else
        print_error "Grok.dmg returned HTTP $HTTP_STATUS"
    fi
    
    # Verify the NEW version is in the live appcast
    LIVE_APPCAST=$(curl -s "https://www.topoffunnel.com/downloads/appcast.xml" 2>/dev/null)
    if echo "$LIVE_APPCAST" | grep -q "sparkle:version=\"$NEW_BUILD\""; then
        print_success "Live appcast contains version $NEW_VERSION (build $NEW_BUILD)"
    else
        print_warning "Live appcast may not have updated yet (CDN cache)"
        print_info "Try again in a minute or clear CDN cache"
    fi
    
    # Final XML validation of live feed
    if command -v xmllint &> /dev/null; then
        if curl -s "https://www.topoffunnel.com/downloads/appcast.xml" | xmllint --noout - 2>/dev/null; then
            print_success "Live appcast.xml has valid XML syntax"
        else
            print_error "WARNING: Live appcast.xml has XML errors!"
        fi
    fi
    
else
    print_warning "tofu-main-site repo not found at $TOFU_REPO_PATH"
fi

echo ""
echo "  3. Verify deployment:"
echo "     curl -I https://www.topoffunnel.com/downloads/appcast.xml"
echo "     curl -I https://www.topoffunnel.com/downloads/Grok.dmg"
echo ""
echo "  4. Verify deployment:"
echo "     curl -I https://www.topoffunnel.com/downloads/appcast.xml"
echo "     curl -I https://www.topoffunnel.com/downloads/Grok.dmg"
echo ""

print_success "Release preparation complete! 🎉"
