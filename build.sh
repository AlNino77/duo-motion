#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

APP_NAME="DuoMo"
BUNDLE_ID="com.lqsky7.duomo"
INFO_PLIST="$DIR/Info.plist"
VERSION_OVERRIDE=""
BUILD_OVERRIDE=""
SHOULD_INSTALL=true

usage() {
    cat <<USAGE
Usage: ./build.sh [--version X.Y.Z] [--build N] [--no-install]

  --version X.Y.Z  Set the marketing version in Info.plist.
  --build N        Set the integer build number in Info.plist.
  --no-install     Build the app and DMG without installing to /Applications.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || { echo "Missing value for --version"; exit 1; }
            VERSION_OVERRIDE="$2"
            shift 2
            ;;
        --build)
            [[ $# -ge 2 ]] || { echo "Missing value for --build"; exit 1; }
            BUILD_OVERRIDE="$2"
            shift 2
            ;;
        --no-install)
            SHOULD_INSTALL=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

[[ -f "$INFO_PLIST" ]] || { echo "Info.plist not found"; exit 1; }

if [[ -n "$VERSION_OVERRIDE" ]]; then
    [[ "$VERSION_OVERRIDE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo "Version must use semantic versioning, for example 1.0.1"
        exit 1
    }
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION_OVERRIDE" "$INFO_PLIST"
fi

if [[ -n "$BUILD_OVERRIDE" ]]; then
    [[ "$BUILD_OVERRIDE" =~ ^[0-9]+$ ]] || {
        echo "Build number must be an integer"
        exit 1
    }
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_OVERRIDE" "$INFO_PLIST"
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Info.plist version must use semantic versioning"
    exit 1
}
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || {
    echo "Info.plist build number must be an integer"
    exit 1
}

echo "=== $APP_NAME v$VERSION (Build $BUILD_NUMBER) ==="

BUILD_DIR="$DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
DMG_OUTPUT="$BUILD_DIR/$APP_NAME-v$VERSION.dmg"

rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "▶ Compiling Metal shaders..."
METAL_TOOLCHAIN_ID="$(xcodebuild -showComponent MetalToolchain -json 2>/dev/null | /usr/bin/plutil -extract toolchainIdentifier raw -o - - 2>/dev/null || true)"
METAL_XCRUN=(xcrun)
if [[ -n "$METAL_TOOLCHAIN_ID" ]]; then
    METAL_XCRUN+=(-toolchain "$METAL_TOOLCHAIN_ID")
fi
"${METAL_XCRUN[@]}" -sdk macosx metal -c "$DIR/Sources/FoldShaders.metal" -o "$BUILD_DIR/FoldShaders.air"
"${METAL_XCRUN[@]}" -sdk macosx metallib "$BUILD_DIR/FoldShaders.air" -o "$RESOURCES_DIR/default.metallib"
cp "$DIR/Sources/FoldShaders.metal" "$RESOURCES_DIR/FoldShaders.metal"

echo "▶ Compiling Swift application for Apple Silicon and Intel..."
SWIFT_FRAMEWORKS=(
    -framework AppKit
    -framework SwiftUI
    -framework Metal
    -framework MetalKit
    -framework CoreMedia
    -framework CoreVideo
    -framework ScreenCaptureKit
    -framework IOKit
    -framework QuartzCore
)

swiftc -target arm64-apple-macos14.0 -O \
    "$DIR"/Sources/*.swift \
    -o "$BUILD_DIR/${APP_NAME}_arm64" \
    "${SWIFT_FRAMEWORKS[@]}"

swiftc -target x86_64-apple-macos14.0 -O \
    "$DIR"/Sources/*.swift \
    -o "$BUILD_DIR/${APP_NAME}_x86_64" \
    "${SWIFT_FRAMEWORKS[@]}"

lipo -create \
    "$BUILD_DIR/${APP_NAME}_arm64" \
    "$BUILD_DIR/${APP_NAME}_x86_64" \
    -output "$MACOS_DIR/$APP_NAME"
rm -f "$BUILD_DIR/${APP_NAME}_arm64" "$BUILD_DIR/${APP_NAME}_x86_64"

cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"

if [[ ! -f "$DIR/Resources/AppIcon.icns" && -f "$DIR/Resources/AppIcon.png" ]]; then
    echo "▶ Generating AppIcon.icns..."
    ICONSET="$BUILD_DIR/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    sips -z 16 16     "$DIR/Resources/AppIcon.png" --out "$ICONSET/icon_16x16.png" >/dev/null 2>&1
    sips -z 32 32     "$DIR/Resources/AppIcon.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null 2>&1
    sips -z 32 32     "$DIR/Resources/AppIcon.png" --out "$ICONSET/icon_32x32.png" >/dev/null 2>&1
    sips -z 64 64     "$DIR/Resources/AppIcon.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null 2>&1
    sips -z 128 128   "$DIR/Resources/AppIcon.png" --out "$ICONSET/icon_128x128.png" >/dev/null 2>&1
    sips -z 256 256   "$DIR/Resources/AppIcon.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null 2>&1
    sips -z 256 256   "$DIR/Resources/AppIcon.png" --out "$ICONSET/icon_256x256.png" >/dev/null 2>&1
    sips -z 512 512   "$DIR/Resources/AppIcon.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null 2>&1
    sips -z 512 512   "$DIR/Resources/AppIcon.png" --out "$ICONSET/icon_512x512.png" >/dev/null 2>&1
    sips -z 1024 1024 "$DIR/Resources/AppIcon.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null 2>&1
    iconutil -c icns "$ICONSET" -o "$DIR/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
fi

if [[ -f "$DIR/Resources/AppIcon.icns" ]]; then
    cp "$DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$CONTENTS_DIR/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS_DIR/Info.plist"
fi

if [[ -d "$DIR/Resources/Untitled.icon" ]]; then
    cp -R "$DIR/Resources/Untitled.icon" "$RESOURCES_DIR/Untitled.icon"
fi

for resource in default.png AppIcon.png AppIcon.svg; do
    if [[ -f "$DIR/Resources/$resource" ]]; then
        cp "$DIR/Resources/$resource" "$RESOURCES_DIR/$resource"
    fi
done

echo "▶ Codesigning application bundle..."
SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -n 1 | awk -F '"' '{print $2}' || true)
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
fi
echo "▶ Using signing identity: $SIGNING_IDENTITY"
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"

echo "▶ Creating disk image..."
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING" "$DMG_OUTPUT"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_OUTPUT" >/dev/null 2>&1
rm -rf "$DMG_STAGING"
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    codesign --force --sign "$SIGNING_IDENTITY" "$DMG_OUTPUT" >/dev/null 2>&1
fi

if [[ "$SHOULD_INSTALL" == true ]]; then
    INSTALL_TARGET="/Applications/$APP_NAME.app"
    LEGACY_TARGET="/Applications/macTilt.app"
    echo "▶ Installing to $INSTALL_TARGET..."
    pkill -x "$APP_NAME" || true
    pkill -x "macTilt" || true
    sleep 0.5
    [[ ! -d "$INSTALL_TARGET" ]] || rm -rf "$INSTALL_TARGET"
    [[ ! -d "$LEGACY_TARGET" ]] || rm -rf "$LEGACY_TARGET"
    cp -R "$APP_BUNDLE" "$INSTALL_TARGET"
    echo "✔ Installed: $INSTALL_TARGET"
fi

echo "✔ App: $APP_BUNDLE"
echo "✔ DMG: $DMG_OUTPUT"
echo "✔ Bundle ID: $BUNDLE_ID"
