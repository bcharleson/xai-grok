#!/bin/bash

# =============================================================================
# ⚠️ DEPRECATED - DO NOT USE ⚠️
# =============================================================================
# This script is DEPRECATED as of December 2024.
# Use Cursor commands instead: /release-grok
# See: RELEASE_WORKFLOW_2025.md for the new workflow
# =============================================================================
#
# Grok for Mac - Release Script (DEPRECATED)
# =============================================================================
#
# CRITICAL RELEASE PROCESS - READ CAREFULLY!
# -------------------------------------------
# This script automates the ENTIRE release process. DO NOT run individual
# commands manually or copy files manually - this leads to signature mismatches!
#
# THE RELEASE FLOW:
# 1. Build app in Xcode (Product → Build, Release configuration)
# 2. Run: ./release.sh <version> [build_number]
# 3. Wait for script to complete and verify deployment
#
# WHAT THIS SCRIPT DOES:
# 1. Updates MARKETING_VERSION and CURRENT_PROJECT_VERSION in Xcode project
# 2. Runs build-dmg.sh to create signed DMG at ~/Desktop/Grok.dmg
# 3. Moves DMG to ~/Downloads/Grok.dmg (THE CANONICAL LOCATION)
# 4. Signs DMG with Sparkle EdDSA key (generates signature)
# 5. Updates appcast.xml with new version entry and signature
# 6. Copies ONLY ~/Downloads/Grok.dmg to tofu-main-site (NEVER from elsewhere!)
# 7. Commits and pushes to deploy
#
# CRITICAL: The DMG file flow is:
#   ~/Desktop/Grok.dmg → ~/Downloads/Grok.dmg → tofu-main-site/public/downloads/
#   ^^^^^^^^^^^^^^^^^^^^   ^^^^^^^^^^^^^^^^^^^
#   build-dmg.sh creates   THIS is the signed file we deploy!
#
# WARNING: NEVER copy Grok.dmg from the GrokChat folder - that may be stale!
#
# Usage:
#   ./release.sh <version> [build_number]
#
# Examples:
#   ./release.sh 1.0.80        # Auto-increments build number
#   ./release.sh 1.0.80 46     # Explicit build number
#
# =============================================================================

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# CONFIGURATION - Canonical file locations
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFO_PLIST="$SCRIPT_DIR/Sources/Info.plist"
APPCAST="$SCRIPT_DIR/appcast.xml"
DOWNLOADS_DIR="$HOME/Downloads"

# CRITICAL: These are the ONLY valid DMG locations in the release process
DMG_BUILD_OUTPUT="$HOME/Desktop/Grok.dmg"      # Where build-dmg.sh creates it
DMG_CANONICAL="$DOWNLOADS_DIR/Grok.dmg"        # THE file we sign and deploy

# CRITICAL: tofu-main-site paths
TOFU_REPO_PATH="$HOME/Documents/DeveloperProjects/tofu-main-site"
TOFU_DOWNLOADS_PATH="$TOFU_REPO_PATH/public/downloads"
TOFU_GROK_PAGE="$TOFU_REPO_PATH/app/grok/page.tsx"

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
    # Read from Xcode project settings instead of Info.plist
    grep -A1 "MARKETING_VERSION" "$SCRIPT_DIR/GrokApp.xcodeproj/project.pbxproj" | grep -v "MARKETING_VERSION" | sed 's/.*= \(.*\);/\1/' | head -1 || echo "unknown"
}

