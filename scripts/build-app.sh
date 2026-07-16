#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
/bin/bash "$ROOT_DIR/scripts/check-version.sh"
APP_VERSION="$(< "$ROOT_DIR/VERSION")"
APP_NAME="Codex Usage Bar"
BUNDLE_ID="local.codex-usage-bar"
OUTPUT_DIR="${APP_OUTPUT_DIR:-$ROOT_DIR/.build}"
if [[ "$OUTPUT_DIR" != /* ]]; then
    OUTPUT_DIR="$ROOT_DIR/$OUTPUT_DIR"
fi
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
EXECUTABLE_SOURCE="$ROOT_DIR/.build/$CONFIGURATION/CodexUsageBar"
ICON_NAME="CodexUsageBar"
ICON_FILE="$ICON_NAME.icns"

case "$CONFIGURATION" in
    debug|release) ;;
    *)
        printf 'Unsupported CONFIGURATION: %s\n' "$CONFIGURATION" >&2
        exit 64
        ;;
esac

if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Invalid app version in %s/VERSION\n' "$ROOT_DIR" >&2
    exit 1
fi

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION"

mkdir -p "$OUTPUT_DIR"
STAGING_ROOT="$(mktemp -d "$OUTPUT_DIR/.codex-usage-bar-package.XXXXXX")"
STAGING_APP="$STAGING_ROOT/$APP_NAME.app"
EXECUTABLE_DEST="$STAGING_APP/Contents/MacOS/$APP_NAME"
BACKUP_APP=""

path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

cleanup() {
    local exit_status="$1"
    trap - EXIT HUP INT TERM

    # Any failure or handled signal after moving the previous app aside must put
    # it back when the canonical destination is still empty. If a new app is
    # already present, retain the backup and report it instead of deleting the
    # user's last known-good bundle during an interrupted install.
    if [[ -n "$BACKUP_APP" ]] && path_exists "$BACKUP_APP"; then
        if ! path_exists "$APP_DIR"; then
            if mv "$BACKUP_APP" "$APP_DIR"; then
                printf 'Restored previous app after interrupted install: %s\n' "$APP_DIR" >&2
                BACKUP_APP=""
            else
                printf 'ERROR could not restore previous app from: %s\n' "$BACKUP_APP" >&2
                exit_status=1
            fi
        elif [[ "$exit_status" -ne 0 ]]; then
            printf 'Previous app retained after interrupted install: %s\n' "$BACKUP_APP" >&2
        fi
    fi

    if [[ -n "$STAGING_ROOT" && -d "$STAGING_ROOT" ]]; then
        if ! rm -rf "$STAGING_ROOT"; then
            printf 'ERROR could not remove packaging directory: %s\n' "$STAGING_ROOT" >&2
            exit_status=1
        fi
    fi
    exit "$exit_status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources"
cp "$EXECUTABLE_SOURCE" "$EXECUTABLE_DEST"
cp "$ROOT_DIR/LICENSE" "$STAGING_APP/Contents/Resources/LICENSE"
cp "$ROOT_DIR/VERSION" "$STAGING_APP/Contents/Resources/VERSION"
swift "$ROOT_DIR/scripts/generate-app-icon.swift" "$STAGING_APP/Contents/Resources/$ICON_FILE"

/usr/libexec/PlistBuddy -c "Clear dict" "$STAGING_APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $APP_VERSION" "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $APP_NAME" "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $ICON_NAME" "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 13.0" "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHumanReadableCopyright string Copyright © 2026 Codex Usage Bar contributors" "$STAGING_APP/Contents/Info.plist"

# Ad-hoc signing makes the locally built bundle internally verifiable. Public
# binary distribution still requires a Developer ID signature and notarization.
/usr/bin/codesign --force --sign - "$EXECUTABLE_DEST"
/usr/bin/codesign --force --sign - "$STAGING_APP"
/usr/bin/codesign --verify --deep --strict "$STAGING_APP"
/usr/bin/plutil -lint "$STAGING_APP/Contents/Info.plist" >/dev/null

# The prior usable bundle remains untouched until every staging check passes.
if path_exists "$APP_DIR"; then
    BACKUP_APP="$OUTPUT_DIR/.$APP_NAME.previous.$(/usr/bin/uuidgen).app"
    mv "$APP_DIR" "$BACKUP_APP"
fi

mv "$STAGING_APP" "$APP_DIR"

if [[ -n "$BACKUP_APP" ]] && path_exists "$BACKUP_APP"; then
    rm -rf "$BACKUP_APP"
    BACKUP_APP=""
fi

printf '%s\n' "$APP_DIR"
