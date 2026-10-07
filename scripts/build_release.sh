#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
readonly VERSION="1.0.4"
readonly PRODUCT_NAME="LocalTranscriber"
readonly BUILD_DIR="$PROJECT_ROOT/release-build"
readonly DERIVED_DATA_DIR="$BUILD_DIR/DerivedData"
readonly APP_PATH="$BUILD_DIR/$PRODUCT_NAME.app"
readonly DIST_DIR="$PROJECT_ROOT/release-dist"
readonly DMG_PATH="$DIST_DIR/$PRODUCT_NAME-$VERSION-macos-arm64.dmg"
readonly ZIP_PATH="$DIST_DIR/$PRODUCT_NAME-$VERSION-macos-arm64.zip"
readonly CHECKSUM_PATH="$DIST_DIR/$PRODUCT_NAME-$VERSION-checksums.txt"
readonly ENTITLEMENTS_PATH="$PROJECT_ROOT/LocalTranscriber/LocalTranscriber.entitlements"

for command_name in xcodebuild codesign hdiutil ditto shasum plutil lipo; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf 'error: required command is unavailable: %s\n' "$command_name" >&2
        exit 1
    fi
done

case "$BUILD_DIR" in
    "$PROJECT_ROOT/release-build") ;;
    *) printf 'error: refusing unsafe build directory: %s\n' "$BUILD_DIR" >&2; exit 1 ;;
esac

case "$DIST_DIR" in
    "$PROJECT_ROOT/release-dist") ;;
    *) printf 'error: refusing unsafe distribution directory: %s\n' "$DIST_DIR" >&2; exit 1 ;;
esac

PACKAGE_TMP="$(mktemp -d "${TMPDIR:-/private/tmp}/localtranscriber-release.XXXXXX")"
DMG_MOUNTED=0

cleanup() {
    if [[ "$DMG_MOUNTED" -eq 1 ]]; then
        hdiutil detach "$PACKAGE_TMP/dmg-mount" -quiet >/dev/null 2>&1 || true
    fi
    rm -rf "$PACKAGE_TMP"
}
trap cleanup EXIT INT TERM

verify_app() {
    local app="$1"
    codesign --verify --deep --strict --verbose=4 "$app"

    if [[ ! -f "$app/Contents/_CodeSignature/CodeResources" ]]; then
        printf 'error: CodeResources is missing from %s\n' "$app" >&2
        exit 1
    fi
}

printf 'Building clean Release application...\n'
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

xcodebuild \
    -project "$PROJECT_ROOT/LocalTranscriber.xcodeproj" \
    -scheme LocalTranscriber \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    clean build

readonly BUILT_APP="$DERIVED_DATA_DIR/Build/Products/Release/$PRODUCT_NAME.app"
if [[ ! -d "$BUILT_APP" ]]; then
    printf 'error: Release application was not produced at %s\n' "$BUILT_APP" >&2
    exit 1
fi

ditto "$BUILT_APP" "$APP_PATH"

required_resources=(
    "Contents/MacOS/LocalTranscriber"
    "Contents/Info.plist"
    "Contents/Resources/AppIcon.icns"
    "Contents/Resources/Assets.car"
    "Contents/Resources/transcribe_worker.py"
    "Contents/Resources/ManagedInstaller/installer/install.sh"
    "Contents/Resources/ManagedInstaller/runtime-manifest.json"
    "Contents/Resources/ManagedInstaller/scripts/validate_runtime.sh"
    "Contents/Resources/ManagedInstaller/scripts/audit_macos_compatibility.sh"
)

for resource in "${required_resources[@]}"; do
    if [[ ! -e "$APP_PATH/$resource" ]]; then
        printf 'error: required application resource is missing: %s\n' "$resource" >&2
        exit 1
    fi
done

if [[ "$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/Info.plist")" != "media.studioflow.LocalTranscriber" ]]; then
    printf 'error: unexpected bundle identifier\n' >&2
    exit 1
fi

if [[ "$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")" != "$VERSION" ]]; then
    printf 'error: unexpected application version\n' >&2
    exit 1
fi

if [[ "$(lipo -archs "$APP_PATH/Contents/MacOS/LocalTranscriber")" != "arm64" ]]; then
    printf 'error: Release executable is not arm64-only\n' >&2
    exit 1
fi

printf 'Applying final ad-hoc signature to the complete application bundle...\n'
codesign \
    --force \
    --deep \
    --sign - \
    --timestamp=none \
    --entitlements "$ENTITLEMENTS_PATH" \
    "$APP_PATH"

verify_app "$APP_PATH"

printf 'Creating DMG...\n'
mkdir -p "$PACKAGE_TMP/dmg-root"
ditto "$APP_PATH" "$PACKAGE_TMP/dmg-root/$PRODUCT_NAME.app"
ln -s /Applications "$PACKAGE_TMP/dmg-root/Applications"
hdiutil create \
    -volname "$PRODUCT_NAME $VERSION" \
    -srcfolder "$PACKAGE_TMP/dmg-root" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

printf 'Creating ZIP...\n'
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

printf 'Verifying application extracted from DMG...\n'
mkdir -p "$PACKAGE_TMP/dmg-mount" "$PACKAGE_TMP/dmg-extract"
hdiutil attach -readonly -nobrowse -mountpoint "$PACKAGE_TMP/dmg-mount" "$DMG_PATH" >/dev/null
DMG_MOUNTED=1
ditto "$PACKAGE_TMP/dmg-mount/$PRODUCT_NAME.app" "$PACKAGE_TMP/dmg-extract/$PRODUCT_NAME.app"
verify_app "$PACKAGE_TMP/dmg-extract/$PRODUCT_NAME.app"
hdiutil detach "$PACKAGE_TMP/dmg-mount" -quiet
DMG_MOUNTED=0

printf 'Verifying application extracted from ZIP...\n'
mkdir -p "$PACKAGE_TMP/zip-extract"
ditto -x -k "$ZIP_PATH" "$PACKAGE_TMP/zip-extract"
verify_app "$PACKAGE_TMP/zip-extract/$PRODUCT_NAME.app"

(
    cd "$DIST_DIR"
    shasum -a 256 "$(basename "$DMG_PATH")" "$(basename "$ZIP_PATH")" >"$(basename "$CHECKSUM_PATH")"
)

printf '\nRelease artifacts are ready:\n'
ls -lh "$DMG_PATH" "$ZIP_PATH" "$CHECKSUM_PATH"
cat "$CHECKSUM_PATH"
