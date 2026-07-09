#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="Codex Usage Bar"
BUNDLE_ID="local.codex-usage-bar"
APP_DIR="$ROOT_DIR/.build/$APP_NAME.app"
EXECUTABLE_SOURCE="$ROOT_DIR/.build/$CONFIGURATION/CodexUsageBar"
EXECUTABLE_DEST="$APP_DIR/Contents/MacOS/$APP_NAME"
ICON_NAME="CodexUsageBar"
ICON_FILE="$ICON_NAME.icns"

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$EXECUTABLE_SOURCE" "$EXECUTABLE_DEST"
swift "$ROOT_DIR/scripts/generate-app-icon.swift" "$APP_DIR/Contents/Resources/$ICON_FILE"

/usr/libexec/PlistBuddy -c "Clear dict" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 0.1.0" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $APP_NAME" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $ICON_NAME" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 13.0" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$APP_DIR/Contents/Info.plist"

# Ad-hoc signing makes the locally built bundle internally verifiable. Public
# binary distribution still requires a Developer ID signature and notarization.
/usr/bin/codesign --force --sign - "$EXECUTABLE_DEST"
/usr/bin/codesign --force --sign - "$APP_DIR"

printf '%s\n' "$APP_DIR"
