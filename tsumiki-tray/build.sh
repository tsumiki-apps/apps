#!/bin/bash
# つみきトレイを組み立てて ~/Applications/つみき/TsumikiTray.app に置く。
# 自己テストが通らなければ置かない。署名は毎回同じ開発者証明書（無ければ ad-hoc）。
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-$HOME/Applications/つみき/TsumikiTray.app}"
ID="${TSUMIKI_SIGN_ID:-03541F4F153A80FCF6ACD26D006B78CC93C69710}"
security find-identity -v -p codesigning | grep -q "$ID" || { echo "証明書が無いので ad-hoc で署名します"; ID="-"; }
SRC="main.swift Store.swift Shelf.swift Icon.swift SelfTest.swift"
rm -rf build && mkdir -p build
# その Mac の種類（Apple シリコン＝arm64・Intel＝x86_64）に合わせて組み立てる
swiftc -O -target "$(uname -m)-apple-macos15.0" -o build/TsumikiTray $SRC
build/TsumikiTray --selftest
# 組み立て・署名は build/ の中で済ませ、通ってから入れ替える（途中で失敗しても動いている版を壊さない）
APP=build/TsumikiTray.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/TsumikiTray "$APP/Contents/MacOS/TsumikiTray"
cp Info.plist "$APP/Contents/Info.plist"
build/TsumikiTray --icons build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$ID" --options runtime "$APP"
codesign --verify "$APP"
RUNNING=0; pgrep -x TsumikiTray >/dev/null && RUNNING=1
[ $RUNNING = 1 ] && { pkill -x TsumikiTray || true; sleep 0.5; }
rm -rf "$OUT" && mkdir -p "$(dirname "$OUT")" && cp -R "$APP" "$OUT"
echo "OK $OUT"
# 動いていたなら新しい版で起動し直す
[ $RUNNING = 1 ] && open "$OUT" || true
