#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
OUTPUT_APP="$PWD/dist/Co-Count.app"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cocount-app.XXXXXX")"
trap 'rm -r "$STAGING_DIR"' EXIT
APP_DIR="$STAGING_DIR/Co-Count.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$PWD/dist"
cp "$BIN_DIR/Co-Count" "$APP_DIR/Contents/MacOS/Co-Count"
cp -R "$BIN_DIR/Co-Count_Cocount.bundle" "$APP_DIR/Contents/Resources/"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
ICON_FILE="$APP_DIR/Contents/Resources/AppIcon.icns"
PREVIOUS_ICON="$OUTPUT_APP/Contents/Resources/AppIcon.icns"
if [ -f "$PREVIOUS_ICON" ] && [ ! scripts/make-icon.swift -nt "$PREVIOUS_ICON" ]; then
  cp "$PREVIOUS_ICON" "$ICON_FILE"
else
  ICONSET="$STAGING_DIR/Cocount.iconset"
  swift scripts/make-icon.swift "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$ICON_FILE"
fi
# Fresh staging prevents resources from older app names/builds accumulating in the bundle.
xattr -cr "$APP_DIR"
codesign --force --sign - "$APP_DIR"
xattr -cr "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
# Only replace this script's generated output after the staged bundle passes verification.
if [ -e "$OUTPUT_APP" ]; then rm -r "$OUTPUT_APP"; fi
mv "$APP_DIR" "$OUTPUT_APP"
# File Provider can attach Finder metadata just after the move into Documents.
# Retry only metadata cleanup; never weaken signature verification.
VERIFIED=false
for attempt in 1 2 3; do
  xattr -cr "$OUTPUT_APP"
  if codesign --verify --deep --strict "$OUTPUT_APP" 2> "$STAGING_DIR/verify.log"; then
    VERIFIED=true
    break
  fi
  sleep 0.1
done
if [ "$VERIFIED" != true ]; then
  cat "$STAGING_DIR/verify.log" >&2
  exit 1
fi
echo "Built: $OUTPUT_APP"