get_current_build() {
    # Read from Xcode project settings instead of Info.plist
    grep -A1 "CURRENT_PROJECT_VERSION" "$SCRIPT_DIR/GrokApp.xcodeproj/project.pbxproj" | grep -v "CURRENT_PROJECT_VERSION" | sed 's/.*= \(.*\);/\1/' | head -1 || echo "0"
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
if [ "$NEW_BUILD" -le "$CURRENT_BUILD" ]; then
    print_error "Build number must be greater than current ($CURRENT_BUILD)"
    exit 1
fi

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
# Step 1: Update Xcode Project Settings
# =============================================================================

print_header "Step 1: Updating Xcode Project Settings"

PROJECT_FILE="$SCRIPT_DIR/GrokApp.xcodeproj/project.pbxproj"

# Update MARKETING_VERSION in both Debug and Release configurations
sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $NEW_VERSION;/g" "$PROJECT_FILE"
print_success "Updated MARKETING_VERSION to $NEW_VERSION"

# Update CURRENT_PROJECT_VERSION in both Debug and Release configurations
sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" "$PROJECT_FILE"
print_success "Updated CURRENT_PROJECT_VERSION to $NEW_BUILD"

print_info "Info.plist will use these values via \$(MARKETING_VERSION) and \$(CURRENT_PROJECT_VERSION)"

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
# Step 3: Move DMG to Canonical Location
# =============================================================================
# CRITICAL: build-dmg.sh outputs to ~/Desktop/Grok.dmg
#           We move it to ~/Downloads/Grok.dmg which is THE canonical location
#           ALL subsequent operations use ~/Downloads/Grok.dmg
# =============================================================================

print_header "Step 3: Preparing DMG (Moving to Canonical Location)"

# SAFETY CHECK: Remove any stale DMG from GrokChat folder to prevent confusion
if [ -f "$SCRIPT_DIR/Grok.dmg" ]; then
    print_warning "Found stale Grok.dmg in GrokChat folder - REMOVING to prevent accidents"
    rm "$SCRIPT_DIR/Grok.dmg"
    print_success "Removed stale $SCRIPT_DIR/Grok.dmg"
fi

if [ -f "$DMG_BUILD_OUTPUT" ]; then
    # Move from Desktop to Downloads (canonical location)
    mv "$DMG_BUILD_OUTPUT" "$DMG_CANONICAL"
    print_success "Moved $DMG_BUILD_OUTPUT → $DMG_CANONICAL"
elif [ -f "$DMG_CANONICAL" ]; then
    # Check if the DMG in Downloads is fresh (created in last 10 minutes)
    DMG_AGE=$(( $(date +%s) - $(stat -f %m "$DMG_CANONICAL") ))
    if [ "$DMG_AGE" -gt 600 ]; then
        print_error "CRITICAL: DMG at $DMG_CANONICAL is $((DMG_AGE/60)) minutes old!"
        print_error "This may be a stale file. Please rebuild with build-dmg.sh"
        exit 1
    fi
    print_success "Using existing DMG at $DMG_CANONICAL (${DMG_AGE}s old)"
else
    print_error "CRITICAL: No DMG found!"
    print_error "Expected at: $DMG_BUILD_OUTPUT (from build-dmg.sh)"
    print_error "Or at: $DMG_CANONICAL"
    exit 1
fi

# Display the canonical DMG file info
print_info "Canonical DMG: $DMG_CANONICAL"
print_info "Size: $(ls -lh "$DMG_CANONICAL" | awk '{print $5}')"
print_info "Modified: $(stat -f '%Sm' "$DMG_CANONICAL")"

# =============================================================================
# Step 3a: Sign Update with Sparkle EdDSA Key
# =============================================================================
# CRITICAL: We sign $DMG_CANONICAL (~/Downloads/Grok.dmg)
#           The signature MUST match the file we deploy!
#           If you deploy a different file, updates will fail with:
#           "The update is improperly signed and could not be validated"
# =============================================================================

print_header "Step 3a: Signing Update with Sparkle EdDSA Key"

if [ -f "$SCRIPT_DIR/bin/sign_update" ]; then
    print_info "Signing: $DMG_CANONICAL"
    SIGNATURE_OUTPUT=$("$SCRIPT_DIR/bin/sign_update" "$DMG_CANONICAL")
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
        print_info "Signature: ${SIGNATURE:0:40}..."
        print_info "Length: $LENGTH bytes"

        # Store for later verification
        SIGNED_DMG_PATH="$DMG_CANONICAL"
        SIGNED_DMG_LENGTH="$LENGTH"
        SIGNED_DMG_SIGNATURE="$SIGNATURE"
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

# Read release notes from file if it exists
RELEASE_NOTES_FILE="$SCRIPT_DIR/RELEASE_NOTES_$NEW_VERSION.txt"
if [ -f "$RELEASE_NOTES_FILE" ]; then
    # Parse release notes and convert to HTML list items
    NOTES_HTML=$(grep "^•" "$RELEASE_NOTES_FILE" | sed 's/^• /<li>/' | sed 's/$/<\/li>/')
    if [ -z "$NOTES_HTML" ]; then
        NOTES_HTML="<li>Release Notes for $NEW_VERSION</li>"
    fi
else
    print_warning "Release notes file not found: $RELEASE_NOTES_FILE"
    NOTES_HTML="<li>Release Notes for $NEW_VERSION</li>"
fi

cat <<EOF >> "$TMP_CAST"
        <item>
            <title>Version $NEW_VERSION</title>
            <pubDate>$(date -R)</pubDate>
            <description><![CDATA[
                <h2>What's New in $NEW_VERSION</h2>
                <ul>
                    $NOTES_HTML
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
# =============================================================================
# Step 5: Deploy to tofu-main-site
# =============================================================================
# CRITICAL DEPLOYMENT FLOW:
#   1. Validate appcast.xml syntax
#   2. Copy $DMG_CANONICAL (~/Downloads/Grok.dmg) to tofu-main-site
#   3. Verify the copied file has the SAME signature as what's in appcast.xml
#   4. Commit and push
#
# THE #1 CAUSE OF "IMPROPERLY SIGNED" ERRORS:
#   Copying the wrong DMG file! Always use $DMG_CANONICAL.
# =============================================================================

print_header "Step 5: Deploy to tofu-main-site"

if [ -d "$TOFU_REPO_PATH" ]; then

    # =========================================================================
    # PRE-DEPLOYMENT VALIDATION
    # =========================================================================
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

    # =========================================================================
    # COPY FILES (with verification)
    # =========================================================================
    print_header "📤 Copying Files to tofu-main-site"

    # CRITICAL: Copy from $DMG_CANONICAL (~/Downloads/Grok.dmg) ONLY!
    print_info "Source DMG: $DMG_CANONICAL"
    print_info "Destination: $TOFU_DOWNLOADS_PATH/Grok.dmg"

    cp "$DMG_CANONICAL" "$TOFU_DOWNLOADS_PATH/Grok.dmg"
    print_success "Copied Grok.dmg to $TOFU_DOWNLOADS_PATH"

    cp "$APPCAST" "$TOFU_DOWNLOADS_PATH/appcast.xml"
    print_success "Copied appcast.xml to $TOFU_DOWNLOADS_PATH"

    # =========================================================================
    # POST-COPY SIGNATURE VERIFICATION (THE KEY SAFEGUARD!)
    # =========================================================================
    print_header "🔐 Verifying Deployed DMG Signature"

    # Re-sign the DEPLOYED file to verify it matches
    DEPLOYED_DMG="$TOFU_DOWNLOADS_PATH/Grok.dmg"
    DEPLOYED_SIG_OUTPUT=$("$SCRIPT_DIR/bin/sign_update" "$DEPLOYED_DMG")
    DEPLOYED_SIGNATURE=$(echo "$DEPLOYED_SIG_OUTPUT" | grep -o 'edSignature="[^"]*"' | cut -d'"' -f2)
    DEPLOYED_LENGTH=$(echo "$DEPLOYED_SIG_OUTPUT" | grep -o 'length="[^"]*"' | cut -d'"' -f2)

    print_info "Deployed DMG signature: ${DEPLOYED_SIGNATURE:0:40}..."
    print_info "Expected signature:     ${SIGNATURE:0:40}..."

    if [ "$DEPLOYED_SIGNATURE" = "$SIGNATURE" ] && [ "$DEPLOYED_LENGTH" = "$LENGTH" ]; then
        print_success "✅ SIGNATURE VERIFIED! Deployed DMG matches appcast.xml"
    else
        print_error "❌ CRITICAL: SIGNATURE MISMATCH!"
        print_error "Deployed: $DEPLOYED_SIGNATURE"
        print_error "Expected: $SIGNATURE"
        print_error ""
        print_error "This means the WRONG FILE was copied!"
        print_error "Users will see 'improperly signed' error!"
        print_error ""
        print_error "Aborting deployment. Please run release.sh again."
        exit 1
    fi

    # =========================================================================
    # UPDATE WEBSITE VERSION
    # =========================================================================
    if [ -f "$TOFU_GROK_PAGE" ]; then
        sed -i '' "s/Version [0-9.]*[0-9]/Version $NEW_VERSION/g" "$TOFU_GROK_PAGE"
        print_success "Updated version text in $TOFU_GROK_PAGE"
    else
        print_warning "Could not find Grok page at $TOFU_GROK_PAGE"
    fi

    # =========================================================================
    # COMMIT AND PUSH
    # =========================================================================
    print_header "📤 Pushing to GitHub"

    cd "$TOFU_REPO_PATH" || exit
    git add public/downloads/Grok.dmg public/downloads/appcast.xml app/grok/page.tsx
    git commit -m "Release Grok for Mac v$NEW_VERSION (Build $NEW_BUILD)"
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
