#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release

APP="$ROOT/build/SpaceMap.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/release/SpaceMap" "$APP/Contents/MacOS/SpaceMap"
# Localized resources compiled by SwiftPM (Localizable.strings(dictionary)).
BUNDLE="$ROOT/.build/release/SpaceMap_SpaceMap.bundle"
if [ -d "$BUNDLE/Contents/Resources" ]; then
    cp -R "$BUNDLE/Contents/Resources/"* "$APP/Contents/Resources/"
fi
# App icon generated from scripts/icon.swift (never a committed binary).
./scripts/make-icon.sh "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>es</string>
    <string>pt</string>
    <string>fr</string>
    <string>de</string>
    <string>ja</string>
  </array>
  <key>CFBundleExecutable</key><string>SpaceMap</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.marcoleejr.spacemap</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>SpaceMap</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST
# macOS ties Full Disk Access to the code signature. Ad-hoc signatures change
# on every build, so macOS forgets the grant; sign with a stable identity.
IDENTITY="${SPACEMAP_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)"
fi
if [ -n "$IDENTITY" ]; then
    codesign --force --deep --options runtime --identifier com.marcoleejr.spacemap --sign "$IDENTITY" "$APP"
    printf 'Built and signed %s with "%s"\n' "$APP" "$IDENTITY"
else
    echo "warning: no Apple Development identity found; signing ad-hoc. macOS will forget Full Disk Access after each rebuild." >&2
    codesign --force --deep --identifier com.marcoleejr.spacemap --sign - "$APP"
    printf 'Built and ad-hoc signed %s\n' "$APP"
fi
