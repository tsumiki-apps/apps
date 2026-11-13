#!/bin/bash
# 公証して、どの Mac でも普通に開ける zip を作る（有料の Apple Developer Program が要る）。
#   ./notarize.sh <出力.zip>
# 前もって1回だけ：
#   1. Xcode → 設定 → Accounts → Manage Certificates → ＋ → 「Developer ID Application」を作る
#   2. appleid.apple.com でアプリ用パスワードを作り、次を実行（値はキーチェーンに入る。ここには書かない）
#      xcrun notarytool store-credentials tsumikishot --apple-id <Apple ID> --team-id <チームID>
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:?出力の zip を指定}"
PROFILE="${TSUMIKI_NOTARY_PROFILE:-tsumikishot}"
ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)
[ -n "$ID" ] || { echo "Developer ID Application の証明書が見つかりません（上の手順1）"; exit 1; }
TMP="build/notary.zip"
TSUMIKI_SIGN_ID="$ID" ./package.sh "$PWD/$TMP"
xcrun notarytool submit "$TMP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple build/dist/TsumikiShot.app          # 公証の印をアプリに貼る（ネットが無くても開ける）
spctl -a -vv -t exec build/dist/TsumikiShot.app          # 「accepted / Notarized Developer ID」なら OK
rm -f "$OUT"; ditto -c -k --norsrc --noextattr --noacl --keepParent build/dist/TsumikiShot.app "$OUT"
echo "OK ${OUT}（公証済み）"
