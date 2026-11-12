# monitor-align

macOS 選單列 app：多螢幕游標跨螢幕時依實體公釐換算位置，不跳位。單一檔案 `monitor-align.swift`，沒有 Xcode 專案（只有 Command Line Tools）。

## 常用指令

```sh
scripts/build-app.sh                                        # 編譯成 build/MonitorAlign.app（ad-hoc 簽章）
build/MonitorAlign.app/Contents/MacOS/monitor-align --selftest   # 純函式自我測試，不需螢幕
build/MonitorAlign.app/Contents/MacOS/monitor-align --dump       # 印螢幕、pt/mm、相鄰組與校正狀態
./install.sh                                                # 建憑證（首次）→ 編譯 → 簽章 → 裝到 ~/Applications → 啟動
```

## 結構

- 純函式（`derivePairs`、`crossPoint`、校正檔 v2 的 `matchCalib`／`mergeCalib` 等）放最上面，`selftest()` 直接測；不要在這區碰 CG／AppKit。
- event tap 的 callback 是 C function pointer，只能用全域變數（`M`、`glidePaused`、`calibrating`…）。
- 校正檔 `~/.config/monitor-align/calib.json`（v2）：ref 是各螢幕的區域座標，key 為「廠牌-型號-序號/解析度」，與排列無關。舊格式一律忽略。

## 簽章與授權（改動時要記得）

- 輔助使用授權綁簽章的 designated requirement。`install.sh` 用本機自簽憑證 `monitor-align-dev` 簽章，DR 不隨重新編譯改變，所以授權保留。
- 自簽憑證**必須** `add-trusted-cert` 才能被 `codesign` 使用（首次安裝會要登入密碼）。憑證用 `/usr/bin/openssl`（LibreSSL）產生，openssl 3 的 PKCS#12 `security import` 讀不了。
- 同名憑證可能有多張，`codesign -s` 一律傳 SHA-1 hash。
- 不要用 event tap 抓鍵盤（會多一個 Input Monitoring 權限）；校正用 local `NSEvent` monitor 與 60Hz 輪詢游標位置。

## 分支與發版（專案例外）

**此專案合進 `dev` 自動發 beta，`dev` 合進 `main` 自動發 stable。全域規範的「版號 commit 經 PR、推 tag 前先問」在這裡不適用，以本段為準**，不要因為全域規範而停下來問要不要打 tag。

### 分支

- `main`：stable。`dev`：整合分支，從 `main` 切出。
- **gh 預設 `main`**：GitHub 預設分支是 `main`，所以開 PR 一律明確 `gh pr create --base dev`。
- **git 預設 `dev`**：日常工作分支是 `dev`。功能分支 `issue/<n>` 從 `dev` 切出，PR 的 base 是 `dev`，用 squash merge。
- `dev` → `main` 發 stable：PR 用 **merge commit**（不 squash，兩條分支才不會分岔）。進 `main` 的 PR 只能來自 `dev`，`ci.yml` 的 `base-guard` 會擋其他來源（要設成 `main` 的必要檢查）。
- 兩條分支都開分支保護（要求 PR），**不開**「require branches up to date」。沒有保護時 owner 直接 push 也會發版。

### 發版

- `.github/workflows/release.yml`：`push` 到 `dev` 或 `main`，或 `workflow_dispatch`（只准從這兩條分支）。組 `MonitorAlign-vX.Y.Z[-beta.N]-arm64.zip` 與 `.sha256`，**最後才** `gh release create`，所以中途失敗不會留下孤兒 tag。
- 版號由 `scripts/next-version.sh` 算（`scripts/test-next-version.sh` 測，CI 會跑）：
  - `main` → `vX.Y.Z`（stable，latest）；`dev` → `vX.Y.Z-beta.N`（prerelease），`X.Y.Z` 是下一個 stable 版號，N 每次合進 `dev` 加 1。
  - stable 會延續已發的 beta 系列（`0.2.0-beta.3` 之後發 `0.2.0`）。沒有任何 tag 時，第一個 beta 是 `0.1.0-beta.1`，第一個 stable 是 `0.1.0`。
  - 不用 `sort -V`（macOS 對 prerelease 排序不可靠）。
- PR 標籤：`minor`／`major` 把 base 往上推，`no-release` 不發版。`dev` 上看**功能 PR** 的標籤，`main` 上看 **dev→main 那個 PR** 的標籤。
- 標籤靠 `commits/{sha}/pulls` 查，不解析 commit 標題。concurrency 每條分支各一個 group；同一條分支連續三個 merge 時，排隊被取消那次的內容併入下一版，它 PR 上的標籤會丟失。
- 「這個 commit 已發過」的判斷分通道（`main` 只看 stable tag，`dev` 只看 beta tag），所以 dev→main 即使用 fast-forward 合併也不會壞。
- `VERSION` 不帶 `v`（`0.1.1`、`0.1.1-beta.2`）；tag 帶 `v`。本機編譯的版號是 `dev`。

### 信任根

- zip 與 SHA256 放在同一個 Release，HTTPS 已保證傳輸完整，所以 SHA256 只防傳輸損毀、**不防竄改**。
- 真正的信任根是「任何能寫入這個 repo 或 Release 的人或東西」，包括被入侵的 action 依賴。
- 最大風險是 app 內「檢查更新…」用使用者本機憑證重簽下載的 app：能把檔案放進 Release 的人，就能讓它繼承輔助使用權限（event tap 足以側錄鍵盤）。要做真正的來源驗證得用離線金鑰簽 Release，那跟 CI 自動發版互相矛盾，所以不做。
- 緩解：`main`、`dev` 分支保護、action 以 commit SHA 釘版本、下載網址由 app 自己用 tag 組（不信 API 回傳的網址）、解壓後驗 bundle id 與版本、更新一律由使用者確認。
- 不共用憑證：私鑰不放 GitHub，每個使用者在自己機器建自己的憑證。

## 流程

遵守全域開發規範（issue → 從 `dev` 切 branch `issue/<n>` → plan → review → 實作 → `/simplify` → CI 綠燈 → commit → PR 到 `dev`）。PR 的 CI（`.github/workflows/ci.yml`）在 arm64 macOS 跑版號腳本測試、編譯與 selftest。
