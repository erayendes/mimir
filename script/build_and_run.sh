#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
# Dev builds get a separate identity from the production app: distinct bundle id,
# name ("Mimir Dev"), no version string and no Sparkle feed. This keeps them out
# of the production app's UserDefaults / login item / auto-update state, and the
# popover footer shows "Mimir dev" (the missing version falls back to "dev").
PRODUCT="Mimir"            # swift product / executable name (Contents/MacOS/Mimir)
APP_NAME="Mimir Dev"       # bundle + display name
BUNDLE_ID="com.erayendes.mimir.dev"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$PRODUCT"
INFO_PLIST="$APP_CONTENTS/Info.plist"

cd "$ROOT_DIR"

pkill -x "$PRODUCT" >/dev/null 2>&1 || true

# Derleme yap ve yolu al
swift build -c release
BUILD_DIR="$(swift build -c release --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$PRODUCT"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
mkdir -p "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

# İkonları ve kaynakları kopyala
if [ -f "$ROOT_DIR/Sources/Mimir/Resources/Mimir.icns" ]; then
  cp "$ROOT_DIR/Sources/Mimir/Resources/Mimir.icns" "$APP_RESOURCES/"
fi
cp -R "$ROOT_DIR/Sources/Mimir/Resources/BrandIcons" "$APP_RESOURCES/" 2>/dev/null || true
cp "$ROOT_DIR/Sources/Mimir/Resources/AppIcon.png" "$APP_RESOURCES/" 2>/dev/null || true
cp "$ROOT_DIR/Sources/Mimir/Resources/MenuIcon.png" "$APP_RESOURCES/" 2>/dev/null || true

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$PRODUCT</string>
  <key>CFBundleIconFile</key>
  <string>Mimir</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <string>1</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# Sparkle.framework'ü bundle'a kopyala
FRAMEWORKS_DIR="$APP_CONTENTS/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"
SPARKLE_FW="$(find "$ROOT_DIR/.build/artifacts" -name "Sparkle.framework" -type d | head -1)"
if [ -n "$SPARKLE_FW" ]; then
  ditto --norsrc "$SPARKLE_FW" "$FRAMEWORKS_DIR/Sparkle.framework"
fi

# Sign from /tmp — iCloud Drive (bird daemon) keeps re-adding extended attributes
# to bundles under ~/Documents, which codesign rejects ("resource fork ... not
# allowed"). Sign a clean copy outside the synced tree, then ditto it back.
TMP_BUNDLE="/tmp/${PRODUCT}_dev.app"
rm -rf "$TMP_BUNDLE"
ditto --norsrc "$APP_BUNDLE" "$TMP_BUNDLE"
xattr -cr "$TMP_BUNDLE" 2>/dev/null || true

# Sign Sparkle's nested components first (deepest level → outward).
# --options runtime preserves Hardened Runtime so Updater.app and XPC services launch correctly.
SPARKLE_B="$TMP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"
if [ -d "$SPARKLE_B" ]; then
  codesign --force --sign - --options runtime "$SPARKLE_B/XPCServices/Downloader.xpc"
  codesign --force --sign - --options runtime "$SPARKLE_B/XPCServices/Installer.xpc"
  codesign --force --sign - --options runtime "$SPARKLE_B/Updater.app"
  codesign --force --sign -                   "$SPARKLE_B/Autoupdate"
  codesign --force --sign - --options runtime "$TMP_BUNDLE/Contents/Frameworks/Sparkle.framework"
fi

# Seal the whole app bundle last, then copy the signed bundle back over the original.
codesign --force --sign - "$TMP_BUNDLE"
rm -rf "$APP_BUNDLE"
ditto --norsrc "$TMP_BUNDLE" "$APP_BUNDLE"
rm -rf "$TMP_BUNDLE"

launch_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

install_app() {
  DEST_DIR="/Applications"
  echo "Installing to $DEST_DIR/$APP_NAME.app..."
  
  # Eski yerel kurulumu temizle (varsa)
  rm -rf "$HOME/Applications/$APP_NAME.app"
  
  # Ana dizine kur
  rm -rf "$DEST_DIR/$APP_NAME.app"
  cp -R "$APP_BUNDLE" "$DEST_DIR/"
  xattr -cr "$DEST_DIR/$APP_NAME.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST_DIR/$APP_NAME.app"
  
  echo "Installation complete! Mimir is now in /Applications."
  /usr/bin/open -a "$DEST_DIR/$APP_NAME.app"
}

case "$MODE" in
  run)
    launch_app
    ;;
  install)
    install_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    launch_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PRODUCT\""
    ;;
  --telemetry|telemetry)
    launch_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    launch_app
    sleep 1
    pgrep -x "$PRODUCT" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
