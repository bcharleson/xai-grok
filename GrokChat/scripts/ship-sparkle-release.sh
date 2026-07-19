#!/bin/bash
# =============================================================================
# ship-sparkle-release.sh
#
# Post-notarize publisher for Grok for Mac (proven with 1.0.89 / build 56).
#
# Prerequisites:
#   - Notarized + stapled Grok.app (Developer ID)
#   - Sparkle EdDSA private key in login Keychain (account ed25519)
#   - Public key must be: a+vXV7cwhCxuoSLMpuoX8e1G8O223alkm0FX+QxYHlk=
#
# Usage:
#   ./scripts/ship-sparkle-release.sh \
#     --app "/path/to/Submissions/<UUID>/Grok.app" \
#     --version 1.0.90 \
#     --build 57 \
#     --notes $'Bullet one\nBullet two'
#
# Optional:
#   --skip-push     Update tofu files locally but do not commit/push
#   --dry-run       Print actions only
# =============================================================================

set -euo pipefail

EXPECTED_PUBLIC_KEY="a+vXV7cwhCxuoSLMpuoX8e1G8O223alkm0FX+QxYHlk="
SPARKLE_BIN="${SPARKLE_BIN:-$HOME/Documents/DeveloperProjects/xAI Grok/GrokChat/bin}"
GEN="$SPARKLE_BIN/generate_keys"
SIGN="$SPARKLE_BIN/sign_update"
TOFU_ROOT="${TOFU_ROOT:-$HOME/Developer/tofu-main-site}"
APPCAST="$TOFU_ROOT/public/downloads/appcast.xml"
TOFU_DMG="$TOFU_ROOT/public/downloads/Grok.dmg"
GROK_PAGE="$TOFU_ROOT/app/grok/page.tsx"
DMG_OUT="${DMG_OUT:-$HOME/Desktop/Grok.dmg}"

APP=""
VERSION=""
BUILD=""
NOTES="Bug fixes and improvements"
SKIP_PUSH=false
DRY_RUN=false

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --notes) NOTES="$2"; shift 2 ;;
    --skip-push) SKIP_PUSH=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1"; usage ;;
  esac
done

[[ -n "$APP" && -n "$VERSION" && -n "$BUILD" ]] || usage
[[ -d "$APP" ]] || { echo "❌ App not found: $APP"; exit 1; }
[[ -x "$GEN" && -x "$SIGN" ]] || { echo "❌ Sparkle tools missing in: $SPARKLE_BIN"; exit 1; }
[[ -f "$APPCAST" && -f "$GROK_PAGE" ]] || { echo "❌ tofu-main-site missing at: $TOFU_ROOT"; exit 1; }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Grok Sparkle ship — $VERSION (build $BUILD)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# --- Key safety gate ---------------------------------------------------------
PUBLIC_KEY="$("$GEN" -p 2>/dev/null | tr -d '\n')"
if [[ "$PUBLIC_KEY" != "$EXPECTED_PUBLIC_KEY" ]]; then
  echo "❌ Wrong Sparkle key in Keychain."
  echo "   Got:      $PUBLIC_KEY"
  echo "   Expected: $EXPECTED_PUBLIC_KEY"
  echo "   Import the OLD key (generate_keys -f). Do NOT generate a new key."
  exit 1
fi
echo "✅ Sparkle public key matches production"

APP_KEY="$(defaults read "$APP/Contents/Info" SUPublicEDKey 2>/dev/null || true)"
APP_VER="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)"
APP_BUILD="$(defaults read "$APP/Contents/Info" CFBundleVersion)"
if [[ "$APP_KEY" != "$EXPECTED_PUBLIC_KEY" ]]; then
  echo "❌ App SUPublicEDKey mismatch: $APP_KEY"
  exit 1
fi
if [[ "$APP_VER" != "$VERSION" || "$APP_BUILD" != "$BUILD" ]]; then
  echo "❌ App version/build mismatch."
  echo "   App has:  $APP_VER ($APP_BUILD)"
  echo "   You passed: $VERSION ($BUILD)"
  exit 1
fi
echo "✅ App metadata: $APP_VER ($APP_BUILD), correct SUPublicEDKey"

if ! spctl -a -vv "$APP" 2>&1 | grep -q "Notarized Developer ID"; then
  echo "❌ App is not notarized (spctl). Staple first: xcrun stapler staple \"$APP\""
  exit 1
fi
echo "✅ Notarized Developer ID"

if [[ "$DRY_RUN" == true ]]; then
  echo "(dry-run) would package DMG, sign, update appcast/page, push tofu"
  exit 0
fi

