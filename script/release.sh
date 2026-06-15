#!/usr/bin/env bash
# Usage: ./script/release.sh <version> "<release notes>"
# Example: ./script/release.sh 1.8 "Added Gemini support"
set -euo pipefail

VERSION="${1:-}"
NOTES="${2:-}"

# BUILD_ONLY=1 → build + assemble bundle + dSYM, then stop (no sign/notarize/
# publish). This is the CI entry point: GitHub Actions does Developer ID signing,
# notarization, Sparkle signing, appcast and the GitHub release itself.
BUILD_ONLY="${BUILD_ONLY:-}"

if [ -z "$VERSION" ]; then
  echo "usage: $0 <version> \"<release notes>\"   (notes optional when BUILD_ONLY=1)"
  echo "   eg: $0 1.8 \"Added Gemini support\""
  exit 1
fi
if [ -z "$BUILD_ONLY" ] && [ -z "$NOTES" ]; then
  echo "✗ release notes required for a full local release (or set BUILD_ONLY=1)" >&2
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
# Resolved lazily: .build/artifacts only exists after `swift build` fetches the
# Sparkle binary, and under `set -o pipefail` a failing find here would abort the
# whole script before the build even runs. Tolerate absence; BUILD_ONLY never uses it.
SIGN_UPDATE="$(find "$ROOT_DIR/.build/artifacts" -name "sign_update" -not -path "*/old_dsa*" -type f 2>/dev/null | head -1 || true)"

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
ditto --norsrc "$SPARKLE_FW" "$APP_CONTENTS/Frameworks/Sparkle.framework"

# ── BUILD_ONLY stop: hand the unsigned bundle + dSYM to CI, which signs with the
# Developer ID cert, notarizes, and publishes. Avoids ad-hoc signing the artifact
# that ships to users.
if [ -n "$BUILD_ONLY" ]; then
  echo "── Extracting dSYM..."
  rm -rf "$DIST_DIR/$APP_NAME.app.dSYM"
  dsymutil "$BUILD_DIR/$APP_NAME" -o "$DIST_DIR/$APP_NAME.app.dSYM"
  echo "✓ BUILD_ONLY: dist/$APP_NAME.app (unsigned) + dSYM ready for CI"
  exit 0
fi

# ── 5. Codesign (inner → outer, preserve Hardened Runtime)
# Sign from /tmp — iCloud Drive (bird daemon) re-adds com.apple.fileprovider.fpfs#P
# to bundle directories inside ~/Documents, which codesign rejects.
echo "── Signing bundle..."
TMP_BUNDLE="/tmp/${APP_NAME}_release.app"
rm -rf "$TMP_BUNDLE"
ditto --norsrc "$APP_BUNDLE" "$TMP_BUNDLE"
xattr -cr "$TMP_BUNDLE" 2>/dev/null || true

SPARKLE_B_TMP="$TMP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign - --options runtime "$SPARKLE_B_TMP/XPCServices/Downloader.xpc"
codesign --force --sign - --options runtime "$SPARKLE_B_TMP/XPCServices/Installer.xpc"
codesign --force --sign - --options runtime "$SPARKLE_B_TMP/Updater.app"
codesign --force --sign -                   "$SPARKLE_B_TMP/Autoupdate"
codesign --force --sign - --options runtime "$TMP_BUNDLE/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$TMP_BUNDLE"

# Copy signed bundle back (without xattrs)
rm -rf "$APP_BUNDLE"
ditto --norsrc "$TMP_BUNDLE" "$APP_BUNDLE"
rm -rf "$TMP_BUNDLE"

# ── 6. dSYM (for Sentry)
echo "── Extracting dSYM..."
rm -rf "$DIST_DIR/$APP_NAME.app.dSYM"
dsymutil "$BUILD_DIR/$APP_NAME" -o "$DIST_DIR/$APP_NAME.app.dSYM"

