#!/bin/bash
# Genera un binario universal (Apple Silicon + Intel) y un instalador .dmg
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(tr -d '[:space:]' < VERSION)"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Ferry"

APP="build/Ferry.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Ferry"
cat > "$APP/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Ferry</string>
  <key>CFBundleIdentifier</key><string>com.reca.ferry</string>
  <key>CFBundleExecutable</key><string>Ferry</string>
  <key>CFBundleDevelopmentRegion</key><string>es</string>
  <key>CFBundleLocalizations</key><array><string>es</string><string>en</string></array>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>com.reca.ferry</string>
    <key>CFBundleURLSchemes</key><array><string>ferry</string></array>
  </dict></array>
  <key>NSAppleEventsUsageDescription</key><string>Ferry pregunta al Finder qué carpeta tienes abierta para pegar ahí los archivos.</string>
</dict></plist>
PL
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHumanReadableCopyright string © 2026 ChocolitosSoft. Todos los derechos reservados." "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/en.lproj Resources/es.lproj "$APP/Contents/Resources/"
cp -R "QuickAction/Traer de Ferry.workflow" "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

STAGE="build/dmg"
rm -rf "$STAGE" build/Ferry-$VERSION.dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# Icono del volumen del DMG
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
SetFile -a C "$STAGE" 2>/dev/null || true
hdiutil create -volname "Ferry" -srcfolder "$STAGE" -ov -format UDZO build/Ferry-$VERSION.dmg
# Icono del archivo .dmg en el Finder
osascript -l JavaScript -e 'ObjC.import("AppKit"); function run(a){ var img=$.NSImage.alloc.initWithContentsOfFile($("Resources/AppIcon.icns")); $.NSWorkspace.sharedWorkspace.setIconForFileOptions(img,$(a[0]),0); }' "build/Ferry-$VERSION.dmg"
cp "build/Ferry-$VERSION.dmg" build/Ferry.dmg # nombre fijo para el enlace /releases/latest/download/Ferry.dmg
echo "Listo: build/Ferry-$VERSION.dmg (y build/Ferry.dmg)"
