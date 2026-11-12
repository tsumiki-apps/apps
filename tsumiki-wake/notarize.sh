#!/bin/bash
# 公証して、どの Mac でも普通に開ける zip を作る（有料の Apple Developer Program が要る）。
#   ./notarize.sh <出力.zip>
# 証明書・鍵は ~/.tsumiki-signing から鍵束に入れたもの（Developer ID Application）。
# notarytool の保存名はつみきショットと同じ tsumikishot（作り方は ../tsumiki-shot/notarize.sh の先頭）。
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:?出力の zip を指定}"
PROFILE="${TSUMIKI_NOTARY_PROFILE:-tsumikishot}"
ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)
[ -n "$ID" ] || { echo "Developer ID Application の証明書が見つかりません（~/.tsumiki-signing/import.sh）"; exit 1; }
TMP="build/notary.zip"
TSUMIKI_SIGN_ID="$ID" ./package.sh "$PWD/$TMP"
xcrun notarytool submit "$TMP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple build/dist/TsumikiWake.app          # 公証の印をアプリに貼る（ネットが無くても開ける）
spctl -a -vv -t exec build/dist/TsumikiWake.app          # 「accepted / Notarized Developer ID」なら OK
rm -f "$OUT"; ditto -c -k --norsrc --keepParent build/dist/TsumikiWake.app "$OUT"
unzip -l "$OUT" | grep -q '/\._' && { echo "zip に ._ が入っています"; exit 1; }
echo "OK ${OUT}（公証済み）"
