#!/bin/bash
# まどわけを Developer ID で署名して公証し、どの Mac でも普通に開ける zip を作る（つみきショットの notarize.sh と同じ流れ）。
#   ./notarize.sh [出力.zip 既定 build/madowake.zip]
# 前もって：Developer ID Application の証明書と、notarytool の保存名 tsumikishot（キーチェーン）
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-$PWD/build/madowake.zip}"
PROFILE="${TSUMIKI_NOTARY_PROFILE:-tsumikishot}"
ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)
[ -n "$ID" ] || { echo "Developer ID Application の証明書が見つかりません"; exit 1; }
./build.sh >/dev/null
APP="build/まどわけ.app"
xattr -cr "$APP"
codesign --force --sign "$ID" --options runtime --timestamp "$APP"
codesign --verify --strict "$APP"
TMP=build/notary.zip; rm -f "$TMP"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" "$TMP"
xcrun notarytool submit "$TMP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl -a -vv -t exec "$APP"          # 「accepted / Notarized Developer ID」なら OK
rm -f "$OUT" "$TMP"; ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" "$OUT"
echo "OK ${OUT}（公証済み）"
