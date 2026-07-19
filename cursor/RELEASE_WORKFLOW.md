# Grok for Mac — Sparkle Release Workflow (authoritative)

> Proven on **2026-07-19** with **1.0.89 (build 56)**.  
> Follow this exact path for every public update so existing users get Sparkle notifications.

## Critical rules (do not break)

1. **Never run bare `generate_keys`** on a release Mac. That creates a *new* key and breaks updates for everyone who already has the app installed.
2. **Always verify the public key before signing:**
   ```bash
   "/Users/brandoncharleson/Documents/DeveloperProjects/xAI Grok/GrokChat/bin/generate_keys" -p
   ```
   Must print exactly:
   ```text
   a+vXV7cwhCxuoSLMpuoX8e1G8O223alkm0FX+QxYHlk=
   ```
   That same string must be in `GrokChat/Sources/Info.plist` → `SUPublicEDKey`.
3. **Build number must always increase** (`CURRENT_PROJECT_VERSION`). Marketing version (`1.0.x`) can stay or bump; Sparkle keys off build.
4. **One production key.** Private key lives only in **Keychain** (and offline encrypted backups). Never put `eddsa_private_key*` files inside this git repo. Sync Macs with `generate_keys -x` / `-f` outside the repo.

5. **What is safe in git:** `SUPublicEDKey` (public). ExportOptions team ID. Release docs.  
   **What must stay out:** private EdDSA seed, `GrokChat/bin/`, appcast with live signatures is optional/private infra, `.p12` / Developer ID keys.

## Paths

| What | Path |
|------|------|
| App source | `$HOME/Developer/xai-grok-macos/GrokChat` |
| Website / feed host | `$HOME/Developer/tofu-main-site` |
| Live feed | `https://www.topoffunnel.com/downloads/appcast.xml` |
| Live DMG | `https://www.topoffunnel.com/downloads/Grok.dmg` |
| Sparkle tools | `$HOME/Documents/DeveloperProjects/xAI Grok/GrokChat/bin/{generate_keys,sign_update}` |
| Export options | `GrokChat/Release/ExportOptions-Upload.plist` |
| Team ID | `CC989JZCNV` |

---

## Phase 0 — Preflight

```bash
GEN="/Users/brandoncharleson/Documents/DeveloperProjects/xAI Grok/GrokChat/bin/generate_keys"
SIGN="/Users/brandoncharleson/Documents/DeveloperProjects/xAI Grok/GrokChat/bin/sign_update"

# 1) Correct Sparkle key in Keychain
"$GEN" -p
# → a+vXV7cwhCxuoSLMpuoX8e1G8O223alkm0FX+QxYHlk=

# 2) Info.plist still has that public key
rg -A1 'SUPublicEDKey' ~/Developer/xai-grok-macos/GrokChat/Sources/Info.plist

# 3) Live build number (new build must be higher)
curl -sL https://www.topoffunnel.com/downloads/appcast.xml | rg 'sparkle:version=' | head -1
```

---

## Phase 1 — Bump version

Edit **both** Release and Debug configs in:

`GrokChat/GrokApp.xcodeproj/project.pbxproj`

- `MARKETING_VERSION` → e.g. `1.0.90`
- `CURRENT_PROJECT_VERSION` → e.g. `57` (**must be > live**)

`Info.plist` uses `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` — do not hardcode versions there.  
Do **not** change `SUPublicEDKey` or `SUFeedURL`.

---

## Phase 2 — Archive (Release)

```bash
cd ~/Developer/xai-grok-macos/GrokChat

ARCHIVE_DIR="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)"
mkdir -p "$ARCHIVE_DIR"
ARCHIVE_PATH="$ARCHIVE_DIR/Grok-VERSION-$(date +%H%M%S).xcarchive"

xcodebuild archive \
  -project GrokApp.xcodeproj \
  -scheme Grok \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=CC989JZCNV

# Confirm metadata before uploading
defaults read "$ARCHIVE_PATH/Products/Applications/Grok.app/Contents/Info" CFBundleShortVersionString
defaults read "$ARCHIVE_PATH/Products/Applications/Grok.app/Contents/Info" CFBundleVersion
defaults read "$ARCHIVE_PATH/Products/Applications/Grok.app/Contents/Info" SUPublicEDKey
# SUPublicEDKey must be a+vXV7cwhCxuoSLMpuoX8e1G8O223alkm0FX+QxYHlk=
```

---

## Phase 3 — Developer ID export + notarize

Uses cloud-managed Developer ID (local Keychain may only show Apple Development — that is OK).

