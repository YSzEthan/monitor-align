#!/bin/sh
# 一個指令：（沒有憑證就建立）→ 編譯 → 簽章 → 安裝到 ~/Applications → 啟動。
# 憑證只在本機 Keychain，私鑰不離開這台電腦；用固定憑證簽章，輔助使用授權才不會因重新編譯失效。
set -eu
cd "$(dirname "$0")"
CERT=monitor-align-dev
APP="$HOME/Applications/MonitorAlign.app"

# 憑證的 SHA-1：沒有就建立（同名可能有多張，一律用 hash 指定給 codesign）。
# 自簽憑證不需要 add-trusted-cert 也能簽章，所以不會跳密碼視窗
H=$(scripts/ensure-cert.sh "$CERT") || H=

scripts/build-app.sh >/dev/null
NEW=build/MonitorAlign.app
if [ -n "$H" ]; then
  codesign --force -s "$H" --identifier dev.monitor-align "$NEW"
else
  echo "警告：找不到可用的簽章憑證，改用 ad-hoc 簽章。每次重新編譯後都要重新授權輔助使用。"
fi

# 簽章身分變了（第一次換成自簽憑證、或憑證重建）：舊授權對不上，清掉讓系統重新詢問
dr() { codesign -d -r- "$1" 2>&1 | grep '^designated' || true; }
if [ "$(dr "$APP")" != "$(dr "$NEW")" ]; then
  tccutil reset Accessibility dev.monitor-align >/dev/null 2>&1 || true
  echo "簽章身分有變，啟動後請在 系統設定 → 隱私權與安全性 → 輔助使用 允許 MonitorAlign（只需這一次）。"
fi

pkill -f "$APP/Contents/MacOS/monitor-align" 2>/dev/null || true
sleep 0.5
mkdir -p "$HOME/Applications" "$HOME/.local/bin"
rm -rf "$APP"
ditto "$NEW" "$APP"
ln -sf "$APP/Contents/MacOS/monitor-align" "$HOME/.local/bin/monitor-align"
open "$APP"
echo "已安裝並啟動：${APP}（選單列右上角的雙螢幕圖示）"
