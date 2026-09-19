#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build"
APP_DIR="$PROJECT_DIR/build/Bassline.app"

# A stable signing identity keeps the same cdhash across rebuilds, so the
# System Audio Recording permission is granted once instead of on every build.
# Override with: SIGN_IDENTITY="Developer ID Application: ..." bash scripts/build_app.sh
SIGN_IDENTITY="${SIGN_IDENTITY:-Bassline Self Signed}"

cd "$PROJECT_DIR"

echo "Building Bassline (release)..."
swift build -c release

BINARY="$BUILD_DIR/release/Bassline"
if [ ! -f "$BINARY" ]; then
    echo "Error: binary not found at $BINARY" >&2
    exit 1
fi

echo "Assembling $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/Bassline"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

if security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY"; then
    echo "Signing with \"$SIGN_IDENTITY\"..."
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_DIR"
else
    cat >&2 <<EOF

Warning: signing identity "$SIGN_IDENTITY" not found, falling back to ad-hoc.
Ad-hoc signing changes the app identity on every build, so macOS will ask for
System Audio Recording permission again each time.

To create a reusable self-signed identity once:
  1. Open Keychain Access
  2. Keychain Access > Certificate Assistant > Create a Certificate...
  3. Name: $SIGN_IDENTITY
     Identity Type: Self Signed Root
     Certificate Type: Code Signing
  4. Rebuild.

EOF
    codesign --force --sign - "$APP_DIR"
fi

echo "Done: $APP_DIR"