```bash
EXPORT_OPTS="$HOME/Developer/xai-grok-macos/GrokChat/Release/ExportOptions-Upload.plist"
EXPORT_DIR="/tmp/GrokExport"
rm -rf "$EXPORT_DIR" && mkdir -p "$EXPORT_DIR"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  -allowProvisioningUpdates
```

Notarized app lands at:

```text
$ARCHIVE_PATH/Submissions/<UUID>/Grok.app
```

Staple (poll until ticket exists):

```bash
APP="$ARCHIVE_PATH/Submissions/<UUID>/Grok.app"
# Find UUID:
ls "$ARCHIVE_PATH/Submissions"

until xcrun stapler staple "$APP" 2>&1 | grep -q 'worked'; do
  sleep 15
done
xcrun stapler validate "$APP"
spctl -a -vv "$APP"   # → accepted, Notarized Developer ID
```

Optional local install:

```bash
ditto "$APP" /Applications/Grok.app
```

---

## Phase 4 — DMG + Sparkle sign + publish

Preferred: run the ship script (wraps the exact commands from 1.0.89):

```bash
cd ~/Developer/xai-grok-macos/GrokChat
./scripts/ship-sparkle-release.sh \
  --app "$APP" \
  --version 1.0.90 \
  --build 57 \
  --notes "Short bullet list of what's new"
```

What it does:

1. Builds `~/Desktop/Grok.dmg` (UDZO, Applications symlink)
2. Signs with Keychain EdDSA key via `sign_update`
3. Inserts a new top `<item>` in `tofu-main-site/public/downloads/appcast.xml`
4. Copies DMG → `tofu-main-site/public/downloads/Grok.dmg`
5. Updates version string on `tofu-main-site/app/grok/page.tsx`
6. Commits + pushes `tofu-main-site` `main` (Vercel deploys)

### Manual equivalent (if not using the script)

```bash
SIGN="/Users/brandoncharleson/Documents/DeveloperProjects/xAI Grok/GrokChat/bin/sign_update"
DMG="$HOME/Desktop/Grok.dmg"
STAGE="/tmp/GrokDMG"
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Grok.app"
ln -sf /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Grok" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

"$SIGN" "$DMG"
# → sparkle:edSignature="..." length="..."

cp "$DMG" ~/Developer/tofu-main-site/public/downloads/Grok.dmg
# Edit appcast.xml: new <item> ABOVE previous latest
# Edit app/grok/page.tsx version line
cd ~/Developer/tofu-main-site
git add public/downloads/Grok.dmg public/downloads/appcast.xml app/grok/page.tsx
git commit -m "Ship Grok VERSION (Build BUILD)"
git push origin main
```

---

## Phase 5 — Verify live

```bash
curl -sL "https://www.topoffunnel.com/downloads/appcast.xml" | sed -n '39,62p'
# Expect new shortVersionString + matching edSignature + length

curl -sI "https://www.topoffunnel.com/downloads/Grok.dmg" | rg -i content-length
# Must equal appcast length=

curl -sL "https://www.topoffunnel.com/grok" | rg -o 'Version 1\.0\.[0-9]+'
```

Then on a machine with an older install: **Grok → Check for Updates**.

---

## If the Sparkle key is missing on this Mac

Do **not** generate a new key. Export from the Mac that still has it:

```bash
# On Mac that has the OLD key (confirm -p first!)
generate_keys -p   # must be a+vXV7...
generate_keys -x ~/Desktop/eddsa_private_key_OLD

# On this Mac
# Remove conflicting key if generate_keys -f errors:
security delete-generic-password -a ed25519 -s "https://sparkle-project.org"
generate_keys -f ~/Desktop/eddsa_private_key_OLD
generate_keys -p   # must be a+vXV7...
```

---

## Appcast item template

```xml
<!-- LATEST VERSION: VERSION (Build BUILD) -->
<item>
    <title>Version VERSION</title>
    <pubDate>RFC-2822 date from date -R</pubDate>
    <description><![CDATA[
        <h2>What's New in VERSION</h2>
        <ul>
            <li>…</li>
        </ul>
    ]]></description>
    <enclosure
        url="https://www.topoffunnel.com/downloads/Grok.dmg"
        sparkle:version="BUILD"
        sparkle:shortVersionString="VERSION"
        sparkle:edSignature="FROM_sign_update"
        length="FROM_sign_update"
        type="application/octet-stream"
    />
    <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
</item>
```

Keep the filename **`Grok.dmg`** forever. Versioning lives only in `appcast.xml`.
