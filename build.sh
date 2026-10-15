#!/bin/bash
# Snapper build script: compile -> bundle -> ad-hoc sign -> launch.
# Needs only the free Command Line Tools:  xcode-select --install
#
# Usage:  ./build.sh            build, update /Applications/Snapper.app in place and relaunch
#         ./build.sh --no-run   build only
#         ./build.sh --zip      build/Snapper-<version>.zip
#         ./build.sh --release  both the .dmg (what in-app updates download) and the .zip
#         ./build.sh --dmg      build the drag-to-Applications installer, build/Snapper-<version>.dmg
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found. Install the Command Line Tools with:  xcode-select --install" >&2
  exit 1
fi

APP="build/Snapper.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

ARCH="$(uname -m)"

echo "==> Compiling (${ARCH}, macOS 14+)"
swiftc -O -whole-module-optimization \
  -swift-version 5 \
  -parse-as-library \
  -target "${ARCH}-apple-macos14.0" \
  -o "$MACOS/Snapper" \
  Snapper/*.swift \
  -framework AppKit \
  -framework SwiftUI \
  -framework ScreenCaptureKit \
  -framework Carbon \
  -framework UniformTypeIdentifiers \
  -framework ServiceManagement \
  -framework CoreGraphics \
  -framework ApplicationServices \
  -framework AVFoundation \
  -framework AVKit \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework CoreImage \
  -framework ImageIO \
  -framework Vision \
  -framework Combine \
  -framework QuartzCore

# Images used in the app (menu bar icon, logo badge), with @2x versions for Retina.
for f in Snapper/Resources/*.png; do
  [ -f "$f" ] && cp "$f" "$RES/"
done

# App icon: build a pixel-perfect .icns from the hand-tuned iconset (design/make_icons.py),
# falling back to the prebuilt .icns.
ICON_KEY=""
if [ -d "Snapper/Resources/AppIcon.iconset" ] && command -v iconutil >/dev/null 2>&1 \
   && iconutil -c icns "Snapper/Resources/AppIcon.iconset" -o "$RES/AppIcon.icns" 2>/dev/null; then
  ICON_KEY="  <key>CFBundleIconFile</key><string>AppIcon</string>"
elif [ -f "Snapper/Resources/AppIcon.icns" ]; then
  cp "Snapper/Resources/AppIcon.icns" "$RES/AppIcon.icns"
  ICON_KEY="  <key>CFBundleIconFile</key><string>AppIcon</string>"
fi

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Snapper</string>
  <key>CFBundleName</key><string>Snapper</string>
  <key>CFBundleDisplayName</key><string>Snapper</string>
  <key>CFBundleIdentifier</key><string>com.example.snapper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.4</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>NSHumanReadableCopyright</key><string>Snapper. Built by Bykorp.</string>
${ICON_KEY}
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>Snapper needs Screen Recording access to capture screenshots and record your screen.</string>
  <key>NSMicrophoneUsageDescription</key><string>Snapper records your microphone when you turn on microphone recording.</string>
  <key>NSCameraUsageDescription</key><string>Snapper shows your camera in a bubble when you turn on the camera option while recording.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.example.snapper</string>
      <key>CFBundleURLSchemes</key><array><string>snapper</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Snapper Project</string>
      <key>CFBundleTypeExtensions</key><array><string>snapper</string></array>
      <key>CFBundleTypeRole</key><string>Editor</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sign with the stable local identity when it exists (run ./setup-signing.sh once). A stable identity keeps
# Screen Recording and other permissions across updates; plain ad-hoc signing makes macOS ask again every build.
IDENTITY="Snapper Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "==> Signing with \"$IDENTITY\""
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  echo "==> Ad-hoc signing (run ./setup-signing.sh once so permissions survive updates)"
  codesign --force --deep --sign - "$APP"
fi

echo "==> Built $APP"

MODE="${1:-}"

if [ "$MODE" = "--zip" ] || [ "$MODE" = "--release" ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  ZIP="build/Snapper-${VERSION}.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "==> Built $ZIP"
  [ "$MODE" = "--zip" ] && exit 0
fi

if [ "$MODE" = "--dmg" ] || [ "$MODE" = "--release" ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  DMG="build/Snapper-${VERSION}.dmg"
  RWDMG="build/rw.dmg"
  VOL="Snapper"
  echo "==> Packaging $DMG"
  hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true
  rm -f "$DMG" "$RWDMG"
  hdiutil create -size 120m -fs HFS+ -volname "$VOL" -ov "$RWDMG" >/dev/null
  hdiutil attach "$RWDMG" -noautoopen -nobrowse >/dev/null
  MNT="/Volumes/$VOL"
  cp -R "$APP" "$MNT/"
  ln -s /Applications "$MNT/Applications"
  mkdir "$MNT/.background"
  cp design/dmg-background.png "$MNT/.background/background.png"
  if [ -f "$RES/AppIcon.icns" ]; then
    cp "$RES/AppIcon.icns" "$MNT/.VolumeIcon.icns"
    SetFile -a C "$MNT" 2>/dev/null || true
  fi
  # Lay out the installer window: app on the left, Applications on the right, arrow between.
  perl -e 'alarm 60; exec @ARGV' osascript >/dev/null 2>&1 <<OSA || echo "note: window layout skipped (allow Terminal to control Finder to style the DMG)"
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 860, 545}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.png"
    set position of item "Snapper.app" of container window to {180, 190}
    set position of item "Applications" of container window to {480, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
  sync
  hdiutil detach "$MNT" >/dev/null
  hdiutil convert "$RWDMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
  rm -f "$RWDMG"
  if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$DMG" || true
  fi
  echo "==> Built $DMG"
  exit 0
fi

if [ "${1:-}" = "--no-run" ]; then
  exit 0
fi

# Default: update the installed app in place (no need to delete anything), then relaunch it.
pkill -x Snapper >/dev/null 2>&1 || true
sleep 0.5
DEST="/Applications/Snapper.app"
if [ -d "$DEST" ] || [ -w "/Applications" ]; then
  echo "==> Updating $DEST"
  rsync -a --delete "$APP/" "$DEST/" 2>/dev/null || { rm -rf "$DEST" && cp -R "$APP" "$DEST"; }
  echo "==> Launching"
  open "$DEST"
else
  echo "==> Launching"
  open "$APP"
fi
