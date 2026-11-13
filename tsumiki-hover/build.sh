#!/bin/bash
# つみきホバーを組み立てて ~/Applications/つみき/TsumikiHover.app に置く。
# 署名は毎回同じ開発者証明書（ad-hoc だと組み直すたびに「アクセシビリティ」の許可が外れる）。
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-$HOME/Applications/つみき/TsumikiHover.app}"
ID="${TSUMIKI_SIGN_ID:-03541F4F153A80FCF6ACD26D006B78CC93C69710}"
security find-identity -v -p codesigning | grep -q "$ID" || { echo "証明書が無いので ad-hoc で署名します"; ID="-"; }
rm -rf build && mkdir -p build
swiftc -O -target "$(uname -m)-apple-macos15.0" -o build/TsumikiHover main.swift Engine.swift SelfTest.swift LiveTest.swift Icon.swift
build/TsumikiHover --selftest
# 本物の窓での試験は、許可があるときだけ（端末に「アクセシビリティ」の許可があれば通る）
if [ "${HOVER_LIVE:-0}" = 1 ]; then build/TsumikiHover --livetest; fi
# 組み立て・署名は build/ の中で済ませ、通ってから入れ替える（途中で失敗しても動いている版を壊さない）
APP=build/TsumikiHover.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/TsumikiHover "$APP/Contents/MacOS/TsumikiHover"
cp Info.plist "$APP/Contents/Info.plist"
build/TsumikiHover --icons build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$ID" --options runtime "$APP"
codesign --verify "$APP"
RUNNING=0; pgrep -x TsumikiHover >/dev/null && RUNNING=1
[ $RUNNING = 1 ] && { pkill -x TsumikiHover || true; sleep 0.5; }
rm -rf "$OUT" && mkdir -p "$(dirname "$OUT")" && cp -R "$APP" "$OUT"
echo "OK $OUT"
# 動いていたなら新しい版で起動し直す
[ $RUNNING = 1 ] && open "$OUT" || true
