#!/bin/bash
# 公証して、どの Mac でも普通に開ける zip を作る（つみきショットと同じ証明書・同じ保存名）。
#   ./notarize.sh <出力.zip>
# 前もって必要なもの（つみきショットで用意済み）：Developer ID Application の証明書と、
#   xcrun notarytool store-credentials tsumikishot …（値はキーチェーン。ここには書かない）
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:?出力の zip を指定}"
PROFILE="${TSUMIKI_NOTARY_PROFILE:-tsumikishot}"
ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)
[ -n "$ID" ] || { echo "Developer ID Application の証明書が見つかりません"; exit 1; }
TMP="build/notary.zip"
TSUMIKI_SIGN_ID="$ID" ./package.sh "$PWD/$TMP"
xcrun notarytool submit "$TMP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple build/dist/TsumikiClip.app
spctl -a -vv -t exec build/dist/TsumikiClip.app
rm -f "$OUT"; ditto -c -k --norsrc --noextattr --noqtn --keepParent build/dist/TsumikiClip.app "$OUT"
echo "OK ${OUT}（公証済み）"
