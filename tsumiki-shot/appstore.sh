#!/bin/bash
# App Store に出す .pkg を作る（App Store 版＝-D APPSTORE：箱の中で動く・Mac 標準のキーは書き換えない・既定のキーは ⌥⇧⌘）。
#   ./appstore.sh <版 例 1.0> <組番号 例 1>
# 前もって1回だけ（有料の Apple Developer Program に入ってから）：
#   1. developer.apple.com → Certificates で「Apple Distribution」と「Mac Installer Distribution」を作ってこの Mac に入れる
#   2. Identifiers で App ID を登録（既定 com.tsumiki.shot・変えるなら BUNDLE_ID=…）
#   3. Profiles で「Mac App Store Connect」のプロファイルを作り、このフォルダに AppStore.provisionprofile の名前で置く（git に入らない）
#   4. sudo xcodebuild -license accept（Xcode の使用許諾。送る道具 altool に要る）
# 送る：API キーがあれば ASC_KEY_ID / ASC_ISSUER を付けると altool で送る。無ければ Transporter.app に pkg を落とす
set -euo pipefail
cd "$(dirname "$0")"
VER="${1:?版（例 1.0）}"; BUILD="${2:?組番号（例 1）}"
BUNDLE_ID="${BUNDLE_ID:-com.tsumiki.shot}"
PROFILE=AppStore.provisionprofile
APPID=$(security find-identity -v -p codesigning | grep -E '"(Apple Distribution|3rd Party Mac Developer Application):' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
PKGID=$(security find-identity -v | grep -E '"(Mac Installer Distribution|3rd Party Mac Developer Installer):' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
NG=""
[ -n "$APPID" ] || NG+="・「Apple Distribution」の証明書が無い\n"
[ -n "$PKGID" ] || NG+="・「Mac Installer Distribution」の証明書が無い\n"
[ -f "$PROFILE" ] || NG+="・$PROFILE が無い\n"
if [ -n "$NG" ]; then printf "まだ出せません（前準備はこのファイルの先頭）：\n$NG"; exit 1; fi
TEAM=$(security cms -D -i "$PROFILE" | plutil -extract TeamIdentifier.0 raw -)
PBID=$(security cms -D -i "$PROFILE" | plutil -extract Entitlements.com\\.apple\\.application-identifier raw -)
[ "$PBID" = "$TEAM.$BUNDLE_ID" ] || { echo "プロファイルの App ID（$PBID）が $TEAM.$BUNDLE_ID と違う"; exit 1; }

SRC="main.swift Stitcher.swift SelfTest.swift Probe.swift Render.swift Editor.swift Extras.swift ExtraTest.swift Record.swift Shortcuts.swift AutoScroll.swift Icon.swift"
D=build/appstore && rm -rf "$D" && mkdir -p "$D"
swiftc -O -D APPSTORE -target arm64-apple-macos15.0 -o "$D/arm64" $SRC
swiftc -O -D APPSTORE -target x86_64-apple-macos15.0 -o "$D/x86_64" $SRC
"$D/arm64" --selftest >/dev/null && "$D/arm64" --extratest "$D" >/dev/null
APP="$D/TsumikiShot.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/TsumikiShot" "$D/arm64" "$D/x86_64"
cp Info.plist "$APP/Contents/Info.plist"
P=/usr/libexec/PlistBuddy
$P -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :CFBundleShortVersionString $VER" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
"$D/arm64" --icons "$D/AppIcon.iconset"
iconutil -c icns "$D/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
xattr -cr "$APP"  # 隔離などの属性が残ると App Store の処理で落ちる（91109）
# 署名に使う権限＝AppStore.entitlements ＋ チームと App ID
ENT="$D/signed.entitlements"; cp AppStore.entitlements "$ENT"
$P -c "Add :com.apple.application-identifier string $TEAM.$BUNDLE_ID" -c "Add :com.apple.developer.team-identifier string $TEAM" "$ENT"
codesign --force --sign "$APPID" --options runtime --timestamp --entitlements "$ENT" "$APP"
codesign --verify --strict "$APP"
PKG="$D/TsumikiShot-$VER-$BUILD.pkg"
productbuild --component "$APP" /Applications --sign "$PKGID" "$PKG"
echo "OK $PKG"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER:-}" ]; then
  xcrun altool --validate-app -f "$PKG" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER"
  xcrun altool --upload-app -f "$PKG" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER"
else
  echo "送る：Transporter.app を開いて $PKG を落とす（または ASC_KEY_ID / ASC_ISSUER を付けて再実行）"
fi
