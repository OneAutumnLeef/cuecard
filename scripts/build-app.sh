#!/bin/bash
# Builds a SwiftPM executable and wraps it in a signed .app bundle, using only the Command Line Tools.
#
#   scripts/build-app.sh <package-dir> <product> <bundle-id> [debug|release]
#
# Build output goes to ~/Library/Caches/MacTele, outside iCloud Drive, so iCloud never syncs
# thousands of temporary files. Signing uses the "MacTele Local Dev" identity from
# scripts/setup-signing.sh when it exists (permissions survive rebuilds); otherwise ad-hoc.
# Optional env: SIGN_ID, VERSION, ICON (.icns path), DISPLAY_NAME, URL_SCHEME.
set -euo pipefail

PKG_DIR="$1"; PRODUCT="$2"; BUNDLE_ID="$3"; CONFIG="${4:-debug}"
CACHE="$HOME/Library/Caches/MacTele"
SCRATCH="$CACHE/build/$(basename "$PKG_DIR")"
APP_DIR="$CACHE/apps"
SIGN_ID="${SIGN_ID:--}"
VERSION="${VERSION:-0.0.1}"

swift build --package-path "$PKG_DIR" --scratch-path "$SCRATCH" -c "$CONFIG" --product "$PRODUCT" >&2
BIN="$(swift build --package-path "$PKG_DIR" --scratch-path "$SCRATCH" -c "$CONFIG" --show-bin-path)/$PRODUCT"

APP="$APP_DIR/$PRODUCT.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$PRODUCT"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$PRODUCT</string>
    <key>CFBundleExecutable</key><string>$PRODUCT</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>The teleprompter listens to you so it can follow your place in the script.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Your speech is recognised on this Mac to match it against your script.</string>
</dict>
</plist>
PLIST

[ -n "${ICON:-}" ] && [ -f "$ICON" ] && cp "$ICON" "$APP/Contents/Resources/AppIcon.icns" && \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
[ -n "${DISPLAY_NAME:-}" ] && /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $DISPLAY_NAME" "$APP/Contents/Info.plist"
if [ -n "${URL_SCHEME:-}" ]; then
  /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" -c "Add :CFBundleURLTypes:0 dict" \
    -c "Add :CFBundleURLTypes:0:CFBundleURLName string $BUNDLE_ID" \
    -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" \
    -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string $URL_SCHEME" "$APP/Contents/Info.plist"
fi

# Prefer the stable local identity from scripts/setup-signing.sh, so macOS keeps permissions across rebuilds.
SIGN_DIR="$HOME/Library/Application Support/MacTele/signing"
if [ "$SIGN_ID" = "-" ] && [ -f "$SIGN_DIR/dev.keychain-db" ]; then
  security unlock-keychain -p "$(cat "$SIGN_DIR/password")" "$SIGN_DIR/dev.keychain-db"
  codesign --force --keychain "$SIGN_DIR/dev.keychain-db" --sign "MacTele Local Dev" --timestamp=none "$APP" >&2
else
  codesign --force --sign "$SIGN_ID" --timestamp=none "$APP" >&2
fi
echo "$APP"
