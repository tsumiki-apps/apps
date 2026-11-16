#!/bin/bash
# つみきカメラ.app を ~/Applications に作る。
# ⚠️ ad-hoc 署名（鍵が無いとき）だと、作り直すたびにカメラの許可が効かなくなる（設定の一覧から − で消して取り直し）。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="$HOME/Applications/つみきカメラ.app"
# 先に別の場所で組む（組めなかったときに、動いている今のアプリを消さない）
bin="$(mktemp -d)/tsumiki-camera"
swiftc -O -o "$bin" "$here/main.swift"
rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
mv "$bin" "$app/Contents/MacOS/tsumiki-camera"
cat > "$app/Contents/Info.plist" <<PL
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
# 署名は「Developer ID Application」の鍵で（作り直しても同じ鍵なら許可が外れない）。無ければ ad-hoc
id="$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')"
codesign --force --sign "${id:--}" --identifier com.tsumiki.camera "$app"
echo "$app"
