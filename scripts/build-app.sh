#!/usr/bin/env bash
# Builds dist/Reclaim.app (with the `reclaim` command-line tool inside) and a zip of it.
#   VERSION=1.2.0   version string written into Info.plist (a leading "v" is dropped)
#   UNIVERSAL=1     build for both Apple silicon and Intel (requires Xcode, not just the CLT)
#   CONFIGURATION=debug   quick unoptimized build for development (no zip)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
VERSION="${VERSION#v}"
CONFIGURATION="${CONFIGURATION:-release}"
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c "$CONFIGURATION" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIGURATION" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="dist/Reclaim.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"
cp "$BIN_DIR/ReclaimApp" "$APP/Contents/MacOS/Reclaim"
cp "$BIN_DIR/reclaim" "$APP/Contents/Resources/reclaim"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
# Login agent for "Run in the menu bar" (registered by the app via SMAppService).
cp Resources/io.github.reclaim.Reclaim.background.plist "$APP/Contents/Library/LaunchAgents/"

# Sign with the first local certificate if there is one: macOS ties a Full Disk Access grant for an
# ad-hoc signed app to that exact build, so every rebuild would lose it. Falls back to ad-hoc (CI).
# Use a Developer ID to distribute without warnings.
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk 'NR==1 && /\)/ {print $2}')"
fi
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP/Contents/Resources/reclaim"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"

if [[ "$CONFIGURATION" == "release" ]]; then
  (cd dist && rm -f "Reclaim-$VERSION.zip" && ditto -c -k --keepParent Reclaim.app "Reclaim-$VERSION.zip")
  echo "Built $APP and dist/Reclaim-$VERSION.zip"
else
  echo "Built $APP ($CONFIGURATION)"
fi
