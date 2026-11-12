#!/bin/bash
# 算下一個版號。用法：next-version.sh <dev|main> <patch|minor|major> < tag 清單（每行一個）
# 輸出兩行：VERSION=<不帶 v>、LATEST_STABLE=<帶 v，沒有則空>
#   main → stable  X.Y.Z
#   dev  → beta    X.Y.Z-beta.N
# 不用 sort -V（macOS 對 prerelease 排序不可靠）：先去掉 v 再逐欄數字排序。
set -eu
channel=$1 bump=$2
tags=$(cat)

sortv() { sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n; }
# 取 X.Y.Z 清單（stdin）的最大者；空輸入輸出空字串
maxv() { sortv | tail -1; }
bump_ver() {
  [ -z "$1" ] && { echo 0.1.0; return; }
  IFS=. read -r a b c <<<"$1"
  case $2 in
    major) echo "$((a + 1)).0.0" ;;
    minor) echo "$a.$((b + 1)).0" ;;
    *)     echo "$a.$b.$((c + 1))" ;;
  esac
}

stable=$(grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' <<<"$tags" | maxv || true)
betas=$(grep -E '^v[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$' <<<"$tags" || true)

label_base=$(bump_ver "$stable" "$bump")

# base = max(標籤算出的下一版, 已發 beta 系列的 X.Y.Z)。minor／major 標籤只會把 base 往上推；
# 已發過 stable 的舊 beta 一定小於 label_base（它必大於 stable），取 max 自然被排除
base=$({ echo "$label_base"; sed -E 's/-beta\.[0-9]+$//' <<<"$betas"; } | maxv)

if [ "$channel" = main ]; then
  version=$base
else
  n=$(grep -E "^v${base//./\\.}-beta\.[0-9]+\$" <<<"$betas" | sed -E 's/.*-beta\.//' | sort -n | tail -1 || true)
  version="$base-beta.$(( ${n:-0} + 1 ))"
fi

echo "VERSION=$version"
echo "LATEST_STABLE=${stable:+v$stable}"