# --- DMG ---------------------------------------------------------------------
STAGE="$(mktemp -d /tmp/GrokDMG.XXXXXX)"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

ditto "$APP" "$STAGE/Grok.app"
ln -sf /Applications "$STAGE/Applications"
rm -f "$DMG_OUT"
hdiutil create -volname "Grok" -srcfolder "$STAGE" -ov -format UDZO "$DMG_OUT" >/dev/null
LENGTH="$(stat -f%z "$DMG_OUT")"
echo "✅ DMG: $DMG_OUT ($LENGTH bytes)"

# --- Sparkle sign ------------------------------------------------------------
SIGN_OUT="$("$SIGN" "$DMG_OUT")"
echo "$SIGN_OUT"
ED_SIG="$(echo "$SIGN_OUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
SIGN_LEN="$(echo "$SIGN_OUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
[[ -n "$ED_SIG" && "$SIGN_LEN" == "$LENGTH" ]] || { echo "❌ sign_update failed"; exit 1; }
"$SIGN" --verify "$DMG_OUT" "$ED_SIG" >/dev/null
echo "✅ Sparkle signature verified"

# --- Appcast insert ----------------------------------------------------------
PUBDATE="$(date -R)"
NOTES_HTML=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  NOTES_HTML+="                    <li>${line}</li>"$'\n'
done <<< "$NOTES"
NOTES_HTML="${NOTES_HTML%$'\n'}"

ITEM_FILE="$(mktemp)"
cat > "$ITEM_FILE" <<EOF
        <!-- LATEST VERSION: ${VERSION} (Build ${BUILD}) -->
        <item>
            <title>Version ${VERSION}</title>
            <pubDate>${PUBDATE}</pubDate>
            <description><![CDATA[
                <h2>What's New in ${VERSION}</h2>
                <ul>
${NOTES_HTML}
                    <li>Universal binary (Apple Silicon + Intel)</li>
                    <li>Apple notarized for enhanced security</li>
                </ul>
            ]]></description>
            <enclosure
                url="https://www.topoffunnel.com/downloads/Grok.dmg"
                sparkle:version="${BUILD}"
                sparkle:shortVersionString="${VERSION}"
                sparkle:edSignature="${ED_SIG}"
                length="${LENGTH}"
                type="application/octet-stream"
            />
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
        </item>
EOF

python3 - "$APPCAST" "$ITEM_FILE" <<'PY'
import sys
from pathlib import Path

appcast = Path(sys.argv[1])
item = Path(sys.argv[2]).read_text()
text = appcast.read_text()
marker = "        <!-- LATEST VERSION:"
idx = text.find(marker)
if idx < 0:
    # Fallback: insert after <language>…</language>
    lang = text.find("</language>")
    if lang < 0:
        raise SystemExit("Could not find insertion point in appcast.xml")
    insert_at = text.find("\n", lang) + 1
    text = text[:insert_at] + "\n" + item + "\n" + text[insert_at:]
else:
    # Replace previous "LATEST VERSION" comment wording on old item
    text = text.replace("<!-- LATEST VERSION:", "<!-- VERSION:", 1)
    text = text[:idx] + item + "\n" + text[idx:]
appcast.write_text(text)
print("Updated", appcast)
PY

# --- Page version line -------------------------------------------------------
python3 - "$GROK_PAGE" "$VERSION" <<'PY'
import re, sys
from pathlib import Path
path = Path(sys.argv[1])
version = sys.argv[2]
text = path.read_text()
new, n = re.subn(
    r"Version 1\.\d+\.\d+ • macOS",
    f"Version {version} • macOS",
    text,
    count=1,
)
if n != 1:
    raise SystemExit(f"Could not update version line in {path}")
path.write_text(new)
print("Updated", path)
PY

cp "$DMG_OUT" "$TOFU_DMG"
echo "✅ Copied DMG → $TOFU_DMG"

# --- Deploy ------------------------------------------------------------------
if [[ "$SKIP_PUSH" == true ]]; then
  echo "⏭  --skip-push: tofu files updated locally only"
  exit 0
fi

cd "$TOFU_ROOT"
git add public/downloads/Grok.dmg public/downloads/appcast.xml app/grok/page.tsx
git commit -m "Ship Grok ${VERSION} (Build ${BUILD})"
git push origin HEAD
echo "✅ Pushed tofu-main-site"

echo
echo "Wait for Vercel, then verify:"
echo "  curl -sL https://www.topoffunnel.com/downloads/appcast.xml | sed -n '39,62p'"
echo "  curl -sI https://www.topoffunnel.com/downloads/Grok.dmg | rg -i content-length"
echo
echo "Done — users on the original Sparkle key will see ${VERSION}."
