#!/bin/bash
# つみきそうじを組み立てて ~/Applications/つみき/TsumikiClean.app に置く。
# 署名は毎回同じ開発者証明書（ad-hoc だと組み直すたびに「アクセシビリティ」の許可が外れる）。
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-$HOME/Applications/つみき/TsumikiClean.app}"
ID="${TSUMIKI_SIGN_ID:-03541F4F153A80FCF6ACD26D006B78CC93C69710}"
security find-identity -v -p codesigning | grep -q "$ID" || { echo "証明書が無いので ad-hoc で署名します"; ID="-"; }
SRC="main.swift Core.swift Blocker.swift Curtain.swift Icon.swift SelfTest.swift"
rm -rf build && mkdir -p build
swiftc -O -target "$(uname -m)-apple-macos15.0" -o build/TsumikiClean $SRC
build/TsumikiClean --selftest
# 組み立て・署名は build/ の中で済ませ、通ってから入れ替える
APP=build/TsumikiClean.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/TsumikiClean "$APP/Contents/MacOS/TsumikiClean"
cp Info.plist "$APP/Contents/Info.plist"
build/TsumikiClean --icons build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$ID" --options runtime "$APP"
codesign --verify "$APP"
RUNNING=0; pgrep -x TsumikiClean >/dev/null && RUNNING=1
[ $RUNNING = 1 ] && { pkill -x TsumikiClean || true; sleep 0.5; }
rm -rf "$OUT" && mkdir -p "$(dirname "$OUT")" && cp -R "$APP" "$OUT"
echo "OK $OUT"
