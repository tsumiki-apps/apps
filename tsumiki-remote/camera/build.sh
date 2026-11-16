#!/bin/bash
# つみきカメラ.app を ~/Applications に作る。
# ⚠️ ad-hoc 署名（鍵が無いとき）だと、作り直すたびにカメラの許可が効かなくなる（設定の一覧から − で消して取り直し）。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="$HOME/Applications/つみきカメラ.app"
# 先に別の場所で組んで署名まで済ませる（組めない・署名できないときに、動いている今のアプリを消さない）
work="$(mktemp -d)"
tmpapp="$work/つみきカメラ.app"
mkdir -p "$tmpapp/Contents/MacOS"
swiftc -O -o "$tmpapp/Contents/MacOS/tsumiki-camera" "$here/main.swift"
cat > "$tmpapp/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.tsumiki.camera</string>
  <key>CFBundleName</key><string>つみきカメラ</string>
  <key>CFBundleExecutable</key><string>tsumiki-camera</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>NSCameraUsageDescription</key><string>つみきリモートから Mac の内蔵カメラを1枚撮るため</string>
</dict></plist>
PL
# 署名の鍵：CAMERA_SIGN_ID（ハッシュ）を渡せばそれ。無ければ「Developer ID Application」が1つだけのときそれ。
# 2つ以上あると黙って別の鍵になり許可が外れるので止める。1つも無ければ ad-hoc（作り直すたびに許可の取り直し）
id="${CAMERA_SIGN_ID:-}"
if [ -z "$id" ]; then
  ids="$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2}')"
  n="$(printf '%s' "$ids" | grep -c . || true)"
  if [ "$n" -gt 1 ]; then echo "Developer ID の鍵が $n 個あります。CAMERA_SIGN_ID=<ハッシュ> を付けて撃ってください" >&2; exit 1; fi
  id="$ids"
fi
[ -z "$id" ] && echo "⚠️ Developer ID の鍵がありません。ad-hoc 署名にします（カメラの許可を取り直すことになります）" >&2
codesign --force --sign "${id:--}" --identifier com.tsumiki.camera "$tmpapp"
rm -rf "$app"
mv "$tmpapp" "$app"
rm -rf "$work"
echo "$app"
