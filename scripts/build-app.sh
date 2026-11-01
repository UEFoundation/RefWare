#!/bin/zsh
# Builds RefWare.app at the given path.  --universal: one app for Apple Silicon and Intel Macs.
#   scripts/build-app.sh ~/Applications/RefWare.app
#   scripts/build-app.sh dist/RefWare.app --universal
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:?usage: build-app.sh <path/RefWare.app> [--universal]}"
if [ "${2:-}" = "--universal" ]; then
  for ARCH in arm64 x86_64; do
    for P in RefWareCapture refware; do
      swift build -c release --triple "$ARCH-apple-macosx14.0" --product "$P"
    done
  done
  BIN=.build/universal
  mkdir -p "$BIN"
  for P in RefWareCapture refware; do
    lipo -create ".build/arm64-apple-macosx/release/$P" ".build/x86_64-apple-macosx/release/$P" -output "$BIN/$P"
  done
else
  swift build -c release --product RefWareCapture
  swift build -c release --product refware
  BIN=.build/release
fi


rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/RefWareCapture" "$APP/Contents/MacOS/RefWareCapture"
# The charter's RPA Attribution Log is shown in the app (Credits, Records ▸ Development record).
mkdir -p "$APP/Contents/Resources"
[ -f "Project Charter RefWare.txt" ] && cp "Project Charter RefWare.txt" "$APP/Contents/Resources/ProjectCharter.txt"
[ -f assets/AppIcon.icns ] || ./scripts/make-icons.sh
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>RefWare</string>
  <key>CFBundleDisplayName</key><string>RefWare</string>
  <key>CFBundleIdentifier</key><string>ai.uefoundation.refware.capture</string>
  <key>CFBundleExecutable</key><string>RefWareCapture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>RefWare reads the address of your front browser tab so it can add that page or PDF to your reference library.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>RefWare capture link</string>
      <key>CFBundleURLSchemes</key><array><string>refware</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# The CLI travels inside the app; it doubles as Chrome's native-messaging host.
cp "$BIN/refware" "$APP/Contents/MacOS/refware"

# No extended attributes inside the bundle: some unzip tools turn them into ._ files, breaking the seal.
xattr -cr "$APP"
# Ad-hoc signature (inner tool first). Releases get a Developer ID signature once the Foundation has one.
codesign --force --sign - "$APP/Contents/MacOS/refware"
codesign --force --sign - "$APP/Contents/MacOS/RefWareCapture"
codesign --force --sign - "$APP"

