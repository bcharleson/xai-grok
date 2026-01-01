# 🚀 Grok for Mac - Notarized Universal Binary Release Workflow

> **NEW WORKFLOW (December 2024)**: This is the official process for releasing notarized universal binaries.

---

## 📋 Overview

This workflow produces a **universal binary** (Apple Silicon + Intel) that is **Apple notarized** for enhanced security and user trust.

**Benefits:**
- ✅ No scary security warnings for users
- ✅ No "Privacy & Security" workarounds needed
- ✅ Professional, trustworthy installation experience
- ✅ Works on both Apple Silicon and Intel Macs

---

## 🎯 Complete Release Process

### **Phase 1: Build & Archive in Xcode**

1. **Open the project in Xcode**
   ```bash
   cd ~/Documents/DeveloperProjects/xAI\ Grok/GrokChat
   open GrokApp.xcodeproj
   ```

2. **Verify build settings**
   - Target: **Any Mac (Apple Silicon, Intel)**
   - Build Configuration: **Release**
   - Code Signing: **Developer ID Application**

3. **Archive the app**
   - Menu: **Product → Archive**
   - Wait for build to complete (~2-3 minutes)
   - Xcode Organizer will open automatically

---

### **Phase 2: Distribute & Notarize**

4. **In Xcode Organizer (Archives window)**
   - Select your latest archive
   - Click **"Distribute App"**

5. **Choose distribution method**
   - Select: **"Direct Distribution"**
   - Click **"Next"**

6. **Distribution options**
   - ✅ **Rebuild from Bitcode:** OFF (not needed for macOS)
   - ✅ **Strip Swift symbols:** ON (reduces size)
   - ✅ **Upload your app to Apple to be notarized:** **ON** ⭐
   - Click **"Next"**

7. **Code signing**
   - **Automatically manage signing** (recommended)
   - Xcode will select your Developer ID certificate
   - Click **"Next"**

8. **Review and upload**
   - Review the summary
   - Click **"Upload"**
   - Xcode uploads to Apple's notary service

9. **Wait for notarization**
   - Dialog shows: "Uploading Grok to Apple notary service"
   - Takes **5-30 minutes** (usually ~10 minutes)
   - You'll see a progress indicator
   - ☕ **Grab coffee while you wait**

10. **Notarization succeeds**
    - Dialog shows: **"App 'Grok' notarized."**
    - Green checkmark ✅
    - Click **"Export..."**

---

### **Phase 3: Export Notarized App**

