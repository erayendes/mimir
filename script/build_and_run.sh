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

# WIDGET=1 builds + embeds the WidgetKit extension and signs the bundle with Developer ID so the
# App Group shared container resolves (ad-hoc signing has no Team ID → no container). Default off,
# so the everyday `./script/build_and_run.sh` stays fast and ad-hoc as before.
WIDGET="${WIDGET:-0}"
APP_GROUP="group.com.erayendes.mimir"
if [ "$WIDGET" = "1" ]; then
  SIGN_ID="${SIGN_ID:-Developer ID Application: Eray Endes (926AC5V2UG)}"
  # App Groups for a widget extension need a provisioning profile, which is tied to the prod
  # app-id. So a widget build uses the prod bundle id (quit the shipped Mimir while testing).
  BUNDLE_ID="com.erayendes.mimir"
else
  SIGN_ID="${SIGN_ID:--}"   # ad-hoc
fi

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
cp -R "$ROOT_DIR/Sources/Mimir/Resources/en.lproj" "$APP_RESOURCES/" 2>/dev/null || true
cp -R "$ROOT_DIR/Sources/Mimir/Resources/tr.lproj" "$APP_RESOURCES/" 2>/dev/null || true
cp "$ROOT_DIR/Sources/Mimir/Resources/AppIcon.png" "$APP_RESOURCES/" 2>/dev/null || true
cp "$ROOT_DIR/Sources/Mimir/Resources/MenuIcon.png" "$APP_RESOURCES/" 2>/dev/null || true

# When embedding a widget, give the host a version so it matches the extension (avoids the
# "extension version must match host" validation); normal dev builds omit it (footer shows "dev").
# CFBundleVersion is a fresh epoch each build: chronod (the widget gallery daemon) caches extension
# metadata keyed by version, so a constant build number leaves the gallery showing a STALE widget
# after code changes. A monotonically increasing build number forces it to re-read every time.
WIDGET_BUILD_NUM="$(date +%s)"
EXTRA_PLIST=""
if [ "$WIDGET" = "1" ]; then
  EXTRA_PLIST="  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>$WIDGET_BUILD_NUM</string>"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
$EXTRA_PLIST
  <key>MimirAppGroup</key>
  <string>$APP_GROUP</string>
  <key>CFBundleExecutable</key>
  <string>$PRODUCT</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>tr</string>
  </array>
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

# Build + embed the WidgetKit extension (.appex) into Contents/PlugIns (WIDGET=1 only). The Xcode
# project is generated from WidgetExtension/project.yml; the appex is built UNSIGNED here and signed
# below (inside-out, with its own entitlements).
if [ "$WIDGET" = "1" ]; then
  echo "▶ Building widget extension..."
  xcodegen generate --spec "$ROOT_DIR/WidgetExtension/project.yml" --project "$ROOT_DIR/WidgetExtension" >/dev/null
  WIDGET_BUILD="$ROOT_DIR/.build/widget"
  rm -rf "$WIDGET_BUILD"
  xcodebuild -project "$ROOT_DIR/WidgetExtension/MimirWidgetExtension.xcodeproj" \
    -target MimirWidgetExtension -configuration Release \
    MARKETING_VERSION=1.0 CURRENT_PROJECT_VERSION="$WIDGET_BUILD_NUM" \
    CONFIGURATION_BUILD_DIR="$WIDGET_BUILD" CODE_SIGNING_ALLOWED=NO build >/dev/null
  mkdir -p "$APP_CONTENTS/PlugIns"
  rm -rf "$APP_CONTENTS/PlugIns/MimirWidgetExtension.appex"
  cp -R "$WIDGET_BUILD/MimirWidgetExtension.appex" "$APP_CONTENTS/PlugIns/"
  # Embed provisioning profiles (these authorise the App Group entitlement for Developer ID).
  cp "$ROOT_DIR/signing/Mimir_App.provisionprofile" "$APP_CONTENTS/embedded.provisionprofile"
  cp "$ROOT_DIR/signing/Mimir_Widget.provisionprofile" "$APP_CONTENTS/PlugIns/MimirWidgetExtension.appex/Contents/embedded.provisionprofile"
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
  codesign --force --sign "$SIGN_ID" --options runtime "$SPARKLE_B/XPCServices/Downloader.xpc"
  codesign --force --sign "$SIGN_ID" --options runtime "$SPARKLE_B/XPCServices/Installer.xpc"
  codesign --force --sign "$SIGN_ID" --options runtime "$SPARKLE_B/Updater.app"
  codesign --force --sign "$SIGN_ID"                   "$SPARKLE_B/Autoupdate"
  codesign --force --sign "$SIGN_ID" --options runtime "$TMP_BUNDLE/Contents/Frameworks/Sparkle.framework"
fi

# Sign the widget extension with its OWN sandbox + App Group entitlements, inside-out (before the
# host app). Not via `codesign --deep` — that cannot apply per-nested entitlements and would strip
# the appex's App Group access.
if [ "$WIDGET" = "1" ]; then
  codesign --force --sign "$SIGN_ID" --options runtime \
    --entitlements "$ROOT_DIR/WidgetExtension/MimirWidget/MimirWidget.dev.entitlements" \
    "$TMP_BUNDLE/Contents/PlugIns/MimirWidgetExtension.appex"
fi

# Seal the whole app bundle last. With a widget, the host carries the App Group entitlement so both
# processes resolve the same shared container; otherwise sign ad-hoc as before.
if [ "$WIDGET" = "1" ]; then
  codesign --force --sign "$SIGN_ID" --options runtime \
    --entitlements "$ROOT_DIR/Sources/Mimir/Mimir.dev.entitlements" "$TMP_BUNDLE"
else
  codesign --force --sign "$SIGN_ID" "$TMP_BUNDLE"
fi
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
