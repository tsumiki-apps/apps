#!/bin/bash
# つみきロックを組み立てて ~/Applications/TsumikiLock.app に置く。
# 署名は毎回同じ開発者証明書で行う（ad-hoc だと組み直すたびに鍵束が「許可しますか」を出し、
# 幕の裏に隠れて合言葉が読めなくなる）。
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-$HOME/Applications/TsumikiLock.app}"
ID="${TSUMIKI_SIGN_ID:-03541F4F153A80FCF6ACD26D006B78CC93C69710}"
rm -rf build && mkdir -p build
swiftc -O -o build/TsumikiLock main.swift 2>&1 | grep -v "^$" || true
test -x build/TsumikiLock
mkdir -p "$OUT/Contents/MacOS"
cp build/TsumikiLock "$OUT/Contents/MacOS/TsumikiLock"
cp Info.plist "$OUT/Contents/Info.plist"
codesign --force --sign "$ID" --options runtime --entitlements TsumikiLock.entitlements "$OUT"
codesign --verify "$OUT" && echo "OK $OUT"
