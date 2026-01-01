# 🚀 Grok for Mac - Complete Release Workflow

> **CRITICAL**: This is the authoritative guide for safe releases. Follow every step exactly.

---

## 📁 Repository Structure Reference

| Repository | URL | Purpose |
|------------|-----|---------|
| **PRIVATE** | `github.com/bcharleson/xai-grok-private` | Active development + release infrastructure |
| **PUBLIC** | `github.com/bcharleson/xai-grok` | Open source (no signing keys, no appcast) |
| **WEBSITE** | `github.com/bcharleson/tofu-main-site` | Hosts DMG + appcast.xml at topoffunnel.com |

---

## 1️⃣ Daily Development Workflow

### Making Code Changes

```bash
# 1. Navigate to private repo
cd ~/Documents/DeveloperProjects/xAI\ Grok

# 2. Make your changes in Xcode or editor

# 3. Test in Xcode (⌘R to run)

# 4. Commit to private repo
git add .
git commit -m "Description of changes"
git push origin main
```

### Syncing to Public Repository

```bash
# After committing to private, sync to public
./sync-to-public.sh
```

**What sync-to-public.sh does:**
- Copies source files to public repo
- Excludes: `bin/`, `appcast.xml`, `release.sh`, signing keys
- Replaces `SUFeedURL` with placeholder
- Commits and pushes to public

---

## 2️⃣ Pre-Release Checklist

Before running `./release.sh`, verify ALL of these:

### ☐ Code Ready
- [ ] All changes committed to private repo
- [ ] App builds without errors in Xcode (⌘B)
- [ ] App runs correctly (⌘R) - test key features
- [ ] No console errors in Xcode debug output

