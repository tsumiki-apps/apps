#!/bin/bash
# TsumikiSnap.app（つみきスナップ）を組み立てて tsumiki-snap.zip にする（Apple Silicon・Intel 両方で動く1本）
set -euo pipefail
cd "$(dirname "$0")"
OUT=build; APP="$OUT/TsumikiSnap.app"
rm -rf "$OUT"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for a in arm64 x86_64; do
  swiftc -O -target $a-apple-macos13 Core.swift Keys.swift Icon.swift SelfTest.swift main.swift -o "$OUT/TsumikiSnap-$a"
done
lipo -create "$OUT"/TsumikiSnap-arm64 "$OUT"/TsumikiSnap-x86_64 -output "$APP/Contents/MacOS/TsumikiSnap"
rm "$OUT"/TsumikiSnap-*

# アイコン（コードで描く。build/icon_1024.png も出る＝配布ページ用）
"$APP/Contents/MacOS/TsumikiSnap" --icons "$OUT/AppIcon.iconset"
iconutil -c icns "$OUT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"; rm -rf "$OUT/AppIcon.iconset"

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --options runtime "$APP"
ditto -c -k --norsrc --keepParent "$APP" "$OUT/tsumiki-snap.zip"
echo "OK: $OUT/tsumiki-snap.zip"
