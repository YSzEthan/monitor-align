#!/bin/sh
# 從 GitHub Release 安裝最新 stable：下載 → 核對 SHA256 → 驗 bundle → 本機憑證簽章 → 裝到 ~/Applications → 啟動。
#   curl -fsSL https://raw.githubusercontent.com/YSzEthan/monitor-align/main/scripts/install-release.sh | sh
# curl 下載的檔案不帶 com.apple.quarantine，所以不會被 Gatekeeper 擋。
# 流程與 install.sh 相同，只是「編譯」換成「下載並驗證」。測試版請裝好後用選單的「接收測試版」。
# 全部包在 main()、最後一行才呼叫：curl 中途斷線時 sh 只會收到半個函式（語法錯誤），不會執行一半。
set -eu

REPO=YSzEthan/monitor-align
CERT=monitor-align-dev
APPS="$HOME/Applications"
APP="$APPS/MonitorAlign.app"
STAGE="$APPS/.MonitorAlign.new.app"   # 與 app 內 installBundle 同名：app 啟動時會順手清掉殘留

die() { echo "錯誤：$*" >&2; exit 1; }
fetch() { curl -fsSL --proto '=https' --tlsv1.2 "$@"; }

main() {
  [ "$(uname -s)" = Darwin ] || die "只支援 macOS"
  # 不用 uname -m：終端機跑在 Rosetta 下會回 x86_64
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ] || die "Release 只有 Apple Silicon（arm64）版"

  tmp=$(mktemp -d); trap 'rm -rf "$tmp" "$STAGE"' EXIT

  json=$(fetch "https://api.github.com/repos/$REPO/releases/latest") \
    || die "查不到最新版本（網路不通，或被 GitHub 限流，稍後再試）"
  tag=$(printf '%s\n' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  # tag 會被拿去組網址，只收標準寫法的 stable（對應 app 內 canonicalTag）
  printf '%s\n' "$tag" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
    || die "最新版本的 tag 格式不認得：$tag"
  ver=${tag#v}

  # 網址一律自己用 tag 組，不採用 API 回傳的 browser_download_url
  name="MonitorAlign-$tag-arm64.zip"
  base="https://github.com/$REPO/releases/download/$tag"
  echo "下載 $tag …"
  fetch -o "$tmp/$name" "$base/$name" || die "下載失敗：$base/$name"
  fetch -o "$tmp/$name.sha256" "$base/$name.sha256" || die "下載失敗：$base/$name.sha256"

  # 直接比 hash 欄位，不信 .sha256 檔裡寫的檔名（shasum -c 會照檔名去找檔案）
  want=$(cut -d' ' -f1 "$tmp/$name.sha256")
  got=$(shasum -a 256 "$tmp/$name" | cut -d' ' -f1)
  [ -n "$want" ] && [ "$want" = "$got" ] || die "SHA256 不符，已中止"

  ditto -x -k "$tmp/$name" "$tmp/x"
  src="$tmp/x/MonitorAlign.app"
  [ -d "$src" ] || die "zip 內找不到 MonitorAlign.app"
  plist="$src/Contents/Info.plist"
  pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }
  [ "$(pb CFBundleIdentifier)" = dev.monitor-align ] || die "bundle id 不符"
  [ "$(pb CFBundleShortVersionString)" = "$ver" ] || die "app 版本與 tag 不符"

  # 在 staging 簽章並驗證；全部成功才動舊版，任何一步失敗舊版都原封不動
  mkdir -p "$APPS"
  rm -rf "$STAGE"
  ditto "$src" "$STAGE"
  xattr -cr "$STAGE"

  # 與 install.sh 一樣用本機自簽憑證：簽章身分固定，輔助使用授權才不會因更新失效
  H=
  ec="$STAGE/Contents/Resources/ensure-cert.sh"
  if [ -f "$ec" ]; then H=$(sh "$ec" "$CERT") || H=; fi
  if [ -n "$H" ]; then
    # 第一次用私鑰簽章可能因鑰匙圈詢問回 errSecInternalComponent，重試一次
    codesign --force -s "$H" --identifier dev.monitor-align "$STAGE" 2>/dev/null \
      || { sleep 1; codesign --force -s "$H" --identifier dev.monitor-align "$STAGE"; }
  else
    echo "警告：找不到可用的簽章憑證，沿用 ad-hoc 簽章。每次更新後都要重新授權輔助使用。"
  fi
  codesign --verify --strict "$STAGE" || die "簽章驗證失敗"

  # 簽章身分變了（第一次、或憑證重建）：舊授權對不上，清掉讓系統重新詢問
  dr() { codesign -d -r- "$1" 2>&1 | grep '^designated' || true; }
  if [ "$(dr "$APP")" != "$(dr "$STAGE")" ]; then
    tccutil reset Accessibility dev.monitor-align >/dev/null 2>&1 || true
    echo "簽章身分有變，啟動後請在 系統設定 → 隱私權與安全性 → 輔助使用 允許 MonitorAlign（只需這一次）。"
  fi

  pkill -f "$APP/Contents/MacOS/monitor-align" 2>/dev/null || true
  sleep 0.5
  rm -rf "$APP"
  mv "$STAGE" "$APP"
  open "$APP"
  echo "已安裝並啟動 $tag：$APP（選單列右上角的雙螢幕圖示）"
  if [ -d /Applications/MonitorAlign.app ]; then
    echo "提醒：/Applications 還有一份舊的 MonitorAlign.app，可以自行刪除。"
  fi
}

main "$@"
