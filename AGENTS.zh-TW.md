# 專案工作規範

[English](AGENTS.md) | **繁體中文**

## 交付流程

專案擁有者指定：完成授權範圍與驗證後，commit、push 工作分支、建立以 main 為目標的 PR，必要檢查／審核通過後合併，刪除本次遠端及本機分支，回到最新 main。後續明確指示優先；已授權交付時，不要只停在提議建立 PR。

1. 檢查工作目錄與指示，保留不相關變更。fetch origin，在安全切換前提下從最新 main 開始。
2. 分支前綴**區分大小寫**，後接小寫英文連字號描述：
   - `Feature/`：新增功能，例如 Feature/scan-search。
   - `Bugfix/`：修正錯誤，例如 Bugfix/playback-orientation。
   - `Enhance/`：改善既有功能、效能、UX、文件或維護，例如 Enhance/bilingual-ui-docs-workflow。
   不用 codex/ 或前綴小寫變體；一般工作不留長期額外分支。
3. 完成全部範圍並更新雙語文件。檢查最終差異，排除不相關修改、掃描資料、機密與建置產物。
4. 執行相關驗證。Swift App 變更依序建置未簽章 iPhone／Simulator，執行相關回歸；語言／文件變更加跑 python3 tools/check_project.py 與語系測試，清楚說明合成／模擬器限制。
5. 使用具體英文 commit 主旨（feat:、fix:、enhance: 或 docs:），push 並開 PR。描述最終行為、取捨、驗證及待實機檢查，英文先、繁中摘要後。有附加工具時把 PR 附到目前工作。
6. 檢查 PR 可合併性與必要檢查／審核，修正失敗後重跑相關檢查並更新 PR。合併已驗證的 head，通常 squash。不可直接推 main、用管理員繞過、關閉保護或跳過必要審核；外部條件阻擋時明確回報，保留 PR 與分支。
7. 確認合併後，只刪除**本次工作分支**的遠端與本機版本，main 僅以 fast-forward 更新並 prune。Squash 後本機可能需 branch -D，但必須先核對 PR 合併 head 且工作目錄乾淨。不可刪除其他分支、worktree 或未合併成果。
8. 回報 PR、合併 commit、主要改動、驗證與最終分支狀態。未確認前不得宣稱已合併／清理。

## 語言與相容性

- 文件英文優先（README.md、docs/NAME.md），完整繁中對照（README.zh-TW.md、docs/NAME.zh-TW.md），互相連結，同語言內連結對應版本。
- App 預設繁中，首頁可選英文並保存。使用 L10n 與 en.lproj／zh-Hant.lproj 處理文字、動態訊息、無障礙、錯誤與進度；機器可讀識別碼不隨語言改變。
- 本機專案、scheme、repo 名稱與 bundle ID 均為 arkit-3dgs-scanner。識別碼、程式碼與文件中不得出現公司或雇主名稱；本專案為個人研究專案。
- 寫 capture-meta.json，繼續讀舊 meta.json，匯出改名保留原 bytes。
- 保留原照片／深度。運動估計不是實測模糊，警告政策與深度融合資格分開。
- 手機端 3DGS 訓練（Metal，[說明](docs/ON_DEVICE_3DGS.zh-TW.md)）與供外部訓練器使用的 COLMAP 資料匯出並存。訓練必須在裝置上執行：不得把伺服器流程包裝成手機端訓練、記憶體配置須有上限，並在進入背景、過熱、低電量或記憶體不足時暫停並儲存檢查點。不得以 Mac 或 Simulator 結果宣稱裝置上的記憶體或速度。

指令參考[貢獻流程](CONTRIBUTING.zh-TW.md)及[語系文件](docs/LOCALIZATION.zh-TW.md)。