### ☐ Version Planning
- [ ] Decided on version number (e.g., `1.0.80`)
- [ ] Build number will auto-increment (or specify manually)
- [ ] Release notes ready (what's new in this version)

### ☐ Environment Check
```bash
# Verify Sparkle signing key is accessible
security find-generic-password -s "ed25519" 2>/dev/null && echo "✅ EdDSA key found"

# Verify sign_update tool exists
ls -la GrokChat/bin/sign_update && echo "✅ sign_update found"

# Verify tofu-main-site is available
ls ~/Documents/DeveloperProjects/tofu-main-site/public/downloads/ && echo "✅ tofu-main-site ready"
```

### ☐ Clean State
```bash
# Ensure NO stale Grok.dmg in GrokChat folder
ls GrokChat/Grok.dmg 2>/dev/null && echo "⚠️ DELETE THIS FILE!" || echo "✅ No stale DMG"

# Check ~/Downloads for old DMGs (optional cleanup)
ls -la ~/Downloads/Grok*.dmg 2>/dev/null
```

---

## 3️⃣ Release Execution

### Step 1: Navigate to GrokChat
```bash
cd ~/Documents/DeveloperProjects/xAI\ Grok/GrokChat
```

### Step 2: Run Release Script
```bash
./release.sh 1.0.80
```
(Replace `1.0.80` with your target version)

### Step 3: Monitor Output - Watch For These Checkpoints

```
✅ Step 1: Updated MARKETING_VERSION and CURRENT_PROJECT_VERSION
✅ Step 2: Build complete (build-dmg.sh succeeded)
✅ Step 3: Moved DMG to ~/Downloads/Grok.dmg
✅ Step 3a: Update signed successfully (signature displayed)
✅ Step 4: appcast.xml updated with new entry
✅ Pre-Deployment: XML syntax valid
✅ Pre-Deployment: appcast.xml contains build XX
✅ Post-Copy: SIGNATURE VERIFIED! ← CRITICAL!
✅ Pushed release to tofu-main-site
```

### ⚠️ IF YOU SEE "SIGNATURE MISMATCH" - STOP!
The script will abort automatically. See Error Recovery section below.

---

## 4️⃣ Post-Release Verification

### Immediate Checks (within 2 minutes)

```bash
# 1. Verify appcast.xml is live (wait ~60 seconds for Vercel)
curl -s "https://www.topoffunnel.com/downloads/appcast.xml" | grep "LATEST VERSION"
# Should show your new version

# 2. Verify DMG is downloadable
curl -I "https://www.topoffunnel.com/downloads/Grok.dmg" | head -5
# Should show HTTP 200

# 3. Verify signature in live appcast matches what you deployed
curl -s "https://www.topoffunnel.com/downloads/appcast.xml" | grep -A2 "sparkle:version=\"XX\""
# Replace XX with your build number
```

### Real User Test (recommended)

1. **On another Mac** (or VM) with an older version installed:
   - Open Grok app
   - Click "Check for Updates..." in menu
   - Should show update available
   - Click "Install Update"
   - **Must complete without "improperly signed" error**

2. **If no second Mac available:**
   - Download fresh DMG from https://www.topoffunnel.com/grok
   - Open the app
   - Verify version in About panel matches release

### Website Verification
- Visit https://www.topoffunnel.com/grok
- Verify version number displays correctly
- Test download button works

---

## 5️⃣ Error Recovery

### Scenario A: Build Failed (before deployment)

```bash
# Safe - nothing deployed yet
# Fix the build error in Xcode, then:
./release.sh 1.0.80  # Same version, try again
```

### Scenario B: Signature Mismatch Detected

The script auto-aborts before push. This is safe.

```bash
# 1. Delete any stale DMG files
rm -f ~/Downloads/Grok.dmg ~/Desktop/Grok.dmg GrokChat/Grok.dmg

# 2. Clean Xcode build
cd GrokChat && rm -rf build/ DerivedData/

# 3. Rebuild from scratch
./release.sh 1.0.80
```

### Scenario C: Deployed but Update Fails for Users

**CRITICAL: Users are seeing "improperly signed" error**

```bash
# 1. Verify which file has wrong signature
cd GrokChat
./bin/sign_update ~/Documents/DeveloperProjects/tofu-main-site/public/downloads/Grok.dmg
# Compare output to appcast.xml

# 2. If mismatch, copy correct DMG
cp ~/Downloads/Grok.dmg ~/Documents/DeveloperProjects/tofu-main-site/public/downloads/

# 3. Verify signature now matches
./bin/sign_update ~/Documents/DeveloperProjects/tofu-main-site/public/downloads/Grok.dmg
# This MUST match the signature in appcast.xml

# 4. Commit fix
cd ~/Documents/DeveloperProjects/tofu-main-site
git add public/downloads/Grok.dmg
git commit -m "Fix: Deploy correctly signed DMG"
git push origin main
```

### Scenario D: Need to Rollback to Previous Version

```bash
# 1. In appcast.xml, move the previous version's <item> to the top
# 2. Copy the old DMG (if you have it) or note: users will stay on current

# IMPORTANT: Sparkle uses build NUMBER for comparison
# A rollback only works if the old build number is HIGHER
# Usually you should just fix forward with a new version
```

### Scenario E: Git Corruption (can't commit)

```bash
# 1. Backup your changes
cp release.sh /tmp/release.sh.backup
cp appcast.xml /tmp/appcast.xml.backup

# 2. Fresh clone
cd ~/Documents/DeveloperProjects
git clone https://github.com/bcharleson/xai-grok-private.git xai-grok-fresh

# 3. Copy your files to fresh clone
cp /tmp/release.sh.backup xai-grok-fresh/GrokChat/release.sh
cp /tmp/appcast.xml.backup xai-grok-fresh/GrokChat/appcast.xml
# Copy other modified files as needed

# 4. Rename directories
mv "xAI Grok" "xAI Grok-corrupted"
mv xai-grok-fresh "xAI Grok"
```

---

## 📋 Quick Reference Card

### The Golden Rule
```
DMG Flow: ~/Desktop/Grok.dmg → ~/Downloads/Grok.dmg → tofu-main-site
          (build-dmg.sh)        (CANONICAL - sign here)   (deploy)

NEVER copy Grok.dmg from GrokChat/ folder!
```

### One-Command Release
```bash
cd ~/Documents/DeveloperProjects/xAI\ Grok/GrokChat && ./release.sh 1.0.XX
```

### Emergency Signature Verification
```bash
# Check deployed file matches appcast
./bin/sign_update ~/Documents/DeveloperProjects/tofu-main-site/public/downloads/Grok.dmg
grep "edSignature" ~/Documents/DeveloperProjects/tofu-main-site/public/downloads/appcast.xml | head -1
```

### Key URLs
- **Appcast Feed**: https://www.topoffunnel.com/downloads/appcast.xml
- **DMG Download**: https://www.topoffunnel.com/downloads/Grok.dmg
- **Landing Page**: https://www.topoffunnel.com/grok

---

## 📊 Version Number Reference

| Component | Location | Updated By |
|-----------|----------|------------|
| MARKETING_VERSION | `project.pbxproj` | release.sh |
| CURRENT_PROJECT_VERSION | `project.pbxproj` | release.sh |
| About Panel | Dynamic | Reads from Bundle |
| Settings Panel | Dynamic | Reads from Bundle |
| appcast.xml | `GrokChat/appcast.xml` | release.sh |
| Landing Page | `app/grok/page.tsx` | release.sh |

---

*Last updated: December 19, 2025*
*After signature mismatch incident - safeguards added*

