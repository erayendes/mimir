#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
# The local build IS this machine's Mimir: the same bundle as a release (release.sh builds it),
# signed with Developer ID so the widget and App Group work, installed over /Applications/Mimir.app.
# There is no separate dev app — stable and beta can't sit side by side anyway (one bundle id).
#
# Version: the release branch's version ("release/3.0-beta.4" → 3.0-beta.4), else the last tag.
# `MimirLocalBuild` in Info.plist keeps Sentry and TelemetryDeck quiet. The build number is the
# LAST RELEASED tag's plus a timestamp component (299999002.<epoch>):
# Sparkle compares component-wise, so it leaves this build alone until the next release ships, then
# replaces it with that notarized artifact; and chronod, which caches widget metadata by version,
# sees a new one every build instead of showing a stale widget.
PRODUCT="Mimir"
BUNDLE_ID="com.erayendes.mimir"
SIGN_ID="${SIGN_ID:-Developer ID Application: Eray Endes (926AC5V2UG)}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/$PRODUCT.app"
INSTALLED="/Applications/$PRODUCT.app"
cd "$ROOT_DIR"

LAST_TAG="$(git describe --tags --abbrev=0 --match 'v*')"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
case "$BRANCH" in
  release/*) VERSION="${BRANCH#release/}" ;;
  *)         VERSION="${LAST_TAG#v}" ;;
esac
export BUILD_NUMBER="$(bash script/build_number.sh "${LAST_TAG#v}").$(date +%s)"
BUILD_ONLY=1 bash script/release.sh "$VERSION"
/usr/libexec/PlistBuddy -c "Add :MimirLocalBuild bool true" "$APP_BUNDLE/Contents/Info.plist"

# Sign inside-out like CI (release.yml), from a temp dir: iCloud Drive re-adds xattrs codesign rejects.
# A private dir, not a fixed /tmp path another user could claim first.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
TMP_BUNDLE="$TMP_DIR/${PRODUCT}_local.app"
ditto --norsrc "$APP_BUNDLE" "$TMP_BUNDLE"
xattr -cr "$TMP_BUNDLE" 2>/dev/null || true
sign() { codesign --force --sign "$SIGN_ID" --options runtime "$@"; }
SPARKLE_B="$TMP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE_B/XPCServices/Downloader.xpc"
sign "$SPARKLE_B/XPCServices/Installer.xpc"
sign "$SPARKLE_B/Updater.app"
sign "$SPARKLE_B/Autoupdate"
sign "$TMP_BUNDLE/Contents/Frameworks/Sparkle.framework"
sign --entitlements WidgetExtension/MimirWidget/MimirWidget.entitlements \
  "$TMP_BUNDLE/Contents/PlugIns/MimirWidgetExtension.appex"
sign --entitlements Sources/Mimir/Mimir.entitlements "$TMP_BUNDLE"

rm -rf "$INSTALLED"
ditto --norsrc "$TMP_BUNDLE" "$INSTALLED"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALLED"

launch_app() {
  /usr/bin/open "$INSTALLED"
}

case "$MODE" in
  run)
    launch_app
    ;;
  --debug|debug)
    lldb -- "$INSTALLED/Contents/MacOS/$PRODUCT"
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
