#!/bin/zsh
# Builds "RefWare.app" (library window, review window, browser capture) into ~/Applications
# and registers the refware:// link type.
set -euo pipefail
cd "$(dirname "$0")/.."

OLD="$HOME/Applications/RefWare Capture.app"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -d "$OLD" ]; then "$LSREG" -u "$OLD" 2>/dev/null || true; rm -rf "$OLD"; fi
APP="$HOME/Applications/RefWare.app"
./scripts/build-app.sh "$APP"

# Chrome-family browsers: let the RefWare extension talk to RefWare directly (no refware:// prompts).
# The extension's ID is fixed by the "key" in its manifest. (The app also does this itself at launch.)
EXT_ID=gjhkilaogdpgoffbffmnmoeijkgjhccm
for BROWSER in "Google/Chrome" "Google/Chrome Beta" "Google/Chrome Canary" "Chromium" "BraveSoftware/Brave-Browser" "Microsoft Edge" "Arc/User Data"; do
  BASE="$HOME/Library/Application Support/$BROWSER"
  [ -d "$BASE" ] || continue
  mkdir -p "$BASE/NativeMessagingHosts"
  cat > "$BASE/NativeMessagingHosts/ai.uefoundation.refware.json" <<JSON
{
  "name": "ai.uefoundation.refware",
  "description": "RefWare — send pages and PDFs to your reference library",
  "path": "$APP/Contents/MacOS/refware",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXT_ID/"]
}
JSON
  echo "Browser bridge: $BROWSER (extension $EXT_ID)"
done
"$LSREG" -f "$APP"

# The command line (for you and for AI agents): ~/.local/bin/refware → the copy inside the app.
mkdir -p "$HOME/.local/bin"
ln -sf "$APP/Contents/MacOS/refware" "$HOME/.local/bin/refware"

echo "Installed: $APP"
echo "CLI:       $HOME/.local/bin/refware"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "           (add it to your PATH:  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc  then open a new terminal)" ;;
esac
echo "Chrome extension: chrome://extensions → Developer mode → Load unpacked → $(pwd)/browser/chrome"
echo
echo "Bookmarklet (save as a bookmark named “Send to RefWare”):"
echo "javascript:(()=>{location.href='refware://capture?url='+encodeURIComponent(location.href)})()"
