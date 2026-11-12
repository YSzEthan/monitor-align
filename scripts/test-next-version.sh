#!/bin/bash
# next-version.sh 的情境測試。CI 會跑。
set -u
cd "$(dirname "$0")" || exit 1
fail=0
# check <預期> <channel> <bump> <tag...>
check() {
  want=$1 channel=$2 bump=$3; shift 3
  got=$(printf '%s\n' "$@" | ./next-version.sh "$channel" "$bump" | sed -n 's/^VERSION=//p')
  if [ "$got" = "$want" ]; then echo "ok   $channel/$bump [$*] → $got"
  else echo "FAIL $channel/$bump [$*] → ${got}（預期 ${want}）"; fail=1; fi
}

check 0.1.0-beta.1 dev   patch
check 0.1.0        main  patch
check 0.1.0-beta.3 dev   patch v0.1.0-beta.1 v0.1.0-beta.2
check 0.1.0        main  patch v0.1.0-beta.2
check 0.1.1-beta.1 dev   patch v0.1.0
check 0.2.0-beta.1 dev   minor v0.1.0
check 1.0.0-beta.1 dev   major v0.1.0
check 0.1.1        main  patch v0.1.0
check 0.1.1-beta.3 dev   patch v0.1.0 v0.1.1-beta.1 v0.1.1-beta.2
check 0.2.0-beta.1 dev   minor v0.1.0 v0.1.1-beta.1 v0.1.1-beta.2
check 0.1.1        main  patch v0.1.0 v0.1.1-beta.2
check 0.2.0        main  minor v0.1.0 v0.1.1-beta.2
# 發過 stable 之後，同 base 的舊 beta 不再算
check 0.1.1-beta.1 dev   patch v0.1.0 v0.1.0-beta.1 v0.1.0-beta.2
# 排序要真的比到 major／minor（不是字串排序）
check 1.0.1-beta.1 dev   patch v0.9.0 v1.0.0
check 0.10.1       main  patch v0.9.0 v0.10.0
check 0.10.1-beta.1 dev  patch v0.9.0 v0.10.0
check 0.10.0-beta.2 dev  patch v0.9.0 v0.10.0-beta.1
# 不合格 tag 被忽略
check 0.1.1-beta.1 dev   patch v0.1.0 v0.1.1-rc.1 v0.2.0-alpha
check 0.1.1        main  patch v0.1.0 foo v1

latest=$(printf '%s\n' v0.1.0 v0.2.0-beta.1 | ./next-version.sh main patch | sed -n 's/^LATEST_STABLE=//p')
[ "$latest" = v0.1.0 ] && echo "ok   LATEST_STABLE=$latest" || { echo "FAIL LATEST_STABLE=$latest"; fail=1; }

exit $fail