11. **Export the notarized DMG**
    - Choose save location: **~/Downloads/**
    - Filename: **Grok.dmg**
    - Click **"Export"**
    - The DMG is now ready for distribution!

---

### **Phase 4: Deploy with Automation**

12. **Run the deployment script**
    ```bash
    cd ~/Documents/DeveloperProjects/xAI\ Grok/GrokChat
    ./deploy-notarized.sh 1.0.81 ~/Downloads/Grok.dmg
    ```
    
    Replace `1.0.81` with your version number.

13. **What the script does automatically:**
    - ✅ Updates `Info.plist` with new version/build
    - ✅ Signs DMG with Sparkle EdDSA signature
    - ✅ Updates `appcast.xml` with new release entry
    - ✅ Validates XML syntax
    - ✅ Copies DMG to `tofu-main-site/public/downloads/`
    - ✅ Copies appcast.xml to `tofu-main-site/public/downloads/`
    - ✅ Updates version number on Grok landing page
    - ✅ Commits and pushes to GitHub
    - ✅ Waits for Vercel deployment
    - ✅ Verifies files are live

14. **Script output**
    ```
    🚀 Deploy Notarized Grok for Mac
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    📋 Deployment Information
      Version:         1.0.81
      Build:           81
      Source DMG:      /Users/you/Downloads/Grok.dmg
      Destination:     tofu-main-site/public/downloads/Grok.dmg
    
    ✓ Updated CFBundleShortVersionString to 1.0.81
    ✓ Updated CFBundleVersion to 81
    ✓ DMG signed successfully
    ✓ Updated appcast.xml
    ✓ appcast.xml XML syntax is valid
    ✓ Copied Grok.dmg to tofu-main-site
    ✓ Copied appcast.xml to tofu-main-site
    ✓ Updated version in Grok page
    ✓ Pushed to tofu-main-site
    ✓ appcast.xml is live (HTTP 200)
    ✓ Grok.dmg is live (HTTP 200)
    ✓ Live appcast contains version 1.0.81 (build 81)
    
    ✅ Deployment Complete!
    
    Grok for Mac v1.0.81 (Build 81) is now live!
    ```

---

### **Phase 5: Verify & Announce**

15. **Test the download**
    - Visit: https://www.topoffunnel.com/grok
    - Click "Download for macOS"
    - Verify DMG downloads correctly

16. **Test installation (on a clean Mac if possible)**
    - Open the DMG
    - Drag to Applications
    - Double-click to launch
    - **Should NOT see scary warnings!** ✅
    - Should only see: "Grok is from an identified developer. Are you sure you want to open it?"
    - Click "Open" → App launches successfully

17. **Test auto-update (optional)**
    - Open an older version of Grok
    - Wait for Sparkle to detect the update
    - Verify update downloads and installs correctly

---

## 📊 Version Numbering

- **Marketing Version** (CFBundleShortVersionString): `1.0.81`
  - Format: `MAJOR.MINOR.PATCH`
  - User-facing version number
  
- **Build Number** (CFBundleVersion): `81`
  - Auto-incremented by script
  - Must always increase

---

## 🔧 Troubleshooting

### Notarization Failed

**Error:** "The binary is not signed with a valid Developer ID certificate"
- **Fix:** Ensure you're using **Developer ID Application** certificate, not **Mac App Distribution**

**Error:** "The app contains invalid entitlements"
- **Fix:** Check `GrokChat.entitlements` - remove any App Store-specific entitlements

**Error:** "Notarization timed out"
- **Fix:** Wait longer (can take up to 1 hour during peak times)

### Script Errors

**Error:** "sign_update tool not found"
- **Fix:** Ensure `GrokChat/bin/sign_update` exists and is executable

**Error:** "tofu-main-site repo not found"
- **Fix:** Clone tofu-main-site to `~/Documents/DeveloperProjects/tofu-main-site`

**Error:** "XML syntax is invalid"
- **Fix:** Check `appcast.xml` for unclosed tags or special characters

---

## 📁 File Locations

| File | Location |
|------|----------|
| **Exported DMG** | `~/Downloads/Grok.dmg` |
| **Info.plist** | `GrokChat/Sources/Info.plist` |
| **appcast.xml** | `GrokChat/appcast.xml` |
| **Deployment Script** | `GrokChat/deploy-notarized.sh` |
| **tofu-main-site DMG** | `tofu-main-site/public/downloads/Grok.dmg` |
| **tofu-main-site appcast** | `tofu-main-site/public/downloads/appcast.xml` |
| **Grok Landing Page** | `tofu-main-site/app/grok/page.tsx` |

---

## 🎯 Quick Reference

**One-command deployment after exporting from Xcode:**
```bash
./deploy-notarized.sh 1.0.XX ~/Downloads/Grok.dmg
```

**Verify deployment:**
```bash
curl -I https://www.topoffunnel.com/downloads/Grok.dmg
curl -I https://www.topoffunnel.com/downloads/appcast.xml
```

---

## 🚨 Important Notes

1. **Always export from Xcode Organizer** - Don't use the old `build-dmg.sh` script
2. **Wait for notarization to complete** - Don't skip this step!
3. **Test on a clean Mac** - Verify no security warnings appear
4. **Keep your Developer ID certificate valid** - Renew before expiration
5. **Backup your Sparkle signing keys** - Stored in macOS Keychain

---

**Last Updated:** December 24, 2024
**Workflow Version:** 2.0 (Notarized Universal Binary)