# ── 7. Zip from /tmp to avoid iCloud xattr contamination
echo "── Zipping..."
TMP_ZIP_DIR="/tmp/MimirRelease_zip"
rm -rf "$TMP_ZIP_DIR" && mkdir "$TMP_ZIP_DIR"
ditto --norsrc "$APP_BUNDLE" "$TMP_ZIP_DIR/$APP_NAME.app"
xattr -cr "$TMP_ZIP_DIR/$APP_NAME.app" 2>/dev/null || true
rm -f "$ZIP_PATH"
cd "$TMP_ZIP_DIR"
zip -r --symlinks "$ZIP_PATH" "$APP_NAME.app" --quiet
cd "$ROOT_DIR"
rm -rf "$TMP_ZIP_DIR"
ZIP_SIZE="$(wc -c < "$ZIP_PATH" | tr -d ' ')"

# ── 8. Sign the zip → get edSignature
echo "── Getting edSignature..."
if [ -z "$SIGN_UPDATE" ]; then
  echo "✗ sign_update not found. Run 'swift build' first." >&2
  exit 1
fi

# Sign without leaving a persistent private key on disk. sign_update reading the
# key straight from the Keychain triggers a GUI authorization prompt that
# headless/agent shells can't satisfy, but generate_keys' Keychain access is
# already authorized — so we export the key to a temp file (in $TMPDIR, which is
# NOT cloud-synced), sign with --ed-key-file, then delete it on exit.
#
# CI / externally-managed key: set SPARKLE_PRIVATE_KEY_FILE to a key file path
# and it's used as-is (never deleted, never exported from Keychain).
if [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
  if [ ! -f "$SPARKLE_PRIVATE_KEY_FILE" ]; then
    echo "✗ SPARKLE_PRIVATE_KEY_FILE set but not found: $SPARKLE_PRIVATE_KEY_FILE" >&2
    exit 1
  fi
  KEY_FILE="$SPARKLE_PRIVATE_KEY_FILE"
else
  GEN_KEYS="$(find "$ROOT_DIR/.build/artifacts" -name generate_keys -type f | head -1)"
  if [ -z "$GEN_KEYS" ]; then
    echo "✗ generate_keys not found. Run 'swift build' first." >&2
    exit 1
  fi
  # generate_keys -x refuses to overwrite an existing file, so hand it a path
  # inside a fresh 0700 temp dir rather than a pre-created mktemp file.
  KEY_DIR="$(mktemp -d -t mimir_sparkle)"
  KEY_FILE="$KEY_DIR/ed_private_key"
  trap 'rm -rf "$KEY_DIR"' EXIT
  if ! "$GEN_KEYS" -x "$KEY_FILE" >/dev/null 2>&1; then
    echo "✗ Could not export the Sparkle key from the Keychain." >&2
    echo "  Generate/import it once with: $GEN_KEYS" >&2
    exit 1
  fi
fi

SIGN_OUTPUT="$("$SIGN_UPDATE" --ed-key-file "$KEY_FILE" "$ZIP_PATH" 2>&1)"
ED_SIG="$(echo "$SIGN_OUTPUT" | grep -oE 'edSignature="[^"]+"' | cut -d'"' -f2)"
# Shred the temp key as soon as we're done with it (don't wait for EXIT trap).
if [ -z "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
  rm -rf "$KEY_DIR"
  trap - EXIT
fi
if [ -z "$ED_SIG" ]; then
  echo "✗ sign_update failed." >&2
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

# ── 11. Push first — gh release create refuses a tag that isn't on the remote yet,
# so the commit and tag must land before we cut the release.
echo "── Pushing..."
git push
git push origin "v$VERSION"

# ── 12. GitHub release + upload zip
echo "── Creating GitHub release..."
if gh release view "v$VERSION" &>/dev/null; then
  gh release upload "v$VERSION" "$ZIP_PATH" --clobber
  gh release edit "v$VERSION" --title "Mimir v$VERSION" --notes "$NOTES"
else
  gh release create "v$VERSION" "$ZIP_PATH" \
    --title "Mimir v$VERSION" \
    --notes "$NOTES"
fi

echo ""
echo "✓ Mimir v$VERSION released"
echo "  https://github.com/erayendes/mimir/releases/tag/v$VERSION"
