#!/bin/bash
# まどわけ.app を組み立てて madowake.zip にする（Apple Silicon・Intel 両方で動く1本）
set -euo pipefail
cd "$(dirname "$0")"
OUT=build; APP="$OUT/まどわけ.app"
rm -rf "$OUT"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for a in arm64 x86_64; do
  swiftc -O -target $a-apple-macos13 Core.swift main.swift -o "$OUT/madowake-$a"
done
lipo -create "$OUT"/madowake-arm64 "$OUT"/madowake-x86_64 -output "$APP/Contents/MacOS/madowake"
rm "$OUT"/madowake-*

# アイコン
IS="$OUT/AppIcon.iconset"; mkdir -p "$IS"
for s in 16 32 128 256 512; do
  sips -z $s $s icon_1024.png --out "$IS/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) icon_1024.png --out "$IS/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$IS" -o "$APP/Contents/Resources/AppIcon.icns"; rm -rf "$IS"

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --options runtime "$APP"
ditto -c -k --norsrc --keepParent "$APP" "$OUT/madowake.zip"
echo "OK: $OUT/madowake.zip"
