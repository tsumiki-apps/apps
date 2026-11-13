#!/bin/bash
# つみきウェイクを組み立てて ~/Applications/つみき/TsumikiWake.app に置く。自己テストが通らなければ置かない。
# 署名は毎回同じ開発者証明書（証明書の無い Mac では ad-hoc）。
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-$HOME/Applications/つみき/TsumikiWake.app}"
ID="${TSUMIKI_SIGN_ID:-03541F4F153A80FCF6ACD26D006B78CC93C69710}"
security find-identity -v -p codesigning | grep -q "$ID" || { echo "証明書が無いので ad-hoc で署名します"; ID="-"; }
SRC="main.swift Engine.swift Icon.swift SelfTest.swift"
rm -rf build && mkdir -p build
swiftc -O -target "$(uname -m)-apple-macos15.0" -o build/TsumikiWake $SRC
build/TsumikiWake --selftest
# 組み立て・署名は build/ の中で済ませ、通ってから入れ替える（途中で失敗しても動いている版を壊さない）
APP=build/TsumikiWake.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/TsumikiWake "$APP/Contents/MacOS/TsumikiWake"
cp Info.plist "$APP/Contents/Info.plist"
build/TsumikiWake --icons build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$ID" --options runtime "$APP"
codesign --verify "$APP"
RUNNING=0; pgrep -x TsumikiWake >/dev/null && RUNNING=1
[ $RUNNING = 1 ] && { pkill -x TsumikiWake || true; sleep 0.5; }
rm -rf "$OUT" && mkdir -p "$(dirname "$OUT")" && cp -R "$APP" "$OUT"
echo "OK $OUT"
[ $RUNNING = 1 ] && open "$OUT" || true
