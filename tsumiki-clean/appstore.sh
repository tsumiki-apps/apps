#!/bin/bash
# App Store に出す .pkg を作る（App Store 版＝箱の中（サンドボックス）で動く版。つみきショットの appstore.sh と同じ形）。
#   ./appstore.sh <版 例 1.0> <組番号 例 1>
# 前もって1回だけ：
#   1. 「Apple Distribution」「Mac Installer Distribution」の証明書（ショットで作ったものをそのまま使う）
#   2. App ID com.tsumiki.clean を登録し、「Mac App Store Connect」のプロファイルを AppStore.provisionprofile の名前で置く（git に入らない）
# 送る：ASC_KEY_ID / ASC_ISSUER を付けると altool で送る。無ければ Transporter.app に pkg を落とす
set -euo pipefail
cd "$(dirname "$0")"
VER="${1:?版（例 1.0）}"; BUILD="${2:?組番号（例 1）}"
BUNDLE_ID="${BUNDLE_ID:-com.tsumiki.clean}"
NAME=TsumikiClean
PROFILE=AppStore.provisionprofile
APPID=$(security find-identity -v -p codesigning | grep -E '"(Apple Distribution|3rd Party Mac Developer Application):' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
PKGID=$(security find-identity -v | grep -E '"(Mac Installer Distribution|3rd Party Mac Developer Installer):' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
DEVID="${TSUMIKI_SIGN_ID:-03541F4F153A80FCF6ACD26D006B78CC93C69710}"
NG=""
[ -n "$APPID" ] || NG+="・「Apple Distribution」の証明書が無い\n"
[ -n "$PKGID" ] || NG+="・「Mac Installer Distribution」の証明書が無い\n"
[ -f "$PROFILE" ] || NG+="・$PROFILE が無い\n"
if [ -n "$NG" ]; then printf "まだ出せません（前準備はこのファイルの先頭）：\n$NG"; exit 1; fi
TEAM=$(security cms -D -i "$PROFILE" | plutil -extract TeamIdentifier.0 raw -)
PBID=$(security cms -D -i "$PROFILE" | plutil -extract Entitlements.com\\.apple\\.application-identifier raw -)
[ "$PBID" = "$TEAM.$BUNDLE_ID" ] || { echo "プロファイルの App ID（$PBID）が $TEAM.$BUNDLE_ID と違う"; exit 1; }

SRC="main.swift Core.swift Blocker.swift Curtain.swift Icon.swift SelfTest.swift"
D=build/appstore && rm -rf "$D" && mkdir -p "$D"
swiftc -O -D APPSTORE -target arm64-apple-macos15.0 -o "$D/arm64" $SRC
swiftc -O -D APPSTORE -target x86_64-apple-macos15.0 -o "$D/x86_64" $SRC
# 自己テストは箱の中で回す（単体のファイルでは箱が立たないので、.app の形にして開発用の証明書＋同じ権限で署名して動かす）
T="$D/sandboxtest/$NAME.app"; mkdir -p "$T/Contents/MacOS"; cp "$D/arm64" "$T/Contents/MacOS/$NAME"; cp Info.plist "$T/Contents/"
codesign --force --sign "$DEVID" --entitlements AppStore.entitlements "$T" 2>/dev/null || codesign --force --sign - --entitlements AppStore.entitlements "$T"
"$T/Contents/MacOS/$NAME" --selftest >/dev/null || { echo "箱の中の自己テストで ✗（$T/Contents/MacOS/$NAME --selftest で中身）"; exit 1; }
echo "箱の中の自己テスト OK"
APP="$D/$NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/$NAME" "$D/arm64" "$D/x86_64"
cp Info.plist "$APP/Contents/Info.plist"
P=/usr/libexec/PlistBuddy
$P -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :CFBundleShortVersionString $VER" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
"$D/arm64" --icons "$D/AppIcon.iconset"
iconutil -c icns "$D/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
xattr -cr "$APP"  # 隔離などの属性が残ると App Store の処理で落ちる（91109）
ENT="$D/signed.entitlements"; cp AppStore.entitlements "$ENT"
$P -c "Add :com.apple.application-identifier string $TEAM.$BUNDLE_ID" -c "Add :com.apple.developer.team-identifier string $TEAM" "$ENT"
codesign --force --sign "$APPID" --options runtime --timestamp --entitlements "$ENT" "$APP"
codesign --verify --strict "$APP"
PKG="$D/$NAME-$VER-$BUILD.pkg"
productbuild --component "$APP" /Applications --sign "$PKGID" "$PKG"
echo "OK $PKG"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER:-}" ]; then
  xcrun altool --validate-app -f "$PKG" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER"
  xcrun altool --upload-app -f "$PKG" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER"
else
  echo "送る：Transporter.app を開いて $PKG を落とす（または ASC_KEY_ID / ASC_ISSUER を付けて再実行）"
fi
