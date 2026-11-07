#!/bin/bash
# つみきショットを組み立てて ~/Applications/TsumikiShot.app に置く。
# 署名は毎回同じ開発者証明書（ad-hoc だと組み直すたびに「画面収録」の許可が外れる）。
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-$HOME/Applications/TsumikiShot.app}"
ID="${TSUMIKI_SIGN_ID:-03541F4F153A80FCF6ACD26D006B78CC93C69710}"
rm -rf build && mkdir -p build
swiftc -O -target arm64-apple-macos15.0 -o build/TsumikiShot main.swift Stitcher.swift SelfTest.swift Probe.swift Render.swift Editor.swift Extras.swift ExtraTest.swift Record.swift Shortcuts.swift AutoScroll.swift Icon.swift
build/TsumikiShot --selftest
build/TsumikiShot --extratest build
# 組み立て・署名は build/ の中で済ませ、通ってから入れ替える（途中で失敗しても動いている版を壊さない）
APP=build/TsumikiShot.app
mkdir -p "$APP/Contents/MacOS"
cp build/TsumikiShot "$APP/Contents/MacOS/TsumikiShot"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
build/TsumikiShot --icons build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$ID" --options runtime "$APP"
codesign --verify "$APP"
RUNNING=0; pgrep -x TsumikiShot >/dev/null && RUNNING=1
[ $RUNNING = 1 ] && { pkill -x TsumikiShot || true; sleep 0.5; }
rm -rf "$OUT" && mkdir -p "$(dirname "$OUT")" && cp -R "$APP" "$OUT"
echo "OK $OUT"
# 動いていたなら新しい版で起動し直す
[ $RUNNING = 1 ] && open "$OUT" || true
