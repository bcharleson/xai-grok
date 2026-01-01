# Grok Release Workflow (2025)

## ⚠️ IMPORTANT: New Workflow

As of December 2024, we use **Cursor Commands** for all releases. The old shell scripts (`release.sh`, `deploy-notarized.sh`) are **DEPRECATED** and should not be used.

---

## The New Release Process

### Step 1: Build & Notarize in Xcode (You Do This)

1. **Build**: `Product → Build` (⌘B) with Release configuration
2. **Archive**: `Product → Archive`
3. **Notarize & Export**:
   - In Organizer: `Distribute App`
   - Choose: `Developer ID` (not App Store!)
   - Wait for notarization email from Apple
   - Export to: `~/Desktop/Grok.app`

### Step 2: Run Cursor Command (AI Does This)

```
/release-grok
```

That's it! The command handles everything:
- ✅ Creates DMG from notarized app
- ✅ Signs DMG (both code signing and Sparkle)
- ✅ Updates appcast.xml
- ✅ Deploys to tofu-main-site
- ✅ Updates website version
- ✅ Commits and pushes to GitHub
- ✅ Verifies deployment

---

## Available Commands

### Primary Commands

#### `/release-grok` - Main Release Command
**Use for**: All normal releases (version bumps, new features, bug fixes)

**Prerequisites**:
- Notarized `Grok.app` at `~/Desktop/Grok.app`
- Optional: Release notes file `RELEASE_NOTES_X.X.XX.txt`

**What it does**: Complete end-to-end release automation

---

#### `/quick-fix-release` - Emergency Hotfix
**Use for**: Urgent patches without version changes

**Prerequisites**:
- Notarized `Grok.app` at `~/Desktop/Grok.app`
- Same version number as current release

**What it does**: Re-packages and deploys current version with fixes

---

#### `/verify-release` - Post-Deployment Check
**Use for**: Verifying a release is live and working

**Prerequisites**: None

**What it does**: 
- Checks DMG accessibility
- Validates appcast.xml
- Verifies signatures
- Confirms version alignment

---

#### `/rollback-release` - Emergency Rollback
**Use for**: Critical issues requiring immediate rollback

**Prerequisites**: Previous version's DMG file

**What it does**: Reverts to previous stable version

---

## Version & Build Numbers

### Where They're Set
- **Primary Source**: `GrokApp.xcodeproj/project.pbxproj`
  - `MARKETING_VERSION` = Version (e.g., "1.0.83")
  - `CURRENT_PROJECT_VERSION` = Build (e.g., "50")
- **Derived**: `Sources/Info.plist` (uses Xcode variables)

### Version Scheme
- **Major**: Breaking changes (2.0.0)
- **Minor**: New features (1.1.0)  
- **Patch**: Bug fixes (1.0.1)
- **Build**: Auto-increments for each release

### Updating Version
1. In Xcode: Select project → General → Identity
2. Update "Version" (e.g., 1.0.84)
3. Update "Build" (e.g., 51)
4. Build, Archive, Notarize, Export
5. Run `/release-grok`

---

## File Structure

```
xAI Grok/
├── .cursor/
│   └── commands/
│       ├── release-grok.md          ← Main release command
│       ├── quick-fix-release.md     ← Hotfix command
│       ├── verify-release.md        ← Verification command
│       └── rollback-release.md      ← Rollback command
│
├── GrokChat/
│   ├── Sources/
│   │   └── Info.plist               ← Version info (uses Xcode vars)
│   ├── GrokApp.xcodeproj/
│   │   └── project.pbxproj          ← Master version source
│   ├── Grok.entitlements            ← App permissions
│   ├── appcast.xml                  ← Sparkle update feed
│   ├── RELEASE_NOTES_X.X.XX.txt    ← Release notes (optional)
│   ├── bin/
│   │   └── sign_update              ← Sparkle signing tool
│   │
│   ├── release.sh                   ← ⚠️ DEPRECATED - DO NOT USE
│   ├── deploy-notarized.sh          ← ⚠️ DEPRECATED - DO NOT USE
│   └── build-dmg.sh                 ← ⚠️ DEPRECATED - DO NOT USE
│
└── tofu-main-site/
    ├── public/downloads/
    │   ├── Grok.dmg                 ← Production DMG
    │   └── appcast.xml              ← Production appcast
    └── app/grok/page.tsx            ← Download page
```

---

## Release Notes (Optional)

Create a file named `RELEASE_NOTES_X.X.XX.txt` before running `/release-grok`:

```
Version X.X.XX (Build YY) - Brief Title

What's New:
• Feature: Description of new feature
• Fix: Bug fix description
• Improvement: Enhancement description

Technical Changes:
• Updated dependencies
• Performance improvements
• Security enhancements
```

If no release notes file exists, a generic entry is created.

---

## Troubleshooting

### "App not found at ~/Desktop/Grok.app"
**Solution**: Make sure you exported from Xcode Organizer to Desktop

### "App is not notarized"
**Solution**: Wait for Apple's notarization email, then export again

### "Signature mismatch"
**Solution**: The DMG changed after signing. Run `/release-grok` again

### "XML invalid"
**Solution**: Check `appcast.xml` for syntax errors

### "Sparkle signing failed"
**Solution**: Verify EdDSA keys are in macOS Keychain

### "Deployment failed"
**Solution**: 
1. Check internet connection
2. Verify GitHub credentials
3. Check tofu-main-site repo access

---

## Testing Releases

### Before Public Release
1. Install on clean Mac
2. Verify no Gatekeeper warnings
3. Test microphone/camera permissions
4. Test Grokipedia login
5. Test voice recording

### After Public Release
1. Run `/verify-release`
2. Download from topoffunnel.com
3. Test Sparkle auto-update from previous version
4. Monitor error reports

---

## Emergency Procedures

### Critical Bug Found After Release

**Option 1: Quick Hotfix**
1. Fix bug in code
2. Build, Archive, Notarize, Export
3. Run `/quick-fix-release`

**Option 2: New Patch Release**
1. Fix bug
2. Bump patch version (e.g., 1.0.83 → 1.0.84)
3. Build, Archive, Notarize, Export  
4. Run `/release-grok`

**Option 3: Rollback** (Last Resort)
1. Get previous version's DMG
2. Run `/rollback-release`
3. Fix issue and re-release ASAP

---

## Key Changes from Old Workflow

### What Changed
- ❌ No more `release.sh` script
- ❌ No more `deploy-notarized.sh` script
- ❌ No more `build-dmg.sh` script
- ✅ Xcode handles all building/archiving/notarizing
- ✅ Cursor commands handle all deployment
- ✅ Clearer separation: You build, AI deploys

### Why Changed
- **Simpler**: Fewer manual steps
- **Safer**: Notarization happens in Xcode (more reliable)
- **Faster**: One command vs multiple scripts
- **Better**: Proper notarization every time
- **Clearer**: Explicit prerequisites

---

## Support

If you encounter issues not covered here:
1. Check Xcode Organizer for notarization status
2. Verify all prerequisites are met
3. Run `/verify-release` to check current state
4. Check terminal output for specific errors

---

**Last Updated**: December 28, 2024  
**Current Version**: 1.0.83 (Build 50)  
**Workflow Version**: 2.0
