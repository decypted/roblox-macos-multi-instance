#!/bin/bash
# Builds "RBX Multi-Instance.app" (universal) and packages it into a .dmg.
# Usage: ./build.sh   -> dist/RBX-Multi-Instance-<version>-mac.dmg
# Optional: SIGN_ID="Developer ID Application: Name (TEAMID)" ./build.sh
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
EXE="RBX-Multi-Instance"
APPNAME="RBX Multi-Instance"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP="$BUILD/$APPNAME.app"
SIGN_ID="${SIGN_ID:--}"

rm -rf "$BUILD" "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST"

echo "==> Compiling $VERSION (arm64 + x86_64)"
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 -target "$arch-apple-macos13.0" \
    -o "$BUILD/$EXE-$arch" Sources/*.swift
done
lipo -create -output "$APP/Contents/MacOS/$EXE" "$BUILD/$EXE-arm64" "$BUILD/$EXE-x86_64"
cp Info.plist "$APP/Contents/Info.plist"

echo "==> Building app icon"
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
SRC_PNG="$ROOT/Resources/AppIcon.png"
for size in 16 32 128 256 512; do
  sips -z $size $size "$SRC_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size*2)) $((size*2)) "$SRC_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"

echo "==> Signing ($SIGN_ID)"
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
codesign --verify --verbose=1 "$APP"

echo "==> Creating DMG"
DMG="$DIST/$EXE-$VERSION-mac.dmg"
"$ROOT/packaging/make-dmg.sh" "$APP" "$APPNAME" "$DMG"

echo "==> Done: $DMG"
