#!/bin/bash
# 別の Mac へ持っていく用：Apple シリコンと Intel の両方で動く .app を作り、zip にする。
#   ./package.sh <出力.zip>
# 署名はこの Mac の開発者証明書（無ければ ad-hoc）。公証はしていない＝初回は「このまま開く」が要る。
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:?出力の zip を指定}"
ID="${TSUMIKI_SIGN_ID:-03541F4F153A80FCF6ACD26D006B78CC93C69710}"
security find-identity -v -p codesigning | grep -q "$ID" || { echo "証明書が無いので ad-hoc で署名します"; ID="-"; }
SRC="main.swift Stitcher.swift SelfTest.swift Probe.swift Render.swift Editor.swift Extras.swift ExtraTest.swift Record.swift Shortcuts.swift AutoScroll.swift Icon.swift"
D=build/dist && rm -rf "$D" && mkdir -p "$D"
swiftc -O -target arm64-apple-macos15.0 -o "$D/arm64" $SRC
swiftc -O -target x86_64-apple-macos15.0 -o "$D/x86_64" $SRC
"$D/arm64" --selftest >/dev/null && "$D/arm64" --extratest "$D" >/dev/null
# Intel 側も確かめる（Rosetta があるときだけ）
if arch -x86_64 /usr/bin/true 2>/dev/null; then
  # 結果は出すが止めない（Rosetta の上では文字の読み取りだけ ✗ になる＝本物の Intel 機とは違う）
  NG=$( { arch -x86_64 "$D/x86_64" --selftest; arch -x86_64 "$D/x86_64" --extratest "$D"; } 2>&1 | grep "✗" || true)
  if [ -z "$NG" ]; then echo "Intel 側の自己テスト OK"; else echo "Intel 側（Rosetta）で ✗："; echo "$NG"; fi
else echo "Rosetta が無いので Intel 側の自己テストは飛ばしました"; fi
APP="$D/TsumikiShot.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/TsumikiShot" "$D/arm64" "$D/x86_64"
cp Info.plist "$APP/Contents/Info.plist"
"$D/arm64" --icons "$D/AppIcon.iconset"
iconutil -c icns "$D/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$ID" --options runtime "$APP"
codesign --verify "$APP"
rm -f "$OUT"; ditto -c -k --keepParent "$APP" "$OUT"
echo "OK ${OUT} ($(lipo -archs "${APP}/Contents/MacOS/TsumikiShot"))"
