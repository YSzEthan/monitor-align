#!/bin/sh
# 一個指令：（沒有憑證就建立）→ 編譯 → 簽章 → 安裝到 ~/Applications → 啟動。
# 憑證只在本機 Keychain，私鑰不離開這台電腦；用固定憑證簽章，輔助使用授權才不會因重新編譯失效。
set -eu
cd "$(dirname "$0")"
CERT=monitor-align-dev
APP="$HOME/Applications/MonitorAlign.app"
KC="$HOME/Library/Keychains/login.keychain-db"

# 憑證的 SHA-1：同名可能有多張，一律用 hash 指定給 codesign
identity() { security find-identity -p codesigning -v | awk -v n="\"$CERT\"" 'index($0, n) { print $2; exit }'; }

make_cert() {
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT   # 中途失敗也不留未加密私鑰
  pw=$(/usr/bin/openssl rand -hex 12)
  cat > "$tmp/c.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$CERT
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
  # 一定要用 /usr/bin/openssl（LibreSSL）：openssl 3 產的 PKCS#12，security import 讀不了
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/k.pem" -out "$tmp/c.pem" -days 3650 -config "$tmp/c.cnf" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/k.pem" -in "$tmp/c.pem" -out "$tmp/c.p12" -passout "pass:$pw"
  security import "$tmp/c.p12" -k "$KC" -P "$pw" -x -T /usr/bin/codesign >/dev/null
  echo "要信任這張本機憑證（只用於簽章）。請在跳出的視窗輸入登入密碼。"
  security add-trusted-cert -p codeSign "$tmp/c.pem"
}

H=$(identity || true)
if [ -z "$H" ]; then make_cert; H=$(identity || true); fi

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
