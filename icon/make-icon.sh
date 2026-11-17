#!/bin/zsh
# Regenerates ../driver/MATBridge.icns (the virtual audio device's icon) from matbridge.svg.
# Needs Google Chrome (to rasterize the SVG with a transparent background); the output is committed,
# so building the driver doesn't need this. Run it only after editing matbridge.svg.
set -e
DIR="${0:A:h}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[[ -x "$CHROME" ]] || { echo "Google Chrome not found at $CHROME"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

cp "$DIR/matbridge.svg" "$TMP/in.svg"
echo "<html><body style=\"margin:0;background:transparent\"><img src=\"in.svg\" width=1024 height=1024 style=\"display:block\"></body></html>" > "$TMP/in.html"
"$CHROME" --headless --disable-gpu --hide-scrollbars --default-background-color=00000000 \
  --window-size=1024,1024 --screenshot="$TMP/icon.png" "file://$TMP/in.html" >/dev/null 2>&1

SET="$TMP/MATBridge.iconset"; mkdir "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$DIR/../driver/MATBridge.icns"
echo "Wrote driver/MATBridge.icns"
