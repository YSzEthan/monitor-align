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

## 流程

遵守全域開發規範（issue → branch `issue/<n>` → plan → review → 實作 → `/simplify` → CI 綠燈 → commit → PR）。PR 的 CI（`.github/workflows/ci.yml`）在 arm64 macOS 跑編譯與 selftest。
