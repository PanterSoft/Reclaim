#!/usr/bin/env bash
# Builds dist/Reclaim.app (with the `reclaim` command-line tool inside) and a zip of it.
#   VERSION=1.2.0   version string written into Info.plist (a leading "v" is dropped)
#   UNIVERSAL=1     build for both Apple silicon and Intel (requires Xcode, not just the CLT)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
VERSION="${VERSION#v}"
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="dist/Reclaim.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ReclaimApp" "$APP/Contents/MacOS/Reclaim"
cp "$BIN_DIR/reclaim" "$APP/Contents/Resources/reclaim"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

# Ad-hoc signature: enough to run locally. Use a Developer ID to distribute without warnings.
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP/Contents/Resources/reclaim"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"

(cd dist && rm -f "Reclaim-$VERSION.zip" && ditto -c -k --keepParent Reclaim.app "Reclaim-$VERSION.zip")
echo "Built $APP and dist/Reclaim-$VERSION.zip"
