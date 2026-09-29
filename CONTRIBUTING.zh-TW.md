# 貢獻流程

[English](CONTRIBUTING.md) | **繁體中文**

依照擁有者指定的[工作規範](AGENTS.zh-TW.md)，透過 PR 送至 main；必要檢查／審核通過後合併，再刪除本次遠端與本機分支。不可繞過保護，若受阻就保留 PR 並說明原因。

## 分支命名

| 前綴 | 用途 | 範例 |
| --- | --- | --- |
| Feature/ | 新功能 | Feature/scan-search |
| Bugfix/ | 修正問題 | Bugfix/playback-orientation |
| Enhance/ | 改善既有功能、效能、UI、文件與維護 | Enhance/bilingual-ui-docs-workflow |

前綴區分大小寫，後接小寫英文連字號描述。保留不相關變更，再從最新 main 開始；不可刪除其他工作的分支。

## 驗證

```sh
python3 tools/check_project.py
bash tools/test_localization.sh
bash tools/test_training_quality.sh
bash tools/test_gaussian_training.sh
bash tools/test_metric_loop.sh
bash tools/test_fusion_memory.sh
xcodebuild -project arkit-3dgs-scanner.xcodeproj -scheme arkit-3dgs-scanner \
  -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project arkit-3dgs-scanner.xcodeproj -scheme arkit-3dgs-scanner \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

iPhone 與 Simulator 依序建置，避免 build database 鎖定衝突；依受影響模組加跑回歸。編譯／合成測試不代表感測器精度。呼叫語系程式的 Swift 命令列工具需加入 Capture/Localization.swift；沒有 App bundle 資源時會退回中文來源文字。

文件英文優先，搭配 .zh-TW.md；App 預設繁中、可切英文。參見[語系慣例](docs/LOCALIZATION.zh-TW.md)。不提交原始掃描、私人影像、憑證或建置輸出。

## 程式結構

```text
arkit-3dgs-scanner/Capture/    AR session、關鍵影格、融合、姿態精修、照片選用、匯出
arkit-3dgs-scanner/History/    掃描紀錄、回放、重處理與刪除
arkit-3dgs-scanner/Training/   手機端 3DGS：Metal 核心、訓練器、記憶體配置、檢查點、匯出、檢視器與介面
tools/                         資料轉換、分析與回歸測試
docs/                          架構、座標、品質與效能說明
```

`arkit-3dgs-scanner` scheme 執行最佳化的 Release 版；只有需要逐行除錯時才用 `arkit-3dgs-scanner-Debug`，因為 Debug 版的融合與訓練慢很多（見[融合診斷](docs/SCAN_FUSION_DIAGNOSTICS.zh-TW.md)）。`Training/` 是以 Swift 與 Metal 全新實作，不使用先前的 msplat C++ 引擎、橋接或建置設定。掃描與資料集準備不依賴訓練器。

## 可選的 Python 工具

```sh
python3 -m venv .venv
.venv/bin/pip install -r tools/requirements.txt
.venv/bin/python tools/test_math.py
.venv/bin/python tools/validate_dataset.py /path/to/scan
.venv/bin/python tools/arkit2gs.py /path/to/scan -o /path/to/dataset --format both
```

## 授權

貢獻的內容一律採用本專案的 [Apache License 2.0](LICENSE)。請保留 [NOTICE](NOTICE)，新增的 3DGS 原始碼檔也請加上相同的 `SPDX-License-Identifier` 檔頭。

## PR 與合併

英文 commit 主旨具體描述改動，前綴 feat:、fix:、enhance: 或 docs:。PR 說明問題、結果、驗證及限制，英文在前、繁中摘要在後。使用 gh 時，把多行說明寫入檔案，透過 --body-file 傳入。commit 與 PR 不加 AI 工具的標註（「Generated with Claude Code」、AI 的 `Co-Authored-By` 行）。

Push 分支、開 PR、確認必要狀態／審核後合併已驗證的 head，通常 squash。若 main 變動影響本次修改，更新分支並重跑相關檢查。禁止 --admin、關閉規則或直接推 main。

確認合併後回到 main，pull --ff-only，清除本次 origin／本機分支並 fetch/prune。Squash 後強制刪本機分支前需核對 PR 已合併。最後回報 PR、merge commit、改動、測試及清理狀態。
