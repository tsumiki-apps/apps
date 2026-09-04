#!/bin/zsh
# SVG -> PNG (1920x1080) via headless Chrome
# usage: ./render.sh foo.svg   -> foo.png
set -e
DIR="${0:A:h}"
SVG="$1"
BASE="${SVG:t:r}"
OUT="$DIR/${BASE}.png"

cat > "$DIR/.wrap-$BASE.html" <<HTML
<!doctype html><meta charset="utf-8">
<style>
html,body{margin:0;padding:0;background:#F4F2EE;}
svg{display:block;width:1920px;height:1080px;}
</style>
$(cat "$SVG")
HTML

/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --screenshot="$OUT" --window-size=1920,1080 \
  "file://$DIR/.wrap-$BASE.html" 2>/dev/null

echo "$OUT"
