#!/bin/sh
# 用法：make-dmg.sh <MonitorAlign.app> <輸出.dmg>
# DMG 內放 app 與「Applications」捷徑，使用者開啟後拖進去即可。release.yml 與 CI 共用。
set -eu
APP=$1 OUT=$2
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ditto "$APP" "$TMP/$(basename "$APP")"
ln -s /Applications "$TMP/Applications"
rm -f "$OUT"
# CI 的 hdiutil 偶爾回 Resource busy，重試幾次
for i in 1 2 3; do
  hdiutil create -volname MonitorAlign -srcfolder "$TMP" -ov -format UDZO "$OUT" >/dev/null && exit 0
  sleep 2
done
echo "hdiutil create 失敗" >&2
exit 1
