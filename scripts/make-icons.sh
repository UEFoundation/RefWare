#!/bin/zsh
# Builds assets/AppIcon.icns and the Chrome extension icons from assets/RefWare-logo.png.
# Best source: a 1024×1024 PNG (smaller sources are upscaled and look soft at large sizes).
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=assets/RefWare-logo.png
SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET" browser/chrome/icons
for s in 16 32 128 256 512; do
  sips -z $s $s "$SRC" --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); sips -z $d $d "$SRC" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o assets/AppIcon.icns
for s in 16 32 48 128; do sips -z $s $s "$SRC" --out "browser/chrome/icons/icon-$s.png" >/dev/null; done
echo "Built assets/AppIcon.icns and browser/chrome/icons/ from $SRC ($(sips -g pixelWidth "$SRC" | awk '/pixelWidth/{print $2}') px)"
