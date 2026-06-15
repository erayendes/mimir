#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Mimir"
BUNDLE_ID="com.erayendes.mimir"
MIN_SYSTEM_VERSION="14.0"
MARKETING_VERSION="1.8"
BUILD_NUMBER="18"
# SUFeedURL lokal test için: http://localhost:8765/appcast.xml
# Production için Info.plist'teki değer kullanılır (aşağıda)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

cd "$ROOT_DIR"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

# Derleme yap ve yolu al
swift build -c release
BUILD_DIR="$(swift build -c release --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"

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
  <string>$APP_NAME</string>
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
  <key>CFBundleShortVersionString</key>
  <string>$MARKETING_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>SUFeedURL</key>
  <string>https://raw.githubusercontent.com/erayendes/mimir/main/appcast.xml</string>
  <key>SUPublicEDKey</key>
  <string>AL98f6dND8KQ8nhLPIcesddvzdSXi2d7jQ5AQ3PEbAY=</string>
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

# Clear quarantine/provenance attributes inherited from SPM download
xattr -cr "$APP_BUNDLE"

# Sign Sparkle's nested components first (deepest level → outward).
# --options runtime preserves Hardened Runtime so Updater.app and XPC services launch correctly.
SPARKLE_B="$FRAMEWORKS_DIR/Sparkle.framework/Versions/B"
if [ -d "$SPARKLE_B" ]; then
  codesign --force --sign - --options runtime "$SPARKLE_B/XPCServices/Downloader.xpc"
  codesign --force --sign - --options runtime "$SPARKLE_B/XPCServices/Installer.xpc"
  codesign --force --sign - --options runtime "$SPARKLE_B/Updater.app"
  codesign --force --sign -                   "$SPARKLE_B/Autoupdate"
  codesign --force --sign - --options runtime "$FRAMEWORKS_DIR/Sparkle.framework"
fi

# Seal the whole app bundle last
codesign --force --sign - "$APP_BUNDLE"

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
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    launch_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    launch_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
