#!/usr/bin/env bash
# Kullanım: ./script/release.sh 1.0
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "Kullanım: $0 <versiyon>  (örn. 1.0)" >&2
  exit 1
fi

APP_NAME="Mimir"
BUNDLE_ID="com.erayendes.mimir"
MIN_SYSTEM_VERSION="14.0"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"

cd "$ROOT_DIR"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

echo "→ Derleniyor: $APP_NAME $VERSION"
# -g: release build'de debug bilgisi üret ki dSYM çıkarılabilsin (Sentry sembolleştirme)
swift build -c release -Xswiftc -g
BUILD_DIR="$(swift build -c release --show-bin-path)"

echo "→ dSYM çıkarılıyor"
rm -rf "$DIST_DIR/$APP_NAME.app.dSYM"
mkdir -p "$DIST_DIR"
dsymutil "$BUILD_DIR/$APP_NAME" -o "$DIST_DIR/$APP_NAME.app.dSYM"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

[ -f "$ROOT_DIR/Sources/Mimir/Resources/Mimir.icns" ] && \
  cp "$ROOT_DIR/Sources/Mimir/Resources/Mimir.icns" "$APP_BUNDLE/Contents/Resources/"
cp -R "$ROOT_DIR/Sources/Mimir/Resources/BrandIcons" "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
cp "$ROOT_DIR/Sources/Mimir/Resources/AppIcon.png" "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
cp "$ROOT_DIR/Sources/Mimir/Resources/MenuIcon.png" "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true

cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
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
  <string>$VERSION</string>
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

# Sparkle.framework'ü bundle'a kopyala
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"
SPARKLE_FW="$(find "$ROOT_DIR/.build/artifacts" -name "Sparkle.framework" -type d | head -1)"
if [ -z "$SPARKLE_FW" ]; then
  echo "ERROR: Sparkle.framework bulunamadı — önce 'swift build -c release' çalıştırın" >&2
  exit 1
fi
cp -R "$SPARKLE_FW" "$FRAMEWORKS_DIR/"

echo "✓ dist/Mimir.app hazır"

if [ "${SKIP_ZIP:-false}" = "true" ]; then
  echo "  (zip atlandı — CI imzalama sonrası paketleyecek)"
  exit 0
fi

echo "→ Zip oluşturuluyor: $ZIP_NAME"
rm -f "$ZIP_PATH"
cd "$DIST_DIR"
zip -qr "$ZIP_NAME" "$APP_NAME.app"
cd "$ROOT_DIR"

SHA256=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')

# Sparkle EdDSA imzası
SIGN_UPDATE="$(find "$ROOT_DIR/.build/artifacts" -name "sign_update" -type f | head -1)"
if [ -n "$SIGN_UPDATE" ]; then
  SIG_OUTPUT=$("$SIGN_UPDATE" "$ZIP_PATH" 2>/dev/null || true)
  ED_SIG=$(echo "$SIG_OUTPUT" | grep -o 'edSignature="[^"]*"' | cut -d'"' -f2)
  ZIP_LEN=$(echo "$SIG_OUTPUT" | grep -o 'length="[^"]*"' | cut -d'"' -f2)
  if [ -n "$ED_SIG" ] && [ -n "$ZIP_LEN" ]; then
    python3 "$ROOT_DIR/script/gen_appcast_item.py" \
      --version "$VERSION" \
      --url "https://github.com/erayendes/mimir/releases/download/v${VERSION}/${ZIP_NAME}" \
      --signature "$ED_SIG" \
      --length "$ZIP_LEN" \
      --appcast "$ROOT_DIR/appcast.xml"
    echo "✓ appcast.xml güncellendi"
  else
    echo "⚠️  Sparkle imzası alınamadı (Keychain'de anahtar yok?). appcast.xml güncellenmedi."
  fi
else
  echo "⚠️  sign_update bulunamadı. appcast.xml güncellenmedi."
fi

echo ""
echo "✓ dist/$ZIP_NAME hazır"
echo "  SHA256: $SHA256"
echo ""
echo "Sonraki adımlar:"
echo "  git tag v$VERSION && git push origin v$VERSION"
echo ""
echo "Homebrew cask için:"
echo "  sha256 \"$SHA256\""
echo "  url \"https://github.com/erayendes/mimir/releases/download/v$VERSION/$ZIP_NAME\""
