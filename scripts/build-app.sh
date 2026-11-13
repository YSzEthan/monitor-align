#!/bin/sh
# 編譯並組出 build/MonitorAlign.app（ad-hoc 簽章）。install.sh 與 CI 共用。
# 版號由環境變數 VERSION 帶入，沒帶就是 dev。
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-build}/MonitorAlign.app
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
swiftc -O monitor-align.swift -o "$OUT/Contents/MacOS/monitor-align"
# app 內「重新簽章…」要用：Release 的使用者沒有這個 repo
cp scripts/ensure-cert.sh "$OUT/Contents/Resources/"
sed "s/__VERSION__/${VERSION:-dev}/g" Info.plist > "$OUT/Contents/Info.plist"
# icon 由程式碼畫（不放二進位檔）；一定要在 codesign 之前，icns 才會被簽章封住
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
"$OUT/Contents/MacOS/monitor-align" --make-icon "$TMP"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$OUT/Contents/Resources/AppIcon.icns"
codesign --force -s - --identifier dev.monitor-align "$OUT"
touch "$OUT"   # 讓 Finder 重讀 icon
echo "$OUT"
