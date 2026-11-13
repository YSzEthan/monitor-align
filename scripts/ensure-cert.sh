#!/bin/sh
# ensure-cert.sh [--no-create] <名稱>
# 確保 login keychain 有這張可簽章的自簽憑證，輸出它的 SHA-1（同名可能有多張，codesign 一律傳 hash）。
# --no-create：只查；沒有就輸出空字串並以 1 結束。
# install.sh 與 app 內「重新簽章…」共用這一份：build-app.sh 會複製到 Contents/Resources/。
set -eu
create=1
if [ "${1:-}" = "--no-create" ]; then create=0; shift; fi
CERT=$1
KC="$HOME/Library/Keychains/login.keychain-db"

# 不能加 -v：自簽憑證沒被信任，-v 看不到它；codesign 不需要信任也能用（實測）。過期與撤銷的不算
identity() { security find-identity -p codesigning | awk -v n="\"$CERT\"" 'index($0, n) && !/EXPIRED|REVOKED/ { print $2; exit }'; }

H=$(identity || true)
if [ -n "$H" ]; then echo "$H"; exit 0; fi
[ "$create" = 1 ] || exit 1

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
# -x：私鑰不可匯出；-T：codesign 可使用
security import "$tmp/c.p12" -k "$KC" -P "$pw" -x -T /usr/bin/codesign >/dev/null

H=$(identity || true)
[ -n "$H" ] || { echo "建立憑證後仍找不到 $CERT" >&2; exit 1; }
echo "$H"
