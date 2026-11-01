#!/bin/zsh
# Builds the downloadable release: dist/RefWare-<version>-macOS.zip with the app (Apple Silicon
# and Intel), the Chrome extension, and install notes. Attach the zip to a GitHub Release.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: make-release.sh <version, e.g. 1.0>}"
OUT="dist/RefWare-$VERSION"
rm -rf "$OUT" "$OUT-macOS.zip"
mkdir -p "$OUT"
./scripts/build-app.sh "$OUT/RefWare.app" --universal
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$OUT/RefWare.app/Contents/Info.plist"
xattr -cr "$OUT"
codesign --force --sign - "$OUT/RefWare.app"
cp -R browser/chrome "$OUT/RefWare Chrome Extension"
cat > "$OUT/INSTALL.txt" <<'TXT'
RefWare — installing

1. Drag RefWare.app into your Applications folder.

2. Open it. The first time, macOS says it can't verify the developer (this release
   isn't notarized by Apple yet). Open System Settings ▸ Privacy & Security, scroll
   down, click "Open Anyway" next to RefWare, and confirm. You only do this once.

3. Point RefWare at your library (a new one is created if the file doesn't exist):
     /Applications/RefWare.app/Contents/MacOS/refware config --library ~/Documents/RefWare/library.json --project UEF-0001 --reviewer <your initials>

4. Command line (for you and for AI agents such as Claude Code or Codex), in Terminal:
     mkdir -p ~/.local/bin && ln -sf /Applications/RefWare.app/Contents/MacOS/refware ~/.local/bin/refware
   then, if `refware` isn't found in a new Terminal window:
     echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
   Agents: see AGENTS.md in the repository.

5. Chrome extension (optional — one-click "send this page to RefWare"):
   Move the "RefWare Chrome Extension" folder somewhere permanent (e.g. Documents).
   In Chrome, open chrome://extensions, turn on Developer mode (top right), click
   "Load unpacked", and choose that folder. Brave, Edge and Arc work the same way.
   Then open RefWare once more so it can connect to the browser.

Documentation and source: the RefWare repository on GitHub (README.md).
TXT
cp LICENSE NOTICE "$OUT/"
ditto -c -k --norsrc --noextattr --keepParent "$OUT" "$OUT-macOS.zip"
echo "Release: $OUT-macOS.zip ($(du -h "$OUT-macOS.zip" | cut -f1))"
lipo -archs "$OUT/RefWare.app/Contents/MacOS/RefWareCapture"
