#!/usr/bin/env bash
# Usage: ./script/release.sh <version> "<release notes>"
# Example: ./script/release.sh 1.8 "Added Gemini support"
set -euo pipefail

VERSION="${1:-}"
NOTES="${2:-}"

if [ -z "$VERSION" ] || [ -z "$NOTES" ]; then
  echo "usage: $0 <version> \"<release notes>\""
  echo "   eg: $0 1.8 \"Added Gemini support\""
  exit 1
fi

APP_NAME="Mimir"
BUNDLE_ID="com.erayendes.mimir"
MIN_SYSTEM_VERSION="14.0"
BUILD_NUMBER="$(echo "$VERSION" | tr -d '.')"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
ZIP_PATH="$DIST_DIR/Mimir.zip"
SIGN_UPDATE="$(find "$ROOT_DIR/.build/artifacts" -name "sign_update" -not -path "*/old_dsa*" -type f | head -1)"

cd "$ROOT_DIR"

echo "▶ Releasing Mimir v$VERSION (build $BUILD_NUMBER)"
echo ""

# ── 1. Bump version in build_and_run.sh so dev builds stay in sync
echo "── Bumping version..."
sed -i '' "s/^MARKETING_VERSION=.*/MARKETING_VERSION=\"$VERSION\"/" script/build_and_run.sh
sed -i '' "s/^BUILD_NUMBER=.*/BUILD_NUMBER=\"$BUILD_NUMBER\"/" script/build_and_run.sh

# ── 2. Build (release, with debug info for Sentry symbolication)
echo "── Building..."
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
swift build -c release -Xswiftc -g
BUILD_DIR="$(swift build -c release --show-bin-path)"

# ── 3. Assemble bundle
echo "── Assembling bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources" "$APP_CONTENTS/Frameworks"

cp "$BUILD_DIR/$APP_NAME" "$APP_CONTENTS/MacOS/$APP_NAME"
chmod +x "$APP_CONTENTS/MacOS/$APP_NAME"

[ -f "$ROOT_DIR/Sources/Mimir/Resources/Mimir.icns" ] && \
  cp "$ROOT_DIR/Sources/Mimir/Resources/Mimir.icns" "$APP_CONTENTS/Resources/"
cp -R "$ROOT_DIR/Sources/Mimir/Resources/BrandIcons" "$APP_CONTENTS/Resources/" 2>/dev/null || true
cp "$ROOT_DIR/Sources/Mimir/Resources/AppIcon.png"   "$APP_CONTENTS/Resources/" 2>/dev/null || true
cp "$ROOT_DIR/Sources/Mimir/Resources/MenuIcon.png"  "$APP_CONTENTS/Resources/" 2>/dev/null || true

cat > "$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>Mimir</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <string>1</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>SUFeedURL</key>
  <string>https://raw.githubusercontent.com/erayendes/mimir/main/appcast.xml</string>
  <key>SUPublicEDKey</key>
  <string>AL98f6dND8KQ8nhLPIcesddvzdSXi2d7jQ5AQ3PEbAY=</string>
</dict>
</plist>
PLIST

# ── 4. Embed Sparkle.framework
SPARKLE_FW="$(find "$ROOT_DIR/.build/artifacts" -name "Sparkle.framework" -type d | head -1)"
if [ -z "$SPARKLE_FW" ]; then
  echo "✗ Sparkle.framework not found. Run 'swift build' first." >&2
  exit 1
fi
cp -R "$SPARKLE_FW" "$APP_CONTENTS/Frameworks/"

# ── 5. Codesign (inner → outer, preserve Hardened Runtime)
echo "── Signing bundle..."
xattr -cr "$APP_BUNDLE"
SPARKLE_B="$APP_CONTENTS/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign - --options runtime "$SPARKLE_B/XPCServices/Downloader.xpc"
codesign --force --sign - --options runtime "$SPARKLE_B/XPCServices/Installer.xpc"
codesign --force --sign - --options runtime "$SPARKLE_B/Updater.app"
codesign --force --sign -                   "$SPARKLE_B/Autoupdate"
codesign --force --sign - --options runtime "$APP_CONTENTS/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP_BUNDLE"

# ── 6. dSYM (for Sentry)
echo "── Extracting dSYM..."
rm -rf "$DIST_DIR/$APP_NAME.app.dSYM"
dsymutil "$BUILD_DIR/$APP_NAME" -o "$DIST_DIR/$APP_NAME.app.dSYM"

# ── 7. Zip (--symlinks preserves framework symlink structure)
echo "── Zipping..."
rm -f "$ZIP_PATH"
cd "$DIST_DIR"
zip -r --symlinks Mimir.zip Mimir.app --quiet
cd "$ROOT_DIR"
ZIP_SIZE="$(wc -c < "$ZIP_PATH" | tr -d ' ')"

# ── 8. Sign the zip → get edSignature
echo "── Getting edSignature..."
if [ -z "$SIGN_UPDATE" ]; then
  echo "✗ sign_update not found. Run 'swift build' first." >&2
  exit 1
fi
SIGN_OUTPUT="$("$SIGN_UPDATE" "$ZIP_PATH" 2>&1)"
ED_SIG="$(echo "$SIGN_OUTPUT" | grep -oE 'edSignature="[^"]+"' | cut -d'"' -f2)"
if [ -z "$ED_SIG" ]; then
  echo "✗ sign_update failed — is the Sparkle private key in your Keychain?" >&2
  echo "$SIGN_OUTPUT" >&2
  exit 1
fi

# ── 9. Update appcast.xml
echo "── Updating appcast.xml..."
python3 "$ROOT_DIR/script/gen_appcast_item.py" \
  --version "$VERSION" \
  --build-number "$BUILD_NUMBER" \
  --url "https://github.com/erayendes/mimir/releases/download/v${VERSION}/Mimir.zip" \
  --signature "$ED_SIG" \
  --length "$ZIP_SIZE" \
  --notes "$NOTES" \
  --appcast "$ROOT_DIR/appcast.xml"

# ── 10. Commit + tag
echo "── Committing..."
git add appcast.xml script/build_and_run.sh
git commit -m "chore: release v$VERSION"
git tag "v$VERSION"

# ── 11. GitHub release + upload zip
echo "── Creating GitHub release..."
if gh release view "v$VERSION" &>/dev/null; then
  gh release upload "v$VERSION" "$ZIP_PATH" --clobber
  gh release edit "v$VERSION" --title "Mimir v$VERSION" --notes "$NOTES"
else
  gh release create "v$VERSION" "$ZIP_PATH" \
    --title "Mimir v$VERSION" \
    --notes "$NOTES"
fi

# ── 12. Push
echo "── Pushing..."
git push && git push --tags

echo ""
echo "✓ Mimir v$VERSION released"
echo "  https://github.com/erayendes/mimir/releases/tag/v$VERSION"
