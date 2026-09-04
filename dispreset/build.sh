#!/bin/bash
# ディスプレイ配置.app を作り直す。
# AppleScript を書き換えたら、これを実行すれば ~/Applications に入る。
set -euo pipefail

cd "$(dirname "$0")"
APP="$HOME/Applications/ディスプレイ配置.app"

rm -rf "$APP"
mkdir -p "$HOME/Applications"
osacompile -o "$APP" ディスプレイ配置.applescript

# アイコンを差し替え（Dock で一目でわかるように）
cp ディスプレイ配置.icns "$APP/Contents/Resources/applet.icns"

# 正式な bundle id を付ける。
# これがあると、自動復元の常駐項目を plist の AssociatedBundleIdentifiers で
# このアプリに紐付けられ、「ログイン項目と機能拡張」に "ディスプレイ配置" と表示される。
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.kodai.dispreset' "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.kodai.dispreset' "$APP/Contents/Info.plist"

# Resources を触ると署名が壊れるので ad-hoc で署名し直す
codesign --force --deep --sign - "$APP" 2>/dev/null

# Launch Services に登録（この名前で認識させるため）
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

# Finder / Dock のアイコンキャッシュを更新させる
touch "$APP"

echo "ビルド完了: $APP"
