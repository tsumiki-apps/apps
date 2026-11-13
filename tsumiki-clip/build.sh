#!/bin/bash
# つみきクリップを組み立てて ~/Applications/つみき/TsumikiClip.app に置く。
# 署名は毎回同じ開発者証明書（ad-hoc だと組み直すたびに「アクセシビリティ」の許可が外れる）。
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-$HOME/Applications/つみき/TsumikiClip.app}"
ID="${TSUMIKI_SIGN_ID:-03541F4F153A80FCF6ACD26D006B78CC93C69710}"
security find-identity -v -p codesigning | grep -q "$ID" || { echo "証明書が無いので ad-hoc で署名します"; ID="-"; }
SRC="main.swift Store.swift Clipboard.swift Strip.swift Settings.swift Keys.swift Icon.swift SelfTest.swift"
# ネットにつながるコードを持たない（履歴を外に送らない）ことを毎回確かめる
if grep -nE "URLSession|NWConnection|NSURLConnection|CFSocket|import Network|CloudKit|NSUbiquitous" $SRC; then echo "✗ ネットにつながるコードがある"; exit 1; fi
rm -rf build && mkdir -p build
swiftc -O -target "$(uname -m)-apple-macos15.0" -o build/TsumikiClip $SRC
build/TsumikiClip --selftest
APP=build/TsumikiClip.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/TsumikiClip "$APP/Contents/MacOS/TsumikiClip"
cp Info.plist "$APP/Contents/Info.plist"
build/TsumikiClip --icons build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$ID" --options runtime "$APP"
codesign --verify "$APP"
RUNNING=0; pgrep -x TsumikiClip >/dev/null && RUNNING=1
[ $RUNNING = 1 ] && { pkill -x TsumikiClip || true; sleep 0.5; }
rm -rf "$OUT" && mkdir -p "$(dirname "$OUT")" && cp -R "$APP" "$OUT"
echo "OK $OUT"
[ $RUNNING = 1 ] && open "$OUT" || true
