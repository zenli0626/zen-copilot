#!/bin/bash
# Build NotchPilot.app — a proper, launchable menu-bar app bundle.
#
# A bare `swift run` binary has no bundle identifier or signature, so macOS
# notifications won't fire and it ties up a terminal. This wraps the release
# binary into NotchPilot.app with an Info.plist (bundle id, LSUIElement) and
# ad-hoc code signature, so notifications work and it launches from Finder/open.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Swift product/executable name (the target in Package.swift) vs. the
# user-facing app display name. Keeping the product name lets us rename the app
# without touching the Swift module/dir.
PRODUCT_NAME="NotchPilot"
APP_NAME="Zen-Copilot"
BUNDLE_ID="com.zenli.zencopilot"
APP_DIR="$ROOT/dist/$APP_NAME.app"
VERSION="1.0.0"

echo "==> Building release binary…"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/$PRODUCT_NAME"
[ -x "$BIN" ] || { echo "ERROR: built binary not found at $BIN" >&2; exit 1; }

echo "==> Assembling $APP_DIR …"
# Remove any prior bundle under either name so we don't leave a stale app around.
rm -rf "$APP_DIR" "$ROOT/dist/$PRODUCT_NAME.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key><string>Zen-Copilot brings the Claude Code terminal tab you click to the front, and needs permission to control your terminal app to do so.</string>
    <key>NSHumanReadableCopyright</key><string>NotchPilot</string>
</dict>
</plist>
PLIST

# Code signing.
#
# Default: ad-hoc ("-"). This builds and runs anywhere with no developer cert,
# so a stranger can clone and build immediately. The trade-off: ad-hoc
# signatures have no stable designated requirement, so macOS TCC grants
# (Automation + Accessibility) reset on every rebuild and you'll be re-prompted.
#
# For a stable signature whose TCC grants PERSIST across rebuilds, export your
# own codesign identity hash before building:
#   export ZENCOPILOT_SIGN_ID=<your codesign identity hash>
# Find it with:  security find-identity -v -p codesigning
SIGN_ID="${ZENCOPILOT_SIGN_ID:-}"
if [ -n "$SIGN_ID" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  echo "==> Code signing with stable identity ($SIGN_ID)…"
  codesign --force --deep --sign "$SIGN_ID" "$APP_DIR" \
    && echo "   signed; TCC grants will persist across rebuilds" \
    || echo "   WARNING: signing failed — falling back to ad-hoc (grants will reset)"
else
  if [ -n "$SIGN_ID" ]; then
    echo "==> WARNING: ZENCOPILOT_SIGN_ID ($SIGN_ID) not found in keychain; ad-hoc signing instead"
  else
    echo "==> Ad-hoc signing (default). Set ZENCOPILOT_SIGN_ID=<hash> for a stable signature whose TCC grants persist across rebuilds."
  fi
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "==> Done: $APP_DIR"
echo "   Launch with:  open \"$APP_DIR\""
