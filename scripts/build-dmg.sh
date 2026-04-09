#!/usr/bin/env bash
# build-dmg.sh — Build a release .app bundle and package it as a signed DMG
# Usage: ./scripts/build-dmg.sh [version]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SWIFT_DIR="$REPO/src-swift"

APP_NAME="Murmur"
BUNDLE_ID="com.murmurtype"
VERSION="${1:-$(defaults read "$SWIFT_DIR/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "2.0")}"

DIST_DIR="$REPO/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_OUT="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
BG_IMG="$DIST_DIR/dmg-background.png"

echo "▶ Building murmur $VERSION"
echo ""

# ── 1. Build universal release binary ────────────────────────────────────────
echo "[1/5] Compiling (arm64)…"
cd "$SWIFT_DIR"
swift build -c release

BINARY="$SWIFT_DIR/.build/arm64-apple-macosx/release/murmur"

# ── 2. Assemble .app bundle ───────────────────────────────────────────────────
echo "[2/5] Assembling $APP_NAME.app…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY"                        "$APP_BUNDLE/Contents/MacOS/murmur"
cp "$SWIFT_DIR/Info.plist"          "$APP_BUNDLE/Contents/Info.plist"
cp "$SWIFT_DIR/murmur.icns"         "$APP_BUNDLE/Contents/Resources/murmur.icns"

# Copy SPM resource bundle (tray icons) — must sit next to the binary (MacOS/)
# so the existing tray-icon loading code (executableURL/../murmur_murmur.bundle) finds it
BUNDLE_SRC="$SWIFT_DIR/.build/arm64-apple-macosx/release/murmur_murmur.bundle"
if [ -d "$BUNDLE_SRC" ]; then
    cp -R "$BUNDLE_SRC" "$APP_BUNDLE/Contents/MacOS/"
fi

# Copy SenseVoice model files into Resources/
MODEL_SRC="$REPO/models/sense-voice-zh-en"
if [ -d "$MODEL_SRC" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources/models/sense-voice-zh-en"
    cp "$MODEL_SRC"/model.int8.onnx "$MODEL_SRC"/tokens.txt \
       "$APP_BUNDLE/Contents/Resources/models/sense-voice-zh-en/"
fi

# Patch Info.plist version
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION"            "$APP_BUNDLE/Contents/Info.plist"

# ── 3. Code sign ─────────────────────────────────────────────────────────────
SIGN_ID="Developer ID Application: Fertan KANAN (2TK55NZP65)"
ENTITLEMENTS="$SWIFT_DIR/murmur.entitlements"

echo "[3/7] Code signing…"
# Sign inside-out: frameworks/bundles first, then the main binary, then the app

# Sign sherpa-onnx framework if present
SHERPA_FW="$APP_BUNDLE/Contents/Frameworks/sherpa-onnx.framework"
if [ -d "$SHERPA_FW" ]; then
    codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$SHERPA_FW"
fi
# Sign resource bundle if present
RES_BUNDLE="$APP_BUNDLE/Contents/MacOS/murmur_murmur.bundle"
if [ -d "$RES_BUNDLE" ]; then
    codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$RES_BUNDLE"
fi
# Sign the main binary explicitly
codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_ID" "$APP_BUNDLE/Contents/MacOS/murmur"
# Sign the app bundle
codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_ID" "$APP_BUNDLE"

echo "[4/7] Verifying signature…"
codesign --verify --deep --verbose=2 "$APP_BUNDLE"

# ── 4. Generate DMG background ────────────────────────────────────────────────
echo "[5/7] Generating background…"
python3 "$SCRIPT_DIR/gen-dmg-background.py" "$BG_IMG"

# ── 5. Create DMG ─────────────────────────────────────────────────────────────
echo "[6/7] Packaging DMG…"
rm -f "$DMG_OUT"

create-dmg \
    --volname "$APP_NAME $VERSION" \
    --volicon "$SWIFT_DIR/murmur.icns" \
    --background "$BG_IMG" \
    --window-pos 200 150 \
    --window-size 660 420 \
    --icon-size 120 \
    --icon "$APP_NAME.app" 185 230 \
    --app-drop-link 475 230 \
    --hide-extension "$APP_NAME.app" \
    --no-internet-enable \
    "$DMG_OUT" \
    "$APP_BUNDLE"

# Sign the DMG itself
codesign --force --sign "$SIGN_ID" "$DMG_OUT"

# ── 6. Notarize ──────────────────────────────────────────────────────────────
echo "[7/7] Notarizing…"
xcrun notarytool submit "$DMG_OUT" \
    --keychain-profile "murmur-notarize" \
    --wait

# Staple the notarization ticket to the DMG
xcrun stapler staple "$DMG_OUT"

echo ""
echo "✓ Done: $DMG_OUT (signed + notarized)"
ls -lh "$DMG_OUT"
